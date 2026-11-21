@testable import CatusshModule
import XCTest

final class OpenSSHConfigReaderTests: XCTestCase {
    private func withDirectory(_ run: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(directory)
    }

    private func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testDefaultsAliasesQuotesAndFirstMatchingValue() throws {
        try withDirectory { directory in
            try write("""
            User = "DefaultUser" # before any Host
            Host "build" build2
                HostName=%h.example.com
                IdentityFile "~/.ssh/my key" # connection metadata only
                User later
            Host Build
                HostName 2001:db8::1
            Host build
                HostName ignored.example.com
            Host build? !build3
                Port 2201
            Host * !Build
                Port = 2222
            Host excluded !excluded
                User secret
            """, to: directory.appendingPathComponent("config"))
            let preview = try OpenSSHConfigReader.read(directory: directory)
            XCTAssertEqual(preview.hosts, [
                .init(alias: "build", hostname: "build.example.com", username: "DefaultUser", port: 2222),
                .init(alias: "build2", hostname: "build2.example.com", username: "DefaultUser", port: 2201),
                .init(alias: "Build", hostname: "2001:db8::1", username: "DefaultUser", port: 22),
            ])
            XCTAssertTrue(preview.skipped.isEmpty)
        }
    }

    func testSkipsUnrepresentableDestinationsAndInvalidValues() throws {
        try withDirectory { directory in
            try write("""
            Host private
                ProxyJump gateway
            Host via-command
                ProxyCommand echo 'never executed'
            Host invalid-port
                Port 70000
            Host invalid-host
                HostName ${HOST}
            Host pinned
                UserKnownHostsFile /custom/trust
            Host restricted
                IdentitiesOnly yes
            Host no-agent
                IdentityAgent none
            Host plain
            Host * !plain
                Port 2022
            """, to: directory.appendingPathComponent("config"))
            let preview = try OpenSSHConfigReader.read(directory: directory, defaultUsername: "LocalUser")
            XCTAssertEqual(preview.hosts, [.init(alias: "plain", hostname: "plain", username: "LocalUser", port: 22)])
            XCTAssertEqual(preview.skipped.map(\.alias), ["private", "via-command", "invalid-port", "invalid-host", "pinned", "restricted", "no-agent"])
            XCTAssertTrue(preview.skipped[0].reason.lowercased().contains("proxyjump"))
        }
    }

    func testExplicitDirectHostOverridesWildcardRestrictions() throws {
        try withDirectory { directory in
            try write("""
            Host direct disabled-command overridden-jump
                CanonicalizeHostname no
                IdentitiesOnly no
                IdentityAgent SSH_AUTH_SOCK
            Host direct overridden-jump
                ProxyJump none
            Host disabled-command
                ProxyCommand none
            Host overridden-jump
                ProxyCommand ssh proxy
            Host *
                ProxyJump gateway
                IdentityAgent none
                IdentitiesOnly yes
                CanonicalizeHostname yes
            """, to: directory.appendingPathComponent("config"))
            let preview = try OpenSSHConfigReader.read(directory: directory)
            XCTAssertEqual(preview.hosts.map(\.alias), ["direct", "disabled-command"])
            XCTAssertEqual(preview.skipped.map(\.alias), ["overridden-jump"])
            XCTAssertTrue(preview.skipped[0].reason.lowercased().contains("proxycommand"))
        }
    }

    func testOnlyUnquotedWordBoundaryStartsComment() throws {
        try withDirectory { directory in
            // U+2028 inside a comment does not start a new OpenSSH directive.
            try write("""
            # comment\u{2028}Host escaped
            Host build
                HostName buil"d".example # hostname comment
                User 'LocalUser'
            Host bad
                HostName "alias"#suffix
            """, to: directory.appendingPathComponent("config"))
            let preview = try OpenSSHConfigReader.read(directory: directory)
            XCTAssertEqual(preview.hosts, [.init(alias: "build", hostname: "build.example", username: "LocalUser", port: 22)])
            XCTAssertEqual(preview.skipped.map(\.alias), ["bad"])
        }
    }

    func testFilesAreIncludedInOrderWithoutLeakingHostConditionBackToParent() throws {
        try withDirectory { directory in
            let fragments = directory.appendingPathComponent("config.d")
            try FileManager.default.createDirectory(at: fragments, withIntermediateDirectories: false)
            try write("""
            Include "~/.ssh/config.d/*.conf" missing/*.conf
            User fallback
            Host local
            """, to: directory.appendingPathComponent("config"))
            try write("Host build\n  Port 2022", to: fragments.appendingPathComponent("10-address.conf"))
            try write("Host build\n  Port 3333\n  HostName example.org", to: fragments.appendingPathComponent("20-overrides.conf"))
            let preview = try OpenSSHConfigReader.read(directory: directory)
            XCTAssertEqual(preview.hosts, [
                .init(alias: "build", hostname: "example.org", username: "fallback", port: 2022),
                .init(alias: "local", hostname: "local", username: "fallback", port: 22),
            ])
        }
    }

    func testFailsClosedWhenEvaluationNeedsUnsupportedConditionsOrPaths() throws {
        try withDirectory { directory in
            let config = directory.appendingPathComponent("config")
            for text in [
                "Host build\nInclude unknown.conf",
                "Host build\nMatch exec 'echo no'\nProxyJump gateway",
                "Host *\nInclude config",
                "Include ../outside.conf",
                "Include ${HOME}/hosts.conf",
                "Host build\nUser \"unterminated",
            ] {
                try write(text, to: config)
                XCTAssertThrowsError(try OpenSSHConfigReader.read(directory: directory), text)
            }
            try withDirectory { outside in
                let external = outside.appendingPathComponent("external.conf")
                try write("Host escaped", to: external)
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.conf"), withDestinationURL: external)
                try write("Include linked.conf", to: config)
                XCTAssertThrowsError(try OpenSSHConfigReader.read(directory: directory))
            }
        }
    }
}

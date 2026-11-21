import Darwin
import Foundation

public struct OpenSSHConfigHost: Hashable, Identifiable, Sendable {
    public let alias: String
    public let hostname: String
    public let username: String
    public let port: Int
    public var id: String { alias }
}

public struct OpenSSHConfigSkip: Hashable, Identifiable, Sendable {
    public let alias: String
    public let reason: String
    public var id: String { alias }
}

public struct OpenSSHConfigPreview: Sendable {
    public let hosts: [OpenSSHConfigHost]
    public let skipped: [OpenSSHConfigSkip]
}

/// Imports endpoint metadata from the selected user configuration. The caller owns
/// security-scoped access to the directory for the duration of the read. No processes,
/// system ssh_config, identity files, agent sockets or host-key databases are accessed.
public enum OpenSSHConfigReader {
    public static func read(directory: URL, defaultUsername: String = NSUserName()) throws -> OpenSSHConfigPreview {
        var parser = Parser(directory: directory.standardizedFileURL.resolvingSymlinksInPath())
        try parser.read(parser.directory.appendingPathComponent("config"), ancestors: [])
        var hosts: [OpenSSHConfigHost] = []
        var skipped: [OpenSSHConfigSkip] = []
        for alias in parser.aliases {
            do {
                hosts.append(try parser.resolve(alias, defaultUsername: defaultUsername))
            } catch {
                skipped.append(OpenSSHConfigSkip(alias: alias, reason: error.localizedDescription))
            }
        }
        return OpenSSHConfigPreview(hosts: hosts, skipped: skipped)
    }
}

private struct ConfigError: LocalizedError {
    let errorDescription: String?
    init(_ message: String.LocalizationValue) { errorDescription = String(localized: message) }
}

private struct Block {
    var patterns = ["*"]
    var options: [(key: String, arguments: [String])] = []

    func matches(_ alias: String) -> Bool {
        var positive = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let glob = negated ? String(pattern.dropFirst()) : pattern
            // OpenSSH host patterns have only two metacharacters, * and ?.
            if fnmatch(glob.replacingOccurrences(of: "[", with: "\\["), alias, 0) == 0 {
                if negated { return false }
                positive = true
            }
        }
        return positive
    }
}

private struct Parser {
    let directory: URL
    var aliases: [String] = []
    private var seen: Set<String> = []
    private var blocks: [Block] = []
    private var remainingBytes = 1_048_576
    private var remainingFiles = 256

    init(directory: URL) { self.directory = directory }

    mutating func read(_ file: URL, ancestors: Set<URL>) throws {
        let file = try contained(file)
        guard !ancestors.contains(file), ancestors.count < 16 else {
            throw ConfigError("Recursive OpenSSH Include in \(file.lastPathComponent).")
        }
        let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize,
              size <= remainingBytes, remainingFiles > 0
        else { throw ConfigError("OpenSSH configuration exceeds the import limit or contains a non-regular file.") }
        guard file.lastPathComponent == "config" || file.pathExtension == "conf" else {
            throw ConfigError("Only config and .conf files inside the selected SSH folder can be included.")
        }
        remainingFiles -= 1
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: remainingBytes + 1) ?? Data()
        remainingBytes -= data.count
        guard remainingBytes >= 0, let content = String(data: data, encoding: .utf8), !content.contains("\0") else {
            throw ConfigError("Invalid or oversized OpenSSH configuration in \(file.lastPathComponent).")
        }

        var block = Block()
        let lines = content.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        for (offset, line) in lines.enumerated() {
            var location: String { String(localized: "\(file.lastPathComponent), line \(offset + 1)") }
            let input = line.drop(while: Self.isSeparator)
            guard !input.isEmpty, input.first != "#" else { continue }
            let keyword = input.prefix { !Self.isSeparator($0) && $0 != "=" }
            let key = keyword.lowercased()
            var rest = input[keyword.endIndex...].drop(while: Self.isSeparator)
            if rest.first == "=" { rest = rest.dropFirst().drop(while: Self.isSeparator) }
            guard !key.isEmpty, let arguments = Self.words(rest), !arguments.isEmpty else {
                throw ConfigError("Invalid OpenSSH directive in \(location).")
            }
            switch key {
            case "host":
                if !block.options.isEmpty { blocks.append(block) }
                block = Block(patterns: arguments)
                for alias in arguments where !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?") {
                    if block.matches(alias), seen.insert(alias).inserted { aliases.append(alias) }
                }
                guard aliases.count <= 2048 else { throw ConfigError("Too many OpenSSH hosts to import.") }
            case "include":
                guard block.patterns == ["*"] else { throw ConfigError("Conditional Include in \(location) requires OpenSSH.") }
                if !block.options.isEmpty { blocks.append(block) }
                block.options = []
                for argument in arguments {
                    for included in try includeFiles(argument) {
                        try read(included, ancestors: ancestors.union([file]))
                    }
                }
            case "match":
                throw ConfigError("Match in \(location) requires OpenSSH to evaluate conditional settings.")
            default:
                block.options.append((key, arguments))
            }
        }
        if !block.options.isEmpty { blocks.append(block) }
    }

    private func contained(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(directory.path + "/") else {
            throw ConfigError("An OpenSSH Include points outside the selected SSH folder.")
        }
        return resolved
    }

    /// Relative Include paths are relative to ~/.ssh, even inside an included file.
    /// Expand common filename globs only, avoiding traversal into unrelated directories.
    private func includeFiles(_ argument: String) throws -> [URL] {
        var path = argument
        if path.hasPrefix("~/.ssh/") { path.removeFirst("~/.ssh/".count) }
        guard !path.isEmpty, !path.hasPrefix("~"), !path.contains(where: { "%$[]{}\\".contains($0) }),
              !path.split(separator: "/").contains("..")
        else { throw ConfigError("Unsupported OpenSSH Include path.") }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard !parent.path.contains(where: { "*?".contains($0) }), parent.path == directory.path || parent.path.hasPrefix(directory.path + "/") else {
            throw ConfigError("OpenSSH Include must name a directory inside the selected SSH folder.")
        }
        let glob = url.lastPathComponent
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [] // OpenSSH ignores Include patterns with no matches.
        }
        return entries.filter { fnmatch(glob, $0.lastPathComponent, FNM_PERIOD) == 0 }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
    }

    private static func isSeparator(_ c: Character) -> Bool { c == " " || c == "\t" }

    /// Tokenize configuration values without shell expansion. Reject escapes rather
    /// than giving a shell command or a filename a different interpretation.
    private static func words(_ input: Substring) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        for c in input {
            if c == "\\" || (c.isWhitespace && !isSeparator(c)) { return nil }
            if let delimiter = quote {
                if c == delimiter { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if isSeparator(c) {
                if started { words.append(word) }
                word = ""
                started = false
            } else if c == "#", !started {
                break
            } else {
                word.append(c)
                started = true
            }
        }
        guard quote == nil else { return nil }
        if started { words.append(word) }
        return words
    }

    private static func isDisabled(_ arguments: [String]) -> Bool {
        arguments.count == 1 && ["no", "false"].contains(arguments[0].lowercased())
    }

    func resolve(_ alias: String, defaultUsername: String) throws -> OpenSSHConfigHost {
        var values: [String: String] = [:]
        var seenOptions: Set<String> = []
        for block in blocks where block.matches(alias) {
            for (key, arguments) in block.options {
                guard seenOptions.insert(key).inserted else { continue }
                switch key {
                case "hostname", "user", "port":
                    guard arguments.count == 1 else { throw ConfigError("Invalid \(key) setting.") }
                    values[key] = arguments[0]
                case "proxyjump" where seenOptions.contains("proxycommand"):
                    // Even ProxyCommand none blocks later jumps. ProxyJump none,
                    // however, still allows a subsequent ProxyCommand to take effect.
                    continue
                case "proxyjump", "proxycommand":
                    if arguments.map({ $0.lowercased() }) != ["none"] { throw ConfigError("\(key) requires a proxy connection.") }
                case "canonicalizehostname":
                    if !Self.isDisabled(arguments) { throw ConfigError("Hostname canonicalization requires OpenSSH.") }
                case "identitiesonly":
                    if !Self.isDisabled(arguments) { throw ConfigError("IdentitiesOnly requires a specific SSH identity.") }
                case "identityagent":
                    if arguments != ["SSH_AUTH_SOCK"] { throw ConfigError("IdentityAgent changes the SSH agent used for authentication.") }
                case "identityfile", "addkeystoagent", "usekeychain", "ignoreunknown",
                     "serveraliveinterval", "serveralivecountmax", "tcpkeepalive", "loglevel", "compression":
                    // Credentials are selected independently in catussh. Keepalive,
                    // logging and compression settings do not select a destination.
                    continue
                default:
                    throw ConfigError("Unsupported OpenSSH directive: \(key).")
                }
            }
        }
        let hostname = (values["hostname"] ?? alias).replacingOccurrences(of: "%h", with: alias)
        let username = values["user"] ?? defaultUsername
        guard !alias.isEmpty, !alias.hasPrefix("-"), !hostname.isEmpty, !hostname.hasPrefix("-"),
              hostname.allSatisfy({ $0.isLetter || $0.isNumber || "._-:".contains($0) })
        else { throw ConfigError("Invalid or unsupported hostname.") }
        guard !username.isEmpty, !username.hasPrefix("-"),
              username.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { throw ConfigError("Invalid or unsupported username.") }
        let portText = values["port"] ?? "22"
        guard portText.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(portText), port > 0 else {
            throw ConfigError("Invalid port.")
        }
        return OpenSSHConfigHost(alias: alias, hostname: hostname, username: username, port: Int(port))
    }
}

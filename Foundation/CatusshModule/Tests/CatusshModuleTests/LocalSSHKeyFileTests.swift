#if os(macOS)
    @testable import CatusshModule
    import NSRemoteShell
    import XCTest

    final class LocalSSHKeyFileTests: XCTestCase {
        func testDraftKeepsTheReferenceAndPassphraseOutOfSyncAndBackup() throws {
            let original = RDIdentity(username: "deploy", password: "prior-password")
            defer { LocalSSHKeyFile.setURL(nil, for: original.id) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-deploy-key")
            var draft = IdentityDraft(original)
            draft.method = .localKeyFile
            draft.localKeyURL = url
            draft.localKeyPassphrase = "sample-session-passphrase"
            XCTAssertTrue(draft.isValid)
            XCTAssertTrue(draft.differs(from: original))
            XCTAssertNil(LocalSSHKeyFile.url(for: original.id))

            let saved = draft.saving(to: original)
            XCTAssertTrue(saved.usesLocalKeyFile)
            XCTAssertFalse(saved.useSSHAgent)
            XCTAssertTrue(saved.privateKey.isEmpty && saved.password.isEmpty)
            let encoded = String(decoding: try JSONEncoder().encode(saved.content), as: UTF8.self)
            XCTAssertFalse(encoded.contains(url.lastPathComponent))
            XCTAssertFalse(encoded.contains(draft.localKeyPassphrase))
            XCTAssertFalse(encoded.contains("prior-password"))

            var reopened = IdentityDraft(saved)
            XCTAssertEqual(reopened.localKeyURL, url.standardizedFileURL)
            XCTAssertEqual(reopened.localKeyPassphrase, draft.localKeyPassphrase)
            XCTAssertFalse(reopened.differs(from: saved))
            reopened.method = .sshAgent
            let agent = reopened.saving(to: saved)
            XCTAssertTrue(agent.useSSHAgent)
            XCTAssertFalse(agent.usesLocalKeyFile)
            XCTAssertNil(LocalSSHKeyFile.url(for: agent.id))
            XCTAssertTrue(LocalSSHKeyFile.passphrase(for: agent.id).isEmpty)
        }

        func testMissingDeviceReferenceFailsWithoutTryingOtherCredentials() {
            var synced = RDIdentity(username: "deploy", privateKey: "old-value")
            synced.usesLocalKeyFile = true
            XCTAssertNil(LocalSSHKeyFile.url(for: synced.id))
            XCTAssertTrue(synced.privateKey.isEmpty)
            let shell = NSRemoteShell()
            synced.callAuthenticationWith(remote: shell)
            XCTAssertFalse(shell.isAuthenticated)
            XCTAssertEqual(shell.getLastError(), String(localized: "The local key file is unavailable on this device. Choose a key in Identities."))
            XCTAssertEqual(synced.localKeyAuthenticationHint, String(localized: "Choose a readable local key file for this login in Identities on this Mac."))
        }
    }
#endif

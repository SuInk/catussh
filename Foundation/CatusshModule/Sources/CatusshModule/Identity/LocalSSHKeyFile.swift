import Foundation
import os

/// Device-local settings for a file-backed identity. Sync and backup encode
/// RDIdentity, which carries only the authentication method.
public enum LocalSSHKeyFile {
    private static let sessionPassphrases = OSAllocatedUnfairLock(initialState: [UUID: String]())

    public static func url(for identityID: UUID) -> URL? {
        #if os(macOS)
            guard let path = UserDefaults.standard.string(forKey: defaultsKey(identityID)) else { return nil }
            return URL(fileURLWithPath: path)
        #else
            return nil
        #endif
    }

    public static func setURL(_ url: URL?, for identityID: UUID) {
        #if os(macOS)
            guard url == nil || url?.isFileURL == true else { return }
            let path = url?.standardizedFileURL.path
            if path != self.url(for: identityID)?.path { setPassphrase("", for: identityID) }
            UserDefaults.standard.set(path, forKey: defaultsKey(identityID))
        #endif
    }

    private static func defaultsKey(_ id: UUID) -> String { "localSSHKeyFile." + id.uuidString }

    static func passphrase(for id: UUID) -> String {
        sessionPassphrases.withLock { $0[id] ?? "" }
    }

    static func setPassphrase(_ passphrase: String, for id: UUID) {
        sessionPassphrases.withLock { $0[id] = passphrase.isEmpty ? nil : passphrase }
    }

    static func readableURL(for id: UUID) -> URL? {
        guard let url = url(for: id)?.resolvingSymlinksInPath(),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: url.path)
        else { return nil }
        return url
    }
}

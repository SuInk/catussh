#if os(macOS)
    import Foundation

    public enum SSHSetupAgentStatus: Sendable {
        case available, empty, unavailable

        /// Checks the same agent socket that catussh inherits from macOS.
        /// Listing identities neither signs in to a server nor loads a key.
        public static func check() async -> Self {
            await Task.detached(priority: .utility) { probe() }.value
        }

        private static func probe() -> Self {
            guard let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !socket.isEmpty else { return .unavailable }
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            command.arguments = ["-l"]
            command.environment = ["SSH_AUTH_SOCK": socket, "LC_ALL": "C"]
            command.standardInput = FileHandle.nullDevice
            command.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            command.standardError = errors

            let finished = DispatchSemaphore(value: 0)
            command.terminationHandler = { _ in finished.signal() }
            do { try command.run() } catch { return .unavailable }
            guard finished.wait(timeout: .now() + .seconds(2)) == .success else {
                if command.isRunning { command.terminate() }
                return .unavailable
            }
            guard command.terminationReason == .exit else { return .unavailable }
            switch command.terminationStatus {
            case 0:
                return .available
            case 1:
                // ssh-add prints "The agent has no identities." on stdout.
                // An agent that refuses the listing also exits 1, but writes
                // a diagnostic to stderr. Fingerprints on stdout are discarded.
                return errors.fileHandleForReading.readData(ofLength: 1).isEmpty ? .empty : .unavailable
            default:
                return .unavailable
            }
        }
    }
#endif

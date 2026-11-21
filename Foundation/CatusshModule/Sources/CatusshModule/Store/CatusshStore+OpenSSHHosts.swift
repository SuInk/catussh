import Foundation

private let importedAliasKey = "openssh.alias"

public enum OpenSSHImportState: Equatable, Sendable {
    case new, update, saved, conflict
}

public struct OpenSSHImportResult: Equatable, Sendable {
    public var added = 0
    public var updated = 0
}

private enum OpenSSHImportError: LocalizedError {
    case changed, dependency(String, String), locked

    var errorDescription: String? {
        switch self {
        case .changed:
            String(localized: "The SSH configuration or a saved server changed. Review the selection again.")
        case let .dependency(jump, target):
            String(localized: "Select the jump host \(jump) before importing \(target).")
        case .locked:
            String(localized: "Unlock your keychain and reopen catussh to save imported servers.")
        }
    }
}

private struct ImportedLogin: Hashable {
    let username: String
    let keyFile: URL?

    init(_ host: OpenSSHConfigHost) {
        username = host.username
        keyFile = host.identityFile?.standardizedFileURL
    }

    init?(_ identity: RDIdentity) {
        username = identity.username
        if identity.usesLocalKeyFile {
            guard let url = LocalSSHKeyFile.url(for: identity.id) else { return nil }
            keyFile = url.standardizedFileURL
        } else {
            guard identity.useSSHAgent else { return nil }
            keyFile = nil
        }
    }
}

@MainActor
private struct OpenSSHImportPlan {
    let hosts: [OpenSSHConfigHost]
    var states = [String: OpenSSHImportState]()
    var existing = [String: RDMachine]()

    init(_ candidates: [OpenSSHConfigHost], store: CatusshStore) {
        var byAlias = [String: OpenSSHConfigHost]()
        var ordered = [OpenSSHConfigHost]()
        for host in candidates {
            if let previous = byAlias[host.alias] {
                if previous != host { states[host.alias] = .conflict }
            } else {
                byAlias[host.alias] = host
                ordered.append(host)
            }
        }
        hosts = ordered

        var matches = [String: [RDMachine]]()
        for machine in store.machineGroup.machines {
            matches[machine.name, default: []].append(machine)
            if let alias = machine.attachment[importedAliasKey], alias != machine.name {
                matches[alias, default: []].append(machine)
            }
        }
        for host in hosts where states[host.alias] == nil {
            if let file = host.identityFile {
                #if os(macOS)
                    guard file.isFileURL else { states[host.alias] = .conflict; continue }
                #else
                    states[host.alias] = .conflict
                    continue
                #endif
            }
            guard let matches = matches[host.alias] else {
                states[host.alias] = .new
                continue
            }
            guard matches.count == 1, let machine = matches.first,
                  (machine.attachment[importedAliasKey] ?? host.alias) == host.alias,
                  machine.remoteAddress.caseInsensitiveCompare(host.hostname) == .orderedSame,
                  Int(machine.remotePort) == host.port,
                  let identity = store.associatedIdentity(for: machine), identity.username == host.username
            else {
                states[host.alias] = .conflict
                continue
            }
            existing[host.alias] = machine
            states[host.alias] = .saved
            if let file = host.identityFile {
                let imported = machine.attachment[importedAliasKey] == host.alias
                let usernameOnly = !identity.useSSHAgent && !identity.usesLocalKeyFile &&
                    identity.password.isEmpty && identity.privateKey.isEmpty && identity.publicKey.isEmpty
                if usernameOnly {
                    states[host.alias] = .update
                } else if imported, identity.usesLocalKeyFile {
                    // A sync or backup carries the login method, while each Mac
                    // binds its own path. Preserve any different path chosen here.
                    if let bound = LocalSSHKeyFile.url(for: identity.id) {
                        if bound.standardizedFileURL != file.standardizedFileURL { states[host.alias] = .conflict }
                    } else {
                        states[host.alias] = .update
                    }
                } else if imported, identity.useSSHAgent {
                    // The first version of setup used the agent for all logins.
                    states[host.alias] = .update
                }
            }
            if host.jumpAlias == nil, machine.transport != .direct { states[host.alias] = .conflict }
        }

        // A native jump must terminate on a direct server. Require the actual
        // referenced UUID too when a target already exists; names can be edited.
        for host in hosts {
            guard let jump = host.jumpAlias else { continue }
            guard let hop = byAlias[jump], hop.jumpAlias == nil, states[jump] != .conflict else {
                states[host.alias] = .conflict
                continue
            }
            if let target = existing[host.alias] {
                guard let savedHop = existing[jump], target.transport == .proxyJump,
                      target.proxyJumpMachineID.flatMap(UUID.init(uuidString:)) == savedHop.id
                else {
                    states[host.alias] = .conflict
                    continue
                }
            }
        }
    }

    func changes(selected: Set<String>) throws -> [OpenSSHConfigHost] {
        for alias in selected {
            guard let state = states[alias], state != .conflict else { throw OpenSSHImportError.changed }
        }
        let changes = hosts.filter { selected.contains($0.alias) && states[$0.alias] != .saved }
        for host in changes {
            if let jump = host.jumpAlias, states[jump] != .saved, !selected.contains(jump) {
                throw OpenSSHImportError.dependency(jump, host.alias)
            }
        }
        return changes
    }
}

public extension CatusshStore {
    @MainActor
    func openSSHImportStates(for hosts: [OpenSSHConfigHost]) -> [String: OpenSSHImportState] {
        OpenSSHImportPlan(hosts, store: self).states
    }

    /// Validates against the current store, including unselected dependencies,
    /// before publishing either group or writing any device-local key references.
    @MainActor
    @discardableResult
    func applyOpenSSHImport(selectedAliases: Set<String>, from hosts: [OpenSSHConfigHost]) throws -> OpenSSHImportResult {
        let plan = OpenSSHImportPlan(hosts, store: self)
        let changes = try plan.changes(selected: selectedAliases)
        var result = OpenSSHImportResult()
        guard !changes.isEmpty else { return result }
        guard Self.savesChanges else { throw OpenSSHImportError.locked }

        var machineIDs = plan.existing.mapValues(\.id)
        for host in changes where plan.states[host.alias] == .new { machineIDs[host.alias] = UUID() }

        var logins = [ImportedLogin: UUID]()
        for identity in identityGroup.identities {
            if let login = ImportedLogin(identity) { logins[login] = identity.id }
        }
        var newIdentities = [RDIdentity]()
        var localKeys = [UUID: URL]()
        var machines = machineGroup.machines
        let positions = Dictionary(machines.indices.map { (machines[$0].id, $0) }, uniquingKeysWith: { first, _ in first })

        for host in changes {
            let login = ImportedLogin(host)
            let identityID: UUID
            if let machine = plan.existing[host.alias], let previous = associatedIdentity(for: machine),
               previous.usesLocalKeyFile, let file = login.keyFile, LocalSSHKeyFile.url(for: previous.id) == nil,
               localKeys[previous.id] == nil || localKeys[previous.id] == file
            {
                // A synced identity has the same UUID on every device. Binding
                // its missing local path must preserve that UUID on other Macs.
                identityID = previous.id
                localKeys[identityID] = file
                logins[login] = identityID
            } else if let existing = logins[login] {
                identityID = existing
            } else {
                var identity = RDIdentity(username: login.username, group: "SSH Config", authenticAutomatically: false)
                if let file = login.keyFile {
                    identity.usesLocalKeyFile = true
                    localKeys[identity.id] = file
                } else {
                    identity.useSSHAgent = true
                }
                identityID = identity.id
                logins[login] = identityID
                newIdentities.append(identity)
            }
            guard let id = machineIDs[host.alias] else { throw OpenSSHImportError.changed }
            if let position = positions[id] {
                machines[position].associatedIdentity = identityID.uuidString
                result.updated += 1
            } else {
                var machine = RDMachine(
                    id: id, remoteAddress: host.hostname, remotePort: String(host.port),
                    name: host.alias, group: "SSH Config", lastConnection: Date(timeIntervalSince1970: 0),
                    associatedIdentity: identityID.uuidString, attachment: [importedAliasKey: host.alias]
                )
                if let jump = host.jumpAlias {
                    guard let jumpID = machineIDs[jump] else { throw OpenSSHImportError.changed }
                    machine.transport = .proxyJump
                    machine.proxyJumpMachineID = jumpID.uuidString
                }
                machines.append(machine)
                result.added += 1
            }
        }

        for (id, file) in localKeys { LocalSSHKeyFile.setURL(file, for: id) }
        if !newIdentities.isEmpty { identityGroup.items.append(contentsOf: newIdentities) }
        if machines != machineGroup.machines { machineGroup.items = machines }
        flushPendingWrites()
        return result
    }

    // Compatibility with callers that only want to add previously unseen hosts.
    @MainActor
    func savedOpenSSHHostAliases(in hosts: [OpenSSHConfigHost]) -> Set<String> {
        let occupied = Set(machineGroup.machines.flatMap { [$0.name, $0.attachment[importedAliasKey]].compactMap { $0 } })
        return occupied.intersection(hosts.map(\.alias))
    }

    @MainActor
    @discardableResult
    func importOpenSSHHosts(_ hosts: [OpenSSHConfigHost]) -> Int {
        let new = openSSHImportStates(for: hosts).compactMap { $0.value == .new ? $0.key : nil }
        return (try? applyOpenSSHImport(selectedAliases: Set(new), from: hosts).added) ?? 0
    }
}

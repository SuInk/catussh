import Foundation

private let importedAliasKey = "openssh.alias"

public extension CatusshStore {
    /// Uses the original alias as well as the display name so renaming an
    /// imported server doesn't bring back a duplicate on the next import.
    @MainActor
    private var occupiedOpenSSHAliases: Set<String> {
        var aliases = Set<String>()
        for machine in machineGroup.machines {
            aliases.insert(machine.name)
            if let importedAlias = machine.attachment[importedAliasKey] {
                aliases.insert(importedAlias)
            }
        }
        return aliases
    }

    @MainActor
    func savedOpenSSHHostAliases(in hosts: [OpenSSHConfigHost]) -> Set<String> {
        let occupied = occupiedOpenSSHAliases
        return occupied.intersection(hosts.map(\.alias))
    }

    /// Adds the selected bookmarks without opening a connection or copying
    /// credential files. An explicit identity keeps the login scoped to the
    /// configured user even if Quick Connect has other automatic identities.
    @MainActor
    @discardableResult
    func importOpenSSHHosts(_ hosts: [OpenSSHConfigHost]) -> Int {
        var occupied = occupiedOpenSSHAliases
        var agents = [String: UUID]()
        for identity in identityGroup.identities where identity.useSSHAgent {
            agents[identity.username] = identity.id
        }

        var newIdentities = [RDIdentity]()
        var newMachines = [RDMachine]()
        for host in hosts {
            guard occupied.insert(host.alias).inserted else { continue }
            let identityID: UUID
            if let existing = agents[host.username] {
                identityID = existing
            } else {
                var identity = RDIdentity(username: host.username, group: "SSH Config", authenticAutomatically: false)
                identity.useSSHAgent = true
                newIdentities.append(identity)
                agents[host.username] = identity.id
                identityID = identity.id
            }
            newMachines.append(RDMachine(
                remoteAddress: host.hostname,
                remotePort: String(host.port),
                name: host.alias,
                group: "SSH Config",
                lastConnection: Date(timeIntervalSince1970: 0),
                associatedIdentity: identityID.uuidString,
                attachment: [importedAliasKey: host.alias]
            ))
        }

        guard !newMachines.isEmpty else { return 0 }
        if !newIdentities.isEmpty { identityGroup.items.append(contentsOf: newIdentities) }
        machineGroup.items.append(contentsOf: newMachines)
        flushPendingWrites()
        return newMachines.count
    }
}

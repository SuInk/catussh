@testable import CatusshModule
import XCTest

@MainActor
final class OpenSSHHostImportTests: XCTestCase {
    private var store: CatusshStore { .shared }
    private var savedMachines = RDMachineGroup()
    private var savedIdentities = RDIdentityGroup()

    override func setUp() async throws {
        savedMachines = store.machineGroup
        savedIdentities = store.identityGroup
        store.machineGroup = RDMachineGroup()
        store.identityGroup = RDIdentityGroup()
    }

    override func tearDown() async throws {
        store.identityGroup = savedIdentities
        store.machineGroup = savedMachines
        store.flushPendingWrites()
    }

    private func host(_ alias: String, user: String = "deploy") -> OpenSSHConfigHost {
        OpenSSHConfigHost(alias: alias, hostname: "build.example", username: user, port: 2222)
    }

    func testImportBindsConfiguredAccountsWithoutUsingStoredPasswords() throws {
        let passwordIdentity = RDIdentity(username: "deploy", password: "fixture")
        store.identityGroup.insert(passwordIdentity)
        let hosts = [host("build"), host("build-copy"), host("Build", user: "operator")]

        XCTAssertEqual(store.importOpenSSHHosts(hosts), 3)
        let machines = store.machineGroup.machines
        XCTAssertEqual(machines.map(\.name), hosts.map(\.alias))
        XCTAssertEqual(machines.map(\.remoteAddress), hosts.map(\.hostname))
        XCTAssertEqual(machines.map(\.remotePort), ["2222", "2222", "2222"])
        XCTAssertEqual(machines.map { store.workerAssociatedIdentity(for: $0)?.username }, hosts.map(\.username))
        let deploy = try XCTUnwrap(store.associatedIdentity(for: machines[0]))
        XCTAssertTrue(deploy.useSSHAgent)
        XCTAssertFalse(deploy.authenticAutomatically)
        XCTAssertTrue(deploy.password.isEmpty)
        XCTAssertNotEqual(deploy.id, passwordIdentity.id)
        XCTAssertEqual(machines[0].associatedIdentity, machines[1].associatedIdentity)
        XCTAssertNotEqual(machines[0].associatedIdentity, machines[2].associatedIdentity)
        XCTAssertEqual(store.identityGroup.count, 3)
        XCTAssertEqual(store.identityGroup[passwordIdentity.id], passwordIdentity)
    }

    func testExistingAgentIsReusedAndRepeatImportPreservesEdits() throws {
        var agent = RDIdentity(username: "deploy", group: "Operations")
        agent.useSSHAgent = true
        store.identityGroup.insert(agent)
        let original = host("build")
        XCTAssertEqual(store.importOpenSSHHosts([original, original]), 1)
        var machine = try XCTUnwrap(store.machineGroup.machines.first)
        XCTAssertEqual(machine.associatedIdentity, agent.id.uuidString)
        machine.name = "My build machine"
        machine.remotePort = "2223"
        store.machineGroup.insert(machine)

        XCTAssertEqual(store.savedOpenSSHHostAliases(in: [original]), ["build"])
        XCTAssertEqual(store.importOpenSSHHosts([original]), 0)
        XCTAssertEqual(store.machineGroup.machines, [machine])
        XCTAssertEqual(store.identityGroup.identities, [agent])
    }

    func testManualServerAddedAfterPreviewWinsWithoutCreatingAnOrphanIdentity() {
        let selected = host("build")
        XCTAssertTrue(store.savedOpenSSHHostAliases(in: [selected]).isEmpty)
        let manual = RDMachine(remoteAddress: "other.example", remotePort: "22", name: "build")
        store.machineGroup.insert(manual)

        XCTAssertEqual(store.savedOpenSSHHostAliases(in: [selected]), ["build"])
        XCTAssertEqual(store.importOpenSSHHosts([selected]), 0)
        XCTAssertEqual(store.machineGroup.machines, [manual])
        XCTAssertTrue(store.identityGroup.identities.isEmpty)
    }
}

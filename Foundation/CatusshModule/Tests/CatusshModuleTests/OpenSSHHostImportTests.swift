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
        for identity in store.identityGroup.identities where identity.usesLocalKeyFile {
            LocalSSHKeyFile.setURL(nil, for: identity.id)
        }
        store.identityGroup = savedIdentities
        store.machineGroup = savedMachines
        store.flushPendingWrites()
    }

    private func host(_ alias: String, user: String = "deploy", jump: String? = nil, key: URL? = nil) -> OpenSSHConfigHost {
        OpenSSHConfigHost(alias: alias, hostname: "build.example", username: user, port: 2222, jumpAlias: jump, identityFile: key)
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

    func testJumpsAreBoundByIDRegardlessOfConfigOrder() throws {
        let hosts = [host("internal", user: "app", jump: "gateway"), host("gateway")]
        let result = try store.applyOpenSSHImport(selectedAliases: ["internal", "gateway"], from: hosts)
        XCTAssertEqual(result.added, 2)
        let target = try XCTUnwrap(store.machineGroup.machines.first)
        let gateway = try XCTUnwrap(store.machineGroup.machines.last)
        XCTAssertEqual(target.transport, .proxyJump)
        XCTAssertEqual(target.proxyJumpMachineID, gateway.id.uuidString)
        XCTAssertEqual(gateway.transport, .direct)
        XCTAssertNil(gateway.proxyJumpMachineID)
        XCTAssertEqual(store.openSSHImportStates(for: hosts), ["internal": .saved, "gateway": .saved])
        XCTAssertEqual(try store.applyOpenSSHImport(selectedAliases: ["internal"], from: hosts).added, 0)
    }

    func testMissingConflictingOrUnselectedDependencyMakesNoChanges() throws {
        let target = host("inside", jump: "gateway")
        let valid = [host("unrelated"), target, host("gateway")]
        XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["unrelated", "inside"], from: valid))
        XCTAssertEqual(store.openSSHImportStates(for: [target]), ["inside": .conflict])
        XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["inside"], from: [target]))
        XCTAssertEqual(store.machineGroup.count, 0)
        XCTAssertEqual(store.identityGroup.count, 0)

        let admin = RDIdentity(username: "other-user", password: "fixture")
        store.identityGroup.insert(admin)
        let manual = RDMachine(remoteAddress: "build.example", remotePort: "2222", name: "gateway", associatedIdentity: admin.id.uuidString)
        store.machineGroup.insert(manual)
        XCTAssertEqual(store.openSSHImportStates(for: valid)["inside"], .conflict)
        XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["unrelated", "inside", "gateway"], from: valid))
        XCTAssertEqual(store.machineGroup.machines, [manual])
        XCTAssertEqual(store.identityGroup.identities, [admin])
    }

    func testMatchingManualGatewayIsReusedWithoutChangingItsLogin() throws {
        let deploy = RDIdentity(username: "deploy", password: "fixture")
        store.identityGroup.insert(deploy)
        let manual = RDMachine(remoteAddress: "build.example", remotePort: "2222", name: "gateway", associatedIdentity: deploy.id.uuidString)
        store.machineGroup.insert(manual)
        let hosts = [host("gateway"), host("target", user: "other", jump: "gateway")]
        let result = try store.applyOpenSSHImport(selectedAliases: ["target"], from: hosts)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(store.machineGroup.machines.first, manual)
        XCTAssertEqual(store.machineGroup.machines.last?.proxyJumpMachineID, manual.id.uuidString)
        XCTAssertEqual(store.identityGroup[deploy.id], deploy)
    }

    func testRejectsJumpChainsAndStaleSavedRoutes() throws {
        let hosts = [host("a", jump: "b"), host("b", jump: "c"), host("c")]
        XCTAssertEqual(store.openSSHImportStates(for: hosts)["a"], .conflict)
        XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["a", "b", "c"], from: hosts))
        XCTAssertTrue(store.machineGroup.items.isEmpty)
        let supported = [host("a", jump: "b"), host("b")]
        _ = try store.applyOpenSSHImport(selectedAliases: ["a", "b"], from: supported)
        var target = try XCTUnwrap(store.machineGroup.machines.first)
        target.proxyJumpMachineID = UUID().uuidString
        store.machineGroup.insert(target)
        XCTAssertEqual(store.openSSHImportStates(for: supported)["a"], .conflict)
        XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["a"], from: supported))
        XCTAssertEqual(store.machineGroup.machines.first, target)
    }

    #if os(macOS)
        func testManualUsernameOnlyBookmarkCanExplicitlyBindAKeyWithoutChangingItsOldIdentity() throws {
            let blank = RDIdentity(username: "deploy", authenticAutomatically: false)
            let configured = RDIdentity(username: "deploy", password: "fixture")
            store.identityGroup.insert(blank)
            store.identityGroup.insert(configured)
            var original = RDMachine(remoteAddress: "build.example", remotePort: "2222", name: "manual",
                                     group: "Personal", comment: "Keep this", associatedIdentity: blank.id.uuidString)
            let other = RDMachine(remoteAddress: "build.example", remotePort: "2222", name: "password",
                                  associatedIdentity: configured.id.uuidString)
            store.machineGroup.insert(original)
            store.machineGroup.insert(other)
            let key = URL(fileURLWithPath: "/tmp/import-test-manual")
            let hosts = [host("manual", key: key), host("password", key: key)]
            XCTAssertEqual(store.openSSHImportStates(for: hosts), ["manual": .update, "password": .saved])
            XCTAssertEqual(try store.applyOpenSSHImport(selectedAliases: [], from: hosts).updated, 0)
            XCTAssertEqual(store.machineGroup.items, [original, other])
            let result = try store.applyOpenSSHImport(selectedAliases: ["manual", "password"], from: hosts)
            XCTAssertEqual(result.updated, 1)
            XCTAssertEqual(result.added, 0)
            let updated = store.machineGroup[original.id]
            let login = try XCTUnwrap(store.associatedIdentity(for: updated))
            XCTAssertEqual(LocalSSHKeyFile.url(for: login.id), key.standardizedFileURL)
            original.associatedIdentity = login.id.uuidString
            XCTAssertEqual(store.machineGroup.items, [original, other])
            XCTAssertEqual(store.identityGroup[blank.id], blank)
            XCTAssertEqual(store.identityGroup[configured.id], configured)
            XCTAssertEqual(store.openSSHImportStates(for: hosts), ["manual": .saved, "password": .saved])
        }

        func testLocalKeyLoginsAreScopedByBothPathAndUser() throws {
            let first = URL(fileURLWithPath: "/tmp/import-test-key")
            let other = URL(fileURLWithPath: "/tmp/import-test-other-key")
            let hosts = [host("a", key: first), host("b", key: first), host("c", key: other),
                         host("d", user: "root", key: first), host("agent")]
            let result = try store.applyOpenSSHImport(selectedAliases: Set(hosts.map(\.alias)), from: hosts)
            XCTAssertEqual(result.added, 5)
            let ids = try store.machineGroup.machines.map { try XCTUnwrap(store.associatedIdentity(for: $0)) }
            XCTAssertEqual(ids[0].id, ids[1].id)
            XCTAssertEqual(Set(ids.map(\.id)).count, 4)
            XCTAssertEqual(LocalSSHKeyFile.url(for: ids[0].id), first.standardizedFileURL)
            XCTAssertEqual(LocalSSHKeyFile.url(for: ids[2].id), other.standardizedFileURL)
            XCTAssertTrue(ids[4].useSSHAgent)
            XCTAssertTrue(ids.allSatisfy { $0.privateKey.isEmpty && $0.password.isEmpty })
            let encoded = try String(decoding: JSONEncoder().encode(store.identityGroup), as: UTF8.self)
            XCTAssertFalse(encoded.contains("import-test-key"))
        }

        func testExplicitUpdateUpgradesLegacyLoginWhilePreservingServerAndSharedAgent() throws {
            let original = [host("gateway"), host("other")]
            XCTAssertEqual(store.importOpenSSHHosts(original), 2)
            var gateway = try XCTUnwrap(store.machineGroup.machines.first)
            let agent = try XCTUnwrap(store.associatedIdentity(for: gateway))
            gateway.name = "Renamed gateway"
            gateway.comment = "User-edited note"
            store.machineGroup.insert(gateway)

            let newKey = URL(fileURLWithPath: "/tmp/import-test-upgrade")
            let hosts = [host("target", jump: "gateway"), host("gateway", key: newKey)]
            XCTAssertEqual(store.openSSHImportStates(for: hosts), ["gateway": .update, "target": .new])
            XCTAssertThrowsError(try store.applyOpenSSHImport(selectedAliases: ["target"], from: hosts))
            XCTAssertEqual(store.identityGroup.count, 1)
            let result = try store.applyOpenSSHImport(selectedAliases: ["target", "gateway"], from: hosts)
            XCTAssertEqual(result.added, 1)
            XCTAssertEqual(result.updated, 1)
            let updated = store.machineGroup[gateway.id]
            let login = try XCTUnwrap(store.associatedIdentity(for: updated))
            XCTAssertTrue(login.usesLocalKeyFile)
            XCTAssertEqual(LocalSSHKeyFile.url(for: login.id), newKey.standardizedFileURL)
            gateway.associatedIdentity = login.id.uuidString
            XCTAssertEqual(updated, gateway)
            XCTAssertEqual(store.machineGroup.machines[1].associatedIdentity, agent.id.uuidString)
            XCTAssertEqual(store.identityGroup[agent.id], agent)
            XCTAssertEqual(store.machineGroup.machines[2].proxyJumpMachineID, gateway.id.uuidString)
            XCTAssertEqual(store.openSSHImportStates(for: hosts), ["gateway": .saved, "target": .saved])
            XCTAssertEqual(try store.applyOpenSSHImport(selectedAliases: ["gateway"], from: hosts).updated, 0)
        }

        func testRestoringDeviceLocalPathPreservesSyncedIdentity() throws {
            let key = URL(fileURLWithPath: "/tmp/import-test-device-key")
            let host = host("device", key: key)
            _ = try store.applyOpenSSHImport(selectedAliases: ["device"], from: [host])
            let machine = try XCTUnwrap(store.machineGroup.machines.first)
            let identity = try XCTUnwrap(store.associatedIdentity(for: machine))
            LocalSSHKeyFile.setURL(nil, for: identity.id)
            XCTAssertEqual(store.openSSHImportStates(for: [host]), ["device": .update])
            XCTAssertEqual(try store.applyOpenSSHImport(selectedAliases: ["device"], from: [host]).updated, 1)
            XCTAssertEqual(store.identityGroup.identities, [identity])
            XCTAssertEqual(store.machineGroup.machines, [machine])
            XCTAssertEqual(LocalSSHKeyFile.url(for: identity.id), key.standardizedFileURL)
        }
    #endif
}

import CatusshDesign
import CatusshModule
import SwiftUI

/// Preview the route and login that each saved server will use.
struct SSHSetupSheet: View {
    @EnvironmentObject private var store: CatusshStore
    @Environment(\.dismiss) private var dismiss

    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    @State private var scanID = UUID()
    @State private var phase = Phase.reading
    @State private var selected = Set<String>()
    @State private var importFailure: String?
    @State private var agentStatus: SSHSetupAgentStatus?
    @State private var agentCheckID = UUID()

    private enum Phase {
        case reading
        case review(OpenSSHConfigPreview)
        case missing
        case failed(String)
        case finished(OpenSSHImportResult)
    }

    var body: some View {
        SheetScaffold(String(localized: "Import SSH servers")) {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                switch phase {
                case .reading:
                    ProgressView("Looking for SSH hosts…")
                case let .review(preview):
                    review(preview)
                    if preview.hosts.contains(where: { selected.contains($0.alias) && $0.identityFile == nil }) { loginHelp }
                    if let importFailure { Text(importFailure).foregroundStyle(.rxWarning) }
                case .missing:
                    Text("This folder has no config file. Choose the folder that contains your OpenSSH config, or add a server manually from Home.")
                case let .failed(message):
                    Text("Couldn’t read the SSH configuration.")
                        .font(.rxBodyStrong)
                    Text(message).textSelection(.enabled)
                    Text("Choose another folder or add a server manually from Home.")
                case let .finished(result):
                    Label("Added \(result.added), updated \(result.updated)", systemImage: "checkmark.circle.fill")
                        .font(.rxBodyStrong)
                    Text("Open a server’s Terminal to connect. You can change its login in Identities.")
                }
            }
            .font(.rxBody)
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if case .finished = phase {
                Spacer()
                Button("Show Servers") {
                    AppRouter.shared.route = .servers
                    dismiss()
                }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Choose Folder…", action: chooseDirectory)
                    .buttonStyle(.rx)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.rx)
                    .keyboardShortcut(.cancelAction)
                if case let .review(preview) = phase {
                    Button("Import Selected") {
                        do {
                            phase = .finished(try store.applyOpenSSHImport(selectedAliases: selected, from: preview.hosts))
                        } catch {
                            importFailure = error.localizedDescription
                        }
                    }
                    .buttonStyle(.rxPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || !CatusshStore.savesChanges)
                }
            }
        }
        .frame(width: 560)
        .task(id: scanID) { await scan(directory) }
        .task(id: agentCheckID) {
            let status = await SSHSetupAgentStatus.check()
            if !Task.isCancelled { agentStatus = status }
        }
    }

    @ViewBuilder private var loginHelp: some View {
        if let agentStatus, agentStatus != .available {
            VStack(alignment: .leading, spacing: RX.Space.s1) {
                Label {
                    Text(agentStatus == .empty
                        ? String(localized: "Your SSH agent has no keys loaded.")
                        : String(localized: "catussh could not reach your SSH agent."))
                } icon: {
                    Image(systemName: "key")
                }
                .font(.rxBodyStrong)
                if agentStatus == .empty {
                    Text("If you use the default Ed25519 key, run this in Terminal. For another key, substitute its path.")
                    Text(verbatim: "ssh-add ~/.ssh/id_ed25519")
                        .font(.rxCode)
                        .textSelection(.enabled)
                } else {
                    Text("You can still save these hosts. Before connecting, choose a password or key file for the login in Identities.")
                }
                Button("Check Again") { agentCheckID = UUID() }.rxLinkButton()
            }
            .font(.rxHelp)
        }
    }

    @ViewBuilder private func review(_ preview: OpenSSHConfigPreview) -> some View {
        let states = store.openSSHImportStates(for: preview.hosts)
        let available = Set(preview.hosts.map(\.alias).filter { states[$0] == .new || states[$0] == .update })
        let hideNames = store.machineRedacted == .all
        let hideAddresses = store.machineRedacted != .none
        Text("Review the login and route for each host. Key files stay on this Mac and are opened when you connect.")
        RedactableText(directory.appendingPathComponent("config").path, redacted: hideAddresses)
            .font(.rxCode)
            .foregroundStyle(.rxInkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
        if preview.hosts.isEmpty && preview.skipped.isEmpty {
            Text("No named hosts found. Look for a Host entry with a name such as dev in your config.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RX.Space.s2) {
                    ForEach(preview.hosts) { host in
                        let status = states[host.alias]
                        let needsJumpUpdate = host.jumpAlias.map { states[$0] == .update && !selected.contains($0) } ?? false
                        Toggle(isOn: Binding(
                            get: { available.contains(host.alias) && selected.contains(host.alias) },
                            set: { include in
                                importFailure = nil
                                if include {
                                    selected.insert(host.alias)
                                    if let jump = host.jumpAlias, states[jump] == .new { selected.insert(jump) }
                                } else {
                                    selected.remove(host.alias)
                                    for dependent in preview.hosts where dependent.jumpAlias == host.alias {
                                        selected.remove(dependent.alias)
                                    }
                                }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    RedactableText(host.alias, redacted: hideNames).font(.rxBodyStrong)
                                    RedactableText("\(host.username)@\(host.hostname) · \(host.port)", redacted: hideAddresses)
                                        .font(.rxCode)
                                        .foregroundStyle(.rxInkSecondary)
                                    HStack(spacing: RX.Space.s2) {
                                        Image(systemName: "key")
                                        if status == .saved {
                                            Text("Keep saved login")
                                        } else if let key = host.identityFile {
                                            RedactableText((key.path as NSString).abbreviatingWithTildeInPath, redacted: hideAddresses)
                                        } else {
                                            Text("SSH Agent")
                                        }
                                        if let jump = host.jumpAlias {
                                            Image(systemName: "arrow.turn.up.right")
                                            RedactableText(String(localized: "via \(jump)"), redacted: hideNames)
                                        }
                                    }
                                    .font(.rxCaption)
                                    if needsJumpUpdate { Text("Select the jump host update first.").font(.rxCaption) }
                                }
                                Spacer()
                                switch status {
                                case .saved: Text("Already saved").font(.rxCaption)
                                case .update: Text("Update login").font(.rxCaption)
                                case .conflict: Text("Existing settings differ").font(.rxCaption)
                                default: EmptyView()
                                }
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        .rxCheckboxToggle()
                        .disabled(!available.contains(host.alias) || needsJumpUpdate)
                    }
                    if !preview.skipped.isEmpty {
                        Text("Requires manual setup").font(.rxBodyStrong)
                        ForEach(preview.skipped) { skipped in
                            VStack(alignment: .leading, spacing: 2) {
                                RedactableText(skipped.alias, redacted: hideNames)
                                Text(skipped.reason).font(.rxHelp).foregroundStyle(.rxInkSecondary)
                            }
                        }
                    }
                }
                .padding(RX.Space.s3)
            }
            .frame(height: 210)
            .rxCard(padding: 0)
            if !available.isEmpty {
                HStack {
                    Text("\(selected.intersection(available).count) selected")
                    Spacer()
                    Button(selected.isSuperset(of: available) ? String(localized: "Deselect All") : String(localized: "Select All")) {
                        importFailure = nil
                        selected = selected.isSuperset(of: available) ? [] : available
                    }
                    .rxLinkButton()
                }
                .font(.rxHelp)
            }
        }
        if !CatusshStore.savesChanges {
            Text("Unlock your keychain and reopen catussh to save imported servers.")
                .foregroundStyle(.rxWarning)
        }
    }

    private func chooseDirectory() {
        UIBridge.openPanel(
            message: String(localized: "Choose the folder containing your OpenSSH config file."),
            prompt: String(localized: "Preview Hosts"),
            directory: directory.deletingLastPathComponent(),
            canChooseFiles: false, canChooseDirectories: true, allowsMultipleSelection: false,
            canCreateDirectories: false, showsHiddenFiles: true
        ) { urls in
            guard let folder = urls.first else { return }
            directory = folder
            phase = .reading
            importFailure = nil
            scanID = UUID()
        }
    }

    @MainActor private func scan(_ folder: URL) async {
        do {
            let preview = try await Task.detached(priority: .userInitiated) {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                return try OpenSSHConfigReader.read(directory: folder)
            }.value
            guard !Task.isCancelled else { return }
            let states = store.openSSHImportStates(for: preview.hosts)
            selected = Set(preview.hosts.compactMap { host in
                guard states[host.alias] == .new else { return nil }
                if let jump = host.jumpAlias, states[jump] == .update { return nil }
                return host.alias
            })
            phase = .review(preview)
        } catch {
            guard !Task.isCancelled else { return }
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            phase = missing ? .missing : .failed(error.localizedDescription)
        }
    }
}

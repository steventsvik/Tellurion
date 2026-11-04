#if os(macOS)
import AppKit
import SwiftUI

/// More than one sign-in for Claude Code or Codex. A profile is a folder of its own that the
/// agent uses for its settings and sign-in (CLAUDE_CONFIG_DIR, CODEX_HOME); "Your sign-in" is
/// the usual one. New agent tiles start with the active profile, and each tile shows whose
/// it is. Tellurion only points the agents at these folders: it never reads or copies sign-in
/// details.
struct BoardAccount: Codable, Identifiable, Equatable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case claude, codex

        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var kind: VerticalTabAgentKind { self == .claude ? .claude : .codex }
        /// The variable that points the agent at a profile's folder.
        var variable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        /// What starts its sign-in in a new tile.
        var login: String { self == .claude ? "claude" : "codex login" }
    }

    var id = UUID()
    var provider: Provider
    var name: String
    /// A Codex "account" that's really a model on Venice: Codex keeps its usual folder and sign-in,
    /// and its model requests go to Venice. Nil for every other account.
    var veniceModel: String?
    var venicePrivate: Bool?

    var isVenice: Bool { veniceModel != nil }

    var folder: URL {
        AgentTools.root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    /// Whether the agent has set the profile up yet: only that its file is there is checked,
    /// nothing in it is read.
    var used: Bool {
        if isVenice { return true }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(provider == .codex ? "auth.json" : ".claude.json").path)
    }
}

final class BoardAccounts: ObservableObject {
    static let shared = BoardAccounts()

    @Published private(set) var accounts: [BoardAccount] = []
    /// Per provider: the profile new tiles use (nil: your usual sign-in).
    @Published private(set) var active: [BoardAccount.Provider: UUID] = [:]
    /// Venice accounts that were removed, kept so tiles still naming one don't start their agent
    /// on another provider.
    private var removedVenice: Set<UUID> = []

    private var file: URL { AgentTools.root.appendingPathComponent("accounts.json") }

    private struct Saved: Codable {
        var accounts: [BoardAccount]
        var active: [String: UUID]
        var removedVenice: [UUID]?
    }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        accounts = saved.accounts
        removedVenice = Set(saved.removedVenice ?? [])
        active = Dictionary(uniqueKeysWithValues: saved.active.compactMap { key, value in
            BoardAccount.Provider(rawValue: key).map { ($0, value) }
        })
    }

    private static let log = StoredFile.logger("Accounts")

    private func save() {
        let saved = Saved(accounts: accounts, active: Dictionary(uniqueKeysWithValues: active.map { ($0.key.rawValue, $0.value) }),
                          removedVenice: Array(removedVenice))
        StoredFile.write(json: saved, to: file, what: "the account profiles", log: Self.log)
    }

    func wasRemovedVenice(_ id: UUID?) -> Bool { id.map(removedVenice.contains) ?? false }

    func account(_ id: UUID?) -> BoardAccount? { id.flatMap { id in accounts.first { $0.id == id } } }

    /// A new, empty profile (its folder made, owner-only).
    @discardableResult
    func add(_ provider: BoardAccount.Provider, name: String) -> BoardAccount {
        let account = BoardAccount(provider: provider, name: name.isEmpty ? "\(provider.title) \(accounts.count + 2)" : name)
        do {
            try FileManager.default.createDirectory(at: account.folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            Self.log.error("Couldn't make a profile's folder: \(error.localizedDescription, privacy: .public)")
        }
        accounts.append(account)
        save()
        return account
    }

    /// The account for a Venice model, made the first time. Its folder isn't used: Codex stays in
    /// its usual one, with its hooks, skills, MCP servers and sessions.
    func veniceAccount(model: String, name: String, isPrivate: Bool) -> BoardAccount {
        if let existing = accounts.first(where: { $0.veniceModel == model }) { return existing }
        let account = BoardAccount(provider: .codex, name: "Venice · " + name, veniceModel: model, venicePrivate: isPrivate)
        accounts.append(account)
        save()
        return account
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        accounts[index].name = name
        save()
    }

    /// Forgets a profile and deletes its folder (its sign-in with it).
    func remove(_ id: UUID) {
        guard let account = account(id) else { return }
        if account.isVenice {
            removedVenice.insert(id)
        } else {
            StoredFile.remove(account.folder, what: "a profile's folder", log: Self.log)
        }
        accounts.removeAll { $0.id == id }
        if active[account.provider] == id { active[account.provider] = nil }
        save()
    }

    /// The profile new tiles use; nil goes back to your usual sign-in.
    func use(_ id: UUID?, for provider: BoardAccount.Provider) {
        active[provider] = id
        save()
    }

    /// The variables for a tile using these profiles (by provider).
    func environment(_ chosen: [BoardAccount.Provider: UUID]) -> [String: String] {
        var environment: [String: String] = [:]
        for (provider, id) in chosen {
            guard let account = account(id), account.provider == provider else { continue }
            if let model = account.veniceModel {
                environment.merge(VeniceCodex.environment(model: model)) { _, new in new }
            } else {
                environment[provider.variable] = account.folder.path
            }
        }
        return environment
    }
}

extension BoardController {
    /// Points a new tile's agents at the active profiles, and remembers which they were.
    func applyAccounts(_ config: inout Ghostty.SurfaceConfiguration, chosen: [BoardAccount.Provider: UUID]? = nil) -> [BoardAccount.Provider: UUID] {
        guard TellurionSettings.isOn(.accounts) else { return [:] }
        let chosen = chosen ?? BoardAccounts.shared.active
        config.environmentVariables.merge(BoardAccounts.shared.environment(chosen)) { $1 }
        return chosen
    }

    /// The profile a tile's running agent signed in with, if not your usual one.
    func account(of surface: Ghostty.SurfaceView) -> BoardAccount? {
        guard TellurionSettings.isOn(.accounts), let kind = VerticalTabsAgents.shared.info(for: surface)?.kind,
              let provider = BoardAccount.Provider.allCases.first(where: { $0.kind == kind }) else { return nil }
        return BoardAccounts.shared.account(model.tileAccounts[surface.id]?[provider])
    }

    /// A tile running a profile's sign-in, so you can sign it in there.
    func connect(_ account: BoardAccount) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workspace.folder
        var chosen = BoardAccounts.shared.active
        chosen[account.provider] = account.id
        if account.isVenice {
            // With the Accounts switch off as well: this tile was asked for by name, and it has to
            // come back on Venice.
            guard prepareVenice(account), let folder = VeniceCodex.projectFolder(workspace.folder) else { return }
            setFolder(folder)
            config.workingDirectory = folder
            config.environmentVariables.merge(BoardAccounts.shared.environment(chosen)) { $1 }
            guard let tile = addTile(config: config, command: "codex\n") else { return }
            model.tileAccounts[tile.id] = chosen
            return
        }
        let applied = applyAccounts(&config, chosen: chosen)
        guard let tile = addTile(config: config, command: account.provider.login + "\n") else { return }
        model.tileAccounts[tile.id] = applied
        setTitle("Sign in: \(account.name)", for: tile)
    }

    /// What using a Venice model takes: its notices, and the proxy running. False if it can't
    /// go ahead, with the problem shown in the Local Models window.
    @MainActor
    func prepareVenice(_ account: BoardAccount) -> Bool {
        VeniceAccount.shared.prepareUseOrShowProblem(modelName: account.name, isPrivate: account.venicePrivate ?? false)
    }

    /// Removing a profile deletes its sign-in, so it asks first, and says which tiles use it.
    func confirmRemove(_ account: BoardAccount) {
        let using = model.surfaces.filter { model.tileAccounts[$0.id]?[account.provider] == account.id }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = Self.removalNote(for: account, tilesUsingIt: using.count)
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        BoardAccounts.shared.remove(account.id)
        // A tile on Venice keeps naming it, so it won't come back on another provider.
        if !account.isVenice { for surface in using { model.tileAccounts[surface.id]?[account.provider] = nil } }
        scheduleSave()
    }

    /// What removing a profile means for its sign-in and for the tiles on it.
    static func removalNote(for account: BoardAccount, tilesUsingIt count: Int) -> String {
        var note = account.isVenice ? "Your Venice account stays connected." : "Its sign-in is deleted from this Mac."
        if count > 0 {
            note += " \(count) tile\(count == 1 ? " uses" : "s use") it and "
            note += account.isVenice
                ? "won't start Codex again until you choose an account for \(count == 1 ? "it" : "them")."
                : "will need to sign in again."
        }
        if account.isVenice, BoardAccounts.shared.active[.codex] == account.id { note += " New tiles will use your usual sign-in." }
        return note
    }

    /// Starts the tile's agent again on another profile (or your usual sign-in).
    func switchAccount(_ surface: Ghostty.SurfaceView, to account: BoardAccount?, provider: BoardAccount.Provider) {
        if let account, account.isVenice, !prepareVenice(account) { return }
        var chosen = model.tileAccounts[surface.id] ?? [:]
        chosen[provider] = account?.id
        model.tileAccounts[surface.id] = chosen
        scheduleSave()
        guard let terminal = surface.surfaceModel else { return }
        func key(_ key: Ghostty.Input.Key, _ mods: Ghostty.Input.Mods, _ codepoint: UInt32) {
            terminal.sendKeyEvent(.init(key: key, action: .press, mods: mods, unshiftedCodepoint: codepoint))
            terminal.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        }
        // Quit the agent, point the shell at the profile, start it there.
        key(.c, .ctrl, 99)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            key(.c, .ctrl, 99)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                terminal.sendText(VeniceCodex.switchLine(to: account, provider: provider))
                key(.enter, [], 13)
            }
        }
    }
}

// MARK: - The panel

/// Accounts: per provider, your usual sign-in and the profiles you added; which one new tiles
/// use; and connecting another.
struct BoardAccountsView: View {
    let controller: BoardController
    @Binding var isPresented: Bool
    @ObservedObject private var store = BoardAccounts.shared
    @ObservedObject private var venice = VeniceAccount.shared
    @State private var provider: BoardAccount.Provider = .claude
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Accounts").font(Tellurion.font(16, weight: .semibold)).foregroundColor(Tellurion.text)
                Spacer()
                Picker("", selection: $provider) {
                    ForEach(BoardAccount.Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if provider == .claude {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").foregroundColor(.yellow)
                    Text("Claude Code may keep its sign-in in your Mac's keychain, which profiles can't fully separate. After switching, check the account with /status in the tile.")
                        .font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.yellow.opacity(0.08)))
            }
            VStack(spacing: 6) {
                row(nil, title: "Your sign-in", detail: "The usual \(provider.title) sign-in")
                ForEach(store.accounts.filter { $0.provider == provider }) { account in
                    row(account, title: account.name, detail: account.isVenice ? "On Venice · " + (account.veniceModel ?? "") : account.used ? "Set up" : "Not set up yet: open a tile to sign in")
                }
            }
            if provider == .codex { veniceModels }
            TellurionSectionLabel("Connect another account")
            HStack(spacing: 8) {
                TextField("e.g. Personal Max", text: $name).textFieldStyle(.roundedBorder)
                Button("Connect") {
                    let account = store.add(provider, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    name = ""
                    controller.connect(account)
                    isPresented = false
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
            }
            Text("Opens a \(provider.title) tile where its own sign-in runs. New \(provider.title) tiles use the account marked Active.")
                .font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Tellurion.panel)
    }

    /// Codex with its usual setup, its model requests going to Venice.
    @ViewBuilder
    private var veniceModels: some View {
        if venice.connected {
            Menu("Add a Venice Model") {
                ForEach(venice.models.filter(\.worksInCodex)) { model in
                    Button(model.name + (model.isPrivate ? "" : " (Anonymized)")) {
                        _ = store.veniceAccount(model: model.id, name: model.name, isPrivate: model.isPrivate)
                    }
                }
            }
            .frame(maxWidth: 220)
            .onAppear { venice.refreshIfEmpty() }
        } else {
            Button("Connect Venice…") { LocalModelsWindow.show() }
                .buttonStyle(TellurionButtonStyle())
                .help("Run Codex on abliterated and other models from your own Venice account")
        }
    }

    private func row(_ account: BoardAccount?, title: String, detail: String) -> some View {
        let active = store.active[provider] == account?.id
        return HStack(spacing: 10) {
            Text(account?.initials ?? "ME").font(Tellurion.font(11, weight: .bold)).foregroundColor(Tellurion.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(account == nil ? Tellurion.muted : Tellurion.core))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(detail).font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
            }
            Spacer()
            if active {
                Text("● ACTIVE").font(Tellurion.font(10, weight: .bold)).foregroundColor(Tellurion.core)
            } else {
                Button("Use") {
                    if let account, account.isVenice, !controller.prepareVenice(account) { return }
                    store.use(account?.id, for: provider)
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
            }
            if let account {
                Button { controller.connect(account) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.plain).help("Open a tile with this account")
                Button {
                    controller.promptRename("Rename Account", current: account.name) { store.rename(account.id, to: $0) }
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Rename")
                Button { controller.confirmRemove(account) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Remove this account and its sign-in")
            }
        }
        .foregroundColor(Tellurion.muted)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tellurion.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Tellurion.core.opacity(0.6) : .clear))
    }
}
#endif

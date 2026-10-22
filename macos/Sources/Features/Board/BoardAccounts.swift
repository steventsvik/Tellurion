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

    /// Whether it has been signed in: the agent wrote its account to the folder (only that
    /// the entry is there is checked, nothing in it is read).
    var signedIn: Bool {
        let files = FileManager.default
        switch provider {
        case .codex: return files.fileExists(atPath: folder.appendingPathComponent("auth.json").path)
        case .claude:
            guard let data = files.contents(atPath: folder.appendingPathComponent(".claude.json").path) else { return false }
            return String(bytes: data, encoding: .utf8)?.contains("\"oauthAccount\"") == true
        }
    }
}

final class BoardAccounts: ObservableObject {
    static let shared = BoardAccounts()

    @Published private(set) var accounts: [BoardAccount] = []
    /// Per provider: the profile new tiles use (nil: your usual sign-in).
    @Published private(set) var active: [BoardAccount.Provider: UUID] = [:]

    private var file: URL { AgentTools.root.appendingPathComponent("accounts.json") }

    private struct Saved: Codable {
        var accounts: [BoardAccount]
        var active: [String: UUID]
    }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        accounts = saved.accounts
        active = Dictionary(uniqueKeysWithValues: saved.active.compactMap { key, value in
            BoardAccount.Provider(rawValue: key).map { ($0, value) }
        })
    }

    private func save() {
        let saved = Saved(accounts: accounts, active: Dictionary(uniqueKeysWithValues: active.map { ($0.key.rawValue, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: AgentTools.root, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func account(_ id: UUID?) -> BoardAccount? { id.flatMap { id in accounts.first { $0.id == id } } }

    /// A new, empty profile (its folder made, owner-only).
    @discardableResult
    func add(_ provider: BoardAccount.Provider, name: String) -> BoardAccount {
        let account = BoardAccount(provider: provider, name: name.isEmpty ? "\(provider.title) \(accounts.count + 2)" : name)
        try? FileManager.default.createDirectory(at: account.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
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
        try? FileManager.default.removeItem(at: account.folder)
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
            environment[provider.variable] = account.folder.path
        }
        return environment
    }
}

extension BoardController {
    /// Points a new tile's agents at the active profiles, and remembers which they were.
    func applyAccounts(_ config: inout Ghostty.SurfaceConfiguration, chosen: [BoardAccount.Provider: UUID]? = nil) -> [BoardAccount.Provider: UUID] {
        let chosen = chosen ?? BoardAccounts.shared.active
        for (key, value) in BoardAccounts.shared.environment(chosen) { config.environmentVariables[key] = value }
        return chosen
    }

    /// The profile a tile's running agent signed in with, if not your usual one.
    func account(of surface: Ghostty.SurfaceView) -> BoardAccount? {
        guard let kind = VerticalTabsAgents.shared.info(for: surface)?.kind,
              let provider = BoardAccount.Provider.allCases.first(where: { $0.kind == kind }) else { return nil }
        return BoardAccounts.shared.account(model.tileAccounts[surface.id]?[provider])
    }

    /// A tile running a profile's sign-in, so you can sign it in there.
    func connect(_ account: BoardAccount) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workspace.folder
        var chosen = BoardAccounts.shared.active
        chosen[account.provider] = account.id
        let applied = applyAccounts(&config, chosen: chosen)
        guard let tile = addTile(config: config, command: account.provider.login + "\n") else { return }
        model.tileAccounts[tile.id] = applied
        setTitle("Sign in: \(account.name)", for: tile)
    }

    /// Starts the tile's agent again on another profile (or your usual sign-in).
    func switchAccount(_ surface: Ghostty.SurfaceView, to account: BoardAccount?, provider: BoardAccount.Provider) {
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
                let line = account.map { "export \(provider.variable)=\(AgentTools.shellQuote($0.folder.path))" } ?? "unset \(provider.variable)"
                terminal.sendText(line + "; " + (provider == .claude ? "claude" : "codex"))
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
    @State private var provider: BoardAccount.Provider = .claude
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Accounts").font(Extreme.font(16, weight: .semibold)).foregroundColor(Extreme.text)
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
                        .font(Extreme.font(11.5)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.yellow.opacity(0.08)))
            }
            VStack(spacing: 6) {
                row(nil, title: "Your sign-in", detail: "The usual \(provider.title) sign-in")
                ForEach(store.accounts.filter { $0.provider == provider }) { account in
                    row(account, title: account.name, detail: account.signedIn ? "Signed in" : "Not signed in yet: open a tile to sign in")
                }
            }
            ExtremeSectionLabel("Connect another account")
            HStack(spacing: 8) {
                TextField("e.g. Personal Max", text: $name).textFieldStyle(.roundedBorder)
                Button("Connect") {
                    let account = store.add(provider, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    name = ""
                    controller.connect(account)
                    isPresented = false
                }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
            }
            Text("Opens a \(provider.title) tile where its own sign-in runs. New \(provider.title) tiles use the account marked Active.")
                .font(Extreme.font(11)).foregroundColor(Extreme.dim)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Extreme.panel)
    }

    private func row(_ account: BoardAccount?, title: String, detail: String) -> some View {
        let active = store.active[provider] == account?.id
        return HStack(spacing: 10) {
            Text(account?.initials ?? "ME").font(Extreme.font(11, weight: .bold)).foregroundColor(Extreme.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(account == nil ? Extreme.muted : Extreme.core))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
                Text(detail).font(Extreme.font(11)).foregroundColor(Extreme.dim)
            }
            Spacer()
            if active {
                Text("● ACTIVE").font(Extreme.font(10, weight: .bold)).foregroundColor(Extreme.core)
            } else {
                Button("Use") { store.use(account?.id, for: provider) }.buttonStyle(ExtremeButtonStyle(prominent: true))
            }
            if let account {
                Button { controller.connect(account) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.plain).help("Open a tile with this account")
                Button {
                    controller.promptRename("Rename Account", current: account.name) { store.rename(account.id, to: $0) }
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Rename")
                Button { store.remove(account.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Remove this account and its sign-in")
            }
        }
        .foregroundColor(Extreme.muted)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Extreme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Extreme.core.opacity(0.6) : .clear))
    }
}
#endif

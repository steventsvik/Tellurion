#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Local Models window: the models Ollama has, each opened as a chat on this Mac, and
/// a few to download.
enum LocalModelsWindow {
    static let windowID = "local-models"

    static func show() {
        guard TellurionSettings.isOn(.localModels) else { return }
        AgentToolWindows.show(id: windowID, title: "Local Models", size: NSSize(width: 680, height: 760)) {
            LocalModelsWindowView()
        }
    }

    /// The terminal window or board in front of the others, to open a model in.
    static var frontTerminal: BaseTerminalController? {
        NSApp.orderedWindows.lazy.compactMap { TerminalWindows.controller(of: $0) }.first
            ?? TerminalWindows.all.first
    }
}

struct LocalModelsWindowView: View {
    @ObservedObject private var models = LocalModelsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TellurionWindowTitle(icon: .environment, title: "Local Models",
                               subtitle: "Chat with a model on this Mac or on Venice. Drag one from the sidebar under a chat.")
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 14)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    if let error = models.error {
                        Text(error).font(Tellurion.font(12)).foregroundColor(Tellurion.danger)
                    }
                    // Every provider's models: Ollama, LM Studio, a llama.cpp or MLX server, Apple's.
                    let installed = models.models.filter { $0.host != .venice }
                    if !installed.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            TellurionSectionLabel("On this Mac")
                            ForEach(installed) { LocalModelWindowRow(item: $0) }
                        }
                        if installed.contains(where: { $0.host == .ollama || $0.host == .lmStudio }) {
                            LocalCodexOptions()
                        }
                    }
                    VeniceSection()
                    if case .running = models.ollama {
                        ModelCatalogView(installed: Set(installed.filter { $0.host == .ollama }.map(\.name)))
                    }
                    Text("Chats with models on this Mac run through Ollama and the like: nothing leaves it, and they work offline. "
                         + "Small models answer faster but know less.")
                        .font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .onAppear { models.watch(true) }
        .onDisappear { models.watch(false) }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            let state = models.ollama
            Circle().fill(state == .notInstalled ? Tellurion.dim : state == .stopped ? Tellurion.warn : Tellurion.live)
                .frame(width: 7, height: 7)
            Text("Ollama").font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
            switch state {
            case .notInstalled:
                Text("isn't installed").font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    .buttonStyle(TellurionButtonStyle())
            case .stopped:
                Text("isn't running").font(Tellurion.font(11)).foregroundColor(Tellurion.warn)
                Button("Start", action: models.startOllama).buttonStyle(TellurionButtonStyle())
            case .running(let version):
                Text(version.map { "running · \($0)" } ?? "running").font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
            }
            Spacer()
        }
    }
}

private struct LocalModelWindowRow: View {
    let item: LocalModel
    @ObservedObject private var models = LocalModelsModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(item.name).font(Tellurion.mono(12)).foregroundColor(Tellurion.text).lineLimit(1)
            if item.loaded {
                Text("LOADED").font(Tellurion.font(9, weight: .bold)).foregroundColor(Tellurion.ink)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Tellurion.live))
            }
            // Which app serves it: the same model can be in Ollama and LM Studio.
            Text(item.host == .ollama || item.host == .lmStudio ? "\(item.host.rawValue) · \(item.detail)" : item.detail)
                .font(Tellurion.font(11)).foregroundColor(Tellurion.dim).lineLimit(1)
            Spacer(minLength: 8)
            if models.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                if item.loaded, item.host.canUnload {
                    Button("Unload") { models.unload(item) }.buttonStyle(TellurionButtonStyle()).help("Free its memory now")
                }
                if item.host == .ollama || item.host == .lmStudio {
                    Button("Open in Codex") {
                        guard let owner = LocalModelsWindow.frontTerminal else { return }
                        LocalModelSessions.openCodex(item, from: owner)
                        owner.window?.makeKeyAndOrderFront(nil)
                    }
                    .buttonStyle(TellurionButtonStyle())
                    .disabled(item.tools == false)
                    .help(item.tools == false ? "This model can't call tools, which Codex needs"
                          : "Codex, with its usual tools and setup, on \(item.name). Nothing leaves this Mac.")
                }
                Button("Open") {
                    guard let owner = LocalModelsWindow.frontTerminal else { return }
                    LocalModelSessions.open(item, from: owner)
                    owner.window?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .help("Chat with \(item.name): below the chat in front, or in a new tab")
            }
        }
        .padding(.vertical, 3)
    }
}

/// What Codex sessions on a model on this Mac may use beyond coding tools, for the ones started
/// from now on. Nothing else about them leaves the Mac, so this is the one switch.
private struct LocalCodexOptions: View {
    @ObservedObject private var models = LocalModelsModel.shared
    @State private var webSearch = LocalCodexOption.webSearch.isOn

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Codex sessions on these models").font(Tellurion.font(11, weight: .medium)).foregroundColor(Tellurion.dim)
                .padding(.bottom, 4)
            Toggle("Search the web", isOn: $webSearch).toggleStyle(.checkbox).font(Tellurion.font(12))
                .onChange(of: webSearch) { on in
                    do {
                        try LocalCodexOption.webSearch.set(on)
                    } catch {
                        models.error = error.localizedDescription
                        webSearch = LocalCodexOption.webSearch.isOn
                    }
                }
            Text("The one thing that leaves this Mac: what it searches for goes to Exa, free for about 50 searches a day, "
                 + "or to your own SearXNG if you've set one up (tellurion venice search setup). Off, a session has no web access.")
                .font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The sidebar's Local models section: Ollama's models, to click open or drag under a chat.
/// Takes no room when Ollama has none.
struct LocalModelsSidebarSection: View {
    let owner: BaseTerminalController
    @ObservedObject private var models = LocalModelsModel.shared
    @AppStorage("LocalModelsSectionCollapsed") private var collapsed = false

    var body: some View {
        let list = models.models
        VStack(alignment: .leading, spacing: 4) {
            if !list.isEmpty {
                Rectangle().fill(Tellurion.line).frame(height: 1).padding(.bottom, 4)
                header(count: list.count)
                if !collapsed {
                    ForEach(list) { LocalModelSidebarRow(item: $0, owner: owner) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, list.isEmpty ? 0 : 6)
        // Stays mounted (empty) so it appears when a model is downloaded.
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)
        // Keeps its height in a short window; the tab list above scrolls instead.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { models.watch(true) }
        .onDisappear { models.watch(false) }
        .animation(.easeOut(duration: 0.18), value: list.map(\.id))
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(Tellurion.dim).frame(width: 8)
                    Text("LOCAL MODELS").font(Tellurion.font(10.5, weight: .semibold)).kerning(1.1).foregroundColor(Tellurion.muted)
                        .fixedSize()
                    Text("\(count)").font(Tellurion.font(10)).foregroundColor(Tellurion.dim).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Tellurion.line.opacity(0.7)).frame(height: 1)
            Button { LocalModelsWindow.show() } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundColor(Tellurion.dim)
            }
            .buttonStyle(.plain)
            .help("Local Models: download, unload and open")
        }
        .padding(.horizontal, 4)
    }
}

private struct LocalModelSidebarRow: View {
    let item: LocalModel
    let owner: BaseTerminalController
    @State private var hovering = false

    /// Always says which app serves it: the same model can be in Ollama and LM Studio.
    private var hostLine: String {
        switch item.host {
        case .venice:
            return "Venice · " + (item.isPrivate ? "Private" : "Anonymized") + (item.uncensored ? " · Uncensored" : "")
        case .ollama:
            return "Ollama · " + (item.loaded ? "Loaded" + (item.memory.map { " · " + Housekeeping.bytes($0) } ?? "") : item.detail)
        case .lmStudio:
            return item.host.rawValue + (item.loaded ? " · Loaded" : "")
        case .llamaCpp, .mlx, .apple:
            return item.host.rawValue
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.host == .venice ? "cloud" : "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(item.loaded ? Tellurion.live : Tellurion.dim)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(Tellurion.mono(11.5))
                    .foregroundColor(Tellurion.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hostLine)
                    .font(Tellurion.font(9.5))
                    .foregroundColor(item.loaded ? Tellurion.live.opacity(0.85) : Tellurion.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Tellurion.dim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Tellurion.raised : .clear))
        .contentShape(Rectangle())
        .overlay(LocalModelDragSource(payload: item.host.rawValue + "\t" + item.name, title: item.name,
                                      onClick: { LocalModelSessions.open(item, from: owner) },
                                      onHover: { hovering = $0 }))
    }
}
#endif

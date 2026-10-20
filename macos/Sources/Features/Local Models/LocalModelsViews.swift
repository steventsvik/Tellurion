#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Local Models window: the models Ollama has, each opened as a chat on this Mac, and
/// a few to download.
enum LocalModelsWindow {
    static let windowID = "local-models"

    static func show() {
        guard ExtremeSettings.isOn(.localModels) else { return }
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
            ExtremeWindowTitle(icon: .environment, title: "Local Models",
                               subtitle: "Chat with a model on this Mac. Drag one from the sidebar under a chat.")
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 14)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    if let error = models.error {
                        Text(error).font(Extreme.font(12)).foregroundColor(Extreme.danger)
                    }
                    // Every provider's models: Ollama, LM Studio, a llama.cpp or MLX server, Apple's.
                    let installed = models.models
                    if !installed.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ExtremeSectionLabel("On this Mac")
                            ForEach(installed) { LocalModelWindowRow(item: $0) }
                        }
                    }
                    if case .running = models.ollama {
                        ModelCatalogView(installed: Set(installed.filter { $0.host == .ollama }.map(\.name)))
                    }
                    Text("Each chat runs through Ollama on this Mac: nothing leaves it, and it works offline. "
                         + "Small models answer faster but know less.")
                        .font(Extreme.font(11)).foregroundColor(Extreme.dim)
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
            Circle().fill(state == .notInstalled ? Extreme.dim : state == .stopped ? Extreme.warn : Extreme.live)
                .frame(width: 7, height: 7)
            Text("Ollama").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
            switch state {
            case .notInstalled:
                Text("isn't installed").font(Extreme.font(11)).foregroundColor(Extreme.dim)
                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    .buttonStyle(ExtremeButtonStyle())
            case .stopped:
                Text("isn't running").font(Extreme.font(11)).foregroundColor(Extreme.warn)
                Button("Start", action: models.startOllama).buttonStyle(ExtremeButtonStyle())
            case .running(let version):
                Text(version.map { "running · \($0)" } ?? "running").font(Extreme.font(11)).foregroundColor(Extreme.muted)
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
            Text(item.name).font(Extreme.mono(12)).foregroundColor(Extreme.text).lineLimit(1)
            if item.loaded {
                Text("LOADED").font(Extreme.font(9, weight: .bold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Extreme.live))
            }
            // Which app serves it: the same model can be in Ollama and LM Studio.
            Text(item.host == .ollama || item.host == .lmStudio ? "\(item.host.rawValue) · \(item.detail)" : item.detail)
                .font(Extreme.font(11)).foregroundColor(Extreme.dim).lineLimit(1)
            Spacer(minLength: 8)
            if models.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                if item.loaded, item.host.canUnload {
                    Button("Unload") { models.unload(item) }.buttonStyle(ExtremeButtonStyle()).help("Free its memory now")
                }
                Button("Open") {
                    guard let owner = LocalModelsWindow.frontTerminal else { return }
                    LocalModelSessions.open(item, from: owner)
                    owner.window?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
                .help("Chat with \(item.name): below the chat in front, or in a new tab")
            }
        }
        .padding(.vertical, 3)
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
                Rectangle().fill(Extreme.line).frame(height: 1).padding(.bottom, 4)
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
                        .font(.system(size: 8, weight: .bold)).foregroundColor(Extreme.dim).frame(width: 8)
                    Text("LOCAL MODELS").font(Extreme.font(10.5, weight: .semibold)).kerning(1.1).foregroundColor(Extreme.muted)
                        .fixedSize()
                    Text("\(count)").font(Extreme.font(10)).foregroundColor(Extreme.dim).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Extreme.line.opacity(0.7)).frame(height: 1)
            Button { LocalModelsWindow.show() } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundColor(Extreme.dim)
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

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(item.loaded ? Extreme.live : Extreme.dim)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(Extreme.mono(11.5))
                    .foregroundColor(Extreme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Always says which app serves it: the same model can be in Ollama and LM Studio.
                Text(item.host == .ollama
                     ? "Ollama · " + (item.loaded ? "Loaded" + (item.memory.map { " · " + Housekeeping.bytes($0) } ?? "") : item.detail)
                     : item.host.rawValue + (item.loaded && item.host == .lmStudio ? " · Loaded" : ""))
                    .font(Extreme.font(9.5))
                    .foregroundColor(item.loaded ? Extreme.live.opacity(0.85) : Extreme.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Extreme.dim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Extreme.raised : .clear))
        .contentShape(Rectangle())
        .overlay(LocalModelDragSource(payload: item.host.rawValue + "\t" + item.name, title: item.name,
                                      onClick: { LocalModelSessions.open(item, from: owner) },
                                      onHover: { hovering = $0 }))
    }
}
#endif

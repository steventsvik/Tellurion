#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Every localhost session, grouped by project, plus other dev servers found on this Mac.
enum LocalhostManager {
    static func toggle() {
        if AgentToolWindows.isOpen(LocalhostSessions.windowID) {
            AgentToolWindows.close(id: LocalhostSessions.windowID)
        } else {
            show()
        }
    }

    static func show() {
        guard ExtremeSettings.isOn(.localhost) else { return }
        AgentToolWindows.show(id: LocalhostSessions.windowID, title: "Localhost", size: NSSize(width: 980, height: 680)) {
            LocalhostManagerView()
        }
    }

    /// The "New server" sheet, as its own small window.
    static func showNewServer(folder: String?, from owner: BaseTerminalController?) {
        guard ExtremeSettings.isOn(.localhost) else { return }
        AgentToolWindows.show(id: "localhost-new", title: "New Localhost Server", size: NSSize(width: 520, height: 420)) {
            LocalhostNewServerView(folder: folder ?? NSHomeDirectory(), owner: owner)
        }
    }
}

private struct LocalhostManagerView: View {
    @ObservedObject private var store = LocalhostSessions.shared

    private var groups: [(project: LocalhostProject, sessions: [LocalhostSession])] {
        let grouped = Dictionary(grouping: store.sessions, by: \.project)
        return grouped.map { ($0.key, $0.value.sorted { $0.created < $1.created }) }
            .sorted { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.sessions.isEmpty {
                        emptyState
                    }
                    ForEach(groups, id: \.project) { group in
                        projectSection(group.project, group.sessions)
                    }
                    othersSection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(
            LinearGradient(colors: [Color.cyan.opacity(0.05), Color.purple.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .onAppear { store.scanOthers = true }
        .onDisappear { store.scanOthers = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "globe").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: .cyan.opacity(0.4), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Localhost").font(.system(size: 17, weight: .bold))
                Text(summary).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            if store.sessions.contains(where: \.isRunning) {
                Button(role: .destructive) { store.stopAll() } label: { Label("Stop all", systemImage: "stop.fill") }
            }
            Button {
                let owner = TerminalWindows.front
                LocalhostManager.showNewServer(folder: owner?.focusedSurface?.pwd, from: owner)
            } label: { Label("New server", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    private var summary: String {
        let live = store.liveCount
        let stopped = store.sessions.count - store.sessions.filter(\.isRunning).count
        var parts = ["\(live) live"]
        if stopped > 0 { parts.append("\(stopped) stopped") }
        parts.append("\(Set(store.sessions.map(\.project)).count) project\(Set(store.sessions.map(\.project)).count == 1 ? "" : "s")")
        if !store.others.isEmpty { parts.append("\(store.others.count) other server\(store.others.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("No localhost sessions").font(.system(size: 15, weight: .semibold))
            Text("When Claude Code starts a dev server it opens here, in its own tab that keeps running after the agent is done. You can also start one yourself, or move a server that's already running.")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func projectSection(_ project: LocalhostProject, _ sessions: [LocalhostSession]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(project.color).frame(width: 4, height: 18)
                Text(project.name).font(.system(size: 14, weight: .bold))
                Text((project.root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    LocalhostManager.showNewServer(folder: project.root, from: nil)
                } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
                if sessions.contains(where: \.isRunning) {
                    Button { store.stopAll(in: project) } label: { Label("Stop all", systemImage: "stop.fill") }
                        .controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 520), spacing: 12)], spacing: 12) {
                ForEach(sessions) { session in
                    LocalhostManagerCard(session: session)
                }
            }
        }
    }

    @ViewBuilder
    private var othersSection: some View {
        if !store.others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(.orange)
                    Text("Other servers on this Mac").font(.system(size: 14, weight: .bold))
                    Text("not in a localhost session, so they stop when whatever started them does")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(store.others) { server in
                        LocalhostOtherRow(server: server)
                    }
                }
            }
        }
    }
}

private struct LocalhostManagerCard: View {
    let session: LocalhostSession
    @State private var hovering = false

    var body: some View {
        let accent = session.project.color
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    LocalhostPulse(color: session.statusColor, active: session.state == .live, size: 8)
                    Text(session.statusLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(session.statusColor)
                    if session.state == .live, let since = session.liveSince {
                        Text("for \(localhostUptime(since: since, now: context.date))")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    LocalhostFrameworkBadge(framework: session.framework)
                }
                LocalhostURLPill(session: session, large: true)
                Text("$ " + session.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    if session.isRunning {
                        Label(String(format: "%.0f%% CPU", session.cpu), systemImage: "cpu")
                        Label(String(format: "%.0f MB", session.memoryMB), systemImage: "memorychip")
                    }
                    let extra = session.ports.filter { $0 != session.url?.port }
                    if !extra.isEmpty {
                        Label(extra.map { ":\($0)" }.joined(separator: " "), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    if let agent = session.agent {
                        HStack(spacing: 4) {
                            VerticalTabAgentLogo(kind: agent, tint: agent.standaloneLogoColor).frame(width: 11, height: 11)
                            Text("started by \(agent.displayName)")
                        }
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                Divider().opacity(0.5)
                HStack(spacing: 6) {
                    Button { LocalhostSessions.shared.openInBrowser(session.url) } label: {
                        Label("Open", systemImage: "safari").fixedSize()
                    }.disabled(session.url == nil)
                    Button {
                        if let url = session.url { LocalhostPreview.show(url, title: session.project.name) }
                    } label: { Label("Preview", systemImage: "eye").fixedSize() }.disabled(session.url == nil)
                    Button { LocalhostSessions.shared.focus(session) } label: { Label("Logs", systemImage: "text.alignleft").fixedSize() }
                    if session.state == .live {
                        VisualFixLaunchButton(url: session.url, controller: nil)
                    }
                    Spacer(minLength: 4)
                    LocalhostIconButton(symbol: session.isRunning ? "arrow.clockwise" : "play.fill",
                                        help: session.isRunning ? "Restart" : "Start again",
                                        tint: session.isRunning ? .orange : .green) {
                        LocalhostSessions.shared.restart(session)
                    }
                    if session.isRunning {
                        LocalhostIconButton(symbol: "stop.fill", help: "Stop the server (the tab stays)", tint: .red) {
                            LocalhostSessions.shared.stop(session)
                        }
                    }
                    LocalhostIconButton(symbol: "xmark", help: "Stop and close the tab", tint: .red) {
                        LocalhostSessions.shared.close(session)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [accent.opacity(hovering ? 0.2 : 0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            })
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(LinearGradient(colors: [accent.opacity(0.8), Color.cyan.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1))
        .shadow(color: session.state == .live ? accent.opacity(0.25) : .clear, radius: 8)
        .onHover { hovering = $0 }
    }
}

private struct LocalhostOtherRow: View {
    let server: LocalhostOtherServer

    var body: some View {
        let color = server.project?.color ?? .orange
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.system(size: 13, weight: .semibold))
                    LocalhostFrameworkBadge(framework: server.framework, compact: true)
                    Text(server.ports.map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
                Text(server.rootCommand)
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { LocalhostSessions.shared.openInBrowser(server.url) } label: { Label("Open", systemImage: "safari") }
            Button {
                confirm("Move \(server.displayName) into a localhost session?",
                        "It's stopped and started again in its own tab (same folder and command), so it keeps running on its own.\n\n\(server.rootCommand)",
                        button: "Move") { LocalhostSessions.shared.adopt(server) }
            } label: { Label("Keep alive", systemImage: "pin.fill") }
                .disabled(server.cwd == nil)
                .help("Restart it in its own tab so it survives the terminal or agent that started it")
            Button(role: .destructive) {
                confirm("Stop \(server.displayName)?", server.rootCommand, button: "Stop") {
                    LocalhostSessions.shared.stopOther(server)
                }
            } label: { Image(systemName: "stop.fill") }
                .help("Stop this server")
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private func confirm(_ title: String, _ detail: String, button: String, action: () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

// MARK: - New server

private struct LocalhostNewServerView: View {
    @State var folder: String
    let owner: BaseTerminalController?
    @State private var command = ""

    private var scripts: [(name: String, body: String)] { LocalhostFramework.serverScripts(in: folder) }
    private var manager: String { LocalhostFramework.packageManager(in: folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 22, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New localhost server").font(.system(size: 17, weight: .semibold))
                    Text("Runs in its own tab and keeps running until you stop it.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            HStack {
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { chooseFolder() }.controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            if !scripts.isEmpty {
                Text("From package.json").font(.system(size: 12, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(scripts, id: \.name) { script in
                        let run = manager == "npm" || manager == "bun" ? "\(manager) run \(script.name)" : "\(manager) \(script.name)"
                        Button {
                            command = run
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(script.body).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(command == run ? Color.cyan.opacity(0.2) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(command == run ? Color.cyan : Color.primary.opacity(0.1)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 12, weight: .semibold))
                TextField("npm run dev", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(start)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { AgentToolWindows.close(id: "localhost-new") }.keyboardShortcut(.cancelAction)
                Button("Start server", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear {
            if command.isEmpty, let first = scripts.first {
                command = manager == "npm" || manager == "bun" ? "\(manager) run \(first.name)" : "\(manager) \(first.name)"
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            command = ""
        }
    }

    private func start() {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        LocalhostSessions.shared.start(command: trimmed, in: folder, from: owner, focus: true)
        AgentToolWindows.close(id: "localhost-new")
    }
}

// MARK: - Preview

/// A small browser window for a localhost URL, with reload and "open in browser".
enum LocalhostPreview {
    static func show(_ url: URL, title: String) {
        AgentToolWindows.show(id: "preview-\(url.absoluteString)", title: "\(title) · \(url.host ?? ""):\(url.port ?? 80)",
                              size: NSSize(width: 1100, height: 760)) {
            LocalhostPreviewView(url: url)
        }
    }
}

private final class LocalhostPreviewModel: ObservableObject {
    let webView = WKWebView()
    @Published var address: String
    @Published var loading = false
    private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        address = url.absoluteString
        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.loading = view.isLoading }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { if let url = view.url { self?.address = url.absoluteString } }
            },
        ]
        webView.load(URLRequest(url: url))
    }

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        if let url = URL(string: text) { webView.load(URLRequest(url: url)) }
    }
}

private struct LocalhostPreviewView: View {
    @StateObject private var model: LocalhostPreviewModel

    init(url: URL) {
        _model = StateObject(wrappedValue: LocalhostPreviewModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                Button { model.webView.reload() } label: {
                    Image(systemName: model.loading ? "xmark" : "arrow.clockwise")
                }
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundColor(.cyan)
                    TextField("", text: $model.address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { model.go() }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                Button { if let url = model.webView.url { NSWorkspace.shared.open(url) } } label: {
                    Label("Open in browser", systemImage: "safari")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.top, 30)
            .padding(.bottom, 8)
            Divider()
            LocalhostWebView(webView: model.webView)
        }
    }
}

private struct LocalhostWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

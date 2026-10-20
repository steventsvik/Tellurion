#if os(macOS)
import AppKit
import SwiftUI

/// The Environment window: what a folder sets up (mise, direnv, version files), the
/// containers Docker runs, and the models loaded in Ollama and LM Studio.
enum EnvironmentWindow {
    static let windowID = "environment"

    static func show(folder: String? = nil) {
        guard ExtremeSettings.isOn(.environment) else { return }
        AgentToolWindows.show(id: windowID, title: "Environment", size: NSSize(width: 900, height: 640)) {
            EnvironmentWindowView(folder: folder ?? NSHomeDirectory())
        }
    }

    /// For the focused terminal of the frontmost window (a tab, or a tile on a board).
    static func showForFrontTab() {
        show(folder: TerminalWindows.front?.focusedSurface?.pwd)
    }
}

/// The folder tab's state and its few actions.
final class FolderEnvironmentModel: ObservableObject {
    @Published var folder: String { didSet { if folder != oldValue { load() } } }
    @Published private(set) var environment: FolderEnvironment?
    @Published private(set) var loading = false
    @Published var notice: String?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.environment", qos: .userInitiated)

    init(folder: String) {
        self.folder = folder
    }

    func load() {
        loading = true
        let folder = self.folder
        queue.async { [weak self] in
            let environment = FolderEnvironmentProbe.probe(folder)
            DispatchQueue.main.async {
                guard let self, self.folder == folder else { return }
                self.environment = environment
                self.loading = false
            }
        }
    }

    /// `mise trust` for the folder's config files: mise reads them from then on.
    func trust(_ files: [String]) {
        guard let mise = ToolPath.find("mise") else { return }
        let folder = self.folder
        queue.async { [weak self] in
            for file in files { _ = ToolPath.run(mise, ["trust", file], in: folder) }
            DispatchQueue.main.async { self?.notice = "Trusted"; self?.load() }
        }
    }

    /// Installs the missing versions in a tab, where the downloads show.
    func installMissing() {
        SetupChecks.openTab(running: "cd \(AgentTools.shellQuote(folder)) && \(ToolPath.find("mise").map(AgentTools.shellQuote) ?? "mise") install")
    }

    func direnv(_ verb: String, _ path: String) {
        guard let direnv = ToolPath.find("direnv") else { return }
        let folder = self.folder
        queue.async { [weak self] in
            _ = ToolPath.run(direnv, [verb, path], in: folder)
            DispatchQueue.main.async { self?.notice = verb == "allow" ? "Allowed" : "Blocked"; self?.load() }
        }
    }

    func open(_ path: String) {
        let full = path.hasPrefix("/") ? path : path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : folder + "/" + path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
    }
}

struct EnvironmentWindowView: View {
    enum Tab: String, CaseIterable { case folder = "This Folder", containers = "Containers", models = "Local Models" }

    @StateObject private var folderModel: FolderEnvironmentModel
    @StateObject private var containers = ContainersModel()
    @StateObject private var models = LocalModelsModel()
    @State private var tab: Tab = .folder

    init(folder: String) {
        _folderModel = StateObject(wrappedValue: FolderEnvironmentModel(folder: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                ExtremeWindowTitle(icon: .environment, title: "Environment", subtitle: subtitle)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 14)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                Group {
                    switch tab {
                    case .folder: FolderPane(model: folderModel)
                    case .containers: ContainersPane(model: containers)
                    case .models: ModelsPane(model: models)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Extreme.ink)
        .onAppear { folderModel.load(); start(tab) }
        .onChange(of: tab) { start($0) }
        .onDisappear { containers.stop(); models.stop() }
    }

    private var subtitle: String {
        switch tab {
        case .folder:
            return (folderModel.folder as NSString).lastPathComponent
        case .containers: return "Everything Docker runs, from Docker Desktop, OrbStack or Colima"
        case .models: return "Models on this Mac in Ollama and LM Studio"
        }
    }

    /// Only the tab on screen polls.
    private func start(_ tab: Tab) {
        if tab == .containers { containers.start() } else { containers.stop() }
        if tab == .models { models.start() } else { models.stop() }
    }
}

// MARK: - This folder

private struct FolderPane: View {
    @ObservedObject var model: FolderEnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(model.folder).font(Extreme.mono(11)).foregroundColor(Extreme.muted).lineLimit(1).truncationMode(.head)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.load() }
                Button("Choose Folder…", action: choose)
            }
            if let env = model.environment, env.missing {
                Text("This folder doesn't exist anymore. Choose another one.")
                    .font(Extreme.font(12)).foregroundColor(Extreme.warn)
            } else if let env = model.environment {
                miseNotices(env)
                if env.isEmpty {
                    Text("Nothing here sets up tools or environment variables: no mise or asdf config, no version files, no .envrc.")
                        .font(Extreme.font(12)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if !env.tools.isEmpty { toolsSection(env) }
                if !env.variables.isEmpty || env.direnvFile != nil { variablesSection(env) }
            } else {
                Text("Reading…").font(Extreme.font(12)).foregroundColor(Extreme.dim)
            }
        }
    }

    @ViewBuilder
    private func miseNotices(_ env: FolderEnvironment) -> some View {
        switch env.mise {
        case .untrusted(let files):
            banner("mise won't read \(files.count == 1 ? "this folder's config" : "\(files.count) config files here") until you trust it.",
                   color: Extreme.warn) {
                Button("Trust") { model.trust(files) }.help("mise trust")
            }
        case .failed(let message):
            banner("mise couldn't read this folder: \(message)", color: Extreme.danger) { EmptyView() }
        default:
            EmptyView()
        }
        if env.tools.contains(where: { $0.installed == false }) {
            banner("Some versions this folder asks for aren't installed yet.", color: Extreme.warn) {
                Button("Install with mise") { model.installMissing() }.help("Runs mise install in a new tab")
            }
        }
        if env.mise == .active && !env.miseActivated {
            banner("Your shell doesn't run mise activate, so terminals here don't switch to these versions on their own "
                   + "(agents included). Add eval \"$(mise activate zsh)\" to ~/.zshrc, or run commands with mise exec.",
                   color: Extreme.warn) { EmptyView() }
        }
    }

    private func toolsSection(_ env: FolderEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Tool versions")
            ForEach(env.tools) { tool in
                HStack(spacing: 10) {
                    Text(tool.name).font(Extreme.mono(12)).foregroundColor(Extreme.text).frame(width: 90, alignment: .leading)
                    Text(tool.requested.isEmpty ? "any" : tool.requested).font(Extreme.mono(12)).foregroundColor(Extreme.gold)
                    if let resolved = tool.resolved, resolved != tool.requested {
                        Text("→ \(resolved)").font(Extreme.mono(11)).foregroundColor(Extreme.muted)
                    }
                    if tool.installed == false {
                        Text("not installed").font(Extreme.font(11)).foregroundColor(Extreme.warn)
                    } else if tool.installed == true {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Extreme.live)
                    }
                    Spacer(minLength: 8)
                    if let onPath = tool.onPath {
                        Text("terminal has \(onPath)").font(Extreme.font(11))
                            .foregroundColor(tool.mismatch ? Extreme.warn : Extreme.dim)
                            .help(tool.mismatch ? "Without something switching versions, commands here run \(tool.name) \(onPath)" : "")
                    }
                    Button(tool.source) { model.open(tool.source) }
                        .buttonStyle(.plain).font(Extreme.font(11)).foregroundColor(Extreme.bronze)
                        .help("Show in Finder")
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func variablesSection(_ env: FolderEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Environment variables")
            if let path = env.direnvFile {
                HStack(spacing: 8) {
                    Text("direnv").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                    switch env.direnv {
                    case .allowed:
                        Text("allowed").font(Extreme.font(11)).foregroundColor(Extreme.live)
                        Button("Block") { model.direnv("deny", path) }.help("direnv deny")
                    case .notAllowed:
                        Text("not allowed, so it isn't loaded").font(Extreme.font(11)).foregroundColor(Extreme.warn)
                        if ToolPath.find("direnv") != nil {
                            Button("Allow") { confirmAllow(path) }.help("direnv allow")
                        }
                    case .denied:
                        Text("blocked").font(Extreme.font(11)).foregroundColor(Extreme.danger)
                        Button("Allow") { confirmAllow(path) }.help("direnv allow")
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Button(FolderEnvironmentProbe.display(path, in: model.folder)) { model.open(path) }
                        .buttonStyle(.plain).font(Extreme.font(11)).foregroundColor(Extreme.bronze)
                }
                if ToolPath.find("direnv") == nil {
                    Text("There's an .envrc here, but direnv isn't installed, so nothing loads it.")
                        .font(Extreme.font(11)).foregroundColor(Extreme.warn)
                } else if !env.direnvHooked {
                    Text("Your shell doesn't run direnv hook, so the terminal won't load it on its own.")
                        .font(Extreme.font(11)).foregroundColor(Extreme.warn)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(env.variables) { variable in
                    HStack(spacing: 6) {
                        Text(variable.name).font(Extreme.mono(11.5)).foregroundColor(Extreme.text).lineLimit(1)
                        Text(variable.source).font(Extreme.font(10)).foregroundColor(Extreme.dim).lineLimit(1)
                    }
                }
            }
            Text("Names only: values are never read or shown.").font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
        }
    }

    /// Allowing runs the file's code in every shell that enters the folder: show it first.
    private func confirmAllow(_ path: String) {
        let alert = NSAlert()
        alert.messageText = "Allow this .envrc?"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        alert.informativeText = "direnv will run it every time a terminal enters this folder.\n\n"
            + String(text.prefix(600)) + (text.count > 600 ? "\n…" : "")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.direnv("allow", path) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.folder)
        if panel.runModal() == .OK, let url = panel.url { model.folder = url.path }
    }
}

// MARK: - Containers

private struct ContainersPane: View {
    @ObservedObject var model: ContainersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.runtime {
            case .unknown:
                Text("Asking Docker…").font(Extreme.font(12)).foregroundColor(Extreme.dim)
            case .notInstalled:
                Text("Docker isn't installed. Install Docker Desktop, OrbStack, or Colima (brew install colima docker) to run containers.")
                    .font(Extreme.font(12)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
            case .stopped(let context):
                banner("\(name(context)) isn't running, so there are no containers to show.", color: Extreme.warn) {
                    if model.canStartRuntime { Button("Start \(name(context))") { model.startRuntime() } }
                }
            case .running(let context):
                HStack {
                    Text("\(name(context)) · \(model.containers.filter(\.isRunning).count) running, \(model.containers.count) in all")
                        .font(Extreme.font(12)).foregroundColor(Extreme.muted)
                    Spacer()
                }
                if let error = model.error { banner(error, color: Extreme.danger) { EmptyView() } }
                if model.containers.isEmpty {
                    Text("No containers.").font(Extreme.font(12)).foregroundColor(Extreme.dim)
                }
                ForEach(model.groups, id: \.project) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        ExtremeSectionLabel(group.project.isEmpty ? "Other containers" : group.project)
                        ForEach(group.containers) { container in row(container) }
                    }
                }
            }
        }
    }

    private func name(_ context: String) -> String {
        switch context {
        case let c where c.contains("colima"): return "Colima"
        case let c where c.contains("orbstack"): return "OrbStack"
        case "desktop-linux", "default": return "Docker"
        default: return context
        }
    }

    private func row(_ container: ContainerEntry) -> some View {
        HStack(spacing: 10) {
            Circle().fill(container.unhealthy ? Extreme.danger : container.isRunning ? Extreme.live : Extreme.dim)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(Extreme.mono(12)).foregroundColor(Extreme.text).lineLimit(1)
                Text("\(container.image) · \(container.status)").font(Extreme.font(10.5)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                Button(":\(String(port))") { if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) } }
                    .buttonStyle(.plain).font(Extreme.mono(11)).foregroundColor(Extreme.gold)
                    .help("Open localhost:\(port)")
            }
            if let cpu = container.cpu, let memory = container.memory {
                Text("\(cpu) · \(memory)").font(Extreme.mono(10.5)).foregroundColor(Extreme.muted).frame(width: 130, alignment: .trailing)
            }
            if model.busy.contains(container.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    if container.isRunning {
                        Button("Stop") { model.stop(container) }
                        Button("Restart") { model.restart(container) }
                        Button("Open a Shell Inside") { model.openShell(container) }
                    } else {
                        Button("Start") { model.start(container) }
                    }
                    Button("Show Logs") { model.showLogs(container) }
                    Divider()
                    Button("Remove…") { confirmRemove(container) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(Extreme.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 4)
    }

    private func confirmRemove(_ container: ContainerEntry) {
        let alert = NSAlert()
        alert.messageText = "Remove \(container.name)?"
        alert.informativeText = "The container is deleted (stopped first if it's running). Its image and named volumes stay."
        alert.alertStyle = .warning
        let remove = alert.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { model.remove(container) }
    }
}

// MARK: - Local models

private struct ModelsPane: View {
    @ObservedObject var model: LocalModelsModel
    @State private var pullName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hostRow("Ollama", model.ollama, start: model.startOllama)
            hostRow("LM Studio", model.lmStudio, start: model.startLMStudio)
            if let error = model.error { banner(error, color: Extreme.danger) { EmptyView() } }
            if model.loadedMemory > 0 {
                Text("Loaded models are using \(bytes(model.loadedMemory)) of this Mac's \(bytes(LocalModelsModel.memory)) memory.")
                    .font(Extreme.font(12)).foregroundColor(Extreme.muted)
            }
            ForEach([LocalModel.Host.ollama, .lmStudio], id: \.self) { host in
                let list = model.models.filter { $0.host == host }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ExtremeSectionLabel(host.rawValue)
                        ForEach(list) { row($0) }
                    }
                }
            }
            if case .running = model.ollama {
                HStack(spacing: 8) {
                    TextField("Model to download, e.g. qwen3:8b", text: $pullName, onCommit: pull)
                        .textFieldStyle(.roundedBorder).font(Extreme.mono(11.5)).frame(maxWidth: 320)
                    Button("Pull", action: pull).disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("ollama pull, in a new tab")
                }
            }
        }
    }

    private func hostRow(_ title: String, _ state: LocalModelsModel.HostState, start: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(state == .notInstalled ? Extreme.dim : state == .stopped ? Extreme.warn : Extreme.live).frame(width: 7, height: 7)
            Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
            switch state {
            case .notInstalled:
                Text("not installed").font(Extreme.font(11)).foregroundColor(Extreme.dim)
            case .stopped:
                Text("not running").font(Extreme.font(11)).foregroundColor(Extreme.warn)
                Button("Start", action: start)
            case .running(let version):
                Text(version.map { "running · \($0)" } ?? "running").font(Extreme.font(11)).foregroundColor(Extreme.muted)
            }
            Spacer()
        }
    }

    private func row(_ item: LocalModel) -> some View {
        HStack(spacing: 10) {
            Text(item.name).font(Extreme.mono(12)).foregroundColor(Extreme.text).lineLimit(1)
            if item.loaded {
                Text("LOADED").font(Extreme.font(9, weight: .bold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Extreme.live))
            }
            Text(item.detail).font(Extreme.font(11)).foregroundColor(Extreme.dim).lineLimit(1)
            Spacer(minLength: 8)
            if let memory = item.memory {
                let gpu = Int(((item.gpuShare ?? 0) * 100).rounded())
                Text("\(bytes(memory)) in memory · \(gpu == 100 ? "all on GPU" : "\(gpu)% GPU")")
                    .font(Extreme.font(11)).foregroundColor(Extreme.muted)
            } else if let size = item.size {
                Text(bytes(size)).font(Extreme.font(11)).foregroundColor(Extreme.dim)
            }
            if model.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                if item.loaded { Button("Unload") { model.unload(item) }.help("Free its memory now") }
                Button("Run") { model.run(item) }.help("Chat with it in a new tab")
                if item.host == .ollama {
                    Button("Remove…") { confirmRemove(item) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func pull() {
        model.pull(pullName)
        pullName = ""
    }

    private func confirmRemove(_ item: LocalModel) {
        let alert = NSAlert()
        alert.messageText = "Remove \(item.name)?"
        alert.informativeText = "Ollama deletes it from disk\(item.size.map { ", freeing \(bytes($0))" } ?? ""). Pull it again to get it back."
        alert.alertStyle = .warning
        let remove = alert.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { model.remove(item) }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

// MARK: - Shared

private func banner<Actions: View>(_ text: String, color: Color, @ViewBuilder actions: () -> Actions) -> some View {
    HStack(alignment: .center, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(color)
        Text(text).font(Extreme.font(12)).foregroundColor(Extreme.text).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        actions()
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.1)))
}
#endif

#if os(macOS)
import AppKit
import Combine

/// One of Tellurion's optional features. Everything is on in a fresh install; Settings
/// and the welcome window turn them off. A feature that's off has no menu item, shortcut,
/// button or palette entry, and does no background work.
enum ExtremeFeature: String, CaseIterable, Identifiable {
    case editor
    case visualFix
    case missionControl
    case races
    case localhost
    case review
    case undo
    case commandHistory
    case activity
    case background
    case usage
    case ports
    case git
    case memory
    case sharedMemory
    case skills
    case environment
    case phone
    case localModels
    case menuBar
    case webTiles
    case ink
    case documents
    case diagrams
    case accounts
    case missionMap
    case media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Code editor"
        case .visualFix: return "Visual Fix"
        case .missionControl: return "Mission Control"
        case .races: return "Agent races"
        case .localhost: return "Localhost sessions"
        case .review: return "Review changes"
        case .undo: return "Undo agent turns"
        case .commandHistory: return "Command history"
        case .activity: return "Agent activity"
        case .background: return "Background processes"
        case .usage: return "Usage meter"
        case .ports: return "Ports"
        case .git: return "Git panel"
        case .memory: return "Project memory"
        case .sharedMemory: return "Shared memory"
        case .skills: return "Skills"
        case .environment: return "Environment"
        case .phone: return "Phone"
        case .localModels: return "Local models"
        case .menuBar: return "Menu bar"
        case .webTiles: return "Web tiles"
        case .ink: return "Draw on boards"
        case .documents: return "Documents"
        case .diagrams: return "Diagrams"
        case .accounts: return "Accounts"
        case .missionMap: return "Mission Map"
        case .media: return "Media tiles"
        }
    }

    var detail: String {
        switch self {
        case .editor: return "A VS Code–style editor per tab that follows the agent, with the code map and backend views"
        case .visualFix: return "Preview your dev server beside the terminal and point at what to change"
        case .missionControl: return "Every agent in every window as a live card"
        case .races: return "Give one task to several agents in separate copies and keep the best"
        case .localhost: return "Dev servers agents start open in their own tab and keep running"
        case .review: return "An inbox of each agent's finished changes, with comments and commit"
        case .undo: return "A snapshot before every agent turn, so you can roll a turn back"
        case .commandHistory: return "Every command as a block with its output, and a fix chip when one fails"
        case .activity: return "Active time, prompts, files, tests and tokens per agent"
        case .background: return "Finds dev servers, VMs and agents left running"
        case .usage: return "Your Claude and ChatGPT plan limits in the sidebar"
        case .ports: return "What's listening on which port in the sidebar, with Stop, and who holds a port a command couldn't get"
        case .git: return "Click a tab's branch: switch branches, stashes, recent commits, and its pull request's checks"
        case .memory: return "See, edit and delete what Claude Code and Codex remember about each project"
        case .sharedMemory: return "Codex sessions start with what Claude Code remembers about the project, and Claude Code sessions with what Codex remembers"
        case .skills: return "Every skill your agents have installed, with updates, and what's trending on skills.sh"
        case .environment: return "A folder's tool versions and variables (mise, direnv), your containers, and local models"
        case .phone: return "Use your terminal from your phone over your own private Tailscale network"
        case .localModels: return "Chat with a model on this Mac (Ollama), offline: open it from the sidebar, or drag it under a chat"
        case .menuBar: return "Which agents need you, from the menu bar, with your boards and a new sketch a click away"
        case .webTiles: return "Any website or your dev server in a tile on a board, sandboxed, at real device sizes"
        case .ink: return "A pen and labels straight on a board, over tiles and empty space"
        case .documents: return "Project overviews, guides and references your CLI writes from the code, read-only, with PDF export"
        case .diagrams: return "Architecture and flow diagrams your CLI draws from the project, as editable sketches"
        case .accounts: return "More than one Claude Code or Codex sign-in, and which one each tile uses"
        case .missionMap: return "Who runs whom on a board: orchestrators, groups and every agent's status"
        case .media: return "Video and music files playing in a tile on a board"
        }
    }

    /// The ⌃⌘ shortcut letter, if it has one.
    var shortcut: String? {
        switch self {
        case .editor: return "E"
        case .visualFix: return "V"
        case .missionControl: return "M"
        case .races: return "R"
        case .localhost: return "L"
        case .review: return "I"
        case .commandHistory: return "B"
        case .activity: return "A"
        case .background: return "K"
        case .memory: return "Y"
        case .skills: return "U"
        case .environment: return "N"
        case .undo, .usage, .ports, .git, .sharedMemory, .phone, .localModels, .menuBar,
             .webTiles, .ink, .documents, .diagrams, .accounts, .missionMap, .media: return nil
        }
    }

    var key: String { "ExtremeFeature." + rawValue }
}

/// A starting set of features, offered by the welcome window and Settings.
enum ExtremePreset: String, CaseIterable, Identifiable {
    case everything, essentials, sidebar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .essentials: return "Agent essentials"
        case .sidebar: return "Just the sidebar"
        }
    }

    var detail: String {
        switch self {
        case .everything: return "Every feature on"
        case .essentials: return "Editor, Mission Control, review, undo, localhost, ports, git, memory, skills, environment, usage, phone, local models and the menu bar"
        case .sidebar: return "Vertical tabs with agent status, nothing else"
        }
    }

    var features: Set<ExtremeFeature> {
        switch self {
        case .everything: return Set(ExtremeFeature.allCases)
        case .essentials: return [.editor, .missionControl, .localhost, .review, .undo, .usage, .ports, .git, .memory, .sharedMemory, .skills, .environment, .phone, .localModels, .menuBar]
        case .sidebar: return []
        }
    }
}

/// How much the chrome moves.
enum ExtremeMotionLevel: String, CaseIterable, Identifiable {
    /// The sigil, sprites, glints and the terminal frame's breathing, plus status.
    case full
    /// Only what tells you something: spinners and pulsing status dots.
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .status: return "Status only"
        }
    }
}

/// Tellurion's own settings (Ghostty's are in its config file).
final class ExtremeSettings: ObservableObject {
    static let shared = ExtremeSettings()

    /// Posted on the main thread whenever a feature is turned on or off.
    static let featuresDidChange = Notification.Name("com.steventsvik.ghostty-extreme.featuresDidChange")

    static let motionKey = "ExtremeMotionLevel"

    /// Where the hooks look to see a feature is off (they can't read the app's defaults).
    static var flagsFolder: URL {
        URL(fileURLWithPath: HookInstaller.home).appendingPathComponent(".ghostty-extreme/features", isDirectory: true)
    }

    private init() {}

    /// Whether `feature` is on. Safe from any thread.
    static func isOn(_ feature: ExtremeFeature) -> Bool {
        UserDefaults.standard.object(forKey: feature.key) as? Bool ?? true
    }

    func isOn(_ feature: ExtremeFeature) -> Bool { Self.isOn(feature) }

    func set(_ feature: ExtremeFeature, on: Bool) {
        guard Self.isOn(feature) != on else { return }
        objectWillChange.send()
        // Closed while still on: a feature that's off can close but never open.
        if !on { Self.close(feature) }
        UserDefaults.standard.set(on, forKey: feature.key)
        Self.writeFlags()
        NotificationCenter.default.post(name: Self.featuresDidChange, object: feature)
    }

    func apply(_ preset: ExtremePreset) {
        for feature in ExtremeFeature.allCases { set(feature, on: preset.features.contains(feature)) }
    }

    /// The preset matching the current switches, if any.
    var preset: ExtremePreset? {
        let on = Set(ExtremeFeature.allCases.filter(Self.isOn))
        return ExtremePreset.allCases.first { $0.features == on }
    }

    static var motion: ExtremeMotionLevel {
        ExtremeMotionLevel(rawValue: UserDefaults.standard.string(forKey: motionKey) ?? "") ?? .full
    }

    var motion: ExtremeMotionLevel {
        get { Self.motion }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.motionKey)
        }
    }

    /// Mirrors the switches the hooks need into files. Called at launch and on every change.
    static func writeFlags() {
        let folder = flagsFolder
        for (feature, name) in [(ExtremeFeature.localhost, "localhost-off"), (.sharedMemory, "shared-memory-off")] {
            let flag = folder.appendingPathComponent(name)
            if isOn(feature) {
                try? FileManager.default.removeItem(at: flag)
            } else {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: flag.path, contents: Data())
            }
        }
    }

    /// Closes whatever a feature has open when it's turned off.
    private static func close(_ feature: ExtremeFeature) {
        switch feature {
        case .editor:
            for controller in TerminalWindows.all where EditorPanel.shared.isVisible(controller) {
                EditorPanel.shared.toggle(from: controller)
            }
        case .visualFix:
            for controller in TerminalWindows.all where VisualFixPanel.shared.isVisible(controller) {
                VisualFixPanel.shared.toggle(controller)
            }
        case .commandHistory:
            for controller in TerminalWindows.all where CommandBlocksPanel.shared.isVisible(controller) {
                CommandBlocksPanel.shared.toggle(controller)
            }
        case .missionControl:
            AgentToolWindows.close(id: MissionControl.windowID)
        case .background:
            AgentToolWindows.close(id: Housekeeping.windowID)
        case .localhost:
            AgentToolWindows.close(id: LocalhostSessions.windowID)
        case .review:
            AgentToolWindows.close(id: ReviewInbox.windowID)
        case .activity:
            AgentToolWindows.close(id: ActivityDashboard.windowID)
        case .ports:
            PortsMonitor.shared.dismissConflict()
        case .memory:
            AgentToolWindows.close(id: "memory")
        case .skills:
            AgentToolWindows.close(id: SkillsWindow.windowID)
        case .environment:
            AgentToolWindows.close(id: EnvironmentWindow.windowID)
        case .phone:
            AgentToolWindows.close(id: PhoneSetup.windowID)
            if PhoneServer.shared.running { PhoneServer.shared.turnOff() }
        case .localModels:
            AgentToolWindows.close(id: LocalModelsWindow.windowID)
        case .ink:
            for board in BoardController.all where board.model.tool == .pen || board.model.tool == .eraser { board.model.tool = .select }
        case .webTiles:
            for board in BoardController.all where board.model.tool == .web { board.model.tool = .select }
        case .documents:
            for board in BoardController.all { board.model.showDocuments = false }
        case .missionMap:
            for board in BoardController.all { board.model.showMissionMap = false }
        case .accounts:
            for board in BoardController.all { board.model.showAccounts = false }
        case .races, .undo, .usage, .git, .sharedMemory, .menuBar, .diagrams, .media:
            break
        }
    }
}
#endif

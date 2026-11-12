#if os(macOS)
import AppKit
import Combine

/// One of Tellurion's optional features. Everything is on in a fresh install; Settings
/// and the welcome window turn them off. A feature that's off has no menu item, shortcut,
/// button or palette entry, and does no background work.
enum TellurionFeature: String, CaseIterable, Identifiable {
    case editor
    case visualFix
    case missionControl
    case orchestrator
    case races
    case localhost
    case review
    case undo
    case checks
    case commandHistory
    case activity
    case sessionSearch
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
    case conflicts
    case media
    case budgets
    case smallJobs
    case glasses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Code editor"
        case .visualFix: return "Visual Fix"
        case .missionControl: return "Mission Control"
        case .orchestrator: return "Orchestrator"
        case .races: return "Agent races"
        case .localhost: return "Localhost sessions"
        case .review: return "Review changes"
        case .undo: return "Undo agent turns"
        case .checks: return "Project checks"
        case .commandHistory: return "Command history"
        case .activity: return "Agent activity"
        case .sessionSearch: return "Search sessions"
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
        case .conflicts: return "Conflict radar"
        case .media: return "Media tiles"
        case .budgets: return "Budgets"
        case .smallJobs: return "Small jobs on this Mac"
        case .glasses: return "Glasses"
        }
    }

    var detail: String {
        switch self {
        case .editor: return "A VS Code–style editor per tab that follows the agent, with the code map and backend views"
        case .visualFix: return "Preview your dev server beside the terminal and point at what to change"
        case .missionControl: return "Every agent in every window as a live card"
        case .orchestrator: return "One command for a project's tabs: your own Claude Code or Codex splits the work between the wired agents and follows up"
        case .races: return "Give one task to several agents in separate copies and keep the best"
        case .localhost: return "Dev servers agents start open in their own tab and keep running"
        case .review: return "An inbox of each agent's finished changes, with comments and commit"
        case .undo: return "A snapshot before every agent turn, so you can roll a turn back"
        case .checks: return "When an agent finishes, the project's own check runs, and done means it passed"
        case .commandHistory: return "Every command as a block with its output, and a fix chip when one fails"
        case .activity: return "Active time, prompts, files, tests and tokens per agent"
        case .sessionSearch: return "One search box across every Claude Code and Codex session on this Mac"
        case .background: return "Finds dev servers, VMs and agents left running"
        case .usage: return "Your Claude and ChatGPT plan limits in the sidebar"
        case .ports: return "What's listening on which port in the sidebar, with Stop, and who holds a port a command couldn't get"
        case .git: return "Click a tab's branch: switch branches, stashes, recent commits, and its pull request's checks"
        case .memory: return "See, edit and delete what Claude Code and Codex remember about each project"
        case .sharedMemory: return "Codex sessions start with what Claude Code remembers about the project, and Claude Code sessions with what Codex remembers"
        case .skills: return "Every skill your agents have installed, with updates, and what's trending on skills.sh"
        case .environment: return "A folder's tool versions and variables (mise, direnv), your containers, and local models"
        case .phone: return "Use your terminal from your phone over your own private Tailscale network"
        case .localModels: return "Chat with a model on this Mac (Ollama), offline, or use Venice from your own account: open it from the sidebar, or drag it under a chat"
        case .menuBar: return "Which agents need you, from the menu bar, with your boards and a new sketch a click away"
        case .webTiles: return "Any website or your dev server in a tile on a board, sandboxed, at real device sizes"
        case .ink: return "A pen and labels straight on a board, over tiles and empty space"
        case .documents: return "Project overviews, guides and references your CLI writes from the code, read-only, with PDF export"
        case .diagrams: return "Architecture and flow diagrams your CLI draws from the project, as editable sketches"
        case .accounts: return "More than one Claude Code or Codex sign-in, and which one each tile uses"
        case .missionMap: return "Who runs whom on a board: orchestrators, groups and every agent's status"
        case .conflicts: return "Warns when two agents change the same file in the same folder, and can give each agent of a group its own worktree"
        case .media: return "Video and music files playing in a tile on a board"
        case .budgets: return "A cap on what one agent session may cost at API prices or use in tokens, which pauses the agent when it's reached"
        case .smallJobs: return "Short texts Tellurion asks a model for, such as a commit message, are written by a model on this Mac when one can; the rest go to Claude Code or Codex as before"
        case .glasses: return "Even G2 glasses, through phone access: who needs you, Allow or Deny for a permission prompt, an agent's latest output, and talking to an agent or the orchestrator"
        }
    }

    /// The ⌃⌘ shortcut letter, if it has one.
    var shortcut: String? {
        switch self {
        case .editor: return "E"
        case .visualFix: return "V"
        case .missionControl: return "M"
        case .orchestrator: return "O"
        case .races: return "R"
        case .localhost: return "L"
        case .review: return "I"
        case .commandHistory: return "B"
        case .activity: return "A"
        case .sessionSearch: return nil
        case .background: return "K"
        case .memory: return "Y"
        case .skills: return "U"
        case .environment: return "N"
        case .undo, .checks, .usage, .ports, .git, .sharedMemory, .phone, .localModels, .menuBar,
             .webTiles, .ink, .documents, .diagrams, .accounts, .missionMap, .conflicts, .media, .budgets, .smallJobs, .glasses: return nil
        }
    }

    var key: String { "ExtremeFeature." + rawValue }
}

/// A starting set of features, offered by the welcome window and Settings.
enum TellurionPreset: String, CaseIterable, Identifiable {
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

    var features: Set<TellurionFeature> {
        switch self {
        case .everything: return Set(TellurionFeature.allCases)
        case .essentials: return [.editor, .missionControl, .localhost, .review, .undo, .usage, .ports, .git, .memory, .sharedMemory, .skills, .environment, .phone, .localModels, .menuBar, .glasses]
        case .sidebar: return []
        }
    }
}

/// How much the chrome moves.
enum TellurionMotionLevel: String, CaseIterable, Identifiable {
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
final class TellurionSettings: ObservableObject {
    static let shared = TellurionSettings()

    /// Posted on the main thread whenever a feature is turned on or off.
    static let featuresDidChange = Notification.Name("com.steventsvik.ghostty-extreme.featuresDidChange")

    static let motionKey = "ExtremeMotionLevel"

    /// Where the hooks look to see a feature is off (they can't read the app's defaults).
    static var flagsFolder: URL {
        URL(fileURLWithPath: HookInstaller.home).appendingPathComponent(".ghostty-extreme/features", isDirectory: true)
    }

    private init() {}

    /// Off until you turn them on, whatever the preset: they change where something is done.
    static let optIn: Set<TellurionFeature> = [.smallJobs]

    /// Whether `feature` is on. Safe from any thread.
    static func isOn(_ feature: TellurionFeature) -> Bool {
        UserDefaults.standard.object(forKey: feature.key) as? Bool ?? !optIn.contains(feature)
    }

    func isOn(_ feature: TellurionFeature) -> Bool { Self.isOn(feature) }

    func set(_ feature: TellurionFeature, on: Bool) {
        guard Self.isOn(feature) != on else { return }
        objectWillChange.send()
        // Closed while still on: a feature that's off can close but never open.
        if !on { Self.close(feature) }
        UserDefaults.standard.set(on, forKey: feature.key)
        Self.writeFlags()
        NotificationCenter.default.post(name: Self.featuresDidChange, object: feature)
    }

    func apply(_ preset: TellurionPreset) {
        for feature in TellurionFeature.allCases where !Self.optIn.contains(feature) { set(feature, on: preset.features.contains(feature)) }
    }

    /// The preset matching the current switches, if any.
    var preset: TellurionPreset? {
        let on = Set(TellurionFeature.allCases.filter(Self.isOn)).subtracting(Self.optIn)
        return TellurionPreset.allCases.first { $0.features.subtracting(Self.optIn) == on }
    }

    static var motion: TellurionMotionLevel {
        TellurionMotionLevel(rawValue: UserDefaults.standard.string(forKey: motionKey) ?? "") ?? .full
    }

    var motion: TellurionMotionLevel {
        get { Self.motion }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.motionKey)
        }
    }

    /// Mirrors the switches the hooks need into files. Called at launch and on every change.
    static func writeFlags() {
        for (feature, name) in [(TellurionFeature.localhost, "localhost-off"), (.sharedMemory, "shared-memory-off")] {
            setFlag(name, on: !isOn(feature))
        }
    }

    private static let log = StoredFile.logger("Settings")

    /// A flag file in `flagsFolder`, there or not: how the hooks and `tellurion doctor` read a
    /// switch without asking the app.
    static func setFlag(_ name: String, on: Bool, in folder: URL = flagsFolder) {
        let flag = folder.appendingPathComponent(name)
        if on {
            StoredFile.write(Data(), to: flag, what: "the \(name) flag", log: log)
        } else {
            StoredFile.remove(flag, what: "the \(name) flag", log: log)
        }
    }

    /// Closes whatever a feature has open when it's turned off.
    private static func close(_ feature: TellurionFeature) {
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
        case .orchestrator:
            ClassicOrchestrators.shared.turnedOff()
        case .background:
            AgentToolWindows.close(id: Housekeeping.windowID)
        case .localhost:
            AgentToolWindows.close(id: LocalhostSessions.windowID)
        case .review:
            AgentToolWindows.close(id: ReviewInbox.windowID)
        case .checks:
            AgentToolWindows.close(id: ProjectChecks.windowID)
            AgentToolWindows.close(id: ProjectCheckLog.windowID)
        case .activity:
            AgentToolWindows.close(id: ActivityDashboard.windowID)
        case .sessionSearch:
            AgentToolWindows.close(id: SessionSearch.windowID)
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
        case .budgets:
            AgentToolWindows.close(id: BudgetsWindow.windowID)
        case .glasses:
            GlassesServer.shared.turnedOff()
        case .races, .undo, .usage, .git, .sharedMemory, .menuBar, .diagrams, .conflicts, .media, .smallJobs:
            break
        }
    }
}
#endif

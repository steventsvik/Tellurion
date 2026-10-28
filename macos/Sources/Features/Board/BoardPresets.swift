#if os(macOS)
import AppKit

/// A group you can start again in one go: its name, role, agents (one per slot), first task
/// and whether its agents skip permission prompts. Saved in ~/.ghostty-extreme/presets.json.
struct BoardPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var role: BoardRole
    /// Agent binaries ("claude", "codex", …), or "shell".
    var slots: [String]
    var task: String?
    var skip = false
    /// Built in: can't be deleted.
    var builtIn = false
}

enum BoardPresets {
    static var file: URL { AgentTools.root.appendingPathComponent("presets.json") }

    static let builtIns: [BoardPreset] = [
        BoardPreset(name: "Review squad", role: .reviewers, slots: ["claude", "claude", "claude"],
                    task: "Review the latest changes in this project. Each of you, look for different problems: one for bugs, one for security, one for readability. End with a short list of findings.",
                    builtIn: true),
        BoardPreset(name: "Ship a feature", role: .backend, slots: ["claude", "codex", "codex", "claude"], builtIn: true),
        BoardPreset(name: "Docs crew", role: .docs, slots: ["claude", "claude"],
                    task: "Read this project and improve its documentation where it's missing or out of date.", builtIn: true),
    ]

    /// Built-ins first, then yours.
    static func all() -> [BoardPreset] {
        builtIns + saved()
    }

    static func saved() -> [BoardPreset] {
        guard let data = try? Data(contentsOf: file),
              let presets = try? JSONDecoder().decode([BoardPreset].self, from: data) else { return [] }
        return presets
    }

    static func save(_ preset: BoardPreset) {
        var presets = saved()
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        write(presets)
    }

    static func delete(_ id: UUID) {
        write(saved().filter { $0.id != id })
    }

    private static func write(_ presets: [BoardPreset]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets) else { return }
        try? FileManager.default.createDirectory(at: AgentTools.root, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension BoardController {
    /// Starts a group: one tile per slot laid out as a grid, all in a new named group.
    @discardableResult
    func spawnGroup(name: String, role: BoardRole, slots: [String], folder: String?, task: String?, skip: Bool) -> UUID? {
        let task = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [(agent: BoardAgent?, command: String)] = slots.prefix(12).map { slot in
            guard let agent = BoardAgent.catalog.first(where: { $0.binary == slot }) else { return (nil, "") }
            var line = agent.command(prompt: task?.isEmpty == false ? task : nil)
            if skip, let flag = agent.skipFlag, line.hasPrefix(agent.binary) {
                line = agent.binary + " " + flag + line.dropFirst(agent.binary.count)
            }
            return (agent, line)
        }
        guard !lines.isEmpty else { return nil }
        undoManager?.beginUndoGrouping()
        let views = launch(lines, folder: folder?.isEmpty == false ? folder : nil, skip: skip)
        guard !views.isEmpty else {
            undoManager?.endUndoGrouping()
            return nil
        }
        let id = createGroup(views.map(\.id), name: name, role: role)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Spawn \(name)")
        return id
    }

    func spawnPreset(_ preset: BoardPreset) {
        spawnGroup(name: preset.name, role: preset.role, slots: preset.slots, folder: nil, task: preset.task, skip: preset.skip)
    }

    /// The Presets chip's menu, at the pointer: each preset to spawn, edit or delete.
    func showPresetsMenu() {
        guard let window, let view = window.contentView else { return }
        let menu = NSMenu()
        for preset in BoardPresets.all() {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem("Spawn \(preset.slots.count)", image: nil) { [weak self] in self?.spawnPreset(preset) })
            sub.addItem(ClosureMenuItem("Edit…", image: nil) { [weak self] in
                self?.model.groupComposerPreset = preset
                self?.model.showGroupComposer = true
            })
            if !preset.builtIn {
                sub.addItem(.separator())
                sub.addItem(ClosureMenuItem("Delete", image: nil) { BoardPresets.delete(preset.id) })
            }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Preset…", image: nil) { [weak self] in
            self?.model.groupComposerPreset = nil
            self?.model.showGroupComposer = true
        })
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Spawn 4: four of your default agent, as a team.
    func spawnFour() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let installed = BoardAgent.installed()
            let agent = (installed.first { $0.kind == .claude } ?? installed.first)?.binary ?? "shell"
            DispatchQueue.main.async { [weak self] in
                self?.spawnGroup(name: "Team", role: .general, slots: Array(repeating: agent, count: 4), folder: nil, task: nil, skip: false)
            }
        }
    }
}
#endif

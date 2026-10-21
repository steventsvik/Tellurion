#if os(macOS)
import AppKit
import SwiftUI

/// The Group composer, rising from the bar's Group chip: a name, a role (which colors it), a
/// grid of up to 12 agent slots (click one to change its agent, or fill them all), a folder,
/// a first task, and whether the agents skip permission prompts. Spawn starts them all as a
/// grid inside a new group. Save as Preset keeps the setup for the Presets chip.
struct BoardGroupComposer: View {
    let controller: BoardController
    /// Prefilled from a preset being edited.
    let preset: BoardPreset?
    let done: () -> Void

    @State private var name = "Team"
    @State private var role: BoardRole = .general
    @State private var slots: [Slot] = []
    @State private var installed: [BoardAgent]?
    @State private var folder = ""
    @State private var task = ""
    @State private var skip = false

    private struct Slot: Identifiable, Equatable {
        let id = UUID()
        var agent: String
    }

    private static let limit = 12
    private var color: Color { Color(nsColor: role.nsColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameField
            roleChips
            Divider().overlay(Extreme.line)
            if let installed {
                slotGrid(installed)
                fillAll(installed)
            } else {
                Text("Looking for agents…").font(Extreme.font(11.5)).foregroundColor(Extreme.dim).frame(height: 120)
            }
            Divider().overlay(Extreme.line)
            options
            footer
        }
        .padding(14)
        .frame(width: 400)
        .background(Extreme.panel)
        .onAppear(perform: load)
    }

    // MARK: Parts

    private var nameField: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            TextField("Group name", text: $name)
                .textFieldStyle(.plain)
                .font(Extreme.font(14, weight: .semibold))
                .foregroundColor(Extreme.text)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Extreme.raised))
    }

    private var roleChips: some View {
        let rows = [Array(BoardRole.allCases.prefix(4)), Array(BoardRole.allCases.dropFirst(4))]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(rows[row]) { option in
                        let on = option == role
                        Button {
                            // A role's name replaces a role name or the default, never yours.
                            if BoardRole.allCases.contains(where: { $0.title == name }) || name == "Team" || name.isEmpty {
                                name = option.title
                            }
                            role = option
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color(nsColor: option.nsColor)).frame(width: 6, height: 6)
                                Text(option.title).font(Extreme.font(11, weight: on ? .semibold : .regular))
                            }
                            .foregroundColor(on ? Extreme.text : Extreme.muted)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(on ? Color(nsColor: option.nsColor).opacity(0.18) : .clear))
                            .overlay(Capsule().strokeBorder(on ? Color(nsColor: option.nsColor).opacity(0.6) : Extreme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func slotGrid(_ installed: [BoardAgent]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach($slots) { $slot in
                let agent = installed.first { $0.binary == slot.agent }
                Button {
                    // Each click moves to the next installed agent, then a plain shell.
                    let options = installed.map(\.binary) + ["shell"]
                    let index = options.firstIndex(of: slot.agent) ?? -1
                    slot.agent = options[(index + 1) % options.count]
                } label: {
                    VStack(spacing: 5) {
                        Group {
                            if let agent {
                                VerticalTabAgentLogo(kind: agent.kind, tint: Extreme.text)
                            } else {
                                Image(systemName: "terminal").font(.system(size: 13)).foregroundColor(Extreme.muted)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(agent?.kind.displayName ?? "Shell").font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((agent?.kind.brandColor ?? .gray).opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder((agent?.kind.brandColor ?? .gray).opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Click to change the agent")
                .contextMenu {
                    ForEach(installed) { option in Button(option.kind.displayName) { slot.agent = option.binary } }
                    Button("Shell") { slot.agent = "shell" }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: slots)
    }

    private func fillAll(_ installed: [BoardAgent]) -> some View {
        HStack(spacing: 6) {
            Text("Fill all").font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            ForEach(installed) { agent in
                Button { slots = slots.map { _ in Slot(agent: agent.binary) } } label: {
                    VerticalTabAgentLogo(kind: agent.kind, tint: Extreme.text).frame(width: 14, height: 14)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Extreme.raised))
                }
                .buttonStyle(.plain)
                .help("Make every slot \(agent.kind.displayName)")
            }
            Button { slots = slots.map { _ in Slot(agent: "shell") } } label: {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundColor(Extreme.muted)
                    .frame(width: 24, height: 24).background(Circle().fill(Extreme.raised))
            }
            .buttonStyle(.plain)
            .help("Make every slot a plain terminal")
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10.5)).foregroundColor(Extreme.dim)
                Text(folder.isEmpty ? "Board's folder" : (folder as NSString).abbreviatingWithTildeInPath)
                    .font(Extreme.mono(11)).foregroundColor(Extreme.muted).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…", action: chooseFolder).controlSize(.small)
            }
            TextField("First task for every agent (optional)", text: $task, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Extreme.font(12))
                .lineLimit(1...3)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.raised))
            Toggle(isOn: $skip) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skip permission prompts").font(Extreme.font(11.5, weight: .medium)).foregroundColor(skip ? .red : Extreme.text)
                    if skip {
                        Text("Agents will run commands and change files without asking. Only in folders you trust.")
                            .font(Extreme.font(10.5)).foregroundColor(.red.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                stepperButton("minus", enabled: slots.count > 1) { slots.removeLast() }
                Text("\(slots.count)").font(Extreme.mono(12)).foregroundColor(Extreme.text).frame(width: 26)
                stepperButton("plus", enabled: slots.count < Self.limit) {
                    slots.append(Slot(agent: slots.last?.agent ?? "claude"))
                }
            }
            .background(Capsule().fill(Extreme.raised))
            Button("Save as Preset…", action: savePreset).buttonStyle(.plain)
                .font(Extreme.font(11)).foregroundColor(Extreme.muted)
            Spacer()
            Button("Cancel", action: done).keyboardShortcut(.cancelAction).buttonStyle(.plain)
                .font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            Button(action: spawn) {
                Text("Spawn \(slots.count)").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(color))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(installed == nil || slots.isEmpty)
        }
    }

    private func stepperButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? Extreme.text : Extreme.dim)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Actions

    private func load() {
        folder = controller.workspace.folder ?? ""
        if let preset {
            name = preset.name
            role = preset.role
            task = preset.task ?? ""
            skip = preset.skip
            slots = preset.slots.map { Slot(agent: $0) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = BoardAgent.installed()
            DispatchQueue.main.async {
                installed = found
                if slots.isEmpty {
                    let agent = (found.first { $0.kind == .claude } ?? found.first)?.binary ?? "shell"
                    slots = (0..<6).map { _ in Slot(agent: agent) }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func spawn() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.spawnGroup(name: title.isEmpty ? role.title : title, role: role, slots: slots.map(\.agent),
                              folder: folder, task: task, skip: skip)
        done()
    }

    private func savePreset() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.promptRename("Save as Preset", info: "It appears under Presets in the bar.",
                                current: title.isEmpty ? role.title : title, button: "Save") { presetName in
            var saved = BoardPreset(name: presetName, role: role, slots: slots.map(\.agent),
                                    task: task.isEmpty ? nil : task, skip: skip)
            if let preset, !preset.builtIn { saved.id = preset.id }
            BoardPresets.save(saved)
        }
    }
}
#endif

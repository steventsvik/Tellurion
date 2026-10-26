#if os(macOS)
import AppKit
import SwiftUI

/// The bar at the bottom of a board: tell the board's agent what you want, @mention a tile to
/// talk to its agent directly, or hold Space to speak. Quick actions sit above it, and its
/// answer (and anything waiting for you to confirm) above those.
struct BoardAssistantBar: View {
    let controller: BoardController
    @ObservedObject var assistant: BoardAssistant
    @ObservedObject var model: BoardModel
    @StateObject private var dictation = BoardDictation()
    @State private var text = ""
    @State private var expanded = false
    @State private var showReply = true
    @State private var hint = Self.hints.randomElement() ?? ""
    /// What was typed before dictation started; the words are added after it.
    @State private var spokenAfter: String?
    @AppStorage("BoardAssistantCollapsed") private var collapsed = false
    @AppStorage("BoardAssistantHintsOff") private var hintsOff = false

    static let hints = [
        "start 3 Claude agents, one per kanban card",
        "sketch the backend: API, queue, workers, Postgres",
        "make a kanban for this week's work",
        "set up a writer and a reviewer for the login page",
        "pause every agent",
        "show where the agents are working",
        "tidy the board by project",
    ]

    var body: some View {
        VStack(spacing: 9) {
            if collapsed {
                Spacer(minLength: 0)
                collapsedPill
            } else {
                if expanded {
                    conversation
                } else if showReply, let reply = latest {
                    replyBubble(reply)
                }
                if let pending = assistant.pending { confirmation(pending) }
                if !hintsOff, assistant.messages.isEmpty, !assistant.busy, assistant.pending == nil { hintView }
                chips
                inputBar
                handle
            }
        }
        // Never wider than the board: it shrinks (chips drop out) rather than widen the window.
        .frame(minWidth: 0, maxWidth: 680)
        .padding(.horizontal, 24)
        .padding(.bottom, collapsed ? 14 : 6)
        .background(focusShortcut)
        .onAppear { assistant.lookUp() }
        .onChange(of: assistant.messages.count) { _ in showReply = true }
        .onDisappear { dictation.stop() }
    }

    // MARK: Parts

    /// ⌘L: type to the board's agent.
    private var focusShortcut: some View {
        Button("") { focusField() }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func focusField() {
        if collapsed { collapsed = false }
        DispatchQueue.main.async {
            guard let field = controller.assistantField else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    private var collapsedPill: some View {
        Button(action: focusField) {
            HStack(spacing: 8) {
                BoardAssistantOrb(busy: assistant.busy, listening: dictation.listening).frame(width: 18, height: 18)
                Text("Ask the board").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                Text("⌘L").font(Extreme.font(11)).foregroundColor(Extreme.dim)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Extreme.panel.opacity(0.96)))
            .overlay(Capsule().strokeBorder(Extreme.lineStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the board's agent (⌘L)")
    }

    private var handle: some View {
        Button { collapsed = true; expanded = false } label: {
            Capsule().fill(Extreme.lineStrong).frame(width: 46, height: 5)
                .frame(width: 80, height: 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide the board's agent (⌘L shows it)")
        .accessibilityLabel("Hide the board's agent")
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            BoardAssistantOrb(busy: assistant.busy, listening: dictation.listening)
                .frame(width: 30, height: 30)
                .help(assistant.engine.map { "The board's agent runs \($0.title)" } ?? "")
            BoardAssistantField(text: $text, placeholder: placeholder, controller: controller,
                                onSubmit: submit, onRecall: recall, onHold: { $0 ? startDictation() : dictation.stop() })
                .frame(height: 22)
            if dictation.listening {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("listening").font(Extreme.font(11, weight: .medium)).foregroundColor(.red)
                    BoardWaveform(levels: dictation.levels).frame(width: 56, height: 18)
                }
                .transition(.opacity)
            }
            iconButton(expanded ? "chevron.down" : "chevron.up", expanded ? "Hide the conversation" : "Show the conversation") {
                expanded.toggle()
            }
            if assistant.busy {
                iconButton("stop.fill", "Stop", filled: true) { assistant.stop() }
            } else {
                iconButton("arrow.up", "Send (Return)", filled: !text.trimmingCharacters(in: .whitespaces).isEmpty) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            iconButton(dictation.listening ? "mic.fill" : "mic", dictation.listening ? "Stop listening" : "Speak (or hold Space)",
                       tint: dictation.listening ? Extreme.core : nil) {
                if dictation.listening { dictation.stop() } else { startDictation() }
            }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Extreme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dictation.listening ? Extreme.core.opacity(0.7) : Extreme.lineStrong, lineWidth: dictation.listening ? 1.5 : 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var placeholder: String {
        if dictation.listening { return "Listening…" }
        if assistant.engines?.isEmpty == true { return "@ to direct an agent · install Claude Code or Codex to ask the board" }
        return "Ask the board · hold Space to speak · @ to direct an agent"
    }

    private func iconButton(_ symbol: String, _ help: String, filled: Bool = false, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundColor(filled ? Extreme.ink : (tint ?? Extreme.muted))
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? Extreme.gold : Extreme.raised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(full: true)
            chipRow(full: false)
            EmptyView()
        }
    }

    private func chipRow(full: Bool) -> some View {
        HStack(spacing: 7) {
            chip("New terminal", 0) { controller.addTile() }
            chip("Spawn 4", 1) { controller.spawnFour() }
            chip("Group", 3) {
                model.groupComposerPreset = nil
                model.showGroupComposer = true
            }
            .popover(isPresented: $model.showGroupComposer, arrowEdge: .bottom) {
                BoardGroupComposer(controller: controller, preset: model.groupComposerPreset) {
                    model.showGroupComposer = false
                }
            }
            presetsChip
            chip("Orchestrator", 6) { model.showOrchestratorComposer = true }
            if full { chip("Sketch", 2) { controller.addSketch() } }
            if !model.surfaces.isEmpty {
                if model.paused.isEmpty {
                    chip("Pause all", 4) { controller.setPaused(true) }
                } else {
                    chip("Resume all", 4) { controller.setPaused(false) }
                }
            }
            if full { chip("Agent Map", 5) { controller.showAgentMap() } }
        }
        .fixedSize()
    }

    /// Saved groups to start again: spawn one, edit it in the composer, or delete it.
    private var presetsChip: some View {
        chip("Presets", 8) { controller.showPresetsMenu() }
    }

    private func chip(_ title: String, _ color: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Extreme.panel.opacity(0.95)))
                .overlay(Capsule().strokeBorder(BoardProjects.color(color).opacity(0.75), lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var hintView: some View {
        HStack(spacing: 6) {
            Button {
                text = hint
                focusField()
            } label: {
                (Text("Try ").foregroundColor(Extreme.muted) + Text("“\(hint)”").foregroundColor(Extreme.text).bold())
                    .font(Extreme.font(12))
            }
            .buttonStyle(.plain)
            .help("Use this")
            Button { hintsOff = true } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundColor(Extreme.dim)
            }
            .buttonStyle(.plain)
            .help("Don't show suggestions")
            .accessibilityLabel("Don't show suggestions")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Extreme.panel.opacity(0.9)))
        .overlay(Capsule().strokeBorder(Extreme.line))
    }

    /// The answer to show: what it's working on, or its last reply.
    private var latest: BoardAssistant.Message? {
        if assistant.busy { return nil }
        return assistant.messages.last { $0.role != .user || !$0.done.isEmpty }
    }

    private func replyBubble(_ message: BoardAssistant.Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            messageBody(message)
            Spacer(minLength: 0)
            Button { showReply = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Extreme.dim)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Hide")
            .accessibilityLabel("Hide the answer")
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Extreme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Extreme.line))
    }

    @ViewBuilder
    private func messageBody(_ message: BoardAssistant.Message) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !message.text.isEmpty {
                Text(message.text).font(Extreme.font(12.5, weight: message.role == .user ? .semibold : .regular))
                    .foregroundColor(message.role == .error ? Extreme.danger : Extreme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(message.done.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "checkmark").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Board agent").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                if let engines = assistant.engines, engines.count > 1 {
                    Picker("", selection: Binding(get: { assistant.engine ?? .claude }, set: { assistant.engine = $0 })) {
                        ForEach(engines) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Which agent answers")
                } else if let engine = assistant.engine {
                    Text(engine.title).font(Extreme.font(11)).foregroundColor(Extreme.dim)
                }
                Spacer()
                Button("New Conversation") { assistant.reset() }
                    .buttonStyle(ExtremeButtonStyle())
                    .disabled(assistant.messages.isEmpty && !assistant.busy)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.messages.isEmpty {
                            Text("Ask for agents, cards, sketches or a whole workflow, and the board sets it up. Start with @ and a tile's name to talk to its agent instead.")
                                .font(Extreme.font(12)).foregroundColor(Extreme.muted)
                        }
                        ForEach(assistant.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.role == .user ? "person.fill" : "sparkle")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(message.role == .user ? Extreme.muted : Extreme.core)
                                    .frame(width: 14, height: 16)
                                messageBody(message)
                            }
                            .id(message.id)
                        }
                        if assistant.busy {
                            Text("Working on it…").font(Extreme.font(12)).foregroundColor(Extreme.dim).id("busy")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .onAppear { proxy.scrollTo(assistant.messages.last?.id) }
                .onChange(of: assistant.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Extreme.panel.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Extreme.line))
    }

    private func confirmation(_ pending: BoardAssistant.Pending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.lines.count == 1 ? "Is this OK?" : "Are these OK?")
                .font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
            ForEach(Array(pending.lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "arrow.turn.down.right").font(Extreme.font(12)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { assistant.cancel() }
                    .buttonStyle(ExtremeButtonStyle())
                Button("Do It") { assistant.confirm() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Extreme.panel.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Extreme.warn.opacity(0.6)))
    }

    // MARK: Doing

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !assistant.busy else { return }
        dictation.cancel()
        text = ""
        assistant.send(message)
        hint = Self.hints.randomElement() ?? hint
    }

    /// ↑ in an empty bar: what you last asked.
    private func recall() {
        guard text.isEmpty, let last = assistant.messages.last(where: { $0.role == .user }) else { return }
        text = last.text
    }

    private func startDictation() {
        guard !dictation.listening else { return }
        spokenAfter = text
        var written = text
        dictation.start(update: { words in
            // The last words arrive after stopping; they don't replace what was typed since.
            guard dictation.listening || text == written else { return }
            let before = spokenAfter ?? ""
            text = before.isEmpty ? words : before + " " + words
            written = text
        }, failed: { reason in
            assistant.record(reason)
            showReply = true
        })
    }
}

// MARK: - The waveform

/// The microphone's loudness while dictating: thin bars, newest on the right.
struct BoardWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule().fill(Color.red.opacity(0.85))
                    .frame(width: 1.5, height: max(2, levels[index] * 18))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

// MARK: - The orb

/// The board agent's mark: a disc in the AI's color that turns while it works and swells
/// while it listens. Core Animation, and only while busy or listening.
struct BoardAssistantOrb: NSViewRepresentable {
    var busy: Bool
    var listening: Bool

    func makeNSView(context: Context) -> BoardAssistantOrbView { BoardAssistantOrbView() }

    func updateNSView(_ view: BoardAssistantOrbView, context: Context) {
        view.set(busy: busy, listening: listening)
    }
}

final class BoardAssistantOrbView: NSView {
    private let disc = CAGradientLayer()
    private let shine = CAGradientLayer()
    private var busy = false
    private var listening = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let core = Extreme.chrome.core.nsColor, gold = Extreme.chrome.gold.nsColor
        disc.type = .conic
        disc.startPoint = CGPoint(x: 0.5, y: 0.5)
        disc.endPoint = CGPoint(x: 0.5, y: 0)
        disc.colors = [core, gold, core.withAlphaComponent(0.55), gold.withAlphaComponent(0.8), core].map(\.cgColor)
        shine.type = .radial
        shine.startPoint = CGPoint(x: 0.35, y: 0.7)
        shine.endPoint = CGPoint(x: 1.05, y: 0)
        shine.colors = [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        layer?.addSublayer(disc)
        layer?.addSublayer(shine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [disc, shine] {
            layer.frame = bounds
            layer.cornerRadius = bounds.width / 2
            layer.masksToBounds = true
        }
        CATransaction.commit()
    }

    func set(busy: Bool, listening: Bool) {
        guard busy != self.busy || listening != self.listening else { return }
        self.busy = busy
        self.listening = listening
        let still = ExtremeSettings.motion != .full
        if busy && !still {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 1.4
            spin.repeatCount = .infinity
            disc.add(spin, forKey: "spin")
        } else {
            disc.removeAnimation(forKey: "spin")
        }
        if listening && !still {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.86
            pulse.toValue = 1.0
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "pulse")
        } else {
            layer?.removeAnimation(forKey: "pulse")
        }
        alphaValue = busy || listening ? 1 : 0.85
    }
}

// MARK: - The text field

/// The bar's text field (and an orchestrator's): Return sends, ↑ recalls, Escape goes back to
/// the board, @ lists the tiles, and holding Space in an empty field dictates. Where `onImages`
/// is set, pasting a picture hands it over instead of pasting (see BoardFieldEditor).
struct BoardAssistantField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let controller: BoardController
    /// An orchestrator's field: @ lists only these tiles, and ⌘L stays with the bar.
    var mentions: Set<UUID>?
    /// Takes the pictures pasted into the field, if it takes any.
    var onImages: (([ImageAttachment]) -> Void)?
    let onSubmit: () -> Void
    let onRecall: () -> Void
    let onHold: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = BoardAssistantTextField()
        field.onImages = onImages
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = Extreme.chrome.text.nsColor
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(mentions == nil ? "Ask the board" : "Command the orchestrator")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        if mentions == nil {
            controller.assistantField = field
        } else {
            field.font = .systemFont(ofSize: 12.5)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        (field as? BoardAssistantTextField)?.onImages = onImages
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Extreme.chrome.dim.nsColor, .font: NSFont.systemFont(ofSize: mentions == nil ? 13.5 : 12.5),
        ])
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BoardAssistantField
        weak var field: NSTextField? {
            didSet { installMonitor() }
        }
        private var monitor: Any?
        /// Space is down in an empty field; after a moment it starts dictation.
        private var holding = false
        private var dictating = false
        private var hold: DispatchWorkItem?
        private var lastLength = 0

        init(_ parent: BoardAssistantField) {
            self.parent = parent
        }

        deinit { removeMonitor() }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private var editing: Bool {
            guard let field, let editor = field.currentEditor() else { return false }
            return field.window?.firstResponder === editor
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                // Letting go of Space always counts while holding, even if focus moved away.
                guard let self, event.keyCode == 49, event.window === self.field?.window,
                      self.editing || (event.type == .keyUp && self.holding),
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return event }
                return self.space(event)
            }
        }

        private func space(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyDown {
                if holding { return nil }
                guard field?.stringValue.isEmpty == true, !event.isARepeat else { return event }
                holding = true
                let work = DispatchWorkItem { [weak self] in
                    self?.dictating = true
                    self?.parent.onHold(true)
                }
                hold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                return nil
            }
            guard holding else { return event }
            holding = false
            if dictating {
                dictating = false
                parent.onHold(false)
            } else {
                hold?.cancel()
            }
            return nil
        }

        /// Focus left the bar mid-hold: stop listening rather than wait for a Space that won't come.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard holding else { return }
            holding = false
            hold?.cancel()
            if dictating {
                dictating = false
                parent.onHold(false)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            let value = field.stringValue
            parent.text = value
            defer { lastLength = value.count }
            // Typed "@" at the start or after a space: pick a tile.
            guard value.count == lastLength + 1, let editor = field.currentEditor() as? NSTextView else { return }
            let caret = editor.selectedRange().location
            let string = value as NSString
            guard caret >= 1, string.substring(with: NSRange(location: caret - 1, length: 1)) == "@",
                  caret == 1 || string.substring(with: NSRange(location: caret - 2, length: 1)) == " " else { return }
            showTiles(in: editor, at: caret)
        }

        private func showTiles(in editor: NSTextView, at caret: Int) {
            let only = parent.mentions
            let tiles = parent.controller.tileLabels().filter { only?.contains($0.id) ?? true }
            let groups = only == nil ? parent.controller.model.groups : []
            guard let field, !tiles.isEmpty || !groups.isEmpty else { return }
            let menu = NSMenu()
            // Groups first: @Backend reaches every tile in it.
            for group in groups {
                let item = NSMenuItem(title: group.name, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = group.name
                item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
                item.toolTip = "Every tile in \(group.name) (\(group.tiles.count))"
                menu.addItem(item)
            }
            if !groups.isEmpty, !tiles.isEmpty { menu.addItem(.separator()) }
            for tile in tiles {
                let item = NSMenuItem(title: tile.label, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tile.label
                if let info = VerticalTabsAgents.shared.info(for: tile.surface) {
                    item.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
                    item.toolTip = info.activity.label
                }
                menu.addItem(item)
            }
            let glyph = editor.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
            let inWindow = field.window?.convertPoint(fromScreen: glyph.origin) ?? .zero
            menu.popUp(positioning: nil, at: field.convert(inWindow, from: nil), in: field)
        }

        @objc private func pick(_ item: NSMenuItem) {
            guard let label = item.representedObject as? String, let field,
                  let editor = field.currentEditor() as? NSTextView else { return }
            field.window?.makeFirstResponder(field)
            editor.insertText(label + " ", replacementRange: editor.selectedRange())
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onRecall()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                let board = parent.controller
                if let surface = board.focusedSurface ?? board.model.focused?.value {
                    Ghostty.moveFocus(to: surface)
                } else {
                    control.window?.makeFirstResponder(board.canvas)
                }
                return true
            default:
                return false
            }
        }
    }
}

/// The bar's and the orchestrators' text field; it edits with BoardFieldEditor.
final class BoardAssistantTextField: NSTextField {
    /// Takes the pictures pasted into the field; nil where the field takes text only.
    var onImages: (([ImageAttachment]) -> Void)?
    /// Its field editor, handed to the window when it starts editing.
    private(set) lazy var editor: BoardFieldEditor = {
        let editor = BoardFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    var acceptsImages: Bool { onImages != nil }

    /// The pasteboard's pictures become attachments; true when there were any.
    @discardableResult
    func attach(from pasteboard: NSPasteboard) -> Bool {
        guard let onImages else { return false }
        let images = ImageAttachment.read(from: pasteboard)
        guard !images.isEmpty else { return false }
        onImages(images)
        return true
    }
}

/// The field editor behind BoardAssistantTextField: a pasted picture attaches to a field that
/// takes pictures; text pastes as it always did.
final class BoardFieldEditor: NSTextView {
    /// Tests: how many pastes reached a field editor.
    static var pastes = 0

    override func paste(_ sender: Any?) {
        Self.pastes += 1
        if let field = delegate as? BoardAssistantTextField, field.attach(from: .general) { return }
        super.paste(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), let field = delegate as? BoardAssistantTextField, field.acceptsImages,
           ImageAttachment.mayHoldImages(.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
}

extension BoardController {
    /// The board's fields edit with their own editor (see BoardFieldEditor), so a picture
    /// pasted into an orchestrator's command attaches to it.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? BoardAssistantTextField)?.editor
    }
}
#endif

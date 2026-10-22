#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Sketches on a board: adding and closing them, saving their drawings, and handing them to
/// an agent or to the rest of the Mac (pasteboard, share sheet, PNG files).
extension BoardController {
    static let sketchSize = CGSize(width: 960, height: 620)

    /// A new sketch beside the tile with the cursor, or in the middle of the view; `elements`
    /// starts it with something (pictures dropped on the board); `focus` gives it the keyboard.
    @discardableResult
    func addSketch(elements: [SketchElement] = [], at point: CGPoint? = nil, size: CGSize = BoardController.sketchSize, focus: Bool = true) -> UUID {
        let title = BoardStore.uniqueName("Sketch", taken: Set(model.sketches.map(\.title)))
        let sketch = BoardSketch(id: UUID(), title: title, elements: elements)
        insertSketch(sketch, frame: spot(for: size, at: point))
        undoManager?.registerUndo(withTarget: self) { $0.removeSketch(sketch.id) }
        undoManager?.setActionName("New Sketch")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if focus {
                self.focusSketch(sketch.id)
            } else if let frame = self.model.frames[sketch.id] {
                self.revealRect(frame)
            }
        }
        return sketch.id
    }

    private func insertSketch(_ sketch: BoardSketch, frame: CGRect) {
        model.frames[sketch.id] = frame
        model.sketches.append(sketch)
        if !model.order.contains(sketch.id) { model.order.append(sketch.id) }
        scheduleSave()
    }

    /// Closes a sketch; ⌘Z brings it back.
    func removeSketch(_ id: UUID) {
        guard let index = model.sketches.firstIndex(where: { $0.id == id }) else { return }
        let sketch = model.sketches[index]
        let frame = model.frames[id] ?? .zero
        model.sketches.remove(at: index)
        model.order.removeAll { $0 == id }
        if model.focusedSketch == id { model.focusedSketch = nil }
        undoManager?.registerUndo(withTarget: self) { board in
            board.insertSketch(sketch, frame: frame)
            board.undoManager?.registerUndo(withTarget: board) { $0.removeSketch(id) }
        }
        undoManager?.setActionName("Close Sketch")
        scheduleSave()
    }

    func updateSketch(_ id: UUID, elements: [SketchElement]) {
        guard let index = model.sketches.firstIndex(where: { $0.id == id }),
              model.sketches[index].elements != elements else { return }
        model.sketches[index].elements = elements
        scheduleSave()
    }

    func renameSketch(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = model.sketches.firstIndex(where: { $0.id == id }) else { return }
        model.sketches[index].title = title
        scheduleSave()
    }

    func promptSketchTitle(_ id: UUID) {
        guard let sketch = model.sketches.first(where: { $0.id == id }) else { return }
        promptRename("Rename Sketch", current: sketch.title) { [weak self] text in self?.renameSketch(id, to: text) }
    }

    /// The sketch's view on the board.
    func sketchView(_ id: UUID) -> BoardSketchView? {
        canvas?.documentView?.subviews.lazy.compactMap { $0 as? BoardSketchView }.first { $0.nodeID == id }
    }

    /// Zooms in on a sketch and puts the keyboard in it.
    func focusSketch(_ id: UUID) {
        guard model.frames[id] != nil else { return }
        raise(id: id)
        zoom(toNode: id)
        sketchView(id)?.focusCanvas()
    }

    // MARK: Out to the Mac

    private func picture(_ id: UUID) -> NSImage? {
        guard let sketch = model.sketches.first(where: { $0.id == id }) else { return nil }
        return SketchRenderer.image(of: sketch.elements, images: BoardSketchImages.image,
                                    appearance: window?.effectiveAppearance)
    }

    /// The sketch as a PNG file under ~/.ghostty-extreme/sketches, named after it.
    func exportSketch(_ id: UUID) -> URL? {
        guard let sketch = model.sketches.first(where: { $0.id == id }), let image = picture(id),
              let data = SketchRenderer.png(image) else {
            NSSound.beep()
            return nil
        }
        let folder = AgentTools.root.appendingPathComponent("sketches", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = sketch.title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let file = folder.appendingPathComponent("\(safe.isEmpty ? "sketch" : safe)-\(AgentTools.timestamp()).png")
        return (try? data.write(to: file, options: .atomic)) != nil ? file : nil
    }

    func copySketch(_ id: UUID) {
        guard let image = picture(id) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    func saveSketch(_ id: UUID) {
        guard let window, let sketch = model.sketches.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = sketch.title + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = self?.picture(id),
                  let data = SketchRenderer.png(image) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: To an agent

    /// Asks which agent gets the sketch and what it should do with it, then sends it: typed
    /// into a running agent on this board, or to a new Claude Code or Codex tile beside it.
    func sendSketch(_ id: UUID) {
        guard let window, let sketch = model.sketches.first(where: { $0.id == id }) else { return }
        guard !sketch.elements.isEmpty else {
            NSSound.beep()
            return
        }
        let agents = model.surfaces.filter { surface in
            guard let kind = VerticalTabsAgents.shared.info(for: surface)?.kind else { return false }
            return kind != .hermes && kind != .unknown
        }
        let alert = NSAlert()
        alert.messageText = "Send “\(sketch.title)” to an Agent"
        alert.informativeText = "The agent gets the drawing as a picture, with what you write here."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        let focusedAgent = (focusedSurface ?? model.focused?.value).flatMap { surface in agents.firstIndex { $0 === surface } }
        for surface in agents {
            let info = VerticalTabsAgents.shared.info(for: surface)
            popup.addItem(withTitle: BoardTileTitle.title(surface, info, name: model.titles[surface.id]))
        }
        if !agents.isEmpty { popup.menu?.addItem(.separator()) }
        popup.addItem(withTitle: "New Claude Code tile")
        popup.addItem(withTitle: "New Codex tile")
        popup.selectItem(at: focusedAgent ?? 0)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        field.stringValue = "Build what this sketch shows."
        field.placeholderString = "What should the agent do with it?"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 98)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let file = self.exportSketch(id) else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (text.isEmpty ? "Here's a sketch." : text) + "\n\nThe sketch is the picture at " + file.path
            let choice = popup.indexOfSelectedItem
            if choice < agents.count {
                self.deliver(prompt, to: agents[choice])
            } else {
                let agent: VerticalTabAgentKind = popup.titleOfSelectedItem?.contains("Codex") == true ? .codex : .claude
                self.startAgent(agent, prompt: prompt, near: self.model.frames[id])
            }
        }
    }

    /// Types the prompt into a running agent and submits it (a busy agent queues it).
    func deliver(_ prompt: String, to surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        model.sendText(prompt)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
            model.sendKeyEvent(.init(key: .enter, action: .release))
        }
        TerminalWindows.show(surface)
    }

    /// A new Claude Code or Codex tile beside `near`, started on the prompt.
    @discardableResult
    func startAgent(_ agent: VerticalTabAgentKind, prompt: String, near: CGRect?) -> Ghostty.SurfaceView? {
        guard let file = AgentTools.writePrompt(prompt, folder: "board-prompts", name: "\(AgentTools.timestamp())-\(UUID().uuidString.prefix(6)).md") else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workspace.folder ?? (focusedSurface ?? model.focused?.value)?.pwd
        let frame = freeSpot(size: Self.tileSize, near: near)
        return addTile(config: config, command: AgentTools.agentCommand(agent, promptFile: file), frame: frame)
    }

    // MARK: Dropped on the board

    /// Folders become terminals there; pictures become a sketch; other files open a terminal
    /// in their folder. `point` is in board points.
    func drop(_ urls: [URL], images: [NSImage], at point: CGPoint) -> Bool {
        var pictures = images
        var opened = false
        // Video and audio play in a media tile; Markdown shows as a document.
        let media = urls.filter(BoardMedia.isMedia)
        if !media.isEmpty, addMedia(media, at: point) != nil { opened = true }
        let documents = ExtremeSettings.isOn(.documents)
        for url in urls where documents && url.pathExtension.lowercased() == "md" {
            placeDocument(url, at: point)
            opened = true
        }
        for url in urls where !BoardMedia.isMedia(url) && !(documents && url.pathExtension.lowercased() == "md") {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
                pictures.append(image)
                continue
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = isFolder.boolValue ? url.path : url.deletingLastPathComponent().path
            addTile(config: config, frame: freeSpot(size: Self.tileSize, near: nil, around: point))
            opened = true
        }
        guard !pictures.isEmpty else { return opened }
        let elements = BoardSketchImages.elements(for: pictures, largest: 520, at: CGPoint(x: 40, y: 40))
        guard !elements.isEmpty else { return opened }
        addSketch(elements: elements, at: point)
        return true
    }
}
#endif

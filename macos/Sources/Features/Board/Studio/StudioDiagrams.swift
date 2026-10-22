#if os(macOS)
import AppKit
import SwiftUI

/// Diagrams of a project, drawn by your Claude Code or Codex: pick one (Architecture, User
/// flow…) or describe it; it reads the project (read-only) and answers with boxes, groups and
/// arrows, which become an ordinary sketch on the board, hand-drawn ("Ink") or in color, to
/// edit like any other. Starter shapes give a blank flow, steps, a decision or a mind map.
enum StudioDiagram {
    struct Spec: Decodable {
        struct Group: Decodable { var id: String; var label: String }
        struct Node: Decodable { var id: String; var label: String; var subtitle: String?; var shape: String?; var group: String? }
        struct Edge: Decodable { var from: String; var to: String; var label: String? }
        var title: String?
        var groups: [Group]?
        var nodes: [Node]
        var edges: [Edge]?
    }

    static let presets: [(title: String, ask: String)] = [
        ("Architecture", "the project's architecture: its main parts and how they talk to each other"),
        ("User flow", "the main user flow through the app, screen by screen or step by step"),
        ("Data flow", "how data moves through the project, from where it comes in to where it's stored or shown"),
        ("Components", "the main components and modules, grouped by layer, and which uses which"),
        ("Request lifecycle", "the lifecycle of a request, from the client through the server and back"),
        ("State flow", "the main states and the transitions between them"),
    ]

    static let instructions = """
    You draw diagrams of the software project in the current folder. You can read its files \
    (read-only); look at what you need first. Answer with JSON only, no other text:
    {"title": "...", "groups": [{"id": "g1", "label": "CLIENT"}], \
    "nodes": [{"id": "n1", "label": "Browser", "subtitle": "visitor", "shape": "rectangle", "group": "g1"}], \
    "edges": [{"from": "n1", "to": "n2", "label": "requests"}]}
    shape is rectangle, ellipse (people and outside systems), diamond (decisions) or database. \
    Use real names from the project (files, modules, services) as labels, with a short \
    subtitle. Groups are optional (layers or areas, uppercase labels). Keep it readable: \
    6 to 16 nodes, edge labels of one or two words.
    """

    /// A blank starting point, no model needed.
    static func starter(_ name: String) -> Spec {
        func node(_ id: String, _ label: String, _ shape: String = "rectangle") -> Spec.Node {
            Spec.Node(id: id, label: label, subtitle: nil, shape: shape, group: nil)
        }
        switch name {
        case "Steps":
            return Spec(title: "Steps", groups: nil, nodes: (1...4).map { node("s\($0)", "Step \($0)") },
                        edges: (1...3).map { Spec.Edge(from: "s\($0)", to: "s\($0 + 1)", label: nil) })
        case "Decision branch":
            return Spec(title: "Decision", groups: nil,
                        nodes: [node("a", "Start"), node("d", "Question?", "diamond"), node("y", "If yes"), node("n", "If no")],
                        edges: [.init(from: "a", to: "d", label: nil), .init(from: "d", to: "y", label: "yes"), .init(from: "d", to: "n", label: "no")])
        case "Mind map":
            return Spec(title: "Mind map", groups: nil, nodes: [node("c", "Idea", "ellipse")] + (1...5).map { node("t\($0)", "Topic \($0)") },
                        edges: (1...5).map { Spec.Edge(from: "c", to: "t\($0)", label: nil) })
        default:
            return Spec(title: "Flow", groups: nil, nodes: [node("a", "Start", "ellipse"), node("b", "Do this"), node("c", "Then this"), node("d", "Done", "ellipse")],
                        edges: [.init(from: "a", to: "b", label: nil), .init(from: "b", to: "c", label: nil), .init(from: "c", to: "d", label: nil)])
        }
    }

    static let box = CGSize(width: 210, height: 88)
    static let gap = CGSize(width: 140, height: 44)
    static let margin: CGFloat = 48
    /// Between one group's band and the next (room for the frame and its label).
    static let bandGap: CGFloat = 86

    /// Where each box goes: columns follow the arrows (a box sits right of what points at
    /// it), and each group has a band of rows to itself, so group frames never overlap.
    static func layout(_ nodes: [Spec.Node], _ edges: [Spec.Edge], groups: [Spec.Group]) -> [String: CGRect] {
        var column: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for _ in 0..<nodes.count {
            var changed = false
            for edge in edges where edge.from != edge.to {
                let next = (column[edge.from] ?? 0) + 1
                if next > (column[edge.to] ?? 0), next < nodes.count {
                    column[edge.to] = next
                    changed = true
                }
            }
            if !changed { break }
        }
        let bands = groups.map { Optional($0.id) } + [nil]
        var frames: [String: CGRect] = [:]
        var y = margin
        for band in bands {
            let known = Set(groups.map(\.id))
            let members = nodes.filter { band == nil ? !($0.group.map(known.contains) ?? false) : $0.group == band }
            guard !members.isEmpty else { continue }
            var rowsUsed = 0
            for c in Set(members.compactMap { column[$0.id] }).sorted() {
                let inColumn = members.filter { column[$0.id] == c }
                for (row, node) in inColumn.enumerated() {
                    frames[node.id] = CGRect(x: margin + CGFloat(c) * (box.width + gap.width),
                                             y: y + CGFloat(row) * (box.height + gap.height), width: box.width, height: box.height)
                }
                rowsUsed = max(rowsUsed, inColumn.count)
            }
            y += CGFloat(rowsUsed) * (box.height + gap.height) - gap.height + bandGap
        }
        return frames
    }

    /// The sketch's elements: boxes with subtitles, group frames behind them, arrows with
    /// labels, and a title, hand-drawn ("Ink") or in color.
    static func elements(_ spec: Spec, ink: Bool) -> (elements: [SketchElement], size: CGSize) {
        var seen = Set<String>()
        let nodes = spec.nodes.filter { seen.insert($0.id).inserted }
        let ids = Set(nodes.map(\.id))
        let edges = (spec.edges ?? []).filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
        let groups = (spec.groups ?? []).filter { group in nodes.contains { $0.group == group.id } }
        let groupColor = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, [1, 5, 3, 6, 2, 4][$0 % 6]) })
        let frames = layout(nodes, edges, groups: groups)
        let top: CGFloat = spec.title?.isEmpty == false ? 70 : 0
        func shifted(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: top) }
        var elements: [SketchElement] = []
        // Group frames first, so they sit behind their boxes.
        for group in groups {
            let members = nodes.filter { $0.group == group.id }.compactMap { frames[$0.id] }
            guard let first = members.first else { continue }
            let area = shifted(members.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -24, dy: -22))
            let outline = CGRect(x: area.minX, y: area.minY - 28, width: area.width, height: area.height + 28)
            elements.append(SketchElement(kind: .rectangle, frame: outline, color: ink ? 7 : groupColor[group.id] ?? 7, width: 1.5,
                                          opacity: 0.8, dashed: true, hand: ink ? true : nil))
            elements.append(SketchElement(kind: .text, frame: CGRect(x: outline.minX + 12, y: outline.minY + 6, width: max(outline.width - 24, 80), height: 22),
                                          color: ink ? 0 : groupColor[group.id] ?? 7, text: group.label.uppercased(),
                                          font: ink ? "hand" : "sans", fontSize: 0))
        }
        var boxIDs: [String: UUID] = [:]
        for node in nodes {
            guard let frame = frames[node.id] else { continue }
            let kind = SketchElement.Kind(rawValue: node.shape ?? "").flatMap { $0.isBox && $0 != .image && $0 != .text ? $0 : nil } ?? .rectangle
            let color = ink ? 0 : node.group.flatMap { groupColor[$0] } ?? (kind == .database ? 1 : 0)
            let element = SketchElement(kind: kind, frame: shifted(frame), color: color, text: node.label,
                                        font: ink ? "hand" : nil, subtitle: node.subtitle, hand: ink ? true : nil)
            boxIDs[node.id] = element.id
            elements.append(element)
        }
        for edge in edges {
            guard let from = frames[edge.from].map(shifted), let to = frames[edge.to].map(shifted) else { continue }
            let a = CGPoint(x: from.midX, y: from.midY), b = CGPoint(x: to.midX, y: to.midY)
            elements.append(SketchElement(kind: .arrow, points: [a, b], width: 2, start: boxIDs[edge.from], end: boxIDs[edge.to],
                                          font: ink ? "hand" : nil, hand: ink ? true : nil))
            if let label = edge.label, !label.isEmpty {
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                elements.append(SketchElement(kind: .text, frame: CGRect(x: middle.x - 60, y: middle.y - 26, width: 120, height: 22),
                                              width: 1.5, text: label, font: ink ? "hand" : nil, fontSize: 0, align: "center"))
            }
        }
        if let title = spec.title, !title.isEmpty {
            elements.insert(SketchElement(kind: .text, frame: CGRect(x: margin, y: 22, width: 760, height: 44), color: 0, text: title,
                                          font: ink ? "hand" : "sans", fontSize: 2), at: 0)
        }
        let bounds = elements.reduce(CGRect.null) { $0.union($1.frame) }
        return (elements, CGSize(width: max(BoardController.sketchSize.width, bounds.maxX + margin),
                                 height: max(BoardController.sketchSize.height, bounds.maxY + margin)))
    }
}

/// The Diagrams popover's state, and the drawing in progress.
final class StudioDiagrams: ObservableObject {
    @Published var engine: HeadlessAgent.Engine = .claude
    @Published var ink = true
    @Published var describe = ""
    /// The sketch being drawn, while a model works on it.
    @Published private(set) var drawing: UUID?
    @Published private(set) var error: String?
    private var process: Process?

    weak var board: BoardController?

    func generate(_ ask: String, title: String) {
        guard let board, drawing == nil, let project = board.documentsProject else { return }
        error = nil
        // A placeholder sketch at once: three faint boxes until the real one arrives.
        let skeleton = (0..<3).map { index in
            SketchElement(kind: .rectangle, frame: CGRect(x: 60 + CGFloat(index) * 260, y: 140, width: 200, height: 84), color: 7,
                          opacity: 0.35, dashed: true)
        }
        let id = board.addSketch(elements: skeleton, at: nil, size: BoardController.sketchSize, focus: false)
        board.renameSketch(id, to: "\(title) (drawing…)")
        drawing = id
        let ink = self.ink
        process = HeadlessAgent.stream(engine, instructions: StudioDiagram.instructions, prompt: "Draw " + ask + ".",
                                       folder: project, model: "sonnet", progress: { _, _ in }, done: { [weak self, weak board] result in
            guard let self, let board else { return }
            self.drawing = nil
            self.process = nil
            switch result {
            case .success(let text):
                guard let data = HeadlessAgent.object(in: text), let spec = try? JSONDecoder().decode(StudioDiagram.Spec.self, from: data),
                      !spec.nodes.isEmpty else {
                    self.error = "The answer wasn't a diagram. Try again."
                    self.discard(id)
                    return
                }
                let drawn = StudioDiagram.elements(spec, ink: ink)
                // The real sketch where the placeholder was (the placeholder isn't undoable).
                let at = board.model.frames[id].map { CGPoint(x: $0.minX + drawn.size.width / 2, y: $0.minY + drawn.size.height / 2) }
                self.discard(id)
                let real = board.addSketch(elements: drawn.elements, at: at, size: drawn.size, focus: false)
                board.renameSketch(real, to: spec.title ?? title)
                board.zoom(toNode: real)
            case .failure(let failure):
                self.error = failure.localizedDescription
                self.discard(id)
            }
        })
    }

    /// Removes the placeholder without an undo step.
    private func discard(_ id: UUID) {
        board?.undoManager?.disableUndoRegistration()
        board?.removeSketch(id)
        board?.undoManager?.enableUndoRegistration()
    }

    func cancel() {
        process?.terminate()
    }

    /// A starter shape, at once.
    func starter(_ name: String) {
        guard let board else { return }
        let drawn = StudioDiagram.elements(StudioDiagram.starter(name), ink: ink)
        let id = board.addSketch(elements: drawn.elements, at: nil, size: drawn.size, focus: true)
        board.renameSketch(id, to: name)
    }
}

/// The Diagrams popover, from the right-hand palette.
struct StudioDiagramsPanel: View {
    @ObservedObject var diagrams: StudioDiagrams
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Model")
            HStack(spacing: 6) {
                ForEach(HeadlessAgent.Engine.allCases) { engine in
                    Button { diagrams.engine = engine } label: {
                        HStack(spacing: 5) {
                            VerticalTabAgentLogo(kind: engine.kind, tint: Extreme.text).frame(width: 12, height: 12)
                            Text(engine.title).font(Extreme.font(11.5, weight: .medium)).foregroundColor(Extreme.text)
                        }
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(Capsule().strokeBorder(diagrams.engine == engine ? Extreme.core : Extreme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            label("Style")
            Picker("", selection: $diagrams.ink) {
                Text("Ink").tag(true)
                Text("Colorful").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            label("From your project")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(StudioDiagram.presets, id: \.title) { preset in
                    Button {
                        diagrams.generate(preset.ask, title: preset.title)
                        close()
                    } label: {
                        Text(preset.title).font(Extreme.font(11.5, weight: .medium)).foregroundColor(Extreme.text)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                    }
                    .buttonStyle(.plain)
                    .disabled(diagrams.drawing != nil)
                }
            }
            HStack(spacing: 6) {
                TextField("Describe a diagram…", text: $diagrams.describe).textFieldStyle(.plain).font(Extreme.font(12))
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                Button("Generate") {
                    let ask = diagrams.describe.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !ask.isEmpty else { return }
                    diagrams.generate(ask, title: "Diagram")
                    close()
                }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
                .disabled(diagrams.describe.trimmingCharacters(in: .whitespaces).isEmpty || diagrams.drawing != nil)
            }
            if let error = diagrams.error { Text(error).font(Extreme.font(11)).foregroundColor(.red) }
            label("Starter shapes")
            HStack(spacing: 6) {
                ForEach(["Flow", "Steps", "Decision branch", "Mind map"], id: \.self) { name in
                    Button {
                        diagrams.starter(name)
                        close()
                    } label: {
                        Text(name).font(Extreme.font(11)).foregroundColor(Extreme.text)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
    }
}

/// "● Claude is drawing ×" on the board while a diagram is drawn.
struct StudioDrawingPill: View {
    @ObservedObject var diagrams: StudioDiagrams

    var body: some View {
        if diagrams.drawing != nil {
            HStack(spacing: 8) {
                Circle().fill(Extreme.core).frame(width: 7, height: 7)
                Text("\(diagrams.engine == .claude ? "Claude" : "Codex") is drawing").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                Button { diagrams.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Extreme.muted)
                }
                .buttonStyle(.plain)
                .help("Stop drawing")
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(Extreme.panel.opacity(0.97)))
            .overlay(Capsule().strokeBorder(Extreme.lineStrong))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
    }
}
#endif

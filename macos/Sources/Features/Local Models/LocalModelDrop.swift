#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A local model dropped on a terminal pane opens below it, in the pane's folder.
struct LocalModelDropDelegate: DropDelegate {
    @Binding var over: Bool
    let surface: Ghostty.SurfaceView

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.tellurionLocalModel])
    }

    func dropEntered(info: DropInfo) { over = true }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func dropExited(info: DropInfo) { over = false }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        guard let provider = info.itemProviders(for: [.tellurionLocalModel]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.tellurionLocalModel.identifier) { [weak surface] data, _ in
            guard let data, let dragged = String(bytes: data, encoding: .utf8), !dragged.isEmpty else { return }
            DispatchQueue.main.async {
                guard let surface, let controller = surface.window?.windowController as? BaseTerminalController else { return }
                // "<host>\t<name>", as the sidebar row wrote it.
                let parts = dragged.split(separator: "\t", maxSplits: 1).map(String.init)
                let host = parts.count == 2 ? LocalModel.Host(rawValue: parts[0]) ?? .ollama : .ollama
                let name = parts.last ?? dragged
                let model = LocalModelsModel.shared.models.first { $0.host == host && $0.name == name }
                    ?? LocalModel(host: host, name: name, size: nil, detail: "", loaded: false, memory: nil, gpuShare: nil)
                LocalModelSessions.open(model, below: surface, in: controller)
            }
        }
        return true
    }
}

/// Where the model will open: the bottom half of the pane, labeled.
struct LocalModelDropPreview: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    Rectangle().fill(Tellurion.gold.opacity(0.16))
                    Rectangle().strokeBorder(Tellurion.gold.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    Label("Open below this chat", systemImage: "rectangle.split.1x2")
                        .font(Tellurion.font(12, weight: .semibold))
                        .foregroundColor(Tellurion.gold)
                }
                .frame(height: geometry.size.height / 2)
            }
        }
    }
}
#endif

#if os(macOS)
/// Makes a sidebar model row clickable and draggable onto a terminal pane. AppKit, not
/// SwiftUI's onDrag: in Tellurion's windows a press on the sidebar would otherwise go to the
/// window's drag-to-move handler before SwiftUI sees it (the same reason Ghostty's pane grab
/// handle is an AppKit view).
struct LocalModelDragSource: NSViewRepresentable {
    let payload: String
    let title: String
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.payload = payload
        view.title = title
        view.onClick = onClick
        view.onHover = onHover
        view.toolTip = "Click to chat with \(title) below the chat in front (or in a new tab).\n"
            + "Drag it onto a chat to open it underneath that one."
    }

    final class SourceView: NSView, NSDraggingSource {
        var payload = ""
        var title = ""
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        private var dragged = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Taken here so the window doesn't start moving; a drag or a click follows.
        override func mouseDown(with event: NSEvent) { dragged = false }

        override func mouseUp(with event: NSEvent) {
            if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged else { return }
            dragged = true
            let item = NSPasteboardItem()
            item.setData(Data(payload.utf8), forType: NSPasteboard.PasteboardType(UTType.tellurionLocalModel.identifier))
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = Self.chip(title)
            let point = convert(event.locationInWindow, from: nil)
            dragging.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                             width: image.size.width, height: image.size.height), contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .copy : []
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        /// The drag image: the model's name on a small dark chip.
        private static func chip(_ title: String) -> NSImage {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = NSSize(width: text.size().width + 24, height: 26)
            return NSImage(size: size, flipped: false) { rect in
                NSColor(white: 0.12, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                text.draw(at: NSPoint(x: 12, y: (rect.height - text.size().height) / 2))
                return true
            }
        }
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// A part of the terminal window that the Layout window arranges.
enum LayoutBox: String, CaseIterable, Identifiable {
    case tabs, terminal, editor, visualFix, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabs: return "Tabs"
        case .terminal: return "Terminal"
        case .editor: return "Code editor"
        case .visualFix: return "Visual Fix"
        case .history: return "Command history"
        }
    }

    var detail: String {
        switch self {
        case .tabs: return "The sidebar"
        case .terminal: return "Your agents and shells"
        case .editor: return "Opens with ⌃⌘E"
        case .visualFix: return "Opens with ⌃⌘V"
        case .history: return "Opens with ⌃⌘B"
        }
    }

    var symbol: String {
        switch self {
        case .tabs: return "sidebar.left"
        case .terminal: return "terminal"
        case .editor: return PixelIcon.code.symbol
        case .visualFix: return PixelIcon.target.symbol
        case .history: return "list.bullet.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .tabs: return Tellurion.bronze
        case .terminal: return Tellurion.core
        case .editor: return Tellurion.gold
        case .visualFix: return Tellurion.live
        case .history: return Tellurion.muted
        }
    }

    /// The setting that turns it on, for the parts that can be off.
    var feature: TellurionFeature? {
        switch self {
        case .tabs, .terminal: return nil
        case .editor: return .editor
        case .visualFix: return .visualFix
        case .history: return .commandHistory
        }
    }

    /// Its share of the width in the Layout window's map.
    var weight: CGFloat {
        switch self {
        case .tabs: return 1.3
        case .terminal: return 3
        case .editor: return 2.6
        case .visualFix: return 2.3
        case .history: return 1.6
        }
    }
}

/// The left-to-right order of every terminal window's parts.
final class WindowLayout: ObservableObject {
    static let shared = WindowLayout()
    static let key = "WindowLayoutOrder"
    static let standard: [LayoutBox] = [.tabs, .terminal, .editor, .visualFix, .history]

    struct Template: Identifiable {
        let name: String
        let detail: String
        let order: [LayoutBox]
        var id: String { name }
    }

    static let templates: [Template] = [
        Template(name: "Classic", detail: "Tabs, the terminal, then the editor", order: standard),
        Template(name: "Editor first", detail: "The editor beside the tabs, the terminal on the right",
                 order: [.tabs, .editor, .visualFix, .terminal, .history]),
        Template(name: "Tabs on the right", detail: "The terminal first, the tabs at the far right",
                 order: [.terminal, .editor, .visualFix, .history, .tabs]),
        Template(name: "Mirrored", detail: "Classic, flipped: the editor left, the tabs right",
                 order: [.history, .visualFix, .editor, .terminal, .tabs]),
    ]

    @Published private(set) var order: [LayoutBox]

    private init() {
        let saved = (UserDefaults.standard.string(forKey: Self.key) ?? "")
            .split(separator: ",").compactMap { LayoutBox(rawValue: String($0)) }
        order = Self.complete(saved)
    }

    /// Every part exactly once; any a saved order lacks go at the end.
    static func complete(_ boxes: [LayoutBox]) -> [LayoutBox] {
        var seen = Set<LayoutBox>()
        let unique = boxes.filter { seen.insert($0).inserted }
        return unique + standard.filter { !seen.contains($0) }
    }

    func set(_ newOrder: [LayoutBox]) {
        let complete = Self.complete(newOrder)
        guard complete != order else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { order = complete }
        if complete == Self.standard {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(complete.map(\.rawValue).joined(separator: ","), forKey: Self.key)
        }
    }

    /// Whether `box` is left of the terminal, so it grows the window leftward and its
    /// resize handle is on its right edge.
    func isLeftOfTerminal(_ box: LayoutBox) -> Bool {
        (order.firstIndex(of: box) ?? 0) < (order.firstIndex(of: .terminal) ?? 0)
    }

    static func isLeftOfTerminal(_ box: LayoutBox) -> Bool { shared.isLeftOfTerminal(box) }
}

/// The 1pt line between a column and the terminal side. The terminal and the editor's web
/// view take the mouse right up to their edges, so the handle also takes a few points of
/// its own on the terminal side, where it can always be grabbed.
struct ColumnResizeHandle: View {
    let color: Color
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// On the column's right edge, so dragging right widens it.
    let onTrailingEdge: Bool
    @State private var startWidth: Double?
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .frame(width: 5, alignment: onTrailingEdge ? .leading : .trailing)
            .overlay(
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // Keep push/pop balanced so the cursor stack never leaks.
                        if inside, !cursorPushed {
                            NSCursor.resizeLeftRight.push()
                            cursorPushed = true
                        } else if !inside, cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    .gesture(
                        // Measured in the window, not the handle, which moves as the column resizes.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                let delta = onTrailingEdge ? value.translation.width : -value.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }))
    }
}

extension NSWindow {
    /// Grows (or, with a negative `delta`, shrinks) the window on one side, keeping the
    /// other side where it is so the terminal doesn't move on screen.
    func grow(by delta: CGFloat, onLeft: Bool, animate: Bool) {
        guard !styleMask.contains(.fullScreen) else { return }
        var frame = self.frame
        frame.size.width = max(frame.width + delta, minSize.width)
        if onLeft { frame.origin.x -= frame.width - self.frame.width }
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.width > visible.width { frame.size.width = visible.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        }
        setFrame(frame, display: true, animate: animate)
    }
}
#endif

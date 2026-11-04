#if os(macOS)
import AppKit
import SwiftUI

/// The Layout window: a map of the terminal window whose parts you drag into a new
/// order, and templates to start from. Every terminal window follows it.
enum LayoutWindow {
    static let windowID = "layout"

    static func show() {
        AgentToolWindows.show(id: windowID, title: "Layout", size: NSSize(width: 780, height: 560)) {
            LayoutWindowView()
        }
    }
}

struct LayoutWindowView: View {
    @ObservedObject private var layout = WindowLayout.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                TellurionWindowTitle(icon: .layout, title: "Layout",
                                   subtitle: "Drag a box to a new spot. Every window follows.")
                Spacer()
                Button("Reset") { layout.set(WindowLayout.standard) }
                    .buttonStyle(TellurionButtonStyle())
                    .disabled(layout.order == WindowLayout.standard)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 14)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                LayoutMap()
                    .frame(height: 230)
                TellurionSectionLabel("Templates")
                HStack(spacing: 10) {
                    ForEach(WindowLayout.templates) { template in
                        LayoutTemplateCard(template: template, selected: layout.order == template.order) {
                            layout.set(template.order)
                        }
                    }
                }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
    }
}

/// The window drawn small, one box per part. Dragging a box moves the others aside; letting
/// go applies the order.
private struct LayoutMap: View {
    @ObservedObject private var layout = WindowLayout.shared
    @ObservedObject private var settings = TellurionSettings.shared
    @State private var draft: [LayoutBox] = WindowLayout.shared.order
    @State private var dragging: LayoutBox?
    /// The dragged box's center, following the pointer.
    @State private var dragX: CGFloat = 0
    /// Where in the box the pointer took hold.
    @State private var grab: CGFloat = 0

    private let inset: CGFloat = 12
    private let gap: CGFloat = 8
    private let titlebar: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let frames = slots(draft, width: geometry.size.width)
            let height = geometry.size.height - titlebar - inset * 2
            ZStack(alignment: .topLeading) {
                windowChrome
                ForEach(draft) { box in
                    let slot = frames[box] ?? (0, 0)
                    LayoutBoxCard(box: box, on: box.feature.map(settings.isOn) ?? true,
                                  lifted: dragging == box, canMoveLeft: draft.first != box,
                                  canMoveRight: draft.last != box) { step in
                        move(box, by: step)
                    }
                    .frame(width: slot.width, height: height)
                    .position(x: dragging == box ? dragX : slot.center, y: titlebar + inset + height / 2)
                    .zIndex(dragging == box ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("layoutMap"))
                            .onChanged { value in
                                if dragging != box {
                                    grab = value.startLocation.x - slot.center
                                    withAnimation(.easeOut(duration: 0.12)) { dragging = box }
                                }
                                // Kept inside the map.
                                dragX = min(max(value.location.x - grab, inset + slot.width / 2),
                                            geometry.size.width - inset - slot.width / 2)
                                reorder(box, width: geometry.size.width)
                            }
                            .onEnded { _ in
                                let order = draft
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragging = nil }
                                layout.set(order)
                            })
                }
            }
            .coordinateSpace(name: "layoutMap")
        }
        .onChange(of: layout.order) { order in
            guard dragging == nil else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { draft = order }
        }
    }

    private var windowChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(Tellurion.ink)
            shape.strokeBorder(Tellurion.lineStrong, lineWidth: 1)
            HStack(spacing: 6) {
                ForEach([Color(rgb: 0xFF5F57), Color(rgb: 0xFEBC2E), Color(rgb: 0x28C840)], id: \.self) {
                    Circle().fill($0.opacity(0.75)).frame(width: 9, height: 9)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 10)
        }
    }

    /// Each part's center and width for `order` in a map `width` wide.
    private func slots(_ order: [LayoutBox], width: CGFloat) -> [LayoutBox: (center: CGFloat, width: CGFloat)] {
        let room = width - inset * 2 - gap * CGFloat(max(0, order.count - 1))
        let total = order.map(\.weight).reduce(0, +)
        var x = inset
        var result: [LayoutBox: (CGFloat, CGFloat)] = [:]
        for box in order {
            let boxWidth = room * box.weight / total
            result[box] = (x + boxWidth / 2, boxWidth)
            x += boxWidth + gap
        }
        return result
    }

    /// Puts the dragged box in whichever spot is nearest the pointer.
    private func reorder(_ box: LayoutBox, width: CGFloat) {
        let others = draft.filter { $0 != box }
        let best = (0...others.count).min { lhs, rhs in
            distance(inserting: box, at: lhs, into: others, width: width)
                < distance(inserting: box, at: rhs, into: others, width: width)
        } ?? 0
        var candidate = others
        candidate.insert(box, at: best)
        guard candidate != draft else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draft = candidate }
    }

    private func distance(inserting box: LayoutBox, at index: Int, into others: [LayoutBox], width: CGFloat) -> CGFloat {
        var order = others
        order.insert(box, at: index)
        return abs((slots(order, width: width)[box]?.center ?? 0) - dragX)
    }

    /// Moves a box one spot left (-1) or right (+1), from its menu.
    private func move(_ box: LayoutBox, by step: Int) {
        guard let index = draft.firstIndex(of: box) else { return }
        let target = index + step
        guard draft.indices.contains(target) else { return }
        var order = draft
        order.swapAt(index, target)
        layout.set(order)
    }
}

private struct LayoutBoxCard: View {
    let box: LayoutBox
    /// False when its feature is turned off in Settings.
    let on: Bool
    let lifted: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let move: (Int) -> Void
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: box.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(box.tint)
            Text(box.title)
                .font(Tellurion.font(11.5, weight: .semibold))
                .foregroundColor(Tellurion.text)
                .multilineTextAlignment(.center)
            Text(on ? box.detail : "Off in Settings")
                .font(Tellurion.font(9.5))
                .foregroundColor(Tellurion.muted)
                .multilineTextAlignment(.center)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(lifted ? Tellurion.raised : Tellurion.panel))
        .overlay(alignment: .top) {
            Capsule().fill(box.tint.opacity(0.8)).frame(height: 3).padding(.horizontal, 14).padding(.top, 6)
        }
        .overlay(shape.strokeBorder(lifted || hovering ? box.tint.opacity(0.7) : Tellurion.line, lineWidth: 1))
        .opacity(on ? 1 : 0.5)
        .scaleEffect(lifted ? 1.05 : 1)
        .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: lifted ? 14 : 0, y: lifted ? 8 : 0)
        .contentShape(shape)
        .onHover { inside in
            hovering = inside
            // Keep push/pop balanced so the cursor stack never leaks.
            if inside, !cursorPushed {
                NSCursor.openHand.push()
                cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed { NSCursor.pop() }
        }
        .contextMenu {
            Button("Move Left") { move(-1) }.disabled(!canMoveLeft)
            Button("Move Right") { move(1) }.disabled(!canMoveRight)
        }
        .help("Drag to move \(box.title.lowercased()), or right-click to move it one spot")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A template: a small picture of its order, its name and what it's for.
private struct LayoutTemplateCard: View {
    let template: WindowLayout.Template
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geometry in
                    let total = template.order.map(\.weight).reduce(0, +)
                    let room = geometry.size.width - 2 * CGFloat(template.order.count - 1)
                    HStack(spacing: 2) {
                        ForEach(template.order) { box in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(box.tint.opacity(box == .terminal ? 0.55 : 0.35))
                                .frame(width: room * box.weight / total)
                        }
                    }
                }
                .frame(height: 34)
                Text(template.name)
                    .font(Tellurion.font(11.5, weight: .semibold))
                    .foregroundColor(selected ? Tellurion.gold : Tellurion.text)
                Text(template.detail)
                    .font(Tellurion.font(9.5))
                    .foregroundColor(Tellurion.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 112, alignment: .top)
            .background(shape.fill(hovering ? Tellurion.raised : Tellurion.panel))
            .overlay(shape.strokeBorder(selected ? Tellurion.gold.opacity(0.7) : (hovering ? Tellurion.lineStrong : Tellurion.line),
                                        lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif

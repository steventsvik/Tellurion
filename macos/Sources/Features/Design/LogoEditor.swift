#if os(macOS)
import SwiftUI

/// Draw your own logo: a 32×32 grid painted with the design's color roles, so the mark
/// recolors with the design. Mirror paints both halves at once.
struct LogoEditorView: View {
    @Binding var logo: DesignLogo
    let chrome: ChromeColors
    var done: () -> Void

    @State private var role: DesignLogo.Role = .gold
    @State private var erasing = false
    @State private var mirror = true
    @State private var undo: [[String]] = []
    @State private var stroking = false

    private let cell: CGFloat = 13
    private var side: CGFloat { cell * CGFloat(DesignLogo.size) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: .design, title: "Draw your logo",
                                   subtitle: "Click or drag to paint. Pixels are roles, so the logo follows the design's colors.")
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                canvas
                VStack(alignment: .leading, spacing: 14) {
                    TellurionSectionLabel("Paint")
                    roles
                    HStack(spacing: 8) {
                        toggleButton("Eraser", on: erasing, icon: "eraser") { erasing.toggle() }
                        toggleButton("Mirror", on: mirror, icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { mirror.toggle() }
                    }
                    TellurionSectionLabel("Edit")
                    HStack(spacing: 8) {
                        Button("Undo") { if let last = undo.popLast() { logo.rows = last } }.disabled(undo.isEmpty)
                        Button("Clear") { push(); logo.rows = DesignLogo.blank.rows }.disabled(logo.isEmpty)
                        Menu("Start from…") {
                            ForEach(DesignLogo.starters, id: \.title) { starter in
                                Button(starter.title) { push(); logo.rows = starter.logo.rows }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    TellurionSectionLabel("Preview")
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach([16, 32, 64] as [CGFloat], id: \.self) { size in
                            PixelBitmap(rows: logo.rows, colors: logo.colors(in: chrome), pixel: size / CGFloat(DesignLogo.size))
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chrome.ink.color))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(chrome.line.color, lineWidth: 1))
                        }
                        Image(nsImage: DesignStore.dockIcon(logo: logo, chrome: chrome, size: 256))
                            .resizable().frame(width: 72, height: 72)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button("Done", action: done).buttonStyle(TellurionButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                }
                .frame(width: 300)
            }
            .padding(20)
        }
        .frame(width: side + 300 + 60, height: side + 200)  // the controls column is taller than the canvas
        .tellurionWindow()
    }

    private var canvas: some View {
        Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(chrome.ink.color))
            let colors = logo.colors(in: chrome)
            for (y, row) in logo.rows.enumerated() {
                for (x, char) in row.enumerated() {
                    guard char != ".", let color = colors[char] else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)), with: .color(color))
                }
            }
            var grid = Path()
            for i in 0...DesignLogo.size {
                let p = CGFloat(i) * cell
                grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: side))
                grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: side, y: p))
            }
            context.stroke(grid, with: .color(chrome.line.color.opacity(0.6)), lineWidth: 0.5)
            if mirror {
                var axis = Path()
                axis.move(to: CGPoint(x: side / 2, y: 0)); axis.addLine(to: CGPoint(x: side / 2, y: side))
                context.stroke(axis, with: .color(chrome.gold.color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(width: side, height: side)
        .overlay(Rectangle().strokeBorder(chrome.lineStrong.color, lineWidth: 1))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !stroking { push(); stroking = true }
                    paint(at: value.location)
                }
                .onEnded { _ in stroking = false })
        .accessibilityLabel("Logo canvas")
    }

    private var roles: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(DesignLogo.Role.allCases) { candidate in
                let selected = candidate == role && !erasing
                Button {
                    role = candidate
                    erasing = false
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(candidate.color(in: chrome).color)
                            .frame(width: 18, height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Tellurion.line, lineWidth: 1))
                        Text(candidate.title).font(Tellurion.font(11.5)).foregroundColor(selected ? Tellurion.gold : Tellurion.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Tellurion.raised : Tellurion.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Tellurion.gold.opacity(0.6) : Tellurion.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleButton(_ title: String, on: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Tellurion.font(11.5))
                .foregroundColor(on ? Tellurion.gold : Tellurion.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Tellurion.raised : Tellurion.panel))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Tellurion.gold.opacity(0.6) : Tellurion.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func push() {
        undo.append(logo.rows)
        if undo.count > 60 { undo.removeFirst() }
    }

    private func paint(at point: CGPoint) {
        let x = Int(point.x / cell), y = Int(point.y / cell)
        guard (0..<DesignLogo.size).contains(x), (0..<DesignLogo.size).contains(y) else { return }
        let char: Character = erasing ? "." : role.rawValue
        logo.set(x, y, to: char)
        if mirror { logo.set(DesignLogo.size - 1 - x, y, to: char) }
    }
}
#endif

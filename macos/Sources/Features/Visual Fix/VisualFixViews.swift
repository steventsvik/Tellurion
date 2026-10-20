#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// A tab's Visual Fix panel as placed in its window: a resize handle and the panel.
struct VisualFixColumn: View {
    let controller: BaseTerminalController
    var maxWidth: CGFloat = .infinity
    @AppStorage(VisualFixPanel.widthKey) private var width: Double = VisualFixPanel.defaultWidth
    @ObservedObject private var layout = WindowLayout.shared

    var body: some View {
        // The handle is on the side facing the terminal.
        let left = layout.isLeftOfTerminal(.visualFix)
        let handle = ColumnResizeHandle(color: Extreme.gold.opacity(0.35), width: $width,
                                        range: 360...max(360, min(1800, Double(maxWidth))), onTrailingEdge: left)
        HStack(spacing: 0) {
            if !left { handle }
            VisualFixPanelView(session: VisualFixPanel.shared.session(for: controller), controller: controller)
                .frame(width: min(CGFloat(width), maxWidth))
            if left { handle }
        }
        .transition(.move(edge: left ? .leading : .trailing).combined(with: .opacity))
    }
}

struct VisualFixPanelView: View {
    @ObservedObject var session: VisualFixSession
    let controller: BaseTerminalController

    var body: some View {
        VStack(spacing: 0) {
            VisualFixToolbar(session: session, controller: controller)
            VisualFixHint(session: session)
            ZStack {
                if session.url == nil {
                    VisualFixEmptyState(session: session)
                        .transition(.opacity)
                } else {
                    VisualFixStage(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.requests.isEmpty {
                VisualFixRequestList(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Extreme.ink)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.requests.isEmpty)
    }
}

// MARK: - Toolbar

private struct VisualFixToolbar: View {
    @ObservedObject var session: VisualFixSession
    let controller: BaseTerminalController
    @ObservedObject private var localhost = LocalhostSessions.shared

    var body: some View {
        // Narrow panels drop the title and labels so the controls stay readable.
        ViewThatFits(in: .horizontal) {
            bar(wide: true)
            bar(wide: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Extreme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Extreme.line).frame(height: 1) }
    }

    private func bar(wide: Bool) -> some View {
        HStack(spacing: 6) {
            if wide {
                HStack(spacing: 7) {
                    PixelIconView(icon: .target, color: Extreme.gold, pixel: 1.6)
                    Text("Visual Fix").font(Extreme.font(13, weight: .semibold)).foregroundColor(Extreme.gold).fixedSize()
                }
                .padding(.trailing, 4)
            }
            ExtremeIconButton(icon: .target, label: "Pick", help: "Point at things on the page (click to choose one)",
                              active: session.picking) {
                session.setPicking(!session.picking)
            }
            appButton
            ExtremeIconButton(icon: .restart, help: "Reload the page (⌘R)") { session.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                ForEach(VisualFixDevice.allCases) { device in
                    ExtremeIconButton(icon: device.icon, help: "\(device.name) · \(Int(device.width))px wide",
                                      active: session.device == device) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { session.device = device }
                    }
                }
            }
            ExtremeIconButton(icon: .close, label: wide ? "Close" : nil, help: "Close Visual Fix (⌃⌘V)") {
                VisualFixPanel.shared.hide(controller)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Which running app is shown; click for the others.
    private var appButton: some View {
        let port = session.url?.port.map { ":\($0)" } ?? ""
        let name = localhost.sessions.first { $0.url?.port == session.url?.port }?.project.name
        return Button {
            showAppMenu()
        } label: {
            HStack(spacing: 6) {
                PixelDot(color: session.loadError == nil ? Extreme.live : Extreme.danger, size: 5)
                Text(name ?? "localhost").font(Extreme.font(10.5)).foregroundColor(Extreme.text).lineLimit(1).fixedSize()
                Text(verbatim: port).font(Extreme.font(10.5)).foregroundColor(Extreme.gold).fixedSize()
                PixelIconView(icon: .chevronDown, color: Extreme.muted, pixel: 1)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Extreme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose which running app to preview")
        .opacity(session.url == nil ? 0 : 1)
    }

    private func showAppMenu() {
        let menu = NSMenu()
        let live = localhost.sessions.filter { $0.url != nil && $0.isRunning }
        for app in live {
            guard let url = app.url else { continue }
            let item = ClosureMenuItem("\(app.project.name)  —  localhost:\(url.port ?? 80)", image: nil) { session.load(url) }
            item.state = url.port == session.url?.port ? .on : .off
            menu.addItem(item)
        }
        let others = localhost.others.filter { other in !live.contains { $0.ports.contains(other.ports.first ?? -1) } }
        if !others.isEmpty {
            if !live.isEmpty { menu.addItem(.separator()) }
            for other in others {
                guard let url = other.url else { continue }
                menu.addItem(ClosureMenuItem("\(other.displayName)  —  localhost:\(url.port ?? 80)", image: nil) { session.load(url) })
            }
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No running apps", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        if let url = session.url {
            menu.addItem(ClosureMenuItem("Open in Browser", image: nil) { NSWorkspace.shared.open(url) })
        }
        menu.addItem(ClosureMenuItem("Localhost Manager…", image: nil) { LocalhostManager.show() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// One line saying what to do next, changing as you go.
private struct VisualFixHint: View {
    @ObservedObject var session: VisualFixSession

    var body: some View {
        let (text, color): (String, Color) = {
            if session.url == nil { return ("Start your app to point at things in it", Extreme.muted) }
            if session.loadError != nil { return ("The app isn't answering", Extreme.danger) }
            if session.selection != nil { return ("Say what should change, then press Return to send it", Extreme.core) }
            if session.picking { return ("Hover anything in your app, then click it to fix it", Extreme.gold) }
            return ("Browsing freely. Turn on PICK to point at something", Extreme.muted)
        }()
        HStack(spacing: 8) {
            PixelDot(color: color, blinking: session.picking && session.selection == nil, size: 5, interval: 0.6)
            Text(text).font(Extreme.font(10.5)).foregroundColor(color)
                .id(text)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            Spacer()
            if session.loading { PixelSpinner(color: Extreme.gold, pixel: 2) }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Extreme.raised.opacity(0.6))
        .overlay(alignment: .bottom) {
            if session.loading {
                PixelActivityBar(color: Extreme.gold, pixel: 2)
            } else {
                Rectangle().fill(Extreme.line).frame(height: 1)
            }
        }
        .clipped()
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: text)
    }
}

// MARK: - Stage

/// The page, sized for the chosen device, with everything drawn over it.
private struct VisualFixStage: View {
    @ObservedObject var session: VisualFixSession

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(size: geometry.size, device: session.device)
            ZStack(alignment: .topLeading) {
                VisualFixBackdrop()
                // The device frame.
                RoundedRectangle(cornerRadius: layout.corner)
                    .fill(Extreme.panel)
                    .overlay(RoundedRectangle(cornerRadius: layout.corner).strokeBorder(Extreme.lineStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
                    .frame(width: layout.page.width + layout.bezel * 2, height: layout.page.height + layout.bezel * 2)
                    .offset(x: layout.page.minX - layout.bezel, y: layout.page.minY - layout.bezel)
                VisualFixWebViewHost(webView: session.webView, zoom: layout.zoom)
                    .frame(width: layout.page.width, height: layout.page.height)
                    .clipShape(RoundedRectangle(cornerRadius: max(0, layout.corner - layout.bezel)))
                    .offset(x: layout.page.minX, y: layout.page.minY)
                VisualFixOverlay(session: session, page: layout.page, zoom: layout.zoom, stage: geometry.size)
                if let error = session.loadError {
                    VisualFixUnreachable(message: error) { session.reload() }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                Text(verbatim: "\(Int(session.device.width)) px · \(Int(layout.zoom * 100))%")
                    .font(Extreme.font(9)).kerning(1).foregroundColor(Extreme.dim)
                    .offset(x: layout.page.minX, y: layout.page.maxY + layout.bezel + 4)
            }
            .onAppear { session.zoom = layout.zoom }
            .onChange(of: layout.zoom) { session.zoom = $0 }
        }
        .clipped()
    }

    /// Where the page goes: as wide as the device (scaled down to fit), centered.
    struct Layout: Equatable {
        let page: CGRect
        let zoom: CGFloat
        let corner: CGFloat
        let bezel: CGFloat

        init(size: CGSize, device: VisualFixDevice) {
            let margin: CGFloat = device == .desktop ? 12 : 22
            let bezel: CGFloat = device == .desktop ? 1 : 6
            let available = max(120, size.width - margin * 2 - bezel * 2)
            let zoom = min(1, available / device.width)
            let width = device.width * zoom
            let height = max(120, size.height - margin * 2 - bezel * 2 - 16)
            page = CGRect(x: (size.width - width) / 2, y: margin + bezel, width: width, height: height)
            self.zoom = zoom
            self.bezel = bezel
            corner = device == .phone ? 26 : device == .tablet ? 16 : 4
        }
    }
}

/// A faint pixel grid behind the page.
private struct VisualFixBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 16
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Extreme.lineStrong.opacity(0.5)))
                    x += step
                }
                y += step
            }
        }
        .background(Extreme.ink)
    }
}

private struct VisualFixUnreachable: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            PixelIconView(icon: .globe, color: Extreme.danger, pixel: 3)
            Text(message).font(Extreme.font(12)).foregroundColor(Extreme.text).multilineTextAlignment(.center)
            Button("Try Again", action: retry).buttonStyle(ExtremeButtonStyle(prominent: true))
        }
        .padding(24)
        .extremePanel()
    }
}

// MARK: - Overlay

/// The hover outline, the chosen element, pins for sent requests and the composer, drawn
/// over the page in the stage's coordinates.
private struct VisualFixOverlay: View {
    @ObservedObject var session: VisualFixSession
    let page: CGRect
    let zoom: CGFloat
    let stage: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Everything but the composer and pins lets the pointer through to the page.
            ZStack(alignment: .topLeading) {
                if session.picking, let hover = session.hover, !isSelection(hover.rect) {
                    HoverBox(label: hover.label, rect: place(hover.rect))
                }
                if let rect = session.selectionRect {
                    SelectionBox(rect: place(rect))
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                }
                ForEach(session.requests) { request in
                    if let rect = request.rect, request.state != .done {
                        PinOutline(state: request.state, rect: place(rect))
                    }
                    if request.id == session.justFinished, let rect = request.rect ?? Optional(request.element.rect) {
                        DoneSweep(rect: place(rect))
                    }
                }
            }
            .frame(width: page.width, height: page.height, alignment: .topLeading)
            .offset(x: page.minX, y: page.minY)
            .clipped()
            .allowsHitTesting(false)

            ForEach(session.requests) { request in
                if let rect = request.rect, request.state != .done {
                    let spot = place(rect)
                    PinBadge(request: request)
                        .position(x: page.minX + max(10, spot.minX), y: page.minY + max(10, spot.minY))
                        .onTapGesture { session.reveal(request) }
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }

            if let element = session.selection, let rect = session.selectionRect {
                let spot = place(rect).offsetBy(dx: page.minX, dy: page.minY)
                VisualFixComposer(session: session, element: element, number: nextNumber)
                    .frame(width: composerWidth)
                    .position(composerCenter(for: spot))
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                    .id(element.selector)
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: session.hover)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.selectionRect)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: session.requests)
    }

    private var nextNumber: Int { (session.requests.map(\.id).max() ?? 0) + 1 }
    private let composerWidth: CGFloat = 340
    private let composerHeight: CGFloat = 250

    private func place(_ css: CGRect) -> CGRect {
        CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
    }

    private func isSelection(_ rect: CGRect) -> Bool { session.selectionRect.map { $0 == rect } ?? false }

    /// Below the element when there's room, otherwise above it, kept on the stage.
    private func composerCenter(for spot: CGRect) -> CGPoint {
        let x = min(max(spot.midX, composerWidth / 2 + 8), stage.width - composerWidth / 2 - 8)
        let below = spot.maxY + 14 + composerHeight / 2
        let above = spot.minY - 14 - composerHeight / 2
        var y = below + composerHeight / 2 < stage.height ? below : above
        if y - composerHeight / 2 < 8 { y = min(stage.height - composerHeight / 2 - 8, max(composerHeight / 2 + 8, spot.midY)) }
        return CGPoint(x: x, y: y)
    }
}

/// The element under the pointer: a gold outline that glides from element to element.
private struct HoverBox: View {
    let label: String
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Extreme.gold.opacity(0.09))
                .overlay(Rectangle().strokeBorder(Extreme.gold, lineWidth: 2))
                .shadow(color: Extreme.gold.opacity(0.55), radius: 6)
                .frame(width: max(4, rect.width), height: max(4, rect.height))
                .offset(x: rect.minX, y: rect.minY)
            Text(label)
                .font(Extreme.font(9.5))
                .foregroundColor(Extreme.ink)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Extreme.gold)
                .fixedSize()
                .offset(x: max(0, rect.minX), y: rect.minY > 18 ? rect.minY - 17 : rect.maxY + 2)
        }
    }
}

/// The chosen element: marching cyan outline with pixel corner brackets.
private struct SelectionBox: View {
    let rect: CGRect

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = CGFloat(context.date.timeIntervalSinceReferenceDate * 18).truncatingRemainder(dividingBy: 12)
            ZStack {
                Rectangle().fill(Extreme.core.opacity(0.08))
                Rectangle().strokeBorder(Extreme.core, style: StrokeStyle(lineWidth: 2, dash: [6, 6], dashPhase: -phase))
                Brackets(color: Extreme.core)
                    .padding(-6)
            }
            .shadow(color: Extreme.core.opacity(0.6), radius: 8)
        }
        .frame(width: max(4, rect.width), height: max(4, rect.height))
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Corner brackets, like the terminal's frame.
private struct Brackets: View {
    let color: Color
    var length: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let t: CGFloat = 3
            let w = size.width, h = size.height
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] {
                let ox = dx > 0 ? x : x - t, oy = dy > 0 ? y : y - t
                context.fill(Path(CGRect(x: dx > 0 ? ox : x - length, y: oy, width: length, height: t)), with: .color(color))
                context.fill(Path(CGRect(x: ox, y: dy > 0 ? oy : y - length, width: t, height: length)), with: .color(color))
            }
        }
    }
}

/// A sent request's element while the agent works on it.
private struct PinOutline: View {
    let state: VisualFixRequest.State
    let rect: CGRect

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let pulse = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4)
            let color = color
            Rectangle()
                .strokeBorder(color.opacity(state == .working ? 0.45 + 0.55 * pulse : 0.7),
                              style: StrokeStyle(lineWidth: 1.5, dash: state == .queued ? [3, 4] : []))
                .background(color.opacity(state == .working ? 0.04 + 0.06 * pulse : 0.03))
        }
        .frame(width: max(4, rect.width), height: max(4, rect.height))
        .offset(x: rect.minX, y: rect.minY)
    }

    private var color: Color {
        switch state {
        case .queued: return Extreme.gold
        case .working: return Extreme.core
        case .needsYou: return Extreme.warn
        case .done: return Extreme.live
        }
    }
}

/// The request's number on its element, with what's happening to it.
private struct PinBadge: View {
    let request: VisualFixRequest

    var body: some View {
        HStack(spacing: 4) {
            Text("\(request.id)").font(Extreme.font(10.5))
            switch request.state {
            case .queued: PixelDot(color: Extreme.ink, blinking: true, size: 4, interval: 0.4)
            case .working: PixelSpinner(color: Extreme.ink, pixel: 1.8)
            case .needsYou: Text("!").font(Extreme.font(10.5))
            case .done: EmptyView()
            }
        }
        .foregroundColor(Extreme.ink)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.ink.opacity(0.5), lineWidth: 1))
        .shadow(color: background.opacity(0.8), radius: 6)
        .help(request.text)
    }

    private var background: Color {
        switch request.state {
        case .queued: return Extreme.gold
        case .working: return Extreme.core
        case .needsYou: return Extreme.warn
        case .done: return Extreme.live
        }
    }
}

/// The change landed: a green light sweeps across the element.
private struct DoneSweep: View {
    let rect: CGRect
    @State private var progress: CGFloat = -0.3

    var body: some View {
        ZStack {
            Rectangle().strokeBorder(Extreme.live, lineWidth: 2)
            GeometryReader { geometry in
                LinearGradient(colors: [Extreme.live.opacity(0), Extreme.live.opacity(0.45), Extreme.live.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(30, geometry.size.width * 0.35))
                    .offset(x: progress * geometry.size.width)
            }
            .clipped()
        }
        .shadow(color: Extreme.live.opacity(0.7), radius: 10)
        .frame(width: max(4, rect.width), height: max(4, rect.height))
        .offset(x: rect.minX, y: rect.minY)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatCount(2, autoreverses: false)) { progress = 1.1 }
        }
    }
}

// MARK: - Composer

/// Say what should change about the chosen element, and send it.
private struct VisualFixComposer: View {
    @ObservedObject var session: VisualFixSession
    let element: VisualFixElement
    let number: Int
    @State private var draft = ""
    @State private var newAgent: VerticalTabAgentKind = .claude
    @FocusState private var focused: Bool

    private static let suggestions = ["Make it bigger", "Fix the spacing", "Fix it on mobile", "Match our brand colors",
                                      "Center it", "Remove it"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("#\(number)")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Extreme.core)
                Text(element.label).font(Extreme.font(11)).foregroundColor(Extreme.text).lineLimit(1)
                Spacer(minLength: 4)
                smallButton("↑ Parent", help: "Choose the element around this one") { session.selectParent() }
                smallButton("✕", help: "Cancel (Esc)") { session.cancelSelection() }
            }
            if let path = element.componentPath ?? element.source {
                HStack(spacing: 5) {
                    PixelIconView(icon: .code, color: Extreme.core, pixel: 1)
                    Text(element.source.map { path == $0 ? $0 : "\(path) · \(shortSource($0))" } ?? path)
                        .font(Extreme.font(9.5)).foregroundColor(Extreme.core).lineLimit(1).truncationMode(.middle)
                }
            }
            if !element.text.isEmpty {
                Text("“\(element.text)”").font(Extreme.font(10)).foregroundColor(Extreme.muted).lineLimit(1)
            }

            TextField("What should change?", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Extreme.font(12))
                .foregroundColor(Extreme.text)
                .lineLimit(2...4)
                .focused($focused)
                .padding(8)
                .background(Extreme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Extreme.gold : Extreme.lineStrong, lineWidth: 1))
                .onSubmit(send)

            WrappingChips(items: Self.suggestions) { suggestion in
                draft = draft.isEmpty ? suggestion : draft.trimmingCharacters(in: .whitespaces) + ". " + suggestion
                focused = true
            }

            HStack(spacing: 8) {
                target
                Spacer(minLength: 4)
                Button(action: send) {
                    HStack(spacing: 6) {
                        if session.sending { PixelSpinner(color: Extreme.ink, pixel: 1.6) }
                        Text("Send  ⏎")
                    }
                }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.sending)
            }
        }
        .padding(12)
        .background(Extreme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.gold.opacity(0.8), lineWidth: 1))
        .overlay(Brackets(color: Extreme.gold, length: 8).padding(-3).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.65), radius: 18, y: 8)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { session.cancelSelection() }
    }

    /// Who gets it: the agent running in the tab, or the one to start.
    @ViewBuilder
    private var target: some View {
        if let surface = session.targetSurface, let info = VerticalTabsAgents.shared.info(for: surface) {
            let otherTab = session.isInAnotherTab(surface)
            HStack(spacing: 6) {
                AgentSprite(kind: info.kind, pixel: 1.2)
                Text("to \(info.kind.displayName)").font(Extreme.font(10)).foregroundColor(Extreme.text)
                if let project = session.projectName {
                    Text("· \(project)").font(Extreme.font(10)).foregroundColor(Extreme.gold).lineLimit(1)
                }
                if otherTab {
                    Text("· other tab").font(Extreme.font(10)).foregroundColor(Extreme.muted)
                }
                if info.activity == .working {
                    Text("· queued").font(Extreme.font(10)).foregroundColor(Extreme.muted)
                }
            }
            .help((session.projectRoot.map { "The agent working in \(($0 as NSString).abbreviatingWithTildeInPath)" }
                   ?? "The agent in this tab")
                  + (otherTab ? ", in another tab" : "")
                  + (info.activity == .working ? ". It's busy; this is queued for when it's done." : "."))
        } else {
            HStack(spacing: 4) {
                Text("start").font(Extreme.font(10)).foregroundColor(Extreme.muted)
                if let project = session.projectName {
                    Text("in \(project):").font(Extreme.font(10)).foregroundColor(Extreme.gold).lineLimit(1)
                }
                ForEach([VerticalTabAgentKind.claude, .codex], id: \.self) { kind in
                    Button { newAgent = kind } label: {
                        HStack(spacing: 4) {
                            AgentSprite(kind: kind, pixel: 1)
                            Text(kind == .claude ? "Claude" : "Codex").font(Extreme.font(10))
                        }
                        .foregroundColor(newAgent == kind ? Extreme.ink : Extreme.text)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(newAgent == kind ? Extreme.gold : Extreme.raised)
                    }
                    .buttonStyle(.plain)
                }
            }
            .help(session.projectRoot.map {
                "No agent is working in \(($0 as NSString).abbreviatingWithTildeInPath); one starts there in a new split with this request"
            } ?? "No agent is running in this tab; one starts in a new split with this request")
        }
    }

    private func send() {
        session.send(draft, newAgent: newAgent)
    }

    private func shortSource(_ source: String) -> String {
        let parts = source.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private func smallButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Extreme.font(9.5)).foregroundColor(Extreme.muted)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Quick suggestions, wrapped onto as many rows as they need.
private struct WrappingChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        ChipFlow(spacing: 5) {
            ForEach(items, id: \.self) { item in
                ChipButton(title: item) { tap(item) }
            }
        }
    }
}

private struct ChipButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Extreme.font(9.5))
                .foregroundColor(hovering ? Extreme.ink : Extreme.gold)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(hovering ? Extreme.gold : Extreme.gold.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.gold.opacity(0.5), lineWidth: 1))
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hovering = inside } }
    }
}

/// Lays children out in rows, wrapping when a row is full.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Requests

/// Everything sent from this panel and where it stands.
private struct VisualFixRequestList: View {
    @ObservedObject var session: VisualFixSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ExtremeSectionLabel("Requests")
                let working = session.requests.filter { $0.state != .done }.count
                if working > 0 {
                    Text("\(working) in progress").font(Extreme.font(9.5)).foregroundColor(Extreme.core)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.requests.reversed()) { request in
                        RequestCard(session: session, request: request)
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                    removal: .scale.combined(with: .opacity)))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Extreme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Extreme.line).frame(height: 1) }
    }
}

private struct RequestCard: View {
    @ObservedObject var session: VisualFixSession
    let request: VisualFixRequest
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            status
            VStack(alignment: .leading, spacing: 3) {
                Text(request.text).font(Extreme.font(10.5)).foregroundColor(Extreme.text).lineLimit(1)
                Text(detail).font(Extreme.font(9.5)).foregroundColor(color).lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
            if hovering {
                VStack(spacing: 3) {
                    if let surface = session.surface(for: request) {
                        miniButton("Agent") {
                            NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
                        }
                        if request.state == .done, let item = ReviewInbox.shared.item(for: surface) {
                            miniButton("Review") { ReviewInbox.show(selecting: item) }
                        }
                    }
                    miniButton("✕") { session.dismiss(request) }
                }
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(request.id == session.justFinished ? Extreme.live.opacity(0.14) : Extreme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(hovering ? 0.9 : 0.45), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture { session.reveal(request) }
        .help("\(request.element.label)\nClick to scroll to it")
    }

    @ViewBuilder
    private var status: some View {
        ZStack {
            Rectangle().fill(color).frame(width: 22, height: 22)
            switch request.state {
            case .working: PixelSpinner(color: Extreme.ink, pixel: 2)
            case .done: Text("✓").font(Extreme.font(12)).foregroundColor(Extreme.ink)
            case .needsYou: Text("!").font(Extreme.font(12)).foregroundColor(Extreme.ink)
            case .queued: Text("\(request.id)").font(Extreme.font(11)).foregroundColor(Extreme.ink)
            }
        }
        .shadow(color: color.opacity(0.7), radius: request.state == .working ? 6 : 2)
    }

    private var detail: String {
        let who = request.agent.displayName
        switch request.state {
        case .queued: return "#\(request.id) · waiting for \(who)"
        case .working: return "#\(request.id) · \(who) is on it"
        case .needsYou: return "#\(request.id) · \(who) needs you"
        case .done: return "#\(request.id) · done · page reloaded"
        }
    }

    private var color: Color {
        switch request.state {
        case .queued: return Extreme.gold
        case .working: return Extreme.core
        case .needsYou: return Extreme.warn
        case .done: return Extreme.live
        }
    }

    private func miniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Extreme.font(10, weight: .semibold)).foregroundColor(Extreme.text)
                .frame(minWidth: 44).padding(.vertical, 2)
                .background(Extreme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Nothing running

private struct VisualFixEmptyState: View {
    @ObservedObject var session: VisualFixSession
    @ObservedObject private var localhost = LocalhostSessions.shared
    @State private var address = ""
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 16) {
            PixelIconView(icon: .target, color: Extreme.gold, pixel: 5)
                .scaleEffect(breathe ? 1.08 : 0.94)
                .shadow(color: Extreme.gold.opacity(breathe ? 0.6 : 0.2), radius: breathe ? 14 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
                }
            Text("Point at your app, say what to change").font(Extreme.font(14)).foregroundColor(Extreme.text)
            Text("Start your dev server (or ask your agent to), then pick it here.\nClick anything on the page and your agent fixes it.")
                .font(Extreme.font(11)).foregroundColor(Extreme.muted).multilineTextAlignment(.center)
            let live = localhost.sessions.filter { $0.url != nil && $0.isRunning }
            if !live.isEmpty {
                VStack(spacing: 6) {
                    ForEach(live) { app in
                        Button {
                            if let url = app.url { session.load(url) }
                        } label: {
                            HStack(spacing: 8) {
                                PixelDot(color: Extreme.live, blinking: true, size: 5, interval: 0.8)
                                Text(app.project.name).font(Extreme.font(11.5)).foregroundColor(Extreme.text)
                                Text(verbatim: ":\(app.ports.first ?? 0)").font(Extreme.font(11.5)).foregroundColor(Extreme.gold)
                                Spacer()
                                Text("Preview →").font(Extreme.font(11, weight: .semibold)).foregroundColor(Extreme.gold)
                            }
                            .padding(.horizontal, 12).frame(width: 300, height: 34)
                            .background(Extreme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("localhost:3000", text: $address)
                    .textFieldStyle(.plain)
                    .font(Extreme.font(11.5))
                    .padding(.horizontal, 8).frame(width: 190, height: 28)
                    .background(Extreme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
                    .onSubmit(open)
                Button("Open", action: open).buttonStyle(ExtremeButtonStyle(prominent: !address.isEmpty))
                Button("Localhost Manager") { LocalhostManager.show() }.buttonStyle(ExtremeButtonStyle())
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualFixBackdrop())
    }

    private func open() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if Int(text) != nil { text = "localhost:\(text)" }
        if !text.contains("://") { text = "http://" + text }
        if let url = URL(string: text) { session.load(url) }
    }
}

// MARK: - Hosting

/// Shows the page laid out at full size, scaled to fit: the container's bounds are larger
/// than its frame (the way scroll view magnification works), so clicks and scrolling still
/// land in the right place.
private struct VisualFixWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let zoom: CGFloat

    func makeNSView(context: Context) -> ScaledContainer {
        let container = ScaledContainer()
        container.attach(webView)
        container.zoom = zoom
        return container
    }

    func updateNSView(_ container: ScaledContainer, context: Context) {
        container.attach(webView)
        container.zoom = zoom
    }

    final class ScaledContainer: NSView {
        var zoom: CGFloat = 1 {
            didSet { if zoom != oldValue { needsLayout = true } }
        }
        private weak var content: NSView?

        override var isFlipped: Bool { true }

        func attach(_ view: NSView) {
            guard view.superview !== self else { return }
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
            content = view
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let scale = max(0.1, zoom)
            let size = NSSize(width: frame.width / scale, height: frame.height / scale)
            if bounds.size != size {
                setBoundsSize(size)
                setBoundsOrigin(.zero)
            }
            content?.frame = NSRect(origin: .zero, size: size)
        }
    }
}

// MARK: - Entry points

/// "◎ Fix" on a localhost card: opens Visual Fix on that app.
struct VisualFixLaunchButton: View {
    let url: URL?
    let controller: BaseTerminalController?
    var large = false
    @State private var hovering = false

    var body: some View {
        Button {
            VisualFixPanel.shared.show(from: controller, url: url)
        } label: {
            HStack(spacing: 5) {
                PixelIconView(icon: .target, color: hovering ? Extreme.ink : Extreme.gold, pixel: large ? 1.4 : 1.1)
                Text(large ? "Fix visually" : "Fix").font(Extreme.font(large ? 11.5 : 10.5, weight: .semibold))
            }
            .foregroundColor(hovering ? Extreme.ink : Extreme.gold)
            .padding(.horizontal, large ? 9 : 6)
            .frame(height: large ? 26 : 20)
            .background(hovering ? Extreme.gold : Extreme.gold.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.gold.opacity(0.75), lineWidth: 1))
            .shadow(color: Extreme.gold.opacity(hovering ? 0.6 : 0), radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .disabled(url == nil)
        .help("Visual Fix: point at anything in this app and your agent changes it")
        .fixedSize()
    }
}
#endif

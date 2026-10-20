#if os(macOS)
import AppKit
import SwiftUI

/// The sidebar's Ports section: dev servers and whatever else of yours is listening, which
/// project each belongs to, and Stop. Takes no room when nothing is listening.
struct PortsSidebarSection: View {
    let owner: BaseTerminalController
    @ObservedObject private var monitor = PortsMonitor.shared
    @ObservedObject private var settings = ExtremeSettings.shared
    @AppStorage("PortsSectionCollapsed") private var collapsed = false
    @State private var showOthers = false

    var body: some View {
        // Localhost sessions already have their own cards.
        let dev = monitor.devEntries.filter { $0.sessionID == nil || !settings.isOn(.localhost) }
        let others = monitor.entries.filter { $0.kind != .dev }
        VStack(alignment: .leading, spacing: 4) {
            if !dev.isEmpty || monitor.conflict != nil || showOthers {
                Rectangle().fill(Extreme.line).frame(height: 1).padding(.bottom, 4)
                header(count: dev.count, others: others.count)
                if let conflict = monitor.conflict {
                    PortConflictBanner(conflict: conflict, holder: monitor.entries.first { $0.port == conflict.port })
                }
                if !collapsed {
                    ForEach(dev) { PortRow(entry: $0, owner: owner) }
                    if showOthers {
                        ForEach(others) { PortRow(entry: $0, owner: owner) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, dev.isEmpty && monitor.conflict == nil && !showOthers ? 0 : 6)
        // Stays mounted (empty) so the list keeps updating and appears when a server starts.
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)
        // Keeps its height in a short window; the tab list above scrolls instead.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { monitor.watch(true) }
        .onDisappear { monitor.watch(false) }
        .animation(.easeOut(duration: 0.18), value: dev.map(\.id))
    }

    private func header(count: Int, others: Int) -> some View {
        HStack(spacing: 6) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(Extreme.dim).frame(width: 8)
                    Text("PORTS").font(Extreme.font(10.5, weight: .semibold)).kerning(1.1).foregroundColor(Extreme.muted)
                    Text("\(count)").font(Extreme.font(10)).foregroundColor(Extreme.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Extreme.line.opacity(0.7)).frame(height: 1)
            if others > 0 && !collapsed {
                Button(showOthers ? "Hide \(others) other" : "+\(others) other") { showOthers.toggle() }
                    .buttonStyle(.plain)
                    .font(Extreme.font(10))
                    .foregroundColor(Extreme.dim)
                    .help("Apps, background services and container ports")
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct PortRow: View {
    let entry: PortEntry
    let owner: BaseTerminalController
    @ObservedObject private var monitor = PortsMonitor.shared
    @ObservedObject private var settings = ExtremeSettings.shared
    @State private var hovering = false
    @State private var armed = false

    var body: some View {
        let framework = entry.framework
        let stopping = monitor.stopping.contains(entry.id)
        HStack(spacing: 7) {
            Image(systemName: entry.kind == .container ? "shippingbox.fill" : entry.kind == .other ? "app.dashed" : framework.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(entry.kind == .dev ? framework.color : Extreme.dim)
                .frame(width: 14)
            Text(":\(String(entry.port))")
                .font(Extreme.mono(11.5))
                .foregroundColor(entry.kind == .dev ? Extreme.text : Extreme.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(Extreme.font(11, weight: .medium))
                    .foregroundColor(entry.project.map { $0.color.opacity(0.95) } ?? Extreme.muted)
                    .lineLimit(1)
                Text(stopping ? "Stopping…" : subtitle)
                    .font(Extreme.font(9.5))
                    .foregroundColor(stopping ? Extreme.warn : Extreme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering || armed {
                actions
            } else if entry.memory > 0 {
                Text(Housekeeping.bytes(entry.memory)).font(Extreme.font(9.5)).foregroundColor(Extreme.dim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Extreme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: focusOwner)
        .help(help)
        .modifier(PortRowAccessibility(label: "Port \(String(entry.port)), \(entry.title), \(entry.command)",
                                       hint: ownerTab != nil ? "Goes to its tab" : "",
                                       goToTab: focusOwner, openInBrowser: openInBrowser,
                                       openInVisualFix: openInVisualFix, stop: stop))
    }

    private func openInBrowser() {
        if let url = entry.url { NSWorkspace.shared.open(url) }
    }

    private func openInVisualFix() {
        guard entry.kind == .dev, settings.isOn(.visualFix) else { return }
        VisualFixPanel.shared.show(from: ownerTab ?? owner, url: entry.url)
    }

    private func stop() {
        if entry.kind != .container { monitor.stop(entry) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if entry.sessionID != nil { parts.append("localhost session") }
        if entry.kind == .container { parts.append("container port") }
        parts.append(entry.command)
        return parts.joined(separator: " · ")
    }

    private var help: String {
        "\(entry.command)\npid \(entry.pid)" + (entry.cwd.map { "\n\($0.abbreviatedPath)" } ?? "")
            + (ownerTab != nil ? "\nClick to go to its tab" : "")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if entry.kind != .other {
                icon("globe", help: "Open http://localhost:\(entry.port)") {
                    if let url = entry.url { NSWorkspace.shared.open(url) }
                }
            }
            if entry.kind == .dev && settings.isOn(.visualFix) {
                icon("scope", help: "Open in Visual Fix") {
                    VisualFixPanel.shared.show(from: ownerTab ?? owner, url: entry.url)
                }
            }
            if entry.kind != .container {
                if armed {
                    Button { armed = false; monitor.stop(entry) } label: {
                        Text("Stop?").font(Extreme.font(10, weight: .bold)).foregroundColor(Extreme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Extreme.danger))
                    }
                    .buttonStyle(.plain)
                    .help("Click again to stop \(entry.command)")
                } else {
                    icon("stop.fill", help: "Stop \(entry.command) (asks once more)") {
                        armed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
                    }
                }
            }
        }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundColor(Extreme.muted)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The terminal working in the server's project: its localhost session, or one whose
    /// folder is inside the project (a tab, or a tile on a board).
    private var ownerSurface: Ghostty.SurfaceView? {
        if let id = entry.sessionID, let session = LocalhostSessions.shared.sessions.first(where: { $0.id == id }) {
            return LocalhostSessions.shared.surface(for: session)
        }
        guard let root = entry.project?.root else { return nil }
        return TerminalWindows.surfaces.first { _, surface in
            guard let pwd = surface.pwd else { return false }
            return pwd == root || pwd.hasPrefix(root + "/")
        }?.surface
    }

    private var ownerTab: BaseTerminalController? {
        ownerSurface.flatMap { TerminalWindows.controller(for: $0) }
    }

    private func focusOwner() {
        guard let surface = ownerSurface else { return }
        TerminalWindows.show(surface)
    }
}

/// For VoiceOver and keyboard users (who never hover): the row is one element whose press
/// does what a click does (go to its tab), with the hover buttons as named actions. Stop is
/// only ever a named action, never what a plain press does.
private struct PortRowAccessibility: ViewModifier {
    let label: String
    let hint: String
    let goToTab: () -> Void
    let openInBrowser: () -> Void
    let openInVisualFix: () -> Void
    let stop: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, goToTab)
            .accessibilityAction(named: "Open in browser", openInBrowser)
            .accessibilityAction(named: "Open in Visual Fix", openInVisualFix)
            .accessibilityAction(named: "Stop", stop)
    }
}

/// "Port 3000 is taken by web-app (next dev)", with a way to stop it.
private struct PortConflictBanner: View {
    let conflict: PortsMonitor.Conflict
    let holder: PortEntry?
    @ObservedObject private var monitor = PortsMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(Extreme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Port \(String(conflict.port)) is taken").font(Extreme.font(11, weight: .semibold)).foregroundColor(Extreme.text)
                Text(holder.map { "by \($0.title) · \($0.command)" } ?? "by something outside your account")
                    .font(Extreme.font(10)).foregroundColor(Extreme.muted).lineLimit(2)
                if let holder, holder.kind != .container {
                    Button("Stop it") { monitor.stop(holder) }
                        .buttonStyle(ExtremeButtonStyle(prominent: true))
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            Button { monitor.dismissConflict() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Extreme.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Extreme.warn.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Extreme.warn.opacity(0.35), lineWidth: 1))
    }
}
#endif

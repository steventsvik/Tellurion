#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Shared pieces

/// A dot that radiates while the server is live. Core Animation, so it costs no
/// SwiftUI layout per frame (a `repeatForever` here re-laid out the whole window).
struct LocalhostPulse: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 8

    var body: some View {
        RadiateDotLayer(color: color, active: active, size: size)
            .frame(width: size * 2.6, height: size * 2.6)
    }
}

/// The framework's badge: symbol and name in its color.
struct LocalhostFrameworkBadge: View {
    let framework: LocalhostFramework
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: framework.symbol).font(.system(size: compact ? 9 : 10, weight: .bold))
            if !compact { Text(framework.name).font(.system(size: 10.5, weight: .semibold)) }
        }
        .foregroundColor(framework.color)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(framework.color.opacity(0.16)))
        .overlay(Capsule().stroke(framework.color.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

/// `localhost:5173 ↗`: the thing you click to open the app.
struct LocalhostURLPill: View {
    let session: LocalhostSession
    var large = false
    @State private var hovering = false

    var body: some View {
        let accent = session.project.color
        Button {
            LocalhostSessions.shared.openInBrowser(session.url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: large ? 12 : 10, weight: .semibold))
                if let port = session.url?.port {
                    Text("localhost").foregroundColor(.primary.opacity(0.75))
                        + Text(verbatim: ":\(port)").foregroundColor(.primary).bold()
                } else {
                    Text(session.state == .starting && !session.isQuiet ? "starting…" : "not listening")
                        .foregroundColor(.secondary)
                }
                if session.url != nil {
                    Image(systemName: "arrow.up.right").font(.system(size: large ? 10 : 8.5, weight: .bold))
                        .foregroundColor(accent)
                }
            }
            .font(.system(size: large ? 14 : 12, design: .monospaced))
            .padding(.horizontal, large ? 12 : 9)
            .padding(.vertical, large ? 6 : 4)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [accent.opacity(hovering ? 0.36 : 0.24), Color.cyan.opacity(hovering ? 0.22 : 0.12)],
                                   startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.url == nil)
        .onHover { hovering = $0 }
        .help(session.url.map { "Open \($0.absoluteString) in your browser" } ?? "")
    }
}

/// Round icon button used on cards.
struct LocalhostIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundColor(hovering ? tint : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

func localhostUptime(since date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

// MARK: - Sidebar

/// The "LOCALHOST" block at the end of the sidebar: one card per session tab.
struct LocalhostSidebarSection: View {
    let entries: [VerticalTabEntry]
    let owner: BaseTerminalController
    @ObservedObject private var store = LocalhostSessions.shared
    /// Folded down to its header, so the cards don't take the sidebar's space.
    @AppStorage("LocalhostSectionCollapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .bold)).foregroundColor(Extreme.dim).frame(width: 8)
                        Image(systemName: "globe").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text("LOCALHOST").font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                        if collapsed {
                            Text("\(entries.count)").font(Extreme.font(10)).foregroundColor(Extreme.dim)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show localhost sessions" : "Hide localhost sessions")
                .accessibilityLabel(collapsed ? "Show localhost sessions" : "Hide localhost sessions")
                if store.liveCount > 0 {
                    Text("\(store.liveCount) live")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.92, blue: 0.55)))
                }
                Spacer()
                Button("Manage") { LocalhostManager.show() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.accentColor)
                    .help("Localhost manager (⌃⌘L)")
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // Two cards show at once; more scroll.
            if collapsed {
                EmptyView()
            } else if entries.count > 2 {
                ScrollView { cards.padding(.vertical, 4) }.frame(height: 300)
            } else {
                cards
            }
        }
        .padding(.bottom, collapsed ? 8 : 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: entries.map(\.id))
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(entries) { entry in
                if let controller = entry.controller, let session = store.session(for: controller) {
                    LocalhostTabCard(session: session, controller: controller, owner: owner, isSelected: controller === owner)
                        .padding(.horizontal, 8)
                        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
        }
    }
}

/// A localhost session in the sidebar: a glowing card with the URL front and center.
struct LocalhostTabCard: View {
    let session: LocalhostSession
    /// The server's own tab.
    let controller: BaseTerminalController
    /// The tab whose sidebar shows the card: where Visual Fix opens.
    let owner: BaseTerminalController
    let isSelected: Bool
    @State private var hovering = false
    @Environment(\.extremeMotion) private var motion

    var body: some View {
        let accent = session.project.color
        let live = session.state == .live
        TimelineView(.periodic(from: .now, by: motion ? 1 : 3600)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(LinearGradient(colors: [accent, .cyan.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                            .overlay(Image(systemName: "globe").font(.system(size: 13, weight: .bold)).foregroundColor(.white))
                        LocalhostPulse(color: session.statusColor, active: live, size: 7)
                            .offset(x: 7, y: 7)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(session.statusLabel).foregroundColor(session.statusColor)
                            if live, let since = session.liveSince {
                                Text("· \(localhostUptime(since: since, now: context.date))").foregroundColor(.secondary)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    Spacer(minLength: 4)
                    LocalhostFrameworkBadge(framework: session.framework)
                }

                HStack(spacing: 6) {
                    LocalhostURLPill(session: session)
                    ForEach(session.ports.filter { $0 != session.url?.port }.prefix(2), id: \.self) { port in
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    if live { VisualFixLaunchButton(url: session.url, controller: owner) }
                }

                HStack(spacing: 6) {
                    Text("$ " + session.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if hovering {
                        controls
                    } else if let agent = session.agent {
                        HStack(spacing: 3) {
                            VerticalTabAgentLogo(kind: agent, tint: agent.standaloneLogoColor).frame(width: 10, height: 10)
                            Text("by \(agent.displayName)")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    }
                }
                .frame(height: 22)
            }
        }
        .padding(10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.18))
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(colors: [accent.opacity(isSelected ? 0.22 : 0.13), Color.cyan.opacity(0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            })
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(LinearGradient(colors: [accent.opacity(isSelected ? 0.95 : 0.6), Color.cyan.opacity(isSelected ? 0.7 : 0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isSelected ? 1.5 : 1))
        .shadow(color: live ? accent.opacity(isSelected ? 0.45 : 0.25) : .clear, radius: isSelected ? 10 : 6)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hovering = $0 }
        .onTapGesture { LocalhostSessions.shared.focus(session) }
        .contextMenu { menu }
        .help("\(session.command)\n\(session.cwd)")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            LocalhostIconButton(symbol: "eye", help: "Preview in Tellurion", tint: .cyan, size: 20) {
                if let url = session.url { LocalhostPreview.show(url, title: session.project.name) }
            }
            .disabled(session.url == nil)
            if session.isRunning {
                LocalhostIconButton(symbol: "arrow.clockwise", help: "Restart", tint: .orange, size: 20) {
                    LocalhostSessions.shared.restart(session)
                }
                LocalhostIconButton(symbol: "stop.fill", help: "Stop the server (the tab stays)", tint: .red, size: 20) {
                    LocalhostSessions.shared.stop(session)
                }
            } else {
                LocalhostIconButton(symbol: "play.fill", help: "Start again", tint: .green, size: 20) {
                    LocalhostSessions.shared.restart(session)
                }
            }
            LocalhostIconButton(symbol: "xmark", help: "Stop and close the tab", tint: .red, size: 20) {
                LocalhostSessions.shared.close(session)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Fix Visually…") { VisualFixPanel.shared.show(from: owner, url: session.url) }.disabled(session.url == nil)
        Button("Open in Browser") { LocalhostSessions.shared.openInBrowser(session.url) }.disabled(session.url == nil)
        Button("Preview in Tellurion") {
            if let url = session.url { LocalhostPreview.show(url, title: session.project.name) }
        }.disabled(session.url == nil)
        Button("Copy URL") { VerticalTabsActions.copy(session.url?.absoluteString ?? "") }.disabled(session.url == nil)
        Divider()
        Button(session.isRunning ? "Restart" : "Start Again") { LocalhostSessions.shared.restart(session) }
        Button("Stop Server") { LocalhostSessions.shared.stop(session) }.disabled(!session.isRunning)
        Button("Show Logs") { LocalhostSessions.shared.focus(session) }
        Divider()
        Button("Open Localhost Manager") { LocalhostManager.show() }
        Button("Stop and Close Tab") { LocalhostSessions.shared.close(session) }
    }
}

/// Sidebar header button: opens the localhost manager, with the live count.
struct LocalhostHeaderButton: View {
    @ObservedObject private var store = LocalhostSessions.shared
    @State private var hovering = false

    var body: some View {
        Button(action: LocalhostManager.toggle) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.liveCount > 0
                        ? AnyShapeStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.primary))
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14), lineWidth: 1))
                if store.liveCount > 0 {
                    Text("\(store.liveCount)")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Circle().fill(Color(red: 0.25, green: 0.92, blue: 0.55)))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Localhost manager (⌃⌘L)")
    }
}

// MARK: - Toast

/// "Your app is live" pop-up shown over the terminal when a session starts listening.
struct LocalhostToastView: View {
    let session: LocalhostSession
    var controller: BaseTerminalController?
    let dismiss: () -> Void

    var body: some View {
        let accent = session.project.color
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [accent, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "globe").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: accent.opacity(0.6), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(session.project.name) is live").font(.system(size: 13, weight: .semibold))
                    LocalhostFrameworkBadge(framework: session.framework, compact: true)
                }
                Text(session.agent.map { "Started by \($0.displayName) in its own tab · keeps running after it's done" }
                     ?? "Running in its own tab")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            LocalhostURLPill(session: session, large: true)
            VisualFixLaunchButton(url: session.url, controller: controller, large: true)
            LocalhostIconButton(symbol: "xmark", help: "Dismiss", size: 20, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial)
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [accent.opacity(0.2), Color.cyan.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
            })
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(LinearGradient(colors: [accent, .cyan.opacity(0.6)], startPoint: .leading, endPoint: .trailing), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .fixedSize()
    }
}

/// Places the toast at the top of the terminal area.
struct LocalhostToastLayer: View {
    var controller: BaseTerminalController?
    @ObservedObject private var store = LocalhostSessions.shared

    var body: some View {
        VStack {
            if let session = store.toast {
                LocalhostToastView(session: session, controller: controller) { store.toast = nil }
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { LocalhostSessions.shared.focus(session) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.toast?.id)
    }
}
#endif

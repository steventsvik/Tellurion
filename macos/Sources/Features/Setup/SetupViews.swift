#if os(macOS)
import AppKit
import SwiftUI

/// The Setup Check window: whether agent status is set up and working, with a fix for
/// each problem. Also available as `tellurion doctor` in a terminal.
enum SetupCheckWindow {
    static func show() {
        AgentToolWindows.show(id: SetupChecks.windowID, title: "Setup Check", size: NSSize(width: 640, height: 640)) {
            SetupCheckView()
        }
    }

    static func toggle() {
        if AgentToolWindows.isOpen(SetupChecks.windowID) { AgentToolWindows.close(id: SetupChecks.windowID) } else { show() }
    }
}

extension SetupCheck.Status {
    var color: Color {
        switch self {
        case .ok: return Tellurion.live
        case .info: return Tellurion.muted
        case .warning: return Tellurion.warn
        case .problem: return Tellurion.danger
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "minus.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }
}

private struct SetupCheckView: View {
    @ObservedObject private var store = SetupChecks.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.checks.isEmpty {
                        Text("Checking…").font(Tellurion.font(12)).foregroundColor(Tellurion.muted)
                    }
                    ForEach(SetupCheck.Section.allCases, id: \.self) { section in
                        let checks = store.checks.filter { $0.section == section }
                        if !checks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                TellurionSectionLabel(section.rawValue)
                                ForEach(checks) { SetupCheckRow(check: $0) }
                            }
                        }
                    }
                    if let error = store.fixError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Tellurion.font(11.5)).foregroundColor(Tellurion.danger)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            Rectangle().fill(Tellurion.line).frame(height: 1)
            footer
        }
        .tellurionWindow()
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TellurionWindowTitle(icon: .bolt, title: "Setup Check", subtitle: summary)
            Spacer()
            Button { store.refresh() } label: {
                Label(store.running ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
            }
            .disabled(store.running)
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var summary: String {
        let problems = store.problems.count
        let warnings = store.checks.filter { $0.status == .warning }.count
        if store.checks.isEmpty { return "Agent hooks, tools and permissions" }
        if problems == 0 && warnings == 0 { return "Everything's set up" }
        return [problems > 0 ? "\(problems) to fix" : nil, warnings > 0 ? "\(warnings) to look at" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("In a terminal: tellurion doctor")
                .font(Tellurion.mono(11)).foregroundColor(Tellurion.dim)
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy report") { copyReport() }
                .help("A plain-text report for GitHub issues (your home folder shows as ~)")
            Button("Welcome…") { WelcomeWindow.show() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copyReport() {
        var lines = ["Tellurion \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") setup check"]
        for section in SetupCheck.Section.allCases {
            let checks = store.checks.filter { $0.section == section }
            guard !checks.isEmpty else { continue }
            lines.append("\n\(section.rawValue)")
            for check in checks {
                let mark: String
                switch check.status {
                case .ok: mark = "✓"
                case .info: mark = "-"
                case .warning: mark = "!"
                case .problem: mark = "✗"
                }
                lines.append("  \(mark) \(check.title)" + (check.detail.isEmpty ? "" : " — \(check.detail)"))
            }
        }
        let text = lines.joined(separator: "\n").replacingOccurrences(of: NSHomeDirectory(), with: "~")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

struct SetupCheckRow: View {
    let check: SetupCheck
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(check.status.color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(Tellurion.font(11.5, weight: .regular))
                        .foregroundColor(Tellurion.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let alternative = check.alternative {
                Button(alternative.title) { SetupChecks.shared.apply(alternative) }
                    .buttonStyle(TellurionButtonStyle())
            }
            if let fix = check.fix {
                Button(fix.title) { SetupChecks.shared.apply(fix) }
                    .buttonStyle(TellurionButtonStyle(prominent: check.status >= .warning && fix != .liveTest))
            }
        }
        .padding(compact ? 8 : 10)
        .tellurionPanel(fill: compact ? Tellurion.raised : Tellurion.panel)
    }
}

/// In the sidebar: a warning when agent status needs setting up, and a short confirmation
/// when a live test arrives. Nothing at all while everything's fine.
struct SetupSidebarChip: View {
    @ObservedObject private var store = SetupChecks.shared
    @State private var hovering = false

    var body: some View {
        if store.showLivePass {
            chip(color: Tellurion.live, text: "Agent status works · test event arrived", symbol: "checkmark")
        } else if let first = store.problems.first {
            let count = store.problems.count
            chip(color: Tellurion.danger,
                 text: count == 1 ? first.title : "Agent status: \(count) things to fix",
                 symbol: "chevron.right")
        }
    }

    private func chip(color: Color, text: String, symbol: String) -> some View {
        Button(action: SetupCheckWindow.show) {
            HStack(spacing: 6) {
                PixelDot(color: color, size: 5)
                Text(text)
                    .font(Tellurion.font(11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(hovering ? Tellurion.gold : color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(hovering ? 0.16 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Setup Check")
        .transition(.opacity)
    }
}
#endif

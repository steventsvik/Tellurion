#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// One usage window of a subscription, e.g. "5h" at 42% resetting in 2 hours.
struct UsageWindow: Equatable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

/// A subscription's current usage.
struct UsageEntry: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    /// Fits under the name next to the rings.
    let shortDetail: String
    let agent: VerticalTabAgentKind
    let windows: [UsageWindow]
    /// When the numbers were last reported.
    let updated: Date?
}

/// Live usage of the user's AI subscriptions, from data the tools themselves record:
///
/// - Claude: `rate_limits` from Claude Code's status line input (Pro/Max plans), which the
///   status line script saves to ~/.claude/ghostty-extreme/claude-usage.json.
/// - ChatGPT plan (Codex, and Hermes when it uses the Codex provider): the `rate_limits`
///   Codex writes into its session files under ~/.codex/sessions.
///
/// Nothing here calls a network API or touches credentials. Files are re-read every 30s
/// while the app is active and right after agent activity.
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var entries: [UsageEntry] = []

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.usage", qos: .utility)
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        center.publisher(for: VerticalTabsAgents.didChange)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            if NSApp.isActive { self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        queue.async {
            let entries = [Self.claude(), Self.chatGPT()].compactMap { $0 }
            DispatchQueue.main.async {
                if entries != self.entries { self.entries = entries }
            }
        }
    }

    // MARK: Claude

    /// The last report of each Claude window, by key (read and written on `queue`).
    private static var lastClaudeWindows: [String: UsageWindow] = [:]

    private static func claude() -> UsageEntry? {
        let path = NSHomeDirectory() + "/.claude/ghostty-extreme/claude-usage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else {
            return UsageEntry(id: "claude", name: "Claude", detail: "Waiting for Claude Code to report usage", shortDetail: "",
                              agent: .claude, windows: [], updated: nil)
        }
        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any], let used = w["used_percentage"] as? Double else { return nil }
            return UsageWindow(label: label, usedPercent: used,
                               resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        // Claude Code leaves a window out of its report while none is running (e.g. between
        // 5-hour windows), and the status line script saves each report whole. The 5h and
        // Week rows stay put: the last numbers seen until they reset, then unused.
        let now = Date()
        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
            if let current = window(key, label) {
                lastClaudeWindows[key] = current
                windows.append(current)
            } else if let last = lastClaudeWindows[key], let resetsAt = last.resetsAt, resetsAt > now {
                windows.append(last)
            } else {
                windows.append(UsageWindow(label: label, usedPercent: 0, resetsAt: nil))
            }
        }
        if let spend = window("spend_limit", "Spend") { windows.append(spend) }
        let updated = (json["updated"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return UsageEntry(id: "claude", name: "Claude", detail: "Claude Code", shortDetail: "Code", agent: .claude,
                          windows: windows, updated: updated)
    }

    // MARK: ChatGPT (Codex / Hermes)

    private static func chatGPT() -> UsageEntry? {
        guard let (limits, updated) = latestCodexRateLimits() else { return nil }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
            let minutes = w["window_minutes"] as? Double ?? 0
            let label = minutes >= 10_000 ? "Week" : minutes >= 1_440 ? "\(Int(minutes / 1_440))d" : minutes > 0 ? "\(Int(minutes / 60))h" : "Limit"
            windows.append(UsageWindow(label: label, usedPercent: used,
                                       resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }))
        }
        let plan = (limits["plan_type"] as? String).map(planName) ?? "ChatGPT"
        return UsageEntry(id: "chatgpt", name: "ChatGPT", detail: "\(plan) · Codex & Hermes", shortDetail: plan, agent: .codex,
                          windows: windows, updated: updated)
    }

    private static func planName(_ raw: String) -> String {
        switch raw {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    /// The most recent `rate_limits` record across the newest Codex session files.
    private static func latestCodexRateLimits() -> ([String: Any], Date?)? {
        let root = NSHomeDirectory() + "/.codex/sessions"
        let fm = FileManager.default
        // Sessions are stored as YYYY/MM/DD/rollout-*.jsonl; walk the newest days first.
        func newest(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >)
        }
        var files: [(path: String, modified: Date)] = []
        outer: for year in newest(root) {
            for month in newest("\(root)/\(year)") {
                for day in newest("\(root)/\(year)/\(month)") {
                    let dir = "\(root)/\(year)/\(month)/\(day)"
                    for name in newest(dir) where name.hasSuffix(".jsonl") {
                        let path = "\(dir)/\(name)"
                        let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                        files.append((path, modified))
                    }
                    if files.count >= 6 { break outer }
                }
            }
        }
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(6) {
            guard let handle = FileHandle(forReadingAtPath: file.path) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            // The cut can land inside a character; only whole lines are used.
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any] else { continue }
                return (limits, file.modified)
            }
        }
        return nil
    }
}

// MARK: - View

/// Bottom-left of the sidebar: each subscription's usage as a row of ring gauges, one per
/// limit window. The rings fill and change color as usage grows; clicking the panel
/// shows the exact percentages and time until each window resets.
struct UsagePanel: View {
    @ObservedObject private var monitor = UsageMonitor.shared
    let palette: VerticalTabsPalette
    static let showsPercentKey = "GhosttyExtremeUsageShowPercentages"
    /// Percentages, or when each limit resets.
    @AppStorage(UsagePanel.showsPercentKey) private var showsPercent = true
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if !monitor.entries.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                TellurionSectionLabel("Usage") {
                    Button(action: ActivityDashboard.toggle) {
                        HStack(spacing: 5) {
                            PixelIconView(icon: .chart, color: Tellurion.gold, pixel: 1.1)
                            Text("Graphs")
                        }
                    }
                    .buttonStyle(TellurionButtonStyle())
                    .help("Agent activity, usage graphs and API value (⌃⌘A)")
                }
                ForEach(monitor.entries) { entry in
                    UsageRow(entry: entry, showsPercent: showsPercent, now: now)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .onTapGesture { showsPercent.toggle() }
            .help(showsPercent ? "Click to show when limits reset" : "Click to show percentages")
            .onReceive(clock) { now = $0 }
        }
    }
}

private struct UsageRow: View {
    let entry: UsageEntry
    let showsPercent: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                AgentSprite(kind: entry.agent == .codex ? .codex : entry.agent, pixel: 1.5)
                    .frame(width: 20, height: 14)
                Text(entry.name)
                    .font(Tellurion.font(11.5, weight: .semibold))
                    .foregroundColor(Tellurion.text)
                Text(entry.windows.isEmpty ? "no usage yet" : entry.shortDetail)
                    .font(Tellurion.font(10.5))
                    .foregroundColor(Tellurion.dim)
                    .lineLimit(1)
            }
            ForEach(entry.windows, id: \.label) { window in
                UsageBar(window: window, showsPercent: showsPercent, now: now)
            }
        }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [entry.detail]
        for window in entry.windows {
            let resets = window.resetsAt.map { "resets \(DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short))" } ?? ""
            lines.append("\(window.label): \(Int(window.usedPercent.rounded()))% used \(resets)")
        }
        if let updated = entry.updated {
            lines.append("Reported \(RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: now))")
        }
        return lines.joined(separator: "\n")
    }
}

/// One limit window as a glowing meter. Hovering it shows when the limit resets.
private struct UsageBar: View {
    let window: UsageWindow
    let showsPercent: Bool
    let now: Date
    @State private var hovering = false

    /// A window that has already reset shows as unused until new numbers arrive.
    private var used: Double {
        if let resetsAt = window.resetsAt, resetsAt <= now { return 0 }
        return min(max(window.usedPercent, 0), 100)
    }

    private var color: Color {
        used >= 90 ? Tellurion.danger : used >= 70 ? Tellurion.warn : Tellurion.gold
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(Tellurion.font(10.5))
                .foregroundColor(Tellurion.muted)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tellurion.line.opacity(0.8))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(used > 0 ? 6 : 0, geometry.size.width * used / 100))
                        .shadow(color: color.opacity(hovering ? 0.7 : 0.35), radius: hovering ? 5 : 3)
                }
            }
            .frame(height: hovering ? 8 : 6)
            Text(hovering ? "resets \(resetText)" : showsPercent ? "\(Int(used.rounded()))%" : resetText)
                .font(Tellurion.font(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(used >= 70 ? color : hovering ? Tellurion.text : Tellurion.muted)
                .frame(width: hovering ? 70 : 38, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hovering = inside } }
        .animation(.easeOut(duration: 0.5), value: used)
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return "—" }
        let minutes = Int(resetsAt.timeIntervalSince(now) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}
#endif

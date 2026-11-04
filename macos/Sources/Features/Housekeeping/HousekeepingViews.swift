#if os(macOS)
import AppKit
import SwiftUI

/// The Background window (⌃⌘K): everything left running, how long since it was used, and
/// whether it's ready to close.
enum HousekeepingWindow {
    static func toggle() {
        if AgentToolWindows.isOpen(Housekeeping.windowID) { AgentToolWindows.close(id: Housekeeping.windowID) } else { show() }
    }

    static func show() {
        guard TellurionSettings.isOn(.background) else { return }
        AgentToolWindows.show(id: Housekeeping.windowID, title: "Background", size: NSSize(width: 1040, height: 720)) {
            HousekeepingView()
        }
    }
}

extension Housekeeping.Rating {
    var color: Color {
        switch self {
        case .active: return Tellurion.live
        case .idle: return Tellurion.core
        case .stale: return Tellurion.warn
        case .close: return Tellurion.danger
        }
    }
}

private struct HousekeepingView: View {
    @ObservedObject private var store = Housekeeping.shared
    @State private var filter: Filter = .attention
    @State private var closing: Set<String> = []

    enum Filter: String, CaseIterable {
        case attention = "Needs attention", everything = "Everything", projects = "By project"
    }

    private var shown: [Housekeeping.Item] {
        filter == .attention ? store.items.filter { $0.rating >= .idle } : store.items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.items.isEmpty {
                        empty(store.scannedAt == nil ? "Looking around…" : "Nothing left running in the background.")
                    } else if shown.isEmpty {
                        empty("Everything running was used recently. Nothing to tidy up.")
                    } else if filter == .projects {
                        ForEach(projectGroups, id: \.0) { name, items in section(name, symbol: "folder", items: items) }
                    } else {
                        ForEach(Housekeeping.Kind.allCases, id: \.self) { kind in
                            let items = shown.filter { $0.kind == kind }
                            if !items.isEmpty { section(kind.title, symbol: kind.symbol, items: items) }
                        }
                    }
                }
                .padding(16)
            }
        }
        .tellurionWindow()
        .onAppear { store.watch(true) }
        .onDisappear { store.watch(false) }
    }

    private var projectGroups: [(String, [Housekeeping.Item])] {
        Dictionary(grouping: store.items) { $0.project ?? "No project" }
            .map { ($0.key, $0.value) }
            .sorted { ($0.1.map(\.score).max() ?? 0) > ($1.1.map(\.score).max() ?? 0) }
    }

    // MARK: Header

    private var header: some View {
        let ready = store.items.filter { $0.rating == .close && $0.close != .none }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                TellurionWindowTitle(icon: .chart, title: "Background",
                                   subtitle: "Everything left running, when it was last used, and what's ready to close")
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                Button { store.refresh() } label: {
                    Label(store.scanning ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.scanning)
            }
            HStack(spacing: 8) {
                chip("\(store.items.count) running", Tellurion.muted)
                let stale = store.staleCount
                if stale > 0 { chip("\(stale) stale", Tellurion.warn) }
                if store.reclaimable > 0 { chip("\(Housekeeping.bytes(store.reclaimable)) you could free", Tellurion.warn) }
                chip("Tellurion: \(Int(store.selfUsage.cpu))% CPU · \(Housekeeping.bytes(store.selfUsage.memory))",
                     store.selfUsage.cpu > 25 ? Tellurion.danger : Tellurion.muted)
                Spacer()
                if !ready.isEmpty {
                    Button {
                        confirm(ready)
                    } label: {
                        Label("Close \(ready.count) ready to close", systemImage: "xmark.circle")
                    }
                    .buttonStyle(TellurionButtonStyle(prominent: true))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Tellurion.font(11.5, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 10) {
            TellurionSigil(size: 52)
            Text(text).font(Tellurion.font(13)).foregroundColor(Tellurion.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    // MARK: Sections and rows

    private func section(_ title: String, symbol: String, items: [Housekeeping.Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(Tellurion.muted)
                Text(title.uppercased()).font(Tellurion.font(10.5, weight: .bold)).kerning(1.2).foregroundColor(Tellurion.muted)
                Text("\(items.count)").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
                Rectangle().fill(Tellurion.line).frame(height: 1)
            }
            ForEach(items) { item in row(item) }
        }
    }

    private func row(_ item: Housekeeping.Item) -> some View {
        let rating = item.rating
        let busy = closing.contains(item.id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(rating.color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rating.color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title).font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted).lineLimit(1)
                    }
                }
                Text(item.command)
                    .font(Tellurion.mono(10.5)).foregroundColor(Tellurion.dim)
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.command)
                if rating >= .idle || item.kind == .vm, !item.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(item.reasons, id: \.self) { reason in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(rating.color.opacity(0.8)).frame(width: 4, height: 4)
                                Text(reason).font(Tellurion.font(11.5)).foregroundColor(Tellurion.text.opacity(0.8))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                ratingPill(item)
                Text(usedText(item)).font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                Text(sizeText(item)).font(Tellurion.mono(10.5)).foregroundColor(Tellurion.dim)
            }
            .frame(width: 210, alignment: .trailing)
            actions(item, busy: busy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tellurion.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(rating >= .stale ? rating.color.opacity(0.35) : Tellurion.line, lineWidth: 1))
        .opacity(busy ? 0.5 : 1)
    }

    private func ratingPill(_ item: Housekeeping.Item) -> some View {
        let color = item.rating.color
        return HStack(spacing: 6) {
            Text(item.rating.label).font(Tellurion.font(11, weight: .semibold)).foregroundColor(color)
            // How stale, as a short bar.
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: max(3, CGFloat(item.score) / 100 * 44))
            }
            .frame(width: 44, height: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.1)))
        .help("Staleness \(item.score)/100")
    }

    private func usedText(_ item: Housekeeping.Item) -> String {
        if item.cpu > 5 { return "Working now" }
        guard let last = item.lastActive else { return "Running \(item.started.map { Housekeeping.span(Date().timeIntervalSince($0)) } ?? "")" }
        let idle = Date().timeIntervalSince(last)
        return idle < 120 ? "In use now" : "Last used \(Housekeeping.ago(idle))"
    }

    private func sizeText(_ item: Housekeeping.Item) -> String {
        var parts: [String] = []
        if item.reserved > 0 { parts.append("\(Housekeeping.bytes(item.reserved)) reserved") } else if item.memory > 0 { parts.append(Housekeeping.bytes(item.memory)) }
        if item.cpu >= 0.5 { parts.append("\(Int(item.cpu.rounded()))% CPU") }
        if let started = item.started { parts.append("up \(Housekeeping.span(Date().timeIntervalSince(started)))") }
        return parts.joined(separator: " · ")
    }

    private func actions(_ item: Housekeeping.Item, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if item.close != .none {
                Button { confirm([item]) } label: { Text(closeLabel(item)) }
                    .disabled(busy)
            }
            Menu {
                if let port = item.ports.first {
                    Button("Open http://localhost:\(port)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                }
                if let folder = item.folder {
                    Button("Show Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
                }
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.command, forType: .string)
                }
                if case .terminate = item.close {
                    Divider()
                    Button("Force Quit") { confirm([item], force: true) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(width: 130, alignment: .trailing)
    }

    private func closeLabel(_ item: Housekeeping.Item) -> String {
        switch item.close {
        case .colimaStop: return "Stop VM"
        case .dockerStop: return "Stop"
        case .launchdStop: return "Stop"
        default: return "Close"
        }
    }

    // MARK: Closing

    private func confirm(_ items: [Housekeeping.Item], force: Bool = false) {
        let alert = NSAlert()
        if items.count == 1, let item = items.first {
            alert.messageText = "\(force ? "Force quit" : closeLabel(item)) \(item.title)?"
            alert.informativeText = explanation(item)
        } else {
            alert.messageText = "Close \(items.count) things that look finished?"
            alert.informativeText = items.map { "• \($0.title)\($0.project.map { " (\($0))" } ?? "") — \(usedText($0).lowercased())" }
                .joined(separator: "\n")
                + "\n\nThis frees about \(Housekeeping.bytes(items.reduce(0) { $0 + max($1.memory, $1.reserved) }))."
        }
        alert.addButton(withTitle: force ? "Force Quit" : "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in items {
            closing.insert(item.id)
            Housekeeping.shared.close(item, force: force) { closing.remove(item.id) }
        }
    }

    private func explanation(_ item: Housekeeping.Item) -> String {
        switch item.close {
        case .colimaStop(let profile):
            return "Stops the Colima VM “\(profile)” and every container in it, freeing \(Housekeeping.bytes(item.reserved)). Start it again with `colima start\(profile == "default" ? "" : " -p \(profile)")` (a Docker session in Tellurion starts it for you)."
        case .dockerStop:
            return "Stops the container. Unless it was started with --rm, it's kept and can be started again."
        case .launchdStop(let label):
            return "Stops the login service \(label) until you next log in (it isn't removed)."
        case .terminate(let pids):
            return "Sends a normal quit signal to \(pids.count) process\(pids.count == 1 ? "" : "es"), so it can shut down cleanly.\(item.inTerminal ? " It's running in a Tellurion tab; the tab stays open." : "")"
        case .none:
            return ""
        }
    }
}

/// The sidebar's reminder when things have gone stale: "3 stale · 7.1 GB".
struct HousekeepingChip: View {
    @ObservedObject private var store = Housekeeping.shared
    @State private var hovering = false

    var body: some View {
        let stale = store.staleCount
        if stale > 0 {
            Button(action: HousekeepingWindow.show) {
                HStack(spacing: 6) {
                    PixelDot(color: Tellurion.warn, size: 5)
                    Text("\(stale) stale in the background")
                        .font(Tellurion.font(11, weight: .medium))
                    if store.reclaimable > 0 {
                        Text("· \(Housekeeping.bytes(store.reclaimable))").font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(hovering ? Tellurion.gold : Tellurion.warn)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tellurion.warn.opacity(hovering ? 0.16 : 0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open Background (⌃⌘K): things left running that look finished")
        }
    }
}
#endif

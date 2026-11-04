#if os(macOS)
import AppKit
import Combine
import Sparkle
import SwiftUI

/// The update window: what the new version brings, then its progress while it downloads,
/// prepares and restarts. Opened from the titlebar pill, the sidebar card's "What's new",
/// and by itself when Check for Updates… finds a release.
enum UpdateWindow {
    private static let id = "software-update"

    static func show() {
        guard let model = (NSApp.delegate as? AppDelegate)?.updateViewModel else { return }
        AgentToolWindows.show(id: id, title: "Software Update", size: NSSize(width: 500, height: 560)) {
            UpdateWindowView(model: model)
        }
    }

    static func close() {
        AgentToolWindows.close(id: id)
    }

    static var isOpen: Bool { AgentToolWindows.isOpen(id) }
}

/// The release notes for an update: the appcast's description (release.sh puts the
/// changelog section there), or, for feeds without one, the GitHub release's notes.
@MainActor
final class UpdateNotes: ObservableObject {
    enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    @Published private(set) var blocks: [Block] = []
    @Published private(set) var loading = false
    private var version = ""

    func load(_ item: SUAppcastItem) {
        let version = item.displayVersionString
        guard version != self.version else { return }
        self.version = version
        blocks = []
        if let description = item.itemDescription, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks = Self.parse(description)
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/steventsvik/Tellurion/releases/tags/extreme-\(version)") else { return }
        loading = true
        Task {
            var body = ""
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = json["body"] as? String ?? ""
            }
            guard version == self.version else { return }
            // The notes end where the install instructions start.
            if let install = body.range(of: "\n## Install") { body = String(body[..<install.lowerBound]) }
            blocks = Self.parse(body)
            loading = false
        }
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                blocks.append(.heading(String(line.dropFirst(2).dropLast(2))))
            } else if case .bullet(let previous)? = blocks.last, raw.hasPrefix("  ") {
                // A bullet wrapped onto the next line.
                blocks[blocks.count - 1] = .bullet(previous + " " + line)
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct UpdateWindowView: View {
    @ObservedObject var model: UpdateViewModel
    @ObservedObject private var updates = TellurionUpdates.shared
    @StateObject private var notes = UpdateNotes()
    /// The release being installed, kept for the progress screen (the states after
    /// "available" don't carry it).
    @State private var item: SUAppcastItem?

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .updateAvailable(let update):
                available(update)
            case .downloading(let download):
                let fraction = download.expectedLength.map { $0 > 0 ? min(1, Double(download.progress) / Double($0)) : 0 }
                let detail = download.expectedLength.map { "\(Self.bytes(download.progress)) of \(Self.bytes($0))" }
                progress(step: 0, fraction: fraction, detail: detail, cancel: download.cancel)
            case .extracting(let extracting):
                progress(step: 1, fraction: extracting.progress, detail: nil, cancel: nil)
            case .installing:
                progress(step: 2, fraction: nil, detail: nil, cancel: nil)
            case .checking(let checking):
                message(title: "Checking for updates…", text: nil, spinner: true) {
                    Button("Cancel") { checking.cancel() }
                }
            case .notFound(let notFound):
                message(title: "You're up to date", text: "Tellurion \(currentVersion) is the latest version.", spinner: false) {
                    Button("OK") { model.state = .idle; notFound.acknowledgement() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case .error(let error):
                message(title: "The update didn't finish", text: error.error.localizedDescription, spinner: false) {
                    Button("Close") { error.dismiss() }
                    Button("Try again") { error.retry() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case .idle, .permissionRequest:
                Color.clear
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .tellurionWindow()
        .onAppear { remember(model.state) }
        .onChange(of: model.state) { state in
            remember(state)
            // Skipped, dismissed, or done: nothing left to show.
            if state.isIdle { UpdateWindow.close() }
        }
    }

    private func remember(_ state: UpdateState) {
        if case .updateAvailable(let update) = state {
            item = update.appcastItem
            notes.load(update.appcastItem)
        }
    }

    // MARK: Available

    private func available(_ update: UpdateState.UpdateAvailable) -> some View {
        let version = update.appcastItem.displayVersionString
        return VStack(alignment: .leading, spacing: 18) {
            header(title: "Tellurion \(version)",
                   subtitle: currentVersion.isEmpty ? "A new version is ready" : "A new version is ready. You have \(currentVersion).")
            HStack(spacing: 8) {
                if update.appcastItem.contentLength > 0 {
                    chip(Self.bytes(update.appcastItem.contentLength))
                }
                if let date = update.appcastItem.date {
                    chip("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                }
                chip("Notarized by Apple")
            }
            VStack(alignment: .leading, spacing: 10) {
                TellurionSectionLabel("What's new") {
                    if let url = update.releaseNotes?.url {
                        Button("On GitHub ↗") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .font(Tellurion.font(10.5))
                            .foregroundColor(Tellurion.gold)
                            .fixedSize()
                    }
                }
                notesView
            }
            .frame(maxHeight: .infinity)
            footer(update)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 20)
    }

    private var notesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if notes.blocks.isEmpty {
                    Text(notes.loading ? "Loading the release notes…" : "No release notes for this version.")
                        .font(Tellurion.font(12)).foregroundColor(Tellurion.muted)
                }
                ForEach(Array(notes.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let text):
                        Text(UpdateNotes.inline(text))
                            .font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.gold)
                            .padding(.top, 4)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Rectangle().fill(Tellurion.gold).frame(width: 4, height: 4).offset(y: -2)
                            Text(UpdateNotes.inline(text))
                                .font(Tellurion.font(12, weight: .regular)).foregroundColor(Tellurion.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .paragraph(let text):
                        Text(UpdateNotes.inline(text))
                            .font(Tellurion.font(12, weight: .regular)).foregroundColor(Tellurion.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .tint(Tellurion.gold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .tellurionPanel()
    }

    @ViewBuilder
    private func footer(_ update: UpdateState.UpdateAvailable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if updates.waitingForAgents {
                note("Updating when \(updates.busyAgents == 1 ? "the agent finishes its" : "\(updates.busyAgents) agents finish their") turn. You can keep working.")
            } else if updates.busyAgents > 0 {
                note("\(updates.busyAgents == 1 ? "An agent is" : "\(updates.busyAgents) agents are") mid-turn. Everything reopens after the update, but a turn in progress stops.")
            } else {
                note("Takes a few seconds. Your tabs, agents and servers reopen where they were.")
            }
            HStack(spacing: 8) {
                Button("Skip this version") { update.reply(.skip) }
                    .buttonStyle(.plain)
                    .font(Tellurion.font(11))
                    .foregroundColor(Tellurion.muted)
                Spacer()
                Button("Later") { UpdateWindow.close() }
                    .keyboardShortcut(.cancelAction)
                if updates.waitingForAgents {
                    Button("Cancel waiting") { updates.cancelWaiting() }
                    Button("Update now") { updates.installNow() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                } else if updates.busyAgents > 0 {
                    Button("Update now") { updates.installNow() }
                    Button("Update when done") { updates.installWhenAgentsFinish() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Update and restart") { updates.installNow() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Progress

    private static let steps = ["Download", "Prepare", "Restart"]

    private func progress(step: Int, fraction: Double?, detail: String?, cancel: (() -> Void)?) -> some View {
        let version = item?.displayVersionString ?? ""
        let titles = ["Downloading", "Preparing", "Restarting into"]
        return VStack(spacing: 22) {
            Spacer(minLength: 0)
            TellurionSigil(size: 64)
            VStack(spacing: 6) {
                Text("\(titles[step]) Tellurion \(version)")
                    .font(Tellurion.font(17, weight: .semibold)).foregroundColor(Tellurion.text)
                Text("Your tabs, agents and servers reopen where they were.")
                    .font(Tellurion.font(12, weight: .regular)).foregroundColor(Tellurion.muted)
            }
            VStack(spacing: 8) {
                UpdateProgressBar(fraction: fraction, height: 8)
                HStack {
                    Text(detail ?? " ").font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                    Spacer()
                    if let fraction {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(Tellurion.font(11.5, weight: .semibold)).foregroundColor(Tellurion.gold).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: 360)
            HStack(spacing: 18) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 6) {
                        if index < step {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Tellurion.gold)
                        } else if index == step {
                            PixelSpinner(color: Tellurion.gold, pixel: 3)
                        } else {
                            Circle().strokeBorder(Tellurion.dim, lineWidth: 1).frame(width: 9, height: 9)
                        }
                        Text(name).font(Tellurion.font(11.5, weight: index == step ? .semibold : .regular))
                            .foregroundColor(index <= step ? Tellurion.text : Tellurion.dim)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if let cancel {
                    Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                }
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Pieces

    private func message<Buttons: View>(title: String, text: String?, spinner: Bool,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            TellurionSigil(size: 56)
            HStack(spacing: 8) {
                if spinner { PixelSpinner(color: Tellurion.gold, pixel: 3) }
                Text(title).font(Tellurion.font(16, weight: .semibold)).foregroundColor(Tellurion.text)
            }
            if let text {
                Text(text).font(Tellurion.font(12, weight: .regular)).foregroundColor(Tellurion.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { Spacer(); buttons() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            TellurionSigil(size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("UPDATE AVAILABLE")
                    .font(Tellurion.font(10, weight: .semibold)).kerning(1.2).foregroundColor(Tellurion.gold)
                Text(title).font(Tellurion.font(19, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(subtitle).font(Tellurion.font(12, weight: .regular)).foregroundColor(Tellurion.muted)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Tellurion.font(10.5))
            .foregroundColor(Tellurion.text.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Tellurion.raised))
            .overlay(Capsule().strokeBorder(Tellurion.line, lineWidth: 1))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
#endif

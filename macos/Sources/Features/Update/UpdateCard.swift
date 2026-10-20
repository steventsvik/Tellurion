#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Keeps Tellurion current: checks for a new release soon after launch and every hour,
/// and installs it when asked, now or once the agents have finished their turns.
final class ExtremeUpdates: ObservableObject {
    static let shared = ExtremeUpdates()

    /// Waiting for working agents to finish before installing.
    @Published private(set) var waitingForAgents = false
    @Published private(set) var busyAgents = 0

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private weak var controller: UpdateController?

    private init() {
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.agentsChanged() }
            .store(in: &cancellables)
    }

    /// Starts the checks. Only release builds with automatic checks on check by themselves.
    func start(_ controller: UpdateController) {
        self.controller = controller
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkQuietly() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkQuietly() }
        agentsChanged()
    }

    private func checkQuietly() {
        guard let controller, controller.updater.automaticallyChecksForUpdates,
              controller.viewModel.state.isIdle, controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    /// Agents in the middle of a turn: quitting would cut it off.
    static func workingAgents() -> Int {
        TerminalWindows.all.flatMap { Array($0.surfaceTree) }.filter { surface in
            guard let activity = VerticalTabsAgents.shared.info(for: surface)?.activity else { return false }
            return activity == .working || activity == .needsPermission
        }.count
    }

    private func agentsChanged() {
        let busy = Self.workingAgents()
        if busy != busyAgents { busyAgents = busy }
        if waitingForAgents && busy == 0 {
            waitingForAgents = false
            installNow()
        }
    }

    func installNow() {
        waitingForAgents = false
        controller?.installUpdate()
    }

    func installWhenAgentsFinish() {
        if Self.workingAgents() == 0 { installNow() } else { waitingForAgents = true }
    }

    func cancelWaiting() { waitingForAgents = false }
}

/// The update card at the top of the sidebar: what's new, an Update button, and a progress
/// bar while it downloads and installs.
struct UpdateCard: View {
    @ObservedObject var model: UpdateViewModel
    @ObservedObject private var updates = ExtremeUpdates.shared

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Extreme.gold.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Extreme.gold.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var content: AnyView? {
        switch model.state {
        case .updateAvailable(let update):
            return AnyView(available(version: update.appcastItem.displayVersionString))
        case .downloading(let download):
            let fraction = download.expectedLength.map { $0 > 0 ? Double(download.progress) / Double($0) : 0 }
            return AnyView(progress(title: "Downloading update", fraction: fraction, cancel: download.cancel))
        case .extracting(let extracting):
            return AnyView(progress(title: "Preparing update", fraction: extracting.progress, cancel: nil))
        case .installing:
            return AnyView(progress(title: "Restarting into the update", fraction: nil, cancel: nil))
        default:
            return nil
        }
    }

    private func available(version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(Extreme.gold).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                    Text("Tellurion \(version)").font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                }
                Spacer(minLength: 0)
                Button("What's new") { UpdateWindow.show() }
                .buttonStyle(.plain)
                .font(Extreme.font(10.5))
                .foregroundColor(Extreme.gold)
            }
            if updates.waitingForAgents {
                Text("Updating when \(updates.busyAgents == 1 ? "the agent finishes" : "\(updates.busyAgents) agents finish") their turn…")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                HStack(spacing: 6) {
                    Button("Update now") { updates.installNow() }.buttonStyle(ExtremeButtonStyle())
                    Button("Cancel") { updates.cancelWaiting() }.buttonStyle(ExtremeButtonStyle())
                }
            } else if updates.busyAgents > 0 {
                Text("\(updates.busyAgents == 1 ? "An agent is" : "\(updates.busyAgents) agents are") mid-turn. Everything reopens after the update, but a turn in progress stops.")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Update when done") { updates.installWhenAgentsFinish() }
                        .buttonStyle(ExtremeButtonStyle(prominent: true))
                    Button("Now") { updates.installNow() }.buttonStyle(ExtremeButtonStyle())
                }
            } else {
                Text("Takes a few seconds. Your tabs, agents and servers reopen where they were.")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { updates.installNow() } label: {
                    Text("Update and restart").frame(maxWidth: .infinity)
                }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
            }
        }
    }

    private func progress(title: String, fraction: Double?, cancel: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                Spacer()
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%").font(Extreme.font(11)).foregroundColor(Extreme.gold)
                        .monospacedDigit()
                }
            }
            UpdateProgressBar(fraction: fraction)
            HStack {
                Text("Your tabs, agents and servers reopen after the restart.")
                    .font(Extreme.font(10)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let cancel {
                    Button("Cancel", action: cancel).buttonStyle(.plain)
                        .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                }
            }
        }
    }
}

/// A slim gold bar: filled to `fraction`, or a sweeping segment while the length is unknown.
struct UpdateProgressBar: View {
    let fraction: Double?
    var height: CGFloat = 6
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Extreme.text.opacity(0.1))
                if let fraction {
                    Capsule().fill(Extreme.gold)
                        .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    Capsule().fill(Extreme.gold)
                        .frame(width: geometry.size.width * 0.3)
                        .offset(x: sweep ? geometry.size.width * 0.7 : 0)
                        // Only shown for the few seconds before the restart.
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: height)
    }
}
#endif

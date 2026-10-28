#if os(macOS)
import AppKit
import UserNotifications

/// Tells the user when a coding agent is waiting on them in a pane they aren't looking at:
/// a macOS notification (clicking it jumps to that pane) and a count on the Dock icon.
///
/// Only permission prompts and questions count as "waiting". The alert fires once when
/// the agent starts waiting; the Dock count drops as soon as the agent moves on.
final class AgentAlerts {
    static let shared = AgentAlerts()

    /// Posted when the number of waiting agents changes; the app delegate refreshes the badge.
    static let waitingCountDidChange = Notification.Name("com.steventsvik.ghostty-extreme.agentWaitingCountDidChange")

    private(set) var waitingCount = 0

    private init() {
        // A closed pane forgets its agent; recount once it's gone.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.recount() }
        }
    }

    /// Called after every agent event with the pane's activity before and after it.
    func agentChanged(on surface: Ghostty.SurfaceView,
                      from old: VerticalTabAgentActivity?,
                      to info: VerticalTabAgentInfo?) {
        if let info, Self.isWaiting(info.activity), old != info.activity,
           !VerticalTabsAgents.isBeingViewed(surface) {
            notify(info, on: surface)
        }
        recount()
    }

    static func isWaiting(_ activity: VerticalTabAgentActivity) -> Bool {
        activity == .needsPermission || activity == .needsInput
    }

    private func recount() {
        let count = VerticalTabsAgents.shared.count { Self.isWaiting($0.activity) }
        guard count != waitingCount else { return }
        waitingCount = count
        NotificationCenter.default.post(name: Self.waitingCountDidChange, object: nil)
    }

    private func notify(_ info: VerticalTabAgentInfo, on surface: Ghostty.SurfaceView) {
        let title = info.activity == .needsPermission
            ? "\(info.name) needs your permission"
            : "\(info.name) has a question"
        let body = info.detail ?? info.task ?? "Waiting for you"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [surface] _, _ in
            center.getNotificationSettings { [surface] settings in
                guard settings.authorizationStatus == .authorized else { return }
                DispatchQueue.main.async { [weak surface] in
                    // Permission prompts get Allow / Deny buttons (see AgentPermissions).
                    surface?.showUserNotification(
                        title: title, body: body,
                        category: info.activity == .needsPermission ? AgentPermissions.notificationCategory
                                                                    : Ghostty.userNotificationCategory)
                }
            }
        }
    }
}
#endif

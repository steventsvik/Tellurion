#if os(macOS)
import AppKit
import UserNotifications

/// Answers an agent's permission prompt from outside its pane: the sidebar card, Mission
/// Control or the notification.
///
/// It only ever answers a prompt that's on screen right now. The hooks can say an agent
/// is waiting a moment after it moved on, and a stray key is not harmless: Escape interrupts
/// a working agent and Enter submits whatever is typed. So the pane's screen has to show
/// Claude Code's or Codex's prompt, with "1. Yes" selected, before any key is sent.
@MainActor
enum AgentPermissions {
    enum Answer { case allow, deny }

    nonisolated static let notificationCategory = "com.steventsvik.ghostty-extreme.permission"
    nonisolated static let allowAction = "com.steventsvik.ghostty-extreme.permission.allow"
    nonisolated static let denyAction = "com.steventsvik.ghostty-extreme.permission.deny"

    /// The notification category with Allow and Deny buttons.
    nonisolated static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: notificationCategory,
            actions: [
                UNNotificationAction(identifier: allowAction, title: "Allow"),
                UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction])
    }

    /// What the prompt on screen offers, or nil when there's no prompt to answer.
    struct Prompt: Equatable {
        /// "1. Yes" is selected, so Enter allows.
        let canAllow: Bool
        /// A "No … (esc)" option is shown, so Escape denies.
        let canDeny: Bool
    }

    /// The permission prompt in this pane, if its agent is waiting for permission and the
    /// prompt is on screen.
    static func prompt(on surface: Ghostty.SurfaceView) -> Prompt? {
        guard let info = VerticalTabsAgents.shared.info(for: surface), info.activity == .needsPermission,
              info.kind == .claude || info.kind == .codex else { return nil }
        return parse(surface.cachedVisibleContents.get())
    }

    /// Reads the prompt from the bottom of the screen. Codex and older Claude Code end their
    /// prompt with "No, and tell Claude/Codex what to do differently"; Claude Code 2.1.29x
    /// ends it with a numbered "No" and "Esc to cancel". Escape picks "No" in all of them.
    /// Both mark the selected option ("❯ 1. Yes" in Claude Code, "› Yes, proceed" in Codex).
    static func parse(_ screen: String) -> Prompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).map(String.init)
        func has(_ pattern: String) -> Bool { lines.contains { $0.range(of: pattern, options: .regularExpression) != nil } }
        guard has(#"No, and tell (Claude|Codex) what to do differently"#)
            || (has(#"^\s*[│|]?\s*[❯›>▶]?\s*[1-9]\.\s+No\s*$"#) && has(#"Esc to cancel"#)) else { return nil }
        // The options, top to bottom. Enter only allows when the first one ("Yes", not
        // "Yes, and don't ask again") is the selected one.
        let options = lines.filter { $0.range(of: #"^\s*[│|]?\s*[❯›>▶]?\s*(?:[1-9]\.\s+)?(Yes|No)\b"#, options: .regularExpression) != nil }
        guard let first = options.first, first.range(of: #"Yes\b"#, options: .regularExpression) != nil else { return nil }
        return Prompt(canAllow: first.range(of: #"[❯›>▶]\s*(?:[1-9]\.\s+)?Yes\b"#, options: .regularExpression) != nil,
                      canDeny: true)
    }

    /// Sends the answer if the prompt allows it. Returns whether a key was sent.
    @discardableResult
    static func answer(_ answer: Answer, on surface: Ghostty.SurfaceView) -> Bool {
        guard let prompt = prompt(on: surface), let model = surface.surfaceModel else { return false }
        switch answer {
        case .allow:
            guard prompt.canAllow else { return false }
            model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
            model.sendKeyEvent(.init(key: .enter, action: .release))
        case .deny:
            guard prompt.canDeny else { return false }
            model.sendKeyEvent(.init(key: .escape, action: .press, text: "\u{1b}"))
            model.sendKeyEvent(.init(key: .escape, action: .release))
        }
        return true
    }

    /// Handles Allow or Deny from a notification. Returns false for any other response.
    nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        let action = response.actionIdentifier
        guard action == allowAction || action == denyAction else { return false }
        let surfaceID = (response.notification.request.content.userInfo["surface"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { answerFromNotification(allow: action == allowAction, surfaceID: surfaceID) }
        return true
    }

    private static func answerFromNotification(allow: Bool, surfaceID: UUID?) {
        guard let surfaceID, let surface = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surfaceID) else { return }
        if !answer(allow ? .allow : .deny, on: surface) {
            // The prompt changed or is gone: show the pane instead of guessing.
            if let window = surface.window {
                window.makeKeyAndOrderFront(nil)
                Ghostty.moveFocus(to: surface)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif

#if os(macOS)
import SwiftUI

/// "Allow" and "Deny" for a pane's permission prompt, shown on its sidebar card and in
/// Mission Control while the prompt is on screen.
struct AgentPermissionButtons: View {
    let surface: Ghostty.SurfaceView
    let prompt: AgentPermissions.Prompt
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if prompt.canAllow {
                Button { AgentPermissions.answer(.allow, on: surface) } label: {
                    Label("Allow", systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .help("Choose \"Yes\" in the agent's prompt (Enter)")
            }
            if prompt.canDeny {
                Button { AgentPermissions.answer(.deny, on: surface) } label: {
                    Label("Deny", systemImage: "xmark").labelStyle(.titleAndIcon)
                }
                .buttonStyle(TellurionButtonStyle())
                .help("Choose \"No, and tell it what to do differently\" (Esc)")
            }
        }
        .controlSize(compact ? .small : .regular)
        .font(.system(size: compact ? 11 : 12, weight: .semibold))
    }
}
#endif

import SwiftUI

/// Tellurion's About window: what it is in one line, what it does in six, then the version
/// and where to go next.
struct AboutView: View {
    @Environment(\.openURL) var openURL

    private let githubURL = URL(string: "https://github.com/steventsvik/Tellurion")
    private let websiteURL = URL(string: "https://steventsvik.github.io/Tellurion/")

    /// Read the commit from the bundle.
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    private enum VersionConfig {
        case stable(version: String)
        case tip(commit: String?)
        case other(String)
        case none

        init(version: String?) {
            guard let version else { self = .none; return }
            if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                self = .stable(version: version)
                return
            }
            if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                self = .tip(commit: version)
                return
            }
            self = .other(version)
        }

        var url: URL? {
            switch self {
            case .stable(let version):
                let slug = version.replacingOccurrences(of: ".", with: "-")
                return URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)")
            default:
                return nil
            }
        }
    }

    private var versionConfig: VersionConfig { VersionConfig(version: version) }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    /// This version's release notes.
    private var whatsNewURL: URL? {
        guard let version else { return githubURL?.appendingPathComponent("releases") }
        return githubURL?.appendingPathComponent("releases/tag/extreme-\(version)")
    }

    private struct Highlight: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let highlights = [
        Highlight(symbol: "person.3.sequence.fill", title: "Every agent, one sidebar",
                  detail: "Claude Code, Codex, Gemini and a dozen more, with live status. You know the second one needs you."),
        Highlight(symbol: "chevron.left.forwardslash.chevron.right", title: "Watch the code change",
                  detail: "The editor follows each agent as it reads and edits, side by side when several work at once."),
        Highlight(symbol: "hand.raised.fill", title: "Answer from anywhere",
                  detail: "Allow or deny from the sidebar, a notification, Mission Control or your phone."),
        Highlight(symbol: "arrow.uturn.backward.circle.fill", title: "Undo any turn",
                  detail: "A snapshot before every prompt, and a review inbox for each agent's finished work."),
        Highlight(symbol: "cpu.fill", title: "Models on your Mac",
                  detail: "Ollama, LM Studio, Apple's own model. Private, offline, no account."),
        Highlight(symbol: "rectangle.split.3x1.fill", title: "Your window, your way",
                  detail: "Drag the tabs, terminal and panels into place. Visual Fix, ports, skills and more are a click away."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
                .padding(.bottom, 26)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(highlights) { HighlightCard(highlight: $0) }
            }
            .padding(.horizontal, 28)
            footer
                .padding(.top, 24)
                .padding(.bottom, 26)
        }
        .frame(width: 600)
        .background(background)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Extreme.core.opacity(0.25), radius: 18)
                .accessibilityLabel("Tellurion")
            Text("TELLURION")
                .font(Extreme.font(13, weight: .semibold))
                .kerning(5)
                .foregroundColor(Extreme.gold)
            Text("Mission control for your AI coding agents.")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Extreme.text)
                .multilineTextAlignment(.center)
            Text("Run as many agents as you like and see everything they do, live.\nOne terminal, every agent, nothing hidden.")
                .font(Extreme.font(12.5))
                .foregroundColor(Extreme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .textSelection(.enabled)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                if let url = whatsNewURL {
                    Button("What's new") { openURL(url) }.buttonStyle(ExtremeButtonStyle(prominent: true))
                }
                if let url = websiteURL {
                    Button("Website") { openURL(url) }.buttonStyle(ExtremeButtonStyle())
                }
                if let url = githubURL {
                    Button("GitHub") { openURL(url) }.buttonStyle(ExtremeButtonStyle())
                }
            }
            versionLine
            VStack(spacing: 3) {
                Text("Built on Ghostty by Mitchell Hashimoto and its contributors.")
                if let copyright { Text(copyright) }
            }
            .font(Extreme.font(10.5))
            .foregroundColor(Extreme.dim)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
        }
    }

    /// "Version 1.7.0 · build 12 · a1b2c3d", the commit linking to it on GitHub.
    private var versionLine: some View {
        HStack(spacing: 6) {
            if let version { Text("Version \(version)") }
            if let build, build != version { Text("·"); Text("build \(build)") }
            if let commit, !commit.isEmpty, let url = githubURL?.appendingPathComponent("commits/\(commit)") {
                Text("·")
                Link(destination: url) { Text(String(commit.prefix(9))).font(Extreme.mono(10.5)) }
            }
        }
        .font(Extreme.font(11))
        .foregroundColor(Extreme.muted)
        .textSelection(.enabled)
    }

    private var background: some View {
        ZStack {
            Extreme.ink
            // A soft glow behind the icon, in the core's cyan.
            RadialGradient(colors: [Extreme.core.opacity(0.10), .clear], center: .top, startRadius: 10, endRadius: 320)
            LinearGradient(colors: [.clear, Extreme.gold.opacity(0.05)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private struct HighlightCard: View {
        let highlight: Highlight

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: highlight.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Extreme.gold)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.ink))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlight.title)
                        .font(Extreme.font(12.5, weight: .semibold))
                        .foregroundColor(Extreme.text)
                    Text(highlight.detail)
                        .font(Extreme.font(11))
                        .foregroundColor(Extreme.muted)
                        .lineSpacing(1.5)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            // One height for every card, so the grid lines up.
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
            .background(shape.fill(Extreme.panel))
            .overlay(shape.strokeBorder(Extreme.line, lineWidth: 1))
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}

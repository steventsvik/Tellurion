#if os(macOS)
import SwiftUI

/// A design drawn small: a sidebar with tabs beside a terminal with a prompt, in the
/// design's own colors. Cards use it at thumbnail size, the editor at full size.
struct DesignPreview: View {
    let design: TellurionDesign
    /// 1 is the editor's size; cards use less.
    var scale: CGFloat = 1

    private var terminal: TerminalColors { DesignPreview.terminalColors(for: design) }
    private var chrome: ChromeColors {
        switch design.chrome {
        case .fixed(let colors): return colors
        case .auto(let accent, let ai): return .derived(from: terminal, accent: accent, ai: ai)
        }
    }

    /// The colors a design resolves to, using the live config for "mine".
    static func terminalColors(for design: TellurionDesign) -> TerminalColors {
        switch design.terminal {
        case .mine: return DesignStore.shared.currentTerminalColors
        case .theme(let name): return GhosttyThemes.colors(named: name) ?? DesignStore.shared.currentTerminalColors
        case .custom(let colors): return colors
        }
    }

    var body: some View {
        let chrome = chrome
        let terminal = terminal
        let pad = (CGFloat(design.window?.padding ?? 8) * 0.6 + 4) * scale
        let font = design.font.family ?? Tellurion.fontFamily
        HStack(spacing: 0) {
            sidebar(chrome)
                .frame(width: 96 * scale)
            Rectangle().fill(chrome.line.color).frame(width: 1)
            ZStack(alignment: .topLeading) {
                terminal.background.color.opacity(design.window?.opacity ?? 1)
                VStack(alignment: .leading, spacing: 3 * scale) {
                    line([("❯ ", terminal.ansi(2)), ("claude", terminal.foreground), ("  --resume", terminal.ansi(8))], font: font)
                    line([("  Reading ", terminal.ansi(8)), ("src/app.swift", terminal.ansi(4))], font: font)
                    line([("  + ", terminal.ansi(2)), ("let design = DesignStore.shared", terminal.foreground)], font: font)
                    line([("  - ", terminal.ansi(1)), ("static let gold = Color(…)", terminal.ansi(8))], font: font)
                    line([("  ✓ ", terminal.ansi(10)), ("tests ", terminal.foreground), ("42 passed", terminal.ansi(2)), ("  ", terminal.foreground), ("1 skipped", terminal.ansi(3))], font: font)
                    HStack(spacing: 0) {
                        Text("❯ ").font(.custom(font, size: 9 * scale)).foregroundColor(terminal.ansi(5).color)
                        cursor(terminal)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2 * scale) {
                        ForEach(0..<16, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5 * scale).fill(terminal.ansi(i).color).frame(width: 7 * scale, height: 7 * scale)
                        }
                    }
                }
                .padding(pad)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.ink.color)
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous).strokeBorder(chrome.line.color, lineWidth: 1))
    }

    private func sidebar(_ chrome: ChromeColors) -> some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 4 * scale) {
                PixelBitmap(rows: design.logo.rows, colors: design.logo.colors(in: chrome), pixel: 0.5 * scale)
                Text("TELLURION").font(.system(size: 5.5 * scale, weight: .semibold)).kerning(1.2 * scale).foregroundColor(chrome.gold.color)
            }
            .padding(.bottom, 2 * scale)
            tab("claude · api", detail: "Working", color: chrome.core.color, active: true, chrome: chrome)
            tab("codex · web", detail: "Needs you", color: chrome.warn.color, active: false, chrome: chrome)
            tab("zsh", detail: "~/Projects", color: chrome.dim.color, active: false, chrome: chrome)
            Spacer(minLength: 0)
            HStack(spacing: 3 * scale) {
                Circle().fill(chrome.live.color).frame(width: 3 * scale, height: 3 * scale)
                Text("3 agents").font(.system(size: 5.5 * scale)).foregroundColor(chrome.muted.color)
            }
        }
        .padding(7 * scale)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(chrome.ink.color)
    }

    private func tab(_ title: String, detail: String, color: Color, active: Bool, chrome: ChromeColors) -> some View {
        HStack(spacing: 4 * scale) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2 * scale, height: 12 * scale)
            VStack(alignment: .leading, spacing: 1.5 * scale) {
                Text(title).font(.system(size: 6 * scale, weight: .semibold)).foregroundColor(active ? chrome.text.color : chrome.muted.color)
                Text(detail).font(.system(size: 5 * scale)).foregroundColor(active ? color : chrome.dim.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5 * scale).padding(.vertical, 3.5 * scale)
        .background(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous).fill(active ? chrome.raised.color : chrome.panel.color))
        .overlay(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous).strokeBorder(active ? chrome.gold.color.opacity(0.5) : chrome.line.color, lineWidth: 0.5 * scale))
    }

    private func line(_ parts: [(String, DesignColor)], font: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.0).font(.custom(font, size: 9 * scale)).foregroundColor(part.1.color)
            }
        }
        .lineLimit(1)
    }

    private func cursor(_ terminal: TerminalColors) -> some View {
        let color = (terminal.cursor ?? terminal.foreground).color
        return Group {
            switch design.window?.cursor ?? .block {
            case .block: Rectangle().fill(color).frame(width: 5.5 * scale, height: 11 * scale)
            case .bar: Rectangle().fill(color).frame(width: 1.5 * scale, height: 11 * scale)
            case .underline: Rectangle().fill(color).frame(width: 5.5 * scale, height: 1.5 * scale).offset(y: 4.5 * scale)
            }
        }
    }
}

extension DesignStore {
    /// The terminal's colors right now, from the live config.
    var currentTerminalColors: TerminalColors {
        (NSApp.delegate as? AppDelegate).flatMap { TerminalColors(config: $0.ghostty.config) } ?? .tellurion
    }
}
#endif

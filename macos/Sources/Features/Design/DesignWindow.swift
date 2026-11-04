#if os(macOS)
import AppKit
import SwiftUI

/// The Design window: twenty templates that apply as you click, and Customize, where you
/// pick the terminal's colors, the chrome's accent, the font, the window and the logo.
enum DesignWindow {
    static let windowID = "design"

    static func show() {
        AgentToolWindows.show(id: windowID, title: "Design", size: NSSize(width: 1040, height: 720), followsDesign: false) {
            DesignWindowView()
        }
    }
}

private enum DesignMode: String, CaseIterable, Identifiable {
    case templates, customize
    var id: String { rawValue }
    var title: String { self == .templates ? "Templates" : "Customize" }
}

struct DesignWindowView: View {
    @ObservedObject private var store = DesignStore.shared
    @State private var mode: DesignMode = .templates

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                TellurionWindowTitle(icon: nil, title: "Design", subtitle: subtitle, sigil: true)
                    .id(store.revision)  // the sigil and colors follow the design
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(DesignMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                .accessibilityLabel("Templates or Customize")
                Button("Reset") { store.reset() }
                    .disabled(store.design.isStandardLook)
                    .help("Back to Tellurion as shipped, with your own terminal colors")
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 14)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            switch mode {
            case .templates: DesignGallery(customize: { mode = .customize })
            case .customize: DesignEditor()
            }
        }
    }

    private var subtitle: String {
        store.design.isStandardLook ? "Tellurion as shipped. Pick a template, or make it yours."
            : "In use: \(store.design.name)"
    }
}

// MARK: - Templates

private struct DesignGallery: View {
    @ObservedObject private var store = DesignStore.shared
    var customize: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.mine.isEmpty {
                    TellurionSectionLabel("Yours")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.mine) { design in
                            DesignCard(design: design, inUse: store.design.id == design.id, customize: customize,
                                       delete: { store.deleteFromMine(design.id) })
                        }
                    }
                }
                TellurionSectionLabel("Templates")
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(DesignTemplates.all) { design in
                        DesignCard(design: design, inUse: store.design.id == design.id, customize: customize, delete: nil)
                    }
                }
                Text("A template sets the terminal's colors, the chrome around it, the window and the cursor. Your Ghostty config keeps everything else; the design is written to tellurion-design.ghostty beside it.")
                    .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .id(store.revision)  // the cards recolor; the scroll position stays
        }
    }
}

private struct DesignCard: View {
    let design: TellurionDesign
    let inUse: Bool
    var customize: () -> Void
    var delete: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { DesignStore.shared.apply(design) } label: {
            VStack(alignment: .leading, spacing: 10) {
                DesignPreview(design: design, scale: 0.72)
                    .frame(height: 150)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(design.name).font(Tellurion.font(13, weight: .semibold)).foregroundColor(inUse ? Tellurion.gold : Tellurion.text)
                            if inUse {
                                Text("IN USE").font(Tellurion.font(9, weight: .bold)).kerning(1).foregroundColor(Tellurion.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Tellurion.gold))
                            }
                        }
                        Text(design.tagline.isEmpty ? "Your design" : design.tagline)
                            .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if inUse {
                        Button("Customize", action: customize).buttonStyle(TellurionButtonStyle())
                    } else if let delete, hovering {
                        Button(action: delete) {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(TellurionButtonStyle()).help("Delete this design")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tellurionPanel(active: inUse)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(design.name)\(inUse ? ", in use" : "")")
    }
}

// MARK: - Customize

private struct DesignEditor: View {
    @ObservedObject private var store = DesignStore.shared
    @State private var draft: TellurionDesign = DesignStore.shared.design
    @State private var original: TellurionDesign = DesignStore.shared.design
    @State private var themeSearch = ""
    @State private var drawing = false

    private var terminal: TerminalColors { DesignPreview.terminalColors(for: draft) }
    private var chrome: ChromeColors {
        switch draft.chrome {
        case .fixed(let colors): return colors
        case .auto(let accent, let ai): return .derived(from: terminal, accent: accent, ai: ai)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DesignPreview(design: draft, scale: 1.25)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                HStack(spacing: 12) {
                    PixelBitmap(rows: draft.logo.rows, colors: draft.logo.colors(in: chrome), pixel: 2)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chrome.ink.color))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(chrome.line.color, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Logo").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                        Text("Drawn in pixels with the design's colors: the new-tab splash, the tool windows and, if you like, the Dock.")
                            .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Draw…") { drawing = true }
                            Toggle("Dock icon", isOn: $draft.logo.dockIcon).toggleStyle(.switch).font(Tellurion.font(11.5))
                                .foregroundColor(Tellurion.text)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .tellurionPanel()
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            Rectangle().fill(Tellurion.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    terminalSection
                    chromeSection
                    fontSection
                    windowSection
                }
                .padding(20)
            }
            .frame(width: 400)
        }
        .onChange(of: draft) { store.preview($0) }
        .onReceive(store.$design) { design in
            // A template applied elsewhere while editing (the Dock icon reset, or Reset).
            if design != draft, design.id != draft.id { draft = design; original = design }
        }
        .sheet(isPresented: $drawing) {
            LogoEditorView(logo: $draft.logo, chrome: chrome) { drawing = false }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .accessibilityLabel("Design name")
            Button("Save to Yours") { store.saveToMine(draft) }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .help("Keeps this design under Templates → Yours")
            Spacer()
            Button("Revert") { draft = original; store.apply(original) }
                .disabled(draft == original)
        }
    }

    // MARK: Terminal colors

    private enum TerminalKind: String, CaseIterable, Identifiable {
        case mine, theme, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mine: return "Mine"
            case .theme: return "Theme"
            case .custom: return "Custom"
            }
        }
    }

    private var terminalKind: TerminalKind {
        switch draft.terminal {
        case .mine: return .mine
        case .theme: return .theme
        case .custom: return .custom
        }
    }

    private var themeName: String? {
        if case .theme(let name) = draft.terminal { return name }
        return nil
    }

    private var filteredThemes: [String] {
        let query = themeSearch.trimmingCharacters(in: .whitespaces)
        let names = query.isEmpty ? GhosttyThemes.names : GhosttyThemes.names.filter { $0.localizedCaseInsensitiveContains(query) }
        return Array(names.prefix(400))
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Terminal colors")
            Picker("", selection: Binding(get: { terminalKind }, set: { setTerminalKind($0) })) {
                ForEach(TerminalKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Where the terminal colors come from")
            switch terminalKind {
            case .mine:
                note("Whatever your Ghostty config says. The chrome can still follow those colors.")
            case .theme:
                TextField("Search \(GhosttyThemes.names.count) themes", text: $themeSearch).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search themes")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(filteredThemes, id: \.self) { name in
                                themeRow(name)
                            }
                        }
                    }
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tellurion.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tellurion.line, lineWidth: 1))
                    .onAppear { if let themeName { proxy.scrollTo(themeName, anchor: .center) } }
                }
            case .custom:
                customColors
            }
        }
    }

    private func themeRow(_ name: String) -> some View {
        let selected = name == themeName
        let colors = GhosttyThemes.colors(named: name)
        return Button { draft.terminal = .theme(name) } label: {
            HStack(spacing: 8) {
                if let colors {
                    HStack(spacing: 1) {
                        ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { i in
                            Rectangle().fill(colors.ansi(i + 1).color).frame(width: 5, height: 12)
                        }
                    }
                    .padding(2)
                    .background(colors.background.color)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(name).font(Tellurion.font(11.5)).foregroundColor(selected ? Tellurion.gold : Tellurion.text).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Tellurion.gold) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Tellurion.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(name)
    }

    private var customColors: some View {
        let colors = customTerminal
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                colorWell("Background", colors.background) { c in setCustom { $0.background = c } }
                colorWell("Text", colors.foreground) { c in setCustom { $0.foreground = c } }
                colorWell("Cursor", colors.cursor ?? colors.foreground) { c in setCustom { $0.cursor = c } }
                colorWell("Selection", colors.selectionBackground ?? colors.ansi(8)) { c in setCustom { $0.selectionBackground = c } }
            }
            Text("ANSI colors").font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
            ForEach([0, 8], id: \.self) { base in
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { i in
                        ColorPicker("", selection: Binding(get: { colors.ansi(base + i).color },
                                                           set: { c in setCustom { $0.palette[base + i] = DesignColor(c) } }),
                                    supportsOpacity: false)
                            .labelsHidden().frame(width: 36)
                            .accessibilityLabel("ANSI color \(base + i)")
                    }
                }
            }
            HStack(spacing: 8) {
                Menu("Start from a theme…") {
                    ForEach(DesignTemplates.all.compactMap { template -> String? in
                        if case .theme(let name) = template.terminal { return name }
                        return nil
                    }, id: \.self) { name in
                        Button(name) { if let c = GhosttyThemes.colors(named: name) { draft.terminal = .custom(c) } }
                    }
                    Button("Tellurion") { draft.terminal = .custom(.tellurion) }
                    Button("Mine") { draft.terminal = .custom(store.currentTerminalColors) }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private var customTerminal: TerminalColors {
        if case .custom(let colors) = draft.terminal { return colors }
        return terminal
    }

    private func setCustom(_ edit: (inout TerminalColors) -> Void) {
        var colors = customTerminal
        if colors.palette.count < 16 { colors.palette += Array(repeating: colors.foreground, count: 16 - colors.palette.count) }
        edit(&colors)
        draft.terminal = .custom(colors)
    }

    private func setTerminalKind(_ kind: TerminalKind) {
        switch kind {
        case .mine: draft.terminal = .mine
        case .theme: draft.terminal = .theme(themeName ?? "Catppuccin Mocha")
        case .custom: draft.terminal = .custom(terminal)
        }
    }

    // MARK: Chrome

    private var chromeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Chrome")
            Toggle(isOn: Binding(get: { if case .auto = draft.chrome { return true } else { return false } },
                                 set: { on in draft.chrome = on ? .auto(accent: chrome.gold, ai: chrome.core) : .fixed(chrome) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Follow the terminal's colors").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text("The sidebar, panels and tool windows take their ink, text and hairlines from the terminal")
                        .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            switch draft.chrome {
            case .auto(let accent, let ai):
                HStack(spacing: 14) {
                    colorWell("Accent", accent ?? chrome.gold) { c in draft.chrome = .auto(accent: c, ai: ai) }
                    colorWell("AI", ai ?? chrome.core) { c in draft.chrome = .auto(accent: accent, ai: c) }
                    Button("From the palette") { draft.chrome = .auto(accent: nil, ai: nil) }
                        .disabled(accent == nil && ai == nil)
                        .help("Take the accent and AI colors from the terminal's ANSI yellow and cyan")
                }
                note("Accent is for what matters: the active tab, buttons, the logo. AI is for agents at work.")
            case .fixed(let colors):
                fixedChrome(colors)
            }
        }
    }

    private func fixedChrome(_ colors: ChromeColors) -> some View {
        func well(_ title: String, _ path: WritableKeyPath<ChromeColors, DesignColor>) -> some View {
            colorWell(title, colors[keyPath: path]) { c in
                var next = colors
                next[keyPath: path] = c
                draft.chrome = .fixed(next)
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) { well("Ink", \.ink); well("Panel", \.panel); well("Raised", \.raised); well("Hairline", \.line); well("Frame", \.lineStrong) }
            HStack(spacing: 14) { well("Accent", \.gold); well("Bronze", \.bronze); well("AI", \.core); well("Text", \.text); well("Muted", \.muted) }
            HStack(spacing: 14) { well("Dim", \.dim); well("Live", \.live); well("Warn", \.warn); well("Danger", \.danger) }
            Button("Derive from the terminal") { draft.chrome = .fixed(.derived(from: terminal, accent: colors.gold, ai: colors.core)) }
        }
    }

    // MARK: Font

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Font")
            HStack(spacing: 12) {
                Picker("Family", selection: Binding(get: { draft.font.family ?? "" }, set: { draft.font.family = $0.isEmpty ? nil : $0 })) {
                    Text("From your config").tag("")
                    Divider()
                    ForEach(GhosttyThemes.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                Picker("Size", selection: Binding(get: { draft.font.size ?? 0 }, set: { draft.font.size = $0 == 0 ? nil : $0 })) {
                    Text("Config").tag(0.0)
                    Divider()
                    ForEach([10.0, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24], id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .frame(width: 110)
            }
            .font(Tellurion.font(11.5))
        }
    }

    // MARK: Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Window")
            Toggle(isOn: Binding(get: { draft.window != nil }, set: { draft.window = $0 ? WindowLook() : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set the window").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text("Opacity, blur, padding and the cursor. Off leaves them to your config.")
                        .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                }
            }
            .toggleStyle(.switch)
            if let window = draft.window {
                let binding = Binding(get: { draft.window ?? window }, set: { draft.window = $0 })
                slider("Opacity", value: binding.opacity, in: 0.5...1, step: 0.01, label: String(format: "%.0f%%", window.opacity * 100))
                slider("Blur", value: Binding(get: { Double(window.blur) }, set: { binding.wrappedValue.blur = Int($0) }), in: 0...60, step: 1,
                       label: window.blur == 0 ? "Off" : "\(window.blur)")
                    .disabled(window.opacity >= 1)
                slider("Padding", value: Binding(get: { Double(window.padding) }, set: { binding.wrappedValue.padding = Int($0) }), in: 0...40, step: 1,
                       label: "\(window.padding) pt")
                HStack(spacing: 12) {
                    Text("Cursor").font(Tellurion.font(11.5)).foregroundColor(Tellurion.text).frame(width: 60, alignment: .leading)
                    Picker("", selection: binding.cursor) {
                        ForEach(DesignCursorStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Toggle("Blink", isOn: binding.cursorBlink).toggleStyle(.checkbox).font(Tellurion.font(11.5)).foregroundColor(Tellurion.text)
                }
            }
        }
    }

    // MARK: Bits

    private func colorWell(_ title: String, _ color: DesignColor, set: @escaping (DesignColor) -> Void) -> some View {
        VStack(spacing: 4) {
            ColorPicker("", selection: Binding(get: { color.color }, set: { set(DesignColor($0)) }), supportsOpacity: false)
                .labelsHidden().frame(width: 44)
            Text(title).font(Tellurion.font(10, weight: .regular)).foregroundColor(Tellurion.muted)
        }
        .accessibilityLabel(title)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Tellurion.font(11.5)).foregroundColor(Tellurion.text).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
            Text(label).font(Tellurion.mono(10.5)).foregroundColor(Tellurion.muted).frame(width: 44, alignment: .trailing)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted).fixedSize(horizontal: false, vertical: true)
    }
}
#endif

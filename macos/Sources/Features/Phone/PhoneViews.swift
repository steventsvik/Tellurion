#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The phone setup window: Tailscale step by step, then the devices that can reach this Mac.
enum PhoneSetup {
    static let windowID = "phone"

    static func show() {
        guard TellurionSettings.isOn(.phone) else { return }
        TailscaleMonitor.shared.watch()
        AgentToolWindows.show(id: windowID, title: "Phone", size: NSSize(width: 560, height: 600)) {
            PhoneSetupView()
        }
    }
}

// MARK: - Corner badge

/// Bottom right of the terminal: a small phone that says whether phone access is live.
/// Dim when it's off, gold while it waits for a phone, green with a phone connected.
/// Hovering names the state; clicking opens the Phone window.
struct PhoneCornerBadge: View {
    @ObservedObject private var monitor = TailscaleMonitor.shared
    @ObservedObject private var server = PhoneServer.shared
    @ObservedObject private var phones = PhoneDevices.shared
    @State private var hovering = false

    private var connectedNames: [String] {
        phones.devices.filter { server.connected[$0.id] != nil }.map(\.name)
    }

    private var label: String {
        guard server.running else {
            return monitor.status.isReady ? "Phone access off" : "Phone · \(monitor.status.summary)"
        }
        if server.servePort == nil && !PhoneServer.devMode { return "Phone · starting" }
        let names = connectedNames
        switch names.count {
        case 0: return "Phone · on, no phone connected"
        case 1: return "Phone · live · \(names[0])"
        default: return "Phone · live · \(names.count) phones"
        }
    }

    private var color: Color {
        guard server.running else { return Tellurion.dim }
        if server.error != nil { return Tellurion.danger }
        return server.connected.isEmpty ? Tellurion.gold : Tellurion.live
    }

    var body: some View {
        Button(action: PhoneSetup.show) {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    PixelIconView(icon: .phone, color: server.running ? color : Tellurion.muted, pixel: 1.2)
                    Circle().fill(color).frame(width: 5, height: 5).offset(x: 3, y: -2)
                }
                if hovering {
                    Text(label)
                        .font(Tellurion.font(11, weight: .medium))
                        .foregroundColor(Tellurion.text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, hovering ? 9 : 6)
            .frame(height: 22)
            .background(Capsule().fill(Tellurion.panel.opacity(hovering ? 0.96 : 0.75)))
            .overlay(Capsule().stroke(hovering ? Tellurion.lineStrong : Tellurion.line, lineWidth: 1))
            .opacity(hovering || server.running ? 1 : 0.7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help("Use this terminal from your phone. Click to set up, pair a phone or see who's connected.")
        .accessibilityLabel(label)
    }
}

// MARK: - Setup window

private struct PhoneSetupView: View {
    @ObservedObject private var monitor = TailscaleMonitor.shared
    @ObservedObject private var server = PhoneServer.shared
    @ObservedObject private var phones = PhoneDevices.shared

    private enum StepState { case done, current, later }

    @State private var showSetup = false
    /// A phone was removed but the list couldn't be saved.
    @State private var removeFailed = false
    /// The Glasses block is showing its QR; the phone's steps aside.
    @State private var pairingGlasses = false

    /// Tailscale is ready for phone access: the window leads with pairing and phones.
    private func ready(_ s: TailscaleStatus) -> Bool { s.state == .running && s.magicDNS && s.httpsEnabled }

    var body: some View {
        let status = monitor.status
        VStack(alignment: .leading, spacing: 0) {
            TellurionWindowTitle(icon: .phone, title: "Phone",
                               subtitle: "Use this Mac's terminal from your phone, over your own private Tailscale network")
                .padding(.horizontal, 22)
                .padding(.top, 34)
                .padding(.bottom, 16)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ready(status) {
                        access
                        devices(status)
                        setupSummary(status)
                    } else {
                        checklist(status)
                        if status.state == .running { devices(status) }
                    }
                    if let error = monitor.error {
                        Text(error)
                            .font(Tellurion.font(11))
                            .foregroundColor(Tellurion.danger)
                            .textSelection(.enabled)
                    }
                    Text("Tellurion only uses Tailscale inside your own tailnet. It never turns on Funnel, which would put your terminal on the public internet.")
                        .font(Tellurion.font(10.5))
                        .foregroundColor(Tellurion.dim)
                        .padding(.top, 4)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear(perform: pairIfFirstPhone)
        .onChange(of: server.servePort) { _ in pairIfFirstPhone() }
    }

    /// No phone paired yet: have the code ready, since that's what the window is for.
    private func pairIfFirstPhone() {
        guard server.running, server.url != nil, phones.devices.isEmpty, phones.pairingCode == nil else { return }
        phones.newPairingCode()
    }

    private func checklist(_ status: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Install Tailscale", state: installState(status),
                 detail: "Free for personal use. It connects your Mac and phone privately, on Wi-Fi or cellular.") {
                Button(ToolPath.find("brew") == nil ? "Download…" : "Install with Homebrew") { monitor.install() }
                    .buttonStyle(TellurionButtonStyle(prominent: true))
            }
            step(2, "Turn it on and sign in", state: connectState(status), detail: connectDetail(status)) {
                if status.state == .appNotRunning {
                    Button("Open Tailscale") { monitor.openApp() }.buttonStyle(TellurionButtonStyle(prominent: true))
                } else {
                    Button(status.state == .needsLogin ? "Sign in…" : "Turn on") { monitor.connect() }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .disabled(monitor.busy)
                }
            }
            step(3, "Turn on HTTPS for your tailnet", state: httpsState(status),
                 detail: "One switch on Tailscale's DNS page: MagicDNS and HTTPS Certificates. The phone app needs it to install to your home screen and notify you. This page notices when it's on.") {
                Button("Open DNS settings…") { monitor.openHTTPSSettings() }.buttonStyle(TellurionButtonStyle(prominent: true))
            }
            step(4, "Add your phone", state: phoneState(status),
                 detail: "Install Tailscale on your phone and sign in with the same account.") {
                HStack(alignment: .center, spacing: 14) {
                    QRCodeView(text: "https://tailscale.com/download", size: 104)
                    Text("Scan with your phone's camera")
                        .font(Tellurion.font(11))
                        .foregroundColor(Tellurion.muted)
                }
            }
        }
    }

    /// The finished checklist, folded away.
    private func setupSummary(_ status: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showSetup.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Tellurion.live)
                    Text("Tailscale is set up").font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
                    if let login = status.loginName {
                        Text(login).font(Tellurion.font(11)).foregroundColor(Tellurion.muted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: showSetup ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Tellurion.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSetup { checklist(status) }
        }
        .padding(.top, 8)
    }

    // MARK: Steps

    private func installState(_ s: TailscaleStatus) -> StepState { s.state == .notInstalled ? .current : .done }

    private func connectState(_ s: TailscaleStatus) -> StepState {
        switch s.state {
        case .notInstalled: return .later
        case .running: return .done
        default: return .current
        }
    }

    private func connectDetail(_ s: TailscaleStatus) -> String {
        switch s.state {
        case .appNotRunning: return "Tailscale is installed but not running."
        case .stopped: return "Tailscale is switched off."
        case .needsLogin: return "Sign in in your browser; this page continues by itself."
        case .starting: return "Connecting…"
        default: return s.dnsName.map { "Connected as \($0)" } ?? "Connected"
        }
    }

    private func httpsState(_ s: TailscaleStatus) -> StepState {
        guard s.state == .running else { return .later }
        return s.magicDNS && s.httpsEnabled ? .done : .current
    }

    private func phoneState(_ s: TailscaleStatus) -> StepState {
        guard s.state == .running else { return .later }
        return s.phones.isEmpty ? .current : .done
    }

    private func step<Action: View>(_ number: Int, _ title: String, state: StepState, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Tellurion.live.opacity(0.18) : state == .current ? Tellurion.gold.opacity(0.18) : Tellurion.raised)
                Circle()
                    .strokeBorder(state == .done ? Tellurion.live : state == .current ? Tellurion.gold : Tellurion.line, lineWidth: 1)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Tellurion.live)
                } else {
                    Text("\(number)").font(Tellurion.font(11, weight: .semibold))
                        .foregroundColor(state == .current ? Tellurion.gold : Tellurion.dim)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Tellurion.font(13, weight: .semibold))
                    .foregroundColor(state == .later ? Tellurion.dim : Tellurion.text)
                if state != .done || number == 2 {
                    Text(detail)
                        .font(Tellurion.font(11))
                        .foregroundColor(state == .later ? Tellurion.dim : Tellurion.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .current { action().padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(state == .current ? Tellurion.panel : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state == .current ? Tellurion.gold.opacity(0.35) : Tellurion.line.opacity(0.6)))
    }

    // MARK: Devices

    private func devices(_ s: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TellurionSectionLabel("On your tailnet")
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundColor(Tellurion.gold)
                Text("This Mac").font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(s.dnsName ?? s.ip ?? "").font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .textSelection(.enabled).lineLimit(1)
            }
            ForEach(s.phones) { phone in
                HStack(spacing: 8) {
                    Image(systemName: "iphone").foregroundColor(phone.online ? Tellurion.live : Tellurion.dim)
                    Text(phone.name).font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text(phone.online ? "online" : "offline").font(Tellurion.font(11))
                        .foregroundColor(phone.online ? Tellurion.live : Tellurion.dim)
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Phone access

    private var access: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Phone access")
            if !server.running {
                Text("Turn it on to use this Mac's terminal from your paired phones. Only devices signed in to your own Tailscale account can reach it, and each phone has to be paired here first.")
                    .font(Tellurion.font(11))
                    .foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on phone access") { server.turnOn() }
                    .buttonStyle(TellurionButtonStyle(prominent: true))
                    .disabled(monitor.busy)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Circle().fill(server.connected.isEmpty ? Tellurion.gold : Tellurion.live).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveSummary).font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
                        if let url = server.url {
                            Text(url.absoluteString).font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                                .textSelection(.enabled)
                        } else {
                            Text(monitor.busy ? "Setting up Tailscale Serve…" : "Waiting for Tailscale Serve")
                                .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                        }
                    }
                    Spacer()
                    Button("Turn off") { server.turnOff() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tellurion.panel))
                if !pairingGlasses { pairing }
                pairedList
                if TellurionSettings.isOn(.glasses) { GlassesBlock(pairing: $pairingGlasses) }
            }
            if removeFailed {
                Text("The phone is disconnected, but the list of phones couldn't be saved: it would be paired again the next time Tellurion opens.")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = server.error {
                Text(error).font(Tellurion.font(11)).foregroundColor(Tellurion.danger).textSelection(.enabled)
            }
        }
        .padding(.top, 8)
    }

    private var liveSummary: String {
        switch server.connected.count {
        case 0: return "On · waiting for a phone"
        case 1: return "Live · " + (phones.devices.first { server.connected[$0.id] != nil }?.name ?? "1 phone") + " connected"
        default: return "Live · \(server.connected.count) phones connected"
        }
    }

    @ViewBuilder
    private var pairing: some View {
        if let code = phones.pairingCode, let url = server.url {
            HStack(alignment: .center, spacing: 16) {
                QRCodeView(text: url.absoluteString + "#pair=" + code, size: 150)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with your phone's camera").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text(code)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundColor(Tellurion.gold)
                        .textSelection(.enabled)
                    Text("Or open \(url.host ?? "the address") on your phone and type this code. It works once, for 10 minutes. Your phone has to be on Tailscale.")
                        .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { phones.cancelPairing() }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tellurion.panel))
        } else if server.url != nil {
            Button(phones.devices.isEmpty ? "Pair a phone…" : "Pair another phone…") { phones.newPairingCode() }
                .buttonStyle(TellurionButtonStyle(prominent: phones.devices.isEmpty))
        }
    }

    @ViewBuilder
    private var pairedList: some View {
        if !phones.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(phones.devices) { device in
                    let online = server.connected[device.id] != nil
                    HStack(spacing: 8) {
                        Image(systemName: device.isGlasses ? "eyeglasses" : "iphone").foregroundColor(online ? Tellurion.live : Tellurion.muted)
                        Text(device.name).font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
                        Text(online ? "connected" : device.lastSeen.map { "last used " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "")
                            .font(Tellurion.font(11)).foregroundColor(online ? Tellurion.live : Tellurion.dim)
                        Spacer()
                        Button("Remove") { removeFailed = !phones.remove(device.id) }
                    }
                }
                if phones.devices.count > 1 {
                    Button("Remove all phones") { removeFailed = !phones.removeAll() }
                }
            }
        }
    }
}

/// A QR code for `text`, drawn crisp at any size.
struct QRCodeView: View {
    let text: String
    let size: CGFloat

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
#endif

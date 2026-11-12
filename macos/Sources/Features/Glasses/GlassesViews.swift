#if os(macOS)
import SwiftUI

/// The Glasses block of the Phone window: pairing Even G2 glasses, by QR from the Even
/// app or by approving the app on the glasses' menu, and how to put it on that menu.
struct GlassesBlock: View {
    /// The glasses' QR is showing, so the phone's steps aside.
    @Binding var pairing: Bool
    @ObservedObject private var server = PhoneServer.shared
    @ObservedObject private var phones = PhoneDevices.shared
    @ObservedObject private var requests = GlassesPairing.shared
    @State private var showPacking = false

    /// This Mac's address without the slash at the end: what the packaged app is built for.
    private var origin: String? {
        server.url.map { $0.absoluteString.hasSuffix("/") ? String($0.absoluteString.dropLast()) : $0.absoluteString }
    }

    private var packCommand: String? {
        guard let origin, let script = Bundle.main.resourceURL?.appendingPathComponent("PhoneWeb/glasses/pack/pack.sh") else { return nil }
        return "sh \(Ghostty.Shell.quote(script.path)) \(origin)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TellurionSectionLabel("Glasses")
            Text("On Even G2 glasses: your projects and tabs with each tab's terminal, the orchestrator's own screen, the tools, Allow or Deny for a permission prompt, a few keys (Enter, Esc, Ctrl-C) for an agent's pane, and talking to an agent or the orchestrator. What you say is turned into text on this Mac.")
                .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let request = requests.pending {
                approval(request)
            }
            if pairing, let code = phones.pairingCode, let origin {
                qr(origin + "/glasses/#pair=" + code)
            } else if origin != nil {
                HStack(spacing: 10) {
                    Button("Pair glasses…") {
                        phones.newPairingCode()
                        requests.open()
                        pairing = true
                    }
                    if requests.isOpen, requests.pending == nil {
                        Text("Waiting for the glasses to ask, for 5 minutes")
                            .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    }
                }
            }
            packing
        }
        .padding(.top, 8)
        .onChange(of: phones.pairingCode) { code in
            if code == nil { pairing = false }
        }
    }

    private func approval(_ request: GlassesPairRequests.Request) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Glasses want to pair").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(request.code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(Tellurion.gold)
                Text("Approve only if your glasses show this number.")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
            }
            Spacer()
            Button("Deny") { requests.answer(code: request.code, approve: false) }
            Button("Approve") { requests.answer(code: request.code, approve: true) }
                .buttonStyle(TellurionButtonStyle(prominent: true))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tellurion.panel))
    }

    private func qr(_ address: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            QRCodeView(text: address, size: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text("In the Even app: Even Hub → Scan QR").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Tellurion.gold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It works once, for 10 minutes. Your phone has to be on Tailscale. An app already on the glasses' menu asks by itself instead: a number shows here to approve.")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel") {
                    phones.cancelPairing()
                    requests.close()
                    pairing = false
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tellurion.panel))
    }

    /// A scanned QR lasts as long as the Even app keeps it open. To stay on the glasses'
    /// menu the app is packaged for this Mac's address and uploaded to your own Even Hub account.
    @ViewBuilder
    private var packing: some View {
        if let packCommand {
            Button { withAnimation(.easeOut(duration: 0.15)) { showPacking.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showPacking ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Keep it on the glasses' menu").font(Tellurion.font(11, weight: .medium))
                }
                .foregroundColor(Tellurion.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showPacking {
                Text("Build the app for this Mac's address, then upload it to your Even Hub account and make it your beta build:")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(packCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Tellurion.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tellurion.panel))
            }
        }
    }
}
#endif

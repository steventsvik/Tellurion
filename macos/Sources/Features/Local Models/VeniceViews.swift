#if os(macOS)
import AppKit
import SwiftUI

/// The Local Models window's Venice section: connect an account, then pick a model. The list is
/// read when it appears, and on Refresh.
struct VeniceSection: View {
    @ObservedObject private var account = VeniceAccount.shared
    @State private var key = ""
    @State private var search = ""
    @State private var uncensoredOnly = false
    @State private var privateOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtremeSectionLabel("On Venice") {
                if account.busy { ProgressView().controlSize(.small) }
                if account.connected {
                    Button("Refresh", action: account.refresh)
                        .buttonStyle(.plain).font(Extreme.font(11)).foregroundColor(Extreme.dim)
                    Button("Disconnect", action: account.disconnect)
                        .buttonStyle(.plain).font(Extreme.font(11)).foregroundColor(Extreme.dim)
                }
            }
            Text("Abliterated and other models on Venice's servers, from your own account, in a chat or driving Codex with its usual tools. "
                 + "Unlike models on this Mac, what you send goes to Venice. Nothing is sent until you open one.")
                .font(Extreme.font(11)).foregroundColor(Extreme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let error = account.error {
                Text(error).font(Extreme.font(12)).foregroundColor(Extreme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if account.connected { list } else { connect }
        }
        .onAppear { if account.connected, account.models.isEmpty { account.refresh() } }
    }

    private var connect: some View {
        HStack(spacing: 8) {
            SecureField("Venice API key", text: $key)
                .textFieldStyle(.plain).font(Extreme.mono(12))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Extreme.raised))
                .onSubmit(submit)
            Button("Connect", action: submit)
                .buttonStyle(ExtremeButtonStyle(prominent: true))
                .disabled(key.isEmpty || account.busy)
            Button("Get a Key") { NSWorkspace.shared.open(VeniceAPI.keysPage) }
                .buttonStyle(ExtremeButtonStyle())
                .help("Keys are made on Venice's site while you're signed in")
        }
    }

    private func submit() {
        guard !key.isEmpty, !account.busy else { return }
        account.connect(key: key)
        key = ""
    }

    private var shown: [VeniceAPI.Model] {
        let words = search.lowercased().split(separator: " ")
        return account.models.filter { model in
            (!uncensoredOnly || model.uncensored) && (!privateOnly || model.isPrivate)
                && words.allSatisfy { model.id.lowercased().contains($0) || model.name.lowercased().contains($0) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search \(account.models.count) models", text: $search)
                    .textFieldStyle(.plain).font(Extreme.font(12))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Extreme.raised))
                Toggle("Uncensored", isOn: $uncensoredOnly).toggleStyle(.checkbox).font(Extreme.font(11))
                Toggle("Private", isOn: $privateOnly).toggleStyle(.checkbox).font(Extreme.font(11))
            }
            Text("Star a model to keep it in the sidebar. Private: Venice says nothing is stored. Anonymized: the model's own provider may store what's sent.")
                .font(Extreme.font(11)).foregroundColor(Extreme.dim)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { VeniceRow(model: $0) }
                }
            }
            .frame(maxHeight: 300)
            VeniceOptions()
        }
    }
}

/// What Codex sessions on Venice may use, for the ones started from now on.
private struct VeniceOptions: View {
    @ObservedObject private var account = VeniceAccount.shared
    @State private var memory = VeniceCodexOption.memory.isOn
    @State private var computerUse = VeniceCodexOption.computerUse.isOn
    @State private var secretFiles = VeniceCodexOption.secretFiles.isOn
    @State private var webSearch = VeniceCodexOption.webSearch.isOn
    @State private var limit = VeniceSpendMeter.shared.limit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex sessions you start from now on").font(Extreme.font(11, weight: .medium)).foregroundColor(Extreme.dim)
            option("Search the web with Exa", "Sends what it searches for to Exa, free within Exa's rate limit. Results count as tokens on Venice.",
                   .webSearch, $webSearch)
            option("Use my Codex memory", "Sends what Codex remembers about you and your projects to Venice. Venice sessions never add to it.",
                   .memory, $memory)
            option("Allow computer use", "Lets the model control apps and your browser on this Mac, outside Codex's sandbox.",
                   .computerUse, $computerUse)
            option("Let it read secret files", "Leaves .env files, SSH keys and saved logins readable, and known key formats in what's sent. Off, they stay on this Mac. Its other files can still be read.",
                   .secretFiles, $secretFiles)
            spendingRow
        }
    }

    private var spendingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Stop for the day at $").font(Extreme.font(12))
                TextField("", value: $limit, format: .number)
                    .textFieldStyle(.plain).font(Extreme.mono(12)).frame(width: 52)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Extreme.raised))
                    .onChange(of: limit) { VeniceSpendMeter.shared.limit = $0 }
            }
            Text(spendingText)
                .font(Extreme.font(11))
                .foregroundColor(VeniceSpendMeter.isOver(account.spending, limit: limit) ? Extreme.danger : Extreme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var spendingText: String {
        let money = { (value: Double) in "$" + String(format: "%.2f", value) }
        let limitNote = limit > 0 ? "" : " No limit is set."
        guard let spending = account.spending else { return "Nothing spent today." + limitNote }
        let stopped = VeniceSpendMeter.isOver(spending, limit: limit) ? " Limit reached: requests are stopped." : ""
        return "Spent today \(money(spending.spent)) · Balance \(money(spending.balance)), including anything else using this key." + stopped + limitNote
    }

    private func option(_ title: String, _ detail: String, _ option: VeniceCodexOption, _ value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(title, isOn: value).toggleStyle(.checkbox).font(Extreme.font(12))
                .onChange(of: value.wrappedValue) { on in
                    do {
                        try option.set(on)
                    } catch {
                        account.error = error.localizedDescription
                        value.wrappedValue = option.isOn
                    }
                }
            Text(detail).font(Extreme.font(11)).foregroundColor(Extreme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VeniceRow: View {
    let model: VeniceAPI.Model
    @ObservedObject private var account = VeniceAccount.shared

    private var isStarred: Bool { account.starred[model.id] != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button { account.toggleStar(model) } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 11)).foregroundColor(isStarred ? Extreme.gold : Extreme.dim)
            }
            .buttonStyle(.plain)
            .help(isStarred ? "Take it out of the sidebar" : "Keep it in the sidebar")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.name).font(Extreme.font(12, weight: .medium)).foregroundColor(Extreme.text)
                        .lineLimit(1).truncationMode(.middle)
                    if model.uncensored { tag("UNCENSORED", Extreme.muted) }
                    tag(model.isPrivate ? "PRIVATE" : "ANONYMIZED", model.isPrivate ? Extreme.muted : Extreme.warn)
                }
                Text(model.detail).font(Extreme.font(11)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Chat") {
                guard let owner = LocalModelsWindow.frontTerminal else { return }
                LocalModelSessions.open(item, from: owner)
                owner.window?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(ExtremeButtonStyle())
            .help("Chat with \(model.name) on Venice: below the chat in front, or in a new tab")
            Button("Open in Codex") {
                guard let owner = LocalModelsWindow.frontTerminal else { return }
                LocalModelSessions.openCodex(item, name: model.name, from: owner)
                owner.window?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(ExtremeButtonStyle(prominent: true))
            .disabled(!model.worksInCodex)
            .help(model.worksInCodex ? "Codex, with its usual tools and setup, on \(model.name)"
                  : "This model can't call tools, which Codex needs")
        }
        .padding(.vertical, 3)
    }

    private var item: LocalModel {
        LocalModel(host: .venice, name: model.id, size: nil, detail: "Cloud", loaded: false, memory: nil, gpuShare: nil,
                   uncensored: model.uncensored, isPrivate: model.isPrivate)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(Extreme.font(8.5, weight: .bold)).foregroundColor(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Extreme.line, lineWidth: 1))
    }
}
#endif

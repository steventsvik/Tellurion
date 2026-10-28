#if os(macOS)
import AppKit
import SwiftUI

/// Models on Hugging Face that Ollama can run (GGUF files), from its public API: no account
/// is needed to browse or to download a public model. Ollama downloads one by name,
/// `hf.co/<repo>:<quantization>`. Gated models (some official releases) need an account
/// and an accepted license, so they only link to their page.
///
/// Searched once when the window first shows the section, and again only when you pick a
/// filter, search or press refresh. Nothing is polled.
@MainActor
final class HuggingFaceCatalog: ObservableObject {
    static let shared = HuggingFaceCatalog()

    enum Filter: String, CaseIterable, Identifiable {
        case popular = "Popular", coding = "Coding", uncensored = "Uncensored"
        var id: String { rawValue }

        /// What it searches for (nil: the most downloaded overall).
        var search: String? {
            switch self {
            case .popular: return nil
            case .coding: return "coder"
            case .uncensored: return "abliterated"
            }
        }
    }

    struct Model: Identifiable, Equatable {
        let repo: String
        let downloads: Int
        let likes: Int
        let gated: Bool
        /// The file Tellurion would download, once its size is known: a good default
        /// quantization (Q4_K_M if there is one).
        var quantization: String?
        var bytes: Int64?
        /// Its files have been looked up (quantization stays nil if none suits Ollama).
        var checked = false
        var id: String { repo }

        /// What Ollama pulls.
        var ollamaName: String? { quantization.map { "hf.co/\(repo):\($0)" } }
        var page: URL? { URL(string: "https://huggingface.co/\(repo)") }
    }

    @Published private(set) var models: [Model] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var filter: Filter = .popular
    private var lastQuery: String?
    private var cache: [String: [Model]] = [:]

    nonisolated private static let api = URL(string: "https://huggingface.co/api/models")!

    /// The list for `filter`, or for `text` when there is one. Cached until refresh.
    func load(text: String = "", refresh: Bool = false) {
        let search = text.trimmingCharacters(in: .whitespaces).isEmpty ? filter.search : text.trimmingCharacters(in: .whitespaces)
        let key = search ?? ""
        if !refresh, key == lastQuery, !models.isEmpty { return }
        lastQuery = key
        if !refresh, let cached = cache[key] {
            models = cached
            return
        }
        loading = true
        error = nil
        Task { [weak self] in
            let result = await Self.search(search)
            guard let self, self.lastQuery == key else { return }
            self.loading = false
            switch result {
            case .success(let found):
                self.models = found
                self.cache[key] = found
                await self.fillSizes(for: key)
            case .failure(let message):
                self.models = []
                self.error = message
            }
        }
    }

    /// Looks up each model's files (one request each) to pick a quantization and its size.
    private func fillSizes(for key: String) async {
        let repos = models.map(\.repo)
        await withTaskGroup(of: (String, String?, Int64?).self) { group in
            for repo in repos { group.addTask { await Self.pickFile(repo) } }
            for await (repo, quantization, bytes) in group {
                guard lastQuery == key, let index = models.firstIndex(where: { $0.repo == repo }) else { continue }
                models[index].quantization = quantization
                models[index].bytes = bytes
                models[index].checked = true
            }
        }
        cache[key] = models
    }

    // MARK: API

    private enum Result { case success([Model]), failure(String) }

    nonisolated private static func search(_ text: String?) async -> Result {
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "filter", value: "gguf"), URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "40")]
        if let text { query.append(URLQueryItem(name: "search", value: text)) }
        components.queryItems = query
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure("Couldn't reach Hugging Face. Check your connection, then refresh.")
        }
        // Only models you chat with: not speech, image or detection models.
        let chat: Set<String> = ["text-generation", "image-text-to-text"]
        let models = list.compactMap { item -> Model? in
            guard let repo = item["id"] as? String else { return nil }
            if let tag = item["pipeline_tag"] as? String, !chat.contains(tag) { return nil }
            let gated = (item["gated"] as? Bool) ?? ((item["gated"] as? String).map { $0 != "false" } ?? false)
            return Model(repo: repo, downloads: item["downloads"] as? Int ?? 0, likes: item["likes"] as? Int ?? 0,
                         gated: gated, quantization: nil, bytes: nil)
        }
        return .success(Array(models.prefix(15)))
    }

    /// Preferred quantizations, best balance first; files split into parts are skipped.
    nonisolated private static let preferred = ["Q4_K_M", "UD-Q4_K_XL", "Q4_K_S", "IQ4_XS", "Q4_0", "Q5_K_M", "Q8_0"]

    nonisolated private static func pickFile(_ repo: String) async -> (String, String?, Int64?) {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (repo, nil, nil) }
        let files = (info["siblings"] as? [[String: Any]] ?? []).compactMap { file -> (String, Int64)? in
            guard let name = file["rfilename"] as? String, name.hasSuffix(".gguf"), !name.contains("-of-"),
                  !name.lowercased().contains("mmproj") else { return nil }
            return (name, (file["size"] as? NSNumber)?.int64Value ?? 0)
        }
        for quantization in preferred {
            if let file = files.first(where: { $0.0.uppercased().hasSuffix("-\(quantization).GGUF") || $0.0.uppercased().hasSuffix(".\(quantization).GGUF") }) {
                return (repo, quantization, file.1)
            }
        }
        return (repo, nil, nil)
    }
}

/// The Hugging Face part of the Local Models window.
struct HuggingFaceSection: View {
    /// Ollama's model names, to show what's already downloaded.
    let installed: Set<String>
    @ObservedObject private var catalog = HuggingFaceCatalog.shared
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtremeSectionLabel("Hugging Face") {
                Button { catalog.load(text: text, refresh: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundColor(Extreme.dim).help("Search again")
            }
            Text("Any public GGUF model on Hugging Face, downloaded through Ollama. No account needed.")
                .font(Extreme.font(11)).foregroundColor(Extreme.dim)
            HStack(spacing: 8) {
                Picker("Show", selection: $catalog.filter) {
                    ForEach(HuggingFaceCatalog.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                TextField("Search Hugging Face", text: $text, onCommit: { catalog.load(text: text) })
                    .textFieldStyle(.roundedBorder).font(Extreme.font(12))
            }
            if catalog.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").font(Extreme.font(11)).foregroundColor(Extreme.dim) }
                    .padding(.vertical, 6)
            } else if let error = catalog.error {
                Text(error).font(Extreme.font(11)).foregroundColor(Extreme.warn)
            } else {
                VStack(spacing: 2) {
                    ForEach(catalog.models) { HuggingFaceRow(model: $0, installed: isInstalled($0)) }
                }
            }
        }
        .onAppear { catalog.load(text: text) }
        .onChange(of: catalog.filter) { _ in
            text = ""
            catalog.load()
        }
    }

    private func isInstalled(_ model: HuggingFaceCatalog.Model) -> Bool {
        let prefix = "hf.co/\(model.repo)".lowercased()
        return installed.contains { $0.lowercased().hasPrefix(prefix) }
    }
}

private struct HuggingFaceRow: View {
    let model: HuggingFaceCatalog.Model
    let installed: Bool
    @ObservedObject private var models = LocalModelsModel.shared
    @State private var hovering = false

    private var fits: Bool {
        guard let bytes = model.bytes else { return true }
        return Double(bytes) * 1.2 + 6_000_000_000 <= Double(LocalModelsModel.memory)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.repo).font(Extreme.mono(12)).foregroundColor(fits ? Extreme.text : Extreme.dim)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(Extreme.font(11)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? (model.checked ? "" : "…"))
                    .font(Extreme.font(11, weight: .medium)).foregroundColor(fits ? Extreme.muted : Extreme.warn)
                Text("\(Self.short(model.downloads)) downloads").font(Extreme.font(10)).foregroundColor(Extreme.dim)
            }
            .frame(width: 96, alignment: .trailing)
            action.frame(width: 96)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Extreme.raised : .clear))
        .onHover { hovering = $0 }
    }

    private var detail: String {
        if model.gated { return "Needs a Hugging Face account and its license accepted" }
        if let quantization = model.quantization { return "\(quantization) · \(model.likes) likes" }
        return model.checked ? "No file Ollama can run: see its page" : "\(model.likes) likes"
    }

    @ViewBuilder
    private var action: some View {
        if installed {
            Text("Downloaded").font(Extreme.font(11)).foregroundColor(Extreme.live)
        } else if !model.checked && !model.gated {
            ProgressView().controlSize(.small)
        } else if model.gated || model.ollamaName == nil {
            Button("Open page") { if let page = model.page { NSWorkspace.shared.open(page) } }
                .buttonStyle(ExtremeButtonStyle())
        } else if let name = model.ollamaName, let progress = models.downloads[name] {
            VStack(spacing: 2) {
                ProgressView(value: progress ?? 0).progressViewStyle(.linear).tint(Extreme.gold)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Starting…").font(Extreme.font(10)).foregroundColor(Extreme.dim)
            }
        } else if let name = model.ollamaName {
            Button("Download") { models.download(name) }
                .buttonStyle(ExtremeButtonStyle())
                .help(fits ? "Download \(name) through Ollama" : "Probably too big for this Mac's memory")
        }
    }

    private static func short(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return "\(count / 1_000)K"
        default: return "\(count)"
        }
    }
}
#endif

#if os(macOS)
import SwiftUI

/// Models to download from the Local Models window: the most popular on ollama.com in each
/// size, and the most popular uncensored (abliterated) builds. Download counts and sizes were
/// read from ollama.com on 2026-10-15; counts are for the whole model family.
struct CatalogModel: Identifiable {
    let name: String
    let note: String
    /// Download size, which is roughly the memory it needs while loaded.
    let gigabytes: Double
    /// "120M", the family's downloads on ollama.com.
    let downloads: String
    var tags: [String] = []
    var id: String { name }

    var size: String {
        gigabytes < 1 ? "\(Int((gigabytes * 1000).rounded())) MB" : String(format: gigabytes < 10 ? "%.1f GB" : "%.0f GB", gigabytes)
    }

    /// Fits this Mac: the model, plus room for macOS and the apps already open.
    var fits: Bool {
        gigabytes * 1.2 + 6 <= Double(LocalModelsModel.memory) / 1_000_000_000
    }
}

enum ModelCatalog {
    enum Tier: String, CaseIterable, Identifiable {
        case tiny = "Tiny", small = "Small", medium = "Medium", large = "Large", huge = "Huge"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .tiny: return "Under 2 GB · any Mac, instant answers"
            case .small: return "2 to 5 GB · 8 GB Macs"
            case .medium: return "5 to 10 GB · 16 GB Macs"
            case .large: return "10 to 25 GB · 32 GB Macs"
            case .huge: return "Over 25 GB · 64 GB Macs and up"
            }
        }
    }

    static let popular: [Tier: [CatalogModel]] = [
        .tiny: [
            CatalogModel(name: "gemma3:1b", note: "Google's smallest; quick replies", gigabytes: 0.806, downloads: "41M"),
            CatalogModel(name: "qwen3.5:0.8b", note: "Alibaba's newest, smallest; sees images", gigabytes: 1.2, downloads: "22M", tags: ["vision"]),
            CatalogModel(name: "deepseek-r1:1.5b", note: "Reasons step by step before answering", gigabytes: 1.1, downloads: "94M", tags: ["thinking"]),
            CatalogModel(name: "llama3.2:1b", note: "Meta's small model", gigabytes: 1.3, downloads: "86M"),
        ],
        .small: [
            CatalogModel(name: "llama3.2:3b", note: "Meta; a solid everyday model", gigabytes: 2.0, downloads: "86M"),
            CatalogModel(name: "qwen3:4b", note: "Strong for its size; reasons first", gigabytes: 2.5, downloads: "40M", tags: ["thinking"]),
            CatalogModel(name: "qwen3.5:4b", note: "Alibaba's newest; sees images", gigabytes: 3.3, downloads: "22M", tags: ["vision", "thinking"]),
            CatalogModel(name: "gemma3:4b", note: "Google; sees images", gigabytes: 3.4, downloads: "41M", tags: ["vision"]),
        ],
        .medium: [
            CatalogModel(name: "llama3.1:8b", note: "The most downloaded model on Ollama", gigabytes: 4.9, downloads: "120M"),
            CatalogModel(name: "deepseek-r1:8b", note: "Reasoning: math, logic, careful answers", gigabytes: 5.2, downloads: "94M", tags: ["thinking"]),
            CatalogModel(name: "qwen3:8b", note: "Good all-rounder; reasons first", gigabytes: 5.2, downloads: "40M", tags: ["thinking"]),
            CatalogModel(name: "gemma4:e4b", note: "Google's newest; images and audio", gigabytes: 6.6, downloads: "27M", tags: ["vision"]),
            CatalogModel(name: "qwen3.5:9b", note: "Alibaba's newest; sees images", gigabytes: 6.6, downloads: "22M", tags: ["vision", "thinking"]),
            CatalogModel(name: "phi4:14b", note: "Microsoft; strong at reasoning and math", gigabytes: 9.1, downloads: "7.8M"),
        ],
        .large: [
            CatalogModel(name: "gpt-oss:20b", note: "OpenAI's open model", gigabytes: 14, downloads: "14M", tags: ["thinking"]),
            CatalogModel(name: "mistral-small3.2:24b", note: "Mistral; follows instructions well", gigabytes: 15, downloads: "2.5M", tags: ["vision"]),
            CatalogModel(name: "gemma4:26b", note: "Google's newest, larger", gigabytes: 16, downloads: "27M", tags: ["vision"]),
            CatalogModel(name: "qwen3.8:27b", note: "Alibaba's latest; coding and research", gigabytes: 18, downloads: "3.9M", tags: ["vision", "thinking"]),
            CatalogModel(name: "qwen3-coder:30b", note: "Best here for code", gigabytes: 19, downloads: "10M", tags: ["code"]),
            CatalogModel(name: "qwen3.6:35b", note: "Strong at agentic coding", gigabytes: 23, downloads: "7.1M", tags: ["vision", "thinking"]),
        ],
        .huge: [
            CatalogModel(name: "llama3.3:70b", note: "Meta's largest everyday model", gigabytes: 43, downloads: "4.2M"),
            CatalogModel(name: "deepseek-r1:70b", note: "Reasoning, full strength", gigabytes: 43, downloads: "94M", tags: ["thinking"]),
            CatalogModel(name: "gpt-oss:120b", note: "OpenAI's larger open model", gigabytes: 65, downloads: "14M", tags: ["thinking"]),
            CatalogModel(name: "qwen3.5:122b", note: "Alibaba's largest that runs locally", gigabytes: 81, downloads: "22M", tags: ["vision", "thinking"]),
        ],
    ]

    /// Most downloaded first. Abliterated: the model's refusals removed from its weights, by
    /// community publishers (mostly huihui_ai), not the original makers.
    static let uncensored: [CatalogModel] = [
        CatalogModel(name: "dolphin3:8b", note: "Dolphin 3, Llama 3.1 based; the classic", gigabytes: 4.9, downloads: "4.2M"),
        CatalogModel(name: "llama2-uncensored:7b", note: "The original uncensored Llama; older", gigabytes: 3.8, downloads: "2.7M"),
        CatalogModel(name: "dolphin-mistral:7b", note: "Dolphin on Mistral; good at code", gigabytes: 4.1, downloads: "1.8M"),
        CatalogModel(name: "dolphin-phi:2.7b", note: "Small and fast", gigabytes: 1.6, downloads: "1.6M"),
        CatalogModel(name: "huihui_ai/gemma-4-abliterated:e4b", note: "Gemma 4, abliterated", gigabytes: 9.6, downloads: "1.3M", tags: ["vision"]),
        CatalogModel(name: "huihui_ai/deepseek-r1-abliterated:8b", note: "DeepSeek R1 reasoning, abliterated", gigabytes: 5.0, downloads: "743K", tags: ["thinking"]),
        CatalogModel(name: "huihui_ai/qwen3.5-abliterated:9b", note: "Qwen 3.5, abliterated", gigabytes: 6.6, downloads: "679K", tags: ["vision", "thinking"]),
        CatalogModel(name: "huihui_ai/qwen3.5-abliterated:4B", note: "Qwen 3.5 small, abliterated", gigabytes: 3.3, downloads: "679K", tags: ["vision", "thinking"]),
        CatalogModel(name: "huihui_ai/gpt-oss-abliterated:20b", note: "OpenAI's open model, abliterated", gigabytes: 14, downloads: "411K", tags: ["thinking"]),
        CatalogModel(name: "huihui_ai/Qwen3.6-abliterated:27b", note: "Qwen 3.6, abliterated", gigabytes: 17, downloads: "407K", tags: ["vision", "thinking"]),
        CatalogModel(name: "huihui_ai/qwen3-abliterated:4b", note: "Qwen 3 small, abliterated", gigabytes: 2.5, downloads: "353K", tags: ["thinking"]),
        CatalogModel(name: "orcarouter/Qwen3.8-27B-Uncensored", note: "Qwen 3.8, abliterated; most popular of its size", gigabytes: 18, downloads: "228K", tags: ["vision", "thinking"]),
        CatalogModel(name: "huihui_ai/llama3.3-abliterated:70b", note: "Llama 3.3 70B, abliterated", gigabytes: 43, downloads: "60K"),
        CatalogModel(name: "huihui_ai/llama3.2-abliterate:3b", note: "Llama 3.2 small, abliterated", gigabytes: 2.2, downloads: "52K"),
    ]

    /// The size that suits this Mac best, opened first. Worked out once.
    static let bestTier: Tier = {
        let memory = Double(LocalModelsModel.memory) / 1_073_741_824
        switch memory {
        case ..<12: return .small
        case ..<24: return .medium
        case ..<48: return .large
        default: return .huge
        }
    }()
}

/// The Download part of the Local Models window.
struct ModelCatalogView: View {
    /// Names already downloaded ("qwen3:4b"), shown as such.
    let installed: Set<String>
    @ObservedObject private var models = LocalModelsModel.shared
    @State private var tier = ModelCatalog.bestTier
    @AppStorage("LocalModelsShowUncensored") private var showUncensored = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                TellurionSectionLabel("Popular")
                Picker("Size", selection: $tier) {
                    ForEach(ModelCatalog.Tier.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(tier.detail + (tier == ModelCatalog.bestTier ? " · best fit for this Mac" : ""))
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                VStack(spacing: 2) {
                    ForEach(ModelCatalog.popular[tier] ?? []) { CatalogRow(model: $0, installed: isInstalled($0)) }
                }
            }
            HuggingFaceSection(installed: installed)
            VStack(alignment: .leading, spacing: 8) {
                TellurionSectionLabel("Uncensored") {
                    Button(showUncensored ? "Hide" : "Show") { showUncensored.toggle() }
                        .buttonStyle(.plain).font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                }
                if showUncensored {
                    Text("Abliterated and uncensored builds answer without refusing. They're community versions, "
                         + "not from the original makers, and can be less accurate. Most downloaded first.")
                        .font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 2) {
                        ForEach(ModelCatalog.uncensored) { CatalogRow(model: $0, installed: isInstalled($0)) }
                    }
                }
            }
        }
    }

    /// Ollama lists a model as "name:tag", and the default tag as "name:latest".
    private func isInstalled(_ model: CatalogModel) -> Bool {
        installed.contains(model.name) || installed.contains(model.name + ":latest")
    }
}

private struct CatalogRow: View {
    let model: CatalogModel
    let installed: Bool
    @ObservedObject private var models = LocalModelsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name).font(Tellurion.mono(12)).foregroundColor(model.fits ? Tellurion.text : Tellurion.dim)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(model.tags, id: \.self) { tag in
                        Text(tag.uppercased()).font(Tellurion.font(8.5, weight: .bold)).foregroundColor(Tellurion.muted)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Tellurion.line, lineWidth: 1))
                    }
                }
                Text(model.note).font(Tellurion.font(11)).foregroundColor(Tellurion.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.size).font(Tellurion.font(11, weight: .medium)).foregroundColor(model.fits ? Tellurion.muted : Tellurion.warn)
                Text("\(model.downloads) downloads").font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
            }
            .frame(width: 96, alignment: .trailing)
            if installed {
                Text("Downloaded").font(Tellurion.font(11)).foregroundColor(Tellurion.live).frame(width: 84)
            } else if let progress = models.downloads[model.name] {
                VStack(spacing: 2) {
                    ProgressView(value: progress ?? 0).progressViewStyle(.linear).tint(Tellurion.gold)
                    Text(progress.map { "\(Int($0 * 100))%" } ?? "Starting…").font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
                }
                .frame(width: 84)
            } else {
                Button("Download") { models.download(model.name) }
                    .buttonStyle(TellurionButtonStyle())
                    .frame(width: 84)
                    .help(model.fits ? "Download \(model.name) through Ollama" : "Probably too big for this Mac's memory")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Tellurion.raised : .clear))
        .onHover { hovering = $0 }
    }
}
#endif

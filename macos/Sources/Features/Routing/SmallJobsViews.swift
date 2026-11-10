#if os(macOS)
import Foundation
import SwiftUI

/// The Small jobs block in Settings, there while the feature is on: which model on this Mac
/// gets them, and where the last few ran.
struct SmallJobsSettingsBlock: View {
    @ObservedObject private var settings = TellurionSettings.shared
    @ObservedObject private var log = SmallJobLog.shared
    @AppStorage(SmallJobs.modelKey) private var chosen = ""
    @State private var models: [SmallJobModel] = []

    var body: some View {
        if settings.isOn(.smallJobs) {
            VStack(alignment: .leading, spacing: 10) {
                TellurionSectionLabel("Small jobs")
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model").font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                        Text(detail).font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $chosen) {
                        Text("Automatic").tag("")
                        ForEach(models) { Text(Self.title($0)).tag($0.id) }
                        // The one picked earlier, while its server is stopped.
                        if !chosen.isEmpty, !models.contains(where: { $0.id == chosen }) {
                            Text("\(chosen) (not available)").tag(chosen)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .accessibilityLabel("Model for small jobs")
                }
                .padding(10)
                .tellurionPanel()
                Text(recent).font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Asked once each time Settings shows the block; nothing is polled.
            .task { models = await SmallJobClient.live.models().filter { !$0.embedding } }
        }
    }

    private var detail: String {
        chosen.isEmpty
            ? "Automatic uses a model that's already loaded, or loads a small one. A job that doesn't fit, takes too long or comes back wrong goes on to Claude Code or Codex."
            : "Loaded when a job needs it. A job that doesn't fit, takes too long or comes back wrong goes on to Claude Code or Codex."
    }

    private var recent: String {
        guard let summary = SmallJobLog.summary(log.entries) else {
            return models.isEmpty ? "No models found in Ollama or LM Studio, so every job goes on as before."
                : "No jobs yet. Try Suggest in a review's Commit."
        }
        return [summary, SmallJobLog.lastReason(log.entries).map { "Last one sent on: \($0)" }].compactMap { $0 }.joined(separator: ". ") + "."
    }

    static func title(_ model: SmallJobModel) -> String {
        "\(model.name) · \(model.host.rawValue)" + (model.loaded ? " · loaded" : "")
    }
}
#endif

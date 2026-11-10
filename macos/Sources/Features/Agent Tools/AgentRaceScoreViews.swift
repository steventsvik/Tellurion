#if os(macOS)
import AppKit
import SwiftUI

extension AgentRaceScores {
    static let windowID = "race-scoreboard"

    /// The full scoreboard: standings and the history of decided races.
    static func showScoreboard() {
        guard TellurionSettings.isOn(.races) else { return }
        AgentToolWindows.show(id: windowID, title: "Race Scoreboard", size: NSSize(width: 780, height: 600)) {
            AgentRaceScoreboardView()
        }
    }
}

/// Wins, win rate and median time per agent (and per model, when known) for one project
/// or for all of them, by kind of task. Used in the race setup window and on the scoreboard.
struct AgentRaceTrackRecord: View {
    /// The repository the numbers are for; nil shows every project.
    let root: String?
    /// Offers "This project" and "Everywhere". Without it, `root` alone decides.
    var choosesScope = true

    @ObservedObject private var scores = AgentRaceScores.shared
    @State private var everywhere = false
    @State private var category: AgentRaceCategory?

    private var scope: String? { choosesScope && everywhere ? nil : root }

    var body: some View {
        let agents = AgentRaceScores.standings(scores.records, root: scope, category: category)
        let models = AgentRaceScores.standings(scores.records, root: scope, category: category, byModel: true)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Track record").font(Tellurion.font(12))
                Spacer()
                if choosesScope, root != nil {
                    Picker("", selection: $everywhere) {
                        Text("This project").tag(false)
                        Text("Everywhere").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                Picker("", selection: $category) {
                    Text("All tasks").tag(AgentRaceCategory?.none)
                    ForEach(AgentRaceCategory.allCases) { category in
                        Text(category.label).tag(AgentRaceCategory?.some(category))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            .controlSize(.small)
            if agents.isEmpty {
                Text(emptyText)
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(agents) { agent in
                    row(agent)
                    ForEach(models.filter { $0.agent == agent.agent }.prefix(3)) { model in
                        row(model)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if scores.records.isEmpty {
            return "Nothing here yet. It fills in as races are decided: each time you keep one agent's work, that's a win for it."
        }
        return "No races between different agents here yet. It fills in as races are decided."
    }

    private func row(_ standing: AgentRaceScores.Standing) -> some View {
        HStack(spacing: 8) {
            if let model = standing.model {
                Text(model).font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 26)
            } else {
                AgentBadge(kind: standing.kind, size: 18)
                Text(standing.kind.displayName).font(Tellurion.font(12))
            }
            Spacer(minLength: 8)
            Text("won \(standing.wins) of \(standing.races)")
                .frame(width: 96, alignment: .trailing)
            Text("\(Int((standing.rate * 100).rounded()))%")
                .frame(width: 40, alignment: .trailing)
            Text(standing.medianSeconds.map { "median \(AgentRaceScores.duration($0))" } ?? "")
                .foregroundColor(Tellurion.muted)
                .frame(width: 96, alignment: .trailing)
        }
        .font(Tellurion.font(11).monospacedDigit())
    }
}

/// One line under the task in race setup, shown only when the history is clear enough.
struct AgentRaceAdviceLine: View {
    let advice: AgentRaceScores.Advice
    let use: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar").font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
            Text(advice.text).font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Use", action: use).controlSize(.small)
        }
    }
}

/// The scoreboard window: standings on top, then every decided race.
struct AgentRaceScoreboardView: View {
    @ObservedObject private var scores = AgentRaceScores.shared
    /// The root of the project shown; nil for all of them.
    @State private var project: String?

    private struct Project: Identifiable {
        let root: String
        let name: String
        var id: String { root }
    }

    private var projects: [Project] {
        var seen = Set<String>()
        return scores.records.filter { seen.insert($0.root).inserted }
            .map { Project(root: $0.root, name: $0.project) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let shown = AgentRaceScores.filter(scores.records, root: project, category: nil)
        VStack(alignment: .leading, spacing: 0) {
            header
            AgentRaceTrackRecord(root: project, choosesScope: false)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            if shown.isEmpty {
                Text("No decided races yet. Keep one agent's work in a race, or clean up a race where every agent finished, and it's listed here.")
                    .font(Tellurion.font(12)).foregroundColor(Tellurion.muted)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { record in
                            row(record)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flag.checkered.2.crossed").font(Tellurion.font(20)).foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Scoreboard").font(Tellurion.font(15))
                Text("Whose work you kept, by project and kind of task. Kept on this Mac only, without the prompts or the changes.")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: $project) {
                Text("All projects").tag(String?.none)
                ForEach(projects) { project in
                    Text(project.name).tag(String?.some(project.root))
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Menu {
                Button("Forget this project's history") { confirmForget(project) }
                    .disabled(project == nil)
                Button("Forget all") { confirmForget(nil) }
                    .disabled(scores.records.isEmpty)
            } label: { Label("Forget", systemImage: "trash") }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func row(_ record: AgentRaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(record.title.isEmpty ? "Untitled task" : record.title).font(Tellurion.font(12)).lineLimit(1)
                Text(record.category.label)
                    .font(Tellurion.font(10))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Rectangle().fill(Tellurion.text.opacity(0.08)))
                Spacer()
                Text("\(record.project) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
            }
            HStack(spacing: 14) {
                ForEach(record.entries) { entry in
                    HStack(spacing: 5) {
                        AgentBadge(kind: entry.kind, size: 16)
                        Text(Self.summary(of: entry))
                            .foregroundColor(entry.id == record.winner ? Tellurion.text : Tellurion.muted)
                    }
                }
                Spacer()
                if let winner = record.winnerEntry {
                    Text("Kept \(winner.name)").foregroundColor(.green)
                } else {
                    Text("No winner").foregroundColor(Tellurion.muted)
                }
            }
            .font(Tellurion.font(11).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// "Codex 1 · gpt-5 · 4m · 3 files +40 −12 · check passed"
    static func summary(of entry: AgentRaceRecord.Entry) -> String {
        var parts = [entry.name]
        if let model = entry.model { parts.append(model) }
        if let backend = entry.backend { parts.append("on \(backend)") }
        switch entry.outcome {
        case .finished: parts.append(entry.seconds.map(AgentRaceScores.duration) ?? "finished")
        case .working: parts.append("still working")
        case .failed: parts.append("failed")
        case .unknown: break
        }
        if entry.files > 0 {
            parts.append("\(entry.files) file\(entry.files == 1 ? "" : "s") +\(entry.added) −\(entry.removed)")
        }
        if let passed = entry.checkPassed { parts.append(passed ? "check passed" : "check failed") }
        return parts.joined(separator: " · ")
    }

    private func confirmForget(_ root: String?) {
        let alert = NSAlert()
        if let root {
            let name = projects.first { $0.root == root }?.name ?? (root as NSString).lastPathComponent
            alert.messageText = "Forget \(name)'s race history?"
            alert.informativeText = "Its decided races are removed from the scoreboard. Races that are still open aren't touched."
        } else {
            alert.messageText = "Forget all race history?"
            alert.informativeText = "Every decided race is removed from the scoreboard, for every project. Races that are still open aren't touched."
        }
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        scores.forget(root: root)
        if root != nil { project = nil }
    }
}
#endif

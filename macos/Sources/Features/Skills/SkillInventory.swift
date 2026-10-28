#if os(macOS)
import Foundation

/// An agent that skills can be installed for. `cliName` is its name in the `skills` CLI.
enum SkillAgent: String, CaseIterable, Identifiable {
    case claudeCode, codex, cursor, hermes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .hermes: return "Hermes"
        }
    }

    var cliName: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .hermes: return "hermes-agent"
        }
    }

    /// Whether the agent looks installed: its settings folder exists.
    var isPresent: Bool {
        let folder: String
        switch self {
        case .claudeCode: folder = ".claude"
        case .codex: folder = ".codex"
        case .cursor: folder = ".cursor"
        case .hermes: folder = ".hermes"
        }
        return FileManager.default.fileExists(atPath: SkillInventory.home + "/" + folder)
    }
}

/// A folder of skills, as the Installed list groups them.
enum SkillGroup: String, CaseIterable {
    case shared, claude, plugins, codex, cursor, hermes, claudeAI

    var title: String {
        switch self {
        case .shared: return "Shared"
        case .claude: return "Claude Code"
        case .plugins: return "Claude Code plugins"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .hermes: return "Hermes"
        case .claudeAI: return "Synced from Claude.ai"
        }
    }

    /// Who reads skills from here.
    var readBy: String {
        switch self {
        case .shared: return "Codex, Cursor and other agents that read ~/.agents/skills"
        case .claude, .plugins, .claudeAI: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .hermes: return "Hermes"
        }
    }
}

struct InstalledSkill: Identifiable, Hashable {
    /// Where the skill came from, which decides how it's updated.
    enum Origin: Hashable {
        /// Installed by `npx skills`, which records the repo and a hash of the folder.
        case registry(source: String, skillPath: String, hash: String, ref: String?)
        /// A git checkout.
        case git(remote: String)
        /// Part of a Claude Code plugin.
        case plugin(id: String, version: String)
        /// Shipped with an agent, which updates it.
        case bundled(String)
        /// Installed by Hermes from its skills hub, which updates it.
        case hermesHub(source: String)
        /// Copied in by hand or written by an agent: nothing to compare against.
        case local
    }

    /// The real folder (symlinks resolved), so a skill linked into several agents is one row.
    let id: String
    let name: String
    let summary: String
    /// The folder it was found at.
    let folder: String
    let group: SkillGroup
    /// From the front tab's project rather than the home folder.
    let project: Bool
    /// That project's folder, where `npx skills` keeps the project's lock.
    var root: String?
    /// Other places it's linked into.
    var alsoIn: [SkillGroup] = []
    let origin: Origin
    let modified: Date?

    var skillFile: String { id + "/SKILL.md" }

    /// The `owner/repo` (or domain) it was installed from, if known.
    var source: String? {
        if case .registry(let source, _, _, _) = origin { return source }
        return nil
    }
}

enum SkillUpdateStatus: Equatable {
    case unknown
    case checking
    case current
    case available
    /// Updated by the agent or plugin it came with.
    case managed(String)
    /// No source is recorded, so there's nothing to compare against.
    case untracked
    case failed(String)
}

/// Finds every installed skill and checks the ones with a known source for updates.
enum SkillInventory {
    static let home = NSHomeDirectory()

    /// The skills under the home folder, then those in `project` (the front tab's folder).
    static func scan(project projectRoot: String?) -> [InstalledSkill] {
        let project = projectRoot
        let lock = registryLock()
        let hermesBundled = hermesBundledNames()
        let hermesHub = hermesHubSources()
        let projectLock = project.flatMap { $0 == home ? nil : registryLock(at: $0 + "/skills-lock.json") } ?? [:]
        var found: [InstalledSkill] = []
        var index: [String: Int] = [:]

        func add(_ folder: String, group: SkillGroup, project: Bool, origin explicit: InstalledSkill.Origin? = nil) {
            let real = (folder as NSString).resolvingSymlinksInPath
            if let existing = index[real] {
                if found[existing].group != group, !found[existing].alsoIn.contains(group) { found[existing].alsoIn.append(group) }
                return
            }
            guard let text = try? String(contentsOfFile: real + "/SKILL.md", encoding: .utf8) else { return }
            let meta = frontmatter(text)
            let dirName = (folder as NSString).lastPathComponent
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dirName
            let records = Records(lock: project ? projectLock : lock, hermesBundled: hermesBundled, hermesHub: hermesHub)
            let origin = explicit ?? origin(of: real, name: name, dirName: dirName, group: group, project: project, records: records)
            let modified = (try? FileManager.default.attributesOfItem(atPath: real + "/SKILL.md"))?[.modificationDate] as? Date
            index[real] = found.count
            var skill = InstalledSkill(id: real, name: name, summary: meta["description"] ?? "", folder: folder,
                                       group: group, project: project, origin: origin, modified: modified)
            if project { skill.root = projectRoot }
            found.append(skill)
        }

        func addAll(in parent: String, group: SkillGroup, project: Bool = false, nested: Bool = false,
                    origin: InstalledSkill.Origin? = nil) {
            for folder in skillFolders(in: parent, nested: nested) { add(folder, group: group, project: project, origin: origin) }
        }

        addAll(in: home + "/.agents/skills", group: .shared)
        addAll(in: home + "/.claude/skills", group: .claude)
        addAll(in: home + "/.codex/skills", group: .codex)
        addAll(in: home + "/.codex/skills/.system", group: .codex, origin: .bundled("Codex"))
        addAll(in: home + "/.cursor/skills", group: .cursor)
        addAll(in: home + "/.cursor/skills-cursor", group: .cursor, origin: .bundled("Cursor"))
        addAll(in: home + "/.hermes/skills", group: .hermes, nested: true)
        for (path, plugin) in pluginSkillFolders() { add(path, group: .plugins, project: false, origin: plugin) }
        // Claude.ai keeps synced skills in one folder per account.
        for account in subfolders(of: home + "/.claude/skills/synced") {
            addAll(in: account, group: .claudeAI, origin: .bundled("Claude.ai"))
        }
        if let project, project != home {
            addAll(in: project + "/.agents/skills", group: .shared, project: true)
            addAll(in: project + "/.claude/skills", group: .claude, project: true)
            addAll(in: project + "/.cursor/skills", group: .cursor, project: true)
            addAll(in: project + "/.hermes/skills", group: .hermes, project: true, nested: true)
        }
        return found
    }

    /// Folders holding a SKILL.md. Hermes sorts its skills into category folders, one level down.
    private static func skillFolders(in parent: String, nested: Bool) -> [String] {
        var result: [String] = []
        for folder in subfolders(of: parent) {
            if FileManager.default.fileExists(atPath: folder + "/SKILL.md") {
                result.append(folder)
            } else if nested {
                result += subfolders(of: folder).filter { FileManager.default.fileExists(atPath: $0 + "/SKILL.md") }
            }
        }
        return result
    }

    private static func subfolders(of parent: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return names.filter { !$0.hasPrefix(".") && $0 != "synced" }.sorted().compactMap { name in
            let path = parent + "/" + name
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : nil
        }
    }

    /// What the installers recorded: `npx skills`' lock, and Hermes's manifest and hub lock.
    private struct Records {
        let lock: [String: [String: Any]]
        let hermesBundled: Set<String>
        let hermesHub: [String: String]
    }

    private static func origin(of folder: String, name: String, dirName: String, group: SkillGroup, project: Bool,
                               records: Records) -> InstalledSkill.Origin {
        let lock = records.lock, hermesBundled = records.hermesBundled, hermesHub = records.hermesHub
        if group == .hermes {
            if hermesBundled.contains(dirName) || hermesBundled.contains(name) { return .bundled("Hermes") }
            // Hermes's optional official skills come from its own repo, like the bundled ones.
            if let source = hermesHub[dirName] { return source == "official" ? .bundled("Hermes") : .hermesHub(source: source) }
        }
        // The home lock describes `npx skills`' copies: the ones in ~/.agents/skills, or a copy it
        // put straight into an agent's folder. A same-named skill beside one of those is another
        // skill. A project's lock covers the project's skills.
        let shared = home + "/.agents/skills/"
        let lockApplies = project || folder.hasPrefix(shared) || !FileManager.default.fileExists(atPath: shared + dirName)
        if lockApplies, let entry = lock[dirName] ?? lock[name],
           let source = entry["source"] as? String,
           let skillPath = entry["skillPath"] as? String {
            let hash = entry["skillFolderHash"] as? String ?? entry["computedHash"] as? String ?? ""
            return .registry(source: source, skillPath: skillPath, hash: hash, ref: entry["ref"] as? String)
        }
        if FileManager.default.fileExists(atPath: folder + "/.git") {
            let remote = AgentTools.git(["config", "--get", "remote.origin.url"], in: folder)
            let url = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if remote.ok, !url.isEmpty { return .git(remote: url) }
        }
        return .local
    }

    /// `npx skills`' record of what it installed, by skill name: everywhere, or in one project.
    private static func registryLock(at path: String = home + "/.agents/.skill-lock.json") -> [String: [String: Any]] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = json["skills"] as? [String: [String: Any]] else { return [:] }
        return skills
    }

    /// The skills Hermes ships with (its manifest lists them as `name:hash`).
    private static func hermesBundledNames() -> Set<String> {
        guard let text = try? String(contentsOfFile: home + "/.hermes/skills/.bundled_manifest", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: ":").first.map(String.init) })
    }

    /// What Hermes installed from its skills hub: skill name → where from.
    private static func hermesHubSources() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: home + "/.hermes/skills/.hub/lock.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["installed"] as? [String: [String: Any]] else { return [:] }
        return installed.mapValues { $0["source"] as? String ?? "" }
    }

    /// Skills inside installed Claude Code plugins.
    private static func pluginSkillFolders() -> [(String, InstalledSkill.Origin)] {
        guard let data = FileManager.default.contents(atPath: home + "/.claude/plugins/installed_plugins.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [[String: Any]]] else { return [] }
        var result: [(String, InstalledSkill.Origin)] = []
        for (id, installs) in plugins.sorted(by: { $0.key < $1.key }) {
            guard let install = installs.first, let path = install["installPath"] as? String else { continue }
            let origin = InstalledSkill.Origin.plugin(id: id, version: install["version"] as? String ?? "")
            for folder in skillFolders(in: path + "/skills", nested: false) { result.append((folder, origin)) }
        }
        return result
    }

    /// The `key: value` lines of a SKILL.md's frontmatter, with folded (`>`/`|`) and
    /// indented continuation lines joined.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let first = line.first, first == " " || first == "\t" {
                if let key { result[key] = ((result[key] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { value = "" }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            key = name
            result[name] = value
        }
        return result
    }

    /// The SKILL.md without its frontmatter.
    static func body(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Updates

    /// Checks `skills` for newer versions: each `npx skills` repo is fetched once and its
    /// folder hashes compared (as `npx skills update` does); git checkouts ask their remote.
    static func checkUpdates(_ skills: [InstalledSkill]) async -> [String: SkillUpdateStatus] {
        var result: [String: SkillUpdateStatus] = [:]
        var bySource: [String: [InstalledSkill]] = [:]
        for skill in skills {
            switch skill.origin {
            case .registry(let source, _, _, let ref):
                bySource[source + "#" + (ref ?? ""), default: []].append(skill)
            case .git(let remote):
                result[skill.id] = await gitStatus(skill.id, remote: remote)
            case .plugin: result[skill.id] = .managed("Claude Code updates plugins")
            case .bundled(let owner): result[skill.id] = .managed("Updates with \(owner)")
            case .hermesHub: result[skill.id] = .managed("Hermes checks it with `hermes skills check`")
            case .local: result[skill.id] = .untracked
            }
        }
        for (key, group) in bySource {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let source = String(parts[0])
            let ref = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
            let tree = await folderHashes(source: source, ref: ref)
            for skill in group {
                guard case .registry(_, let skillPath, let hash, _) = skill.origin else { continue }
                // Projects record a hash of the files rather than git's, which only a download
                // could compare.
                if !isGitHash(hash) {
                    result[skill.id] = .managed("Projects record a hash this can't compare; Update gets the latest")
                    continue
                }
                switch tree {
                case .failure(let error): result[skill.id] = .failed(error.message)
                case .success(let folders):
                    let folder = (skillPath as NSString).deletingLastPathComponent
                    if let latest = folders[folder] {
                        result[skill.id] = latest == hash ? .current : .available
                    } else {
                        result[skill.id] = .failed("No longer in \(source)")
                    }
                }
            }
        }
        return result
    }

    private struct CheckError: Error { let message: String }

    /// Folder path → git tree hash, for every folder in the repo.
    private static func folderHashes(source: String, ref: String?) async -> Result<[String: String], CheckError> {
        guard isGitHub(source),
              let url = URL(string: "https://api.github.com/repos/\(source)/git/trees/\(ref ?? "HEAD")?recursive=1") else {
            return .failure(CheckError(message: "Can't check \(source)"))
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tellurion", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failure(CheckError(message: "Offline")) }
        if http.statusCode == 403 || http.statusCode == 429 {
            return .failure(CheckError(message: "GitHub's hourly limit; try again later"))
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["tree"] as? [[String: Any]] else {
            return .failure(CheckError(message: http.statusCode == 404 ? "\(source) is gone or private" : "GitHub said \(http.statusCode)"))
        }
        var folders: [String: String] = [:]
        for entry in entries where entry["type"] as? String == "tree" {
            if let path = entry["path"] as? String, let sha = entry["sha"] as? String { folders[path] = sha }
        }
        // A skill at the root of its repo.
        if let root = json["sha"] as? String { folders[""] = root }
        return .success(folders)
    }

    /// Whether a skill's remote is somewhere on the network. A local path or a `git://` URL
    /// could make `ls-remote` run a program the repository's config names.
    static func isNetworkRemote(_ remote: String) -> Bool {
        let lower = remote.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("ssh://")
            || lower.range(of: #"^[a-z0-9._-]+@[a-z0-9][a-z0-9.-]*:"#, options: .regularExpression) != nil
    }

    private static func gitStatus(_ folder: String, remote: String) async -> SkillUpdateStatus {
        guard isNetworkRemote(remote) else { return .failed("Not a network remote: \(remote)") }
        return await Task.detached {
            let head = AgentTools.git(["rev-parse", "HEAD"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never prompt for a password or passphrase, and run git's own upload-pack, not
            // one the repository's config names. Only network transports, even if the
            // repository's config rewrites the remote's URL to a local path or a git:// one.
            let latest = AgentTools.git(["-c", "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=8",
                                         "-c", "protocol.file.allow=never", "-c", "protocol.git.allow=never",
                                         "ls-remote", "--upload-pack=git-upload-pack", "origin", "HEAD"], in: folder)
            guard latest.ok, let sha = latest.output.split(separator: "\t").first.map(String.init), !head.isEmpty else {
                return .failed("Couldn't reach \(remote)")
            }
            return sha == head ? .current : .available
        }.value
    }

    private static func isGitHash(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    /// `owner/repo`, as opposed to a website that serves skills.
    static func isGitHub(_ source: String) -> Bool {
        let parts = source.split(separator: "/")
        return parts.count == 2 && !parts[0].contains(".")
    }

    // MARK: Commands

    /// The shell line that updates `skill`, if it can be updated from here.
    static func updateCommand(_ skill: InstalledSkill) -> String? {
        switch skill.origin {
        case .registry:
            if let root = skill.root {
                return "cd \(AgentTools.shellQuote(root)) && npx -y skills@latest update \(AgentTools.shellQuote(skill.name)) -p -y"
            }
            return "npx -y skills@latest update \(AgentTools.shellQuote(skill.name)) -g -y"
        case .git: return "git -C \(AgentTools.shellQuote(skill.id)) pull --ff-only"
        case .plugin(let id, _): return "claude plugin update \(AgentTools.shellQuote(id))"
        case .hermesHub: return "hermes skills update \(AgentTools.shellQuote(skill.name))"
        case .bundled, .local: return nil
        }
    }

    static let updateAllCommand = "npx -y skills@latest update -g -y"

    /// The shell line that removes a skill `npx skills` installed.
    static func removeCommand(_ skill: InstalledSkill) -> String {
        let line = "npx -y skills@latest remove \(AgentTools.shellQuote(skill.name))"
        if let root = skill.root { return "cd \(AgentTools.shellQuote(root)) && " + line + " -y" }
        return line + " -g -y"
    }

    /// The shell line that installs `skill` from `source` for `agents`; everywhere when
    /// `project` is nil, otherwise in that project.
    static func installCommand(source: String, skill: String, agents: [SkillAgent], project: String?) -> String {
        let from = isGitHub(source) ? source : "https://" + source
        var line = "npx -y skills@latest add \(AgentTools.shellQuote(from)) -s \(AgentTools.shellQuote(skill))"
        if !agents.isEmpty { line += " -a " + agents.map(\.cliName).joined(separator: " ") }
        line += project == nil ? " -g -y" : " -y"
        if let project { line = "cd \(AgentTools.shellQuote(project)) && " + line }
        return line
    }
}
#endif

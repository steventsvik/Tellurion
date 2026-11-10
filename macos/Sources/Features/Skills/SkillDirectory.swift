#if os(macOS)
import Foundation

/// A skill listed on skills.sh, the directory `npx skills` installs from.
struct ListedSkill: Identifiable, Hashable, Decodable {
    let source: String
    let skillId: String
    let name: String
    let installs: Int
    /// The Hot list's installs this hour yesterday, and the change since.
    var installsYesterday: Int?
    var change: Int?
    /// The last eight weeks' installs (All time only).
    var weeklyInstalls: [Int]?
    /// From the skill's own company or project, rather than the community.
    var isOfficial: Bool?

    var id: String { source + "/" + skillId }
    /// Whether its source and id can go on the install line; skills.sh's lists are read
    /// from the network, so an entry that fails this is left out.
    var isTypable: Bool { SkillInventory.isTypable(source) && SkillInventory.isTypable(skillId) }
    var official: Bool { isOfficial == true }
    var owner: String { String(source.split(separator: "/").first ?? Substring(source)) }
    /// Its skills.sh page. Skills served from a website have none that works.
    var page: URL? {
        SkillInventory.isGitHub(source) ? URL(string: "https://skills.sh/\(source)/\(skillId)") : nil
    }
    var repo: URL? { SkillInventory.isGitHub(source) ? URL(string: "https://github.com/\(source)") : URL(string: "https://\(source)") }
}

/// A partner's security review of a skill, from skills.sh.
struct SkillAudit: Identifiable, Hashable {
    let provider: String
    let status: String
    let summary: String
    let risk: String?

    var id: String { provider }
}

enum SkillDirectory {
    enum Board: String, CaseIterable, Identifiable {
        case trending, hot, allTime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trending: return "Trending"
            case .hot: return "Hot"
            case .allTime: return "All time"
            }
        }

        var detail: String {
            switch self {
            case .trending: return "Most installed in the last 24 hours"
            case .hot: return "Gaining fastest this hour, against the same hour yesterday"
            case .allTime: return "Most installed ever"
            }
        }

        fileprivate var path: String {
            switch self {
            case .trending: return "trending"
            case .hot: return "hot"
            case .allTime: return ""
            }
        }
    }

    struct Failure: Error { let message: String }

    /// A leaderboard, read from the skills.sh page itself: its API needs a Vercel login
    /// an app can't have, and the page carries the same list.
    static func board(_ board: Board) async -> Result<[ListedSkill], Failure> {
        guard let url = URL(string: "https://skills.sh/" + board.path) else { return .failure(Failure(message: "Bad address")) }
        guard let html = await page(url) else { return .failure(Failure(message: "Couldn't reach skills.sh")) }
        let skills = parseBoard(html)
        return skills.isEmpty ? .failure(Failure(message: "skills.sh changed its page; the list couldn't be read")) : .success(skills)
    }

    /// The skill records embedded in a leaderboard page, in order, without repeats.
    static func parseBoard(_ html: String) -> [ListedSkill] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\\"source\\":[^{}]*\}"#) else { return [] }
        var seen = Set<String>()
        var result: [ListedSkill] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let json = html[r].replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
            guard let skill = try? JSONDecoder().decode(ListedSkill.self, from: Data(json.utf8)),
                  skill.isTypable, seen.insert(skill.id).inserted else { continue }
            result.append(skill)
        }
        return result
    }

    /// Search by name, repo or description.
    static func search(_ query: String) async -> Result<[ListedSkill], Failure> {
        var components = URLComponents(string: "https://skills.sh/api/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "60")]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(Failure(message: "Couldn't reach skills.sh")) }
        struct Hit: Decodable { let source: String; let skillId: String; let name: String; let installs: Int? }
        struct Reply: Decodable { let skills: [Hit] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .failure(Failure(message: "skills.sh's search answered in a way this version doesn't understand"))
        }
        return .success(reply.skills.map { ListedSkill(source: $0.source, skillId: $0.skillId, name: $0.name, installs: $0.installs ?? 0) }
            .filter(\.isTypable))
    }

    /// The one-line description skills.sh shows for a skill, or for a skill served from a
    /// website, the one in that site's skills index.
    static func summary(_ skill: ListedSkill) async -> String? {
        guard SkillInventory.isGitHub(skill.source) else { return await siteSummary(skill) }
        guard let url = skill.page, let html = await page(url),
              let regex = try? NSRegularExpression(pattern: #"<meta name="description" content="([^"]*)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return unescape(String(html[r]))
    }

    private static func siteSummary(_ skill: ListedSkill) async -> String? {
        for path in [".well-known/agent-skills/index.json", ".well-known/skills/index.json"] {
            guard let url = URL(string: "https://\(skill.source)/\(path)"),
                  let (data, response) = try? await URLSession.shared.data(for: request(url)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let skills = json["skills"] as? [[String: Any]] else { continue }
            let match = skills.first { ($0["name"] as? String) == skill.skillId || ($0["name"] as? String) == skill.name }
            if let description = match?["description"] as? String { return description }
        }
        return nil
    }

    /// Security reviews, or none if nobody has reviewed it yet.
    static func audits(_ skill: ListedSkill) async -> [SkillAudit] {
        guard let url = URL(string: "https://skills.sh/api/v1/skills/audit/\(skill.source)/\(skill.skillId)"),
              let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audits = json["audits"] as? [[String: Any]] else { return [] }
        return audits.compactMap { audit in
            guard let provider = audit["provider"] as? String, let status = audit["status"] as? String else { return nil }
            return SkillAudit(provider: provider, status: status, summary: audit["summary"] as? String ?? "",
                              risk: audit["riskLevel"] as? String)
        }
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // The site redirects clients it doesn't recognize to a bare page.
        request.setValue("Mozilla/5.0 (Macintosh) Tellurion", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func page(_ url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    private static func unescape(_ s: String) -> String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
#endif

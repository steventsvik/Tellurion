#if os(macOS)
import Foundation

/// What kind of work a race's task is. The scoreboard keeps its numbers per category, since
/// an agent that's good at bug fixes isn't necessarily the one to pick for a refactor.
enum AgentRaceCategory: String, Codable, CaseIterable, Identifiable {
    case bugFix
    case feature
    case refactor
    case tests
    case docs
    case interface
    case performance
    case config
    case other

    var id: String { rawValue }

    /// "Bug fix", for pickers and the history list.
    var label: String {
        switch self {
        case .bugFix: return "Bug fix"
        case .feature: return "New feature"
        case .refactor: return "Refactor"
        case .tests: return "Tests"
        case .docs: return "Docs"
        case .interface: return "UI and styling"
        case .performance: return "Performance"
        case .config: return "Dependencies and config"
        case .other: return "Other"
        }
    }

    /// "bug fixes", as it reads in "For bug fixes in this project, …".
    var plural: String {
        switch self {
        case .bugFix: return "bug fixes"
        case .feature: return "new features"
        case .refactor: return "refactors"
        case .tests: return "test work"
        case .docs: return "docs"
        case .interface: return "UI and styling work"
        case .performance: return "performance work"
        case .config: return "dependency and config changes"
        case .other: return "other tasks"
        }
    }

    // MARK: Classifying

    /// The category of a task, from its wording alone: no model is asked, and the same text
    /// always gives the same answer.
    ///
    /// Each category has a list of words and phrases with a weight (3 for one that names the
    /// category outright, 2 for a likely one, 1 for a hint). They're matched as whole words,
    /// each counts once, and the category with the highest total wins. A tie goes to whichever
    /// comes first in `tieOrder`; a task that matches nothing is `.other`.
    static func classify(_ task: String) -> AgentRaceCategory {
        let text = task.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        var best = AgentRaceCategory.other
        var bestScore = 0
        for category in tieOrder {
            var score = 0
            for rule in compiled[category] ?? [] where rule.pattern.firstMatch(in: text, range: range) != nil {
                score += rule.weight
            }
            if score > bestScore {
                best = category
                bestScore = score
            }
        }
        return best
    }

    /// Which category wins a tie: the specific ones before the general ones, so "add tests"
    /// is about tests and "fix the layout" is about the UI only when the scores say so.
    static let tieOrder: [AgentRaceCategory] = [.bugFix, .tests, .docs, .performance, .interface, .config, .refactor, .feature]

    private struct Rule {
        let pattern: NSRegularExpression
        let weight: Int
    }

    /// The rules, as alternatives per weight. `\b` is added around each list.
    private static let rules: [AgentRaceCategory: [(weight: Int, words: [String])]] = [
        .bugFix: [
            (3, ["bugs?", "crash(es|ed|ing)?", "regress(ion|ions|ed)", "broken", "exceptions?", "segfaults?", "deadlocks?",
                 "race conditions?", "off[- ]by[- ]one", "(does|do|did)(n't| not) work", "(isn't|is not|not|stopped) working",
                 "fail(s|ed|ing)? to", "errors?", "hangs?", "freezes?", "memory leaks?", "null pointer", "incorrect(ly)?", "wrong(ly)?"]),
            (2, ["fix(es|ed|ing)?", "hotfix", "bugfix", "resolve[sd]?", "repair", "debug"]),
            (1, ["issues?", "problems?", "unexpected(ly)?"]),
        ],
        .feature: [
            (2, ["add(s|ed|ing)?", "implement(s|ed|ing)?", "introduce", "support for", "features?", "create", "build", "new"]),
            (1, ["allow", "enable", "let users?", "option to", "ability to", "integrate"]),
        ],
        .refactor: [
            (3, ["refactor(s|ed|ing)?", "restructure", "reorgani[sz]e", "clean ?up", "simplify", "dedup(licate)?", "duplication",
                 "dead code", "tech(nical)? debt", "decouple", "moderni[sz]e"]),
            (2, ["extract", "renam(e|ed|ing)", "rewrite", "migrate", "split", "consolidate", "tidy", "unused"]),
            (1, ["move", "inline", "readab(le|ility)"]),
        ],
        .tests: [
            (3, ["tests?", "unit[- ]tests?", "test coverage", "coverage", "flaky", "test suite", "specs?", "e2e", "end[- ]to[- ]end",
                 "xctest", "jest", "pytest", "vitest", "snapshot tests?", "regression tests?"]),
            (2, ["mocks?", "fixtures?", "assertions?", "test cases?"]),
        ],
        .docs: [
            (3, ["readme", "docs?", "documentation", "document(s|ed|ing)?", "changelog", "docstrings?", "doc comments?",
                 "release notes", "jsdoc", "tutorial", "api reference", "user guide"]),
            (2, ["typos?", "comments?", "wording", "spelling", "grammar"]),
            (1, ["explain", "guide", "examples?"]),
        ],
        .interface: [
            (3, ["css", "styl(e|es|ed|ing)", "layouts?", "align(s|ed|ment)?", "padding", "margins?", "spacing", "colou?rs?", "fonts?",
                 "typography", "dark mode", "light mode", "themes?", "animat(e|es|ed|ion|ions)", "transitions?", "responsive",
                 "redesign", "icons?", "hover", "ui", "ux", "rounded corners?", "shadows?", "gradients?", "tailwind", "look and feel",
                 "pixels?"]),
            (2, ["tooltips?", "sidebar", "toolbar", "truncat(e|es|ed|ion)", "overlap(s|ping)?", "centered?", "visual(ly|s)?"]),
        ],
        .performance: [
            (3, ["performance", "perf", "slow(er|ly|ness)?", "fast(er)?", "speed(s|ing)? up", "optimi[sz](e|es|ed|ing|ation)",
                 "latency", "memory usage", "cpu", "bottlenecks?", "profil(e|ing)", "benchmarks?", "n\\+1", "laggy?", "jank(y)?"]),
            (2, ["cach(e|es|ed|ing)", "throttl(e|ed|ing)", "debounc(e|ed|ing)", "lazy[- ]load(ing)?", "memory leaks?", "takes too long",
                 "startup time", "allocations?"]),
        ],
        .config: [
            (3, ["dependenc(y|ies)", "upgrad(e|es|ed|ing)", "bump(s|ed|ing)?", "package\\.json", "lockfiles?", "ci", "github actions",
                 "dockerfile", "docker", "tsconfig", "makefile", "gitignore", "env(ironment)? var(iable)?s?", "pipeline"]),
            (2, ["config(s|uration|ure)?", "npm", "yarn", "pnpm", "cargo", "pip", "homebrew", "eslint", "prettier", "swiftlint",
                 "linter", "webpack", "vite", "workflows?", "build scripts?", "settings file"]),
            (1, ["versions?", "install", "setup"]),
        ],
    ]

    private static let compiled: [AgentRaceCategory: [Rule]] = rules.mapValues { groups in
        groups.flatMap { group in
            group.words.compactMap { word in
                // The lists above are fixed; one that didn't compile would only be left out.
                (try? NSRegularExpression(pattern: "(?<![\\w])(?:\(word))(?![\\w])")).map { Rule(pattern: $0, weight: group.weight) }
            }
        }
    }
}
#endif

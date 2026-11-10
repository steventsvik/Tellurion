import Foundation
import Testing
@testable import Ghostty

/// What the brain is told about its job: the same everywhere but for where it lives.
struct OrchestratorPromptTests {
    private let board = OrchestratorPrompt.instructions(for: .board)
    private let tabs = OrchestratorPrompt.instructions(for: .tabs)

    @Test func aBoardsBrainIsOnACanvasOfTerminals() {
        #expect(board.hasPrefix("You are an orchestrator on the user's Tellurion board, a canvas of terminals in a macOS app. "
                                + "Several coding agents (Claude Code, Codex and others, each in its own terminal) are wired to you."))
        #expect(board.contains("you act only through the actions below, and the board carries them out."))
        #expect(OrchestratorPrompt.instructions == board)
    }

    @Test func aClassicWindowsBrainIsAmongTabs() {
        #expect(tabs.hasPrefix("You are an orchestrator in the user's Tellurion terminal: several tabs, each with a coding agent, in a macOS app. "
                               + "Several coding agents (Claude Code, Codex and others, each in its own terminal) are wired to you."))
        #expect(tabs.contains("you act only through the actions below, and Tellurion carries them out."))
        #expect(!tabs.contains("board"))
        #expect(!tabs.contains("canvas"))
    }

    @Test func everythingElseIsTheSame() {
        let boardOpening = "You are an orchestrator on the user's Tellurion board, a canvas of terminals in a macOS app."
        let tabsOpening = "You are an orchestrator in the user's Tellurion terminal: several tabs, each with a coding agent, in a macOS app."
        let rest = board.dropFirst(boardOpening.count).replacingOccurrences(of: "and the board carries them out", with: "and Tellurion carries them out")
        #expect(String(tabs.dropFirst(tabsOpening.count)) == rest)
        for text in [board, tabs] {
            #expect(text.contains("Reply with JSON only"))
            #expect(text.contains("at most 24 in all"))
            #expect(text.contains("you can't approve it"))
        }
    }

    @Test func anAgentItStartsIsToldWhereItWorks() {
        #expect(OrchestratorPrompt.memberIntro(role: "Reviewer", orchestrator: "Orchestrator", place: .board)
                == "You're the Reviewer working for Orchestrator, which coordinates several coding agents on the user's Tellurion board. "
                + "It sees your final answer each turn, so end each turn with a short summary of what you did and anything you need.")
        #expect(OrchestratorPrompt.memberIntro(role: nil, orchestrator: "Orchestrator", place: .tabs)
                == "You're an agent working for Orchestrator, which coordinates several coding agents in the user's Tellurion terminal. "
                + "It sees your final answer each turn, so end each turn with a short summary of what you did and anything you need.")
    }
}

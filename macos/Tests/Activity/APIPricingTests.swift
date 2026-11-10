import Foundation
import Testing
@testable import Ghostty

/// What a Claude response costs at API prices, for the models people are on now.
struct APIPricingTests {
    @Test func theNewestModelsHaveAPrice() {
        for model in ["claude-fable-5-2", "claude-mythos-5-2", "claude-fable-5-2[1m]", "claude-opus-5-5", "claude-sonnet-5-5"] {
            #expect(APIPricing.claude(model: model, fast: false) != nil, "\(model)")
        }
    }

    @Test func aFableResponseIsCosted() throws {
        let usage: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000]
        let cost = try #require(APIPricing.claudeCost(model: "claude-fable-5-2", usage: usage))
        #expect(abs(cost.input - 8.2) < 0.0001)
        #expect(abs(cost.output - 40) < 0.0001)
    }

    @Test func fastModeCostsMore() throws {
        let usage: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 1_000_000, "speed": "fast"]
        let cost = try #require(APIPricing.claudeCost(model: "claude-fable-5-2", usage: usage))
        #expect(abs(cost.input - 16) < 0.0001)
        #expect(abs(cost.output - 80) < 0.0001)
    }

    @Test func aModelNobodyHasPricedHasNoCost() {
        #expect(APIPricing.claude(model: "claude-some-future-model", fast: false) == nil)
    }
}

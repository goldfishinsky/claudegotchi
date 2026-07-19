import XCTest
@testable import PetCore

final class ModelPlatformTests: XCTestCase {
    func testInferCodexModels() {
        XCTAssertEqual(ModelPlatform.infer(model: "gpt-5-codex"), "codex")
        XCTAssertEqual(ModelPlatform.infer(model: "gpt-4o"), "codex")
        XCTAssertEqual(ModelPlatform.infer(model: "codex-mini"), "codex")
        XCTAssertEqual(ModelPlatform.infer(model: "o1-preview"), "codex")
        XCTAssertEqual(ModelPlatform.infer(model: "o3"), "codex")
        XCTAssertEqual(ModelPlatform.infer(model: "O4-mini"), "codex", "case-insensitive")
    }

    func testInferClaudeModels() {
        XCTAssertEqual(ModelPlatform.infer(model: "claude-opus-4-8"), "claude-code")
        XCTAssertEqual(ModelPlatform.infer(model: "claude-sonnet-4-5"), "claude-code")
        XCTAssertEqual(ModelPlatform.infer(model: "opus"), "claude-code", "o + letter is not the o-series")
    }

    func testDominantByLifetimeTokens() {
        let models = [
            ModelUsage(model: "claude-sonnet-4-5", tokensIn: 100, tokensOut: 40, calls: 2),
            ModelUsage(model: "gpt-5-codex", tokensIn: 300, tokensOut: 50, calls: 3),
        ]
        XCTAssertEqual(ModelPlatform.dominant(models: models), "codex")
    }

    func testDominantTieResolvesToClaude() {
        let models = [
            ModelUsage(model: "claude-opus-4-1", tokensIn: 50, tokensOut: 0, calls: 1),
            ModelUsage(model: "gpt-5-codex", tokensIn: 50, tokensOut: 0, calls: 1),
        ]
        XCTAssertEqual(ModelPlatform.dominant(models: models), "claude-code")
    }

    func testDominantEmptyResolvesToClaude() {
        XCTAssertEqual(ModelPlatform.dominant(models: []), "claude-code")
    }
}

import XCTest
import GRDB
@testable import PetCore

final class AgentActivityTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    var petId: Int64!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "agent-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        let pet = try Pet.insert(Pet.fresh(species: "frog", at: 0), into: db)
        petId = pet.id!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private let window: Int64 = 15 * 60 * 1000

    private func insert(id: String, type: String, ts: Int64, sessionId: String?,
                        cwd: String?, tokensIn: Int? = nil, tokensOut: Int? = nil,
                        model: String? = nil, prompt: String? = nil) throws {
        var obj: [String: Any] = ["type": type, "ts": ts]
        if let tokensIn { obj["tokens_in"] = tokensIn }
        if let tokensOut { obj["tokens_out"] = tokensOut }
        if let model { obj["model"] = model }
        if let prompt { obj["prompt"] = prompt }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let payload = String(data: data, encoding: .utf8)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, ts, type, petId!, payload, sessionId, cwd])
        }
    }

    func testWorkingSessionWithTokensAndModel() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 100_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi", model: "claude-opus-4-8[1m]")
        try insert(id: "e2", type: "post_tool_use", ts: now - 70_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi", tokensIn: 100, tokensOut: 50)
        try insert(id: "e3", type: "post_tool_use", ts: now - 10_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi", tokensIn: 200, tokensOut: 30)

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        let a = agents[0]
        XCTAssertEqual(a.sessionId, "s1")
        XCTAssertEqual(a.repoName, "claudegotchi")
        XCTAssertEqual(a.state, .working)
        XCTAssertEqual(a.sessionTokens, 380)
        XCTAssertEqual(a.ratePerMin, 230, "e2 is outside the trailing 60s window")
        XCTAssertEqual(a.model, "opus-4-8")
    }

    func testStoppedSessionExcluded() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "stop", ts: now - 1_000, sessionId: "s1", cwd: "/tmp/r")
        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertTrue(agents.isEmpty)
    }

    func testResumedAfterStopStillActive() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 60_000, sessionId: "s1", cwd: "/tmp/r",
                   model: "claude-fable-5")
        try insert(id: "e2", type: "stop", ts: now - 40_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e3", type: "post_tool_use", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 5)
        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].state, .working)
        XCTAssertEqual(agents[0].sessionTokens, 15)
    }

    func testIdleVsWorkingBoundary() throws {
        let now: Int64 = 1_000_000
        // last event exactly 120s old → still working (inclusive boundary)
        try insert(id: "w1", type: "session_start", ts: now - 200_000, sessionId: "work", cwd: "/tmp/w")
        try insert(id: "w2", type: "pre_tool_use", ts: now - 120_000, sessionId: "work", cwd: "/tmp/w")
        // last event 121s old → idle (still inside the 15-min active window)
        try insert(id: "i1", type: "session_start", ts: now - 300_000, sessionId: "idle", cwd: "/tmp/i")
        try insert(id: "i2", type: "pre_tool_use", ts: now - 121_000, sessionId: "idle", cwd: "/tmp/i")

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionId, $0) })
        XCTAssertEqual(byId["work"]?.state, .working)
        XCTAssertEqual(byId["idle"]?.state, .idle)
        // working sorts before idle
        XCTAssertEqual(agents.first?.sessionId, "work")
    }

    func testTokenSumsOnlyPostToolUse() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 999, tokensOut: 999, model: "claude-fable-5")
        try insert(id: "e2", type: "post_tool_use", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 5)
        try insert(id: "e3", type: "post_tool_use", ts: now - 15_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 40, tokensOut: 45)

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].sessionTokens, 100, "session_start tokens must be ignored")
        XCTAssertEqual(agents[0].model, "fable-5")
    }

    func testStopCarriedTokensCountTowardSession() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "post_tool_use", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 5)
        // Stop now carries the turn's final-message tokens; they must be included.
        try insert(id: "e3", type: "stop", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 199, tokensOut: 38, model: "claude-haiku-4-5-20251001")
        try insert(id: "e4", type: "pre_tool_use", ts: now - 1_000, sessionId: "s1", cwd: "/tmp/r")

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].sessionTokens, 252, "post_tool_use(15) + stop(237)")
        XCTAssertEqual(agents[0].model, "haiku-4-5")
    }

    func testRateWindowExcludesOlderEvents() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 90_000, sessionId: "s1", cwd: "/tmp/r")
        // outside 60s window → counts toward lifetime only
        try insert(id: "e2", type: "post_tool_use", ts: now - 90_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 1000, tokensOut: 0)
        // inside 60s window
        try insert(id: "e3", type: "post_tool_use", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 20, tokensOut: 5)

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents[0].sessionTokens, 1025)
        XCTAssertEqual(agents[0].ratePerMin, 25, "only the event within the trailing 60s counts")
    }

    func testCwdFallback() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 5_000, sessionId: "s1", cwd: nil)
        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].repoName, "未知目录")
        XCTAssertNil(agents[0].model)
        XCTAssertEqual(agents[0].ratePerMin, 0)
        XCTAssertEqual(agents[0].sessionTokens, 0)
    }

    func testMostRecentModelWins() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r",
                   model: "claude-opus-4-20250514")
        try insert(id: "e2", type: "post_tool_use", ts: now - 10_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 1, tokensOut: 1, model: "claude-fable-5")
        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents[0].model, "fable-5")
    }

    func testStaleSessionOutsideWindowExcluded() throws {
        let now: Int64 = 2_000_000
        try insert(id: "e1", type: "session_start", ts: 0, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "post_tool_use", ts: 100, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 10)
        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertTrue(agents.isEmpty)
    }

    func testTitleIsFirstUserPromptSubmit() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 100_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 90_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "第一个任务：修复登录")
        try insert(id: "e3", type: "post_tool_use", ts: now - 50_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 5)
        try insert(id: "e4", type: "user_prompt_submit", ts: now - 10_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "第二个任务：改样式")

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].title, "第一个任务：修复登录", "first prompt wins, not the latest")
    }

    func testTitleSkipsSystemInjectedPrompts() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 100_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 90_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "<task-notification>agent finished</task-notification>")
        try insert(id: "e3", type: "user_prompt_submit", ts: now - 80_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "  <command-name>/init</command-name>")
        try insert(id: "e4", type: "user_prompt_submit", ts: now - 70_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "修复真正的 bug")

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents[0].title, "修复真正的 bug", "harness noise is skipped in favor of the human prompt")
    }

    func testTitleFallsBackToFirstWhenAllNoise() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 100_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 90_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "<local-command-caveat>caveat</local-command-caveat>")
        try insert(id: "e3", type: "user_prompt_submit", ts: now - 80_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "<system-reminder>be nice</system-reminder>")

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents[0].title, "<local-command-caveat>caveat</local-command-caveat>",
                       "when every prompt is noise, the first is used anyway")
    }

    func testPickTitleUnit() {
        XCTAssertNil(AgentActivityTracker.pickTitle([]))
        XCTAssertEqual(AgentActivityTracker.pickTitle(["hello"]), "hello")
        XCTAssertEqual(
            AgentActivityTracker.pickTitle(["<task-notification>x", "real task"]), "real task")
        XCTAssertEqual(
            AgentActivityTracker.pickTitle(["<system-reminder>x", "  <command-name>/y", "done"]), "done")
        XCTAssertEqual(
            AgentActivityTracker.pickTitle(["<system>only noise"]), "<system>only noise")
    }

    func testTitleNilWhenNoUserPromptSubmit() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "post_tool_use", ts: now - 10_000, sessionId: "s1", cwd: "/tmp/r",
                   tokensIn: 10, tokensOut: 5)

        let agents = try AgentActivityTracker.activeAgents(db: db, nowMs: now, windowMs: window)
        XCTAssertEqual(agents.count, 1)
        XCTAssertNil(agents[0].title)
    }

    func testDateSuffixStrippedFromModel() throws {
        XCTAssertEqual(AgentActivityTracker.shortModel("claude-opus-4-20250514"), "opus-4")
        XCTAssertEqual(AgentActivityTracker.shortModel("claude-opus-4-8[1m]"), "opus-4-8")
        XCTAssertEqual(AgentActivityTracker.shortModel("claude-fable-5"), "fable-5")
        XCTAssertEqual(AgentActivityTracker.shortModel("opus"), "opus")
    }

    func testFilterHidesByDirectory() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/hookprobe/x")
        try insert(id: "e2", type: "session_start", ts: now - 5_000, sessionId: "s2", cwd: "/tmp/repo")
        let filter = SessionFilter(directoryPatterns: ["/hookprobe"])
        let agents = try AgentActivityTracker.activeAgents(
            db: db, nowMs: now, windowMs: window, filter: filter)
        XCTAssertEqual(agents.map(\.sessionId), ["s2"], "hookprobe session is hidden")
    }

    func testFilterHidesByPromptPrefix() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 5_000, sessionId: "noise", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 4_000, sessionId: "noise", cwd: "/tmp/r",
                   prompt: "<task-notification>done</task-notification>")
        try insert(id: "h1", type: "session_start", ts: now - 5_000, sessionId: "human", cwd: "/tmp/r")
        try insert(id: "h2", type: "user_prompt_submit", ts: now - 4_000, sessionId: "human", cwd: "/tmp/r",
                   prompt: "修复登录")
        let filter = SessionFilter(promptPrefixPatterns: ["<task-notification>"])
        let agents = try AgentActivityTracker.activeAgents(
            db: db, nowMs: now, windowMs: window, filter: filter)
        XCTAssertEqual(agents.map(\.sessionId), ["human"], "task-notification-only session is hidden")
    }

    func testFilterKeepsRealSessionWithNoisyLaterPrompt() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 6_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "真正的任务")
        try insert(id: "e3", type: "user_prompt_submit", ts: now - 4_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "<task-notification>x</task-notification>")
        let filter = SessionFilter(promptPrefixPatterns: ["<task-notification>"])
        let agents = try AgentActivityTracker.activeAgents(
            db: db, nowMs: now, windowMs: window, filter: filter)
        XCTAssertEqual(agents.count, 1, "de-noised title is the human prompt, so session stays visible")
    }
}

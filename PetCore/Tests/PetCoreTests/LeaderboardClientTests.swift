import XCTest
@testable import PetCore

final class LeaderboardClientTests: XCTestCase {
    private func makeClient(_ fake: FakeHTTPTransport) -> HTTPLeaderboardClient {
        HTTPLeaderboardClient(transport: fake, baseURL: URL(string: "https://api.test")!, githubClientID: "cid-123")
    }

    private func bodyString(_ fake: FakeHTTPTransport, _ index: Int = 0) -> String {
        String(data: fake.calls[index].body ?? Data(), encoding: .utf8) ?? ""
    }

    func testDeviceFlowStartDecodesAndPosts() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"device_code":"dc-1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
            """)
        let start = try await makeClient(fake).startDeviceFlow()
        XCTAssertEqual(start.deviceCode, "dc-1")
        XCTAssertEqual(start.userCode, "WDJB-MJHT")
        XCTAssertEqual(start.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(start.expiresIn, 900)
        XCTAssertEqual(start.interval, 5)

        let call = fake.calls[0]
        XCTAssertEqual(call.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.timeout, 15)
        XCTAssertTrue(bodyString(fake).contains("client_id=cid-123"))
    }

    func testPollPending() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"error":"authorization_pending"}"#)
        let r = try await makeClient(fake).pollDeviceFlow(deviceCode: "dc-1")
        XCTAssertEqual(r, .pending)
    }

    func testPollSlowDownIsPending() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"error":"slow_down","interval":10}"#)
        let r = try await makeClient(fake).pollDeviceFlow(deviceCode: "dc-1")
        XCTAssertEqual(r, .pending)
    }

    func testPollAuthorized() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"access_token":"gho_abc","token_type":"bearer","scope":""}"#)
        let r = try await makeClient(fake).pollDeviceFlow(deviceCode: "dc-9")
        XCTAssertEqual(r, .authorized(githubToken: "gho_abc"))
        let body = bodyString(fake)
        XCTAssertTrue(body.contains("device_code=dc-9"))
        XCTAssertTrue(body.contains("grant_type=urn"))
        XCTAssertEqual(fake.calls[0].url?.absoluteString, "https://github.com/login/oauth/access_token")
    }

    func testPollFailedError() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"error":"access_denied"}"#)
        let r = try await makeClient(fake).pollDeviceFlow(deviceCode: "dc-1")
        XCTAssertEqual(r, .failed("access_denied"))
    }

    func testAuthenticateDecodesAndSendsSnakeCaseBody() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"token":"cg_xyz","user":{"id":42,"login":"jalen","avatar_url":"https://a/x.png"}}
            """)
        let resp = try await makeClient(fake).authenticate(githubToken: "gho_abc")
        XCTAssertEqual(resp.token, "cg_xyz")
        XCTAssertEqual(resp.user.id, 42)
        XCTAssertEqual(resp.user.login, "jalen")
        XCTAssertEqual(resp.user.avatarUrl, "https://a/x.png")

        let call = fake.calls[0]
        XCTAssertEqual(call.url?.absoluteString, "https://api.test/v1/auth/github")
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(bodyString(fake).contains("\"github_token\""))
        XCTAssertTrue(bodyString(fake).contains("gho_abc"))
    }

    func testSyncBodyKeysBearerAndResponse() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"ok":true,"clamped":false,"next_sync_after_ms":1800000}"#)
        let payload = SyncPayload(
            platform: "claude-code",
            totals: .init(tokensIn: 100, tokensOut: 50, sessions: 3, toolsUsed: 7),
            pet: .init(uid: "01ABC", species: "frog", name: nil, birthdayMs: 1000, xp: 42),
            best: .init(survivalMs: 86_400_000, species: "slime", name: "Goo"),
            models: ["claude-sonnet-4-5": .init(in: 100, out: 50, calls: 5)]
        )
        let resp = try await makeClient(fake).sync(payload, token: "cg_test")
        XCTAssertTrue(resp.ok)
        XCTAssertFalse(resp.clamped)
        XCTAssertEqual(resp.nextSyncAfterMs, 1_800_000)

        let call = fake.calls[0]
        XCTAssertEqual(call.url?.absoluteString, "https://api.test/v1/sync")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.headers["Authorization"], "Bearer cg_test")
        let body = bodyString(fake)
        for key in ["\"tokens_in\"", "\"tokens_out\"", "\"tools_used\"", "\"birthday_ms\"", "\"survival_ms\"", "\"claude-sonnet-4-5\"", "\"in\"", "\"out\"", "\"calls\"", "\"uid\""] {
            XCTAssertTrue(body.contains(key), "sync body missing \(key): \(body)")
        }
        XCTAssertFalse(body.contains("birthdayMs"))
        XCTAssertFalse(body.contains("toolsUsed"))
    }

    func testSyncRateLimited() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 429, json: #"{"error":"rate_limited","retry_after_ms":5000}"#)
        let payload = SyncPayload(
            platform: "claude-code",
            totals: .init(tokensIn: 0, tokensOut: 0, sessions: 0, toolsUsed: 0),
            pet: nil, best: nil, models: [:]
        )
        do {
            _ = try await makeClient(fake).sync(payload, token: "cg_test")
            XCTFail("expected rateLimited")
        } catch let e as LeaderboardError {
            XCTAssertEqual(e, .rateLimited(retryAfterMs: 5000))
        }
    }

    func testSyncNilPetOmitsKey() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: #"{"ok":true,"clamped":false,"next_sync_after_ms":0}"#)
        let payload = SyncPayload(
            platform: "claude-code",
            totals: .init(tokensIn: 0, tokensOut: 0, sessions: 0, toolsUsed: 0),
            pet: nil, best: nil, models: [:]
        )
        _ = try await makeClient(fake).sync(payload, token: "cg_test")
        let body = bodyString(fake)
        XCTAssertFalse(body.contains("\"pet\""))
        XCTAssertFalse(body.contains("\"best\""))
        XCTAssertTrue(body.contains("\"models\":{}"))
    }

    func testLeaderboardDecodesRowsAndQuery() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"board":"survival_current","platform":"claude-code","page":0,"rows":[
              {"rank":1,"login":"jalen","avatar_url":"https://a/x.png","pet":{"species":"frog","name":"Kero"},"value_ms":864000000},
              {"rank":2,"login":"amy","avatar_url":null,"pet":null,"value_ms":3600000}
            ]}
            """)
        let page = try await makeClient(fake).leaderboard(board: "survival_current", platform: "claude-code", page: 0)
        XCTAssertEqual(page.board, "survival_current")
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows[0].rank, 1)
        XCTAssertEqual(page.rows[0].login, "jalen")
        XCTAssertEqual(page.rows[0].avatarUrl, "https://a/x.png")
        XCTAssertEqual(page.rows[0].pet?.species, "frog")
        XCTAssertEqual(page.rows[0].pet?.name, "Kero")
        XCTAssertEqual(page.rows[0].valueMs, 864_000_000)
        XCTAssertNil(page.rows[0].value)
        XCTAssertNil(page.rows[1].avatarUrl)
        XCTAssertNil(page.rows[1].pet)

        let call = fake.calls[0]
        XCTAssertEqual(call.method, "GET")
        let query = call.url?.query ?? ""
        XCTAssertTrue(query.contains("board=survival_current"))
        XCTAssertTrue(query.contains("platform=claude-code"))
        XCTAssertTrue(query.contains("page=0"))
    }

    func testLeaderboardTokensBoardValueField() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"board":"tokens","platform":"claude-code","page":0,"rows":[
              {"rank":1,"login":"jalen","avatar_url":null,"pet":{"species":"frog","name":null},"value":123456789}
            ]}
            """)
        let page = try await makeClient(fake).leaderboard(board: "tokens", platform: nil, page: 0)
        XCTAssertEqual(page.rows[0].value, 123_456_789)
        XCTAssertNil(page.rows[0].valueMs)
        XCTAssertNil(page.rows[0].pet?.name)
        XCTAssertFalse((fake.calls[0].url?.query ?? "").contains("platform="))
    }

    func testModelStatsDecodes() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"platform":"claude-code","models":[
              {"model":"claude-sonnet-4-5","tokens_in":1000,"tokens_out":500,"calls":10,"users":37},
              {"model":"claude-opus-4-1","tokens_in":200,"tokens_out":100,"calls":2}
            ]}
            """)
        let stats = try await makeClient(fake).modelStats(platform: "claude-code")
        XCTAssertEqual(stats.platform, "claude-code")
        XCTAssertEqual(stats.models.count, 2)
        XCTAssertEqual(stats.models[0].model, "claude-sonnet-4-5")
        XCTAssertEqual(stats.models[0].tokensIn, 1000)
        XCTAssertEqual(stats.models[0].tokensOut, 500)
        XCTAssertEqual(stats.models[0].calls, 10)
        XCTAssertEqual(stats.models[0].users, 37)
        XCTAssertNil(stats.models[1].users)
        XCTAssertEqual(fake.calls[0].url?.absoluteString, "https://api.test/v1/stats/models?platform=claude-code")
    }

    func testMeDecodesRanksAndBearer() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 200, json: """
            {"id":42,"login":"jalen","avatar_url":"https://a/x.png","hidden":false,"flagged":false,
             "last_sync_at":1780488000000,
             "ranks":{"tokens":{"rank":12,"total":1873},"survival_current":null,"survival_best":{"rank":7,"total":1873}}}
            """)
        let me = try await makeClient(fake).me(token: "cg_test")
        XCTAssertEqual(me.login, "jalen")
        XCTAssertEqual(me.avatarUrl, "https://a/x.png")
        XCTAssertEqual(me.ranks.tokens, RankEntry(rank: 12, total: 1873))
        XCTAssertNil(me.ranks.survivalCurrent)
        XCTAssertEqual(me.ranks.survivalBest, RankEntry(rank: 7, total: 1873))
        XCTAssertEqual(fake.calls[0].headers["Authorization"], "Bearer cg_test")
        XCTAssertEqual(fake.calls[0].method, "GET")
    }

    func testUnauthorizedMapping() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 401, json: #"{"error":"unauthorized"}"#)
        do {
            _ = try await makeClient(fake).me(token: "bad")
            XCTFail("expected unauthorized")
        } catch let e as LeaderboardError {
            XCTAssertEqual(e, .unauthorized)
        }
    }

    func testHTTP500Mapping() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 500, json: #"{"error":"boom"}"#)
        do {
            _ = try await makeClient(fake).leaderboard(board: "tokens", platform: nil, page: 0)
            XCTFail("expected http 500")
        } catch let e as LeaderboardError {
            XCTAssertEqual(e, .http(status: 500))
        }
    }

    func testTransportErrorMapping() async throws {
        let fake = FakeHTTPTransport()
        fake.failNext(HTTPTransportError.nonHTTPResponse)
        do {
            _ = try await makeClient(fake).me(token: "x")
            XCTFail("expected transport error")
        } catch let e as LeaderboardError {
            XCTAssertEqual(e, .transport)
        }
    }

    func testDeleteAccountMethodAndBearer() async throws {
        let fake = FakeHTTPTransport()
        fake.enqueue(status: 204, body: Data())
        try await makeClient(fake).deleteAccount(token: "cg_test")
        XCTAssertEqual(fake.calls[0].method, "DELETE")
        XCTAssertEqual(fake.calls[0].url?.absoluteString, "https://api.test/v1/me")
        XCTAssertEqual(fake.calls[0].headers["Authorization"], "Bearer cg_test")
    }
}

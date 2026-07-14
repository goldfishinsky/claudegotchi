import XCTest
@testable import PetCore

final class LeaderboardCredentialsTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemoryCredentialsStore()
        XCTAssertNil(try store.load())

        let account = LeaderboardAccount(token: "cg_abc", githubLogin: "jalen", avatarUrl: "https://a/x.png")
        try store.save(account)
        XCTAssertEqual(try store.load(), account)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testInMemorySeedInitial() throws {
        let seeded = LeaderboardAccount(token: "cg_seed", githubLogin: "amy", avatarUrl: nil)
        let store = InMemoryCredentialsStore(seeded)
        XCTAssertEqual(try store.load(), seeded)
    }

    func testAccountCodableRoundTrip() throws {
        for avatar in ["https://a/x.png", nil] {
            let account = LeaderboardAccount(token: "cg_abc", githubLogin: "jalen", avatarUrl: avatar)
            let data = try JSONEncoder().encode(account)
            let decoded = try JSONDecoder().decode(LeaderboardAccount.self, from: data)
            XCTAssertEqual(decoded, account)
        }
    }
}

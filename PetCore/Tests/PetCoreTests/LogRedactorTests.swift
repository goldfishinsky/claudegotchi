import XCTest
@testable import PetCore

final class LogRedactorTests: XCTestCase {
    func testRedactsGitHubToken() {
        let out = LogRedactor.redact("token ghp_0123456789abcdefghijklmnopqrstuvwxyz here")
        XCTAssertFalse(out.contains("ghp_0123456789abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func testRedactsAuthorizationHeader() {
        let out = LogRedactor.redact("Authorization: Bearer sk-secret-value")
        XCTAssertFalse(out.contains("sk-secret-value"))
        XCTAssertFalse(out.contains("Bearer"))
        XCTAssertTrue(out.contains("Authorization: [REDACTED]"))
    }

    func testRedactsAwsAccessKey() {
        let out = LogRedactor.redact("key=AKIAIOSFODNN7EXAMPLE done")
        XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    func testRedactsUserInfoInURL() {
        let out = LogRedactor.redact("https://alice:s3cret@github.com/x.git")
        XCTAssertFalse(out.contains("alice:s3cret"))
        XCTAssertTrue(out.contains("github.com/x.git"))
    }

    func testLeavesCleanTextUntouched() {
        let clean = "Edit src/auth.ts 12.3k tokens"
        XCTAssertEqual(LogRedactor.redact(clean), clean)
    }
}

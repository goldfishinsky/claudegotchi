import XCTest
@testable import HookHelper

final class HookTypeGuardTests: XCTestCase {
    func testCwdReadFromPayload() {
        let cwd = ClaudegotchiHook.cwdFromPayload(#"{"cwd":"/tmp/work","session_id":"s"}"#)
        XCTAssertEqual(cwd, "/tmp/work")
    }

    func testCwdNilWhenAbsent() {
        XCTAssertNil(ClaudegotchiHook.cwdFromPayload(#"{"session_id":"s"}"#))
        XCTAssertNil(ClaudegotchiHook.cwdFromPayload(nil))
    }

    func testRejectsPrApprovedRawType() {
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_approved"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_merged"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_anything"))
    }

    func testAcceptsKnownHookType() {
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("session_start"))
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("post_tool_use"))
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("notification"))
    }
}

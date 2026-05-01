import XCTest
@testable import HookHelper

final class HookSpoolTests: XCTestCase {
    var url: URL!
    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID()).jsonl")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testAppendCreatesFileAndWritesLine() throws {
        try HookSpool.append("line-1", to: url)
        let content = try String(contentsOf: url)
        XCTAssertEqual(content, "line-1\n")
    }

    func testAppendAccumulates() throws {
        try HookSpool.append("a", to: url)
        try HookSpool.append("b", to: url)
        try HookSpool.append("c", to: url)
        let content = try String(contentsOf: url)
        XCTAssertEqual(content, "a\nb\nc\n")
    }

    func testParentDirectoryCreated() throws {
        let nested = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nested-\(UUID())/level1/level2/spool.jsonl")
        defer { try? FileManager.default.removeItem(at: nested.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        try HookSpool.append("x", to: nested)
        XCTAssertEqual(try String(contentsOf: nested), "x\n")
    }
}

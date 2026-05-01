import XCTest
@testable import PetCore

final class SpoolReaderTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID()).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ s: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(s.utf8))
        try h.close()
    }

    func testReadsCompleteLines() throws {
        try append("line1\nline2\nline3\n")
        let r = SpoolReader(url: url)
        XCTAssertEqual(try r.readNewLines(), ["line1", "line2", "line3"])
    }

    func testHoldsBackPartialLine() throws {
        try append("complete\npartial-no-newline")
        let r = SpoolReader(url: url)
        XCTAssertEqual(try r.readNewLines(), ["complete"])
        try append("-completed-now\n")
        XCTAssertEqual(try r.readNewLines(), ["partial-no-newline-completed-now"])
    }

    func testAdvancesOffsetAcrossCalls() throws {
        let r = SpoolReader(url: url)
        try append("a\n")
        XCTAssertEqual(try r.readNewLines(), ["a"])
        try append("b\nc\n")
        XCTAssertEqual(try r.readNewLines(), ["b", "c"])
        XCTAssertEqual(try r.readNewLines(), [])
    }

    func testMissingFileReturnsEmpty() throws {
        let r = SpoolReader(url: url)
        XCTAssertEqual(try r.readNewLines(), [])
    }

    func testOffsetResetOnRotation() throws {
        let r = SpoolReader(url: url)
        try append("a\nb\n")
        XCTAssertEqual(try r.readNewLines(), ["a", "b"])
        try FileManager.default.removeItem(at: url)
        try append("c\n")
        XCTAssertEqual(try r.readNewLines(), ["c"])
    }
}

import XCTest
@testable import PetCore

final class NativeTitleSettingTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private let iso = "20260720T000000Z"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try json.data(using: .utf8)!.write(to: settings)
    }
    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testEnableOnMissingFileCreatesEnvEntry() throws {
        XCTAssertFalse(try NativeTitleSetting.isDisabled(settingsPath: settings))
        try NativeTitleSetting.setDisabled(true, settingsPath: settings, nowISO: iso)
        XCTAssertTrue(try NativeTitleSetting.isDisabled(settingsPath: settings))
        let env = try read()["env"] as? [String: Any]
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String, "1")
    }

    func testEnablePreservesExistingKeysAndBacksUp() throws {
        try write(#"{"model":"opus","env":{"FOO":"bar"},"hooks":{"Stop":[]}}"#)
        try NativeTitleSetting.setDisabled(true, settingsPath: settings, nowISO: iso)
        let root = try read()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["hooks"])
        let env = root["env"] as? [String: Any]
        XCTAssertEqual(env?["FOO"] as? String, "bar")
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String, "1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: settings.appendingPathExtension("bak-\(iso)").path))
    }

    func testDisableRemovesOnlyOurKeyLeavingOtherEnv() throws {
        try write(#"{"env":{"FOO":"bar","CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"1"}}"#)
        try NativeTitleSetting.setDisabled(false, settingsPath: settings, nowISO: iso)
        let env = try read()["env"] as? [String: Any]
        XCTAssertNil(env?["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"])
        XCTAssertEqual(env?["FOO"] as? String, "bar")
    }

    func testDisableDropsEmptyEnvDict() throws {
        try write(#"{"env":{"CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"1"}}"#)
        try NativeTitleSetting.setDisabled(false, settingsPath: settings, nowISO: iso)
        XCTAssertNil(try read()["env"])
    }

    func testDisableLeavesUserAuthoredValueUntouched() throws {
        try write(#"{"env":{"CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"0"}}"#)
        try NativeTitleSetting.setDisabled(false, settingsPath: settings, nowISO: iso)
        let env = try read()["env"] as? [String: Any]
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String, "0",
                       "a value we did not write must be preserved")
    }

    func testEnableIsIdempotent() throws {
        try NativeTitleSetting.setDisabled(true, settingsPath: settings, nowISO: iso)
        try NativeTitleSetting.setDisabled(true, settingsPath: settings, nowISO: iso)
        let env = try read()["env"] as? [String: Any]
        XCTAssertEqual(env?.count, 1)
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String, "1")
    }

    func testCorruptSettingsThrows() throws {
        try write("{ not json")
        XCTAssertThrowsError(try NativeTitleSetting.isDisabled(settingsPath: settings)) {
            XCTAssertEqual($0 as? NativeTitleSetting.SettingError, .corruptSettings)
        }
    }
}

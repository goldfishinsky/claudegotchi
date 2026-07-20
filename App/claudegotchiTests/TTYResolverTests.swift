import XCTest
@testable import claudegotchi

final class TTYResolverTests: XCTestCase {
    func testResolvesTerminalThroughShellChain() {
        let procs = [
            ProcInfo(pid: 100, ppid: 90, tty: "/dev/ttys001"),   // claude
            ProcInfo(pid: 90, ppid: 80, tty: "/dev/ttys001"),    // zsh
            ProcInfo(pid: 80, ppid: 50, tty: "/dev/ttys001"),    // login
            ProcInfo(pid: 50, ppid: 1, tty: nil),                // Terminal.app
        ]
        let apps: [Int32: String] = [50: "com.apple.Terminal"]
        XCTAssertEqual(
            TTYOwnerResolver.resolve(tty: "/dev/ttys001", processes: procs, guiApps: apps),
            "com.apple.Terminal")
    }

    func testResolvesElectronEditorThroughHelperChain() {
        let procs = [
            ProcInfo(pid: 200, ppid: 190, tty: "/dev/ttys002"),  // shell in integrated terminal
            ProcInfo(pid: 190, ppid: 180, tty: nil),             // pty host
            ProcInfo(pid: 180, ppid: 170, tty: nil),             // Code Helper
            ProcInfo(pid: 170, ppid: 1, tty: nil),               // Code main
        ]
        let apps: [Int32: String] = [170: "com.microsoft.VSCode"]
        XCTAssertEqual(
            TTYOwnerResolver.resolve(tty: "/dev/ttys002", processes: procs, guiApps: apps),
            "com.microsoft.VSCode")
    }

    func testReturnsNilWhenNoGUIAncestor() {
        let procs = [
            ProcInfo(pid: 100, ppid: 90, tty: "/dev/ttys001"),
            ProcInfo(pid: 90, ppid: 1, tty: "/dev/ttys001"),
        ]
        XCTAssertNil(TTYOwnerResolver.resolve(tty: "/dev/ttys001", processes: procs, guiApps: [:]))
    }

    func testReturnsNilWhenTTYAbsentFromTable() {
        let procs = [ProcInfo(pid: 100, ppid: 50, tty: "/dev/ttys001")]
        let apps: [Int32: String] = [50: "com.apple.Terminal"]
        XCTAssertNil(TTYOwnerResolver.resolve(tty: "/dev/ttys999", processes: procs, guiApps: apps))
    }

    func testReturnsNilForEmptyTTY() {
        XCTAssertNil(TTYOwnerResolver.resolve(tty: "", processes: [], guiApps: [:]))
    }

    func testPicksFirstGUIAncestorNotADeeperOne() {
        let procs = [
            ProcInfo(pid: 300, ppid: 250, tty: "/dev/ttys003"),  // shell
            ProcInfo(pid: 250, ppid: 1, tty: nil),               // iTerm2 (immediate GUI parent)
        ]
        let apps: [Int32: String] = [250: "com.googlecode.iterm2", 1: "com.apple.launchd"]
        XCTAssertEqual(
            TTYOwnerResolver.resolve(tty: "/dev/ttys003", processes: procs, guiApps: apps),
            "com.googlecode.iterm2")
    }

    func testTerminatesOnParentCycleWithoutHang() {
        let procs = [
            ProcInfo(pid: 10, ppid: 20, tty: "/dev/ttys004"),
            ProcInfo(pid: 20, ppid: 10, tty: "/dev/ttys004"),
        ]
        XCTAssertNil(TTYOwnerResolver.resolve(tty: "/dev/ttys004", processes: procs, guiApps: [:]))
    }
}

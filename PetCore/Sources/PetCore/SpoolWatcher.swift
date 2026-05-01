import Foundation
import GRDB
#if canImport(CoreServices)
import CoreServices
#endif

public final class SpoolWatcher {
    private let db: DatabaseQueue
    private let applier: EventApplier
    private let spoolURL: URL
    private let spoolLockURL: URL
    private let pausedProvider: () -> Bool
    private let config: ConfigYAML
    private let reader: SpoolReader
    private var fsStream: FSEventStreamRef?

    public init(
        db: DatabaseQueue, applier: EventApplier,
        spoolURL: URL, spoolLockURL: URL,
        pausedProvider: @escaping () -> Bool,
        config: ConfigYAML
    ) {
        self.db = db
        self.applier = applier
        self.spoolURL = spoolURL
        self.spoolLockURL = spoolLockURL
        self.pausedProvider = pausedProvider
        self.config = config
        self.reader = SpoolReader(url: spoolURL)
    }

    public func pump() throws {
        let lines = try reader.readNewLines()
        let atx = ApplyTransaction(db: db, applier: applier, paused: pausedProvider())
        for line in lines {
            try atx.process(jsonLine: line)
        }
    }

    public func maybeRotate() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: spoolURL.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: spoolURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let ageSeconds = -mtime.timeIntervalSinceNow
        guard size > config.spool.rotateWhenBytesExceed
            || ageSeconds > Double(config.spool.rotateWhenAgeExceedsSeconds) else { return }

        let lockFD = open(spoolLockURL.path, O_WRONLY | O_CREAT, 0o600)
        guard lockFD >= 0 else { return }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { return }
        defer { _ = flock(lockFD, LOCK_UN) }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let bakURL = spoolURL.appendingPathExtension("\(stamp).bak")
        // Spec §4: a helper that is mid-write during this rename keeps its
        // open fd pointing at the .bak inode (POSIX semantics on APFS). The
        // helper finishes its write into the .bak, which we drain below.
        // No event loss.
        try fm.moveItem(at: spoolURL, to: bakURL)

        let bakReader = SpoolReader(url: bakURL)
        let lines = try bakReader.readNewLines()
        let atx = ApplyTransaction(db: db, applier: applier, paused: pausedProvider())
        for line in lines {
            try atx.process(jsonLine: line)
        }
        try fm.removeItem(at: bakURL)
    }

    public func startWatching() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [spoolURL.deletingLastPathComponent().path] as CFArray
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<SpoolWatcher>.fromOpaque(info).takeUnretainedValue()
            try? watcher.pump()
            try? watcher.maybeRotate()
        }
        fsStream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        if let s = fsStream {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
        }
    }

    public func stopWatching() {
        if let s = fsStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            fsStream = nil
        }
    }
}

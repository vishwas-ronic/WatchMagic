import Foundation

/// Append-only JSON-lines diagnostic log with size rotation.
///
/// `log(_:_:)` is cheap and thread-safe: it serialises one line and appends it
/// to an in-memory buffer. File I/O happens only in `flush` on a private
/// utility queue (call `startAutoFlush()` to flush every ~2 s), so it can be
/// called from the motion queue. When the file would exceed `maxBytes` it is
/// moved to `<name>.1` (replacing the previous backup) and a new file started.
///
/// Each line: `{"ts": "<ISO time>", "ev": "<event>", ...fields}` with sorted
/// keys. Fields whose key looks like a secret (token, authorization,
/// password, secret, bearer) are dropped; doubles are rounded to 4 decimals;
/// NaN/∞ become strings.
public final class DiagLog: @unchecked Sendable {
    public static let defaultMaxBytes = 1_000_000
    /// Lines kept in memory if flushing stalls (oldest dropped beyond this).
    public static let maxBufferedLines = 5000

    public let url: URL
    public let maxBytes: Int
    public var backupURL: URL { url.appendingPathExtension("1") }

    private let lock = NSLock()
    private var buffer: [String] = []
    private var dropped = 0
    private let ioQueue = DispatchQueue(label: "ai.ronic.watchmagic.diaglog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let now: @Sendable () -> Date

    public init(url: URL, maxBytes: Int = DiagLog.defaultMaxBytes, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.maxBytes = maxBytes
        self.now = now
    }

    // MARK: Logging

    public func log(_ event: String, _ fields: [String: Any?] = [:]) {
        let line = Self.line(event: event, fields: fields, date: now())
        lock.lock()
        buffer.append(line)
        if buffer.count > Self.maxBufferedLines {
            let n = buffer.count - Self.maxBufferedLines
            buffer.removeFirst(n)
            dropped += n
        }
        lock.unlock()
    }

    private static let secretKeys = ["token", "authorization", "password", "secret", "bearer"]

    /// One JSON line (no trailing newline).
    public static func line(event: String, fields: [String: Any?], date: Date) -> String {
        var obj: [String: Any] = [:]
        for (k, v) in fields {
            let lower = k.lowercased()
            if secretKeys.contains(where: { lower.contains($0) }) { continue }
            guard let v else { continue }
            obj[k] = sanitize(v)
        }
        obj["ts"] = isoString(date)
        obj["ev"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"ev":"diag_encode_error","event":"\#(event)"}"#
        }
        return s
    }

    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double:
            guard d.isFinite else { return String(d) }
            // Decimal so JSONSerialization prints "50.1", not "50.100000000000001".
            return NSDecimalNumber(string: String(format: "%.4f", d), locale: Locale(identifier: "en_US_POSIX"))
        case let f as Float:
            return sanitize(Double(f))
        case let i as Int: return i
        case let b as Bool: return b
        case let s as String: return s
        case let u as UUID: return u.uuidString
        case let a as [Any]: return a.map(sanitize)
        case let a as [Any?]: return a.map { $0.map(sanitize) ?? NSNull() }
        case let o as [String: Any]: return o.mapValues(sanitize)
        case let o as [String: Any?]: return o.compactMapValues { $0.map(sanitize) }
        case let d as Date: return isoString(d)
        case let url as URL: return url.absoluteString
        default: return String(describing: v)
        }
    }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: Flushing

    /// Flushes every `interval` seconds until `stopAutoFlush()`.
    public func startAutoFlush(interval: TimeInterval = 2) {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.writePending() }
        t.resume()
        timer = t
    }

    public func stopAutoFlush() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Asynchronous flush on the I/O queue.
    public func flush() {
        ioQueue.async { [weak self] in self?.writePending() }
    }

    /// Blocks until everything logged so far is on disk (tests, before sending the log).
    public func flushSync() {
        ioQueue.sync { writePending() }
    }

    /// Lines logged but not yet written.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    private func writePending() {
        lock.lock()
        var lines = buffer
        let lost = dropped
        buffer = []
        dropped = 0
        lock.unlock()
        if lost > 0 {
            lines.insert(Self.line(event: "diag_dropped", fields: ["lines": lost], date: now()), at: 0)
        }
        guard !lines.isEmpty else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maxBytes {
            try? fm.removeItem(at: backupURL)
            try? fm.moveItem(at: url, to: backupURL)
        }
        if fm.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

import XCTest
@testable import WatchMagicKit

final class DiagnosticsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    // MARK: DiagLog

    func testLineIsSortedJSONWithoutSecrets() throws {
        let line = DiagLog.line(event: "ha_call",
                                fields: ["service": "light.turn_on", "ms": 123.456789, "ok": true, "token": "abc",
                                         "Authorization": "Bearer abc", "missing": nil, "nan": Double.nan,
                                         "id": UUID(uuidString: "00000000-0000-0000-0000-000000000001")!],
                                date: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(line.contains("abc"))
        XCTAssertFalse(line.contains("\n"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["ev"] as? String, "ha_call")
        XCTAssertEqual(obj["ts"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(obj["ms"] as? Double, 123.4568)
        XCTAssertEqual(obj["ok"] as? Bool, true)
        XCTAssertEqual(obj["nan"] as? String, "nan")
        XCTAssertNil(obj["missing"])
        XCTAssertEqual(obj["id"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertLessThan(line.range(of: "\"ev\"")!.lowerBound, line.range(of: "\"ts\"")!.lowerBound)
    }

    func testBufferedUntilFlushThenAppends() throws {
        let url = try tempDir().appendingPathComponent("diag.log")
        let log = DiagLog(url: url)
        log.log("a", ["n": 1])
        log.log("b")
        XCTAssertEqual(log.pendingCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        log.flushSync()
        XCTAssertEqual(log.pendingCount, 0)
        log.log("c")
        log.flushSync()
        XCTAssertEqual(try lines(url).map { $0["ev"] as? String }, ["a", "b", "c"])
    }

    func testRotatesKeepingOneBackup() throws {
        let url = try tempDir().appendingPathComponent("diag.log")
        let log = DiagLog(url: url, maxBytes: 600)
        for round in 0..<3 {
            for i in 0..<5 { log.log("r\(round)", ["i": i, "pad": String(repeating: "x", count: 40)]) }
            log.flushSync()
        }
        let main = try lines(url), backup = try lines(log.backupURL)
        XCTAssertEqual(Set(main.compactMap { $0["ev"] as? String }), ["r2"])
        XCTAssertEqual(Set(backup.compactMap { $0["ev"] as? String }), ["r1"]) // r0 rotated out
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.backupURL.appendingPathExtension("1").path))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 600)
    }

    func testAutoFlush() throws {
        let url = try tempDir().appendingPathComponent("diag.log")
        let log = DiagLog(url: url)
        log.startAutoFlush(interval: 0.05)
        defer { log.stopAutoFlush() }
        log.log("tick")
        let exp = expectation(description: "flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(try lines(url).first?["ev"] as? String, "tick")
    }

    // MARK: Ring buffer

    private func sample(_ t: Double) -> MotionSample {
        MotionSample(t: t, rotationRate: .zero, gravity: Vector3(0, 0, -1), attitude: Quaternion(x: 0, y: 0, z: 0, w: 1))
    }

    func testRingBufferKeepsLastDuration() {
        var r = MotionRingBuffer(duration: 2, maxRateHz: 10) // capacity 21
        for i in 0..<55 { r.append(sample(Double(i) * 0.1)) } // 0 … 5.4 s
        let s = r.samples()
        XCTAssertEqual(r.count, 21)
        XCTAssertEqual(s.first!.t, 3.4, accuracy: 1e-9)
        XCTAssertEqual(s.last!.t, 5.4, accuracy: 1e-9)
        XCTAssertEqual(s.map(\.t), s.map(\.t).sorted())
        // Time limit applies even when not full (rate lower than expected).
        var slow = MotionRingBuffer(duration: 2, maxRateHz: 10)
        for i in 0..<6 { slow.append(sample(Double(i))) }
        XCTAssertEqual(slow.samples().map(\.t), [3, 4, 5])
        slow.removeAll()
        XCTAssertTrue(slow.samples().isEmpty)
    }

    // MARK: Bursts

    func testBurstSummarisesAndRateLimits() throws {
        var b = RotationBurstTracker(threshold: 1.5, quietTime: 0.1, maxDuration: 2, minInterval: 0.5)
        var out: [RotationBurst] = []
        func feed(_ t: Double, _ pr: Double, _ rr: Double, _ w: Double) {
            if let x = b.process(t: t, pitchRate: pr, rollRate: rr, speed: w) { out.append(x) }
        }
        feed(0.00, 0, 0, 0.2)
        feed(0.01, -2.4, 0.3, 2.5)
        feed(0.02, -3.1, 0.5, 3.2)  // sub-threshold flick (detector needs 3.5)
        b.noteGesture()
        feed(0.03, 1.0, 0.1, 1.2)
        feed(0.20, 0, 0, 0.1)        // quiet ≥ 0.1 s → burst 1 reported
        XCTAssertEqual(out.count, 1)
        let first = try XCTUnwrap(out.first)
        XCTAssertEqual(first.maxPitchRate, 3.1); XCTAssertEqual(first.maxRollRate, 0.5); XCTAssertEqual(first.maxSpeed, 3.2)
        XCTAssertEqual(first.samples, 2); XCTAssertTrue(first.gestureFired); XCTAssertEqual(first.suppressedBefore, 0)
        // A second burst 0.3 s after the first: suppressed.
        feed(0.30, 2, 0, 2); feed(0.50, 0, 0, 0)
        XCTAssertEqual(out.count, 1)
        // A third one later: reported, counting the suppressed one.
        feed(1.00, 0, 4, 4); feed(1.20, 0, 0, 0)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].suppressedBefore, 1)
        XCTAssertFalse(out[1].gestureFired)
        // Max duration ends a long burst.
        for i in 0...30 { feed(3 + Double(i) * 0.1, 0, 0, 2) }
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2].duration, 2, accuracy: 1e-9)
    }

    func testTraceRecorderStall() {
        var r = TraceRecorder(duration: 10)
        XCTAssertFalse(r.isStalled(at: 100))
        _ = r.append(sample(0)); _ = r.append(sample(0.01))
        XCTAssertFalse(r.isStalled(at: 0.9))
        XCTAssertTrue(r.isStalled(at: 1.2))
        XCTAssertEqual(r.lastSampleTime, 0.01)
    }
}

final class TrainingTests: XCTestCase {
    private func sample(_ t: Double, accel: Vector3? = Vector3(0.01, -0.02, 0.5)) -> MotionSample {
        MotionSample(t: t, rotationRate: Vector3(1, 2, 3), gravity: Vector3(0, 0, -1),
                     attitude: Quaternion(x: 0, y: 0, z: 0, w: 1), userAcceleration: accel)
    }

    func testCSVUserAccelerationRoundTripAndOldFormat() throws {
        let csv = MotionCSV.encode([sample(1), sample(1.02)], comments: ["label=x"])
        XCTAssertTrue(csv.hasPrefix("# label=x\nt,rx,ry,rz,gx,gy,gz,qx,qy,qz,qw,ax,ay,az\n"), csv)
        let back = try MotionCSV.decode(csv)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].userAcceleration, Vector3(0.01, -0.02, 0.5))
        // Old traces (no ax/ay/az) still load, with nil acceleration.
        let old = try MotionCSV.decode("t,rx,ry,rz,gx,gy,gz,qx,qy,qz,qw\n0,0,0,0,0,0,-1,0,0,0,1\n")
        XCTAssertEqual(old.count, 1)
        XCTAssertNil(old[0].userAcceleration)
        // No acceleration anywhere → no columns.
        XCTAssertFalse(MotionCSV.encode([sample(0, accel: nil)]).contains("ax"))
    }

    func testPlanTiming() {
        let p = TrainingPlan.standard
        XCTAssertEqual(p.cueOffsets(for: .flickUp), [1, 3.5, 6, 8.5, 11, 13.5, 16, 18.5, 21, 23.5])
        XCTAssertEqual(p.duration(for: .twist), 25.5, accuracy: 1e-9)
        XCTAssertEqual(p.cueOffsets(for: .none), [])
        XCTAssertEqual(p.duration(for: .none), 60)
    }

    func testRecorderEmitsCuesAndFinishes() throws {
        var r = TrainingRecorder(label: .flickDown)
        var events: [TrainingRecorder.Event] = []
        let t0 = 5000.0
        var i = 0
        while !r.isFinished {
            events += r.append(sample(t0 + Double(i) * 0.02))
            i += 1
        }
        XCTAssertEqual(events.filter { if case .cue = $0 { return true } else { return false } }.count, 10)
        XCTAssertEqual(events.last, .finished)
        XCTAssertEqual(r.cueTimes.count, 10)
        XCTAssertEqual(r.cueTimes[0] - t0, 1, accuracy: 0.021)
        XCTAssertEqual(r.cueTimes[9] - t0, 23.5, accuracy: 0.021)
        XCTAssertEqual(r.samples.last!.t - t0, 25.5, accuracy: 0.021)
        XCTAssertEqual(try XCTUnwrap(r.measuredRateHz), 50, accuracy: 0.1)
        XCTAssertTrue(r.append(sample(t0 + 30)).isEmpty) // finished: ignored

        let csv = r.csv(wristIsLeft: true, crownIsRight: true, pointingSign: -1, requestedRateHz: 50)
        let h = TrainingRecorder.headerFields(of: csv)
        XCTAssertEqual(h["label"], "flickDown")
        XCTAssertEqual(h["wrist"], "left"); XCTAssertEqual(h["crown"], "right"); XCTAssertEqual(h["sign"], "-1")
        XCTAssertEqual(h["rate"], "50")
        XCTAssertEqual(h["complete"], "true")
        let cues = try XCTUnwrap(h["cues"]).split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(cues.count, 10)
        XCTAssertEqual(cues[0], r.cueTimes[0], accuracy: 1e-6)
        XCTAssertEqual(try MotionCSV.decode(csv).count, r.samples.count) // comment lines ignored
    }

    func testFileNameAndStall() {
        let d = Date(timeIntervalSince1970: 1_794_045_000)
        XCTAssertEqual(TrainingRecorder.fileName(label: .flickUp, date: d, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
                       "train-flickUp-20261107-152000.csv")
        var r = TrainingRecorder(label: .none)
        _ = r.append(sample(0))
        XCTAssertTrue(r.isStalled(at: 1.5))
        XCTAssertFalse(r.isStalled(at: 0.5))
    }
}

final class TrainingMessageTests: XCTestCase {
    func testStartRoundTripAndPlan() throws {
        let s = TrainingStart(label: .twist)
        let d = try s.dictionary()
        XCTAssertEqual(d[SyncPayload.Keys.kind] as? String, "trainingStart")
        XCTAssertTrue(d.values.allSatisfy { $0 is String || $0 is Data }) // plist-safe
        let back = try TrainingStart(dictionary: d)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.cueCount, 10)
        XCTAssertEqual(back.plan, TrainingPlan.standard)
        XCTAssertEqual(TrainingStart(label: .none).cueCount, 0)
        XCTAssertEqual(TrainingStart(label: .none).plan.duration(for: .none), 60)
        // Clamped.
        var wild = s; wild.cueCount = 1000; wild.cueIntervalS = 0
        XCTAssertEqual(wild.plan.cueCount, 50); XCTAssertEqual(wild.plan.cueInterval, 0.5)
        XCTAssertThrowsError(try TrainingStart(dictionary: try TrainingCancel(sessionID: s.sessionID).dictionary()))
    }

    func testStatusAndCancelRoundTrip() throws {
        let st = TrainingStatus(sessionID: UUID(), label: .flickUp, phase: .cue, cueIndex: 2, cueTotal: 10)
        XCTAssertEqual(try TrainingStatus(dictionary: st.dictionary()), st)
        let c = TrainingCancel(sessionID: UUID())
        XCTAssertEqual(try TrainingCancel(dictionary: c.dictionary()), c)
        XCTAssertEqual(SyncPayload.kind(of: try st.dictionary()), .trainingStatus)
    }

    func testTrainingFileNames() {
        XCTAssertEqual(TrainingRecorder.label(ofFileName: "train-flickDown-20261107-152000.csv"), .flickDown)
        XCTAssertEqual(TrainingRecorder.label(ofFileName: "train-none-20261107-152000.csv"), TrainingLabel.none)
        XCTAssertNil(TrainingRecorder.label(ofFileName: "trace-20261107-152000.csv"))
        XCTAssertNil(TrainingRecorder.label(ofFileName: "train-bogus-1.csv"))
        XCTAssertTrue(TrainingRecorder.isTrainingFile("train-twist-x.csv"))
    }
}

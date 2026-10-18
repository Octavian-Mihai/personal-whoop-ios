import XCTest
@testable import StrandAnalytics
@testable import WhoopProtocol

final class EngineTests: XCTestCase {
    func testFrameHelloMatchesSpec() {
        // Spec §14.10 worked example: 5/MG client hello.
        let expected: [UInt8] = [0xAA,0x01,0x08,0x00,0x00,0x01,0xE6,0x71,0x23,0x01,0x91,0x01,0x36,0x3E,0x5C,0x8D]
        let built = FrameCodec.build(family: .whoop5, .getHello, seq: 1, payload: [0x01])
        XCTAssertEqual(built, expected)
        if case .success(let f) = FrameCodec.verify(expected, family: .whoop5) { XCTAssertEqual(f.command, 145) } else { XCTFail() }
    }

    func testWhoop4RoundTripAndReassembly() {
        let b = FrameCodec.build(family: .whoop4, .getBatteryLevel, seq: 1)
        XCTAssertEqual(b.count, 12)
        var r = Reassembler(family: .whoop4)
        XCTAssertTrue(r.feed(Array(b[0..<5])).isEmpty)
        XCTAssertEqual(r.feed(Array(b[5...])).count, 1)
        var bad = b; bad[8] ^= 0xFF
        XCTAssertEqual(FrameCodec.verify(bad, family: .whoop4), .failure(.payloadCRCMismatch))
    }

    func testHRVCleaningAndRMSSD() {
        let rr = (0..<60).map { 800.0 + ($0 % 2 == 0 ? 20 : -20) }
        let r = HRVAnalyzer.analyze(rr)!
        XCTAssertEqual(r.rmssd, 40, accuracy: 0.01)
        XCTAssertNil(HRVAnalyzer.analyze(Array(rr.prefix(10))))
    }

    func testBaselineAndCharge() {
        var hrv = Baseline(metric: .hrv), rhr = Baseline(metric: .restingHR), resp = Baseline(metric: .respiration)
        for i in 0..<20 { hrv.fold(60 + Double(i % 3)); rhr.fold(55); resp.fold(14.5) }
        XCTAssertEqual(hrv.status, .trusted)
        let b = ChargeBaselines(hrv: hrv, restingHR: rhr, respiration: resp)
        let hi = RecoveryScorer.score(.init(hrv: 85, restingHR: 52, rest: 90), baselines: b)!
        let lo = RecoveryScorer.score(.init(hrv: 40, restingHR: 62, rest: 50), baselines: b)!
        XCTAssertGreaterThan(hi.score, lo.score)
        XCTAssertEqual(hi.band, .green); XCTAssertEqual(lo.band, .red)
        XCTAssertNil(RecoveryScorer.score(.init(hrv: 60), baselines: ChargeBaselines(hrv: Baseline(metric: .hrv), restingHR: rhr, respiration: resp)))
    }

    func testEffortLogCompression() {
        let rest = 55.0, mx = 190.0
        let hr = (0..<1200).map { HRSample(t: Double($0), bpm: 175) }   // 20 min at ~89 %HRR → zone 4
        let e = StrainScorer.score(hr: hr, restingHR: rest, hrMax: mx)!
        XCTAssertGreaterThan(e, 30); XCTAssertLessThan(e, 70)
        XCTAssertNil(StrainScorer.score(hr: Array(hr.prefix(100)), restingHR: rest, hrMax: mx))
    }

    func testRestScore() {
        let r = RestScorer.score(asleepMin: 480, inBedMin: 500, deepMin: 70, remMin: 110, needMin: 480, consistency: 0.9)!
        XCTAssertGreaterThan(r, 85)
        let poor = RestScorer.score(asleepMin: 240, inBedMin: 400, deepMin: 5, remMin: 20, needMin: 480)!
        XCTAssertLessThan(poor, 50)
    }

    func testSleepDebtAndNeed() {
        XCTAssertEqual(SleepDebt.debt(nights: [480, 480], baseNeed: 480), 0)
        XCTAssertGreaterThan(SleepDebt.debt(nights: [300, 300, 300], baseNeed: 480), 100)
        XCTAssertEqual(SleepNeed.need(recentDurationsMin: [400, 410]), 480)
    }

    func testStagerProducesSegments() {
        let start = 1_760_000_000.0, end = start + 7 * 3600
        let hr = stride(from: start, to: end, by: 5).map { HRSample(t: $0, bpm: 52 + 4 * sin($0 / 900)) }
        let g = stride(from: start, to: end, by: 10).map { GravitySample(t: $0, x: 0, y: 0, z: 1) }
        let segs = SleepStager.stage(start: start, end: end, hr: hr, gravity: g)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.first!.start, start, accuracy: 1)
    }

    func testHydrationAndZones() {
        XCTAssertEqual(HydrationGoal.goalML(male: true, effort: 50), 4050)
        XCTAssertEqual(HRZones(age: 30).zone(for: 190), 5)
    }

    func testBreathPacerAndAlarm() {
        let c = BreathPacer.cues(bpm: 6, durationSeconds: 30)
        XCTAssertEqual(c.first, HapticCue(offsetMs: 0, pulses: 1))
        XCTAssertEqual(c[1], HapticCue(offsetMs: 4000, pulses: 2))
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let a = SmartAlarm.next(after: now, wakeMinute: 7 * 60, weekdays: [], calendar: cal)!
        XCTAssertGreaterThan(a, now)
        XCTAssertEqual(WindDownNudge.minuteOfDay(wakeMinute: 6 * 60).minute, 21 * 60 + 30)
    }

    func testSleepMarksRefineDetection() {
        let data = 0.0...100_000
        let detected = [(start: 3_600.0, end: 30_000.0)]
        // both marks: user's window wins
        let both = SleepDetector.refine(detected: detected, bed: 1_000, wake: 28_000, dataRange: data)
        XCTAssertEqual(both.count, 1); XCTAssertEqual(both[0].start, 1_000); XCTAssertEqual(both[0].end, 28_000)
        // bed only, close: start snaps
        XCTAssertEqual(SleepDetector.refine(detected: detected, bed: 2_000, wake: nil, dataRange: data)[0].start, 2_000)
        // wake only, close: end snaps
        XCTAssertEqual(SleepDetector.refine(detected: detected, bed: nil, wake: 31_000, dataRange: data)[0].end, 31_000)
        // far-away marks are ignored
        XCTAssertEqual(SleepDetector.refine(detected: detected, bed: 60_000, wake: nil, dataRange: data)[0].start, 3_600)
        // an absurd window (> 16 h) isn't used as a window; each mark is judged on its own (bed snaps, far wake ignored)
        let odd = SleepDetector.refine(detected: detected, bed: 0, wake: 70_000, dataRange: data)[0]
        XCTAssertEqual(odd.start, 0); XCTAssertEqual(odd.end, 30_000)
    }

    func testSnoozeRingsAgainAfterDelay() {
        let fired = Date(timeIntervalSince1970: 1_760_000_000)               // an alarm that just went off
        let again = SmartAlarm.snoozeInstant(firedAt: fired, delayMinutes: 4, count: 0)!
        XCTAssertEqual(again.timeIntervalSince(fired), 240, accuracy: 60)    // ~4 min later, rounded up to a whole minute
        XCTAssertGreaterThanOrEqual(again, fired.addingTimeInterval(240))
        XCTAssertNotNil(SmartAlarm.snoozeInstant(firedAt: fired, delayMinutes: 4, count: 2))
        XCTAssertNil(SmartAlarm.snoozeInstant(firedAt: fired, delayMinutes: 4, count: 3))   // max 3 re-arms
    }

    func testFusionAndStreaks() {
        let r = FusionResolver.resolve(.steps, inputs: [(.noopComputed, 9000), (.appleHealth, 8800)])!
        XCTAssertEqual(r.winner.source, .appleHealth); XCTAssertEqual(r.agreement, .agree)
        let s = StreakCalculator.streaks(days: ["2026-10-15", "2026-10-16", "2026-10-17"], today: "2026-10-18")
        XCTAssertEqual(s.current, 3); XCTAssertEqual(s.longest, 3)
    }

    func testCosinor() {
        var bins: [(hour: Double, value: Double)] = []
        for h in 0..<24 {
            let hour = Double(h)
            let phase: Double = 2.0 * Double.pi * (hour - 15.0) / 24.0
            bins.append((hour: hour, value: 70.0 + 10.0 * cos(phase)))
        }
        let f = CircadianEngine.cosinor(bins)!
        XCTAssertEqual(f.amplitude, 10, accuracy: 0.01); XCTAssertEqual(f.acrophase, 15, accuracy: 0.01)
    }
}

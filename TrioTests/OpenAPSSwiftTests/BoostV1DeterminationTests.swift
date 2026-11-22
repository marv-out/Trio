import Foundation
import Testing
@testable import Trio

/// The Boost-active determination runs the V1 engine (BoostV1Engine, parity-checked against AAPS
/// DetermineBasalBoost in BoostV5Core). These tests cover Trio's side: that active mode reaches the
/// engine and the stock path does not, that the inputs it builds carry the values AAPS gives the
/// engine, and that the user's SMB-off lever still stands.
@Suite("Boost V1 determination") struct BoostV1DeterminationTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14

    private func profile() -> Profile {
        var p = Profile()
        p.currentBasal = 1.0
        p.maxDailyBasal = 1.5
        p.maxBasal = 3.0
        p.minBg = 90
        p.maxBg = 160
        p.sens = 40
        p.carbRatio = 10
        p.thresholdSetting = 70
        p.maxIob = 6
        p.enableSMBAlways = true
        p.enableUAM = true
        p.bolusIncrement = 0.05
        p.smbInterval = 3
        return p
    }

    private func preferences(_ mode: BoostMode, boostMaxIOB: Decimal = 12) -> Preferences {
        var p = Preferences()
        p.boostMaxIOB = boostMaxIOB
        p.curve = .rapidActing
        p.useCustomPeakTime = false
        p.boostMode = mode
        p.boostUseTdd = false
        return p
    }

    private func tick(_ value: Decimal, _ k: Int) -> IobResult {
        let time = now.addingTimeInterval(Double(k) * 300)
        let zeroTemp = IobResult.IobWithZeroTemp(
            iob: value, activity: 0, basaliob: value, bolusiob: 0, netbasalinsulin: 0, bolusinsulin: 0, time: time
        )
        var result = IobResult(
            iob: value, activity: 0, basaliob: value, bolusiob: 0, netbasalinsulin: 0, bolusinsulin: 0,
            time: time, iobWithZeroTemp: zeroTemp, lastBolusTime: nil, lastTemp: nil
        )
        if k == 0 {
            result.lastBolusTime = UInt64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
            let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
            result.lastTemp = IobResult.LastTemp(rate: 0, timestamp: now, started_at: now, date: nowMs, duration: 30)
        }
        return result
    }

    private func iob(_ value: Decimal) -> [IobResult] {
        (0 ..< 48).map { tick(value, $0) }
    }

    private func variables(smbIsOff: Bool = false) -> TrioCustomOrefVariables {
        TrioCustomOrefVariables(
            average_total_data: 0, weightedAverage: 0, currentTDD: 0, past2hoursAverage: 0, date: now,
            overridePercentage: 100, useOverride: false, duration: 0, unlimited: false, overrideTarget: 0,
            smbIsOff: smbIsOff, advancedSettings: false, isfAndCr: false, isf: false, cr: false,
            smbIsScheduledOff: false, start: 0, end: 0, smbMinutes: 30, uamMinutes: 30
        )
    }

    private func run(
        _ mode: BoostMode,
        smbIsOff: Bool = false,
        glucose: Decimal = 190,
        delta: Decimal = 6,
        boostMaxIOB: Decimal = 12
    ) throws -> Determination? {
        let readingTime = now.addingTimeInterval(-1800)
        let readings = [BloodGlucose(
            sgv: 120, date: Decimal(readingTime.timeIntervalSince1970 * 1000), dateString: readingTime, glucose: 120
        )]
        return try DeterminationGenerator.determineBasal(
            profile: profile(),
            preferences: preferences(mode, boostMaxIOB: boostMaxIOB),
            currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
            iobData: iob(0.2),
            mealData: ComputedCarbs(
                carbs: 0, mealCOB: 0, currentDeviation: 0, maxDeviation: 0, minDeviation: 0,
                slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0, allDeviations: [0, 0, 0, 0, 0], lastCarbTime: 0
            ),
            autosensData: Autosens(ratio: 1.0, newisf: nil),
            glucoseStatus: GlucoseStatus(
                delta: delta, glucose: glucose, noise: 0, shortAvgDelta: 4, longAvgDelta: 3, date: now,
                lastCalIndex: nil, device: "test"
            ),
            microBolusAllowed: true,
            trioCustomOrefVariables: variables(smbIsOff: smbIsOff),
            currentTime: now,
            boostV1Context: mode == .active ? .preview : nil,
            boostGlucose: readings
        )
    }

    @Test("Active mode runs the V1 engine and carries its telemetry") func activeRunsV1() throws {
        let det = try #require(try run(.active))
        let v1 = try #require(det.boostV1)
        #expect(det.reason.contains("Boost V1 tier \(v1.tier)"))
        // The engine's inputs: profile target midpoint, the 12 U default Boost max IOB reduced to max IOB 6
        // (at the old hidden 1.0 U every daytime SMB stopped once IOB reached 1 U), the LGS threshold, and
        // the 60-minute low from the one reading.
        #expect(v1.inputTargetBg == 125)
        #expect(v1.v6MaxIob == 6.0)
        #expect(v1.lgsThreshold == 70)
        #expect(v1.recentLowBg == 120)
    }

    @Test("The V1 tiers see the set Boost max IOB") func v1TiersSeeBoostMaxIob() throws {
        // IOB 0.2 U: at the default the UAM tier fires; a limit of 0.3 leaves it 0.1 U of headroom, and
        // a limit of 0.1, below IOB, locks every Boost tier out so the engine falls to enhanced oref1.
        let open = try #require(try run(.active))
        #expect(open.boostV1?.tier == "UAM_HIGH_BOOST")
        let clamped = try #require(try run(.active, boostMaxIOB: 0.3))
        #expect(clamped.boostV1?.tier == "UAM_HIGH_BOOST")
        #expect((clamped.units ?? 0) < (open.units ?? 0))
        let locked = try #require(try run(.active, boostMaxIOB: 0.1))
        #expect(locked.boostV1?.tier != "UAM_HIGH_BOOST")
        // The 12 U default survives a save and reload unchanged.
        let reloaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
        #expect(reloaded.boostMaxIOB == 12)
    }

    @Test("A set Boost max IOB is a lower limit; max IOB still caps it") func setBoostMaxIobIsALimit() throws {
        let lower = try #require(try run(.active, boostMaxIOB: 2)?.boostV1)
        #expect(lower.v6MaxIob == 2.0)
        let higher = try #require(try run(.active, boostMaxIOB: 10)?.boostV1)
        #expect(higher.v6MaxIob == 6.0)
        var prefs = Preferences()
        var profile = profile()
        #expect(BoostV1Determination.boostMaxIob(preferences: prefs, profile: profile) == 6.0)
        profile.maxIob = 9 // the default follows a change to max IOB on the next cycle
        #expect(BoostV1Determination.boostMaxIob(preferences: prefs, profile: profile) == 9.0)
        profile.maxIob = 15 // but no further than the setting's own 12 U maximum
        #expect(BoostV1Determination.boostMaxIob(preferences: prefs, profile: profile) == 12.0)
        prefs.boostMaxIOB = 3
        #expect(BoostV1Determination.boostMaxIob(preferences: prefs, profile: profile) == 3.0)
    }

    @Test("A file from before the 12 U default migrates once; a saved value survives") func boostMaxIobMigration() throws {
        func decode(_ json: String) throws -> Preferences {
            try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        }
        // The hidden setting was the factory 1.0 or an auto-config copy, never a choice.
        #expect(try decode(#"{"boostMaxIOB": 1.0}"#).boostMaxIOB == 12)
        #expect(try decode(#"{"boostMaxIOB": 8.0}"#).boostMaxIOB == 12)
        #expect(try decode(#"{"boostMaxIOB": 3.0, "boostMaxIOBMigrated": true}"#).boostMaxIOB == 3)
        #expect(try decode(#"{"boostMaxIOB": 30, "boostMaxIOBMigrated": true}"#).boostMaxIOB == 12)
        #expect(try decode(#"{"boostMaxIOB": 0, "boostMaxIOBMigrated": true}"#).boostMaxIOB == 0.1)
        var set = Preferences()
        set.boostMaxIOB = 4
        let roundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(set))
        #expect(roundTrip.boostMaxIOB == 4)
    }

    @Test("Shadow and off keep the stock determination") func stockPathUnchanged() throws {
        for mode in [BoostMode.off, .shadow] {
            let det = try #require(try run(mode))
            #expect(det.boostV1 == nil)
            #expect(!det.reason.contains("Boost V1"))
        }
    }

    @Test("The SMB-off lever stands in Boost") func smbOffLever() throws {
        let det = try #require(try run(.active, smbIsOff: true))
        #expect(det.units == nil)
        #expect(det.reason.contains("SMB off (user lever)"))
    }

    @Test("No reading in the last hour gives AAPS's 999") func recentLowDefault() {
        #expect(BoostV1Determination.recentLowBg60Min([], now: now) == 999)
    }

    @Test("The loop's SMB interval check has no slack, as in AAPS LoopPlugin") func smbFrequency() {
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        // 4 min 59 s since the last bolus with a 5-minute interval: V1's own check (6 s slack)
        // would dose; the loop check withholds it.
        #expect(BoostV1Determination.smbFrequencyExceeded(
            lastBolusTimeMs: nowMs - 299_000, now: now, smbIntervalMin: 5
        ))
        // At exactly the interval AAPS allows it (last + interval > now is false).
        #expect(!BoostV1Determination.smbFrequencyExceeded(
            lastBolusTimeMs: nowMs - 300_000, now: now, smbIntervalMin: 5
        ))
        #expect(!BoostV1Determination.smbFrequencyExceeded(
            lastBolusTimeMs: nowMs - 301_000, now: now, smbIntervalMin: 5
        ))
        // No bolus on record never blocks.
        #expect(!BoostV1Determination.smbFrequencyExceeded(lastBolusTimeMs: 0, now: now, smbIntervalMin: 5))
        #expect(!BoostV1Determination.smbFrequencyExceeded(lastBolusTimeMs: nil, now: now, smbIntervalMin: 5))
    }

    @Test("Insulin peak as AAPS coerces it") func insulinPeak() {
        var prefs = Preferences()
        var p = Profile()
        p.curve = .ultraRapid
        prefs.useCustomPeakTime = true
        p.insulinPeakTime = 38
        #expect(BoostV1Determination.insulinPeakMinutes(profile: p, preferences: prefs) == 38)
        p.insulinPeakTime = 20
        #expect(BoostV1Determination.insulinPeakMinutes(profile: p, preferences: prefs) == 30)
        prefs.useCustomPeakTime = false
        #expect(BoostV1Determination.insulinPeakMinutes(profile: p, preferences: prefs) == 55)
        p.curve = .rapidActing
        #expect(BoostV1Determination.insulinPeakMinutes(profile: p, preferences: prefs) == 75)
    }

    @Test("Trial day index is the local calendar day") func localDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        // 2026-10-14 23:30 BST is 22:30 UTC, still 14 October locally: day 20,740.
        let t = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 30)))
        #expect(BoostV1Determination.localDayIndex(t, calendar: cal) == 20740)
        // 2026-10-15 00:30 BST is 23:30 UTC on the 14th; locally it is the 15th.
        let u = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 0, minute: 30)))
        #expect(BoostV1Determination.localDayIndex(u, calendar: cal) == 20741)
    }
}

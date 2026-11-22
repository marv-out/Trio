import Foundation
import Testing
@testable import Trio

/// Boost sensitivity with TDD-based ISF off (AAPS 3d9d471dbb, f393d02e55, 1c6358ac6c), through the
/// Trio glue rather than the pure core: the oref autosens ratio divides the ISF at target, BG impact
/// on ISF is 0, and the selected ratio that drives basal and the target shift is the oref one only
/// when autosens owns sensitivity. Field case from AAPS: ratio 1.30 on an ISF of 68.4 gives 52.6.
@Suite("BoostISFAutosensTests") struct BoostISFAutosensTests {
    private func prefs(useTdd: Bool = false, autosensWhenNoTdd: Bool = true) -> Preferences {
        var p = Preferences()
        p.boostUseTdd = useTdd
        p.boostAutosensWhenNoTdd = autosensWhenNoTdd
        p.boostDynIsfVelocity = 100
        p.boostEnableCircadianIsf = false
        return p
    }

    private func context(_ ratio: Decimal, tempTarget: Decimal? = nil, profile: Profile = Profile()) -> BoostISF.AutosensContext {
        .make(
            orefRatio: ratio,
            isTempTarget: tempTarget != nil,
            targetBg: tempTarget ?? 100,
            profile: profile,
            preferences: prefs()
        )
    }

    private func sensNT(_ p: Preferences, _ ctx: BoostISF.AutosensContext) -> Double {
        BoostISF.sensNormalTarget(
            profileSens: 68.4, tdd: 0, profilePercent: 100, autosens: ctx, profile: Profile(), preferences: p
        )
    }

    private func adjusted(_ p: Preferences, _ ctx: BoostISF.AutosensContext, bg: Decimal) -> Decimal {
        BoostISF.adjustedSensitivity(
            profileSens: 68.4, currentGlucose: bg, tdd: 0, profilePercent: 100, hourOfDay: 12,
            autosens: ctx, profile: Profile(), preferences: p
        )
    }

    @Test("resistant autosens strengthens the ISF at target when TDD is off") func resistant() {
        #expect(sensNT(prefs(), context(1.3)) == 52.6)
    }

    @Test("dosing ISF is flat across BG with TDD off, and carries autosens") func flatAcrossBg() {
        #expect(adjusted(prefs(), context(1.3), bg: 100) == 52.6)
        #expect(adjusted(prefs(), context(1.3), bg: 250) == 52.6)
    }

    @Test("switch off leaves the profile ISF") func switchOff() {
        #expect(sensNT(prefs(autosensWhenNoTdd: false), context(1.3)) == 68.4)
    }

    @Test("TDD on owns sensitivity and keeps the BG curve") func tddOn() {
        let p = prefs(useTdd: true)
        // No TDD available, so the profile ISF stands, and autosens is not applied.
        #expect(sensNT(p, context(1.3)) == 68.4)
        // BG impact is live with TDD on: at 250 the curve strengthens ISF below the target value.
        #expect(adjusted(p, context(1.3), bg: 250) < 68.4)
    }

    @Test("a temp target with its own ratio replaces autosens") func tempTarget() {
        var profile = Profile()
        profile.lowTemptargetLowersSensitivity = true
        #expect(sensNT(prefs(), context(1.3, tempTarget: 80, profile: profile)) == 68.4)
        // A temp target that sets no ratio does not block autosens.
        #expect(sensNT(prefs(), context(1.3, tempTarget: 80)) == 52.6)
    }

    @Test("selected ratio for basal and targets") func selectedRatio() {
        #expect(BoostISF.sensitivityRatio(autosens: context(1.3), preferences: prefs()) == Decimal(string: "1.3"))
        #expect(BoostISF.sensitivityRatio(autosens: context(1.3), preferences: prefs(useTdd: true)) == 1)
        #expect(BoostISF.sensitivityRatio(autosens: context(1.3), preferences: prefs(autosensWhenNoTdd: false)) == 1)
        #expect(BoostISF.sensitivityRatio(autosens: .neutral, preferences: prefs()) == 1)
    }
}

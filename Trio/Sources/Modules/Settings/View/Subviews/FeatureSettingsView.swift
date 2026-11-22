//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Trio Features"),
                content: {
                    Text("Treatments").navigationLink(to: .treatmentsSettings, from: self)
                    Text("Shortcuts").navigationLink(to: .shortcutsConfig, from: self)
                    Text("Remote Control").navigationLink(to: .remoteControlConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Trio Personalization"),
                content: {
                    Text("User Interface").navigationLink(to: .userInterfaceSettings, from: self)
                    Text("App Icons").navigationLink(to: .iconConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Anonymized Data Sharing"),
                content: {
                    Text("App Diagnostics").navigationLink(to: .appDiagnostics, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Boost (V6)"),
                footer: Text(
                    "Off: stock Trio only. Shadow: runs the Boost V6 engine and logs what it would dose (in the determination reason) without changing dosing. Active: Boost V6 drives the SMB."
                ),
                content: {
                    Picker("Boost Mode", selection: $state.boostMode) {
                        ForEach(BoostMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            )
            .listRowBackground(Color.chart)

            if state.boostMode != .off {
                // Essentials at top level — mirrors the AAPS Boost V6 screen. Everything else is
                // auto-configured/learned and lives under "Advanced Boost Settings" below.
                Section(header: Text("Boost V6 Tuning")) {
                    BoostSliderRow(
                        title: "Aggression", info: BoostSettingInfo.aggression,
                        value: $state.boostV5Aggression, range: 0.7 ... 1.6, step: 0.05
                    )
                    BoostSliderRow(
                        title: "Hypo Caution", info: BoostSettingInfo.hypoCaution,
                        value: $state.boostV5HypoCaution, range: 1.0 ... 2.0, step: 0.05
                    )
                    BoostSliderRow(
                        title: "Boost max IOB (U)", info: BoostSettingInfo.boostMaxIob,
                        value: $state.boostMaxIOB, range: 0.1 ... 12, step: 0.1
                    )
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Night Mode"),
                    footer: Text("Timing and gating options are under Advanced.")
                ) {
                    BoostToggleRow(
                        title: "Enabled", info: BoostSettingInfo.nightModeEnabled,
                        isOn: $state.boostNightModeEnabled
                    )
                    if state.boostNightModeEnabled {
                        BoostGlucoseSliderRow(
                            title: "BG offset", info: BoostSettingInfo.nightModeBgOffset,
                            valueMgdl: $state.boostNightModeBgOffset, rangeMgdl: 0 ... 90, units: state.units
                        )
                    }
                }
                .listRowBackground(Color.chart)

                Section {
                    // A view of its own that observes the state model: a destination built inline
                    // here is not redrawn when the model changes, so its sliders moved without the
                    // values beside them updating.
                    NavigationLink(destination: BoostAdvancedSettingsView(state: state)) {
                        Text("Advanced Boost Settings")
                    }
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Feature Settings")
        .navigationBarTitleDisplayMode(.automatic)
        // Wire the StateModel to the resolver so subscribe() runs and the Boost setting
        // bindings persist to preferences. Without this, edits (e.g. Boost Mode) update the
        // in-memory @Published values but are never written back, so they revert on navigation.
        .onAppear(perform: configureView)
    }
}

/// Advanced Boost settings, pushed from Feature Settings. Mirrors the AAPS V6 "Advanced" sub-screen:
/// the advanced dosing settings and the engine settings grouped by function.
private struct BoostAdvancedSettingsView: View {
    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @State private var showAutoConfig = false

    var body: some View {
        Form {
            Section(
                header: Text("Auto-config"),
                footer: Text(BoostSettingInfo.runAutoConfig)
            ) {
                Button("Run auto-config now") { showAutoConfig = true }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Dosing (advanced)")) {
                BoostSliderRow(
                    title: "Sensitivity", info: BoostSettingInfo.sensitivity,
                    value: $state.boostV5Sensitivity, range: 0.8 ... 1.2, step: 0.05
                )
                BoostSliderRow(
                    title: "Confirmed cap (U)", info: BoostSettingInfo.confirmedCap,
                    value: $state.boostV5ConfirmedCapU, range: 0 ... 7.5, step: 0.05,
                    onUserEdit: state.markBoostV5ConfirmedCapUserSet
                )
                BoostSliderRow(
                    title: "Committed cap (U)", info: BoostSettingInfo.committedCap,
                    value: $state.boostV5CommittedCapU, range: 0 ... 5.0, step: 0.05,
                    onUserEdit: state.markBoostV5CommittedCapUserSet
                )
                BoostSliderRow(
                    title: "Cumulative SMB cap / 60 min (U)", info: BoostSettingInfo.cumulativeCap,
                    value: $state.boostCumulativeSmbCap60Min, range: 0 ... 10, step: 0.1, decimals: 2,
                    onUserEdit: state.markBoostCumulativeSmbCap60MinUserSet
                )
                BoostToggleRow(
                    title: "Fast-carb confirm", info: BoostSettingInfo.fastCarbConfirm,
                    isOn: $state.boostV5FastCarbConfirm
                )
                BoostToggleRow(
                    title: "Phase-3 composed brake floor", info: BoostSettingInfo.composedFloor,
                    isOn: $state.boostV5ComposedFloorActive
                )
                BoostToggleRow(
                    title: "Confirm sooner", info: BoostSettingInfo.aggressiveEarlyConfirm,
                    isOn: $state.boostV5AggressiveEarlyConfirm
                )
                BoostToggleRow(
                    title: "Velocity-budget floor", info: BoostSettingInfo.velocityBudget,
                    isOn: $state.boostV5VelocityBudgetActive
                )
                BoostSliderRow(
                    title: "Early primer ceiling (U)", info: BoostSettingInfo.primerCap,
                    value: $state.boostV5PrimerCapU, range: 0 ... 2.5, step: 0.05
                )
                BoostToggleRow(
                    title: "Force primer as bolus", info: BoostSettingInfo.primerBolusMode,
                    isOn: $state.boostV5PrimerBolusMode
                )
                BoostToggleRow(
                    title: "Confirm tranche", info: BoostSettingInfo.confirmTranche,
                    isOn: $state.boostV5ConfirmTranche
                )
                BoostSliderRow(
                    title: "Tranche immediate fraction", info: BoostSettingInfo.trancheFraction,
                    value: $state.boostV5TrancheFraction, range: 0 ... 1, step: 0.05
                )
                BoostSliderRow(
                    title: "Tranche release threshold", info: BoostSettingInfo.trancheThreshold,
                    value: $state.boostV5TrancheThreshold, range: 0 ... 1, step: 0.01
                )
                BoostToggleRow(
                    title: "Post-rescue tight-ramp trial", info: BoostSettingInfo.postRescueTrial,
                    isOn: $state.boostV5PostRescueTightRampTrial
                )
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Boost Dynamic ISF"),
                footer: Text("Applies only in Active mode.")
            ) {
                BoostToggleRow(title: "Use TDD", info: BoostSettingInfo.useTdd, isOn: $state.boostUseTdd)
                if !state.boostUseTdd {
                    BoostToggleRow(
                        title: "Autosens without TDD", info: BoostSettingInfo.autosensWhenNoTdd,
                        isOn: $state.boostAutosensWhenNoTdd
                    )
                }
                BoostToggleRow(
                    title: "Circadian ISF", info: BoostSettingInfo.circadianIsf,
                    isOn: $state.boostEnableCircadianIsf
                )
                BoostGlucoseSliderRow(
                    title: "Normal target", info: BoostSettingInfo.normalTarget,
                    valueMgdl: $state.boostDynIsfNormalTarget, rangeMgdl: 70 ... 120, units: state.units
                )
                BoostGlucoseSliderRow(
                    title: "BG cap", info: BoostSettingInfo.bgCap,
                    valueMgdl: $state.boostDynIsfBgCap, rangeMgdl: 100 ... 300, units: state.units
                )
                if state.boostUseTdd {
                    BoostSliderRow(
                        title: "Velocity %", info: BoostSettingInfo.velocity,
                        value: $state.boostDynIsfVelocity, range: 0 ... 100, step: 5
                    )
                }
                BoostSliderRow(
                    title: "Adjustment factor %", info: BoostSettingInfo.adjustmentFactor,
                    value: $state.boostDynIsfAdjustmentFactor, range: 1 ... 300, step: 1
                )
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Boost Night Mode — timing & gating"),
                footer: Text("Enable and BG offset are on the main screen.")
            ) {
                BoostSliderRow(
                    title: "Start hour", info: BoostSettingInfo.nightStart,
                    value: $state.boostNightModeStartHour, range: 0 ... 23, step: 1
                )
                BoostSliderRow(
                    title: "End hour", info: BoostSettingInfo.nightEnd,
                    value: $state.boostNightModeEndHour, range: 0 ... 23, step: 1
                )
                BoostToggleRow(
                    title: "Disable with COB", info: BoostSettingInfo.disableWithCob,
                    isOn: $state.boostNightModeDisableWithCob
                )
                BoostToggleRow(
                    title: "Disable with low TT", info: BoostSettingInfo.disableWithLowTt,
                    isOn: $state.boostNightModeDisableWithLowTt
                )
                BoostToggleRow(
                    title: "Auto by sleep", info: BoostSettingInfo.autoBySleep,
                    isOn: $state.boostNightModeAutoBySleep
                )
                BoostSliderRow(
                    title: "Sleep-in hours", info: BoostSettingInfo.sleepInHours,
                    value: $state.boostSleepInHours, range: 0 ... 18, step: 0.5
                )
                BoostSliderRow(
                    title: "Sleep-in steps (60m)", info: BoostSettingInfo.sleepInSteps,
                    value: $state.boostSleepInSteps, range: 0 ... 1000, step: 50
                )
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Boost V6 Pre-Meal")) {
                BoostToggleRow(title: "Enabled", info: BoostSettingInfo.preMeal, isOn: $state.boostV6PreMealEnabled)
                if state.boostV6PreMealEnabled {
                    BoostGlucoseSliderRow(
                        title: "Pre-meal target", info: BoostSettingInfo.preMealTarget,
                        valueMgdl: $state.boostV6PreMealTargetMgdl, rangeMgdl: 65 ... 90, units: state.units
                    )
                    BoostSliderRow(
                        title: "Lead time (min)", info: BoostSettingInfo.preMealLead,
                        value: $state.boostV6PreMealLeadMin, range: 30 ... 90, step: 5
                    )
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Boost Exercise — Steps")) {
                BoostSliderRow(
                    title: "Active steps / 5 min", info: BoostSettingInfo.activitySteps(5, 420),
                    value: $state.boostActivitySteps5, range: 0 ... 2000, step: 10
                )
                BoostSliderRow(
                    title: "Active steps / 15 min", info: BoostSettingInfo.activitySteps(15, 800),
                    value: $state.boostActivitySteps15, range: 0 ... 4000, step: 25
                )
                BoostSliderRow(
                    title: "Active steps / 30 min", info: BoostSettingInfo.activitySteps(30, 1200),
                    value: $state.boostActivitySteps30, range: 0 ... 6000, step: 50
                )
                BoostSliderRow(
                    title: "Active steps / 60 min", info: BoostSettingInfo.activitySteps(60, 1800),
                    value: $state.boostActivitySteps60, range: 0 ... 10000, step: 50
                )
                BoostSliderRow(
                    title: "Activity profile %", info: BoostSettingInfo.activityPct,
                    value: $state.boostActivityPct, range: 30 ... 150, step: 5
                )
                BoostSliderRow(
                    title: "Inactive steps / 60 min", info: BoostSettingInfo.inactivitySteps,
                    value: $state.boostInactivitySteps, range: 0 ... 1000, step: 25
                )
                BoostSliderRow(
                    title: "Inactivity profile %", info: BoostSettingInfo.inactivityPct,
                    value: $state.boostInactivityPct, range: 100 ... 200, step: 5
                )
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Boost Exercise — Heart Rate")) {
                BoostToggleRow(
                    title: "HR integration", info: BoostSettingInfo.hrIntegration,
                    isOn: $state.boostHrIntegrationEnabled
                )
                if state.boostHrIntegrationEnabled {
                    BoostSliderRow(
                        title: "Max HR (bpm)", info: BoostSettingInfo.hrMax,
                        value: $state.boostHrMaxBpm, range: 150 ... 220, step: 1
                    )
                    BoostSliderRow(
                        title: "Resting HR (bpm)", info: BoostSettingInfo.hrResting,
                        value: $state.boostHrRestingBpm, range: 30 ... 100, step: 1
                    )
                    BoostToggleRow(
                        title: "Stress detection", info: BoostSettingInfo.hrStress,
                        isOn: $state.boostHrStressDetection
                    )
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Boost Post-Exercise")) {
                BoostToggleRow(
                    title: "Enabled", info: BoostSettingInfo.postExercise,
                    isOn: $state.boostPostExerciseEnabled
                )
                if state.boostPostExerciseEnabled {
                    BoostSliderRow(
                        title: "Recovery window (h)", info: BoostSettingInfo.postExerciseHours,
                        value: $state.boostPostExerciseHours, range: 0.5 ... 8, step: 0.5
                    )
                    BoostGlucoseSliderRow(
                        title: "Recovery target", info: BoostSettingInfo.postExerciseTarget,
                        valueMgdl: $state.boostPostExerciseTarget, rangeMgdl: 90 ... 200, units: state.units
                    )
                    BoostSliderRow(
                        title: "SMB scale", info: BoostSettingInfo.postExerciseScale,
                        value: $state.boostPostExerciseScale, range: 0 ... 1, step: 0.05
                    )
                    BoostSliderRow(
                        title: "Min duration (min)", info: BoostSettingInfo.postExerciseMinDuration,
                        value: $state.boostPostExerciseMinDuration, range: 1 ... 120, step: 1
                    )
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Advanced Boost")
        .navigationBarTitleDisplayMode(.automatic)
        .sheet(isPresented: $showAutoConfig) {
            BoostAutoConfigRunView(state: state)
        }
    }
}

/// The run-now dialog. The override is off each time the dialog opens and applies to that run only.
private struct BoostAutoConfigRunView: View {
    @ObservedObject var state: Settings.StateModel

    @Environment(\.dismiss) private var dismiss
    @State private var overrideHypoProtections = false
    @State private var running = false
    @State private var result: [String]?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(BoostSettingInfo.runAutoConfig)) {
                    BoostToggleRow(
                        title: "Override hypo protections", info: BoostSettingInfo.overrideHypoProtections,
                        isOn: $overrideHypoProtections
                    )
                    .disabled(running)
                    Button(running ? "Running…" : "Run auto-config") {
                        running = true
                        Task {
                            result = await state.runBoostAutoConfigNow(overrideHypoProtections: overrideHypoProtections)
                            running = false
                        }
                    }
                    .disabled(running)
                }
                if let result {
                    Section(header: Text("Result")) {
                        ForEach(Array(result.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Auto-config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

/// A setting row in the AAPS Boost pattern: title and value, the setting's description under the
/// title, then the control.
private struct BoostSliderRow: View {
    let title: String
    let info: String
    @Binding var value: Decimal
    let range: ClosedRange<Double>
    let step: Double
    /// Decimals shown; by default from the step. The cumulative cap is written by auto-config to 0.01 U.
    var decimals: Int?
    var onUserEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.\(decimals ?? (step >= 1 ? 0 : step >= 0.1 ? 1 : 2))f", value.doubleValue))
                    .foregroundStyle(.secondary)
            }
            BoostInfoText(info)
            Slider(
                value: Binding(get: { value.doubleValue }, set: { value = Decimal($0) }),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    // Fires only on genuine user interaction (drag start/end), never programmatically —
                    // the right place to flag a knob as user-set. Mark on release.
                    if !editing { onUserEdit?() }
                }
            )
        }
    }
}

/// Glucose-valued slider: stored in mg/dL, displayed and adjusted in the user's units.
private struct BoostGlucoseSliderRow: View {
    let title: String
    let info: String
    @Binding var valueMgdl: Decimal
    let rangeMgdl: ClosedRange<Double>
    let units: GlucoseUnits

    var body: some View {
        let mmol = units == .mmolL
        let range: ClosedRange<Double> = mmol
            ? Decimal(rangeMgdl.lowerBound).asMmolL.doubleValue ... Decimal(rangeMgdl.upperBound).asMmolL.doubleValue
            : rangeMgdl
        let shown = mmol
            ? String(format: "%.1f mmol/L", valueMgdl.asMmolL.doubleValue)
            : String(format: "%.0f mg/dL", valueMgdl.doubleValue)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(shown).foregroundStyle(.secondary)
            }
            BoostInfoText(info)
            Slider(
                value: Binding(
                    get: { mmol ? valueMgdl.asMmolL.doubleValue : valueMgdl.doubleValue },
                    set: { valueMgdl = mmol ? Decimal($0).asMgdL : Decimal($0) }
                ),
                in: range,
                step: mmol ? 0.1 : 1
            )
        }
    }
}

private struct BoostToggleRow: View {
    let title: String
    let info: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
            BoostInfoText(info)
        }
    }
}

private struct BoostInfoText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
}

/// Descriptions of the Boost settings. Taken from the AAPS Boost 6.3.2 preference summaries
/// (core/keys strings.xml, `pref_summary_boost_*`), with Android-specific sources (Health Connect,
/// Wear OS) replaced by Apple Health and times given in hours, as Trio sets them.
private enum BoostSettingInfo {
    static let aggression =
        "Scales the catch-up dose at meal CONFIRMED. 1.0 = calibrated default; lower = gentler commit dose, higher = more aggressive. Range 0.7-1.6."
    static let hypoCaution =
        "Multiplier on the ML hypo-risk damper floor. 1.0 = default; raise toward 2.0 for hypo unawareness or after a recent severe hypo. Range 1.0-2.0."
    static let nightModeEnabled =
        "Disable SMBs during night hours when BG is near target. Active mode only."
    static let nightModeBgOffset =
        "SMBs are disabled when BG is below the profile target plus this offset. This gates night mode; it does not raise the target. Default: 1.5 mmol/L (27 mg/dL)"
    static let runAutoConfig =
        "Auto-config re-derives the dose caps, aggression and hypo caution from the last 28 days of your own history. It runs by itself every 7 days; this runs it now and shows what it did. It needs Boost Active, first set-up finished, and 24 hours since the last run. A raise is held back while time below 70 mg/dL is over 4.0% or time below 54 mg/dL is 1.0% or more."
    static let overrideHypoProtections =
        "Lets this one run raise the dose caps and aggression, lower hypo caution, and switch on Confirm sooner and Fast-carb confirm even though your time below 70 or 54 mg/dL is over the limit that normally holds them back. Lowerings still apply, and every value stays inside its own limits. The automatic runs keep the protections."
    static let boostMaxIob =
        "The most insulin on board at which Boost may still add an SMB. Boost uses this or your max IOB, whichever is lower, so at the default of 12 U it uses your max IOB and follows it when it changes. Set a lower value to hold Boost below max IOB. Default: 12 U. Range 0.1–12 U."
    static let sensitivity =
        "Scales the per-cycle insulin (aggression) budget. 1.0 = default; below 1.0 for sensitive users, above for resistant. Range 0.8–1.2."
    static let confirmedCap = "Hard upper limit on the confirmed meal SMB. Default: 2.5 U"
    static let committedCap =
        "Hard upper limit on the per-cycle committed meal SMB, up to 5.0 U. Auto-config sets it from your history and goes above 2.5 U only when your daily dose is above about 100 U or a quarter or more of your SMBs are above 2.5 U. Default: 0.5 U"
    static let cumulativeCap =
        "Total SMB insulin (U) that may be delivered in any rolling 60-minute window. Caps insulin stacking during sustained climbs. Set to 0 to disable. Factory default: 10 U (non-binding); auto-configuration tightens it to your own history (Confirmed cap + 2× Committed cap)."
    static let fastCarbConfirm =
        "When a rise is sharp AND accelerating AND the meal score corroborates (and you're awake, not exercising), Boost confirms the meal in one cycle instead of waiting — so fast carbs get covered ~15 min earlier. Replay-validated to avoid firing on sleep/compression. Toggle off to revert to the standard observe-confirm timing."
    static let composedFloor =
        "Enforces a 25% floor on the composed soft-brake multiplier during active meal sessions above 160 mg/dL with eventualBG above target — fixes the soft-brake stack compounding to sub-pump-step zero doses mid-meal. All hard gates and dose caps still apply. Default OFF. The floor engages ONLY while BOTH your trailing 14-day time below 63 mg/dL is under 2.0% AND your time below 70 mg/dL is under 3.5%; it is insulin-adding, so it stays suppressed (even when this is ON) if either figure is higher."
    static let aggressiveEarlyConfirm =
        "Confirms a meal one cycle sooner still when its signal is confirm-strength on two consecutive cycles — the same shot, delivered a touch earlier. Because it occasionally commits to a rise that would have faded, it adds a little insulin, so it is set automatically only for users whose recent low-glucose exposure is well within target. Default OFF; auto-config turns it on where it is safe."
    static let velocityBudget =
        "When you are above 180 mg/dL but oref calculates no extra insulin is needed, this delivers a small hold — up to 0.5 U, capped at your committed cap and your IOB headroom — to bring highs down a little faster. Excludes decelerating highs, sleep, and the post-rescue window; all hard hypo gates still apply. Default OFF. Uses the same hypo gate as the brake floor (14-day time below 63 mg/dL under 2.0% and below 70 mg/dL under 3.5%)."
    static let primerCap =
        "Fizzle-safe early primer delivered on a sustained rise during OBSERVING — gives an earlier meal response. Additive up to this base; any velocity-scaled excess is netted off the CONFIRMED commit-shot (move, not add). 0 = OFF. Auto-config derives a per-user value."
    static let primerBolusMode =
        "Off: auto-config chooses how the early primer is delivered, as a temp basal that can be withdrawn if the rise fades for people with more time below range, otherwise as a bolus. On: always a bolus. Floors and the commit-shot net-off are unaffected. Default OFF."
    static let confirmTranche =
        "Experimental, off by default. Splits the confirm commitment, giving part at the confirming cycle and holding the rest for ten minutes, released only if the rise continues. Can only deliver less insulin than without it, never more."
    static let trancheFraction =
        "Share of the sized confirm dose delivered at the confirming cycle. The remainder is held. Set to 1.0 to make the tranche inert without switching it off."
    static let trancheThreshold =
        "The remainder is released when the rule's probability exceeds this. Higher withholds more. A value you set here yourself is kept; set it back to 0.48 to hand it back to auto-config."
    static let postRescueTrial =
        "Within-user trial. On randomised treatment days the post-rescue rebound guard is capped at 60% and applies across the whole window instead of switching off above 170 mg/dL. Neither arm can deliver more insulin than the current behaviour. Leave OFF unless you are enrolled."
    static let useTdd =
        "Calculate ISF from Total Daily Dose using the logarithmic formula. When disabled, uses profile ISF directly, and Velocity is set to 0 (switching this back on sets it to 100)."
    static let autosensWhenNoTdd =
        "When TDD-based ISF is off, let Autosens adjust ISF, basal, target and carb absorption. When this is off as well, no sensitivity adjustment is applied. No effect when TDD-based ISF is on, since TDD owns sensitivity then."
    static let circadianIsf = "Applies time-of-day ISF adjustment based on circadian rhythm model"
    static let normalTarget = "Reference BG target for ISF calculation. Default: 99 mg/dL"
    static let bgCap = "BG above this value is softened to reduce ISF aggressiveness at very high BG. Default: 210 mg/dL"
    static let velocity =
        "Controls how much your current blood glucose level affects ISF. At 100%, ISF is fully adjusted by BG (higher BG = stronger ISF). At 50%, only half the BG-driven adjustment is applied. At 0%, BG has no effect and ISF stays at the target-level value regardless of current BG. Default: 100"
    static let adjustmentFactor = "Scale the calculated TDD by this percentage. Default: 100"
    static let nightStart = "Start of the Night Mode window (hour, 24h). Default: 22"
    static let nightEnd =
        "End of the Night Mode window (hour, 24h), in the phone's time zone. Night mode can continue after this for up to Sleep-in Hours while the step count stays low. Default: 7"
    static let disableWithCob = "Allow SMBs during Night Mode if carbs are on board"
    static let disableWithLowTt = "Allow SMBs during Night Mode when temp target is below profile target"
    static let autoBySleep =
        "When ON, sleep state (heart rate + steps from Apple Health) drives Night Mode in addition to the time window. Engages early (PRE_SLEEP) 60 minutes before the start hour to limit IOB before bed; stays active past the end hour while still sleeping. Wake requires BOTH HR rise and step activity (BG trend alone does not wake). Needs a heart-rate source such as a watch."
    static let sleepInHours =
        "How long night mode can stay on after the Night Mode end hour while you are still in bed. Night mode ends early once the step count in the last hour reaches Sleep-in Steps, so with an end of 07:00 and 2 hours here it can run until 09:00 if no walking is recorded. Set to 0 for night mode to end at the end hour. Default: 2"
    static let sleepInSteps =
        "Steps in the last hour below which you are treated as still in bed after the Night Mode end hour, keeping night mode on for up to Sleep-in Hours. Default: 250"
    static let preMeal =
        "Experimental: learns your habitual meal times (from Boost meal commits) and applies a low target shortly before a learned meal so insulin is working when carbs land. Exercise and post-exercise recovery override it."
    static let preMealTarget =
        "The low target applied during the pre-meal window. Lower = more pre-emptive insulin. Default: 72 mg/dL (4.0 mmol/L)."
    static let preMealLead =
        "How many minutes before a learned meal the low target window OPENS. It closes 45 min before the meal. Default: 60 min."
    static func activitySteps(_ minutes: Int, _ defaultSteps: Int) -> String {
        "Steps in \(minutes) min above which user is active. Default: \(defaultSteps)"
    }

    static let activityPct = "Profile percentage when active. Default: 80"
    static let inactivitySteps = "Steps/hour below which user is inactive. Default: 500"
    static let inactivityPct = "Profile percentage when inactive. Default: 130"
    static let hrIntegration =
        "Use heart rate data to classify exercise type (aerobic vs resistance) and confirm step-count signals. Needs heart rate in Apple Health, for example from a watch. Falls back to step-only detection if no recent HR data is available."
    static let hrMax =
        "Your maximum heart rate in BPM used for Karvonen zone calculation. Standard estimate: 220 minus age. Default 180 bpm is conservative for adults when age is unknown. Range 150–220."
    static let hrResting =
        "Your resting heart rate in BPM used for Karvonen Heart Rate Reserve method. Measure on waking before getting up. Default 60 bpm. Range 30–100."
    static let hrStress =
        "Detect elevated HR without movement as possible stress or illness. Reduces insulin aggressiveness (raises target) when HR is in zone 2+ but steps are very low. Disable if you experience false positives."
    static let postExercise =
        "After exercise, reduces Boost's bolus cap and Boost scale for a recovery window, to guard against delayed hypoglycaemia. Trio does not set a temp target for it. Active mode only."
    static let postExerciseHours =
        "How long the reduction remains active after exercise ends. Evidence supports 1–4 h; default 2 h covers the primary risk window (Riddell et al.)"
    static let postExerciseTarget =
        "Not used by Trio yet. AAPS sets this as a temp target during the recovery window; Trio does not create one, so set a temp target yourself if you want one. Default 8.0 mmol/L / 144 mg/dL"
    static let postExerciseScale =
        "Multiplier (0.0–1.0) applied to the Boost bolus cap and Boost scale during the recovery window. 0.5 = 50% reduction."
    static let postExerciseMinDuration =
        "Recovery only triggers if exercise was detected for at least this many minutes. Avoids false triggers from brief activity bursts. Default: 10 min."
}

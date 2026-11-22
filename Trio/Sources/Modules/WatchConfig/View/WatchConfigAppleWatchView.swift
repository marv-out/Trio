import SwiftUI
import Swinject

struct WatchConfigAppleWatchView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: WatchConfig.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView?
    @State var hintLabel: String?
    @State private var decimalPlaceholder: Decimal = 0.0
    @State private var booleanPlaceholder: Bool = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private func onDelete(offsets: IndexSet) {
        state.devices.remove(atOffsets: offsets)
        state.deleteGarminDevice()
    }

    @ViewBuilder private var watchStatusRows: some View {
        if let status = state.watchStatus {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last contact")
                    Spacer()
                    Text(status.receivedAt, style: .time).foregroundStyle(.secondary)
                }
                if let trigger = status.trigger {
                    HStack {
                        Text("Last sent on")
                        Spacer()
                        Text(Self.triggerDescription(trigger)).foregroundStyle(.secondary)
                    }
                }
                if status.preciseMode {
                    HStack {
                        Text("Live session")
                        Spacer()
                        Text(status.liveSessionRunning ? "running" : "not running")
                            .foregroundStyle(status.liveSessionRunning ? Color.secondary : Color.orange)
                    }
                }
                HStack {
                    Text("Motion & Fitness access")
                    Spacer()
                    Text(status.motionAuthorization)
                        .foregroundStyle(status.motionAuthorization == "authorized" ? Color.secondary : Color.orange)
                }
                if let stepSource = status.stepSource {
                    HStack {
                        Text("Step source")
                        Spacer()
                        switch stepSource {
                        case "motion": Text("Motion sensor (live)").foregroundStyle(.secondary)
                        case "healthKit": Text("Watch Health data (delayed)").foregroundStyle(.orange)
                        default: Text(stepSource).foregroundStyle(.secondary)
                        }
                    }
                }
                if let stepError = status.stepError {
                    Text("Step error: \(stepError)").foregroundStyle(.red)
                }
                if let liveSessionError = status.liveSessionError {
                    Text(liveSessionError).foregroundStyle(.orange)
                }
            }
            .font(.footnote)
        } else {
            Text("No status from the watch yet").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static func triggerDescription(_ trigger: String) -> String {
        switch trigger {
        case "sensorWake": return String(localized: "Sensor wake")
        case "backgroundRefresh": return String(localized: "Background refresh")
        case "appActive": return String(localized: "Watch app opened")
        case "heartRate": return String(localized: "New heart rate")
        case "live": return String(localized: "Live session")
        case "settings": return String(localized: "Settings change")
        default: return trigger
        }
    }

    private func stepRow(_ label: LocalizedStringKey, _ steps: Int?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let steps {
                Text("\(steps)")
            } else {
                Text("--").foregroundStyle(.secondary)
            }
        }
    }

    /// Time of the newest value; marked when it is older than 5 minutes
    @ViewBuilder private func ageRow(_ date: Date?, now: Date) -> some View {
        HStack {
            Text("Updated").foregroundStyle(.secondary)
            Spacer()
            if let date {
                if state.isOutdated(date, now: now) {
                    Label {
                        Text(date, style: .time)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    Text("outdated").foregroundStyle(.orange)
                } else {
                    Text(date, style: .time).foregroundStyle(.secondary)
                }
            } else {
                Text("No data").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    var body: some View {
        List {
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.confirmBolusFaster,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Confirm Bolus Faster")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Confirm Bolus Faster"),
                miniHint: String(localized: "Reduce the number of crown rotations required for bolus confirmation."),
                verboseHint: Text(
                    "Enabling this feature lowers the number of turns on the crown dial required when confirming a bolus."
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Shows forecast on the Apple Watch"),
                verboseHint: Text(
                    "Enable this feature to show the forecast on the Apple Watch"
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.useCriticalAlertsWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Critical Alerts on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Critical Alerts on Watch"),
                miniHint: String(localized: "The watch’s urgent low alarm sounds through Silent Mode"),
                verboseHint: Text(
                    "When this is on, the urgent low alarm the watch raises for its own readings sounds even in Silent Mode. The watch asks for permission the first time."
                )
            )

            if state.cgmSharesWithWatch {
                Section(
                    header: Text("Glucose on the Watch"),
                    footer: Text(
                        String(
                            localized: "The watch reads the \(state.cgmName) itself while “Read on Apple Watch” is on in its settings. It shows the iPhone’s readings while they come, and its own, with a watch symbol in the glucose bubble, once they stop."
                        )
                    ),
                    content: {
                        HStack {
                            Text("Read on Apple Watch")
                            Spacer()
                            Text(state.watchReadsSensor ? "On" : "Off").foregroundStyle(.secondary)
                        }
                        NavigationLink(String(localized: "Change in the \(state.cgmName) Settings")) {
                            CGMSettings.RootView(
                                resolver: resolver,
                                displayClose: false,
                                bluetoothManager: resolver.resolve(BluetoothStateManager.self)!
                            )
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                ).listRowBackground(Color.chart)
            }

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.watchActivityEnabled,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Heart Rate and Steps from Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Heart Rate and Steps from Watch"),
                miniHint: String(
                    localized: "The Trio watch app sends heart rate and steps directly to Trio, also while the iPhone is locked."
                ),
                verboseHint: VStack(alignment: .leading, spacing: 10) {
                    Text("Default: OFF").bold()
                    Text(
                        "When enabled, the Trio watch app reads heart rate and steps on the Apple Watch and sends them directly to Trio on the iPhone. The data does not pass through the iPhone's Apple Health store, which cannot be read while the iPhone is locked."
                    )
                    Text(
                        "Steps are counted by the watch's motion sensors. Heart rate is read from the watch's own health data, so the watch asks for access once. The watch must be worn and unlocked."
                    )
                    Text(
                        "With \"Read on Apple Watch\" on for a G7, the sensor wakes the Trio watch app about every 5 minutes. Each time, the watch sends heart rate and steps. This needs no workout and little extra battery. Without it, the watch sends only when watchOS allows, often only every 15 minutes or more."
                    )
                    Text(
                        "Without a workout, the watch measures heart rate only now and then. The newest value can therefore be older than 5 minutes even though data arrives every 5 minutes."
                    )
                    Text(
                        "Values older than 5 minutes are marked as outdated. The data is kept for 24 hours. Turning this off deletes the stored data."
                    )
                    Text(
                        "When Boost is on, it reads steps and heart rate from here instead of Apple Health, so this data then changes insulin delivery. Boost ignores steps that are more than 10 minutes old or have gaps. Steps from the watch's Health data (delayed) are used to detect activity, but never to raise insulin for inactivity."
                    ).bold()
                    Text(
                        "This is not medical advice. Discuss how activity data is used for dosing with your care team."
                    )
                },
                headerText: String(localized: "Apple Watch Sensor Data")
            )

            if state.watchActivityEnabled {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.watchActivityPreciseMode,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Precise Mode (Workout)")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Precise Mode (Workout)"),
                    miniHint: String(localized: "Heart rate and steps every minute, at the cost of battery."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "The Trio watch app runs a workout session in the background. Only this keeps the app running and the heart rate sensor measuring continuously, so data is sent every minute. The workout is not saved."
                        )
                        Text(
                            "This uses noticeably more watch battery. The workout icon shows on the watch face. Starting a workout in another app ends Trio's session; open the Trio watch app or tap \"Start Live Session on Watch\" to restart it."
                        )
                    }
                )

                if !state.watchActivityPreciseMode, !state.watchReadsSensor {
                    Section {
                        Text(
                            "\"Read on Apple Watch\" is off, so the sensor does not wake the watch. Data arrives only when watchOS allows, often only every 15 minutes or more."
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }.listRowBackground(Color.chart)
                }

                Section(
                    header: Text("Received from Apple Watch"),
                    footer: Text(
                        "Values older than 5 minutes are outdated and are not live data. Step counts for 15, 30 and 60 minutes show \"--\" when data is outdated or minutes are missing. They end at the newest minute received, usually 1–2 minutes ago."
                    ),
                    content: {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(spacing: 8) {
                                HStack {
                                    Text("Heart Rate")
                                    Spacer()
                                    if let heartRate = state.latestHeartRate {
                                        Text("\(Int(heartRate.bpm.rounded())) bpm")
                                    } else {
                                        Text("No data").foregroundStyle(.secondary)
                                    }
                                }
                                ageRow(state.latestHeartRate?.date, now: context.date)
                                Divider()
                                // Shown only while the data is current and complete; "--" otherwise
                                let isOutdated = state.isOutdated(state.lastStepUpdate, now: context.date)
                                let recent: WatchRecentSteps? = isOutdated ? nil : state.recentSteps
                                stepRow("Steps (last 15 min)", recent?.last15Minutes)
                                stepRow("Steps (last 30 min)", recent?.last30Minutes)
                                stepRow("Steps (last 60 min)", recent?.last60Minutes)
                                HStack {
                                    Text("Steps (today)")
                                    Spacer()
                                    Text("\(state.stepsToday)")
                                }
                                ageRow(state.lastStepUpdate, now: context.date)
                            }
                        }

                        watchStatusRows

                        if state.watchActivityPreciseMode {
                            Button("Start Live Session on Watch") {
                                state.startLiveSessionOnWatch()
                            }
                            if let error = state.liveSessionStartError {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                ).listRowBackground(Color.chart)
            }

            Section(
                header: Text("Contact Image"),
                content: {
                    VStack {
                        HStack {
                            NavigationLink("Contacts Configuration") {
                                ContactImage.RootView(resolver: resolver)
                            }.foregroundStyle(Color.accentColor)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        // back from the CGM's settings
        .onAppear { state.refreshWatchSensor() }
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: hintLabel ?? "",
                hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.automatic)
        .settingsHighlightScroll()
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}

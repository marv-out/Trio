import SwiftUI
import Swinject

extension History {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @State var deletionTarget: History.DeletionTarget?
        @State var showErrorAlert: Bool = false
        @State var errorMessage: String = ""
        @State var showFutureEntries: Bool = false // default to hide future entries
        @State var showManualGlucose: Bool = false
        @State var isAmountUnconfirmed: Bool = true
        @State var showTreatmentTypeFilter = false
        @State var selectedTreatmentTypes: Set<TreatmentType> = Set(TreatmentType.allCases)

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        // Glucose readings now live in GRDB; `state.glucoseStored` is kept current via
        // ValueObservation (see HistoryStateModel), sorted newest-first.

        // Pump events (incl. boluses + temp basals) now live in GRDB; `state.pumpEventStored` is kept
        // current via ValueObservation (see HistoryStateModel), sorted newest-first.

        // Carbs (+ FPU equivalents) now live in GRDB; `state.carbEntryStored` is kept current via
        // ValueObservation (see HistoryStateModel), sorted newest-first.

        // Override + temp target runs now live in GRDB; `state.overrideRunStored` /
        // `state.tempTargetRunStored` are kept current via ValueObservation (see HistoryStateModel),
        // sorted newest-first.

        var body: some View {
            historyConfirmations(
                ZStack(alignment: .center, content: {
                    VStack {
                        Picker("Mode", selection: $state.mode) {
                            ForEach(
                                Mode.allCases.indexed(),
                                id: \.1
                            ) { index, item in
                                Text(item.name).tag(index)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal)

                        Form {
                            switch state.mode {
                            case .treatments: treatmentsList
                            case .glucose: glucoseList
                            case .meals: mealsList
                            case .adjustments: adjustmentsList
                            }
                        }.scrollContentBackground(.hidden)
                            .background(appState.trioBackgroundColor(for: colorScheme))
                    }.blur(radius: state.waitForSuggestion ? 8 : 0)

                    // Show custom progress view
                    /// don't show it if glucose is stale as it will block the UI
                    if state.waitForSuggestion && state.isGlucoseDataFresh(state.glucoseStored.first?.date) {
                        CustomProgressView(text: progressText.displayName)
                    }
                })
                    .background(appState.trioBackgroundColor(for: colorScheme))
                    .onAppear(perform: configureView)
                    .onDisappear {
                        state.carbEntryDeleted = false
                        state.insulinEntryDeleted = false
                    }
                    .navigationTitle("History")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing, content: {
                            addButton({
                                showManualGlucose = true
                                state.manualGlucose = 0
                            })
                        })
                    }
                    .sheet(isPresented: $showManualGlucose) {
                        addGlucoseView()
                    }
                    .sheet(isPresented: $state.showCarbEntryEditor) {
                        if let carbEntry = state.carbEntryToEdit {
                            CarbEntryEditorView(state: state, carbEntry: carbEntry)
                        }
                    }
            )
        }

        @ViewBuilder func addButton(_ action: @escaping () -> Void) -> some View {
            Button(
                action: action,
                label: {
                    HStack {
                        Text("Add Glucose")
                        Image(systemName: "plus")
                            .font(.title2)
                    }
                }
            )
        }

        var progressText: ProgressText {
            switch (state.carbEntryDeleted, state.insulinEntryDeleted) {
            case (true, false):
                return .updatingCOB
            case(false, true):
                return .updatingIOB
            default:
                return .updatingHistory
            }
        }
    }
}

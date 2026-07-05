import SwiftUI

extension History.RootView {
    func requestDelete(_ target: History.DeletionTarget) {
        deletionTarget = target
    }

    @ViewBuilder func historyConfirmations(_ content: some View) -> some View {
        content
            .confirmationDialog(
                deletionTarget?.title(units: state.units) ?? "",
                isPresented: Binding(
                    get: { deletionTarget != nil },
                    set: { if !$0 { deletionTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletionTarget
            ) { target in
                Button("Delete", role: .destructive) {
                    switch target {
                    case let .glucose(glucose):
                        if let pk = glucose.pk {
                            state.invokeGlucoseDeletionTask(pk)
                        }
                    case let .insulin(pumpEvent):
                        if let pk = pumpEvent.event.pk {
                            state.invokeInsulinDeletionTask(pk)
                        }
                    case let .carbs(carbEntry):
                        if let pk = carbEntry.pk {
                            state.invokeCarbDeletionTask(
                                pk,
                                isFpuOrComplexMeal: carbEntry.isFPU || carbEntry.fat > 0 || carbEntry.protein > 0
                            )
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                if let message = target.message(units: state.units) {
                    Text(message)
                }
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
    }
}

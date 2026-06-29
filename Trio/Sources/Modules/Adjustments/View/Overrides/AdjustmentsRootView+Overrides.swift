import CoreData
import SwiftUI

extension Adjustments.RootView {
    @ViewBuilder func overrides() -> some View {
        if state.isOverrideEnabled, state.activeOverrideName.isNotEmpty {
            currentActiveAdjustment
        }
        if state.overridePresets.isNotEmpty {
            overridePresets
        } else {
            defaultText
        }
    }

    var overridePresets: some View {
        Section {
            ForEach(state.overridePresets) { preset in
                overridesView(for: preset, showCheckMark: showOverrideCheckmark) {
                    requestOverridePresetActivation(preset)
                }
                .contextMenu {
                    actionButtonsForOverrides(for: preset)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    actionButtonsForOverrides(for: preset)
                }
            }
            .onMove(perform: state.reorderOverride)
            .listRowBackground(Color.chart)
        } header: {
            Text("Override Presets")
        } footer: {
            HStack {
                Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                Text("Swipe left to edit or delete an override preset. Hold, drag and drop to reorder a preset.")
            }
        }
    }

    private func requestOverridePresetActivation(_ preset: OverrideRecord) {
        guard let pk = preset.pk else { return }
        let activation = PendingPresetActivation.override(
            pk: pk,
            presetID: preset.id,
            name: preset.name ?? ""
        )

        requestPresetActivation(activation)
    }

    func actionButtonsForOverrides(for preset: OverrideRecord) -> some View {
        Group {
            Button(role: .destructive) {
                selectedOverride = preset
                isConfirmDeletePresented = true
            } label: {
                Label("Delete", systemImage: "trash.fill")
                    .tint(.red)
            }
            Button(action: {
                // Set the selected Override to the chosen Preset and pass it to the Edit Sheet
                selectedOverride = preset
                state.showOverrideEditSheet = true
            }, label: {
                Label("Edit", systemImage: "pencil")
                    .tint(.blue)
            })
        }
    }

    var overrideLabelDivider: some View {
        Divider()
            .frame(width: 1, height: 20)
    }

    var stickyStopOverrideButton: some View {
        ZStack {
            Rectangle()
                .frame(width: UIScreen.main.bounds.width, height: 65)
                .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                .background(.thinMaterial)
                .opacity(0.8)
                .clipShape(Rectangle())

            Button(action: {
                showCancelOverrideConfirmDialog = true
            }, label: {
                Text("Stop Override")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            })
                .frame(width: UIScreen.main.bounds.width * 0.9, height: 40, alignment: .center)
                .disabled(!state.isOverrideEnabled)
                .background(!state.isOverrideEnabled ? Color(.systemGray4) : Color(.systemRed))
                .tint(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                .padding(5)
        }
    }

    @ViewBuilder func overridesView(
        for preset: OverrideRecord,
        showCheckMark _: Bool = false,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let isSelected = preset.id == selectedOverridePresetID
        let name = preset.name ?? ""
        let indefinite = preset.indefinite
        let duration = preset.duration ?? Decimal(0)
        let percentage = preset.percentage
        let smbMinutes = preset.smbMinutes ?? Decimal(0)
        let uamMinutes = preset.uamMinutes ?? Decimal(0)

        let target: String = {
            guard let targetValue = preset.target, targetValue != 0 else { return "" }
            return state.units == .mgdL ? targetValue.description : targetValue.formattedAsMmolL
        }()

        let targetString = target.isEmpty ? "" : "\(target) \(state.units.rawValue)"

        let durationString = indefinite ? "" : "\(state.formatHoursAndMinutes(Int(duration)))"

        let scheduledSMBString: String = {
            guard preset.smbIsScheduledOff, preset.start != preset.end else { return "" }
            return " \(formatTimeRange(start: preset.start.map { "\($0)" }, end: preset.end.map { "\($0)" }))"
        }()

        let smbString: String = {
            guard preset.smbIsOff || preset.smbIsScheduledOff else { return "" }
            return "SMBs Off\(scheduledSMBString)"
        }()

        let maxSmbMinsString: String = {
            guard smbMinutes != 0, preset.advancedSettings, !preset.smbIsOff,
                  smbMinutes != state.defaultSmbMinutes else { return "" }
            return "\(smbMinutes.formatted()) min SMB"
        }()

        let maxUamMinsString: String = {
            guard uamMinutes != 0, preset.advancedSettings, !preset.smbIsOff,
                  uamMinutes != state.defaultUamMinutes else { return "" }
            return "\(uamMinutes.formatted()) min UAM"
        }()

        let isfAndCrString: String = {
            switch (preset.isfAndCr, preset.isf, preset.cr) {
            case (_, true, true),
                 (true, _, _):
                return " ISF/CR"
            case (false, true, false):
                return " ISF"
            case (false, false, true):
                return " CR"
            default:
                return ""
            }
        }()

        let percentageString = percentage != 100 ? "\(Int(percentage))%\(isfAndCrString)" : ""

        // Combine all labels into a single array, filtering out empty strings
        let labels: [String] = [
            durationString,
            percentageString,
            targetString,
            smbString,
            maxSmbMinsString,
            maxUamMinsString
        ].filter { !$0.isEmpty }

        if !name.isEmpty {
            ZStack(alignment: .trailing) {
                HStack {
                    VStack {
                        HStack {
                            Text(name)
                            Spacer()
                        }
                        HStack(spacing: 5) {
                            ForEach(labels, id: \.self) { label in
                                Text(label)
                                if label != labels.last { // Add divider between labels
                                    overrideLabelDivider
                                }
                            }
                            Spacer()
                        }
                        .padding(.top, 2)
                        .foregroundColor(.secondary)
                        .font(.caption)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap?()
                    }
                }
                // show checkmark to indicate if the preset was actually pressed
                if showOverrideCheckmark && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.large)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.green)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

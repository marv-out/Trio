import Foundation
import SwiftUI
import Swinject

protocol ContactImageStorage {
    func fetchContactImageEntries() async -> [ContactImageEntry]
    func storeContactImageEntry(_ entry: ContactImageEntry) async
    func updateContactImageEntry(_ contactImageEntry: ContactImageEntry) async
    func deleteContactImageEntry(_ storedID: Int64) async
}

final class BaseContactImageStorage: ContactImageStorage, Injectable {
    @Injected() private var settingsManager: SettingsManager!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    /// Fetches all stored contact-image entries (GRDB), mapped to the `ContactImageEntry`
    /// domain model. High-contrast entries first, as before.
    func fetchContactImageEntries() async -> [ContactImageEntry] {
        do {
            let records = try await ContactImageStore.fetchAll()
            return records.map { record in
                ContactImageEntry(
                    name: record.name ?? String(localized: "No name provided"),
                    layout: ContactImageLayout(rawValue: record.layout ?? "Default") ?? .default,
                    ring: ContactImageLargeRing(rawValue: record.ring ?? "Hidden") ?? .none,
                    primary: ContactImageValue(rawValue: record.primary ?? "Glucose Reading") ?? .glucose,
                    top: ContactImageValue(rawValue: record.top ?? "None") ?? .none,
                    bottom: ContactImageValue(rawValue: record.bottom ?? "None") ?? .none,
                    contactId: record.contactId,
                    hasHighContrast: record.hasHighContrast ?? false,
                    ringWidth: ContactImageEntry.RingWidth(rawValue: Int(record.ringWidth ?? 0)) ?? .regular,
                    ringGap: ContactImageEntry.RingGap(rawValue: Int(record.ringGap ?? 0)) ?? .small,
                    colorMode: ContactImageEntry.ColorMode(rawValue: record.colorMode ?? "Color") ?? .color,
                    fontSize: ContactImageEntry.FontSize(rawValue: Int(record.fontSize ?? 0)) ?? .regular,
                    secondaryFontSize: ContactImageEntry.FontSize(rawValue: Int(record.fontSizeSecondary ?? 0)) ?? .small,
                    fontWeight: Font.Weight.fromString(record.fontWeight ?? "regular"),
                    fontWidth: Font.Width.fromString(record.fontWidth ?? "standard"),
                    storedID: record.pk
                )
            }
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Error fetching contact image entries: \(error)")
            return []
        }
    }

    /// Stores a new contact-image entry.
    func storeContactImageEntry(_ contactImageEntry: ContactImageEntry) async {
        let record = makeRecord(from: contactImageEntry, id: UUID())
        do {
            try await ContactImageStore.insert(record)
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to save Contact Image Entry: \(error)"
            )
        }
    }

    /// Updates the entry matching `contactId` in place; no-op if none exists.
    func updateContactImageEntry(_ contactImageEntry: ContactImageEntry) async {
        // id/pk are preserved by the store; pass nil id here.
        let record = makeRecord(from: contactImageEntry, id: nil)
        do {
            try await ContactImageStore.updateByContactId(record)
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update Contact Image Entry: \(error)"
            )
        }
    }

    /// Deletes a contact-image entry by its GRDB row id.
    func deleteContactImageEntry(_ storedID: Int64) async {
        do {
            try await ContactImageStore.delete(pk: storedID)
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to delete Contact Image Entry: \(error)"
            )
        }
    }

    private func makeRecord(from entry: ContactImageEntry, id: UUID?) -> ContactImageRecord {
        ContactImageRecord(
            id: id,
            name: entry.name,
            contactId: entry.contactId,
            layout: entry.layout.rawValue,
            ring: entry.ring.rawValue,
            primary: entry.primary.rawValue,
            top: entry.top.rawValue,
            bottom: entry.bottom.rawValue,
            hasHighContrast: entry.hasHighContrast,
            ringWidth: Int16(entry.ringWidth.rawValue),
            ringGap: Int16(entry.ringGap.rawValue),
            colorMode: entry.colorMode.rawValue,
            fontSize: Int16(entry.fontSize.rawValue),
            fontSizeSecondary: Int16(entry.secondaryFontSize.rawValue),
            fontWeight: entry.fontWeight.asString,
            fontWidth: entry.fontWidth.asString
        )
    }
}

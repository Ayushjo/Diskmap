import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

@MainActor
@Suite("Saved searches in the app")
struct SavedSearchAppTests {

    @Test func saveSelectMoveRemove() {
        let model = ScanModel()   // never writes the user's preferences
        #expect(model.saveSearch(name: "Big videos", query: " kind:video size>1GB ", sort: .largest))
        #expect(model.saveSearch(name: "Logs", query: "name:*.log size>50MB", sort: .oldest))
        #expect(model.saveSearch(name: "Huge videos", query: "kind:video size>1GB", sort: .largest), "same query renames")
        #expect(model.savedSearches.map(\.name) == ["Huge videos", "Logs"])
        #expect(UserDefaults.standard.string(forKey: ScanModel.savedSearchesKey).map { $0.contains("Huge videos") } != true)

        let logs = model.savedSearches[1]
        model.openSavedSearch(logs)
        #expect(model.destination == .find)
        #expect(model.findQuery == logs.query)
        #expect(model.findSort == .oldest)
        #expect(model.isSavedSearchSelected(logs))
        #expect(!model.isSavedSearchSelected(model.savedSearches[0]))

        model.moveSavedSearch(logs.id, by: -1)
        #expect(model.savedSearches.first?.id == logs.id)
        model.removeSavedSearch(logs.id)
        #expect(model.savedSearches.map(\.name) == ["Huge videos"])
        #expect(!model.saveSearch(name: "x", query: "   ", sort: .largest))
    }

    @Test func numberedShortcutsIgnoreSavedSearches() {
        let model = ScanModel()
        model.saveSearch(name: "A", query: "size>1GB", sort: .largest)
        #expect(KeyboardCommands.numberedDestinations == Array(AppNavSection.allCases.flatMap(\.items).prefix(9)))
        #expect(KeyboardCommands.numberedDestinations.count == 9)
    }
}

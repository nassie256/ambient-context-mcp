import Foundation
import Testing
@testable import AmbientContextCore

@Suite("TransientStateSettings")
struct TransientStateSettingsTests {
    private let temp = TempDirectory()

    private var settingsPath: String { temp.file("settings.json") }

    @Test("Save_then_load_round_trips_LastActivityDate")
    func saveThenLoadRoundTripsLastActivityDate() {
        let store = JsonFileSettingsStore(path: settingsPath)
        let today = DateOnly(2026, 5, 17)

        store.saveTransientStateSettings(TransientStateSettings(lastActivityDate: today))

        let reopened = JsonFileSettingsStore(path: settingsPath)
        let loaded = reopened.loadTransientStateSettings()

        #expect(loaded.lastActivityDate == today)
    }

    @Test("Load_returns_default_when_section_absent")
    func loadReturnsDefaultWhenSectionAbsent() {
        let store = JsonFileSettingsStore(path: settingsPath)
        // 別セクションだけ保存し、transientState は触らない
        store.saveUiSettings(UiSettings())

        let loaded = store.loadTransientStateSettings()

        #expect(loaded.lastActivityDate == nil)
    }

    @Test("Save_does_not_clobber_other_sections")
    func saveDoesNotClobberOtherSections() throws {
        let store = JsonFileSettingsStore(path: settingsPath)
        store.saveSettingsWindowStatus(
            SettingsWindowStatus(left: 123, top: 456, width: 789, height: 321))

        store.saveTransientStateSettings(
            TransientStateSettings(lastActivityDate: DateOnly(2026, 5, 17)))

        let reopened = JsonFileSettingsStore(path: settingsPath)
        let windowAfter = try #require(reopened.loadSettingsWindowStatus())

        #expect(windowAfter.left == 123)
        #expect(windowAfter.top == 456)
    }
}

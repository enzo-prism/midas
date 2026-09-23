import AppKit
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowControllerTests {
    private func makeController(
        selection: PreferencesSelection,
        created: @escaping @MainActor () -> Void = {},
        presented: @escaping @MainActor (NSWindow) -> Void = { _ in }) -> SettingsWindowController
    {
        SettingsWindowController(
            selection: selection,
            makeWindow: {
                created()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: true)
                window.isReleasedWhenClosed = false
                return window
            },
            presentWindow: presented)
    }

    @Test
    func `opens by creating once then reusing the retained window`() throws {
        let selection = try PreferencesSelection(onboardingDefaults: #require(UserDefaults(suiteName: #function)))
        var creations = 0
        var presented: [NSWindow] = []
        let controller = self.makeController(
            selection: selection,
            created: { creations += 1 },
            presented: { presented.append($0) })

        #expect(controller.open(tab: .providers) == .created)
        controller.closeWindow()
        #expect(controller.open(tab: nil) == .reused)

        #expect(creations == 1)
        #expect(presented.count == 2)
        #expect(presented[0] === presented[1])
        #expect(presented[0].identifier == SettingsWindowIdentity.identifier)
        #expect(selection.tab == .providers)
    }

    @Test
    func `requested tab replaces the current selection`() throws {
        let selection = try PreferencesSelection(onboardingDefaults: #require(UserDefaults(suiteName: #function)))
        let controller = self.makeController(selection: selection)

        controller.open(tab: .about)
        #expect(selection.tab == .about)
        controller.open(tab: .general)
        #expect(selection.tab == .general)
    }
}

import AppKit
import CodexBarCore
import SwiftUI

enum SettingsWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier("com.steipete.codexbar.settings")
    static let frameAutosaveName = "Midas.SettingsWindow"
    static let title = "Midas Settings"
}

/// Posted with a `SettingsOpenRequest` so callers can tell whether anyone presented Settings.
final class SettingsOpenRequest {
    let tab: PreferencesTab?
    var wasHandled = false

    init(tab: PreferencesTab?) {
        self.tab = tab
    }
}

/// Owns the Settings window in AppKit so opening it never depends on a live SwiftUI scene.
/// The previous design relayed requests through a hidden `WindowGroup` window; once macOS tore that
/// window down, every Settings action was silently dropped.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Outcome: Equatable {
        case created
        case reused
    }

    typealias WindowFactory = @MainActor () -> NSWindow
    typealias WindowAction = @MainActor (NSWindow) -> Void

    private let selection: PreferencesSelection
    private let makeWindow: WindowFactory
    private let presentWindow: WindowAction
    private let logger = CodexBarLog.logger(LogCategories.app)
    private var retainedWindow: NSWindow?

    init(
        selection: PreferencesSelection,
        makeWindow: @escaping WindowFactory,
        presentWindow: @escaping WindowAction = SettingsWindowController.present)
    {
        self.selection = selection
        self.makeWindow = makeWindow
        self.presentWindow = presentWindow
        super.init(window: nil)
    }

    convenience init(
        selection: PreferencesSelection,
        makeRootView: @escaping @MainActor () -> PreferencesView)
    {
        self.init(selection: selection) {
            let hostingController = NSHostingController(rootView: makeRootView())
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: PreferencesTab.defaultWidth,
                    height: PreferencesTab.windowHeight),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.contentViewController = hostingController
            window.title = SettingsWindowIdentity.title
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            if !window.setFrameUsingName(SettingsWindowIdentity.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(SettingsWindowIdentity.frameAutosaveName)
            return window
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool {
        self.retainedWindow?.isVisible == true
    }

    @discardableResult
    func open(tab: PreferencesTab?) -> Outcome {
        if let tab {
            self.selection.tab = tab
        }
        let outcome: Outcome
        let window: NSWindow
        if let retainedWindow {
            window = retainedWindow
            outcome = .reused
        } else {
            window = self.makeWindow()
            window.identifier = SettingsWindowIdentity.identifier
            self.retainedWindow = window
            self.window = window
            outcome = .created
        }
        self.presentWindow(window)
        self.logger.info(
            "Settings window presented",
            metadata: [
                "outcome": outcome == .created ? "created" : "reused",
                "tab": self.selection.tab.rawValue,
            ])
        return outcome
    }

    func closeWindow() {
        self.retainedWindow?.close()
    }

    static func present(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

import AppKit
import SwiftUI

/// Editor windows opened from AppKit, one per package. SwiftUI's
/// `openWindow(id:value:)` only acts from inside a rendered view, which left
/// the take-complete path (and any programmatic open) silently doing
/// nothing; hosting the editor in our own `NSWindow` makes opening a plain
/// call. The hosting view is released on close so the editor's
/// `onDisappear` runs and its model is torn down.
@MainActor final class EditorWindows: NSObject, NSWindowDelegate {
    static let shared = EditorWindows()

    private var windows: [URL: NSWindow] = [:]

    func open(_ url: URL, appModel: AppModel) {
        let key = url.standardizedFileURL
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let settings = EditorSettings()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: settings.windowWidth, height: settings.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = url.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: EditorWindow(url: .constant(url), appModel: appModel))
        hosting.sizingOptions = []  // PLAN M1-F6: the window never sizes itself from the content
        window.contentView = hosting
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
        // Dropping the hosting view runs the editor's onDisappear (model close).
        window.contentView = nil
    }
}

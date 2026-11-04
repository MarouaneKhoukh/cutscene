import AppKit
import CutsceneCore
import SwiftUI

/// The process entry: `--editor-check <package>` runs the editor's
/// self-check (PLAN M2-10) without a window and exits; anything else is the app.
@main
enum CutsceneMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--editor-check") {
            exit(EditorSelfCheck.run(arguments: Array(arguments[(index + 1)...])))
        }
        CutsceneApp.main()
    }
}

/// The launch arguments the app reads beyond the system's `-key value` defaults.
enum LaunchArgument {
    /// Opens the onboarding and recovery windows right after launch, whatever
    /// the grants and the recordings folder hold, so the hosted windows can
    /// be checked for PLAN M1-F6's layout crash from a shell (`open
    /// dist/Cutscene.app --args --open-windows`) without revoking a grant.
    static let openWindows = "--open-windows"

    static func isPresent(_ argument: String) -> Bool {
        CommandLine.arguments.contains(argument)
    }
}

/// The menu-bar recorder (ARCHITECTURE §1): a `MenuBarExtra`, a `Settings`
/// scene, a small recorder window shown at launch, and the editor
/// (`WindowGroup` keyed by the package URL, M2-10). `LSUIElement` in the
/// bundle keeps it out of the Dock; the editor flips the activation policy
/// while it is open.
struct CutsceneApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel
    /// Alive for the process when `--open-windows` was given, nil otherwise.
    private let launchWindows: LaunchWindowOpener?

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        launchWindows = LaunchArgument.isPresent(LaunchArgument.openWindows) ? LaunchWindowOpener(model: model) : nil
        appDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
        // ⌘Q from the main menu (visible while an editor is open) goes the
        // way the menu's Quit does; the delegate below catches every other
        // termination request (the Dock tile, a logout).
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Cutscene") { model.quit() }
                    .keyboardShortcut("q")
            }
        }

        // One editor per package: `openWindow(id:value:)` with the same URL
        // brings the existing window forward. Never opened at launch and
        // never restored: a menu-bar agent starts with no window but the
        // recorder's.
        WindowGroup("Editor", id: AppModel.editorWindowID, for: URL.self) { $url in
            EditorWindow(url: $url, appModel: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The launcher: a live preview of the source, the camera bubble and
        // the microphone meter around one Record button. Shown at launch
        // because on a notched MacBook a full menu bar hides new status items
        // (observed 2026-11-04).
        Window("Cutscene", id: "recorder") {
            RecorderLauncher(model: model)
        }
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// The application delegate: every termination request, whichever way it
/// came (the menu's Quit, ⌘Q, the Dock tile, a logout), is held with
/// `.terminateLater` until `AppModel.settleForQuit` has stopped the take,
/// cancelled the render, settled the recovery and saved the open editors,
/// then let through. Without it `NSApp.terminate` from the standard menu
/// killed a take mid-finish and lost an editor's debounced save.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // A second request while the first settles would reply twice;
        // the first reply ends the process.
        guard !model.isQuitting else { return .terminateCancel }
        Task { @MainActor in
            await model.settleForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Opens the onboarding and recovery windows once the app has finished
/// launching (`LaunchArgument.openWindows`). The recovery window shown here
/// is its own flow, so it opens with "Nothing left to finish." when the
/// recordings folder is clean; a staged `inProgress` package makes the
/// model's own one open beside it.
@MainActor final class LaunchWindowOpener {
    private unowned let model: AppModel
    private var recovery: RecoveryFlow?
    private var observer: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    private func open() {
        model.showOnboarding()
        let recovery = RecoveryFlow(model: model)
        self.recovery = recovery
        recovery.show()
    }
}

/// Makes the hosting window float above other apps and follow the user to
/// every Space, full-screen apps included; a launch window that sits on the
/// desktop Space is invisible to someone working in a full-screen app
/// (observed 2026-11-04). The recording HUD (M2-09) needs the same behaviour.
struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    /// The view joins its window a few run-loop turns after creation; poll
    /// briefly instead of assuming a particular turn.
    private func configureWhenAttached(_ view: NSView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt == 0 ? 0 : 50)) {
            if let window = view.window {
                configure(window)
            } else if attempt < 40 {
                configureWhenAttached(view, attempt: attempt + 1)
            }
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.orderFrontRegardless()
    }
}

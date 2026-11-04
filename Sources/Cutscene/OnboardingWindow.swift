import AppKit
import CutsceneCapture
import Security
import SwiftUI

/// The numbers the onboarding window is drawn with.
struct OnboardingWindowSettings: Sendable, Equatable {
    /// Fixed content size in points (PLAN M1-F6): the window never sizes
    /// itself from its rows. The width is `AppSettings.onboardingWindowWidth`;
    /// the height holds the four rows with the relaunch notice and the
    /// ad-hoc diagnosis both showing, and anything beyond scrolls.
    var width = 600.0
    var height = 640.0
}

/// The window that walks the user through the grants (ARCHITECTURE §7): one
/// row per capability with its state, a request button where a request can
/// still prompt, the System Settings deep link where it cannot, and Relaunch
/// once a grant waits for one.
///
/// An AppKit window rather than a SwiftUI `Window` scene: a menu-bar agent
/// has no window to hand `openWindow` to, and the model opens this one at
/// launch, from the menu and from a declined microphone grant alike. While it
/// is visible `PermissionsModel` re-preflights once a second.
///
/// The content is an `NSHostingView` with no sizing options in a window of
/// a fixed size, not an `NSHostingController` as the content view
/// controller: the controller's `preferredContentSize` re-measured the
/// SwiftUI graph from inside AppKit's update-constraints pass, and when the
/// rows changed height during that pass AppKit's loop detector threw
/// `NSInternalInconsistencyException` and killed the app (PLAN M1-F6, two
/// reports on 2026-11-03).
@MainActor final class OnboardingWindow: NSObject, NSWindowDelegate {
    let settings: OnboardingWindowSettings
    private unowned let model: AppModel
    private var window: NSWindow?

    init(model: AppModel, settings: OnboardingWindowSettings? = nil) {
        self.model = model
        self.settings =
            settings ?? OnboardingWindowSettings(width: model.settings.onboardingWindowWidth)
    }

    func show() {
        let window = window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14; the menu click that got
        // us here usually grants it, and when it does not the window still
        // comes forward.
        NSApp.activate()
        if !NSApp.isActive {
            window.orderFrontRegardless()
        }
        model.permissions.isOnboardingVisible = true
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.permissions.isOnboardingVisible = false
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: settings.width, height: settings.height)
        let hosting = NSHostingView(rootView: OnboardingView(model: model, window: self, settings: settings))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.contentView = hosting
        window.title = "Welcome to Cutscene"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}

/// The rows: Screen Recording (required), Microphone, Camera (a later
/// milestone) and Input Monitoring (opt-in from Settings, so a deep link only).
///
/// The rows and notices scroll inside the fixed frame, so a state that adds
/// a notice never asks the window for more height. Every text that may wrap
/// carries `fixedSize(horizontal: false, vertical: true)` so the two
/// measuring passes agree (see `RecoveryView`).
struct OnboardingView: View {
    let model: AppModel
    let window: OnboardingWindow
    let settings: OnboardingWindowSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Welcome to Cutscene").font(.title.bold())
                    Text(
                        """
                        Cutscene records a display from the menu bar. macOS asks once per capability, \
                        and a Screen Recording grant reaches the app only after it relaunches.
                        """
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Capability.allCases, id: \.self) { capability in
                            PermissionRow(capability: capability, model: model)
                            if capability != Capability.allCases.last { Divider() }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    if model.permissions.relaunchNeeded {
                        relaunchNotice
                    }
                    if model.permissions.screenRecording != .granted, CodeSignature.isAdHoc {
                        adHocDiagnosis
                    }
                    if let error = model.relaunchError {
                        Text(error).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { window.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: settings.width, height: settings.height)
    }

    private var relaunchNotice: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A grant is waiting for a relaunch").font(.headline)
                    Text("The running app predates it; relaunching takes a second and keeps everything else.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Relaunch Cutscene") { model.relaunch() }
                    .disabled(model.isBusy)
            }
            .padding(4)
        }
    }

    /// The dev window's diagnosis, kept for ad-hoc builds: TCC binds such a
    /// grant to one exact build (platform-notes, "the ad-hoc trap").
    private var adHocDiagnosis: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Development build with an ad-hoc signature", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(
                    """
                    If System Settings already shows Cutscene enabled, that grant belongs to an older build: \
                    ad-hoc signatures change with every code change. Clear it with \
                    `tccutil reset ScreenCapture app.cutscene.Cutscene`, relaunch, and allow again. \
                    `make dev-cert` prevents this permanently. A grant only takes effect after a relaunch.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }
}

private struct PermissionRow: View {
    let capability: Capability
    let model: AppModel

    private var state: PermissionState { model.permissions.state(of: capability) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.displayName).font(.headline)
                Text(purpose).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stateDescription).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .granted:
            EmptyView()
        case .grantedPendingRelaunch:
            Button("Relaunch Cutscene") { model.relaunch() }
                .disabled(model.isBusy)
        case .notDetermined:
            if canRequestHere {
                Button("Grant…") { Task { await model.permissions.request(capability) } }
            }
            settingsButton
        case .denied:
            if canRequestAgain {
                Button("Grant…") { Task { await model.permissions.request(capability) } }
            }
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button("System Settings…") { model.permissions.openSystemSettings(for: capability) }
    }

    /// Screen Recording and the microphone are asked for from here; the
    /// camera is asked for by the pick alone (M2-09: "on first toggle
    /// only") and Input Monitoring by a Settings action (§7), so those two
    /// rows link to the switch only.
    private var canRequestHere: Bool {
        switch capability {
        case .screenRecording, .microphone: true
        case .camera, .inputMonitoring: false
        }
    }

    /// Screen Recording's "declined" is read from a false preflight after a
    /// request, which a dismissed dialog produces too, and the system never
    /// re-prompts an answered app, so a second press is harmless and the
    /// button stays. The microphone's state is the system's own answer.
    private var canRequestAgain: Bool {
        switch capability {
        case .screenRecording: true
        case .microphone, .camera, .inputMonitoring: false
        }
    }

    private var purpose: String {
        switch capability {
        case .screenRecording: "Required: the display's frames and system audio."
        case .microphone: "Narration, on the same clock as the video. Asked for when you pick a microphone."
        case .camera: "The camera bubble. Asked for when you pick a camera; pick it again to be asked."
        case .inputMonitoring:
            "Optional: keystrokes and exact click times. Switched on from Settings; the recorder never asks."
        }
    }

    private var stateDescription: String {
        switch state {
        case .notDetermined: "Not asked yet"
        case .denied: "Off in System Settings"
        case .grantedPendingRelaunch: "Granted; takes effect after a relaunch"
        case .granted: "Granted"
        }
    }

    private var symbolName: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .grantedPendingRelaunch: "arrow.clockwise.circle.fill"
        case .notDetermined: "circle"
        case .denied: "xmark.circle"
        }
    }

    private var symbolColor: Color {
        switch state {
        case .granted: .green
        case .grantedPendingRelaunch: .orange
        case .notDetermined: .secondary
        case .denied: .red
        }
    }
}

/// How this binary is signed, read once from its own code object.
enum CodeSignature {
    /// Whether the signature is ad-hoc (no certificate), the development
    /// case TCC binds to one exact build. False when the information cannot
    /// be read, so a stable identity never sees the diagnosis.
    static let isAdHoc: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let information = information as? [String: Any],
            let flags = information[kSecCodeInfoFlags as String] as? UInt32
        else { return false }
        return SecCodeSignatureFlags(rawValue: flags).contains(.adhoc)
    }()
}

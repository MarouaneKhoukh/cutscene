import AppKit
import Foundation

/// Quits this instance and opens the bundle again: the only way a fresh
/// Screen Recording or Input Monitoring grant reaches the process, since the
/// window server decides at connection time (ARCHITECTURE §7, platform-notes).
///
/// Launch Services is asked for a second instance of our own bundle with
/// `createsNewApplicationInstance`; without it, `openApplication` would just
/// bring this instance, the one that predates the grant, to the front. The
/// dev window's `/usr/bin/open -n` through a shell was the prototype; this
/// is the same request without the shell and with an error to show.
@MainActor enum Relauncher {
    enum RelaunchError: LocalizedError {
        /// The process is not running from an `.app` bundle (`swift run`),
        /// which Launch Services cannot open again.
        case notABundle(URL)
        case launchFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .notABundle(let url):
                "\(url.path) is not an app bundle; relaunch needs the bundle from `make run`."
            case .launchFailed(let error):
                "The new instance could not be launched: \(error.localizedDescription)"
            }
        }
    }

    /// Launches a new instance of this bundle and terminates this one once
    /// the launch was accepted. Returns only on failure, with why.
    static func relaunch() async throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { throw RelaunchError.notABundle(bundleURL) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let failure: (any Error)? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                continuation.resume(returning: error)
            }
        }
        if let failure { throw RelaunchError.launchFailed(failure) }
        NSApp.terminate(nil)
    }
}

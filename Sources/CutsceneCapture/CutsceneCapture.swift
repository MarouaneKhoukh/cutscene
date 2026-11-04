import AVFoundation
import CutsceneCore
import ScreenCaptureKit

/// Screen, camera, microphone and input-event capture.
public enum CutsceneCapture {
    /// Number of displays the current process is allowed to capture.
    ///
    /// A toolchain and permission smoke test; real capture lives in dedicated types.
    public static func capturableDisplayCount() async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.count
    }
}

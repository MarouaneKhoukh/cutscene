/// Cutscene's shared vocabulary: projects, recordings, the timeline and brand kits.
///
/// This module deliberately imports nothing from AppKit or SwiftUI so it can be
/// tested quickly and reused from command-line tools.
public enum CutsceneCore {
    /// Version of the on-disk project format. Bumped only on breaking changes.
    public static let projectFormatVersion = 1
}

import Testing

@testable import CutsceneCore

@Test func projectFormatVersionIsStable() {
    #expect(CutsceneCore.projectFormatVersion == 1)
}

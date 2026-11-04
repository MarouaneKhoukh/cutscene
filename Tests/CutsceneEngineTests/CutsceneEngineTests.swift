import Testing

@testable import CutsceneEngine

@Test func engineModuleLinks() {
    #expect(String(describing: CutsceneEngine.self) == "CutsceneEngine")
}

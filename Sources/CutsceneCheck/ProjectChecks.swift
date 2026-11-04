import CutsceneCore
import Foundation

/// Project-model checks: project, timeline, brand kit, store and migrator
/// (PLAN M1-03). Registered empty by M1-00 so `main.swift` is edited once per
/// milestone rather than once per task; the owning task fills the body and
/// reports through the shared checker so the pass count stays one number.
@MainActor
func runProjectChecks(_ checker: Checker) {
    checkTimeline(checker)
    checkProvenanceAndSource(checker)
    checkKitColor(checker)
    checkBrandKit(checker)
    checkExportSettings(checker)
    checkProject(checker)
    checkUnknownKeys(checker)
    checkRefusal(checker)
    checkMigrator(checker)
    checkProjectStore(checker)
}

/// JSON equality through Foundation's own parser, independent of `JSONValue`.
private func jsonObject(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

private func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "cutscene-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func uuid(_ text: String) -> UUID {
    UUID(uuidString: text)!
}

/// One step of a path into a JSON tree: an object key or an array index.
private enum PathStep: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    init(stringLiteral value: String) {
        self = .key(value)
    }

    init(integerLiteral value: Int) {
        self = .index(value)
    }
}

/// The value at `path` in `root`, nil when any step is missing.
private func value(at path: [PathStep], in root: JSONValue) -> JSONValue? {
    var current: JSONValue? = root
    for step in path {
        switch step {
        case .key(let key): current = current?[key]
        case .index(let index): current = current?[index]
        }
    }
    return current
}

private func describe(_ path: [PathStep]) -> String {
    path.map { step in
        switch step {
        case .key(let key): key
        case .index(let index): "[\(index)]"
        }
    }.joined(separator: ".")
}

// MARK: - Fixtures

private let clipID = uuid("11111111-1111-1111-1111-111111111111")
private let headTrimID = uuid("22222222-2222-2222-2222-222222222222")
private let tailTrimID = uuid("33333333-3333-3333-3333-333333333333")
private let manualCutID = uuid("44444444-4444-4444-4444-444444444444")
private let takeID = uuid("55555555-5555-5555-5555-555555555555")
private let retakeCutID = uuid("66666666-6666-6666-6666-666666666666")
private let silenceCutID = uuid("77777777-7777-7777-7777-777777777777")
private let wordIDs = [
    uuid("88888888-8888-8888-8888-888888888888"), uuid("99999999-9999-9999-9999-999999999999"),
]
private let wordsCutID = uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
private let autoSegmentID = uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
private let manualSegmentID = uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
private let laterCutID = uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")

/// One clip trimmed at both ends: the acceptance case.
private let trimmedTimeline = Timeline(
    clips: [Clip(id: clipID, start: 0, end: 12.5)],
    cuts: [
        Cut(id: headTrimID, start: 0, end: 1.5, provenance: .trim),
        Cut(id: tailTrimID, start: 10, end: 12.5, provenance: .trim),
    ])

/// Every provenance and source kind once.
private let timelineSample: Timeline = {
    var timeline = trimmedTimeline
    timeline.cuts += [
        Cut(id: manualCutID, start: 4, end: 4.5, provenance: .manual),
        Cut(id: retakeCutID, start: 6, end: 7, provenance: .retake(takeID)),
        Cut(id: silenceCutID, start: 8, end: 8.25, provenance: .silence),
        Cut(id: wordsCutID, start: 9, end: 9.5, provenance: .transcriptWords(wordIDs)),
    ]
    timeline.zoom = ZoomTrack(
        segments: [
            ZoomTrackSegment(
                id: autoSegmentID, start: 1.2, end: 4, focus: NormalizedPoint(x: 0.25, y: 0.75), amount: 2,
                source: .auto(generation: 1)),
            ZoomTrackSegment(
                id: manualSegmentID, start: 5, end: 6, focus: NormalizedPoint(x: 0.5, y: 0.5), amount: 1.5,
                source: .manual, locked: true),
        ], planGeneration: 1)
    return timeline
}()

private let recordingSample = RecordingManifest(
    recordingID: uuid("6F9619FF-8B86-D011-B42D-00C04FC964FF"),
    createdAt: PackageJSON.date(from: "2026-11-03T10:15:30.250Z")!,
    source: .display,
    content: ContentGeometry(
        displayID: 1, displayBoundsPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080),
        captureRectPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: 2),
    screen: ScreenTrackInfo(
        width: 3840, height: 2160, frameRate: 60, codec: "hevc",
        audioTracks: [AudioTrackInfo(source: .microphone, channelCount: 1)]),
    state: .complete, stopReason: .userStopped, duration: 12.5)

private let styleSample: BrandKit = {
    var style = BrandKit.default
    style.frame.cornerRadius = 24
    return style
}()

private let exportSample: ExportSettings = {
    var export = ExportSettings()
    export.preset = .uhd4K
    export.codec = .hevc
    export.frameRate = 30
    return export
}()

private let projectSample = Project(
    recording: recordingSample, timeline: timelineSample, kit: .default, style: styleSample,
    kitReference: KitReference(name: "Team"), export: exportSample)

/// `BrandKit.default`, compact, sorted keys: the pin M1-05 maps onto the
/// Engine and Render defaults.
private let kitFixture =
    "{\"background\":{\"gradient\":{\"angleDegrees\":45,\"from\":\"#1C2B4B\",\"to\":\"#4A1F5E\"},"
    + "\"kind\":\"linearGradient\",\"solid\":\"#1C2B4B\"},"
    + "\"camera\":{\"borderColor\":\"#FFFFFF\",\"borderWidth\":0,\"inset\":0.03,\"mirrorsBuiltInCameras\":true,"
    + "\"position\":\"bottomTrailing\",\"shape\":\"roundedRectangle\",\"size\":0.2,\"usesFrameShadow\":true},"
    + "\"cursor\":{\"click\":{\"color\":\"#FFFFFF\",\"duration\":0.5,\"easing\":\"easeOutCubic\",\"enabled\":true,"
    + "\"endOpacity\":0,\"endRadius\":44,\"endStrokeWidth\":0,\"maximumConcurrent\":4,\"startOpacity\":0.65,"
    + "\"startRadius\":0,\"startStrokeWidth\":2.5},"
    + "\"clickAnticipationWindow\":0.5,\"clickSpring\":{\"friction\":40,\"mass\":1,\"tension\":530},"
    + "\"clickSpringLead\":0.175,\"disabledRanges\":[],\"dragSpring\":{\"friction\":40,\"mass\":1,\"tension\":1000},"
    + "\"fadeInLead\":0.25,\"fadeOutDuration\":0.4,\"idleFadeDelay\":2,\"idleHoldGap\":0.067,"
    + "\"leadTimeConstant\":0.13,\"maximumInputRate\":60,\"minimumTravel\":0.0005208333333333333,"
    + "\"pressScale\":0.8,\"pressScaleDuration\":0.13,\"sampleRate\":60,\"scale\":1,\"settleTimeout\":5,"
    + "\"shakeLegThreshold\":0.015,\"shakeWindow\":0.1,\"spring\":{\"friction\":70,\"mass\":3,\"tension\":470}},"
    + "\"frame\":{\"cornerRadius\":18,\"padding\":0.06,\"referenceHeight\":1080,"
    + "\"shadow\":{\"blurRadius\":48,\"offsetX\":0,\"offsetY\":18,\"opacity\":0.55}},"
    + "\"schemaVersion\":1,"
    + "\"zoom\":{\"amount\":2,\"camera\":{\"deadZoneHeight\":0.7,\"deadZoneWidth\":0.5,"
    + "\"fallbackFocus\":{\"x\":0.5,\"y\":0.5},\"preAimThreshold\":1.0005,\"retargetInterval\":0.008,"
    + "\"sampleRate\":120,\"spring\":{\"friction\":40,\"mass\":2.25,\"tension\":200}},"
    + "\"detectsTypingBursts\":true,\"fallbackFocus\":{\"x\":0.5,\"y\":0.5},\"holdAfter\":2.5,\"leadIn\":0.3,"
    + "\"mergeGap\":2.5,\"trailingIgnore\":1,\"typingBurstMaximumGap\":0.5,\"typingBurstMinimumKeys\":3}}"

private let styleFixture = kitFixture.replacingOccurrences(of: "\"cornerRadius\":18", with: "\"cornerRadius\":24")

private let recordingFixture =
    "{\"content\":{\"captureRectPoints\":{\"height\":1080,\"width\":1920,\"x\":0,\"y\":0},"
    + "\"displayBoundsPoints\":{\"height\":1080,\"width\":1920,\"x\":0,\"y\":0},\"displayID\":1,\"pointPixelScale\":2},"
    + "\"createdAt\":\"2026-11-03T10:15:30.250Z\",\"duration\":12.5,\"formatVersion\":1,"
    + "\"recordingID\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\","
    + "\"screen\":{\"audioTracks\":[{\"channelCount\":1,\"source\":\"microphone\"}],\"codec\":\"hevc\","
    + "\"frameRate\":60,\"height\":2160,\"width\":3840},\"source\":{\"kind\":\"display\"},"
    + "\"state\":\"complete\",\"stopReason\":\"userStopped\"}"

private let timelineFixture =
    "{\"clips\":[{\"end\":12.5,\"id\":\"11111111-1111-1111-1111-111111111111\",\"start\":0}],"
    + "\"cuts\":[{\"end\":1.5,\"id\":\"22222222-2222-2222-2222-222222222222\",\"provenance\":{\"kind\":\"trim\"},\"start\":0},"
    + "{\"end\":12.5,\"id\":\"33333333-3333-3333-3333-333333333333\",\"provenance\":{\"kind\":\"trim\"},\"start\":10},"
    + "{\"end\":4.5,\"id\":\"44444444-4444-4444-4444-444444444444\",\"provenance\":{\"kind\":\"manual\"},\"start\":4},"
    + "{\"end\":7,\"id\":\"66666666-6666-6666-6666-666666666666\",\"provenance\":{\"kind\":\"retake\","
    + "\"takeID\":\"55555555-5555-5555-5555-555555555555\"},\"start\":6},"
    + "{\"end\":8.25,\"id\":\"77777777-7777-7777-7777-777777777777\",\"provenance\":{\"kind\":\"silence\"},\"start\":8},"
    + "{\"end\":9.5,\"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"provenance\":{\"kind\":\"transcriptWords\","
    + "\"wordIDs\":[\"88888888-8888-8888-8888-888888888888\",\"99999999-9999-9999-9999-999999999999\"]},\"start\":9}],"
    + "\"zoom\":{\"planGeneration\":1,\"segments\":[{\"amount\":2,\"end\":4,\"focus\":{\"x\":0.25,\"y\":0.75},"
    + "\"id\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\",\"locked\":false,\"source\":{\"generation\":1,\"kind\":\"auto\"},"
    + "\"start\":1.2},{\"amount\":1.5,\"end\":6,\"focus\":{\"x\":0.5,\"y\":0.5},"
    + "\"id\":\"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC\",\"locked\":true,\"source\":{\"kind\":\"manual\"},\"start\":5}]}}"

private let exportFixture =
    "{\"audio\":{\"microphoneGainDB\":0,\"systemAudioGainDB\":-6},\"codec\":\"hevc\",\"frameRate\":30,\"preset\":\"4k\"}"

private let projectFixture =
    "{\"export\":\(exportFixture),\"formatVersion\":1,\"kit\":\(kitFixture),\"kitReference\":{\"name\":\"Team\"},"
    + "\"recording\":\(recordingFixture),\"style\":\(styleFixture),\"timeline\":\(timelineFixture)}"

// MARK: - Timeline

@MainActor
private func checkTimeline(_ checker: Checker) {
    checker.equal(
        trimmedTimeline.keptRanges(), [TimeRange(start: 1.5, end: 10)],
        "one clip with two trim cuts keeps the inner range")
    checker.close(trimmedTimeline.duration, 8.5, "the trimmed timeline plays the inner range's length")
    checker.equal(
        timelineSample.keptRanges(),
        [
            TimeRange(start: 1.5, end: 4), TimeRange(start: 4.5, end: 6), TimeRange(start: 7, end: 8),
            TimeRange(start: 8.25, end: 9), TimeRange(start: 9.5, end: 10),
        ], "every cut kind removes its span, in order")
    checker.close(timelineSample.duration, 6.25, "the duration is the kept ranges end to end")

    let clip = Clip(id: clipID, start: 0, end: 10)
    func kept(_ cuts: [TimeRange], clips: [Clip] = [clip]) -> [TimeRange] {
        Timeline(clips: clips, cuts: cuts.map { Cut(start: $0.start, end: $0.end, provenance: .manual) }).keptRanges()
    }
    checker.equal(kept([]), [TimeRange(start: 0, end: 10)], "no cuts keeps the clip")
    checker.equal(
        kept([TimeRange(start: 2, end: 5), TimeRange(start: 4, end: 6)]),
        [TimeRange(start: 0, end: 2), TimeRange(start: 6, end: 10)], "overlapping cuts merge into one gap")
    checker.equal(
        kept([TimeRange(start: 4, end: 6), TimeRange(start: 2, end: 4)]),
        [TimeRange(start: 0, end: 2), TimeRange(start: 6, end: 10)], "touching cuts merge, whatever their order")
    checker.equal(
        kept([TimeRange(start: 12, end: 14)]), [TimeRange(start: 0, end: 10)], "a cut outside the clip is ignored")
    checker.equal(kept([TimeRange(start: -1, end: 11)]), [], "a cut covering the clip keeps nothing")
    checker.equal(
        kept([TimeRange(start: 6, end: 4)]), [TimeRange(start: 0, end: 10)], "a reversed cut is empty and ignored")
    checker.equal(
        kept([TimeRange(start: 0, end: 3)]), [TimeRange(start: 3, end: 10)], "a cut at the head leaves no empty range")
    checker.equal(
        kept([TimeRange(start: 7, end: 10)]), [TimeRange(start: 0, end: 7)], "a cut at the tail leaves no empty range")
    checker.equal(kept([], clips: [Clip(start: 5, end: 5)]), [], "an empty clip keeps nothing")
    checker.equal(
        kept([TimeRange(start: 4, end: 11)], clips: [Clip(start: 0, end: 5), Clip(start: 10, end: 15)]),
        [TimeRange(start: 0, end: 4), TimeRange(start: 11, end: 15)], "a cut applies to every clip it overlaps")
    checker.equal(
        Timeline.wholeRecording(duration: 12.5, clipID: clipID).keptRanges(), [TimeRange(start: 0, end: 12.5)],
        "a whole-recording timeline keeps all of it")

    checker.equal(trimmedTimeline.timelineTime(forSourceTime: 1.5), 0, "the first kept moment plays at zero")
    checker.equal(trimmedTimeline.timelineTime(forSourceTime: 3), 1.5, "source time shifts by the head trim")
    checker.equal(trimmedTimeline.timelineTime(forSourceTime: 0.5), nil, "a trimmed moment has no timeline time")
    checker.equal(trimmedTimeline.timelineTime(forSourceTime: 10), 8.5, "the last kept moment plays at the duration")
    checker.equal(trimmedTimeline.timelineTime(forSourceTime: 11), nil, "a moment after the tail trim is cut")
    checker.equal(trimmedTimeline.sourceTime(forTimelineTime: 0), 1.5, "timeline zero is the first kept moment")
    checker.equal(trimmedTimeline.sourceTime(forTimelineTime: 8.5), 10, "the duration maps to the last kept moment")
    checker.equal(trimmedTimeline.sourceTime(forTimelineTime: 9), nil, "past the duration is nowhere")
    checker.equal(trimmedTimeline.sourceTime(forTimelineTime: -1), nil, "before zero is nowhere")
    let midCut = Timeline(clips: [clip], cuts: [Cut(start: 4, end: 6, provenance: .manual)])
    checker.equal(midCut.sourceTime(forTimelineTime: 4), 4, "a shared boundary maps to the earlier range")
    checker.equal(midCut.sourceTime(forTimelineTime: 5), 7, "timeline time skips the cut")
    checker.equal(midCut.timelineTime(forSourceTime: 6), 4, "the moment after a cut follows the moment before it")
    checker.equal(midCut.timelineTime(forSourceTime: 5), nil, "inside the cut is nowhere")

    checker.equal(TimeRange(start: 3, end: 1).duration, 0, "a reversed range has no duration")
    checker.equal(TimeRange(start: 3, end: 1).closedRange, 3...3, "a reversed range collapses to its start")
    checker.equal(TimeRange(2...5), TimeRange(start: 2, end: 5), "a closed range converts")
    checker.check(TimeRange(start: 2, end: 5).contains(5), "a range contains its end")

    let auto = timelineSample.zoom.segments[0]
    var lockedAuto = auto
    lockedAuto.locked = true
    checker.check(auto.isReplaceableByReplan, "an unlocked auto segment is replaced by a replan")
    checker.check(!lockedAuto.isReplaceableByReplan, "a locked auto segment survives a replan")
    checker.check(!timelineSample.zoom.segments[1].isReplaceableByReplan, "a manual segment survives a replan")
    checker.close(auto.duration, 2.8, "a segment's duration is end minus start")
    checker.check(auto.contains(4) && !auto.contains(4.1), "a segment contains its end and not past it")
}

// MARK: - Provenance and segment source

@MainActor
private func checkProvenanceAndSource(_ checker: Checker) {
    do {
        let unknownProvenance = Data("{\"confidence\":0.9,\"kind\":\"aiScene\",\"model\":\"x\"}".utf8)
        let provenance = try PackageJSON.decode(Provenance.self, from: unknownProvenance)
        checker.equal(
            provenance, .unknown(kind: "aiScene", raw: ["confidence": 0.9, "kind": "aiScene", "model": "x"]),
            "an unknown provenance kind is kept with its whole object")
        checker.equal(
            text(try PackageJSON.encode(provenance)), text(unknownProvenance),
            "an unknown provenance re-encodes verbatim")
        let unknownSource = Data("{\"kind\":\"imported\",\"tool\":\"other\"}".utf8)
        let source = try PackageJSON.decode(ZoomSegmentSource.self, from: unknownSource)
        checker.equal(
            source, .unknown(kind: "imported", raw: ["kind": "imported", "tool": "other"]),
            "an unknown segment source is kept with its whole object")
        checker.equal(
            text(try PackageJSON.encode(source)), text(unknownSource), "an unknown source re-encodes verbatim")
        let segment = ZoomTrackSegment(
            id: autoSegmentID, start: 0, end: 1, focus: NormalizedPoint(x: 0, y: 0), amount: 2, source: source)
        checker.check(!segment.isReplaceableByReplan, "a segment of unknown source is treated as the user's")
        let sparseSegment = try PackageJSON.decode(
            ZoomTrackSegment.self,
            from: Data(
                ("{\"amount\":2,\"end\":1,\"focus\":{\"x\":0,\"y\":0},\"id\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\","
                    + "\"source\":{\"kind\":\"manual\"},\"start\":0}").utf8))
        checker.equal(sparseSegment.locked, false, "a segment without `locked` is unlocked")
        let cutWithUnknownKind = try PackageJSON.decode(
            Cut.self,
            from: Data(
                ("{\"end\":11,\"id\":\"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD\",\"provenance\":{\"kind\":\"aiScene\"},"
                    + "\"start\":10.5}").utf8))
        let timeline = Timeline(clips: [Clip(start: 10, end: 12)], cuts: [cutWithUnknownKind])
        checker.equal(
            timeline.keptRanges(), [TimeRange(start: 10, end: 10.5), TimeRange(start: 11, end: 12)],
            "a cut of unknown provenance still removes its span")
    } catch {
        checker.check(false, "provenance and source coding threw \(error)")
    }
}

// MARK: - Colors

@MainActor
private func checkKitColor(_ checker: Checker) {
    let navy = KitColor(rgb: 0x1C_2B_4B)
    checker.equal(KitColor(hex: "#1C2B4B"), navy, "a #RRGGBB color parses")
    checker.equal(KitColor(hex: "1c2b4b"), navy, "lower case without the hash parses too")
    checker.equal(navy.hex, "#1C2B4B", "an opaque color prints as #RRGGBB")
    checker.equal(navy.rgb, 0x1C_2B_4B, "the packed value reads back")
    checker.equal(KitColor(hex: "#1C2B4B80"), KitColor(rgb: 0x1C_2B_4B, alpha: 128), "a #RRGGBBAA color parses")
    checker.equal(KitColor(rgb: 0x1C_2B_4B, alpha: 128).hex, "#1C2B4B80", "a translucent color prints its alpha")
    checker.equal(KitColor(hex: "#12345"), nil, "five digits are not a color")
    checker.equal(KitColor(hex: "#GGGGGG"), nil, "non-hex digits are not a color")
    checker.equal(KitColor.white, KitColor(red: 255, green: 255, blue: 255), "white is all channels full")
    do {
        checker.equal(text(try PackageJSON.encode([navy])), "[\"#1C2B4B\"]", "a color encodes as a hex string")
        checker.equal(
            try PackageJSON.decode([KitColor].self, from: Data("[\"#4a1f5e\"]".utf8)), [KitColor(rgb: 0x4A_1F_5E)],
            "a hex string decodes")
    } catch {
        checker.check(false, "color coding threw \(error)")
    }
    checker.check(
        (try? PackageJSON.decode([KitColor].self, from: Data("[\"#xyz\"]".utf8))) == nil, "a bad color fails to decode")
}

// MARK: - Brand kit

@MainActor
private func checkBrandKit(_ checker: Checker) {
    let kit = BrandKit.default
    checker.equal(BrandKit.currentSchemaVersion, 1, "the kit schema version is 1")
    checker.equal(kit.schemaVersion, 1, "a new kit carries the current schema")
    checker.equal(BrandKit(), kit, "the default kit is a plain init")
    checker.equal(kit.cursor.spring, .mellow, "the cursor spring is the mellow preset")
    checker.equal(SpringStyle.mellow, SpringStyle(tension: 470, mass: 3, friction: 70), "mellow mirrors the engine")
    checker.equal(SpringStyle.snappy, SpringStyle(tension: 530, mass: 1, friction: 40), "snappy mirrors the engine")
    checker.equal(SpringStyle.drag, SpringStyle(tension: 1000, mass: 1, friction: 40), "drag mirrors the engine")
    checker.equal(SpringStyle.camera, SpringStyle(tension: 200, mass: 2.25, friction: 40), "camera mirrors the engine")
    checker.equal(kit.zoom.camera.spring, .camera, "the camera spring is the camera preset")
    checker.close(kit.cursor.minimumTravel, 1.0 / 1920, "minimum travel is one 1080p pixel")
    checker.equal(CursorStyle.scaleRange, 1...3, "the cursor scale range is 1 to 3")
    checker.equal(kit.frame.cornerRadius, 18, "the corner radius is RenderStyle's")
    checker.equal(kit.frame.shadow.opacity, 0.55, "the shadow opacity is RenderStyle's")
    checker.equal(kit.background.gradient.angleDegrees, 45, "the gradient angle is RenderStyle's")
    checker.equal(kit.typography, nil, "reserved groups are nil")
    do {
        checker.equal(text(try kit.jsonData()), kitFixture, "the default kit encodes to the pinned JSON")
        checker.equal(try BrandKit(jsonData: Data(kitFixture.utf8)), kit, "the pinned kit JSON decodes to the default")
        checker.equal(
            try BrandKit(jsonData: try kit.jsonData(prettyPrinted: true)), kit, "a pretty-printed kit decodes the same")
        checker.equal(try BrandKit(jsonData: Data("{}".utf8)), kit, "an empty kit takes every default")
        let sparse = try BrandKit(jsonData: Data("{\"frame\":{\"cornerRadius\":24},\"schemaVersion\":1}".utf8))
        checker.equal(sparse, styleSample, "a sparse kit takes the defaults for what it leaves out")
        let kitWithUnknowns =
            "{\"frame\":{\"cornerRadius\":24,\"glow\":1},\"schemaVersion\":1,\"typography\":{\"font\":\"Inter\"},"
            + "\"vendor\":\"x\"}"
        let decoded = try BrandKit(jsonData: Data(kitWithUnknowns.utf8))
        checker.equal(decoded.frame.extra, ["glow": 1], "unknown keys inside a group land in its extra")
        checker.equal(decoded.extra, ["vendor": "x"], "unknown top-level kit keys land in extra")
        checker.equal(decoded.typography, ["font": "Inter"], "a reserved group is kept as data")
        // Re-saved, the sparse kit is the full style sample plus its three
        // invented members, each where it was read.
        guard case .object(var expected) = try JSONValue(encoding: styleSample),
            case .object(var expectedFrame) = expected["frame"] ?? .null
        else {
            checker.check(false, "the style sample did not encode as an object")
            return
        }
        expectedFrame["glow"] = 1
        expected["frame"] = .object(expectedFrame)
        expected["typography"] = ["font": "Inter"]
        expected["vendor"] = "x"
        checker.equal(
            try JSONValue(encoding: decoded), .object(expected),
            "a kit with unknown fields re-saves JSON-equal, defaults filled in")
    } catch {
        checker.check(false, "kit JSON coding threw \(error)")
    }
}

// MARK: - Export settings

@MainActor
private func checkExportSettings(_ checker: Checker) {
    let settings = ExportSettings()
    checker.equal(settings.preset, .hd1080, "1080p is the default preset")
    checker.equal(settings.codec, nil, "the codec defaults to the preset's")
    checker.equal(settings.frameRate, 60, "60 fps is the default")
    checker.equal(ExportSettings.supportedFrameRates, [30, 60], "30 and 60 fps are offered")
    checker.equal(settings.audio.systemAudioGainDB, -6, "system audio sits 6 dB under the voice")
    checker.equal(ExportPresetID.hd1080.rawValue, "1080p", "the 1080p preset is spelled 1080p")
    checker.equal(ExportPresetID.uhd4K.rawValue, "4k", "the 4K preset is spelled 4k")
    do {
        checker.equal(
            text(try PackageJSON.encode(settings)),
            "{\"audio\":{\"microphoneGainDB\":0,\"systemAudioGainDB\":-6},\"frameRate\":60,\"preset\":\"1080p\"}",
            "default export settings leave the codec out")
        checker.equal(text(try PackageJSON.encode(exportSample)), exportFixture, "chosen export settings encode")
        checker.equal(
            try PackageJSON.decode(ExportSettings.self, from: Data("{}".utf8)), settings,
            "empty settings take the defaults")
        checker.equal(
            try PackageJSON.decode(ExportSettings.self, from: Data(exportFixture.utf8)), exportSample,
            "the export fixture decodes")
    } catch {
        checker.check(false, "export settings coding threw \(error)")
    }
}

// MARK: - Project

@MainActor
private func checkProject(_ checker: Checker) {
    checker.equal(Project.currentFormatVersion, 1, "the project format version is 1")
    checker.equal(Project.currentFormatVersion, CutsceneCore.projectFormatVersion, "it is the module's constant")
    let fresh = Project(recording: recordingSample)
    checker.equal(fresh.formatVersion, 1, "a new project carries the current format version")
    checker.equal(fresh.timeline.clips.count, 1, "a new project has one clip")
    checker.equal(fresh.timeline.keptRanges(), [TimeRange(start: 0, end: 12.5)], "the clip spans the recording")
    checker.equal(fresh.kit, .default, "the default kit is the snapshot")
    checker.equal(fresh.style, fresh.kit, "the style starts as the kit")
    checker.equal(fresh.kitReference, nil, "the built-in kit has no reference")
    checker.equal(fresh.export, ExportSettings(), "export settings start at the defaults")
    var running = recordingSample
    running.duration = nil
    running.state = .inProgress
    checker.equal(
        Project(recording: running).timeline.keptRanges(), [], "a project over a running take keeps nothing yet")

    do {
        checker.equal(
            text(try projectSample.jsonData()), projectFixture, "the project encodes to the pinned JSON (sorted keys)")
        checker.equal(
            try Project(jsonData: Data(projectFixture.utf8)), projectSample, "the pinned JSON decodes to the project")
        checker.equal(
            try Project(jsonData: try projectSample.jsonData(prettyPrinted: true)), projectSample,
            "a pretty-printed project decodes to the same project")
        checker.equal(
            try PackageJSON.decode(Project.self, from: Data(projectFixture.utf8)), projectSample,
            "a current-format document decodes without the migrator too")
        let sparse = try Project(jsonData: Data("{\"formatVersion\":1,\"recording\":\(recordingFixture)}".utf8))
        checker.equal(sparse.timeline, Timeline(), "a project without a timeline has an empty one")
        checker.equal(sparse.kit, .default, "a project without a kit has the default")
        checker.equal(sparse.style, .default, "a project without a style has the kit")
        let styled = try Project(
            jsonData: Data(
                "{\"formatVersion\":1,\"kit\":\(styleFixture),\"recording\":\(recordingFixture)}".utf8))
        checker.equal(styled.style, styleSample, "a project without a style takes its own kit, not the default")
    } catch {
        checker.check(false, "project JSON coding threw \(error)")
    }
}

// MARK: - Unknown keys

/// The pinned project with an invented field at every level this build
/// models, as a newer build might write it.
private let injectedFixture: String = {
    var json = projectFixture
    func inject(_ target: String, _ replacement: String) {
        precondition(json.contains(target), "injection target missing: \(target)")
        json = json.replacingOccurrences(of: target, with: replacement)
    }
    inject(
        "\"formatVersion\":1,\"kit\"",
        "\"formatVersion\":1,\"vendor\":{\"tool\":\"future\",\"tags\":[\"a\",1,null,2.5]},\"zeta\":true,\"kit\"")
    inject("\"clips\":[", "\"chapters\":[{\"t\":1}],\"clips\":[")
    inject(
        "\"id\":\"11111111-1111-1111-1111-111111111111\",\"start\":0}",
        "\"id\":\"11111111-1111-1111-1111-111111111111\",\"label\":\"take 1\",\"start\":0}")
    inject(
        "\"provenance\":{\"kind\":\"manual\"},\"start\":4}",
        "\"provenance\":{\"kind\":\"manual\"},\"reason\":\"um\",\"start\":4}")
    inject("\"planGeneration\":1,", "\"planGeneration\":1,\"planner\":\"v2\",")
    inject("\"locked\":true,", "\"locked\":true,\"note\":\"intro\",")
    inject("\"schemaVersion\":1,\"zoom\"", "\"schemaVersion\":1,\"typographyHint\":\"serif\",\"zoom\"")
    inject("\"opacity\":0.55}", "\"opacity\":0.55,\"spread\":2}")
    inject("\"startStrokeWidth\":2.5}", "\"startStrokeWidth\":2.5,\"glow\":true}")
    inject("\"sampleRate\":120,", "\"sampleRate\":120,\"smoothing\":\"spring\",")
    inject("\"usesFrameShadow\":true}", "\"usesFrameShadow\":true,\"zIndex\":3}")
    inject("\"angleDegrees\":45,", "\"angleDegrees\":45,\"dither\":true,")
    inject(
        "{\"friction\":70,\"mass\":3,\"tension\":470}",
        "{\"friction\":70,\"mass\":3,\"preset\":\"mellow\",\"tension\":470}")
    inject("\"preset\":\"4k\"}", "\"preset\":\"4k\",\"watermark\":\"corner\"}")
    inject("\"systemAudioGainDB\":-6}", "\"systemAudioGainDB\":-6,\"ducking\":true}")
    inject("{\"name\":\"Team\"}", "{\"name\":\"Team\",\"revision\":\"abc123\"}")
    inject("\"state\":\"complete\"", "\"state\":\"complete\",\"hdr\":false")
    return json
}()

/// Where each invented field sits and what it holds, for walking the saved
/// JSON. The kit groups are checked on both the snapshot and the style.
private let injectedPaths: [(path: [PathStep], value: JSONValue)] = [
    (["vendor"], ["tool": "future", "tags": ["a", 1, nil, 2.5]]),
    (["zeta"], true),
    (["timeline", "chapters"], [["t": 1]]),
    (["timeline", "clips", 0, "label"], "take 1"),
    (["timeline", "cuts", 2, "reason"], "um"),
    (["timeline", "zoom", "planner"], "v2"),
    (["timeline", "zoom", "segments", 1, "note"], "intro"),
    (["kit", "typographyHint"], "serif"),
    (["style", "typographyHint"], "serif"),
    (["kit", "frame", "shadow", "spread"], 2),
    (["style", "frame", "shadow", "spread"], 2),
    (["kit", "cursor", "click", "glow"], true),
    (["kit", "zoom", "camera", "smoothing"], "spring"),
    (["kit", "camera", "zIndex"], 3),
    (["kit", "background", "gradient", "dither"], true),
    (["kit", "cursor", "spring", "preset"], "mellow"),
    (["export", "watermark"], "corner"),
    (["export", "audio", "ducking"], true),
    (["kitReference", "revision"], "abc123"),
    (["recording", "hdr"], false),
]

/// An edit touching the style, the cuts, a zoom segment and the export.
private func edit(_ project: inout Project) {
    project.style.frame.cornerRadius = 30
    project.timeline.cuts.append(Cut(id: laterCutID, start: 11, end: 11.5, provenance: .manual))
    project.timeline.zoom.segments[0].start = 1
    project.export.frameRate = 60
}

@MainActor
private func checkEdits(_ saved: JSONValue, _ checker: Checker, label: String) {
    for (path, expected) in injectedPaths {
        checker.equal(value(at: path, in: saved), expected, "\(label): \(describe(path)) survives load, edit and save")
    }
    checker.equal(
        value(at: ["style", "frame", "cornerRadius"], in: saved)?.doubleValue, 30, "\(label): the style edit took")
    checker.equal(value(at: ["timeline", "cuts"], in: saved)?.arrayValue?.count, 7, "\(label): the added cut is saved")
    checker.equal(
        value(at: ["timeline", "zoom", "segments", 0, "start"], in: saved)?.doubleValue, 1,
        "\(label): the moved segment is saved")
    checker.equal(value(at: ["export", "frameRate"], in: saved)?.intValue, 60, "\(label): the export edit took")
    checker.equal(
        value(at: ["kit", "frame", "cornerRadius"], in: saved)?.doubleValue, 18,
        "\(label): the kit snapshot is untouched")
}

@MainActor
private func checkUnknownKeys(_ checker: Checker) {
    do {
        let loaded = try Project(jsonData: Data(injectedFixture.utf8))
        checker.equal(
            loaded.extra, ["vendor": ["tool": "future", "tags": ["a", 1, nil, 2.5]], "zeta": true],
            "unknown project keys land in extra")
        checker.equal(loaded.timeline.extra, ["chapters": [["t": 1]]], "unknown timeline keys land in its extra")
        checker.equal(loaded.timeline.clips[0].extra, ["label": "take 1"], "unknown clip keys land in its extra")
        checker.equal(loaded.timeline.cuts[2].extra, ["reason": "um"], "unknown cut keys land in its extra")
        checker.equal(loaded.timeline.zoom.extra, ["planner": "v2"], "unknown zoom-track keys land in its extra")
        checker.equal(
            loaded.timeline.zoom.segments[1].extra, ["note": "intro"], "unknown segment keys land in its extra")
        checker.equal(loaded.kit.extra, ["typographyHint": "serif"], "unknown kit keys land in its extra")
        checker.equal(loaded.style.extra, ["typographyHint": "serif"], "unknown style keys land in its extra")
        checker.equal(loaded.kit.frame.shadow.extra, ["spread": 2], "unknown shadow keys land in its extra")
        checker.equal(loaded.kit.cursor.click.extra, ["glow": true], "unknown ripple keys land in its extra")
        checker.equal(
            loaded.kit.zoom.camera.extra, ["smoothing": "spring"], "unknown camera-motion keys land in its extra")
        checker.equal(loaded.kit.camera.extra, ["zIndex": 3], "unknown bubble keys land in its extra")
        checker.equal(loaded.kit.background.gradient.extra, ["dither": true], "unknown gradient keys land in its extra")
        checker.equal(loaded.kit.cursor.spring.extra, ["preset": "mellow"], "unknown spring keys land in its extra")
        checker.equal(loaded.export.extra, ["watermark": "corner"], "unknown export keys land in its extra")
        checker.equal(loaded.export.audio.extra, ["ducking": true], "unknown audio keys land in its extra")
        checker.equal(
            loaded.kitReference?.extra, ["revision": "abc123"], "unknown kit-reference keys land in its extra")
        checker.equal(loaded.recording.extra, ["hdr": false], "unknown manifest keys land in its extra")
        checker.equal(
            loaded.timeline.keptRanges(), timelineSample.keptRanges(), "the known fields decode beside invented ones")
        checker.equal(loaded.style.frame.cornerRadius, 24, "the style decodes beside invented keys")
        checker.check(
            jsonObject(try loaded.jsonData()) == jsonObject(Data(injectedFixture.utf8)),
            "a project with invented fields at every level re-encodes JSON-equal (Foundation)")

        var edited = loaded
        edit(&edited)
        checkEdits(try JSONValue(jsonData: try edited.jsonData()), checker, label: "in memory")
    } catch {
        checker.check(false, "unknown-key round trip threw \(error)")
    }
}

// MARK: - Refusal

@MainActor
private func checkRefusal(_ checker: Checker) {
    let newer = projectFixture.replacingOccurrences(
        of: "\"formatVersion\":1,\"kit\"", with: "\"formatVersion\":99,\"kit\"")
    func projectError(_ body: () throws -> Void) -> ProjectFormatError? {
        do {
            try body()
            return nil
        } catch {
            return error as? ProjectFormatError
        }
    }
    checker.equal(
        projectError { _ = try Project(jsonData: Data(newer.utf8)) }, .unsupportedFormatVersion(99),
        "format version 99 is refused with a typed error")
    checker.equal(
        projectError { _ = try PackageJSON.decode(Project.self, from: Data(newer.utf8)) },
        .unsupportedFormatVersion(99),
        "the decoder refuses version 99 on its own too")
    checker.equal(
        projectError { _ = try Migrator.standard.migrate(JSONValue(jsonData: Data(newer.utf8))) },
        .unsupportedFormatVersion(99), "the migrator refuses version 99")
    checker.equal(
        projectError { _ = try Project(jsonData: Data("{\"recording\":\(recordingFixture)}".utf8)) },
        .missingFormatVersion, "a project without a format version is refused")
    checker.equal(
        projectError { _ = try Project(jsonData: Data("[1,2]".utf8)) }, .notAnObject,
        "a document that is not an object is refused")
    let newerKit = projectFixture.replacingOccurrences(
        of: "\"schemaVersion\":1,\"zoom\"", with: "\"schemaVersion\":99,\"zoom\"")
    checker.equal(
        projectError { _ = try Project(jsonData: Data(newerKit.utf8)) }, .unsupportedKitSchemaVersion(99),
        "a kit of schema 99 inside a project is refused")
    checker.equal(
        projectError { _ = try BrandKit(jsonData: Data("{\"schemaVersion\":99}".utf8)) },
        .unsupportedKitSchemaVersion(99), "a kit file of schema 99 is refused")
    checker.check(
        ProjectFormatError.unsupportedFormatVersion(99).errorDescription?.contains("99") == true,
        "the refusal names the version")
    checker.check(
        ProjectFormatError.unsupportedKitSchemaVersion(99).errorDescription?.contains("99") == true,
        "the kit refusal names the schema")
}

// MARK: - Migrator

@MainActor
private func checkMigrator(_ checker: Checker) {
    checker.equal(Migrator.standard.currentVersion, 1, "the standard chain ends at format 1")
    checker.equal(Migrator.standard.oldestReadableVersion, 1, "the standard chain starts at format 1")
    checker.equal(Migrator.standard.steps.count, 0, "format 1 has no steps")
    let rename = MigrationStep(fromVersion: 1, summary: "renames a to b") { object in
        var object = object
        object["b"] = object.removeValue(forKey: "a")
        return object
    }
    let addC = MigrationStep(fromVersion: 2, summary: "adds c") { object in
        var object = object
        object["c"] = .integer(Int64((object["b"]?.intValue ?? 0) + 1))
        return object
    }
    let migrator = Migrator(currentVersion: 3, steps: [addC, rename])
    checker.equal(
        migrator.steps.map(\.fromVersion), [1, 2], "steps are kept in version order, whatever order they come in")
    checker.equal(migrator.oldestReadableVersion, 1, "the oldest readable version is the first step's")
    checker.equal(rename.toVersion, 2, "a step lifts by one")
    func migrationError(_ migrator: Migrator, _ document: JSONValue) -> ProjectFormatError? {
        do {
            _ = try migrator.migrate(document)
            return nil
        } catch {
            return error as? ProjectFormatError
        }
    }
    do {
        let v1: JSONValue = ["formatVersion": 1, "a": 5]
        checker.equal(try Migrator.standard.migrate(v1), v1, "format 1 is the identity on the standard chain")
        checker.equal(
            try migrator.migrate(v1), ["formatVersion": 3, "b": 5, "c": 6],
            "a version-1 document goes through both steps in order and ends at the current version")
        checker.equal(
            try migrator.migrate(["formatVersion": 2, "b": 7]), ["formatVersion": 3, "b": 7, "c": 8],
            "a version-2 document goes through the second step only")
        let v3: JSONValue = ["formatVersion": 3, "b": 1, "c": 2]
        checker.equal(try migrator.migrate(v3), v3, "the current version passes through unchanged")
        checker.equal(
            try migrator.migrate(["formatVersion": 1.0, "a": 5]), ["formatVersion": 3, "b": 5, "c": 6],
            "an integral floating-point version counts")
    } catch {
        checker.check(false, "migration threw \(error)")
    }
    checker.equal(
        migrationError(migrator, ["formatVersion": 4]), .unsupportedFormatVersion(4), "a newer version is refused")
    checker.equal(
        migrationError(migrator, ["formatVersion": 0]), .unsupportedFormatVersion(0),
        "a version before the chain is refused")
    checker.equal(migrationError(migrator, ["a": 5]), .missingFormatVersion, "a document without a version is refused")
    checker.equal(
        migrationError(migrator, ["formatVersion": "1"]), .missingFormatVersion,
        "a version that is not an integer is refused")
    checker.equal(
        migrationError(migrator, ["formatVersion": 1.5]), .missingFormatVersion, "a fractional version is refused")
    checker.equal(migrationError(migrator, [1, 2]), .notAnObject, "an array is refused")
    checker.equal(migrationError(migrator, "x"), .notAnObject, "a scalar is refused")
    let gapped = Migrator(
        currentVersion: 4,
        steps: [rename, MigrationStep(fromVersion: 3, summary: "noop") { $0 }])
    checker.equal(
        migrationError(gapped, ["formatVersion": 1, "a": 5]), .missingMigrationStep(fromVersion: 2),
        "a hole in the chain is reported after the steps before it ran")
    checker.equal(
        migrationError(gapped, ["formatVersion": 2]), .missingMigrationStep(fromVersion: 2),
        "a document at the hole is reported at once")
    let failing = Migrator(
        currentVersion: 2,
        steps: [MigrationStep(fromVersion: 1, summary: "fails") { _ in throw ProjectFormatError.notAnObject }])
    checker.equal(
        migrationError(failing, ["formatVersion": 1]), .notAnObject, "a step's own error propagates")
}

// MARK: - Store

@MainActor
private func checkProjectStore(_ checker: Checker) {
    do {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try RecordingPackage.create(at: directory.appendingPathComponent("Store.cutscene"))
        let session1 = ProjectStore(package: package)
        checker.check(!session1.projectExists, "a fresh package has no project")
        checker.check(!session1.hasPreservedPrevious, "a fresh session has preserved nothing")
        checker.equal(try session1.loadPrevious(), nil, "there is no previous project to load")

        try session1.save(projectSample)
        let firstBytes = try Data(contentsOf: package.projectURL)
        checker.check(session1.projectExists, "the first save creates project.json")
        checker.check(
            !FileManager.default.fileExists(atPath: package.previousProjectURL.path),
            "a first save that creates the file preserves nothing")
        checker.check(session1.hasPreservedPrevious, "the session counts its first save as the preserving one")
        checker.equal(try session1.load(), projectSample, "the saved project loads back equal")
        checker.equal(
            try Project(jsonData: firstBytes), projectSample, "the file is the project, pretty-printed")
        checker.check(text(firstBytes).contains("\n  \"formatVersion\" : 1"), "the file on disk is pretty-printed")
        checker.equal(
            try PackageJSON.decode(Project.self, from: firstBytes), projectSample, "it decodes without the migrator")

        var edited = projectSample
        edit(&edited)
        try session1.save(edited)
        checker.check(
            !FileManager.default.fileExists(atPath: package.previousProjectURL.path),
            "a later save in the creating session still writes no .previous")
        checker.equal(try session1.load(), edited, "the second save replaced the file")
        let session1Bytes = try Data(contentsOf: package.projectURL)

        let session2 = ProjectStore(package: package)
        checker.check(session2.projectExists, "a new session sees the project")
        checker.equal(try session2.load(), edited, "a new session loads the last save")
        var edited2 = edited
        edited2.style.frame.cornerRadius = 40
        try session2.save(edited2)
        checker.equal(
            try Data(contentsOf: package.previousProjectURL), session1Bytes,
            "the first save of a session copies the opened file to .previous byte for byte")
        checker.equal(try session2.loadPrevious(), edited, "the previous project loads")
        var edited3 = edited2
        edited3.style.frame.cornerRadius = 50
        try session2.save(edited3)
        checker.equal(
            try Data(contentsOf: package.previousProjectURL), session1Bytes,
            ".previous is written once per session, not on every save")
        checker.equal(try session2.load(), edited3, "the last save is the file")

        // A newer build's file: unknown keys at every level, through the
        // store on disk.
        try Data(injectedFixture.utf8).write(to: package.projectURL)
        let session3 = ProjectStore(package: package)
        var loaded = try session3.load()
        checker.equal(loaded.kitReference?.extra, ["revision": "abc123"], "the store loads unknown keys")
        edit(&loaded)
        try session3.save(loaded)
        checkEdits(try JSONValue(jsonData: Data(contentsOf: package.projectURL)), checker, label: "on disk")
        checker.equal(
            try Data(contentsOf: package.previousProjectURL), Data(injectedFixture.utf8),
            "the newer build's file is preserved as .previous, byte for byte")

        // A refused file leaves a typed error through the store too.
        let newer = projectFixture.replacingOccurrences(
            of: "\"formatVersion\":1,\"kit\"", with: "\"formatVersion\":99,\"kit\"")
        try Data(newer.utf8).write(to: package.projectURL)
        var storeError: ProjectFormatError?
        do {
            _ = try ProjectStore(package: package).load()
        } catch {
            storeError = error as? ProjectFormatError
        }
        checker.equal(storeError, .unsupportedFormatVersion(99), "the store refuses version 99 with the typed error")
    } catch {
        checker.check(false, "the project store threw \(error)")
    }
}

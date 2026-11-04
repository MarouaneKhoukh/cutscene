import CutsceneCore
import Foundation

/// Recording-format checks: manifest, frame index and package layout (PLAN
/// M1-01). Registered empty by M1-00 so `main.swift` is edited once per
/// milestone rather than once per task; the owning task fills the body and
/// reports through the shared checker so the pass count stays one number.
@MainActor
func runRecordingFormatChecks(_ checker: Checker) {
    checkJSONValue(checker)
    checkManifest(checker)
    checkFrameIndex(checker)
    checkPackage(checker)
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

// MARK: - JSONValue

@MainActor
private func checkJSONValue(_ checker: Checker) {
    let tree: JSONValue = [
        "b": [1, 2.5, "x", nil, true, ["deep": [[]]]], "a": ["n": 9_223_372_036_854_775_807, "neg": -3],
    ]
    let pinned = "{\"a\":{\"n\":9223372036854775807,\"neg\":-3},\"b\":[1,2.5,\"x\",null,true,{\"deep\":[[]]}]}"
    do {
        checker.equal(text(try tree.jsonData()), pinned, "a JSONValue tree encodes with sorted keys and exact integers")
        checker.equal(try JSONValue(jsonData: Data(pinned.utf8)), tree, "the pinned JSON decodes to the same tree")
        checker.equal(
            try JSONValue(jsonData: try tree.jsonData(prettyPrinted: true)), tree,
            "a pretty-printed tree decodes to the same tree")
        checker.equal(try JSONValue(jsonData: Data("1.0".utf8)), .integer(1), "an integral number reads as an integer")
        checker.equal(try JSONValue(jsonData: Data("1.5".utf8)), .number(1.5), "a fraction reads as a number")
        checker.equal(try JSONValue(jsonData: Data("\"s\"".utf8)), .string("s"), "a bare string is accepted")
        checker.equal(
            try JSONValue(jsonData: Data("-9223372036854775808".utf8)), .integer(.min),
            "the smallest 64-bit integer survives exactly")
    } catch {
        checker.check(false, "JSONValue coding threw \(error)")
    }
    checker.equal(tree["a"]?["n"]?.intValue, Int.max, "paths walk objects and read exact integers")
    checker.equal(tree["a"]?["neg"]?.doubleValue, -3, "an integer reads as a double too")
    checker.equal(tree["b"]?[1]?.doubleValue, 2.5, "paths walk arrays")
    checker.equal(tree["b"]?[1]?.intValue, nil, "a fraction is not an integer")
    checker.equal(tree["b"]?[2]?.stringValue, "x", "strings read back")
    checker.equal(tree["b"]?[3]?.isNull, true, "null is a value, not a missing key")
    checker.equal(tree["b"]?[4]?.boolValue, true, "booleans read back")
    checker.equal(tree["b"]?[9], nil, "an index out of range is nil")
    checker.equal(tree["missing"], nil, "a missing key is nil")
    checker.equal(tree["b"]?["x"], nil, "a key on an array is nil")
    checker.equal(tree["b"]?[5]?["deep"]?.arrayValue?.count, 1, "nested containers read back")
    struct Row: Codable, Equatable {
        var id: Int
        var when: Date
    }
    do {
        let row = Row(id: 7, when: PackageJSON.date(from: "2026-11-03T10:15:30.250Z")!)
        let encoded = try JSONValue(encoding: row)
        checker.equal(
            encoded, ["id": 7, "when": "2026-11-03T10:15:30.250Z"],
            "init(encoding:) yields the package JSON of a value, dates as ISO 8601")
        checker.equal(try encoded.decoded(as: Row.self), row, "decoded(as:) is the inverse of init(encoding:)")
    } catch {
        checker.check(false, "JSONValue bridging threw \(error)")
    }
    checker.equal(
        PackageJSON.date(from: "2026-11-03T10:15:30Z"), PackageJSON.date(from: "2026-11-03T10:15:30.000Z"),
        "dates parse with and without fractional seconds")
    checker.equal(
        PackageJSON.date(from: "2026-11-03T11:15:30+01:00"), PackageJSON.date(from: "2026-11-03T10:15:30Z"),
        "dates parse with an offset")
    checker.equal(PackageJSON.date(from: "yesterday"), nil, "a non-date does not parse")
}

// MARK: - Manifest

private let manifestRecordingID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

private let manifestSample = RecordingManifest(
    recordingID: manifestRecordingID,
    createdAt: PackageJSON.date(from: "2026-11-03T10:15:30.250Z")!,
    source: .window(
        WindowSource(
            windowID: 1234, title: "brief.md", bundleID: "com.apple.Terminal", applicationName: "Terminal",
            frame: PointRect(x: 120, y: 80, width: 1440, height: 900), strategy: .displaySurface)),
    content: ContentGeometry(
        displayID: 1, displayBoundsPoints: PointRect(x: 0, y: 0, width: 1512, height: 982),
        captureRectPoints: PointRect(x: 0, y: 0, width: 1512, height: 982), pointPixelScale: 2),
    screen: ScreenTrackInfo(
        width: 3024, height: 1964, frameRate: 60, codec: "hevc",
        audioTracks: [
            AudioTrackInfo(source: .system, channelCount: 2),
            AudioTrackInfo(
                source: .microphone, channelCount: 1, deviceID: "BuiltInMicrophoneDevice",
                deviceName: "MacBook Pro Microphone"),
        ]),
    camera: CameraTrackInfo(
        width: 1920, height: 1080, frameRate: 30, codec: "hevc", deviceID: "FaceTimeHD",
        deviceName: "FaceTime HD Camera", isBuiltIn: true),
    state: .complete, stopReason: .userStopped, duration: 12.5)

private let manifestFixture = """
    {"camera":{"codec":"hevc","deviceID":"FaceTimeHD","deviceName":"FaceTime HD Camera","frameRate":30,"height":1080,\
    "isBuiltIn":true,"width":1920},\
    "content":{"captureRectPoints":{"height":982,"width":1512,"x":0,"y":0},\
    "displayBoundsPoints":{"height":982,"width":1512,"x":0,"y":0},"displayID":1,"pointPixelScale":2},\
    "createdAt":"2026-11-03T10:15:30.250Z","duration":12.5,"formatVersion":1,\
    "recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
    "screen":{"audioTracks":[{"channelCount":2,"source":"system"},\
    {"channelCount":1,"deviceID":"BuiltInMicrophoneDevice","deviceName":"MacBook Pro Microphone","source":"microphone"}],\
    "codec":"hevc","frameRate":60,"height":1964,"width":3024},\
    "source":{"kind":"window","window":{"applicationName":"Terminal","bundleID":"com.apple.Terminal",\
    "frame":{"height":900,"width":1440,"x":120,"y":80},"strategy":"displaySurface","title":"brief.md","windowID":1234}},\
    "state":"complete","stopReason":"userStopped"}
    """

/// A take still running: no camera, no stop reason, no duration.
private let inProgressSample = RecordingManifest(
    recordingID: manifestRecordingID,
    createdAt: PackageJSON.date(from: "2026-11-03T10:15:30Z")!,
    source: .display,
    content: ContentGeometry(
        displayID: 1, displayBoundsPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080),
        captureRectPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: 1),
    screen: ScreenTrackInfo(width: 1920, height: 1080, frameRate: 60, codec: "h264"))

private let inProgressFixture = """
    {"content":{"captureRectPoints":{"height":1080,"width":1920,"x":0,"y":0},\
    "displayBoundsPoints":{"height":1080,"width":1920,"x":0,"y":0},"displayID":1,"pointPixelScale":1},\
    "createdAt":"2026-11-03T10:15:30.000Z","formatVersion":1,"recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
    "screen":{"audioTracks":[],"codec":"h264","frameRate":60,"height":1080,"width":1920},\
    "source":{"kind":"display"},"state":"inProgress"}
    """

@MainActor
private func checkManifest(_ checker: Checker) {
    checker.equal(RecordingManifest.currentFormatVersion, 1, "the manifest format version is 1")
    checker.equal(manifestSample.formatVersion, 1, "a new manifest carries the current format version")
    checker.equal(manifestSample.source.label, "Terminal", "a window source is labelled by its application")
    checker.equal(CaptureSource.display.label, "Display", "a display source is labelled Display")
    checker.equal(CaptureSource.area.label, "Area", "an area source is labelled Area")
    checker.equal(
        CaptureSource.window(
            WindowSource(
                windowID: 1, title: "Notes", bundleID: "x", frame: PointRect(x: 0, y: 0, width: 1, height: 1),
                strategy: .pinnedFrame)
        ).label, "Notes", "a window without an application name is labelled by its title")

    do {
        checker.equal(
            text(try manifestSample.jsonData()), manifestFixture,
            "the manifest encodes to the pinned JSON (sorted keys, no pretty printing)")
        checker.equal(
            try RecordingManifest(jsonData: Data(manifestFixture.utf8)), manifestSample,
            "the manifest decodes from the pinned JSON")
        checker.equal(
            try RecordingManifest(jsonData: try manifestSample.jsonData(prettyPrinted: true)), manifestSample,
            "a pretty-printed manifest decodes to the same manifest")
        checker.equal(
            text(try inProgressSample.jsonData()), inProgressFixture,
            "an in-progress manifest leaves camera, stop reason and duration out")
        checker.equal(
            try RecordingManifest(jsonData: Data(inProgressFixture.utf8)), inProgressSample,
            "the in-progress fixture decodes")
    } catch {
        checker.check(false, "manifest JSON coding threw \(error)")
    }

    // Invented fields at three levels: beside the known keys of the
    // manifest, inside `screen`, and inside the window source. They come
    // back in `extra` and go out again, JSON-equal to what was read.
    let invented =
        manifestFixture
        .replacingOccurrences(
            of: "\"state\":\"complete\"",
            with: "\"state\":\"complete\",\"vendor\":{\"tool\":\"future\",\"tags\":[\"a\",1,null,2.5]},"
                + "\"zeta\":true"
        )
        .replacingOccurrences(
            of: "\"codec\":\"hevc\",\"frameRate\":60", with: "\"codec\":\"hevc\",\"frameRate\":60,\"hdr\":false"
        )
        .replacingOccurrences(
            of: "\"strategy\":\"displaySurface\"", with: "\"strategy\":\"displaySurface\",\"displayID\":7")
    do {
        let decoded = try RecordingManifest(jsonData: Data(invented.utf8))
        checker.equal(
            decoded.extra, ["vendor": ["tool": "future", "tags": ["a", 1, nil, 2.5]], "zeta": true],
            "unknown top-level keys land in extra, nested values intact")
        checker.equal(decoded.screen.extra, ["hdr": false], "unknown keys inside screen land in its extra")
        if case .window(let window) = decoded.source {
            checker.equal(window.extra, ["displayID": 7], "unknown keys inside the window source land in its extra")
        } else {
            checker.check(false, "the invented-field manifest lost its window source")
        }
        var known = decoded
        known.extra = [:]
        known.screen.extra = [:]
        if case .window(var window) = known.source {
            window.extra = [:]
            known.source = .window(window)
        }
        checker.equal(known, manifestSample, "the known fields decode unchanged beside invented ones")
        let reencoded = try decoded.jsonData()
        checker.check(
            jsonObject(reencoded) == jsonObject(Data(invented.utf8)),
            "invented fields at three levels survive decode then encode, JSON-equal (Foundation)")
        checker.equal(
            try JSONValue(jsonData: reencoded), try JSONValue(jsonData: Data(invented.utf8)),
            "invented fields survive decode then encode, JSON-equal (JSONValue)")
        checker.equal(
            try RecordingManifest(jsonData: reencoded), decoded, "a manifest with extras round-trips to itself")
        // A stray entry under a known key never shadows the typed field.
        var shadowed = manifestSample
        shadowed.extra = ["state": "bogus", "note": "kept"]
        let shadowedJSON = jsonObject(try shadowed.jsonData())
        checker.equal(
            shadowedJSON?["state"] as? String, "complete", "a typed field wins over an extra of the same name")
        checker.equal(shadowedJSON?["note"] as? String, "kept", "other extras set by hand are written")
    } catch {
        checker.check(false, "decoding the invented-field manifest threw \(error)")
    }

    let future = manifestFixture.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":99")
    do {
        _ = try RecordingManifest(jsonData: Data(future.utf8))
        checker.check(false, "a manifest from a newer format version must be refused")
    } catch let error as RecordingFormatError {
        checker.equal(error, .unsupportedManifestVersion(99), "the refused manifest version is reported")
    } catch {
        checker.check(false, "unexpected error for a newer manifest version: \(error)")
    }
    let foreignSource = inProgressFixture.replacingOccurrences(
        of: "\"kind\":\"display\"", with: "\"kind\":\"application\"")
    do {
        _ = try RecordingManifest(jsonData: Data(foreignSource.utf8))
        checker.check(false, "a manifest with an unknown source kind must be refused")
    } catch let error as RecordingFormatError {
        checker.equal(error, .unknownCaptureSourceKind("application"), "the unknown source kind is reported")
    } catch {
        checker.check(false, "unexpected error for an unknown source kind: \(error)")
    }
    let badDate = inProgressFixture.replacingOccurrences(of: "2026-11-03T10:15:30.000Z", with: "yesterday")
    checker.check(
        (try? RecordingManifest(jsonData: Data(badDate.utf8))) == nil, "a manifest with a malformed date is refused")

    // The commit point: inProgress written at start, complete written over
    // it at stop, each atomically, and read back through the package.
    do {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try RecordingPackage.create(at: directory.appendingPathComponent("Take.cutscene"))
        try package.writeManifest(inProgressSample)
        checker.equal(try package.manifest().state, .inProgress, "the manifest written at start reads back")
        try package.writeManifest(manifestSample)
        checker.equal(try package.manifest(), manifestSample, "the manifest rewritten at stop reads back")
        let onDisk = text(try Data(contentsOf: package.manifestURL))
        checker.check(onDisk.contains("\n  \"camera\""), "the manifest file is pretty-printed for people")
        checker.equal(
            try RecordingManifest(jsonData: Data(onDisk.utf8)), manifestSample,
            "the pretty file decodes to the manifest")
    } catch {
        checker.check(false, "manifest file round trip threw \(error)")
    }
}

// MARK: - Frame index

private let frameIndexFixture = """
    {"formatVersion":1,"k":"header","recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}
    {"br":[120,80,1440,900],"cr":[0,0,1512,982],"cs":2,"d":0,"n":0,"s":"started","sf":2,"sr":[0,0,1512,982],"t":0.0167}
    {"d":0.0167,"n":1,"s":"complete","t":0.0333}
    {"d":0.0333,"n":2,"s":"idle","t":0.05}
    {"br":[140,90,1440,900],"d":0.05,"n":3,"s":"complete","t":0.0667}
    {"k":"gap","t":0.0833}
    {"k":"hold","t":1}
    {"n":4,"s":"complete","t":1.0167}

    """

@MainActor
private func checkFrameIndex(_ checker: Checker) {
    let surface = PointRect(x: 0, y: 0, width: 1512, height: 982)
    let window = PointRect(x: 120, y: 80, width: 1440, height: 900)
    let moved = PointRect(x: 140, y: 90, width: 1440, height: 900)
    // Every frame carries the full geometry the recorder saw, as the
    // indexer hands it over; the writer is what makes the file sparse.
    let entries = [
        FrameIndexEntry(
            number: 0, time: 0.0167, displayTime: 0, status: .started, contentRect: surface, contentScale: 2,
            scaleFactor: 2, screenRect: surface, boundingRect: window),
        FrameIndexEntry(
            number: 1, time: 0.0333, displayTime: 0.0167, status: .complete, contentRect: surface, contentScale: 2,
            scaleFactor: 2, screenRect: surface, boundingRect: window),
        FrameIndexEntry(number: 2, time: 0.05, displayTime: 0.0333, status: .idle),
        FrameIndexEntry(
            number: 3, time: 0.0667, displayTime: 0.05, status: .complete, contentRect: surface, contentScale: 2,
            scaleFactor: 2, screenRect: surface, boundingRect: moved),
        FrameIndexEntry(number: 4, time: 1.0167),
    ]
    checker.equal(FrameIndexHeader.currentFormatVersion, 1, "the frame index format version is 1")

    do {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frames.jsonl")
        // No time-based flush, so the buffering itself is on the test.
        let settings = FrameIndexWriterSettings(maximumPendingLines: 60, flushInterval: 3600)
        let writer = try FrameIndexWriter(
            url: url, header: FrameIndexHeader(recordingID: manifestRecordingID), settings: settings)
        let headerLine = frameIndexFixture.split(separator: "\n", omittingEmptySubsequences: true)[0]
        checker.equal(
            text(try Data(contentsOf: url)), headerLine + "\n", "the header is on disk before the first frame")
        try writer.append(entries[0])
        try writer.append(entries[1])
        try writer.append(entries[2])
        try writer.append(entries[3])
        try writer.appendGap(at: 0.0833)
        try writer.appendHold(at: 1)
        try writer.append(entries[4])
        checker.equal(writer.linesWritten, 8, "the writer counts the header and every line")
        checker.equal(
            text(try Data(contentsOf: url)), headerLine + "\n",
            "lines under the pending limit wait in memory until a flush")
        try writer.close()
        try writer.close()
        let data = try Data(contentsOf: url)
        checker.equal(
            text(data), frameIndexFixture,
            "the index matches the pinned lines: geometry keys only on the frames where a value changed")
        checker.check(
            (try? writer.append(entries[4])) == nil, "appending after close fails rather than writing nowhere")

        let index = try FrameIndex.read(from: url)
        checker.equal(index.header.recordingID, manifestRecordingID, "the header reads back")
        checker.equal(index.lines.count, 7, "every line after the header reads back")
        checker.equal(index.truncatedAtLine, nil, "an intact file is not reported as truncated")
        checker.equal(index.holdTimes, [1], "hold lines read back with their time")
        checker.equal(index.gapTimes, [0.0833], "gap lines read back with their time")
        checker.equal(
            index.expectedMovieFrameCount, 4,
            "the movie holds complete and started frames plus holds minus gaps (3 + 1 + 1 - 1)")
        checker.equal(try index.jsonLines(), data, "an index re-encodes byte for byte")

        let sparse = index.frames(carryingGeometryForward: false)
        checker.equal(sparse.count, 5, "five frames read back")
        checker.equal(sparse[1].boundingRect, nil, "a repeated geometry value is absent from the stored entry")
        checker.equal(sparse[3].boundingRect, moved, "a changed geometry value is present")
        checker.equal(sparse[3].contentRect, nil, "unchanged keys beside a changed one stay absent")
        let filled = index.frames()
        checker.equal(filled[1].boundingRect, window, "carrying forward fills a repeated value from the last frame")
        checker.equal(filled[2].contentScale, 2, "an idle frame inherits the geometry too")
        checker.equal(filled[3].contentRect, surface, "unchanged keys are filled from the last frame that carried them")
        checker.equal(filled[3].boundingRect, moved, "the changed value is kept over the carried one")
        checker.equal(filled[4].boundingRect, moved, "the last change carries to the end")
        checker.equal(filled[4].displayTime, nil, "display time is never carried: it belongs to one frame")
        checker.equal(filled.map(\.number), [0, 1, 2, 3, 4], "frame numbers read back in order")
        checker.equal(filled.map(\.status), [.started, .complete, .idle, .complete, .complete], "statuses read back")
        checker.equal(
            filled.map { $0.status == .complete }, [false, true, false, true, true],
            "an open-set status compares with its constants")

        // A crash mid-write tears the last line; every complete line before
        // it is kept and the tear is reported.
        let torn = data.prefix(data.count - 12)
        let recovered = try FrameIndex(jsonLines: torn)
        checker.equal(recovered.lines.count, 6, "a torn last line yields every complete entry before it")
        checker.equal(recovered.truncatedAtLine, 7, "the torn line's position is reported")
        checker.equal(recovered.frames().map(\.number), [0, 1, 2, 3], "the frames before the tear are intact")
        let tornHeader = data.prefix(20)
        checker.check(
            (try? FrameIndex(jsonLines: tornHeader)) == nil, "a tear inside the header leaves nothing to read")
        checker.check((try? FrameIndex(jsonLines: Data())) == nil, "an empty file has no header")
        let noHeader = data.dropFirst(Int(headerLine.utf8.count) + 1)
        do {
            _ = try FrameIndex(jsonLines: noHeader)
            checker.check(false, "an index must start with its header")
        } catch let error as RecordingFormatError {
            checker.equal(error, .missingFrameIndexHeader, "a missing header is reported")
        }
        let futureHeader = Data(
            frameIndexFixture.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8)
        do {
            _ = try FrameIndex(jsonLines: futureHeader)
            checker.check(false, "an index from a newer format version must be refused")
        } catch let error as RecordingFormatError {
            checker.equal(error, .unsupportedFrameIndexVersion(2), "the refused index version is reported")
        }

        // A line kind this build does not know is kept and written back as it was.
        let foreignLine = "{\"k\":\"marker\",\"label\":\"take 2\",\"t\":2}"
        let extended = try FrameIndex(jsonLines: data + Data((foreignLine + "\n").utf8))
        checker.equal(extended.lines.count, 8, "an unknown line kind is kept, not dropped")
        checker.equal(
            extended.lines.last, .other(kind: "marker", raw: ["k": "marker", "label": "take 2", "t": 2]),
            "an unknown line decodes as .other with its kind and raw fields")
        checker.equal(
            text(try extended.jsonLines()), frameIndexFixture + foreignLine + "\n",
            "an unknown line re-encodes verbatim")
        checker.equal(extended.expectedMovieFrameCount, 4, "an unknown line does not count as a frame")

        // Flushing: a second writer with a one-line limit writes every line at once.
        let eagerURL = directory.appendingPathComponent("eager.jsonl")
        let eager = try FrameIndexWriter(
            url: eagerURL, header: FrameIndexHeader(recordingID: manifestRecordingID),
            settings: FrameIndexWriterSettings(maximumPendingLines: 1, flushInterval: 3600))
        try eager.append(entries[0])
        checker.equal(
            try FrameIndex.read(from: eagerURL).lines.count, 1, "a pending limit of one line writes every line at once")
        try eager.close()
        let timedURL = directory.appendingPathComponent("timed.jsonl")
        let timed = try FrameIndexWriter(
            url: timedURL, header: FrameIndexHeader(recordingID: manifestRecordingID),
            settings: FrameIndexWriterSettings(maximumPendingLines: 60, flushInterval: 0))
        try timed.append(entries[0])
        checker.equal(
            try FrameIndex.read(from: timedURL).lines.count, 1, "a zero flush interval writes every line at once")
        try timed.close()
    } catch {
        checker.check(false, "frame index checks threw \(error)")
    }
}

// MARK: - Package

@MainActor
private func checkPackage(_ checker: Checker) {
    checker.equal(RecordingPackage.pathExtension, "cutscene", "the package extension is stable")
    checker.equal(RecordingPackage.typeIdentifier, "app.cutscene.project", "the package UTI is stable")

    let base = URL(fileURLWithPath: "/Users/someone/Movies/Cutscene/Demo.cutscene", isDirectory: true)
    let package = RecordingPackage(url: base)
    func relative(_ url: URL) -> String {
        String(url.path.dropFirst(base.path.count))
    }
    checker.equal(package.url.path, base.path, "the package URL is the folder")
    checker.equal(relative(package.projectURL), "/project.json", "project.json sits at the top")
    checker.equal(relative(package.previousProjectURL), "/project.json.previous", "the previous project sits beside it")
    checker.equal(relative(package.recordingDirectory), "/recording", "the recording folder")
    checker.equal(relative(package.manifestURL), "/recording/manifest.json", "the manifest path")
    checker.equal(relative(package.screenMovieURL), "/recording/screen.mp4", "the finalized screen movie")
    checker.equal(relative(package.screenFragmentedMovieURL), "/recording/screen.mov", "the fragmented screen movie")
    checker.equal(relative(package.cameraMovieURL), "/recording/camera.mp4", "the camera movie")
    checker.equal(relative(package.cameraFragmentedMovieURL), "/recording/camera.mov", "the fragmented camera movie")
    checker.equal(relative(package.eventsURL), "/recording/events.json", "the event log")
    checker.equal(
        relative(package.eventsSidecarURL), "/recording/events.events.jsonl",
        "the sidecar name matches InputTelemetryRecorder.sidecarURL(for:)")
    checker.equal(relative(package.frameIndexURL), "/recording/frames.jsonl", "the frame index")
    checker.equal(relative(package.cursorsDirectory), "/recording/cursors", "the cursor sprites folder")
    checker.equal(
        relative(package.cursorSpriteURL(shapeID: "arrow")), "/recording/cursors/arrow.png", "a sprite by shape id")
    checker.equal(relative(package.transcriptURL), "/recording/transcript.json", "the reserved transcript")
    checker.equal(relative(package.thumbnailURL), "/thumbnail.jpg", "the poster")
    checker.equal(relative(package.derivedDirectory), "/derived", "the caches folder")
    checker.equal(
        RecordingPackage(url: URL(fileURLWithPath: "/Users/someone/Movies/./Cutscene/x/../Demo.cutscene")).url.path,
        base.path, "a package URL is standardized, so two spellings of one folder compare equal")

    checker.equal(
        RecordingPackage.defaultRecordingsDirectory.lastPathComponent, "Cutscene", "recordings go to Cutscene")
    checker.check(
        RecordingPackage.defaultRecordingsDirectory.path.hasSuffix("/Movies/Cutscene"),
        "the recordings folder is inside Movies")
    checker.equal(
        RecordingPackage.defaultExportsDirectory.deletingLastPathComponent().path,
        RecordingPackage.defaultRecordingsDirectory.path, "exports go inside the recordings folder")
    checker.equal(RecordingPackage.defaultExportsDirectory.lastPathComponent, "Exports", "the exports folder name")

    let utc = PackageNamingSettings(timeZone: TimeZone(identifier: "UTC")!)
    let createdAt = PackageJSON.date(from: "2026-11-03T10:15:30.250Z")!
    checker.equal(
        RecordingPackage.name(createdAt: createdAt, label: "Terminal", settings: utc),
        "2026-11-03 10.15.30 Terminal.cutscene", "packages are named <yyyy-MM-dd HH.mm.ss> <source>.cutscene")
    let tokyo = PackageNamingSettings(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    checker.equal(
        RecordingPackage.name(createdAt: createdAt, label: "Terminal", settings: tokyo),
        "2026-11-03 19.15.30 Terminal.cutscene", "the name uses the given time zone")
    let composed = RecordingPackage.url(
        createdAt: createdAt, source: .display, in: base.deletingLastPathComponent(), settings: utc)
    checker.equal(
        composed.path, "/Users/someone/Movies/Cutscene/2026-11-03 10.15.30 Display.cutscene",
        "the package URL composes the name")
    checker.equal(RecordingPackage.sanitizedLabel("a/b:c"), "a-b-c", "path separators become dashes")
    checker.equal(RecordingPackage.sanitizedLabel("  Notes \n"), "Notes", "newlines and surrounding spaces go")
    checker.equal(RecordingPackage.sanitizedLabel("   "), "Recording", "an empty label falls back")
    checker.equal(
        RecordingPackage.sanitizedLabel(String(repeating: "x", count: 100)).count, 40,
        "a long label is cut to the maximum")
    checker.equal(
        RecordingPackage.sanitizedLabel("Short", settings: PackageNamingSettings(maximumLabelLength: 3)), "Sho",
        "the maximum label length is a tunable")

    do {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proposed = directory.appendingPathComponent("Take.cutscene")
        checker.equal(RecordingPackage.availableURL(for: proposed), proposed, "a free name is used as is")
        checker.equal(RecordingPackage(url: proposed).exists, false, "a package does not exist before create")
        checker.check(
            (try? RecordingPackage.open(at: proposed)) == nil, "opening a missing package fails")
        let created = try RecordingPackage.create(at: proposed)
        checker.equal(created.exists, true, "create makes the package folder")
        var isDirectory: ObjCBool = false
        checker.check(
            FileManager.default.fileExists(atPath: created.cursorsDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue, "create makes recording/cursors")
        checker.check(
            !FileManager.default.fileExists(atPath: created.derivedDirectory.path),
            "create leaves derived/ for the first cache")
        checker.equal(try RecordingPackage.open(at: proposed), created, "open finds the created package")
        do {
            _ = try RecordingPackage.create(at: proposed)
            checker.check(false, "create must refuse an existing package")
        } catch let error as RecordingPackageError {
            checker.equal(error, .alreadyExists(created.url), "create reports the existing package")
        }
        let second = RecordingPackage.availableURL(for: proposed)
        checker.equal(second.lastPathComponent, "Take 2.cutscene", "a taken name gets a counter")
        _ = try RecordingPackage.create(at: second)
        checker.equal(
            RecordingPackage.availableURL(for: proposed).lastPathComponent, "Take 3.cutscene",
            "the counter skips every taken name")

        let tree: JSONValue = ["formatVersion": 1, "timeline": ["clips": [["start": 0, "end": 12.5]]], "note": nil]
        try created.writeJSON(tree, to: created.projectURL)
        checker.equal(try created.readJSON(JSONValue.self, from: created.projectURL), tree, "package JSON round-trips")
        let onDisk = text(try Data(contentsOf: created.projectURL))
        checker.check(onDisk.hasPrefix("{\n  \"formatVersion\" : 1"), "package JSON is pretty-printed with sorted keys")
        try created.writeJSON(tree, to: created.derivedDirectory.appendingPathComponent("cache.json"))
        checker.check(
            FileManager.default.fileExists(atPath: created.derivedDirectory.path),
            "writing into derived/ creates it on demand")
    } catch {
        checker.check(false, "package disk checks threw \(error)")
    }
}

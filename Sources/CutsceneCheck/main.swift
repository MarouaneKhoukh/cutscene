import CutsceneCore
import CutsceneEngine
import Foundation

/// Minimal check runner for the pure modules.
///
/// The Command Line Tools ship neither XCTest nor Swift Testing, so until
/// Xcode is the standard toolchain `make check` runs this executable instead.
/// Golden-vector checks for `CutsceneEngine` live here; the Swift Testing suite
/// under `Tests/` mirrors them for Xcode users and CI.
@MainActor
final class Checker {
    private(set) var failures = 0
    private(set) var passes = 0

    func check(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }

    func equal<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        check(actual == expected, "\(message): got \(actual), expected \(expected)", file: file, line: line)
    }

    func close(
        _ actual: Double, _ expected: Double, tolerance: Double = 1e-9, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        check(
            abs(actual - expected) <= tolerance,
            "\(message): got \(actual), expected \(expected) ± \(tolerance)", file: file, line: line)
    }
}

let checker = Checker()

// MARK: CutsceneCore

checker.equal(CutsceneCore.projectFormatVersion, 1, "project format version is stable")

// Event log. One log exercising every InputEvent case, and the exact JSON it
// must produce. The fixture pins the on-disk shape: renaming a field or
// changing its meaning is a format change and must bump
// `EventLog.currentFormatVersion`; a new kind is not, since older builds keep
// it through `.unknown`. The first eight events are the format-1 fixture.
let eventLogSample: EventLog = {
    var log = EventLog(
        recordingID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
        startHostTimeSeconds: 12345.5,
        captureRectPoints: PointRect(x: 100, y: 50, width: 1280, height: 720),
        displayID: 1,
        pointPixelScale: 2,
        samplingRateHz: 120
    )
    let point = NormalizedPoint(x: 0.5, y: 0.25)
    log.append(.pointerMoved(time: 0.125, position: point))
    log.append(.buttonDown(time: 0.25, position: point, button: .left))
    log.append(.buttonUp(time: 0.375, position: point, button: .other(2)))
    log.append(.keyDown(time: 0.5, keyCode: 36, modifiers: [.shift, .command], isRepeat: false))
    log.append(.keyUp(time: 0.625, keyCode: 36, modifiers: []))
    log.append(
        .cursorShapeChanged(
            time: 0.75,
            shape: CursorShape(
                id: "arrow", hotspot: NormalizedPoint(x: 0.3, y: 0.23), sizePoints: PointSize(width: 17, height: 23))))
    log.append(.takeMarker(time: 1, label: "take 2"))
    log.append(.takeMarker(time: 1.5, label: nil))
    // Format 2: global points on pointer events, scroll with and without
    // one, focus with and without a window, geometry, and a kind this build
    // does not know, with nested values that must come back as they went in.
    let global = GlobalPoint(x: 1180.5, y: 612)
    log.append(.pointerMoved(time: 1.55, position: point, global: global))
    log.append(.buttonDown(time: 1.6, position: point, button: .right, global: global))
    log.append(.scroll(time: 1.65, position: point, deltaX: 0, deltaY: -12.5, phase: .changed))
    log.append(.scroll(time: 1.7, position: point, deltaX: 3.25, deltaY: 0, phase: .momentumBegan, global: global))
    log.append(.focus(time: 1.75, bundleID: "com.apple.Terminal", windowID: 1234))
    log.append(.focus(time: 1.8, bundleID: "com.apple.finder", windowID: nil))
    log.append(.geometry(time: 1.85, windowID: 1234, frame: PointRect(x: 120, y: 80, width: 1440, height: 900)))
    log.append(
        .unknown(
            kind: "shell",
            raw: [
                "type": "shell", "time": 1.9, "command": "ls -la", "exitCode": 0, "args": ["ls", "-la"],
                "env": ["PATH": "/bin"], "ok": true, "none": .null,
            ]))
    return log
}()

let eventLogFormat1Fixture = """
    {"captureRectPoints":{"height":720,"width":1280,"x":100,"y":50},"displayID":1,"events":[\
    {"time":0.125,"type":"pointerMoved","x":0.5,"y":0.25},\
    {"button":"left","time":0.25,"type":"buttonDown","x":0.5,"y":0.25},\
    {"button":"other","buttonNumber":2,"time":0.375,"type":"buttonUp","x":0.5,"y":0.25},\
    {"isRepeat":false,"keyCode":36,"modifiers":["shift","command"],"time":0.5,"type":"keyDown"},\
    {"keyCode":36,"modifiers":[],"time":0.625,"type":"keyUp"},\
    {"heightPoints":23,"hotspotX":0.3,"hotspotY":0.23,"shapeID":"arrow","time":0.75,"type":"cursorShapeChanged",\
    "widthPoints":17},\
    {"label":"take 2","time":1,"type":"takeMarker"},\
    {"time":1.5,"type":"takeMarker"}],\
    "formatVersion":1,"pointPixelScale":2,"recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
    "samplingRateHz":120,"startHostTimeSeconds":12345.5}
    """

let eventLogFixture = """
    {"captureRectPoints":{"height":720,"width":1280,"x":100,"y":50},"displayID":1,"events":[\
    {"time":0.125,"type":"pointerMoved","x":0.5,"y":0.25},\
    {"button":"left","time":0.25,"type":"buttonDown","x":0.5,"y":0.25},\
    {"button":"other","buttonNumber":2,"time":0.375,"type":"buttonUp","x":0.5,"y":0.25},\
    {"isRepeat":false,"keyCode":36,"modifiers":["shift","command"],"time":0.5,"type":"keyDown"},\
    {"keyCode":36,"modifiers":[],"time":0.625,"type":"keyUp"},\
    {"heightPoints":23,"hotspotX":0.3,"hotspotY":0.23,"shapeID":"arrow","time":0.75,"type":"cursorShapeChanged",\
    "widthPoints":17},\
    {"label":"take 2","time":1,"type":"takeMarker"},\
    {"time":1.5,"type":"takeMarker"},\
    {"gx":1180.5,"gy":612,"time":1.55,"type":"pointerMoved","x":0.5,"y":0.25},\
    {"button":"right","gx":1180.5,"gy":612,"time":1.6,"type":"buttonDown","x":0.5,"y":0.25},\
    {"deltaX":0,"deltaY":-12.5,"phase":"changed","time":1.65,"type":"scroll","x":0.5,"y":0.25},\
    {"deltaX":3.25,"deltaY":0,"gx":1180.5,"gy":612,"phase":"momentumBegan","time":1.7,"type":"scroll","x":0.5,\
    "y":0.25},\
    {"bundleID":"com.apple.Terminal","time":1.75,"type":"focus","windowID":1234},\
    {"bundleID":"com.apple.finder","time":1.8,"type":"focus"},\
    {"frameHeight":900,"frameWidth":1440,"frameX":120,"frameY":80,"time":1.85,"type":"geometry","windowID":1234},\
    {"args":["ls","-la"],"command":"ls -la","env":{"PATH":"/bin"},"exitCode":0,"none":null,"ok":true,"time":1.9,\
    "type":"shell"}],\
    "formatVersion":2,"pointPixelScale":2,"recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
    "samplingRateHz":120,"startHostTimeSeconds":12345.5}
    """

checker.equal(EventLog.currentFormatVersion, 2, "event log format version is 2")
checker.equal(EventLog.oldestReadableFormatVersion, 1, "event logs are read back to format 1")
checker.equal(eventLogSample.formatVersion, 2, "a new event log carries format version 2")
checker.equal(
    eventLogSample.events.map(\.time),
    [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 1, 1.5, 1.55, 1.6, 1.65, 1.7, 1.75, 1.8, 1.85, 1.9],
    "time is exposed uniformly across event cases, the unknown kind's from its row")
checker.equal(
    eventLogSample.events.map { $0.position != nil },
    [true, true, true, false, false, false, false, false, true, true, true, true, false, false, false, false],
    "position is present only on pointer events, scroll included")
checker.equal(
    eventLogSample.events.map { $0.globalPosition != nil },
    [false, false, false, false, false, false, false, false, true, true, false, true, false, false, false, false],
    "the global point is present only where the recorder wrote one")

do {
    let encoded = String(decoding: try eventLogSample.jsonData(), as: UTF8.self)
    checker.equal(encoded, eventLogFixture, "event log encodes to the pinned JSON (sorted keys, no pretty printing)")
    let decoded = try EventLog(jsonData: Data(eventLogFixture.utf8))
    checker.equal(decoded, eventLogSample, "event log decodes from the pinned JSON fixture")
    let roundTripped = try EventLog(jsonData: try eventLogSample.jsonData())
    checker.equal(roundTripped, eventLogSample, "event log survives a JSON round trip with every event case")
    let pretty = try EventLog(jsonData: try eventLogSample.jsonData(prettyPrinted: true))
    checker.equal(pretty, eventLogSample, "pretty-printed event log decodes to the same log")
} catch {
    checker.check(false, "event log JSON coding threw \(error)")
}

do {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cutscene-check-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try eventLogSample.write(to: url)
    let read = try EventLog.read(from: url)
    checker.equal(read, eventLogSample, "event log survives write(to:) and read(from:)")
} catch {
    checker.check(false, "event log file round trip threw \(error)")
}

// A format-1 file is a format-2 file with fewer kinds: it decodes to the same
// events and writes back as format 2, byte for byte the old fixture with the
// new version number.
do {
    let upgraded = try EventLog(jsonData: Data(eventLogFormat1Fixture.utf8))
    checker.equal(upgraded.formatVersion, 2, "a format-1 log decodes as format 2")
    checker.equal(upgraded.events, Array(eventLogSample.events.prefix(8)), "format-1 events decode unchanged")
    checker.equal(
        String(decoding: try upgraded.jsonData(), as: UTF8.self),
        eventLogFormat1Fixture.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2"),
        "a format-1 log re-encodes as the pinned format-2 JSON")
} catch {
    checker.check(false, "decoding the format-1 fixture threw \(error)")
}

// Order: appends out of time order land in place, equal times keep arrival order.
var unorderedLog = EventLog(
    startHostTimeSeconds: 0, captureRectPoints: PointRect(x: 0, y: 0, width: 1, height: 1), displayID: 1,
    pointPixelScale: 1, samplingRateHz: 120)
unorderedLog.append(.takeMarker(time: 3, label: "c"))
unorderedLog.append(.takeMarker(time: 1, label: "a"))
unorderedLog.append(.takeMarker(time: 2, label: "b"))
unorderedLog.append(.takeMarker(time: 1, label: "a2"))
unorderedLog.append(contentsOf: [.takeMarker(time: 0.5, label: "start"), .takeMarker(time: 2, label: "b2")])
func markerLabels(_ events: [InputEvent]) -> [String?] {
    events.map { event in
        if case .takeMarker(_, let label) = event { return label }
        return nil
    }
}
checker.equal(unorderedLog.events.map(\.time), [0.5, 1, 1, 2, 2, 3], "events stay sorted after out-of-order appends")
checker.equal(
    markerLabels(unorderedLog.events), ["start", "a", "a2", "b", "b2", "c"], "simultaneous events keep arrival order")

// Decode guards: an unsorted file comes back sorted; a newer format is
// refused; an unknown event kind is kept and written back as it was read.
let unsortedFixture = """
    {"captureRectPoints":{"height":1,"width":1,"x":0,"y":0},"displayID":1,"events":[\
    {"label":"late","time":2,"type":"takeMarker"},{"label":"early","time":1,"type":"takeMarker"},\
    {"label":"early2","time":1,"type":"takeMarker"}],"formatVersion":1,"pointPixelScale":1,\
    "recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","samplingRateHz":120,"startHostTimeSeconds":0}
    """
do {
    let sorted = try EventLog(jsonData: Data(unsortedFixture.utf8))
    checker.equal(sorted.events.map(\.time), [1, 1, 2], "events are sorted on decode")
    checker.equal(markerLabels(sorted.events), ["early", "early2", "late"], "decode sort is stable")
} catch {
    checker.check(false, "decoding an unsorted event log threw \(error)")
}

let futureVersion = EventLog.currentFormatVersion + 1
let futureFixture = unsortedFixture.replacingOccurrences(
    of: "\"formatVersion\":1", with: "\"formatVersion\":\(futureVersion)")
do {
    _ = try EventLog(jsonData: Data(futureFixture.utf8))
    checker.check(false, "an event log from a newer format version must be refused")
} catch let error as EventLogError {
    checker.equal(error, .unsupportedFormatVersion(futureVersion), "the refused format version is reported")
} catch {
    checker.check(false, "unexpected error for a newer format version: \(error)")
}
let prehistoricFixture = unsortedFixture.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":0")
checker.check(
    (try? EventLog(jsonData: Data(prehistoricFixture.utf8))) == nil, "a format version below the first is refused")

// Unknown kinds round-trip: the rows are kept in time order, decode as
// `.unknown` with the row's `type` as the kind, and encode back JSON-equal to
// what was read, down to nested values and exact 64-bit integers.
func jsonEvents(_ text: String) -> NSArray? {
    ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary)?["events"] as? NSArray
}
let unknownTypeFixture = unsortedFixture.replacingOccurrences(of: "\"type\":\"takeMarker\"", with: "\"type\":\"shell\"")
do {
    let decoded = try EventLog(jsonData: Data(unknownTypeFixture.utf8))
    checker.equal(decoded.events.map(\.time), [1, 1, 2], "unknown kinds are kept and sorted, not dropped")
    checker.check(
        decoded.events.allSatisfy {
            if case .unknown(let kind, let raw) = $0 { return kind == "shell" && raw["type"] == "shell" }
            return false
        }, "unknown kinds decode as .unknown with the row's type as the kind")
    checker.equal(
        String(decoding: try decoded.jsonData(), as: UTF8.self),
        """
        {"captureRectPoints":{"height":1,"width":1,"x":0,"y":0},"displayID":1,"events":[\
        {"label":"early","time":1,"type":"shell"},{"label":"early2","time":1,"type":"shell"},\
        {"label":"late","time":2,"type":"shell"}],"formatVersion":2,"pointPixelScale":1,\
        "recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","samplingRateHz":120,"startHostTimeSeconds":0}
        """, "unknown kinds round-trip into the pinned JSON")
} catch {
    checker.check(false, "decoding unknown kinds threw \(error)")
}
let shellRow = #"{"type":"shell","time":1,"foo":"bar"}"#
let richRow = #"""
    {"type":"ssh","time":2,"big":9007199254740993,"neg":-3,"frac":0.1,"exp":1e3,"text":"héllo/wörld",\#
    "nested":{"a":[1,2.5,"x",false,null,{"b":[]}],"empty":{}}}
    """#
let unknownRowsFixture = """
    {"captureRectPoints":{"height":1,"width":1,"x":0,"y":0},"displayID":1,"events":[\(shellRow),\(richRow)],\
    "formatVersion":2,"pointPixelScale":1,"recordingID":"6F9619FF-8B86-D011-B42D-00C04FC964FF",\
    "samplingRateHz":120,"startHostTimeSeconds":0}
    """
do {
    let decoded = try EventLog(jsonData: Data(unknownRowsFixture.utf8))
    let reencoded = String(decoding: try decoded.jsonData(), as: UTF8.self)
    checker.check(
        reencoded.contains(#"{"foo":"bar","time":1,"type":"shell"}"#), "the shell row re-encodes with sorted keys")
    checker.check(
        jsonEvents(reencoded) != nil && jsonEvents(reencoded) == jsonEvents(unknownRowsFixture),
        "unknown rows round-trip JSON-equal, nested values and 64-bit integers included")
    checker.check(reencoded.contains("9007199254740993"), "a 64-bit integer in an unknown row keeps its exact value")
    checker.check(reencoded.contains(#""text":"héllo/wörld""#), "strings in an unknown row keep slashes and non-ASCII")
    if case .unknown(let kind, let raw) = decoded.events[1] {
        checker.equal(kind, "ssh", "the kind is the row's type")
        checker.equal(raw["big"], .integer(9_007_199_254_740_993), "integers decode exactly")
        checker.equal(raw["frac"], .number(0.1), "fractions decode as numbers")
        checker.equal(raw["nested"]?.doubleValue, nil, "doubleValue is nil for a non-number")
    } else {
        checker.check(false, "the rich row decodes as .unknown")
    }
    let line = try JSONDecoder().decode(InputEvent.self, from: Data(shellRow.utf8))
    checker.equal(
        line, .unknown(kind: "shell", raw: ["type": "shell", "time": 1, "foo": "bar"]), "a sidecar line decodes")
    checker.equal(line.position, nil, "an unknown kind carries no position")
    let lineEncoder = JSONEncoder()
    lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    checker.equal(
        String(decoding: try lineEncoder.encode(line), as: UTF8.self), #"{"foo":"bar","time":1,"type":"shell"}"#,
        "a sidecar line encodes back as the row it was")
} catch {
    checker.check(false, "unknown rows round trip threw \(error)")
}
// A built unknown event's `type` comes from its kind, and one without a
// numeric time has no place in the log.
do {
    let built = InputEvent.unknown(kind: "shell", raw: ["time": 3, "type": "stale"])
    checker.equal(built.time, 3, "a built unknown event reads its time from the row")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    checker.equal(
        String(decoding: try encoder.encode(built), as: UTF8.self), #"{"time":3,"type":"shell"}"#,
        "the kind wins over a stale type in the row")
    var log = eventLogSample
    checker.check(
        !log.append(.unknown(kind: "shell", raw: ["type": "shell"])), "an unknown event without a time is refused")
    checker.check(
        !log.append(.unknown(kind: "shell", raw: ["type": "shell", "time": "soon"])),
        "an unknown event with a non-numeric time is refused")
    checker.equal(log, eventLogSample, "refused unknown events leave the log unchanged")
} catch {
    checker.check(false, "encoding a built unknown event threw \(error)")
}
// Rows of a known kind are still read strictly: a missing time, a torn
// global point or a scroll phase this build does not know is refused.
let untimedUnknownFixture = unknownRowsFixture.replacingOccurrences(of: "\"time\":1,", with: "")
checker.check(
    (try? EventLog(jsonData: Data(untimedUnknownFixture.utf8))) == nil, "an unknown row without a time is refused")
let tornGlobalFixture = eventLogFixture.replacingOccurrences(
    of: "\"gx\":1180.5,\"gy\":612,\"time\":1.55", with: "\"gx\":1180.5,\"time\":1.55")
checker.check((try? EventLog(jsonData: Data(tornGlobalFixture.utf8))) == nil, "gx without gy is refused")
let unknownPhaseFixture = eventLogFixture.replacingOccurrences(of: "\"phase\":\"changed\"", with: "\"phase\":\"flung\"")
checker.check((try? EventLog(jsonData: Data(unknownPhaseFixture.utf8))) == nil, "unknown scroll phases are refused")
let unknownModifierFixture = eventLogFixture.replacingOccurrences(of: "\"shift\"", with: "\"hyper\"")
checker.check(
    (try? EventLog(jsonData: Data(unknownModifierFixture.utf8))) == nil, "unknown modifier names are refused")

// Times must be finite: a NaN would land at index 0 and make every later
// comparison false, so the sorted invariant would be gone without a word.
do {
    var log = eventLogSample
    checker.check(!log.append(.takeMarker(time: .nan, label: "nan")), "append refuses a NaN time")
    checker.check(!log.append(.takeMarker(time: .infinity, label: "inf")), "append refuses an infinite time")
    checker.equal(log, eventLogSample, "refused events leave the log unchanged")
    log.append(contentsOf: [.takeMarker(time: -.infinity, label: nil), .takeMarker(time: 2, label: "two")])
    checker.equal(
        log.events.count, eventLogSample.events.count + 1, "append(contentsOf:) drops only the non-finite event")
    checker.equal(log.events.last?.time, 2, "the finite event of the batch is in place")
    // JSON cannot spell NaN, so the decoder guard is reached through a
    // decoder that accepts a spelling for it.
    let lenient = JSONDecoder()
    lenient.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    let nanFixture = unsortedFixture.replacingOccurrences(of: "\"time\":2", with: "\"time\":\"nan\"")
    do {
        _ = try lenient.decode(EventLog.self, from: Data(nanFixture.utf8))
        checker.check(false, "a log with a NaN time must be refused")
    } catch let error as EventLogError {
        if case .invalidTime(let time) = error {
            checker.check(time.isNaN, "the refused time is reported")
        } else {
            checker.check(false, "unexpected event log error for a NaN time: \(error)")
        }
    } catch {
        checker.check(false, "unexpected error for a NaN time: \(error)")
    }
}

// MARK: CutsceneEngine

// Deterministic pseudo-random numbers for synthetic traces. A fixed seed, so
// every run of the checker sees the same trace.
struct TraceRandom {
    var state: UInt64

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}

/// Pointer samples along a straight line, at `rate` Hz, from `from` at `start` to `to` at `end`.
func linearMoves(
    from: NormalizedPoint, to: NormalizedPoint, start: Double, end: Double, rate: Double = 120
) -> [InputEvent] {
    let steps = max(Int(((end - start) * rate).rounded()), 1)
    return (0...steps).map { step in
        let t = Double(step) / Double(steps)
        return .pointerMoved(
            time: start + (end - start) * t,
            position: NormalizedPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    }
}

func click(at time: Double, _ position: NormalizedPoint, holdFor: Double = 0.08) -> [InputEvent] {
    [
        .buttonDown(time: time, position: position, button: .left),
        .buttonUp(time: time + holdFor, position: position, button: .left),
    ]
}

func pointDistance(_ a: NormalizedPoint, _ b: NormalizedPoint) -> Double {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
}

// Springs. Every preset released from displacement 1 must come to rest within
// 3 s at 60 Hz and land exactly on its target.
let springPresets: [(String, SpringParameters)] = [
    ("mellow", .mellow), ("slow", .slow), ("smooth", .smooth), ("fast", .fast),
    ("snappy", .snappy), ("drag", .drag), ("camera", .camera),
]
checker.equal(SpringParameters.mellow, SpringParameters(tension: 470, mass: 3.0, friction: 70), "mellow preset")
checker.equal(SpringParameters.slow, SpringParameters(tension: 200, mass: 2.25, friction: 40), "slow preset")
checker.equal(SpringParameters.smooth, SpringParameters(tension: 80, mass: 2.5, friction: 28), "smooth preset")
checker.equal(SpringParameters.fast, SpringParameters(tension: 380, mass: 1.0, friction: 30), "fast preset")
checker.equal(SpringParameters.snappy, SpringParameters(tension: 530, mass: 1.0, friction: 40), "snappy preset")
checker.equal(SpringParameters.drag, SpringParameters(tension: 1000, mass: 1.0, friction: 40), "drag preset")
checker.equal(SpringParameters.camera, SpringParameters(tension: 200, mass: 2.25, friction: 40), "camera preset")
checker.equal(Spring.restDisplacement, 1e-5, "rest snap displacement threshold")
checker.equal(Spring.restVelocity, 1e-4, "rest snap velocity threshold")
var restTimes: [String] = []
for (name, parameters) in springPresets {
    var spring = Spring(parameters: parameters, position: 1, target: 0)
    var restAfter: Double?
    for step in 1...180 {
        spring.step(by: 1.0 / 60)
        if spring.isAtRest {
            restAfter = Double(step) / 60
            break
        }
    }
    checker.check(
        restAfter != nil, "\(name) preset comes to rest within 3 s (at \(spring.position), \(spring.velocity))")
    checker.equal(spring.position, 0, "\(name) preset snaps exactly onto its target at rest")
    checker.equal(spring.velocity, 0, "\(name) preset has zero velocity at rest")
    checker.check(parameters.dampingRatio < 1, "\(name) preset is under-damped (ζ = \(parameters.dampingRatio))")
    restTimes.append("\(name) \(String(format: "%.3f", restAfter ?? .nan)) s")
}
print("spring rest times from displacement 1: " + restTimes.joined(separator: ", "))

// Critically and over-damped springs never cross their target. With tension
// 100 and mass 1, friction 20 is exactly ζ = 1 and friction 40 is ζ = 2.
for (name, friction) in [("critically damped", 20.0), ("over-damped", 40.0)] {
    let parameters = SpringParameters(tension: 100, mass: 1, friction: friction)
    var spring = Spring(parameters: parameters, position: 1, target: 0)
    var crossed = false
    var monotonic = true
    var previous = spring.position
    for _ in 1...600 {
        spring.step(by: 1.0 / 120)
        if spring.position < 0 { crossed = true }
        if spring.position > previous + 1e-12 { monotonic = false }
        previous = spring.position
    }
    checker.check(!crossed, "\(name) spring never overshoots its target")
    checker.check(monotonic, "\(name) spring approaches its target monotonically")
    checker.check(spring.isAtRest, "\(name) spring is at rest after 5 s")
}
checker.close(SpringParameters(tension: 100, mass: 1, friction: 20).dampingRatio, 1, "ζ = 1 for 100/1/20")

// The closed form must agree with a brute-force integration in every branch.
// Semi-implicit Euler at 10 µs is accurate to about 1e-4 over 0.1 s.
func eulerReference(_ parameters: SpringParameters, seconds: Double) -> (position: Double, velocity: Double) {
    let h = 1e-5
    var x = 1.0
    var v = 0.0
    for _ in 0..<Int((seconds / h).rounded()) {
        v += (-parameters.tension * x - parameters.friction * v) / parameters.mass * h
        x += v * h
    }
    return (x, v)
}
for (name, parameters) in [
    ("under-damped", SpringParameters.mellow),
    ("critically damped", SpringParameters(tension: 100, mass: 1, friction: 20)),
    ("over-damped", SpringParameters(tension: 100, mass: 1, friction: 40)),
] {
    var spring = Spring(parameters: parameters, position: 1, target: 0)
    for _ in 1...6 {
        spring.step(by: 1.0 / 60)
    }
    let reference = eulerReference(parameters, seconds: 0.1)
    checker.close(spring.position, reference.position, tolerance: 1e-3, "\(name) closed form matches Euler position")
    checker.close(spring.velocity, reference.velocity, tolerance: 1e-2, "\(name) closed form matches Euler velocity")
}

// The three branches meet: ζ just below, at and just above 1 give the same motion.
do {
    var positions: [Double] = []
    for friction in [20 * (1 - 2e-4), 20.0, 20 * (1 + 2e-4)] {
        var spring = Spring(
            parameters: SpringParameters(tension: 100, mass: 1, friction: friction), position: 1, target: 0)
        for _ in 1...12 {
            spring.step(by: 1.0 / 60)
        }
        positions.append(spring.position)
    }
    checker.close(positions[0], positions[1], tolerance: 1e-3, "under-damped branch meets the critical branch")
    checker.close(positions[2], positions[1], tolerance: 1e-3, "over-damped branch meets the critical branch")
}

// A step of zero or negative length is the identity; shared coefficients give
// the same result as stepping each spring alone.
do {
    var spring = Spring(parameters: .fast, position: 0.3, velocity: 2, target: 1)
    spring.step(by: 0)
    checker.equal(spring.position, 0.3, "a zero-length step leaves the position")
    checker.equal(spring.velocity, 2, "a zero-length step leaves the velocity")
    var pair = Spring2D(parameters: .smooth, position: NormalizedPoint(x: 0, y: 1), target: NormalizedPoint(x: 1, y: 0))
    var lone = Spring(parameters: .smooth, position: 0, target: 1)
    for _ in 1...30 {
        pair.step(by: 1.0 / 60)
        lone.step(by: 1.0 / 60)
    }
    checker.equal(pair.x.position, lone.position, "Spring2D x axis matches a lone spring")
    checker.close(pair.y.position, 1 - lone.position, "Spring2D y axis mirrors the x axis")
    for _ in 1...300 {
        pair.step(by: 1.0 / 60)
    }
    checker.check(pair.isAtRest, "Spring2D comes to rest")
    checker.equal(pair.position, NormalizedPoint(x: 1, y: 0), "Spring2D lands exactly on its target")
    checker.close(SpringParameters.mellow.phaseLag, 70.0 / 470, "phase lag is friction / tension")
}

// Easing.
checker.equal(Easing.smoothstep(0), 0, "smoothstep(0)")
checker.equal(Easing.smoothstep(1), 1, "smoothstep(1)")
checker.equal(Easing.smoothstep(0.5), 0.5, "smoothstep(0.5)")
checker.equal(Easing.smoothstep(-3), 0, "smoothstep clamps below")
checker.equal(Easing.smoothstep(7), 1, "smoothstep clamps above")
checker.close(Easing.smootherstep(0.3), 0.16308, "smootherstep(0.3) = 6t⁵ − 15t⁴ + 10t³")
checker.equal(Easing.smootherstep(0.5), 0.5, "smootherstep(0.5)")
checker.close(
    (Easing.smootherstep(1e-4) - Easing.smootherstep(0)) / 1e-4, 0, tolerance: 1e-6, "smootherstep is flat at 0")
checker.close(
    (Easing.smootherstep(1) - Easing.smootherstep(1 - 1e-4)) / 1e-4, 0, tolerance: 1e-6, "smootherstep is flat at 1")
checker.close(Easing.easeInOutCubic(0.25), 0.0625, "easeInOutCubic(0.25)")
checker.close(Easing.easeInOutCubic(0.75), 0.9375, "easeInOutCubic(0.75)")
checker.equal(Easing.easeInOutCubic(0.5), 0.5, "easeInOutCubic(0.5)")
checker.equal(Easing.lerp(2, 4, 0.25), 2.5, "lerp")
checker.equal(Easing.unlerp(2, 4, 2.5), 0.25, "unlerp")
checker.equal(Easing.unlerp(2, 2, 2), 1, "unlerp of an empty range is finished")
do {
    var filter = OnePoleLowPass(timeConstant: 0.13, initialValue: 0)
    filter.update(toward: 1, dt: 0.13)
    checker.close(filter.value, 1 - exp(-1), "one-pole filter covers 63% of a step in one time constant")
    var twice = OnePoleLowPass(timeConstant: 0.13, initialValue: 0)
    twice.update(toward: 1, dt: 0.065)
    twice.update(toward: 1, dt: 0.065)
    checker.close(twice.value, filter.value, "one-pole filter is independent of the step size")
    var snap = OnePoleLowPass(timeConstant: 0, initialValue: 0)
    snap.update(toward: 1, dt: 0.001)
    checker.equal(snap.value, 1, "a zero time constant snaps")
}

// Zoom planner: defaults from research brief §5.4.
let zoomDefaults = ZoomPlannerSettings()
checker.equal(zoomDefaults.leadIn, 0.3, "zoom lead-in default")
checker.equal(zoomDefaults.holdAfter, 2.5, "zoom hold default")
checker.equal(zoomDefaults.mergeGap, 2.5, "zoom merge gap default")
checker.equal(zoomDefaults.trailingIgnore, 1.0, "zoom trailing ignore default")
checker.equal(zoomDefaults.amount, 2.0, "zoom amount default")
checker.equal(zoomDefaults.typingBurstMinimumKeys, 3, "typing burst minimum keys default")
checker.equal(zoomDefaults.typingBurstMaximumGap, 0.5, "typing burst gap default")

// A 10 s trace with 4 clicks: the first two windows overlap, the third is
// 2.7 s after the merged window (over the merge gap), the fourth is inside
// the ignored last second.
let fourClicks: [InputEvent] =
    linearMoves(from: NormalizedPoint(x: 0.1, y: 0.1), to: NormalizedPoint(x: 0.2, y: 0.3), start: 0, end: 1)
    + click(at: 1.0, NormalizedPoint(x: 0.2, y: 0.3))
    + linearMoves(from: NormalizedPoint(x: 0.2, y: 0.3), to: NormalizedPoint(x: 0.4, y: 0.3), start: 1.1, end: 2)
    + click(at: 2.0, NormalizedPoint(x: 0.4, y: 0.3))
    + linearMoves(from: NormalizedPoint(x: 0.4, y: 0.3), to: NormalizedPoint(x: 0.8, y: 0.7), start: 2.1, end: 7.5)
    + click(at: 7.5, NormalizedPoint(x: 0.8, y: 0.7))
    + linearMoves(from: NormalizedPoint(x: 0.8, y: 0.7), to: NormalizedPoint(x: 0.5, y: 0.5), start: 7.6, end: 9.5)
    + click(at: 9.5, NormalizedPoint(x: 0.5, y: 0.5))
do {
    let segments = ZoomPlanner().plan(events: fourClicks, recordingEnd: 10)
    checker.equal(segments.count, 2, "4 clicks in 10 s give 2 segments")
    if segments.count == 2 {
        checker.close(segments[0].start, 0.7, "first segment starts 0.3 s before the first click")
        checker.close(segments[0].end, 4.5, "first segment holds 2.5 s after the second click")
        checker.close(segments[0].focus.x, 0.3, "merged focus x is the click-weighted center")
        checker.close(segments[0].focus.y, 0.3, "merged focus y is the click-weighted center")
        checker.equal(segments[0].amount, 2.0, "segment amount is the default 2×")
        checker.close(segments[1].start, 7.2, "second segment starts 0.3 s before the third click")
        checker.close(segments[1].end, 10.0, "second segment is clamped to the recording end")
        checker.equal(segments[1].focus, NormalizedPoint(x: 0.8, y: 0.7), "single-click focus is the click")
    }
    var tight = ZoomPlannerSettings()
    tight.mergeGap = 2.7
    let merged = ZoomPlanner(settings: tight).plan(events: fourClicks, recordingEnd: 10)
    checker.equal(merged.count, 1, "a merge gap of 2.7 s joins the third click")
    if let only = merged.first {
        checker.close(only.start, 0.7, "merged segment keeps the first start")
        checker.close(only.end, 10.0, "merged segment keeps the last end")
        checker.close(only.focus.x, (0.2 + 0.4 + 0.8) / 3, "three-click focus x")
        checker.close(only.focus.y, (0.3 + 0.3 + 0.7) / 3, "three-click focus y")
    }
    checker.equal(ZoomPlanner().plan(events: [], recordingEnd: 10), [], "no events, no segments")
    checker.equal(
        ZoomPlanner().plan(events: click(at: 9.2, NormalizedPoint(x: 0.5, y: 0.5)), recordingEnd: 10), [],
        "a click in the last second is the stop click and is ignored")
    let early = ZoomPlanner().plan(events: click(at: 0.1, NormalizedPoint(x: 0.5, y: 0.5)), recordingEnd: 10)
    checker.equal(early.first?.start, 0, "a segment never starts before the recording")
}

// Typing bursts: three non-modifier key-downs under 0.5 s apart anchor at the
// pointer's last position; pairs, modifier keys and the last second do not.
do {
    func key(_ time: Double, _ code: UInt16 = 0) -> InputEvent {
        .keyDown(time: time, keyCode: code, modifiers: [], isRepeat: false)
    }
    let typing: [InputEvent] = [
        .pointerMoved(time: 0.5, position: NormalizedPoint(x: 0.6, y: 0.4)),
        key(1.0), key(1.3), key(1.6),
        key(6.0), key(6.6),
        key(7.0, 56), key(7.1, 56), key(7.2, 56),
        key(9.2), key(9.3), key(9.4),
    ]
    let segments = ZoomPlanner().plan(events: typing, recordingEnd: 10)
    checker.equal(segments.count, 1, "only the real burst makes a segment")
    if let burst = segments.first {
        checker.close(burst.start, 0.7, "burst segment starts 0.3 s before the first key")
        checker.close(burst.end, 4.1, "burst segment holds 2.5 s after the last key")
        checker.equal(burst.focus, NormalizedPoint(x: 0.6, y: 0.4), "burst anchors at the last pointer position")
    }
    var noTyping = ZoomPlannerSettings()
    noTyping.detectsTypingBursts = false
    checker.equal(
        ZoomPlanner(settings: noTyping).plan(events: typing, recordingEnd: 10), [], "typing can be turned off")
    let mixed: [InputEvent] =
        click(at: 1.0, NormalizedPoint(x: 0.2, y: 0.2)) + [
            .pointerMoved(time: 2.5, position: NormalizedPoint(x: 0.6, y: 0.6))
        ]
        + [key(3.0), key(3.2), key(3.4)]
    let merged = ZoomPlanner().plan(events: mixed, recordingEnd: 10)
    checker.equal(merged.count, 1, "a click and an overlapping burst merge")
    if let only = merged.first {
        checker.close(only.start, 0.7, "merged click+burst start")
        checker.close(only.end, 5.9, "merged click+burst end")
        checker.close(only.focus.x, 0.4, "click and burst each count once in the focus")
    }
    // Auto-repeat is a held key: alone it makes no burst, inside one it
    // extends the hold without counting as typing.
    func repeated(_ time: Double) -> InputEvent {
        .keyDown(time: time, keyCode: 125, modifiers: [], isRepeat: true)
    }
    let heldArrow = [key(0.7, 125)] + (1...29).map { repeated(0.7 + Double($0) * 0.033) }
    checker.equal(ZoomPlanner().plan(events: heldArrow, recordingEnd: 10), [], "a held arrow key is not a typing burst")
    let burstThenHold = [key(1.0), key(1.2), key(1.4)] + (1...10).map { repeated(1.4 + Double($0) * 0.1) }
    let extended = ZoomPlanner().plan(events: burstThenHold, recordingEnd: 10)
    checker.equal(extended.count, 1, "repeats inside a burst do not split it")
    checker.close(extended.first?.end ?? -1, 2.4 + 2.5, "repeats inside a burst extend its hold")
    let twoThenHold = [key(1.0), key(1.2)] + (1...10).map { repeated(1.2 + Double($0) * 0.1) }
    checker.equal(ZoomPlanner().plan(events: twoThenHold, recordingEnd: 10), [], "repeats do not count toward a burst")
}

// Events before time zero (a log offset by another tool) are not anchors, so
// no segment can end before it starts.
do {
    let center = NormalizedPoint(x: 0.5, y: 0.5)
    checker.equal(
        ZoomPlanner().plan(events: [.buttonDown(time: -3, position: center, button: .left)], recordingEnd: 10), [],
        "a click before the recording is not an anchor")
    let straddling = ZoomPlanner().plan(events: click(at: -0.1, center) + click(at: 1, center), recordingEnd: 10)
    checker.equal(straddling.count, 1, "only the click inside the recording anchors a segment")
    checker.check(straddling.allSatisfy { $0.end >= $0.start }, "no segment runs backwards")
}

// Cursor smoother: defaults from research brief §5.3.
let cursorDefaults = CursorSmootherSettings()
checker.equal(cursorDefaults.sampleRate, 60, "cursor sample rate default")
checker.equal(cursorDefaults.spring, .mellow, "cursor spring default")
checker.equal(cursorDefaults.clickSpring, .snappy, "click spring default")
checker.equal(cursorDefaults.dragSpring, .drag, "drag spring default")
checker.equal(cursorDefaults.shakeLegThreshold, 0.015, "shake leg threshold default")
checker.equal(cursorDefaults.shakeWindow, 0.1, "shake window default")
checker.equal(cursorDefaults.maximumInputRate, 60, "input decimation default")
checker.equal(cursorDefaults.leadTimeConstant, 0.13, "lead easing default")
checker.equal(cursorDefaults.clickAnticipationWindow, 0.5, "click anticipation default")
checker.equal(cursorDefaults.clickSpringLead, 0.175, "click spring lead default")
checker.equal(cursorDefaults.idleHoldGap, 0.067, "idle hold gap default")
checker.equal(cursorDefaults.settleTimeout, 5, "settle timeout default")
checker.equal(cursorDefaults.idleFadeDelay, 2, "idle fade delay default")
checker.equal(cursorDefaults.fadeOutDuration, 0.4, "fade out default")
checker.equal(cursorDefaults.fadeInLead, 0.25, "fade in lead default")
checker.equal(cursorDefaults.pressScale, 0.8, "press scale default")
checker.equal(cursorDefaults.pressScaleDuration, 0.13, "press scale duration default")

// A still pointer: smoothed equals raw, and the cursor fades out after 2 s.
do {
    let still = CursorSmoother().timeline(
        events: [.pointerMoved(time: 0, position: NormalizedPoint(x: 0.3, y: 0.7))], duration: 4)
    checker.equal(still.samples.count, 241, "60 Hz over 4 s is 241 samples")
    checker.equal(still.duration, 4, "timeline duration")
    checker.check(
        still.samples.allSatisfy {
            $0.smoothedPosition == $0.rawPosition && $0.rawPosition == NormalizedPoint(x: 0.3, y: 0.7)
        },
        "a still pointer stays exactly where it is")
    checker.equal(still.sample(at: 1.0)?.opacity, 1, "visible while idle under 2 s")
    checker.equal(still.sample(at: 2.0)?.opacity, 1, "fade starts at 2 s idle")
    checker.close(still.sample(at: 2.2)?.opacity ?? -1, 0.5, "half faded 200 ms into the 400 ms fade")
    checker.equal(still.sample(at: 2.4)?.opacity, 0, "gone after the 400 ms fade")
    checker.equal(still.sample(at: 3.5)?.opacity, 0, "stays hidden while idle")
    checker.check(still.samples.allSatisfy { $0.scale == 1 && !$0.isPressed }, "no press, no scaling")
}

// A step move: the spring reaches the new position, and the lead starts it
// slightly before the raw jump.
do {
    let step: [InputEvent] = [
        .pointerMoved(time: 0, position: NormalizedPoint(x: 0.2, y: 0.2)),
        .pointerMoved(time: 1.0, position: NormalizedPoint(x: 0.8, y: 0.8)),
    ]
    let timeline = CursorSmoother().timeline(events: step, duration: 3)
    checker.equal(
        timeline.sample(at: 0.5)?.smoothedPosition, NormalizedPoint(x: 0.2, y: 0.2), "at rest before the move")
    checker.equal(
        timeline.sample(at: 0.5)?.rawPosition, NormalizedPoint(x: 0.2, y: 0.2), "raw holds across the idle gap")
    checker.equal(timeline.sample(at: 1.0)?.rawPosition, NormalizedPoint(x: 0.8, y: 0.8), "raw jumps at the event")
    // The lead is friction/tension = 149 ms, so the spring sits still until
    // 0.851 s and is under way, but not there, when the raw pointer jumps.
    checker.equal(
        timeline.sample(at: 0.84)?.smoothedPosition, NormalizedPoint(x: 0.2, y: 0.2), "at rest until the lead window")
    let before = timeline.sample(at: 0.95)!.smoothedPosition
    checker.check(
        before.x > 0.2 && before.x < 0.8, "the phase lead starts the spring before the raw jump (x = \(before.x))")
    checker.equal(
        timeline.sample(at: 2.5)?.smoothedPosition, NormalizedPoint(x: 0.8, y: 0.8), "settled on the new position")
}

// Phase-lead compensation: at constant velocity the smoothed cursor rides on
// the raw one instead of trailing it by friction/tension seconds.
do {
    let glide = linearMoves(
        from: NormalizedPoint(x: 0.1, y: 0.5), to: NormalizedPoint(x: 0.7, y: 0.5), start: 0, end: 2)
    let timeline = CursorSmoother().timeline(events: glide, duration: 2)
    var worst = 0.0
    for sample in timeline.samples where sample.time >= 1.0 && sample.time <= 1.8 {
        worst = max(worst, pointDistance(sample.smoothedPosition, sample.rawPosition))
    }
    let uncompensatedLag = SpringParameters.mellow.phaseLag * 0.3
    // Reading the target at the start of a step instead of its midpoint would
    // lag by dt/2 × v = 0.0025 here, so the bound pins the midpoint read too.
    checker.check(worst < 0.001, "steady-state tracking error \(worst) is far below the raw lag \(uncompensatedLag)")
    print("glide: steady-state tracking error \(String(format: "%.6f", worst)) of the frame")
}

// Click anticipation and press feedback: the cursor is on the click point when
// the click lands, shrinks to 0.8× over 130 ms and recovers after release.
do {
    let approach =
        linearMoves(from: NormalizedPoint(x: 0.1, y: 0.5), to: NormalizedPoint(x: 0.9, y: 0.5), start: 0, end: 2)
        + click(at: 2.0, NormalizedPoint(x: 0.9, y: 0.5), holdFor: 0.5)
    let timeline = CursorSmoother().timeline(events: approach, duration: 3)
    let atClick = timeline.sample(at: 2.0)!
    checker.check(
        pointDistance(atClick.smoothedPosition, NormalizedPoint(x: 0.9, y: 0.5)) < 0.01,
        "smoothed cursor is on the click point at click time (\(atClick.smoothedPosition))")
    checker.equal(timeline.sample(at: 1.9)?.isPressed, false, "not pressed before the click")
    checker.equal(timeline.sample(at: 2.0)?.isPressed, true, "pressed from the button-down sample")
    checker.equal(timeline.sample(at: 2.45)?.isPressed, true, "pressed while held")
    checker.equal(timeline.sample(at: 2.5)?.isPressed, false, "released at button-up")
    checker.equal(timeline.samples[120].time, 2.0, "sample 120 is the click sample")
    checker.check(
        timeline.samples[124].scale < 0.95 && timeline.samples[124].scale > 0.8, "shrinking 67 ms after the press")
    checker.close(timeline.samples[128].scale, 0.8, tolerance: 1e-12, "fully shrunk 133 ms after the press")
    checker.equal(timeline.sample(at: 2.4)?.scale, 0.8, "stays shrunk while held")
    checker.equal(timeline.sample(at: 2.7)?.scale, 1, "back to full size 200 ms after release")
    // During the hold the drag spring is active; it tracks a dragged pointer closely.
    let dragTrace =
        [InputEvent.buttonDown(time: 0, position: NormalizedPoint(x: 0.2, y: 0.5), button: .left)]
        + linearMoves(from: NormalizedPoint(x: 0.2, y: 0.5), to: NormalizedPoint(x: 0.8, y: 0.5), start: 0, end: 2)
        + [.buttonUp(time: 2.0, position: NormalizedPoint(x: 0.8, y: 0.5), button: .left)]
    let drag = CursorSmoother().timeline(events: dragTrace, duration: 2)
    var dragError = 0.0
    for sample in drag.samples where sample.time >= 0.5 && sample.time <= 1.8 {
        dragError = max(dragError, pointDistance(sample.smoothedPosition, sample.rawPosition))
    }
    checker.check(dragError < 0.003, "dragging tracks the raw pointer (worst error \(dragError))")
}

// A drag followed by a click within the anticipation window: the held button
// wins, so the cursor stays on the drag path until the release and only then
// heads for the click point.
do {
    let dragEnd = NormalizedPoint(x: 0.8, y: 0.5)
    let clickPoint = NormalizedPoint(x: 0.2, y: 0.9)
    let dragThenClick =
        [InputEvent.buttonDown(time: 0, position: NormalizedPoint(x: 0.2, y: 0.5), button: .left)]
        + linearMoves(from: NormalizedPoint(x: 0.2, y: 0.5), to: dragEnd, start: 0, end: 1)
        + [.buttonUp(time: 1.0, position: dragEnd, button: .left)]
        + click(at: 1.3, clickPoint)
    let timeline = CursorSmoother().timeline(events: dragThenClick, duration: 2)
    var worst = 0.0
    for sample in timeline.samples where sample.time >= 0.3 && sample.time <= 1.0 {
        worst = max(worst, pointDistance(sample.smoothedPosition, sample.rawPosition))
    }
    checker.check(worst < 0.01, "a drag stays on the drag path although a click follows within 0.5 s (worst \(worst))")
    let atClick = timeline.sample(at: 1.3)!.smoothedPosition
    checker.check(
        pointDistance(atClick, clickPoint) < pointDistance(atClick, dragEnd),
        "after the release the cursor heads for the click point (\(atClick))")
}

// A held button with the pointer still is not idle: the cursor stays visible
// and shrunk through a 5 s press, and fades only after the release.
do {
    let point = NormalizedPoint(x: 0.4, y: 0.6)
    let hold: [InputEvent] = [
        .pointerMoved(time: 0, position: point),
        .buttonDown(time: 1.0, position: point, button: .left),
        .buttonUp(time: 6.0, position: point, button: .left),
    ]
    let timeline = CursorSmoother().timeline(events: hold, duration: 9)
    checker.check(
        timeline.samples.filter { $0.time >= 1.0 && $0.time < 6.0 }.allSatisfy { $0.opacity == 1 && $0.isPressed },
        "the cursor stays visible and pressed through a 5 s hold")
    checker.equal(timeline.sample(at: 5.5)?.scale, 0.8, "shrunk while held")
    checker.equal(timeline.sample(at: 7.9)?.opacity, 1, "visible until 2 s after the release")
    checker.equal(timeline.sample(at: 8.5)?.opacity, 0, "faded out 2.4 s after the release")
}

// The settle timeout must not fire inside the lead window: a move after a
// long idle plays out exactly like the same move after a short one, with no
// teleport onto the lead target while the cursor fades in.
do {
    let from = NormalizedPoint(x: 0.2, y: 0.2)
    let to = NormalizedPoint(x: 0.8, y: 0.8)
    let early = CursorSmoother().timeline(
        events: [.pointerMoved(time: 0, position: from), .pointerMoved(time: 1.0, position: to)], duration: 3)
    let late = CursorSmoother().timeline(
        events: [.pointerMoved(time: 0, position: from), .pointerMoved(time: 6.0, position: to)], duration: 8)
    var worst = 0.0
    for sample in late.samples where sample.time >= 5.5 {
        worst = max(
            worst, pointDistance(sample.smoothedPosition, early.sample(at: sample.time - 5.0)!.smoothedPosition))
    }
    checker.check(worst < 1e-6, "a move at 6 s follows the same path as a move at 1 s (worst difference \(worst))")
    var largestStep = 0.0
    for (a, b) in zip(late.samples, late.samples.dropFirst()) where b.time < 6.0 {
        largestStep = max(largestStep, pointDistance(a.smoothedPosition, b.smoothedPosition))
    }
    checker.check(largestStep < 0.1, "no teleport before the raw motion starts (largest step \(largestStep))")
    checker.check(late.sample(at: 5.9)!.opacity > 0.5, "fading in before the move")
    checker.equal(late.sample(at: 7.5)?.smoothedPosition, to, "settled on the new position")
}

// The snappy click spring engages 175 ms before a click and not earlier: with
// the click spring set equal to the ordinary one the timeline matches the
// default exactly until then and departs from it after.
do {
    let approach =
        linearMoves(from: NormalizedPoint(x: 0.1, y: 0.5), to: NormalizedPoint(x: 0.9, y: 0.5), start: 0, end: 2)
        + click(at: 2.0, NormalizedPoint(x: 0.9, y: 0.5))
    var sameSpring = CursorSmootherSettings()
    sameSpring.clickSpring = sameSpring.spring
    let plain = CursorSmoother(settings: sameSpring).timeline(events: approach, duration: 3)
    let snappy = CursorSmoother().timeline(events: approach, duration: 3)
    var beforeLead = 0.0
    var withinLead = 0.0
    for (a, b) in zip(plain.samples, snappy.samples) {
        let difference = pointDistance(a.smoothedPosition, b.smoothedPosition)
        if a.time <= 2.0 - 0.175 {
            beforeLead = max(beforeLead, difference)
        } else if a.time <= 2.0 {
            withinLead = max(withinLead, difference)
        }
    }
    checker.equal(beforeLead, 0, "the click spring changes nothing until 175 ms before the click")
    checker.check(withinLead > 1e-4, "the click spring changes the last 175 ms of the approach (\(withinLead))")
}

// Slow drift: a pointer creeping 1/1920 of the frame every 150 ms, sampled
// at 120 Hz, must come out as a line, not a staircase the raw path holds across.
do {
    var drift: [InputEvent] = []
    for step in 0...360 {
        let time = Double(step) / 120
        drift.append(.pointerMoved(time: time, position: NormalizedPoint(x: 0.5 + time / 0.150 / 1920, y: 0.5)))
    }
    let timeline = CursorSmoother().timeline(events: drift, duration: 3)
    var worstRawStep = 0.0
    for (a, b) in zip(timeline.samples, timeline.samples.dropFirst()) {
        worstRawStep = max(worstRawStep, abs(b.rawPosition.x - a.rawPosition.x))
    }
    let distinct = Set(timeline.samples.map(\.rawPosition.x)).count
    // A staircase steps 1/1920 at a time; the line moves 1/1920 / 9 per 60 Hz sample.
    checker.check(worstRawStep < 1.5 / 1920 / 9 * 2, "slow drift: raw path steps at most \(worstRawStep) per sample")
    checker.check(distinct > 150, "slow drift: raw path has \(distinct) distinct positions in 181 samples")
}

// Shake pre-filter: a 120 Hz ±0.005 jitter collapses to a still path, while
// the same trace with the filter off keeps the jitter.
do {
    var jitter: [InputEvent] = []
    for step in 0...120 {
        let x = 0.5 + (step % 2 == 0 ? 0.005 : -0.005)
        jitter.append(.pointerMoved(time: Double(step) / 120, position: NormalizedPoint(x: x, y: 0.5)))
    }
    func rawPathLength(_ timeline: CursorTimeline) -> Double {
        zip(timeline.samples, timeline.samples.dropFirst()).reduce(0) {
            $0 + pointDistance($1.0.rawPosition, $1.1.rawPosition)
        }
    }
    let filtered = CursorSmoother().timeline(events: jitter, duration: 1)
    var unfilteredSettings = CursorSmootherSettings()
    unfilteredSettings.shakeLegThreshold = 0
    let unfiltered = CursorSmoother(settings: unfilteredSettings).timeline(events: jitter, duration: 1)
    checker.check(rawPathLength(filtered) < 0.02, "shake filter removes the jitter (path \(rawPathLength(filtered)))")
    // Decimation to 60/s keeps every third 120 Hz sample, so about 0.27 of the 1.2 jitter travel survives.
    checker.check(
        rawPathLength(unfiltered) > 0.2, "without the filter the jitter remains (path \(rawPathLength(unfiltered)))")
}

// Idle fade and fade-in before motion resumes.
do {
    let pause: [InputEvent] = [
        .pointerMoved(time: 0, position: NormalizedPoint(x: 0.3, y: 0.3)),
        .pointerMoved(time: 5.0, position: NormalizedPoint(x: 0.6, y: 0.6)),
    ]
    let timeline = CursorSmoother().timeline(events: pause, duration: 6)
    checker.equal(timeline.sample(at: 3.0)?.opacity, 0, "hidden after 2.4 s idle")
    checker.equal(timeline.sample(at: 4.5)?.opacity, 0, "still hidden 500 ms before motion")
    checker.close(timeline.samples[294].opacity, Easing.smoothstep(0.6), "fading in 100 ms before motion resumes")
    checker.equal(timeline.sample(at: 5.0)?.opacity, 1, "fully visible when motion resumes")
    checker.equal(timeline.sample(at: 5.5)?.opacity, 1, "visible after motion")
}

// Per-segment disable: inside the range the raw motion passes through untouched.
do {
    let step: [InputEvent] = [
        .pointerMoved(time: 0, position: NormalizedPoint(x: 0.2, y: 0.2)),
        .pointerMoved(time: 1.5, position: NormalizedPoint(x: 0.8, y: 0.8)),
    ]
    var settings = CursorSmootherSettings()
    settings.disabledRanges = [1.0...2.0]
    let timeline = CursorSmoother(settings: settings).timeline(events: step, duration: 3)
    checker.check(
        timeline.samples.filter { $0.time >= 1.0 && $0.time <= 2.0 }.allSatisfy {
            $0.smoothedPosition == $0.rawPosition
        },
        "smoothed equals raw inside the disabled range")
    checker.equal(
        timeline.samples[90].smoothedPosition, NormalizedPoint(x: 0.8, y: 0.8), "raw jump passes through at 1.5 s")
    checker.equal(
        timeline.sample(at: 2.5)?.smoothedPosition, NormalizedPoint(x: 0.8, y: 0.8),
        "spring resumes from the raw position")
}

// sample(at:) interpolates linearly between neighbours and clamps at the ends.
do {
    let a = CursorSample(
        time: 0, smoothedPosition: NormalizedPoint(x: 0, y: 0), rawPosition: NormalizedPoint(x: 1, y: 1),
        isPressed: false,
        opacity: 1, scale: 1)
    let b = CursorSample(
        time: 1, smoothedPosition: NormalizedPoint(x: 1, y: 0), rawPosition: NormalizedPoint(x: 0, y: 1),
        isPressed: true,
        opacity: 0, scale: 0.8)
    let timeline = CursorTimeline(sampleRate: 1, samples: [a, b])
    let mid = timeline.sample(at: 0.25)!
    checker.equal(mid.smoothedPosition, NormalizedPoint(x: 0.25, y: 0), "smoothed position interpolates")
    checker.equal(mid.rawPosition, NormalizedPoint(x: 0.75, y: 1), "raw position interpolates")
    checker.equal(mid.opacity, 0.75, "opacity interpolates")
    checker.close(mid.scale, 0.95, "scale interpolates")
    checker.equal(mid.isPressed, false, "isPressed takes the nearer sample")
    checker.equal(timeline.sample(at: 0.75)?.isPressed, true, "isPressed takes the nearer sample (upper)")
    checker.equal(timeline.sample(at: -1)?.time, 0, "clamped below")
    checker.equal(timeline.sample(at: 9)?.time, 1, "clamped above")
    checker.check(CursorTimeline(sampleRate: 60, samples: []).sample(at: 0) == nil, "empty timeline has no samples")
}

// Camera planner: defaults from research brief §5.4.
let cameraDefaults = CameraPlannerSettings()
checker.equal(cameraDefaults.sampleRate, 120, "camera sample rate default")
checker.equal(cameraDefaults.retargetInterval, 0.008, "camera retarget interval default")
checker.equal(cameraDefaults.spring, .camera, "camera spring default")
checker.equal(cameraDefaults.deadZoneWidth, 0.5, "dead zone width default")
checker.equal(cameraDefaults.deadZoneHeight, 0.7, "dead zone height default")
checker.equal(cameraDefaults.preAimThreshold, 1.0005, "pre-aim threshold default")
// The brief's edge_snap_ratio 0.25 is half the viewport side at 2×; at other
// amounts the band follows the viewport so the focus is always centred when
// it can be and always inside the viewport.
checker.equal(CameraPlanner.edgeSnapRatio(forAmount: 2), 0.25, "edge snap ratio is 0.25 at 2×")
checker.equal(CameraPlanner.edgeSnapRatio(forAmount: 4), 0.125, "edge snap ratio is half the viewport side (4×)")
checker.equal(
    CameraPlanner.travel(forFocus: NormalizedPoint(x: 0.25, y: 0.75), amount: 2), NormalizedPoint(x: 0, y: 1),
    "the inner band maps to the full travel range")
checker.equal(
    CameraPlanner.travel(forFocus: NormalizedPoint(x: 0.02, y: 0.98), amount: 2), NormalizedPoint(x: 0, y: 1),
    "the outer band snaps to the edges")
do {
    let travel = CameraPlanner.travel(forFocus: NormalizedPoint(x: 0.7, y: 0.3), amount: 5)
    checker.close(travel.x, 0.75, "travel centres the focus at 5× (x)")
    checker.close(travel.y, 0.25, "travel centres the focus at 5× (y)")
    let center = CameraPlanner.center(travel: travel, amount: 5)
    checker.close(center.x, 0.7, "the centred viewport sits on the focus at 5× (x)")
    checker.close(center.y, 0.3, "the centred viewport sits on the focus at 5× (y)")
    checker.equal(
        CameraPlanner.travel(forFocus: NormalizedPoint(x: 0.7, y: 0.3), amount: 1), NormalizedPoint(x: 0.5, y: 0.5),
        "at 1× the whole frame shows and travel is the centre")
}
checker.equal(
    CameraPlanner.center(travel: NormalizedPoint(x: 0, y: 1), amount: 2), NormalizedPoint(x: 0.25, y: 0.75),
    "travel 0 and 1 at 2× are the flush viewports")
do {
    let viewport = CameraTimeline.viewport(center: NormalizedPoint(x: 0.25, y: 0.75), amount: 2)
    checker.equal(viewport.origin, NormalizedPoint(x: 0, y: 0.5), "viewport origin from center and amount")
    checker.equal(viewport.size, NormalizedSize(width: 0.5, height: 0.5), "viewport size is 1/amount")
}

/// Finite-difference speeds and velocity jumps of a camera timeline, per
/// channel. Travel is measured only while the frame is zoomed in: pre-aim
/// snaps while the frame shows everything are by design and invisible.
struct Continuity {
    var travelSpeed = 0.0
    var amountSpeed = 0.0
    var activitySpeed = 0.0
    var travelJump = 0.0
    /// Largest travel velocity jump as a fraction of what the spring could
    /// produce there from its known target; 1 is exactly the limit.
    var travelJumpRatio = 0.0
    var amountJump = 0.0
    var activityJump = 0.0
    var originStep = 0.0
}

/// The travel channel is held to the spring's own acceleration from its
/// known target: |x″| ≤ (k·|target − x| + c·|x′|) / m, so consecutive
/// finite-difference velocities may differ by at most that × dt, plus 5% and
/// a floor of 0.01/s for the clamp at the travel limits, which zeroes a
/// sub-pixel overshoot. A velocity dropped or reset at a segment boundary
/// shows up as a ratio far above 1, where a bound from |displacement| ≤ 1
/// would let anything under ~0.9/s through.
func continuity(of timeline: CameraTimeline, spring: SpringParameters = cameraDefaults.spring) -> Continuity {
    var result = Continuity()
    let samples = timeline.samples
    guard samples.count >= 3 else { return result }
    let rate = timeline.sampleRate
    let dt = 1 / rate
    let kOverM = spring.tension / spring.mass
    let cOverM = spring.friction / spring.mass
    let axes: [(position: KeyPath<CameraSample, Double>, target: KeyPath<CameraSample, Double>)] = [
        (\.travel.x, \.travelTarget.x), (\.travel.y, \.travelTarget.y),
    ]
    func zoomed(_ sample: CameraSample) -> Bool { sample.amount > cameraDefaults.preAimThreshold }
    for index in 1..<(samples.count - 1) {
        let a = samples[index - 1]
        let b = samples[index]
        let c = samples[index + 1]
        if zoomed(a), zoomed(b), zoomed(c) {
            for axis in axes {
                let v1 = (b[keyPath: axis.position] - a[keyPath: axis.position]) * rate
                let v2 = (c[keyPath: axis.position] - b[keyPath: axis.position]) * rate
                let displacement = max(
                    abs(a[keyPath: axis.target] - a[keyPath: axis.position]),
                    abs(b[keyPath: axis.target] - b[keyPath: axis.position]),
                    abs(c[keyPath: axis.target] - c[keyPath: axis.position]))
                let limit = (kOverM * displacement + cOverM * max(abs(v1), abs(v2))) * dt * 1.05 + 0.01
                result.travelSpeed = max(result.travelSpeed, abs(v1), abs(v2))
                result.travelJump = max(result.travelJump, abs(v2 - v1))
                result.travelJumpRatio = max(result.travelJumpRatio, abs(v2 - v1) / limit)
            }
        }
        let va1 = (b.amount - a.amount) * rate
        let va2 = (c.amount - b.amount) * rate
        result.amountSpeed = max(result.amountSpeed, abs(va1), abs(va2))
        result.amountJump = max(result.amountJump, abs(va2 - va1))
        let vc1 = (b.activity - a.activity) * rate
        let vc2 = (c.activity - b.activity) * rate
        result.activitySpeed = max(result.activitySpeed, abs(vc1), abs(vc2))
        result.activityJump = max(result.activityJump, abs(vc2 - vc1))
        let originB = CameraTimeline.viewport(center: b.center, amount: b.amount).origin
        let originC = CameraTimeline.viewport(center: c.center, amount: c.amount).origin
        result.originStep = max(result.originStep, abs(originC.x - originB.x), abs(originC.y - originB.y))
    }
    return result
}

/// Checks a camera timeline for C1 continuity. The travel channel is held to
/// the per-sample bound from its known target (see `continuity(of:)`); the
/// amount and activity channels, whose targets are the segment amount and 0
/// or 1, to |x″| ≤ (k·|displacement| + c·|x′|) / m with the displacement
/// bounded by the zoom range (5% slack).
@MainActor
func checkContinuity(_ timeline: CameraTimeline, zoomAmount: Double, label: String) {
    let spring = cameraDefaults.spring
    let dt = 1 / timeline.sampleRate
    let kOverM = spring.tension / spring.mass
    let cOverM = spring.friction / spring.mass
    let measured = continuity(of: timeline)
    let amountLimit = (kOverM * (zoomAmount - 1) + cOverM * measured.amountSpeed) * dt * 1.05 + 1e-9
    let activityLimit = (kOverM * 1 + cOverM * measured.activitySpeed) * dt * 1.05 + 1e-9
    // |origin′| ≤ |travel′|·(1 − 1/a) + travel·|a′|/a² ≤ |travel′| + |a′|, and a
    // pre-aim snap moves the origin by at most (1.0005 − 1) / 1.0005.
    let originLimit = (measured.travelSpeed + measured.amountSpeed) * dt * 1.05 + 0.001
    checker.check(
        measured.travelJumpRatio <= 1,
        "\(label): travel velocity jumps stay within the spring's acceleration "
            + "(\(measured.travelJumpRatio) of the limit)")
    checker.check(
        measured.amountJump <= amountLimit, "\(label): amount velocity jump \(measured.amountJump) ≤ \(amountLimit)")
    checker.check(
        measured.activityJump <= activityLimit,
        "\(label): activity velocity jump \(measured.activityJump) ≤ \(activityLimit)")
    checker.check(
        measured.originStep <= originLimit, "\(label): viewport origin step \(measured.originStep) ≤ \(originLimit)")
    print(
        "\(label): max velocity jump travel \(String(format: "%.4f", measured.travelJump))/s "
            + "(\(String(format: "%.2f", measured.travelJumpRatio)) of the spring limit), amount "
            + "\(String(format: "%.4f", measured.amountJump))×/s (limit \(String(format: "%.4f", amountLimit))), "
            + "origin step \(String(format: "%.4f", measured.originStep)) (limit \(String(format: "%.4f", originLimit)))"
    )
}

@MainActor
func checkInsideFrame(_ timeline: CameraTimeline, label: String) {
    var worst = 0.0
    var outside = 0
    for sample in timeline.samples {
        let viewport = CameraTimeline.viewport(center: sample.center, amount: sample.amount)
        let overflow = max(
            -viewport.origin.x, -viewport.origin.y, viewport.origin.x + viewport.size.width - 1,
            viewport.origin.y + viewport.size.height - 1)
        worst = max(worst, overflow)
        if overflow > 1e-12 { outside += 1 }
        if sample.amount < 1 || sample.travel.x < 0 || sample.travel.x > 1 || sample.travel.y < 0 || sample.travel.y > 1
        {
            outside += 1
        }
    }
    checker.equal(outside, 0, "\(label): viewport inside the frame at every sample (worst overflow \(worst))")
    // Between samples the renderer interpolates; the feasible set is convex, so
    // those viewports stay inside too.
    var random = TraceRandom(state: 7)
    var interpolatedOutside = 0
    for _ in 0..<2000 {
        let viewport = timeline.viewport(at: random.next(in: 0...timeline.duration))
        if viewport.origin.x < 0 || viewport.origin.y < 0 || viewport.origin.x + viewport.size.width > 1 + 1e-12
            || viewport.origin.y + viewport.size.height > 1 + 1e-12
        {
            interpolatedOutside += 1
        }
    }
    checker.equal(interpolatedOutside, 0, "\(label): interpolated viewports stay inside the frame")
}

// Corner clicks: the pointer sweeps the whole frame and clicks near all four
// corners, 6 s apart so each click is its own segment.
let corners = [
    NormalizedPoint(x: 0.02, y: 0.02), NormalizedPoint(x: 0.98, y: 0.02), NormalizedPoint(x: 0.98, y: 0.98),
    NormalizedPoint(x: 0.02, y: 0.98),
]
var cornerTrace: [InputEvent] = linearMoves(from: NormalizedPoint(x: 0.5, y: 0.5), to: corners[0], start: 0, end: 1.5)
for (index, corner) in corners.enumerated() {
    let clickTime = 2.0 + 6.0 * Double(index)
    cornerTrace += click(at: clickTime, corner)
    if index + 1 < corners.count {
        cornerTrace += linearMoves(from: corner, to: corners[index + 1], start: clickTime + 1, end: clickTime + 5)
    }
}
let cornerCursor = CursorSmoother().timeline(events: cornerTrace, duration: 22)
let cornerSegments = ZoomPlanner().plan(events: cornerTrace, recordingEnd: 22)
checker.equal(cornerSegments.count, 4, "four corner clicks give four segments")
let cornerCamera = CameraPlanner().timeline(segments: cornerSegments, cursor: cornerCursor)
checker.equal(cornerCamera.samples.count, 22 * 120 + 1, "120 Hz over 22 s")
checkInsideFrame(cornerCamera, label: "corner clicks")
checkContinuity(cornerCamera, zoomAmount: 2, label: "corner clicks")
checker.check((cornerCamera.samples.map(\.amount).max() ?? 0) > 1.99, "the camera reaches 2× zoom")
for (index, corner) in corners.enumerated() {
    let viewport = cornerCamera.viewport(at: 2.0 + 6.0 * Double(index) + 0.8)
    let contains =
        corner.x >= viewport.origin.x && corner.x <= viewport.origin.x + viewport.size.width
        && corner.y >= viewport.origin.y && corner.y <= viewport.origin.y + viewport.size.height
    checker.check(contains, "the zoomed viewport shows corner \(index) (\(viewport))")
}
// Pre-aim: a segment entered from amount 1 begins with the center already on
// its target, so the zoom scales straight toward the focus instead of panning
// at magnification; with the cursor parked on the corner the target then holds.
for segment in cornerSegments {
    guard
        let firstZoomed = cornerCamera.samples.firstIndex(where: {
            $0.time >= segment.start && $0.amount > cameraDefaults.preAimThreshold
        })
    else {
        checker.check(false, "the segment at \(segment.start) s zooms in")
        continue
    }
    let sample = cornerCamera.samples[firstZoomed]
    checker.check(
        pointDistance(sample.travel, sample.travelTarget) < 1e-9,
        "pre-aim: the center is on its target at the first zoomed sample of the segment at \(segment.start) s")
    let later = cornerCamera.samples[firstZoomed + 10]
    checker.check(
        pointDistance(later.travel, sample.travel) < 1e-9,
        "pre-aim: the center holds for the next 10 samples of the segment at \(segment.start) s")
}
// Between segments the framing holds: the center target freezes at the
// segment's end, so once the spring has settled the travel stays put although
// the cursor keeps sweeping toward the next corner, while the amount returns to 1.
if let first = cornerSegments.first {
    let settled = cornerCamera.sample(at: first.end + 1.5)!
    let later = cornerCamera.sample(at: first.end + 2.5)!
    checker.close(later.travel.x, settled.travel.x, tolerance: 1e-4, "framing holds during zoom-out (x)")
    checker.close(later.travel.y, settled.travel.y, tolerance: 1e-4, "framing holds during zoom-out (y)")
    let cursorMoved = pointDistance(
        cornerCursor.sample(at: first.end + 1.5)!.smoothedPosition,
        cornerCursor.sample(at: first.end + 2.5)!.smoothedPosition)
    checker.check(cursorMoved > 0.1, "while the cursor moved \(cursorMoved) of the frame in that second")
    checker.check(settled.amount < 1.001, "zoomed out 1.5 s after the segment (amount \(settled.amount))")
    checker.equal(later.amount, 1, "amount rests at exactly 1")
    checker.equal(cornerCamera.sample(at: 0.5)?.amount, 1, "amount is 1 before the first segment")
    checker.equal(cornerCamera.sample(at: 0.5)?.activity, 0, "activity is 0 before the first segment")
    checker.check(cornerCamera.sample(at: first.start + 1)!.activity > 0.99, "activity reaches 1 inside a segment")
}

// Segment boundary mid-flight: with a 0.5 s merge gap the second segment
// starts 0.6 s into the zoom-out, so the camera retargets while moving.
do {
    let trace =
        linearMoves(from: NormalizedPoint(x: 0.3, y: 0.5), to: NormalizedPoint(x: 0.3, y: 0.5), start: 0, end: 2)
        + click(at: 2.0, NormalizedPoint(x: 0.3, y: 0.5))
        + linearMoves(from: NormalizedPoint(x: 0.3, y: 0.5), to: NormalizedPoint(x: 0.75, y: 0.4), start: 2.5, end: 5.4)
        + click(at: 5.4, NormalizedPoint(x: 0.75, y: 0.4))
    var tight = ZoomPlannerSettings()
    tight.mergeGap = 0.5
    let segments = ZoomPlanner(settings: tight).plan(events: trace, recordingEnd: 10)
    checker.equal(segments.count, 2, "two segments 0.6 s apart")
    let cursor = CursorSmoother().timeline(events: trace, duration: 10)
    let camera = CameraPlanner().timeline(segments: segments, cursor: cursor)
    if segments.count == 2 {
        let atStart = camera.sample(at: segments[1].start)!
        checker.check(
            atStart.amount > 1.0005, "the second segment starts before zoom-out ends (amount \(atStart.amount))")
    }
    checkInsideFrame(camera, label: "boundary mid-flight")
    checkContinuity(camera, zoomAmount: 2, label: "boundary mid-flight")
    // Dead zone: the cursor leaves the first click's box, so the camera re-aims
    // and the viewport contains the cursor when the segment ends.
    if let first = segments.first {
        let viewport = camera.viewport(at: first.end)
        let cursorAtEnd = cursor.sample(at: first.end)!.smoothedPosition
        let contains =
            cursorAtEnd.x >= viewport.origin.x && cursorAtEnd.x <= viewport.origin.x + viewport.size.width
            && cursorAtEnd.y >= viewport.origin.y && cursorAtEnd.y <= viewport.origin.y + viewport.size.height
        checker.check(contains, "the camera re-aims when the cursor leaves the dead zone (\(viewport), \(cursorAtEnd))")
    }
    // The continuity check has teeth: a timeline with one sample shoved
    // sideways fails it.
    var broken = camera.samples
    broken[400].travel.x += 0.01
    broken[400].amount += 0.01
    let brokenJumps = continuity(of: CameraTimeline(sampleRate: camera.sampleRate, samples: broken))
    checker.check(
        brokenJumps.travelJump > 2, "a 0.01 travel discontinuity is a \(brokenJumps.travelJump)/s velocity jump")
    checker.check(
        brokenJumps.amountJump > 2, "a 0.01 amount discontinuity is a \(brokenJumps.amountJump)/s velocity jump")
    checker.check(
        brokenJumps.travelJumpRatio > 1,
        "a 0.01 travel discontinuity exceeds the spring bound (\(brokenJumps.travelJumpRatio))"
    )
}

// Segment boundary with the travel channel in flight: the cursor sweeps
// across the frame right up to the first segment's end, so the dead zone has
// just restarted and the center spring is still accelerating when the second
// segment begins 0.15 s later. The velocity must carry across, and the camera
// must have followed the cursor out of each dead zone on the way.
do {
    let sweepStart = NormalizedPoint(x: 0.2, y: 0.5)
    let sweepEnd = NormalizedPoint(x: 0.9, y: 0.5)
    let secondClickTime = 4.95
    let secondClick = NormalizedPoint(x: 0.2 + 0.7 * (secondClickTime - 2.3) / 3.0, y: 0.5)
    let trace =
        linearMoves(from: sweepStart, to: sweepStart, start: 0, end: 2)
        + click(at: 2.0, sweepStart)
        + linearMoves(from: sweepStart, to: sweepEnd, start: 2.3, end: 5.3)
        + click(at: secondClickTime, secondClick)
    var tight = ZoomPlannerSettings()
    tight.mergeGap = 0.1
    let segments = ZoomPlanner(settings: tight).plan(events: trace, recordingEnd: 10)
    checker.equal(segments.count, 2, "two segments 0.15 s apart")
    let cursor = CursorSmoother().timeline(events: trace, duration: 10)
    let camera = CameraPlanner().timeline(segments: segments, cursor: cursor)
    checkInsideFrame(camera, label: "sweep boundary")
    checkContinuity(camera, zoomAmount: 2, label: "sweep boundary")
    if segments.count == 2 {
        let boundary = Int((segments[1].start * camera.sampleRate).rounded())
        let before = camera.samples[boundary - 1]
        let atStart = camera.samples[boundary]
        let speed = abs(atStart.travel.x - before.travel.x) * camera.sampleRate
        checker.check(
            atStart.amount > 1.0005, "sweep boundary: the second segment starts zoomed in (amount \(atStart.amount))")
        checker.check(speed > 0.2, "sweep boundary: the center is in flight at the boundary (\(speed) travel/s)")
        // Dead zone: once the click's own zoom has settled, the viewport center
        // stays within half a dead zone (0.125 at 2×) plus spring lag of the
        // cursor. A box that never restarted would drift to the midpoint of the
        // click and the cursor instead.
        var worst = 0.0
        for sample in camera.samples where sample.time >= segments[0].start + 1.2 && sample.time <= segments[0].end {
            worst = max(worst, abs(sample.center.x - cursor.smoothedPosition(at: sample.time)!.x))
        }
        checker.check(worst <= 0.185, "sweep boundary: the center tracks the sweeping cursor (worst offset \(worst))")
        print(
            "sweep boundary: center speed at the boundary \(String(format: "%.3f", speed)) travel/s, worst offset from the cursor \(String(format: "%.3f", worst))"
        )
        // Teeth: the velocity reset a restarted spring would show at the
        // boundary fails the continuity bound.
        var reset = camera.samples
        for index in boundary..<(boundary + 6) {
            reset[index].travel.x = reset[boundary - 1].travel.x
        }
        let resetJumps = continuity(of: CameraTimeline(sampleRate: camera.sampleRate, samples: reset))
        checker.check(
            resetJumps.travelJumpRatio > 1,
            "sweep boundary: a zeroed velocity at the boundary is caught (\(resetJumps.travelJumpRatio) of the limit)")
    }
}

// Zoom amounts other than 2×: the focus is centred wherever the frame allows
// and always inside the viewport. A fixed 0.25 edge-snap ratio centres only
// at 2× and loses the focus beyond 4×.
do {
    let focus = NormalizedPoint(x: 0.7, y: 0.7)
    let trace = [InputEvent.pointerMoved(time: 0, position: focus)] + click(at: 2.0, focus)
    let cursor = CursorSmoother().timeline(events: trace, duration: 6)
    for amount in [1.5, 3.0, 5.0] {
        var settings = ZoomPlannerSettings()
        settings.amount = amount
        let segments = ZoomPlanner(settings: settings).plan(events: trace, recordingEnd: 6)
        let camera = CameraPlanner().timeline(segments: segments, cursor: cursor, duration: 6)
        let sample = camera.sample(at: 3.5)!
        let viewport = CameraTimeline.viewport(center: sample.center, amount: sample.amount)
        let inside =
            focus.x >= viewport.origin.x && focus.x <= viewport.origin.x + viewport.size.width
            && focus.y >= viewport.origin.y && focus.y <= viewport.origin.y + viewport.size.height
        checker.check(inside, "\(amount)×: the focus lies inside the zoomed viewport (\(viewport))")
        checker.close(sample.amount, amount, tolerance: 1e-3, "\(amount)×: the camera reaches the requested amount")
        if amount >= 3 {
            checker.check(
                pointDistance(sample.center, focus) < 1e-6, "\(amount)×: the focus is centred (center \(sample.center))"
            )
        }
        checkInsideFrame(camera, label: "\(amount)× click")
    }
}

// Corrupt durations: NaN (what `CMTime.seconds` gives for an invalid time)
// and infinities yield the single sample at time zero instead of a trap.
do {
    let empty = CursorTimeline(sampleRate: 60, samples: [])
    for duration in [Double.nan, .infinity, -.infinity, -5] {
        checker.equal(
            CursorSmoother().timeline(events: [], duration: duration).samples.count, 1,
            "cursor timeline over duration \(duration) has one sample")
        checker.equal(
            CameraPlanner().timeline(segments: [], cursor: empty, duration: duration).samples.count, 1,
            "camera timeline over duration \(duration) has one sample")
    }
    let nanSegment = ZoomSegment(start: 0, end: .nan, focus: NormalizedPoint(x: 0.5, y: 0.5), amount: 2)
    checker.equal(
        CameraPlanner().timeline(segments: [nanSegment], cursor: empty).samples.count, 1,
        "a NaN segment end gives a one-sample timeline by default")
    checker.equal(
        ZoomPlanner().plan(events: click(at: 1, NormalizedPoint(x: 0.5, y: 0.5)), recordingEnd: .infinity), [],
        "an infinite recording end plans nothing")
}

// Overlapping segments: the default duration is the latest end, not the end
// of the segment that starts last.
do {
    let center = NormalizedPoint(x: 0.5, y: 0.5)
    let overlapping = [
        ZoomSegment(start: 0, end: 10, focus: center, amount: 2),
        ZoomSegment(start: 2, end: 5, focus: center, amount: 2),
    ]
    let camera = CameraPlanner().timeline(
        segments: overlapping, cursor: CursorTimeline(sampleRate: 60, samples: []))
    checker.equal(camera.duration, 10, "the default camera duration covers the latest segment end")
}

// `continuity(of:)` on a timeline too short to difference returns zeros
// rather than forming an empty range.
do {
    let short = CameraTimeline(sampleRate: 120, samples: Array(cornerCamera.samples.prefix(2)))
    checker.equal(continuity(of: short).travelJumpRatio, 0, "continuity of a two-sample timeline is zero")
    checker.equal(
        continuity(of: CameraTimeline(sampleRate: 120, samples: [])).travelSpeed, 0,
        "continuity of an empty timeline is zero"
    )
}

// Budget: a 30-minute trace with 50,000 events plans in under 500 ms in a
// release build (the brief's figure; a debug build gets three times that),
// and the smoother is deterministic. Clicks come in clusters 6–14 s apart so
// the segments number in the hundreds and the camera switches segments as
// often as it would in a real session.
do {
    var random = TraceRandom(state: 0x5EED)
    var events: [InputEvent] = []
    events.reserveCapacity(50_000)
    var time = 0.0
    var position = NormalizedPoint(x: 0.5, y: 0.5)
    var nextCluster = random.next(in: 6...14)
    var clicksLeft = 0
    var nextClick = 0.0
    while events.count < 50_000 {
        time += random.next(in: 0.02...0.052)
        if clicksLeft == 0, time >= nextCluster {
            clicksLeft = 1 + Int(random.next() * 3)
            nextClick = time
            nextCluster = time + random.next(in: 6...14)
        }
        let roll = random.next()
        if clicksLeft > 0, time >= nextClick, events.count + 2 <= 50_000 {
            events += click(at: time, position, holdFor: 0.06)
            clicksLeft -= 1
            nextClick = time + random.next(in: 0.3...1.5)
        } else if roll < 0.02 {
            events.append(
                .keyDown(time: time, keyCode: UInt16(random.next(in: 0...50)), modifiers: [], isRepeat: false))
        } else {
            position = NormalizedPoint(
                x: min(max(position.x + random.next(in: -0.05...0.05), 0), 1),
                y: min(max(position.y + random.next(in: -0.05...0.05), 0), 1))
            events.append(.pointerMoved(time: time, position: position))
        }
    }
    checker.equal(events.count, 50_000, "the budget trace has 50,000 events")
    print("budget trace spans \(String(format: "%.0f", time)) s")
    let clock = ContinuousClock()
    func milliseconds(_ duration: Duration) -> String {
        String(
            format: "%.1f", Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15)
    }
    var cursor: CursorTimeline?
    var segments: [ZoomSegment] = []
    var camera: CameraTimeline?
    // Best of three, so a busy machine does not fail a budget the code meets.
    var best = Duration.seconds(1_000)
    for run in 1...3 {
        let cursorTime = clock.measure { cursor = CursorSmoother().timeline(events: events, duration: 1800) }
        let zoomTime = clock.measure { segments = ZoomPlanner().plan(events: events, recordingEnd: 1800) }
        let cameraTime = clock.measure {
            camera = CameraPlanner().timeline(segments: segments, cursor: cursor!, duration: 1800)
        }
        let total = cursorTime + zoomTime + cameraTime
        best = min(best, total)
        print(
            "30-minute plan, run \(run): cursor \(milliseconds(cursorTime)) ms, zoom \(milliseconds(zoomTime)) ms "
                + "(\(segments.count) segments), camera \(milliseconds(cameraTime)) ms, total \(milliseconds(total)) ms"
        )
    }
    #if DEBUG
        let budget = Duration.milliseconds(1500)
        let budgetNote = "debug build, 3× the 500 ms release budget"
    #else
        let budget = Duration.milliseconds(500)
        let budgetNote = "release build"
    #endif
    checker.check(
        best < budget,
        "30-minute, 50k-event plan completes in under \(milliseconds(budget)) ms (\(budgetNote); best "
            + "\(milliseconds(best)) ms)")
    checker.equal(cursor?.samples.count, 1800 * 60 + 1, "cursor timeline covers 30 minutes at 60 Hz")
    checker.equal(camera?.samples.count, 1800 * 120 + 1, "camera timeline covers 30 minutes at 120 Hz")
    checker.check(segments.count >= 100, "the budget trace produces hundreds of zoom segments (\(segments.count))")
    checkInsideFrame(camera!, label: "30-minute trace")
    let again = CursorSmoother().timeline(events: events, duration: 1800)
    checker.check(again == cursor, "the smoother is deterministic across two runs")
    let cameraAgain = CameraPlanner().timeline(segments: segments, cursor: again, duration: 1800)
    checker.check(cameraAgain == camera, "the camera planner is deterministic across two runs")
}

// MARK: Milestone 1

// One registration per milestone (PLAN "Shared entry files"): each file below
// is a stub until its task lands, so the pass count moves only when checks do.
runRecordingFormatChecks(checker)
runProjectChecks(checker)
runRenderPlanChecks(checker)
runKitChecks(checker)

// MARK: Milestone 2

runLayoutChecks(checker)
runContentMapperChecks(checker)

if checker.failures == 0 {
    print("OK: \(checker.passes) checks passed")
} else {
    print("\(checker.failures) of \(checker.failures + checker.passes) checks failed")
    exit(1)
}

import CoreGraphics
import CoreVideo
import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Proves the compositor without a recording or a permission: paints a
/// synthetic desktop and a synthetic camera frame, pushes them through
/// `Compositor` under a scripted camera (full frame → 2× on the top-right
/// quadrant → back) with the procedural cursor moving and pressing once, a
/// click ripple on the pressed frame and the camera bubble on every frame,
/// writes the frames as PNGs for eyeballing, and pins what the eye would
/// otherwise have to catch: known pixels of the gradient, shadow, corner mask
/// and content; the cursor's presence, body and stability under sub-pixel
/// moves; the ripple's ring and reach; the bubble's centre, mirroring, corner
/// mask and shadow; a window-mode content crop; the engine's stacked 9:16
/// layout; a transparent source region showing the background; the 420v path
/// against the BGRA one; the colour-tag guard; a minified 4K source; the
/// 1080p median and a warm 4K frame against budgets.
enum RenderSpike {
    static let sourceWidth = 1920
    static let sourceHeight = 1080
    static let frameCount = 6
    static let maximumMedianMilliseconds = 8.0
    /// The synthetic camera: a 720p picture, the shape a built-in camera
    /// delivers, with a face-coloured disc at the centre and a red bar on its
    /// left third, so the bubble's centre, its aspect fill and its mirroring
    /// each have a pixel to pin. Colours are 8-bit so the pins are exact.
    static let cameraWidth = 1280
    static let cameraHeight = 720
    static let cameraBackground = (38, 140, 153)
    static let cameraFace = (242, 204, 179)
    static let cameraBar = (230, 38, 51)
    /// The bar's span as a fraction of the camera's width.
    static let cameraBarRange = 0.28...0.32
    /// The disc's radius as a fraction of the camera's height.
    static let cameraFaceRadius = 0.3
    /// A bubble pixel may drift this much: the picture is box-filtered 4×4
    /// over a 5.9× minification, and the probes sit on flat colour.
    static let bubbleTolerance = 4
    /// The click behind the pressed frame's ripple and how far into the
    /// ripple that frame is: 0.1 s of the default 0.5 s, where the ring is
    /// still bright and a few pixels wide.
    static let rippleClickTime = 3.0
    static let rippleAge = 0.1
    /// A ring's worth of pixels at least; the default ring at 0.1 s is 21 px
    /// in radius, so its circumference alone is twice this.
    static let minimumRipplePixels = 60
    /// A ring pixel may drift this much: its coverage rides on the ring's
    /// sub-pixel radius, and the ring's edge is a linear ramp.
    static let rippleTolerance = 6
    /// The right half of the source, as a window-mode crop selects a window.
    static let rightHalfCrop = CameraViewport(
        origin: NormalizedPoint(x: 0.5, y: 0), size: NormalizedSize(width: 0.5, height: 1))
    /// The 9:16 preset, where the engine stacks the bubble under the card.
    static let verticalCanvas = CanvasSpec(width: 1080, height: 1920, frameRate: 60)
    /// One 60 fps interval: ARCHITECTURE §5 trips the v2 decoder above it at 4K.
    static let maximum4KMilliseconds = 16.7
    /// Below this fraction of pixels differing from the top-left one, a frame is flat.
    static let minimumVariedFraction = 0.01
    /// The 2× frame must differ from the 1× frame over at least this fraction of the output.
    static let minimumZoomDifference = 0.05
    /// A pinned pixel may drift this much per channel from rounding and filtering.
    static let probeTolerance = 3
    /// The cursor body, probed two points inside its edges, may pick up this
    /// much from the trilinear footprint of the coarser mip level.
    static let cursorBodyTolerance = 16
    /// Moving the cursor half a pixel may change the ink it leaves by this
    /// fraction; point-sampled edges flip whole pixels and exceed it.
    static let maximumInkVariation = 0.10
    /// Pixels where the 420v render may differ from the BGRA one by more than
    /// `chromaTolerance`: 4:2:0 subsampling blurs every colour edge (measured
    /// 0.24 % on the synthetic desktop; a shifted or swapped render is tens of percent).
    static let maximumChromaMismatch = 0.02
    static let chromaTolerance: UInt32 = 12
    /// One-pixel stripes minified 2.3× must box-filter to within this of mid-grey.
    static let stripeTolerance = 48
    static let zoomAmounts: [Double] = [1.0, 1.5, 2.0, 2.0, 1.5, 1.0]
    static let zoomCenter = NormalizedPoint(x: 0.75, y: 0.25)
    static let pressedFrame = 3
    static let cursorStart = NormalizedPoint(x: 0.56, y: 0.12)
    static let cursorEnd = NormalizedPoint(x: 0.90, y: 0.42)
    /// Cleared to transparent in the alpha check, in source pixels.
    static let transparentHole = CGRect(x: 1500, y: 700, width: 200, height: 200)
    /// One-pixel vertical stripes drawn into the 4K source, in its pixels.
    static let stripePatch = CGRect(x: 3400, y: 1800, width: 192, height: 192)

    static func run(arguments: [String]) async -> Bool {
        guard arguments.count <= 1 else {
            print("too many arguments; expected [outputDir]")
            return false
        }
        let outputDirectory = URL(fileURLWithPath: arguments.first ?? ".build/render-spike", isDirectory: true)
        do {
            return try render(into: outputDirectory)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    private static func render(into directory: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("render spike: GPU \(CutsceneRender.gpuName ?? "none"), output \(directory.path)")

        let clock = ContinuousClock()
        var compositor: Compositor?
        let setup = try clock.measure { compositor = try Compositor() }
        guard let compositor else { return false }
        print("compositor ready in \(milliseconds(setup)) ms (runtime shader compile included)")

        var style = RenderStyle()
        style.outputWidth = sourceWidth
        style.outputHeight = sourceHeight
        let desktop = try DesktopPainter(width: sourceWidth, height: sourceHeight, scale: 1, stripes: nil)
        var failures: [String] = []

        // The bubble as the engine places it for a 16:9 canvas: a circle a
        // fifth of the canvas tall in the bottom-trailing corner, over the
        // card. The synthetic camera is a built-in one, so it is mirrored.
        let cameraFrame = try paintCamera()
        var bubbleLayout = LayoutSettings()
        bubbleLayout.bubble = BubbleSettings()
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        guard
            let hdBubble = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: sourceAspect, settings: bubbleLayout)
                .bubble
        else {
            print("FAIL: the layout solver placed no bubble on the 16:9 canvas")
            return false
        }
        let camera = CameraBubbleFrame(pixelBuffer: cameraFrame, placement: hdBubble, isMirrored: true)
        print(
            "bubble: \(hdBubble.outline) \(format(hdBubble.rect.width))×\(format(hdBubble.rect.height)) px at "
                + "(\(format(hdBubble.rect.x)), \(format(hdBubble.rect.y))), \(hdBubble.arrangement), mirrored")

        // The scripted frames.
        var frames: [[UInt32]] = []
        var timings: [RenderTiming] = []
        for index in 0..<frameCount {
            let viewport = CameraViewport(CameraTimeline.viewport(center: zoomCenter, amount: zoomAmounts[index]))
            let position = cursorPosition(atFrame: index)
            let pressed = index == pressedFrame
            let cursor = cursorSample(at: position, pressed: pressed)
            let ripples = pressed ? pressedRipples(at: position) : []
            let source = try desktop.paint(frame: index)
            let rendered = try compositor.render(
                SourceFrame(pixelBuffer: source, viewport: viewport, cursor: cursor, ripples: ripples, camera: camera),
                style: style)
            timings.append(rendered.timing)

            let pixels = try readPixels(of: rendered.pixelBuffer)
            frames.append(pixels)
            let name = String(format: "frame-%02d.png", index)
            try writePNG(pixels, width: sourceWidth, height: sourceHeight, to: directory.appendingPathComponent(name))
            let varied = variedFraction(pixels)
            print(
                "\(name)  zoom \(String(format: "%.2f", zoomAmounts[index]))×  "
                    + "cpu \(String(format: "%.2f", rendered.timing.cpuSeconds * 1000)) ms  "
                    + "gpu \(String(format: "%.2f", rendered.timing.gpuSeconds * 1000)) ms  "
                    + "cursor (\(String(format: "%.2f", position.x)), \(String(format: "%.2f", position.y)))"
                    + (pressed ? " pressed" : "")
                    + (ripples.first.map { "  ripple r \(format($0.radius)) px" } ?? "")
                    + "  varied \(String(format: "%.1f", varied * 100))%")
            if varied < minimumVariedFraction {
                failures.append("\(name) is a flat color")
            }
        }

        // Pinned pixels, derived by hand from the default style (gradient
        // 0x1C2B4B → 0x4A1F5E at 45°, padding 0.06, radius 18, shadow 0.55 /
        // 48 px / (0, 18)) and the desktop: at 1× the card is 1689.6 × 950.4
        // at (115.2, 64.8), 0.88 output pixels per source pixel.
        check(
            frames[0], width: sourceWidth, frame: "frame-00",
            [
                Probe(1300, 230, (255, 140, 26), "orange block"),
                Probe(1734, 680, (255, 255, 255), "white page"),
                // Outside the rounded corner: gradient at t 0.377 times 1 − 0.107 shadow, not the menu bar's 225.
                Probe(116, 66, (40, 34, 73), "masked card corner"),
                Probe(0, 1079, (28, 43, 75), "gradient `from` corner"),
                Probe(1919, 0, (74, 31, 94), "gradient `to` corner"),
                // Between the card's bottom edge (1015.2) and the shadow's (1033.2): 0.413 shadow.
                Probe(960, 1016, (26, 23, 48), "shadow below the card"),
                Probe(960, 1079, (43, 39, 81), "gradient past the shadow"),
            ], failures: &failures)
        check(
            frames[2], width: sourceWidth, frame: "frame-02",
            [
                Probe(1050, 570, (255, 140, 26), "orange block at 2×"),
                Probe(1065, 258, (61, 61, 69), "terminal title bar at 2×"),
                // The tip is at (777.5, 521): four pixels right and ten down is inside the body.
                Probe(781, 531, (0, 0, 0), "cursor body at 2×", tolerance: cursorBodyTolerance),
            ],
            failures: &failures)
        let belowCard = rgb(frames[0][1016 * sourceWidth + 960])
        let pastShadow = rgb(frames[0][1079 * sourceWidth + 960])
        if belowCard.0 >= pastShadow.0 || belowCard.2 >= pastShadow.2 {
            failures.append(
                "frame-00: the shadow below the card \(belowCard) is not darker than the gradient \(pastShadow)")
        }

        // The cursor: everything it changes lies inside its box, its body is
        // black, and a half-pixel move leaves the same amount of ink (a
        // point-sampled sprite flips whole edge pixels instead).
        let fullLayout = CardLayout(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, outputWidth: sourceWidth, outputHeight: sourceHeight,
            viewport: .full, style: style)
        let cursorless = try readPixels(
            of: compositor.render(SourceFrame(pixelBuffer: desktop.paint(frame: 0), camera: camera), style: style)
                .pixelBuffer)
        let sprite = CursorSprite.arrow
        let tip = fullLayout.point(cursorStart)
        let spriteWidth = sprite.sizePoints.width * fullLayout.pixelsPerSourcePixel
        let spriteHeight = sprite.sizePoints.height * fullLayout.pixelsPerSourcePixel
        let box = PixelBox(
            minX: Int((tip.x - sprite.hotspot.x * spriteWidth).rounded(.down)) - 2,
            minY: Int((tip.y - sprite.hotspot.y * spriteHeight).rounded(.down)) - 2,
            maxX: Int((tip.x + (1 - sprite.hotspot.x) * spriteWidth).rounded(.up)) + 2,
            maxY: Int((tip.y + (1 - sprite.hotspot.y) * spriteHeight).rounded(.up)) + 2)
        var inside = 0
        var outside = 0
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth where differs(frames[0][y * sourceWidth + x], cursorless[y * sourceWidth + x]) {
                if box.contains(x, y) { inside += 1 } else { outside += 1 }
            }
        }
        print("cursor: \(inside) pixels changed inside its \(box.width)×\(box.height) box, \(outside) outside")
        if outside > 0 { failures.append("the cursor changed \(outside) pixels outside its box") }
        if inside < 50 || inside > box.width * box.height {
            failures.append("the cursor changed \(inside) pixels; expected between 50 and the box")
        }
        check(
            frames[0], width: sourceWidth, frame: "frame-00",
            [Probe(Int(tip.x) + 2, Int(tip.y) + 5, (0, 0, 0), "cursor body", tolerance: cursorBodyTolerance)],
            failures: &failures)
        let shifted = NormalizedPoint(
            x: cursorStart.x + 0.5 / fullLayout.width, y: cursorStart.y + 0.5 / fullLayout.height)
        let shiftedPixels = try readPixels(
            of: compositor.render(
                SourceFrame(
                    pixelBuffer: desktop.paint(frame: 0), cursor: cursorSample(at: shifted, pressed: false),
                    camera: camera),
                style: style
            ).pixelBuffer)
        let ink = inkSum(frames[0], against: cursorless, in: box, width: sourceWidth)
        let shiftedInk = inkSum(shiftedPixels, against: cursorless, in: box, width: sourceWidth)
        let inkVariation = Double(abs(ink - shiftedInk)) / Double(max(ink, shiftedInk, 1))
        print(
            "cursor ink: \(ink) at rest, \(shiftedInk) half a pixel on, "
                + "variation \(String(format: "%.1f", inkVariation * 100))% (limit \(Int(maximumInkVariation * 100))%)")
        if inkVariation > maximumInkVariation {
            failures.append(
                "the cursor's ink varies \(String(format: "%.1f", inkVariation * 100))% with sub-pixel phase")
        }

        // The ripple on the pressed frame: everything it changes lies within
        // its ring's reach around the click, it changes a ring's worth of
        // pixels, and a pixel on the ring is the screen under it mixed with
        // the ripple's white by the ring's coverage, which the spike computes
        // the way the shader does (half the stroke plus a one-pixel ramp).
        let pressedViewport = CameraViewport(
            CameraTimeline.viewport(center: zoomCenter, amount: zoomAmounts[pressedFrame]))
        let pressedPosition = cursorPosition(atFrame: pressedFrame)
        let rippleless = try readPixels(
            of: compositor.render(
                SourceFrame(
                    pixelBuffer: desktop.paint(frame: pressedFrame), viewport: pressedViewport,
                    cursor: cursorSample(at: pressedPosition, pressed: true), camera: camera),
                style: style
            ).pixelBuffer)
        guard let ripple = pressedRipples(at: pressedPosition).first else {
            failures.append("ClickEffects produced no ripple \(rippleAge) s after the click")
            return report(failures: failures, timings: timings, warm4K: nil)
        }
        let pressedLayout = CardLayout(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, outputWidth: sourceWidth, outputHeight: sourceHeight,
            viewport: pressedViewport, style: style)
        let rippleCenter = pressedLayout.point(pressedPosition)
        let reach = ripple.radius + ripple.strokeWidth + 2
        let rippleBox = PixelBox(
            minX: Int((rippleCenter.x - reach).rounded(.down)), minY: Int((rippleCenter.y - reach).rounded(.down)),
            maxX: Int((rippleCenter.x + reach).rounded(.up)), maxY: Int((rippleCenter.y + reach).rounded(.up)))
        var rippleInside = 0
        var rippleOutside = 0
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth
            where differs(frames[pressedFrame][y * sourceWidth + x], rippleless[y * sourceWidth + x]) {
                if rippleBox.contains(x, y) { rippleInside += 1 } else { rippleOutside += 1 }
            }
        }
        let ringX = Int(rippleCenter.x + ripple.radius)
        let ringY = Int(rippleCenter.y)
        let ringDistance =
            ((Double(ringX) + 0.5 - rippleCenter.x) * (Double(ringX) + 0.5 - rippleCenter.x)
            + (Double(ringY) + 0.5 - rippleCenter.y) * (Double(ringY) + 0.5 - rippleCenter.y)).squareRoot()
        let ringCoverage =
            min(max(ripple.strokeWidth / 2 + 0.5 - abs(ringDistance - ripple.radius), 0), 1) * ripple.opacity
        let under = rgb(rippleless[ringY * sourceWidth + ringX])
        func lit(_ channel: Int) -> Int { Int((Double(channel) + Double(255 - channel) * ringCoverage).rounded()) }
        print(
            "ripple: radius \(format(ripple.radius)) px, stroke \(format(ripple.strokeWidth)) px, "
                + "opacity \(format(ripple.opacity)); \(rippleInside) pixels changed within \(format(reach)) px of "
                + "the click, \(rippleOutside) beyond; ring pixel (\(ringX), \(ringY)) coverage \(format(ringCoverage))"
        )
        if rippleOutside > 0 { failures.append("the ripple changed \(rippleOutside) pixels beyond its reach") }
        if rippleInside < minimumRipplePixels {
            failures.append("the ripple changed \(rippleInside) pixels; expected at least \(minimumRipplePixels)")
        }
        check(
            frames[pressedFrame], width: sourceWidth, frame: String(format: "frame-%02d", pressedFrame),
            [
                Probe(
                    ringX, ringY, (lit(under.0), lit(under.1), lit(under.2)), "ripple ring", tolerance: rippleTolerance)
            ],
            failures: &failures)

        // The bubble on frame 0: the camera's centre at the bubble's centre,
        // the camera's left-third bar on the bubble's right when mirrored and
        // on its left when not, the corner of the bubble's rect (outside the
        // circle) untouched, and the shadow below the bubble darker than the
        // same pixel without a bubble.
        let bubbleless = try readPixels(
            of: compositor.render(
                SourceFrame(
                    pixelBuffer: desktop.paint(frame: 0), cursor: cursorSample(at: cursorStart, pressed: false)),
                style: style
            ).pixelBuffer)
        let unmirrored = try readPixels(
            of: compositor.render(
                SourceFrame(
                    pixelBuffer: desktop.paint(frame: 0), cursor: cursorSample(at: cursorStart, pressed: false),
                    camera: CameraBubbleFrame(pixelBuffer: cameraFrame, placement: hdBubble, isMirrored: false)),
                style: style
            ).pixelBuffer)
        try writePNG(
            unmirrored, width: sourceWidth, height: sourceHeight,
            to: directory.appendingPathComponent("frame-00-unmirrored.png"))
        let bubbleRect = hdBubble.rect
        let bubbleCenter = (x: Int(bubbleRect.x + bubbleRect.width / 2), y: Int(bubbleRect.y + bubbleRect.height / 2))
        // Aspect fill, as the compositor does it: the camera scaled to cover
        // the bubble, the centred slice that fits shown.
        let fill = max(bubbleRect.width / Double(cameraWidth), bubbleRect.height / Double(cameraHeight))
        let visibleFraction = bubbleRect.width / (Double(cameraWidth) * fill)
        let barFraction = (cameraBarRange.lowerBound + cameraBarRange.upperBound) / 2
        let barOffset = (barFraction - (1 - visibleFraction) / 2) / visibleFraction * bubbleRect.width
        let barX = Int(bubbleRect.x + barOffset)
        let mirroredBarX = Int(bubbleRect.x + bubbleRect.width - barOffset)
        let corner = (x: Int(bubbleRect.x) + 2, y: Int(bubbleRect.y) + 2)
        check(
            frames[0], width: sourceWidth, frame: "frame-00",
            [
                Probe(
                    bubbleCenter.x, bubbleCenter.y, cameraFace, "camera centre in the bubble",
                    tolerance: bubbleTolerance),
                Probe(
                    mirroredBarX, bubbleCenter.y, cameraBar, "the camera's left bar on the mirrored bubble's right",
                    tolerance: bubbleTolerance),
                Probe(
                    barX, bubbleCenter.y, cameraBackground, "camera background on the mirrored bubble's left",
                    tolerance: bubbleTolerance),
                Probe(
                    corner.x, corner.y, rgb(bubbleless[corner.y * sourceWidth + corner.x]),
                    "the bubble rect's corner outside the circle, as without a bubble"),
            ], failures: &failures)
        check(
            unmirrored, width: sourceWidth, frame: "frame-00-unmirrored",
            [
                Probe(
                    barX, bubbleCenter.y, cameraBar, "the camera's left bar on the unmirrored bubble's left",
                    tolerance: bubbleTolerance),
                Probe(
                    mirroredBarX, bubbleCenter.y, cameraBackground,
                    "camera background on the unmirrored bubble's right",
                    tolerance: bubbleTolerance),
            ], failures: &failures)
        let below = (x: bubbleCenter.x, y: Int(bubbleRect.maxY) + 4)
        let shadowed = rgb(frames[0][below.y * sourceWidth + below.x])
        let unshadowed = rgb(bubbleless[below.y * sourceWidth + below.x])
        print(
            "bubble: centre (\(bubbleCenter.x), \(bubbleCenter.y)), bar at x \(barX) unmirrored / \(mirroredBarX) "
                + "mirrored; below the bubble \(shadowed) vs \(unshadowed) without one")
        if shadowed.0 + shadowed.1 + shadowed.2 >= unshadowed.0 + unshadowed.1 + unshadowed.2 {
            failures.append("the bubble casts no shadow: \(shadowed) below it is not darker than \(unshadowed)")
        }
        // The camera in 420v, as a decoder would deliver it without the engine's conversion.
        let camera420v = try readPixels(
            of: compositor.render(
                SourceFrame(
                    pixelBuffer: desktop.paint(frame: 0),
                    camera: CameraBubbleFrame(
                        pixelBuffer: convertTo420v(cameraFrame), placement: hdBubble, isMirrored: true)),
                style: style
            ).pixelBuffer)
        check(
            camera420v, width: sourceWidth, frame: "frame-00 with a 420v camera",
            [
                Probe(
                    bubbleCenter.x, bubbleCenter.y, cameraFace, "camera centre in the bubble",
                    tolerance: bubbleTolerance + 2),
                Probe(
                    mirroredBarX, bubbleCenter.y, cameraBar, "the mirrored bar", tolerance: bubbleTolerance + 2),
            ], failures: &failures)

        // A window-mode crop: the right half of the source is the content,
        // so the card narrows to the crop's aspect (8:9: 844.8 × 950.4 at
        // x 537.6) and shows the orange block through the crop, while the
        // pixels where the cropped-away half was are the gradient.
        let cropped = try readPixels(
            of: compositor.render(
                SourceFrame(pixelBuffer: desktop.paint(frame: 0), contentCrop: rightHalfCrop), style: style
            ).pixelBuffer)
        try writePNG(
            cropped, width: sourceWidth, height: sourceHeight, to: directory.appendingPathComponent("frame-00-crop.png")
        )
        let cropLayout = CardLayout(
            sourceWidth: sourceWidth / 2, sourceHeight: sourceHeight, outputWidth: sourceWidth,
            outputHeight: sourceHeight, viewport: .full, style: style)
        // The block's centre on frame 0 is source (1348, 208): 388 px into the right half.
        let croppedBlock = cropLayout.point(
            sourceX: 1348 - Double(sourceWidth / 2), sourceY: 208, sourceWidth: sourceWidth / 2,
            sourceHeight: sourceHeight
        )
        print(
            "crop: right half, card \(format(cropLayout.width))×\(format(cropLayout.height)) at "
                + "(\(format(cropLayout.originX)), \(format(cropLayout.originY)))")
        check(
            cropped, width: sourceWidth, frame: "frame-00-crop",
            [
                Probe(Int(croppedBlock.x), Int(croppedBlock.y), (255, 140, 26), "orange block through the crop"),
                Probe(
                    300, 540, gradient(300, 540, width: sourceWidth, height: sourceHeight),
                    "gradient where the left half was"),
            ], failures: &failures)

        // The engine's 9:16 layout: the card rect it solved (the bubble
        // stacked below it, the two centred as one) is honoured, so the
        // orange block lands where the layout's card puts it and the bubble
        // shows the camera.
        let verticalStyle = RenderStyle(kit: .default, canvas: verticalCanvas)
        let verticalLayout = LayoutSolver.solve(
            canvas: .vertical1080, contentAspectRatio: sourceAspect,
            settings: LayoutSettings(kit: .default, hasCamera: true))
        guard let verticalBubble = verticalLayout.bubble else {
            failures.append("the layout solver placed no bubble on the 9:16 canvas")
            return report(failures: failures, timings: timings, warm4K: nil)
        }
        let vertical = try compositor.render(
            SourceFrame(
                pixelBuffer: desktop.paint(frame: 0),
                camera: CameraBubbleFrame(pixelBuffer: cameraFrame, placement: verticalBubble, isMirrored: true),
                cardRect: verticalLayout.card),
            style: verticalStyle)
        let verticalPixels = try readPixels(of: vertical.pixelBuffer)
        try writePNG(
            verticalPixels, width: verticalCanvas.width, height: verticalCanvas.height,
            to: directory.appendingPathComponent("frame-vertical.png"))
        let verticalCard = verticalLayout.card
        let verticalBlock = (
            x: Int(verticalCard.x + 1348 / Double(sourceWidth) * verticalCard.width),
            y: Int(verticalCard.y + 208 / Double(sourceHeight) * verticalCard.height)
        )
        let verticalCenter = (
            x: Int(verticalBubble.rect.x + verticalBubble.rect.width / 2),
            y: Int(verticalBubble.rect.y + verticalBubble.rect.height / 2)
        )
        let aboveCard = (x: Int(verticalCard.x + verticalCard.width / 2), y: Int(verticalCard.y) - 60)
        print(
            "9:16: card \(format(verticalCard.width))×\(format(verticalCard.height)) at "
                + "(\(format(verticalCard.x)), \(format(verticalCard.y))), bubble \(verticalBubble.arrangement) at "
                + "(\(format(verticalBubble.rect.x)), \(format(verticalBubble.rect.y)))  "
                + "cpu \(String(format: "%.2f", vertical.timing.cpuSeconds * 1000)) ms")
        check(
            verticalPixels, width: verticalCanvas.width, frame: "frame-vertical",
            [
                Probe(verticalBlock.x, verticalBlock.y, (255, 140, 26), "orange block through the layout's card"),
                Probe(
                    verticalCenter.x, verticalCenter.y, cameraFace, "camera centre in the stacked bubble",
                    tolerance: bubbleTolerance),
                Probe(
                    aboveCard.x, aboveCard.y,
                    gradient(aboveCard.x, aboveCard.y, width: verticalCanvas.width, height: verticalCanvas.height),
                    "gradient above the layout's card"),
            ], failures: &failures)

        // A transparent region of the source shows the shadowed background
        // through the card, as a window capture's corners and margins must.
        let holed = try desktop.paint(frame: 0, clearing: transparentHole)
        let holedPixels = try readPixels(
            of: compositor.render(SourceFrame(pixelBuffer: holed), style: style).pixelBuffer)
        try writePNG(
            holedPixels, width: sourceWidth, height: sourceHeight,
            to: directory.appendingPathComponent("frame-00-alpha.png"))
        let holeCenter = fullLayout.point(
            sourceX: transparentHole.midX, sourceY: transparentHole.midY, sourceWidth: sourceWidth,
            sourceHeight: sourceHeight)
        check(
            holedPixels, width: sourceWidth, frame: "frame-00-alpha",
            // Gradient at t 0.612 under the full 0.55 shadow: (56, 36, 87) × 0.45.
            [Probe(Int(holeCenter.x), Int(holeCenter.y), (25, 16, 39), "background through a transparent region")],
            failures: &failures)

        // The 420v path against the BGRA one: the same frame converted on the
        // CPU (BT.709 video range, left-sited chroma) must render alike except
        // along colour edges, which 4:2:0 blurs. The bubble rides along so
        // only the screen path differs between the two.
        let yuv = try convertTo420v(desktop.paint(frame: 0))
        let yuvPixels = try readPixels(
            of: compositor.render(SourceFrame(pixelBuffer: yuv, camera: camera), style: style).pixelBuffer)
        try writePNG(
            yuvPixels, width: sourceWidth, height: sourceHeight,
            to: directory.appendingPathComponent("frame-00-420v.png"))
        let chromaMismatch = differingFraction(frames[0], yuvPixels, tolerance: chromaTolerance)
        print(
            "420v vs BGRA: \(String(format: "%.2f", chromaMismatch * 100))% of pixels differ by more than \(chromaTolerance)"
        )
        if chromaMismatch > maximumChromaMismatch {
            failures.append(
                "the 420v render differs from BGRA on \(String(format: "%.1f", chromaMismatch * 100))% of pixels")
        }
        check(
            yuvPixels, width: sourceWidth, frame: "frame-00-420v",
            [
                Probe(1300, 230, (255, 140, 26), "orange block", tolerance: probeTolerance + 1),
                Probe(1734, 680, (255, 255, 255), "white page", tolerance: probeTolerance + 1),
                Probe(116, 66, (40, 34, 73), "masked card corner"),
            ], failures: &failures)

        // Colour tags: a frame tagged for Display P3, by primaries or by
        // colour space, must be refused rather than rendered as BT.709.
        let p3Primaries = try desktop.paintStandalone(frame: 0)
        CVBufferSetAttachment(
            p3Primaries, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        expectUnsupportedColorSpace(
            "P3 primaries", failures: &failures
        ) { try compositor.render(SourceFrame(pixelBuffer: p3Primaries), style: style) }
        let p3ColorSpace = try desktop.paintStandalone(frame: 0)
        if let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
            CVBufferSetAttachment(p3ColorSpace, kCVImageBufferCGColorSpaceKey, displayP3, .shouldPropagate)
            expectUnsupportedColorSpace(
                "Display P3 colour space", failures: &failures
            ) { try compositor.render(SourceFrame(pixelBuffer: p3ColorSpace), style: style) }
        }

        // The preview path: the same frame onto a plain texture of another
        // size. Managed storage works on every macOS GPU; it needs a blit
        // synchronization before the CPU reads what the GPU wrote.
        let previewWidth = 1280
        let previewHeight = 720
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: previewWidth, height: previewHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = compositor.device.makeTexture(descriptor: descriptor) else {
            failures.append("could not create a \(previewWidth)×\(previewHeight) preview texture")
            return report(failures: failures, timings: timings, warm4K: nil)
        }
        let viewport = CameraViewport(CameraTimeline.viewport(center: zoomCenter, amount: 2))
        let previewTiming = try compositor.render(
            SourceFrame(pixelBuffer: try desktop.paint(frame: 2), viewport: viewport), style: style, to: texture)
        let previewPixels = try readPixels(of: texture, device: compositor.device)
        let previewVaried = variedFraction(previewPixels)
        print(
            "render(to:) \(previewWidth)×\(previewHeight)  cpu \(String(format: "%.2f", previewTiming.cpuSeconds * 1000)) ms  "
                + "gpu \(String(format: "%.2f", previewTiming.gpuSeconds * 1000)) ms  "
                + "varied \(String(format: "%.1f", previewVaried * 100))%")
        if previewVaried < minimumVariedFraction { failures.append("render(to:) produced a flat texture") }
        descriptor.pixelFormat = .bgra8Unorm_srgb
        if let sRGBTexture = compositor.device.makeTexture(descriptor: descriptor) {
            do {
                try compositor.render(
                    SourceFrame(pixelBuffer: try desktop.paint(frame: 2)), style: style, to: sRGBTexture)
                failures.append("render(to:) accepted an sRGB texture")
            } catch RenderError.unsupportedOutput {
                print("render(to:) refused an sRGB texture, as it should")
            }
        }

        // A 4K source: minified 2.27× onto the 1080p canvas, where one-pixel
        // stripes must average to grey instead of aliasing, then rendered at
        // 4K for the timing that matters to export.
        let desktop4K = try DesktopPainter(
            width: 2 * sourceWidth, height: 2 * sourceHeight, scale: 2, stripes: stripePatch)
        let source4K = try desktop4K.paint(frame: 0)
        let minified = try compositor.render(SourceFrame(pixelBuffer: source4K), style: style)
        let minifiedPixels = try readPixels(of: minified.pixelBuffer)
        try writePNG(
            minifiedPixels, width: sourceWidth, height: sourceHeight,
            to: directory.appendingPathComponent("frame-00-4k-source.png"))
        let layout4K = CardLayout(
            sourceWidth: 2 * sourceWidth, sourceHeight: 2 * sourceHeight, outputWidth: sourceWidth,
            outputHeight: sourceHeight, viewport: .full, style: style)
        let patchMin = layout4K.point(
            sourceX: stripePatch.minX, sourceY: stripePatch.minY, sourceWidth: 2 * sourceWidth,
            sourceHeight: 2 * sourceHeight)
        let patchMax = layout4K.point(
            sourceX: stripePatch.maxX, sourceY: stripePatch.maxY, sourceWidth: 2 * sourceWidth,
            sourceHeight: 2 * sourceHeight)
        var stripeLow = 255
        var stripeHigh = 0
        for y in (Int(patchMin.y) + 3)...(Int(patchMax.y) - 3) {
            for x in (Int(patchMin.x) + 3)...(Int(patchMax.x) - 3) {
                let (r, g, b) = rgb(minifiedPixels[y * sourceWidth + x])
                stripeLow = min(stripeLow, r, g, b)
                stripeHigh = max(stripeHigh, r, g, b)
            }
        }
        print(
            "4K source on 1080p  cpu \(String(format: "%.2f", minified.timing.cpuSeconds * 1000)) ms  "
                + "gpu \(String(format: "%.2f", minified.timing.gpuSeconds * 1000)) ms  "
                + "1-px stripes read \(stripeLow)...\(stripeHigh) (want 128 ± \(stripeTolerance))")
        if stripeLow < 128 - stripeTolerance || stripeHigh > 128 + stripeTolerance {
            failures.append("1-px stripes minified 2.3× read \(stripeLow)...\(stripeHigh); the source is aliasing")
        }
        var style4K = style.scaled(by: 2)
        style4K.outputWidth = 2 * sourceWidth
        style4K.outputHeight = 2 * sourceHeight
        let viewport4K = CameraViewport(CameraTimeline.viewport(center: zoomCenter, amount: 1.5))
        let cursor4K = cursorSample(at: cursorStart, pressed: true)
        // The 4K frame carries everything the export's does: the bubble as
        // the engine places it on a 4K canvas and a ripple at twice its 1080p size.
        let bubble4K = LayoutSolver.solve(canvas: .uhd2160, contentAspectRatio: sourceAspect, settings: bubbleLayout)
            .bubble
        let frame4K = SourceFrame(
            pixelBuffer: source4K, viewport: viewport4K, cursor: cursor4K, sourcePixelsPerPoint: 2,
            ripples: pressedRipples(at: cursorStart).map { $0.scaled(by: 2) },
            camera: bubble4K.map { CameraBubbleFrame(pixelBuffer: cameraFrame, placement: $0, isMirrored: true) })
        // The first 4K frame allocates the pool's IOSurface; the second is the steady state.
        let cold4K = try compositor.render(frame4K, style: style4K)
        let warm4K = try compositor.render(frame4K, style: style4K)
        try writePNG(
            try readPixels(of: warm4K.pixelBuffer), width: 2 * sourceWidth, height: 2 * sourceHeight,
            to: directory.appendingPathComponent("frame-4k.png"))
        print(
            "4K output  cold cpu \(String(format: "%.2f", cold4K.timing.cpuSeconds * 1000)) ms, "
                + "warm cpu \(String(format: "%.2f", warm4K.timing.cpuSeconds * 1000)) ms  "
                + "gpu \(String(format: "%.2f", warm4K.timing.gpuSeconds * 1000)) ms")

        let zoomDifference = differingFraction(frames[0], frames[2])
        print("frame-00 vs frame-02 differ over \(String(format: "%.1f", zoomDifference * 100))% of the pixels")
        if zoomDifference < minimumZoomDifference {
            failures.append("zooming to 2× changed only \(String(format: "%.1f", zoomDifference * 100))% of the frame")
        }
        compositor.flush()
        return report(failures: failures, timings: timings, warm4K: warm4K.timing)
    }

    private static func report(failures: [String], timings: [RenderTiming], warm4K: RenderTiming?) -> Bool {
        var failures = failures
        let cpu = timings.map(\.cpuSeconds).sorted()
        if !cpu.isEmpty {
            let median = median(cpu)
            let gpuMedian = self.median(timings.map(\.gpuSeconds).sorted())
            print(
                "1080p frames: median cpu \(String(format: "%.2f", median * 1000)) ms "
                    + "(gpu \(String(format: "%.2f", gpuMedian * 1000)) ms), "
                    + "p95 \(String(format: "%.2f", percentile(cpu, 0.95) * 1000)) ms, "
                    + "max \(String(format: "%.2f", cpu.last! * 1000)) ms, budget \(maximumMedianMilliseconds) ms median"
            )
            if median * 1000 > maximumMedianMilliseconds {
                failures.append(
                    "median frame time \(String(format: "%.2f", median * 1000)) ms > \(maximumMedianMilliseconds) ms")
            }
        }
        if let warm4K, warm4K.cpuSeconds * 1000 > maximum4KMilliseconds {
            failures.append(
                "warm 4K frame \(String(format: "%.2f", warm4K.cpuSeconds * 1000)) ms > \(maximum4KMilliseconds) ms")
        }
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    private static func cursorSample(at position: NormalizedPoint, pressed: Bool) -> CursorSample {
        CursorSample(
            time: 0, smoothedPosition: position, rawPosition: position, isPressed: pressed, opacity: 1,
            scale: pressed ? CursorSmootherSettings().pressScale : 1)
    }

    /// Where the scripted cursor is on frame `index`: a straight line from
    /// `cursorStart` to `cursorEnd` over the frames.
    private static func cursorPosition(atFrame index: Int) -> NormalizedPoint {
        let t = Double(index) / Double(frameCount - 1)
        return NormalizedPoint(
            x: Easing.lerp(cursorStart.x, cursorEnd.x, t), y: Easing.lerp(cursorStart.y, cursorEnd.y, t))
    }

    /// The rings the engine draws `rippleAge` seconds after a click at
    /// `position`, with the default settings at the 1080p reference height.
    private static func pressedRipples(at position: NormalizedPoint) -> [Ripple] {
        ClickEffects(clicks: [ClickEvent(time: rippleClickTime, position: position, button: .left)])
            .ripples(at: rippleClickTime + rippleAge)
    }

    /// The default style's gradient at an output pixel, as the shader
    /// evaluates it (CSS angle, the line long enough for the corners to land
    /// on the stops), for probes on the background away from any shadow.
    private static func gradient(_ x: Int, _ y: Int, width: Int, height: Int) -> (Int, Int, Int) {
        guard case .linearGradient(let from, let to, let angleDegrees) = RenderStyle().background else {
            return (0, 0, 0)
        }
        let radians = angleDegrees * .pi / 180
        let direction = (x: sin(radians), y: -cos(radians))
        let halfLength = abs(Double(width) / 2 * direction.x) + abs(Double(height) / 2 * direction.y)
        let dot =
            (Double(x) + 0.5 - Double(width) / 2) * direction.x + (Double(y) + 0.5 - Double(height) / 2) * direction.y
        let t = min(max(dot / halfLength * 0.5 + 0.5, 0), 1)
        func channel(_ a: Double, _ b: Double) -> Int { Int((Easing.lerp(a, b, t) * 255).rounded()) }
        return (channel(from.red, to.red), channel(from.green, to.green), channel(from.blue, to.blue))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = Int((Double(sorted.count) * fraction).rounded(.up))
        return sorted[max(min(rank, sorted.count) - 1, 0)]
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(
            format: "%.1f", Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15)
    }

    private static func expectUnsupportedColorSpace(
        _ what: String, failures: inout [String], _ render: () throws -> RenderedFrame
    ) {
        do {
            _ = try render()
            failures.append("a frame tagged with \(what) rendered as BT.709")
        } catch RenderError.unsupportedColorSpace(let detail) {
            print("colour check refused \(what): \(detail)")
        } catch {
            failures.append("a frame tagged with \(what) failed with \(error.localizedDescription)")
        }
    }

    // MARK: Layout and probes

    /// The compositor's card layout (padding, aspect fit, centred), mirrored
    /// so probes can be placed from source coordinates; a drift between the
    /// two shows up as failed probes, which is the point.
    private struct CardLayout {
        let originX: Double
        let originY: Double
        let width: Double
        let height: Double
        let pixelsPerSourcePixel: Double
        let viewport: CameraViewport

        init(
            sourceWidth: Int, sourceHeight: Int, outputWidth: Int, outputHeight: Int, viewport: CameraViewport,
            style: RenderStyle
        ) {
            let padding = style.padding * Double(min(outputWidth, outputHeight))
            let visibleWidth = viewport.size.width * Double(sourceWidth)
            let visibleHeight = viewport.size.height * Double(sourceHeight)
            pixelsPerSourcePixel = min(
                (Double(outputWidth) - 2 * padding) / visibleWidth, (Double(outputHeight) - 2 * padding) / visibleHeight
            )
            width = visibleWidth * pixelsPerSourcePixel
            height = visibleHeight * pixelsPerSourcePixel
            originX = (Double(outputWidth) - width) / 2
            originY = (Double(outputHeight) - height) / 2
            self.viewport = viewport
        }

        /// Where a normalized source point lands in the output.
        func point(_ p: NormalizedPoint) -> (x: Double, y: Double) {
            (
                originX + (p.x - viewport.origin.x) / viewport.size.width * width,
                originY + (p.y - viewport.origin.y) / viewport.size.height * height
            )
        }

        func point(sourceX: Double, sourceY: Double, sourceWidth: Int, sourceHeight: Int) -> (x: Double, y: Double) {
            point(NormalizedPoint(x: sourceX / Double(sourceWidth), y: sourceY / Double(sourceHeight)))
        }
    }

    private struct PixelBox {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        func contains(_ x: Int, _ y: Int) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    private struct Probe {
        let x: Int
        let y: Int
        let expected: (Int, Int, Int)
        let what: String
        let tolerance: Int

        init(_ x: Int, _ y: Int, _ expected: (Int, Int, Int), _ what: String, tolerance: Int = probeTolerance) {
            self.x = x
            self.y = y
            self.expected = expected
            self.what = what
            self.tolerance = tolerance
        }
    }

    private static func check(
        _ pixels: [UInt32], width: Int, frame: String, _ probes: [Probe], failures: inout [String]
    ) {
        for probe in probes {
            let actual = rgb(pixels[probe.y * width + probe.x])
            let off = max(
                abs(actual.0 - probe.expected.0), abs(actual.1 - probe.expected.1), abs(actual.2 - probe.expected.2))
            if off > probe.tolerance {
                failures.append(
                    "\(frame) (\(probe.x),\(probe.y)) \(probe.what) is \(actual), expected \(probe.expected) ± \(probe.tolerance)"
                )
            }
        }
    }

    // MARK: Pixels

    /// The BGRA pixels of a frame as packed rows.
    private static func readPixels(of buffer: CVPixelBuffer) throws -> [UInt32] {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer(kCVReturnError) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            for row in 0..<height {
                raw.baseAddress!.advanced(by: row * width * 4)
                    .copyMemory(from: base.advanced(by: row * bytesPerRow), byteCount: width * 4)
            }
        }
        return pixels
    }

    /// The pixels of a managed render target, after the blit synchronization
    /// managed storage requires before a CPU read (MTLBlitCommandEncoder.h).
    private static func readPixels(of texture: MTLTexture, device: MTLDevice) throws -> [UInt32] {
        guard let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw SpikeError.sync }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { throw SpikeError.sync }
        var pixels = [UInt32](repeating: 0, count: texture.width * texture.height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    private static func rgb(_ pixel: UInt32) -> (Int, Int, Int) {
        (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
    }

    /// Fraction of pixels that differ from the top-left one by more than a
    /// hair in any channel, so dithering or rounding never counts as content.
    private static func variedFraction(_ pixels: [UInt32]) -> Double {
        guard let reference = pixels.first else { return 0 }
        var varied = 0
        for pixel in pixels where differs(pixel, reference) { varied += 1 }
        return Double(varied) / Double(pixels.count)
    }

    private static func differingFraction(_ a: [UInt32], _ b: [UInt32], tolerance: UInt32 = 8) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var differing = 0
        for index in a.indices where differs(a[index], b[index], tolerance: tolerance) { differing += 1 }
        return Double(differing) / Double(a.count)
    }

    private static func differs(_ a: UInt32, _ b: UInt32, tolerance: UInt32 = 8) -> Bool {
        for shift in stride(from: 0, through: 16, by: 8) {
            let channelA = (a >> UInt32(shift)) & 0xFF
            let channelB = (b >> UInt32(shift)) & 0xFF
            if (channelA > channelB ? channelA - channelB : channelB - channelA) > tolerance { return true }
        }
        return false
    }

    /// Total channel difference between two renders inside a box: how much
    /// the cursor changed the picture.
    private static func inkSum(_ pixels: [UInt32], against reference: [UInt32], in box: PixelBox, width: Int) -> Int {
        var sum = 0
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX {
                let a = rgb(pixels[y * width + x])
                let b = rgb(reference[y * width + x])
                sum += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
            }
        }
        return sum
    }

    /// The frame as 420v (BT.709 video range) in an IOSurface-backed buffer,
    /// tagged like a decoded intermediate. Chroma is left-sited: each sample
    /// is the mean of the two rows of the pair's left column, which is what
    /// `kCVImageBufferChromaLocation_Left` describes and the shader assumes.
    private static func convertTo420v(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixels = try readPixels(of: source)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)

        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        func channels(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let (r, g, b) = rgb(pixels[y * width + x])
            return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { throw SpikeError.pixelBuffer(kCVReturnError) }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let lumaPlane = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chromaPlane = chromaBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = channels(x, y)
                lumaPlane[y * lumaStride + x] = UInt8((16 + 219 * luma(r, g, b)).rounded())
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let top = channels(2 * x, 2 * y)
                let bottom = channels(2 * x, min(2 * y + 1, height - 1))
                let r = (top.0 + bottom.0) / 2
                let g = (top.1 + bottom.1) / 2
                let b = (top.2 + bottom.2) / 2
                let yy = luma(r, g, b)
                chromaPlane[y * chromaStride + 2 * x] = UInt8((128 + 224 * (b - yy) / 1.8556).rounded())
                chromaPlane[y * chromaStride + 2 * x + 1] = UInt8((128 + 224 * (r - yy) / 1.5748).rounded())
            }
        }
        return buffer
    }

    private static func writePNG(_ pixels: [UInt32], width: Int, height: Int, to url: URL) throws {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw SpikeError.png(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpikeError.png(url.lastPathComponent) }
    }

    enum SpikeError: LocalizedError {
        case pixelBufferPool(CVReturn)
        case pixelBuffer(CVReturn)
        case context
        case sync
        case png(String)

        var errorDescription: String? {
            switch self {
            case .pixelBufferPool(let status): "CVPixelBufferPoolCreate failed (\(status))."
            case .pixelBuffer(let status): "CVPixelBufferCreate failed (\(status))."
            case .context: "CoreGraphics would not draw into the source frame."
            case .sync: "The blit synchronization of the preview texture failed."
            case .png(let name): "Could not write \(name)."
            }
        }
    }

    // MARK: Synthetic camera

    /// Paints the camera frame: the background, the bar on the left third
    /// and the disc at the centre, in an IOSurface-backed BGRA buffer tagged
    /// sRGB like the desktop. The picture is symmetric top to bottom, so
    /// CoreGraphics' bottom-left origin needs no flip.
    private static func paintCamera() throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, cameraWidth, cameraHeight, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
            &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: base, width: cameraWidth, height: cameraHeight, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw SpikeError.context }
        func color(_ rgb: (Int, Int, Int)) -> CGColor {
            CGColor(
                srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        }
        let width = CGFloat(cameraWidth)
        let height = CGFloat(cameraHeight)
        context.setFillColor(color(cameraBackground))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color(cameraBar))
        context.fill(
            CGRect(
                x: width * cameraBarRange.lowerBound, y: 0,
                width: width * (cameraBarRange.upperBound - cameraBarRange.lowerBound), height: height))
        let radius = height * cameraFaceRadius
        context.setFillColor(color(cameraFace))
        context.fillEllipse(
            in: CGRect(x: width / 2 - radius, y: height / 2 - radius, width: 2 * radius, height: 2 * radius))
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        return buffer
    }

    // MARK: Synthetic desktop

    /// Paints a desktop into IOSurface-backed BGRA frames: wallpaper, menu
    /// bar, three windows with title bars and text-like stripes, a dock and
    /// an orange block that moves every frame. `scale` 2 paints the same
    /// desktop at Retina size; `stripes` adds a patch of one-pixel vertical
    /// lines for the minification check. Frames are tagged sRGB the way a
    /// pinned ScreenCaptureKit stream would tag them.
    private final class DesktopPainter {
        private let width: Int
        private let height: Int
        private let scale: CGFloat
        private let stripes: CGRect?
        private let pool: CVPixelBufferPool
        private let colorSpace: CGColorSpace

        /// The compositor wraps sources through a CVMetalTextureCache, which
        /// needs IOSurface backing, as ScreenCaptureKit frames have.
        private static func bufferAttributes() -> [CFString: Any] {
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        }

        init(width: Int, height: Int, scale: CGFloat, stripes: CGRect?) throws {
            self.width = width
            self.height = height
            self.scale = scale
            self.stripes = stripes
            var attributes = Self.bufferAttributes()
            attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA
            attributes[kCVPixelBufferWidthKey] = width
            attributes[kCVPixelBufferHeightKey] = height
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let pool = created else { throw SpikeError.pixelBufferPool(status) }
            self.pool = pool
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw SpikeError.context }
            self.colorSpace = colorSpace
        }

        /// A pooled frame; `clearing` punches a transparent hole into it.
        func paint(frame index: Int, clearing hole: CGRect? = nil) throws -> CVPixelBuffer {
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }
            try paint(frame: index, into: buffer, clearing: hole)
            return buffer
        }

        /// A frame outside the pool, for attachments that must not come back
        /// on a recycled buffer.
        func paintStandalone(frame index: Int) throws -> CVPixelBuffer {
            var created: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, Self.bufferAttributes() as CFDictionary,
                &created)
            guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }
            try paint(frame: index, into: buffer, clearing: nil)
            return buffer
        }

        private func paint(frame index: Int, into buffer: CVPixelBuffer, clearing hole: CGRect?) throws {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer),
                let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw SpikeError.context }
            // Top-left origin, like the screen, in 1080p desktop units.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            draw(in: context, frame: index)
            if let hole {
                context.clear(hole)
            }
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        }

        private func draw(in context: CGContext, frame index: Int) {
            let w = CGFloat(width) / scale
            let h = CGFloat(height) / scale
            // Wallpaper.
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [rgb(0.10, 0.16, 0.34), rgb(0.33, 0.14, 0.40)] as CFArray, locations: [0, 1])
            {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
            // Menu bar.
            fill(context, CGRect(x: 0, y: 0, width: w, height: 28), rgba(0.96, 0.96, 0.98, 0.9))
            var random = StripeRandom(state: 0x5EED)
            var x: CGFloat = 16
            for _ in 0..<7 {
                let length = CGFloat(random.next(in: 36...90))
                fill(context, CGRect(x: x, y: 9, width: length, height: 10), rgb(0.2, 0.2, 0.22), radius: 3)
                x += length + 22
            }

            // Editor on the left, terminal and browser stacked on the right.
            window(
                context, CGRect(x: 64, y: 92, width: 1120, height: 912), title: rgb(0.86, 0.86, 0.88),
                body: rgb(0.12, 0.12, 0.14))
            codeStripes(context, in: CGRect(x: 96, y: 160, width: 1056, height: 820), random: &random)
            window(
                context, CGRect(x: 1232, y: 92, width: 624, height: 440), title: rgb(0.24, 0.24, 0.27),
                body: rgb(0.05, 0.05, 0.07))
            terminalStripes(context, in: CGRect(x: 1256, y: 156, width: 576, height: 350), random: &random)
            window(
                context, CGRect(x: 1232, y: 564, width: 624, height: 440), title: rgb(0.93, 0.93, 0.95),
                body: rgb(1, 1, 1))
            fill(context, CGRect(x: 1400, y: 576, width: 300, height: 20), rgb(0.84, 0.84, 0.87), radius: 6)
            pageStripes(context, in: CGRect(x: 1256, y: 628, width: 576, height: 350), random: &random)

            // Dock.
            fill(context, CGRect(x: 640, y: 1004, width: 640, height: 64), rgba(0.9, 0.9, 0.95, 0.35), radius: 16)
            let dockColors = [
                rgb(0.95, 0.30, 0.25), rgb(0.98, 0.65, 0.15), rgb(0.95, 0.85, 0.20), rgb(0.30, 0.75, 0.35),
                rgb(0.25, 0.60, 0.95), rgb(0.55, 0.35, 0.85), rgb(0.90, 0.40, 0.70), rgb(0.30, 0.80, 0.80),
                rgb(0.60, 0.60, 0.65), rgb(0.20, 0.20, 0.25),
            ]
            for (slot, color) in dockColors.enumerated() {
                fill(context, CGRect(x: 656 + CGFloat(slot) * 62, y: 1012, width: 48, height: 48), color, radius: 11)
            }

            // The moving block, crossing the top-right quadrant over the six frames.
            let blockX = 1300 + CGFloat(index) * 72
            let blockY = 160 + CGFloat(index) * 40
            fill(context, CGRect(x: blockX, y: blockY, width: 96, height: 96), rgb(1.0, 0.55, 0.10), radius: 12)

            // One-pixel stripes in device pixels, drawn without anti-aliasing
            // so every column is exactly black or white.
            if let stripes {
                context.saveGState()
                context.setShouldAntialias(false)
                let patch = CGRect(
                    x: stripes.minX / scale, y: stripes.minY / scale, width: stripes.width / scale,
                    height: stripes.height / scale)
                fill(context, patch, rgb(0, 0, 0))
                context.setFillColor(rgb(1, 1, 1))
                for column in stride(from: 0, to: Int(stripes.width), by: 2) {
                    context.fill(
                        CGRect(
                            x: patch.minX + CGFloat(column) / scale, y: patch.minY, width: 1 / scale,
                            height: patch.height))
                }
                context.restoreGState()
            }
        }

        private func window(_ context: CGContext, _ rect: CGRect, title: CGColor, body: CGColor) {
            fill(context, rect, body, radius: 12)
            let titleBar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.clip()
            fill(context, titleBar, title)
            context.restoreGState()
            let lights = [rgb(1.0, 0.37, 0.34), rgb(1.0, 0.74, 0.18), rgb(0.16, 0.78, 0.25)]
            for (slot, color) in lights.enumerated() {
                context.setFillColor(color)
                context.fillEllipse(
                    in: CGRect(x: rect.minX + 18 + CGFloat(slot) * 22, y: rect.minY + 15, width: 14, height: 14))
            }
        }

        /// Lines of "code": indented runs of colored tokens.
        private func codeStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            let palette = [
                rgb(0.78, 0.47, 0.87), rgb(0.40, 0.72, 0.98), rgb(0.60, 0.85, 0.55), rgb(0.95, 0.60, 0.35),
                rgb(0.75, 0.75, 0.78),
            ]
            var indent = 0
            var y = area.minY
            while y + 12 <= area.maxY {
                indent = max(0, min(indent + Int(random.next(in: -1.5...1.5)), 4))
                var x = area.minX + CGFloat(indent) * 32
                for _ in 0..<Int(random.next(in: 2...5.99)) {
                    let length = CGFloat(random.next(in: 40...180))
                    guard x + length <= area.maxX else { break }
                    let color = palette[Int(random.next(in: 0...Double(palette.count) - 0.01))]
                    fill(context, CGRect(x: x, y: y, width: length, height: 12), color, radius: 4)
                    x += length + 12
                }
                y += 26
            }
        }

        /// A prompt in green followed by a white command on every other line.
        private func terminalStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            var y = area.minY
            var isPrompt = true
            while y + 10 <= area.maxY {
                if isPrompt {
                    fill(context, CGRect(x: area.minX, y: y, width: 60, height: 10), rgb(0.35, 0.9, 0.45), radius: 3)
                    let length = CGFloat(random.next(in: 120...380))
                    fill(
                        context, CGRect(x: area.minX + 72, y: y, width: length, height: 10), rgb(0.9, 0.9, 0.9),
                        radius: 3)
                } else {
                    let length = CGFloat(random.next(in: 200...540))
                    fill(context, CGRect(x: area.minX, y: y, width: length, height: 10), rgb(0.6, 0.6, 0.62), radius: 3)
                }
                isPrompt.toggle()
                y += 22
            }
        }

        /// Gray paragraph lines with a blue button.
        private func pageStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            fill(context, CGRect(x: area.minX, y: area.minY, width: 320, height: 22), rgb(0.15, 0.15, 0.18), radius: 5)
            var y = area.minY + 44
            while y + 10 <= area.maxY - 60 {
                let length = CGFloat(random.next(in: 300...560))
                fill(context, CGRect(x: area.minX, y: y, width: length, height: 10), rgb(0.72, 0.72, 0.75), radius: 3)
                y += 22
            }
            fill(
                context, CGRect(x: area.minX, y: area.maxY - 44, width: 140, height: 40), rgb(0.2, 0.5, 0.95), radius: 8
            )
        }

        private func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            context.setFillColor(color)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else {
                context.fill(rect)
            }
        }

        private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        private func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// Deterministic stripe lengths, so every run paints the same desktop.
    private struct StripeRandom {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func next(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }
}

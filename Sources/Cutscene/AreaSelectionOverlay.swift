import AppKit
import CutsceneCapture
import CutsceneCore
import Foundation

/// The numbers the area overlay is drawn and snapped with (PLAN M2-09).
struct AreaSelectionSettings: Sendable, Equatable {
    /// Opacity of the veil over everything outside the selection.
    var dimOpacity = 0.4
    /// Side of a resize handle in points, and how far outside it a press
    /// still grabs it.
    var handleSize = 10.0
    var handleHitSlop = 6.0
    var strokeWidth = 2.0
    /// Smallest selection on each side, in points; a drag shorter than this
    /// is a click and selects nothing.
    var minimumSidePoints = 16.0
    var labelFontSize = 12.0
    var hintFontSize = 14.0
    /// Points between the top of the screen and the hint, clear of the menu bar.
    var hintTopInset = 48.0
    var hint = "Drag to select the area to record. Return or double-click records it; Esc or a right click cancels."
}

/// What the overlay hands back: the display and the rect, in the space of
/// `CaptureRequest.Source.area` (display-local points, top-left origin),
/// already snapped to whole pixels with an even pixel size.
struct AreaSelection: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let rect: PointRect
    let pixelWidth: Int
    let pixelHeight: Int
}

/// The conversions between AppKit screen coordinates and Quartz
/// display-local ones, kept pure so they can be checked without a screen.
///
/// AppKit's origin is the bottom-left corner of a screen with y up; Quartz's
/// is the top-left corner with y down. A screen-local AppKit rect (origin at
/// the screen's own bottom-left, which is what a view filling a panel the
/// size of the screen measures in) and its Quartz display-local counterpart
/// share x; y flips across the screen's height.
enum AreaGeometry {
    /// Quartz display-local rect of a screen-local AppKit `rect`.
    static func quartzRect(appKit rect: CGRect, screenHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Screen-local AppKit rect of a Quartz display-local `rect`; its own inverse.
    static func appKitRect(quartz rect: CGRect, screenHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `rect` (Quartz display-local points) cut to the display and snapped
    /// the way `StreamConfigurationBuilder` snaps a source rect: the origin
    /// to whole pixels, the size to an even number of them, both rounded
    /// down, so the stream resamples nothing and the take gets what the
    /// overlay showed. Nil when nothing of `rect` lies on the display or a
    /// side is under `minimumSide` points.
    static func snapped(quartz rect: CGRect, displaySize: CGSize, scale: Double, minimumSide: Double)
        -> (rect: CGRect, width: Int, height: Int)?
    {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clipped.isNull, clipped.width >= minimumSide, clipped.height >= minimumSide, scale > 0 else {
            return nil
        }
        let x = (clipped.minX * scale).rounded(.down) / scale
        let y = (clipped.minY * scale).rounded(.down) / scale
        let width = StreamConfigurationBuilder.evenPixels((clipped.maxX - x) * scale)
        let height = StreamConfigurationBuilder.evenPixels((clipped.maxY - y) * scale)
        return (CGRect(x: x, y: y, width: Double(width) / scale, height: Double(height) / scale), width, height)
    }
}

/// The area picker (ARCHITECTURE §1): a `.screenSaver`-level panel over
/// every display, dimmed, where one drag makes the selection, its handles
/// resize it and dragging inside moves it; Return or a double click records,
/// Esc or a right click cancels. The selection lives on one display at a
/// time (the stream samples one display), and the completion gets it in the
/// request's own space, snapped. The panels are non-activating so a
/// full-screen Space keeps them (platform-notes "Window capture") and the
/// app does not come forward over what is about to be recorded.
@MainActor final class AreaSelectionController {
    typealias Completion = @MainActor (AreaSelection?) -> Void

    let settings: AreaSelectionSettings
    private var panels: [AreaSelectionPanel] = []
    private var completion: Completion?

    init(settings: AreaSelectionSettings = AreaSelectionSettings(), completion: @escaping Completion) {
        self.settings = settings
        self.completion = completion
    }

    /// Whether the panels are on screen.
    var isActive: Bool { !panels.isEmpty }

    /// Opens a panel on every screen; the one under the pointer takes the keyboard.
    func begin() {
        guard panels.isEmpty else { return }
        let pointer = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = AreaSelectionPanel(screen: screen, controller: self, settings: settings)
            panels.append(panel)
            if NSMouseInRect(pointer, screen.frame, false) {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        if !panels.contains(where: { $0.isKeyWindow }) {
            panels.first?.makeKeyAndOrderFront(nil)
        }
    }

    func cancel() {
        finish(nil)
    }

    func confirm(_ selection: AreaSelection) {
        finish(selection)
    }

    /// A press on `view`'s display: the other displays drop their selection.
    func selectionBegan(in view: AreaSelectionView) {
        for panel in panels where panel.selectionView !== view {
            panel.selectionView.clearSelection()
        }
    }

    private func finish(_ selection: AreaSelection?) {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        let completion = completion
        self.completion = nil
        completion?(selection)
    }
}

/// One screen's panel: borderless, non-activating, able to become key so
/// Return and Esc reach it.
final class AreaSelectionPanel: NSPanel {
    let selectionView: AreaSelectionView

    @MainActor init(screen: NSScreen, controller: AreaSelectionController, settings: AreaSelectionSettings) {
        selectionView = AreaSelectionView(screen: screen, controller: controller, settings: settings)
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = selectionView
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}

/// The veil, the selection, its handles and the size label on one screen.
/// Coordinates are the view's, which is the screen's own AppKit space
/// (the panel's frame is the screen's frame), so `AreaGeometry` converts
/// them to the display-local Quartz rect the request takes.
final class AreaSelectionView: NSView {
    /// A resize handle by the edges it moves: −1 the min edge, 1 the max
    /// edge, 0 neither, on each axis.
    private struct Handle: Equatable {
        var dx: Int
        var dy: Int

        static let all: [Handle] = [
            Handle(dx: -1, dy: -1), Handle(dx: 0, dy: -1), Handle(dx: 1, dy: -1),
            Handle(dx: -1, dy: 0), Handle(dx: 1, dy: 0),
            Handle(dx: -1, dy: 1), Handle(dx: 0, dy: 1), Handle(dx: 1, dy: 1),
        ]
    }

    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(grabOffset: CGPoint)
        case resizing(Handle, original: CGRect)
    }

    private unowned let controller: AreaSelectionController
    private let settings: AreaSelectionSettings
    private let displayID: CGDirectDisplayID
    private let displaySize: CGSize
    private let scale: Double
    /// The selection in view coordinates, snapped; nil before the first drag.
    private var selection: CGRect?
    private var pixelSize: (width: Int, height: Int)?
    private var drag: Drag?

    @MainActor init(screen: NSScreen, controller: AreaSelectionController, settings: AreaSelectionSettings) {
        self.controller = controller
        self.settings = settings
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = CGDirectDisplayID(number?.uint32Value ?? CGMainDisplayID())
        displaySize = screen.frame.size
        scale = Double(screen.backingScaleFactor)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AreaSelectionView is made in code.")
    }

    override var acceptsFirstResponder: Bool { true }

    /// The first click lands as a selection, not as an activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func clearSelection() {
        selection = nil
        pixelSize = nil
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let selection, selection.contains(point) {
            confirm()
            return
        }
        controller.selectionBegan(in: self)
        if let selection, let handle = handle(at: point, of: selection) {
            drag = .resizing(handle, original: selection)
        } else if let selection, selection.contains(point) {
            drag = .moving(grabOffset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY))
        } else {
            drag = .creating(anchor: point)
            setSelection(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .creating(let anchor):
            setSelection(
                CGRect(
                    x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x),
                    height: abs(point.y - anchor.y)))
        case .moving(let offset):
            guard let current = selection else { return }
            setSelection(CGRect(origin: CGPoint(x: point.x - offset.x, y: point.y - offset.y), size: current.size))
        case .resizing(let handle, let original):
            setSelection(Self.resized(original, by: handle, to: point))
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.cancel()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            controller.cancel()
        case 36, 76:  // Return, keypad Enter
            confirm()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        controller.cancel()
    }

    // MARK: Selection

    private func confirm() {
        guard let selection, let pixelSize else { return }
        let quartz = AreaGeometry.quartzRect(appKit: selection, screenHeight: displaySize.height)
        controller.confirm(
            AreaSelection(
                displayID: displayID, rect: PointRect(quartz), pixelWidth: pixelSize.width,
                pixelHeight: pixelSize.height))
    }

    /// Stores `rect` snapped as the stream will snap it, so the frame on
    /// screen is the frame in the file; a rect too small to record clears
    /// the selection.
    private func setSelection(_ rect: CGRect?) {
        defer { needsDisplay = true }
        guard let rect,
            let snapped = AreaGeometry.snapped(
                quartz: AreaGeometry.quartzRect(appKit: rect, screenHeight: displaySize.height),
                displaySize: displaySize, scale: scale, minimumSide: settings.minimumSidePoints)
        else {
            selection = nil
            pixelSize = nil
            return
        }
        selection = AreaGeometry.appKitRect(quartz: snapped.rect, screenHeight: displaySize.height)
        pixelSize = (snapped.width, snapped.height)
    }

    /// `original` with the edges `handle` names moved to `point`; a drag past
    /// the opposite edge flips the rect rather than collapsing it.
    private static func resized(_ original: CGRect, by handle: Handle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle.dx {
        case -1: minX = point.x
        case 1: maxX = point.x
        default: break
        }
        switch handle.dy {
        case -1: minY = point.y
        case 1: maxY = point.y
        default: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func handleRect(_ handle: Handle, of selection: CGRect) -> CGRect {
        let size = settings.handleSize
        let x = [selection.minX, selection.midX, selection.maxX][handle.dx + 1]
        let y = [selection.minY, selection.midY, selection.maxY][handle.dy + 1]
        return CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
    }

    private func handle(at point: CGPoint, of selection: CGRect) -> Handle? {
        let slop = settings.handleHitSlop
        return Handle.all.first { handleRect($0, of: selection).insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let veil = NSBezierPath(rect: bounds)
        if let selection {
            veil.appendRect(selection)
            veil.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(settings.dimOpacity).setFill()
        veil.fill()

        drawHint()
        guard let selection else { return }
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = settings.strokeWidth
        outline.stroke()
        NSColor.white.setFill()
        for handle in Handle.all {
            NSBezierPath(rect: handleRect(handle, of: selection)).fill()
        }
        if let pixelSize {
            drawLabel("\(pixelSize.width) × \(pixelSize.height) px", near: selection)
        }
    }

    private func drawHint() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: settings.hint,
            attributes: [
                .font: NSFont.systemFont(ofSize: settings.hintFontSize, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
        let size = text.size()
        let padding = settings.hintFontSize
        let box = NSRect(
            x: bounds.midX - size.width / 2 - padding, y: bounds.maxY - settings.hintTopInset - size.height - padding,
            width: size.width + padding * 2, height: size.height + padding * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: padding, yRadius: padding).fill()
        text.draw(in: box.insetBy(dx: padding, dy: padding))
    }

    /// The size above the selection, or inside its top edge when the
    /// selection touches the top of the screen.
    private func drawLabel(_ string: String, near selection: CGRect) {
        let text = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: settings.labelFontSize, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
        let size = text.size()
        let padding = settings.labelFontSize / 2
        var box = NSRect(
            x: selection.minX, y: selection.maxY + padding, width: size.width + padding * 2,
            height: size.height + padding)
        if box.maxY > bounds.maxY {
            box.origin.y = selection.maxY - box.height - padding
        }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: padding, yRadius: padding).fill()
        text.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }
}

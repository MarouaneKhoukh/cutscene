import AppKit
import Foundation

/// The numbers the countdown runs on (PLAN M2-09: 3 s, tunable).
struct CountdownSettings: Sendable, Equatable {
    /// Whole seconds counted down before the take starts; 0 skips the
    /// countdown. Three is enough to let go of the menu and put the pointer
    /// where the take begins, and short enough not to feel like waiting.
    var seconds = 3
    /// Seconds between one number and the next.
    var tickInterval: TimeInterval = 1
    /// Diameter of the badge in points, and the size of its number.
    var badgeDiameter = 180.0
    var fontSize = 112.0
    /// Opacity of the badge's dark disc; the number itself stays white.
    var badgeOpacity = 0.55
}

/// The number counting down on every display (ARCHITECTURE §1: a panel per
/// `NSScreen` at `.screenSaver` level). The panels ignore the mouse, so the
/// pointer can be put where the take begins while the number runs; the
/// menu and the pill carry Cancel. Our application is excluded from a
/// display or area capture and a window capture includes only the chosen
/// window, so the badge never reaches the recording; it is gone before the
/// stream starts in any case.
@MainActor final class CountdownOverlay {
    let settings: CountdownSettings
    private var panels: [NSPanel] = []
    private var badges: [CountdownBadgeView] = []

    init(settings: CountdownSettings = CountdownSettings()) {
        self.settings = settings
    }

    /// Whether the badges are on screen.
    var isVisible: Bool { !panels.isEmpty }

    /// Shows `remaining` on every display, making the panels on the first call.
    func show(remaining: Int) {
        if panels.isEmpty {
            makePanels()
        }
        for badge in badges {
            badge.remaining = remaining
        }
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        badges = []
    }

    private func makePanels() {
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let badge = CountdownBadgeView(frame: NSRect(origin: .zero, size: screen.frame.size), settings: settings)
            panel.contentView = badge
            panel.orderFrontRegardless()
            panels.append(panel)
            badges.append(badge)
        }
    }
}

/// A dark disc with the remaining seconds, centred in its panel. Drawn by
/// hand rather than hosted: a hosting view sized from its content is what
/// crashed the M1 windows (PLAN M1-F6).
final class CountdownBadgeView: NSView {
    private let settings: CountdownSettings

    var remaining = 0 {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, settings: CountdownSettings) {
        self.settings = settings
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CountdownBadgeView is made in code.")
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = settings.badgeDiameter
        let disc = NSRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        NSColor.black.withAlphaComponent(settings.badgeOpacity).setFill()
        NSBezierPath(ovalIn: disc).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: String(remaining),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: settings.fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
        let size = text.size()
        text.draw(in: NSRect(x: disc.minX, y: disc.midY - size.height / 2, width: disc.width, height: size.height))
    }
}

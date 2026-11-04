import Foundation

/// Interpolation curves shared by the effects. Every function takes a
/// progress `t` and clamps it to 0...1, so callers can feed raw ratios
/// (elapsed / duration) without guarding the ends themselves.
public enum Easing {
    /// Hermite blend `3t² − 2t³`: zero slope at both ends.
    public static func smoothstep(_ t: Double) -> Double {
        let t = clamp01(t)
        return t * t * (3 - 2 * t)
    }

    /// Perlin's quintic `6t⁵ − 15t⁴ + 10t³`: zero slope *and* zero curvature at
    /// both ends, so a zoom that starts or stops on it has no visible kick.
    public static func smootherstep(_ t: Double) -> Double {
        let t = clamp01(t)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Cubic ease-in on the first half, cubic ease-out on the second.
    public static func easeInOutCubic(_ t: Double) -> Double {
        let t = clamp01(t)
        if t < 0.5 {
            return 4 * t * t * t
        }
        let u = -2 * t + 2
        return 1 - u * u * u / 2
    }

    /// `a` at `t = 0`, `b` at `t = 1`; not clamped, so it also extrapolates.
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// Where `value` sits between `a` and `b`, as 0...1; the inverse of `lerp`.
    /// Returns 1 when `a == b`, so a zero-length ramp counts as finished.
    public static func unlerp(_ a: Double, _ b: Double, _ value: Double) -> Double {
        guard b != a else { return 1 }
        return clamp01((value - a) / (b - a))
    }

    static func clamp01(_ t: Double) -> Double {
        min(max(t, 0), 1)
    }
}

/// A first-order (one-pole) low-pass filter, the discrete form of
/// `dy/dt = (x − y) / τ`.
///
/// `timeConstant` τ is the time the output takes to cover 63% of a step in
/// its input. The update uses the exact exponential for the elapsed time,
/// so it behaves the same whether it is fed 60 or 120 times a second.
public struct OnePoleLowPass: Sendable, Hashable {
    /// τ in seconds. Zero or negative means no filtering: the output snaps to the input.
    public var timeConstant: Double
    /// The filtered value after the latest `update`.
    public private(set) var value: Double

    public init(timeConstant: Double, initialValue: Double) {
        self.timeConstant = timeConstant
        self.value = initialValue
    }

    /// Moves the output toward `input` for `dt` seconds and returns it.
    @discardableResult
    public mutating func update(toward input: Double, dt: Double) -> Double {
        guard timeConstant > 0, dt > 0 else {
            value = input
            return value
        }
        let blend = 1 - exp(-dt / timeConstant)
        value += (input - value) * blend
        return value
    }

    /// Forces the output, for example when the signal it tracks is reset.
    public mutating func reset(to newValue: Double) {
        value = newValue
    }
}

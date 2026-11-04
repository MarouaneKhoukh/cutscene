import CutsceneCore
import Foundation

/// Constants of a spring-mass-damper, in the (tension, mass, friction) form
/// the presets are quoted in: `m·x″ + c·x′ + k·x = 0` with `k = tension`,
/// `m = mass`, `c = friction`.
public struct SpringParameters: Sendable, Hashable {
    /// Stiffness `k`. Must be positive.
    public var tension: Double
    /// Mass `m`. Must be positive.
    public var mass: Double
    /// Damping `c`. Zero gives an undamped oscillator.
    public var friction: Double

    public init(tension: Double, mass: Double, friction: Double) {
        self.tension = tension
        self.mass = mass
        self.friction = friction
    }

    /// Cap's default cursor spring: heavy and well damped.
    public static let mellow = SpringParameters(tension: 470, mass: 3.0, friction: 70)
    public static let slow = SpringParameters(tension: 200, mass: 2.25, friction: 40)
    public static let smooth = SpringParameters(tension: 80, mass: 2.5, friction: 28)
    public static let fast = SpringParameters(tension: 380, mass: 1.0, friction: 30)
    /// Applied in the last 175 ms before a click so the cursor lands on the click point.
    public static let snappy = SpringParameters(tension: 530, mass: 1.0, friction: 40)
    /// Applied while a button is held so drags track the pointer closely.
    public static let drag = SpringParameters(tension: 1000, mass: 1.0, friction: 40)
    /// The auto-zoom camera channels (stiffness 200, damping 40, mass 2.25).
    public static let camera = SpringParameters(tension: 200, mass: 2.25, friction: 40)

    /// Undamped angular frequency ω = √(k/m), in radians per second.
    public var angularFrequency: Double {
        (tension / mass).squareRoot()
    }

    /// ζ = c / (2√(k·m)); below 1 the spring overshoots, above 1 it creeps.
    public var dampingRatio: Double {
        friction / (2 * (tension * mass).squareRoot())
    }

    /// Seconds a spring trails a target that moves at constant speed, `c / k`.
    /// The cursor smoother samples its target this far ahead to cancel the lag.
    public var phaseLag: Double {
        friction / tension
    }
}

/// The closed-form solution of a spring over one fixed time step, reduced to
/// four coefficients (Ryan Juckett, "Damped Springs"). Computing them once and
/// applying them to many springs with the same constants and step is what
/// keeps the offline simulations cheap.
///
/// With `d = position − target`:
/// `d′ = d·positionFromPosition + v·positionFromVelocity`,
/// `v′ = d·velocityFromPosition + v·velocityFromVelocity`.
public struct SpringStep: Sendable, Hashable {
    public let positionFromPosition: Double
    public let positionFromVelocity: Double
    public let velocityFromPosition: Double
    public let velocityFromVelocity: Double

    /// Damping ratios this close to 1 take the critically damped branch; the
    /// other two divide by √|ζ² − 1| and lose precision as it goes to zero.
    static let criticalDampingTolerance = 1e-4

    /// Coefficients for advancing `parameters` by `dt` seconds. A non-positive
    /// `dt` yields the identity step.
    public init(parameters: SpringParameters, dt: Double) {
        let omega = parameters.angularFrequency
        guard dt > 0, omega > 0, omega.isFinite else {
            positionFromPosition = 1
            positionFromVelocity = 0
            velocityFromPosition = 0
            velocityFromVelocity = 1
            return
        }
        let zeta = max(parameters.dampingRatio, 0)

        if zeta > 1 + Self.criticalDampingTolerance {
            // Over-damped: the sum of two decaying exponentials with rates z1 and z2.
            let za = -omega * zeta
            let zb = omega * (zeta * zeta - 1).squareRoot()
            let z1 = za - zb
            let z2 = za + zb
            let e1 = exp(z1 * dt)
            let e2 = exp(z2 * dt)
            let invTwoZb = 1 / (2 * zb)
            let e1OverTwoZb = e1 * invTwoZb
            let e2OverTwoZb = e2 * invTwoZb
            let z1e1OverTwoZb = z1 * e1OverTwoZb
            let z2e2OverTwoZb = z2 * e2OverTwoZb
            positionFromPosition = e1OverTwoZb * z2 - z2e2OverTwoZb + e2
            positionFromVelocity = -e1OverTwoZb + e2OverTwoZb
            velocityFromPosition = (z1e1OverTwoZb - z2e2OverTwoZb + e2) * z2
            velocityFromVelocity = -z1e1OverTwoZb + z2e2OverTwoZb
        } else if zeta < 1 - Self.criticalDampingTolerance {
            // Under-damped: a decaying sinusoid at the damped frequency α.
            let omegaZeta = omega * zeta
            let alpha = omega * (1 - zeta * zeta).squareRoot()
            let expTerm = exp(-omegaZeta * dt)
            let cosTerm = cos(alpha * dt)
            let sinTerm = sin(alpha * dt)
            let invAlpha = 1 / alpha
            let expSin = expTerm * sinTerm
            let expCos = expTerm * cosTerm
            let expOmegaZetaSinOverAlpha = expTerm * omegaZeta * sinTerm * invAlpha
            positionFromPosition = expCos + expOmegaZetaSinOverAlpha
            positionFromVelocity = expSin * invAlpha
            velocityFromPosition = -expSin * alpha - omegaZeta * expOmegaZetaSinOverAlpha
            velocityFromVelocity = expCos - expOmegaZetaSinOverAlpha
        } else {
            // Critically damped: the fastest approach with no overshoot.
            let expTerm = exp(-omega * dt)
            let timeExp = dt * expTerm
            let timeExpFreq = timeExp * omega
            positionFromPosition = timeExpFreq + expTerm
            positionFromVelocity = timeExp
            velocityFromPosition = -omega * timeExpFreq
            velocityFromVelocity = -timeExpFreq + expTerm
        }
    }

    /// Advances one spring in place.
    @inlinable
    public func apply(position: inout Double, velocity: inout Double, target: Double) {
        let displacement = position - target
        let oldVelocity = velocity
        position = displacement * positionFromPosition + oldVelocity * positionFromVelocity + target
        velocity = displacement * velocityFromPosition + oldVelocity * velocityFromVelocity
    }
}

/// A one-dimensional spring chasing a target, with the rest snap that stops
/// it from creeping forever: once the displacement is below `restDisplacement`
/// and the speed below `restVelocity` it lands exactly on the target.
public struct Spring: Sendable, Hashable {
    public static let restDisplacement = 1e-5
    public static let restVelocity = 1e-4

    public var parameters: SpringParameters
    public var position: Double
    /// Units per second.
    public var velocity: Double
    public var target: Double

    /// Starts at `position`, at rest, aiming at `target` (the start position
    /// when omitted).
    public init(parameters: SpringParameters, position: Double, velocity: Double = 0, target: Double? = nil) {
        self.parameters = parameters
        self.position = position
        self.velocity = velocity
        self.target = target ?? position
    }

    /// Whether the spring is within the rest thresholds of its target.
    public var isAtRest: Bool {
        abs(position - target) < Self.restDisplacement && abs(velocity) < Self.restVelocity
    }

    /// Advances by `dt` seconds with freshly computed coefficients. A
    /// non-positive `dt` changes nothing.
    public mutating func step(by dt: Double) {
        guard dt > 0 else { return }
        step(SpringStep(parameters: parameters, dt: dt))
    }

    /// Advances with coefficients computed earlier for these parameters.
    public mutating func step(_ step: SpringStep) {
        step.apply(position: &position, velocity: &velocity, target: target)
        if isAtRest {
            snapToTarget()
        }
    }

    /// Lands on the target with zero velocity.
    public mutating func snapToTarget() {
        position = target
        velocity = 0
    }
}

/// Two `Spring`s with shared constants, one per axis, over `NormalizedPoint`.
/// The step coefficients are computed once and applied to both axes.
public struct Spring2D: Sendable, Hashable {
    public var x: Spring
    public var y: Spring

    public init(parameters: SpringParameters, position: NormalizedPoint, target: NormalizedPoint? = nil) {
        x = Spring(parameters: parameters, position: position.x, target: target?.x)
        y = Spring(parameters: parameters, position: position.y, target: target?.y)
    }

    public var parameters: SpringParameters {
        get { x.parameters }
        set {
            x.parameters = newValue
            y.parameters = newValue
        }
    }

    public var position: NormalizedPoint {
        get { NormalizedPoint(x: x.position, y: y.position) }
        set {
            x.position = newValue.x
            y.position = newValue.y
        }
    }

    public var target: NormalizedPoint {
        get { NormalizedPoint(x: x.target, y: y.target) }
        set {
            x.target = newValue.x
            y.target = newValue.y
        }
    }

    /// Speed along the path, in normalized units per second.
    public var speed: Double {
        (x.velocity * x.velocity + y.velocity * y.velocity).squareRoot()
    }

    public var isAtRest: Bool {
        x.isAtRest && y.isAtRest
    }

    public mutating func step(by dt: Double) {
        guard dt > 0 else { return }
        step(SpringStep(parameters: x.parameters, dt: dt))
    }

    public mutating func step(_ step: SpringStep) {
        x.step(step)
        y.step(step)
    }

    public mutating func snapToTarget() {
        x.snapToTarget()
        y.snapToTarget()
    }
}

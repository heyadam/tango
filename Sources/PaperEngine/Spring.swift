import Foundation

/// Closed-form damped spring. Each step starts from the current position and velocity, so
/// changing the target mid-flight is continuous and the result does not depend on frame rate.
public enum Spring {
    /// - Parameters:
    ///   - response: Seconds for one undamped oscillation; smaller is stiffer.
    ///   - dampingRatio: 1 is critically damped, below 1 overshoots.
    public static func step(
        position: Double,
        velocity: Double,
        target: Double,
        response: Double,
        dampingRatio: Double,
        dt: Double
    ) -> (position: Double, velocity: Double) {
        guard dt > 0 else { return (position, velocity) }
        let omega = 2 * Double.pi / max(response, 0.01)
        let zeta = max(dampingRatio, 0.01)
        let x0 = position - target
        let v0 = velocity
        let t = dt

        if abs(zeta - 1) < 1e-6 {
            let b = v0 + omega * x0
            let e = exp(-omega * t)
            let x = (x0 + b * t) * e
            let v = (b - omega * (x0 + b * t)) * e
            return (target + x, v)
        }

        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let a = x0
            let b = (v0 + zeta * omega * x0) / wd
            let e = exp(-zeta * omega * t)
            let c = cos(wd * t)
            let s = sin(wd * t)
            let x = e * (a * c + b * s)
            let v = e * ((b * wd - zeta * omega * a) * c - (a * wd + zeta * omega * b) * s)
            return (target + x, v)
        }

        let s = omega * (zeta * zeta - 1).squareRoot()
        let r1 = -zeta * omega + s
        let r2 = -zeta * omega - s
        let c2 = (v0 - r1 * x0) / (r2 - r1)
        let c1 = x0 - c2
        let e1 = exp(r1 * t)
        let e2 = exp(r2 * t)
        return (target + c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
    }

    /// Whether the spring is close enough to its target to stop.
    public static func isAtRest(position: Double, velocity: Double, target: Double) -> Bool {
        abs(position - target) < 0.0005 && abs(velocity) < 0.005
    }
}

public enum EasingCurve: String, Sendable, CaseIterable {
    case linear = "Linear"
    case easeIn = "Ease In"
    case easeOut = "Ease Out"
    case easeInOut = "Ease In Out"

    public func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:
            return x
        case .easeIn:
            return x * x * x
        case .easeOut:
            let inv = 1 - x
            return 1 - inv * inv * inv
        case .easeInOut:
            if x < 0.5 { return 4 * x * x * x }
            let inv = -2 * x + 2
            return 1 - inv * inv * inv / 2
        }
    }
}

import CoreGraphics

/// Shared coordinate-space math for model-supplied screen points — used by
/// both `ScreenPlanRunner.validate` (parse-time rejection of an out-of-bounds
/// point) and `ScreenAwarenessService`'s dispatch path (last-instant
/// correction right before a coordinate click is posted). Keeping this in one
/// place means the two can never silently apply different rules.
public enum CoordinateSpace {
    /// Small allowance for a point landing just outside the captured window
    /// frame — window chrome/shadow rounding, not a real coordinate-space bug.
    private static let boundsMargin: CGFloat = 4

    /// If a model reads coordinates directly off the screenshot image
    /// instead of the point-space list in the context text, the result is
    /// roughly `scale`x too large. Detect that case — the raw point falls
    /// outside the window frame, but dividing by scale brings it back
    /// inside — and correct it before dispatch.
    public static func resolvedPoint(_ point: CGPoint, windowFrame: CGRect?, scale: CGFloat?) -> CGPoint {
        guard let windowFrame, let scale, scale > 1,
              !isWithinBounds(point, windowFrame: windowFrame) else {
            return point
        }
        let scaled = CGPoint(x: point.x / scale, y: point.y / scale)
        return isWithinBounds(scaled, windowFrame: windowFrame) ? scaled : point
    }

    public static func isWithinBounds(_ point: CGPoint, windowFrame: CGRect?) -> Bool {
        guard let windowFrame else { return true }
        return windowFrame.insetBy(dx: -boundsMargin, dy: -boundsMargin).contains(point)
    }
}

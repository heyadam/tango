import CoreGraphics

/// Where a prototype's screen goes in the view that shows it.
public nonisolated enum Viewport {
    /// The scale and the top-left corner that center a screen of `screen` points in `bounds`.
    /// `fills` scales it up as well as down until it touches two sides; otherwise it keeps
    /// `margin` around it and never grows past its true size. Nil when either has no area.
    public static func fit(
        screen: CGSize, in bounds: CGRect, fills: Bool, margin: CGFloat = 16
    ) -> (scale: CGFloat, origin: CGPoint)? {
        let available = fills ? bounds : bounds.insetBy(dx: margin, dy: margin)
        guard screen.width > 0, screen.height > 0, available.width > 0, available.height > 0 else { return nil }
        let fitted = min(available.width / screen.width, available.height / screen.height)
        let scale = fills ? fitted : min(1, fitted)
        return (scale, CGPoint(
            x: (bounds.width - screen.width * scale) / 2,
            y: (bounds.height - screen.height * scale) / 2
        ))
    }
}

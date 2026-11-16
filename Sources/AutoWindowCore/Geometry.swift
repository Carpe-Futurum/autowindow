import CoreGraphics

public enum Geometry {
    /// The display a window belongs to: the one containing its center, else the one it overlaps most.
    public static func display(for frame: CGRect, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit }
        return displays
            .map { ($0, area($0.bounds.intersection(frame))) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    public static func relative(_ frame: CGRect, to display: DisplaySnapshot) -> CGRect {
        frame.offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY)
    }

    /// Converts a display-relative frame back to global space, shrunk and shifted to fit the display.
    public static func absolute(_ relative: CGRect, on display: DisplaySnapshot) -> CGRect {
        let b = display.bounds
        var f = relative.offsetBy(dx: b.minX, dy: b.minY)
        f.size.width = min(f.width, b.width)
        f.size.height = min(f.height, b.height)
        f.origin.x = min(max(f.minX, b.minX), b.maxX - f.width)
        f.origin.y = min(max(f.minY, b.minY), b.maxY - f.height)
        return f
    }

    private static func area(_ r: CGRect) -> CGFloat {
        r.isNull ? 0 : r.width * r.height
    }
}

import CoreGraphics

/// Moving the front window to a part of its screen, the way Magnet and Rectangle do.
public enum SnapAction: String, CaseIterable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, centerTwoThirds, rightTwoThirds
    case nextDisplay, previousDisplay
    case maximize, center, restore

    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        }
    }
}

public enum WindowSnap {
    /// Where `action` puts a window inside `area` (the screen minus menu bar and Dock).
    /// Nil for actions that don't depend on one screen alone (display moves, restore).
    public static func frame(_ action: SnapAction, window: CGRect, in area: CGRect) -> CGRect? {
        let a = area
        func part(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: a.minX + a.width * x, y: a.minY + a.height * y, width: a.width * w, height: a.height * h).integral
        }
        let third: CGFloat = 1.0 / 3.0
        switch action {
        case .left: return part(0, 0, 0.5, 1)
        case .right: return part(0.5, 0, 0.5, 1)
        case .top: return part(0, 0, 1, 0.5)
        case .bottom: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .leftThird: return part(0, 0, third, 1)
        case .centerThird: return part(third, 0, third, 1)
        case .rightThird: return part(2 * third, 0, third, 1)
        case .leftTwoThirds: return part(0, 0, 2 * third, 1)
        case .centerTwoThirds: return part(third / 2, 0, 2 * third, 1)
        case .rightTwoThirds: return part(third, 0, 2 * third, 1)
        case .maximize: return a.integral
        case .center:
            let w = min(window.width, a.width), h = min(window.height, a.height)
            return CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h).integral
        case .nextDisplay, .previousDisplay, .restore: return nil
        }
    }

    /// The same place and share of the screen, on another screen.
    public static func move(_ window: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let sx = to.width / from.width, sy = to.height / from.height
        var f = CGRect(x: to.minX + (window.minX - from.minX) * sx,
                       y: to.minY + (window.minY - from.minY) * sy,
                       width: min(window.width * sx, to.width),
                       height: min(window.height * sy, to.height))
        f.origin.x = min(max(f.minX, to.minX), to.maxX - f.width)
        f.origin.y = min(max(f.minY, to.minY), to.maxY - f.height)
        return f.integral
    }

    /// Index of the area a window is on: the one holding its center, else the one it overlaps most.
    public static func areaIndex(for window: CGRect, in areas: [CGRect]) -> Int? {
        let center = CGPoint(x: window.midX, y: window.midY)
        if let i = areas.firstIndex(where: { $0.contains(center) }) { return i }
        let overlaps = areas.enumerated().map { ($0.offset, $0.element.intersection(window)) }
            .filter { !$0.1.isNull && $0.1.width * $0.1.height > 0 }
        return overlaps.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}

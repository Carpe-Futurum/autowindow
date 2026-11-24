import CoreGraphics

/// Edits to a saved layout from the Saved Layouts window. Frames passed in are global (display-arrangement) coordinates.
public extension Layout {
    func absoluteFrame(ofWindowAt index: Int) -> CGRect? {
        guard windows.indices.contains(index),
              let display = displays.first(where: { $0.uuid == windows[index].displayUUID }) else { return nil }
        return Geometry.absolute(windows[index].relativeFrame, on: display)
    }

    /// Puts a window at `frame`. It moves to the display holding the frame's center and is shrunk/shifted to fit it.
    mutating func place(windowAt index: Int, frame: CGRect) {
        guard windows.indices.contains(index),
              let display = Geometry.display(for: frame, in: displays)
                ?? displays.first(where: { $0.uuid == windows[index].displayUUID }) else { return }
        setRelativeFrame(Geometry.relative(frame, to: display), display: display.uuid, forWindowAt: index)
    }

    /// Sets a window's frame relative to a display's top-left corner, fitted to that display.
    mutating func setRelativeFrame(_ relative: CGRect, display uuid: String, forWindowAt index: Int) {
        guard windows.indices.contains(index), let display = displays.first(where: { $0.uuid == uuid }) else { return }
        let fitted = Geometry.relative(Geometry.absolute(relative, on: display), to: display)
        windows[index].displayUUID = uuid
        windows[index].relativeFrame = fitted.rounded
    }

    mutating func arrange(windowAt index: Int, _ arrangement: Arrangement) {
        guard windows.indices.contains(index),
              let display = displays.first(where: { $0.uuid == windows[index].displayUUID }) else { return }
        let frame = arrangement.frame(current: windows[index].relativeFrame.size, in: display.bounds.size)
        setRelativeFrame(frame, display: display.uuid, forWindowAt: index)
    }

    /// Edge positions windows snap to: every display's edges and center, and the other windows' edges.
    func snapTargets(excluding index: Int?) -> (x: [CGFloat], y: [CGFloat]) {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for d in displays {
            xs += [d.bounds.minX, d.bounds.midX, d.bounds.maxX]
            ys += [d.bounds.minY, d.bounds.midY, d.bounds.maxY]
        }
        for i in windows.indices where i != index {
            guard let f = absoluteFrame(ofWindowAt: i) else { continue }
            xs += [f.minX, f.maxX]
            ys += [f.minY, f.maxY]
        }
        return (xs, ys)
    }
}

/// One-click placements on a window's own display (display-relative frames).
public enum Arrangement: String, CaseIterable, Sendable {
    case fill, leftHalf, rightHalf, topHalf, bottomHalf, center

    public func frame(current size: CGSize, in display: CGSize) -> CGRect {
        let w = display.width, h = display.height
        switch self {
        case .fill: return CGRect(x: 0, y: 0, width: w, height: h)
        case .leftHalf: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .topHalf: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        case .center:
            let s = CGSize(width: min(size.width, w), height: min(size.height, h))
            return CGRect(x: (w - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height)
        }
    }
}

/// Which edges a resize drag moves.
public struct Edges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = Edges(rawValue: 1)
    public static let right = Edges(rawValue: 2)
    public static let top = Edges(rawValue: 4)
    public static let bottom = Edges(rawValue: 8)
}

public enum Snap {
    public static let minimumSize = CGSize(width: 160, height: 100)

    /// Shifts a moved frame so its nearest edge (or center) lands on a target within `threshold`.
    public static func move(_ frame: CGRect, targets: (x: [CGFloat], y: [CGFloat]), threshold: CGFloat) -> CGRect {
        let dx = bestOffset([frame.minX, frame.midX, frame.maxX], targets.x, threshold)
        let dy = bestOffset([frame.minY, frame.midY, frame.maxY], targets.y, threshold)
        return frame.offsetBy(dx: dx, dy: dy)
    }

    /// Resizes `original` by `translation` on `edges`, snapping each moving edge and keeping a minimum size.
    public static func resize(_ original: CGRect, edges: Edges, translation: CGSize,
                              targets: (x: [CGFloat], y: [CGFloat]), threshold: CGFloat) -> CGRect {
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
        if edges.contains(.left) { minX = snapped(minX + translation.width, targets.x, threshold) }
        if edges.contains(.right) { maxX = snapped(maxX + translation.width, targets.x, threshold) }
        if edges.contains(.top) { minY = snapped(minY + translation.height, targets.y, threshold) }
        if edges.contains(.bottom) { maxY = snapped(maxY + translation.height, targets.y, threshold) }
        if maxX - minX < minimumSize.width {
            if edges.contains(.left) { minX = maxX - minimumSize.width } else { maxX = minX + minimumSize.width }
        }
        if maxY - minY < minimumSize.height {
            if edges.contains(.top) { minY = maxY - minimumSize.height } else { maxY = minY + minimumSize.height }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func snapped(_ value: CGFloat, _ targets: [CGFloat], _ threshold: CGFloat) -> CGFloat {
        value + bestOffset([value], targets, threshold)
    }

    /// Smallest shift that puts one of `points` on one of `targets`, or 0 if none is within `threshold`.
    static func bestOffset(_ points: [CGFloat], _ targets: [CGFloat], _ threshold: CGFloat) -> CGFloat {
        var best: CGFloat = 0, bestDistance = threshold
        for p in points {
            for t in targets where abs(t - p) <= bestDistance {
                best = t - p
                bestDistance = abs(t - p)
            }
        }
        return best
    }
}

extension CGRect {
    var rounded: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

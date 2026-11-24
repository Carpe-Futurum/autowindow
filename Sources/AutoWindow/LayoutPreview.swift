import AppKit
import AutoWindowCore
import SwiftUI

/// Scaled, editable drawing of a saved layout: every display in its saved arrangement,
/// every window where it was saved. Drag a window to move it, drag the selected window's
/// handles to resize; edges snap to displays and other windows (hold ⌘ to turn snapping off).
struct LayoutPreview: View {
    @Binding var layout: AutoWindowCore.Layout
    @Binding var selected: Int?
    /// Only show windows on this desktop (displays with a single desktop always show everything).
    var desktop: Int? = nil
    /// Called once before each edit gesture, so the caller can record an undo step.
    var willEdit: () -> Void = {}

    @State private var gestureOrigin: CGRect?
    @State private var activeIndex: Int?
    @FocusState private var focused: Bool

    private static let space = "preview"
    private static let snapDistance: CGFloat = 8 // view points

    var body: some View {
        GeometryReader { geo in
            let map = PreviewMapper(displays: layout.displays, size: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil; focused = true }
                ForEach(layout.displays, id: \.uuid) { display in
                    let r = map.rect(display.bounds)
                    DisplayTile(display: display)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { selected = nil; focused = true }
                }
                // Big windows first, so small ones stay visible on top (z-order isn't saved).
                ForEach(drawOrder, id: \.self) { index in
                    if let frame = layout.absoluteFrame(ofWindowAt: index) {
                        let r = map.rect(frame)
                        WindowTile(
                            record: layout.windows[index],
                            desktopBadge: layout.spaceCount(forDisplay: layout.windows[index].displayUUID) > 1
                                ? layout.windows[index].spaceIndex : nil,
                            isSelected: index == selected,
                            sizeBadge: index == activeIndex ? "\(Int(frame.width)) × \(Int(frame.height))" : nil
                        )
                        .frame(width: max(r.width, 4), height: max(r.height, 4))
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { selected = index; focused = true }
                        .gesture(moveGesture(index, map))
                        .help(tooltip(index))
                    }
                }
                // Display names above windows, so they never get hidden.
                ForEach(layout.displays, id: \.uuid) { display in
                    let r = map.rect(display.bounds)
                    DisplayLabel(display: display)
                        .frame(width: r.width, height: r.height, alignment: .bottomLeading)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
                if let index = selected, isVisible(index), let frame = layout.absoluteFrame(ofWindowAt: index) {
                    ResizeHandles(rect: map.rect(frame)) { edges in resizeGesture(index, edges, map) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: Self.space)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            nudge(press) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard selected != nil else { return .ignored }
            selected = nil
            return .handled
        }
    }

    private func isVisible(_ i: Int) -> Bool {
        guard layout.windows.indices.contains(i) else { return false }
        guard let desktop else { return true }
        let r = layout.windows[i]
        return layout.spaceCount(forDisplay: r.displayUUID) <= 1 || (r.spaceIndex ?? 1) == desktop
    }

    private var drawOrder: [Int] {
        layout.windows.indices.filter(isVisible).sorted {
            if $0 == selected || $1 == selected { return $1 == selected }
            let a = layout.windows[$0].relativeFrame, b = layout.windows[$1].relativeFrame
            return a.width * a.height > b.width * b.height
        }
    }

    private func tooltip(_ index: Int) -> String {
        let r = layout.windows[index]
        let title = r.title.isEmpty ? "" : " — \(r.title)"
        return "\(r.appName)\(title)\n\(Int(r.relativeFrame.width)) × \(Int(r.relativeFrame.height)) at \(Int(r.relativeFrame.minX)), \(Int(r.relativeFrame.minY))"
    }

    private func threshold(_ map: PreviewMapper) -> CGFloat {
        NSEvent.modifierFlags.contains(.command) ? 0 : Self.snapDistance / max(map.scale, 0.0001)
    }

    private func begin(_ index: Int) -> CGRect? {
        if gestureOrigin == nil {
            gestureOrigin = layout.absoluteFrame(ofWindowAt: index)
            guard gestureOrigin != nil else { return nil }
            willEdit()
            selected = index
            activeIndex = index
            focused = true
        }
        return gestureOrigin
    }

    private func end() {
        gestureOrigin = nil
        activeIndex = nil
    }

    private func moveGesture(_ index: Int, _ map: PreviewMapper) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let origin = begin(index) else { return }
                let moved = origin.offsetBy(dx: value.translation.width / map.scale, dy: value.translation.height / map.scale)
                let snapped = Snap.move(moved, targets: layout.snapTargets(excluding: index), threshold: threshold(map))
                layout.place(windowAt: index, frame: snapped)
            }
            .onEnded { _ in end() }
    }

    private func resizeGesture(_ index: Int, _ edges: Edges, _ map: PreviewMapper) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let origin = begin(index) else { return }
                let t = CGSize(width: value.translation.width / map.scale, height: value.translation.height / map.scale)
                let frame = Snap.resize(origin, edges: edges, translation: t,
                                        targets: layout.snapTargets(excluding: index), threshold: threshold(map))
                // Keep the window on its own display while resizing, even if its center crosses over.
                let uuid = layout.windows[index].displayUUID
                if let display = layout.displays.first(where: { $0.uuid == uuid }) {
                    layout.setRelativeFrame(Geometry.relative(frame, to: display), display: uuid, forWindowAt: index)
                }
            }
            .onEnded { _ in end() }
    }

    /// Arrow keys move the selected window 10 pt, 1 pt with Shift.
    private func nudge(_ press: KeyPress) -> Bool {
        guard let index = selected, let frame = layout.absoluteFrame(ofWindowAt: index) else { return false }
        let step: CGFloat = press.modifiers.contains(.shift) ? 1 : 10
        let (dx, dy): (CGFloat, CGFloat) = switch press.key {
        case .leftArrow: (-step, 0)
        case .rightArrow: (step, 0)
        case .upArrow: (0, -step)
        default: (0, step)
        }
        willEdit()
        layout.place(windowAt: index, frame: frame.offsetBy(dx: dx, dy: dy))
        return true
    }
}

/// Eight grab handles around the selected window: corners resize both ways, sides one way.
private struct ResizeHandles<G: Gesture>: View {
    let rect: CGRect
    let gesture: (Edges) -> G

    private static var handles: [(Edges, UnitPoint)] { [
        ([.left, .top], .topLeading), ([.top], .top), ([.right, .top], .topTrailing), ([.right], .trailing),
        ([.right, .bottom], .bottomTrailing), ([.bottom], .bottom), ([.left, .bottom], .bottomLeading), ([.left], .leading),
    ] }

    private static func cursor(_ edges: Edges) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.left, .top]: .topLeft
            case [.right, .top]: .topRight
            case [.left, .bottom]: .bottomLeft
            case [.right, .bottom]: .bottomRight
            case [.top]: .top
            case [.bottom]: .bottom
            case [.left]: .left
            default: .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if edges == [.left] || edges == [.right] { return .resizeLeftRight }
        if edges == [.top] || edges == [.bottom] { return .resizeUpDown }
        return .crosshair
    }

    var body: some View {
        ForEach(Self.handles, id: \.0.rawValue) { edges, point in
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .padding(5) // bigger hit area than the dot
                .contentShape(Rectangle())
                .onHover { inside in if inside { Self.cursor(edges).push() } else { NSCursor.pop() } }
                .gesture(gesture(edges))
                .position(x: rect.minX + rect.width * point.x, y: rect.minY + rect.height * point.y)
        }
    }
}

/// Maps global display coordinates into the preview's view space, keeping aspect ratio.
struct PreviewMapper {
    let union: CGRect
    let scale: CGFloat
    let origin: CGPoint

    init(displays: [DisplaySnapshot], size: CGSize, padding: CGFloat = 12) {
        let u = displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        union = u.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : u
        scale = max(0, min((size.width - 2 * padding) / union.width, (size.height - 2 * padding) / union.height))
        origin = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(
            x: origin.x + (r.minX - union.minX) * scale,
            y: origin.y + (r.minY - union.minY) * scale,
            width: r.width * scale,
            height: r.height * scale
        )
    }
}

private struct DisplayTile: View {
    let display: DisplaySnapshot

    var body: some View {
        // Color.clear sets the size; the wallpaper fills it without growing the tile.
        Color.clear
            .overlay {
                if let image = Wallpapers.image(forDisplayUUID: display.uuid) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.6), lineWidth: 1))
    }
}

private struct DisplayLabel: View {
    let display: DisplaySnapshot

    var body: some View {
        Text(display.name + (display.isMain ? " · main" : ""))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)
    }
}

private struct WindowTile: View {
    let record: WindowRecord
    var desktopBadge: Int?
    let isSelected: Bool
    var sizeBadge: String?

    var body: some View {
        GeometryReader { geo in
            let bar = min(max(geo.size.height * 0.12, 4), 14)
            VStack(spacing: 0) {
                AppTint.color(for: record.bundleID).frame(height: bar)
                ZStack {
                    // Opaque, so overlapping windows don't bleed through each other.
                    Color(nsColor: .windowBackgroundColor)
                    AppTint.color(for: record.bundleID).opacity(0.12)
                    if geo.size.width > 28, geo.size.height > 24 {
                        HStack(spacing: 4) {
                            Image(nsImage: AppIcons.icon(for: record.bundleID))
                                .resizable()
                                .frame(width: min(28, geo.size.height * 0.4), height: min(28, geo.size.height * 0.4))
                            if geo.size.width > 90 {
                                Text(record.appName)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.accentColor : .black.opacity(0.35), lineWidth: isSelected ? 2.5 : 0.75)
            )
            .overlay(alignment: .topTrailing) {
                if let desktopBadge, bar >= 8 {
                    Text("\(desktopBadge)")
                        .font(.system(size: max(7, bar - 4), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(height: bar)
                        .help("Desktop \(desktopBadge)")
                }
            }
            .overlay(alignment: .top) {
                if let sizeBadge {
                    Text(sizeBadge)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, bar + 3)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0.45 : 0.3), radius: isSelected ? 5 : 2, y: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
    }
}

/// A stable colour per app (String.hashValue changes every launch, so hash by hand).
enum AppTint {
    static func color(for bundleID: String) -> Color {
        var h: UInt32 = 5381
        for b in bundleID.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            ?? NSImage()
        cache[bundleID] = icon
        return icon
    }
}

@MainActor
enum Wallpapers {
    private static var cache: [String: NSImage?] = [:]

    /// Wallpaper of a connected display, downscaled; nil if not connected or not a plain image.
    static func image(forDisplayUUID uuid: String) -> NSImage? {
        if let hit = cache[uuid] { return hit }
        let image = Displays.screen(forUUID: uuid)
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .flatMap { thumbnail(of: $0) }
        cache[uuid] = image
        return image
    }

    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

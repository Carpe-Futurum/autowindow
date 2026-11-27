import AppKit
import ApplicationServices
import AutoWindowCore
import SwiftUI

/// Rest the pointer on a window's green button and a small panel of snap positions appears beside it;
/// click one to snap that window. The same idea as Magnet's green button menu.
///
/// macOS offers no way to add items to another app's green-button menu, so this watches the pointer,
/// asks Accessibility what is under it, and shows a panel of its own that never takes focus.
@MainActor
enum GreenButtonPanel {
    /// Shorter than macOS waits before its own menu, so the cover is up first and that menu never opens.
    static let hoverDelay: TimeInterval = 0.25

    private static var monitor: Any?
    private static var pending: DispatchWorkItem?
    private static var panel: NSPanel?
    /// A see-through window over the green button. With it there, the app sees the pointer leave its button,
    /// so macOS doesn't open its own, shorter menu: the list replaces it, as in Magnet.
    /// A click on it still does what the green button does.
    private static var cover: NSPanel?
    private static var poll: Timer?
    /// The green button's frame in AppKit coordinates, so the panel stays while the pointer is on it.
    private static var buttonRect: CGRect = .zero

    static func setEnabled(_ enabled: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide()
        guard enabled else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            MainActor.assumeIsolated { pointerMoved() }
        }
    }

    private static func pointerMoved() {
        guard panel == nil else { return } // the poll handles a visible panel
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { checkUnderPointer() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    private static func checkUnderPointer() {
        guard AXWindow.isTrusted, panel == nil,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let mouse = NSEvent.mouseLocation
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(mouse.x), Float(primaryHeight - mouse.y), &hit) == .success,
              let hit, isGreenButton(hit),
              let windowElement: AXUIElement = copy(hit, kAXWindowAttribute) else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              !app.bundleIdentifier.map(WindowManager.userIgnored.contains).orFalse else { return }
        let window = AXWindow(element: windowElement, app: app)
        guard window.isStandard, let button = frameOf(hit) else { return }
        // AX top-left to AppKit bottom-left.
        buttonRect = CGRect(x: button.minX, y: primaryHeight - button.maxY, width: button.width, height: button.height)
        show(for: window, button: hit)
    }

    /// Windows that can go full screen report the green button as a full-screen button.
    private static func isGreenButton(_ element: AXUIElement) -> Bool {
        let subrole: String? = copy(element, kAXSubroleAttribute)
        return subrole == (kAXZoomButtonSubrole as String) || subrole == (kAXFullScreenButtonSubrole as String)
    }

    // MARK: - Panel

    private static func show(for window: AXWindow, button: AXUIElement) {
        let multipleDisplays = NSScreen.screens.count > 1
        let view = SnapPalette(showDisplayMoves: multipleDisplays) { action in
            hide()
            Snapper.perform(action, window: window)
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = makePanel(CGRect(origin: .zero, size: size))
        p.contentView = host

        // Where macOS shows its own menu: just under the green button.
        var origin = CGPoint(x: buttonRect.minX - 6, y: buttonRect.minY - 4 - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonRect.origin) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        panel = p

        let c = makePanel(CGRect(origin: .zero, size: buttonRect.size))
        c.backgroundColor = NSColor(white: 0, alpha: 0.001) // fully clear windows let clicks through
        c.hasShadow = false
        c.contentView = ClickCatcher { hide(); AXUIElementPerformAction(button, kAXPressAction as CFString) }
        c.setFrame(buttonRect, display: false)
        c.orderFrontRegardless()
        cover = c

        // Close once the pointer has left both the button and the panel for a moment.
        var away = 0
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                let m = NSEvent.mouseLocation
                // The gap between button and panel counts as "on it", so moving across doesn't close it.
                let zone = panel.frame.union(buttonRect).insetBy(dx: -6, dy: -6)
                away = zone.contains(m) ? 0 : away + 1
                if away >= 3 { hide() }
            }
        }
    }

    private static func makePanel(_ rect: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return p
    }

    private static func hide() {
        poll?.invalidate()
        poll = nil
        cover?.orderOut(nil)
        cover = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - AX helpers

    private static func copy<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

/// Takes a click, even though its app isn't active.
private final class ClickCatcher: NSView {
    let onClick: () -> Void
    init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

/// A list like the menu bar's Snap Front Window menu: picture, name, shortcut.
private struct SnapPalette: View {
    let showDisplayMoves: Bool
    let snap: (SnapAction) -> Void

    private var groups: [[SnapAction]] {
        [
            [.left, .right, .top, .bottom],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftThird, .leftTwoThirds, .centerThird, .rightTwoThirds, .rightThird],
        ] + (showDisplayMoves ? [[.nextDisplay, .previousDisplay]] : []) + [
            [.maximize, .center, .restore],
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                if i > 0 { Divider().padding(.vertical, 4).padding(.horizontal, 6) }
                ForEach(group, id: \.self) { action in
                    SnapRow(action: action) { snap(action) }
                }
            }
        }
        .padding(5)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct SnapRow: View {
    let action: SnapAction
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                SnapPicture(action: action, highlighted: hovering)
                Text(action.title)
                Spacer(minLength: 12)
                Text(Snapper.shortcutLabel(for: action))
                    .foregroundStyle(hovering ? .white.opacity(0.85) : .secondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small screen with the part the action fills.
private struct SnapPicture: View {
    let action: SnapAction
    let highlighted: Bool
    private let w: CGFloat = 20, h: CGFloat = 13

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill((highlighted ? Color.white : .primary).opacity(0.3))
            part
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder private var part: some View {
        switch action {
        case .restore: fill(CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4))
        case .center: fill(CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6))
        case .nextDisplay, .previousDisplay:
            Image(systemName: action == .nextDisplay ? "arrow.right" : "arrow.left")
                .font(.system(size: 9, weight: .bold)).frame(width: w, height: h)
        default:
            let r = WindowSnap.frame(action, window: .zero, in: CGRect(x: 0, y: 0, width: 300, height: 300)) ?? .zero
            fill(CGRect(x: r.minX / 300 * w, y: r.minY / 300 * h, width: r.width / 300 * w, height: r.height / 300 * h))
        }
    }

    private func fill(_ r: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(highlighted ? Color.white : .primary)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }
}

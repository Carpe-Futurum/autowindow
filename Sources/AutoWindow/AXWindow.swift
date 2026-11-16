import AppKit
import ApplicationServices

/// Thin wrapper around an Accessibility window element.
struct AXWindow {
    let element: AXUIElement
    let app: NSRunningApplication

    var title: String { (attribute(kAXTitleAttribute) as String?) ?? "" }
    var isMinimized: Bool { (attribute(kAXMinimizedAttribute) as Bool?) ?? false }
    var isStandard: Bool { (attribute(kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String) }

    var frame: CGRect? {
        guard let pos: CGPoint = value(kAXPositionAttribute, .cgPoint),
              let size: CGSize = value(kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Size, then position, then size again: some apps clamp size to the screen the window is on at the time.
    func setFrame(_ frame: CGRect) {
        withEnhancedUIDisabled {
            set(kAXSizeAttribute, frame.size, .cgSize)
            set(kAXPositionAttribute, frame.origin, .cgPoint)
            set(kAXSizeAttribute, frame.size, .cgSize)
        }
    }

    /// Standard, non-minimized windows of an app, in AX order (front to back).
    static func windows(of app: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
            .map { AXWindow(element: $0, app: app) }
            .filter { $0.isStandard && !$0.isMinimized }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Private

    private func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func value<T>(_ name: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(axValue, type, pointer) ? pointer.pointee : nil
    }

    private func set(_ name: String, _ value: CGPoint, _ type: AXValueType) {
        var v = value
        guard let axValue = AXValueCreate(type, &v) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, axValue)
    }

    private func set(_ name: String, _ value: CGSize, _ type: AXValueType) {
        var v = value
        guard let axValue = AXValueCreate(type, &v) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, axValue)
    }

    /// Apps with AXEnhancedUserInterface on (often due to VoiceOver-like tools) animate and fight AX moves.
    private func withEnhancedUIDisabled(_ body: () -> Void) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let key = "AXEnhancedUserInterface" as CFString
        var raw: CFTypeRef?
        let wasOn = AXUIElementCopyAttributeValue(appElement, key, &raw) == .success && (raw as? Bool) == true
        if wasOn { AXUIElementSetAttributeValue(appElement, key, kCFBooleanFalse) }
        body()
        if wasOn { AXUIElementSetAttributeValue(appElement, key, kCFBooleanTrue) }
    }
}

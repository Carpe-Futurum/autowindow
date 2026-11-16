import AutoWindowCore
import CoreGraphics
import Foundation
import Testing

private let laptop = DisplaySnapshot(uuid: "A", name: "Built-in", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
private let external = DisplaySnapshot(uuid: "B", name: "Studio Display", bounds: CGRect(x: 1512, y: -500, width: 2560, height: 1440), isMain: false)

@Test func signatureIgnoresOrder() {
    #expect(Layout.signature(for: [laptop, external]) == Layout.signature(for: [external, laptop]))
}

@Test func displayForWindowUsesCenter() {
    let frame = CGRect(x: 1400, y: 0, width: 800, height: 600) // center at x=1800 -> external
    #expect(Geometry.display(for: frame, in: [laptop, external])?.uuid == "B")
}

@Test func relativeRoundTrip() {
    let frame = CGRect(x: 1600, y: -400, width: 1000, height: 800)
    let rel = Geometry.relative(frame, to: external)
    #expect(rel == CGRect(x: 88, y: 100, width: 1000, height: 800))
    #expect(Geometry.absolute(rel, on: external) == frame)
}

@Test func absoluteFollowsMovedDisplay() {
    var moved = external
    moved.bounds.origin = CGPoint(x: -2560, y: 0) // user put the external on the left
    let rel = CGRect(x: 88, y: 100, width: 1000, height: 800)
    #expect(Geometry.absolute(rel, on: moved) == CGRect(x: -2472, y: 100, width: 1000, height: 800))
}

@Test func absoluteClampsToDisplay() {
    let rel = CGRect(x: 1000, y: 500, width: 2000, height: 600)
    let f = Geometry.absolute(rel, on: laptop)
    #expect(f.width == 1512)
    #expect(laptop.bounds.contains(f))
}

@Test func matcherPrefersTitleThenOrder() {
    func rec(_ title: String, _ i: Int) -> WindowRecord {
        WindowRecord(bundleID: "app", appName: "App", title: title, index: i, displayUUID: "A", relativeFrame: .zero)
    }
    let records = [rec("Inbox", 0), rec("Draft", 1), rec("Gone", 2)]
    let live = [
        LiveWindowInfo(bundleID: "app", title: "Draft", index: 0),
        LiveWindowInfo(bundleID: "app", title: "Other", index: 1),
        LiveWindowInfo(bundleID: "other", title: "Inbox", index: 0),
    ]
    let pairs = Dictionary(uniqueKeysWithValues: Matcher.match(records: records, live: live).map { ($0.0, $0.1.title) })
    #expect(pairs[0] == "Draft")
    #expect(pairs[1] == "Inbox") // leftover by order
    #expect(pairs[2] == nil)     // different app never matched
}

@Test func mergeKeepsQuitApps() {
    let old = Layout(signature: "s", name: "Desk", displays: [laptop], windows: [
        WindowRecord(bundleID: "quit", appName: "Q", title: "", index: 0, displayUUID: "A", relativeFrame: .zero),
        WindowRecord(bundleID: "run", appName: "R", title: "old", index: 0, displayUUID: "A", relativeFrame: .zero),
    ])
    let fresh = Layout(signature: "s", name: "auto", displays: [laptop], windows: [
        WindowRecord(bundleID: "run", appName: "R", title: "new", index: 0, displayUUID: "A", relativeFrame: .zero),
    ])
    let merged = old.merging(fresh, runningBundleIDs: ["run"])
    #expect(merged.name == "Desk")
    #expect(Set(merged.windows.map(\.title)) == ["", "new"])
}

@Test func storeRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("layouts.json")
    let layout = Layout(signature: "A+B", name: "Desk", displays: [laptop, external], windows: [])
    LayoutStore(fileURL: url).save(layout)
    #expect(LayoutStore(fileURL: url).layout(for: "A+B")?.name == "Desk")
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

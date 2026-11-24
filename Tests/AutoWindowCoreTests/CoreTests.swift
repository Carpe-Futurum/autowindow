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

// MARK: - Editing

private func editLayout() -> Layout {
    Layout(signature: "A+B", name: "Desk", displays: [laptop, external], windows: [
        WindowRecord(bundleID: "a", appName: "A", title: "", index: 0, displayUUID: "A", relativeFrame: CGRect(x: 100, y: 100, width: 800, height: 600)),
        WindowRecord(bundleID: "b", appName: "B", title: "", index: 0, displayUUID: "B", relativeFrame: CGRect(x: 0, y: 0, width: 1280, height: 1440)),
    ])
}

@Test func placeMovesWindowToDisplayUnderItsCenter() {
    var l = editLayout()
    l.place(windowAt: 0, frame: CGRect(x: 2000, y: -400, width: 800, height: 600)) // center on external
    #expect(l.windows[0].displayUUID == "B")
    #expect(l.windows[0].relativeFrame == CGRect(x: 488, y: 100, width: 800, height: 600))
}

@Test func placeFitsWindowInsideDisplay() {
    var l = editLayout()
    l.place(windowAt: 0, frame: CGRect(x: 1000, y: 500, width: 800, height: 600)) // center still on laptop, sticks out
    #expect(l.windows[0].displayUUID == "A")
    #expect(l.windows[0].relativeFrame == CGRect(x: 712, y: 382, width: 800, height: 600))
}

@Test func arrangeHalves() {
    var l = editLayout()
    l.arrange(windowAt: 1, .rightHalf)
    #expect(l.windows[1].relativeFrame == CGRect(x: 1280, y: 0, width: 1280, height: 1440))
    l.arrange(windowAt: 0, .center)
    #expect(l.windows[0].relativeFrame == CGRect(x: 356, y: 191, width: 800, height: 600))
}

@Test func moveSnapsNearestEdge() {
    let snapped = Snap.move(CGRect(x: 7, y: 300, width: 100, height: 100), targets: ([0, 500], [0]), threshold: 10)
    #expect(snapped.minX == 0)    // left edge 7 -> 0
    #expect(snapped.minY == 300)  // nothing near
}

@Test func resizeSnapsAndKeepsMinimum() {
    let r = Snap.resize(CGRect(x: 0, y: 0, width: 400, height: 300), edges: [.right, .bottom],
                        translation: CGSize(width: 95, height: -290), targets: ([500], []), threshold: 10)
    #expect(r.maxX == 500)                         // 495 snapped to 500
    #expect(r.height == Snap.minimumSize.height)   // can't collapse
}

// MARK: - Snapshots

@Test func matcherPrefersWindowID() {
    let records = [
        WindowRecord(bundleID: "app", appName: "App", title: "", index: 0, displayUUID: "A", relativeFrame: .zero, windowID: 42, spaceIndex: 3),
        WindowRecord(bundleID: "app", appName: "App", title: "", index: 1, displayUUID: "A", relativeFrame: .zero, windowID: 7, spaceIndex: 1),
    ]
    let live = [
        LiveWindowInfo(bundleID: "app", title: "", index: 0, windowID: 7),
        LiveWindowInfo(bundleID: "app", title: "", index: 1, windowID: 42),
    ]
    let pairs = Dictionary(uniqueKeysWithValues: Matcher.match(records: records, live: live).map { ($0.0, $0.1.windowID) })
    #expect(pairs[0] == 7)
    #expect(pairs[1] == 42)
}

@Test func oldLayoutsFileStillLoads() throws {
    let json = """
    [{"signature":"A","name":"Desk","displays":[],"updatedAt":"2026-11-16T10:00:00Z",
      "windows":[{"bundleID":"a","appName":"A","title":"","index":0,"displayUUID":"A","relativeFrame":[[0,0],[10,10]]}]}]
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("layouts.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
    let layout = try #require(LayoutStore(fileURL: url).layout(for: "A"))
    #expect(!layout.isSnapshot)
    #expect(layout.windows.first?.spaceIndex == nil)
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func snapshotsKeyedByIDSoSeveralPerDisplaySet() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshots.json")
    let store = LayoutStore(fileURL: url)
    for (id, name) in [("1", "Morning"), ("2", "Calls")] {
        var s = Layout(signature: "A+B", name: name, displays: [laptop, external], windows: [])
        s.id = id
        s.spaceCounts = ["A": 1, "B": 4]
        store.save(s)
    }
    let reloaded = LayoutStore(fileURL: url)
    #expect(reloaded.layouts.count == 2)
    #expect(reloaded.layout(for: "2")?.spaceCount(forDisplay: "B") == 4)
    #expect(reloaded.layout(for: "2")?.hasDesktops == true)
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

// MARK: - Hardening

@Test func unreadableEntryDoesNotHideTheRestAndIsKeptAside() throws {
    let json = """
    [{"signature":"A","name":"Good","displays":[],"updatedAt":"2026-11-16T10:00:00Z","windows":[]},
     {"signature":"B","name":"Bad","displays":"oops"}]
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("layouts.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
    let store = LayoutStore(fileURL: url)
    #expect(store.layout(for: "A")?.name == "Good")
    #expect(store.loadProblem != nil)
    let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: dir.appendingPathComponent(copies[0])) == Data(json.utf8))
    try FileManager.default.removeItem(at: dir)
}

@Test func notJSONIsKeptAsideNotOverwrittenBlind() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("snapshots.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let store = LayoutStore(fileURL: url)
    #expect(store.layouts.isEmpty)
    #expect(store.loadProblem != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("unreadable") })
    try FileManager.default.removeItem(at: dir)
}

@Test func windowIDsAreOnlyTrustedInTheSameBootSession() {
    var layout = Layout(signature: "s", name: "n", displays: [laptop], windows: [
        WindowRecord(bundleID: "a", appName: "A", title: "t", index: 0, displayUUID: "A", relativeFrame: .zero, windowID: 9),
    ])
    layout.session = 100
    #expect(layout.recordsForMatching(session: 100).first?.windowID == 9)
    #expect(layout.recordsForMatching(session: 200).first?.windowID == nil)
    layout.session = nil // saved by an older version
    #expect(layout.recordsForMatching(session: 100).first?.windowID == nil)
}

@Test func mergeDropsDeadWindowIDsOfAppsNotRunning() {
    let old = Layout(signature: "s", name: "Desk", displays: [laptop], windows: [
        WindowRecord(bundleID: "quit", appName: "Q", title: "", index: 0, displayUUID: "A", relativeFrame: .zero, windowID: 5),
    ])
    let fresh = Layout(signature: "s", name: "auto", displays: [laptop], windows: [])
    #expect(old.merging(fresh, runningBundleIDs: []).windows.first?.windowID == nil)
}

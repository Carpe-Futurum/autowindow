import AppKit
import AutoWindowCore
import SwiftUI

/// "Saved Layouts" window: pick a layout, see its displays and windows, edit positions, rename or forget it.
struct LayoutsWindow: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    /// The open layout has edits that aren't saved; switching away asks first.
    @State private var dirty = false

    var body: some View {
        NavigationSplitView {
            List(selection: guardedSelection) {
                Section("Snapshots") {
                    if model.snapshots.isEmpty {
                        Text("Save one with ⌘S in the menu").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshots, id: \.storeKey) { row($0).tag($0.storeKey) }
                }
                Section("Automatic") {
                    ForEach(model.layouts, id: \.storeKey) { row($0).tag($0.storeKey) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            if let layout = (model.snapshots + model.layouts).first(where: { $0.storeKey == selection }) {
                LayoutDetail(model: model, layout: layout, dirty: $dirty)
                    .id(layout.storeKey)
            } else {
                Text(model.layouts.isEmpty && model.snapshots.isEmpty ? "No saved layouts yet" : "Select a layout")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            if selection == nil {
                selection = model.snapshots.first { $0.signature == model.currentSignature }?.storeKey
                    ?? model.currentLayout?.storeKey ?? model.layouts.first?.storeKey
            }
        }
    }

    /// Selection that asks before throwing away unsaved edits.
    private var guardedSelection: Binding<String?> {
        Binding(
            get: { selection },
            set: { new in
                guard new != selection else { return }
                guard dirty else { selection = new; return }
                // Ask after this update pass; a modal alert inside a selection change confuses the list.
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Discard unsaved edits?"
                    alert.informativeText = "This layout has edits that haven't been applied or saved."
                    alert.addButton(withTitle: "Discard").hasDestructiveAction = true
                    alert.addButton(withTitle: "Keep Editing")
                    if alert.runModal() == .alertFirstButtonReturn {
                        dirty = false
                        selection = new
                    }
                }
            }
        )
    }

    private func row(_ layout: AutoWindowCore.Layout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(layout.name).lineLimit(1)
                if layout.signature == model.currentSignature, !layout.isSnapshot {
                    Text("current").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Group {
                if layout.isSnapshot {
                    let desktops = (layout.spaceCounts ?? [:]).values.reduce(0, +)
                    Text("\(layout.windows.count) windows · \(desktops) desktops")
                        + Text(layout.signature == model.currentSignature ? "" : " · other displays")
                } else {
                    Text("\(layout.displays.count) displays · \(layout.windows.count) windows")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One layout, edited as a draft: nothing is stored until Apply (current displays) or Save (other displays).
private struct LayoutDetail: View {
    @ObservedObject var model: AppModel
    let layout: AutoWindowCore.Layout
    @Binding var dirty: Bool

    @State private var draft: AutoWindowCore.Layout
    /// The stored windows the draft started from; the draft is "edited" when it differs.
    @State private var base: [WindowRecord]
    @State private var undoStack: [[WindowRecord]] = []
    @State private var name: String
    @State private var selectedWindow: Int?
    @State private var confirmForget = false
    @State private var showList = true
    /// Desktop shown in the picture for displays with several desktops; nil shows all at once.
    @State private var desktop: Int?

    init(model: AppModel, layout: AutoWindowCore.Layout, dirty: Binding<Bool>) {
        self.model = model
        self.layout = layout
        _dirty = dirty
        _draft = State(initialValue: layout)
        _base = State(initialValue: layout.windows)
        _name = State(initialValue: layout.name)
    }

    private var isCurrent: Bool { layout.signature == model.currentSignature }
    private var isEdited: Bool { draft.windows != base }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if draft.hasDesktops { desktopPicker }
                    LayoutPreview(layout: $draft, selected: $selectedWindow, desktop: desktop, willEdit: pushUndo)
                        .frame(minHeight: 440)
                        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Text("Drag a window to move it · drag its handles to resize · arrow keys nudge (⇧ for 1 pt) · hold ⌘ while dragging to stop snapping")
                        .font(.caption).foregroundStyle(.secondary)
                }
                inspector
                    .frame(width: 250)
            }
            .frame(maxHeight: .infinity)

            DisclosureGroup("Windows (\(draft.windows.count))", isExpanded: $showList) {
                windowTable.frame(height: 170)
            }
        }
        .padding()
        .onChange(of: layout.name) { _, fresh in
            // Renamed from the menu: follow it, or closing this window would rename it back.
            name = fresh
            draft.name = fresh
        }
        .onChange(of: layout) { _, fresh in
            // Autosave refreshes the stored layout; follow it unless the user is mid-edit.
            if !isEdited {
                // Window numbers are positions in the list: if the list changed, the selection means something else.
                if fresh.windows.map(\.windowID) != draft.windows.map(\.windowID) { selectedWindow = nil }
                draft = fresh
                base = fresh.windows
                undoStack = []
            }
        }
        .onChange(of: isEdited) { _, edited in dirty = edited }
        .onDisappear {
            commitName()
            // Still edited and nobody chose to discard: the window was closed. It can't be kept open from
            // here, so ask now rather than drop the edits silently.
            if isEdited, dirty { offerToSave(draft) }
            dirty = false
        }
        .confirmationDialog("Forget \"\(layout.name)\"?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                dirty = false
                model.forget(layout)
            }
        } message: {
            Text("The saved positions for these displays are deleted. Autosave starts a new layout next time these displays are connected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: 360)
                    .onSubmit(commitName)
                Group {
                    if isEdited {
                        Text("Edited — not saved yet").foregroundStyle(.orange)
                    } else {
                        Text("Updated \(layout.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z")
                .disabled(undoStack.isEmpty)
            Button("Revert") { revert() }
                .disabled(!isEdited)
            if layout.isSnapshot {
                Button(model.isRestoring ? "Restoring…" : "Restore") { model.restoreSnapshot(layout) }
                    .disabled(!isCurrent || isEdited || model.isRestoring)
                    .help(isCurrent ? "Put every window back on its display and desktop" : "Only possible with these displays connected")
            }
            Button(isCurrent ? "Apply" : "Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isEdited)
                .help(isCurrent ? "Save and move the open windows into place (⌘↩)" : "Save; windows move there next time these displays are connected (⌘↩)")
            Menu {
                if !layout.isSnapshot {
                    Button("Restore Saved Positions Now") { model.restoreNow() }
                        .disabled(!isCurrent || isEdited)
                    Divider()
                }
                Button(layout.isSnapshot ? "Delete Snapshot…" : "Forget Layout…", role: .destructive) { confirmForget = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var desktopPicker: some View {
        let most = (draft.spaceCounts ?? [:]).values.max() ?? 1
        return Picker("Desktop", selection: $desktop) {
            Text("All").tag(Int?.none)
            ForEach(1...max(most, 1), id: \.self) { Text("Desktop \($0)").tag(Int?.some($0)) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Displays with one desktop are always shown")
    }

    // MARK: - Inspector

    @ViewBuilder private var inspector: some View {
        if let index = selectedWindow, draft.windows.indices.contains(index) {
            WindowInspector(layout: $draft, index: index, willEdit: pushUndo) {
                pushUndo()
                draft.windows.remove(at: index)
                selectedWindow = nil
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No window selected").font(.headline)
                Text("Click a window in the picture or the list to see and edit its exact position and size.")
                    .font(.callout).foregroundStyle(.secondary)
                if isCurrent {
                    Text("These displays are connected now, so Apply moves your open windows straight into place.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("These displays aren't all connected. Save keeps the edits; windows move there the next time you connect them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Table

    private struct Row: Identifiable {
        let id: Int
        let record: WindowRecord
        let display: String
    }

    private var rows: [Row] {
        let names = Dictionary(draft.displays.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
        return draft.windows.enumerated()
            .map { Row(id: $0.offset, record: $0.element, display: names[$0.element.displayUUID] ?? "?") }
            .sorted { ($0.display, $0.record.appName) < ($1.display, $1.record.appName) }
    }

    private var windowTable: some View {
        Table(rows, selection: $selectedWindow) {
            TableColumn("App") { row in
                HStack(spacing: 6) {
                    Image(nsImage: AppIcons.icon(for: row.record.bundleID)).resizable().frame(width: 16, height: 16)
                    Text(row.record.appName)
                }
            }
            TableColumn("Window") { row in Text(row.record.title.isEmpty ? "—" : row.record.title).lineLimit(1) }
            TableColumn("Display") { row in
                Text(row.display + (row.record.spaceIndex.map { draft.spaceCount(forDisplay: row.record.displayUUID) > 1 ? " · Desktop \($0)" : "" } ?? ""))
            }
            TableColumn("Position") { row in
                // verbatim: an interpolated Text formats numbers for the locale ("1.280" in Dutch), wrong for coordinates.
                Text(verbatim: "\(Int(row.record.relativeFrame.minX)), \(Int(row.record.relativeFrame.minY))").monospacedDigit()
            }
            .width(80)
            TableColumn("Size") { row in
                Text(verbatim: "\(Int(row.record.relativeFrame.width)) × \(Int(row.record.relativeFrame.height))").monospacedDigit()
            }
            .width(90)
        }
    }

    // MARK: - Actions

    private func pushUndo() {
        undoStack.append(draft.windows)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        draft.windows = previous
        if let i = selectedWindow, !draft.windows.indices.contains(i) { selectedWindow = nil }
    }

    private func revert() {
        draft.windows = base
        undoStack = []
        if let i = selectedWindow, !draft.windows.indices.contains(i) { selectedWindow = nil }
    }

    private func save() {
        model.saveEdits(draft)
        base = draft.windows
        undoStack = []
    }

    private func offerToSave(_ edited: AutoWindowCore.Layout) {
        let model = model, verb = isCurrent ? "Apply" : "Save"
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(verb) your edits to \"\(edited.name)\"?"
            alert.informativeText = "You closed the window with edits that weren't applied or saved."
            alert.addButton(withTitle: verb)
            alert.addButton(withTitle: "Discard").hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { model.saveEdits(edited) }
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != layout.name else { return }
        model.rename(layout, to: trimmed)
        draft.name = trimmed
    }
}

/// Exact position and size of the selected window, its display, and one-click arrangements.
private struct WindowInspector: View {
    @Binding var layout: AutoWindowCore.Layout
    let index: Int
    let willEdit: () -> Void
    let onRemove: () -> Void

    private var record: WindowRecord { layout.windows[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: record.bundleID)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.appName).font(.headline).lineLimit(1)
                    Text(record.title.isEmpty ? "Untitled window" : record.title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Picker("Display", selection: displayBinding) {
                ForEach(layout.displays, id: \.uuid) { Text($0.name).tag($0.uuid) }
            }
            if layout.spaceCount(forDisplay: record.displayUUID) > 1 {
                Picker("Desktop", selection: desktopBinding) {
                    ForEach(1...layout.spaceCount(forDisplay: record.displayUUID), id: \.self) { Text("Desktop \($0)").tag($0) }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    field("X", \.origin.x)
                    field("Y", \.origin.y)
                }
                GridRow {
                    field("W", \.size.width)
                    field("H", \.size.height)
                }
            }
            Text("Points from the display's top-left corner.").font(.caption2).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Arrange").font(.subheadline.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    arrangeButton(.leftHalf, "rectangle.lefthalf.filled", "Left half")
                    arrangeButton(.fill, "rectangle.fill", "Fill display")
                    arrangeButton(.rightHalf, "rectangle.righthalf.filled", "Right half")
                    arrangeButton(.topHalf, "rectangle.tophalf.filled", "Top half")
                    arrangeButton(.center, "rectangle.center.inset.filled", "Center")
                    arrangeButton(.bottomHalf, "rectangle.bottomhalf.filled", "Bottom half")
                }
            }

            Spacer()

            Button("Remove from Layout", role: .destructive, action: onRemove)
                .help("AutoWindow stops placing this window. It comes back if autosave sees it open again.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: { record.displayUUID },
            set: { uuid in
                willEdit()
                layout.setRelativeFrame(record.relativeFrame, display: uuid, forWindowAt: index)
            }
        )
    }

    private var desktopBinding: Binding<Int> {
        Binding(
            get: { record.spaceIndex ?? 1 },
            set: { value in
                willEdit()
                layout.windows[index].spaceIndex = value
            }
        )
    }

    private func field(_ label: String, _ path: WritableKeyPath<CGRect, CGFloat>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(width: 14)
            TextField(label, value: Binding(
                get: { Double(record.relativeFrame[keyPath: path]) },
                set: { value in
                    willEdit()
                    var frame = record.relativeFrame
                    frame[keyPath: path] = CGFloat(value)
                    layout.setRelativeFrame(frame, display: record.displayUUID, forWindowAt: index)
                }
            ), format: .number.precision(.fractionLength(0)).grouping(.never))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
        }
    }

    private func arrangeButton(_ arrangement: Arrangement, _ symbol: String, _ help: String) -> some View {
        Button {
            willEdit()
            layout.arrange(windowAt: index, arrangement)
        } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 22)
        }
        .help(help)
    }
}

import AppKit
import SwiftUI
import ApplicationServices
// The desktop row under the display dropdown: reading Mission Control's desktops,
// a grid per desktop that stays with it when desktops are reordered, the editor
// showing a desktop you are not on, and the row's size. The desktops are made up
// here; no real desktop is read, switched or arranged.
@main struct DesktopSwitcherTests {
    @MainActor static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0); NSApplication.shared.setActivationPolicy(.accessory)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-desktops-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func desktop(_ managed: Int, _ uuid: String, type: Int = 0) -> [String: Any] { ["ManagedSpaceID": managed, "id64": managed, "type": type, "uuid": uuid] }
        func display(_ identifier: String, _ spaces: [[String: Any]], current: [String: Any]) -> [String: Any] { ["Display Identifier": identifier, "Spaces": spaces, "Current Space": current] }

        // What macOS reports: the main display is "Main", its first desktop has no
        // identifier, and a full-screen app is a Space too.
        let second = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let fullScreen = desktop(9, "FULL-SCREEN-APP", type: 4)
        let reported: [[String: Any]] = [
            display("Main", [desktop(1, ""), desktop(3, "AAAA-2"), fullScreen, desktop(5, "AAAA-3")], current: desktop(3, "AAAA-2")),
            display(second, [desktop(7, "BBBB-1"), desktop(8, "BBBB-2"), desktop(12, "MOVIE", type: 4)], current: desktop(12, "MOVIE", type: 4)),
            ["Display Identifier": 4, "Spaces": "damaged"]
        ]
        let parsed = DesktopSpaces.parse(reported, mainDisplay: "MAIN-UUID")
        precondition(parsed.count == 2 && parsed[0].display == "MAIN-UUID" && parsed[1].display == second, "\"Main\" is the main display's own identity; other displays are named by theirs; damaged entries are skipped")
        precondition(parsed[0].desktops == [DesktopSpace(id: DesktopSpaces.first, number: 1), DesktopSpace(id: "AAAA-2", number: 2), DesktopSpace(id: "AAAA-3", number: 3)], "desktops are numbered in Mission Control's order; the first, which has no identifier, gets a fixed one; full-screen apps are not desktops: \(parsed[0].desktops)")
        precondition(parsed[0].current == "AAAA-2" && parsed[1].current == nil && parsed[1].desktops.map(\.id) == ["BBBB-1", "BBBB-2"], "the desktop showing is known per display; a display showing a full-screen app is on no desktop")
        precondition(DesktopSpaces.parse([display("Main", [desktop(1, ""), desktop(3, "AAAA-2")], current: desktop(1, ""))], mainDisplay: "M")[0].current == DesktopSpaces.first, "the first desktop is recognized when it is the one showing")
        precondition(DesktopSpaces.desktops(of: second.lowercased(), in: parsed)?.desktops.count == 2 && DesktopSpaces.desktops(of: "MAIN-UUID", in: parsed)?.desktops.count == 3 && DesktopSpaces.desktops(of: "UNKNOWN", in: parsed) == nil, "each display finds its own desktops")
        precondition(DesktopSpaces.desktops(of: "ANY-DISPLAY", in: [parsed[0]])?.desktops.count == 3, "one list for every display (separate Spaces off) serves any display")
        // Dragging desktop 3 before desktop 2 in Mission Control: the numbers change, the identifiers do not.
        let reordered = DesktopSpaces.parse([display("Main", [desktop(1, ""), desktop(5, "AAAA-3"), desktop(3, "AAAA-2")], current: desktop(3, "AAAA-2"))], mainDisplay: "MAIN-UUID")[0]
        precondition(reordered.desktops == [DesktopSpace(id: DesktopSpaces.first, number: 1), DesktopSpace(id: "AAAA-3", number: 2), DesktopSpace(id: "AAAA-2", number: 3)] && reordered.current == "AAAA-2", "a reordered desktop keeps its identifier and gets a new number")
        precondition(DesktopSpaces.parse([display("Main", [["ManagedSpaceID": NSNumber(value: 4), "type": NSNumber(value: 0), "uuid": "N-1"]], current: ["ManagedSpaceID": NSNumber(value: 4), "type": NSNumber(value: 0), "uuid": "N-1"])], mainDisplay: "M")[0].current == "N-1", "numbers arrive as macOS sends them")
        print("PASS: Mission Control's desktops are read per display: Main, the unnamed first desktop, full-screen Spaces skipped, numbers from the order, identifiers from macOS")

        // Settings from before desktops had grids, and the storage itself.
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"capacities":{"terminal":2},"activeDisplayKey":"D1","displayLayouts":{"D1":{"kind":"wide","customRects":{},"capacities":{"terminal":2},"hiddenLanes":["browser"],"shelvedLanes":[],"showMediaShelf":true,"useCustomGrid":false,"stripPositions":{}}}}"#.utf8))
        precondition(old.spaceLayouts.isEmpty && old.activeSpaceKey == nil && old.displayLayouts["D1"] != nil && old.capacity(.terminal) == 2, "settings saved before this load with no desktop grids and everything else as it was")
        var store = old
        store.windowSplits["terminal"] = "rows"
        store.windowPaneSizes[WindowPaneSizes.key(.terminal, WindowArrangement(count: 2, split: .rows))] = WindowPaneSizes(columns: [1], rows: [0.3, 0.7])
        let carried = store.layoutInUse
        precondition(!store.switchSpace(to: "A") && store.activeSpaceKey == "A" && store.layoutInUse == carried && store.spaceLayouts.isEmpty, "the first desktop seen carries the grid in use forward: arrangements, splits and pane sizes, unchanged")
        precondition(!store.switchSpace(to: "B") && store.layoutInUse == carried && store.spaceLayouts.isEmpty, "a desktop with no grid of its own uses the one its display is showing, and saves nothing until a grid is applied on it")
        store.capacities["terminal"] = 4; store.keepSpaceLayout()
        precondition(store.spaceLayouts.keys.sorted() == ["D1|B"] && store.spaceLayout("B")?.capacities["terminal"] == 4, "an applied grid is saved under the display plus the desktop")
        precondition(store.switchSpace(to: "A") && store.capacity(.terminal) == 2 && store.spaceLayout("A") == nil, "an unused desktop starts from the display's original grid")
        store.capacities["terminal"] = 1; store.windowSplits["terminal"] = nil; store.keepSpaceLayout()
        precondition(store.switchSpace(to: "B") && store.capacity(.terminal) == 4 && store.split(.terminal) == .rows && store.windowPaneSizes == carried.windowPaneSizes, "going back to a desktop brings its own grid back, with its split and pane sizes")
        store.stripPositions["terminal"] = StripPosition(x: 0.2, y: 0.1)
        precondition(store.switchSpace(to: "A") && store.capacity(.terminal) == 1 && store.spaceLayout("B")?.stripPositions["terminal"] != nil && store.stripPositions["terminal"] == nil, "changes made on a desktop that has its own grid stay with it when you leave")
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(store))
        precondition(reloaded.spaceLayouts == store.spaceLayouts && reloaded.activeSpaceKey == "A", "desktop grids survive saving and loading")
        precondition(store.switchDisplay(to: "D2", kind: .wide) && store.activeSpaceKey == nil && store.spaceLayout("A") == nil && store.spaceLayouts["D1|A"]?.capacities["terminal"] == 1, "another display has desktops of its own: the grids of the display left behind stay under its name")
        // A category made after a desktop's grid was saved has no place in that grid.
        var later = Settings(); later.hiddenLanes = []; later.activeDisplayKey = "D1"
        later.customRects = Dictionary(uniqueKeysWithValues: later.enabledLanes.enumerated().map { ($1.rawValue, ZoneRect(CGRect(x: Double($0) / Double(later.enabledLanes.count), y: 0, width: 1 / Double(later.enabledLanes.count), height: 1))) })
        later.useCustomGrid = true
        let before = later.layoutInUse
        let research = CustomCategory(name: "Research"); later.customCategories.append(research)
        later.applySpaceLayout(before)
        precondition(!later.enabledLanes.contains(research.lane) && later.shelvedLanes.contains(research.id) && GridGeometry.valid(later.customRects, lanes: later.enabledLanes), "a category made later waits on the shelf of a desktop whose grid was saved before it")
        print("PASS: a grid per desktop: carried forward, saved on Apply under display plus desktop, restored on return, old settings unchanged")

        // The manager, with made-up desktops on whatever display this Mac has.
        func manager(_ file: String) -> WindowManager {
            let m = WindowManager(settingsFile: dir.appendingPathComponent(file), startPolling: false)
            m.trusted = false; m.settings.hiddenLanes = []
            m.syncDisplayLayout()
            return m
        }
        let m = manager("desktops.json")
        guard m.screen != nil, let displayKey = m.settings.activeDisplayKey else { print("SKIP: no display to place desktops on"); return }
        precondition(m.desktops.isEmpty && m.activeDesktop == nil && m.settings.activeSpaceKey == nil && !DesktopRow.isShown(m), "a test manager reads no real desktops, and without desktops Lanes works as before")
        func key(_ space: String) -> String { Settings.spaceLayoutKey(display: displayKey, space: space) }
        var spaces = [desktop(1, ""), desktop(3, "AAAA-2"), fullScreen, desktop(5, "AAAA-3")], current = desktop(3, "AAAA-2")
        m.spacesAccess = SpacesAccess(read: { [display("Main", spaces, current: current)] })
        func go(to space: [String: Any]) { current = space; m.syncDesktops() }
        func count(_ manager: WindowManager = m) -> Int { manager.settings.capacity(.terminal) }
        func shownCount() -> Int { m.grid.capacity(.terminal) }
        m.setCapacity(.terminal, 2)
        let inherited = m.settings.layoutInUse
        m.syncDesktops()
        precondition(m.desktops.map(\.number) == [1, 2, 3] && m.desktops.map(\.id) == [DesktopSpaces.first, "AAAA-2", "AAAA-3"] && DesktopRow.isShown(m), "the row lists the display's three desktops (not the full-screen app)")
        precondition(m.activeDesktop == "AAAA-2" && m.shownDesktop == "AAAA-2" && m.settings.activeSpaceKey == "AAAA-2" && !m.viewingOtherDesktop, "the desktop you are on is found and selected")
        precondition(m.settings.layoutInUse == inherited && m.settings.spaceLayouts.isEmpty && m.gridDraft == nil, "its grid is the one that was in use: nothing changes, nothing is saved yet")
        // Apply on Desktop 2 makes that grid Desktop 2's own.
        m.editGrid { m.setCapacity(.terminal, 3) }
        precondition(m.hasGridEdits && count() == 2)
        m.applyGridDraft()
        precondition(count() == 3 && m.settings.spaceLayouts.keys.sorted() == [key("AAAA-2")] && m.settings.spaceLayouts[key("AAAA-2")]?.capacities["terminal"] == 3, "Apply saves the grid for the desktop you are on, under the display plus that desktop")
        // Desktop 1 has no grid yet: it starts from the display's original grid, and Apply there is its own.
        go(to: desktop(1, ""))
        precondition(m.activeDesktop == DesktopSpaces.first && m.shownDesktop == DesktopSpaces.first && count() == 2 && m.settings.spaceLayouts.count == 1, "a desktop with no saved grid starts from the display's original grid")
        m.editGrid { m.setCapacity(.terminal, 1) }; m.applyGridDraft()
        precondition(count() == 1 && m.settings.spaceLayouts[key(DesktopSpaces.first)]?.capacities["terminal"] == 1 && m.settings.spaceLayouts[key("AAAA-2")]?.capacities["terminal"] == 3, "its first Apply saves a grid of its own and leaves Desktop 2's alone")
        go(to: desktop(3, "AAAA-2"))
        precondition(count() == 3 && m.shownDesktop == "AAAA-2" && m.status.contains("Desktop 2"), "going back to Desktop 2 puts its grid back in use and in the editor: \(m.status)")
        // Reordering in Mission Control: Desktop 2 becomes Desktop 1. Its grid goes with it.
        spaces = [desktop(3, "AAAA-2"), desktop(1, ""), fullScreen, desktop(5, "AAAA-3")]
        m.syncDesktops()
        precondition(m.desktops.map(\.id) == ["AAAA-2", DesktopSpaces.first, "AAAA-3"] && m.desktops.map(\.number) == [1, 2, 3] && m.desktopName("AAAA-2") == "Desktop 1" && m.activeDesktop == "AAAA-2" && count() == 3, "after a reorder the numbers follow Mission Control and the grid in use stays the same desktop's")
        go(to: desktop(1, ""))
        precondition(m.desktopName(m.activeDesktop) == "Desktop 2" && count() == 1, "the desktop that moved to second place still has the grid saved for it")
        go(to: desktop(3, "AAAA-2"))
        precondition(count() == 3, "and so does the one that moved to first place")
        print("PASS: the active desktop is selected, each desktop's Apply is its own, a desktop without a grid inherits, and a reorder keeps every grid with its desktop")
        // Strips stay on the desktops you organized: none on a desktop you never organized.
        precondition(!m.stripsBelongHere, "before organizing, no desktop shows strips")
        m.noteOrganizedHere()
        precondition(m.organizedDesktops == [key("AAAA-2")] && m.stripsBelongHere, "organizing on Desktop 1 (AAAA-2) gives it strips")
        go(to: desktop(1, ""))
        precondition(!m.stripsBelongHere, "the desktop you never organized shows none of them")
        go(to: desktop(3, "AAAA-2"))
        precondition(m.stripsBelongHere, "and they are back on the desktop you organized")
        print("PASS: strips show only on desktops you organized, and follow you between desktops")

        // The editor shows a desktop you are not on: Apply saves for it only.
        m.showDesktop(DesktopSpaces.first)
        precondition(m.shownDesktop == DesktopSpaces.first && m.activeDesktop == "AAAA-2" && m.viewingOtherDesktop && shownCount() == 1 && count() == 3 && !m.hasGridEdits, "clicking a number shows that desktop's saved grid in the editor; the screen keeps yours")
        m.syncDesktops()
        precondition(m.shownDesktop == DesktopSpaces.first && !m.hasGridEdits, "a refresh keeps the selected desktop while the actual Space stays the same")
        m.editGrid { m.setCapacity(.terminal, 4) }
        precondition(m.hasGridEdits && shownCount() == 4 && count() == 3)
        precondition(m.commitPendingGrid() && count() == 3 && shownCount() == 4 && m.hasGridEdits, "Organize uses the grid of the desktop you are on; the other desktop's changes stay in the editor")
        m.showDesktop("AAAA-3")
        precondition(m.shownDesktop == "AAAA-3" && !m.hasGridEdits && m.hasUnappliedChanges(on: DesktopSpaces.first))
        m.editGrid { m.setCapacity(.terminal, 2); m.settings.gap = 24 }
        let liveBefore = m.settings.layoutInUse
        m.showDesktop(DesktopSpaces.first)
        precondition(shownCount() == 4 && m.hasGridEdits && m.hasUnappliedChanges(on: "AAAA-3"))
        m.applyDisplayedGrid(organizeUnchanged: true)
        precondition(m.settings.layoutInUse == liveBefore && count() == 3, "Apply for a desktop you are not on changes nothing on this one")
        precondition(m.settings.spaceLayouts[key(DesktopSpaces.first)]?.capacities["terminal"] == 4 && m.settings.spaceLayouts[key("AAAA-2")]?.capacities["terminal"] == 3 && !m.hasGridEdits && shownCount() == 4 && m.viewingOtherDesktop, "and saves the grid for that desktop only")
        precondition(m.status.contains("Saved for Desktop 2") && m.status.contains("nothing on Desktop 1 moved"), "the status line says so: \(m.status)")
        m.showDesktop("AAAA-3")
        precondition(shownCount() == 2 && m.grid.gap == 24 && m.settings.layoutInUse == liveBefore)
        m.organizeFromBoard()
        precondition(m.settings.spaceLayout("AAAA-3")?.gap == 24 && m.settings.layoutInUse == liveBefore && !m.hasGridEdits)
        m.showDesktop(DesktopSpaces.first)
        m.editGrid { m.setCapacity(.terminal, 2) }
        m.discardGridDraft()
        precondition(!m.hasGridEdits && shownCount() == 4 && m.viewingOtherDesktop, "Discard goes back to that desktop's saved grid")
        // A preset previewed for another desktop is saved for it too.
        m.previewPreset(.columns)
        precondition(m.presetPreview != nil)
        let previewRects = m.presetPreview!.rects
        m.applyPresetPreview()
        precondition(m.presetPreview == nil && m.settings.layoutInUse == liveBefore && m.settings.spaceLayouts[key(DesktopSpaces.first)]?.customRects == previewRects, "a preset applied while another desktop is shown is saved for that desktop, not put on this one")
        go(to: desktop(1, ""))
        precondition(m.settings.customRects == previewRects && m.shownDesktop == DesktopSpaces.first && !m.viewingOtherDesktop && m.gridDraft == nil, "it is used once you are on that desktop")
        print("PASS: another desktop's grid opens in the editor, Apply saves it for that desktop only, Organize keeps to the desktop you are on")

        // Changing desktops while the editor holds changes: they stay, for the desktop they were made for.
        m.editGrid { m.setCapacity(.terminal, 2) }
        precondition(m.hasGridEdits && !m.viewingOtherDesktop)
        go(to: desktop(3, "AAAA-2"))
        precondition(m.activeDesktop == "AAAA-2" && count() == 3, "the grid in use follows the desktop you are on")
        precondition(m.shownDesktop == "AAAA-2" && !m.hasGridEdits && m.hasUnappliedChanges(on: DesktopSpaces.first),
                     "switching Spaces follows the active desktop and parks the outgoing draft")
        m.showDesktop(DesktopSpaces.first)
        precondition(m.viewingOtherDesktop && m.hasGridEdits && shownCount() == 2 && m.grid.customRects == previewRects)
        m.applyGridDraft()
        precondition(count() == 3 && m.settings.spaceLayouts[key(DesktopSpaces.first)]?.capacities["terminal"] == 2, "and Apply saves them for that desktop")
        // Without changes the editor follows you.
        m.showDesktop("AAAA-3")
        precondition(m.shownDesktop == "AAAA-3" && m.viewingOtherDesktop && !m.hasGridEdits)
        go(to: desktop(1, ""))
        precondition(m.shownDesktop == DesktopSpaces.first && !m.viewingOtherDesktop && count() == 2 && m.gridDraft == nil, "with nothing unapplied, the editor loads the desktop you moved to")
        // A full-screen app is no desktop: the last desktop stays.
        go(to: fullScreen)
        precondition(!m.stripsBelongHere, "an active full-screen Space never shows another desktop’s strips")
        precondition(m.activeDesktop == DesktopSpaces.first && count() == 2 && m.desktops.count == 3, "in a full-screen app the last desktop's grid stays in use")
        // A new desktop starts from the display's original grid; a removed one keeps its saved grid.
        spaces.append(desktop(20, "AAAA-4"))
        go(to: desktop(20, "AAAA-4"))
        precondition(m.desktops.count == 4 && m.desktopName("AAAA-4") == "Desktop 4" && count() == 2 && m.settings.spaceLayouts[key("AAAA-4")] == nil, "a new desktop appears in the row and starts from the display's original grid")
        spaces.removeAll { ($0["uuid"] as? String) == "AAAA-2" }
        go(to: desktop(1, ""))
        precondition(m.desktops.map(\.id) == [DesktopSpaces.first, "AAAA-3", "AAAA-4"] && m.settings.spaceLayouts[key("AAAA-2")] != nil, "a removed desktop leaves the row; its saved grid is kept")
        let restarted = WindowManager(settingsFile: dir.appendingPathComponent("desktops.json"), startPolling: false)
        precondition(restarted.settings.spaceLayouts == m.settings.spaceLayouts && restarted.settings.activeSpaceKey == DesktopSpaces.first && count(restarted) == 2, "desktop grids and the desktop in use survive a restart")
        // One desktop: no row; no desktops reported: as before.
        spaces = [desktop(1, "")]
        m.syncDesktops()
        precondition(m.desktops.count == 1 && !DesktopRow.isShown(m) && count() == 2, "with one desktop there is no row")
        m.spacesAccess = .none; m.syncDesktops()
        precondition(m.desktops.isEmpty && m.activeDesktop == nil && !m.viewingOtherDesktop && count() == 2, "if macOS reports no desktops, Lanes keeps one grid per display")
        print("PASS: unapplied changes survive a desktop change, the editor follows you otherwise, full-screen apps, new and removed desktops, restart")

        // Menus affect only the selected Space. Windows remembered from a previous
        // visit can be assigned from the editor without moving an off-Space window.
        let categories = manager("categories.json")
        let one = desktop(1, ""), two = desktop(3, "AAAA-2")
        var selected = one
        categories.spacesAccess = SpacesAccess(read: { [display("Main", [one, two], current: selected)] })
        categories.syncDesktops()
        let terminal = RunningAppSummary(pid: getpid(), name: "Terminal", bundleID: "com.apple.Terminal", icon: nil, lane: .terminal)
        func window(_ id: String) -> ManagedWindow {
            ManagedWindow(id: id, element: AXUIElementCreateApplication(getpid()), pid: terminal.pid, bundleID: terminal.bundleID,
                          appName: terminal.name, title: id, icon: nil, frame: .zero, minimized: false, lane: .terminal)
        }
        let pinned = window("one-pinned"), peer = window("one-peer"), other = window("two")
        categories.windows = [pinned, peer]
        categories.moveWindow(pinned, to: .terminal)
        categories.assignApp(terminal, to: .desktop)
        precondition(categories.items(.terminal).map(\.id) == [pinned.id] && categories.items(.desktop).map(\.id) == [peer.id],
                     "selecting the current category pins this window and takes priority over an app assignment")
        selected = two; categories.syncDesktops()
        precondition(categories.windows.isEmpty && categories.settings.appRules[terminal.bundleID] == nil, "the newly active desktop cannot inherit the previous window list or its pin")
        categories.windows = [other]
        categories.assignApp(terminal, to: .messaging)
        categories.showDesktop(DesktopSpaces.first)
        precondition(Set(categories.editorWindows.map(\.id)) == Set([pinned.id, peer.id]) && categories.items(.messaging).map(\.id) == [other.id])
        categories.setEditorWindowCategory(peer, to: .preview)
        categories.setEditorAppCategory(terminal, to: .browser)
        precondition(categories.hasGridEdits && categories.settings.appRules[terminal.bundleID] == Lane.messaging.rawValue)
        categories.applyGridDraft()
        selected = one; categories.syncDesktops()
        precondition(categories.settings.appRules[terminal.bundleID] == Lane.browser.rawValue && categories.settings.windowCategories[peer.id] == Lane.preview.rawValue)
        selected = two; categories.syncDesktops()
        let roundTrip = WindowManager(settingsFile: dir.appendingPathComponent("categories.json"), startPolling: false)
        precondition(roundTrip.settings.appRules[terminal.bundleID] == Lane.messaging.rawValue && roundTrip.settings.assignments(for: DesktopSpaces.first).appRules[terminal.bundleID] == Lane.browser.rawValue)
        precondition(WindowManager.discoverableWindow(onScreen: false, hidden: true, belongs: true, scoped: true))
        precondition(!WindowManager.discoverableWindow(onScreen: false, hidden: true, belongs: false, scoped: true))
        precondition(!WindowManager.discoverableWindow(onScreen: true, hidden: false, belongs: false, scoped: true))
        print("PASS: each desktop keeps its own app rules, window pins, and window inventory across switching and restart")

        // Desktop 2 and Desktop 3 have open windows before the first visit in
        // this session. App and window assignments stay on the chosen Space.
        let inactive = manager("inactive-inventory.json")
        let third = desktop(5, "AAAA-3")
        var liveSpace = one
        let editorTerminal = RunningAppSummary(pid: 99201, name: "Terminal", bundleID: "com.apple.Terminal", icon: nil, lane: .terminal)
        let editorFinder = RunningAppSummary(pid: 99202, name: "Finder", bundleID: "com.apple.finder", icon: nil, lane: .desktop)
        func serverWindow(_ number: UInt32, app: RunningAppSummary, layer: Int = 0, title: String? = nil) -> [String: Any] {
            let bounds: [String: CGFloat] = ["X": 300, "Y": 200, "Width": 500, "Height": 400]
            var info: [String: Any] = [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: app.pid,
                                       kCGWindowLayer as String: layer, kCGWindowBounds as String: bounds]
            info[kCGWindowName as String] = title
            return info
        }
        let records = [
            serverWindow(101, app: editorTerminal, title: "Build"),
            serverWindow(102, app: editorTerminal),
            serverWindow(103, app: editorFinder, title: "Project files"),
            serverWindow(104, app: editorFinder, title: "Shared"),
            serverWindow(105, app: editorTerminal, layer: 3)
        ]
        let memberships: [UInt32: Set<Int>] = [101: [3], 102: [3], 103: [5], 104: [3, 5], 105: [3]]
        inactive.spacesAccess = SpacesAccess(read: { [display("Main", [one, two, third], current: liveSpace)] },
                                             windowSpaces: { memberships[$0] }, readWindows: { records })
        inactive.syncDesktops()
        inactive.trusted = true
        inactive.refreshRunningApps()
        inactive.settings.onlyTargetScreen = false
        inactive.runningApps = [editorTerminal, editorFinder]
        func waitForEditorWindows(_ manager: WindowManager) {
            let deadline = Date(timeIntervalSinceNow: 3)
            while manager.loadingEditorWindows && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            precondition(!manager.loadingEditorWindows, "editor window read must finish")
        }
        inactive.showDesktop("AAAA-2")
        waitForEditorWindows(inactive)
        precondition(inactive.activeDesktop == DesktopSpaces.first && inactive.windows.isEmpty)
        precondition(inactive.editorApps.map(\.bundleID) == [editorTerminal.bundleID] &&
                     inactive.editorWindows.map(\.title) == ["Build", "Window 2"],
                     "Desktop 2 shows its existing apps and windows before visiting it")
        let preview = inactive.editorWindows[0], resetPreview = inactive.editorWindows[1]
        inactive.setEditorWindowCategory(preview, to: .browser)
        inactive.setEditorWindowCategory(resetPreview, to: nil)
        inactive.applyGridDraft()
        precondition(inactive.settings.windowCategories[preview.id] == nil && inactive.windows.isEmpty,
                     "saving a preview window's assignment cannot touch the active desktop")
        inactive.showDesktop("AAAA-3")
        waitForEditorWindows(inactive)
        precondition(inactive.activeDesktop == DesktopSpaces.first && inactive.editorApps.map(\.bundleID) == [editorFinder.bundleID] &&
                     inactive.editorWindows.map(\.title) == ["Project files"], "Desktop 3 has its own inventory and excludes shared windows")
        liveSpace = two; inactive.syncDesktops()
        precondition(inactive.adoptDesktopPreviewAssignment(pid: preview.pid, number: preview.windowNumber, id: "live-101"))
        precondition(inactive.settings.windowCategories["live-101"] == Lane.browser.rawValue &&
                     inactive.settings.windowCategories[preview.id] == nil && inactive.userPlaced.contains("live-101"),
                     "the saved editor assignment follows the same window when its real Space opens")
        inactive.settings.windowCategories["live-102"] = Lane.messaging.rawValue
        precondition(inactive.adoptDesktopPreviewAssignment(pid: resetPreview.pid, number: resetPreview.windowNumber, id: "live-102"))
        precondition(inactive.settings.windowCategories["live-102"] == nil && inactive.userPlaced.contains("live-102"),
                     "an offline reset also removes a previously saved live override")
        print("PASS: inactive desktops list already-open apps and windows before a visit")

        let shelf = manager("shelf-repeat.json")
        shelf.settings.hiddenLanes = Lane.allCases.filter { $0 != .terminal }.map(\.rawValue)
        shelf.editGrid {
            precondition(shelf.addShelfCategory(.desktop))
            precondition(shelf.receiveWorkspaceDrop(["shelf:desktop"], at: CGPoint(x: 750, y: 375),
                                                    in: CGSize(width: 1000, height: 500)))
            precondition(shelf.addShelfCategory(.desktop))
        }
        precondition(Set(shelf.grid.enabledLanes.map(shelf.gridName)).isSuperset(of: ["Desktop 1", "Desktop 2", "Desktop 3"]))
        precondition(shelf.settings.enabledLanes == [.terminal] && shelf.hasGridEdits, "repeat shelf additions are staged in the grid")
        let shared: [String: ZoneRect] = [
            "terminal": ZoneRect(CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            "desktop": ZoneRect(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        let isolated = GridGeometry.resizingOnly(shared, lane: .terminal, edge: .left, dx: 0.08, dy: 0, snap: false, floating: [])
        precondition(abs(isolated["terminal"]!.x - 0.08) < 0.0001 && isolated["desktop"] == shared["desktop"],
                     "Command-resize leaves left padding while preserving the neighboring tile")
        let blocked = GridGeometry.resizingOnly(shared, lane: .terminal, edge: .right, dx: 0.15, dy: 0, snap: false, floating: [])
        precondition(blocked["desktop"] == shared["desktop"] && blocked["terminal"]!.cgRect.maxX < 0.5001,
                     "an isolated edge cannot resize the neighbor or overlap it")
        let plain = manager("plain-grid.json")
        plain.settings.customCategories.append(CustomCategory(name: "Desktop 2"))
        plain.settings.shelvedLanes = plain.settings.customCategories.map(\.id)
        let plainLayout = plain.settings.layoutInUse
        plain.settings.customCategories.append(CustomCategory(name: "Terminal 2"))
        plain.settings.applySpaceLayout(plainLayout)
        precondition(plain.settings.enabledLanes.allSatisfy { !$0.isCustom },
                     "adding a category on one desktop cannot change an older grid with no custom rectangles")
        print("PASS: reusable shelf categories and Command-drag padding")

        let restore = manager("restore.json")
        let three = desktop(5, "AAAA-3")
        var restoreSpace = one
        var membership: [UInt32: Set<Int>] = [99101: [1], 99102: [3], 99103: [5], 99104: [1], 99105: [1], 99106: [1]]
        restore.spacesAccess = SpacesAccess(read: { [display("Main", [one, two, three, fullScreen], current: restoreSpace)] },
                                           windowSpaces: { membership[$0] },
                                           windowID: { element in
                                               var pid: pid_t = 0
                                               return AXUIElementGetPid(element, &pid) == .success ? UInt32(exactly: pid) : nil
                                           })
        func savedWindow(_ pid: pid_t, minimized: Bool = false) -> ManagedWindow {
            ManagedWindow(id: "restore-\(pid)", element: AXUIElementCreateApplication(pid), pid: pid, bundleID: "example.restore",
                          appName: "Restore fixture", title: "", icon: nil, frame: CGRect(x: Int(pid - 99000), y: 100, width: 400, height: 300),
                          minimized: minimized, lane: .terminal)
        }
        let firstWindow = savedWindow(99101, minimized: true), secondWindow = savedWindow(99102), thirdWindow = savedWindow(99103)
        let movedWindow = savedWindow(99104), sharedWindow = savedWindow(99105), unknownWindow = savedWindow(99106)
        var restored: [SavedWindow] = []
        func recordRestore(_ saved: SavedWindow) -> Bool { restored.append(saved); return true }
        restore.syncDesktops()
        restore.spacesAccess.tracksDesktops = true
        precondition(restore.windowCanMoveHere(firstWindow.element) && !restore.windowCanMoveHere(secondWindow.element))
        [firstWindow, movedWindow, sharedWindow, unknownWindow].forEach(restore.capture)
        membership[99104] = [3]
        membership[99105] = [1, 3]
        membership[99106] = nil
        precondition(!restore.windowCanMoveHere(movedWindow.element) && !restore.windowCanMoveHere(sharedWindow.element) &&
                     !restore.windowCanMoveHere(unknownWindow.element), "only verified windows exclusive to the active desktop can be moved")
        restoreSpace = two; restore.syncDesktops()
        precondition(!restore.canUndo && restore.snapshot.isEmpty, "a desktop without a snapshot cannot restore another desktop's windows")
        restore.capture(secondWindow)
        restore.visibleSlotIDs[.terminal] = [secondWindow.id]
        restoreSpace = three; restore.syncDesktops()
        precondition(!restore.canUndo && restore.snapshot.isEmpty, "an unorganized third desktop has no Restore action")
        restore.capture(thirdWindow)
        restoreSpace = fullScreen; restore.syncDesktops()
        restore.trusted = true
        restore.undo(restoring: recordRestore)
        precondition(!restore.canRestoreHere && restored.isEmpty, "a full-screen app cannot restore any desktop")
        restoreSpace = one; restore.syncDesktops()
        precondition(restore.canRestoreFromBoard && restore.snapshot.count == 4 && restore.snapshot[firstWindow.id] != nil, "the active desktop has its own snapshot")
        restore.showDesktop("AAAA-2")
        precondition(!restore.canRestoreFromBoard && restore.canRestoreHere, "the board cannot restore a desktop open only in the editor")
        restore.undo(fromBoard: true, restoring: recordRestore)
        precondition(restored.isEmpty && restore.canUndo, "a board action cannot fall through to the active desktop")
        restore.showDesktop(DesktopSpaces.first)
        restore.undo(fromBoard: true, restoring: recordRestore)
        precondition(restored.map(\.pid) == [firstWindow.pid] && restored.first?.frame == firstWindow.frame && restored.first?.minimized == true,
                     "Restore writes only the original frame and minimized state of a window still on that desktop")
        precondition(Set(restore.snapshot.keys) == [unknownWindow.id] && !restore.stripsBelongHere,
                     "Restore ends the active arrangement but holds unverified windows for retry")
        restoreSpace = two; restore.syncDesktops()
        precondition(restore.canUndo && restore.stripsBelongHere && Set(restore.snapshot.keys) == [secondWindow.id] &&
                     restore.visibleSlotIDs[.terminal] == [secondWindow.id], "another desktop keeps its snapshot, strips and selected window")
        restoreSpace = one; restore.syncDesktops()
        restore.trusted = true
        membership[99106] = [1]
        restore.undo(restoring: recordRestore)
        precondition(restored.count == 2 && restored.last?.pid == unknownWindow.pid && !restore.canUndo,
                     "Restore retries an unverified window once macOS confirms its desktop")
        restore.trusted = true
        restore.restoreOnQuit(restoring: recordRestore)
        precondition(restored.count == 4 && Set(restored.map(\.pid)) == [firstWindow.pid, unknownWindow.pid, secondWindow.pid, thirdWindow.pid],
                     "Quit restores the two remaining desktop snapshots even from the already restored desktop")
        print("PASS: Restore keeps each desktop's windows and strips independent")

        // The row: "Desktop 1 2 …" hangs under the display dropdown and is never wider than it.
        func rowManager(_ desktops: Int) -> WindowManager {
            let m = manager("row-\(desktops).json")
            let list = (1...desktops).map { desktop($0, $0 == 1 ? "" : "ROW-\($0)") }
            m.spacesAccess = SpacesAccess(read: { [display("Main", list, current: list[min(1, desktops - 1)])] })
            m.syncDesktops()
            return m
        }
        let lone = rowManager(1)
        let column = NSHostingView(rootView: DisplayMenu(manager: lone)).fittingSize
        precondition(column.width > 60 && column.height < 30, "the dropdown alone: \(column)")
        let margin: CGFloat = 240, pad: CGFloat = 12
        // Draws the header as the Lanes window does: title left, dropdown and row right.
        func draw(_ m: WindowManager, dark: Bool = false) -> NSBitmapImageRep {
            let header = DisplayHeader(manager: m) {
                Text("THE GRID · PRESETS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
            }.frame(width: margin + column.width).padding(pad).background(surface).foregroundStyle(ink)
            let host = NSHostingView(rootView: header)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; host.setFrameSize(size); window.orderFrontRegardless()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            window.close()
            return rep
        }
        // The drawn extent, in points, of everything in a band of the header that is not background.
        func drawn(_ rep: NSBitmapImageRep, top: CGFloat, bottom: CGFloat) -> ClosedRange<CGFloat>? {
            let scale = CGFloat(rep.pixelsWide) / rep.size.width
            guard let ground = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB) else { return nil }
            var low: Int?, high: Int?
            for y in Int(top * scale)..<min(rep.pixelsHigh, Int(bottom * scale)) {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(c.redComponent - ground.redComponent) + abs(c.greenComponent - ground.greenComponent) + abs(c.blueComponent - ground.blueComponent) > 0.06 {
                        low = min(low ?? x, x); high = max(high ?? x, x)
                    }
                }
            }
            guard let low, let high else { return nil }
            return CGFloat(low) / scale...CGFloat(high + 1) / scale
        }
        let columnStart = pad + margin, columnEnd = pad + margin + column.width
        let rowTop = pad + column.height + DisplayHeaderLayout.rowGap
        let alone = draw(lone)
        precondition(abs(alone.size.height - (2 * pad + column.height)) < 1 && drawn(alone, top: rowTop - DisplayHeaderLayout.rowGap, bottom: alone.size.height) == nil, "one desktop: no row, and the header is as tall as before")
        let firstLine = drawn(alone, top: 0, bottom: rowTop - DisplayHeaderLayout.rowGap)
        var widths: [Int: CGFloat] = [:]
        // The numbers alone, when they all show. When they may not fit, a number can be cut off by the scrolling edge.
        let natural = { (n: Int) in CGFloat(n) * DesktopRow.buttonWidth + CGFloat(n - 1) * DesktopRow.spacing }
        for desktops in [2, 4, 9, 16] {
            let m = rowManager(desktops)
            let rep = draw(m)
            precondition(abs(rep.size.height - (2 * pad + column.height + DisplayHeaderLayout.rowGap + DesktopRow.height)) < 1 && abs(rep.size.width - (2 * pad + margin + column.width)) < 1, "\(desktops) desktops: the row adds one line under the dropdown and no width (\(rep.size))")
            // The first line is exactly as it is without the row.
            precondition(drawn(rep, top: 0, bottom: rowTop - DisplayHeaderLayout.rowGap) == firstLine, "\(desktops) desktops: the title and the dropdown stay where they were")
            guard let row = drawn(rep, top: rowTop, bottom: rowTop + DesktopRow.height) else { preconditionFailure("\(desktops) desktops: the row is drawn under the dropdown") }
            precondition(row.lowerBound >= columnStart - 1 && row.upperBound <= columnEnd + 1, "\(desktops) desktops: the row stays inside the dropdown's column (row \(row), column \(columnStart)...\(columnEnd))")
            // The last number's box ends at the dropdown's right end; an unselected number is only its digit, centered in its box.
            precondition(columnEnd - row.upperBound < (natural(desktops) + 60 > column.width ? DesktopRow.buttonWidth + DesktopRow.spacing : DesktopRow.buttonWidth / 2 + 2), "\(desktops) desktops: the row ends at the dropdown's right end (row \(row), column end \(columnEnd))")
            precondition(drawn(rep, top: rowTop + DesktopRow.height + 1, bottom: rep.size.height - 1) == nil, "\(desktops) desktops: the row is one line; nothing wraps under it")
            precondition(drawn(rep, top: rowTop - DisplayHeaderLayout.rowGap + 1, bottom: rowTop - 1) == nil, "\(desktops) desktops: the numbers sit on the row's line, clear of the dropdown above")
            widths[desktops] = row.upperBound - row.lowerBound
        }
        // Two more desktops are two more boxes of the same width (give or take the half box around an unselected digit).
        let step = 2 * (DesktopRow.buttonWidth + DesktopRow.spacing)
        precondition(abs(widths[4]! - widths[2]! - step) <= DesktopRow.buttonWidth / 2 + 2, "numbers have one fixed width: two more desktops are two more buttons (\(widths))")
        if natural(16) + 60 > column.width { precondition(widths[16]! <= column.width + 1 && widths[16]! > column.width - DesktopRow.buttonWidth - DesktopRow.spacing - 2, "16 desktops fill the column and scroll inside it (\(widths[16]!) of \(column.width))") }
        print("desktop row widths under a \(Int(column.width))-point dropdown: " + [2, 4, 9, 16].map { "\($0) desktops \(Int(widths[$0]!)) pt" }.joined(separator: ", "))
        // LANES_DESKTOP_ROW_PNG=/path/prefix also saves the header as PNGs, light and dark.
        if let prefix = ProcessInfo.processInfo.environment["LANES_DESKTOP_ROW_PNG"] {
            for desktops in [2, 4, 9, 16] {
                for dark in [false, true] {
                    try draw(rowManager(desktops), dark: dark).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-\(desktops)-\(dark ? "dark" : "light").png"))
                }
            }
            // The desktop you are on (2) while the editor shows another (4).
            let other = rowManager(4); other.showDesktop("ROW-4")
            for dark in [false, true] { try draw(other, dark: dark).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-4-viewing-other-\(dark ? "dark" : "light").png")) }
        }
        print("PASS: the desktop row hangs under the display dropdown, never wider than it, one line, numbers of one width, scrolling when they do not fit")

        if ProcessInfo.processInfo.environment["LANES_LIVE_INACTIVE_INVENTORY"] == "1" {
            let live = manager("native-inactive-inventory.json")
            live.spacesAccess = .native
            live.syncDesktops()
            live.trusted = true
            let active = live.activeDesktop
            let others = live.desktops.filter { $0.id != active }
            precondition(!others.isEmpty, "native check needs an inactive Space")
            for desktop in others {
                live.showDesktop(desktop.id)
                waitForEditorWindows(live)
                precondition(live.activeDesktop == active && live.windows.isEmpty && !live.editorWindows.isEmpty,
                             "native read must find windows without activating that desktop")
                print("PASS: native Desktop \(desktop.number) shows \(live.editorApps.count) apps and \(live.editorWindows.count) windows while still on \(live.desktopName(active))")
            }
        }
        // What this Mac reports right now (read only; nothing is switched or saved).
        let live = DesktopSpaces.parse(SpacesAccess.native.read(), mainDisplay: NSScreen.screens.first.map(WindowManager.displayKey) ?? "main")
        func describe(_ display: DisplayDesktops) -> String {
            let on = display.desktops.first { $0.id == display.current }.map { "Desktop \($0.number)" } ?? "none (full screen)"
            return "\(display.desktops.count) desktop(s), on \(on)" + (display.desktops.first?.id == DesktopSpaces.first ? ", first desktop unnamed" : "")
        }
        print("Live: macOS reports \(live.count) display(s) with desktops: " + live.map(describe).joined(separator: "; "))
    }
}

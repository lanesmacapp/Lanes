import AppKit
import ApplicationServices

@main struct AppDiscoveryTests {
    @MainActor static func main() {
        let manager = WindowManager(startPolling: false)
        let trusted = AXIsProcessTrusted()
        let expected = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 0 && $0.processIdentifier != getpid() && !$0.isTerminated
        }.map(\.processIdentifier))
        manager.refreshRunningApps()
        let found = Set(manager.runningApps.map(\.pid))
        precondition(found == expected, "all running desktop apps must be discoverable through NSWorkspace")
        precondition(manager.runningApps.allSatisfy { manager.availableLanes.contains($0.lane) }, "apps keep their own category, even a shelved one, instead of being counted in another")
        let actualWindows = manager.windows
        manager.trusted = false
        for lane in manager.enabledLanes {
            precondition(manager.discoveryCount(lane) == "\(manager.apps(lane).count) apps", "counts must identify apps, not claim window discovery")
        }
        precondition(manager.windows.count == actualWindows.count, "app discovery must not fabricate window entries")
        precondition(manager.runningApps.count == found.count, "discovery list cannot contain duplicate processes")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-category-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("settings.json")
        let categories = WindowManager(settingsFile: file, startPolling: false)
        precondition(categories.addCategory(name: "Research"), "a custom category must fit into a populated grid")
        let research = categories.selectedLane
        precondition(research.isCustom && categories.name(research) == "Research")
        precondition(GridGeometry.valid(categories.layoutRects(), lanes: categories.enabledLanes))
        precondition(categories.addCategory(name: "Music"), "multiple custom categories must be allowed")
        categories.renameCategory(research, name: "Reading")
        let reload = WindowManager(settingsFile: file, startPolling: false)
        precondition(reload.name(research) == "Reading" && reload.enabledLanes.contains(research), "custom categories and renames must survive relaunch")
        var focusReleased = false
        reload.onGridSelection = { focusReleased = true }
        reload.selectGridCategory(research)
        precondition(focusReleased && reload.gridSelectionActive, "selecting a grid section must release text-field focus for Backspace")
        reload.deleteSelectedCategory()
        precondition(!reload.enabledLanes.contains(research) && reload.availableLanes.contains(research), "Backspace deletion must be reversible")
        reload.restoreCategory(research)
        precondition(reload.enabledLanes.contains(research) && reload.name(research) == "Reading")
        precondition(GridGeometry.valid(reload.layoutRects(), lanes: reload.enabledLanes), "restore cannot overlap existing categories")
        precondition(!reload.addCategory(name: "   "), "empty names cannot create categories")
        reload.settings.appRules["org.example.reader"] = research.rawValue
        reload.save()
        let original = reload.editorRect(research)
        precondition(reload.receiveShelfDrop(["lane:" + research.rawValue]), "workspace category drags must move it to the shelf")
        precondition(reload.settings.appRules["org.example.reader"] == research.rawValue, "shelving must preserve app assignments")
        precondition(!reload.enabledLanes.contains(research) && reload.settings.shelvedLanes.contains(research.rawValue))
        precondition(!reload.receiveShelfDrop(["unrelated window"]), "window and unrelated drops cannot delete a category")
        let shelfReload = WindowManager(settingsFile: file, startPolling: false)
        shelfReload.settings.hiddenLanes.removeAll { $0 == research.rawValue }
        precondition(!shelfReload.enabledLanes.contains(research), "auto-sort clearing empty-category state must not unshelve a removed group")
        precondition(!shelfReload.receiveWorkspaceDrop(["lane:" + research.rawValue], at: CGPoint(x: -1, y: 2), in: CGSize(width: 1000, height: 500)))
        precondition(shelfReload.receiveWorkspaceDrop(["lane:" + research.rawValue], at: CGPoint(x: original.midX * 1000, y: original.midY * 500), in: CGSize(width: 1000, height: 500)))
        precondition(shelfReload.editorRect(research) == original, "dropping into the freed region must put the category back there")
        precondition(shelfReload.settings.appRules["org.example.reader"] == research.rawValue && !shelfReload.settings.shelvedLanes.contains(research.rawValue))
        precondition(shelfReload.receiveShelfDrop(["lane:" + research.rawValue]))
        let target = shelfReload.editorRect(.terminal)
        let targetPoint = CGPoint(x: target.minX + target.width * 0.75, y: target.midY)
        precondition(shelfReload.receiveWorkspaceDrop(["lane:" + research.rawValue], at: CGPoint(x: targetPoint.x * 1000, y: targetPoint.y * 500), in: CGSize(width: 1000, height: 500)))
        precondition(shelfReload.editorRect(research).contains(targetPoint), "drop on an occupied region must split that region at the requested location")
        precondition(GridGeometry.valid(shelfReload.layoutRects(), lanes: shelfReload.enabledLanes))
        for lane in shelfReload.enabledLanes.dropFirst() { precondition(shelfReload.receiveShelfDrop(["lane:" + lane.rawValue])) }
        precondition(!shelfReload.receiveShelfDrop(["lane:" + shelfReload.enabledLanes[0].rawValue]), "drag removal must protect the final category")
        let terminalWindows = (0..<4).map { index in
            ManagedWindow(id: "terminal-test-\(index)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "com.apple.Terminal", appName: "Terminal", title: "Shell \(index)", icon: nil, frame: CGRect(x: 0, y: 0, width: 1000, height: 900), minimized: false, lane: .terminal)
        }
        let tabManager = WindowManager(settingsFile: fixture.appendingPathComponent("tabs.json"), startPolling: false)
        tabManager.windows = terminalWindows
        tabManager.visibleSlotIDs[.terminal] = Array(terminalWindows.prefix(2).map(\.id))
        precondition(tabManager.reorderTab(["tab:" + terminalWindows[3].id], before: terminalWindows[0]))
        precondition(tabManager.items(.terminal).map(\.id) == ["terminal-test-3", "terminal-test-0", "terminal-test-1", "terminal-test-2"])
        precondition(tabManager.visibleItems(.terminal).map(\.id) == ["terminal-test-0", "terminal-test-1"], "drag reordering tabs must not switch either visible terminal")
        tabManager.renameWindow(terminalWindows[0].id, name: " Server ")
        let reloadedTabs = WindowManager(settingsFile: fixture.appendingPathComponent("tabs.json"), startPolling: false)
        precondition(reloadedTabs.windowLabel(terminalWindows[0]) == "Server", "renamed terminal labels survive app restart while that window stays open")
        precondition(reloadedTabs.settings.windowOrder["terminal"]?.first == "terminal-test-3", "tab ordering survives restart for open windows")
        // Exercise the payloads from the category board, window list and strips
        // against every category, then rediscover in a different app/title order.
        for lane in Lane.allCases + [research] {
            let orderFile = fixture.appendingPathComponent("order-\(lane.rawValue.replacingOccurrences(of: ":", with: "-")).json")
            let ordering = WindowManager(settingsFile: orderFile, startPolling: false)
            ordering.settings.capacities[lane.rawValue] = 2
            let queue = terminalWindows.map { original -> ManagedWindow in var window = original; window.lane = lane; return window }
            ordering.windows = queue
            let visible = ordering.visibleItems(lane).map(\.id)
            precondition(ordering.reorderTab(["lanewindow:" + queue[3].id], before: queue[0]), "category-board drags must reorder every category")
            precondition(ordering.items(lane).map(\.id) == [queue[3].id, queue[0].id, queue[1].id, queue[2].id])
            precondition(ordering.visibleItems(lane).map(\.id) == visible, "reordering must preserve implicit visible panes too")
            precondition(ordering.reorderTab([queue[0].id], before: queue[2], after: true), "window-list drags can insert after the final row")
            precondition(ordering.reorderTab(["tab:" + queue[1].id], before: queue[3]), "strip drags share the same saved order")
            let expected = [queue[1].id, queue[3].id, queue[2].id, queue[0].id]
            precondition(ordering.items(lane).map(\.id) == expected)
            precondition(!ordering.reorderTab(["app:com.apple.Terminal"], before: queue[0]))
            precondition(!ordering.reorderTab(["lanewindow:closed-window"], before: queue[0]))
            let restarted = WindowManager(settingsFile: orderFile, startPolling: false)
            let rediscovered = queue.reversed().map { window in
                ManagedWindow(id: window.id, element: window.element, pid: window.pid, bundleID: window.bundleID, appName: window.appName, title: "Changed \(window.id)", icon: nil, frame: window.frame, minimized: false, lane: lane)
            }
            restarted.windows = restarted.orderedWindows(rediscovered)
            precondition(restarted.items(lane).map(\.id) == expected, "saved order survives restart, rediscovery and changing terminal titles")
            let newcomer = ManagedWindow(id: "new-window", element: queue[0].element, pid: getpid(), bundleID: "com.apple.Terminal", appName: "Terminal", title: "A new shell", icon: nil, frame: queue[0].frame, minimized: false, lane: lane)
            let changed = restarted.orderedWindows([newcomer] + rediscovered.filter { $0.id != queue[3].id })
            precondition(changed.map(\.id) == [queue[1].id, queue[2].id, queue[0].id, newcomer.id], "closing and opening windows keeps the surviving queue and appends new windows")
            ordering.editGrid { ordering.setCapacity(lane, 1) }
            precondition(ordering.reorderTab(["lanewindow:" + queue[0].id], before: queue[1]))
            ordering.discardGridDraft()
            let afterDraft = WindowManager(settingsFile: orderFile, startPolling: false)
            precondition(afterDraft.settings.windowOrder[lane.rawValue] == [queue[0].id, queue[1].id, queue[3].id, queue[2].id], "discarding a grid draft must not undo a saved window order")
        }
        let terminalRect = tabManager.editorRect(.terminal)
        do {
            let popupFile = fixture.appendingPathComponent("popup-order.json")
            let popup = WindowManager(settingsFile: popupFile, startPolling: false)
            popup.windows = terminalWindows
            popup.settings.windowStripStyle = .expanding
            popup.settings.stripList = .always
            popup.settings.capacities["terminal"] = 1
            popup.settings.windowStripScale = 1
            popup.stripHovered(.terminal, true)
            let payload = popup.beginTabDrag(terminalWindows[3])
            popup.stripHovered(.terminal, false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            precondition(popup.expandedStrip == .terminal, "the floating list must stay open when starting a drag triggers mouse exit")
            precondition(popup.dropListedTab([payload], into: .terminal, y: WindowStripMetrics.listTop(scale: 1) + 1), "dropping in the top half of the first popup row reorders")
            let firstOrder = [terminalWindows[3].id] + terminalWindows.prefix(3).map(\.id)
            precondition(popup.items(.terminal).map(\.id) == firstOrder)
            precondition(popup.visibleItems(.terminal).map(\.id) == [terminalWindows[0].id], "popup reordering must not switch the selected terminal")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            precondition(popup.expandedStrip == nil && popup.draggedTab == nil, "after dropping outside hover, the popup resumes normal closing")
            popup.stripHovered(.terminal, true)
            precondition(popup.items(.terminal).map(\.id) == firstOrder, "closing and reopening the popup keeps the saved row order")
            let popupReload = WindowManager(settingsFile: popupFile, startPolling: false)
            precondition(popupReload.orderedWindows(terminalWindows).map(\.id) == firstOrder, "popup order must survive restarting Lanes")
            let again = popup.beginTabDrag(terminalWindows[3])
            let bottom = WindowStripMetrics.listTop(scale: 1) + 4 * WindowStripMetrics.listRow(scale: 1) + 2
            precondition(popup.dropListedTab([again], into: .terminal, y: bottom), "bottom padding is a drop target after the last row")
            precondition(popup.items(.terminal).map(\.id) == terminalWindows.map(\.id))
            _ = popup.beginTabDrag(terminalWindows[1])
            popup.stripHovered(.terminal, false)
            popup.endTabDrag()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            precondition(popup.expandedStrip == nil, "a canceled popup drag must release the expanded list too")
            print("PASS: floating popup drag, hover-exit retention, before/after drops, unchanged selection, reopen and restart persistence")
        }
        do {
            // A hover list near the bottom of the display opens above its pill: the pill
            // stays where it rests, and drops land on the row they are over, on either side.
            let side = WindowManager(settingsFile: fixture.appendingPathComponent("list-side.json"), startPolling: false)
            let display = CGRect(x: 0, y: 0, width: 1512, height: 944)
            side.displayOverride = display
            let twelve = (0..<12).map { i in ManagedWindow(id: "side-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "com.apple.Terminal", appName: "Terminal", title: "Shell \(i)", icon: nil, frame: CGRect(x: 0, y: 0, width: 1000, height: 900), minimized: false, lane: .terminal) }
            side.windows = twelve
            side.settings.shelvedLanes = []; side.settings.showMediaShelf = false; side.settings.useCustomGrid = true
            side.settings.hiddenLanes = side.availableLanes.filter { $0 != .terminal && $0 != .browser }.map(\.rawValue)
            side.settings.customRects = ["terminal": ZoneRect(CGRect(x: 0, y: 0, width: 0.4, height: 1)), "browser": ZoneRect(CGRect(x: 0.4, y: 0, width: 0.6, height: 1))]
            side.settings.windowStripStyle = .expanding; side.settings.stripList = .always
            side.settings.capacities["terminal"] = 1; side.settings.windowStripScale = 1
            let rowHeight = WindowStripMetrics.listRow(scale: 1), pad = WindowStripMetrics.listPad
            // Vertical list, 12 windows, the pill on the bottom edge (it used to jump 323 points up).
            side.settings.stripPositions["terminal"] = StripPosition(x: 0.5, y: 0.9999)
            let rest = side.stripRestFrame(.terminal)
            precondition(rest.maxY == display.maxY && side.stripListOpensAbove(.terminal), "a pill on the display's bottom edge will open its list above")
            side.stripHovered(.terminal, true)
            let open = side.stripFrame(.terminal), size = side.listStripMetrics(.terminal)
            precondition(open.height == size.height && open.maxY == rest.maxY && display.contains(open), "the open list grows up from the pill's bottom edge and stays on the display")
            precondition(side.stripPillFrame(.terminal).origin == rest.origin, "the pill is where it rested: it moved \(rest.minY - side.stripPillFrame(.terminal).minY) points")
            // Drop the last window on the upper half of the third row: it lands before the third window.
            var payload = side.beginTabDrag(twelve[11])
            precondition(side.dropListedTab([payload], into: .terminal, y: pad + 2.25 * rowHeight), "a drop on a row of a list above its pill reorders")
            precondition(side.items(.terminal).map(\.id).prefix(4) == ["side-0", "side-1", "side-11", "side-2"], "and lands on the row it was dropped on: \(side.items(.terminal).map(\.id).prefix(4))")
            payload = side.beginTabDrag(twelve[11])
            precondition(side.dropListedTab([payload], into: .terminal, y: pad + 11.75 * rowHeight) && side.items(.terminal).map(\.id) == twelve.map(\.id), "the lower half of the last row drops after it")
            payload = side.beginTabDrag(twelve[11])
            precondition(!side.dropListedTab([payload], into: .terminal, y: size.height - 16) && side.items(.terminal).map(\.id) == twelve.map(\.id), "the pill under the list is not a row")
            // Dragging the open strip by its dot saves where the pill is, not the top of the list.
            side.moveStrip(.terminal, to: open)
            precondition(abs(side.stripRestFrame(.terminal).minY - rest.minY) < 0.5 && abs(side.stripRestFrame(.terminal).minX - rest.minX) < 0.5, "a strip dropped where it already is rests where it was")
            side.stripHovered(.terminal, false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            precondition(side.expandedStrip == nil && side.stripFrame(.terminal) == side.stripRestFrame(.terminal))
            // A pill in the lower half: 12 rows do not fit under it, 4 would. The side is
            // chosen when the list opens and kept while rows close, so nothing flips mid-hover.
            side.settings.stripPositions["terminal"] = StripPosition(x: 0.5, y: 0.765)
            let middle = side.stripRestFrame(.terminal)
            side.stripHovered(.terminal, true)
            precondition(side.stripListOpensAbove(.terminal) && side.stripPillFrame(.terminal).origin == middle.origin, "12 rows open above a pill in the lower half")
            side.windows = Array(twelve.prefix(4))
            precondition(side.stripListOpensAbove(.terminal) && side.stripFrame(.terminal).maxY == middle.maxY && side.stripPillFrame(.terminal).minY == middle.minY, "closing rows keeps the open list on its side and the pill in place")
            side.stripHovered(.terminal, false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            precondition(!side.stripListOpensAbove(.terminal), "the next time it opens, four rows fit under the pill")
            side.stripHovered(.terminal, true)
            precondition(side.stripFrame(.terminal).minY == middle.minY && side.stripPillFrame(.terminal).origin == side.stripRestFrame(.terminal).origin, "and the list opens below, the pill still in place")
            side.stripHovered(.terminal, false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            // With room under it the list opens below, as before, and rows are found from the pill down.
            side.windows = twelve
            side.settings.stripPositions["terminal"] = nil
            let top = side.stripRestFrame(.terminal)
            side.stripHovered(.terminal, true)
            precondition(!side.stripListOpensAbove(.terminal) && side.stripFrame(.terminal).minY == top.minY && side.stripPillFrame(.terminal).origin == top.origin, "a pill at the top of its tile opens its list below")
            payload = side.beginTabDrag(twelve[11])
            precondition(side.dropListedTab([payload], into: .terminal, y: WindowStripMetrics.listTop(scale: 1) + 2.25 * rowHeight) && side.items(.terminal).map(\.id).prefix(4) == ["side-0", "side-1", "side-11", "side-2"], "a drop on the third row of a list under its pill lands there too")
            print("PASS: a hover list opens above its pill near the bottom of the display; the pill stays put and drops land on their rows either way")
        }
        do {
            let lookFile = fixture.appendingPathComponent("strip-look.json")
            let look = WindowManager(settingsFile: lookFile, startPolling: false)
            look.windows = terminalWindows
            look.settings.windowStripStyle = .expanding
            look.stripHovered(.terminal, true)
            precondition(look.expandedStrip == .terminal)
            var refreshed = 0
            look.onStripAppearanceChanged = { refreshed += 1 }
            // Picked from the strip's own menu while it is open under the mouse.
            look.settings.categoryStripStyles["terminal"] = WindowStripStyle.line.rawValue
            look.stripAppearanceChanged()
            precondition(look.expandedStrip == nil, "a new strip style must show its idle look at once, even under the mouse")
            precondition(refreshed == 1, "a new strip style must redraw the strips")
            precondition(look.displayedStripMetrics(.terminal).height == look.stripMetrics(.terminal).height, "the strip must take the Line size right away")
            let lookReload = WindowManager(settingsFile: lookFile, startPolling: false)
            precondition(lookReload.settings.stripStyle(.terminal) == .line, "the strip style must survive restarting Lanes")
            print("PASS: strip style changes show at once, without moving windows, and survive a restart")
        }
        tabManager.editCategory(.terminal, rect: CGRect(x: terminalRect.minX, y: terminalRect.minY, width: terminalRect.width * 0.9, height: terminalRect.height * 0.9))
        precondition(tabManager.settings.useCustomGrid, "manual width and height edits must change Organize to preserve the grid")
        tabManager.hoveredLane = .terminal
        tabManager.targetSlot(.terminal, index: 1)
        precondition(tabManager.activeSlot[.terminal] == 1 && tabManager.activeWindow(.terminal)?.id == "terminal-test-1", "hover targets the bottom pane without changing either window")
        precondition(tabManager.visibleItems(.terminal).map(\.id) == ["terminal-test-0", "terminal-test-1"])
        tabManager.trusted = false // Fixture AX elements must never manipulate actual windows.
        tabManager.swapPanes(.terminal)
        precondition(tabManager.visibleItems(.terminal).map(\.id) == ["terminal-test-1", "terminal-test-0"], "the swap button exchanges the two panes")
        precondition(tabManager.activeWindow(.terminal)?.id == "terminal-test-1" && tabManager.activeSlot[.terminal] == 0, "the window you were using moves with the swap and stays selected")
        tabManager.show(terminalWindows[1], inPane: 1)
        precondition(tabManager.visibleItems(.terminal).map(\.id) == ["terminal-test-0", "terminal-test-1"], "Show in Right on the left window swaps it over instead of doing nothing")
        precondition(tabManager.activeSlot[.terminal] == 1, "the moved window stays selected in its new pane")
        tabManager.windowChanged("terminal-test-0", userActive: false, at: 1)
        precondition(!tabManager.userMoved.contains("terminal-test-0"), "a move that was not yours is never learned")
        tabManager.windowChanged("terminal-test-0", userActive: true, at: 2)
        precondition(tabManager.userMoved.contains("terminal-test-0"), "your own move is remembered for the next category check")
        tabManager.settings.keepLayout = false
        precondition(!tabManager.guards("terminal-test-0"), "with Keep windows in their tiles off, nothing is put back")
        tabManager.settings.keepLayout = true
        precondition(!tabManager.guards("not-a-window"), "only windows Lanes arranged are guarded")
        let paneWindow = tabManager.windows.first { $0.id == tabManager.slotIDs(.terminal)[0] }!
        let paneTiles = Layout.tiles(in: tabManager.laneFrame(.terminal), count: tabManager.settings.capacity(.terminal), gap: tabManager.settings.gap, lane: .terminal)
        precondition(tabManager.expectedFrame(paneWindow) == paneTiles[0], "a window put back returns to exactly its pane")
        let dropManager = WindowManager(settingsFile: fixture.appendingPathComponent("drops.json"), startPolling: false)
        dropManager.trusted = false
        dropManager.windows = terminalWindows
        var dragEvents: [String?] = []
        dropManager.onTabDrag = { dragEvents.append($0) }
        let otherLane = dropManager.enabledLanes.first { $0 != .terminal }!
        precondition(dropManager.beginTabDrag(terminalWindows[2]) == "tab:terminal-test-2" && dropManager.draggedTab == "terminal-test-2", "dragging a strip tab carries that window")
        precondition(!dropManager.dropTab(["lane:" + otherLane.rawValue], into: otherLane), "only strip tabs can be dropped on a category")
        precondition(dropManager.draggedTab == nil && dragEvents == ["terminal-test-2", nil], "any drop closes the drop zones")
        precondition(dropManager.dropTab(["tab:terminal-test-2"], into: otherLane))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(dropManager.items(otherLane).map(\.id) == ["terminal-test-2"] && dropManager.items(.terminal).count == 3, "a tab dropped on another category moves the window there")
        precondition(dropManager.settings.windowCategories["terminal-test-2"] == otherLane.rawValue, "the new category survives a restart")
        precondition(dropManager.dropTab(["tab:terminal-test-3"], into: .terminal, before: terminalWindows[0]) && dropManager.items(.terminal).first?.id == "terminal-test-3", "a tab dropped in its own strip only reorders")
        precondition(tabManager.saveGridLayout(name: "My work"))
        let savedWork = tabManager.settings.savedLayouts.last!
        let workRects = tabManager.layoutRects()
        tabManager.previewPreset(.focus)
        precondition(tabManager.presetPreview != nil && tabManager.layoutRects() == workRects, "previewing a preset changes nothing until Apply")
        tabManager.presetPreview = nil
        precondition(tabManager.layoutRects() == workRects, "Cancel leaves the grid exactly as it was")
        tabManager.previewPreset(.focus); tabManager.applyPresetPreview()
        precondition(tabManager.layoutRects() != workRects && tabManager.settings.previousLayout?.rects == workRects, "applying a preset keeps the grid you had as the previous layout")
        precondition(!tabManager.layoutRects().isEmpty, "applying a preset never leaves the grid empty")
        tabManager.restorePreviousLayout()
        precondition(tabManager.layoutRects() == workRects, "Back restores exact prior sizes")
        tabManager.setCapacity(.terminal, 1)
        tabManager.loadGridLayout(savedWork)
        precondition(tabManager.settings.capacity(.terminal) == 2 && tabManager.layoutRects() == workRects, "saved presets restore geometry and simultaneous windows")
        precondition(tabManager.saveGridLayout(name: "My work"))
        precondition(tabManager.settings.savedLayouts.last!.name == "My work 2", "duplicate names never overwrite an earlier preset")
        let presetsReload = WindowManager(settingsFile: fixture.appendingPathComponent("tabs.json"), startPolling: false)
        precondition(presetsReload.settings.savedLayouts.count == 2 && presetsReload.settings.previousLayout != nil, "named presets and prior grid survive restart")
        let unsplit = tabManager.layoutRects()
        let splitWindowID = tabManager.visibleItems(.terminal).dropFirst().first!.id
        let split = tabManager.splitCategory(.terminal, sideBySide: true)!
        precondition(GridGeometry.valid(tabManager.layoutRects(), lanes: tabManager.enabledLanes), "split creates two valid independent regions")
        precondition(tabManager.items(split).map(\.id) == [splitWindowID] && tabManager.settings.capacity(.terminal) == 1)
        precondition(tabManager.settings.windowCategories[splitWindowID] == split.rawValue, "each split window keeps its own category across restart")
        let untouched = tabManager.editorRect(split)
        tabManager.moveWindow(terminalWindows[2], to: split)
        precondition(tabManager.items(split).count == 2 && tabManager.editorRect(split) == untouched, "adding another app window only changes that region's queue")
        tabManager.saveGridLayout(name: "Split work")
        let savedSplit = tabManager.settings.savedLayouts.last!
        tabManager.undoLayout()
        precondition(tabManager.layoutRects() == unsplit && !tabManager.availableLanes.contains(split), "Undo split restores the prior category grid")
        tabManager.loadGridLayout(savedSplit)
        precondition(tabManager.enabledLanes.contains(split) && tabManager.items(split).count == 2, "saved split layouts recreate categories and their window assignments after Undo")
        let countManager = WindowManager(settingsFile: fixture.appendingPathComponent("counts.json"), startPolling: false)
        countManager.trusted = false
        countManager.windows = terminalWindows
        countManager.visibleSlotIDs[.terminal] = Array(terminalWindows.prefix(2).map(\.id))
        countManager.activeSlot[.terminal] = 1
        let unchangedGrid = countManager.layoutRects(), peerCapacity = countManager.settings.capacity(.messaging)
        countManager.setCapacity(.terminal, 1)
        precondition(countManager.visibleItems(.terminal).map(\.id) == [terminalWindows[1].id], "reducing two panes to one retains the selected bottom window")
        precondition(countManager.activeSlot[.terminal] == 0, "reducing the count retains a valid target pane")
        countManager.setCapacity(.terminal, 4)
        precondition(countManager.visibleItems(.terminal).count == 4 && countManager.activeWindow(.terminal)?.id == terminalWindows[1].id, "increasing the count fills additional panes without replacing the selected window")
        precondition(countManager.layoutRects() == unchangedGrid && countManager.settings.capacity(.messaging) == peerCapacity, "window counts change only the selected region's interior")
        let countReload = WindowManager(settingsFile: fixture.appendingPathComponent("counts.json"), startPolling: false)
        precondition(countReload.settings.capacity(.terminal) == 4, "each region's window count survives restart")
        var hoverChanges = 0
        reload.onHoveredLaneChanged = { hoverChanges += 1 }
        reload.hoveredLane = research; reload.hoveredLane = research; reload.hoveredLane = nil
        precondition(hoverChanges == 2, "hover key registration should only change on entering or leaving a lane")
        // Grid edits in the Lanes window stay a draft until Apply.
        let draftFile = fixture.appendingPathComponent("draft.json")
        let drafts = WindowManager(settingsFile: draftFile, startPolling: false)
        drafts.trusted = false // Fixture windows must never touch real ones.
        drafts.save()
        let savedBefore = try! Data(contentsOf: draftFile)
        let lanesBefore = drafts.enabledLanes, a = lanesBefore[0], b = lanesBefore[1]
        let rectA = drafts.settings.unitRect(for: a), rectB = drafts.settings.unitRect(for: b)
        drafts.editGrid { drafts.swapCategories(a, b) }
        precondition(drafts.gridDraft != nil && drafts.grid.unitRect(for: a) == rectB, "a grid edit shows in the Lanes window as a draft")
        precondition(drafts.settings.unitRect(for: a) == rectA && drafts.enabledLanes == lanesBefore, "the screen keeps the applied grid until Apply")
        precondition((try! Data(contentsOf: draftFile)) == savedBefore, "a draft is never saved over your settings")
        drafts.discardGridDraft()
        precondition(drafts.gridDraft == nil && drafts.grid.unitRect(for: a) == rectA, "Discard leaves everything as it was")
        drafts.editGrid { drafts.removeCategory(b) }
        precondition(!drafts.trusted, "draft refreshes cannot re-enable window operations in an isolated fixture")
        precondition(drafts.enabledLanes.contains(b) && !drafts.gridLanes.contains(b), "removing a category waits for Apply")
        drafts.editGrid { drafts.restoreCategory(b) }
        drafts.editGrid { drafts.swapCategories(a, b) }
        drafts.editGrid { drafts.swapCategories(a, b) }
        drafts.applyGridDraft()
        precondition(drafts.gridDraft == nil && drafts.enabledLanes.contains(b), "Apply makes the draft the real grid")
        drafts.editGrid { drafts.swapCategories(a, b) }
        drafts.editGrid { drafts.swapCategories(a, b) }
        precondition(drafts.gridDraft == nil, "editing back to the applied grid clears the draft")
        drafts.settings.stripPositions[a.rawValue] = StripPosition(x: 0.2, y: 0.01)
        drafts.editGrid { drafts.swapCategories(a, b) }
        drafts.applyGridDraft()
        precondition(drafts.settings.stripPositions[a.rawValue] == nil, "a dragged strip goes back to the middle when its category's box changes")
        precondition(drafts.settings.unitRect(for: a) == rectB && (try! Data(contentsOf: draftFile)) != savedBefore, "Apply saves the new grid")
        print("PASS: grid edits stay a draft until Apply")

        let pending = WindowManager(settingsFile: fixture.appendingPathComponent("pending.json"), startPolling: false)
        pending.trusted = false
        let originalCount = pending.settings.capacity(.terminal)
        let originalRect = pending.settings.unitRect(for: .terminal)
        pending.editGrid { pending.setCapacity(.terminal, 4); pending.swapCategories(.terminal, .browser) }
        let editedRect = pending.grid.unitRect(for: .terminal)
        precondition(pending.saveGridLayout(name: "Draft preset"))
        let savedDraft = pending.settings.savedLayouts.last!
        precondition(savedDraft.capacities["terminal"] == 4 && savedDraft.rects["terminal"]?.cgRect == editedRect, "saving a draft uses the visible counts and geometry")
        precondition(pending.settings.capacity(.terminal) == originalCount && pending.settings.unitRect(for: .terminal) == originalRect, "saving a draft must not arrange or apply it")
        pending.previewPreset(PresetShape.allCases[0])
        pending.previewPreset(PresetShape.allCases[1])
        let shapeRects = pending.presetPreview!.rects
        precondition(pending.saveGridLayout(name: "Visible preview"))
        precondition(pending.settings.savedLayouts.last!.rects == shapeRects && pending.settings.savedLayouts.last!.capacities["terminal"] == 4, "saving while a preview is shown saves its visible shape and draft counts")
        precondition(pending.gridDraft != nil, "trying several presets never throws away the unsaved grid")
        pending.presetPreview = nil
        precondition(pending.grid.capacity(.terminal) == 4 && pending.grid.unitRect(for: .terminal) == editedRect, "Cancel returns to the exact draft")
        pending.previewSavedLayout(savedDraft)
        pending.presetPreview = nil
        precondition(pending.gridDraft != nil && pending.grid.capacity(.terminal) == 4, "saved-preset previews preserve unsaved edits too")
        precondition(pending.commitPendingGrid(), "the shared Apply/Organize path commits a draft")
        precondition(pending.gridDraft == nil && pending.settings.capacity(.terminal) == 4 && pending.settings.unitRect(for: .terminal) == editedRect, "committing uses the edited count and frame together")
        precondition(pending.settings.previousLayout?.capacities["terminal"] == originalCount, "the applied grid remains recoverable as Previous layout")
        let pendingReload = WindowManager(settingsFile: fixture.appendingPathComponent("pending.json"), startPolling: false)
        precondition(pendingReload.settings.capacity(.terminal) == 4 && pendingReload.settings.savedLayouts.last?.capacities["terminal"] == 4, "applied edits and draft presets survive restart")
        pending.editGrid { pending.setCapacity(.terminal, 3) }
        pending.previewPreset(PresetShape.allCases[0])
        let previewRects = pending.presetPreview!.rects
        precondition(pending.commitPendingGrid())
        precondition(pending.presetPreview == nil && pending.gridDraft == nil && pending.settings.customRects == previewRects, "Organize/Apply consumes the preview and its underlying draft")
        let fitting = AutoSorter.fittingCount(.terminal, limit: 3, frame: pending.laneFrame(.terminal), gap: pending.settings.gap)
        precondition(pending.settings.capacity(.terminal) == fitting && pending.settings.previousLayout?.capacities["terminal"] == 3, "applying a shape keeps counts that fit its new size and preserves the edited layout for Back")
        do {
            // On a display with room, a preset keeps your count; on a MacBook it shows fewer side by side.
            let fit = WindowManager(settingsFile: fixture.appendingPathComponent("preset-fit.json"), startPolling: false)
            fit.windows = terminalWindows
            fit.settings.capacities["terminal"] = 2
            fit.selectedLane = .terminal
            fit.displayOverride = CGRect(x: 0, y: 25, width: 5120, height: 1415)
            fit.previewPreset(.focus)
            precondition(fit.commitPendingGrid() && fit.settings.capacity(.terminal) == 2, "a preset with room keeps two terminals")
            fit.displayOverride = CGRect(x: 0, y: 33, width: 1280, height: 743)
            let four: [Lane] = [.browser, .terminal, .messaging, .preview]
            fit.settings.shelvedLanes = []
            fit.settings.hiddenLanes = fit.availableLanes.filter { !four.contains($0) }.map(\.rawValue)
            fit.settings.floatingLanes = []
            fit.settings.capacities["terminal"] = 4
            fit.selectedLane = .browser
            precondition(fit.presetShapes.contains(.mainSide) && !fit.presetShapes.contains(.columns), "a 13-inch screen offers Main + side but not Columns for four categories")
            fit.previewPreset(.mainSide)
            precondition(fit.commitPendingGrid())
            let shown = Layout.tiles(in: fit.laneFrame(.terminal), count: fit.settings.capacity(.terminal), gap: fit.settings.gap, lane: .terminal)
            precondition(fit.settings.capacity(.terminal) < 4 && shown.allSatisfy { $0.width >= AutoSorter.usableSize(.terminal).width && $0.height >= AutoSorter.usableSize(.terminal).height }, "on a small screen a preset shows only the terminals that fit")
            print("PASS: presets keep window counts that fit and lower the ones that do not")
        }
        do {
            // Choosing another display must leave the arranged one alone, not Restore it.
            let switching = WindowManager(settingsFile: fixture.appendingPathComponent("switch.json"), startPolling: false)
            switching.trusted = false
            switching.windows = terminalWindows
            terminalWindows.forEach(switching.capture)
            switching.canUndo = true
            var stripsHidden = false
            switching.onHideLaneControls = { stripsHidden = true }
            switching.changeScreen(999)
            precondition(!switching.canUndo && switching.snapshot.isEmpty && stripsHidden, "switching displays forgets the old arrangement and its strips")
            precondition(!switching.status.localizedCaseInsensitiveContains("restore"), "switching displays never restores (moves back) the old display's windows")
            switching.canUndo = true
            switching.release()
            precondition(!switching.canUndo && switching.snapshot.isEmpty, "release forgets an arrangement without needing window access")
            print("PASS: switching displays leaves the arranged display where it is")
        }
        do {
            // Closing a tab from a hovered strip must not slide the strip sideways.
            let pin = WindowManager(settingsFile: fixture.appendingPathComponent("pin.json"), startPolling: false)
            pin.displayOverride = CGRect(x: 0, y: 25, width: 3440, height: 1415)
            pin.trusted = true; pin.busy = true   // busy: no re-read of this Mac's real windows
            // Ten windows: one fewer makes every resting strip narrower (a Line loses a
            // segment, a pill loses a digit of its count).
            let ten = (0..<10).map { i in ManagedWindow(id: "pin-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "com.apple.Terminal", appName: "Terminal", title: "Shell \(i)", icon: nil, frame: CGRect(x: 0, y: 0, width: 1000, height: 900), minimized: false, lane: .terminal) }
            pin.windows = ten
            pin.actionAccess.close = { _ in true }
            for style in [WindowStripStyle.line, .expanding, .compact] {
                pin.settings.windowStripStyle = style
                pin.stripHovered(.terminal, true)
                let before = pin.stripFrame(.terminal).minX
                pin.closeFromStrip(pin.windows[0])
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                precondition(abs(pin.stripFrame(.terminal).minX - before) < 0.5, "\(style.title): closing a tab keeps the hovered strip's left edge in place")
                pin.windows.removeFirst()   // the app closed it
                precondition(abs(pin.stripFrame(.terminal).minX - before) < 0.5, "\(style.title): the strip stays put after the window is gone")
                pin.stripHovered(.terminal, false)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
                precondition(pin.pinnedStripOrigin[.terminal] == nil, "\(style.title): leaving the strip lets it re-center")
                precondition(pin.stripFrame(.terminal).minX > before + 0.5, "\(style.title): this check needs a strip that does get narrower")
                pin.endClosing(pin.windows.isEmpty ? "" : "pin-0")
                pin.windows = ten
            }
            print("PASS: closing a tab never slides the hovered strip; it re-centers after the pointer leaves")
        }
        do {
            // Each category keeps its own hover view: Terminal vertical, Browser horizontal,
            // on wide and on narrow tiles alike; the rest follow the setting for all strips.
            let looks = WindowManager(settingsFile: fixture.appendingPathComponent("looks.json"), startPolling: false)
            looks.displayOverride = CGRect(x: 0, y: 25, width: 5120, height: 1415)
            let browsers = (0..<5).map { i in ManagedWindow(id: "look-b\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "company.thebrowser.Browser", appName: "Arc", title: "Page \(i)", icon: nil, frame: .zero, minimized: false, lane: .browser) }
            let shells = (0..<5).map { i in ManagedWindow(id: "look-t\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "Shell \(i)", icon: nil, frame: .zero, minimized: false, lane: .terminal) }
            looks.windows = browsers + shells
            looks.settings.shelvedLanes = []; looks.settings.hiddenLanes = looks.availableLanes.filter { $0 != .browser && $0 != .terminal }.map(\.rawValue)
            looks.settings.windowStripStyle = .expanding
            looks.settings.stripList = .narrow
            looks.settings.categoryStripLists["terminal"] = StripListMode.always.rawValue
            looks.settings.categoryStripLists["browser"] = StripListMode.never.rawValue
            for (terminalWidth, label) in [(0.5, "wide"), (0.08, "narrow")] {
                looks.settings.customRects = ["terminal": ZoneRect(CGRect(x: 0, y: 0, width: terminalWidth, height: 1)), "browser": ZoneRect(CGRect(x: terminalWidth, y: 0, width: 1 - terminalWidth, height: 1))]
                looks.settings.useCustomGrid = true
                precondition(looks.stripUsesList(.terminal), "Terminal opens as a vertical list on a \(label) tile")
                precondition(!looks.stripUsesList(.browser), "Browser opens as horizontal tabs next to a \(label) Terminal")
            }
            looks.settings.customRects = ["terminal": ZoneRect(CGRect(x: 0, y: 0, width: 0.92, height: 1)), "browser": ZoneRect(CGRect(x: 0.92, y: 0, width: 0.08, height: 1))]
            precondition(!looks.stripUsesList(.browser), "Browser stays horizontal even on a narrow tile")
            looks.settings.categoryStripLists.removeValue(forKey: "browser")
            precondition(looks.stripUsesList(.browser), "with Same as all strips (Auto), a narrow Browser tile opens as a list")
            print("PASS: each category keeps its own hover view (Terminal vertical, Browser horizontal), whatever the tile size")
        }
        pending.editGrid { precondition(pending.addCategory(name: "Draft research")) }
        let draftCategory = pending.selectedLane
        precondition(pending.saveGridLayout(name: "Draft category"))
        precondition(pending.settings.savedLayouts.last!.categories.contains(where: { $0.lane == draftCategory }) && pending.settings.savedLayouts.last!.lanes.contains(draftCategory.rawValue), "saved draft presets include new categories, not only their rectangles")
        pending.previewPreset(PresetShape.allCases[0])
        precondition(pending.presetPreview!.lanes.contains(draftCategory), "shape previews include categories added in the draft")
        pending.applyPresetPreview()
        precondition(pending.enabledLanes.contains(draftCategory) && pending.gridDraft == nil, "applying a preview commits newly added categories")
        let paneDraft = WindowManager(settingsFile: fixture.appendingPathComponent("pane-draft.json"), startPolling: false)
        paneDraft.trusted = false
        paneDraft.windows = terminalWindows
        paneDraft.visibleSlotIDs[.terminal] = Array(terminalWindows.prefix(2).map(\.id))
        paneDraft.activeSlot[.terminal] = 1
        paneDraft.editGrid { paneDraft.setCapacity(.terminal, 1) }
        precondition(paneDraft.visibleItems(.terminal).count == 2, "draft counts leave the live panes alone")
        paneDraft.applyGridDraft()
        precondition(paneDraft.visibleItems(.terminal).map(\.id) == [terminalWindows[1].id], "applying a one-pane draft retains the selected bottom window")
        do {
            // Apply writes only what the draft changed. Whatever happened on the screen
            // after the draft began (a window moved to another category, a rename, the
            // gap) is kept.
            let stale = WindowManager(settingsFile: fixture.appendingPathComponent("stale-draft.json"), startPolling: false)
            stale.trusted = false
            stale.windows = terminalWindows
            let count = stale.settings.capacity(.terminal) == 1 ? 2 : 1
            let other = stale.enabledLanes.first { $0 != .terminal }!
            stale.editGrid { stale.setCapacity(.terminal, count) }
            precondition(stale.gridDraft != nil)
            stale.moveWindow(terminalWindows[0], to: other, arrange: false)
            stale.renameCategory(other, name: "Elsewhere")
            stale.settings.gap = 20
            precondition(stale.items(other).map(\.id) == [terminalWindows[0].id], "the window moved while the draft was open")
            stale.applyGridDraft()
            precondition(stale.gridDraft == nil && stale.settings.capacity(.terminal) == count, "Apply still applies the draft's own change")
            precondition(stale.settings.windowCategories[terminalWindows[0].id] == other.rawValue && stale.items(other).map(\.id) == [terminalWindows[0].id], "applying a draft keeps a window assignment made after the draft began")
            precondition(stale.name(other) == "Elsewhere" && stale.settings.gap == 20, "applying a draft keeps a rename and a gap chosen after the draft began")
            // A split in the draft assigns a window to the new half: that assignment is the draft's own.
            var half: Lane?
            let splitWindow = stale.visibleItems(.terminal).dropFirst().first?.id ?? stale.items(.terminal).first { $0.id != stale.activeWindow(.terminal)?.id }!.id
            stale.editGrid { half = stale.splitCategory(.terminal, sideBySide: true) }
            precondition(half != nil && stale.items(.terminal).contains { $0.id == splitWindow }, "a split waits for Apply")
            let late = stale.items(.terminal).first { $0.id != splitWindow }!
            stale.moveWindow(late, to: other, arrange: false)
            stale.applyGridDraft()
            precondition(stale.enabledLanes.contains(half!) && stale.items(half!).map(\.id) == [splitWindow] && stale.settings.windowCategories[splitWindow] == half!.rawValue, "a split still carries over the assignment it created")
            precondition(stale.items(other).map(\.id).contains(late.id) && stale.settings.windowCategories[late.id] == other.rawValue, "and a window moved after the split keeps its new category")
            let staleReload = WindowManager(settingsFile: fixture.appendingPathComponent("stale-draft.json"), startPolling: false)
            precondition(staleReload.settings.windowCategories[terminalWindows[0].id] == other.rawValue && staleReload.settings.windowCategories[late.id] == other.rawValue, "the kept assignments are saved")
            // Editing back to the applied grid clears the draft even after a window moved.
            let back = stale.settings.capacity(other)
            stale.editGrid { stale.setCapacity(other, back == 1 ? 2 : 1) }
            stale.moveWindow(stale.items(.terminal)[0], to: other, arrange: false)
            stale.editGrid { stale.setCapacity(other, back) }
            precondition(stale.gridDraft == nil, "a draft with none of its own changes left is no draft")
            print("PASS: applying a grid draft keeps window assignments, renames and the gap changed after it began")
        }

        // A missing/closed AX window is a safe fixture: it cannot move any
        // actual desktop window. Its last discovered frame is still recoverable.
        let recovery = WindowManager(settingsFile: fixture.appendingPathComponent("recovery.json"), startPolling: false)
        let missingElement = AXUIElementCreateApplication(0)
        var outside = ManagedWindow(id: "outside-test", element: missingElement, pid: 0, bundleID: "org.example.outside", appName: "Outside", title: "Outside", icon: nil, frame: CGRect(x: 50, y: 70, width: 400, height: 300), minimized: true, lane: .desktop)
        let originalFrame = outside.frame
        precondition(!recovery.movePreservingOriginal(outside, to: CGRect(x: 200, y: 200, width: 400, height: 300)))
        precondition(recovery.canUndo && recovery.snapshot[outside.id]?.frame == originalFrame && recovery.snapshot[outside.id]?.minimized == true, "moving an uncategorized window records its frame and minimized state even if AX fails")
        outside.frame.origin = CGPoint(x: 250, y: 250)
        outside.minimized = false
        _ = recovery.movePreservingOriginal(outside, to: CGRect(x: 300, y: 300, width: 400, height: 300))
        precondition(recovery.snapshot.count == 1 && recovery.snapshot[outside.id]?.frame == originalFrame && recovery.snapshot[outside.id]?.minimized == true, "repeated moves never replace the first Restore snapshot")
        do {
            // "Leave [app] alone" after organizing: Restore and Quit must not move that
            // app's windows back either. (AX PID 0 cannot move a real window.)
            let leave = WindowManager(settingsFile: fixture.appendingPathComponent("leave-alone.json"), startPolling: false)
            func fake(_ id: String, pid: pid_t, bundle: String, name: String) -> ManagedWindow {
                ManagedWindow(id: id, element: AXUIElementCreateApplication(0), pid: pid, bundleID: bundle, appName: name, title: id, icon: nil, frame: CGRect(x: 40, y: 60, width: 500, height: 400), minimized: false, lane: .desktop)
            }
            let left = [fake("left-1", pid: 990_001, bundle: "org.example.left", name: "Left"), fake("left-2", pid: 990_001, bundle: "org.example.left", name: "Left")]
            let kept = fake("kept-1", pid: 990_002, bundle: "org.example.kept", name: "Kept")
            leave.windows = left + [kept]
            (left + [kept]).forEach(leave.capture)
            precondition(leave.canUndo && leave.snapshot.count == 3 && leave.snapshot["left-1"]?.bundleID == "org.example.left" && leave.snapshot["left-1"]?.pid == 990_001, "each Restore entry records the app that owns the window")
            precondition(Set(leave.hiddenAppSnapshot.keys) == [990_001, 990_002], "the hidden state of both apps was recorded")
            leave.ignoreApp("org.example.left", name: "Left")
            precondition(leave.snapshot["left-1"] == nil && leave.snapshot["left-2"] == nil && leave.snapshot["kept-1"] != nil, "leaving an app alone removes its windows' saved frames and minimized states from Restore")
            precondition(Array(leave.hiddenAppSnapshot.keys) == [990_002], "and its hidden-app state")
            precondition(leave.restorable().map(\.bundleID) == ["org.example.kept"], "Restore touches only the windows of apps Lanes still manages")
            // The ignore list changed by another route (a settings file from another Mac):
            // Restore checks the list itself before touching any window.
            leave.settings.ignoredApps.append("org.example.kept")
            precondition(leave.snapshot["kept-1"] != nil && leave.restorable().isEmpty, "Restore never moves a window of an app on the Leave alone list")
            leave.manageApp("org.example.kept")
            precondition(leave.restorable().map(\.bundleID) == ["org.example.kept"], "managing the app again makes its windows restorable again")
            print("PASS: Leave alone removes an app from Restore, and Restore checks the list before moving a window")
        }
        do {
            // Preview Overlay with Browser and Terminal, then "Save as preset…": the saved
            // preset must float Terminal over Browser and apply like the preview does.
            let overlay = WindowManager(settingsFile: fixture.appendingPathComponent("overlay-preset.json"), startPolling: false)
            overlay.trusted = false
            overlay.settings.shelvedLanes = []
            overlay.settings.hiddenLanes = overlay.availableLanes.filter { $0 != .browser && $0 != .terminal }.map(\.rawValue)
            overlay.settings.showMediaShelf = false
            overlay.settings.customRects = ["browser": ZoneRect(CGRect(x: 0, y: 0, width: 0.5, height: 1)), "terminal": ZoneRect(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))]
            overlay.selectedLane = .browser
            overlay.previewPreset(.overlay)
            let shown = overlay.presetPreview!
            precondition(shown.floating == ["terminal"] && shown.rects["browser"]?.cgRect == CGRect(x: 0, y: 0, width: 1, height: 1), "Overlay fills the screen with Browser and floats Terminal over it")
            precondition(overlay.saveGridLayout(name: "My overlay"), "an Overlay preview can be saved as a preset")
            let savedOverlay = overlay.settings.savedLayouts.last!
            precondition(savedOverlay.floating == ["terminal"] && savedOverlay.rects == shown.rects && Set(savedOverlay.lanes) == ["browser", "terminal"], "the saved preset keeps the floating category together with its rectangles and categories")
            overlay.presetPreview = nil
            overlay.previewSavedLayout(savedOverlay)
            precondition(overlay.commitPendingGrid(), "the saved Overlay preset applies: \(overlay.status)")
            precondition(overlay.settings.floatingLanes == ["terminal"] && overlay.layoutRects() == shown.rects, "applying it gives the grid that was previewed")
            let overlayReload = WindowManager(settingsFile: fixture.appendingPathComponent("overlay-preset.json"), startPolling: false)
            precondition(overlayReload.settings.savedLayouts.last?.floating == ["terminal"] && overlayReload.settings.floatingLanes == ["terminal"], "the floating category survives a restart")
            // A preset saved by an older build lost its floating category. It is refused
            // with a message, never added again in that state, and never crashes.
            var broken = savedOverlay; broken.id = "broken"; broken.name = "Old overlay"; broken.floating = nil
            overlay.settings.savedLayouts.append(broken)
            overlay.previewSavedLayout(broken)
            precondition(!overlay.commitPendingGrid() && overlay.status == "This preset does not fit your categories.", "an old broken preset is refused without changing the grid")
            let presetCount = overlay.settings.savedLayouts.count
            precondition(!overlay.saveGridLayout(name: "Copy of broken") && overlay.settings.savedLayouts.count == presetCount, "a preset that could not be applied is never added to the list")
            print("PASS: saving an Overlay preview keeps its floating category, and the saved preset applies")
        }
        do {
            // Every connected display has its own identity; its name and size are only a label.
            for screen in NSScreen.screens {
                let key = WindowManager.displayKey(screen), label = WindowManager.displayLabel(screen)
                precondition(key == WindowManager.displayKey(screen) && (UUID(uuidString: key) != nil || key == label), "a display's grid is saved under the identity macOS gives it")
                precondition(label.hasPrefix(screen.localizedName) && label.contains("×"), "its label is still its name and size")
            }
            precondition(Set(NSScreen.screens.map(WindowManager.displayKey)).count == NSScreen.screens.count, "no two connected displays share a grid")
            // A grid saved by an older Lanes under this display's name and size carries over.
            let moved = WindowManager(settingsFile: fixture.appendingPathComponent("display-identity.json"), startPolling: false)
            if let screen = moved.screen, WindowManager.displayKey(screen) != WindowManager.displayLabel(screen) {
                let label = WindowManager.displayLabel(screen), key = WindowManager.displayKey(screen)
                moved.settings.capacities["terminal"] = 3
                moved.settings.activeDisplayKey = label
                moved.settings.displayLayouts = [label: moved.settings.displayLayout(kind: .wide), "Some Other Monitor 5120×1440": moved.settings.displayLayout(kind: .wide)]
                let before = moved.layoutRects()
                moved.syncDisplayLayout()
                precondition(moved.settings.activeDisplayKey == key && moved.settings.displayLayouts[key] != nil && moved.settings.displayLabels[key] == label, "the display in use takes over the grid saved under its name")
                precondition(moved.layoutRects() == before && moved.settings.capacity(.terminal) == 3, "and the grid on screen does not change")
                precondition(moved.settings.displayLayouts["Some Other Monitor 5120×1440"] != nil, "a grid for a monitor that is not connected is kept")
                let movedReload = WindowManager(settingsFile: fixture.appendingPathComponent("display-identity.json"), startPolling: false)
                precondition(movedReload.settings.activeDisplayKey == key && movedReload.settings.displayLabels[key] == label, "the carried-over grid is saved")
            }
            print("PASS: each display keeps its grid under its own identity; a grid saved under its name carries over")
        }
        let isolation = WindowManager(settingsFile: fixture.appendingPathComponent("preset-isolation.json"), startPolling: false)
        isolation.trusted = false
        isolation.windows = terminalWindows
        let isolatedIDs = Set(terminalWindows.map(\.id))
        let fullGrid = isolation.currentGridLayout(name: "Full grid")
        let browserOnly = SavedGridLayout(name: "Browser only", rects: ["browser": ZoneRect(CGRect(x: 0, y: 0, width: 1, height: 1))], capacities: ["browser": 1], lanes: ["browser"], gap: 12, categories: [], categoryNames: [:], windowCategories: [:])
        isolation.loadGridLayout(browserOnly)
        precondition(isolation.items(.browser).allSatisfy { !isolatedIDs.contains($0.id) } && isolation.outsideGrid.filter { isolatedIDs.contains($0.id) }.count == terminalWindows.count, "loading a Browser-only preset shelves terminals instead of relabeling them Browser")
        precondition(isolation.outsideGrid.filter { isolatedIDs.contains($0.id) }.allSatisfy { $0.lane == .terminal }, "shelved windows keep their actual categories")
        isolation.loadGridLayout(fullGrid)
        precondition(isolation.items(.terminal).filter { isolatedIDs.contains($0.id) }.count == terminalWindows.count && isolation.outsideGrid.allSatisfy { !isolatedIDs.contains($0.id) }, "restoring a preset restores shelved category membership without rediscovery")
        isolation.undoLayout()
        precondition(isolation.items(.browser).allSatisfy { !isolatedIDs.contains($0.id) } && isolation.outsideGrid.filter { isolatedIDs.contains($0.id) }.count == terminalWindows.count, "Undo layout preserves the same category isolation")
        print("PASS: preset and Undo category isolation, with shelved windows retained")
        let nativeTabs = WindowManager(settingsFile: fixture.appendingPathComponent("native-tabs.json"), startPolling: false)
        nativeTabs.trusted = true
        var originalTab = ManagedWindow(id: "native-old", element: AXUIElementCreateApplication(0), pid: 0, bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "First project", icon: nil, frame: CGRect(x: 150, y: 170, width: 900, height: 700), minimized: false, lane: .terminal)
        nativeTabs.capture(originalTab)
        let beforeTiling = originalTab.frame
        originalTab.frame = nativeTabs.laneFrame(.terminal)
        nativeTabs.windows = [originalTab]
        _ = nativeTabs.apply(.terminal, raiseWindows: false) // AX PID 0 cannot move a real window.
        let newTab = ManagedWindow(id: "native-new", element: AXUIElementCreateApplication(0), pid: 0, bundleID: originalTab.bundleID, appName: "Ghostty", title: "Second project", icon: nil, frame: originalTab.frame, minimized: false, lane: .terminal)
        nativeTabs.windows = [newTab]
        nativeTabs.adoptTabSwitches(previous: [originalTab])
        precondition(nativeTabs.snapshot[newTab.id]?.frame == beforeTiling, "a new native tab inherits its window group's original Restore frame, not the tiled frame")
        precondition(nativeTabs.slotIDs(.terminal).contains(newTab.id), "native tab switching retains the group's exact pane")
        print("PASS: native-tab Restore snapshot inheritance")
        print("PASS: draft saving, preset preview/cancel, shared Apply/Organize commits, added categories, restart persistence, and uncategorized-window recovery")
        print("PASS: running-app discovery, named categories, shelf drag removal/restore, preserved assignments, drop placement, last-category protection, and hover state")
        print("Live discovery: \(manager.runningApps.count) running apps; window control granted: \(trusted)")
    }
}

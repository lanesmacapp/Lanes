import AppKit
import SwiftUI
import ApplicationServices
// End to end on a real strip (in an invisible off-screen window): its real tab frames,
// the × on the tab under the pointer, and Chrome-style rapid closing at one spot.
@main struct StripCloseTests {
    @MainActor static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0); NSApplication.shared.setActivationPolicy(.accessory)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-strip-close-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = WindowManager(settingsFile: dir.appendingPathComponent("settings.json"), startPolling: false)
        manager.trusted = true; manager.settings.hiddenLanes = []
        manager.windows = (0..<6).map { i in ManagedWindow(id: "preview-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "example.arc", appName: "Arc", title: "Workspace \(i + 1)", icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil), frame: CGRect(x: 0, y: 0, width: 1200, height: 800), minimized: false, lane: .browser) }
        manager.activeIDs[.browser] = "preview-0"
        // Like a busy app, each close takes 150 ms to answer (on a background thread).
        let lock = NSLock()
        var closedIDs: [String] = []
        var closed: [String] { lock.lock(); defer { lock.unlock() }; return closedIDs }
        manager.actionAccess.close = { window in Thread.sleep(forTimeInterval: 0.15); lock.lock(); closedIDs.append(window.id); lock.unlock(); return true }
        manager.settings.windowStripStyle = .expanding; manager.settings.stripList = .never; manager.settings.capacities["browser"] = 1
        manager.expandedStrip = .browser
        let m = manager.displayedStripMetrics(.browser)
        let host = LaneScrollHostingView(rootView: AnyView(Color.clear))
        host.setStripContent(AnyView(LanePickerContent(manager: manager, lane: .browser, barSize: host.barSize, pointer: host.pointer, showBoard: {})))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: m.width, height: m.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.contentView = host
        host.setFrameSize(NSSize(width: m.width, height: m.height))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderFrontRegardless()
        host.visibility.setHovered(true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        let frames = host.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX }
        precondition(frames.count == 6, "every tab reports its frame")
        precondition(frames.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0.value) }, "tab frames are in the strip's own coordinates")
        let target = host.pointer.tabFrames["preview-2"]!
        // Where the pointer is, as macOS reports it: a point in the window.
        let windowPoint = host.convert(NSPoint(x: target.midX, y: host.isFlipped ? target.midY : host.bounds.height - target.midY), to: nil)
        host.pointerMoved(windowPoint: windowPoint)
        precondition(host.pointer.hoveredTab == "preview-2", "the pointer over Workspace 3 picks Workspace 3")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        print("PASS: a real strip reports its tab frames and the pointer picks the tab under it")
        // Click that × like a person: a real mouse down and up at the × in the window.
        let xPoint = host.convert(NSPoint(x: target.maxX - 10, y: host.isFlipped ? target.midY : host.bounds.height - target.midY), to: nil)
        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        host.pointerMoved(windowPoint: xPoint)
        manager.busy = true   // test only: the post-close refresh would load this Mac's real windows
        // Watch the main thread while the tab folds: it must keep ticking at display rate.
        var ticks: [CFTimeInterval] = []
        let watch = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in ticks.append(CACurrentMediaTime()) }
        RunLoop.main.add(watch, forMode: .common)
        click(xPoint)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        // LANES_CLOSE_FRAMES=1 also saves each step as build/close-*.png.
        func shot(_ name: String) throws {
            guard ProcessInfo.processInfo.environment["LANES_CLOSE_FRAMES"] != nil else { return }
            let r = host.bitmapImageRepForCachingDisplay(in: host.bounds)!; host.cacheDisplay(in: host.bounds, to: r)
            try r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
        }
        try shot("close-1-mid")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        try shot("close-2-after")
        watch.invalidate()
        let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
        print("main thread during the fold: \(ticks.count) ticks, longest gap \(String(format: "%.0f", gaps.max() ?? 0)) ms")
        precondition((gaps.max() ?? 999) < 40, "a slow app must not freeze the main thread while the tab folds")
        print("closed: \(closed)")
        precondition(closed == ["preview-2"], "the × closes exactly Workspace 3")
        let next = host.pointer.tabFrames["preview-3"]!
        print("Workspace 4 now at x \(Int(next.minX))–\(Int(next.maxX)) (Workspace 3 was \(Int(target.minX))–\(Int(target.maxX))); hovered: \(host.pointer.hoveredTab ?? "none")")
        precondition(abs(next.minX - target.minX) < 1.5 && abs(next.width - target.width) < 1.5, "Workspace 4 slides exactly into Workspace 3's place")
        precondition(host.pointer.hoveredTab == "preview-3", "the next tab's × is under the cursor")
        // The app really closes the window: nothing under the cursor moves.
        manager.windows.removeAll { $0.id == "preview-2" }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        try shot("close-3-gone")
        let stay = host.pointer.tabFrames["preview-3"]!
        print("after the window is gone: Workspace 4 at x \(Int(stay.minX))–\(Int(stay.maxX))")
        precondition(abs(stay.minX - target.minX) < 1.5 && abs(stay.width - target.width) < 1.5, "while the pointer stays on the strip, tabs keep their width")
        // Rapid second close, same spot.
        click(xPoint)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        precondition(closed == ["preview-2", "preview-3"], "a second click at the same spot closes the next tab")
        precondition(host.pointer.hoveredTab == "preview-4", "and Workspace 5's × is now under the cursor")
        manager.windows.removeAll { $0.id == "preview-3" }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        // Leaving the strip lets the tabs widen again.
        host.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        try shot("close-4-released")
        print("after leaving: Workspace 5 width \(Int(host.pointer.tabFrames["preview-4"]!.width)) (frozen was \(Int(target.width)))")
        print("PASS: closing folds the tab away, the next tab and its × land under the cursor, widths hold until the pointer leaves")
        // The same on a list strip: the list is a box of its own under the pill, the row
        // under the pointer is the one with the ×, and closing folds that row away so the
        // next row and its × rise under the cursor.
        do {
            let chats = WindowManager(settingsFile: dir.appendingPathComponent("list.json"), startPolling: false)
            chats.trusted = true; chats.busy = true; chats.settings.hiddenLanes = []
            chats.windows = (0..<5).map { i in ManagedWindow(id: "chat-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "example.chat", appName: "Chat", title: "Room \(i + 1)", icon: NSImage(systemSymbolName: "message", accessibilityDescription: nil), frame: CGRect(x: 0, y: 0, width: 900, height: 700), minimized: false, lane: .messaging) }
            chats.activeIDs[.messaging] = "chat-0"
            var chatClosedIDs: [String] = []
            var chatClosed: [String] { lock.lock(); defer { lock.unlock() }; return chatClosedIDs }
            chats.actionAccess.close = { window in Thread.sleep(forTimeInterval: 0.15); lock.lock(); chatClosedIDs.append(window.id); lock.unlock(); return true }
            chats.settings.windowStripStyle = .expanding; chats.settings.stripList = .always; chats.settings.capacities["messaging"] = 1; chats.settings.windowStripScale = 1
            let rest = chats.stripMetrics(.messaging)
            precondition(abs(rest.width - chats.stripPillWidth(.messaging)) < 0.01 && rest.height == 32, "a resting strip is exactly its pill: dot, name and count")
            chats.expandedStrip = .messaging
            let open = chats.displayedStripMetrics(.messaging), top = WindowStripMetrics.listTop(scale: 1), rowHeight = WindowStripMetrics.listRow(scale: 1)
            precondition(open.height == top + 5 * rowHeight + WindowStripMetrics.listPad && open.width > rest.width, "the open list strip is the pill, a gap, and a box with one line per window")
            let list = LaneScrollHostingView(rootView: AnyView(Color.clear))
            list.barSize.go(to: CGSize(width: open.width, height: open.height), animate: false, screen: nil)
            list.setStripContent(AnyView(LanePickerContent(manager: chats, lane: .messaging, barSize: list.barSize, pointer: list.pointer, showBoard: {})))
            let listWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: open.width, height: open.height), styleMask: [.borderless], backing: .buffered, defer: false)
            listWindow.isOpaque = false; listWindow.backgroundColor = .clear; listWindow.contentView = list
            list.setFrameSize(NSSize(width: open.width, height: open.height))
            listWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000)); listWindow.orderFrontRegardless()
            list.visibility.setHovered(true)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            let rows = list.pointer.tabFrames.sorted { $0.value.minY < $1.value.minY }
            precondition(rows.map(\.key) == (0..<5).map { "chat-\($0)" }, "every list row reports its frame, in order")
            precondition(abs(rows[0].value.minY - top) < 1 && rows.allSatisfy { abs($0.value.height - rowHeight) < 1 && list.bounds.insetBy(dx: -1, dy: -1).contains($0.value) }, "rows start under the pill and its gap, inside the list's own box")
            let row = list.pointer.tabFrames["chat-2"]!
            func inWindow(_ x: CGFloat, _ y: CGFloat) -> NSPoint { list.convert(NSPoint(x: x, y: list.isFlipped ? y : list.bounds.height - y), to: nil) }
            list.pointerMoved(windowPoint: inWindow(24, 16))
            precondition(list.pointer.hoveredTab == nil, "the pill shows no × on any row")
            list.pointerMoved(windowPoint: inWindow(row.midX, row.midY))
            precondition(list.pointer.hoveredTab == "chat-2", "the pointer on Room 3's line picks Room 3")
            // The × sits at the right end of the line, past the row's highlight.
            let xSpot = inWindow(row.maxX - 3 - (WindowStripMetrics.tabText(scale: 1) * 1.45).rounded() / 2, row.midY)
            func closeButton() -> TabCloseButtonView? {
                var view = list.hitTest(list.superview?.convert(xSpot, from: nil) ?? xSpot)
                while let v = view, !(v is TabCloseButtonView) { view = v.superview }
                return view as? TabCloseButtonView
            }
            list.pointerMoved(windowPoint: inWindow(row.midX, rows[0].value.midY))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            precondition(closeButton() == nil, "a line the pointer is not on shows no × and takes no close click")
            list.pointerMoved(windowPoint: xSpot)
            precondition(list.pointer.hoveredTab == "chat-2", "the × belongs to the line it is on")
            // The × appears once the strip has drawn the hover; until then it takes no clicks.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            guard let first = closeButton() else { preconditionFailure("the × is a real button at the right end of the line") }
            precondition(first.accessibilityLabel() == "Close Chat: Room 3", "the × under the pointer closes the line it is on")
            first.performClick(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(chatClosed == ["chat-2"], "the × closes exactly Room 3")
            let risen = list.pointer.tabFrames["chat-3"]!
            print("Room 4 now at y \(Int(risen.minY))–\(Int(risen.maxY)) (Room 3 was \(Int(row.minY))–\(Int(row.maxY))); hovered: \(list.pointer.hoveredTab ?? "none")")
            precondition(abs(risen.minY - row.minY) < 1.5 && list.pointer.tabFrames["chat-2"] == nil, "Room 4 rises exactly into Room 3's place")
            precondition(list.pointer.hoveredTab == "chat-3", "the next line's × is under the cursor")
            precondition(chats.displayedStripMetrics(.messaging).height == top + 4 * rowHeight + WindowStripMetrics.listPad, "the box shrinks by one line with the fold")
            chats.windows.removeAll { $0.id == "chat-2" }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            guard let second = closeButton() else { preconditionFailure("the next line's × is at the same spot") }
            precondition(second.accessibilityLabel() == "Close Chat: Room 4", "a second click at the same spot closes the next line")
            second.performClick(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(chatClosed == ["chat-2", "chat-3"] && list.pointer.hoveredTab == "chat-4", "rapid closing in a list works line after line")
            print("PASS: a list strip is a pill with its own box under it; the × follows the line under the pointer and rapid closing rises the next line into place")
        }
        // An Expand-on-hover tab strip at rest already holds its tabs, at their open size:
        // hovering only reveals them, nothing is built or re-laid out mid-hover.
        do {
            let calm = WindowManager(settingsFile: dir.appendingPathComponent("calm.json"), startPolling: false)
            calm.trusted = true; calm.busy = true; calm.settings.hiddenLanes = []
            calm.displayOverride = CGRect(x: 0, y: 0, width: 1512, height: 944)
            calm.windows = (0..<6).map { i in ManagedWindow(id: "page-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "example.arc", appName: "Arc", title: "Page \(i + 1)", icon: nil, frame: CGRect(x: 0, y: 0, width: 1200, height: 800), minimized: false, lane: .browser) }
            calm.settings.windowStripStyle = .expanding; calm.settings.stripList = .never; calm.settings.capacities["browser"] = 1
            let restSize = calm.displayedStripMetrics(.browser), openSize = calm.openTabStripMetrics(.browser)
            precondition(openSize.width > restSize.width, "the strip rests as its pill")
            let strip = LaneScrollHostingView(rootView: AnyView(Color.clear))
            strip.barSize.go(to: CGSize(width: restSize.width, height: restSize.height), animate: false, screen: nil)
            strip.setStripContent(AnyView(LanePickerContent(manager: calm, lane: .browser, barSize: strip.barSize, pointer: strip.pointer, showBoard: {})))
            let stripWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: openSize.width, height: openSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
            stripWindow.isOpaque = false; stripWindow.backgroundColor = .clear; stripWindow.contentView = strip
            strip.setFrameSize(NSSize(width: openSize.width, height: openSize.height))
            stripWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000)); stripWindow.orderFrontRegardless()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            let resting = strip.pointer.tabFrames
            precondition(resting.count == 6, "a resting Expand-on-hover strip keeps its \(resting.count) of 6 tabs mounted")
            calm.stripHovered(.browser, true)
            strip.barSize.go(to: CGSize(width: openSize.width, height: openSize.height), animate: false, screen: nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let hovered = strip.pointer.tabFrames
            precondition(hovered.count == 6 && hovered.allSatisfy { id, frame in resting[id].map { abs($0.minX - frame.minX) < 0.5 && abs($0.width - frame.width) < 0.5 } == true }, "hovering reveals the same tabs at the same places and sizes: nothing reflows")
            print("PASS: an Expand-on-hover tab strip lays its tabs out once, at rest, and hovering only reveals them")
        }
        // A Vertical list strip resting at the bottom edge of the display, 12 windows:
        // opening it must leave the pill under the pointer, not slide a row there.
        do {
            let low = WindowManager(settingsFile: dir.appendingPathComponent("low.json"), startPolling: false)
            low.trusted = true; low.busy = true
            low.focusAccess = WindowFocusAccess(frontPID: { getpid() }, windowID: { _ in nil }, stack: { [] }, prepare: { _ in }, raise: { _ in true }, activate: { _ in true }, unminimize: { _ in })
            let display = CGRect(x: 0, y: 0, width: 1512, height: 944)
            low.displayOverride = display
            low.settings.shelvedLanes = []; low.settings.showMediaShelf = false
            low.settings.hiddenLanes = low.availableLanes.filter { $0 != .messaging && $0 != .browser }.map(\.rawValue)
            low.settings.gap = 12; low.settings.windowStripScale = 1; low.settings.capacities["messaging"] = 1; low.settings.useCustomGrid = true
            low.settings.customRects = ["browser": ZoneRect(CGRect(x: 0, y: 0, width: 0.6, height: 1)), "messaging": ZoneRect(CGRect(x: 0.6, y: 0, width: 0.4, height: 1))]
            low.settings.windowStripStyle = .expanding; low.settings.stripList = .always
            low.windows = (0..<12).map { i in ManagedWindow(id: "chat-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "example.chat", appName: "Chat", title: "Room \(i + 1)", icon: NSImage(systemSymbolName: "message", accessibilityDescription: nil), frame: CGRect(x: 0, y: 0, width: 900, height: 700), minimized: false, lane: .messaging) }
            low.visibleSlotIDs[.messaging] = ["chat-0"]
            var lowClosed: [String] = []
            low.actionAccess.close = { window in lock.lock(); lowClosed.append(window.id); lock.unlock(); return true }
            low.settings.stripPositions["messaging"] = StripPosition(x: 0.5, y: 0.9999)
            let rest = low.stripRestFrame(.messaging)
            precondition(rest.maxY == display.maxY && rest.height == 32, "the pill rests on the display's bottom edge")
            low.stripHovered(.messaging, true)
            let panel = low.stripFrame(.messaging), open = low.displayedStripMetrics(.messaging)
            precondition(display.contains(panel) && panel.height == open.height, "the open strip is on the display")
            let list = LaneScrollHostingView(rootView: AnyView(Color.clear))
            list.barSize.panelWillMove(to: panel.minX)
            list.barSize.go(to: CGSize(width: open.width, height: open.height), screenX: panel.minX, restX: rest.minX, animate: false, screen: nil)
            list.setStripContent(AnyView(LanePickerContent(manager: low, lane: .messaging, barSize: list.barSize, pointer: list.pointer, showBoard: {})))
            let listWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: panel.width, height: panel.height), styleMask: [.borderless], backing: .buffered, defer: false)
            listWindow.isOpaque = false; listWindow.backgroundColor = .clear; listWindow.contentView = list
            list.setFrameSize(NSSize(width: panel.width, height: panel.height))
            listWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000)); listWindow.orderFrontRegardless()
            list.visibility.setHovered(true)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            // A point on the display, as the strip's own view sees it.
            func onDisplay(_ x: CGFloat, _ y: CGFloat) -> NSPoint { list.convert(NSPoint(x: x - panel.minX, y: list.isFlipped ? y - panel.minY : list.bounds.height - (y - panel.minY)), to: nil) }
            precondition(list.pointer.tabFrames.count == 12, "every row reports its frame")
            // The pointer has not moved since it came to rest on the pill.
            list.pointerMoved(windowPoint: onDisplay(rest.minX + 40, rest.midY))
            precondition(list.pointer.hoveredTab == nil, "opening the list leaves the pill under the still pointer, not a row (pointer is on \(list.pointer.hoveredTab ?? "none"))")
            // The same geometry everywhere: the strip's frame, the pill, the rows as drawn, and row drops.
            let pill = low.stripPillFrame(.messaging), rowHeight = WindowStripMetrics.listRow(scale: 1), firstRow = WindowStripMetrics.listTop(scale: 1, above: true)
            precondition(low.stripListOpensAbove(.messaging) && pill.origin == rest.origin && panel.maxY == rest.maxY, "the list is above the pill, and the pill is where it rested")
            let rows = list.pointer.tabFrames.sorted { $0.value.minY < $1.value.minY }
            precondition(rows.map(\.key) == (0..<12).map { "chat-\($0)" }, "rows keep their order, the first window on top")
            precondition(abs(rows[0].value.minY - firstRow) < 1 && rows.allSatisfy { abs($0.value.height - rowHeight) < 1 } && rows[11].value.maxY <= pill.minY - panel.minY - WindowStripMetrics.listGap(scale: 1) + 0.5, "rows are drawn where drops look for them: from the top of the box down to just above the pill")
            for (index, row) in rows.enumerated() {
                precondition(WindowStripMetrics.listDrop(y: row.value.midY - rowHeight / 4, scale: 1, rows: 12, above: true).map { $0.row == index && !$0.after } == true, "a drop on row \(index + 1) as drawn lands on row \(index + 1)")
            }
            // What is drawn: the box at the top of the strip, a clear gap, the pill at the bottom.
            let bitmap = list.bitmapImageRepForCachingDisplay(in: list.bounds)!
            list.cacheDisplay(in: list.bounds, to: bitmap)
            func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat { bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / list.bounds.width), y: Int(y * CGFloat(bitmap.pixelsHigh) / list.bounds.height))?.alphaComponent ?? -1 }
            let pillX = rest.minX - panel.minX + 30
            precondition(alpha(pillX, open.height - 16) > 0.9 && alpha(pillX, open.height - 32 - 1.5) < 0.1 && alpha(pillX, 20) > 0.9, "the pill is drawn at the bottom of the strip, under a gap and the list's box")
            // The × on a row closes that row; the box shrinks toward the pill, so the row above comes down under the pointer.
            let target = list.pointer.tabFrames["chat-6"]!
            func inStrip(_ x: CGFloat, _ y: CGFloat) -> NSPoint { list.convert(NSPoint(x: x, y: list.isFlipped ? y : list.bounds.height - y), to: nil) }
            let xSpot = inStrip(target.maxX - 3 - (WindowStripMetrics.tabText(scale: 1) * 1.45).rounded() / 2, target.midY)
            func closeButton() -> TabCloseButtonView? {
                var view = list.hitTest(list.superview?.convert(xSpot, from: nil) ?? xSpot)
                while let v = view, !(v is TabCloseButtonView) { view = v.superview }
                return view as? TabCloseButtonView
            }
            list.pointerMoved(windowPoint: xSpot)
            precondition(list.pointer.hoveredTab == "chat-6", "the pointer on Room 7's line picks Room 7")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            guard let cross = closeButton() else { preconditionFailure("the × is a real button at the right end of the line") }
            precondition(cross.accessibilityLabel() == "Close Chat: Room 7", "the × under the pointer closes the line it is on")
            cross.performClick(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(lowClosed == ["chat-6"], "the × closes exactly Room 7")
            let lowered = list.pointer.tabFrames["chat-5"]!
            precondition(abs(lowered.minY - target.minY) < 1.5 && list.pointer.hoveredTab == "chat-5", "Room 6 comes down exactly into Room 7's place, under the pointer and its ×")
            precondition(low.stripListOpensAbove(.messaging) && low.stripFrame(.messaging).maxY == rest.maxY && low.stripPillFrame(.messaging).minY == rest.minY, "the pill has not moved, and the list is one row shorter at its far end")
            precondition(abs(list.pointer.tabFrames["chat-11"]!.maxY - rows[11].value.maxY) < 1, "the rows next to the pill stay where they were")
            low.windows.removeAll { $0.id == "chat-6" }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            guard let again = closeButton() else { preconditionFailure("the next line's × is at the same spot") }
            precondition(again.accessibilityLabel() == "Close Chat: Room 6", "a second click at the same spot closes the line that came down")
            again.performClick(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(lowClosed == ["chat-6", "chat-5"] && list.pointer.hoveredTab == "chat-4", "rapid closing works line after line in a list above its pill")
            print("PASS: a list strip at the bottom of the display opens above its pill; the pill stays under the pointer")
        }
        // A Detailed strip on a narrow tile: 12 windows in a 293-point lane. Only whole
        // tabs are shown, beside the pill and the counter; the arrows reach the rest.
        do {
            let narrow = WindowManager(settingsFile: dir.appendingPathComponent("narrow.json"), startPolling: false)
            narrow.trusted = true; narrow.busy = true
            // Picking a tab must not raise or activate anything on this Mac.
            narrow.focusAccess = WindowFocusAccess(frontPID: { getpid() }, windowID: { _ in nil }, stack: { [] }, prepare: { _ in }, raise: { _ in true }, activate: { _ in true }, unminimize: { _ in })
            narrow.displayOverride = CGRect(x: 0, y: 0, width: 1512, height: 944)
            narrow.settings.shelvedLanes = []; narrow.settings.showMediaShelf = false
            narrow.settings.hiddenLanes = narrow.availableLanes.filter { $0 != .terminal && $0 != .browser }.map(\.rawValue)
            narrow.settings.gap = 12; narrow.settings.windowStripScale = 1; narrow.settings.capacities["terminal"] = 1
            narrow.settings.customRects = ["terminal": ZoneRect(CGRect(x: 0, y: 0, width: 305.0 / 1500, height: 1)), "browser": ZoneRect(CGRect(x: 305.0 / 1500, y: 0, width: 1 - 305.0 / 1500, height: 1))]
            narrow.settings.useCustomGrid = true
            narrow.settings.windowStripStyle = .detailed
            narrow.windows = (0..<12).map { i in ManagedWindow(id: "shell-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "example.term", appName: "Term", title: "Shell \(i + 1)", icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil), frame: CGRect(x: 0, y: 0, width: 900, height: 700), minimized: false, lane: .terminal) }
            narrow.visibleSlotIDs[.terminal] = ["shell-0"]
            var narrowClosed: [String] = []
            narrow.actionAccess.close = { window in lock.lock(); narrowClosed.append(window.id); lock.unlock(); return true }
            let lane = narrow.rawLaneFrame(.terminal), size = narrow.displayedStripMetrics(.terminal)
            precondition(abs(lane.width - 293) <= 1 && size.width <= lane.width, "the strip is as wide as its 293-point lane, no wider (lane \(lane.width), strip \(size.width))")
            let strip = LaneScrollHostingView(rootView: AnyView(Color.clear))
            strip.setStripContent(AnyView(LanePickerContent(manager: narrow, lane: .terminal, barSize: strip.barSize, pointer: strip.pointer, showBoard: {})))
            let stripWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            stripWindow.isOpaque = false; stripWindow.backgroundColor = .clear; stripWindow.contentView = strip
            strip.setFrameSize(NSSize(width: size.width, height: size.height))
            stripWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000)); stripWindow.orderFrontRegardless()
            strip.visibility.setHovered(true)
            // The room between the pill's start and the counter: every tab must sit in it, whole.
            let pillEnd = narrow.stripPillWidth(.terminal) - (WindowStripMetrics.pillTrail - 6), counterStart = size.width - WindowStripMetrics.counterWidth(count: 12, scale: 1) - 4
            func tabs() -> [(key: String, value: CGRect)] { strip.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX } }
            func check(_ active: Int) {
                narrow.visibleSlotIDs[.terminal] = ["shell-\(active)"]
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
                let shown = tabs()
                precondition(!shown.isEmpty && shown.allSatisfy { $0.value.minX >= pillEnd - 0.5 && $0.value.maxX <= counterStart + 0.5 && $0.value.width >= 30 },
                             "window \(active + 1) of 12: every tab shown is whole, between the pill and the counter (tabs at \(shown.map { "\(Int($0.value.minX))–\(Int($0.value.maxX))" }), room \(Int(pillEnd))–\(Int(counterStart)))")
                precondition(shown.contains { $0.key == "shell-\(active)" }, "window \(active + 1) of 12: the active window's tab is one of them")
                let numbers = shown.compactMap { Int($0.key.dropFirst(6)) }
                precondition(numbers == Array((numbers.first ?? 0)..<((numbers.first ?? 0) + numbers.count)), "the tabs shown are neighbours, in order")
            }
            for active in [0, 5, 11] { check(active) }
            let fitted = tabs().count
            print("293-point lane, 12 windows: \(fitted) whole tabs of \(Int(tabs()[0].value.width)) points beside the pill and the ‹ 12/12 › counter")
            print("PASS: a Detailed strip on a narrow tile shows only whole tabs around the active one, and its counter")
            // Rapid closing there: the run of tabs holds still, so the next tab slides under the pointer,
            // even when the closed tab was the active one and another window takes over.
            narrow.visibleSlotIDs[.terminal] = ["shell-5"]
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
            let run = tabs()
            precondition(run.map(\.key) == ["shell-4", "shell-5", "shell-6"], "three tabs around Shell 6: \(run.map(\.key))")
            let spot = run[1].value
            func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { strip.convert(NSPoint(x: x, y: strip.isFlipped ? y : strip.bounds.height - y), to: nil) }
            func press(_ p: NSPoint) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    stripWindow.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: stripWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
            }
            let cross = at(spot.maxX - 10, spot.midY)
            strip.pointerMoved(windowPoint: cross)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            press(cross)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(narrowClosed == ["shell-5"], "the × closes the active tab, Shell 6 (closed: \(narrowClosed))")
            var slid = strip.pointer.tabFrames["shell-6"]!
            precondition(abs(slid.minX - spot.minX) < 1.5 && abs(slid.width - spot.width) < 1.5 && strip.pointer.hoveredTab == "shell-6", "Shell 7 slides into Shell 6's place, under the pointer")
            precondition(tabs().map(\.key) == ["shell-4", "shell-6", "shell-7"], "and the next tab comes in at the end: \(tabs().map(\.key))")
            narrow.windows.removeAll { $0.id == "shell-5" }   // the app closed it; Shell 1 now shows in the tile
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
            precondition(narrow.activeWindow(.terminal)?.id == "shell-0", "another window takes the tile")
            slid = strip.pointer.tabFrames["shell-6"]!
            precondition(abs(slid.minX - spot.minX) < 1.5 && tabs().map(\.key) == ["shell-4", "shell-6", "shell-7"] && strip.pointer.hoveredTab == "shell-6", "the tabs under the pointer hold still when another window takes over: \(tabs().map(\.key))")
            press(cross)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            precondition(narrowClosed == ["shell-5", "shell-6"] && strip.pointer.hoveredTab == "shell-7", "a second click at the same spot closes the next tab")
            narrow.windows.removeAll { $0.id == "shell-6" }
            // Picking a window that is not among the tabs (the counter's arrow) brings its tab in.
            narrow.reveal(narrow.windows.first { $0.id == "shell-10" }!)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
            precondition(tabs().contains { $0.key == "shell-10" }, "the tabs follow a window you step to: \(tabs().map(\.key))")
            // Leaving the strip re-centers the tabs on the window that shows.
            strip.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!)
            narrow.stripHovered(.terminal, false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let rested = tabs()
            precondition(narrow.frozenTabWidth[.terminal] == nil && rested.contains { $0.key == narrow.activeWindow(.terminal)?.id } && rested.allSatisfy { $0.value.maxX <= counterStart + 6 }, "after the pointer leaves, the tabs are the whole ones around the window that shows")
            print("PASS: rapid closing on a narrow tab strip keeps the next tab under the pointer")
        }
        // Dragging a strip: press anywhere on its pill and move. Tabs and list rows keep
        // their own drag (reorder, move to another category); a press that does not move
        // is a click on whatever is under it.
        do {
            StripCursor.live = false   // test only: no hand cursors on the real pointer
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            func desk(_ file: String, lane: Lane, other: Lane, count: Int, bundle: String) -> WindowManager {
                let m = WindowManager(settingsFile: dir.appendingPathComponent(file), startPolling: false)
                m.trusted = true; m.busy = true
                m.focusAccess = WindowFocusAccess(frontPID: { getpid() }, windowID: { _ in nil }, stack: { [] }, prepare: { _ in }, raise: { _ in true }, activate: { _ in true }, unminimize: { _ in })
                // A display far from every real one: the strip's window sits exactly where the
                // manager places it, as in the app, and nobody sees it.
                m.displayOverride = CGRect(x: -30000, y: 30000, width: 1512, height: 944)
                m.settings.shelvedLanes = []; m.settings.showMediaShelf = false
                m.settings.hiddenLanes = m.availableLanes.filter { $0 != lane && $0 != other }.map(\.rawValue)
                m.settings.gap = 12; m.settings.windowStripScale = 1; m.settings.useCustomGrid = true
                m.settings.customRects = [lane.rawValue: ZoneRect(CGRect(x: 0, y: 0, width: 0.6, height: 1)), other.rawValue: ZoneRect(CGRect(x: 0.6, y: 0, width: 0.4, height: 1))]
                m.windows = (0..<count).map { i in ManagedWindow(id: "win-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: bundle, appName: "App", title: "Window \(i + 1)", icon: nil, frame: CGRect(x: 0, y: 0, width: 900, height: 700), minimized: false, lane: lane) }
                return m
            }
            // A strip in its real window, built the way the app builds it, far off screen.
            final class Rig {
                let manager: WindowManager, lane: Lane, panel: StripPanel, strip: LaneScrollHostingView
                var mouse = NSPoint.zero   // the pointer on the screen, as the drag reads it
                @MainActor init(_ manager: WindowManager, _ lane: Lane) {
                    self.manager = manager; self.lane = lane
                    panel = StripPanel(contentRect: Self.cocoa(manager.stripFrame(lane)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: LaneWindowStrip(manager: manager, lane: lane, showBoard: {}))
                    host.sizingOptions = []
                    panel.contentView = host
                    LaneWindowStrip.makeDraggable(panel, manager: manager, lane: lane)
                    panel.orderFrontRegardless()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
                    strip = LaneWindowStrip.stripView(in: panel)!
                    strip.visibility.setHovered(true)
                    panel.drag!.pointerLocation = { [unowned self] in self.mouse }
                    // Like the app: whenever strips are placed, the window goes where the manager says.
                    manager.onLaneControls = { [unowned self] in self.place() }
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                }
                static func cocoa(_ frame: CGRect) -> NSRect { NSRect(x: frame.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY, width: frame.width, height: frame.height) }
                @MainActor func place() {
                    guard manager.draggingStrip != lane else { return }
                    let frame = manager.stripFrame(lane)
                    if manager.settings.stripStyle(lane).expandsOnHover { strip.barSize.panelWillMove(to: frame.minX) }
                    panel.setFrame(Self.cocoa(frame), display: false)
                    LaneWindowStrip.syncBar(strip, manager: manager, lane: lane, frame: frame, animate: false)
                }
                // A point of the strip (top-left coordinates, like its tab frames) in its window.
                @MainActor func inWindow(_ p: CGPoint) -> NSPoint { strip.convert(NSPoint(x: p.x, y: strip.isFlipped ? p.y : strip.bounds.height - p.y), to: nil) }
                @MainActor func event(_ type: NSEvent.EventType, _ windowPoint: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                }
                // The pointer goes to a point of the strip; the events below happen where it is.
                @MainActor func point(at p: CGPoint) { mouse = panel.convertPoint(toScreen: inWindow(p)) }
                @MainActor func here(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent { event(type, panel.convertPoint(fromScreen: mouse), flags: flags) }
                @MainActor func settle(_ seconds: TimeInterval = 0.12) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
                // Like a person: press at a point of the strip and let go without moving.
                @MainActor func click(_ p: CGPoint) {
                    point(at: p); panel.sendEvent(here(.leftMouseDown)); panel.sendEvent(here(.leftMouseUp)); settle()
                }
                // Press at a point of the strip, move the pointer by (dx, dy) on the screen in steps, let go.
                // `during` runs while the button is still down.
                @MainActor func drag(from p: CGPoint, dx: CGFloat, dy: CGFloat, steps: Int = 5, during: () -> Void = {}) {
                    point(at: p); let start = mouse
                    panel.sendEvent(here(.leftMouseDown))
                    for step in 1...steps {
                        mouse = NSPoint(x: start.x + dx * CGFloat(step) / CGFloat(steps), y: start.y + dy * CGFloat(step) / CGFloat(steps))
                        panel.sendEvent(here(.leftMouseDragged))
                    }
                    during()
                    panel.sendEvent(here(.leftMouseUp)); settle()
                }
            }
            // The spot moveStrip saves for a strip dropped with its window at `frame`.
            func savedSpot(_ m: WindowManager, _ lane: Lane, window frame: NSRect) -> StripPosition {
                let idle = m.stripMetrics(lane)
                return StripPlacementGeometry.position(of: CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: idle.width, height: idle.height), in: m.rawLaneFrame(lane))
            }
            func near(_ a: StripPosition?, _ b: StripPosition) -> Bool { a.map { abs($0.x - b.x) < 0.0001 && abs($0.y - b.y) < 0.0001 } ?? false }
            func at(_ frame: NSRect, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(frame.minX - x) <= 1 && abs(frame.minY - y) <= 1 }

            // 1. A Detailed strip: the pill holds the name, the count, two pane buttons, tabs and the counter.
            let tabsDesk = desk("drag-tabs.json", lane: .browser, other: .terminal, count: 4, bundle: "example.arc")
            tabsDesk.settings.windowStripStyle = .detailed; tabsDesk.settings.capacities["browser"] = 2
            tabsDesk.visibleSlotIDs[.browser] = ["win-0", "win-1"]; tabsDesk.activeIDs[.browser] = "win-0"; tabsDesk.activeSlot[.browser] = 0
            precondition(tabsDesk.settings.stripPlacement == .onWindows, "strips sit on the windows by default")
            let rig = Rig(tabsDesk, .browser)
            guard let pill = rig.strip.pointer.pillFrame else { preconditionFailure("the strip reports where its pill is drawn") }
            let tabFrames = rig.strip.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX }
            precondition(tabFrames.count == 4 && tabFrames.allSatisfy { pill.contains($0.value) }, "a Detailed strip's pill holds its \(tabFrames.count) tabs (pill \(pill))")
            precondition(abs(pill.width - rig.strip.bounds.width) < 1 && abs(pill.height - 32) < 1 && pill.minX < 1, "the pill is the whole Detailed strip (pill \(pill), strip \(rig.strip.bounds))")
            let name = CGPoint(x: pill.minX + WindowStripMetrics.pillLead + WindowStripMetrics.dotBox + WindowStripMetrics.dotGap + 6, y: pill.midY)
            let dot = CGPoint(x: pill.minX + WindowStripMetrics.pillLead + WindowStripMetrics.dotBox / 2, y: pill.midY)
            let edge = CGPoint(x: pill.minX + 4, y: pill.midY)
            let anyTab = CGPoint(x: tabFrames[2].value.midX, y: tabFrames[2].value.midY)
            let between = CGPoint(x: (tabFrames[1].value.maxX + tabFrames[2].value.minX) / 2, y: pill.midY)
            let nextArrow = CGPoint(x: pill.maxX - 4 - WindowStripMetrics.counterArrow / 2, y: pill.midY)
            for (spot, what) in [(name, "the name"), (dot, "the dot"), (edge, "the pill's edge"), (between, "the gap between two tabs"), (nextArrow, "the counter's arrow")] {
                precondition(rig.strip.dragsStrip(windowPoint: rig.inWindow(spot)), "a press on \(what) can drag the strip")
            }
            precondition(tabFrames.allSatisfy { !rig.strip.dragsStrip(windowPoint: rig.inWindow(CGPoint(x: $0.value.midX, y: $0.value.midY))) } && !rig.strip.dragsStrip(windowPoint: rig.inWindow(anyTab)) && !rig.strip.dragsStrip(windowPoint: rig.inWindow(CGPoint(x: pill.midX, y: pill.maxY + 30))), "a press on a tab, or off the pill, does not drag the strip")
            // The Right pane button is the last thing before the tabs: find it by clicking leftwards.
            var paneButton: CGPoint?
            for x in stride(from: tabFrames[0].value.minX - 8, through: name.x + 20, by: -3) where paneButton == nil {
                tabsDesk.activeSlot[.browser] = 0
                rig.click(CGPoint(x: x, y: pill.midY))
                if tabsDesk.activeSlot[.browser] == 1 { paneButton = CGPoint(x: x - 4, y: pill.midY) }
            }
            guard let paneButton else { preconditionFailure("the Right pane button sits on the pill before the tabs") }
            precondition(rig.strip.dragsStrip(windowPoint: rig.inWindow(paneButton)), "a press on a pane button can drag the strip")
            let home = rig.panel.frame
            precondition(tabsDesk.settings.stripPositions["browser"] == nil && tabsDesk.draggingStrip == nil, "clicks leave the strip where it is")
            // Press on the name and move 20 points: the strip follows the pointer.
            var held: (lane: Lane?, origin: NSPoint)?
            rig.drag(from: name, dx: 20, dy: -9) { held = (tabsDesk.draggingStrip, rig.panel.frame.origin) }
            precondition(held?.lane == .browser && held?.origin == NSPoint(x: home.minX + 20, y: home.minY - 9), "a press on the name, moved 20 points, moves the strip with the pointer (\(String(describing: held)))")
            precondition(tabsDesk.draggingStrip == nil && at(rig.panel.frame, home.minX + 20, home.minY - 9), "letting go leaves the strip where it was dropped (\(rig.panel.frame.origin), from \(home.origin))")
            precondition(near(tabsDesk.settings.stripPositions["browser"], savedSpot(tabsDesk, .browser, window: NSRect(x: home.minX + 20, y: home.minY - 9, width: home.width, height: home.height))), "and saves that spot for the category, as dragging the dot did")
            // A press that barely moves is a click, not a drag.
            let dropped = tabsDesk.settings.stripPositions["browser"]
            var spot = rig.panel.frame
            tabsDesk.activeSlot[.browser] = 0
            rig.drag(from: paneButton, dx: 3, dy: 0, steps: 3) { precondition(tabsDesk.draggingStrip == nil, "three points is not a drag yet") }
            precondition(at(rig.panel.frame, spot.minX, spot.minY) && tabsDesk.settings.stripPositions["browser"] == dropped && tabsDesk.activeSlot[.browser] == 1, "a press that moves less than the threshold is a click on the button under it")
            spot = rig.panel.frame
            // A drag that starts on a button moves the strip and does not press the button.
            tabsDesk.activeSlot[.browser] = 0
            rig.drag(from: paneButton, dx: 30, dy: 0)
            precondition(at(rig.panel.frame, spot.minX + 30, spot.minY) && tabsDesk.settings.stripPositions["browser"] != dropped, "a drag that starts on a pane button moves the strip (\(rig.panel.frame.origin), from \(spot.origin))")
            precondition(tabsDesk.activeSlot[.browser] == 0, "and does not press that button")
            rig.click(paneButton)
            precondition(tabsDesk.activeSlot[.browser] == 1, "after a drag, a click on the pane button still selects its pane")
            // The same on the counter: a click steps to the next window, a drag moves the strip.
            let showing = tabsDesk.activeIDs[.browser]
            rig.click(nextArrow)
            let stepped = tabsDesk.activeIDs[.browser]
            precondition(stepped != showing, "a click on the counter's arrow steps to the next window (\(showing ?? "none") → \(stepped ?? "none"))")
            spot = rig.panel.frame
            rig.drag(from: nextArrow, dx: 0, dy: -24)
            precondition(at(rig.panel.frame, spot.minX, spot.minY - 24) && tabsDesk.activeIDs[.browser] == stepped, "a drag that starts on the counter's arrow moves the strip and steps nowhere (\(rig.panel.frame.origin), from \(spot.origin))")
            // Tabs: a click shows the window; a drag is the tab's own, never the strip's.
            spot = rig.panel.frame
            let before = tabsDesk.settings.stripPositions["browser"]
            // A tab whose window is not the one showing, and another to let go over.
            let hidden = tabFrames.filter { $0.key != tabsDesk.activeIDs[.browser] }
            let tabID = hidden[0].key, tab = CGPoint(x: hidden[0].value.midX, y: hidden[0].value.midY), otherTab = CGPoint(x: hidden[1].value.midX, y: hidden[1].value.midY)
            rig.click(tab)
            precondition(tabsDesk.activeIDs[.browser] == tabID && rig.panel.frame == spot, "a press and release on a tab shows that window and moves nothing")
            // The tab's drag belongs to the tab: the strip passes every event of it on, untouched.
            rig.point(at: tab); var passed = 0
            precondition(!rig.panel.drag!.handle(rig.here(.leftMouseDown), in: rig.panel) { _ in passed += 1 }, "a press on a tab goes to the tab")
            for step in 1...6 {
                rig.mouse.x += 5
                precondition(!rig.panel.drag!.handle(rig.here(.leftMouseDragged), in: rig.panel) { _ in passed += 1 }, "a tab's drag (step \(step)) goes to the tab: it reorders tabs or moves the window to another category")
            }
            rig.point(at: otherTab)
            precondition(!rig.panel.drag!.handle(rig.here(.leftMouseUp), in: rig.panel) { _ in passed += 1 }, "and so does its release")
            precondition(passed == 0 && rig.panel.frame == spot && tabsDesk.draggingStrip == nil && tabsDesk.settings.stripPositions["browser"] == before, "dragging a tab never moves the strip")
            // What the strip's controls see of a strip drag: the press, then one release far away, then nothing.
            rig.point(at: name)
            var seen: [NSEvent] = []
            precondition(!rig.panel.drag!.handle(rig.here(.leftMouseDown), in: rig.panel) { seen.append($0) }, "the press itself reaches the control under it")
            rig.mouse.x += 3
            precondition(rig.panel.drag!.handle(rig.here(.leftMouseDragged), in: rig.panel) { seen.append($0) } && seen.isEmpty && !rig.panel.drag!.dragging, "small moves after the press are kept from the controls")
            rig.mouse.x += 9
            precondition(rig.panel.drag!.handle(rig.here(.leftMouseDragged), in: rig.panel) { seen.append($0) } && rig.panel.drag!.dragging, "past the threshold the press becomes a drag")
            precondition(seen.count == 1 && seen[0].type == .leftMouseUp && !rig.panel.contentView!.frame.contains(seen[0].locationInWindow), "the pressed control is let go once, far outside itself, so it un-highlights and does not fire")
            rig.mouse.x += 9
            precondition(rig.panel.drag!.handle(rig.here(.leftMouseDragged), in: rig.panel) { seen.append($0) } && rig.panel.drag!.handle(rig.here(.leftMouseUp), in: rig.panel) { seen.append($0) }, "the rest of the drag and its release are the strip's")
            precondition(seen.count == 1 && !rig.panel.drag!.dragging && tabsDesk.draggingStrip == nil, "the controls see nothing more of it")
            // Control-click opens the strip's menu; it never starts a drag.
            spot = rig.panel.frame; rig.point(at: name)
            precondition(!rig.panel.drag!.handle(rig.here(.leftMouseDown, flags: .control), in: rig.panel) { _ in }, "a Control-click reaches the strip")
            rig.mouse.x += 30
            precondition(!rig.panel.drag!.handle(rig.here(.leftMouseDragged, flags: .control), in: rig.panel) { _ in } && rig.panel.frame == spot, "and moving after it does not drag the strip")
            _ = rig.panel.drag!.handle(rig.here(.leftMouseUp), in: rig.panel) { _ in }
            // Strips in a band above the windows stay put, as before.
            tabsDesk.settings.stripPlacement = .aboveWindows
            rig.settle(0.3)
            let band = rig.strip.pointer.pillFrame ?? pill
            let bandName = CGPoint(x: band.minX + WindowStripMetrics.pillLead + WindowStripMetrics.dotBox + WindowStripMetrics.dotGap + 6, y: band.midY)
            spot = rig.panel.frame
            precondition(!rig.strip.dragsStrip(windowPoint: rig.inWindow(bandName)), "a strip above the windows cannot be dragged")
            rig.drag(from: bandName, dx: 25, dy: 0)
            precondition(rig.panel.frame == spot && tabsDesk.draggingStrip == nil, "pressing and moving on it moves nothing")
            rig.panel.close()
            print("PASS: a strip drags from anywhere on its pill (name, dot, edge, gaps, pane buttons, counter); clicks still click, a drag never presses a button, and tabs keep their own drag")

            // 2. A list strip: the pill drags it, the rows under the pill do not.
            let listDesk = desk("drag-list.json", lane: .messaging, other: .browser, count: 5, bundle: "example.chat")
            listDesk.settings.windowStripStyle = .expanding; listDesk.settings.stripList = .always; listDesk.settings.capacities["messaging"] = 1
            listDesk.visibleSlotIDs[.messaging] = ["win-0"]; listDesk.activeIDs[.messaging] = "win-0"
            listDesk.stripHovered(.messaging, true)
            let listRig = Rig(listDesk, .messaging)
            guard let listPill = listRig.strip.pointer.pillFrame else { preconditionFailure("a list strip reports where its pill is drawn") }
            let rows = listRig.strip.pointer.tabFrames.sorted { $0.value.minY < $1.value.minY }
            precondition(rows.count == 5 && listPill.height < 33 && rows.allSatisfy { $0.value.minY >= listPill.maxY }, "an open list strip is a pill with its rows under it (pill \(listPill), first row \(rows.first?.value ?? .zero))")
            let row = CGPoint(x: rows[3].value.midX, y: rows[3].value.midY)
            let listName = CGPoint(x: listPill.minX + WindowStripMetrics.pillLead + WindowStripMetrics.dotBox + WindowStripMetrics.dotGap + 6, y: listPill.midY)
            let boxEdge = CGPoint(x: rows[0].value.midX, y: (listPill.maxY + rows[0].value.minY) / 2)
            precondition(listRig.strip.dragsStrip(windowPoint: listRig.inWindow(listName)) && !listRig.strip.dragsStrip(windowPoint: listRig.inWindow(row)) && !listRig.strip.dragsStrip(windowPoint: listRig.inWindow(boxEdge)), "the pill drags a list strip; its rows and the box around them do not")
            let listHome = listRig.panel.frame
            listRig.point(at: row); var rowPassed = 0
            precondition(!listRig.panel.drag!.handle(listRig.here(.leftMouseDown), in: listRig.panel) { _ in rowPassed += 1 }, "a press on a row goes to the row")
            for _ in 1...6 {
                listRig.mouse.y -= 5
                precondition(!listRig.panel.drag!.handle(listRig.here(.leftMouseDragged), in: listRig.panel) { _ in rowPassed += 1 }, "a row's drag goes to the row: it reorders the list or moves the window to another category")
            }
            precondition(!listRig.panel.drag!.handle(listRig.here(.leftMouseUp), in: listRig.panel) { _ in rowPassed += 1 } && rowPassed == 0 && listRig.panel.frame == listHome && listDesk.draggingStrip == nil, "dragging a row never moves the strip")
            listRig.click(row)
            precondition(listDesk.activeIDs[.messaging] == rows[3].key && at(listRig.panel.frame, listHome.minX, listHome.minY), "a click on a row still shows its window and moves nothing")
            listRig.drag(from: listName, dx: -18, dy: -12)
            precondition(at(listRig.panel.frame, listHome.minX - 18, listHome.minY - 12) && listDesk.draggingStrip == nil && listDesk.settings.stripPositions["messaging"] != nil, "a press on the pill's name, moved, drags the list strip and saves its spot (\(listRig.panel.frame.origin), from \(listHome.origin))")
            listRig.panel.close()
            print("PASS: a list strip drags by its pill; its rows keep their own drag and still click")

            // 3. Expand on hover, the default look: the resting pill is all handle; open, its tabs are not.
            let hoverDesk = desk("drag-hover.json", lane: .browser, other: .terminal, count: 4, bundle: "example.arc")
            hoverDesk.settings.windowStripStyle = .expanding; hoverDesk.settings.stripList = .never; hoverDesk.settings.capacities["browser"] = 1
            hoverDesk.visibleSlotIDs[.browser] = ["win-0"]; hoverDesk.activeIDs[.browser] = "win-0"
            let hoverRig = Rig(hoverDesk, .browser)
            guard let resting = hoverRig.strip.pointer.pillFrame else { preconditionFailure("a resting strip reports where its pill is drawn") }
            let restWidth = hoverDesk.stripMetrics(.browser).width
            precondition(abs(resting.width - restWidth) < 1.5 && abs(resting.minX) < 1 && hoverRig.strip.bounds.insetBy(dx: -1, dy: -1).contains(resting), "at rest the pill is the dot, the name and the count, at the start of its window (\(resting), rest width \(restWidth))")
            for x in stride(from: resting.minX + 3, to: resting.maxX - 3, by: 6) {
                precondition(hoverRig.strip.dragsStrip(windowPoint: hoverRig.inWindow(CGPoint(x: x, y: resting.midY))), "every part of the resting pill drags the strip (x \(x) of \(resting))")
            }
            let hoverHome = hoverRig.panel.frame
            hoverRig.drag(from: CGPoint(x: resting.maxX - 8, y: resting.midY), dx: 22, dy: 0)
            precondition(at(hoverRig.panel.frame, hoverHome.minX + 22, hoverHome.minY) && hoverDesk.settings.stripPositions["browser"] != nil, "a press on the resting pill's count, moved, drags the strip (\(hoverRig.panel.frame.origin), from \(hoverHome.origin))")
            // The bar can sit to the right of its (invisible) window's left edge, when the
            // window made room on the left. The handle is where the pill is drawn.
            hoverRig.strip.barSize.go(to: CGSize(width: resting.width - 46, height: resting.height), screenX: hoverRig.panel.frame.minX + 40, animate: false, screen: nil)
            hoverRig.settle(0.3)
            let shifted = hoverRig.strip.pointer.pillFrame ?? .zero
            precondition(abs(hoverRig.strip.barSize.offsetX - 40) < 0.5 && abs(shifted.minX - resting.minX - 40) < 1, "the pill reports where it is drawn when its bar is shifted inside its window (\(shifted), offset \(hoverRig.strip.barSize.offsetX))")
            precondition(hoverRig.strip.dragsStrip(windowPoint: hoverRig.inWindow(CGPoint(x: shifted.minX + 20, y: shifted.midY))) && !hoverRig.strip.dragsStrip(windowPoint: hoverRig.inWindow(CGPoint(x: resting.minX + 20, y: resting.midY))), "and the handle moves with it")
            hoverRig.panel.close()
            print("PASS: every part of a resting Expand-on-hover pill drags its strip")

            // 4. Fit to window width, on a real strip: the idle pill is as small as ever; hovering
            // opens a bar as wide as the category's windows, and its tabs share that width.
            let fitDesk = desk("fit.json", lane: .browser, other: .terminal, count: 2, bundle: "example.arc")
            fitDesk.settings.windowStripStyle = .expanding; fitDesk.settings.stripList = .never; fitDesk.settings.capacities["browser"] = 1
            fitDesk.visibleSlotIDs[.browser] = ["win-0"]; fitDesk.activeIDs[.browser] = "win-0"
            let hugging = (idle: fitDesk.stripFrame(.browser), open: fitDesk.openTabStripMetrics(.browser))
            fitDesk.settings.stripExpansion = .keepWindowButtonsClear
            let fitRig = Rig(fitDesk, .browser)
            let fitRegion = fitDesk.rawLaneFrame(.browser)
            let safeLeft = fitRegion.minX + StripPlacementGeometry.windowButtonsWidth
            guard let fitPill = fitRig.strip.pointer.pillFrame else { preconditionFailure("the fitted strip reports its resting pill") }
            precondition(fitDesk.stripFrame(.browser) == hugging.idle && abs(fitRig.panel.frame.width - hugging.idle.width) < 1.5 && abs(fitPill.width - hugging.idle.width) < 1.5 && abs(fitPill.height - 32) < 1,
                         "Fit to window width leaves the idle pill as it was: \(fitPill) in a window of \(fitRig.panel.frame.size), before \(hugging.idle.size)")
            fitDesk.stripHovered(.browser, true)
            fitRig.settle(0.45)
            let fitBar = fitRig.panel.frame, wantedWidth = fitRegion.maxX - safeLeft
            precondition(abs(fitBar.minX - safeLeft) < 1.5 && abs(fitBar.width - wantedWidth) < 1.5 && fitBar.width > hugging.open.width + 50,
                         "hovering opens the strip across its windows: \(fitBar) for a region \(fitRegion); it was \(hugging.open.width) wide")
            guard let openPill = fitRig.strip.pointer.pillFrame else { preconditionFailure("the open fitted strip reports its pill") }
            precondition(abs(openPill.width - fitBar.width) < 1.5 && abs(openPill.minX) < 1, "the open pill is drawn as wide as the strip (\(openPill))")
            var fitTabs = fitRig.strip.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX }
            let share = (fitBar.width - fitDesk.stripChipRoom(.browser)) / 2
            precondition(fitTabs.count == 2 && fitTabs.allSatisfy { abs($0.value.width - (share - 4)) < 1.5 } && share > WindowStripMetrics.chipLimit(scale: 1),
                         "two tabs share the strip's width, \(Int(share)) points each (\(fitTabs.map { Int($0.value.width) }))")
            precondition(fitTabs[0].value.minX >= fitDesk.stripPillWidth(.browser) - 6 && fitTabs[1].value.maxX <= fitBar.width - WindowStripMetrics.counterWidth(count: 2, scale: 1) + 1 && abs(fitTabs[1].value.maxX + 4 + WindowStripMetrics.counterWidth(count: 2, scale: 1) + 4 - fitBar.width) < 2,
                         "they run from the pill's name to the counter at the far end (\(fitTabs.map { "\(Int($0.value.minX))–\(Int($0.value.maxX))" }) in \(Int(fitBar.width)))")
            fitRig.click(CGPoint(x: fitTabs[1].value.midX, y: fitTabs[1].value.midY))
            precondition(fitDesk.activeIDs[.browser] == fitTabs[1].key, "a click on a fitted tab shows its window")
            fitDesk.stripHovered(.browser, false)
            fitRig.settle(0.7)
            precondition(fitDesk.expandedStrip == nil && abs(fitRig.panel.frame.width - hugging.idle.width) < 1.5 && abs(fitRig.panel.frame.minX - hugging.idle.minX) < 1.5 && abs((fitRig.strip.pointer.pillFrame ?? .zero).width - hugging.idle.width) < 1.5,
                         "when the pointer leaves, it closes back to the same small pill in the same place (\(fitRig.panel.frame), was \(hugging.idle))")
            fitRig.panel.close()
            // More windows than fit: readable tabs, and scrolling the strip brings in the rest.
            let manyDesk = desk("fit-many.json", lane: .terminal, other: .browser, count: 30, bundle: "example.term")
            manyDesk.settings.windowStripStyle = .expanding; manyDesk.settings.stripList = .never; manyDesk.settings.capacities["terminal"] = 1
            manyDesk.visibleSlotIDs[.terminal] = ["win-0"]; manyDesk.activeIDs[.terminal] = "win-0"
            manyDesk.settings.stripExpansion = .edgeToEdge
            manyDesk.stripHovered(.terminal, true)
            let manyRig = Rig(manyDesk, .terminal)
            let manyBar = manyRig.panel.frame
            fitTabs = manyRig.strip.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX }
            let counterStart = manyBar.width - WindowStripMetrics.counterWidth(count: 30, scale: 1) - 4
            precondition(abs(manyBar.width - manyDesk.rawLaneFrame(.terminal).width) < 1.5 && fitTabs.count >= 4 && fitTabs.count < 30 && fitTabs.first?.key == "win-0",
                         "30 windows in a \(Int(manyBar.width))-point strip: \(fitTabs.count) tabs are shown, from the window that shows")
            precondition(fitTabs.allSatisfy { $0.value.width >= WindowStripMetrics.readableTab - 4.5 && $0.value.minX >= 0 && $0.value.maxX <= counterStart + 0.5 }, "each is wide enough to read and sits whole inside the strip (\(fitTabs.map { Int($0.value.width) }))")
            let shownAtFirst = fitTabs.count
            // Real scroll-wheel events, one notch each, a second apart on their own clock.
            var notch: UInt64 = 0
            func scroll(_ lines: Int32) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { preconditionFailure("a scroll event") }
                notch += 1; cg.timestamp = notch * 1_000_000_000
                guard let event = NSEvent(cgEvent: cg) else { preconditionFailure("a scroll event") }
                manyRig.strip.scrollWheel(with: event)
                manyRig.settle(0.06)
            }
            for _ in 0..<12 { scroll(-1) }
            manyRig.settle(0.5)
            let scrolledTo = manyDesk.activeWindow(.terminal)?.id ?? ""
            fitTabs = manyRig.strip.pointer.tabFrames.sorted { $0.value.minX < $1.value.minX }
            precondition(scrolledTo != "win-0" && fitTabs.contains { $0.key == scrolledTo } && !fitTabs.contains { $0.key == "win-0" } && fitTabs.count == shownAtFirst,
                         "scrolling on the strip steps through the windows and the tabs scroll with it: now \(scrolledTo), tabs \(fitTabs.map(\.key))")
            precondition(manyRig.panel.frame == manyBar && fitTabs.allSatisfy { $0.value.width >= WindowStripMetrics.readableTab - 4.5 && $0.value.maxX <= counterStart + 0.5 }, "the strip keeps its place and width while its tabs scroll")
            manyRig.panel.close()
            print("PASS: Fit to window width on a real strip — the idle pill is unchanged, the open bar spans the windows, tabs share it, and extra tabs scroll")

            // 5. Alignment on a real strip. Right: the pill rests on the category's right
            // edge and its bar opens to the left; Left: on the left edge, opening to the right.
            let sideDesk = desk("align.json", lane: .browser, other: .terminal, count: 2, bundle: "example.arc")
            sideDesk.settings.windowStripStyle = .expanding; sideDesk.settings.stripList = .never; sideDesk.settings.capacities["browser"] = 1
            sideDesk.visibleSlotIDs[.browser] = ["win-0"]; sideDesk.activeIDs[.browser] = "win-0"
            let centered = sideDesk.stripFrame(.browser), sideRegion = sideDesk.rawLaneFrame(.browser)
            sideDesk.setStripAlignment(.right)
            let sideRig = Rig(sideDesk, .browser)
            let rightHome = sideRig.panel.frame
            precondition(abs(rightHome.maxX - sideRegion.maxX) < 1.5 && abs(rightHome.width - centered.width) < 1.5 && rightHome.minX > centered.minX + 100, "Right: the pill rests on its category's right edge (\(rightHome), region \(sideRegion), centered it was \(centered))")
            sideDesk.stripHovered(.browser, true)
            sideRig.settle(0.45)
            let rightOpen = sideRig.panel.frame
            precondition(abs(rightOpen.maxX - rightHome.maxX) < 1.5 && rightOpen.minX < rightHome.minX - 100 && rightOpen.minX >= sideRegion.minX, "Right: the bar opens to the left, over its own windows (\(rightOpen), pill \(rightHome))")
            let rightTabs = sideRig.strip.pointer.tabFrames
            precondition(rightTabs.count == 2 && abs((sideRig.strip.pointer.pillFrame ?? .zero).width - rightOpen.width) < 1.5 && rightTabs.values.allSatisfy { $0.minX >= 0 && $0.maxX <= rightOpen.width }, "Right: the open bar draws both tabs inside itself (\(String(describing: sideRig.strip.pointer.pillFrame)))")
            sideDesk.stripHovered(.browser, false)
            sideRig.settle(0.7)
            precondition(abs(sideRig.panel.frame.minX - rightHome.minX) < 1.5 && abs(sideRig.panel.frame.width - rightHome.width) < 1.5, "Right: it closes back onto the right edge (\(sideRig.panel.frame))")
            sideDesk.setStripAlignment(.left)
            sideRig.settle(0.3)
            let leftHome = sideRig.panel.frame
            precondition(abs(leftHome.minX - (sideRegion.minX + StripPlacementGeometry.windowButtons)) < 1.5 && abs(leftHome.width - centered.width) < 1.5, "Left: the pill rests at its category's left edge, just past the window's close, minimize and zoom buttons (\(leftHome))")
            sideDesk.stripHovered(.browser, true)
            sideRig.settle(0.45)
            precondition(abs(sideRig.panel.frame.minX - leftHome.minX) < 1.5 && sideRig.panel.frame.width > leftHome.width + 100, "Left: the bar opens to the right (\(sideRig.panel.frame))")
            sideDesk.stripHovered(.browser, false)
            sideRig.settle(0.7)
            sideDesk.setStripAlignment(.middle)
            sideRig.settle(0.3)
            precondition(abs(sideRig.panel.frame.minX - centered.minX) < 1.5 && abs(sideRig.panel.frame.width - centered.width) < 1.5, "Middle: the pill is back where it always was (\(sideRig.panel.frame), was \(centered))")
            sideRig.panel.close()
            print("PASS: alignment on a real strip — Right rests on the right edge and opens leftward, Left on the left edge opening rightward, Middle as before")

            // 6. Idle opacity on a real strip. Keep strips visible: an idle strip fades to the
            // slider's value on the usual clock, and comes back in full under the pointer.
            let fadeDesk = desk("fade.json", lane: .browser, other: .terminal, count: 4, bundle: "example.arc")
            fadeDesk.settings.windowStripStyle = .expanding; fadeDesk.settings.stripList = .never; fadeDesk.settings.capacities["browser"] = 1
            fadeDesk.visibleSlotIDs[.browser] = ["win-0"]; fadeDesk.activeIDs[.browser] = "win-0"
            fadeDesk.settings.keepStripsVisible = true; fadeDesk.settings.idleStripOpacity = 0.6
            let fadeRig = Rig(fadeDesk, .browser)
            let visibility = fadeRig.strip.visibility
            // How opaque the pill is drawn: the alpha of a point on its surface, left of the dot.
            func drawn() -> Double {
                let view = fadeRig.strip
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = Double(bitmap.pixelsWide) / Double(view.bounds.width)
                return Double(bitmap.colorAt(x: Int(5 * scale), y: Int(Double(view.bounds.height) / 2 * scale))?.alphaComponent ?? -1)
            }
            precondition(visibility.idleDelay == 1.5 && visibility.fadeDuration == 0.3, "the fade keeps its timing: 1.5 seconds idle, then 0.3 seconds")
            precondition(visibility.hovered && visibility.opacity == 1 && visibility.floor == 0.6, "under the pointer the strip is fully shown; its idle floor is the slider's 60% (\(visibility.floor))")
            let full = drawn()
            precondition(full > 0.9, "a hovered strip is drawn in full (\(full))")
            visibility.setHovered(false)
            fadeRig.settle(1.0)
            precondition(visibility.opacity == 1 && abs(drawn() - full) < 0.02, "one second after the pointer leaves it has not started fading")
            fadeRig.settle(1.2)
            var idleAlpha = drawn()
            precondition(visibility.opacity == 0 && abs(idleAlpha / full - 0.6) < 0.04, "then it fades to 60%, not to nothing and not staying at 100% (drawn \(idleAlpha) of \(full))")
            fadeDesk.settings.idleStripOpacity = 0.2
            fadeRig.settle(0.3)
            idleAlpha = drawn()
            precondition(visibility.floor == 0.2 && abs(idleAlpha / full - 0.2) < 0.04, "moving the slider changes an idle strip at once (drawn \(idleAlpha) of \(full))")
            visibility.setHovered(true)
            fadeRig.settle(0.2)
            precondition(visibility.opacity == 1 && abs(drawn() - full) < 0.02, "hovering brings it back to full opacity")
            fadeDesk.stripHovered(.browser, true)
            fadeRig.settle(0.45)
            precondition(fadeDesk.expandedStrip == .browser && fadeRig.panel.frame.width > fadeDesk.stripMetrics(.browser).width + 100 && abs(drawn() - full) < 0.02, "and it expands, fully shown")
            visibility.setHovered(false); fadeDesk.stripHovered(.browser, false)
            fadeRig.settle(0.7)
            precondition(fadeDesk.expandedStrip == nil && abs(fadeRig.panel.frame.width - fadeDesk.stripMetrics(.browser).width) < 1.5, "when the pointer leaves it collapses")
            fadeRig.settle(1.7)
            idleAlpha = drawn()
            precondition(visibility.opacity == 0 && abs(idleAlpha / full - 0.2) < 0.04, "and fades back to the slider's value (drawn \(idleAlpha) of \(full))")
            // Toggle off: the floors from before, whatever the slider says.
            fadeDesk.settings.keepStripsVisible = false
            fadeRig.settle(0.3)
            precondition(visibility.floor == 0.35 && abs(drawn() / full - 0.35) < 0.04, "Keep strips visible off, on the windows: the faint 35% outline, as before (\(visibility.floor))")
            fadeDesk.settings.windowStripStyle = .line
            fadeRig.settle(0.3)
            precondition(visibility.floor == 0.9, "off, a Line: 90%, as before (\(visibility.floor))")
            fadeDesk.settings.windowStripStyle = .expanding; fadeDesk.settings.stripPlacement = .aboveWindows
            fadeRig.settle(0.3)
            precondition(visibility.floor == 0 && drawn() < 0.02, "off, above the windows: it fades out completely, as before (\(visibility.floor))")
            fadeDesk.settings.keepStripsVisible = true; fadeDesk.settings.idleStripOpacity = 1
            fadeRig.settle(0.3)
            precondition(visibility.floor == 1 && abs(drawn() - full) < 0.02, "on at 100%: the strip never fades")
            fadeRig.panel.close()
            print("PASS: Idle opacity on a real strip — idle fades to the slider's value on the same clock, hover is full and expands, leaving collapses and fades back; toggle off is as before")
        }
    }
}

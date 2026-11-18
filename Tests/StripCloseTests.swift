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
    }
}

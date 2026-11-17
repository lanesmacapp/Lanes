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
    }
}

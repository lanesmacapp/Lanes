import AppKit
import SwiftUI

@main struct NativeHoverTests {
    @MainActor static func main() {
        let view = LaneScrollHostingView(rootView: AnyView(Color.clear))
        view.frame = CGRect(x: 0, y: 0, width: 620, height: 56)
        var hovered: [Bool] = []
        view.onHover = { hovered.append($0) }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!
        }
        precondition(view.acceptsFirstMouse(for: nil), "window tabs must accept the first click without activating Lanes")
        view.updateTrackingAreas()
        precondition(view.trackingAreas.contains { $0.options.contains(.activeAlways) && $0.options.contains(.inVisibleRect) }, "hover must work while another app is active")
        precondition(view.trackingAreas.contains { $0.options.contains(.activeAlways) && $0.options.contains(.mouseMoved) }, "the tab under the pointer is tracked while another app is active")
        do {
            // The bar keeps its place on screen when Lanes shifts its window to make room,
            // and moves with the window when you drag the strip.
            let bar = StripBarSize()
            bar.panelDidMove(to: 100)
            bar.go(to: CGSize(width: 190, height: 32), screenX: 100, animate: false, screen: nil)
            precondition(bar.offsetX == 0, "a resting bar sits at its window's left edge")
            bar.panelWillMove(to: 40)
            precondition(abs(bar.offsetX - 60) < 0.01, "when Lanes shifts the window 60 pt left, the bar stays where it was on screen")
            bar.panelDidMove(to: 40)
            precondition(abs(bar.offsetX - 60) < 0.01, "the move Lanes announced does not drag the bar along")
            bar.go(to: CGSize(width: 420, height: 32), screenX: 40, animate: false, screen: nil)
            precondition(bar.offsetX == 0, "the bar arrives at its new place")
            bar.panelDidMove(to: 140)
            precondition(bar.offsetX == 0, "dragging the strip carries the bar with it")
            print("PASS: the strip bar keeps its place while Lanes resizes its window and follows a drag")
            // A list strip's pill stays where the strip rests while its list slides left
            // to stay on screen, and still follows a drag.
            let pill = StripBarSize()
            pill.panelDidMove(to: 100)
            pill.go(to: CGSize(width: 92, height: 32), screenX: 100, restX: 100, animate: false, screen: nil)
            precondition(pill.restOffsetX == 0 && pill.offsetX == 0, "a resting pill sits at its window's left edge")
            pill.panelWillMove(to: 40); pill.panelDidMove(to: 40)
            pill.go(to: CGSize(width: 363, height: 180), screenX: 40, restX: 100, animate: false, screen: nil)
            precondition(pill.offsetX == 0 && abs(pill.restOffsetX - 60) < 0.01, "the list moves 60 pt left to fit the screen; the pill stays where it was")
            pill.panelDidMove(to: 140)
            precondition(pill.offsetX == 0 && abs(pill.restOffsetX - 60) < 0.01, "dragging the strip carries the pill and its list together")
            pill.panelWillMove(to: 200); pill.panelDidMove(to: 200)
            pill.go(to: CGSize(width: 92, height: 32), screenX: 200, restX: 200, animate: false, screen: nil)
            precondition(pill.restOffsetX == 0 && pill.offsetX == 0, "closed again, the pill is the whole strip")
            print("PASS: a list strip's pill stays under the pointer while its list slides to stay on screen")
        }
        do {
            // The × follows the pointer from tab to tab, through the strip's own tracking,
            // and disappears when the pointer leaves the strip.
            let strip = LaneScrollHostingView(rootView: AnyView(Color.clear))
            strip.frame = CGRect(x: 0, y: 0, width: 620, height: 32)
            strip.pointer.tabFrames = ["tab-1": CGRect(x: 100, y: 4, width: 150, height: 24), "tab-2": CGRect(x: 254, y: 4, width: 150, height: 24)]
            func windowPoint(x: CGFloat, topY: CGFloat) -> NSPoint { strip.convert(NSPoint(x: x, y: strip.isFlipped ? topY : strip.bounds.height - topY), to: nil) }
            strip.pointerMoved(windowPoint: windowPoint(x: 120, topY: 16))
            precondition(strip.pointer.hoveredTab == "tab-1", "pointing at a tab shows its ×")
            strip.pointerMoved(windowPoint: windowPoint(x: 300, topY: 16))
            precondition(strip.pointer.hoveredTab == "tab-2", "moving to the next tab moves the ×")
            strip.pointerMoved(windowPoint: windowPoint(x: 20, topY: 16))
            precondition(strip.pointer.hoveredTab == nil, "the strip's name area shows no ×")
            strip.pointerMoved(windowPoint: windowPoint(x: 120, topY: 16))
            strip.mouseExited(with: event(.mouseExited))
            precondition(strip.pointer.hoveredTab == nil, "leaving the strip hides the ×")
            print("PASS: the × follows the tab under the pointer while another app is active")
        }
        let visibility = StripVisibility(idleDelay: 0.02, fadeDuration: 0.02)
        func waitForFade(_ message: String) {
            let deadline = Date(timeIntervalSinceNow: 2)
            while visibility.visible && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            precondition(!visibility.visible, message)
        }
        visibility.start()
        waitForFade("idle bars fade all the way out")
        visibility.setHovered(true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        precondition(visibility.visible, "hover restores the bar and cancels its idle fade")
        visibility.setHovered(false)
        waitForFade("leaving the bar fades it again")
        visibility.start()
        precondition(!visibility.visible, "content refreshes must not reveal idle bars")
        visibility.setHovered(true); visibility.setHovered(false); visibility.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        precondition(visibility.visible, "removed views cancel pending fade callbacks")
        view.mouseEntered(with: event(.mouseEntered))
        view.mouseExited(with: event(.mouseExited))
        precondition(hovered == [true, false], "entering and leaving the category strip must scope its keyboard shortcuts")
        var switched: [Int] = []
        view.onSwitch = { switched.append($0) }
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
        wheel.flags = []; wheel.timestamp = 2_000_000_000
        view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        precondition(switched == [1], "ordinary scrolling in the strip switches without Command")
        // A strip that grows or moves under a still pointer can miss its exit
        // event. The pointer check ends the hover anyway.
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 620, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let watched = LaneScrollHostingView(rootView: AnyView(Color.clear))
        panel.contentView = watched
        var pointer = CGPoint(x: 120, y: 120)
        watched.pointerLocation = { pointer }
        var watchedHover: [Bool] = []
        watched.onHover = { watchedHover.append($0) }
        watched.mouseEntered(with: event(.mouseEntered))
        watched.updateTrackingAreas()
        watched.mouseExited(with: event(.mouseExited))
        watched.mouseEntered(with: event(.mouseEntered))
        precondition(watchedHover == [true], "resize tracking events must not restart a hover while the pointer is still on the strip")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: StripHoverCheck.interval * 2.5))
        precondition(watchedHover == [true] && watched.visibility.hovered, "a pointer still on the strip keeps it hovered")
        pointer = CGPoint(x: 900, y: 120)
        // A busy machine can delay the check; it only has to come.
        let releaseDeadline = Date(timeIntervalSinceNow: 2)
        while watched.visibility.hovered && Date() < releaseDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: StripHoverCheck.interval)) }
        precondition(watchedHover == [true, false] && !watched.visibility.hovered, "a missed exit still releases the strip and its keys")
        pointer = CGPoint(x: 120, y: 120)
        watched.mouseEntered(with: event(.mouseEntered))
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        precondition(watchedHover == [true, false, true, true], "opening a strip context menu keeps its expanded list alive")
        var menuSwitches: [Int] = []
        watched.onSwitch = { menuSwitches.append($0) }
        pointer = CGPoint(x: 900, y: 120)
        watched.mouseExited(with: event(.mouseExited))
        watched.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: StripHoverCheck.interval * 2.5))
        precondition(watched.visibility.hovered && watchedHover.last == true, "moving into and scrolling a context menu must not collapse its strip")
        precondition(menuSwitches.isEmpty, "scrolling a context menu must not switch windows behind it")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        precondition(watchedHover.last == false && !watched.visibility.hovered, "closing the menu releases a strip the pointer has left")
        precondition(!StripHoverCheck.contains(nil, .zero), "a closed strip never counts as hovered")
        precondition(StripHoverCheck.contains(CGRect(x: 0, y: 0, width: 10, height: 10), CGPoint(x: 12, y: 5)), "the edge of a strip still counts as on it")
        if let screen = NSScreen.main {
            let bar = StripBarSize()
            let rest = CGSize(width: 82, height: 32), open = CGSize(width: 440, height: 196)
            bar.go(to: rest, animate: false, screen: screen)
            let start = ProcessInfo.processInfo.systemUptime
            bar.go(to: open, animate: true, screen: screen)
            // If AppKit delays the first frame, the reveal should catch up to elapsed time.
            Thread.sleep(forTimeInterval: 0.18)
            let deadline = Date(timeIntervalSinceNow: 0.12)
            while bar.size != open && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
            precondition(bar.size == open, "a delayed first frame must not restart the hover reveal's clock")
            print("PASS: hover reveal recovered from a \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms simulated stall")
        }
        let verticalPanel = NSPanel(contentRect: NSRect(x: 100, y: 500, width: 440, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        verticalPanel.orderFrontRegardless()
        let animator = StripFrameAnimator()
        animator.move(verticalPanel, to: NSRect(x: 100, y: 336, width: 440, height: 196), animated: true)
        var sawIntermediateHeight = false
        let animationDeadline = Date(timeIntervalSinceNow: 2)
        while verticalPanel.frame.height != 196 && Date() < animationDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            if verticalPanel.frame.height > 32 && verticalPanel.frame.height < 196 { sawIntermediateHeight = true }
        }
        verticalPanel.orderOut(nil)
        precondition(sawIntermediateHeight, "vertical list expansion must animate through intermediate heights instead of jumping")
        precondition(verticalPanel.frame.height == 196, "vertical list expansion must finish at its target height")
        print("PASS: native category-strip first click, active-app-independent tracking, hover enter/exit, full idle transparency, canceled fade, plain wheel switching, release after a missed exit, stable context menus, and animated vertical expansion")
    }
}

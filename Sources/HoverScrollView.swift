import SwiftUI
import AppKit
import Combine
import QuartzCore

// Fade the SwiftUI drawing, not the panel or its native tracking area. The
// transparent strip remains a stable hover target and emits no idle pixels.
final class StripVisibility: ObservableObject {
    @Published private(set) var opacity = 1.0
    // Lowest idle opacity. Strips drawn over windows stay faintly visible.
    @Published private(set) var floor = 0.0
    private var requestedFloor = 0.0
    // Defer changes from SwiftUI layout. Slider events can update the drawing
    // immediately and supersede any earlier floor queued by layout.
    func setFloor(_ value: Double, immediately: Bool = false) {
        if immediately {
            requestedFloor = value
            if floor != value { floor = value }
            return
        }
        guard requestedFloor != value else { return }
        requestedFloor = value
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedFloor == value, self.floor != value else { return }
            self.floor = value
        }
    }
    var visible: Bool { opacity > 0 }
    private var fadeTimer: Timer?
    private var pending: DispatchWorkItem?
    private var started = false
    private(set) var hovered = false
    let idleDelay: TimeInterval
    let fadeDuration: TimeInterval
    init(idleDelay: TimeInterval = 1.5, fadeDuration: TimeInterval = 0.3) { self.idleDelay = idleDelay; self.fadeDuration = fadeDuration }
    func start() {
        guard !started else { return }; started = true
        scheduleFade()
    }
    func setHovered(_ value: Bool) {
        hovered = value; cancel()
        if value { opacity = 1 } else { scheduleFade() }
    }
    func cancel() { pending?.cancel(); pending = nil; stopTween() }
    private func scheduleFade() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            self.tween(to: 0, duration: self.fadeDuration)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }
    // Eased opacity tween, stepped once per display refresh (falls back to a
    // 120 Hz timer for newly created panels with no screen yet).
    private var link: CADisplayLink?
    private var tweenFrom = 1.0, tweenTo = 1.0, tweenStart: CFTimeInterval = 0, tweenDuration: CFTimeInterval = 0
    private func stopTween() { link?.invalidate(); link = nil; fadeTimer?.invalidate(); fadeTimer = nil }
    private func tween(to target: Double, duration: TimeInterval) {
        stopTween()
        guard duration > 0, opacity != target else { opacity = target; return }
        tweenFrom = opacity; tweenTo = target; tweenStart = CACurrentMediaTime(); tweenDuration = duration
        if let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(tweenStep))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            fadeTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tweenStep() }
            RunLoop.main.add(fadeTimer!, forMode: .common)
        }
    }
    @objc private func tweenStep() {
        if tweenTo == 0 && hovered { stopTween(); return }
        let t = min(1, (CACurrentMediaTime() - tweenStart) / tweenDuration)
        // Smootherstep: no visible start or stop kink.
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        opacity = tweenFrom + (tweenTo - tweenFrom) * eased
        if t >= 1 { opacity = tweenTo; stopTween() }
    }
    deinit { pending?.cancel(); link?.invalidate(); fadeTimer?.invalidate() }
}
// macOS can miss the exit event when a strip grows, shrinks or moves under the
// pointer. While hovered, a strip checks where the pointer really is, so a
// missed exit never leaves it shown or its bare number and arrow keys captured.
enum StripHoverCheck {
    static let interval: TimeInterval = 0.15
    static func contains(_ frame: CGRect?, _ pointer: CGPoint) -> Bool {
        guard let frame else { return false }
        return frame.insetBy(dx: -4, dy: -4).contains(pointer)
    }
}
// Animate the reveal inside the panel. The panel only resizes at the endpoints.
final class StripBarSize: ObservableObject {
    static let openDuration: TimeInterval = 0.15
    static let closeDuration: TimeInterval = 0.12
    @Published private(set) var size: CGSize?
    // How far right of its (invisible) window's left edge the bar is drawn. The bar's
    // place is kept in screen terms: when the window resizes or shifts to make room,
    // the bar does not move; it slides on the same curve as its size instead.
    @Published private(set) var offsetX: CGFloat = 0
    private var screenX: CGFloat?, panelX: CGFloat?
    // Where the resting pill sits, in the same terms. A list strip's pill stays there,
    // under the pointer, while its list slides sideways to stay on the screen.
    @Published private(set) var restOffsetX: CGFloat = 0
    private var restScreenX: CGFloat?
    private var fromX: CGFloat = 0, toX: CGFloat = 0
    private var link: CADisplayLink?
    private var from = CGSize.zero, to = CGSize.zero, start: CFTimeInterval = 0
    private var duration = StripBarSize.openDuration
    private var foldingTab = false
    func go(to target: CGSize, screenX targetX: CGFloat? = nil, restX: CGFloat? = nil, animate: Bool, screen: NSScreen?, duration foldDuration: TimeInterval? = nil) {
        if let restX { restScreenX = restX; updateOffset() }
        let x = targetX ?? screenX
        guard let current = size, animate, let screen else {
            stop(); setPresentation(size: target, x: x); return
        }
        let currentX = screenX ?? x ?? 0, goalX = x ?? currentX
        if link != nil && abs(to.width - target.width) < 0.5 && abs(to.height - target.height) < 0.5 && abs(toX - goalX) < 0.5 { return }
        let sameSize = abs(current.width - target.width) < 0.5 && abs(current.height - target.height) < 0.5
        if sameSize && abs(currentX - goalX) < 0.5 {
            stop(); setPresentation(size: target, x: goalX); return
        }
        let growing = target.width > current.width + 0.5 || target.height > current.height + 0.5
        duration = foldDuration ?? (growing ? Self.openDuration : Self.closeDuration)
        foldingTab = foldDuration != nil
        if link != nil { StripTrace.log("bar: RESTARTED mid-animation, now \(Int(current.width))×\(Int(current.height)) → \(Int(target.width))×\(Int(target.height))") }
        else { StripTrace.log("bar: animate \(Int(current.width))×\(Int(current.height)) → \(Int(target.width))×\(Int(target.height)), x \(Int(currentX)) → \(Int(goalX)), \(Int(duration * 1000)) ms") }
        frameTimes = []
        stop()
        from = current; to = target; fromX = currentX; toX = goalX; start = CACurrentMediaTime()
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stop() { link?.invalidate(); link = nil }
    private var frameTimes: [CFTimeInterval] = []
    @objc private func step(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if StripTrace.enabled { frameTimes.append(now) }
        let t = min(1, (now - start) / duration)
        if t >= 1 {
            stop(); setPresentation(size: to, x: toX)
            if StripTrace.enabled {
                let gaps = zip(frameTimes.dropFirst(), frameTimes).map { ($0 - $1) * 1000 }
                StripTrace.log("bar: done in \(Int((now - start) * 1000)) ms, \(frameTimes.count) frames, longest gap \(Int(gaps.max() ?? 0)) ms")
            }
            return
        }
        // Hover responds on the first frame. Tab folds keep the symmetric curve used by the rows.
        let e = foldingTab ? (t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) : 1 - pow(1 - t, 2)
        setPresentation(size: CGSize(width: from.width + (to.width - from.width) * e, height: from.height + (to.height - from.height) * e), x: fromX + (toX - fromX) * e)
    }
    private func setPresentation(size target: CGSize, x: CGFloat?) {
        if size != target { size = target }
        screenX = x
        updateOffset()
    }
    // Lanes is about to resize or shift the strip's window to this left edge: the bar
    // keeps its place on screen (and slides there on its own curve).
    private var expectedPanelX: CGFloat?
    func panelWillMove(to minX: CGFloat) {
        expectedPanelX = minX
        panelX = minX
        if screenX == nil { screenX = minX }
        updateOffset()
    }
    // The window moved. If Lanes announced it, nothing to do; any other move (dragging
    // the strip by its handle) carries the bar along with the window.
    func panelDidMove(to minX: CGFloat) {
        if let expected = expectedPanelX, abs(expected - minX) < 0.5 { expectedPanelX = nil; return }
        expectedPanelX = nil
        guard let old = panelX else { panelX = minX; if screenX == nil { screenX = minX }; updateOffset(); return }
        let delta = minX - old
        panelX = minX
        screenX = screenX.map { $0 + delta }; fromX += delta; toX += delta
        restScreenX = restScreenX.map { $0 + delta }
        updateOffset()
    }
    private func updateOffset() {
        let offset = (screenX ?? panelX ?? 0) - (panelX ?? screenX ?? 0)
        if abs(offset - offsetX) > 0.01 { offsetX = offset }
        let rest = (restScreenX ?? screenX ?? panelX ?? 0) - (panelX ?? restScreenX ?? screenX ?? 0)
        if abs(rest - restOffsetX) > 0.01 { restOffsetX = rest }
    }
    deinit { link?.invalidate() }
}
struct BarSizeModifier: ViewModifier {
    @ObservedObject var barSize: StripBarSize
    let active: Bool
    func body(content: Content) -> some View {
        if active, let size = barSize.size {
            content.frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
struct BarOffsetModifier: ViewModifier {
    @ObservedObject var barSize: StripBarSize
    let active: Bool
    func body(content: Content) -> some View { content.offset(x: active ? barSize.offsetX : 0) }
}
struct FadingStripContent: View {
    @ObservedObject var visibility: StripVisibility
    let content: AnyView
    var body: some View {
        content.opacity(max(visibility.floor, visibility.opacity))
    }
}

// Which tab is under the pointer. SwiftUI's own hover only works while Lanes is the
// active app, and strips float over other apps, so the strip's always-on tracking
// area feeds the pointer here. Tabs report their frames; the hovered tab is
// published only when it changes, so moving the mouse does not redraw the strip.
final class StripPointer: ObservableObject {
    @Published private(set) var hoveredTab: String?
    // Published only on enter and leave, not on every move.
    @Published private(set) var isInside = false
    private var location: CGPoint?
    var tabFrames: [String: CGRect] = [:] { didSet { update() } }
    // Where the pill is drawn, in the same coordinates as the tab frames. A strip
    // resting as a Line has none.
    var pillFrame: CGRect?
    // The part of the strip that drags it: anywhere on the pill except its tabs,
    // which are dragged on their own (to reorder them, or onto another category).
    func onPill(_ point: CGPoint) -> Bool {
        guard let pillFrame, pillFrame.contains(point) else { return false }
        return !tabFrames.values.contains { $0.contains(point) }
    }
    func move(to point: CGPoint?) {
        location = point
        if (point != nil) != isInside { isInside = point != nil }
        update()
    }
    private func update() {
        let id = location.flatMap { point in tabFrames.first { $0.value.contains(point) }?.key }
        if id != hoveredTab { hoveredTab = id }
    }
}
struct StripTabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
struct StripPillFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

// The hand cursors of a strip that can be dragged. Tests turn them off: they drive
// strips in windows nobody sees and must not touch the real pointer.
enum StripCursor {
    static var live = true
    static func hover(_ hand: Bool) { if live { (hand ? NSCursor.openHand : NSCursor.arrow).set() } }
    static func grab() { if live { NSCursor.closedHand.push() } }
    static func release() { if live { NSCursor.pop() } }
}
// Dragging a strip by its pill. A press anywhere on the pill reaches the strip as
// usual, so a click still presses the button under it. Once the pointer has moved
// past the threshold the press becomes a drag: the control under it is let go
// without firing, the strip's window follows the pointer, and the rest of that
// drag, release included, never reaches the strip's controls.
@MainActor final class StripDrag {
    static let threshold: CGFloat = 4
    // Whether a press at this point in the window is on the part that drags the strip.
    var canStart: (NSPoint) -> Bool = { _ in false }
    var onBegin: () -> Void = {}
    // The window's frame where the strip was dropped.
    var onEnd: (NSRect) -> Void = { _ in }
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var press: (mouse: NSPoint, origin: NSPoint)?
    private(set) var dragging = false
    // True when the event is used up here; false when the strip should get it.
    // `deliver` hands an event to the strip's views.
    func handle(_ event: NSEvent, in window: NSWindow, deliver: (NSEvent) -> Void) -> Bool {
        switch event.type {
        case .leftMouseDown:
            if dragging { finish(in: window) }
            // Control-click opens the strip's menu.
            press = !event.modifierFlags.contains(.control) && canStart(event.locationInWindow) ? (pointerLocation(), window.frame.origin) : nil
            return false
        case .leftMouseDragged:
            guard let press else { return false }
            let mouse = pointerLocation()
            if !dragging {
                // A press that has barely moved is still a click.
                guard hypot(mouse.x - press.mouse.x, mouse.y - press.mouse.y) > Self.threshold else { return true }
                dragging = true
                // Let go of the pressed control far outside it: it un-highlights and does not fire.
                if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [], timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: 0, pressure: 0) { deliver(release) }
                StripCursor.grab()
                onBegin()
            }
            window.setFrameOrigin(NSPoint(x: press.origin.x + mouse.x - press.mouse.x, y: press.origin.y + mouse.y - press.mouse.y))
            return true
        case .leftMouseUp:
            guard press != nil else { return false }
            guard dragging else { press = nil; return false }
            let mouse = pointerLocation()
            if let press { window.setFrameOrigin(NSPoint(x: press.origin.x + mouse.x - press.mouse.x, y: press.origin.y + mouse.y - press.mouse.y)) }
            finish(in: window)
            return true
        default: return false
        }
    }
    private func finish(in window: NSWindow) {
        press = nil
        guard dragging else { return }
        dragging = false
        StripCursor.release()
        onEnd(window.frame)
    }
}
// A strip's window: every mouse event passes the strip's drag first.
final class StripPanel: NSPanel {
    var drag: StripDrag?
    override func sendEvent(_ event: NSEvent) {
        if let drag, drag.handle(event, in: self, deliver: { super.sendEvent($0) }) { return }
        super.sendEvent(event)
    }
}

final class LaneScrollHostingView: NSHostingView<AnyView> {
    var onSwitch: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    let visibility = StripVisibility()
    var idleOpacityObservation: AnyCancellable?
    let barSize = StripBarSize()
    let pointer = StripPointer()
    // A point in the window, in SwiftUI's top-left coordinates of this view.
    func pointerMoved(windowPoint: NSPoint) {
        pointer.move(to: stripPoint(windowPoint))
        updateCursor(windowPoint: windowPoint)
    }
    private func stripPoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }
    // Whether strips can be dragged by their pill now (only strips that sit on the windows).
    var canDragStrip: () -> Bool = { false }
    // A press at this point in the window, on the pill, drags the strip.
    func dragsStrip(windowPoint: NSPoint) -> Bool { canDragStrip() && pointer.onPill(stripPoint(windowPoint)) }
    // An open hand wherever a press would drag the strip. While a button is held the
    // cursor belongs to the drag (a closed hand).
    private var showsHand = false
    private func updateCursor(windowPoint: NSPoint) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let hand = dragsStrip(windowPoint: windowPoint)
        if hand || showsHand { StripCursor.hover(hand) }
        showsHand = hand
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(windowPoint: event.locationInWindow) }
    private func trackScreenPointer() {
        guard let window else { return }
        pointerMoved(windowPoint: window.convertPoint(fromScreen: pointerLocation()))
    }
    override func mouseMoved(with event: NSEvent) { pointerMoved(windowPoint: event.locationInWindow) }
    func setStripContent(_ content: AnyView) {
        rootView = AnyView(FadingStripContent(visibility: visibility, content: content))
        visibility.start()
    }
    override var isOpaque: Bool { false }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var hoverCheck: Timer?
    private var hoverTracking: NSTrackingArea?
    private var accumulator = LaneScrollAccumulator()
    private var trackedMenu: ObjectIdentifier?
    private var menuObservers: [NSObjectProtocol] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        watchMenus()
        guard hoverTracking == nil else { return }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) {
        pointerMoved(windowPoint: event.locationInWindow)
        guard !visibility.hovered else { return }
        StripTrace.log("tracking: entered")
        watchMenus(); visibility.setHovered(true); onHover?(true); watchPointer()
        trackScreenPointer()
    }
    override func mouseExited(with event: NSEvent) {
        // Resizing can send an exit for the old tracking rect while the pointer is still inside.
        guard window?.frame.contains(pointerLocation()) != true else { return }
        StripTrace.log("tracking: exited")
        endHover()
    }
    private func endHover() {
        guard trackedMenu == nil else { return }
        hoverCheck?.invalidate(); hoverCheck = nil
        pointer.move(to: nil)
        if showsHand { showsHand = false; StripCursor.hover(false) }
        guard visibility.hovered else { return }
        visibility.setHovered(false); onHover?(false)
    }
    private func watchMenus() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.trackedMenu == nil, let menu = notification.object as? NSMenu,
                      StripHoverCheck.contains(self.window?.frame, self.pointerLocation()) else { return }
                self.trackedMenu = ObjectIdentifier(menu)
                self.visibility.setHovered(true)
                self.onHover?(true)
                self.watchPointer()
            }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu, self.trackedMenu == ObjectIdentifier(menu) else { return }
                self.trackedMenu = nil
                if !StripHoverCheck.contains(self.window?.frame, self.pointerLocation()) { self.endHover() }
            }
        })
    }
    private func watchPointer() {
        hoverCheck?.invalidate()
        hoverCheck = Timer.scheduledTimer(withTimeInterval: StripHoverCheck.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // A held button is a strip drag in progress; the panel follows the pointer.
                guard let self, self.trackedMenu == nil, NSEvent.pressedMouseButtons == 0 else { return }
                if !StripHoverCheck.contains(self.window?.frame, self.pointerLocation()) { self.endHover() }
                // A fallback for a missed mouse-moved event: the × follows the pointer anyway.
                else { self.trackScreenPointer() }
            }
        }
    }
    // Moves the strip's window by other means (dragging the strip) keep the bar in step.
    private var frameObservers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameObservers.forEach(NotificationCenter.default.removeObserver); frameObservers = []
        guard let window else { return }
        barSize.panelDidMove(to: window.frame.minX)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, let window = self.window { self.barSize.panelDidMove(to: window.frame.minX) } }
            })
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow == nil { trackedMenu = nil; hoverCheck?.invalidate(); hoverCheck = nil; visibility.cancel(); pointer.move(to: nil); onHover?(false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func scrollWheel(with event: NSEvent) {
        guard trackedMenu == nil else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if let direction = accumulator.consume(delta: delta, precise: event.hasPreciseScrollingDeltas, time: event.timestamp, momentum: !event.momentumPhase.isEmpty) {
            onSwitch?(direction)
        }
    }
    deinit { menuObservers.forEach(NotificationCenter.default.removeObserver) }
}

// Grows and shrinks Expand-on-hover strips once per display refresh (120 Hz
// and up on fast displays) with an ease-out curve. Other moves are immediate.
@MainActor final class StripFrameAnimator: NSObject {
    private var link: CADisplayLink?
    private weak var panel: NSWindow?
    private var from = NSRect.zero, to = NSRect.zero, start: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.26
    func move(_ panel: NSWindow, to target: NSRect, animated: Bool) {
        if link != nil && to == target { return }
        if link == nil && panel.frame == target { return }
        // Only a size change with the left and top edges fixed is a grow or shrink.
        let resize = abs(panel.frame.minX - target.minX) < 1 && abs(panel.frame.maxY - target.maxY) < 1
        guard animated, resize else { cancel(); panel.setFrame(target, display: true); return }
        cancel()
        self.panel = panel; from = panel.frame; to = target; start = CACurrentMediaTime()
        let link = panel.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func cancel() { link?.invalidate(); link = nil; deferred?.cancel(); deferred = nil; deferredTarget = nil }
    // For strips that animate their own bar: the panel
    // jumps to a bigger size at once and shrinks after the bar has finished.
    private var deferred: DispatchWorkItem?
    private var deferredTarget: NSRect?
    // Told just before the panel moves, so the bar can keep its place on screen.
    var willMove: ((NSRect) -> Void)?
    // Allow time for the reveal to reverse and for the final frame to be drawn.
    static let settleDelay: TimeInterval = 0.25
    func moveDeferred(_ panel: NSWindow, to target: NSRect) {
        let frame = panel.frame
        // AppKit can round the open panel to a backing pixel. Re-entering
        // during a fold cancels the pending shrink even with that rounding.
        let tolerance = 0.5
        if frame.insetBy(dx: -tolerance, dy: -tolerance).contains(target),
           target.insetBy(dx: -tolerance, dy: -tolerance).contains(frame) {
            cancel()
            return
        }
        // A smaller target that fits inside the panel: the bar shows the shrink, and the
        // (invisible) panel catches up once the bar has finished.
        if frame.insetBy(dx: -tolerance, dy: -tolerance).contains(target) {
            if deferredTarget == target { return }
            deferred?.cancel()
            deferredTarget = target
            StripTrace.log("panel: shrink to \(Int(target.width))×\(Int(target.height)) deferred")
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel, let target = self.deferredTarget else { return }
                self.deferred = nil; self.deferredTarget = nil
                self.willMove?(target)
                let t = CACurrentMediaTime()
                panel.setFrame(target, display: false)
                StripTrace.log("panel: shrink applied, x \(Int(target.minX)), \(Int(target.width))×\(Int(target.height)) (\(Int((CACurrentMediaTime() - t) * 1000)) ms)")
            }
            deferred = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
            return
        }
        cancel()
        willMove?(target)
        let t = CACurrentMediaTime()
        panel.setFrame(target, display: false)
        StripTrace.log("panel: now x \(Int(target.minX)), \(Int(target.width))×\(Int(target.height)) (from x \(Int(frame.minX)), \(Int(frame.width))×\(Int(frame.height)); setFrame \(Int((CACurrentMediaTime() - t) * 1000)) ms)")
    }
    @objc private func step(_ link: CADisplayLink) {
        guard let panel else { cancel(); return }
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        let eased = 1 - pow(1 - t, 4)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        panel.setFrame(NSRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width), height: mix(from.height, to.height)), display: true)
        if t >= 1 { cancel() }
    }
}

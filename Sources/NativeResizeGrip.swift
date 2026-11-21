import SwiftUI
import AppKit

enum ResizePhase { case began, changed, ended }

// Native mouse tracking gives each grip its own hit area and resize cursor.
// Window coordinates stay stable even while SwiftUI moves the shared border.
struct NativeResizeGrip: NSViewRepresentable {
    let edge: ResizeEdge
    let onDrag: (CGSize, ResizePhase, Bool) -> Void
    func makeNSView(context: Context) -> ResizeGripView {
        let view = ResizeGripView(); view.edge = edge; view.onDrag = onDrag; return view
    }
    func updateNSView(_ view: ResizeGripView, context: Context) {
        view.edge = edge; view.onDrag = onDrag; view.window?.invalidateCursorRects(for: view)
    }
}
final class ResizeGripView: NSView {
    var edge: ResizeEdge = .right
    var onDrag: ((CGSize, ResizePhase, Bool) -> Void)?
    private var keepNeighbors = false
    private var origin: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        let cursor: NSCursor = edge == .top || edge == .bottom ? .resizeUpDown : edge == .bottomRight ? .crosshair : .resizeLeftRight
        addCursorRect(bounds, cursor: cursor)
    }
    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
        keepNeighbors = event.modifierFlags.contains(.command)
        onDrag?(.zero, .began, keepNeighbors)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        onDrag?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y), .changed, keepNeighbors)
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        onDrag?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y), .ended, keepNeighbors)
        self.origin = nil
    }
}

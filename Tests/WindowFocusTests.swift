import AppKit
import ApplicationServices

// Runs the real WindowManager focus lifecycle against a window-server fixture.
// Its activation deliberately raises Arc's wrong Desktop and Browser windows.
@main struct WindowFocusTests {
    @MainActor static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-focus-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WindowManager(settingsFile: directory.appendingPathComponent("settings.json"), startPolling: false)
        manager.settings.hiddenLanes = Lane.allCases.filter { ![.terminal, .desktop, .browser].contains($0) }.map(\.rawValue)
        manager.settings.showMediaShelf = false
        manager.settings.capacities = ["desktop": 1, "terminal": 1, "browser": 2]
        manager.settings.stripPlacement = .onWindows
        manager.settings.customRects = ["terminal": ZoneRect(CGRect(x: 0, y: 0, width: 0.3, height: 0.5)),
                                       "desktop": ZoneRect(CGRect(x: 0, y: 0.5, width: 0.3, height: 0.5)),
                                       "browser": ZoneRect(CGRect(x: 0.3, y: 0, width: 0.7, height: 1))]
        let desktop = manager.laneFrame(.desktop), terminal = manager.laneFrame(.terminal)
        let panes = Layout.tiles(in: manager.laneFrame(.browser), count: 2, gap: manager.settings.gap, lane: .browser)
        func window(_ id: String, _ pid: pid_t, _ frame: CGRect, _ lane: Lane) -> ManagedWindow {
            ManagedWindow(id: id, element: AXUIElementCreateApplication(0), pid: pid, bundleID: "fixture.\(pid)", appName: pid == 22 ? "Arc" : "Ghostty", title: id, icon: nil, frame: frame, minimized: false, lane: lane)
        }
        let ghostty = window("Desktop Ghostty", 11, desktop, .desktop)
        let arcDesktop = window("Desktop Arc", 22, desktop, .desktop)
        let marketing = window("Marketing page", 22, panes[0], .browser)
        let docs = window("Browser Docs", 22, panes[1], .browser)
        let oldBrowser = window("Previous Browser", 22, panes[0], .browser)
        let oldDocs = window("Previous Docs", 22, panes[1], .browser)
        let shell = window("Terminal", 11, terminal, .terminal)
        let all = [ghostty, arcDesktop, marketing, docs, oldBrowser, oldDocs, shell]
        let numbers = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, UInt32($0 + 1)) })
        var server: [FocusWindowInfo] = []
        var front: pid_t? = 11
        var raised: [String] = [], activated: [String] = [], prepared: [String] = []
        var unknownOnActivation = false
        func raise(_ value: ManagedWindow) {
            let number = numbers[value.id]!
            server.removeAll { $0.number == number }
            server.insert(FocusWindowInfo(number: number, pid: value.pid, frame: value.frame), at: 0)
        }
        manager.focusAccess = WindowFocusAccess(frontPID: { front }, windowID: { numbers[$0.id] }, stack: { server },
            prepare: { prepared.append($0.id) }, raise: { raised.append($0.id); raise($0); return true },
            activate: { value in
                activated.append(value.id); front = value.pid
                if value.pid == 22 {
                    raise(arcDesktop); raise(oldBrowser); raise(oldDocs)
                    if unknownOnActivation { server.insert(FocusWindowInfo(number: 900, pid: 99, frame: desktop), at: 0) }
                }
                return true
            }, unminimize: { _ in preconditionFailure("none of these windows should be minimized") })
        func reset() {
            manager.cancelFocus(); manager.trusted = true; manager.windows = all; manager.input = UserInputClock()
            manager.visibleSlotIDs = [.desktop: [ghostty.id], .terminal: [shell.id], .browser: [marketing.id, docs.id]]
            manager.activeSlot = [.desktop: 0, .terminal: 0, .browser: 0]
            manager.activeIDs = [.desktop: ghostty.id, .terminal: shell.id, .browser: marketing.id]
            server = []
            for value in [arcDesktop, marketing, oldDocs, shell, docs, oldBrowser, ghostty] { raise(value) }
            raised = []; activated = []; prepared = []; front = 11; unknownOnActivation = false
        }
        func top(_ frame: CGRect) -> UInt32? {
            server.first { $0.frame.intersection(frame).width * $0.frame.intersection(frame).height >= frame.width * frame.height * 0.6 }?.number
        }
        func settle(_ seconds: Double = 0.23) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        reset()
        let slots = manager.visibleSlotIDs, frames = manager.windows.map(\.frame)
        manager.focus(marketing)
        precondition(top(desktop) == numbers[ghostty.id], "clicking the marketing page in Browser must not replace Desktop Ghostty with Desktop Arc")
        precondition(top(panes[0]) == numbers[marketing.id] && top(panes[1]) == numbers[docs.id], "both Browser panes retain their intended windows")
        precondition(activated == [marketing.id] && prepared == [marketing.id], "activate the chosen app once and prepare its exact window")
        precondition(Set(raised).isSubset(of: [marketing.id, ghostty.id, docs.id]), "repair only the chosen window and actually covered peers, never flash queue members")
        precondition(manager.visibleSlotIDs == slots && manager.windows.map(\.frame) == frames, "focus changes no peer slots or geometry")
        precondition(manager.rememberWorkingWindow() == marketing.id && manager.activeIDs[.desktop] == ghostty.id, "an activation notification cannot record Arc as Desktop's new selection")
        raise(arcDesktop); raise(oldDocs)
        settle()
        precondition(top(desktop) == numbers[ghostty.id] && top(panes[1]) == numbers[docs.id], "delayed Arc reordering also preserves Desktop and the second Browser pane")
        precondition(top(panes[0]) == numbers[marketing.id], "the requested window retains focus after covered peers are restored")

        reset(); front = 22
        manager.focus(marketing); settle()
        precondition(activated.isEmpty && raised == [marketing.id], "switching within Arc avoids app-wide activation and unnecessary peer raises")
        reset(); manager.focus(marketing); manager.focus(shell)
        let afterNewRequest = raised
        raise(arcDesktop); settle()
        precondition(raised == afterNewRequest, "an old Browser request cannot run after a newer Terminal request")
        precondition(manager.selectedLane == .terminal && manager.activeIDs[.terminal] == shell.id)

        reset(); manager.focus(marketing)
        manager.input.key(modified: false, sourcePID: 0, at: ProcessInfo.processInfo.systemUptime + 0.001)
        let afterKey = raised
        raise(arcDesktop); settle()
        precondition(raised == afterKey, "plain typing cancels pending focus repairs instead of repeatedly stealing focus")
        reset(); manager.focus(marketing)
        manager.input.pointer(held: true, sourcePID: 0, at: ProcessInfo.processInfo.systemUptime + 0.001)
        let afterClick = raised
        raise(arcDesktop); settle()
        precondition(raised == afterClick, "a new mouse click cancels pending repairs")

        // Exercise the event-monitor path without posting to the real desktop.
        for kind: CGEventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            reset(); manager.focus(shell)
            front = 22; raise(marketing) // The agent is now using YouTube in Arc.
            let event: CGEvent
            if kind == .keyDown {
                event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            } else {
                let button: CGMouseButton = kind == .rightMouseDown ? .right : kind == .otherMouseDown ? .center : .left
                event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: panes[0].origin, mouseButton: button)!
            }
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 4242)
            let started = ProcessInfo.processInfo.systemUptime
            manager.noteInput(NSEvent(cgEvent: event)!)
            let afterAgentInput = raised
            // Reproduce later app activation while the old request is pending.
            front = 11; raise(ghostty)
            settle()
            precondition(raised == afterAgentInput, "computer-use \(kind) cancels the old Ghostty focus request")
            precondition(!manager.input.userActive(at: started, buttonDown: true), "computer-use focus input does not authorize rearranging windows")
            if kind != .keyDown {
                precondition(manager.input.clicked(within: 0.75, at: ProcessInfo.processInfo.systemUptime), "synthetic clicks also suppress activation selection restoration")
            }
        }
        reset(); manager.focus(marketing)
        manager.windows.removeAll { $0.id == marketing.id }
        let afterClose = raised
        settle()
        precondition(raised == afterClose, "closed windows cannot be raised by a queued callback")
        reset(); manager.focus(marketing); manager.trusted = false
        let afterRevocation = raised
        settle()
        precondition(raised == afterRevocation, "permission revocation cancels queued window actions")
        reset(); manager.focus(marketing)
        server.insert(FocusWindowInfo(number: 901, pid: 22, frame: panes[0]), at: 0)
        let afterAlert = raised
        settle()
        precondition(raised == afterAlert && top(panes[0]) == 901, "a newly opened Arc dialog is never covered by a delayed focus check")

        reset(); unknownOnActivation = true; manager.focus(marketing)
        precondition(top(desktop) == 900 && !raised.contains(ghostty.id), "a new unknown app or alert in Desktop is never covered by a stale peer restoration")
        manager.cancelFocus()
        reset(); manager.trusted = false
        var reassigned = marketing; reassigned.lane = .desktop
        manager.windows[manager.windows.firstIndex(where: { $0.id == marketing.id })!] = reassigned
        manager.reveal(marketing)
        precondition(manager.selectedLane == .desktop && manager.activeIDs[.desktop] == marketing.id, "a stale Browser button resolves the current window category")
        precondition(raised.isEmpty && activated.isEmpty, "no permission means no native actions")
        manager.windows.removeAll { $0.id == marketing.id }
        let afterStale = manager.visibleSlotIDs
        manager.reveal(marketing)
        precondition(manager.visibleSlotIDs == afterStale, "a closed strip entry cannot insert a phantom slot")

        reset(); manager.trusted = false
        var manual = oldBrowser; manual.frame = panes[1]
        manager.recordWorkingSelection(manual)
        precondition(manager.slotIDs(.browser) == [marketing.id, oldBrowser.id] && manager.activeSlot[.browser] == 1, "manually focusing a background window selects its actual pane and preserves its peer")
        precondition(manager.slotIDs(.desktop) == [ghostty.id] && manager.slotIDs(.terminal) == [shell.id])
        reset(); manager.trusted = false; manager.settings.capacities["browser"] = 4
        manager.visibleSlotIDs[.browser] = [marketing.id, docs.id, oldBrowser.id, oldDocs.id]
        manager.show(marketing, inPane: 2)
        precondition(manager.slotIDs(.browser) == [oldBrowser.id, docs.id, marketing.id, oldDocs.id], "Show in Slot 3 swaps an already-visible window in a four-pane category")
        precondition(manager.activeSlot[.browser] == 2 && manager.activeIDs[.browser] == marketing.id)
        precondition(manager.slotIDs(.desktop) == [ghostty.id] && raised.isEmpty && !manager.canUndo, "an untrusted pane swap neither touches the desktop nor fabricates a Restore snapshot")
        manager.cancelFocus()
        reset()
        manager.settings.capacities["browser"] = 2
        var minimized: [String] = [], closed: [String] = [], restored: [String] = []
        var actionSucceeds = true
        manager.actionAccess = WindowActionAccess(minimize: { minimized.append($0.id); return actionSucceeds },
            restore: { restored.append($0.id); return actionSucceeds },
            close: { closed.append($0.id); return actionSucceeds })
        manager.focus(marketing)
        manager.minimizeWindow(marketing)
        let afterMinimize = raised
        settle()
        precondition(raised == afterMinimize, "minimizing cancels pending focus repairs")
        precondition(minimized == [marketing.id] && manager.windows.first(where: { $0.id == marketing.id })!.minimized)
        precondition(manager.slotIDs(.browser) == [oldBrowser.id, docs.id], "minimizing replaces only that pane, preserving its peer")
        precondition(manager.items(.browser).contains(where: { $0.id == marketing.id }), "minimized windows remain selectable in the strip")
        let minimizedFrame = manager.windows.first(where: { $0.id == marketing.id })!.frame
        _ = manager.apply(.browser, onlyIDs: [marketing.id])
        precondition(manager.windows.first(where: { $0.id == marketing.id })!.minimized && manager.windows.first(where: { $0.id == marketing.id })!.frame == minimizedFrame,
                     "layout updates leave minimized windows untouched")
        actionSucceeds = false
        manager.reveal(marketing)
        precondition(manager.windows.first(where: { $0.id == marketing.id })!.minimized, "failed restore keeps minimized state")
        manager.minimizeWindow(docs)
        precondition(!manager.windows.first(where: { $0.id == docs.id })!.minimized, "failed minimize preserves state")
        manager.closeWindow(docs)
        precondition(manager.windows.contains(where: { $0.id == docs.id }), "failed close preserves the entry")
        actionSucceeds = true
        manager.reveal(marketing)
        precondition(!manager.windows.first(where: { $0.id == marketing.id })!.minimized && restored == [marketing.id, marketing.id], "selecting a minimized tab restores that exact window")
        manager.closeWindow(docs)
        precondition(closed == [docs.id, docs.id] && manager.windows.contains(where: { $0.id == docs.id }), "close waits for actual destruction, allowing a save prompt or cancellation")
        manager.trusted = false
        let calls = minimized.count + closed.count
        manager.closeWindow(marketing); manager.minimizeWindow(marketing)
        precondition(calls == minimized.count + closed.count, "permission is required for window actions")
        manager.trusted = true; manager.windows.removeAll { $0.id == marketing.id }
        manager.closeWindow(marketing); manager.minimizeWindow(marketing)
        precondition(calls == minimized.count + closed.count, "stale menu entries never act on another window")
        manager.cancelFocus()
        print("PASS: window actions — exact targets, minimized layout protection, restore, failures, save prompts, permissions, stale entries")
        print("PASS: actual focus lifecycle — cross-category Arc/Ghostty isolation, two Browser panes, delayed activation, rapid requests, input cancellation, closed windows, revoked permissions, unknown alerts, stale strip entries, and manual selections")
    }
}

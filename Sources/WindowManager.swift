import AppKit

// macOS can refuse a background app's request to bring another app forward
// (it does for Dock apps since macOS 14). Lanes is a menu bar app, so the
// request normally works; if it is ever refused, Lanes falls back to the
// window server call that app switchers use, so strips keep switching apps.
enum FrontProcess {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private static let anywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let setFront: SetFront? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        .flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }.map { unsafeBitCast($0, to: SetFront.self) }
    private static let getWindow: GetWindow? = dlsym(anywhere, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    private static let getPSN: GetPSN? = dlsym(anywhere, "GetProcessForPID").map { unsafeBitCast($0, to: GetPSN.self) }
    static func bring(pid: pid_t, window: AXUIElement) -> Bool {
        guard let setFront, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == 0 else { return false }
        guard let windowID = windowID(window) else { return false }
        return setFront(&psn, windowID, 0x200) == 0
    }
    static func windowID(_ window: AXUIElement) -> UInt32? {
        var windowID: UInt32 = 0
        guard let getWindow, getWindow(window, &windowID) == 0, windowID != 0 else { return nil }
        return windowID
    }
}
import ApplicationServices
import Combine
import ServiceManagement

struct ManagedWindow: Identifiable {
    let id: String
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let icon: NSImage?
    var frame: CGRect
    var minimized: Bool
    var lane: Lane
    var windowNumber: UInt32? = nil
}
struct RunningAppSummary: Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String
    let icon: NSImage?
    let lane: Lane
    var id: pid_t { pid }
}
// Where a window was before Lanes first moved it, for Restore. `pid` and `bundleID`
// say whose window it is, so an app you tell Lanes to leave alone can be taken out.
struct SavedWindow {
    let element: AXUIElement
    let frame: CGRect
    var minimized: Bool
    var pid: pid_t = 0
    var bundleID = ""
    var spaceNumber: Int?
}

struct FocusWindowInfo {
    let number: UInt32
    let pid: pid_t
    let frame: CGRect
}

// Reads Mission Control's desktops, per display, as macOS reports them. Injectable
// so tests can describe any set of desktops. macOS has no public call for this:
// the native reader asks the window server (SkyLight) and only reads.
struct SpacesAccess {
    var read: () -> [[String: Any]]
    var windowSpaces: ((UInt32) -> Set<Int>?)? = nil
    var windowID: (AXUIElement) -> UInt32? = FrontProcess.windowID
    var tracksDesktops = false
    var readWindows: (() -> [[String: Any]]?)? = nil
    static let none = SpacesAccess(read: { [] })
    static var native: SpacesAccess {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(library, "CGSMainConnectionID"), let copy = dlsym(library, "CGSCopyManagedDisplaySpaces") else {
            return SpacesAccess(read: { [] }, tracksDesktops: true)
        }
        let mainConnection = unsafeBitCast(connection, to: Connection.self), displaySpaces = unsafeBitCast(copy, to: Copy.self)
        var access = SpacesAccess(read: { (displaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]) ?? [] },
                                  tracksDesktops: true)
        if let symbol = dlsym(library, "CGSCopySpacesForWindows") ?? dlsym(library, "SLSCopySpacesForWindows") {
            typealias CopyMembership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
            let copyMembership = unsafeBitCast(symbol, to: CopyMembership.self)
            access.readWindows = {
                CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            }
            access.windowSpaces = { window in
                let allSpaceTypes: Int32 = 7
                guard let members = copyMembership(mainConnection(), allSpaceTypes, [NSNumber(value: window)] as CFArray)?
                    .takeRetainedValue() as? [NSNumber], !members.isEmpty else { return nil }
                return Set(members.map(\.intValue))
            }
        }
        return access
    }
}

// Injectable so regression tests can reproduce app activation reordering
// windows without sending input to, or moving, the real desktop.
struct WindowFocusAccess {
    var frontPID: () -> pid_t?
    var windowID: (ManagedWindow) -> UInt32?
    var stack: () -> [FocusWindowInfo]
    var prepare: (ManagedWindow) -> Void
    var raise: (ManagedWindow) -> Bool
    var activate: (ManagedWindow) -> Bool
    var unminimize: (ManagedWindow) -> Void

    static var native: Self {
        Self(frontPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             windowID: { FrontProcess.windowID($0.element) },
             stack: {
                 let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
                 return info.compactMap { item in
                     guard (item[kCGWindowLayer as String] as? Int) == 0,
                           let number = item[kCGWindowNumber as String] as? UInt32,
                           let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                           let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                           let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                     return FocusWindowInfo(number: number, pid: pid, frame: frame)
                 }
             }, prepare: { window in
                 // Activation normally raises an app's main/key windows. Ask
                 // for the exact window first, including apps with many panes.
                 var settable = DarwinBoolean(false)
                 if AXUIElementIsAttributeSettable(window.element, kAXMainAttribute as CFString, &settable) == .success, settable.boolValue {
                     _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                 }
                 let app = AXUIElementCreateApplication(window.pid)
                 AXUIElementSetMessagingTimeout(app, 0.2)
                 if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &settable) == .success, settable.boolValue {
                     _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
                 }
             }, raise: { AXUIElementPerformAction($0.element, kAXRaiseAction as CFString) == .success },
             activate: { window in
                 guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
                 NSApp?.yieldActivation(to: app)
                 return app.activate() || FrontProcess.bring(pid: window.pid, window: window.element)
             }, unminimize: { _ = AXUIElementSetAttributeValue($0.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) })
    }
}

// Window-specific actions never send app-wide keyboard shortcuts.
// Main-thread work that takes a frame or more, written to ~/Library/Logs/Lanes/slow.log,
// so a stutter can be traced to what caused it. Nested entries show where the time went.
enum SlowLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lanes/slow.log")
    static var threshold: TimeInterval = 0.012
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    static func note(_ name: @autoclosure () -> String, since start: TimeInterval) {
        guard StripTrace.enabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed >= threshold else { return }
        let line = "\(stamp.string(from: Date()))  \(String(format: "%5.0f", elapsed * 1000)) ms  \(name())\n"
        StripTrace.log("main thread busy \(Int(elapsed * 1000)) ms: \(name())")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? 0 > 400_000 { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

struct WindowActionAccess {
    var minimize: (ManagedWindow) -> Bool
    var restore: (ManagedWindow) -> Bool
    var close: (ManagedWindow) -> Bool
    static var native: Self {
        Self(minimize: { AXUIElementSetAttributeValue($0.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success },
             restore: { AXUIElementSetAttributeValue($0.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success },
             close: { window in
                 guard let value = axValue(window.element, kAXCloseButtonAttribute),
                       CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
                 let button = value as! AXUIElement
                 guard axBool(button, kAXEnabledAttribute) else { return false }
                 return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
             })
    }
}

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}
// Ardia names every window "Ardia"; the page title is on the web area inside it.
// A shallow search keeps the 2-second poll cheap.
func axWebAreaTitle(_ window: AXUIElement) -> String? {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    while !queue.isEmpty, visited < 250 {
        let (element, depth) = queue.removeFirst(); visited += 1
        if (axValue(element, kAXRoleAttribute) as? String) == "AXWebArea" {
            if let title = axValue(element, kAXTitleAttribute) as? String, !title.isEmpty { return title }
            // A page with no title yet (loading, new tab): show its site instead of "Ardia".
            if let url = axValue(element, kAXURLAttribute) as? URL, let host = url.host, !host.isEmpty { return host.replacingOccurrences(of: "www.", with: "") }
            return "New Tab"
        }
        guard depth < 7, let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        for child in children { queue.append((child, depth + 1)) }
    }
    return nil
}
func axBool(_ element: AXUIElement, _ attribute: String) -> Bool { (axValue(element, attribute) as? Bool) ?? false }
func axButtonEnabled(_ element: AXUIElement, _ attribute: String) -> Bool {
    guard let button = axValue(element, attribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
    return axBool(button as! AXUIElement, kAXEnabledAttribute)
}
// Standard windows answer in one call; only dialogs are looked at more closely.
func axIsWindow(_ element: AXUIElement) -> Bool {
    let subrole = axValue(element, kAXSubroleAttribute) as? String
    if subrole == kAXStandardWindowSubrole { return true }
    guard subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole else { return false }
    var resizable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
    return Classifier.isWindow(subrole: subrole, modal: axBool(element, kAXModalAttribute), minimizable: axButtonEnabled(element, kAXMinimizeButtonAttribute),
                               zoomable: axButtonEnabled(element, kAXZoomButtonAttribute), resizable: resizable.boolValue)
}
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = axValue(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

// Text widths for a strip's pill (name, count, pane labels), measured once per
// string and size. Whole points, rounded up, so the pill never clips its text.
enum StripText {
    private static var cache: [String: Double] = [:]
    private static let lock = NSLock()
    static func width(_ text: String, size: Double, weight: NSFont.Weight, digits: Bool = false) -> Double {
        let key = "\(text)\u{1F}\(size)\u{1F}\(weight.rawValue)\u{1F}\(digits)"
        lock.lock(); defer { lock.unlock() }
        if let known = cache[key] { return known }
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let width = (NSAttributedString(string: text, attributes: [.font: font]).size().width).rounded(.up)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = width
        return width
    }
}

@MainActor final class WindowManager: ObservableObject {
    @Published var settings: Settings
    @Published var windows: [ManagedWindow] = []
    @Published var runningApps: [RunningAppSummary] = []
    @Published var selectedLane: Lane = .terminal
    @Published var gridSelectionActive = false
    @Published var renameTarget: Lane?
    @Published var renameWindowID: String?
    @Published var visibleSlotIDs: [Lane: [String]] = [:]
    @Published var activeSlot: [Lane: Int] = [:]
    @Published var showAccessHelp = false
    // An Expand-on-hover strip currently shown at its detailed size.
    @Published var expandedStrip: Lane?
    private var collapseStrip: DispatchWorkItem?
    var hoveredLane: Lane? { didSet { if hoveredLane != oldValue { onHoveredLaneChanged?() } } }
    @Published var pages: [Lane: Int] = [:]
    @Published var trusted = AXIsProcessTrusted() {
        didSet {
            guard oldValue != trusted else { return }
            if trusted, tourSteps.first?.spot == .permission, let tourStep {
                tourSteps = TourGuide.steps(trusted: true, openShortcut: settings.openShortcut)
                self.tourStep = max(0, tourStep - 1)
            }
            onTrustChanged?()
        }
    }
    @Published var status = "Your desktop, with a place for everything."
    @Published var screens: [NSScreen] = NSScreen.screens
    @Published var selectedTemplateChanged = false
    @Published var busy = false
    @Published var layoutHistory: [Settings] = []
    @Published var editorPreview: [String: ZoneRect]?
    // The grid in the Lanes window is a draft: edits there change nothing on the
    // screen until Apply. `grid` is what the editor shows; `settings` is what the
    // screen uses. While a draft edit runs, window moves, strip updates and saving
    // are switched off.
    @Published var gridDraft: Settings? { didSet { if gridDraft == nil { gridDraftBase = nil } } }
    // The applied settings the draft was last edited from. Apply writes only what
    // the draft changed since then, so nothing that happened on the screen in the
    // meantime (a window moved to another category, a rename) is undone.
    private var gridDraftBase: Settings?
    // The draft as Apply would write it: the settings in use now plus the draft's own changes.
    private var editorBase: Settings {
        if !editingDraft, viewingOtherDesktop, let shownDesktop { return settingsShowing(shownDesktop) }
        return settings
    }
    var pendingGrid: Settings? {
        guard let gridDraft else { return nil }
        let base = editorBase
        return base.applyingDraft(gridDraft, since: gridDraftBase ?? base)
    }
    private var editingDraft = false
    var grid: Settings { editingDraft ? settings : gridDraft ?? editorBase }
    var editorPreviousLayout: SavedGridLayout? { editorBase.previousLayout }
    private struct DesktopDraft {
        var grid: Settings?
        var base: Settings?
        var preset: PresetPreview?
        var history: [Settings] = []
    }
    private var desktopDrafts: [String: DesktopDraft] = [:]
    // Mission Control's desktops on the selected display, in its order. The grid on
    // the screen is always the one of the desktop you are on (`activeDesktop`); the
    // grid editor can show another desktop's (`shownDesktop`), as a draft that Apply
    // saves for that desktop without touching this one.
    var spacesAccess: SpacesAccess
    @Published private(set) var desktops: [DesktopSpace] = []
    @Published private(set) var activeDesktop: String?
    // Desktops organized since the last Restore. Strips show only on these, so a
    // desktop you never organized (or one with private windows) stays untouched.
    @Published private(set) var organizedDesktops: Set<String> = []
    // Strips belong on the desktop you are on: always without desktop info, or once it was organized.
    var stripsBelongHere: Bool {
        desktopAvailable && (desktops.isEmpty || desktopArrangementKey.map(organizedDesktops.contains) == true)
    }
    private var desktopArrangementKey: String? {
        guard let display = settings.activeDisplayKey, let desktop = activeDesktop else { return nil }
        return Settings.spaceLayoutKey(display: display, space: desktop)
    }
    @Published private var desktopAvailable = true
    private var currentSpaceNumber: Int?
    private var desktopGeneration = 0
    private typealias DesktopSelection = (slots: [Lane: [String]], active: [Lane: String], pane: [Lane: Int], pages: [Lane: Int])
    private var desktopSelections: [String: DesktopSelection] = [:]
    @Published private var desktopInventory: [String: [ManagedWindow]] = [:]
    private var desktopManagedNumbers: [String: Int] = [:]
    @Published private var pendingDesktopReads: Set<String> = []
    @Published private(set) var shownDesktop: String?
    var viewingOtherDesktop: Bool { shownDesktop != nil && activeDesktop != nil && shownDesktop != activeDesktop }
    // Whether the editor holds changes that Apply would save.
    var hasGridEdits: Bool { gridDraft != nil }
    func hasUnappliedChanges(on desktop: String) -> Bool {
        if shownDesktop == desktop { return hasGridEdits || presetPreview != nil }
        guard let display = settings.activeDisplayKey,
              let draft = desktopDrafts[Settings.spaceLayoutKey(display: display, space: desktop)] else { return false }
        return draft.grid != nil || draft.preset != nil
    }
    var gridLanes: [Lane] { grid.enabledLanes }
    // Floating categories sit over the grid; the rest tile it.
    func isFloating(_ lane: Lane) -> Bool { grid.isFloating(lane) }
    var baseGridLanes: [Lane] { grid.enabledLanes.filter { !grid.isFloating($0) } }
    // Grid categories first, floating ones last: drawn and raised on top.
    var stackedGridLanes: [Lane] { baseGridLanes + grid.enabledLanes.filter { grid.isFloating($0) } }
    var floatingKeys: Set<String> { Set(grid.floatingLanes) }
    func baseRects() -> [String: ZoneRect] { layoutRects().filter { !floatingKeys.contains($0.key) } }
    func floatingRects() -> [String: ZoneRect] { layoutRects().filter { floatingKeys.contains($0.key) } }
    private enum RestoreScope: Hashable {
        case desktop(String)
        case display(String?)
    }
    private var restoreScope: RestoreScope? {
        guard desktopAvailable else { return nil }
        return desktopArrangementKey.map(RestoreScope.desktop) ?? .display(settings.activeDisplayKey)
    }
    @Published private var restoreSnapshots: [RestoreScope: [String: SavedWindow]] = [:]
    private var restoredScopes: Set<RestoreScope> = []
    var snapshot: [String: SavedWindow] { restoreScope.flatMap { restoreSnapshots[$0] } ?? [:] }
    var canUndo: Bool { !snapshot.isEmpty }
    var canRestoreHere: Bool { trusted && !busy && canUndo && (desktopArrangementKey != nil || !spacesAccess.tracksDesktops) }
    var canRestoreFromBoard: Bool { canRestoreHere && !viewingOtherDesktop }
    private subscript(saved id: String) -> SavedWindow? {
        get { restoreScope.flatMap { restoreSnapshots[$0]?[id] } }
        set {
            guard let scope = restoreScope, let newValue else { return }
            restoreSnapshots[scope, default: [:]][id] = newValue
        }
    }
    private var overrides: [String: Lane] = [:]
    @Published var activeIDs: [Lane: String] = [:]
    private var managedByScope: [RestoreScope: Set<String>] = [:]
    private var managedIDs: Set<String> {
        get { restoreScope.flatMap { managedByScope[$0] } ?? [] }
        set { if let scope = restoreScope { managedByScope[scope] = newValue } }
    }
    // Layout guard: your hardware input, Lanes' own recent moves, windows waiting
    // to be put back, and windows you moved yourself since the last check.
    var input = UserInputClock()
    private var lanesMovedAt: [CFHashCode: Double] = [:]
    private var lanesMovedFrames: [CFHashCode: CGRect] = [:]
    private var guardPending: [String: DispatchWorkItem] = [:]
    private var guardPausedUntil = 0.0
    private var focusConfirm: DispatchWorkItem?
    var focusAccess = WindowFocusAccess.native
    var actionAccess = WindowActionAccess.native
    private var focusGeneration = 0
    private var pendingFocus: (id: String, since: Double)?
    private(set) var userMoved: Set<String> = []
    private(set) var putBackCount = 0
    // The strip being dragged keeps its panel frame until the drag ends.
    var draggingStrip: Lane?
    // From the last refresh: windows in each app's own (front-to-back) order,
    // and the window server's on-screen stack, front first.
    private var discoveryOrder: [SeenWindow] = []
    // Windows whose category is shelved or hidden. Lanes neither lists nor tiles them.
    private(set) var outsideGrid: [ManagedWindow] = []
    // Windows you placed yourself. Lanes never second-guesses them from where they sit.
    var userPlaced: Set<String> { Set(settings.placedWindows) }
    func markPlaced(_ id: String) {
        guard !settings.placedWindows.contains(id) else { return }
        settings.placedWindows.append(id)
        if settings.placedWindows.count > 400 { settings.placedWindows.removeFirst(settings.placedWindows.count - 400) }
    }
    private var onScreenStack: [(pid: Int32, frame: CGRect)] = []
    private var onScreenNumbers: [UInt32: Int] = [:]
    private var timer: Timer?
    // One window-created watcher per running app, for centering new windows.
    private var windowWatchers: [pid_t: AXObserver] = [:]
    private var lastSignature = ""
    private var stripSignature = ""
    private var tick = 0
    private var lastRecordedTrust: Bool?
    private var observedMinimumSizes: [Lane: CGSize] = [:]
    private(set) var hiddenAppSnapshot: [pid_t: Bool] = [:]
    private var lastWorkingPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    var onGridSelection: (() -> Void)?
    var onHoveredLaneChanged: (() -> Void)?
    var onTrustChanged: (() -> Void)?
    var onLaneControls: (() -> Void)?
    var onStripResized: (([Lane]) -> Void)?
    var onStripAppearanceChanged: (() -> Void)?
    var onHideLaneControls: (() -> Void)?
    // The Open Lanes shortcut. The app registers the new one with macOS and answers
    // false when macOS refuses it; the old one then keeps working.
    var onOpenShortcut: ((KeyShortcut) -> Bool)?
    var onSetDockVisibility: ((Bool) -> Bool)?
    // Preferences is recording a new shortcut: Lanes' own chords are input for it,
    // not commands, until it ends.
    var recordingShortcut = false
    var onShortcutRecorded: ((KeyShortcut) -> Void)?
    var onSwitcher: (() -> Void)?
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?
    // The Lanes window never closes by itself. An action started in it keeps it in
    // front once windows are arranged; from a shortcut elsewhere, focus returns to
    // the window you were working in.
    var isBoardVisible: (() -> Bool)?
    var onKeepBoard: (() -> Void)?
    var startedInBoard: Bool { NSApp?.isActive == true && (isBoardVisible?() ?? false) }
    var onOverlay: (([(Lane, CGRect)]) -> Void)?
    // A strip tab being dragged. While it is set, every other category shows
    // a drop zone, so a window can change category without opening Lanes.
    private(set) var draggedTab: String?
    var onTabDrag: ((String?) -> Void)?
    private let settingsURL: URL

    init(settingsFile: URL? = nil, startPolling: Bool = true) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lanes")
        settingsURL = settingsFile ?? folder.appendingPathComponent("settings.json")
        // A new install starts from the recommended setup; test fixtures start from plain defaults.
        let saved = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        settings = saved ?? (settingsFile == nil ? .firstRun : Settings())
        let freshInstall = saved == nil && settingsFile == nil
        // Test fixtures read no desktops unless they are given some.
        spacesAccess = startPolling ? .native : .none
        overrides = settings.windowCategories.compactMapValues(Lane.init(rawValue:))
        if startPolling {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.desktopChanged() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let restore = app.flatMap { self.selectionsToRestore(for: $0) } ?? [:]
                // Read the previous app's exact focused window when Lanes takes
                // focus, even if the user switched windows within that app.
                if let app, app.processIdentifier != getpid() { self.lastWorkingPID = app.processIdentifier }
                self.rememberWorkingWindow()
                if let app, !restore.isEmpty { self.restoreSelection(restore, after: app) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.guardPausedUntil = ProcessInfo.processInfo.systemUptime + 5
                // macOS sends this often (not only when a display is plugged in): re-read in the
                // background, so it never freezes a strip for a quarter of a second.
                self?.screens = NSScreen.screens; self?.syncDisplayLayout(); self?.refreshInBackground()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.regularAppsCache = nil; self?.appLaunched(app) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.regularAppsCache = nil; self?.unwatch(app.processIdentifier) }
        }
        }
        if !enabledLanes.contains(selectedLane), let first = enabledLanes.first { selectedLane = first }
        if startPolling { syncDisplayLayout(fresh: freshInstall); refresh(); rememberWorkingWindow(); updateNewWindowWatch() }
        else { refresh() }
    }
    // New windows are handled the moment macOS reports them: put in their app's
    // category or centered, or, when they open over a category's window, counted
    // in that category. Moves and resizes are reported too, for the layout guard.
    func updateNewWindowWatch() {
        guard trusted else { for pid in Array(windowWatchers.keys) { unwatch(pid) }; return }
        for app in regularRunningApps() where windowWatchers[app.processIdentifier] == nil { watch(app.processIdentifier) }
    }
    private func watch(_ pid: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let manager = Unmanaged<WindowManager>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                if name == kAXWindowCreatedNotification { manager.windowCreated(element) }
                else if name == kAXUIElementDestroyedNotification { manager.windowClosed() }
                else { manager.windowChanged(element) }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid), context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, context) == .success else { return }
        _ = AXObserverAddNotification(observer, app, kAXWindowMovedNotification as CFString, context)
        _ = AXObserverAddNotification(observer, app, kAXWindowResizedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        windowWatchers[pid] = observer
    }
    private func unwatch(_ pid: pid_t) {
        closeWatched = closeWatched.filter { !$0.hasPrefix("\(pid)-") }
        guard let observer = windowWatchers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        if trusted && (windows + outsideGrid).contains(where: { $0.pid == pid }) { windowClosed() }
    }
    // macOS reports a closed window only to an observer of that window, so each
    // window Lanes knows is watched once. A close updates its strip at once
    // instead of at the next 10-second check.
    private var closeWatched: Set<String> = []
    private func watchClosing(_ known: [ManagedWindow]) {
        let open = Set(known.map(\.id))
        closeWatched = closeWatched.intersection(open)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for window in known where !closeWatched.contains(window.id) {
            guard let observer = windowWatchers[window.pid] else { continue }
            let result = AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, context)
            if result == .success || result == .notificationAlreadyRegistered { closeWatched.insert(window.id) }
        }
    }
    private var closeRefresh: DispatchWorkItem?
    // Closing from a strip: the tab folds away at once while the app is asked in the
    // background, and heavy window reads wait until the strip has stopped moving, so
    // nothing on the main thread interrupts the animation.
    @Published private(set) var closingWindowIDs: Set<String> = []
    private var closingSince: [String: TimeInterval] = [:]
    private(set) var stripMotionUntil: TimeInterval = 0
    var stripInMotion: Bool { ProcessInfo.processInfo.systemUptime < stripMotionUntil }
    static let stripCloseDuration: TimeInterval = 0.22
    private var closeRefreshDueBy: TimeInterval?
    func windowClosed() {
        closeRefresh?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        // Waiting for the strip to stop moving, but never more than a second: closing fast
        // must not leave a closed window in the list.
        if closeRefreshDueBy == nil { closeRefreshDueBy = now + 1.0 }
        let due = closeRefreshDueBy ?? now
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.busy, !self.editingDraft else { self?.closeRefreshDueBy = nil; return }
                // Another close extended the animation: wait for that one too, up to the deadline.
                if self.stripInMotion && ProcessInfo.processInfo.systemUptime < due { self.windowClosed(); return }
                self.closeRefreshDueBy = nil
                self.refreshInBackground { [weak self] in self?.syncStrips() }
            }
        }
        closeRefresh = work
        // A few windows closing together (a whole app's) update once, after any strip animation.
        let wait = max(0.05, min(stripMotionUntil - now + 0.02, due - now))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }
    // The × on a strip tab. The press goes to the app off the main thread, because an
    // app can take a while to answer and the fold animation must not wait for it.
    func closeFromStrip(_ requested: ManagedWindow) {
        guard !editingDraft, trusted else { status = "Enable window control to close windows."; return }
        guard let window = (windows + outsideGrid).first(where: { $0.id == requested.id }) else {
            status = "That window is no longer available."; return
        }
        let now = ProcessInfo.processInfo.systemUptime
        pinStrip(window.lane)
        stripMotionUntil = max(stripMotionUntil, now + Self.stripCloseDuration + 0.25)
        closingSince[window.id] = now
        closingWindowIDs.insert(window.id)
        StripTrace.log("close requested: \(window.appName) \"\(window.title.prefix(30))\" (\(window.id))")
        cancelFocus()
        let close = actionAccess.close
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let closed = close(window)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishStripClose(window, closed: closed) } }
        }
    }
    private func finishStripClose(_ window: ManagedWindow, closed: Bool) {
        StripTrace.log("close answered: \(window.appName) \"\(window.title.prefix(30))\" → \(closed ? "pressed its close button" : "could not press close")")
        guard closed else {
            // Pressing close on a window that is already gone (closed by its app, or by this
            // very press) reports a failure. Then the tab stays closed and the list is re-read
            // now; only a window that is really still open gets its tab back.
            let element = window.element
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                AXUIElementSetMessagingTimeout(element, 0.3)
                var role: CFTypeRef?
                let gone = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .invalidUIElement
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        StripTrace.log("close failed: \(window.appName) \"\(window.title.prefix(30))\" — the window \(gone ? "is already gone, tab stays closed" : "is still open, tab comes back")")
                        if gone { self.refreshInBackground { [weak self] in self?.syncStrips() } }
                        else { self.endClosing(window.id); self.status = "\(window.appName) could not close this window." }
                    }
                }
            }
            return
        }
        guardPending.removeValue(forKey: window.id)?.cancel()
        status = "Asked \(window.appName) to close \(windowLabel(window))."
        windowClosed()
        // A window still open 8 s after its close (the app said no, quietly) gets its tab back.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeGiveUp + 0.2) { [weak self] in MainActor.assumeIsolated { self?.windowClosed() } }
        // Ghostty (with something running), editors with unsaved work and others ask before
        // closing. That question sits on the window, which may be hidden behind its tile's
        // other windows: bring it forward right away and keep its tab, instead of folding
        // the tab and bringing it back two seconds later.
        let element = window.element
        for delay in [0.3, 1.0] { DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            AXUIElementSetMessagingTimeout(element, 0.3)
            let children = (axValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let asking = children.contains { (axValue($0, kAXRoleAttribute) as? String) == "AXSheet" }
            guard asking else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.closingWindowIDs.contains(window.id), self.windows.contains(where: { $0.id == window.id }) else { return }
                    StripTrace.log("close asked a question: \(window.appName) \"\(window.title.prefix(30))\" — tab kept, window brought forward")
                    self.endClosing(window.id)
                    self.reveal(window)
                    self.status = "\(window.appName) asks before closing \(self.windowLabel(window))."
                }
            }
        } }
    }
    func endClosing(_ id: String) { closingSince[id] = nil; closingWindowIDs.remove(id) }
    // How long a folded tab waits for its window to close before coming back. Slow apps
    // (Ghostty ending a shell) take a moment; a question is caught right away instead.
    static let closeGiveUp: TimeInterval = 8
    // After a re-read: closed windows are gone; a window still open 8 s after its close
    // request gets its tab back.
    private func settleClosing() {
        guard !closingWindowIDs.isEmpty else { return }
        let open = Set((windows + outsideGrid).map(\.id)), now = ProcessInfo.processInfo.systemUptime
        for id in closingWindowIDs where !open.contains(id) || now - (closingSince[id] ?? 0) > Self.closeGiveUp {
            if open.contains(id) { StripTrace.log("TAB CAME BACK: \(windows.first { $0.id == id }.map { "\($0.appName) \"\($0.title.prefix(30))\"" } ?? id) is still open \(String(format: "%.1f", now - (closingSince[id] ?? 0))) s after its close") }
            else { StripTrace.log("closed for real: \(id)") }
            endClosing(id)
        }
    }
    // Strip sizes leave out tabs that are folding away, so the bar shrinks with them.
    func stripCount(_ lane: Lane) -> Int { stripItems(lane).count }
    // A freshly launched app may open its first window before it can be watched.
    private func appLaunched(_ app: NSRunningApplication) {
        guard trusted, app.activationPolicy == .regular, app.processIdentifier != getpid() else { return }
        watch(app.processIdentifier)
        guard settings.newWindowPlacement != .category else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self != nil else { return }
            // A just-launched app is busy: ask it for its windows off the main thread.
            Self.discoveryQueue.async { [weak self] in
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(appElement, 0.3)
                guard let elements = axValue(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { for element in elements { self?.handleNewWindow(element) } } }
            }
        }
    }
    func windowCreated(_ element: AXUIElement) {
        // A new dialog/window is a newer foreground intention, not something
        // a delayed confirmation of the previous selection should cover.
        cancelFocus()
        newWindowAnnounced[CFHash(element)] = ProcessInfo.processInfo.systemUptime
        // Let the app finish positioning its window first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.handleNewWindow(element) }
    }
    private var centeredWindows: Set<String> = []
    private var newWindowAnnounced: [CFHashCode: TimeInterval] = [:]
    // New windows are looked at on their own queue, so one never waits behind a full re-read.
    private static let newWindowQueue = DispatchQueue(label: "lanes.new-window", qos: .userInteractive)
    // Only the new window is asked about (not every window of every app), off the main
    // thread, since its app is often still busy making it.
    private func handleNewWindow(_ element: AXUIElement, attempt: Int = 0) {
        guard trusted, settings.newWindowPlacement != .category, attempt > 0 || NSEvent.pressedMouseButtons == 0 else {
            StripTrace.log("new window: not handled (placement \(settings.newWindowPlacement.rawValue), mouse \(NSEvent.pressedMouseButtons))"); return
        }
        let ignored = settings.ignoredApps
        Self.newWindowQueue.async { [weak self] in
            AXUIElementSetMessagingTimeout(element, 0.3)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
                  !ignored.contains(app.bundleIdentifier ?? "pid.\(pid)") else { return }
            let title = (axValue(element, kAXTitleAttribute) as? String) ?? ""
            let player = Classifier.isCompactPlayer(title: title)
            guard axIsWindow(element) || player, !axBool(element, "AXFullScreen"), !axBool(element, kAXMinimizedAttribute),
                  let frame = axFrame(element), frame.width > 80, frame.height > 60 else { return }
            let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            // Drawn yet? Phi and other Chromium browsers show a new window only once its first page loads.
            let number = FrontProcess.windowID(element)
            let shown = all.contains { item in
                guard (item[kCGWindowOwnerPID as String] as? Int) == Int(pid), (item[kCGWindowIsOnscreen as String] as? Bool) == true else { return false }
                if let number { return (item[kCGWindowNumber as String] as? UInt32) == number }
                guard let b = item[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return false }
                return TabSwitch.sameSpot(CGRect(x: x, y: y, width: w, height: h), frame)
            }
            // A new tab opens in its tab group's spot, beside the tab it hides.
            // Moving it would drag the whole group, so tabs stay where they are.
            let sameSpot = all.filter { item in
                guard (item[kCGWindowOwnerPID as String] as? Int) == Int(pid), (item[kCGWindowLayer as String] as? Int) == 0,
                      let b = item[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return false }
                return TabSwitch.sameSpot(CGRect(x: x, y: y, width: w, height: h), frame)
            }.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.placeNewWindow(element, app: app, frame: frame, title: title, player: player, shown: shown, sameSpot: sameSpot, attempt: attempt) }
            }
        }
    }
    private func placeNewWindow(_ element: AXUIElement, app: NSRunningApplication, frame: CGRect, title: String, player: Bool, shown: Bool, sameSpot: Int, attempt: Int) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("new window: place it (main thread)", since: started) }
        let pid = app.processIdentifier, appName = app.localizedName ?? "?"
        syncDesktops()
        guard trusted, desktopAvailable, !editingDraft else { return }
        guard windowCanMoveHere(element) else { return }
        guard attempt > 0 || centeredWindows.insert("\(pid)-\(CFHash(element))").inserted else { StripTrace.log("new window from \(appName): skipped (seen before)"); return }
        // Not on screen yet: a quick look at this one window again in 0.15 s, for up to 6 s.
        if !shown {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.handleNewWindow(element, attempt: attempt + 1) } }
            else { StripTrace.log("new window from \(appName): still not on screen after 6 s"); newWindowAnnounced[CFHash(element)] = nil; refreshInBackground() }
            return
        }
        let announced = newWindowAnnounced.removeValue(forKey: CFHash(element))
        guard let window = addNewWindow(element, app: app, frame: frame, title: title) else { return }
        StripTrace.log("new window from \(appName): in \(name(window.lane))\(windows.contains { $0.id == window.id } ? "" : " (outside the grid)") \(announced.map { "\(Int((started - $0) * 1000)) ms after macOS announced it" } ?? ""), checks: \(attempt + 1)")
        // The rest of the window list catches up in the background.
        refreshInBackground()
        guard !player else { syncStrips(); return }
        // Arc, Ghostty and others open a new window exactly over the current one:
        // it stays there and joins that window's category. Otherwise Center
        // mode puts it in its app's category (WhatsApp in Messaging), or in the
        // middle when the app has none in the grid.
        if sameSpot < 2 && settings.newWindowPlacement == .center {
            if placeInCategory(element, pid: pid, title: title) { return }
            let target = NewWindowCenter.frame(for: frame.size, in: screenFrame, gap: settings.gap)
            if !TabSwitch.sameSpot(target, frame) {
                move(element, to: target)
                if let i = windows.firstIndex(where: { CFEqual($0.element, element) }) { windows[i].frame = target }
                if let i = outsideGrid.firstIndex(where: { CFEqual($0.element, element) }) { outsideGrid[i].frame = target }
            }
            // Its tab appears now rather than at the next poll.
            syncStrips()
            return
        }
        followLayout(including: [window.id])
    }
    // One new window joins the list right away, sorted into its category like a full read would.
    private func addNewWindow(_ element: AXUIElement, app: NSRunningApplication, frame: CGRect, title: String) -> ManagedWindow? {
        let id = "\(app.processIdentifier)-\(CFHash(element))"
        if let existing = (windows + outsideGrid).first(where: { $0.id == id }) { return existing }
        if settings.onlyTargetScreen && !managedIDs.contains(id) && !onTargetDisplay(frame) { return nil }
        let bundle = app.bundleIdentifier ?? "pid.\(app.processIdentifier)", appName = app.localizedName ?? "App"
        let shownTitle = title.isEmpty ? appName : title
        let number = FrontProcess.windowID(element)
        if adoptDesktopPreviewAssignment(pid: app.processIdentifier, number: number, id: id) { save() }
        let lane = category(for: id, bundle: bundle, appName: appName, title: shownTitle)
        let window = ManagedWindow(id: id, element: element, pid: app.processIdentifier, bundleID: bundle, appName: appName,
                                   title: shownTitle, icon: app.icon, frame: frame, minimized: false, lane: lane, windowNumber: number)
        if enabledLanes.contains(lane) { windows = orderedWindows(windows + [window]) } else { outsideGrid.append(window) }
        watchClosing(windows + outsideGrid)
        return window
    }
    // The new window takes its category's selected pane; the window showing
    // there stays behind it as a tab. Nothing is activated or raised.
    private func placeInCategory(_ element: AXUIElement, pid: pid_t, title: String) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("new window: place in its category", since: started) }
        guard canUndo, stripsBelongHere, !busy, !editingDraft, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        guard let lane = Classifier.knownLane(bundleID: app.bundleIdentifier ?? "pid.\(pid)", appName: app.localizedName ?? "App", title: title, rules: settings.appRules),
              enabledLanes.contains(lane) else { return false }
        guard let window = windows.first(where: { CFEqual($0.element, element) }), window.lane == lane else { return false }
        visibleSlotIDs[lane] = WindowSlots.replacing(slotIDs(lane), with: window.id, at: activeSlot[lane] ?? 0)
        activeIDs[lane] = window.id
        _ = apply(lane, presentationOnly: true, onlyIDs: [window.id])
        syncStrips(); onLaneControls?()
        status = "\(windowLabel(window)) opened in \(name(lane))."
        return true
    }
    // Categories follow where windows are: a window that fills a category's
    // tile counts in that category, whichever app it belongs to, so its strip
    // appears and switching includes it. Floating windows are left alone.
    @discardableResult func followLayout(including opened: Set<String> = []) -> Int {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("follow layout", since: started) }
        guard trusted, desktopAvailable, !busy, draggingStrip == nil else { return 0 }
        let tiles = enabledLanes.flatMap { lane in
            paneTiles(lane).enumerated().map { (lane: lane, tile: $0.element, index: $0.offset) }
        }
        var joined: [(id: String, lane: Lane, index: Int)] = []
        // Windows an app or agent moves keep their category. Only your own moves,
        // and a window that just opened over its app's other window (a new tab,
        // or a new Arc window in Browser 2), count where they sit.
        let eligible = userMoved.union(opened)
        userMoved.removeAll()
        for window in windows + outsideGrid where !window.minimized && !userPlaced.contains(window.id)
            && settings.appRules[window.bundleID] == nil && eligible.contains(window.id) {
            guard let lane = TileMembership.category(of: window.frame, tiles: tiles.map { (lane: $0.lane, tile: $0.tile) }), lane != window.lane else { continue }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let index = tiles.first { $0.lane == lane && $0.tile.contains(center) }?.index ?? 0
            overrides[window.id] = lane; settings.windowCategories[window.id] = lane.rawValue
            joined.append((window.id, lane, index))
        }
        guard !joined.isEmpty else { return 0 }
        save(); refresh(silent: true)
        for move in joined {
            guard let window = windows.first(where: { $0.id == move.id }) else { continue }
            if canUndo { capture(window); managedIDs.insert(window.id) }
            let slots = WindowSlots.normalized(visibleSlotIDs[move.lane] ?? [], ids: items(move.lane).map(\.id), capacity: settings.capacity(move.lane))
            visibleSlotIDs[move.lane] = WindowSlots.replacing(slots, with: window.id, at: move.index)
            activeIDs[move.lane] = window.id; activeSlot[move.lane] = move.index
        }
        status = joined.count == 1 ? "\(windows.first { $0.id == joined[0].id }.map(windowLabel) ?? "A window") now counts in \(name(joined[0].lane)), where it sits." : "\(joined.count) windows now count in the categories where they sit."
        onLaneControls?()
        return joined.count
    }
    var screen: NSScreen? { screens.first(where: { Self.displayID($0) == settings.screenID }) ?? screens.max(by: { $0.frame.width < $1.frame.width }) }
    static func displayID(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    // Tests lay out for a display that is not plugged in: its visible area in
    // top-left screen coordinates (see Tests/DisplaySweepTests.swift).
    var displayOverride: CGRect?
    var screenFrame: CGRect {
        if let displayOverride { return displayOverride }
        guard let screen else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let rect = screen.visibleFrame
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    func onTargetDisplay(_ frame: CGRect) -> Bool {
        guard let screen else { return true }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let displays = screens.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        guard let owner = WindowDisplay.owner(of: frame, displays: displays) else { return true }
        return Self.displayID(screens[owner]) == Self.displayID(screen)
    }
    var enabledLanes: [Lane] { settings.enabledLanes }
    var displayLabel: String {
        guard let screen else { return "No display" }
        return "\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))"
    }
    // Slider drags update only the strip opacity until the new value is committed.
    let idleStripOpacityPreview = CurrentValueSubject<Double?, Never>(nil)

    func idleStripOpacityFloor(for lane: Lane) -> Double {
        if settings.keepStripsVisible, let preview = idleStripOpacityPreview.value { return preview }
        return settings.idleStripFloor(style: settings.stripStyle(lane))
    }

    func previewIdleStripOpacity(_ value: Double) {
        let value = Settings.clampedIdleOpacity(value)
        if idleStripOpacityPreview.value != value { idleStripOpacityPreview.send(value) }
    }

    func setIdleStripOpacity(_ value: Double) {
        let value = Settings.clampedIdleOpacity(value)
        let changed = settings.idleStripOpacity != value
        if changed { settings.idleStripOpacity = value }
        if idleStripOpacityPreview.value != nil { idleStripOpacityPreview.send(nil) }
        if changed { save() }
    }

    func save() {
        guard !editingDraft else { return }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch { status = "Could not save preferences: \(error.localizedDescription)" }
    }
    func poll() {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("2-second poll", since: started) }
        // Window reads take a while on the main thread; skip a beat while a strip animates.
        guard !stripInMotion else { return }
        if !busy { rememberWorkingWindowInBackground() }
        let granted = AXIsProcessTrusted()
        if granted != trusted { trusted = granted; refresh(); if granted { adoptArrangement() }; updateNewWindowWatch() }
        tick += 1
        if !trusted { refresh(silent: true); return }
        if trusted && (settings.autoArrange || tick % 5 == 0) && !busy {
            syncDesktops()
            let previous = windows
            refreshInBackground { [weak self] in
                guard let self, !self.busy else { return }
                self.adoptTabSwitches(previous: previous)
                self.followLayout()
                self.syncStrips()
                if self.settings.autoArrange && self.stripSignature != self.lastSignature {
                    self.lastSignature = self.stripSignature
                    self.placeNewWindows(previous: previous)
                }
            }
        }
    }
    // Strips appear and disappear as categories gain or lose a second window.
    private func syncStrips() {
        let signature = windows.map { "\($0.id):\($0.lane.rawValue)" }.sorted().joined(separator: ",")
        if signature != stripSignature { stripSignature = signature; onLaneControls?() }
    }
    func placeNewWindows(previous: [ManagedWindow] = []) {
        guard settings.autoArrange, canUndo, stripsBelongHere, trusted, !busy else { return }
        busy = true
        defer { busy = false }
        let focused = focusedWindow()
        adoptTabSwitches(previous: previous)
        var count = 0
        for lane in enabledLanes {
            let all = items(lane).filter { !$0.minimized }
            let oldSlots = visibleSlotIDs[lane] ?? []
            var slots = WindowSlots.normalized(oldSlots, ids: all.map(\.id), capacity: settings.capacity(lane))
            let newIDs = Set(all.filter { !managedIDs.contains($0.id) && !$0.minimized && NSRunningApplication(processIdentifier: $0.pid)?.isHidden != true }.map(\.id))
            if let focused, focused.lane == lane, newIDs.contains(focused.id) {
                slots = WindowSlots.replacing(slots, with: focused.id, at: activeSlot[lane] ?? 0)
                activeIDs[lane] = focused.id
            }
            visibleSlotIDs[lane] = slots
            let replacements = Set(slots.filter { !$0.isEmpty }).subtracting(oldSlots)
            let touched = newIDs.union(replacements)
            guard !touched.isEmpty else { continue }
            _ = apply(lane, raiseWindows: false, onlyIDs: touched)
            // Raising a window of the app you are typing in makes it the key
            // window and steals the keyboard. Only other apps' windows are raised.
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            for id in replacements {
                if let window = all.first(where: { $0.id == id }), window.pid != frontmost { _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) }
            }
            count += newIDs.count
        }
        if count > 0 { status = "Placed \(count) new windows. Existing windows and category sizes stayed in place." }
        onLaneControls?()
    }
    // A tab switch hides one window and shows another in the same spot. The new
    // tab takes over the old one's category, slot and selection without moving,
    // so a different window is never pulled into that tile.
    func adoptTabSwitches(previous: [ManagedWindow]) {
        let current = Set(windows.map(\.id))
        let tabApps: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.apple.finder"]
        let vanished = previous.filter { !current.contains($0.id) && managedIDs.contains($0.id) && tabApps.contains($0.bundleID) }
        guard !vanished.isEmpty else { return }
        let previousIDs = Set(previous.map(\.id))
        let appeared = windows.filter { !previousIDs.contains($0.id) && !$0.minimized && overrides[$0.id] == nil && !userPlaced.contains($0.id) }
        let swaps = TabSwitch.pairs(vanished: vanished.map { SeenWindow(id: $0.id, pid: $0.pid, frame: $0.frame) }, appeared: appeared.map { SeenWindow(id: $0.id, pid: $0.pid, frame: $0.frame) })
        var recategorized = false
        for (tab, old) in swaps {
            guard let oldWindow = vanished.first(where: { $0.id == old }), let index = windows.firstIndex(where: { $0.id == tab }) else { continue }
            let lane = oldWindow.lane
            if windows[index].lane != lane {
                overrides[tab] = lane; settings.windowCategories[tab] = lane.rawValue
                windows[index].lane = lane; recategorized = true
            }
            visibleSlotIDs[lane] = (visibleSlotIDs[lane] ?? []).map { $0 == old ? tab : $0 }
            if activeIDs[lane] == old { activeIDs[lane] = tab }
            let original = self[saved: old], firstCapture = self[saved: tab] == nil
            capture(windows[index]); managedIDs.insert(tab)
            // Native tabs share their window group's geometry. Restoring the
            // newly active tab to an already tiled frame would undo Restore.
            if firstCapture, let original {
                self[saved: tab] = SavedWindow(element: windows[index].element, frame: original.frame, minimized: original.minimized,
                                               pid: windows[index].pid, bundleID: windows[index].bundleID, spaceNumber: original.spaceNumber)
            }
            if userPlaced.contains(old) { markPlaced(tab); recategorized = true }
        }
        if recategorized { save() }
    }
    // After Lanes restarts (an update, a crash), take over the windows that
    // already sit in their category's tiles without moving or raising anything,
    // so strips and automatic placement work without pressing Organize again.
    func adoptArrangement(refreshInventory: Bool = true) {
        guard trusted, let scope = restoreScope, !restoredScopes.contains(scope), !busy,
              settings.showLaneControls || settings.autoArrange, !settings.customRects.isEmpty,
              desktops.isEmpty ? !canUndo : !stripsBelongHere && (refreshInventory || activeDesktop.flatMap(settings.spaceLayout) != nil) else { return }
        if refreshInventory { refresh(silent: true) }
        followLayout()
        let order = StackOrder.positions(windows: discoveryOrder, onScreen: onScreenStack, numbers: onScreenNumbers)
        var adopted = 0
        for lane in enabledLanes {
            let all = items(lane), capacity = settings.capacity(lane)
            let tiles = paneTiles(lane, count: capacity)
            let pick = StackOrder.adoptedSlots(tiles: tiles, windows: all.filter { !$0.minimized }.map { SeenWindow(id: $0.id, pid: $0.pid, frame: $0.frame) }, order: order)
            guard !pick.adopted.isEmpty else { continue }
            for id in pick.adopted { if let window = all.first(where: { $0.id == id }) { capture(window); managedIDs.insert(id) } }
            visibleSlotIDs[lane] = WindowSlots.normalized(pick.slots, ids: all.map(\.id), capacity: capacity)
            if let front = pick.slots.first(where: { !$0.isEmpty }) { activeIDs[lane] = front; activeSlot[lane] = pick.slots.firstIndex(of: front) }
            adopted += pick.adopted.count
        }
        guard adopted > 0 else { return }
        status = "Picked up \(adopted) windows where they were. Organize re-arranges everything."
        onLaneControls?()
    }
    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if trusted { refresh() }
        else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    // What the slow part of a window read returns: every window's facts as its app
    // reported them, plus the on-screen order. Asking apps is the slow part (each
    // answers in its own time), so it can run off the main thread.
    struct RawWindow {
        let element: AXUIElement
        let app: NSRunningApplication
        let id: String
        let title: String
        let frame: CGRect
        let minimized: Bool
        let visible: Bool
        let pageTitle: String?
        let number: UInt32?
    }
    struct Discovery {
        let started: TimeInterval
        let windows: [RawWindow]
        var skipped: [String] = []
        let onScreenNumbers: [UInt32: Int]
        let onScreenStack: [(pid: Int32, frame: CGRect)]
    }
    private var windowMembership: ((UInt32) -> Bool?)? {
        guard let space = currentSpaceNumber, let windowSpaces = spacesAccess.windowSpaces else { return nil }
        return { windowSpaces($0).map { $0 == [space] } }
    }
    func windowCanMoveHere(_ element: AXUIElement) -> Bool {
        guard desktopAvailable else { return false }
        guard spacesAccess.tracksDesktops else { return true }
        guard let membership = windowMembership, let number = spacesAccess.windowID(element) else { return false }
        return membership(number) == true
    }
    nonisolated static func discover(apps: [NSRunningApplication], membership: ((UInt32) -> Bool?)? = nil) -> Discovery {
        let started = ProcessInfo.processInfo.systemUptime
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var visibleRects: [pid_t: [CGRect]] = [:]
        var visibleNumbers: [pid_t: Set<UInt32>] = [:]
        var numbers: [UInt32: Int] = [:]
        var stack: [(pid: Int32, frame: CGRect)] = []
        for item in onScreen {
            guard let pid = item[kCGWindowOwnerPID as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { continue }
            // Picture in Picture and other floating windows sit above the normal level but are
            // just as visible; the menu bar, Dock and screen overlays (level 20+) are not windows.
            let layer = (item[kCGWindowLayer as String] as? Int) ?? 0
            guard layer >= 0 && layer < 20 else { continue }
            visibleRects[pid_t(pid), default: []].append(CGRect(x: x, y: y, width: w, height: h))
            if let number = item[kCGWindowNumber as String] as? UInt32 {
                visibleNumbers[pid_t(pid), default: []].insert(number)
                if layer == 0 { numbers[number] = stack.count }
            }
            if layer == 0 { stack.append((pid: Int32(pid), frame: CGRect(x: x, y: y, width: w, height: h))) }
        }
        var raw: [RawWindow] = []
        var skipped: [String] = []
        var seen: Set<String> = []
        for app in apps where !app.isTerminated {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            guard let elements = axValue(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for element in elements {
                AXUIElementSetMessagingTimeout(element, 0.2)
                let rawTitle = (axValue(element, kAXTitleAttribute) as? String) ?? ""
                let who = "\(app.localizedName ?? "?") \"\(rawTitle.prefix(30))\""
                guard axIsWindow(element) || Classifier.isCompactPlayer(title: rawTitle) else { skipped.append("\(who): not a standard window"); continue }
                guard !axBool(element, "AXFullScreen"), let frame = axFrame(element), frame.width > 80, frame.height > 60 else { skipped.append("\(who): full screen or too small"); continue }
                let id = "\(app.processIdentifier)-\(CFHash(element))"
                guard seen.insert(id).inserted else { continue }
                let minimized = axBool(element, kAXMinimizedAttribute)
                let number = FrontProcess.windowID(element)
                let onScreen = WindowVisibility.matches(number: number, onScreen: visibleNumbers[app.processIdentifier, default: []], frame: frame, fallbackFrames: visibleRects[app.processIdentifier, default: []])
                let belongs = number.flatMap { membership?($0) }
                let visible = Self.discoverableWindow(onScreen: onScreen, hidden: minimized || app.isHidden, belongs: belongs, scoped: membership != nil)
                guard visible else { skipped.append("\(who): not on screen (another Space or a background tab) at \(Int(frame.minX)),\(Int(frame.minY))"); continue }
                let appName = app.localizedName ?? "App"
                // Ardia names every window "Ardia"; the page title is on the web area inside it.
                let page = app.bundleIdentifier == "com.ardia.browser" && (rawTitle.isEmpty || rawTitle == appName) ? axWebAreaTitle(element) : nil
                raw.append(RawWindow(element: element, app: app, id: id, title: rawTitle, frame: frame,
                                     minimized: minimized, visible: visible, pageTitle: page, number: number))
            }
        }
        return Discovery(started: started, windows: raw, skipped: skipped, onScreenNumbers: numbers, onScreenStack: stack)
    }
    nonisolated static func discoverableWindow(onScreen: Bool, hidden: Bool, belongs: Bool?, scoped: Bool) -> Bool {
        if onScreen { return belongs != false }
        return hidden && (belongs == true || !scoped)
    }
    // A newer read already landed: an older one is dropped, not applied over it.
    private var lastDiscoveryApplied: TimeInterval = 0
    private static let discoveryQueue = DispatchQueue(label: "lanes.window-discovery", qos: .userInitiated)
    private var backgroundRefreshFollowUps: [() -> Void] = []
    private var backgroundRefreshQueued = false
    private var backgroundRefreshAgain = false

    func refresh(silent: Bool = false, restorePopulatedCategories: Bool = false, caller: String = #function, line: Int = #line) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("refresh (on the main thread, from \(caller) line \(line)): \(windows.count) windows", since: started) }
        // An edit works against a temporary copy of settings and window state.
        // Discovery belongs to the applied grid, so defer it until after Apply.
        guard !editingDraft else { return }
        syncDesktops()
        guard desktopAvailable, prepareDiscovery(silent: silent) else { return }
        let generation = desktopGeneration
        let found = Self.discover(apps: regularRunningApps(), membership: windowMembership)
        syncDesktops()
        guard generation == desktopGeneration else { return }
        applyDiscovery(found, silent: silent, restorePopulatedCategories: restorePopulatedCategories)
    }
    // The same read with the apps asked off the main thread, so strips keep moving
    // while a busy app answers. Used for every update you did not ask for.
    // `then` runs on the main thread once the windows are up to date.
    func refreshInBackground(then followUp: (() -> Void)? = nil) {
        guard !editingDraft else { return }
        let generation = desktopGeneration
        syncDesktops()
        guard desktopAvailable, prepareDiscovery(silent: true) else { return }
        refreshEditorWindowList()
        if let followUp, generation == desktopGeneration { backgroundRefreshFollowUps.append(followUp) }
        // Several requests close together share one read; one that arrives while a read
        // is under way gets a fresh read after it, since the window may be newer.
        guard !backgroundRefreshQueued else { backgroundRefreshAgain = true; return }
        backgroundRefreshQueued = true
        let apps = regularRunningApps(), membership = windowMembership
        let readingGeneration = desktopGeneration
        Self.discoveryQueue.async { [weak self] in
            let found = Self.discover(apps: apps, membership: membership)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.backgroundRefreshQueued = false
                    self.syncDesktops()
                    if readingGeneration != self.desktopGeneration {
                        self.backgroundRefreshAgain = false
                        self.refreshInBackground { [weak self] in self?.showCurrentDesktopStrips() }
                        return
                    }
                    if !self.editingDraft && !self.busy { self.applyDiscovery(found, silent: true, restorePopulatedCategories: false) }
                    if self.backgroundRefreshAgain { self.backgroundRefreshAgain = false; self.refreshInBackground(); return }
                    let followUps = self.backgroundRefreshFollowUps
                    self.backgroundRefreshFollowUps = []
                    followUps.forEach { $0() }
                }
            }
        }
    }
    private func prepareDiscovery(silent: Bool) -> Bool {
        refreshRunningApps()
        trusted = AXIsProcessTrusted()
        recordPermissionState()
        guard trusted else {
            windows = []
            if !silent { status = "\(runningApps.count) running apps found. Enable window control to see their windows." }
            return false
        }
        return true
    }
    // Sorting windows into categories and publishing them: quick, on the main thread.
    private var lastDiscoverySummary = ""
    private func applyDiscovery(_ found: Discovery, silent: Bool, restorePopulatedCategories: Bool) {
        guard found.started >= lastDiscoveryApplied else { StripTrace.log("windows: an older read was dropped"); return }
        defer {
            let byApp = Dictionary(grouping: found.windows, by: { $0.app.localizedName ?? "?" }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            let skippedList = found.skipped.filter { !$0.hasPrefix("Ghostty") || $0.contains("not a standard") }.joined(separator: "; ")
            let summary = "read \(found.windows.count) [\(byApp)] → in grid \(windows.count), outside \(outsideGrid.count)" + (skippedList.isEmpty ? "" : "\n      left out: " + skippedList) + "\n      Ghostty background tabs left out: \(found.skipped.filter { $0.hasPrefix("Ghostty") && !$0.contains("not a standard") }.count)"
            if summary != lastDiscoverySummary { lastDiscoverySummary = summary; StripTrace.log("windows: " + summary) }
        }
        lastDiscoveryApplied = found.started
        onScreenNumbers = found.onScreenNumbers
        onScreenStack = found.onScreenStack
        var result: [ManagedWindow] = []
        var outside: [ManagedWindow] = []
        var populated: Set<Lane> = []
        var resolvedPreviewAssignments = false
        for raw in found.windows {
            let app = raw.app, id = raw.id, frame = raw.frame
            let known = managedIDs.contains(id)
            if settings.onlyTargetScreen && !known && !onTargetDisplay(frame) { continue }
            let bundle = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            if settings.ignoredApps.contains(bundle) { continue }
            let appName = app.localizedName ?? "App"
            let title = raw.pageTitle ?? (raw.title.isEmpty ? appName : raw.title)
            if adoptDesktopPreviewAssignment(pid: app.processIdentifier, number: raw.number, id: id) { resolvedPreviewAssignments = true }
            let lane = category(for: id, bundle: bundle, appName: appName, title: title)
            let window = ManagedWindow(id: id, element: raw.element, pid: app.processIdentifier, bundleID: bundle, appName: appName,
                                       title: title, icon: app.icon, frame: frame, minimized: raw.minimized, lane: lane, windowNumber: raw.number)
            if restorePopulatedCategories && availableLanes.contains(lane) && !settings.shelvedLanes.contains(lane.rawValue) { populated.insert(lane) }
            else if !enabledLanes.contains(lane) {
                // Its category is shelved or hidden: the window stays out of the grid.
                outside.append(window)
                continue
            }
            result.append(window)
        }
        if resolvedPreviewAssignments { save() }
        discoveryOrder = result.map { SeenWindow(id: $0.id, pid: $0.pid, frame: $0.frame, number: $0.windowNumber) }
        if restorePopulatedCategories && !populated.isEmpty {
            settings.hiddenLanes = availableLanes.filter { !populated.contains($0) }.map(\.rawValue)
            settings.showMediaShelf = populated.contains(.media)
        }
        // Only a real change redraws the strips (a re-read every few seconds usually finds none).
        let ordered = orderedWindows(result)
        func signature(_ list: [ManagedWindow]) -> [String] { list.map { "\($0.id)|\($0.lane.rawValue)|\($0.title)|\($0.minimized)|\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" } }
        if signature(ordered) != signature(windows) { windows = ordered }
        settleClosing()
        outsideGrid = outside
        let live = Set((result + outside).map { CFHash($0.element) })
        lanesMovedAt = lanesMovedAt.filter { live.contains($0.key) }
        lanesMovedFrames = lanesMovedFrames.filter { live.contains($0.key) }
        let open = Set((result + outside).map(\.id))
        windowNumbers = windowNumbers.filter { open.contains($0.key) }
        watchClosing(result + outside)
        for lane in enabledLanes { pages[lane] = min(pages[lane] ?? 0, pageCount(lane) - 1) }
        if !silent { status = "\(windows.count) windows found. Assign them, then arrange your desktop." }
    }
    // Windows outside every category are left alone, except that Organize
    // moves any covering a category to the middle so the grid stays clear.
    private func centerStrays() -> Int {
        let regions = enabledLanes.map(rawLaneFrame)
        var moved = 0
        for window in outsideGrid where !window.minimized && NSRunningApplication(processIdentifier: window.pid)?.isHidden != true {
            guard StrayWindow.coversGrid(window.frame, regions: regions) else { continue }
            let target = NewWindowCenter.frame(for: window.frame.size, in: screenFrame, gap: settings.gap)
            if !TabSwitch.sameSpot(target, window.frame), movePreservingOriginal(window, to: target) { moved += 1 }
        }
        return moved
    }
    // Listing apps took ~12 ms and ran twice per re-read. The list is kept until an app
    // launches or quits, and checked afresh at least every 30 seconds.
    private var regularAppsCache: [NSRunningApplication]?
    private var regularAppsCachedAt: TimeInterval = 0
    func regularRunningApps() -> [NSRunningApplication] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = regularAppsCache, now - regularAppsCachedAt < 30 { return cached.filter { !$0.isTerminated } }
        var seen: Set<pid_t> = []
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier > 0 && app.processIdentifier != getpid() && app.activationPolicy == .regular && !app.isTerminated && seen.insert(app.processIdentifier).inserted
        }
        regularAppsCache = apps; regularAppsCachedAt = now
        return apps
    }
    // The app list (with icons) for the Lanes window. Building it took ~30 ms, so it
    // is rebuilt only when apps launch or quit, or your app rules change.
    private var runningAppsKey = ""
    func refreshRunningApps() {
        let apps = regularRunningApps()
        let key = apps.map { "\($0.processIdentifier)" }.joined(separator: ",") + "|" + settings.appRules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        guard key != runningAppsKey else { return }
        runningAppsKey = key
        runningApps = apps.map { app in
            let name = app.localizedName ?? "App", bundle = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            let lane = Classifier.lane(bundleID: bundle, appName: name, title: "", rules: settings.appRules)
            return RunningAppSummary(pid: app.processIdentifier, name: name, bundleID: bundle, icon: app.icon, lane: lane)
        }.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }
    }
    private func category(for id: String, bundle: String, appName: String, title: String) -> Lane {
        Self.category(for: id, bundle: bundle, appName: appName, title: title, in: settings)
    }
    private static func category(for id: String, bundle: String, appName: String, title: String, in settings: Settings) -> Lane {
        if let raw = settings.windowCategories[id], let lane = Lane(rawValue: raw),
           settings.appRules[bundle] == nil || settings.placedWindows.contains(id) { return lane }
        return Classifier.lane(bundleID: bundle, appName: appName, title: title, rules: settings.appRules)
    }
    func apps(_ lane: Lane) -> [RunningAppSummary] { runningApps.filter { $0.lane == lane } }
    func editorItems(_ lane: Lane) -> [ManagedWindow] {
        viewingOtherDesktop ? editorWindows.filter { $0.lane == lane } : items(lane)
    }
    func discoveryCount(_ lane: Lane) -> String { trusted ? "\(editorItems(lane).count)" : "\(apps(lane).count) apps" }
    // The window goes back to its app's usual category.
    func clearWindowCategory(_ window: ManagedWindow) {
        syncDesktops()
        setWindowRule(window.id, to: nil)
        save(); reclassifyInventory()
        if let back = windows.first(where: { $0.id == window.id }), trusted && canUndo && stripsBelongHere && !busy { reveal(back) }
        onLaneControls?()
        status = "\(windowLabel(window)) is back with the rest of \(window.appName)."
    }
    private func setAppRule(_ app: RunningAppSummary, to lane: Lane?) {
        settings.appRules[app.bundleID] = lane?.rawValue
        for window in windows + outsideGrid where window.bundleID == app.bundleID {
            if !settings.placedWindows.contains(window.id) {
                overrides[window.id] = nil
                settings.windowCategories[window.id] = nil
            }
        }
    }
    func resetAppRule(_ app: RunningAppSummary) { updateAppRule(app, to: nil) }
    func assignApp(_ app: RunningAppSummary, to lane: Lane) { updateAppRule(app, to: lane) }
    private func updateAppRule(_ app: RunningAppSummary, to lane: Lane?) {
        syncDesktops()
        let previous = Dictionary(uniqueKeysWithValues: (windows + outsideGrid).filter { $0.bundleID == app.bundleID }.map { ($0.id, $0.lane) })
        setAppRule(app, to: lane)
        save(); refreshRunningApps(); reclassifyInventory()
        if trusted && canUndo && stripsBelongHere && !busy {
            let moved = windows.filter { $0.bundleID == app.bundleID && previous[$0.id] != $0.lane }
            for (destination, group) in Dictionary(grouping: moved, by: \.lane) {
                _ = apply(destination, raiseWindows: false, onlyIDs: Set(group.map(\.id)))
            }
        }
        onLaneControls?()
        status = lane.map { "\(app.name) now goes to \(name($0))." } ?? "\(app.name) uses its automatic category again."
        selectedTemplateChanged = true
    }
    private struct DesktopPreviewWindow {
        let number: UInt32
        let pid: pid_t
        let title: String?
        let frame: CGRect
    }
    private static let desktopPreviewQueue = DispatchQueue(label: "lanes.desktop-editor-inventory", qos: .userInitiated)

    // Read only. Off-Space previews never enter the inventory used by Organize,
    // Restore, focus or the strips.
    private func refreshEditorWindowList() {
        guard trusted, let key = inactiveEditorKey, let display = settings.activeDisplayKey, let shownDesktop,
              let space = desktopManagedNumbers[shownDesktop], let readWindows = spacesAccess.readWindows,
              let windowSpaces = spacesAccess.windowSpaces, !pendingDesktopReads.contains(key) else { return }
        refreshRunningApps()
        let apps = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.pid, $0) })
        let pids = Set(apps.keys)
        pendingDesktopReads.insert(key)
        Self.desktopPreviewQueue.async { [weak self] in
            let records = readWindows().map { items in
                Self.readDesktopPreview(items, pids: pids, space: space, windowSpaces: windowSpaces)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.pendingDesktopReads.remove(key) }
                    guard let records, self.settings.activeDisplayKey == display,
                          self.activeDesktop != shownDesktop, self.desktopManagedNumbers[shownDesktop] == space else { return }
                    self.updateDesktopPreview(records, apps: apps, for: key)
                }
            }
        }
    }
    private nonisolated static func readDesktopPreview(_ items: [[String: Any]], pids: Set<pid_t>, space: Int,
                                                        windowSpaces: (UInt32) -> Set<Int>?) -> [DesktopPreviewWindow] {
        var seen: Set<UInt32> = []
        return items.compactMap { item -> DesktopPreviewWindow? in
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  item[kCGWindowLayer as String] as? Int == 0,
                  let number = item[kCGWindowNumber as String] as? UInt32, seen.insert(number).inserted,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 80, height > 60, windowSpaces(number) == [space] else { return nil }
            let title = (item[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DesktopPreviewWindow(number: number, pid: pid, title: title?.isEmpty == false ? title : nil,
                                        frame: CGRect(x: x, y: y, width: width, height: height))
        }.sorted { $0.number < $1.number }
    }
    private func updateDesktopPreview(_ records: [DesktopPreviewWindow], apps: [pid_t: RunningAppSummary], for key: String) {
        let cached = desktopInventory[key] ?? []
        var ordinals: [pid_t: Int] = [:]
        let updated = records.compactMap { record -> ManagedWindow? in
            guard let app = apps[record.pid], !settings.onlyTargetScreen || onTargetDisplay(record.frame) else { return nil }
            ordinals[record.pid, default: 0] += 1
            if var known = cached.first(where: {
                $0.windowNumber == record.number && $0.pid == record.pid &&
                $0.id != Self.desktopPreviewID(pid: record.pid, number: record.number)
            }) {
                known.frame = record.frame
                return known
            }
            let title = record.title ?? "Window \(ordinals[record.pid, default: 1])"
            return ManagedWindow(id: Self.desktopPreviewID(pid: record.pid, number: record.number),
                                 element: AXUIElementCreateApplication(record.pid), pid: record.pid, bundleID: app.bundleID,
                                 appName: app.name, title: title, icon: app.icon, frame: record.frame,
                                 minimized: false, lane: app.lane, windowNumber: record.number)
        }
        let changed = cached.count != updated.count || zip(cached, updated).contains { old, new in
            old.id != new.id || old.title != new.title || old.frame != new.frame || old.minimized != new.minimized
        }
        if changed || desktopInventory[key] == nil { desktopInventory[key] = updated }
    }

    private var inactiveEditorKey: String? {
        guard viewingOtherDesktop, let display = settings.activeDisplayKey, let shownDesktop else { return nil }
        return Settings.spaceLayoutKey(display: display, space: shownDesktop)
    }
    var loadingEditorWindows: Bool {
        guard let key = inactiveEditorKey else { return false }
        return desktopInventory[key] == nil && pendingDesktopReads.contains(key)
    }
    var editorWindows: [ManagedWindow] {
        let inventory = inactiveEditorKey.map { desktopInventory[$0] ?? [] } ?? (windows + outsideGrid)
        let source = viewingOtherDesktop ? grid : settings
        return inventory.filter { !isIgnored($0.bundleID) }.map { window in
            var result = window
            result.lane = Self.category(for: window.id, bundle: window.bundleID, appName: window.appName, title: window.title, in: source)
            return result
        }
    }
    var editorApps: [RunningAppSummary] {
        guard trusted, !desktops.isEmpty else { return runningApps }
        let open = Set(editorWindows.map(\.pid)), rules = (viewingOtherDesktop ? grid : settings).appRules
        return runningApps.filter { open.contains($0.pid) }.map {
            RunningAppSummary(pid: $0.pid, name: $0.name, bundleID: $0.bundleID, icon: $0.icon,
                              lane: Classifier.lane(bundleID: $0.bundleID, appName: $0.name, title: "", rules: rules))
        }
    }
    var editorAppRules: [String: String] { (viewingOtherDesktop ? grid : settings).appRules }
    func setEditorAppCategory(_ app: RunningAppSummary, to lane: Lane?) {
        if viewingOtherDesktop { editGrid { setAppRule(app, to: lane) } }
        else { updateAppRule(app, to: lane) }
    }
    func setEditorWindowCategory(_ window: ManagedWindow, to lane: Lane?) {
        if viewingOtherDesktop { editGrid { setWindowRule(window.id, to: lane) } }
        else if let lane { moveWindow(window, to: lane) }
        else { clearWindowCategory(window) }
    }
    nonisolated static func desktopPreviewID(pid: pid_t, number: UInt32) -> String {
        "preview:\(pid):\(number)"
    }
    // An off-Space preview identifies a window by its WindowServer number. Once
    // AX sees it on the active Space, transfer the pin to the usual window ID.
    @discardableResult func adoptDesktopPreviewAssignment(pid: pid_t, number: UInt32?, id: String) -> Bool {
        guard let number else { return false }
        let preview = Self.desktopPreviewID(pid: pid, number: number)
        guard preview != id else { return false }
        let rule = settings.windowCategories.removeValue(forKey: preview)
        guard rule != nil || settings.placedWindows.contains(preview) else { return false }
        overrides[preview] = nil
        settings.placedWindows.removeAll { $0 == preview }
        settings.windowCategories[id] = rule
        overrides[id] = rule.flatMap(Lane.init(rawValue:))
        markPlaced(id)
        return true
    }
    private func setWindowRule(_ id: String, to lane: Lane?) {
        overrides[id] = lane
        settings.windowCategories[id] = lane?.rawValue
        markPlaced(id)
    }
    // Leave an app alone: its windows lose their tabs and Lanes never moves,
    // centers or puts them back. They stay exactly where they are.
    struct IgnoredApp: Identifiable { let id: String; let name: String; let icon: NSImage? }
    var ignoredAppList: [IgnoredApp] {
        settings.ignoredApps.map { bundle in
            if let running = runningApps.first(where: { $0.bundleID == bundle }) { return IgnoredApp(id: bundle, name: running.name, icon: running.icon) }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            return IgnoredApp(id: bundle, name: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
    }
    func isIgnored(_ bundleID: String) -> Bool { settings.ignoredApps.contains(bundleID) }
    func ignoreApp(_ bundleID: String, name: String) {
        guard !settings.ignoredApps.contains(bundleID) else { return }
        settings.ignoredApps.append(bundleID)
        for window in windows + outsideGrid where window.bundleID == bundleID {
            guardPending.removeValue(forKey: window.id)?.cancel(); managedIDs.remove(window.id)
            hiddenAppSnapshot[window.pid] = nil
        }
        // Left alone means Restore and Quit leave it alone too: forget where its
        // windows were, whether they were minimized, and whether the app was hidden.
        for (scope, windows) in restoreSnapshots {
            let ignored = windows.filter { $0.value.bundleID == bundleID }
            guard !ignored.isEmpty else { continue }
            for (id, saved) in ignored {
                hiddenAppSnapshot[saved.pid] = nil
                if scope == restoreScope { guardPending.removeValue(forKey: id)?.cancel() }
            }
            let remaining = windows.filter { ignored[$0.key] == nil }
            restoreSnapshots[scope] = remaining.isEmpty ? nil : remaining
            managedByScope[scope]?.subtract(ignored.keys)
        }
        save(); refresh(silent: true); onLaneControls?()
        status = "Lanes leaves \(name) alone. Drag it onto a category to manage it again."
    }
    func manageApp(_ bundleID: String) {
        guard settings.ignoredApps.contains(bundleID) else { return }
        settings.ignoredApps.removeAll { $0 == bundleID }
        save(); refresh(silent: true); onLaneControls?()
        status = "\(ignoredName(bundleID)) is managed by Lanes again."
    }
    private func ignoredName(_ bundleID: String) -> String { runningApps.first { $0.bundleID == bundleID }?.name ?? "The app" }
    func activateApp(_ app: RunningAppSummary) { NSRunningApplication(processIdentifier: app.pid)?.activate() }
    func items(_ lane: Lane) -> [ManagedWindow] { windows.filter { $0.lane == lane } }
    // Discovery order and changing terminal titles must not replace a saved queue.
    func orderedWindows(_ discovered: [ManagedWindow]) -> [ManagedWindow] {
        let oldOrder = Dictionary(uniqueKeysWithValues: windows.enumerated().map { ($1.id, $0) })
        return discovered.sorted {
            let categoryA = availableLanes.firstIndex(of: $0.lane) ?? Int.max, categoryB = availableLanes.firstIndex(of: $1.lane) ?? Int.max
            if categoryA != categoryB { return categoryA < categoryB }
            let saved = settings.windowOrder[$0.lane.rawValue] ?? []
            let a = saved.firstIndex(of: $0.id) ?? (saved.count + (oldOrder[$0.id] ?? 100000)), b = saved.firstIndex(of: $1.id) ?? (saved.count + (oldOrder[$1.id] ?? 100000))
            if a != b { return a < b }
            return ($0.appName, $0.title, $0.id) < ($1.appName, $1.title, $1.id)
        }
    }
    func pageCount(_ lane: Lane) -> Int { Layout.pageCount(total: items(lane).count, capacity: settings.capacity(lane)) }
    func visibleItems(_ lane: Lane) -> [ManagedWindow] {
        let items = items(lane)
        let ids = slotIDs(lane)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }
    func slotIDs(_ lane: Lane) -> [String] { WindowSlots.normalized(visibleSlotIDs[lane] ?? [], ids: items(lane).filter { !$0.minimized }.map(\.id), capacity: settings.capacity(lane)) }
    func rawLaneFrame(_ lane: Lane) -> CGRect { Layout.frame(unit: settings.unitRect(for: lane), in: screenFrame, gap: settings.gap) }
    func laneFrame(_ lane: Lane) -> CGRect {
        var frame = rawLaneFrame(lane)
        if settings.stripReservesSpace { let inset = stripReservedHeight(lane); frame.origin.y += inset; frame.size.height = max(80, frame.height - inset) }
        return frame
    }
    func paneTiles(_ lane: Lane, count: Int? = nil) -> [CGRect] {
        let frame = laneFrame(lane)
        let arrangement = Layout.arrangement(in: frame, count: count ?? settings.capacity(lane), lane: lane, split: settings.split(lane))
        return Layout.tiles(in: frame, count: arrangement.count, gap: settings.gap, lane: lane,
                            split: settings.split(lane), sizes: settings.paneSizes(lane, arrangement: arrangement))
    }
    // The band a strip reserves above its windows. Height only: it needs no text
    // measuring (and the pane chooser's labels depend on this band).
    func stripReservedHeight(_ lane: Lane) -> Double {
        WindowStripMetrics.measure(style: settings.stripStyle(lane), count: stripCount(lane), scale: settings.windowStripScale, availableWidth: rawLaneFrame(lane).width, slots: settings.capacity(lane)).reservedHeight
    }
    func stripMetrics(_ lane: Lane) -> WindowStripMetrics {
        WindowStripMetrics.measure(style: settings.stripStyle(lane), count: stripCount(lane), scale: settings.windowStripScale, availableWidth: rawLaneFrame(lane).width, slots: settings.capacity(lane), pill: stripPillWidth(lane))
    }
    // The resting pill hugs what it draws: dot, name, count and the pane chooser.
    // The strip is a window of its own, so anything wider would block clicks on the
    // windows under it.
    func stripPillWidth(_ lane: Lane) -> Double {
        let scale = WindowStripMetrics.clamped(settings.windowStripScale), text = WindowStripMetrics.tabText(scale: scale)
        let label = StripText.width(name(lane), size: text, weight: .semibold) + StripText.width("\(stripCount(lane))", size: text, weight: .medium, digits: true)
        return WindowStripMetrics.pillChrome * scale + label + stripPaneWidth(lane)
    }
    // The pane chooser between the count and the tabs, with the gap before it.
    func stripPaneWidth(_ lane: Lane) -> Double {
        let scale = WindowStripMetrics.clamped(settings.windowStripScale), slots = slotIDs(lane).count
        if slots == 2 {
            let labels = (0..<2).reduce(0.0) { $0 + StripText.width(slotLabel(lane, index: $1), size: 9 * scale, weight: .semibold) }
            return labels + (6 + 2 * 10 + 2 * 3 + 14) * scale
        }
        return slots > 2 ? WindowStripMetrics.paneRoom(slots: slots) * scale : 0
    }
    // Everything in an open tab strip that is not a tab: the pill and the counter.
    func stripChipRoom(_ lane: Lane) -> Double {
        stripPillWidth(lane) + WindowStripMetrics.counterWidth(count: stripCount(lane), scale: WindowStripMetrics.clamped(settings.windowStripScale))
    }
    // The open list's size, whether or not it is open now (its rows are laid out once).
    func listStripMetrics(_ lane: Lane) -> WindowStripMetrics {
        WindowStripMetrics.list(count: stripCount(lane), scale: settings.windowStripScale, availableWidth: rawLaneFrame(lane).width, slots: settings.capacity(lane), pill: stripPillWidth(lane))
    }
    // Top-left screen coordinates. Above the windows: the reserved band's left
    // edge. On the windows: centered on the region's top edge, or where it was dragged.
    // Preferences › Alignment moves either one to the left, middle or right of that edge.
    // Where the strip rests (not grown by hover).
    func stripRestFrame(_ lane: Lane) -> CGRect {
        let region = rawLaneFrame(lane), idle = stripMetrics(lane)
        let restSize = CGSize(width: idle.width, height: idle.height)
        if let pinned = pinnedStripOrigin[lane] { return CGRect(origin: pinned, size: restSize) }
        let alignment = settings.effectiveStripAlignment
        if settings.stripPlacement == .onWindows {
            let rest = StripPlacementGeometry.frame(size: restSize, region: region, bounds: screenFrame,
                                                     saved: settings.stripPositions[lane.rawValue], alignment: alignment)
            return stripKeepsWindowButtonsClear(lane) ? StripPlacementGeometry.clearingWindowButtons(rest, in: region) : rest
        }
        let x = alignment == .left ? region.minX : alignment == .middle ? region.midX - restSize.width / 2 : region.maxX - restSize.width
        return CGRect(origin: CGPoint(x: x, y: region.minY), size: restSize)
    }
    func stripFrame(_ lane: Lane) -> CGRect {
        let idle = stripMetrics(lane), shown = displayedStripMetrics(lane)
        let rest = stripRestFrame(lane)
        if stripFitsWidth(lane) { return fittedStripFrame(lane) }
        guard shown.width != idle.width || shown.height != idle.height else { return rest }
        let size = CGSize(width: shown.width, height: shown.height)
        var frame = StripPlacementGeometry.grown(rest: rest, size: size, bounds: screenFrame, above: stripListOpensAbove(lane), leftward: stripOpensLeftward(lane))
        // Closing tabs in a strip that opened to the left: its left end, and the tabs
        // under the pointer, hold still while its right end shrinks in.
        if let held = pinnedStripLeft[lane] { frame.origin.x = held }
        return frame
    }
    // A strip aligned to the right of its category opens to the left, so it stays over
    // its own windows. A strip you dragged opens to the right from where you put it.
    func stripOpensLeftward(_ lane: Lane) -> Bool {
        guard settings.effectiveStripAlignment == .right else { return false }
        return settings.stripPlacement != .onWindows || settings.stripPositions[lane.rawValue] == nil
    }
    private func stripKeepsWindowButtonsClear(_ lane: Lane) -> Bool {
        settings.stripPlacement == .onWindows && settings.stripExpansion == .keepWindowButtonsClear
            && settings.stripStyle(lane).expandsOnHover
    }
    // The expanded tab row can fill the grid slot. A vertical list keeps its own size.
    func stripFitsWidth(_ lane: Lane) -> Bool {
        settings.stripFitsWindowWidth && settings.stripStyle(lane).expandsOnHover && expandedStrip == lane && !stripUsesList(lane)
    }
    // Where that open strip sits, open or not.
    func fittedStripFrame(_ lane: Lane) -> CGRect {
        let rest = stripRestFrame(lane)
        var slot = rawLaneFrame(lane)
        if stripKeepsWindowButtonsClear(lane), rest.minY < slot.minY + StripPlacementGeometry.windowButtonsRowHeight,
           rest.maxY > slot.minY {
            let inset = min(StripPlacementGeometry.windowButtonsWidth, slot.width)
            slot.origin.x += inset
            slot.size.width -= inset
        }
        return StripPlacementGeometry.fitted(rest: rest, height: 32 * WindowStripMetrics.clamped(settings.windowStripScale),
                                             region: slot, bounds: screenFrame, margin: 0)
    }
    // A hover list opens under its pill, or above it where it would run past the
    // bottom of the display, so the pill never leaves the pointer. Drawing, the
    // strip's frame and drops on its rows all ask here. The side is chosen when the
    // list opens and kept while it is open: closing rows must not flip it mid-hover.
    private var listSideHeld: [Lane: Bool] = [:]
    func stripListOpensAbove(_ lane: Lane) -> Bool {
        guard stripUsesList(lane) else { return false }
        if expandedStrip == lane, let held = listSideHeld[lane] { return held }
        let above = StripPlacementGeometry.opensAbove(rest: stripRestFrame(lane), height: listStripMetrics(lane).height, bounds: screenFrame)
        listSideHeld[lane] = expandedStrip == lane ? above : nil
        return above
    }
    // Where the pill is on the display right now, open or resting.
    func stripPillFrame(_ lane: Lane) -> CGRect {
        let rest = stripRestFrame(lane), frame = stripFrame(lane)
        guard frame != rest, stripUsesList(lane) else { return rest }
        let height = max(rest.height, 32 * WindowStripMetrics.clamped(settings.windowStripScale))
        return CGRect(x: rest.minX, y: StripPlacementGeometry.pillTop(strip: frame, pillHeight: height, above: stripListOpensAbove(lane)), width: rest.width, height: height)
    }
    func moveStrip(_ lane: Lane, to frame: CGRect) {
        // Save where the resting strip sits; an expanded strip shares its left edge,
        // and its top edge, or its bottom edge when its list is open above the pill.
        let idle = stripMetrics(lane)
        let above = expandedStrip == lane && stripListOpensAbove(lane)
        let rest = CGRect(x: frame.minX, y: above ? frame.maxY - idle.height : frame.minY, width: idle.width, height: idle.height)
        saveStripRestPosition(lane, at: rest)
    }
    func saveStripRestPosition(_ lane: Lane, at rest: CGRect) {
        let position = StripPlacementGeometry.position(of: rest, in: rawLaneFrame(lane))
        settings.stripPositions[lane.rawValue] = position.isNearCategory ? position : nil
        settings.keepSpaceLayout()
        // In its new place the list may open on the other side.
        listSideHeld[lane] = nil
        // A strip that had opened to the left now opens to the right from where it was dropped.
        if pinnedStripLeft.removeValue(forKey: lane) != nil { pinnedStripOrigin[lane] = nil }
        save(); onLaneControls?()
    }
    func resetStripPosition(_ lane: Lane? = nil) {
        if let lane { settings.stripPositions.removeValue(forKey: lane.rawValue) } else { settings.stripPositions.removeAll() }
        settings.keepSpaceLayout()
        save(); onLaneControls?()
        status = lane.map { "\(name($0)) strip moved back to the top edge." } ?? "Strips moved back to the top edge of each category."
    }
    func setStripPlacement(_ placement: StripPlacement) {
        settings.stripPlacement = placement
        stripAppearanceChanged(retile: true)   // a band above the windows takes room from them
        status = placement == .onWindows ? "Strips sit on the windows. Windows use the full height of each category." : "Strips sit in a band above each category."
    }
    // Left, middle or right of each category's top edge. Dragged strips stay where they are.
    func setStripAlignment(_ alignment: StripAlignment?) {
        settings.stripAlignment = alignment
        pinnedStripOrigin.removeAll(); pinnedStripLeft.removeAll()
        stripAppearanceChanged()
        status = "Strip alignment saved."
    }
    func setStripExpansion(_ expansion: StripExpansion) {
        settings.stripExpansion = expansion
        stripAppearanceChanged()
    }
    // The panel's size right now. Layout and reserved space always use the
    // idle size, so hovering never moves a window.
    // Closing tabs with the pointer on a strip: tabs keep this width, so the next × lands
    // under the cursor, and the bar's right end shrinks in around them at once. Released
    // when the strip closes.
    @Published private(set) var frozenTabWidth: [Lane: Double] = [:]
    // On a narrow tile only some tabs fit. While tabs are frozen the run of tabs
    // shown starts at this one, so closing a tab slides the next one into its place
    // instead of re-centering the run on whichever window shows next.
    private(set) var frozenTabStart: [Lane: String] = [:]
    func freezeTabs(_ lane: Lane, width: Double, closing: String? = nil) {
        if let closing, let start = stripTabs(lane).tabs.first(where: { $0.id != closing && !closingWindowIDs.contains($0.id) }) { frozenTabStart[lane] = start.id }
        if frozenTabWidth[lane] == nil { frozenTabWidth[lane] = width }
    }
    func releaseTabs(_ lane: Lane) { frozenTabStart[lane] = nil; if frozenTabWidth[lane] != nil { frozenTabWidth[lane] = nil } }
    // The tabs an open tab strip draws and how wide each is: as many whole tabs as
    // fit between the pill (dot, name, count, pane chooser) and the counter, around
    // the active window. The counter's arrows step through the rest.
    func stripTabs(_ lane: Lane) -> (tabs: [ManagedWindow], width: Double) {
        let all = items(lane), open = stripItems(lane)
        let room = openTabStripMetrics(lane).width - stripChipRoom(lane)
        let fit = WindowStripMetrics.tabFit(room: room, count: open.count, scale: WindowStripMetrics.clamped(settings.windowStripScale), frozen: frozenTabWidth[lane],
                                            fit: settings.stripFitsWindowWidth && settings.stripStyle(lane).expandsOnHover)
        guard fit.shown > 0 else { return ([], 0) }
        let active = activeWindow(lane)?.id
        let held = frozenTabStart[lane].flatMap { id in open.firstIndex { $0.id == id } }
        let run = Layout.tabRun(total: open.count, active: open.firstIndex { $0.id == active } ?? all.firstIndex { $0.id == active }.map { min($0, open.count - 1) }, limit: fit.shown, heldStart: held)
        guard var lower = all.firstIndex(where: { $0.id == open[run.lowerBound].id }), var upper = all.firstIndex(where: { $0.id == open[run.upperBound - 1].id }) else { return ([], fit.width) }
        // Tabs folding away stay in the row until their windows are gone, so their neighbours slide into place.
        while lower > 0, closingWindowIDs.contains(all[lower - 1].id) { lower -= 1 }
        while upper < all.count - 1, closingWindowIDs.contains(all[upper + 1].id) { upper += 1 }
        return (Array(all[lower...upper]), fit.width)
    }
    func displayedStripMetrics(_ lane: Lane) -> WindowStripMetrics {
        guard settings.stripStyle(lane).expandsOnHover, expandedStrip == lane else { return stripMetrics(lane) }
        if stripUsesList(lane) { return listStripMetrics(lane) }
        return openTabStripMetrics(lane)
    }
    // The open tab strip's size, whether or not it is open now: an Expand-on-hover
    // strip lays its tabs out once, for the open strip, and only reveals them.
    func openTabStripMetrics(_ lane: Lane) -> WindowStripMetrics {
        guard settings.stripStyle(lane).expandsOnHover else { return stripMetrics(lane) }
        let count = stripCount(lane), width = rawLaneFrame(lane).width, slots = settings.capacity(lane)
        var metrics = WindowStripMetrics.measure(style: .detailed, count: count, scale: settings.windowStripScale, availableWidth: width, slots: slots, pill: stripPillWidth(lane))
        // A fitted bar spans its part of the grid slot whatever its tabs need, and
        // keeps that width while tabs close (they hold theirs until the pointer leaves).
        if settings.stripFitsWindowWidth { metrics.width = fittedStripFrame(lane).width; return metrics }
        if let frozen = frozenTabWidth[lane] {
            metrics.width = min(metrics.width, stripChipRoom(lane) + Double(max(1, count)) * frozen)
        }
        return metrics
    }
    func stripUsesList(_ lane: Lane) -> Bool {
        guard settings.stripStyle(lane).expandsOnHover, stripCount(lane) > 1 else { return false }
        switch settings.stripList(lane) {
        case .always: return true
        case .never: return false
        case .narrow:
            let width = settings.stripFitsWindowWidth ? fittedStripFrame(lane).width : rawLaneFrame(lane).width
            return WindowStripMetrics.usesList(count: stripCount(lane), scale: settings.windowStripScale, availableWidth: width,
                                               slots: settings.capacity(lane), fit: settings.stripFitsWindowWidth)
        }
    }
    // Grows at once; shrinks a moment after the mouse leaves, so crossing the
    // edge of the growing strip cannot make it flicker.
    // Closing a tab makes the resting strip narrower, and re-centering it would slide
    // every tab out from under the cursor. While the pointer is on the strip its left
    // edge stays put; it re-centers once the pointer leaves.
    private(set) var pinnedStripOrigin: [Lane: CGPoint] = [:]
    // The same for a strip that opened to the left (aligned right): the open strip's
    // left end is what holds still, since its tabs are laid out from there.
    private(set) var pinnedStripLeft: [Lane: Double] = [:]
    func pinStrip(_ lane: Lane) {
        guard pinnedStripOrigin[lane] == nil else { return }
        if expandedStrip == lane, stripOpensLeftward(lane), !stripFitsWidth(lane) { pinnedStripLeft[lane] = stripFrame(lane).minX }
        pinnedStripOrigin[lane] = stripRestFrame(lane).origin
    }
    func stripHovered(_ lane: Lane, _ hovering: Bool) {
        StripTrace.log("hover \(hovering ? "in" : "out"): \(name(lane)) (expanded: \(expandedStrip.map(name) ?? "none"))")
        if hovering {
            collapseStrip?.cancel(); collapseStrip = nil
            guard settings.stripStyle(lane).expandsOnHover, expandedStrip != lane else { return }
            let previous = expandedStrip
            listSideHeld[lane] = nil   // chosen afresh each time the list opens
            expandedStrip = lane
            if let onStripResized { onStripResized([lane] + (previous.map { [$0] } ?? [])) } else { onLaneControls?() }
            return
        }
        guard expandedStrip == lane, draggedTabLane != lane else {
            // A strip that does not grow on hover re-centers as soon as the pointer leaves.
            releaseTabs(lane)
            pinnedStripLeft[lane] = nil
            if draggedTabLane != lane, pinnedStripOrigin.removeValue(forKey: lane) != nil {
                if let resized = onStripResized { resized([lane]) } else { onLaneControls?() }
            }
            return
        }
        collapseStrip?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.expandedStrip == lane, self.hoveredLane != lane, self.draggedTabLane != lane else { return }
            StripTrace.log("collapse: \(self.name(lane))")
            self.expandedStrip = nil
            self.pinnedStripOrigin[lane] = nil; self.pinnedStripLeft[lane] = nil
            self.releaseTabs(lane)
            if let resized = self.onStripResized { resized([lane]) } else { self.onLaneControls?() }
        }
        collapseStrip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    // A strip look (style, hover view, size) changes only the strips: windows
    // never move or resize. A strip that is open under the mouse or under its own
    // menu closes, so the new idle look shows at once, not after the next hover.
    func stripAppearanceChanged(retile: Bool = false) {
        save()
        if retile && trusted && canUndo && stripsBelongHere && !busy {
            for lane in enabledLanes { _ = apply(lane, raiseWindows: false) }
        }
        collapseStrip?.cancel(); collapseStrip = nil
        expandedStrip = nil
        pinnedStripLeft.removeAll()
        if let onStripAppearanceChanged { onStripAppearanceChanged() } else { onLaneControls?() }
        status = "Strip look saved."
    }
    // One category's own look from Preferences. nil: follow the look for all strips.
    func setStripStyle(_ style: WindowStripStyle?, for lane: Lane) { settings.setStripStyle(style, for: lane); stripAppearanceChanged() }
    func setStripList(_ list: StripListMode?, for lane: Lane) { settings.setStripList(list, for: lane); stripAppearanceChanged() }
    // false: macOS refused the shortcut (another app has it), so the old one stays.
    func setOpenShortcut(_ shortcut: KeyShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        if let onOpenShortcut, !onOpenShortcut(shortcut) { return false }
        settings.openShortcut = shortcut; save()
        status = "Open Lanes is now \(shortcut.symbols)."
        return true
    }
    func activeWindow(_ lane: Lane) -> ManagedWindow? {
        let slots = slotIDs(lane), index = activeSlot[lane] ?? 0
        if slots.indices.contains(index), let window = items(lane).first(where: { $0.id == slots[index] }) { return window }
        return items(lane).first(where: { $0.id == activeIDs[lane] && !$0.minimized }) ?? visibleItems(lane).first
    }
    // Tabs folding away are already gone as far as numbers and counts go.
    func stripItems(_ lane: Lane) -> [ManagedWindow] {
        closingWindowIDs.isEmpty ? items(lane) : items(lane).filter { !closingWindowIDs.contains($0.id) }
    }
    func windowCounter(_ lane: Lane) -> String {
        let all = stripItems(lane)
        guard let window = activeWindow(lane), let index = all.firstIndex(where: { $0.id == window.id }) else { return "0/0" }
        return "\(index + 1)/\(all.count)"
    }
    func capture(_ window: ManagedWindow) {
        guard let scope = restoreScope else { return }
        if hiddenAppSnapshot[window.pid] == nil { hiddenAppSnapshot[window.pid] = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false }
        if self[saved: window.id] == nil {
            // Discovery already read the original frame. Preserve it even if a
            // fresh AX read temporarily fails immediately before moving it.
            let frame = axFrame(window.element) ?? window.frame
            let minimized = (axValue(window.element, kAXMinimizedAttribute) as? Bool) ?? window.minimized
            self[saved: window.id] = SavedWindow(element: window.element, frame: frame, minimized: minimized, pid: window.pid,
                                                 bundleID: window.bundleID, spaceNumber: currentSpaceNumber)
        }
        restoredScopes.remove(scope)
        noteOrganizedHere()
    }
    func noteOrganizedHere() { if desktopAvailable, let key = desktopArrangementKey { organizedDesktops.insert(key) } }
    // Track all input for focus, and hardware input separately for layout changes.
    func noteInput(_ event: NSEvent) {
        guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .leftMouseDown: input.pointer(held: true, sourcePID: source, at: now)
        case .leftMouseUp: input.pointer(held: false, sourcePID: source, at: now)
        case .leftMouseDragged: input.pointer(held: nil, sourcePID: source, at: now)
        case .rightMouseDown, .otherMouseDown:
            input.press(sourcePID: source, at: now, mouseDown: true)
            input.pointer(held: nil, sourcePID: source, at: now)
        case .keyDown: input.key(modified: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty, sourcePID: source, at: now)
        default: break
        }
    }
    // A window moved or resized. If you did it, it counts (and may join the
    // category it now fills). Anything else, such as a computer-use agent or the
    // app itself, is put back into its tile once the moves settle.
    func windowChanged(_ element: AXUIElement) {
        guard trusted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let at = lanesMovedAt[CFHash(element)], now - at < 1.0 { return }
        if let moved = lanesMovedFrames[CFHash(element)], let current = axFrame(element), TabSwitch.sameSpot(moved, current) { return }
        guard let window = (windows + outsideGrid).first(where: { CFEqual($0.element, element) }) else { return }
        let screen = NSScreen.screens.first, location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: (screen?.frame.height ?? 0) - location.y)
        let onWindow = [window.frame, axFrame(element) ?? window.frame].contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
        let menuBar = (screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 30) + 4
        let inItsMenuBar = point.y < menuBar && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        windowChanged(window.id, userActive: input.causedMove(at: now, buttonDown: NSEvent.pressedMouseButtons != 0, pointerOnWindow: onWindow, pointerInItsMenuBar: inItsMenuBar), at: now)
    }
    func windowChanged(_ id: String, userActive: Bool, at now: Double) {
        if userActive { userMoved.insert(id); guardPending.removeValue(forKey: id)?.cancel(); return }
        guard guards(id), now >= guardPausedUntil else { return }
        schedulePutBack(id, after: 0.4)
    }
    func guards(_ id: String) -> Bool {
        settings.keepLayout && canUndo && stripsBelongHere && !busy && !editingDraft && draggingStrip == nil && managedIDs.contains(id) && windows.contains { $0.id == id && !$0.minimized }
    }
    private func schedulePutBack(_ id: String, after delay: Double) {
        guardPending[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.putBack(id) } }
        guardPending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    // Where Organize keeps this window: its pane, or its queue tile behind it.
    func expectedFrame(_ window: ManagedWindow) -> CGRect? {
        let lane = window.lane
        let frame = laneFrame(lane)
        let plan = Layout.stack(ids: items(lane).map(\.id), foreground: slotIDs(lane), in: frame, gap: settings.gap, lane: lane,
                                split: settings.split(lane), slotCount: settings.capacity(lane), sizes: settings.paneSizes(lane, in: frame))
        return plan.frames[window.id]
    }
    func putBack(_ id: String) {
        guardPending[id] = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard trusted, guards(id), now >= guardPausedUntil, let window = windows.first(where: { $0.id == id }), let target = expectedFrame(window) else { return }
        // Mid-drag, wait until you let go; your drag then decides.
        if input.dragging(buttonDown: NSEvent.pressedMouseButtons != 0) { schedulePutBack(id, after: 0.4); return }
        if axBool(window.element, "AXFullScreen") {
            // Leaving full screen animates; finish once it has.
            _ = AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, kCFBooleanFalse)
            schedulePutBack(id, after: 1.0); return
        }
        // Fixed-size windows that already fit must not enter a resize loop.
        guard let current = axFrame(window.element), !WindowPlacement.fits(current, in: target) else { return }
        if move(window.element, to: target) {
            if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].frame = target }
            putBackCount += 1
            status = "Put \(windowLabel(window)) back in \(name(window.lane)). Only your own mouse and keyboard rearrange windows."
        }
    }
    @discardableResult func movePreservingOriginal(_ window: ManagedWindow, to frame: CGRect) -> Bool {
        guard windowCanMoveHere(window.element) else { return false }
        capture(window)
        return move(window.element, to: frame, verifyDesktop: false)
    }
    @discardableResult func move(_ element: AXUIElement, to frame: CGRect, verifyDesktop: Bool = true) -> Bool {
        guard !verifyDesktop || windowCanMoveHere(element) else { return false }
        lanesMovedAt[CFHash(element)] = ProcessInfo.processInfo.systemUptime
        var position = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { return false }
        // An app with enhanced accessibility on (other automation tools switch it
        // on) animates every move, and macOS drops the resize mid-slide. Switch it
        // off for the move and back on after, like other window managers do.
        var pid: pid_t = 0
        let app = AXUIElementGetPid(element, &pid) == .success ? AXUIElementCreateApplication(pid) : nil
        let enhanced = app.map { axBool($0, "AXEnhancedUserInterface") } ?? false
        if enhanced, let app { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced, let app { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        // Two passes accommodate windows that clamp their origin when resizing.
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        let positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        guard positionResult == .success, let actual = axFrame(element) else { return false }
        // A fixed-size window is allowed if it fits inside the requested tile.
        lanesMovedFrames[CFHash(element)] = actual
        return WindowPlacement.fits(actual, in: frame)
    }
    // Auto-sort: the grid Organize chooses for the windows that are open, on this display.
    var autoSortOrder: [Lane] { [.terminal, .simulator, .browser, .desktop, .preview] + enabledLanes.filter(\.isCustom) + [.messaging, .media] }
    func autoSortPlan(focused: Lane?, minimums: [Lane: CGSize] = [:]) -> AutoSortPlan {
        let populated = autoSortOrder.filter { !items($0).isEmpty }
        return AutoSorter.plan(items: populated.map { AutoSortItem(lane: $0, count: items($0).count, requiredSize: minimums[$0], isFocused: $0 == focused, stripInset: settings.stripReservesSpace ? stripReservedHeight($0) : 0) }, screen: screenFrame, gap: settings.gap)
    }
    func applyAutoSort(_ plan: AutoSortPlan) {
        settings.customRects = plan.rects; settings.floatingLanes = plan.floating; settings.useCustomGrid = false
        // Auto-sort picks each count for the split Lanes picks itself, so a chosen split goes with it.
        for (lane, capacity) in plan.capacities { settings.capacities[lane] = capacity; settings.windowSplits[lane] = nil; if let category = Lane(rawValue: lane) { pages[category] = 0 } }
    }
    func autoOrganize(hideBoard: Bool = true, forceAutoLayout: Bool = false) {
        guard !busy, !editingDraft else { return }
        syncDesktops()
        guard desktopAvailable else { status = "Switch to a desktop in Mission Control to organize it."; return }
        guard trusted else { status = "Enable window control to arrange your apps."; return }
        let stay = startedInBoard
        let working = rememberWorkingWindow()
        guard commitPendingGrid() else { return }
        let previousSelections = Array(activeIDs.values)
        refresh(silent: true, restorePopulatedCategories: forceAutoLayout || !settings.useCustomGrid)
        guard trusted else { status = "macOS has not recognized window access for this Lanes build. Open Access help to repair its permission entry."; return }
        guard !windows.isEmpty else { status = "No movable windows found on this display. Check the display selector or turn off display filtering."; return }
        let workingWindow = working.flatMap { id in windows.first { $0.id == id } }
        for id in previousSelections {
            if let window = windows.first(where: { $0.id == id }) { activeIDs[window.lane] = id }
        }
        if let workingWindow { activeIDs[workingWindow.lane] = workingWindow.id }
        let populated = autoSortOrder.filter { !items($0).isEmpty }
        for lane in populated {
            let saved = WindowSlots.normalized(visibleSlotIDs[lane] ?? [], ids: items(lane).map(\.id), capacity: settings.capacity(lane))
            visibleSlotIDs[lane] = activeIDs[lane].map { WindowSlots.replacing(saved, with: $0, at: activeSlot[lane] ?? 0) } ?? saved
        }
        if settings.useCustomGrid && !forceAutoLayout {
            for lane in enabledLanes { pages[lane] = 0 }
            arrange(hideBoard: hideBoard)
            if stay { onKeepBoard?() } else if let workingWindow { focus(workingWindow, hideBoard: false) }
            status = "Organized into your custom grid. Your category sizes and window strip styles are kept."
            return
        }
        observedMinimumSizes = [:]
        rememberLayout(); applyAutoSort(autoSortPlan(focused: workingWindow?.lane))
        save(); refreshRunningApps(); arrange(hideBoard: hideBoard)
        // If an app clamps its size, give the measured minimum more weight and
        // choose the grid again rather than leaving an oversized window overlapping.
        if !observedMinimumSizes.isEmpty {
            let adjusted = autoSortPlan(focused: workingWindow?.lane, minimums: observedMinimumSizes)
            settings.customRects = adjusted.rects; settings.floatingLanes = adjusted.floating
            for (id, capacity) in adjusted.capacities { settings.capacities[id] = capacity; settings.windowSplits[id] = nil }
            save(); arrange(hideBoard: hideBoard)
        }
        if stay { onKeepBoard?() } else if let workingWindow { focus(workingWindow, hideBoard: false) }
        status = "Auto-sort · " + status + " Hover a category strip to scroll, use Left/Right, or select with 1–9 / 0."
    }
    // A preset shown on the grid in the Lanes window without touching the screen.
    // Apply uses it; Cancel or choosing another preset leaves everything as it was.
    struct PresetPreview: Equatable {
        let name: String
        let lanes: [Lane]
        let rects: [String: ZoneRect]
        let savedID: String?
        let shape: PresetShape?
        var floating: [String] = []
    }
    @Published var presetPreview: PresetPreview?
    // The grid a preset would give the categories in use.
    func presetLayout(_ shape: PresetShape) -> (rects: [String: ZoneRect], floating: [String]) {
        let lanes = gridLanes
        let counts = Dictionary(uniqueKeysWithValues: lanes.map { ($0, items($0).count) })
        let main = lanes.contains(selectedLane) ? selectedLane : baseGridLanes.first ?? lanes.first ?? .terminal
        if shape == .overlay {
            // Browser fills the screen when it is in the grid; the rest float over it.
            let main = lanes.contains(.browser) ? Lane.browser : main
            return (shape.rects(lanes: lanes, main: main, windows: counts), shape.floating(lanes: lanes, main: main))
        }
        // Other presets arrange the grid and leave floating categories where they are.
        let base = baseGridLanes.isEmpty ? lanes : baseGridLanes
        let kept = base.count == lanes.count ? [:] : floatingRects()
        let rects = shape.rects(lanes: base, main: base.contains(main) ? main : base[0], windows: counts).merging(kept) { grid, _ in grid }
        return (rects, kept.isEmpty ? [] : grid.floatingLanes)
    }
    func previewPreset(_ shape: PresetShape) {
        let layout = presetLayout(shape)
        presetPreview = PresetPreview(name: shape.title, lanes: gridLanes, rects: layout.rects, savedID: nil, shape: shape, floating: layout.floating)
    }
    // A preset is offered only when every category it lays out is wide enough to
    // use, even with one window (Columns on a MacBook with many categories is not).
    func presetFits(_ shape: PresetShape) -> Bool {
        let rects = presetLayout(shape).rects
        return gridLanes.allSatisfy { lane in
            guard let unit = rects[lane.rawValue]?.cgRect else { return true }
            return Layout.frame(unit: unit, in: screenFrame, gap: settings.gap).width >= AutoSorter.usableSize(lane).width
        }
    }
    // After a preset: each category shows only as many windows side by side as fit
    // its new size. Window counts only go down, and only when they would not fit.
    func fitWindowCounts(_ lanes: [Lane]) {
        for lane in lanes where enabledLanes.contains(lane) {
            let current = settings.capacity(lane)
            let fitting = AutoSorter.fittingCount(lane, limit: current, frame: laneFrame(lane), gap: settings.gap, split: settings.split(lane))
            if fitting < current { settings.capacities[lane.rawValue] = fitting }
        }
    }
    func previewSavedLayout(_ layout: SavedGridLayout) {
        presetPreview = PresetPreview(name: layout.name, lanes: layout.lanes.compactMap(Lane.init(rawValue:)), rects: layout.rects, savedID: layout.id, shape: nil, floating: layout.floating ?? [])
    }
    // The presets that suit the display the grid is for.
    var presetShapes: [PresetShape] {
        let shapes = PresetShape.shapes(for: DisplayKind.of(screenFrame.size))
        let fitting = shapes.filter(presetFits)
        return fitting.isEmpty ? shapes : fitting   // never an empty preset row
    }
    func applyPresetPreview() { applyDisplayedGrid() }
    func applyDisplayedGrid(organizeUnchanged: Bool = false) {
        let requested = shownDesktop
        syncDesktops()
        // The button applies the layout the editor was displaying when pressed.
        if let requested, shownDesktop != requested {
            guard desktops.contains(where: { $0.id == requested }) else { return }
            selectEditorDesktop(requested)
        }
        if viewingOtherDesktop {
            if hasGridEdits || presetPreview != nil || organizeUnchanged { saveShownDesktop() }
            return
        }
        guard hasGridEdits || presetPreview != nil || organizeUnchanged, commitPendingGrid() else { return }
        if trusted { arrange(hideBoard: false) }
        else { status = "Grid saved. Enable window control to arrange your apps." }
    }
    func organizeFromBoard() {
        let requested = shownDesktop
        if viewingOtherDesktop { applyDisplayedGrid(organizeUnchanged: true); return }
        syncDesktops()
        guard requested == nil || requested == activeDesktop else {
            status = "Desktop changed. Click Organize on the desktop you want to arrange."
            return
        }
        autoOrganize()
    }
    // Every Apply/Organize entry point commits the same visible grid first.
    // Merely previewing a preset retains the draft underneath it for Cancel.
    @discardableResult func commitPendingGrid() -> Bool {
        // Another desktop's grid is in the editor: Apply saves it for that desktop
        // (saveShownDesktop); Organize arranges this desktop with its own grid.
        if viewingOtherDesktop { return true }
        let preview = presetPreview
        guard previewAccepted(preview) else { return false }
        // An applied grid belongs to the desktop you are on.
        let applying = preview != nil || gridDraft != nil
        defer { if applying { settings.keepSpaceLayout(); save() } }
        commitGridDraft()
        guard let preview else { return true }
        presetPreview = nil
        applyPreset(preview)
        return true
    }
    private func previewAccepted(_ preview: PresetPreview?) -> Bool {
        guard let preview else { return true }
        guard GridGeometry.valid(preview.rects, lanes: preview.lanes, floating: Set(preview.floating)) else {
            status = "This preset does not fit your categories."; return false
        }
        if let id = preview.savedID, !settings.savedLayouts.contains(where: { $0.id == id }) {
            status = "This preset is no longer available."; return false
        }
        return true
    }
    private func applyPreset(_ preview: PresetPreview) {
        if let id = preview.savedID, let layout = settings.savedLayouts.first(where: { $0.id == id }) {
            loadGridLayout(layout)
        } else {
            settings.previousLayout = currentGridLayout(name: "Previous layout")
            let before = layoutRects()
            rememberLayout(); settings.customRects = preview.rects; settings.floatingLanes = preview.floating
            if preview.shape != nil { fitWindowCounts(preview.lanes) }
            recenterMovedStrips(changedFrom: before)
            layoutChanged("\(preview.name) applied.")
        }
    }
    // The tour of the Lanes window: shown once on first launch, and again on request.
    @Published var tourStep: Int?
    private(set) var tourSteps: [TourStep] = []
    private var tourRequestedAfterAccessHelp = false
    func prepareOnboarding() {
        if !settings.hasSeenTour { startTour() }
        else if !trusted { showAccessHelp = true }
    }
    func accessHelpDismissed() {
        if tourRequestedAfterAccessHelp || (!settings.hasSeenTour && tourStep == nil) { startTour() }
    }
    func startTour() {
        guard !showAccessHelp else { tourRequestedAfterAccessHelp = true; return }
        tourRequestedAfterAccessHelp = false
        tourSteps = TourGuide.steps(trusted: trusted, openShortcut: settings.openShortcut)
        tourStep = 0
    }
    func endTour() {
        tourStep = nil
        settings.hasSeenTour = true
        save()
    }
    @discardableResult func setShowInDock(_ show: Bool) -> Bool {
        guard show != settings.showInDock else { return true }
        if let onSetDockVisibility, !onSetDockVisibility(show) { return false }
        settings.showInDock = show
        save()
        return true
    }
    // Open at login uses macOS's own login items (System Settings › General › Login Items).
    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            status = on ? "Lanes opens when you log in." : "Lanes no longer opens at login."
        } catch {
            status = "macOS did not change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
    // The login item follows the bundle it was registered from, even after that
    // bundle is moved into a backup folder. Re-register from /Applications once
    // per new location so login always opens the installed copy.
    func repairLoginItemLocation() {
        let path = Bundle.main.bundlePath, key = "loginItemBundlePath"
        guard Bundle.main.bundleIdentifier == "com.lanes-mac.Lanes", path.hasPrefix("/Applications/"),
              SMAppService.mainApp.status == .enabled, UserDefaults.standard.string(forKey: key) != path else { return }
        try? SMAppService.mainApp.unregister()
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(path, forKey: key) }
    }
    func recordPermissionState() {
        guard Bundle.main.bundleIdentifier == "com.lanes-mac.Lanes" else { return }
        guard lastRecordedTrust != trusted else { return }
        lastRecordedTrust = trusted
        let state: [String: Any] = ["trusted": trusted, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test", "executable": Bundle.main.executableURL?.path ?? "", "checkedAt": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: settingsURL.deletingLastPathComponent().appendingPathComponent("window-access-state.json"), options: .atomic)
    }
    func arrange(hideBoard: Bool = true) {
        guard !editingDraft, !busy else { return }
        syncDesktops()
        guard desktopAvailable else { status = "Switch to a desktop in Mission Control to organize it."; return }
        guard trusted else { status = "Enable window control to arrange your apps."; return }
        guard commitPendingGrid() else { return }
        let stay = startedInBoard
        let working = rememberWorkingWindow()
        cancelFocus()
        busy = true
        refresh(silent: true)
        if windows.isEmpty { status = "No movable windows on this desktop. Open some apps, then refresh."; busy = false; return }
        settings.keepSpaceLayout()
        save()
        var constrained = 0, failed = 0
        let order = enabledLanes.filter { !settings.isFloating($0) } + enabledLanes.filter { settings.isFloating($0) }
        for lane in order {
            let outcome = apply(lane, raiseWindows: false)
            constrained += outcome.constrained; failed += outcome.failed
        }
        let cleared = centerStrays()
        selectedTemplateChanged = false
        lastSignature = windows.map { "\($0.id):\($0.lane.rawValue)" }.sorted().joined(separator: ",")
        status = "Desktop arranged · \(windows.count) windows in \(enabledLanes.count) lanes."
        if cleared > 0 { status += " \(cleared) windows without a category moved to the middle." }
        if constrained > 0 { status += " \(constrained) tiles exceed app minimum sizes; use fewer tiles or widen a lane." }
        if failed > 0 { status += " \(failed) windows could not be positioned." }
        for lane in order {
            for window in visibleItems(lane) {
                if windowCanMoveHere(window.element) { _ = focusAccess.raise(window) }
            }
        }
        busy = false
        onLaneControls?()
        if stay { onKeepBoard?() }
        else if let working, let window = windows.first(where: { $0.id == working }) { focus(window, hideBoard: false) }
    }
    func apply(_ lane: Lane, presentationOnly: Bool = false, raiseWindows: Bool = true, onlyIDs: Set<String>? = nil) -> (constrained: Int, failed: Int) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { SlowLog.note("arrange \(name(lane))\(onlyIDs.map { " (\($0.count) window)" } ?? "")", since: started) }
        guard !editingDraft, desktopAvailable else { return (0, 0) }
        let all = items(lane).filter { !$0.minimized }, visible = visibleItems(lane)
        let slots = slotIDs(lane)
        if visibleSlotIDs[lane] != slots { visibleSlotIDs[lane] = slots }
        let ids = Set(visible.map(\.id))
        let frame = laneFrame(lane)
        let stack = Layout.stack(ids: all.map(\.id), foreground: slots, in: frame, gap: settings.gap, lane: lane, split: settings.split(lane),
                                 presentationOnly: presentationOnly, onlyIDs: onlyIDs, slotCount: settings.capacity(lane), sizes: settings.paneSizes(lane, in: frame))
        if !ids.contains(activeIDs[lane] ?? "") { activeIDs[lane] = visible.first?.id }
        guard trusted else { return (0, stack.raiseOrder.count) }
        var constrained = 0, failed = 0
        // Open queue members share a tile behind the selected window.
        // Explicitly minimized windows remain in the Dock until selected.
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var updated: [String: ManagedWindow] = [:]
        for id in stack.raiseOrder {
            guard let window = byID[id], let frame = stack.frames[id], windowCanMoveHere(window.element) else { continue }
            let app = NSRunningApplication(processIdentifier: window.pid)
            if app?.isHidden == true, let space = currentSpaceNumber, !appIsOnlyOnDesktop(window.pid, space: space) { continue }
            capture(window); managedIDs.insert(window.id)
            if app?.isHidden == true { app?.unhide() }
            let alreadySized = abs(window.frame.minX - frame.minX) < 2 && abs(window.frame.minY - frame.minY) < 2 && abs(window.frame.width - frame.width) < 2 && abs(window.frame.height - frame.height) < 2
            let positioned = alreadySized || move(window.element, to: frame, verifyDesktop: false)
            if !positioned {
                constrained += 1
                if let actual = axFrame(window.element), actual.width > frame.width + 12 || actual.height > frame.height + 12 {
                    let previous = observedMinimumSizes[lane] ?? AutoSorter.minimumSize(lane)
                    observedMinimumSizes[lane] = CGSize(width: max(previous.width, actual.width > frame.width + 12 ? actual.width : previous.width),
                        height: max(previous.height, actual.height > frame.height + 12 ? actual.height : previous.height))
                }
            }
            if positioned { var copy = window; copy.frame = frame; copy.minimized = false; updated[id] = copy }
            // Background windows are positioned without raising them. Switching
            // touches only the new foreground page; focus raises its chosen window.
            if raiseWindows && !presentationOnly && ids.contains(id) && AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) != .success { failed += 1 }
        }
        if !updated.isEmpty { windows = windows.map { updated[$0.id] ?? $0 } }
        return (constrained, failed)
    }
    func cycle(_ lane: Lane, delta: Int = 1) {
        cycleWindow(lane, delta: delta)
    }
    // Match the exact focused AX window, so two windows from the same browser
    // can be cycled or moved separately. Never guess from an app name.
    func focusedWindow() -> ManagedWindow? {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = axValue(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return windows.first { $0.pid == app.processIdentifier && CFEqual($0.element, focused) }
    }
    // The poll's version: the front app is asked off the main thread (a busy app made
    // the poll wait its full 0.2 s timeout), and the answer is recorded on the main thread.
    private func rememberWorkingWindowInBackground() {
        guard trusted, !busy else { return }
        if let pending = pendingFocus {
            if !input.interacted(since: pending.since), windows.contains(where: { $0.id == pending.id }) { return }
            cancelFocus()
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != getpid(), frontmost.activationPolicy == .regular {
            lastWorkingPID = frontmost.processIdentifier
        }
        guard let pid = lastWorkingPID else { return }
        Self.discoveryQueue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let focused = axValue(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
            let element = focused as! AXUIElement
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.trusted, !self.busy, self.pendingFocus == nil, self.lastWorkingPID == pid,
                          let window = self.windows.first(where: { $0.pid == pid && CFEqual($0.element, element) }) else { return }
                    self.recordWorkingSelection(window)
                }
            }
        }
    }
    @discardableResult func rememberWorkingWindow() -> String? {
        guard trusted, !busy else { return nil }
        // App activation can transiently report the wrong main window. Do not
        // turn that intermediate state into a selection in another category.
        if let pending = pendingFocus {
            if !input.interacted(since: pending.since), windows.contains(where: { $0.id == pending.id }) { return pending.id }
            cancelFocus()
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != getpid(), frontmost.activationPolicy == .regular {
            lastWorkingPID = frontmost.processIdentifier
        }
        guard let pid = lastWorkingPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focused = axValue(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let window = windows.first(where: { $0.pid == pid && CFEqual($0.element, focused) }) else { return nil }
        recordWorkingSelection(window)
        return window.id
    }
    // The tab each category showed for this app before it came forward, unless
    // you clicked one of its windows or Lanes itself brought it forward.
    // Read before the app's own front window is recorded as the selection.
    private func selectionsToRestore(for app: NSRunningApplication) -> [Lane: (selected: String, showing: [String])] {
        guard trusted, pendingFocus == nil, app.processIdentifier != getpid(), let bundle = app.bundleIdentifier else { return [:] }
        let now = ProcessInfo.processInfo.systemUptime
        let location = NSEvent.mouseLocation, mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let pointer = CGPoint(x: location.x, y: mainHeight - location.y)
        let onItsWindow = (windows + outsideGrid).contains { $0.bundleID == bundle && $0.frame.contains(pointer) }
        if input.clicked(within: 0.6, at: now) && onItsWindow { return [:] }
        var selected: [Lane: (selected: String, showing: [String])] = [:]
        for lane in enabledLanes {
            if let window = activeWindow(lane), window.bundleID == bundle { selected[lane] = (window.id, slotIDs(lane).filter { $0 != window.id }) }
        }
        return selected
    }
    private func restoreSelection(_ selected: [Lane: (selected: String, showing: [String])], after app: NSRunningApplication) {
        let start = ProcessInfo.processInfo.systemUptime
        let generation = focusGeneration
        // Let the app finish raising its own window first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.busy, self.pendingFocus == nil,
                      self.focusGeneration == generation, !self.input.interacted(since: start),
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleIdentifier,
                      let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                let element = AXUIElementCreateApplication(frontPID)
                guard let focused = axValue(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
                      let front = self.windows.first(where: { $0.pid == frontPID && CFEqual($0.element, focused as! AXUIElement) }),
                      let before = selected[front.lane], let window = self.windows.first(where: { $0.id == before.selected }) else { return }
                let clicked = self.input.clicked(within: 0.75, at: ProcessInfo.processInfo.systemUptime) && front.frame.contains({ let l = NSEvent.mouseLocation; return CGPoint(x: l.x, y: (NSScreen.screens.first?.frame.height ?? 0) - l.y) }())
                guard ActivationRestore.shouldRestore(front: front.id, selected: before.selected, visible: before.showing, clickedWindow: clicked, lanesAsked: false) else { return }
                // As a strip click would: the strip, its pane and the window agree.
                self.reveal(window)
                self.status = "\(self.name(window.lane)) · \(self.windowLabel(window)): the tab you were on."
            }
        }
    }
    func recordWorkingSelection(_ window: ManagedWindow) {
        guard enabledLanes.contains(window.lane) else { return }
        activeIDs[window.lane] = window.id
        var slots = slotIDs(window.lane)
        if !slots.contains(window.id) {
            let tiles = paneTiles(window.lane)
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let slot = tiles.firstIndex(where: { $0.contains(center) }) ?? activeSlot[window.lane] ?? 0
            slots = WindowSlots.replacing(slots, with: window.id, at: slot)
            visibleSlotIDs[window.lane] = slots
        }
        if hoveredLane != window.lane, let slot = slots.firstIndex(of: window.id) { activeSlot[window.lane] = slot }
    }
    func cycleWindow(_ lane: Lane, delta: Int = 1) {
        guard !settings.hiddenLanes.contains(lane.rawValue) else { status = "Restore \(name(lane)) in Preferences to use its shortcut."; return }
        if lane == .media && !settings.showMediaShelf { restoreCategory(.media); arrange(hideBoard: false) }
        if items(lane).isEmpty { refresh(silent: true) }
        let all = items(lane)
        guard trusted, !all.isEmpty else {
            status = trusted ? "No windows in \(name(lane))." : "Enable window control to use window shortcuts."
            return
        }
        if hoveredLane != lane, let focused = focusedWindow(), focused.lane == lane, let slot = slotIDs(lane).firstIndex(of: focused.id) { activeSlot[lane] = slot }
        guard let nextID = WindowSlots.nextID(ids: all.map(\.id), slots: slotIDs(lane), slot: activeSlot[lane] ?? 0, delta: delta), let next = all.first(where: { $0.id == nextID }) else { return }
        reveal(next)
        status = "\(name(lane)) · \(windowCounter(lane)) · \(windowLabel(next))"
    }
    func cycleFocused(delta: Int = 1) {
        refresh(silent: true)
        guard let window = focusedWindow() else {
            status = "Focus an app window, then cycle its category."
            return
        }
        cycleWindow(window.lane, delta: delta)
    }
    func sendFocused(to lane: Lane) {
        guard !settings.hiddenLanes.contains(lane.rawValue) else { status = "Restore \(name(lane)) in Preferences before sending windows there."; return }
        refresh(silent: true)
        guard let window = focusedWindow() else {
            status = "Focus an app window, then use the send-to-lane shortcut."
            return
        }
        let needsReflow = lane == .media && !settings.showMediaShelf
        capture(window)
        assign(window, to: lane)
        if needsReflow { arrange(hideBoard: false) }
        guard let reassigned = windows.first(where: { $0.id == window.id }) else { return }
        reveal(reassigned)
        status = "\(window.appName) moved and resized into \(name(lane))."
    }
    func adjustFocused(dx: CGFloat, dy: CGFloat, resize: Bool) {
        refresh(silent: true)
        guard let window = focusedWindow(), let frame = axFrame(window.element) else {
            status = "Focus an app window to move or resize it."
            return
        }
        capture(window)
        let adjusted = Layout.adjust(frame: frame, bounds: laneFrame(window.lane), dx: dx, dy: dy, resize: resize)
        if adjusted == frame { status = "At the lane boundary. Resize the window first to make room."; return }
        let moved = move(window.element, to: adjusted)
        status = moved ? "\(window.appName) \(resize ? "resized" : "moved") within \(name(window.lane))." : "This app enforces a minimum window size or prevents resizing."
        focus(window)
    }
    func minimizeWindow(_ requested: ManagedWindow) {
        guard !editingDraft, trusted else { status = "Enable window control to minimize windows."; return }
        guard let window = (windows + outsideGrid).first(where: { $0.id == requested.id }) else {
            status = "That window is no longer available."; return
        }
        cancelFocus()
        guard actionAccess.minimize(window) else { status = "\(window.appName) could not minimize this window."; return }
        guardPending.removeValue(forKey: window.id)?.cancel()
        if let index = windows.firstIndex(where: { $0.id == window.id }) { windows[index].minimized = true }
        if let index = outsideGrid.firstIndex(where: { $0.id == window.id }) { outsideGrid[index].minimized = true }
        // Restore/quit must respect a window the user deliberately minimized.
        self[saved: window.id]?.minimized = true
        visibleSlotIDs[window.lane] = slotIDs(window.lane)
        if activeIDs[window.lane] == window.id { activeIDs[window.lane] = visibleItems(window.lane).first?.id }
        onLaneControls?()
        status = "Minimized \(windowLabel(window)). Select its tab to show it again."
    }
    // True when the app was asked to close the window (it may still show a save dialog).
    @discardableResult func closeWindow(_ requested: ManagedWindow) -> Bool {
        guard !editingDraft, trusted else { status = "Enable window control to close windows."; return false }
        guard let window = (windows + outsideGrid).first(where: { $0.id == requested.id }) else {
            status = "That window is no longer available."; return false
        }
        cancelFocus()
        guard actionAccess.close(window) else { status = "\(window.appName) could not close this window."; return false }
        guardPending.removeValue(forKey: window.id)?.cancel()
        // A successful button press can open a save dialog. Let discovery remove
        // the entry only after the app actually destroys the window.
        windowClosed()
        status = "Asked \(window.appName) to close \(windowLabel(window))."
        return true
    }
    func reveal(_ requested: ManagedWindow) {
        guard !editingDraft else { return }
        let started = ProcessInfo.processInfo.systemUptime
        defer { StripTrace.log("tab picked: \(requested.appName) \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms on the main thread") }
        // A strip/menu may hold an older value after a category move or close.
        guard let window = windows.first(where: { $0.id == requested.id }), enabledLanes.contains(window.lane) else {
            status = "That window is no longer in the grid. Refresh to update the list."; return
        }
        // A held run of tabs follows a window you pick that is not one of the tabs shown.
        if frozenTabStart[window.lane] != nil, !stripTabs(window.lane).tabs.contains(where: { $0.id == window.id }) { frozenTabStart[window.lane] = nil }
        if window.minimized {
            guard trusted, actionAccess.restore(window) else {
                status = "Could not show this minimized window."; return
            }
            if let index = windows.firstIndex(where: { $0.id == window.id }) { windows[index].minimized = false }
            self[saved: window.id]?.minimized = false
        }
        let before = trusted ? showing().tops : [:]
        selectedLane = window.lane
        if hoveredLane != window.lane, let focused = focusedWindow(), focused.lane == window.lane, let slot = slotIDs(window.lane).firstIndex(of: focused.id) { activeSlot[window.lane] = slot }
        let oldSlots = slotIDs(window.lane)
        visibleSlotIDs[window.lane] = WindowSlots.replacing(oldSlots, with: window.id, at: activeSlot[window.lane] ?? 0)
        if trusted { _ = apply(window.lane, presentationOnly: true, onlyIDs: [window.id]) }
        focus(window, preserving: before)
        onLaneControls?()
    }
    func cancelFocus() {
        focusGeneration &+= 1
        focusConfirm?.cancel(); focusConfirm = nil; pendingFocus = nil
    }
    func focus(_ requested: ManagedWindow, hideBoard: Bool = true, preserving previous: [String: UInt32]? = nil) {
        guard !editingDraft, let window = windows.first(where: { $0.id == requested.id }), enabledLanes.contains(window.lane) else { return }
        cancelFocus()
        activeIDs[window.lane] = window.id
        if let slot = slotIDs(window.lane).firstIndex(of: window.id) { activeSlot[window.lane] = slot }
        selectedLane = window.lane
        guard trusted else { return }
        let before = previous ?? showing().tops
        let start = ProcessInfo.processInfo.systemUptime
        let generation = focusGeneration
        pendingFocus = (window.id, start)
        if window.minimized { focusAccess.unminimize(window) }
        focusAccess.prepare(window)
        _ = focusAccess.raise(window)
        if focusAccess.frontPID() != window.pid {
            _ = focusAccess.activate(window)
            _ = focusAccess.raise(window)
        }
        // Repair synchronous activation effects immediately, then check the
        // app's delayed main-window changes. Only covered panes are touched.
        reconcileFocus(window, showing: before)
        confirmFront(window, since: start, showing: before, generation: generation)
    }
    // A window keeps its window server number while it is open. Focus checks run
    // every 30 ms, so each window is asked for it once rather than every check.
    private var windowNumbers: [String: UInt32] = [:]
    private func number(_ window: ManagedWindow) -> UInt32? {
        if let known = windowNumbers[window.id] { return known }
        let found = focusAccess.windowID(window)
        if let found { windowNumbers[window.id] = found }
        return found
    }
    // The exact window server identity, rather than a PID/frame guess, tells
    // apart Arc windows and native tabs occupying identical rectangles.
    private func showing() -> (tops: [String: UInt32], known: [UInt32: ManagedWindow]) {
        var known: [UInt32: ManagedWindow] = [:]
        for window in windows + outsideGrid { if let id = number(window) { known[id] = window } }
        let stack = focusAccess.stack()
        var tops: [String: UInt32] = [:]
        for lane in enabledLanes {
            for (index, tile) in paneTiles(lane).enumerated() {
                // An unknown window on top is not skipped to find a managed one
                // behind it: alerts and newly opened apps must not be covered.
                let top = stack.first { window in
                    let shared = window.frame.intersection(tile)
                    return !shared.isNull && shared.width * shared.height >= tile.width * tile.height * 0.6
                }
                if let top, known[top.number] != nil { tops["\(lane.rawValue)#\(index)"] = top.number }
            }
        }
        return (tops, known)
    }
    private func reconcileFocus(_ window: ManagedWindow, showing before: [String: UInt32]) {
        guard focusAccess.frontPID() == window.pid, let wanted = number(window) else { return }
        let now = showing()
        let top = focusAccess.stack().first { $0.pid == window.pid }?.number
        if let top, now.known[top] == nil { return } // New windows and modal alerts win.
        let slot = slotIDs(window.lane).firstIndex(of: window.id) ?? activeSlot[window.lane] ?? 0
        let changing = "\(window.lane.rawValue)#\(slot)"
        let covered = FocusConfirm.covered(before: before, after: now.tops, wanted: wanted,
                                          sameApp: Set(now.known.filter { $0.value.pid == window.pid }.keys), excluding: [changing])
        for id in covered {
            if let back = now.known[id], !back.minimized { _ = focusAccess.raise(back) }
        }
        let repairedTop = focusAccess.stack().first { $0.pid == window.pid }?.number
        if !covered.isEmpty || FocusConfirm.shouldRaise(appInFront: true, topWindow: repairedTop, wanted: wanted, pressedSince: false) {
            _ = focusAccess.raise(window)
        }
    }
    private func confirmFront(_ window: ManagedWindow, since start: Double, showing before: [String: UInt32], generation: Int, check: Int = 0) {
        guard FocusConfirm.checks.indices.contains(check), number(window) != nil else { pendingFocus = nil; return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.focusGeneration == generation else { return }
            guard self.trusted, !self.editingDraft, !self.input.interacted(since: start),
                  let current = self.windows.first(where: { $0.id == window.id }), current.lane == window.lane,
                  self.enabledLanes.contains(current.lane) else { self.cancelFocus(); return }
            self.reconcileFocus(current, showing: before)
            self.confirmFront(current, since: start, showing: before, generation: generation, check: check + 1)
        } }
        focusConfirm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusConfirm.checks[check] - (check > 0 ? FocusConfirm.checks[check - 1] : 0), execute: work)
    }
    // `arrange: false` only records the category; the window moves at the next Organize.
    func moveWindow(_ requested: ManagedWindow, to lane: Lane, arrange arrangeNow: Bool = true) {
        syncDesktops()
        guard availableLanes.contains(lane), let window = (windows + outsideGrid).first(where: { $0.id == requested.id }) else { return }
        setWindowRule(window.id, to: lane)
        save()
        if !enabledLanes.contains(lane) || window.lane == lane {
            reclassifyInventory()
            onLaneControls?()
            status = "\(windowLabel(window)) assigned to \(name(lane))."
            return
        }
        // A window whose own category is shelved can still join any category.
        if enabledLanes.contains(lane), let outside = outsideGrid.firstIndex(where: { $0.id == window.id }) {
            var joined = outsideGrid.remove(at: outside); joined.lane = lane
            windows.append(joined)
            if arrangeNow && trusted && canUndo && stripsBelongHere && !busy { reveal(joined) }
            selectedLane = lane; onLaneControls?()
            status = "\(windowLabel(window)) moved to \(name(lane))."
            return
        }
        guard enabledLanes.contains(lane), let index = windows.firstIndex(where: { $0.id == window.id }), window.lane != lane else { return }
        let source = window.lane, previous = Set(slotIDs(source))
        windows[index].lane = lane
        if arrangeNow && trusted && canUndo && stripsBelongHere && !busy {
            let replacements = Set(slotIDs(source)).subtracting(previous).subtracting([""])
            _ = apply(source, presentationOnly: true, onlyIDs: replacements)
            for replacement in visibleItems(source) where replacements.contains(replacement.id) { _ = AXUIElementPerformAction(replacement.element, kAXRaiseAction as CFString) }
            reveal(windows[index])
        }
        selectedLane = lane; onLaneControls?()
        status = "\(windowLabel(window)) moved to \(name(lane))."
    }
    @discardableResult func splitCategory(_ source: Lane, sideBySide: Bool) -> Lane? {
        guard enabledLanes.contains(source) else { return nil }
        let rect = editorRect(source)
        var first = rect, second = rect
        if sideBySide { first.size.width /= 2; second.origin.x += first.width; second.size.width = first.width }
        else { first.size.height /= 2; second.origin.y += first.height; second.size.height = first.height }
        let base = name(source); var suffix = 2
        while availableLanes.contains(where: { name($0) == "\(base) \(suffix)" }) { suffix += 1 }
        let category = CustomCategory(name: "\(base) \(suffix)")
        var rects = layoutRects(); rects[source.rawValue] = ZoneRect(first); rects[category.id] = ZoneRect(second)
        // Halves of a floating category float too.
        var floating = Set(settings.floatingLanes)
        if floating.contains(source.rawValue) { floating.insert(category.id) }
        guard GridGeometry.valid(rects, lanes: enabledLanes + [category.lane], floating: floating) else { status = "This region is too small to split again."; return nil }
        let sourceWindows = items(source)
        let moved = visibleItems(source).dropFirst().first ?? sourceWindows.first(where: { $0.id != activeWindow(source)?.id })
        rememberLayout()
        settings.customCategories.append(category); settings.customRects = rects
        if settings.isFloating(source) { settings.floatingLanes.append(category.id) }
        settings.capacities[source.rawValue] = 1; settings.capacities[category.id] = 1; settings.windowSplits[source.rawValue] = nil
        settings.useCustomGrid = true
        if let moved, let index = windows.firstIndex(where: { $0.id == moved.id }) {
            setWindowRule(moved.id, to: category.lane)
            windows[index].lane = category.lane; visibleSlotIDs[category.lane] = [moved.id]
        }
        visibleSlotIDs[source] = WindowSlots.normalized(visibleSlotIDs[source] ?? [], ids: items(source).map(\.id), capacity: 1)
        selectedLane = category.lane; gridSelectionActive = true
        layoutChanged("\(base) split into two independent regions.")
        if trusted && canUndo && !busy { _ = apply(source); _ = apply(category.lane) }
        onLaneControls?()
        return category.lane
    }
    func assign(_ window: ManagedWindow, to lane: Lane, rememberApp: Bool = false) {
        guard availableLanes.contains(lane) else { return }
        if !rememberApp { moveWindow(window, to: lane); return }
        if lane == .media && !settings.showMediaShelf { restoreCategory(.media) }
        assignApp(RunningAppSummary(pid: window.pid, name: window.appName, bundleID: window.bundleID, icon: window.icon, lane: window.lane), to: lane)
    }
    func undo(fromBoard: Bool = false, restoring restoreWindow: ((SavedWindow) -> Bool)? = nil) {
        let requestedDesktop = fromBoard ? shownDesktop : nil
        syncDesktops()
        guard trusted else { status = "Enable window control to restore positions."; return }
        guard !busy, !editingDraft else { return }
        guard let scope = restoreScope, desktopArrangementKey != nil || !spacesAccess.tracksDesktops else {
            status = "Switch to a desktop in Mission Control to restore its windows."
            return
        }
        if let requestedDesktop, requestedDesktop != activeDesktop {
            status = "Switch to \(desktopName(requestedDesktop)) in Mission Control to restore its windows."
            return
        }
        guard canUndo else { status = "There are no saved window positions for this desktop."; return }
        busy = true
        defer { busy = false }
        stopRestoringLayout()
        var failures = 0
        var skipped = 0
        var retry: [String: SavedWindow] = [:]
        var restoredApps: Set<pid_t> = []
        for (id, saved) in snapshot where !isIgnored(saved.bundleID) {
            let belongs = belongsToRestoreScope(saved, scope: scope)
            guard saved.spaceNumber == currentSpaceNumber, belongs == true else {
                if belongs == nil { retry[id] = saved }
                skipped += 1
                continue
            }
            if (restoreWindow ?? putBackOriginal)(saved) { restoredApps.insert(saved.pid) }
            else { failures += 1; retry[id] = saved }
        }
        // On a Mission Control desktop, hiding an app could hide windows in
        // other Spaces. Only the window-level changes above run here.
        if case .display = scope {
            for pid in restoredApps where hiddenAppSnapshot[pid] == true {
                if let app = restorableApp(pid), app.isHidden || app.hide() { hiddenAppSnapshot[pid] = nil }
            }
        }
        restoreSnapshots[scope] = retry.isEmpty ? nil : retry
        managedByScope[scope] = nil
        let remainingApps = Set(restoreSnapshots.values.flatMap { $0.values.map(\.pid) })
        hiddenAppSnapshot = hiddenAppSnapshot.filter { $0.value || remainingApps.contains($0.key) }
        restoredScopes.insert(scope)
        if let key = desktopArrangementKey {
            organizedDesktops.remove(key)
            desktopSelections[key] = nil
        }
        desktopGeneration += 1
        backgroundRefreshFollowUps.removeAll()
        clearArrangementControls()
        refresh(silent: true)
        let desktop = desktopName(activeDesktop)
        let incomplete = skipped + failures
        let restored = "Restore finished on \(desktop)."
        if incomplete == 0 { status = "Restored original window positions on \(desktop)." }
        else if incomplete == 1 { status = "\(restored) One window was unavailable or could not be resized." }
        else { status = "\(restored) \(incomplete) windows were unavailable or could not be resized." }
    }
    // Candidates from this desktop. Check the Leave alone list even if it changed
    // without removing the app's snapshot.
    func restorable() -> [SavedWindow] { snapshot.values.filter { !isIgnored($0.bundleID) } }
    private func belongsToRestoreScope(_ saved: SavedWindow, scope: RestoreScope) -> Bool? {
        guard case .desktop = scope else { return true }
        guard let space = saved.spaceNumber, let number = spacesAccess.windowID(saved.element),
              let membership = spacesAccess.windowSpaces?(number) else { return nil }
        // Shared windows and windows moved to another desktop are out of scope.
        return membership == [space]
    }
    private func putBackOriginal(_ saved: SavedWindow) -> Bool {
        _ = AXUIElementSetAttributeValue(saved.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let moved = move(saved.element, to: saved.frame, verifyDesktop: false)
        _ = AXUIElementSetAttributeValue(saved.element, kAXMinimizedAttribute as CFString, saved.minimized ? kCFBooleanTrue : kCFBooleanFalse)
        return moved
    }
    private func restorableApp(_ pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !isIgnored(app.bundleIdentifier ?? "pid.\(pid)") else { return nil }
        return app
    }
    private func appIsOnlyOnDesktop(_ pid: pid_t, space: Int) -> Bool {
        // Hide affects the whole app. Include AX windows (even minimized ones)
        // and window-server entries (including those on other desktops).
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty,
              let serverWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let windowSpaces = spacesAccess.windowSpaces else { return false }
        let numbers = windows.compactMap(spacesAccess.windowID)
        guard numbers.count == windows.count else { return false }
        let otherNumbers = serverWindows.compactMap { info -> UInt32? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let level = info[kCGWindowLayer as String] as? Int, (0..<20).contains(level) else { return nil }
            return info[kCGWindowNumber as String] as? UInt32
        }
        return Set(numbers + otherNumbers).allSatisfy { windowSpaces($0) == [space] }
    }
    func restoreOnQuit(restoring restoreWindow: ((SavedWindow) -> Bool)? = nil) {
        guard trusted, !restoreSnapshots.isEmpty || hiddenAppSnapshot.values.contains(true) else { return }
        busy = true
        defer { busy = false }
        stopRestoringLayout()
        for (scope, windows) in restoreSnapshots {
            for saved in windows.values where !isIgnored(saved.bundleID) && belongsToRestoreScope(saved, scope: scope) == true {
                _ = (restoreWindow ?? putBackOriginal)(saved)
            }
        }
        for (pid, hidden) in hiddenAppSnapshot where hidden { _ = restorableApp(pid)?.hide() }
        release()
    }
    // Stops managing the arrangement without moving a single window: everything
    // stays exactly where it is. Restore (undo) is the one that moves windows back.
    func release() {
        stopRestoringLayout()
        hiddenAppSnapshot.removeAll()
        restoreSnapshots.removeAll(); managedByScope.removeAll(); restoredScopes.removeAll()
        organizedDesktops.removeAll(); desktopSelections.removeAll()
        clearArrangementControls()
    }
    private func stopRestoringLayout() {
        cancelFocus()
        for work in guardPending.values { work.cancel() }
        guardPending.removeAll(); userMoved.removeAll()
    }
    private func clearArrangementControls() {
        onHideLaneControls?()
        pages.removeAll(); visibleSlotIDs.removeAll(); activeSlot.removeAll(); activeIDs.removeAll()
    }
    // Choosing another display leaves the one you were on exactly as arranged.
    // (It used to Restore it, which threw its windows back to where they started.)
    func changeScreen(_ id: UInt32) {
        let leaving = screen.map(\.localizedName), wasArranged = restoreSnapshots.values.contains { !$0.isEmpty }
        if wasArranged { release() }
        settings.screenID = id; save(); syncDisplayLayout(); refresh(); selectedTemplateChanged = true
        if wasArranged, let leaving, let arriving = screen?.localizedName, arriving != leaving {
            status = "Windows on \(leaving) stay where they are. Press Organize to arrange \(arriving)."
        }
    }
    // Each display keeps its own grid. Switching changes the grid and strips only;
    // windows move when you press Organize.
    // A display's name and size: how it is shown, and how older versions saved its grid.
    static func displayLabel(_ screen: NSScreen) -> String { "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))" }
    // What a display's grid is saved under: the identity macOS gives that one
    // display. Two identical monitors have the same name and size, never the same identity.
    static func displayKey(_ screen: NSScreen) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID(screen))?.takeRetainedValue(), let text = CFUUIDCreateString(nil, uuid) else { return displayLabel(screen) }
        return text as String
    }
    func syncDisplayLayout(fresh: Bool = false) {
        guard let screen else { return }
        let firstTime = settings.activeDisplayKey == nil
        let label = Self.displayLabel(screen), twins = screens.filter { Self.displayLabel($0) == label }.count
        let priorKey = desktopArrangementKey
        let displayChanged = settings.activeDisplayKey != Self.displayKey(screen)
        if displayChanged { selectEditorDesktop(nil) }
        let changed = settings.switchDisplay(to: Self.displayKey(screen), label: label, shared: twins > 1, kind: DisplayKind.of(screen.frame.size), fresh: fresh)
        if displayChanged {
            activeDesktop = nil
            changeDesktopInventory(previous: priorKey)
            overrides = settings.windowCategories.compactMapValues(Lane.init(rawValue:))
        }
        syncDesktops()
        save()
        guard changed else { return }
        if !enabledLanes.contains(selectedLane), let first = enabledLanes.first { selectedLane = first }
        onLaneControls?()
        status = firstTime ? "Lanes chose a layout made for this screen." : "Switched to your grid for \(screen.localizedName). Press Organize to arrange your windows."
    }
    func category(at point: CGPoint, in area: CGRect) -> Lane? {
        stackedGridLanes.reversed().first { lane in
            let unit = grid.unitRect(for: lane)
            return Layout.frame(unit: unit, in: area, gap: 7).contains(point)
        }
    }
    func removeCategory(_ lane: Lane) {
        guard enabledLanes.count > 1, enabledLanes.contains(lane), settings.isFloating(lane) || baseGridLanes.count > 1 else { return }
        // Keep the hole and the group's assignments so shelving is reversible.
        var rects = layoutRects(); rects.removeValue(forKey: lane.rawValue)
        settings.customRects = rects
        settings.floatingLanes.removeAll { $0 == lane.rawValue }
        settings.useCustomGrid = true
        layoutHistory = []
        settings.hiddenLanes.append(lane.rawValue)
        if !settings.shelvedLanes.contains(lane.rawValue) { settings.shelvedLanes.append(lane.rawValue) }
        if lane == .media { settings.showMediaShelf = false }
        let fallback = enabledLanes.contains(.desktop) ? Lane.desktop : enabledLanes.first!
        if selectedLane == lane { selectedLane = fallback }
        activeIDs[lane] = nil; pages[lane] = nil
        save(); refresh(silent: true); selectedTemplateChanged = true
        onHideLaneControls?()
        status = "\(name(lane)) moved to the category shelf. Drag it back to restore its group."
        if trusted && canUndo { arrange(hideBoard: false) }
    }
    func restoreCategory(_ lane: Lane, at point: CGPoint? = nil) {
        guard availableLanes.contains(lane), !enabledLanes.contains(lane) else { return }
        if !settings.customRects.isEmpty || point != nil {
            guard let restored = GridGeometry.restoring(lane, rects: baseRects(), active: baseGridLanes, at: point) else {
                status = "Make room by resizing another category, then restore \(name(lane))."; return
            }
            settings.customRects = restored.merging(floatingRects()) { grid, _ in grid }
        }
        layoutHistory = []
        settings.hiddenLanes.removeAll { $0 == lane.rawValue }
        settings.useCustomGrid = true
        settings.shelvedLanes.removeAll { $0 == lane.rawValue }
        if lane == .media { settings.showMediaShelf = true }
        save(); refresh(silent: true); selectedTemplateChanged = true
        selectedLane = lane
        status = "\(name(lane)) restored. Click Apply this grid to use this layout."
        if trusted && canUndo { arrange(hideBoard: false) }
    }
    func selectGridCategory(_ lane: Lane) {
        selectedLane = lane; gridSelectionActive = true; onGridSelection?()
    }
    func name(_ lane: Lane) -> String { settings.name(lane) }
    func gridName(_ lane: Lane) -> String {
        let current = grid
        let name = current.name(lane)
        guard !lane.isCustom, name == lane.title else { return name }
        let prefix = name + " "
        let copies = current.enabledLanes.contains { other in
            let title = current.name(other)
            return other.isCustom && title.hasPrefix(prefix) && (Int(title.dropFirst(prefix.count)) ?? 0) >= 2
        }
        return copies ? name + " 1" : name
    }
    func windowLabel(_ window: ManagedWindow) -> String { windowLabel(window, long: false) }
    // `long`: room for a whole line, as in a strip's list.
    func windowLabel(_ window: ManagedWindow, long: Bool) -> String {
        if let typed = settings.windowLabels[window.id] { return typed }
        guard settings.shortTabNames else { return window.title }
        let length = long ? 60 : TitleSummary.limit
        let label = TitleSummary.label(title: window.title, appName: window.appName, bundleID: window.bundleID, length: length, chatNames: settings.chatNames)
        guard !settings.chatNames else { return label }
        // As before: two windows of one messaging app in a category say which conversation.
        let app = TitleSummary.clean(window.appName)
        if label == app, windows.contains(where: { $0.id != window.id && $0.lane == window.lane && $0.bundleID == window.bundleID }) {
            let detail = TitleSummary.shortTitle(window.title, appName: window.appName, length: length)
            if detail != app { return "\(app) · \(detail)" }
        }
        return label
    }
    // The app's name for the right end of a list row; nil when the row already says it
    // or chat names are off.
    func windowAppName(_ window: ManagedWindow) -> String? {
        guard settings.chatNames else { return nil }
        return TitleSummary.appColumn(label: windowLabel(window, long: true), appName: window.appName)
    }
    func beginRenamingWindow(_ window: ManagedWindow) { renameWindowID = window.id; onShow?() }
    func renameWindow(_ id: String, name: String) {
        let text = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if text.isEmpty { settings.windowLabels.removeValue(forKey: id) } else { settings.windowLabels[id] = text }
        save()
    }
    func reorderTab(_ values: [String], before requested: ManagedWindow, after: Bool = false) -> Bool {
        guard let target = windows.first(where: { $0.id == requested.id }), let value = values.first else { return false }
        let id = value.hasPrefix("lanewindow:") ? String(value.dropFirst(11)) : value.hasPrefix("tab:") ? String(value.dropFirst(4)) : value
        guard let source = windows.first(where: { $0.id == id }), source.lane == target.lane else { return false }
        let ids = WindowSlots.reordered(items(target.lane).map(\.id), source: source.id, before: target.id, after: after)
        // Preserve the displayed panes even if they haven't been explicitly selected yet.
        visibleSlotIDs[target.lane] = slotIDs(target.lane)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        windows = windows.filter { $0.lane != target.lane } + ids.compactMap { byID[$0] }
        settings.windowOrder[target.lane.rawValue] = ids; save()
        status = "\(name(target.lane)) tab order saved. Visible windows stay in place."
        return true
    }
    func beginTabDrag(_ window: ManagedWindow) -> String {
        if expandedStrip == window.lane { collapseStrip?.cancel(); collapseStrip = nil }
        if draggedTab != window.id { draggedTab = window.id; onTabDrag?(window.id) }
        return "tab:" + window.id
    }
    private var draggedTabLane: Lane? { windows.first { $0.id == draggedTab }?.lane }
    func endTabDrag() {
        guard draggedTab != nil else { return }
        let source = draggedTabLane
        draggedTab = nil; onTabDrag?(nil)
        if let source, hoveredLane != source { stripHovered(source, false) }
    }
    // The expanded popup owns its drop target. Resolve the row from the drop
    // position instead of letting the enclosing strip consume a row's drop.
    func dropListedTab(_ values: [String], into lane: Lane, y: Double) -> Bool {
        let all = items(lane)
        let selected = all.firstIndex { $0.id == activeWindow(lane)?.id } ?? 0
        let indices = Array(Layout.pickerIndices(total: all.count, active: selected, limit: 16))
        guard let target = WindowStripMetrics.listDrop(y: y, scale: settings.windowStripScale, rows: indices.count, above: stripListOpensAbove(lane)) else {
            return dropTab(values, into: lane)
        }
        return dropTab(values, into: lane, before: all[indices[target.row]], after: target.after)
    }
    // A tab dropped on a strip or a drop zone. In its own category it reorders;
    // anywhere else the window moves to that category and takes its place there.
    func dropTab(_ values: [String], into lane: Lane, before target: ManagedWindow? = nil, after: Bool = false) -> Bool {
        endTabDrag()
        guard let value = values.first, value.hasPrefix("tab:"), let source = windows.first(where: { $0.id == String(value.dropFirst(4)) }) else { return false }
        if source.lane == lane { return target.map { reorderTab(values, before: $0, after: after) } ?? false }
        guard enabledLanes.contains(lane) else { return false }
        // Moving can close the strip the tab came from, so it waits until the
        // drag has finished.
        DispatchQueue.main.async { [weak self] in self?.moveWindow(source, to: lane) }
        return true
    }
    func handleStripKey(_ action: StripKeyAction) {
        guard let lane = hoveredLane else { return }
        switch action {
        case .cycle(let delta): cycleWindow(lane, delta: delta)
        case .select(let index):
            let all = stripItems(lane)
            if all.indices.contains(index) { reveal(all[index]) }
        }
    }
    // Hover targeting changes the picker, without activating or raising an app.
    func targetSlot(_ lane: Lane, index: Int) {
        let slots = slotIDs(lane)
        guard slots.indices.contains(index), activeSlot[lane] != index else { return }
        activeSlot[lane] = index
    }
    // In a two-pane category, clicking the other pane's label sends the window
    // you are working in there; the window it replaces takes its old place.
    func selectSlot(_ lane: Lane, index: Int) {
        let slots = slotIDs(lane)
        guard slots.indices.contains(index) else { return }
        if slots.count == 2, let working = focusedWindow(), working.lane == lane, let from = slots.firstIndex(of: working.id), from != index {
            swapPanes(lane, keeping: working); return
        }
        activeSlot[lane] = index
        if let window = items(lane).first(where: { $0.id == slots[index] }) { focus(window, hideBoard: false) }
    }
    // Swaps the windows of a two-pane category. Both move at once, and the window
    // you were working in stays on top with the keyboard.
    func swapPanes(_ lane: Lane, keeping working: ManagedWindow? = nil) {
        guard !editingDraft else { return }
        let slots = slotIDs(lane)
        guard slots.count == 2, !slots[0].isEmpty, !slots[1].isEmpty else { return }
        // Decide which window keeps the keyboard before the panes change.
        let focused = working ?? focusedWindow().flatMap { slots.contains($0.id) ? $0 : nil }
        let keep = focused ?? activeWindow(lane)
        swapSlots(lane, from: 0, to: 1, keeping: keep)
    }
    private func swapSlots(_ lane: Lane, from: Int, to: Int, keeping keep: ManagedWindow?) {
        guard !editingDraft else { return }
        let slots = slotIDs(lane)
        guard slots.indices.contains(from), slots.indices.contains(to), from != to else { return }
        let swapped = WindowSlots.swapped(slots, from, to)
        visibleSlotIDs[lane] = swapped
        let changed = Set([slots[from], slots[to]]).subtracting([""])
        _ = apply(lane, presentationOnly: true, onlyIDs: changed)
        for id in changed where id != keep?.id && trusted {
            if let other = items(lane).first(where: { $0.id == id }) { _ = focusAccess.raise(other) }
        }
        if let keep, let slot = swapped.firstIndex(of: keep.id) {
            activeIDs[lane] = keep.id; activeSlot[lane] = slot
            if trusted { focus(keep, hideBoard: false) }
        }
        status = "Swapped the \(name(lane)) panes."
        onLaneControls?()
    }
    // "Show in Left/Right": a window already showing in the other pane swaps over.
    func show(_ requested: ManagedWindow, inPane index: Int) {
        guard let window = windows.first(where: { $0.id == requested.id }), enabledLanes.contains(window.lane) else { return }
        let slots = slotIDs(window.lane)
        guard slots.indices.contains(index) else { return }
        if let from = slots.firstIndex(of: window.id), from != index { swapSlots(window.lane, from: from, to: index, keeping: window); return }
        activeSlot[window.lane] = index; reveal(window)
    }
    func nextWindowLabel(_ lane: Lane) -> String {
        guard let id = WindowSlots.nextID(ids: items(lane).map(\.id), slots: slotIDs(lane), slot: activeSlot[lane] ?? 0, delta: 1), let window = items(lane).first(where: { $0.id == id }) else { return "No windows" }
        return windowLabel(window)
    }
    func slotLabel(_ lane: Lane, index: Int) -> String {
        let count = settings.capacity(lane)
        if count == 2 {
            let frames = paneTiles(lane, count: count)
            return frames[0].minY == frames[1].minY ? (index == 0 ? "Left" : "Right") : (index == 0 ? "Top" : "Bottom")
        }
        return "Slot \(index + 1)"
    }
    var availableLanes: [Lane] { settings.availableLanes }
    func addCategory(name input: String, at point: CGPoint? = nil) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "Give the category a name."; return false }
        let category = CustomCategory(name: String(trimmed.prefix(40)))
        guard let rects = GridGeometry.restoring(category.lane, rects: baseRects(), active: baseGridLanes, at: point) else {
            status = "Make room by resizing a category before adding another one."; return false
        }
        settings.customCategories.append(category); settings.customRects = rects.merging(floatingRects()) { grid, _ in grid }
        settings.capacities[category.id] = 1
        selectedLane = category.lane; gridSelectionActive = true; layoutHistory = []
        save(); refreshRunningApps(); layoutChanged("\(category.name) created.")
        return true
    }
    // A shelf tile is reusable. Restore the next saved copy before creating one.
    @discardableResult func addShelfCategory(_ lane: Lane, at point: CGPoint? = nil) -> Bool {
        guard Lane.allCases.contains(lane) else { return false }
        if !enabledLanes.contains(lane) {
            restoreCategory(lane, at: point)
            return enabledLanes.contains(lane)
        }
        var number = 2
        while true {
            let name = "\(lane.title) \(number)"
            guard let existing = availableLanes.first(where: { settings.name($0) == name }) else {
                return addCategory(name: name, at: point)
            }
            if !enabledLanes.contains(existing) {
                restoreCategory(existing, at: point)
                return enabledLanes.contains(existing)
            }
            number += 1
        }
    }
    func renameCategory(_ lane: Lane, name input: String) {
        let text = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !text.isEmpty else { return }
        settings.categoryNames[lane.rawValue] = text; save()
    }
    func deleteSelectedCategory() {
        guard gridSelectionActive else { return }
        if enabledLanes.count <= 1 { status = "Keep at least one category. Add another before deleting this one."; return }
        removeCategory(selectedLane)
    }
    // Runs a grid edit against the draft. The screen, your windows and the saved
    // settings stay exactly as they are; the result becomes the draft shown in the
    // Lanes window, or disappears if it matches what is applied.
    func editGrid(_ body: () -> Void) {
        guard !editingDraft else { body(); return }
        presetPreview = nil
        let live = settings
        let state = (windows, outsideGrid, overrides, visibleSlotIDs, activeIDs, activeSlot, pages)
        let laneControls = onLaneControls, hideControls = onHideLaneControls, hide = onHide
        onLaneControls = nil; onHideLaneControls = nil; onHide = nil
        let base = editorBase
        let draft = pendingGrid ?? base
        let inventory = viewingOtherDesktop ? editorWindows : nil
        settings = draft
        overrides = settings.windowCategories.compactMapValues(Lane.init(rawValue:))
        editingDraft = true
        if let inventory {
            windows = inventory; outsideGrid = []
            visibleSlotIDs = [:]; activeIDs = [:]; activeSlot = [:]; pages = [:]
            reclassifyInventory()
        }
        body()
        editingDraft = false
        let edited = settings
        settings = live
        (windows, outsideGrid, overrides, visibleSlotIDs, activeIDs, activeSlot, pages) = state
        onLaneControls = laneControls; onHideLaneControls = hideControls; onHide = hide
        gridDraft = Self.sameGrid(edited, base) ? nil : edited
        if gridDraft != nil { gridDraftBase = base }
    }
    static func sameGrid(_ a: Settings, _ b: Settings) -> Bool {
        a.enabledLanes == b.enabledLanes && a.customCategories == b.customCategories && a.categoryNames == b.categoryNames && a.stripPositions == b.stripPositions &&
            a.assignmentsInUse == b.assignmentsInUse && a.placements == b.placements && a.gap == b.gap &&
            a.windowPaneSizes == b.windowPaneSizes && a.useCustomGrid == b.useCustomGrid && a.shelvedLanes == b.shelvedLanes &&
            Set(a.floatingLanes).intersection(a.enabledLanes.map(\.rawValue)) == Set(b.floatingLanes).intersection(b.enabledLanes.map(\.rawValue)) &&
            a.enabledLanes.allSatisfy { a.unitRect(for: $0) == b.unitRect(for: $0) && a.capacity($0) == b.capacity($0) && a.split($0) == b.split($0) }
    }
    // Apply: the draft becomes the grid your screen uses, and windows are arranged into it.
    func applyGridDraft() { applyDisplayedGrid() }
    private func commitGridDraft() {
        guard let draft = pendingGrid else { return }
        gridDraft = nil
        let before = layoutRects()
        let previous = currentGridLayout(name: "Previous layout")
        let chosen = Dictionary(uniqueKeysWithValues: enabledLanes.compactMap { lane in activeWindow(lane).map { (lane, $0.id) } })
        // `draft` is the settings in use plus only what the draft changed: a window
        // moved to another category after the draft began stays where you put it.
        settings = draft
        recenterMovedStrips(changedFrom: before)
        settings.previousLayout = previous
        overrides = settings.windowCategories.compactMapValues(Lane.init(rawValue:))
        reclassifyInventory()
        // Draft editing intentionally restores the live slot state. Apply must
        // now normalize it for the new count without losing the chosen pane.
        for lane in enabledLanes {
            let capacity = settings.capacity(lane)
            let ids = items(lane).map(\.id)
            var slots = WindowSlots.normalized(visibleSlotIDs[lane] ?? [], ids: ids, capacity: capacity)
            if let id = chosen[lane], ids.contains(id) {
                let target = min(activeSlot[lane] ?? 0, capacity - 1)
                slots = WindowSlots.replacing(slots, with: id, at: target)
                activeIDs[lane] = id
                activeSlot[lane] = slots.firstIndex(of: id) ?? target
            }
            visibleSlotIDs[lane] = slots
        }
        save()
        if !enabledLanes.contains(selectedLane), let first = enabledLanes.first { selectedLane = first }
    }
    // A strip you dragged keeps its spot only while its category's box stays the
    // same; when the box changes, the strip goes back to the middle of its top edge.
    func recenterMovedStrips(changedFrom before: [String: ZoneRect]) {
        let after = layoutRects()
        for key in Array(settings.stripPositions.keys) where before[key] != after[key] { settings.stripPositions.removeValue(forKey: key) }
    }
    func discardGridDraft() {
        gridDraft = nil; editorPreview = nil; presetPreview = nil
        layoutHistory.removeAll()
        status = "Grid changes discarded. Your screen is as it was."
    }
    // MARK: Desktops
    func desktopName(_ id: String?) -> String { desktops.first { $0.id == id }.map { "Desktop \($0.number)" } ?? "this desktop" }
    // The editor uses the selected desktop’s grid and category assignments.
    private func settingsShowing(_ desktop: String) -> Settings {
        var shown = settings
        shown.applySpaceLayout(settings.layout(for: desktop))
        shown.assignmentsInUse = settings.assignments(for: desktop)
        shown.previousLayout = settings.previousLayout(for: desktop)
        return shown
    }
    private func selectEditorDesktop(_ id: String?) {
        guard shownDesktop != id else { return }
        if let display = settings.activeDisplayKey, let shownDesktop {
            let key = Settings.spaceLayoutKey(display: display, space: shownDesktop)
            desktopDrafts[key] = DesktopDraft(grid: gridDraft, base: gridDraftBase, preset: presetPreview, history: layoutHistory)
        }
        let draft = settings.activeDisplayKey.flatMap { display in
            id.flatMap { desktopDrafts.removeValue(forKey: Settings.spaceLayoutKey(display: display, space: $0)) }
        }
        shownDesktop = id
        gridDraft = draft?.grid
        gridDraftBase = draft?.base
        presetPreview = draft?.preset
        layoutHistory = draft?.history ?? []
        editorPreview = nil; snapHint = nil
        if !gridLanes.contains(selectedLane), let first = gridLanes.first { selectedLane = first }
    }
    func showDesktop(_ id: String) {
        guard desktops.contains(where: { $0.id == id }), id != shownDesktop else { return }
        selectEditorDesktop(id)
        refreshEditorWindowList()
        status = viewingOtherDesktop ? "Editing \(desktopName(id)). Apply saves to this desktop." : "\(desktopName(id)) is active."
    }
    // Apply while the editor shows another desktop: its grid is saved for that
    // desktop. Lanes cannot move windows on a desktop you are not on, and nothing
    // on this one changes.
    private func saveShownDesktop() {
        guard let shown = shownDesktop else { return }
        if let preview = presetPreview {
            guard previewAccepted(preview) else { return }
            editGrid { applyPreset(preview) }
        }
        let original = settingsShowing(shown)
        var edited = pendingGrid ?? original
        for key in edited.stripPositions.keys {
            if let lane = Lane(rawValue: key), original.unitRect(for: lane) != edited.unitRect(for: lane) {
                edited.stripPositions[key] = nil
            }
        }
        if hasGridEdits {
            settings.setPreviousLayout(currentGridLayout(name: "Previous layout", from: original), for: shown)
        }
        settings.setSpaceLayout(edited.layoutInUse, for: shown)
        settings.setAssignments(edited.assignmentsInUse, for: shown)
        // Categories and their names are shared by every desktop. One made in this
        // edit waits on the shelf of the desktop you are on.
        let known = Set(settings.customCategories.map(\.id))
        for category in edited.customCategories where !known.contains(category.id) {
            settings.customCategories.append(category)
            settings.hiddenLanes.append(category.id); settings.shelvedLanes.append(category.id)
        }
        settings.categoryNames = edited.categoryNames
        gridDraft = nil; editorPreview = nil
        save()
        status = "Saved for \(desktopName(shown)). Lanes uses it when you are on that desktop; nothing on \(desktopName(activeDesktop)) moved."
    }
    // A Space notification changes the grid first. Strips wait for the window
    // list from that Space, so panels shared by macOS never show the old list.
    func desktopChanged() {
        syncDesktops()
        refreshInBackground { [weak self] in self?.showCurrentDesktopStrips() }
    }
    private func showCurrentDesktopStrips() {
        guard !busy else { return }
        adoptArrangement(refreshInventory: false)
        syncStrips()
        onLaneControls?()
    }
    private func changeDesktopInventory(previous: String?) {
        if let previous {
            desktopSelections[previous] = (visibleSlotIDs, activeIDs, activeSlot, pages)
            desktopInventory[previous] = windows + outsideGrid
        }
        desktopGeneration += 1
        backgroundRefreshFollowUps.removeAll()
        cancelFocus()
        for work in guardPending.values { work.cancel() }
        guardPending.removeAll(); userMoved.removeAll()
        onHideLaneControls?()
        collapseStrip?.cancel(); collapseStrip = nil
        expandedStrip = nil; hoveredLane = nil; draggingStrip = nil
        pinnedStripOrigin.removeAll(); pinnedStripLeft.removeAll(); listSideHeld.removeAll()
        frozenTabWidth.removeAll(); frozenTabStart.removeAll()
        let selection = desktopAvailable ? desktopArrangementKey.flatMap { desktopSelections[$0] } : nil
        visibleSlotIDs = selection?.slots ?? [:]
        activeIDs = selection?.active ?? [:]
        activeSlot = selection?.pane ?? [:]
        pages = selection?.pages ?? [:]
        windows = []; outsideGrid = []; discoveryOrder = []; onScreenStack = []; onScreenNumbers = [:]
        lastSignature = ""; stripSignature = ""
    }
    func syncDesktops() {
        guard !editingDraft, let screen, let display = settings.activeDisplayKey, display == Self.displayKey(screen) else { return }
        let all = DesktopSpaces.parse(spacesAccess.read(), mainDisplay: screens.first.map(Self.displayKey) ?? display)
        let found = DesktopSpaces.desktops(of: display, in: all)
        let listedDesktops = found?.desktops ?? []
        if found == nil && spacesAccess.tracksDesktops && !desktops.isEmpty {
            if desktopAvailable {
                desktopAvailable = false
                currentSpaceNumber = nil
                changeDesktopInventory(previous: desktopArrangementKey)
            }
            return
        }
        func listed(_ id: String?) -> String? { id.flatMap { id in listedDesktops.contains { $0.id == id } ? id : nil } }
        let active = found?.current ?? listed(activeDesktop) ?? listed(settings.activeSpaceKey) ?? listedDesktops.first?.id
        let available = found == nil || found?.current != nil
        let previous = activeDesktop
        let priorKey = desktopAvailable ? previous.map { Settings.spaceLayoutKey(display: display, space: $0) } : nil
        let contextChanged = previous != active || desktopAvailable != available || currentSpaceNumber != found?.currentNumber
        if desktops != listedDesktops { desktops = listedDesktops }
        if desktopAvailable != available { desktopAvailable = available }
        currentSpaceNumber = found?.currentNumber
        desktopManagedNumbers = found?.managedNumbers ?? [:]
        if let active, available, settings.activeSpaceKey != active {
            settings.switchSpace(to: active)
            overrides = settings.windowCategories.compactMapValues(Lane.init(rawValue:))
            save()
        }
        if contextChanged {
            activeDesktop = active
            changeDesktopInventory(previous: priorKey)
        }
        if listed(shownDesktop) == nil || (previous != active && available) {
            selectEditorDesktop(active)
        }
        if contextChanged, available, active != nil {
            if !gridLanes.contains(selectedLane), let first = gridLanes.first { selectedLane = first }
            status = "Switched to your grid for \(desktopName(active))."
        }
    }
    func layoutRects() -> [String: ZoneRect] {
        Dictionary(uniqueKeysWithValues: grid.enabledLanes.map { ($0.rawValue, ZoneRect(grid.unitRect(for: $0))) })
    }
    func editorRect(_ lane: Lane) -> CGRect { editorPreview?[lane.rawValue]?.cgRect ?? grid.unitRect(for: lane) }
    func commitGridResize(_ rects: [String: ZoneRect], lane: Lane) {
        guard GridGeometry.valid(rects, lanes: enabledLanes, floating: Set(settings.floatingLanes)), rects != layoutRects() else { editorPreview = nil; return }
        rememberLayout(); settings.customRects = rects; editorPreview = nil
        layoutChanged("\(name(lane)) and its shared borders resized.")
    }
    func rememberLayout() {
        if viewingOtherDesktop && !editingDraft, let key = desktopArrangementKey {
            var draft = desktopDrafts[key] ?? DesktopDraft()
            draft.history = Array((draft.history + [settings]).suffix(30))
            desktopDrafts[key] = draft
        } else {
            layoutHistory.append(settings)
            if layoutHistory.count > 30 { layoutHistory.removeFirst() }
        }
    }
    func validEdit(_ lane: Lane, rect: CGRect) -> Bool {
        var rects = layoutRects(); rects[lane.rawValue] = ZoneRect(rect)
        return GridGeometry.valid(rects, lanes: grid.enabledLanes, floating: floatingKeys)
    }
    func editCategory(_ lane: Lane, rect: CGRect) {
        guard enabledLanes.contains(lane), validEdit(lane, rect: rect) else {
            status = "That region overlaps another category or extends beyond the display. Shrink or move a neighbor first."
            return
        }
        guard settings.unitRect(for: lane) != rect else { return }
        rememberLayout()
        var rects = layoutRects(); rects[lane.rawValue] = ZoneRect(rect)
        settings.customRects = rects; layoutChanged("\(name(lane)) resized / positioned.")
    }
    func layoutChanged(_ message: String) {
        if !editingDraft { cancelFocus() }
        settings.useCustomGrid = true
        save(); selectedTemplateChanged = true
        status = message + " Organize keeps these sizes. Auto layout chooses a new grid."
    }
    func undoLayout() {
        guard let old = layoutHistory.popLast() else { return }
        settings.hiddenLanes = old.hiddenLanes; settings.shelvedLanes = old.shelvedLanes
        settings.customCategories = old.customCategories; settings.showMediaShelf = old.showMediaShelf
        settings.windowCategories = old.windowCategories
        overrides = old.windowCategories.compactMapValues(Lane.init(rawValue:))
        reclassifyInventory()
        if !enabledLanes.contains(selectedLane) { selectedLane = enabledLanes[0] }
        settings.customRects = old.customRects; settings.template = old.template
        settings.splits = old.splits; settings.placements = old.placements; settings.floatingLanes = old.floatingLanes
        settings.capacities = old.capacities; settings.windowSplits = old.windowSplits; settings.windowPaneSizes = old.windowPaneSizes
        layoutChanged("Previous grid restored.")
    }
    // What dropping a dragged category would do, shown live in the grid editor.
    struct SnapHint: Equatable { let lane: Lane; let plan: GridGeometry.SnapPlan }
    @Published var snapHint: SnapHint?
    func snapPlan(_ lane: Lane, candidate: CGRect, at point: CGPoint) -> GridGeometry.SnapPlan {
        // A floating category goes wherever it is dropped.
        if isFloating(lane) { return .move(candidate) }
        return GridGeometry.snapPlan(lane, candidate: candidate, at: point, rects: baseRects(), lanes: baseGridLanes)
    }
    // A resize: a grid category moves its shared borders with its neighbors;
    // a floating one moves only its own edge.
    func resizedGrid(_ start: [String: ZoneRect], lane: Lane, edge: ResizeEdge, dx: Double, dy: Double, keepNeighbors: Bool = false) -> [String: ZoneRect] {
        let floating = floatingKeys
        if keepNeighbors || floating.contains(lane.rawValue) {
            return GridGeometry.resizingOnly(start, lane: lane, edge: edge, dx: dx, dy: dy, snap: !keepNeighbors && settings.snapToGrid, floating: floating)
        }
        return GridGeometry.resizing(start.filter { !floating.contains($0.key) }, lane: lane, edge: edge, dx: dx, dy: dy, snap: settings.snapToGrid)
            .merging(start.filter { floating.contains($0.key) }) { grid, _ in grid }
    }
    // Float a category over the grid, or put it back in. Floating leaves its
    // region where it was; its neighbors grow into the space it left.
    func setFloating(_ lane: Lane, _ on: Bool) {
        guard enabledLanes.contains(lane), settings.isFloating(lane) != on else { return }
        let rect = layoutRects()[lane.rawValue]?.cgRect ?? settings.unitRect(for: lane)
        let others = floatingRects()
        if on {
            guard baseGridLanes.count > 1 else { status = "Keep one category in the grid for \(name(lane)) to float over."; return }
            var base = baseRects(); base.removeValue(forKey: lane.rawValue)
            base = GridGeometry.filling(rect, rects: base)
            rememberLayout()
            settings.floatingLanes.append(lane.rawValue)
            var rects = base.merging(others) { grid, _ in grid }; rects[lane.rawValue] = ZoneRect(rect)
            settings.customRects = rects
            layoutChanged("\(name(lane)) floats over the grid. Switching to one of its windows brings it on top.")
        } else {
            guard let restored = GridGeometry.restoring(lane, rects: baseRects(), active: baseGridLanes, at: CGPoint(x: rect.midX, y: rect.midY)) else {
                status = "Make room in the grid, then put \(name(lane)) back."; return
            }
            rememberLayout()
            settings.floatingLanes.removeAll { $0 == lane.rawValue }
            settings.customRects = restored.merging(others.filter { $0.key != lane.rawValue }) { grid, _ in grid }
            layoutChanged("\(name(lane)) is back in the grid.")
        }
    }
    func dropCategory(_ lane: Lane, candidate: CGRect, at point: CGPoint) {
        snapHint = nil
        switch snapPlan(lane, candidate: candidate, at: point) {
        case .move(let rect): editCategory(lane, rect: rect)
        case .swap(let target): swapCategories(lane, target)
        case .fit(let rects):
            rememberLayout(); settings.customRects = rects.merging(floatingRects()) { grid, _ in grid }
            layoutChanged("\(name(lane)) moved into the free space.")
        case .none: status = "\(name(lane)) does not fit there. Drop it on another category to swap them."
        }
    }
    func swapCategories(_ source: Lane, _ target: Lane) {
        guard source != target, enabledLanes.contains(source), enabledLanes.contains(target) else { return }
        rememberLayout()
        var rects = layoutRects()
        let sourceRect = rects[source.rawValue]; rects[source.rawValue] = rects[target.rawValue]; rects[target.rawValue] = sourceRect
        settings.customRects = rects
        // Floating belongs to the place: the category that takes a floating spot floats.
        if settings.isFloating(source) != settings.isFloating(target) {
            let (from, to) = settings.isFloating(source) ? (source, target) : (target, source)
            settings.floatingLanes.removeAll { $0 == from.rawValue }; settings.floatingLanes.append(to.rawValue)
        }
        layoutChanged("\(name(source)) and \(name(target)) swapped.")
    }
    func resetPlacements() {
        rememberLayout(); settings.customRects = [:]; settings.placements = [:]
        settings.splits = [0.23, 0.42, 0.77, 0.56]
        layoutChanged("Category positions reset.")
    }
    func receiveDrop(_ values: [String], into target: Lane) -> Bool {
        var handled = false
        for value in values {
            if value.hasPrefix("lane:"), let source = Lane(rawValue: String(value.dropFirst(5))) {
                guard availableLanes.contains(source) else { continue }
                if enabledLanes.contains(source) { swapCategories(source, target) }
                else { restoreCategory(source, at: CGPoint(x: editorRect(target).midX, y: editorRect(target).midY)) }
                handled = enabledLanes.contains(source)
            } else if value.hasPrefix("app:"), let app = editorApps.first(where: { $0.bundleID == String(value.dropFirst(4)) }) {
                setEditorAppCategory(app, to: target)
                handled = true
            } else {
                let id = value.hasPrefix("lanewindow:") ? String(value.dropFirst(11)) :
                         value.hasPrefix("tab:") ? String(value.dropFirst(4)) : value
                if let window = editorWindows.first(where: { $0.id == id }) {
                    setEditorWindowCategory(window, to: target)
                    handled = true
                }
            }
        }
        return handled
    }
    func receiveShelfDrop(_ values: [String]) -> Bool {
        guard enabledLanes.count > 1, let value = values.first(where: { $0.hasPrefix("lane:") }),
              let lane = Lane(rawValue: String(value.dropFirst(5))), enabledLanes.contains(lane) else { return false }
        removeCategory(lane); return !enabledLanes.contains(lane)
    }
    func receiveWorkspaceDrop(_ values: [String], at point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, CGRect(origin: .zero, size: size).contains(point) else { return false }
        let unit = CGPoint(x: point.x / size.width, y: point.y / size.height)
        if let item = values.first(where: { $0.hasPrefix("shelf:") }),
           let lane = Lane(rawValue: String(item.dropFirst(6))) { return addShelfCategory(lane, at: unit) }
        guard let value = values.first(where: { $0.hasPrefix("lane:") }),
              let lane = Lane(rawValue: String(value.dropFirst(5))), availableLanes.contains(lane) else { return false }
        if enabledLanes.contains(lane) {
            guard let target = category(at: point, in: CGRect(origin: .zero, size: size)) else { return false }
            swapCategories(lane, target)
        } else { restoreCategory(lane, at: unit) }
        return enabledLanes.contains(lane)
    }
    func currentGridLayout(name: String, from source: Settings? = nil) -> SavedGridLayout {
        let source = source ?? settings
        let rects = Dictionary(uniqueKeysWithValues: source.enabledLanes.map { ($0.rawValue, ZoneRect(source.unitRect(for: $0))) })
        let floating = source.floatingLanes.filter { key in source.enabledLanes.contains { $0.rawValue == key } }
        return SavedGridLayout(name: name, rects: rects, capacities: source.capacities, lanes: source.enabledLanes.map(\.rawValue), gap: source.gap, categories: source.customCategories, categoryNames: source.categoryNames, windowCategories: source.windowCategories, floating: floating.isEmpty ? nil : floating, windowSplits: source.windowSplits.isEmpty ? nil : source.windowSplits, windowPaneSizes: source.windowPaneSizes.isEmpty ? nil : source.windowPaneSizes)
    }
    @discardableResult func saveGridLayout(name input: String) -> Bool {
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { return false }
        var uniqueName = name; var suffix = 2
        while settings.savedLayouts.contains(where: { $0.name == uniqueName }) { uniqueName = "\(name) \(suffix)"; suffix += 1 }
        var layout = currentGridLayout(name: uniqueName, from: pendingGrid ?? grid)
        if let preview = presetPreview {
            if let id = preview.savedID, let saved = settings.savedLayouts.first(where: { $0.id == id }) {
                layout = saved; layout.id = UUID().uuidString; layout.name = uniqueName
            } else {
                // A preview is its rectangles, its categories and the ones that float
                // (Overlay floats everything over the main category): saved together.
                layout.rects = preview.rects; layout.lanes = preview.lanes.map(\.rawValue)
                layout.floating = preview.floating.isEmpty ? nil : preview.floating
            }
        }
        // Only a preset that Apply would accept joins the list.
        guard GridGeometry.valid(layout.rects, lanes: layout.lanes.compactMap(Lane.init(rawValue:)), floating: Set(layout.floating ?? [])) else {
            status = "This preset does not fit your categories."; return false
        }
        settings.savedLayouts.append(layout); save()
        status = "\(uniqueName) saved with category sizes and windows shown at once."
        return true
    }
    func loadGridLayout(_ layout: SavedGridLayout) {
        let lanes = layout.lanes.compactMap(Lane.init(rawValue:))
        let available = Lane.allCases + layout.categories.map(\.lane) + settings.customCategories.map(\.lane)
        guard !lanes.isEmpty, lanes.allSatisfy({ available.contains($0) }),
              GridGeometry.valid(layout.rects, lanes: lanes, floating: Set(layout.floating ?? [])) else { status = "This saved layout contains unavailable categories or invalid regions."; return }
        rememberLayout(); settings.previousLayout = currentGridLayout(name: "Previous layout")
        for category in layout.categories where !settings.customCategories.contains(where: { $0.id == category.id }) { settings.customCategories.append(category) }
        settings.categoryNames.merge(layout.categoryNames, uniquingKeysWith: { _, saved in saved })
        settings.windowCategories = layout.windowCategories
        overrides = layout.windowCategories.compactMapValues(Lane.init(rawValue:))
        settings.hiddenLanes = availableLanes.filter { !lanes.contains($0) }.map(\.rawValue)
        settings.shelvedLanes = settings.hiddenLanes
        settings.showMediaShelf = lanes.contains(.media)
        settings.customRects = layout.rects; settings.capacities = layout.capacities; settings.windowSplits = layout.windowSplits ?? [:]; settings.floatingLanes = layout.floating ?? []
        settings.windowPaneSizes = layout.windowPaneSizes ?? [:]
        settings.gap = min(28, max(4, layout.gap)); editorPreview = nil
        reclassifyInventory()
        if !lanes.contains(selectedLane) { selectedLane = lanes[0] }
        layoutChanged("\(layout.name) loaded.")
    }
    private func reclassifyInventory() {
        var inside: [ManagedWindow] = [], outside: [ManagedWindow] = []
        var resolvedPreviewAssignments = false
        for var window in windows + outsideGrid {
            if adoptDesktopPreviewAssignment(pid: window.pid, number: window.windowNumber, id: window.id) { resolvedPreviewAssignments = true }
            window.lane = category(for: window.id, bundle: window.bundleID, appName: window.appName, title: window.title)
            if enabledLanes.contains(window.lane) { inside.append(window) } else { outside.append(window) }
        }
        windows = inside; outsideGrid = outside
        if resolvedPreviewAssignments { save() }
    }
    func restorePreviousLayout() {
        guard let layout = editorPreviousLayout else { return }
        if viewingOtherDesktop { editGrid { loadGridLayout(layout) } }
        else { loadGridLayout(layout) }
    }
    func deleteSavedLayout(_ id: String) { settings.savedLayouts.removeAll { $0.id == id }; save() }
    func matchesLayout(_ layout: SavedGridLayout) -> Bool {
        layout.rects == layoutRects() && layout.lanes == enabledLanes.map(\.rawValue) &&
            settings.windowPaneSizes == (layout.windowPaneSizes ?? [:]) &&
            enabledLanes.allSatisfy { settings.capacity($0) == layout.capacities[$0.rawValue] && settings.split($0) == layout.windowSplits?[$0.rawValue].flatMap(WindowSplit.init(rawValue:)) } && settings.gap == layout.gap
    }
    func showGrid() { onOverlay?(enabledLanes.map { ($0, rawLaneFrame($0)) }) }
    // Keep the split when it still fits the new number of panes.
    func setCapacity(_ lane: Lane, _ value: Int) {
        let split = settings.split(lane)
        setWindows(lane, count: value, split: value == 1 || (value == 2 && split == .grid) ? nil : split)
    }
    func setArrangement(_ lane: Lane, _ choice: WindowArrangement) {
        setWindows(lane, count: choice.count, split: choice.count == 1 ? nil : choice.split)
    }
    func setWindowSplit(_ split: WindowSplit?, for lane: Lane) {
        setWindows(lane, count: settings.capacity(lane), split: split)
    }
    func arrangementFrame(_ lane: Lane, staged: Bool = false) -> CGRect {
        guard staged else { return laneFrame(lane) }
        let source = grid
        var frame = Layout.frame(unit: source.unitRect(for: lane), in: screenFrame, gap: source.gap)
        if source.stripReservesSpace {
            let inset = WindowStripMetrics.measure(style: source.stripStyle(lane), count: stripCount(lane),
                scale: source.windowStripScale, availableWidth: frame.width, slots: source.capacity(lane)).reservedHeight
            frame.origin.y += inset
            frame.size.height = max(80, frame.height - inset)
        }
        return frame
    }
    // The effective split for the live grid or its draft.
    func arrangement(_ lane: Lane, staged: Bool = false) -> WindowArrangement {
        let source = staged ? grid : settings
        return source.arrangement(lane, in: arrangementFrame(lane, staged: staged))
    }
    func setPaneSizes(_ sizes: WindowPaneSizes?, for lane: Lane, arrangement: WindowArrangement) {
        let key = WindowPaneSizes.key(lane, arrangement)
        let normalized = sizes?.normalized(for: arrangement)
        let changed = normalized == .equal(for: arrangement) ? nil : normalized
        guard settings.windowPaneSizes[key] != changed else { return }
        rememberLayout()
        settings.windowPaneSizes[key] = changed
        selectedTemplateChanged = true
        save()
        if trusted && canUndo && !busy && !editingDraft { _ = apply(lane, raiseWindows: false) }
        status = changed == nil ? "\(name(lane)) pane sizes reset." : "\(name(lane)) pane sizes saved."
    }
    private func setWindows(_ lane: Lane, count value: Int, split: WindowSplit?) {
        guard (1...4).contains(value), settings.capacity(lane) != value || settings.split(lane) != split else { return }
        let oldSlots = slotIDs(lane), oldIndex = activeSlot[lane] ?? 0
        let chosen = activeWindow(lane)?.id
        rememberLayout()
        settings.capacities[lane.rawValue] = value; settings.windowSplits[lane.rawValue] = split?.rawValue
        settings.useCustomGrid = true; pages[lane] = 0; selectedTemplateChanged = true
        var slots = WindowSlots.normalized(oldSlots, ids: items(lane).map(\.id), capacity: value)
        if oldIndex >= value, let chosen { slots = WindowSlots.replacing(slots, with: chosen, at: value - 1) }
        visibleSlotIDs[lane] = slots
        activeSlot[lane] = chosen.flatMap { slots.firstIndex(of: $0) } ?? min(oldIndex, value - 1)
        save()
        if trusted && canUndo && !busy { _ = apply(lane) }
        onLaneControls?()
        status = "\(name(lane)): \(split.map { WindowArrangement(count: value, split: $0).title } ?? "\(value) window\(value == 1 ? "" : "s")") shown at once. Other categories stay fixed."
    }
    func resetRules() {
        settings.appRules.removeAll(); settings.windowCategories.removeAll(); overrides.removeAll(); save(); refresh()
        selectedTemplateChanged = true
    }
}

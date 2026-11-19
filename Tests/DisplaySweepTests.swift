import AppKit
import ApplicationServices

// Every common Mac display, without the hardware. The real layout code (Model and
// WindowManager, through `displayOverride`) runs on each screen's visible area, as
// the main display and as a second display left of or above it. Every category,
// window tile and strip must stay on that screen, apart, and big enough to use.
//
// LANES_SWEEP_SHEET=path.png also draws every layout into one contact sheet.

struct SweepDisplay {
    let name: String
    let size: CGSize
    let menuBar: Double
    let dock: Double
    func visible(at origin: CGPoint) -> CGRect {
        CGRect(x: origin.x, y: origin.y + menuBar, width: size.width, height: size.height - menuBar - dock)
    }
}
struct Workload {
    let name: String
    let counts: [(Lane, Int)]
}

@MainActor struct Sweep {
    var failures: [String] = []
    var cramped: [String] = []
    // Windows under the floor: a product decision (window counts, presets), so reported, not failed.
    var tooSmall: [String] = []
    var checks = 0
    var rows: [String] = []
    // Hard floor: anything smaller is not a usable window on any Mac.
    static let floor = CGSize(width: 300, height: 200)

    mutating func expect(_ ok: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !ok { failures.append(message()) }
    }
    static func inside(_ r: CGRect, _ bounds: CGRect) -> Bool {
        r.width > 0 && r.height > 0 && r.minX >= bounds.minX - 1 && r.minY >= bounds.minY - 1 && r.maxX <= bounds.maxX + 1 && r.maxY <= bounds.maxY + 1
    }
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b); return i.isNull ? 0 : Double(i.width * i.height)
    }

    // Checks one arranged grid; returns the smallest window tile.
    @discardableResult mutating func check(_ m: WindowManager, _ label: String) -> CGSize {
        let visible = m.screenFrame
        let lanes = m.enabledLanes.filter { !m.items($0).isEmpty }
        expect(!lanes.isEmpty, "\(label): no category has windows")
        var smallest = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        var gridFrames: [(Lane, CGRect)] = []
        for lane in lanes {
            let name = m.name(lane)
            let region = m.rawLaneFrame(lane), frame = m.laneFrame(lane)
            expect(Self.inside(region, visible), "\(label): \(name) region \(region) leaves the screen \(visible)")
            expect(Self.inside(frame, visible), "\(label): \(name) window area \(frame) leaves the screen")
            if !m.settings.isFloating(lane) { gridFrames.append((lane, region)) }
            let count = min(m.settings.capacity(lane), m.items(lane).count)
            let tiles = Layout.tiles(in: frame, count: count, gap: m.settings.gap, lane: lane)
            for (i, tile) in tiles.enumerated() {
                expect(Self.inside(tile, visible), "\(label): \(name) window \(i + 1) \(tile) leaves the screen")
                let usable = AutoSorter.usableSize(lane)
                // Presets fit their window counts and Columns hides when too narrow, so
                // no window is ever too narrow; Mini players float when the grid is full.
                expect(tile.width >= usable.width, "\(label): \(name) window \(i + 1) is only \(Int(tile.width)) wide")
                if lane == .media { expect(tile.height >= usable.height, "\(label): Mini players only \(Int(tile.height)) tall") }
                if tile.height < usable.height { tooSmall.append("\(label): \(name) \(Int(tile.width))×\(Int(tile.height))") }
                for other in tiles[(i + 1)...] { expect(Self.overlap(tile, other) < 1, "\(label): two \(name) windows overlap") }
                if tile.width * tile.height < smallest.width * smallest.height { smallest = tile.size }
                let wanted = AutoSorter.minimumSize(lane)
                if tile.width < wanted.width * 0.75 || tile.height < wanted.height * 0.75 {
                    cramped.append("\(label): \(name) \(Int(tile.width))×\(Int(tile.height)) (wants \(Int(wanted.width))×\(Int(wanted.height)))")
                }
            }
            if WindowStripMetrics.needsStrip(windowCount: m.items(lane).count) {
                m.expandedStrip = nil
                let idle = m.stripFrame(lane)
                expect(Self.inside(idle, visible), "\(label): \(name) strip \(idle) leaves the screen")
                m.expandedStrip = lane
                let open = m.stripFrame(lane)
                expect(Self.inside(open, visible), "\(label): \(name) strip opened on hover \(open) leaves the screen")
                m.expandedStrip = nil
                // The same at every alignment, hugging its tabs or fitted to its windows.
                let chosen = (m.settings.stripAlignment, m.settings.stripFitsWindowWidth)
                for alignment in StripAlignment.allCases {
                    for fits in [false, true] {
                        m.settings.stripAlignment = alignment; m.settings.stripFitsWindowWidth = fits
                        m.expandedStrip = nil
                        let rest = m.stripFrame(lane)
                        expect(Self.inside(rest, visible), "\(label): \(name) strip, \(alignment.title)\(fits ? ", fitted" : ""), \(rest) leaves the screen")
                        expect(rest.size == idle.size, "\(label): \(name) idle strip changes size with \(alignment.title)\(fits ? ", fitted" : "")")
                        m.expandedStrip = lane
                        let grown = m.stripFrame(lane)
                        expect(Self.inside(grown, visible), "\(label): \(name) strip opened on hover, \(alignment.title)\(fits ? ", fitted" : ""), \(grown) leaves the screen")
                        expect(Self.overlap(grown, rest) >= Double(rest.width * rest.height) * 0.8, "\(label): \(name) strip, \(alignment.title)\(fits ? ", fitted" : ""), opens away from its pill (\(grown), pill \(rest))")
                    }
                }
                m.settings.stripAlignment = chosen.0; m.settings.stripFitsWindowWidth = chosen.1
                m.expandedStrip = nil
            }
        }
        for (i, a) in gridFrames.enumerated() {
            for b in gridFrames[(i + 1)...] {
                expect(Self.overlap(a.1, b.1) < 1, "\(label): \(m.name(a.0)) and \(m.name(b.0)) overlap")
            }
        }
        let covered = gridFrames.map { Double($0.1.width * $0.1.height) }.reduce(0, +) / Double(visible.width * visible.height)
        expect(covered > 0.85, "\(label): the grid fills only \(Int(covered * 100))% of the screen")
        return smallest
    }
}

@main struct DisplaySweepTests {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)   // keep the report when a precondition stops the run
        let displays: [SweepDisplay] = [
            SweepDisplay(name: "13\" MacBook Air (Intel)", size: CGSize(width: 1280, height: 800), menuBar: 24, dock: 60),
            SweepDisplay(name: "13\" MacBook Air", size: CGSize(width: 1470, height: 956), menuBar: 33, dock: 60),
            SweepDisplay(name: "14\" MacBook Pro", size: CGSize(width: 1512, height: 982), menuBar: 33, dock: 0),
            SweepDisplay(name: "16\" MacBook Pro", size: CGSize(width: 1728, height: 1117), menuBar: 33, dock: 70),
            SweepDisplay(name: "1080p monitor", size: CGSize(width: 1920, height: 1080), menuBar: 24, dock: 70),
            SweepDisplay(name: "1440p / Studio Display", size: CGSize(width: 2560, height: 1440), menuBar: 24, dock: 70),
            SweepDisplay(name: "4K at full resolution", size: CGSize(width: 3840, height: 2160), menuBar: 24, dock: 70),
            SweepDisplay(name: "21:9 ultrawide", size: CGSize(width: 3440, height: 1440), menuBar: 24, dock: 0),
            SweepDisplay(name: "24:10 ultrawide", size: CGSize(width: 3840, height: 1600), menuBar: 24, dock: 0),
            SweepDisplay(name: "32:9 ultrawide", size: CGSize(width: 5120, height: 1440), menuBar: 24, dock: 0),
            SweepDisplay(name: "5K2K ultrawide", size: CGSize(width: 5120, height: 2160), menuBar: 24, dock: 0),
            SweepDisplay(name: "Portrait 1080p", size: CGSize(width: 1080, height: 1920), menuBar: 24, dock: 0),
            SweepDisplay(name: "Portrait 1440p", size: CGSize(width: 1440, height: 2560), menuBar: 24, dock: 0),
        ]
        let workloads = [
            Workload(name: "light", counts: [(.browser, 2), (.terminal, 2)]),
            Workload(name: "typical", counts: [(.browser, 3), (.terminal, 4), (.messaging, 2), (.preview, 1)]),
            Workload(name: "heavy", counts: [(.browser, 5), (.terminal, 6), (.messaging, 3), (.preview, 2), (.desktop, 2), (.simulator, 1), (.media, 1)]),
        ]
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-display-sweep-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func windows(_ workload: Workload, on screen: CGRect) -> [ManagedWindow] {
            workload.counts.flatMap { lane, count in
                (0..<count).map { i in
                    ManagedWindow(id: "\(lane.rawValue)-\(i)", element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "test.\(lane.rawValue)", appName: lane.title, title: "\(lane.title) \(i + 1)", icon: nil, frame: CGRect(x: screen.minX + 40, y: screen.minY + 40, width: 900, height: 700), minimized: false, lane: lane)
                }
            }
        }
        var sweep = Sweep()
        var sheet: [(SweepDisplay, [(String, WindowManager)])] = []
        var hidden: [String: [String]] = [:]
        let main = CGPoint.zero
        for display in displays {
            let kind = DisplayKind.of(display.size)
            let expectedWide = display.size.width / display.size.height >= 2
            sweep.expect(kind == (expectedWide ? .wide : .standard), "\(display.name): counted as \(kind)")
            // Main display, a second display to the left of a MacBook, and one above it.
            let placements: [(String, CGPoint)] = [("main", main), ("left", CGPoint(x: -display.size.width, y: 0)), ("above", CGPoint(x: 0, y: -display.size.height))]
            var cells: [(String, WindowManager)] = []
            var smallest: [String: CGSize] = [:]
            for (place, origin) in placements {
                let visible = display.visible(at: origin)
                let key = "\(display.name) \(Int(display.size.width))×\(Int(display.size.height))"
                // A new install on this display.
                do {
                    let m = WindowManager(settingsFile: fixture.appendingPathComponent("\(UUID().uuidString).json"), startPolling: false)
                    m.settings = .firstRun
                    m.displayOverride = visible
                    m.windows = windows(workloads[1], on: visible)
                    m.settings.switchDisplay(to: key, kind: kind, fresh: true)
                    let label = "\(display.name) [\(place)] new install"
                    sweep.check(m, label)
                    if place == "main" { cells.append(("New install", m)) }
                }
                // Organize with auto layout, the way autoOrganize does it.
                for workload in workloads {
                    let m = WindowManager(settingsFile: fixture.appendingPathComponent("\(UUID().uuidString).json"), startPolling: false)
                    m.displayOverride = visible
                    m.windows = windows(workload, on: visible)
                    m.settings.switchDisplay(to: key, kind: kind)
                    // refresh(restorePopulatedCategories:) brings every category with windows into the grid.
                    let populated = Set(workload.counts.map(\.0))
                    m.settings.shelvedLanes = []
                    m.settings.hiddenLanes = m.availableLanes.filter { !populated.contains($0) }.map(\.rawValue)
                    m.settings.showMediaShelf = populated.contains(.media)
                    m.applyAutoSort(m.autoSortPlan(focused: .browser))
                    let label = "\(display.name) [\(place)] Organize, \(workload.name)"
                    let tile = sweep.check(m, label)
                    if place == "main" { cells.append(("Organize · \(workload.name)", m)); smallest[workload.name] = tile }
                }
                // Every preset the Lanes window offers on this display, applied the way
                // Apply does it, with the typical workload and default window counts.
                let lanes = workloads[1].counts.map(\.0)
                func presetManager() -> WindowManager {
                    let m = WindowManager(settingsFile: fixture.appendingPathComponent("\(UUID().uuidString).json"), startPolling: false)
                    m.displayOverride = visible
                    m.windows = windows(workloads[1], on: visible)
                    m.settings.shelvedLanes = []
                    m.settings.hiddenLanes = m.availableLanes.filter { !lanes.contains($0) }.map(\.rawValue)
                    m.settings.showMediaShelf = false
                    m.selectedLane = .browser
                    return m
                }
                let offered = presetManager().presetShapes
                if place == "main" { hidden[display.name] = PresetShape.shapes(for: kind).filter { !offered.contains($0) }.map(\.title) }
                for shape in offered {
                    let m = presetManager()
                    m.previewPreset(shape)
                    sweep.expect(m.commitPendingGrid(), "\(display.name) [\(place)] \(shape.title): Apply refused the preset")
                    sweep.check(m, "\(display.name) [\(place)] preset \(shape.title)")
                }
            }
            func size(_ s: CGSize?) -> String { s.map { "\(Int($0.width))×\(Int($0.height))" } ?? "-" }
            sweep.rows.append("\(display.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \("\(Int(display.size.width))×\(Int(display.size.height))".padding(toLength: 10, withPad: " ", startingAt: 0)) \(kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) smallest window: light \(size(smallest["light"])), typical \(size(smallest["typical"])), heavy \(size(smallest["heavy"]))" + (hidden[display.name]?.isEmpty == false ? " · hides \(hidden[display.name]!.joined(separator: ", "))" : ""))
            sheet.append((display, cells))
        }

        // Windows that hang across two displays belong to the one holding most of them.
        let macBook = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for (name, external) in [("left", CGRect(x: -2560, y: -229, width: 2560, height: 1440)), ("right", CGRect(x: 1512, y: 0, width: 3440, height: 1440)), ("above", CGRect(x: -304, y: -1080, width: 1920, height: 1080))] {
            let displays = [macBook, external]
            let onExternal = CGRect(x: external.midX - 400, y: external.midY - 300, width: 800, height: 600)
            sweep.expect(WindowDisplay.owner(of: onExternal, displays: displays) == 1, "a window on the \(name) display belongs to it")
            let mostlyMain = CGRect(x: name == "left" ? -200 : name == "right" ? 912 : 100, y: name == "above" ? -150 : 100, width: 800, height: 600)
            sweep.expect(WindowDisplay.owner(of: mostlyMain, displays: displays) == 0, "a window mostly on the MacBook stays with it when the \(name) display is attached")
            let lost = CGRect(x: external.minX - 5000, y: external.minY, width: 300, height: 300)
            sweep.expect(WindowDisplay.owner(of: lost, displays: displays) != nil, "a window off every display still gets a display")
        }

        print("Display sweep (\(displays.count) displays × main, left and above):")
        sweep.rows.forEach { print("  " + $0) }
        var small = Set<String>()
        let tooSmall = sweep.tooSmall.filter { $0.contains("[main]") }.map { $0.replacingOccurrences(of: " [main]", with: "") }.filter { small.insert($0).inserted }
        if !tooSmall.isEmpty {
            print("Windows under their usable size (\(tooSmall.count), main display; same on left and above):")
            tooSmall.forEach { print("  " + $0) }
        }
        if let path = ProcessInfo.processInfo.environment["LANES_SWEEP_SHEET"] { drawSheet(sheet, to: path) }
        // The same layout as main, left and above: one line, plus any line that
        // only happens away from the main display (a coordinate bug).
        func unplaced(_ s: String) -> String { s.replacingOccurrences(of: " [left]", with: "").replacingOccurrences(of: " [above]", with: "").replacingOccurrences(of: " [main]", with: "") }
        var seen = Set<String>(), unique: [String] = []
        for f in sweep.failures where seen.insert(unplaced(f)).inserted { unique.append(unplaced(f)) }
        let mainOnly = Set(sweep.failures.filter { $0.contains("[main]") }.map(unplaced))
        let placementOnly = sweep.failures.filter { !$0.contains("[main]") && !mainOnly.contains(unplaced($0)) }
        if !unique.isEmpty {
            print("FAILURES (\(unique.count) distinct, \(placementOnly.count) only on a second display):")
            unique.forEach { print("  " + $0) }
            placementOnly.forEach { print("  second display only: " + $0) }
        }
        precondition(sweep.failures.isEmpty, "\(unique.count) distinct display sweep failures (listed above)")
        print("PASS: display sweep — \(sweep.checks) checks: every category, window and strip stays on screen and apart on \(displays.count) displays as main, left and above")
    }

    @MainActor static func drawSheet(_ sheet: [(SweepDisplay, [(String, WindowManager)])], to path: String) {
        let cellW = 360.0, cellH = 230.0, pad = 18.0, header = 22.0, rowLabel = 210.0
        let columns = sheet.map(\.1.count).max() ?? 1
        let width = rowLabel + Double(columns) * (cellW + pad) + pad
        let height = pad + header + Double(sheet.count) * (cellH + pad)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor(white: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
            let colors: [String: NSColor] = ["browser": .systemBlue, "terminal": .systemGreen, "messaging": .systemPurple, "preview": .systemOrange, "desktop": .systemGray, "simulator": .systemTeal, "media": .systemPink]
            func text(_ s: String, _ at: NSPoint, size: CGFloat = 11, color: NSColor = .white, bold: Bool = false) {
                (s as NSString).draw(at: at, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color])
            }
            if let titles = sheet.first?.1.map(\.0) {
                for (c, t) in titles.enumerated() { text(t, NSPoint(x: rowLabel + Double(c) * (cellW + pad), y: pad), size: 12, bold: true) }
            }
            for (r, (display, cells)) in sheet.enumerated() {
                let top = pad + header + Double(r) * (cellH + pad)
                text(display.name, NSPoint(x: pad, y: top + 4), size: 13, bold: true)
                text("\(Int(display.size.width))×\(Int(display.size.height)) · \(DisplayKind.of(display.size).rawValue)", NSPoint(x: pad, y: top + 22), color: .lightGray)
                for (c, (_, m)) in cells.enumerated() {
                    let box = NSRect(x: rowLabel + Double(c) * (cellW + pad), y: top, width: cellW, height: cellH)
                    let scale = min(box.width / display.size.width, box.height / display.size.height)
                    let full = NSRect(x: box.minX, y: box.minY, width: display.size.width * scale, height: display.size.height * scale)
                    NSColor(white: 0.22, alpha: 1).setFill(); NSBezierPath(rect: full).fill()
                    let screen = m.screenFrame
                    func map(_ r: CGRect) -> NSRect { NSRect(x: full.minX + (r.minX - screen.minX) * scale, y: full.minY + (r.minY - screen.minY + display.menuBar) * scale, width: r.width * scale, height: r.height * scale) }
                    let lanes = m.enabledLanes.filter { !m.items($0).isEmpty }
                    for lane in lanes.sorted(by: { !m.settings.isFloating($0) && m.settings.isFloating($1) }) {
                        let color = colors[lane.rawValue] ?? .systemYellow
                        let region = map(m.rawLaneFrame(lane))
                        color.withAlphaComponent(0.28).setFill(); NSBezierPath(rect: region).fill()
                        let count = min(m.settings.capacity(lane), m.items(lane).count)
                        for tile in Layout.tiles(in: m.laneFrame(lane), count: count, gap: m.settings.gap, lane: lane) {
                            color.setStroke(); let p = NSBezierPath(rect: map(tile).insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
                        }
                        if WindowStripMetrics.needsStrip(windowCount: m.items(lane).count) {
                            color.setFill(); NSBezierPath(roundedRect: map(m.stripFrame(lane)), xRadius: 2, yRadius: 2).fill()
                        }
                        if region.width > 40 { text("\(m.name(lane)) ×\(m.items(lane).count)", NSPoint(x: region.minX + 3, y: region.minY + 6), size: 9) }
                    }
                }
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Contact sheet: \(path)")
    }
}

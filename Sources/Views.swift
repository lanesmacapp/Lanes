import SwiftUI
import UniformTypeIdentifiers

// AppKit supplies the effective appearance for the board, sheets, and floating strips.
private func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

func paletteColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: adaptiveColor(
        light: NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1),
        dark: NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
    ))
}

let surfaceColor = adaptiveColor(
    light: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.94, alpha: 1),
    dark: NSColor(srgbRed: 0.075, green: 0.09, blue: 0.083, alpha: 1)
)
let surface = Color(nsColor: surfaceColor)
let ink = paletteColor(light: (0.13, 0.17, 0.13), dark: (0.89, 0.90, 0.86))
let muted = paletteColor(light: (0.32, 0.38, 0.32), dark: (0.51, 0.55, 0.52))
let accent = paletteColor(light: (0.27, 0.40, 0.18), dark: (0.75, 0.88, 0.58))
let onAccent = Color(nsColor: adaptiveColor(light: .white, dark: .black))
let neutralOverlay = paletteColor(light: (0.10, 0.17, 0.11), dark: (1, 1, 1))
let chromeShade = Color(nsColor: adaptiveColor(light: NSColor(white: 0, alpha: 0.35), dark: .black))
let stripCloseTint = adaptiveColor(light: NSColor(white: 0.32, alpha: 1), dark: NSColor(white: 0.8, alpha: 1))

private let categoryColors: [Lane: Color] = [
    .terminal: paletteColor(light: (0.28, 0.41, 0.17), dark: (0.70, 0.82, 0.56)),
    .simulator: paletteColor(light: (0.25, 0.37, 0.63), dark: (0.63, 0.73, 0.94)),
    .preview: paletteColor(light: (0.52, 0.30, 0.16), dark: (0.91, 0.68, 0.49)),
    .browser: paletteColor(light: (0.21, 0.36, 0.56), dark: (0.64, 0.76, 0.96)),
    .desktop: paletteColor(light: (0.41, 0.29, 0.57), dark: (0.72, 0.65, 0.85)),
    .messaging: paletteColor(light: (0.17, 0.40, 0.37), dark: (0.52, 0.79, 0.77)),
    .media: paletteColor(light: (0.44, 0.34, 0.13), dark: (0.89, 0.77, 0.47))
]
private let customCategoryColor = paletteColor(light: (0.27, 0.37, 0.58), dark: (0.69, 0.77, 0.93))

extension Lane {
    var color: Color { categoryColors[self] ?? customCategoryColor }
}

// The grid's header line: a title at the left, the display dropdown at the right
// and, when the display has more than one desktop, the desktop row right under
// the dropdown.
struct DisplayHeader<Title: View>: View {
    @ObservedObject var manager: WindowManager
    @ViewBuilder var title: Title
    var body: some View {
        DisplayHeaderLayout {
            title
            DisplayMenu(manager: manager)
            if DesktopRow.isShown(manager) { DesktopRow(manager: manager) }
        }
    }
}
// Places the title, the dropdown and the row. The first line is what it always
// was (title left, dropdown right, centered on each other). The row gets the
// dropdown's width and no more, so it can never widen that column or wrap.
struct DisplayHeaderLayout: SwiftUI.Layout {   // Lanes has a Layout of its own
    static let rowGap: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let title = subviews[0].sizeThatFits(.unspecified), menu = subviews[1].sizeThatFits(.unspecified)
        var height = max(title.height, menu.height)
        if subviews.count > 2 { height += Self.rowGap + subviews[2].sizeThatFits(ProposedViewSize(width: menu.width, height: nil)).height }
        let natural = title.width + 12 + menu.width
        return CGSize(width: proposal.width.map { $0.isFinite ? max($0, menu.width) : natural } ?? natural, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let title = subviews[0].sizeThatFits(.unspecified), menu = subviews[1].sizeThatFits(.unspecified)
        let line = max(title.height, menu.height)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + line / 2), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + line / 2), anchor: .trailing, proposal: .unspecified)
        guard subviews.count > 2 else { return }
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + line + Self.rowGap), anchor: .topTrailing, proposal: ProposedViewSize(width: menu.width, height: nil))
    }
}
struct DisplayMenu: View {
    @ObservedObject var manager: WindowManager
    var body: some View {
        Menu {
            ForEach(manager.screens, id: \.self) { screen in
                Button("\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))") {
                    manager.changeScreen(WindowManager.displayID(screen))
                }
            }
        } label: {
            HStack(spacing: 5) { Image(systemName: "display"); Text(manager.displayLabel); Image(systemName: "chevron.down").font(.system(size: 8)) }
                .font(.system(size: 10)).foregroundStyle(muted)
        }.menuStyle(.borderlessButton).fixedSize()
            .help("Each display keeps its own grid. Lanes switches when you plug in or unplug a display.")
    }
}
// "Desktop 1 2 3 4": the desktops of the display in Mission Control's order. The
// selected number (the look of a selected preset) is the desktop whose grid the
// editor shows; when that is not the desktop you are on, yours is underlined.
struct DesktopRow: View {
    @ObservedObject var manager: WindowManager
    // One desktop needs no row.
    static func isShown(_ manager: WindowManager) -> Bool { manager.desktops.count > 1 }
    static let height: CGFloat = 16
    // Every number has the same width, with room for two digits.
    static let buttonWidth: CGFloat = 20, spacing: CGFloat = 2
    var numbers: some View {
        HStack(spacing: Self.spacing) {
            ForEach(manager.desktops) { desktop in
                DesktopButton(number: desktop.number, shown: desktop.id == (manager.shownDesktop ?? manager.activeDesktop), current: desktop.id == manager.activeDesktop, hasDraft: manager.hasUnappliedChanges(on: desktop.id)) { manager.showDesktop(desktop.id) }
                    .id(desktop.id)
            }
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Text("Desktop").font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).fixedSize()
            // Too many to fit under the dropdown: the numbers scroll; the type never shrinks or wraps.
            ViewThatFits(in: .horizontal) {
                numbers
                ScrollViewReader { proxy in
                    // .never: a scroll bar that always shows (a mouse is connected) would take a line of its own.
                    ScrollView(.horizontal) { numbers }.scrollIndicators(.never)
                        .onAppear { if let shown = manager.shownDesktop ?? manager.activeDesktop { proxy.scrollTo(shown, anchor: .center) } }
                        .onChange(of: manager.shownDesktop) { _, shown in if let shown { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(shown, anchor: .center) } } }
                }
            }
        }.frame(height: Self.height)
            .accessibilityElement(children: .contain).accessibilityLabel("Desktop layouts")
    }
}
struct DesktopButton: View {
    let number: Int
    let shown: Bool      // its grid is in the editor
    let current: Bool    // the desktop you are on
    var hasDraft = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("\(number)").font(.system(size: 11, weight: .medium).monospacedDigit()).lineLimit(1)
                .foregroundStyle(shown ? accent : hovering || current ? ink : muted)
                .frame(width: DesktopRow.buttonWidth, height: DesktopRow.height)
                .background(RoundedRectangle(cornerRadius: 3).fill(shown ? accent.opacity(0.08) : neutralOverlay.opacity(hovering ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(accent.opacity(shown ? 0.35 : 0)))
                .overlay(alignment: .bottom) { if current && !shown { Capsule().fill(accent).frame(width: 8, height: 1.5).padding(.bottom, 1) } }
                .overlay(alignment: .topTrailing) { if hasDraft { Circle().fill(accent).frame(width: 3, height: 3).padding(2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .help(shown ? (current ? "Desktop \(number): the desktop you are on. Its grid is shown." : "Desktop \(number): its grid is shown. Apply saves changes for this desktop only.") : (current ? "Desktop \(number): the desktop you are on. Click to show its grid." : "Show the grid saved for Desktop \(number)."))
            .accessibilityLabel("Desktop \(number)")
            .accessibilityValue([shown ? "Shown" : nil, current ? "Current desktop" : nil, hasDraft ? "Unapplied changes" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

struct CapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var primary = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14).frame(height: 34)
            .foregroundStyle(primary ? onAccent : ink)
            .background(primary ? accent : neutralOverlay.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(neutralOverlay.opacity(primary ? 0 : 0.09)))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

struct BoardView: View {
    @ObservedObject var manager: WindowManager
    @State private var showSettings = false
    @State private var search = ""
    @State private var showSaveLayout = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Rectangle().fill(neutralOverlay.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(neutralOverlay.opacity(0.07)).frame(height: 1)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 21) {
                            if !manager.trusted { permissionBanner.tourSpot(.permission) }
                            gridSection.tourSpot(.grid)
                            CategoryBoard(manager: manager).tourSpot(.windows).id("tour-windows")
                        }.padding(.horizontal, 26).padding(.vertical, 18).id("tour-top")
                    }
                    // The tour scrolls the part it explains into view.
                    .onChange(of: manager.tourStep) { _, index in
                        guard let index, manager.tourSteps.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scroll.scrollTo(manager.tourSteps[index].spot == .windows ? "tour-windows" : "tour-top", anchor: .top)
                        }
                    }
                }
                footer
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(surface).foregroundStyle(ink)
        .sheet(isPresented: $showSaveLayout) { SaveLayoutView(manager: manager) }
        .sheet(isPresented: $showSettings) { SettingsView(manager: manager) }
        .sheet(item: $manager.renameTarget) { lane in NewCategoryView(manager: manager, renameLane: lane) }
        .sheet(isPresented: Binding(get: { manager.renameWindowID != nil }, set: { if !$0 { manager.renameWindowID = nil } })) { RenameWindowView(manager: manager) }
        .sheet(isPresented: $manager.showAccessHelp, onDismiss: manager.accessHelpDismissed) { AccessHelpView(manager: manager) }
        .overlayPreferenceValue(TourAnchors.self) { anchors in TourOverlay(manager: manager, anchors: anchors) }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                Text("lanes").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-1)
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 32)
            Text("YOUR WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(muted).padding(.horizontal, 22).padding(.bottom, 14)
            ScrollView { VStack(spacing: 0) {
            ForEach(Array((manager.viewingOtherDesktop ? manager.gridLanes : manager.enabledLanes).enumerated()), id: \.element.id) { index, lane in
                Button {
                    manager.selectGridCategory(lane); search = ""
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: lane.symbol).font(.system(size: 14)).foregroundStyle(lane.color).frame(width: 18)
                        Text(manager.name(lane)).font(.system(size: 12, weight: manager.selectedLane == lane ? .semibold : .regular))
                        Spacer()
                        Text(manager.discoveryCount(lane)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    }.padding(.horizontal, 12).frame(height: 40)
                    .background(manager.selectedLane == lane ? neutralOverlay.opacity(0.06) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3)
                .draggable("lane:" + lane.rawValue)
                .help(Lane.allCases.firstIndex(of: lane).map { "Cycle windows: Control–Option–Command–\($0 + 1)" } ?? "Focus a window here, then Control–Option–Command–Tab to cycle")
                .contextMenu { Button("Rename category…") { manager.renameTarget = lane }; Button("Delete category", role: .destructive) { manager.editGrid { manager.removeCategory(lane) } }.disabled(manager.enabledLanes.count <= 1) }
                .dropDestination(for: String.self) { values, _ in
                    guard values.contains(where: { $0.hasPrefix("lane:") }) else { return manager.receiveDrop(values, into: lane) }
                    var placed = false; manager.editGrid { placed = manager.receiveDrop(values, into: lane) }; return placed
                }
            }
            }}.frame(maxHeight: .infinity).tourSpot(.categories)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(manager.trusted ? accent : Color.orange).frame(width: 6, height: 6)
                    Text(manager.trusted ? "Window control ready" : "Window control needed").font(.system(size: 10)).foregroundStyle(muted)
                }
                Text("A little order.\nA lot more headspace.").font(.system(size: 16, weight: .medium)).lineSpacing(4).foregroundStyle(ink.opacity(0.72))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Lanes from any app").font(.system(size: 10)).foregroundStyle(muted)
                    Text(manager.settings.openShortcut.spoken).font(.system(size: 10, weight: .medium)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
                    Text("or click the Lanes icon in the menu bar").font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }.tourSpot(.openLanes)
            }.padding(20)
            Rectangle().fill(neutralOverlay.opacity(0.07)).frame(height: 1)
            Button { showSettings = true } label: {
                HStack(spacing: 9) { Image(systemName: "slider.horizontal.3"); Text("Preferences").lineLimit(1); Spacer() }
                    .font(.system(size: 11)).padding(20)
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command).tourSpot(.preferences)
        }.background(chromeShade.opacity(0.14))
    }
    // One slim row: what Lanes sees, then the two actions that move windows.
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Room to think.").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
            Text(manager.trusted ? "\(manager.windows.count) \(manager.windows.count == 1 ? "window" : "windows")  ·  \(manager.enabledLanes.count) \(manager.enabledLanes.count == 1 ? "lane" : "lanes")" : "\(manager.runningApps.count) running apps  ·  window access needed").font(.system(size: 11)).foregroundStyle(muted)
            Spacer()
            CapsuleButton(title: "Restore", symbol: "arrow.uturn.backward", disabled: !manager.canRestoreFromBoard) { manager.undo(fromBoard: true) }
                .help(manager.viewingOtherDesktop
                      ? "Switch to \(manager.desktopName(manager.shownDesktop)) in Mission Control to restore its windows."
                      : "Put the windows on this desktop back where they were before Lanes arranged them.")
                .tourSpot(.restore)
            CapsuleButton(title: manager.viewingOtherDesktop ? "Apply" : "Organize", symbol: "rectangle.3.group", primary: true,
                          disabled: manager.busy || (!manager.viewingOtherDesktop && !manager.trusted)) { manager.organizeFromBoard() }
                .tourSpot(.organize)
                .help(manager.viewingOtherDesktop ? "Save the grid for \(manager.desktopName(manager.shownDesktop))." :
                      "Organize open windows while keeping your edited grid. Use Auto layout to choose new sizes. Control–Option–Command–Return; Right Command twice by default.")
        }.padding(.horizontal, 26).padding(.vertical, 13)
    }
    func presetChip(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(active ? accent : ink.opacity(0.8))
                .background(active ? accent.opacity(0.08) : neutralOverlay.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? accent.opacity(0.35) : neutralOverlay.opacity(0.07)))
        }.buttonStyle(.plain)
    }
    var permissionBanner: some View {
        HStack(spacing: 13) {
            Image(systemName: "hand.raised").font(.system(size: 20)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Let Lanes arrange your windows").font(.system(size: 12, weight: .semibold))
                Text("Turn on Lanes in System Settings. Lanes reads window titles, moves and resizes windows, and brings the one you pick forward. Nothing leaves your Mac.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            CapsuleButton(title: "Open System Settings", primary: true) { manager.requestAccess() }
            Button("Help") { manager.showAccessHelp = true }.font(.system(size: 11))
        }.padding(16).background(accent.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.18)))
    }
    var gridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisplayHeader(manager: manager) {
                Text("THE GRID · PRESETS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(manager.presetShapes) { shape in
                        presetChip(shape.title, symbol: shape.symbol, active: manager.presetPreview?.shape == shape) { manager.previewPreset(shape) }
                            .help(shape.subtitle + (shape == .overlay ? ". Floating categories come on top when you switch to one of their windows." : ". The main category is the one selected in the sidebar."))
                    }
                    if !manager.settings.savedLayouts.isEmpty { Rectangle().fill(neutralOverlay.opacity(0.1)).frame(width: 1, height: 22) }
                    ForEach(manager.settings.savedLayouts) { layout in
                        presetChip(layout.name, symbol: "square.grid.2x2", active: manager.presetPreview?.savedID == layout.id) { manager.previewSavedLayout(layout) }
                            .help("Your preset. Click to preview it.")
                            .contextMenu { Button("Delete preset", role: .destructive) { if manager.presetPreview?.savedID == layout.id { manager.presetPreview = nil }; manager.deleteSavedLayout(layout.id) } }
                    }
                    Button { showSaveLayout = true } label: { Label("Save as preset…", systemImage: "plus") }.font(.system(size: 11))
                        .help("Save the current grid, its categories and windows shown at once as your own preset")
                }
            }.scrollIndicators(.hidden)
            if let preview = manager.presetPreview {
                HStack(spacing: 10) {
                    Image(systemName: "eye").foregroundStyle(accent)
                    Text("Previewing \(preview.name). Nothing on your screen has changed.").font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { manager.presetPreview = nil }.font(.system(size: 11)).keyboardShortcut(.cancelAction)
                    Button { manager.applyPresetPreview() } label: {
                        Text("Apply").font(.system(size: 11, weight: .semibold)).foregroundStyle(surface).padding(.horizontal, 14).padding(.vertical, 6).background(accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.vertical, 10).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.25)))
            }
            if manager.hasGridEdits && manager.presetPreview == nil {
                HStack(spacing: 10) {
                    Image(systemName: "pencil").foregroundStyle(accent)
                    Text(manager.viewingOtherDesktop ? "You changed the grid of \(manager.desktopName(manager.shownDesktop)). Apply saves it for that desktop; nothing on your screen changes." : "You changed the grid. Nothing on your screen has changed yet.").font(.system(size: 11))
                    Spacer()
                    Button("Discard") { manager.discardGridDraft() }.font(.system(size: 11))
                    Button { manager.applyGridDraft() } label: {
                        Text("Apply").font(.system(size: 11, weight: .semibold)).foregroundStyle(surface).padding(.horizontal, 14).padding(.vertical, 6).background(accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.vertical, 10).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.25)))
            }
            GridEditor(manager: manager)
            HStack {
                Text(manager.settings.doubleRightCommand ? "Right Command twice → Organize" : "Control + Option + Command + Return → Organize").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Text(manager.grid.useCustomGrid ? "Custom grid · Organize keeps your sizes" : "Automatic grid")
                    .font(.system(size: 10)).foregroundStyle(manager.selectedTemplateChanged ? accent : muted)
            }
        }
    }
    var filteredWindows: [ManagedWindow] {
        manager.items(manager.selectedLane).filter { search.isEmpty || (manager.windowLabel($0) + $0.title + $0.appName).localizedCaseInsensitiveContains(search) }
    }
    var windowSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: manager.selectedLane.symbol).foregroundStyle(manager.selectedLane.color)
                    Text(manager.name(manager.selectedLane)).font(.system(size: 16, weight: .medium))
                    Text(manager.discoveryCount(manager.selectedLane)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(neutralOverlay.opacity(0.05)).clipShape(Capsule())
                }
                Spacer()
                HStack(spacing: 5) {
                    Text("Windows shown at once").font(.system(size: 10)).foregroundStyle(muted)
                    Picker("Windows shown at once", selection: Binding(get: { manager.grid.capacity(manager.selectedLane) }, set: { value in manager.editGrid { manager.setCapacity(manager.selectedLane, value) } })) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: 52)
                }
                if manager.selectedLane == .browser {
                    Button("Side by side") { manager.editGrid { manager.setCapacity(.browser, 2) } }
                        .font(.system(size: 10)).disabled(manager.grid.capacity(.browser) == 2)
                        .help("Show two separate browser windows next to each other")
                }
                Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(muted) }.buttonStyle(.plain).padding(.leading, 10).help("Refresh open windows")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(muted)
                TextField(manager.trusted ? "Find a window in \(manager.name(manager.selectedLane).lowercased())…" : "Find an app in \(manager.name(manager.selectedLane).lowercased())…", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(muted) }.buttonStyle(.plain) }
            }.padding(10).background(neutralOverlay.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6))
            if !manager.trusted {
                appDiscovery
            } else if filteredWindows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: manager.selectedLane.symbol).font(.system(size: 25)).foregroundStyle(manager.selectedLane.color.opacity(0.4))
                    Text(manager.trusted ? (search.isEmpty ? "No windows in this lane yet" : "No matching windows") : "Your open windows will appear here").font(.system(size: 12, weight: .medium))
                    Text(manager.trusted ? "Open an app, refresh, or move a window here from another lane." : "Enable window control to discover and arrange them.").font(.system(size: 10)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 23).background(neutralOverlay.opacity(0.018)).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 1) {
                    ForEach(filteredWindows) { window in
                        WindowRow(manager: manager, window: window)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(manager.selectedLane.hint).font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                if manager.trusted { pageControls } else { Text("Apps only · enable access for individual windows").font(.system(size: 10)).foregroundStyle(muted) }
            }
        }.simultaneousGesture(TapGesture().onEnded { manager.gridSelectionActive = false })
    }
    var appDiscovery: some View {
        let apps = manager.apps(manager.selectedLane).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.open").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running apps are visible; window access is not recognized").font(.system(size: 12, weight: .medium))
                    Text("Enable Lanes in the macOS permission panel to see window titles and organize them.")
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                CapsuleButton(title: "Enable window control", primary: true) { manager.requestAccess() }
            Button("Access help") { manager.showAccessHelp = true }.font(.system(size: 11))
            }.padding(14).background(accent.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 8))
            if apps.isEmpty {
                Text(search.isEmpty ? "No running apps assigned to this category. Try another category." : "No matching apps.")
                    .font(.system(size: 11)).foregroundStyle(muted).padding(.vertical, 14)
            } else {
                VStack(spacing: 1) {
                    ForEach(apps) { app in
                        HStack(spacing: 11) {
                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 25, height: 25) }
                            Text(app.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("RUNNING APP").font(.system(size: 8)).tracking(0.5).foregroundStyle(muted)
                            Button("Show app") { manager.activateApp(app) }.font(.system(size: 10))
                            Menu {
                                Section("Always send \(app.name) to") {
                                    ForEach(manager.enabledLanes) { lane in Button(manager.name(lane)) { manager.assignApp(app, to: lane) } }
                                }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(muted) }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.horizontal, 12).padding(.vertical, 11).background(neutralOverlay.opacity(0.035))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    var pageControls: some View {
        HStack(spacing: 10) {
            Button { manager.cycle(manager.selectedLane, delta: -1) } label: { Image(systemName: "chevron.left").font(.system(size: 10)) }.buttonStyle(.plain).disabled(manager.items(manager.selectedLane).isEmpty)
            Text(manager.windowCounter(manager.selectedLane)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            Button { manager.cycle(manager.selectedLane) } label: { Image(systemName: "chevron.right").font(.system(size: 10)) }.buttonStyle(.plain).disabled(manager.items(manager.selectedLane).isEmpty)
        }
    }
    var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.canUndo ? "checkmark.circle" : "circle.dotted").foregroundStyle(accent)
            Text(manager.status).lineLimit(2).font(.system(size: 10)).foregroundStyle(muted)
            Spacer(minLength: 8)
            Text("LOCAL. QUIET. YOURS.").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(muted.opacity(0.6))
        }.padding(.horizontal, 26).frame(minHeight: 44).background(chromeShade.opacity(0.12))
    }
}

struct WindowActionsMenu: View {
    @ObservedObject var manager: WindowManager
    let window: ManagedWindow
    var body: some View {
        Button("Minimize Window") { manager.minimizeWindow(window) }
            .disabled(!manager.trusted || window.minimized)
        Button("Close Window", role: .destructive) { manager.closeWindow(window) }
            .disabled(!manager.trusted)
    }
}

struct WindowRow: View {
    @ObservedObject var manager: WindowManager
    let window: ManagedWindow
    var visible: Bool { manager.visibleItems(window.lane).contains(where: { $0.id == window.id }) }
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(muted.opacity(0.5)).frame(width: 9)
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 25, height: 25) }
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.windowLabel(window)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(window.appName).font(.system(size: 9)).foregroundStyle(muted)
            }
            Spacer()
            Text(window.minimized ? "MINIMIZED" : visible ? "VISIBLE" : "STACKED").font(.system(size: 8, weight: .medium)).tracking(0.6)
                .foregroundStyle(visible ? window.lane.color : muted).padding(.horizontal, 7).padding(.vertical, 4)
                .background((visible ? window.lane.color : muted).opacity(0.07)).clipShape(Capsule())
            Menu {
                Section("Move this window to") {
                    ForEach(manager.enabledLanes) { lane in Button(manager.name(lane)) { manager.assign(window, to: lane) } }
                }
                Section("Always send \(window.appName) to") {
                    ForEach(manager.enabledLanes) { lane in Button(manager.name(lane)) { manager.assign(window, to: lane, rememberApp: true) } }
                }
                Button("Show window") { manager.reveal(window) }
                Button("Rename tab…") { manager.beginRenamingWindow(window) }
                Divider()
                WindowActionsMenu(manager: manager, window: window)
            } label: { Image(systemName: "ellipsis").foregroundStyle(muted).frame(width: 20, height: 25) }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, 12).padding(.vertical, 10).background(neutralOverlay.opacity(0.035))
            .contentShape(Rectangle()).onTapGesture(count: 2) { manager.reveal(window) }
            .contextMenu {
                Button("Show window") { manager.reveal(window) }
                WindowActionsMenu(manager: manager, window: window)
            }
            .draggable(window.id)
            .modifier(WindowRowDropTarget { values, after in manager.reorderTab(values, before: window, after: after) })
            .help("Double-click to show. Drag above or below another window to save its order, or drag to another category to reassign.")
    }
}

// Both window lists use the whole row as a target, including its lower half so
// a window can be dragged to the very end of the saved queue.
struct WindowRowDropTarget: ViewModifier {
    let drop: ([String], Bool) -> Bool
    @State private var height: CGFloat = 0
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, value in height = value }
            })
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accent.opacity(targeted ? 0.65 : 0)).allowsHitTesting(false))
            .dropDestination(for: String.self) { values, point in drop(values, point.y > height / 2) }
                isTargeted: { targeted = $0 }
    }
}

struct RenameWindowView: View {
    @ObservedObject var manager: WindowManager
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename window tab").font(.system(size: 22, weight: .medium))
            Text("Choose a name such as Server, Build, or Research. This changes its label in Lanes.").font(.system(size: 12)).foregroundStyle(muted)
            TextField("Window name", text: $label).textFieldStyle(.roundedBorder).focused($focused).onSubmit { rename() }
            HStack {
                Button("Use original title") { label = ""; rename() }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { rename() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 450).background(surface).foregroundStyle(ink)
            .onAppear { if let id = manager.renameWindowID, let window = manager.windows.first(where: { $0.id == id }) { label = manager.windowLabel(window) }; focused = true }
    }
    func rename() { if let id = manager.renameWindowID { manager.renameWindow(id, name: label) }; dismiss() }
}

struct IdleStripOpacityControl: View {
    @ObservedObject var manager: WindowManager
    @State private var dragging = false
    @State private var preview: Double?

    private var opacity: Double { preview ?? manager.settings.idleStripOpacity }

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { opacity }, set: update), in: 0.1...1, step: 0.05, onEditingChanged: editingChanged)
                    .frame(width: 150)
                Text("\(Int((opacity * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
            }
        } label: {
            Text("Idle opacity")
            Text(manager.settings.keepStripsVisible ? "How visible a strip stays while you are not pointing at it." : "Turn on Keep strips visible to use this.")
        }.disabled(!manager.settings.keepStripsVisible)
            .onDisappear { editingChanged(false) }
    }

    private func update(_ value: Double) {
        if dragging {
            preview = Settings.clampedIdleOpacity(value)
            manager.previewIdleStripOpacity(value)
        } else {
            manager.setIdleStripOpacity(value)
        }
    }

    private func editingChanged(_ editing: Bool) {
        dragging = editing
        if !editing { finishPreview() }
    }

    private func finishPreview() {
        guard let preview else { return }
        manager.setIdleStripOpacity(preview)
        self.preview = nil
    }
}

struct SettingsView: View {
    @ObservedObject var manager: WindowManager
    var height: CGFloat = 700   // previews render it taller to show every section
    @Environment(\.dismiss) private var dismiss
    @State private var dockChangeFailed = false
    // Native grouped sections with labels on the left and controls aligned on the
    // right; each explanation sits under its setting as a subtitle.
    var body: some View {
        let windowsByLane = Dictionary(grouping: manager.windows, by: \.lane)
        let inUse = manager.enabledLanes.filter { windowsByLane[$0] != nil }
        let withStrips = inUse.filter { WindowStripMetrics.needsStrip(windowCount: windowsByLane[$0]?.count ?? 0) }
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Preferences").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { manager.save(); dismiss() }.keyboardShortcut(.defaultAction)
            }.foregroundStyle(ink).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)
            Form {
                if !inUse.isEmpty {
                    Section("Windows shown at once") {
                        ForEach(inUse) { lane in
                            windowLimit(lane, openCount: windowsByLane[lane]?.count ?? 0)
                        }
                    }
                }
                Section("Strips") {
                    Toggle("Show a strip for each category", isOn: Binding(get: { manager.settings.showLaneControls }, set: { manager.settings.showLaneControls = $0; manager.save(); manager.selectedTemplateChanged = true; if !$0 { manager.onHideLaneControls?() } }))
                    Group {
                        Toggle(isOn: Binding(get: { manager.settings.keepStripsVisible }, set: {
                            manager.settings.keepStripsVisible = $0
                            manager.save()
                        })) {
                            Text("Keep strips visible")
                            Text("Idle strips fade to the opacity below. Hover one to show it in full.")
                        }
                        IdleStripOpacityControl(manager: manager)
                        Picker("Default strip style", selection: Binding(get: { manager.settings.windowStripStyle }, set: {
                            manager.settings.windowStripStyle = $0
                            manager.stripAppearanceChanged()
                        })) {
                            ForEach(WindowStripStyle.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Default hover layout", selection: Binding(get: { manager.settings.stripList }, set: {
                            manager.settings.stripList = $0
                            manager.stripAppearanceChanged()
                        })) {
                            ForEach(StripListMode.allCases) { Text($0.title).tag($0) }
                        }
                    }.disabled(!manager.settings.showLaneControls)
                }
                if !withStrips.isEmpty {
                    Section("Category strip styles") {
                        ForEach(withStrips) { lane in
                            CategoryStripSettings(manager: manager, lane: lane, windows: windowsByLane[lane] ?? [])
                        }
                        .disabled(!manager.settings.showLaneControls)
                    }
                }
                Section {
                    Group {
                        Picker(selection: Binding(get: { manager.settings.stripPlacement }, set: { manager.setStripPlacement($0) })) {
                            ForEach(StripPlacement.allCases) { placement in Text(placement.title).tag(placement) }
                        } label: {
                            Text("Position")
                            Text(manager.settings.stripPlacement == .onWindows ? "On the top edge of each category. Drag a strip to put it anywhere." : "A band above each category; windows start below it.")
                        }
                        Picker(selection: Binding(get: { manager.settings.stripAlignment }, set: { manager.setStripAlignment($0) })) {
                            Text("Default").tag(nil as StripAlignment?)
                            ForEach(StripAlignment.allCases) { alignment in Text(alignment.title).tag(Optional(alignment)) }
                        } label: {
                            Text("Alignment")
                            Text(manager.settings.stripPlacement == .onWindows ? "Where pills sit along that edge. Dragged strips stay put." : "Where pills sit along the band.")
                        }.pickerStyle(.segmented)
                        Picker(selection: Binding(get: { manager.settings.stripExpansion }, set: { manager.setStripExpansion($0) })) {
                            ForEach(StripExpansion.allCases) { expansion in Text(expansion.title).tag(expansion) }
                        } label: {
                            Text("Expanded strip")
                            Text("Both full-width choices reach the right edge of the grid slot.")
                        }
                        LabeledContent("Size") {
                            HStack {
                                Slider(value: Binding(get: { manager.settings.windowStripScale }, set: { manager.settings.windowStripScale = $0; manager.stripAppearanceChanged(retile: false) }), in: 0.8...1.5, step: 0.1, onEditingChanged: { editing in if !editing { manager.stripAppearanceChanged() } }).frame(width: 150)
                                Text("\(Int(manager.settings.windowStripScale * 100))%").font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
                            }
                        }
                        Toggle(isOn: Binding(get: { manager.settings.shortTabNames }, set: { manager.settings.shortTabNames = $0; manager.save(); manager.onLaneControls?() })) {
                            Text("Short tab names")
                            Text("Each window shows the first meaningful part of its title instead of the whole title.")
                        }
                        Toggle(isOn: Binding(get: { manager.settings.chatNames }, set: { manager.settings.chatNames = $0; manager.save(); manager.onLaneControls?() })) {
                            Text("Chat names and apps")
                            Text("Chats show who you're talking to, and lists show each window's app: \"Sam · Messages\". Off: chats show just their app's name, as before.")
                        }
                        LabeledContent("Dragged strips") {
                            Button("Reset positions") { manager.resetStripPosition() }
                                .disabled(manager.settings.stripPlacement != .onWindows || manager.settings.stripPositions.isEmpty)
                        }
                    }.disabled(!manager.settings.showLaneControls)
                } header: { Text("Strip options") } footer: {
                    Text("Hover a strip and scroll, or use Left/Right and 1–9 (0 = window 10).").font(.system(size: 10)).foregroundStyle(muted)
                }
                Section("Windows") {
                    Picker(selection: Binding(get: { manager.settings.newWindowPlacement }, set: { manager.settings.newWindowPlacement = $0; manager.save(); manager.updateNewWindowWatch() })) {
                        ForEach(NewWindowPlacement.allCases) { choice in Text(choice.title).tag(choice) }
                    } label: {
                        Text("New windows")
                        Text(manager.settings.newWindowPlacement == .center ? "A window from an app with a category opens in it, like WhatsApp in Messaging. Others open centered at their own size."
                             : manager.settings.newWindowPlacement == .leave ? "New windows stay wherever their app opens them until you press Organize."
                             : "After Organize, each new window goes into its category. Existing windows stay put.")
                    }
                    Toggle(isOn: Binding(get: { manager.settings.keepLayout }, set: { manager.settings.keepLayout = $0; manager.save() })) {
                        Text("Keep windows in their tiles")
                        Text("If an agent (Codex, Claude and others) or an app moves an arranged window, Lanes puts it back. Only your own mouse and keyboard rearrange windows.")
                    }
                    LabeledContent("Space between windows") {
                        HStack {
                            Slider(value: Binding(get: { manager.settings.gap }, set: { manager.settings.gap = $0; manager.selectedTemplateChanged = true; manager.save() }), in: 4...28, step: 2).frame(width: 150)
                            Text("\(Int(manager.settings.gap)) pt").font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Section("Displays") {
                    Toggle(isOn: Binding(get: { manager.settings.onlyTargetScreen }, set: { manager.settings.onlyTargetScreen = $0; manager.save(); manager.refresh() })) {
                        Text("Only collect windows from the selected display")
                        Text("Windows on your other displays are left where they are.")
                    }
                }
                Section("Keyboard") {
                    Toggle(isOn: Binding(get: { manager.settings.doubleRightCommand }, set: { manager.settings.doubleRightCommand = $0; manager.save() })) {
                        Text("Double-tap Right Command to organize")
                        Text("Two quick taps, with no other keys held.")
                    }
                    ShortcutRecorderRow(manager: manager)
                    LabeledContent("Hold Control + Option + Command, then") { EmptyView() }
                    shortcut("Organize desktop", "Return")
                    shortcut("Next window in categories 1–7", "1 to 7")
                    shortcut("Cycle the focused window's category", "Tab")
                    shortcut("Previous window in category", "Shift + Tab")
                    shortcut("Send focused window to category", "Shift + 1 to 7")
                    shortcut("Move focused window by 24 pt", "Arrow keys")
                    shortcut("Resize focused window by 24 pt", "Shift + Arrows")
                    shortcut("Restore window positions", "Z")
                    shortcut("On a hovered strip: switch windows", "Scroll, ←/→, 1–9, 0")
                    shortcut("In the grid: delete the selected category", "Backspace")
                }
                Section("General") {
                    Toggle(isOn: Binding(get: { manager.settings.showInDock }, set: {
                        dockChangeFailed = !manager.setShowInDock($0)
                    })) {
                        Text("Show in Dock")
                        Text(dockChangeFailed ? "macOS could not change the Dock icon." : "Click the Dock icon to open the grid editor.")
                    }
                    Toggle("Open Lanes at login", isOn: Binding(get: { manager.opensAtLogin }, set: { manager.setOpensAtLogin($0) }))
                    Toggle(isOn: Binding(get: { manager.gridLanes.contains(.media) }, set: { on in manager.editGrid { if on { manager.restoreCategory(.media) } else { manager.removeCategory(.media) } } })) {
                        Text("Reserve a place for mini players")
                        Text("Picture-in-Picture and compact player windows. App minimum sizes still apply.")
                    }
                    ForEach(manager.availableLanes.filter { manager.settings.hiddenLanes.contains($0.rawValue) }) { lane in
                        LabeledContent { Button("Restore") { manager.editGrid { manager.restoreCategory(lane) } } } label: {
                            Label("\(manager.name(lane)) (removed)", systemImage: lane.symbol).foregroundStyle(lane.color)
                        }
                    }
                    LabeledContent("Category positions") { Button("Reset") { manager.resetPlacements() } }
                    LabeledContent("App assignments (\(manager.settings.appRules.count) saved)") { Button("Reset") { manager.resetRules() } }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width: 560, height: height).background(surface)
    }
    private func windowLimit(_ lane: Lane, openCount: Int) -> some View {
        let extra = openCount - manager.grid.capacity(lane)
        return Picker(selection: Binding(get: { manager.arrangement(lane, staged: true) }, set: { value in
            manager.editGrid { manager.setArrangement(lane, value) }
        })) {
            // One window, then two, three and four windows each way, with a picture of the split.
            ForEach(Array(WindowArrangement.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group) { option in
                    Label { Text(option.title) } icon: { Image(nsImage: ArrangementImage.image(option)) }.labelStyle(.titleAndIcon).tag(option)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Label(manager.name(lane), systemImage: lane.symbol).foregroundStyle(lane.color)
                Text(manager.settings.showLaneControls && extra > 0 ? "\(openCount) open · \(extra) more in strip" : "\(openCount) open")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    func shortcut(_ label: String, _ keys: String) -> some View {
        LabeledContent(label) { Text(keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent) }
    }
}

extension KeyShortcut {
    init(event: NSEvent) {
        let flags = event.modifierFlags
        self.init(keyCode: Int(event.keyCode), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command))
    }
}

// Recording a new Open Lanes shortcut: the next key press held with Command,
// Control or Option becomes the shortcut. Esc cancels.
@MainActor final class ShortcutRecording: ObservableObject {
    @Published var active: Bool
    @Published var note: String?   // why the last key press was not taken
    private var monitor: Any?
    private weak var manager: WindowManager?
    init(active: Bool = false, note: String? = nil) { self.active = active; self.note = note }
    func start(_ manager: WindowManager) {
        guard monitor == nil else { return }
        self.manager = manager; active = true; note = nil
        // Lanes' own chords arrive as hot keys, never as key presses: the app hands them over.
        manager.recordingShortcut = true
        manager.onShortcutRecorded = { [weak self] shortcut in self?.typed(shortcut) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.typed(KeyShortcut(event: event)) }
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; active = false
        manager?.recordingShortcut = false; manager?.onShortcutRecorded = nil
    }
    func typed(_ shortcut: KeyShortcut) {
        guard active, let manager else { return }
        if shortcut.isEscape { note = nil; stop(); return }
        guard shortcut.hasRequiredModifier else { note = "Hold ⌘, ⌃ or ⌥ with the key. Esc cancels."; return }
        if let clash = shortcut.clash { note = "\(shortcut.symbols) is already \u{201C}\(clash)\u{201D} in Lanes. Try another."; return }
        guard manager.setOpenShortcut(shortcut) else { note = Self.refused(shortcut, kept: manager.settings.openShortcut) + " Try another."; return }
        note = nil; stop()
    }
    func reset(_ manager: WindowManager) {
        stop()
        note = manager.setOpenShortcut(.openLanesDefault) ? nil : Self.refused(.openLanesDefault, kept: manager.settings.openShortcut)
    }
    static func refused(_ shortcut: KeyShortcut, kept: KeyShortcut) -> String { "macOS refused \(shortcut.symbols) (another app may hold it), so \(kept.symbols) stays." }
}

// Preferences › Keyboard: the Open Lanes shortcut. Click it, then type a new one.
struct ShortcutRecorderRow: View {
    @ObservedObject var manager: WindowManager
    @StateObject private var recording: ShortcutRecording
    init(manager: WindowManager, showing: ShortcutRecording? = nil) {   // previews show it mid-recording
        self.manager = manager
        _recording = StateObject(wrappedValue: showing ?? ShortcutRecording())
    }
    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button { if recording.active { recording.stop() } else { recording.start(manager) } } label: {
                    Text(recording.active ? "Type the new shortcut…" : manager.settings.openShortcut.symbols)
                        .font(.system(size: recording.active ? 11 : 12, weight: recording.active ? .regular : .medium))
                        .foregroundStyle(recording.active ? ink : accent)
                        .padding(.horizontal, 10).frame(minWidth: 92, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(neutralOverlay.opacity(recording.active ? 0.10 : 0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording.active ? accent : neutralOverlay.opacity(0.16), lineWidth: recording.active ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .help(recording.active ? "Type the shortcut now. Esc cancels." : "Click, then type the shortcut that opens Lanes from any app.")
                    .accessibilityLabel(recording.active ? "Recording the Open Lanes shortcut" : "Open Lanes shortcut: \(manager.settings.openShortcut.spoken). Click to change.")
                Button("Reset") { recording.reset(manager) }
                    .disabled(manager.settings.openShortcut == .openLanesDefault && !recording.active)
                    .help("Back to \(KeyShortcut.openLanesDefault.symbols)")
            }
        } label: {
            Text("Open Lanes")
            Text(recording.note ?? "Shows or hides Lanes from any app. Click the shortcut, then type a new one.")
                .foregroundStyle(recording.note == nil ? Color.secondary : Color.orange)
        }.onDisappear { recording.stop() }
    }
}

struct AccessHelpView: View {
    @ObservedObject var manager: WindowManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Turn on window control").font(.system(size: 22, weight: .medium)); Spacer(); Button("Done") { dismiss() } }
            Text("Lanes moves other apps' windows, so macOS asks you to allow it once. Window data stays on this Mac. Lanes contacts the update host only when you choose Check for Updates… or enable automatic update checks.")
                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            Text("1. Click Open System Settings.\n2. In the list that opens, switch Lanes on. macOS may ask for your password.\n3. Come back here. Lanes notices within a few seconds.").font(.system(size: 12)).lineSpacing(7)
            Text("Already switched on but still not working? This happens after replacing Lanes with a newer download. Select Lanes in that list, remove it with the minus button, add it again with the plus button, and switch it on.")
                .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            Text("This copy: \(Bundle.main.bundlePath)").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent).textSelection(.enabled)
            HStack {
                Button("Open System Settings") { manager.requestAccess() }
                Button("Show Lanes in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }.font(.system(size: 11))
            HStack {
                Image(systemName: manager.trusted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(manager.trusted ? accent : .orange)
                Text(manager.trusted ? "Window control is on" : "Window control is not on yet").font(.system(size: 11))
                Spacer()
                Button("Recheck access") { manager.refresh(); if manager.trusted { dismiss() } }.font(.system(size: 11))
            }
        }.padding(28).frame(width: 590).background(surface)
    }
}

struct SaveLayoutView: View {
    @ObservedObject var manager: WindowManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as preset").font(.system(size: 22, weight: .medium))
            Text("Save these category positions, sizes, and how many windows each shows. Your layouts stay available alongside the built-in presets.")
                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            TextField("Layout name", text: $name).textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if manager.saveGridLayout(name: name) { dismiss() } else { error = manager.status } }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 450).background(surface).foregroundStyle(ink)
    }
}

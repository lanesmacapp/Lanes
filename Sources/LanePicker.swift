import SwiftUI
import AppKit

struct LaneWindowStrip: NSViewRepresentable {
    @ObservedObject var manager: WindowManager
    let lane: Lane
    let showBoard: () -> Void
    // Idle strips on the windows fade to a faint outline; a Line is already small, so
    // it stays clearly visible. Keep strips visible: they fade to the Idle opacity instead.
    var floor: Double { manager.settings.idleStripFloor(style: manager.settings.stripStyle(lane)) }
    static func syncBar(_ view: LaneScrollHostingView, manager: WindowManager, lane: Lane, frame: CGRect, animate: Bool) {
        // While a tab folds away the bar shrinks on the same curve and timing.
        // While you drag the strip, the bar simply moves with it.
        let dragging = manager.draggingStrip == lane
        let folding = manager.stripInMotion && manager.expandedStrip == lane
        view.barSize.go(to: frame.size, screenX: dragging ? nil : frame.minX, restX: dragging ? nil : manager.stripRestFrame(lane).minX,
                        animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                        screen: view.window?.screen ?? NSScreen.main, duration: folding ? WindowManager.stripCloseDuration : nil)
    }
    func makeNSView(context: Context) -> LaneScrollHostingView {
        let view = LaneScrollHostingView(rootView: AnyView(Color.clear))
        view.visibility.setFloor(floor)
        view.setStripContent(AnyView(LanePickerContent(manager: manager, lane: lane, barSize: view.barSize, pointer: view.pointer, showBoard: showBoard)))
        Self.syncBar(view, manager: manager, lane: lane, frame: manager.stripFrame(lane), animate: false)
        view.onSwitch = { delta in manager.cycleWindow(lane, delta: delta) }
        view.canDragStrip = { manager.settings.stripPlacement == .onWindows }
        view.onHover = { active in
            if active { manager.hoveredLane = lane }
            else if manager.hoveredLane == lane { manager.hoveredLane = nil }
            manager.stripHovered(lane, active)
        }
        return view
    }
    func updateNSView(_ view: LaneScrollHostingView, context: Context) {
        view.visibility.setFloor(floor)
        // The mounted strip already observes the manager. Replacing its root here
        // rebuilds the rows and native close buttons on every hover.
        Self.syncBar(view, manager: manager, lane: lane, frame: manager.stripFrame(lane), animate: true)
    }
    // The strip view inside a strip's window (it sits under the window's SwiftUI host).
    static func stripView(in window: NSWindow) -> LaneScrollHostingView? {
        func find(_ view: NSView) -> LaneScrollHostingView? { (view as? LaneScrollHostingView) ?? view.subviews.lazy.compactMap(find).first }
        return window.contentView.flatMap(find)
    }
    // A strip that sits on the windows is dragged by its pill: press anywhere on it
    // (not on a tab) and move. Letting go saves the spot for its category.
    static func makeDraggable(_ panel: StripPanel, manager: WindowManager, lane: Lane) {
        let drag = StripDrag()
        drag.canStart = { [weak panel] point in panel.flatMap(stripView)?.dragsStrip(windowPoint: point) ?? false }
        drag.onBegin = { [weak manager] in manager?.draggingStrip = lane }
        drag.onEnd = { [weak panel, weak manager] frame in
            guard let manager else { return }
            manager.draggingStrip = nil
            let ownsSize = manager.settings.stripStyle(lane).expandsOnHover, usesList = ownsSize && manager.stripUsesList(lane)
            let barSize = panel.flatMap(stripView)?.barSize
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            // Where the pill is drawn: an open list can sit left of its pill at the display's edge.
            let x = frame.minX + (!ownsSize ? 0 : usesList ? barSize?.restOffsetX ?? 0 : barSize?.offsetX ?? 0)
            manager.moveStrip(lane, to: CGRect(x: x, y: mainHeight - frame.maxY, width: frame.width, height: frame.height))
        }
        panel.drag = drag
    }
}
private let stripCountInk = paletteColor(light: (0.32, 0.38, 0.32), dark: (0.584, 0.62, 0.592))

struct LanePickerContent: View {
    @ObservedObject var manager: WindowManager
    let lane: Lane
    var barSize = StripBarSize()
    @ObservedObject var pointer = StripPointer()
    let showBoard: () -> Void
    @State private var dropTargetID: String?
    @State private var showingArrangement = false
    // Closing, Chrome-style: the tab folds away at once and its neighbours slide into
    // its place. Tab widths stay put while the pointer is on the strip, so the next
    // tab's × lands under the cursor for rapid closing.
    // Ease in and out, matching the bar's own resize curve, so tab and bar move as one.
    static let fold = Animation.timingCurve(0.65, 0, 0.35, 1, duration: WindowManager.stripCloseDuration)
    @State private var stripTargeted = false
    var style: WindowStripStyle { manager.settings.stripStyle(lane) }
    var scale: Double { manager.settings.windowStripScale }
    var body: some View {
        strip.contextMenu {
            Button("Open Lanes") { showBoard() }
            Button("Windows shown at once…") { showingArrangement = true }
            if manager.settings.stripPositions[lane.rawValue] != nil { Button("Move strip back to the top edge") { manager.resetStripPosition(lane) } }
            Divider()
            StripLookMenu(manager: manager, lane: lane, inline: true)
        }
        .popover(isPresented: $showingArrangement, arrowEdge: .top) {
            CategoryLookPanel(manager: manager, lane: lane, staged: false, showsStripOptions: false)
        }
        .onPreferenceChange(StripPillFrameKey.self) { pointer.pillFrame = $0 }
    }
    var expanded: Bool { style == .detailed || (style.expandsOnHover && manager.expandedStrip == lane) }
    // The strip looks like the one on the website: a pill with a dot in the category's
    // color, the name and how many windows. The pill's start never changes, so nothing
    // under the mouse moves when an Expand-on-hover strip opens. Tabs grow out of the
    // pill's right end; a list opens as its own box under it. Either is laid out once
    // at its final size and revealed, so text never reflows mid-animation.
    // A narrow strip opens into a list of whole window names instead of chips.
    var usesList: Bool { style.expandsOnHover && manager.stripUsesList(lane) }
    var listed: Bool { expanded && usesList }
    var text: Double { WindowStripMetrics.tabText(scale: scale) }
    @ViewBuilder var strip: some View {
        if style == .line && !expanded { line } else { bar }
    }
    // Line: the category's color, one segment per window, the one showing brighter.
    var line: some View {
        let all = manager.items(lane), active = manager.activeWindow(lane)
        let selectedIndex = all.firstIndex { $0.id == active?.id } ?? 0
        let indices = Array(Layout.pickerIndices(total: all.count, active: selectedIndex, limit: 16))
        return HStack(spacing: 2 * scale) {
            ForEach(indices, id: \.self) { index in
                // Dark rim + soft shadow keep the bar findable on light windows.
                Capsule().fill(lane.color.opacity(index == selectedIndex ? 1 : 0.35))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.55), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }.frame(height: 4 * scale).padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { values, _ in manager.dropTab(values, into: lane) } isTargeted: { stripTargeted = $0 }
            .help("\(manager.name(lane)) · \(manager.windowCounter(lane)). Hover to see every window.")
            .accessibilityLabel("\(manager.name(lane)), window \(manager.windowCounter(lane))")
    }
    var bar: some View {
        barBody
            // A tab from another strip dropped anywhere on this one joins this category.
            .dropDestination(for: String.self) { values, point in
                listed ? manager.dropListedTab(values, into: lane, y: point.y) : manager.dropTab(values, into: lane)
            } isTargeted: { stripTargeted = $0 }
            .foregroundStyle(ink)
            // A list open above its pill hangs from the strip's bottom edge, which is the
            // edge of the pill that never moves; every other strip hangs from its top.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: listAbove ? .bottomLeading : .topLeading)
    }
    // The list opens above the pill where opening under it would run past the bottom of the display.
    var listAbove: Bool { usesList && manager.stripListOpensAbove(lane) }
    @ViewBuilder var barBody: some View {
        if usesList { listBar } else { tabsBar }
    }
    // Every strip that grows on hover animates its own bar (GPU composited, laid out
    // once); its invisible window jumps to the new size instead of resizing each frame.
    var ownsSize: Bool { style.expandsOnHover }
    // The pill's look: the dark surface with the category's color on its edge.
    var pillChrome: StripPillChrome {
        StripPillChrome(inset: WindowStripMetrics.pillInset(scale: scale), edge: lane.color.opacity(stripTargeted ? 1 : 0.4), edgeWidth: stripTargeted ? 2 : 1)
    }
    // Tabs: one pill. Its row is as wide as the open strip from the start; the pill
    // follows the strip's live width, so its right end stays round while it grows.
    var tabsBar: some View {
        let m = manager.displayedStripMetrics(lane)
        let layout = ownsSize ? manager.openTabStripMetrics(lane) : m
        return HStack(spacing: 0) {
                pillHead
                if style == .compact {
                    // Compact never opens: the counter is how you step through its windows.
                    counter.padding(.leading, 6 * scale)
                } else {
                    chipRow.padding(.leading, 6 * scale)
                        .allowsHitTesting(expanded).accessibilityHidden(!expanded)
                }
            }.frame(height: 32 * scale).font(.system(size: 10 * scale))
                .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                .modifier(BarSizeModifier(barSize: barSize, active: ownsSize))
                .modifier(pillChrome)
                // The pill keeps its place on screen while its (invisible) window resizes.
                .modifier(BarOffsetModifier(barSize: barSize, active: ownsSize))
    }
    // List: the pill stays small and gains the counter; the list is a box of its own
    // under it. Its rows are mounted all the time (hidden while idle), so hovering
    // only unfolds the box; building rows and close buttons mid-open caused a hitch.
    // Near the bottom of the display the same box unfolds above the pill instead:
    // the pill is the fixed point either way, so it stays under the pointer.
    var listBar: some View {
        let open = manager.listStripMetrics(lane), shown = manager.displayedStripMetrics(lane), idle = manager.stripMetrics(lane)
        let pill = manager.stripPillWidth(lane), counterWidth = WindowStripMetrics.counterWidth(count: manager.stripCount(lane), scale: scale)
        let top = 32 * scale + WindowStripMetrics.listGap(scale: scale)
        let above = listAbove, edge: Alignment = above ? .bottomLeading : .topLeading
        // The transparent panel is only pill-width at rest. Give the list its
        // own width without letting it size the hosted view past the panel.
        return Color.clear.overlay(alignment: edge) {
            ZStack(alignment: edge) {
                windowList.padding(WindowStripMetrics.listPad)
                    .frame(width: open.width, height: max(0, open.height - top), alignment: edge)
                    .modifier(ListBoxModifier(barSize: barSize, top: top, width: open.width, fallbackHeight: shown.height, radius: 11 * scale,
                                              edge: lane.color.opacity(stripTargeted ? 1 : 0.3), edgeWidth: stripTargeted ? 2 : 1, anchor: edge))
                    .allowsHitTesting(listed).accessibilityHidden(!listed)
                    .padding(above ? .bottom : .top, top)
                HStack(spacing: 0) {
                    pillHead
                    counter.padding(.leading, 6 * scale)
                        .allowsHitTesting(listed).accessibilityHidden(!listed)
                }.fixedSize().frame(height: 32 * scale).font(.system(size: 10 * scale))
                    // The pill stays where it rests, under the pointer, and grows to show
                    // its counter. A Line strip rests as a line, so its pill starts at its own width.
                    .modifier(ListPillModifier(barSize: barSize, rest: style == .line ? pill : min(pill, idle.width), open: min(pill + counterWidth, open.width),
                                               from: idle.height, stretch: min(open.height - idle.height, 2 * WindowStripMetrics.listRow(scale: scale)),
                                               listed: listed, room: open.width, chrome: pillChrome))
            }
        }
    }
    // The pill's start: the dot, the category's name, and how many windows it holds.
    var pillHead: some View {
        HStack(spacing: 0) {
            dot.padding(.leading, WindowStripMetrics.pillLead * scale)
            Text(manager.name(lane)).font(.system(size: text, weight: .semibold)).foregroundStyle(lane.color).lineLimit(1).fixedSize()
                .padding(.leading, WindowStripMetrics.dotGap * scale)
            Text("\(manager.stripCount(lane))").font(.system(size: text, weight: .medium).monospacedDigit())
                .foregroundStyle(stripCountInk).lineLimit(1).fixedSize()
                .padding(.leading, WindowStripMetrics.countGap * scale)
            slotPicker
        }.help(manager.settings.stripPlacement == .onWindows ? Self.dragHelp : "")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(manager.name(lane)), \(manager.stripCount(lane)) windows")
    }
    // A strip that sits on the windows is dragged by its whole pill (StripDrag), so
    // the dot, the name and the count say so when pointed at.
    var dot: some View {
        Circle().fill(lane.color).frame(width: WindowStripMetrics.dot * scale, height: WindowStripMetrics.dot * scale)
            .frame(width: WindowStripMetrics.dotBox * scale, height: 24 * scale)
    }
    static let dragHelp = "Drag the strip to move it anywhere. Right-click the strip to move it back."
    @ViewBuilder var slotPicker: some View {
        let slots = manager.slotIDs(lane)
        if slots.count == 2 {
            HStack(spacing: 3 * scale) {
                paneButton(0, slots: slots)
                Button { manager.swapPanes(lane) } label: {
                    Image(systemName: manager.slotLabel(lane, index: 0) == "Left" ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
                        .font(.system(size: 8 * scale, weight: .semibold)).foregroundStyle(ink.opacity(0.6))
                        .frame(width: 14 * scale, height: 20 * scale).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Swap the two panes. The window you are working in keeps the keyboard.")
                    .accessibilityLabel("Swap \(manager.slotLabel(lane, index: 0)) and \(manager.slotLabel(lane, index: 1))")
                paneButton(1, slots: slots)
            }.padding(.leading, 6 * scale)
        } else if slots.count > 2 {
            Menu {
                ForEach(Array(slots.indices), id: \.self) { index in
                    Button("\(manager.slotLabel(lane, index: index)) · \(manager.items(lane).first(where: { $0.id == slots[index] }).map(manager.windowLabel) ?? "Empty")") { manager.selectSlot(lane, index: index) }
                }
            } label: {
                HStack(spacing: 2) { Text("\((manager.activeSlot[lane] ?? 0) + 1)"); Image(systemName: "chevron.down").font(.system(size: 6 * scale)) }
                    .font(.system(size: 9 * scale, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize().padding(.leading, 6 * scale)
                .help("Target \(manager.slotLabel(lane, index: manager.activeSlot[lane] ?? 0)). Switching this slot keeps the other windows fixed.")
        }
    }
    func paneButton(_ index: Int, slots: [String]) -> some View {
        Button { manager.selectSlot(lane, index: index) } label: {
            Text(manager.slotLabel(lane, index: index))
                .font(.system(size: 9 * scale, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 5 * scale).padding(.vertical, 4 * scale)
                .foregroundStyle((manager.activeSlot[lane] ?? 0) == index ? lane.color : ink.opacity(0.6))
                .background((manager.activeSlot[lane] ?? 0) == index ? lane.color.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
        }.buttonStyle(.plain).fixedSize()
            .onHover { hovering in if hovering { manager.targetSlot(lane, index: index) } }
            .help("\(manager.slotLabel(lane, index: index)): \(manager.items(lane).first(where: { $0.id == slots[index] }).map(manager.windowLabel) ?? "Empty")\nClick to move the window you are working in here; the two windows swap. Hover to target this pane, then scroll or use Left/Right / 1–9 / 0.")
    }
    func tabClick(_ window: ManagedWindow, chipWidth: Double? = nil) {
        if NSEvent.modifierFlags.contains(.option) { closeTab(window, chipWidth: chipWidth) }
        else { manager.reveal(window) }
    }
    func closeTab(_ window: ManagedWindow, chipWidth: Double? = nil) {
        if let chipWidth { manager.freezeTabs(lane, width: chipWidth, closing: window.id) }
        manager.closeFromStrip(window)
    }
    // Fades the right end of a tab's name to make room for its ×, without moving the name.
    func tabNameMask(fading: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: (fading ? 12 : 0) * scale)
            Rectangle().fill(.clear).frame(width: (fading ? 14 : 0) * scale)
        }
    }
    func closeButton(_ window: ManagedWindow, fontSize: CGFloat, chipWidth: Double? = nil) -> some View {
        Button { closeTab(window, chipWidth: chipWidth) } label: {
            Image(systemName: "xmark")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(ink.opacity(0.85))
                .frame(width: fontSize + 8, height: fontSize + 8)
                .background(Circle().fill(neutralOverlay.opacity(0.14)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(1)
        .help("Close window")
        .accessibilityLabel("Close \(window.appName): \(window.title)")
    }
    @ViewBuilder func tabMenu(_ window: ManagedWindow) -> some View {
        Button("Rename tab…") { manager.beginRenamingWindow(window) }
        Button("Show window") { manager.reveal(window) }
        if manager.settings.capacity(lane) > 1 {
            ForEach(Array(manager.slotIDs(lane).indices), id: \.self) { index in
                Button("Show in \(manager.slotLabel(lane, index: index))") { manager.show(window, inPane: index) }
            }
        }
        if manager.enabledLanes.count > 1 {
            Menu("Move") {
                ForEach(manager.enabledLanes) { other in
                    if other == lane { Label(manager.name(other), systemImage: "checkmark") }
                    else { Button(manager.name(other)) { manager.moveWindow(window, to: other) } }
                }
            }
        }
        Divider()
        WindowActionsMenu(manager: manager, window: window)
        Divider()
        Button("Leave \(window.appName) alone") { manager.ignoreApp(window.bundleID, name: window.appName) }
            .help("Lanes stops managing \(window.appName): no tab, never moved. Undo it in Lanes › Categories › Leave alone.")
        Divider()
        Button("Open Lanes") { showBoard() }
    }
    // What follows the mouse while a tab is dragged to another category.
    func tabPreview(_ window: ManagedWindow) -> some View {
        HStack(spacing: 4) {
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
            Text(manager.windowLabel(window)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(lane.color).background(Capsule().fill(surface))
            .overlay(Capsule().strokeBorder(lane.color.opacity(0.5)))
    }
    // Window names as pill chips, with the counter at the right end.
    var chipRow: some View {
        let all = manager.items(lane)
        let active = manager.activeWindow(lane)
        // Room goes to the pill's start and the counter first; the tabs are the whole
        // ones that fit in what is left, around the active window.
        let fit = manager.stripTabs(lane)
        // A tab's width includes the gap after it, so a closing tab folds its gap away too
        // and the open pill is exactly its start, its tabs and the counter.
        let chipWidth = fit.width
        let spacing = 4 * scale
        return HStack(spacing: 0) {
            ForEach(fit.tabs) { window in
                let index = all.firstIndex { $0.id == window.id } ?? 0
                let selected = window.id == active?.id
                let isClosing = manager.closingWindowIDs.contains(window.id)
                HStack(spacing: 0) {
                    Button { tabClick(window, chipWidth: chipWidth) } label: {
                        HStack(spacing: 3 * scale) {
                            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: WindowStripMetrics.tabText(scale: scale), height: WindowStripMetrics.tabText(scale: scale)) }
                            Text(manager.windowLabel(window)).font(.system(size: WindowStripMetrics.tabText(scale: scale), weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                        }.padding(.horizontal, 7 * scale).padding(.vertical, 3 * scale)
                            .frame(maxWidth: .infinity)
                            // The name never moves when the × appears: a long name just fades
                            // out under the ×; a short one already clears it.
                            .mask(tabNameMask(fading: pointer.hoveredTab == window.id))
                            .foregroundStyle(selected ? lane.color : ink.opacity(0.75))
                            .background(selected ? lane.color.opacity(0.18) : neutralOverlay.opacity(0.06)).clipShape(Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).help("\(index + 1)/\(all.count) · \(window.appName) — \(window.title)\nClick to show; × or Option-click closes; hover + Scroll or use Left/Right to switch; 1–9 / 0 selects a tab.\nDrag it onto another category to move it there.")
                        .accessibilityLabel("Show \(window.appName): \(window.title)")
                        .accessibilityValue(selected ? "Selected" : "")
                        .draggable(manager.beginTabDrag(window)) { tabPreview(window) }
                        .dropDestination(for: String.self) { values, point in return manager.dropTab(values, into: lane, before: window, after: point.x > (chipWidth - spacing) / 2) } isTargeted: { active in dropTargetID = active ? window.id : (dropTargetID == window.id ? nil : dropTargetID) }
                        .contextMenu { tabMenu(window) }
                        .overlay { if dropTargetID == window.id { Capsule().strokeBorder(lane.color, lineWidth: 1).allowsHitTesting(false) } }
                        .overlay(alignment: .trailing) {
                            // Only the tab under the pointer shows its ×, inside the chip.
                            if pointer.hoveredTab == window.id {
                                closeButton(window, fontSize: WindowStripMetrics.tabText(scale: scale) - 3, chipWidth: chipWidth)
                                    .frame(width: 18 * scale, height: 18 * scale).padding(.trailing, 2 * scale)
                                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: pointer.hoveredTab == window.id)
                        // A closing tab reports no frame, so the × moves to the tab sliding into its place.
                        .background(GeometryReader { g in Color.clear.preference(key: StripTabFramesKey.self, value: isClosing ? [:] : [window.id: g.frame(in: .global)]) })
                        .accessibilityAction(named: "Close window") { closeTab(window) }
                }.frame(width: max(0, chipWidth - spacing))
                    .padding(.trailing, spacing)
                    // Collapse to nothing, gap included, so the neighbours slide into its place.
                    .frame(width: isClosing ? 0 : chipWidth, alignment: .leading)
                    .opacity(isClosing ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!isClosing)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)), removal: .opacity))
            }
            Spacer(minLength: 0)
            counter.padding(.trailing, 4 * scale)
        }.animation(Self.fold, value: manager.closingWindowIDs)
        .onPreferenceChange(StripTabFramesKey.self) { pointer.tabFrames = $0 }
        // Widths are free again once the pointer leaves the strip.

        .animation(.smooth(duration: 0.3), value: fit.tabs.map(\.id))
            .animation(.smooth(duration: 0.2), value: active?.id)
    }
    // ‹ 2/5 › in the category's color. Its width is fixed, so the pill's size is known
    // without measuring.
    var counter: some View {
        let count = manager.items(lane).count, size = text - 1
        func arrow(_ symbol: String, _ delta: Int, _ label: String) -> some View {
            Button { manager.cycleWindow(lane, delta: delta) } label: {
                Image(systemName: symbol).font(.system(size: size - 2, weight: .semibold))
                    .frame(width: WindowStripMetrics.counterArrow * scale, height: 22 * scale).contentShape(Rectangle())
            }.disabled(count < 2).accessibilityLabel(label)
        }
        return HStack(spacing: 0) {
            arrow("chevron.left", -1, "Previous window")
            Text(manager.windowCounter(lane)).font(.system(size: size).monospacedDigit()).lineLimit(1).fixedSize()
                .frame(width: WindowStripMetrics.counterText(count: manager.stripCount(lane), scale: scale))
            arrow("chevron.right", 1, "Next window")
        }.buttonStyle(.plain).foregroundStyle(lane.color).fixedSize()
    }
    // One window per line: the number key that shows it, its icon and whole name, the
    // app's name at the right, and a × while the pointer is on the line.
    var windowList: some View {
        let all = manager.items(lane)
        let active = manager.activeWindow(lane)
        let selectedIndex = all.firstIndex { $0.id == active?.id } ?? 0
        let indices = Layout.pickerIndices(total: all.count, active: selectedIndex, limit: 16)
        let row = WindowStripMetrics.listRow(scale: scale), close = (text * 1.45).rounded()
        return VStack(alignment: .leading, spacing: 0) {
            let numbered = manager.stripItems(lane)
            ForEach(Array(indices).map { all[$0] }) { window in
                // The number key it answers to; a row folding away already has none.
                let index = numbered.firstIndex { $0.id == window.id } ?? 99
                let selected = window.id == active?.id
                let isClosing = manager.closingWindowIDs.contains(window.id)
                let pointed = pointer.hoveredTab == window.id
                HStack(spacing: 0) {
                    Button { tabClick(window) } label: {
                        HStack(spacing: 6) {
                            Text(index < 9 ? "\(index + 1)" : index == 9 ? "0" : "").font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.38)).frame(width: 10, alignment: .trailing)
                            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: text + 2, height: text + 2) }
                            Text(manager.windowLabel(window, long: true)).font(.system(size: text + 1, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            // Which app it is, so a chat reads "Sam … Messages" and a page "Docs … Chrome".
                            if let app = manager.windowAppName(window) {
                                Text(app).font(.system(size: text - 0.5)).foregroundStyle(ink.opacity(selected ? 0.6 : 0.42))
                                    .lineLimit(1).fixedSize()
                            }
                        }.padding(.horizontal, 6).frame(height: row - 3).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(selected ? lane.color : ink.opacity(0.86))
                            .background(selected ? lane.color.opacity(0.18) : neutralOverlay.opacity(pointed ? 0.06 : 0)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(height: row)
                        .help("\(window.appName) — \(window.title)\nDrag above or below another row to save the order. Drag onto another category to move it there.\nClick to show; × or Option-click closes; hover + Scroll or use Left/Right to switch; 1–9 / 0 selects a window.")
                        .accessibilityLabel("Show \(window.appName): \(window.title)")
                        .accessibilityValue(selected ? "Selected" : "")
                        .draggable(manager.beginTabDrag(window)) { tabPreview(window) }
                        .contextMenu { tabMenu(window) }
                        .overlay { if dropTargetID == window.id { RoundedRectangle(cornerRadius: 6).strokeBorder(lane.color, lineWidth: 1).allowsHitTesting(false) } }
                    // Only the line under the pointer shows its ×, past the end of its highlight.
                    // It stays mounted (hidden), so pointing at a line builds nothing.
                    NativeTabCloseButton(window: window, fontSize: text - 3) { closeTab(window) }
                        .frame(width: close, height: close)
                        .background(Circle().fill(neutralOverlay.opacity(0.14)))
                        .padding(.horizontal, 3)
                        .opacity(pointed ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: pointed)
                }.frame(maxWidth: .infinity, minHeight: row, maxHeight: row)
                    // A closing row reports no frame, so the × moves to the row rising into its place.
                    .background(GeometryReader { g in Color.clear.preference(key: StripTabFramesKey.self, value: isClosing ? [:] : [window.id: g.frame(in: .global)]) })
                    // A closing row folds away at once; the row below rises under the cursor and its ×.
                    .frame(height: isClosing ? 0 : row, alignment: .top)
                    .opacity(isClosing ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!isClosing)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.96, anchor: .top)),
                                            removal: .opacity))
            }
        }.animation(Self.fold, value: manager.closingWindowIDs)
            .onPreferenceChange(StripTabFramesKey.self) { pointer.tabFrames = $0 }
            .animation(.smooth(duration: 0.3), value: indices.map { all[$0].id })
            .animation(.smooth(duration: 0.2), value: active?.id)
    }
}

// The pill's outline: a capsule a little shorter than the strip's row.
struct StripPill: InsettableShape {
    var inset: CGFloat
    var edge: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: edge, dy: min(inset, rect.height / 4) + edge)
        // Round ends (a continuous-corner capsule's path leaves a stray line at each end).
        return Path(roundedRect: r, cornerRadius: max(0, min(r.width, r.height) / 2), style: .circular)
    }
    func inset(by amount: CGFloat) -> StripPill { StripPill(inset: inset, edge: edge + amount) }
}
// The pill's look: the dark surface with the category's color on its edge.
struct StripPillChrome: ViewModifier {
    let inset: CGFloat
    let edge: Color, edgeWidth: CGFloat
    func body(content: Content) -> some View {
        let shape = StripPill(inset: inset)
        return content.background(surface.opacity(0.98)).clipShape(shape)
            .overlay(shape.strokeBorder(edge, lineWidth: edgeWidth).allowsHitTesting(false))
            .contentShape(shape)
            // Where the pill is, for dragging the strip by it.
            .background(GeometryReader { g in Color.clear.preference(key: StripPillFrameKey.self, value: g.frame(in: .global)) })
    }
}
// A list strip's pill grows to show its counter as the list unfolds, on the same
// clock as the strip's own size, so the two move as one. It stays where the strip
// rests on screen (under the pointer) even when the list slides left to fit the display.
struct ListPillModifier: ViewModifier {
    @ObservedObject var barSize: StripBarSize
    let rest: CGFloat, open: CGFloat
    // The strip's resting height, and how far it grows before the pill is fully open.
    let from: CGFloat, stretch: CGFloat
    let listed: Bool
    // The open strip's width: the pill never runs past it.
    let room: CGFloat
    let chrome: StripPillChrome
    func body(content: Content) -> some View {
        var progress: CGFloat = listed ? 1 : 0
        if let height = barSize.size?.height, stretch > 1 { progress = min(1, max(0, (height - from) / stretch)) }
        let width = rest + (open - rest) * progress
        return content.frame(width: width, alignment: .leading).modifier(chrome)
            .offset(x: max(0, min(barSize.restOffsetX, room - width)))
    }
}
// The list's box follows the strip's live size: it unfolds from under the pill and
// folds back, with its own rounded edge all the way. Its rows are laid out once.
struct ListBoxModifier: ViewModifier {
    @ObservedObject var barSize: StripBarSize
    let top: CGFloat, width: CGFloat, fallbackHeight: CGFloat, radius: CGFloat
    let edge: Color, edgeWidth: CGFloat
    // The side of the box next to the pill: its rows stay put there while the far side unfolds.
    var anchor: Alignment = .topLeading
    func body(content: Content) -> some View {
        let height = max(0, (barSize.size?.height ?? fallbackHeight) - top)
        // Round corners: they stay clean while the box is only a few points tall.
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        return content.frame(width: width, height: height, alignment: anchor)
            .background(surface).clipShape(shape)
            .overlay(shape.strokeBorder(edge, lineWidth: edgeWidth).allowsHitTesting(false))
            .contentShape(shape)
            .opacity(height < 1 ? 0 : 1)
    }
}

struct NativeTabCloseButton: NSViewRepresentable {
    let window: ManagedWindow
    let fontSize: CGFloat
    let close: () -> Void
    func makeNSView(context: Context) -> TabCloseButtonView {
        let view = TabCloseButtonView(frame: .zero)
        view.onClose = close
        view.configure(window: window, fontSize: fontSize)
        view.target = view
        view.action = #selector(TabCloseButtonView.press)
        return view
    }
    func updateNSView(_ view: TabCloseButtonView, context: Context) {
        view.onClose = close
        view.configure(window: window, fontSize: fontSize)
    }
}

final class TabCloseButtonView: NSButton {
    var onClose: (() -> Void)?
    private var configuredWindow: String?
    private var configuredFontSize: CGFloat?
    private static var images: [CGFloat: NSImage] = [:]
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(window: ManagedWindow, fontSize: CGFloat) {
        let windowKey = "\(window.id)\u{1F}\(window.appName)\u{1F}\(window.title)"
        guard configuredWindow != windowKey || configuredFontSize != fontSize else { return }
        configuredWindow = windowKey
        configuredFontSize = fontSize
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        if let cached = Self.images[fontSize] { image = cached }
        else if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close window")?.withSymbolConfiguration(.init(pointSize: fontSize, weight: .semibold)) {
            Self.images[fontSize] = symbol
            image = symbol
        }
        contentTintColor = stripCloseTint
        toolTip = "Close window"
        setAccessibilityLabel("Close \(window.appName): \(window.title)")
    }
    @objc func press() { onClose?() }
}

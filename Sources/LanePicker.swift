import SwiftUI
import AppKit

struct LaneWindowStrip: NSViewRepresentable {
    @ObservedObject var manager: WindowManager
    let lane: Lane
    let showBoard: () -> Void
    // Idle strips on the windows fade to a faint outline; a Line is already
    // small, so it stays clearly visible.
    var floor: Double { manager.settings.stripStyle(lane) == .line ? 0.9 : manager.settings.stripPlacement == .onWindows ? 0.35 : 0 }
    func syncBar(_ view: LaneScrollHostingView, animate: Bool) {
        let m = manager.displayedStripMetrics(lane)
        // While a tab folds away the bar shrinks on the same curve and timing.
        // While you drag the strip, the bar simply moves with it.
        view.barSize.go(to: CGSize(width: m.width, height: m.height), screenX: manager.draggingStrip == lane ? nil : manager.stripFrame(lane).minX, animate: animate,
                        screen: view.window?.screen ?? NSScreen.main, duration: manager.stripInMotion ? WindowManager.stripCloseDuration : 0.34)
    }
    func makeNSView(context: Context) -> LaneScrollHostingView {
        let view = LaneScrollHostingView(rootView: AnyView(Color.clear))
        view.visibility.setFloor(floor)
        view.setStripContent(AnyView(LanePickerContent(manager: manager, lane: lane, barSize: view.barSize, pointer: view.pointer, showBoard: showBoard)))
        syncBar(view, animate: false)
        view.onSwitch = { delta in manager.cycleWindow(lane, delta: delta) }
        view.onHover = { active in
            if active { manager.hoveredLane = lane }
            else if manager.hoveredLane == lane { manager.hoveredLane = nil }
            manager.stripHovered(lane, active)
        }
        return view
    }
    func updateNSView(_ view: LaneScrollHostingView, context: Context) {
        view.visibility.setFloor(floor)
        view.setStripContent(AnyView(LanePickerContent(manager: manager, lane: lane, barSize: view.barSize, pointer: view.pointer, showBoard: showBoard)))
        syncBar(view, animate: true)
        view.onSwitch = { delta in manager.cycleWindow(lane, delta: delta) }
        view.onHover = { active in
            if active { manager.hoveredLane = lane }
            else if manager.hoveredLane == lane { manager.hoveredLane = nil }
            manager.stripHovered(lane, active)
        }
    }
}
struct LanePickerContent: View {
    @ObservedObject var manager: WindowManager
    let lane: Lane
    var barSize = StripBarSize()
    @ObservedObject var pointer = StripPointer()
    let showBoard: () -> Void
    @State private var dropTargetID: String?
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
            WindowCountMenu(manager: manager, lane: lane)
            if manager.settings.stripPositions[lane.rawValue] != nil { Button("Move strip back to the top edge") { manager.resetStripPosition(lane) } }
            Divider()
            StripLookMenu(manager: manager, lane: lane, inline: true)
        }
    }
    var expanded: Bool { style == .detailed || (style.expandsOnHover && manager.expandedStrip == lane) }
    // One rounded bar for every style. The name and pane chooser always sit at
    // the left edge and only the right part changes, so nothing under the mouse
    // moves when an Expand-on-hover strip grows. The row is laid out once at its
    // final width and the growing bar reveals it, so text never reflows mid-animation.
    // A narrow strip opens into a list of whole window names instead of chips.
    var listed: Bool { expanded && style.expandsOnHover && manager.stripUsesList(lane) }
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
        let shape = RoundedRectangle(cornerRadius: listed ? 12 * scale : 16 * scale, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6 * scale) {
                moveHandle
                Image(systemName: lane.symbol).foregroundStyle(lane.color)
                Text(manager.name(lane)).font(.system(size: 10 * scale, weight: .semibold)).foregroundStyle(lane.color).lineLimit(1).fixedSize()
                slotPicker
                ZStack(alignment: .leading) {
                    indicators(light: false).opacity(expanded ? 0 : 1).allowsHitTesting(!expanded)
                    chipRow.opacity(expanded && !listed ? 1 : 0).allowsHitTesting(expanded && !listed)
                    HStack { Spacer(minLength: 0); counter }.opacity(listed ? 1 : 0).allowsHitTesting(listed)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.smooth(duration: 0.26), value: expanded)
            }.frame(height: 32 * scale)
            // Mounted all the time (clipped away while idle) so hovering only moves the
            // panel's edge; building the rows and their close buttons mid-open caused the hitch.
            if style.expandsOnHover && manager.stripUsesList(lane) {
                windowList.opacity(listed ? 1 : 0).allowsHitTesting(listed).accessibilityHidden(!listed)
                    .animation(.smooth(duration: 0.2), value: listed)
            }
        }.padding(.horizontal, 12 * scale).font(.system(size: 10 * scale))
            .frame(width: manager.displayedStripMetrics(lane).width, height: manager.displayedStripMetrics(lane).height, alignment: .topLeading)
            // The bar follows the panel's live width; the wider row is clipped by
            // the rounded bar, so the right end stays round while it grows.
            // A list-capable strip is different: its panel jumps to the full size and
            // this bar animates its own size (GPU composited, rows laid out once).
                        .modifier(BarSizeModifier(barSize: barSize, active: ownsSize))
            .background(surface.opacity(0.98)).clipShape(shape)
            .overlay(shape.strokeBorder(lane.color.opacity(stripTargeted ? 1 : 0.25), lineWidth: stripTargeted ? 2 : 1))
            .modifier(BarOffsetModifier(barSize: barSize, active: ownsSize))
            // A tab from another strip dropped anywhere on this one joins this category.
            .dropDestination(for: String.self) { values, point in
                listed ? manager.dropListedTab(values, into: lane, y: point.y) : manager.dropTab(values, into: lane)
            } isTargeted: { stripTargeted = $0 }
            .foregroundStyle(ink).preferredColorScheme(.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    // Every strip that grows on hover animates its own bar (GPU composited, laid out
    // once); its invisible window jumps to the new size instead of resizing each frame.
    var ownsSize: Bool { style.expandsOnHover }
    @ViewBuilder var moveHandle: some View {
        if manager.settings.stripPlacement == .onWindows {
            Image(systemName: "line.3.horizontal").font(.system(size: 9 * scale, weight: .semibold)).foregroundStyle(ink.opacity(0.45))
                .frame(width: 14 * scale, height: 24 * scale)
                .overlay(NativeMoveGrip { frame, phase in
                    switch phase {
                    case .began: manager.draggingStrip = lane
                    case .changed: break
                    case .ended:
                        manager.draggingStrip = nil
                        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
                        manager.moveStrip(lane, to: CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height))
                    }
                })
                .help("Drag to move this strip anywhere. Right-click the strip to move it back.")
        }
    }
    func indicators(light: Bool) -> some View {
        let all = manager.items(lane)
        let active = manager.activeWindow(lane)
        let selectedIndex = all.firstIndex { $0.id == active?.id } ?? 0
        let indices = Layout.pickerIndices(total: all.count, active: selectedIndex, limit: 16)
        return HStack(spacing: 0) {
            if all.isEmpty { Circle().fill(Color.gray.opacity(0.4)).frame(width: 5 * scale, height: 5 * scale) }
            ForEach(Array(indices).map { all[$0] }) { window in
                let index = all.firstIndex { $0.id == window.id } ?? 0
                let selected = window.id == active?.id
                Button { tabClick(window) } label: {
                    Capsule().fill(selected ? (light ? Color(red: 0.21, green: 0.31, blue: 0.22) : lane.color) : (light ? Color(red: 0.68, green: 0.75, blue: 0.67) : Color.white.opacity(0.25)))
                        .frame(width: (selected ? 16 : 4) * scale, height: 5 * scale)
                        .frame(width: (selected ? 18 : 11) * scale, height: 26 * scale)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("\(index + 1)/\(all.count) · \(window.appName) — \(window.title)\nClick to show; Option-click to close; Scroll or use Left/Right to switch; 1–9 / 0 selects a tab.\nDrag it onto another category to move it there.")
                    .accessibilityLabel("Show \(window.appName): \(window.title)")
                    .accessibilityValue(selected ? "Selected" : "")
                    .draggable(manager.beginTabDrag(window)) { tabPreview(window) }
                    .dropDestination(for: String.self) { values, point in return manager.dropTab(values, into: lane, before: window, after: point.x > (selected ? 18 : 11) * scale / 2) } isTargeted: { active in dropTargetID = active ? window.id : (dropTargetID == window.id ? nil : dropTargetID) }
                    .contextMenu { tabMenu(window) }
                    .overlay { if dropTargetID == window.id { RoundedRectangle(cornerRadius: 3).strokeBorder(lane.color, lineWidth: 1).allowsHitTesting(false) } }
            }
        }
    }
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
            }
        } else if slots.count > 2 {
            Menu {
                ForEach(Array(slots.indices), id: \.self) { index in
                    Button("\(manager.slotLabel(lane, index: index)) · \(manager.items(lane).first(where: { $0.id == slots[index] }).map(manager.windowLabel) ?? "Empty")") { manager.selectSlot(lane, index: index) }
                }
            } label: {
                HStack(spacing: 2) { Text("\((manager.activeSlot[lane] ?? 0) + 1)"); Image(systemName: "chevron.down").font(.system(size: 6 * scale)) }
                    .font(.system(size: 9 * scale, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize()
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
        if let chipWidth { manager.freezeTabs(lane, width: chipWidth) }
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
                .foregroundStyle(ink.opacity(0.6))
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
        let selectedIndex = all.firstIndex { $0.id == active?.id } ?? 0
        let indices = Layout.pickerIndices(total: all.count, active: selectedIndex, limit: 16)
        let reserved = WindowStripMetrics.chipRoom(slots: manager.slotIDs(lane).count) * scale
        let fitted = min(WindowStripMetrics.chipLimit(scale: scale), max(36, (manager.displayedStripMetrics(lane).width - reserved) / Double(max(1, indices.count))))
        let chipWidth = manager.frozenTabWidth[lane] ?? fitted
        let spacing = 4 * scale
        // Each tab carries the gap after it, so a closing tab folds its gap away too.
        return HStack(spacing: 0) {
            ForEach(Array(indices).map { all[$0] }) { window in
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
                            .background(selected ? lane.color.opacity(0.18) : Color.white.opacity(0.06)).clipShape(Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).help("\(index + 1)/\(all.count) · \(window.appName) — \(window.title)\nClick to show; × or Option-click closes; hover + Scroll or use Left/Right to switch; 1–9 / 0 selects a tab.\nDrag it onto another category to move it there.")
                        .accessibilityLabel("Show \(window.appName): \(window.title)")
                        .accessibilityValue(selected ? "Selected" : "")
                        .draggable(manager.beginTabDrag(window)) { tabPreview(window) }
                        .dropDestination(for: String.self) { values, point in return manager.dropTab(values, into: lane, before: window, after: point.x > chipWidth / 2) } isTargeted: { active in dropTargetID = active ? window.id : (dropTargetID == window.id ? nil : dropTargetID) }
                        .contextMenu { tabMenu(window) }
                        .overlay { if dropTargetID == window.id { Capsule().strokeBorder(lane.color, lineWidth: 1).allowsHitTesting(false) } }
                        .overlay(alignment: .trailing) {
                            // Only the tab under the pointer shows its ×, inside the chip.
                            if pointer.hoveredTab == window.id {
                                closeButton(window, fontSize: WindowStripMetrics.tabText(scale: scale) - 2, chipWidth: chipWidth)
                                    .frame(width: 18 * scale, height: 18 * scale).padding(.trailing, 2 * scale)
                                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: pointer.hoveredTab == window.id)
                        // A closing tab reports no frame, so the × moves to the tab sliding into its place.
                        .background(GeometryReader { g in Color.clear.preference(key: StripTabFramesKey.self, value: isClosing ? [:] : [window.id: g.frame(in: .global)]) })
                        .accessibilityAction(named: "Close window") { closeTab(window) }
                }.frame(width: chipWidth)
                    .padding(.trailing, spacing)
                    // Collapse to nothing, gap included, so the neighbours slide into its place.
                    .frame(width: isClosing ? 0 : chipWidth + spacing, alignment: .leading)
                    .opacity(isClosing ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!isClosing)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)), removal: .opacity))
            }
            Spacer(minLength: 0)
            counter.padding(.leading, spacing)
        }.animation(Self.fold, value: manager.closingWindowIDs)
        .onPreferenceChange(StripTabFramesKey.self) { pointer.tabFrames = $0 }
        // Widths are free again once the pointer leaves the strip.

        .animation(.smooth(duration: 0.3), value: indices.map { all[$0].id })
            .animation(.smooth(duration: 0.2), value: active?.id)
    }
    var counter: some View {
        let count = manager.items(lane).count
        return HStack(spacing: 4 * scale) {
            Button { manager.cycleWindow(lane, delta: -1) } label: { Image(systemName: "chevron.left") }.disabled(count < 2)
            Text(manager.windowCounter(lane)).font(.system(size: 9 * scale, design: .monospaced)).foregroundStyle(lane.color).fixedSize()
            Button { manager.cycleWindow(lane) } label: { Image(systemName: "chevron.right") }.disabled(count < 2)
        }.buttonStyle(.plain).fixedSize()
    }
    // One window per line with its whole name and the number key that shows it.
    var windowList: some View {
        let all = manager.items(lane)
        let active = manager.activeWindow(lane)
        let selectedIndex = all.firstIndex { $0.id == active?.id } ?? 0
        let indices = Layout.pickerIndices(total: all.count, active: selectedIndex, limit: 16)
        let text = WindowStripMetrics.tabText(scale: scale), row = WindowStripMetrics.listRow(scale: scale)
        return VStack(alignment: .leading, spacing: 0) {
            let numbered = manager.stripItems(lane)
            ForEach(Array(indices).map { all[$0] }) { window in
                // The number key it answers to; a row folding away already has none.
                let index = numbered.firstIndex { $0.id == window.id } ?? 99
                let selected = window.id == active?.id
                let isClosing = manager.closingWindowIDs.contains(window.id)
                HStack(spacing: 0) {
                    Button { tabClick(window) } label: {
                        HStack(spacing: 7) {
                            Text(index < 9 ? "\(index + 1)" : index == 9 ? "0" : "").font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(ink.opacity(0.4)).frame(width: 10, alignment: .trailing)
                            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: text + 2, height: text + 2) }
                            Text(manager.windowLabel(window, long: true)).font(.system(size: text + 1, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).frame(height: row - 2).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(selected ? lane.color : ink.opacity(0.85))
                            .background(selected ? lane.color.opacity(0.18) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(height: row)
                        .help("\(window.appName) — \(window.title)\nDrag above or below another row to save the order. Drag onto another category to move it there.\nClick to show; × or Option-click closes; hover + Scroll or use Left/Right to switch; 1–9 / 0 selects a window.")
                        .accessibilityLabel("Show \(window.appName): \(window.title)")
                        .accessibilityValue(selected ? "Selected" : "")
                        .draggable(manager.beginTabDrag(window)) { tabPreview(window) }
                        .contextMenu { tabMenu(window) }
                        .overlay { if dropTargetID == window.id { RoundedRectangle(cornerRadius: 6).strokeBorder(lane.color, lineWidth: 1).allowsHitTesting(false) } }
                    NativeTabCloseButton(window: window, fontSize: text - 1) { closeTab(window) }
                        .frame(width: 22, height: 22).padding(.trailing, 4)
                }.frame(maxWidth: .infinity, minHeight: row, maxHeight: row)
                    // A closing row folds away at once; the row below rises under the cursor and its ×.
                    .frame(height: isClosing ? 0 : row, alignment: .top)
                    .opacity(isClosing ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!isClosing)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.96, anchor: .top)),
                                            removal: .opacity))
            }
        }.padding(.bottom, 8)
            .animation(Self.fold, value: manager.closingWindowIDs)
            .animation(.smooth(duration: 0.3), value: indices.map { all[$0].id })
            .animation(.smooth(duration: 0.2), value: active?.id)
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
        contentTintColor = NSColor(white: 0.8, alpha: 1)
        toolTip = "Close window"
        setAccessibilityLabel("Close \(window.appName): \(window.title)")
    }
    @objc func press() { onClose?() }
}

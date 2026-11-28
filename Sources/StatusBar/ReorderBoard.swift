import SwiftUI

/// A small local board. Positions are deterministic even while the views animate.
struct BoardGeometry {
    let counts: [Int]
    let width: CGFloat
    let columns: Int
    let cellHeight: CGFloat
    let gap: CGFloat
    let header: CGFloat

    var cellWidth: CGFloat { max(0, (width - CGFloat(columns-1)*gap) / CGFloat(columns)) }
    func sectionHeight(_ index: Int) -> CGFloat {
        let rows = (counts[index] + columns - 1) / columns
        // A section header is itself a drop zone when empty. Its size stays
        // constant as rows cross it, so a popover never moves under the pointer.
        if header > 0 { return header + CGFloat(rows)*(cellHeight + gap) }
        return CGFloat(rows)*cellHeight + CGFloat(max(0, rows-1))*gap
    }
    func top(_ section: Int) -> CGFloat {
        (0..<section).reduce(0) { $0 + sectionHeight($1) + gap }
    }
    var height: CGFloat { top(counts.count) - gap }
    func cell(_ section: Int, _ index: Int) -> CGRect {
        CGRect(x: CGFloat(index % columns)*(cellWidth+gap),
               y: top(section) + header + CGFloat(index / columns)*(cellHeight+gap),
               width: cellWidth, height: cellHeight)
    }

    func destination<Item: Equatable>(at p: CGPoint, groups: [[Item]], moving item: Item) -> [[Item]]? {
        guard CGRect(x: 0, y: 0, width: width, height: height).contains(p),
              let section = groups.indices.last(where: { top($0) <= p.y }) else { return nil }
        let beforePointer = groups[section].enumerated().filter { index, other in
            guard other != item else { return false }
            let frame = cell(section, index)
            if columns == 1 { return p.y >= frame.midY }
            if p.y >= frame.maxY + gap/2 { return true }
            return p.y >= frame.minY - gap/2 && p.x >= frame.midX
        }.count
        var result = groups.map { $0.filter { $0 != item } }
        result[section].insert(item, at: beforePointer)
        return result
    }
}

private struct ExcludedControls: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func reorderControl() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ExcludedControls.self, value: [geo.frame(in: .named("reorderBoard"))])
        })
    }
}

/// The card grid can be taller than its panel. Use the enclosing native clip view
/// so the same drag can reach a card outside the current viewport.
@MainActor
private final class BoardScroll: ObservableObject {
    final class Surface: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    weak var surface: Surface?
    private var timer: Timer?

    func accepts(_ point: CGPoint) -> Bool {
        guard let surface, let clip = surface.enclosingScrollView?.contentView else { return true }
        return clip.bounds.contains(clip.convert(point, from: surface))
    }

    func start(update: @escaping @MainActor @Sendable (CGPoint) -> Void) {
        stop()
        guard let surface, let scroll = surface.enclosingScrollView, let doc = scroll.documentView,
              doc.bounds.height > scroll.contentView.bounds.height else { return }
        let timer = Timer(timeInterval: 1.0/30, repeats: true) { [weak surface, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let surface, let scroll, let window = surface.window else { return }
                let clip = scroll.contentView
                let mouse = window.mouseLocationOutsideOfEventStream
                let point = clip.convert(mouse, from: nil)
                guard clip.bounds.contains(point) else { return }
                let bottom = point.y - clip.bounds.minY, top = clip.bounds.maxY - point.y
                let delta = min(0, bottom - 22) + max(0, 22 - top)
                guard delta != 0 else { return }
                let next = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: delta * 0.55))
                guard abs(next.minY-clip.bounds.minY) >= 0.5 else { return }
                clip.scroll(to: next.origin)
                scroll.reflectScrolledClipView(clip)
                update(surface.convert(mouse, from: nil))
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
}

private struct BoardSurface: NSViewRepresentable {
    let scroll: BoardScroll
    func makeNSView(context: Context) -> BoardScroll.Surface {
        let view = BoardScroll.Surface()
        scroll.surface = view
        return view
    }
    func updateNSView(_ view: BoardScroll.Surface, context: Context) {}
}

private struct BoardDrag<Item> {
    let item: Item
    let grabOffset: CGSize
    var origin: CGPoint
    var groups: [[Item]]
}

/// One gesture owns the drag until release, including moves between empty sections.
/// Only the preview changes during that gesture. Controls inside rows retain their clicks.
struct ReorderBoard<Item: Hashable, Row: View>: View {
    let groups: [[Item]]
    var headings: [String] = []
    var columns = 1
    var cellHeight: CGFloat = 32
    var gap: CGFloat = 4
    var editable = true
    var canMove: (Item) -> Bool = { _ in true }
    let commit: ([[Item]]) -> Void
    @ViewBuilder let row: (Item) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var scroll = BoardScroll()
    @GestureState private var gestureActive = false
    @State private var drag: BoardDrag<Item>?
    @State private var cancelled = false
    @State private var escapeMonitor: Any?
    @State private var exclusions: [CGRect] = []
    @FocusState private var focused: Item?

    private var visible: [[Item]] { drag?.groups ?? groups }
    private func geometry(width: CGFloat) -> BoardGeometry {
        BoardGeometry(counts: visible.map(\.count), width: width, columns: columns,
                      cellHeight: cellHeight, gap: gap, header: headings.isEmpty ? 0 : 28)
    }

    var body: some View {
        GeometryReader { proxy in
            let board = geometry(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(headings.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(headings[i]).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Rectangle().fill(.separator).frame(height: 1)
                        if visible[i].isEmpty {
                            Text("拖入这里").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, visible[i].isEmpty ? 6 : 0)
                    .frame(height: board.header)
                    .background {
                        if visible[i].isEmpty {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        }
                    }
                    .offset(y: board.top(i))
                }
                if let drag, let slot = position(drag.item, in: board) {
                    RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.065))
                        .frame(width: slot.width, height: slot.height).offset(x: slot.minX, y: slot.minY)
                        .accessibilityHidden(true)
                }
                ForEach(groups.flatMap { $0 }, id: \.self) { item in
                    if let slot = position(item, in: board) {
                        let lifted = drag.flatMap { $0.item == item ? $0.origin : nil }
                        row(item)
                            .frame(width: slot.width, height: slot.height)
                            .contentShape(Rectangle())
                            .focusable(editable).focused($focused, equals: item)
                            .modifier(BoardKeyboard(enabled: editable && canMove(item), move: { move(item, by: $0) },
                                                    transfer: headings.count == 2 ? { transfer(item) } : nil))
                            .focusEffectDisabled(lifted != nil)
                            .compositingGroup()
                            .shadow(color: .black.opacity(lifted == nil ? 0 : 0.16), radius: 4, y: 2)
                            .offset(x: lifted?.x ?? slot.minX, y: lifted?.y ?? slot.minY)
                            .animation(lifted != nil || reduceMotion ? nil : .easeOut(duration: 0.14), value: slot.origin)
                            .zIndex(lifted == nil ? 0 : 1)
                    }
                }
            }
            .frame(width: proxy.size.width, height: board.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .background { if editable { BoardSurface(scroll: scroll) } }
            .coordinateSpace(name: "reorderBoard")
            .simultaneousGesture(gesture(width: proxy.size.width), isEnabled: editable)
        }
        .frame(height: geometry(width: 0).height)
        .onExitCommand(perform: escapeAction)
        .onPreferenceChange(ExcludedControls.self) { exclusions = $0 }
        .onChange(of: gestureActive) { _, active in
            if !active { finish() }
        }
        .onDisappear { finish() }
        .onChange(of: editable) { finish() }
        .onChange(of: groups) { finish() }
    }

    private var escapeAction: (() -> Void)? {
        guard drag != nil else { return nil }
        return { cancelDrag() }
    }

    private func position(_ item: Item, in board: BoardGeometry) -> CGRect? {
        for section in visible.indices {
            if let index = visible[section].firstIndex(of: item) { return board.cell(section, index) }
        }
        return nil
    }

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("reorderBoard"))
            .updating($gestureActive) { _, state, _ in state = true }
            .onChanged { value in
                guard !cancelled else { return }
                let board = geometry(width: width)
                if drag == nil {
                    guard !exclusions.contains(where: { $0.contains(value.startLocation) }),
                          let item = groups.joined().first(where: { position($0, in: board)?.contains(value.startLocation) == true }),
                          canMove(item),
                          let frame = position(item, in: board) else { return }
                    let offset = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
                    drag = BoardDrag(item: item, grabOffset: offset, origin: frame.origin, groups: groups)
                    scroll.start { updateDrag(at: $0, width: width) }
                    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        guard event.keyCode == 53 else { return event }
                        cancelDrag()
                        return nil
                    }
                }
                updateDrag(at: value.location, width: width)
            }
            .onEnded { value in
                defer { finish() }
                guard scroll.accepts(value.location), let drag, let final = geometry(width: width).destination(at: value.location, groups: drag.groups, moving: drag.item),
                      final != groups else { return }
                commit(final)
            }
    }

    private func updateDrag(at point: CGPoint, width: CGFloat) {
        guard var next = drag else { return }
        next.origin = CGPoint(x: point.x - next.grabOffset.width, y: point.y - next.grabOffset.height)
        if scroll.accepts(point), let destination = geometry(width: width).destination(at: point, groups: next.groups, moving: next.item) {
            next.groups = destination
        }
        drag = next
    }

    private func cancelDrag() {
        finish()
        cancelled = true
    }

    private func finish() {
        scroll.stop()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        drag = nil
        cancelled = false
    }

    private func move(_ item: Item, by delta: Int) {
        var next = groups
        guard let section = next.firstIndex(where: { $0.contains(item) }),
              let index = next[section].firstIndex(of: item), next[section].indices.contains(index+delta) else { return }
        next[section].swapAt(index, index+delta)
        commit(next)
    }

    private func transfer(_ item: Item) {
        guard groups.count == 2, let section = groups.firstIndex(where: { $0.contains(item) }) else { return }
        var next = groups
        next[section].removeAll { $0 == item }
        next[1-section].append(item)
        commit(next)
    }
}

private struct BoardKeyboard: ViewModifier {
    let enabled: Bool
    let move: (Int) -> Void
    let transfer: (() -> Void)?
    func body(content: Content) -> some View {
        if enabled {
            content
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.space) { guard let transfer else { return .ignored }; transfer(); return .handled }
                .accessibilityAction(named: "向前移动") { move(-1) }
                .accessibilityAction(named: "向后移动") { move(1) }
                .accessibilityActions {
                    if let transfer { Button("切换显示与隐藏", action: transfer) }
                }
        } else { content }
    }
}

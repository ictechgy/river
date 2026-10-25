import AppKit
import Combine
import SwiftUI

@MainActor
public final class DockDragSession: ObservableObject {
  @Published public private(set) var pane: WorkbenchPane?
  @Published public private(set) var target: DockDropTarget?
  @Published public private(set) var location = CGPoint.zero
  public var frames: [WorkbenchPane: CGRect] = [:]
  public var bounds = CGRect.zero
  public init() {}
  public func drag(_ pane: WorkbenchPane, to point: CGPoint) {
    self.pane = pane
    location = point
    guard bounds.contains(point) else {
      target = nil
      return
    }
    // The outer rim targets the entire workspace, not only the nearest pane.
    if point.x < bounds.minX + 18 {
      target = .init(pane: nil, edge: .left)
    } else if point.x > bounds.maxX - 18 {
      target = .init(pane: nil, edge: .right)
    } else if point.y < bounds.minY + 18 {
      target = .init(pane: nil, edge: .top)
    } else if point.y > bounds.maxY - 18 {
      target = .init(pane: nil, edge: .bottom)
    } else if let destination = WorkbenchPane.allCases.first(where: {
      $0 != pane && frames[$0]?.contains(point) == true
    }), let frame = frames[destination] {
      target = .init(pane: destination, edge: DockDropTarget.edge(at: point, in: frame))
    } else {
      target = nil
    }
  }
  public func finish(in layout: LayoutPreferences) {
    if let pane, let target { layout.dockPane(pane, nextTo: target.pane, edge: target.edge) }
    cancel()
  }
  public func cancel() {
    pane = nil
    target = nil
  }
}

private struct DockGeometryKey: PreferenceKey {
  static var defaultValue: [WorkbenchPane: CGRect] { [:] }
  static func reduce(value: inout [WorkbenchPane: CGRect], nextValue: () -> [WorkbenchPane: CGRect])
  {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct DockWorkspace: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var layout: LayoutPreferences
  let drag: DockDragSession
  @StateObject private var branches: BranchBrowserModel
  @StateObject private var diffPresentation: DiffPresentationModel
  init(
    store: WorkbenchStore, layout: LayoutPreferences, drag: DockDragSession,
    diffPresentation: DiffPresentationModel? = nil, branchBrowser: BranchBrowserModel? = nil
  ) {
    self.store = store
    self.layout = layout
    self.drag = drag
    _branches = StateObject(wrappedValue: branchBrowser ?? BranchBrowserModel())
    _diffPresentation = StateObject(wrappedValue: diffPresentation ?? DiffPresentationModel())
  }
  var body: some View {
    GeometryReader { geometry in
      let minimum = layout.dockLayout.root?.minimumSize(focusedPane: layout.focusedPane) ?? .zero
      let size = CGSize(
        width: max(geometry.size.width, minimum.width),
        height: max(geometry.size.height, minimum.height))
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          if let root = layout.dockLayout.root {
            DockNodeView(
              node: root, store: store, layout: layout, drag: drag, branches: branches,
              diffPresentation: diffPresentation)
          } else {
            VStack(spacing: 16) {
              Text("표시할 패널을 선택하세요").font(.headline)
              HStack {
                ForEach(WorkbenchPane.allCases) { pane in
                  Button(pane.title) { layout.showPane(pane) }
                }
              }
              Button("기본 배치 복구") { layout.apply(.focus) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          DockDragOverlay(drag: drag, size: size).allowsHitTesting(false)
        }.frame(width: size.width, height: size.height)
          .coordinateSpace(name: "dock-canvas")
          .onPreferenceChange(DockGeometryKey.self) { frames in
            drag.frames = frames
            drag.bounds = CGRect(origin: .zero, size: size)
          }
      }.background(WorkbenchTheme.chrome)
        .onExitCommand {
          if drag.pane != nil { drag.cancel() } else { layout.restorePaneLayout() }
        }
        .onChange(of: layout.focusedPane) { _, _ in drag.cancel() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in drag.cancel() }
    }.background(
      DockFocusResponderReset(focusedPane: layout.focusedPane) {
        if drag.pane != nil { drag.cancel() } else { layout.restorePaneLayout() }
      })
  }
}

private struct DockNodeView: View {
  let node: DockNode
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var layout: LayoutPreferences
  let drag: DockDragSession
  @ObservedObject var branches: BranchBrowserModel
  @ObservedObject var diffPresentation: DiffPresentationModel
  var body: some View {
    switch node {
    case .tabs(_, let panes, let active):
      let displayed = layout.focusedPane.flatMap { panes.contains($0) ? $0 : nil } ?? active
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          ScrollViewReader { proxy in
            ScrollView(.horizontal) {
              HStack(spacing: 0) {
                ForEach(panes) { pane in
                  DockTab(
                    pane: pane, title: paneTitle(pane), selected: pane == displayed,
                    showsSelection: panes.count > 1, layout: layout, drag: drag
                  ).id(pane)
                }
              }
            }.scrollIndicators(.hidden)
              .onChange(of: displayed) { _, pane in proxy.scrollTo(pane, anchor: .center) }
          }
          if layout.focusedPane == displayed {
            Button("원래 배치로", systemImage: "arrow.down.right.and.arrow.up.left") {
              layout.restorePaneLayout()
            }.font(.system(size: 11)).buttonStyle(.borderless).fixedSize()
              .help("확대하기 전의 패널 배치와 비율로 돌아갑니다.")
              .padding(.horizontal, 6)
          }
          Menu {
            if panes.count > 1 {
              Menu("탭 선택") {
                ForEach(panes) { pane in
                  Button(paneTitle(pane)) { layout.selectPane(pane) }
                    .disabled(pane == displayed)
                }
              }
              Divider()
            }
            Button(layout.focusedPane == displayed ? "원래 배치로" : "패널 크게 보기") {
              layout.focusPane(displayed)
            }
            Divider()
            ForEach(DockEdge.allCases) { edge in
              Menu(edge.title) {
                ForEach(layout.dockLayout.panes.filter { $0 != displayed }) { target in
                  Button(target.title) { layout.dockPane(displayed, nextTo: target, edge: edge) }
                }
              }
            }
            Menu("전체 영역") {
              ForEach(DockEdge.allCases.filter { $0 != .center }) { edge in
                Button(edge.title) { layout.dockPane(displayed, nextTo: nil, edge: edge) }
              }
            }
            Divider()
            Button("이 패널 숨기기") { layout.hidePane(displayed) }
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("\(displayed.title) 배치 메뉴").padding(.horizontal, 7)
        }.frame(height: 32).background(WorkbenchTheme.panel)
        Divider()
        paneContent(displayed).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
      }.riverPaneSurface()
        .background(
          GeometryReader { geometry in
            Color.clear.preference(
              key: DockGeometryKey.self,
              value: layout.focusedPane.map { !panes.contains($0) } == true
                ? [:]
                : Dictionary(
                  uniqueKeysWithValues: panes.map {
                    ($0, geometry.frame(in: .named("dock-canvas")))
                  })
            )
          })
    case .split(let id, let axis, let ratio, let first, let second):
      DockSplit(
        id: id, axis: axis, ratio: ratio,
        firstMinimum: first.minimumSize(focusedPane: layout.focusedPane),
        secondMinimum: second.minimumSize(focusedPane: layout.focusedPane),
        firstPresented: layout.focusedPane.map { first.contains($0) } ?? true,
        secondPresented: layout.focusedPane.map { second.contains($0) } ?? true,
        accessibilityTitle: dividerTitle(first: first, second: second, axis: axis), layout: layout
      ) {
        AnyView(
          DockNodeView(
            node: first, store: store, layout: layout, drag: drag, branches: branches,
            diffPresentation: diffPresentation))
      } second: {
        AnyView(
          DockNodeView(
            node: second, store: store, layout: layout, drag: drag, branches: branches,
            diffPresentation: diffPresentation))
      }
    }
  }
  private func dividerTitle(first: DockNode, second: DockNode, axis: DockAxis) -> String {
    if first.panes.count == 1, second.panes.count == 1,
      let a = first.panes.first, let b = second.panes.first
    {
      return "\(a.title) · \(b.title) 사이 크기 조절"
    }
    return axis == .horizontal ? "좌우 패널 너비 조절" : "위아래 패널 높이 조절"
  }
  private func paneTitle(_ pane: WorkbenchPane) -> String {
    switch pane {
    case .stash: "Stash \(store.stashes.count)"
    case .commit: "커밋 · 스테이징 \(store.stagedCount)"
    default: pane.title
    }
  }
  @ViewBuilder private func paneContent(_ pane: WorkbenchPane) -> some View {
    switch pane {
    case .files: WorkspaceSidebar(store: store)
    case .diff: DiffWorkspace(store: store, presentation: diffPresentation,
      openTaskInformation: { layout.showPane(.details) })
    case .graph: CommitHistory(store: store, expanded: .constant(true), allowsCollapse: false)
    case .commit:
      TaskInspector(
        store: store, historyExpanded: .constant(false), showsHistorySummary: false,
        section: .commit)
    case .stash:
      TaskInspector(
        store: store, historyExpanded: .constant(false), showsHistorySummary: false, section: .stash
      )
    case .details:
      TaskInspector(
        store: store, historyExpanded: .constant(false), showsHistorySummary: false,
        section: .details, openHistory: { layout.showPane(.graph) },
        openFiles: { layout.showPane(.files) }, openCommit: { layout.showPane(.commit) })
    case .branches: BranchesView(store: store, model: branches) { layout.hidePane(.branches) }
    }
  }
}

private struct DockTab: View {
  let pane: WorkbenchPane
  let title: String
  let selected: Bool
  let showsSelection: Bool
  @ObservedObject var layout: LayoutPreferences
  let drag: DockDragSession
  @GestureState private var dragging = false
  @State private var hovering = false
  @State private var cursorPushed = false
  var body: some View {
    Button {
      layout.selectPane(pane)
    } label: {
      HStack(spacing: 7) {
        Image(
          systemName: layout.focusedPane == nil
            ? "circle.grid.2x3.fill" : "arrow.up.left.and.arrow.down.right"
        )
        .font(.system(size: 8))
        .foregroundStyle(WorkbenchTheme.secondaryText).opacity(hovering ? 1 : 0.35)
        Label {
          Text(title)
        } icon: {
          Image(systemName: pane.symbol)
            .foregroundStyle(selected ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
        }
      }
      .font(.system(size: 12, weight: selected ? .semibold : .regular))
      .foregroundStyle(selected ? WorkbenchTheme.primaryText : WorkbenchTheme.secondaryText)
      .padding(.horizontal, 12).frame(height: 32)
      .background(selected && showsSelection ? WorkbenchTheme.canvas : .clear)
      .overlay(alignment: .top) {
        if selected && showsSelection {
          Rectangle().fill(WorkbenchTheme.accent).frame(height: 2).allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .named("dock-canvas"))
        .updating($dragging) { _, state, _ in state = true }
        .onChanged { value in
          guard layout.focusedPane == nil else { return }
          drag.drag(pane, to: value.location)
        }
        .onEnded { value in
          guard layout.focusedPane == nil else {
            drag.cancel()
            return
          }
          drag.drag(pane, to: value.location)
          drag.finish(in: layout)
        }
    )
    .onChange(of: dragging) { _, active in if !active { drag.cancel() } }
    .onHover { inside in
      guard inside != hovering else { return }
      hovering = inside
      if inside && layout.focusedPane == nil {
        NSCursor.openHand.push()
        cursorPushed = true
      } else if cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      }
    }
    .onChange(of: layout.focusedPane) { _, focused in
      if focused != nil, cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      } else if focused == nil, hovering, !cursorPushed {
        NSCursor.openHand.push()
        cursorPushed = true
      }
    }
    .onDisappear {
      if cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      }
      hovering = false
    }
    .accessibilityLabel(
      layout.focusedPane == nil ? "\(title) 패널 · 드래그하여 이동" : "\(title) 패널"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(
      layout.focusedPane == nil
        ? "제목을 끌어 다른 패널의 좌·우·위·아래에 놓기 · 중앙은 탭 합치기"
        : "확대 중에는 끌어 이동하지 않습니다. ‘원래 배치로’ 돌아가거나 배치 메뉴를 사용하세요.")
  }
}

// Pointer movement invalidates only this overlay, not the live diff/graph tree.
private struct DockDragOverlay: View {
  @ObservedObject var drag: DockDragSession
  let size: CGSize
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    ZStack(alignment: .topLeading) {
      if let target = drag.target {
        let frame = target.pane.flatMap { drag.frames[$0] } ?? drag.bounds
        DockDropPreview(frame: frame, edge: target.edge)
      }
      if let pane = drag.pane {
        Label("\(pane.title) · \(drag.target?.edge.title ?? "이동 취소")", systemImage: "hand.draw")
          .font(.system(size: 12, weight: .semibold)).padding(10)
          .background {
            if reduceTransparency {
              RoundedRectangle(cornerRadius: 7).fill(WorkbenchTheme.elevated)
            } else {
              RoundedRectangle(cornerRadius: 7).fill(.regularMaterial)
            }
          }
          .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorkbenchTheme.line))
          .position(
            x: min(size.width - 90, max(90, drag.location.x)), y: max(18, drag.location.y - 24))
      }
    }.frame(width: size.width, height: size.height)
  }
}

struct DockSplitGeometry {
  let available: Double
  let firstMinimum: Double
  let secondMinimum: Double
  func clampedRatio(_ ratio: Double) -> Double {
    let space = max(1, available)
    let lower = min(space, max(0, firstMinimum))
    let upper = max(lower, space - max(0, secondMinimum))
    return min(upper, max(lower, space * (ratio.isFinite ? ratio : 0.5))) / space
  }
  func resizedRatio(from ratio: Double, by distance: Double) -> Double {
    clampedRatio(clampedRatio(ratio) + distance / max(1, available))
  }
}

private struct DockSplit<First: View, Second: View>: View {
  let id: String
  let axis: DockAxis
  let ratio: Double
  let firstMinimum: CGSize
  let secondMinimum: CGSize
  let firstPresented: Bool
  let secondPresented: Bool
  let accessibilityTitle: String
  @ObservedObject var layout: LayoutPreferences
  @ViewBuilder let first: () -> First
  @ViewBuilder let second: () -> Second
  @State private var proposedRatio: Double?
  @State private var dragStart: Double?
  @State private var hovering = false
  @GestureState private var resizing = false
  var body: some View {
    GeometryReader { geometry in
      let showsDivider = firstPresented && secondPresented
      let dividerLength = showsDivider ? 6.0 : 0
      let available = max(
        0, (axis == .horizontal ? geometry.size.width : geometry.size.height) - dividerLength)
      let minimumA = axis == .horizontal ? firstMinimum.width : firstMinimum.height
      let minimumB = axis == .horizontal ? secondMinimum.width : secondMinimum.height
      let sizing = DockSplitGeometry(
        available: available, firstMinimum: minimumA, secondMinimum: minimumB)
      let length =
        firstPresented
        ? (secondPresented ? available * sizing.clampedRatio(proposedRatio ?? ratio) : available)
        : 0
      let secondLength = secondPresented ? available - length : 0
      if axis == .horizontal {
        HStack(spacing: 0) {
          first().frame(width: max(0, length)).clipped()
            .opacity(firstPresented ? 1 : 0).accessibilityHidden(!firstPresented)
            .disabled(!firstPresented)
            .allowsHitTesting(firstPresented)
          divider(sizing: sizing).frame(width: dividerLength)
            .opacity(showsDivider ? 1 : 0).accessibilityHidden(!showsDivider)
            .allowsHitTesting(showsDivider)
          second().frame(width: max(0, secondLength)).clipped()
            .opacity(secondPresented ? 1 : 0).accessibilityHidden(!secondPresented)
            .disabled(!secondPresented)
            .allowsHitTesting(secondPresented)
        }
      } else {
        VStack(spacing: 0) {
          first().frame(height: max(0, length)).clipped()
            .opacity(firstPresented ? 1 : 0).accessibilityHidden(!firstPresented)
            .disabled(!firstPresented)
            .allowsHitTesting(firstPresented)
          divider(sizing: sizing).frame(height: dividerLength)
            .opacity(showsDivider ? 1 : 0).accessibilityHidden(!showsDivider)
            .allowsHitTesting(showsDivider)
          second().frame(height: max(0, secondLength)).clipped()
            .opacity(secondPresented ? 1 : 0).accessibilityHidden(!secondPresented)
            .disabled(!secondPresented)
            .allowsHitTesting(secondPresented)
        }
      }
    }
    .onChange(of: layout.focusedPane) { _, _ in
      proposedRatio = nil
      dragStart = nil
      if hovering {
        NSCursor.pop()
        hovering = false
      }
    }
  }
  private func divider(sizing: DockSplitGeometry) -> some View {
    Rectangle().fill(WorkbenchTheme.chrome)
      .overlay {
        Rectangle().fill(hovering || resizing ? WorkbenchTheme.accent : WorkbenchTheme.line)
          .frame(
            width: axis == .horizontal ? (hovering || resizing ? 2 : 1) : nil,
            height: axis == .vertical ? (hovering || resizing ? 2 : 1) : nil
          )
          .allowsHitTesting(false)
      }.contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .updating($resizing) { _, state, _ in state = true }
          .onChanged { value in
            guard layout.focusedPane == nil else { return }
            if dragStart == nil { dragStart = sizing.clampedRatio(ratio) }
            let distance = axis == .horizontal ? value.translation.width : value.translation.height
            proposedRatio = sizing.resizedRatio(from: dragStart ?? ratio, by: distance)
          }.onEnded { value in
            guard layout.focusedPane == nil else {
              proposedRatio = nil
              dragStart = nil
              return
            }
            let distance = axis == .horizontal ? value.translation.width : value.translation.height
            layout.resizeDock(
              id, ratio: sizing.resizedRatio(from: dragStart ?? ratio, by: distance))
            proposedRatio = nil
            dragStart = nil
          }
      )
      .onChange(of: resizing) { _, active in
        if !active {
          proposedRatio = nil
          dragStart = nil
        }
      }
      .onHover { inside in
        guard layout.focusedPane == nil else { return }
        guard inside != hovering else { return }
        hovering = inside
        if inside {
          (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
          NSCursor.pop()
        }
      }.onDisappear {
        if hovering {
          NSCursor.pop()
          hovering = false
        }
      }
      .accessibilityElement().accessibilityLabel(accessibilityTitle)
      .accessibilityValue("\(Int(ratio * 100)) 퍼센트")
      .accessibilityAdjustableAction { direction in
        guard layout.focusedPane == nil else { return }
        layout.resizeDock(
          id,
          ratio: sizing.resizedRatio(
            from: ratio,
            by: sizing.available * (direction == .increment ? 0.05 : -0.05)))
      }
  }
}

private struct DockDropPreview: View {
  let frame: CGRect
  let edge: DockEdge
  var body: some View {
    let rect = previewRect
    RoundedRectangle(cornerRadius: 5).fill(WorkbenchTheme.accent.opacity(0.14))
      .overlay(RoundedRectangle(cornerRadius: 5).stroke(WorkbenchTheme.accent, lineWidth: 2))
      .overlay(
        Text(edge.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(
          WorkbenchTheme.accentText)
      )
      .frame(width: max(1, rect.width - 6), height: max(1, rect.height - 6))
      .position(x: rect.midX, y: rect.midY)
  }
  private var previewRect: CGRect {
    switch edge {
    case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
    case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
    case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
    case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
    case .center: frame
    }
  }
}

extension DockEdge: Identifiable { public var id: String { rawValue } }

extension DockNode {
  fileprivate func minimumSize(focusedPane: WorkbenchPane?) -> CGSize {
    if let focusedPane {
      return contains(focusedPane) ? focusedPane.minimumSize : .zero
    }
    switch self {
    case .tabs(_, _, let active):
      return active.minimumSize
    case .split(_, let axis, _, let first, let second):
      let a = first.minimumSize(focusedPane: nil)
      let b = second.minimumSize(focusedPane: nil)
      return axis == .horizontal
        ? CGSize(width: a.width + b.width + 6, height: max(a.height, b.height))
        : CGSize(width: max(a.width, b.width), height: a.height + b.height + 6)
    }
  }
}

extension WorkbenchPane {
  fileprivate var minimumSize: CGSize {
    CGSize(
      width: self == .branches || self == .diff ? 340 : 210,
      height: self == .branches ? 300 : (self == .commit ? 235 : 150))
  }
}

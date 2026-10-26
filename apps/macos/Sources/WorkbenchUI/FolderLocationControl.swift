import AppKit
import SwiftUI

/// Folder identity is always visible; the complete location and switch are one click away.
struct CurrentFolderContext: View {
  @ObservedObject var store: WorkbenchStore
  @State private var showLocation = false
  private var isTask: Bool { store.selection?.opId != nil }
  private var unavailable: Bool { store.taskInformationUnavailable }
  private var pending: Bool { store.pendingWorktree }
  private var path: String {
    guard !unavailable else { return "" }
    return store.repository?.path
      ?? (isTask
        ? store.taskRepository?.plan.worktreePath
        : store.workspace?.repositories.first(where: { $0.id == store.selection?.repoId })?.path)
      ?? ""
  }
  private var kind: String {
    if unavailable { return store.taskInformationTitle }
    if pending { return "예정 작업 폴더" }
    return isTask ? "작업용 폴더" : "원래 프로젝트 폴더"
  }
  private var basename: String { path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent }
  private var contextColor: Color {
    unavailable || pending ? WorkbenchTheme.warning : WorkbenchTheme.secondaryText
  }
  var body: some View {
    Button { showLocation.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: unavailable || pending ? "exclamationmark.circle" : isTask ? "folder.badge.gearshape" : "folder")
          .foregroundStyle(contextColor)
        Text(kind).foregroundStyle(contextColor).fixedSize(horizontal: true, vertical: false)
        if !basename.isEmpty {
          Text(basename).foregroundStyle(WorkbenchTheme.primaryText)
            .lineLimit(1).truncationMode(.middle)
        }
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }.font(.system(size: 12)).contentShape(Rectangle())
    }.buttonStyle(ChromeButtonStyle(active: showLocation))
      .help("폴더 위치와 전환 · \(unavailable ? store.taskInformationHint : path)")
      .accessibilityLabel("현재 위치 · \(kind)")
      .accessibilityValue(path)
      .accessibilityHint("전체 경로, Finder에서 열기와 폴더 전환")
      .popover(isPresented: $showLocation, arrowEdge: .bottom) {
        locationDetails
      }
  }
  private var locationDetails: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(unavailable ? store.taskInformationTitle : pending ? store.pendingWorktreeTitle : kind)
        .font(.system(size: 14, weight: .semibold))
      if unavailable || pending {
        Text(unavailable ? store.taskInformationHint : store.pendingWorktreeHint)
          .font(.system(size: 12)).foregroundStyle(contextColor).fixedSize(horizontal: false, vertical: true)
      }
      if !path.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          if pending {
            Text("예정 위치 · 아직 준비되지 않은 폴더")
              .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning)
          }
          Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("경로 복사") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(path, forType: .string)
            }
            Button("Finder에서 열기") { store.openCurrentWorktree() }
              .disabled(store.repository == nil || unavailable || pending)
          }
        }
      }
      if let op = store.contextOperation, let repoID = store.selection?.repoId {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("\(repoID) 폴더 전환").font(.system(size: 12, weight: .semibold))
          folderChoice("작업용 폴더", selected: isTask) {
            store.select(.init(repoId: repoID, opId: op.id))
          }
          folderChoice("원래 프로젝트 폴더", selected: !isTask) {
            store.select(.init(repoId: repoID))
          }
        }
      }
    }.padding(18).frame(width: 390, alignment: .leading)
      .foregroundStyle(WorkbenchTheme.primaryText).background(WorkbenchTheme.canvas)
  }
  private func folderChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button {
      action()
      showLocation = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
        Text(title)
        Spacer()
        if selected { Text("현재 위치").foregroundStyle(WorkbenchTheme.secondaryText) }
      }.font(.system(size: 12)).padding(8).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(store.busy)
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct RepositoryBranchContext: View {
  @ObservedObject var store: WorkbenchStore
  private var branch: String {
    if store.taskInformationUnavailable { return "브랜치 확인 필요" }
    let name = store.repository?.snapshot.branch ?? store.taskRepository?.plan.branchRef ?? ""
    if !name.isEmpty { return name.replacingOccurrences(of: "refs/heads/", with: "") }
    if let head = store.repository?.snapshot.head, !head.isEmpty { return "HEAD · \(head.prefix(8))" }
    if store.selectionCheckFailed { return "브랜치 확인 실패" }
    return store.pendingWorktree ? "브랜치 준비 대기" : "불러오는 중…"
  }
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.branch").foregroundStyle(WorkbenchTheme.accentText)
      Text(branch).font(.system(size: 12, design: .monospaced))
        .lineLimit(1).truncationMode(.middle).foregroundStyle(WorkbenchTheme.secondaryText)
    }.help(branch).accessibilityElement(children: .combine)
      .accessibilityLabel("브랜치 · \(branch)")
  }
}

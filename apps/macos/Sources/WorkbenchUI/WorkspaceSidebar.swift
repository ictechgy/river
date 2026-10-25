import SwiftUI
import WorkbenchProtocol

struct WorkspaceSidebar: View {
  @Environment(\.riverReading) private var reading
  @ObservedObject var store: WorkbenchStore
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        if store.isViewingStash {
          Button("현재 변경으로 돌아가기", systemImage: "arrow.uturn.backward") { store.showWorkingChanges() }
            .font(.system(size: 12)).buttonStyle(.link)
        } else {
          Picker(
            "파일 목록 필터", selection: Binding(get: { store.staged }, set: { store.chooseStaged($0) })
          ) {
            Text("스테이징 전 \(store.repository?.files.filter(\.isWorking).count ?? 0)").tag(false)
            Text("커밋에 포함 \(store.stagedCount)").tag(true)
          }.pickerStyle(.segmented).labelsHidden().font(.system(size: 12))
            .help("목록만 전환합니다. 파일을 선택한 뒤 Diff 위의 파일 전체 스테이징 버튼을 사용하세요.")
          HStack(spacing: 6) {
            Text("목록 전환 · 스테이징은 Diff에서")
              .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Menu {
              Toggle("미검토·다시 검토가 필요한 파일만", isOn: $store.onlyUnreviewedFiles)
            } label: {
              Image(systemName: store.onlyUnreviewedFiles ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(store.onlyUnreviewedFiles ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
            }.menuStyle(.borderlessButton).fixedSize()
              .accessibilityLabel("파일 검토 필터")
              .help("개인 읽기 기록으로 필터링합니다. 테스트나 병합 승인을 뜻하지 않습니다.")
          }
          if store.onlyUnreviewedFiles {
            HStack(spacing: 6) {
              Text("미검토·다시 검토 \(store.displayedFiles.count)/\(store.visibleFiles.count)")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.accentText)
              Spacer(minLength: 0)
              Button("해제") { store.onlyUnreviewedFiles = false }
                .font(.system(size: 12)).buttonStyle(.link)
            }
          }
        }
      }.padding(12).background(WorkbenchTheme.panel)
      if store.displayedFiles.isEmpty {
        Text(store.onlyUnreviewedFiles && !store.visibleFiles.isEmpty && !store.isViewingStash
          ? "현재 변경을 모두 검토했습니다. 필터를 끄면 전체 파일이 표시됩니다." : emptyMessage)
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: reading.density == .comfortable ? 3 : 1) {
            ForEach(store.displayedFiles) { file in fileRow(file) }
          }.padding(.horizontal, 8).padding(.bottom, 12)
        }
      }
      if store.isViewingStash {
        Divider()
        Label("저장된 변경 · 읽기 전용", systemImage: "archivebox")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12).background(WorkbenchTheme.panel)
      }
    }.background(WorkbenchTheme.canvas)
  }
  private var emptyMessage: String {
    if store.isViewingStash {
      return store.stashError
        ?? (store.stashDetail == nil ? "Stash 파일을 불러오는 중…" : "저장된 파일 변경이 없습니다.")
    }
    if store.pendingWorktree { return store.pendingWorktreeHint }
    if store.selectionCheckFailed { return "파일 목록을 확인하지 못했습니다. 새로고침으로 다시 확인해 주세요." }
    if store.repository == nil { return "파일 목록을 불러오는 중…" }
    return store.staged ? "커밋에 포함할 파일이 없습니다. ‘스테이징 전’에서 파일을 선택해 스테이징하세요." : "작업 폴더에 변경이 없습니다."
  }
  private func fileRow(_ file: FileChange) -> some View {
    let selected = file.path == store.selectedFile
    let path = file.path as NSString
    let parent = path.deletingLastPathComponent
    let marker =
      file.index == "?" ? "?" : (store.staged && !store.isViewingStash ? file.index : file.worktree)
    let color = marker == "D" ? WorkbenchTheme.danger : (marker == "A" || marker == "?" ? WorkbenchTheme.success : WorkbenchTheme.warning)
    return Button {
      store.chooseFile(file.path)
    } label: {
      HStack(alignment: .top, spacing: 9) {
        Text(marker).font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(color).frame(width: 15)
        VStack(alignment: .leading, spacing: 4) {
          Text(path.lastPathComponent).font(
            .system(size: 13, weight: selected ? .semibold : .regular)
          )
          .lineLimit(1).truncationMode(.middle)
          if !parent.isEmpty && parent != "." {
            Text(parent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.middle)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if !store.isViewingStash {
          let review = store.reviewState(for: file)
          if review != .unread {
            Image(systemName: review == .reviewed ? "checkmark.circle.fill" : review == .checking ? "clock" : "arrow.clockwise.circle")
              .font(.system(size: 11)).foregroundStyle(review == .reviewed ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
              .help(review.label).accessibilityLabel(review.label)
          }
        }
      }.padding(.horizontal, 10).padding(.vertical, reading.listVerticalPadding).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .background(
        selected ? WorkbenchTheme.selection : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(alignment: .leading) {
        if selected {
          RoundedRectangle(cornerRadius: 2).fill(WorkbenchTheme.accent)
            .frame(width: 3).padding(.vertical, 8).allowsHitTesting(false)
        }
      }
      .accessibilityAddTraits(selected ? .isSelected : [])
      .help(file.path).accessibilityLabel(
        "\(file.path), \(store.isViewingStash ? "stash의 변경" : store.staged ? "커밋에 포함" : file.index == "?" ? "아직 Git에 추가하지 않은 새 파일" : "스테이징 전"), \(store.isViewingStash ? "읽기 전용" : store.reviewState(for: file).label)")
  }
}

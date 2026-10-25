import SwiftUI
import WorkbenchProtocol

struct WorkspaceContextHeader: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var showInspector: Bool
  @ObservedObject var layout: LayoutPreferences
  @ObservedObject var reading: ReadingPreferences
  var body: some View {
    HStack(spacing: 10) {
      RiverAppIcon(size: 22)
      Menu {
        Section(store.workspaceTitle) {
          ForEach(store.operations) { op in
            Button("\(store.title(for: op)) · \(StatusText.label(op.status))") {
              store.selectTask(op)
            }
          }
        }
        Section("기존 저장소") {
          ForEach(store.workspace?.repositories ?? []) { repo in
            Button(repo.id) { store.select(.init(repoId: repo.id), leaveTask: true) }
          }
        }
        Divider()
        Button("새 작업…") {
          store.recoveryTaskID = nil
          store.showTaskSheet = true
        }
        Button("원격 저장소 복제…") { store.showCloneSheet = true }.disabled(store.busy)
        Button("저장소 열기…") { store.chooseRepository() }
        Button("시작 화면") { store.showingWelcome = true }
      } label: {
        Text(store.taskTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(
          WorkbenchTheme.primaryText
        )
        .lineLimit(1)
      }.menuStyle(.borderlessButton).frame(maxWidth: 280, alignment: .leading).disabled(store.busy)
        .help("작업 선택")
      Spacer(minLength: 10)
      if store.validatingSelection {
        Text(store.selectionCheckFailed ? "변경 확인 실패" : "변경 확인 중…")
          .foregroundStyle(
            store.selectionCheckFailed ? WorkbenchTheme.warning : WorkbenchTheme.secondaryText
          ).font(.system(size: 12))
          .fixedSize()
          .help(
            store.selectionCheckFailed
              ? "최신 상태를 확인하지 못했습니다. 새로고침이 성공하면 편집할 수 있습니다." : "최근 화면을 표시하면서 파일의 최신 상태를 확인하고 있습니다.")
      }
      HStack(spacing: 2) {
        Button {
          layout.showPane(.details)
        } label: {
          Text("작업·AI 안내")
        }.buttonStyle(ChromeButtonStyle(active: layout.isPanePresented(.details)))
          .help("작업 정보 패널 열기 · 목적 작성 → AI 요청 복사 → 결과 확인 → 스테이징·커밋")
          .accessibilityValue(layout.isPanePresented(.details) ? "표시 중" : "열기")
        Button {
          layout.showPane(.graph)
        } label: {
          Text("기록")
        }.buttonStyle(ChromeButtonStyle(active: layout.isPanePresented(.graph)))
          .help("커밋 기록과 그래프 열기")
          .accessibilityLabel("커밋 기록")
          .accessibilityValue(layout.isPanePresented(.graph) ? "표시 중" : "열기")
        Button {
          layout.showPane(.branches)
        } label: {
          Text("전체 브랜치")
        }.buttonStyle(ChromeButtonStyle(active: layout.isPanePresented(.branches)))
          .help("전체 브랜치 패널 열기 · 선택한 저장소의 로컬·원격 브랜치와 기록 보기")
          .accessibilityValue(layout.isPanePresented(.branches) ? "표시 중" : "열기")
        Button {
          layout.showPane(.stash)
          store.revealStashes()
        } label: {
          Label("Stash \(store.stashes.count)", systemImage: "archivebox")
        }.buttonStyle(ChromeButtonStyle(active: layout.isPanePresented(.stash)))
          .help("Stash 패널 열기 · 선택한 저장소의 워크트리들이 공유합니다")
          .accessibilityValue(layout.isPanePresented(.stash) ? "표시 중" : "열기")
        Button {
          if layout.isPanePresented(.commit) {
            showInspector = false
          } else {
            layout.showPane(.commit)
          }
        } label: {
          Label("커밋 작성", systemImage: "square.and.pencil")
        }
        .buttonStyle(ChromeButtonStyle(active: layout.isPanePresented(.commit)))
        .accessibilityLabel(layout.isPanePresented(.commit) ? "커밋 패널 숨기기" : "커밋 작성 패널 열기")
        .accessibilityValue(layout.isPanePresented(.commit) ? "표시 중" : "열기")
        .help("커밋 작성 패널 표시 · ⌘⌥I")
        Rectangle().fill(WorkbenchTheme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
        Button {
          Task { await store.refresh(forceDiff: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(ChromeButtonStyle())
        .keyboardShortcut("r", modifiers: .command).disabled(store.busy).help("새로고침 · ⌘R")
        .accessibilityLabel("현재 저장소 새로고침")
        Button {
          layout.showsOptions.toggle()
        } label: {
          Label("화면 구성", systemImage: "rectangle.3.group")
        }.buttonStyle(ChromeButtonStyle(active: layout.showsOptions))
          .accessibilityLabel("화면 구성")
          .help("\(layout.currentLayoutTitle) · 저장한 배치 · 패널 · 글자·색상 · ⌘⌥L")
          .popover(isPresented: $layout.showsOptions, arrowEdge: .bottom) {
            LayoutOptions(layout: layout, reading: reading)
          }
      }.fixedSize(horizontal: true, vertical: false)
    }.font(.system(size: 12)).controlSize(.regular)
      .padding(.horizontal, 16).frame(height: 48).background(WorkbenchTheme.chrome)
  }
}

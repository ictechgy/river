import SwiftUI
import Combine

@MainActor
public final class CommitDraft: ObservableObject {
  @Published public var message = "" {
    didSet { if oldValue != message { revision &+= 1 } }
  }
  public private(set) var revision: UInt64 = 0
}

struct CommitComposer: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var draft: CommitDraft
  @FocusState private var messageFocused: Bool
  var body: some View {
    let snapshot = store.repository?.snapshotHash
    let location = store.selection
    return VStack(alignment: .leading, spacing: 12) {
      TextEditor(text: $draft.message).font(.system(size: 13)).scrollContentBackground(
        .hidden
      )
      .focused($messageFocused)
      .padding(7).frame(height: 78)
      .foregroundStyle(WorkbenchTheme.primaryText)
      .background(WorkbenchTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
      .overlay(alignment: .topLeading) {
        if draft.message.isEmpty {
          Text("무엇을 바꾸셨나요?").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .padding(12).allowsHitTesting(false)
        }
      }
      .overlay(RoundedRectangle(cornerRadius: 6)
        .strokeBorder(messageFocused ? WorkbenchTheme.accent : WorkbenchTheme.line,
                      lineWidth: messageFocused ? 2 : 1).allowsHitTesting(false))
      .accessibilityLabel("커밋 메시지")
      Button {
        Task { await store.commit(expectedSnapshot: snapshot, at: location) }
      } label: {
        Text("\(store.selection?.repoId ?? "저장소") · \(store.stagedCount)개 파일 커밋")
          .font(.system(size: 13, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
      }.buttonStyle(PrimaryActionStyle()).controlSize(.large).keyboardShortcut(
        .return, modifiers: .command
      )
      .disabled(
        !store.canEdit || store.stagedCount == 0
          || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      if store.isViewingStash {
        Button("현재 변경으로 돌아가기", systemImage: "arrow.uturn.backward") { store.showWorkingChanges() }
          .font(.system(size: 12)).buttonStyle(.link)
      }
      if let reason = disabledReason {
        Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
      }
      Text("‘커밋에 포함’ 목록의 스테이징된 내용만 커밋합니다. Git hook·커밋 서명 없이 커밋합니다.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !store.isViewingStash {
        if let count = store.repository?.files.filter({ $0.index == "?" }).count, count > 0 {
          Text("아직 Git에 추가하지 않은 새 파일 \(count)개는 이 커밋에 포함되지 않습니다. ‘스테이징 전’에서 파일을 선택해 파일 전체를 스테이징하세요.")
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
  private var disabledReason: String? {
    if store.isViewingStash { return "Stash는 읽기 전용입니다." }
    if store.selectionCheckFailed { return "최신 상태를 확인하지 못했습니다. 새로고침 후 커밋하세요." }
    if store.repository?.conflict == true { return "충돌 또는 진행 중인 Git 작업을 해결하세요." }
    if store.taskPreparationIncomplete { return store.preparationHint }
    if store.hasRunningOperation { return "다른 저장소의 준비 작업이 끝나면 커밋할 수 있습니다." }
    if store.taskContext.working { return "검사나 작업 기록 수집이 끝나면 커밋할 수 있습니다." }
    if store.busy { return "현재 작업이 끝나면 커밋할 수 있습니다." }
    if store.validatingSelection || store.repository == nil { return "현재 폴더의 변경을 확인하고 있습니다." }
    if !store.canEdit { return "작업공간 연결을 확인한 뒤 커밋할 수 있습니다." }
    if store.stagedCount == 0 { return "‘스테이징 전’에서 파일을 선택해 스테이징하면 커밋할 수 있습니다." }
    if draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "커밋 메시지를 입력하세요." }
    return nil
  }
}

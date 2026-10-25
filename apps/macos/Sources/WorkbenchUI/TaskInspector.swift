import SwiftUI
import WorkbenchProtocol

enum InspectorSection { case all, commit, stash, details }

struct TaskInspector: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var historyExpanded: Bool
  var showsHistorySummary = true
  var section: InspectorSection = .all
  var openHistory: (() -> Void)?
  var openFiles: (() -> Void)?
  var openCommit: (() -> Void)?
  @State private var showTechnicalDetails = false
  @State private var showGraph = false
  @State private var showStashInfo = false
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if section == .all || section == .commit {
            commitComposer.padding(14)
            if section == .all { Divider() }
          }
          if section == .all || section == .stash {
            stashList.padding(14).id("stashes")
            if section == .all { Divider() }
          }
          if section == .all && showsHistorySummary {
            DisclosureGroup("커밋 기록", isExpanded: $historyExpanded) {
              let commits = Array((store.repository?.graph ?? []).prefix(4))
              if commits.isEmpty {
                Text("표시할 커밋이 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary).padding(
                  .vertical, 12)
              } else {
                HStack(spacing: 0) {
                  GraphCanvas(commits: commits).frame(
                    width: 50, height: CGFloat(commits.count * 36))
                  VStack(alignment: .leading, spacing: 0) {
                    ForEach(commits) { commit in
                      VStack(alignment: .leading, spacing: 3) {
                        Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                        Text(String(commit.oid.prefix(8))).font(
                          .system(size: 11, design: .monospaced)
                        )
                        .foregroundStyle(.secondary)
                      }.frame(height: 36, alignment: .leading).help(
                        commit.subject + "\n" + commit.oid)
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 10)
              }
              Button("전체 커밋 그래프 보기") {
                store.historyTab = "history"
                if let openHistory { openHistory() } else { showGraph = true }
              }
              .buttonStyle(.link).font(.system(size: 12))
            }.font(.system(size: 13, weight: .semibold)).padding(18)
            Divider()
          }
          if section == .all || section == .details {
            TaskContextView(store: store, model: store.taskContext,
              openFiles: openFiles, openCommit: openCommit).padding(18)
            Divider()
            DisclosureGroup("위치 · 준비 세부정보", isExpanded: $showTechnicalDetails) {
              VStack(alignment: .leading, spacing: 14) {
                if let current = store.repository {
                  detail("현재 폴더", current.path)
                  detail("HEAD", current.snapshot.head.isEmpty ? "첫 커밋 전" : current.snapshot.head)
                }
                if let repo = store.contextOperation?.repos.first(where: {
                  $0.id == store.selection?.repoId
                }) {
                  detail("기준 브랜치", "\(repo.plan.baseRef) @ \(repo.plan.baseOid.prefix(8))")
                  if !repo.hasWorktree { detail("예정 워크트리", repo.plan.worktreePath) }
                  if let recipe = repo.plan.policy.recipe { detail("준비 recipe", recipe) }
                  if let code = repo.errorCode { detail("준비 오류", code) }
                  if let input = repo.postcondition {
                    detail("준비 결과", "버전 \(input.marketingVersion) · 빌드 \(input.localBuild)")
                  }
                }
                HStack {
                  Button("Finder에서 열기") { store.openCurrentWorktree() }
                  Button("경로 복사") { store.copyCurrentPath() }
                }.disabled(store.repository == nil)
                if store.contextOperation != nil {
                  Button("준비 기록 보기") {
                    store.historyTab = "events"
                    if let openHistory { openHistory() } else { showGraph = true }
                  }.buttonStyle(.link)
                }
              }.padding(.top, 12)
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
          }
        }
      }.background(WorkbenchTheme.panel)
        .task(id: store.stashFocusRequest) {
          if store.stashFocusRequest > 0 {
            await Task.yield()
            proxy.scrollTo("stashes", anchor: .top)
          }
        }
        .sheet(isPresented: $showGraph) {
          VStack(spacing: 0) {
            HStack {
              Text("\(store.selection?.repoId ?? "저장소") · 기록").font(.headline)
              Spacer()
              Button("닫기") { showGraph = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            CommitHistory(store: store, expanded: .constant(true), allowsCollapse: false)
          }.frame(minWidth: 800, idealWidth: 1000, minHeight: 480, idealHeight: 600)
        }
    }
  }
  private var stashList: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if section == .all {
          Text("Stash \(store.stashes.count)").font(.system(size: 13, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        }
        if store.isViewingStash {
          Button("현재 변경으로 돌아가기", systemImage: "arrow.uturn.backward") { store.showWorkingChanges() }
            .font(.system(size: 12)).buttonStyle(.link)
        }
        Spacer()
        Button { showStashInfo.toggle() } label: {
          Image(systemName: "info.circle")
        }.buttonStyle(.borderless).help("Stash 안내와 선택한 변경의 정보")
          .accessibilityLabel("Stash 정보")
          .popover(isPresented: $showStashInfo) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Stash는 이 저장소의 워크트리들이 공유합니다. 저장된 변경을 읽기 전용으로 확인할 수 있습니다.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
              if let stash = store.selectedStash {
                Divider()
                detail(stash.selector, stash.subject)
                detail("커밋 ID", stash.oid)
                if let date = stash.date {
                  Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(.system(size: 12)).textSelection(.enabled)
                }
              }
            }.padding(16).frame(width: 300)
          }
      }
      if let error = store.stashError {
        Text(error).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning).fixedSize(
          horizontal: false, vertical: true)
      }
      if store.stashes.isEmpty && store.stashError == nil {
        Text("저장된 stash가 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary).padding(
          .vertical, 8)
      } else if !store.stashes.isEmpty {
        stashRows
      }
    }
  }
  private var stashRows: some View {
    LazyVStack(spacing: 5) {
      ForEach(store.stashes) { stash in
        Button {
          store.chooseStash(stash)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(stash.selector).font(
                .system(size: 12, weight: .medium, design: .monospaced))
              if store.selectedStashOID == stash.oid {
                Image(systemName: "checkmark").foregroundStyle(WorkbenchTheme.accentText)
                  .accessibilityHidden(true)
              }
              Spacer(minLength: 4)
              if let date = stash.date {
                (Text(date, style: .relative) + Text(" 전")).font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
            }
            Text(stash.subject).font(.system(size: 13)).lineLimit(2).frame(
              maxWidth: .infinity, alignment: .leading)
          }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.busy)
          .background(
            store.selectedStashOID == stash.oid
              ? WorkbenchTheme.selection : .clear,
            in: RoundedRectangle(cornerRadius: 7)
          )
          .accessibilityAddTraits(store.selectedStashOID == stash.oid ? .isSelected : [])
          .help("\(stash.subject)\n\(stash.oid)").accessibilityLabel(
            "\(stash.selector), \(stash.subject), 저장된 변경 읽기 전용으로 보기")
      }
    }
  }
  private var commitComposer: some View { CommitComposer(store: store, draft: store.commitDraft) }
  private func detail(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 12, weight: .medium))
      Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

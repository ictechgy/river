import SwiftUI
import WorkbenchProtocol

struct NewTaskSheet: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var group = ""
  @State private var label = ""
  @State private var slug = ""
  @State private var mode = "materialize"
  @State private var plan: WorkspaceTaskPlan?
  @State private var key = UUID().uuidString
  @State private var busy = false
  @State private var error: String?
  @State private var submissionOutcomeUnknown = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(plan == nil ? "새 작업용 브랜치·폴더 준비" : "실행 계획 확인").font(.title2.weight(.semibold))
      Text(
        plan == nil ? "별도 작업 공간이 필요할 때 사용합니다. 기존 폴더에서 바로 작업하려면 이 창을 닫고 ‘작업·AI 안내’에서 목적을 작성하세요." : "기준 커밋, 작업 폴더와 준비 스크립트가 이 작업에 고정됩니다."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary)
      if store.recoveryTaskID != nil {
        Text("이전 작업의 폴더와 브랜치는 유지됩니다. 다른 브랜치 이름으로 현재 상태에서 새 작업을 준비합니다.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if let error { Text(error).font(.caption).foregroundStyle(WorkbenchTheme.danger).textSelection(.enabled) }
      if let workspacePlan = plan {
        let plan = workspacePlan.details
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if !plan.warnings.isEmpty {
              GroupBox("실행 전 확인 · \(plan.warnings.count)개") {
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                  }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
              }
            }
            ForEach(plan.repos) { repo in
              GroupBox(repo.repoId) {
                VStack(alignment: .leading, spacing: 8) {
                  Text("Base  \(repo.baseRef) @ \(repo.baseOid.prefix(8))")
                  Text("Branch  \(repo.branchRef)")
                  Text(
                    mode == "branch_only"
                      ? "위치  워크트리를 준비할 때 생성" : "위치  \(repo.worktreePath)")
                  if let recipe = repo.policy.recipe {
                    Text("준비 스크립트  \(recipe)\(mode == "branch_only" ? " · 대기" : "")")
                  }
                  if let inputs = repo.policy.inputs {
                    Text("고정 입력  \(inputs.marketingVersion) / build \(inputs.localBuild)")
                  }
                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(
                  maxWidth: .infinity, alignment: .leading
                ).padding(10)
              }
            }
          }
        }.frame(maxHeight: 350)
        Text("쓰기 범위는 변경 감지 정책이며 OS sandbox가 아닙니다. 로컬 build 번호의 배포 전역 유일성은 보장하지 않습니다.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Text(
          "계획 기준 \(plan.snapshotHash.prefix(12)) · 만료 \(Date(timeIntervalSince1970: Double(plan.expiresAt)).formatted(date: .omitted, time: .shortened))"
        )
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
      } else {
        Form {
          Picker("브랜치 그룹", selection: $group) {
            ForEach(store.workspace?.groups ?? []) { group in Text(group.id).tag(group.id) }
          }
          TextField("작업 이름", text: $label, prompt: Text("로그인 개선")).focused($nameFocused)
          TextField("브랜치 이름(영문·숫자)", text: $slug, prompt: Text("login-improvements"))
          Picker("준비 방식", selection: $mode) {
            Text("새 워크트리 + 준비 스크립트 실행").tag("materialize")
            Text("브랜치만 생성 · 준비 스크립트 대기").tag("branch_only")
          }
        }.formStyle(.grouped).frame(height: 210)
        Text("버전·빌드 입력은 그룹에 등록한 고정값을 사용합니다. 준비 결과를 검토한 뒤 staging·commit을 별도로 진행합니다.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Button(plan == nil ? "취소" : "수정") {
          if plan == nil { dismiss() } else { plan = nil; error = nil }
        }
          .keyboardShortcut(.cancelAction).disabled(busy)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(plan == nil ? "계획 미리보기" : "이 계획 실행") { Task { await submit() } }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(
            busy || submissionOutcomeUnknown
              || (plan == nil
                && (label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || group.isEmpty))
          )
      }
    }.padding(28).frame(width: 650)
      .onAppear {
        group = store.taskDetail?.request.groupId ?? store.workspace?.groups.last?.id ?? ""
        if let id = store.recoveryTaskID, let request = store.tasks[id]?.request {
          group = request.groupId; label = request.label
          slug = store.nextTaskSlug(request.taskSlug)
        }
        nameFocused = true
      }
      .interactiveDismissDisabled(busy)
      .onChange(of: store.planSession) { _, _ in
        plan = nil
        error = UserFacingFailure.message(UIError.planInvalidated)
      }
      .onDisappear { store.recoveryTaskID = nil }
  }
  private func submit() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      if let plan {
        try await store.executePlan(plan, key: key)
        dismiss()
      } else {
        plan = try await store.planTask(group: group, label: label, slug: slug, mode: mode)
        key = UUID().uuidString
      }
    } catch UIError.workspaceChanged {
      plan = nil
      self.error = UserFacingFailure.message(UIError.workspaceChanged)
    } catch UIError.planInvalidated {
      plan = nil
      self.error = UserFacingFailure.message(UIError.planInvalidated)
    } catch UIError.submissionOutcomeUnknown {
      plan = nil
      submissionOutcomeUnknown = true
      self.error = UserFacingFailure.message(UIError.submissionOutcomeUnknown)
    } catch let failure as ServiceFailure where failure.code == "branch_collision" {
      slug = store.nextTaskSlug(slug)
      self.error = "같은 브랜치가 있어 새 이름을 제안했습니다. 이름을 확인한 뒤 계획을 다시 확인해 주세요."
    } catch let failure as ServiceFailure where failure.code == "repository_busy" {
      self.error = "다른 저장소 작업을 준비 중입니다. 준비가 끝나면 다시 시도해 주세요."
    } catch { self.error = UserFacingFailure.message(error) }
  }
}

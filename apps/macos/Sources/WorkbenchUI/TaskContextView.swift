import AppKit
import SwiftUI
import WorkbenchProtocol

struct TaskContextView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var model: TaskContextStore
  @State private var editing = false
  @State private var reporting = false
  @State private var editorIdentity = ""
  @State private var reportIdentity = ""
  @State private var handoffText: String?
  @State private var handoffIdentity: String?
  @State private var handoffPurpose: TaskRequestPurpose = .handoff
  @State private var confirmingWorkflowReset = false
  private var canRecord: Bool {
    model.loaded && !model.working && !model.isDirty && !store.busy
      && !store.validatingSelection && store.repository != nil && !store.hasRunningOperation
      && (model.bundle?.workflowVersion != 2 || model.workflow?.canWrite == true)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("작업 목적", systemImage: "scope").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkbenchTheme.accentText).accessibilityAddTraits(.isHeader)
        Spacer()
        Button(model.isDirty ? "이어서 작성" : "작성 · 수정") { editorIdentity = model.identity; editing = true }
          .disabled(!model.loaded || model.working)
      }
      Text(store.contextOperation == nil ? "이 저장소에 저장됩니다." : "이 작업의 저장소들이 함께 사용하는 기록입니다.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if let c = model.bundle?.context {
        Text(c.purpose.isEmpty ? "어떤 문제를 해결할 작업인가요?" : c.purpose)
          .font(.system(size: 13)).foregroundStyle(c.purpose.isEmpty ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        if let workflow = model.workflow, workflow.canWrite {
          WorkflowCriteriaView(bundle: workflow, repoID: store.selection?.repoId, opID: store.selection?.opId,
            head: !model.loaded || store.validatingSelection || store.selectionCheckFailed ? nil : store.repository?.snapshot.head,
            snapshot: !model.loaded || store.validatingSelection || store.selectionCheckFailed ? nil : store.repository?.snapshotHash)
        } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("완료 조건").font(.system(size: 12, weight: .semibold))
          if c.criteria.isEmpty {
            Text("완료를 판단할 조건을 적어 두세요.").foregroundStyle(.secondary)
          } else {
            ForEach(Array(c.criteria.enumerated()), id: \.offset) { _, criterion in
              HStack(alignment: .top, spacing: 7) {
                Image(systemName: "circle").font(.system(size: 9)).padding(.top, 3).foregroundStyle(.secondary)
                Text(criterion).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }.font(.system(size: 12))
        if let previous = model.workflow, !previous.canWrite {
          DisclosureGroup("이전 조건 연결 이력 · 현재 조건으로 적용하지 않음") {
            WorkflowCriteriaView(bundle: previous, repoID: nil, opID: nil, head: nil, snapshot: nil)
          }.font(.system(size: 12))
        }
        }
        if !c.notes.isEmpty {
          DisclosureGroup("남은 일 · 주의할 점") {
            Text(c.notes).font(.system(size: 12)).textSelection(.enabled).padding(.top, 6)
          }.font(.system(size: 12))
        }
        if !c.references.isEmpty {
          DisclosureGroup("참고 \(c.references.count)개") {
            ForEach(Array(c.references.enumerated()), id: \.offset) { _, reference in
              Text(reference).font(.system(size: 11)).textSelection(.enabled).padding(.top, 4)
            }
          }.font(.system(size: 12))
        }
      } else if !model.loaded && model.message == nil {
        ProgressView("작업 정보 읽는 중…").controlSize(.small)
      }
      if model.loaded && model.bundle?.workflowVersion == nil {
        Text("현재 엔진에서는 조건별 연결·검토 상태·검증 절차를 기록할 수 없습니다. 기존 작성·기록은 사용할 수 있으며, 엔진을 업데이트하고 다시 연결하면 새 기능을 사용할 수 있습니다.")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let workflow = model.workflow, !workflow.canWrite {
        VStack(alignment: .leading, spacing: 6) {
          Text("이전 엔진에서 작업 정보가 바뀌었습니다. 조건 연결을 추정하지 않으며, 새 기록은 잠시 중지합니다.")
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning)
          Button("현재 작성본으로 조건 ID 새로 만들기…") { confirmingWorkflowReset = true }
            .disabled(model.working || model.isDirty)
          Text(model.isDirty ? "작성 중인 입력은 ‘이어서 작성’에서 복사한 뒤 현재 저장본을 불러오세요." : "기존 검증·연결 이력은 유지되고 현재 조건에는 새 ID를 부여합니다.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      if let workflowMessage = model.workflowMessage {
        Text(workflowMessage).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      WorkflowGuidesView(model: model, selectedRepoID: store.selection?.repoId)
      if model.isDirty {
        Text("저장하지 않은 작성 내용이 있습니다. 검증·인수인계 전에 저장해 주세요.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.warning)
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("검증 기록", systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WorkbenchTheme.accentText).accessibilityAddTraits(.isHeader)
          Spacer()
          if model.working { ProgressView().controlSize(.small) }
        }
        if let bundle = model.bundle {
          let observed = model.loaded && !store.validatingSelection && !store.selectionCheckFailed
            ? store.repository : nil
          let summary = TaskEvidenceSummary(context: bundle.context, receipts: bundle.verifications,
            repoID: store.selection?.repoId ?? "", opID: store.selection?.opId,
            snapshot: observed?.snapshotHash, conflict: observed?.conflict ?? false)
          VStack(alignment: .leading, spacing: 5) {
            Text(summary.headline).font(.system(size: 12, weight: .medium))
            Text(summary.nextAction).font(.system(size: 12)).foregroundStyle(.secondary)
            if let result = summary.latestResultDescription {
              Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("조회한 최근 \(min(bundle.verifications.count, 50))개 중 이 폴더 \(summary.targetReceiptCount)개")
              .font(.system(size: 11)).foregroundStyle(.secondary)
            if summary.reportedCount > 0 {
              Text(summary.reportsDescription).font(.system(size: 11)).foregroundStyle(.secondary)
            }
          }.fixedSize(horizontal: false, vertical: true)
        }
        if let workflow = model.workflow {
          let warnings = WorkflowEvidencePresentation.visibleWarnings(workflow)
          if !warnings.isEmpty {
            Text("최근 50개 안의 기록: " + warnings.joined(separator: " · "))
              .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.warning)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Button("공백 · 충돌 마커 검사", systemImage: "play.circle") {
          guard let snapshot = store.repository?.snapshotHash, let location = store.selection else { return }
          Task { await model.runCheck(snapshot: snapshot, at: location); await store.refresh() }
        }.disabled(!canRecord)
        Button("직접 / AI 결과 기록…") { reportIdentity = model.identity; reporting = true }.disabled(!canRecord)
        if let bundle = model.bundle {
          DisclosureGroup("검사 범위 · 최근 기록 \(bundle.verifications.count)개") {
            Text("최근 50개 중 현재 폴더를 요약합니다. 공백 검사는 추적 파일과 스테이징 대상이며 빌드·테스트·새 파일·서브모듈 내용·완료 조건·병합 가능 여부는 확인하지 않습니다.")
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            ForEach(Array(bundle.verifications.prefix(5))) { receipt in
              receiptRow(receipt, requirements: bundle.context.requirementsHash).padding(.top, 10)
            }
            if bundle.verifications.count > 5 {
              DisclosureGroup("이전 기록 \(bundle.verifications.count - 5)개") {
                ForEach(Array(bundle.verifications.dropFirst(5))) { receipt in
                  receiptRow(receipt, requirements: bundle.context.requirementsHash).padding(.top, 10)
                }
              }
            }
          }.font(.system(size: 12))
        }
      }
      Divider()
      Menu {
        ForEach(TaskRequestPurpose.allCases) { purpose in
          Button(purpose.title) { collectDraft(purpose) }
        }
      } label: {
        Label("검증 요청 · 인수인계 초안", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
      }.disabled(!model.loaded || model.working || model.isDirty || store.busy)
      Text("검증 요청과 인수인계에 쓸 자료를 미리 보고 복사합니다. AI를 실행하거나 자료를 전송하지 않습니다.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let message = model.message {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .sheet(isPresented: $editing) { ContextEditor(model: model, identity: editorIdentity) }
    .sheet(isPresented: $reporting) { VerificationReportEditor(model: model, identity: reportIdentity) }
    .sheet(isPresented: Binding(get: { handoffText != nil }, set: { if !$0 { handoffText = nil } })) {
      HandoffEditor(text: Binding(get: { handoffText ?? "" }, set: { handoffText = $0 }),
        title: handoffPurpose.draftTitle, canCopy: { handoffIdentity == model.identity && model.loaded })
    }
    .confirmationDialog("현재 조건에 새 ID를 부여할까요?", isPresented: $confirmingWorkflowReset) {
      Button("새 ID로 다시 시작") {
        let identity = model.identity
        Task { _ = await model.resetWorkflow(at: identity) }
      }
      Button("취소", role: .cancel) {}
    } message: {
      Text("이전 엔진이 바꾼 작성본을 기준으로 새 조건 ID를 만듭니다. 과거 보고·조건 연결은 보존되며 자동으로 새 조건에 연결하지 않습니다. 저장하지 않은 입력은 먼저 복사해 두세요.")
    }
    .onChange(of: model.identity) { _, _ in
      editing = false; reporting = false; handoffText = nil; handoffIdentity = nil; confirmingWorkflowReset = false
    }
  }
  private func collectDraft(_ purpose: TaskRequestPurpose) {
    let identity = model.identity
    Task {
      guard let text = await model.handoff(purpose: purpose), identity == model.identity else { return }
      handoffPurpose = purpose; handoffIdentity = identity; handoffText = text
    }
  }
  private func receiptRow(_ r: VerificationReceipt, requirements: String) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 6) {
        Text("\(r.repoId) · \(r.path)")
        Text("앱이 기록할 때 관찰한 HEAD \(r.head.prefix(12)) · 변경 상태 \(r.snapshotHash.prefix(12))")
        if let evidence = model.workflow?.evidence.first(where: { $0.receiptId == r.id }) {
          Text("보고자가 검토했다고 적은 HEAD: \(evidence.claimedReviewedState?.head ?? "미기재")")
          Text("보고자가 검토했다고 적은 변경 상태: \(evidence.claimedReviewedState?.snapshotHash ?? "미기재")")
          Text("제공자: \(evidence.provider.isEmpty ? "미기재" : evidence.provider) · 모델: \(evidence.model.isEmpty ? "미기재" : evidence.model)")
          ForEach(evidence.criteria) { criterion in
            Text("연결 조건 \(criterion.id) · 버전 \(criterion.revision): \(criterion.text)")
          }
          ForEach(Array(evidence.artifacts.enumerated()), id: \.offset) { _, artifact in
            Text("근거 위치 (내용 미조회): \(artifact)").textSelection(.enabled)
          }
        }
        Text(r.command).textSelection(.enabled)
        Text(r.note).textSelection(.enabled)
        if !r.output.isEmpty { Text(String(r.output.prefix(8_000))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
        if r.truncated || r.output.count > 8_000 { Text("출력이 길어 일부만 표시합니다.") }
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(r.repoId) · \(r.opId == nil ? "원래 폴더" : "작업용 폴더")")
          .font(.system(size: 12, weight: .semibold)).lineLimit(2)
        HStack {
          Label(r.sourceLabel, systemImage: r.kind == "git_check" ? "terminal" : "quote.bubble")
            .font(.system(size: 12, weight: .medium))
          Spacer(minLength: 0)
          Label(r.verdictLabel, systemImage: r.verdict == "failed" ? "xmark.circle" : r.verdict == "passed" ? "checkmark.circle" : "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(r.verdict == "failed" ? WorkbenchTheme.danger : r.kind == "git_check" && r.verdict == "passed" ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
        }
        Text(r.freshness(repoId: store.selection?.repoId, opId: store.selection?.opId,
          snapshot: store.validatingSelection ? nil : store.repository?.snapshotHash, requirements: requirements))
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let workflow = model.workflow {
          let presentation = WorkflowEvidencePresentation(receipt: r,
            evidence: workflow.evidence.first { $0.receiptId == r.id }, workflow: workflow.workflow,
            repoID: store.selection?.repoId, opID: store.selection?.opId,
            head: store.validatingSelection ? nil : store.repository?.snapshot.head,
            snapshot: store.validatingSelection ? nil : store.repository?.snapshotHash)
          Text(presentation.labels.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
          if !presentation.warnings.isEmpty {
            Text(presentation.warnings.joined(separator: " · ")).font(.system(size: 11))
              .foregroundStyle(WorkbenchTheme.warning).fixedSize(horizontal: false, vertical: true)
          }
        }
        (Text(Date(timeIntervalSince1970: r.finishedAt), style: .relative) + Text(" 전"))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 10)
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkbenchTheme.line).frame(height: 1).allowsHitTesting(false)
      }
  }
}

private struct ContextEditor: View {
  @ObservedObject var model: TaskContextStore
  let identity: String
  @Environment(\.dismiss) private var dismiss
  private func binding(_ key: WritableKeyPath<ContextDraft, String>) -> Binding<String> {
    Binding(get: { model.draft?[keyPath: key] ?? "" }, set: { if identity == model.identity { model.draft?[keyPath: key] = $0 } })
  }
  private var criteriaBinding: Binding<[WorkflowCriterionDraft]> {
    Binding(get: { model.draft?.criteriaEntries ?? [] }, set: { if identity == model.identity { model.draft?.criteriaEntries = $0 } })
  }
  private var guidesBinding: Binding<[WorkflowGuideReference]> {
    Binding(get: { model.draft?.guides ?? [] }, set: { if identity == model.identity { model.draft?.guides = $0 } })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("작업 목적 · 완료 조건").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("목적").font(.subheadline)
          TextField("해결할 문제와 원하는 결과", text: binding(\.purpose), axis: .vertical).lineLimit(2...4)
          if model.supportsWorkflow {
            WorkflowCriterionEditor(entries: criteriaBinding)
          } else { editor("완료 조건 · 한 줄에 하나씩", key: \.criteria, height: 100) }
          editor("남은 일 · 주의할 점", key: \.notes, height: 85)
          editor("참고 경로 / 링크 · 한 줄에 하나씩 (내용은 자동으로 읽지 않습니다)", key: \.references, height: 55)
          if model.supportsWorkflow {
            WorkflowGuideEditor(guides: guidesBinding, repositoryIDs: model.guideRepositoryIDs)
          }
        }.padding(.trailing, 8)
      }
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
      HStack {
        if model.isDirty || model.draft?.revision != model.bundle?.context.revision
          || (model.supportsWorkflow && model.draft?.workflowRevision != model.workflow?.workflow.revision) {
          Button("현재 저장본 불러오기") { if identity == model.identity { model.reloadDraft() } }
          Text("입력을 보관하려면 먼저 복사해 두세요.").font(.caption).foregroundStyle(WorkbenchTheme.warning)
        }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") { Task { guard identity == model.identity else { return }; await model.save(); if !model.isDirty { dismiss() } } }
          .keyboardShortcut(.defaultAction).disabled(!model.isDirty || !model.loaded
            || (model.bundle?.workflowVersion == 2 && model.workflow?.canWrite != true))
      }
    }.padding(24).frame(width: 720, height: 660).disabled(model.working || identity != model.identity)
  }
  private func editor(_ label: String, key: WritableKeyPath<ContextDraft, String>, height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.subheadline)
      TextEditor(text: binding(key)).font(.system(size: 13)).frame(height: height)
        .border(WorkbenchTheme.line).accessibilityLabel(label)
    }
  }
}

private struct VerificationReportEditor: View {
  @ObservedObject var model: TaskContextStore
  let identity: String
  @Environment(\.dismiss) private var dismiss
  @State private var kind = "human_report"
  @State private var verdict = "unknown"
  @State private var command = ""
  @State private var note = ""
  @State private var criterionIDs: Set<String> = []
  @State private var claimedHead = ""
  @State private var claimedSnapshot = ""
  @State private var provider = ""
  @State private var providerModel = ""
  @State private var artifacts = ""
  @State private var reportStatus = "unknown"
  private var claimedState: WorkflowClaimedState? {
    let head = claimedHead.trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = claimedSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
    return head.isEmpty && snapshot.isEmpty ? nil : WorkflowClaimedState(
      head: head.isEmpty ? nil : head, snapshotHash: snapshot.isEmpty ? nil : snapshot)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("검증 결과 기록").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Picker("출처", selection: $kind) {
            Text("직접 적은 결과").tag("human_report")
            Text("AI가 보고한 결과").tag("ai_report")
          }.pickerStyle(.segmented)
          Text("앱이 실행을 관찰한 검증과 구분해 저장합니다. 아래 명령은 실행되지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
          TextField("검증 항목 / 실행했다고 보고한 명령 (선택)", text: $command)
          Picker("보고된 결과", selection: $verdict) {
            Text("확인 필요").tag("unknown"); Text("통과").tag("passed"); Text("실패").tag("failed")
          }
          if let workflow = model.workflow, model.supportsWorkflow {
            VStack(alignment: .leading, spacing: 8) {
              Text("연결할 완료 조건").font(.subheadline)
              ForEach(workflow.workflow.criteria) { criterion in
                Toggle(criterion.text, isOn: Binding(get: { criterionIDs.contains(criterion.id) }, set: { checked in
                  if checked { criterionIDs.insert(criterion.id) } else { criterionIDs.remove(criterion.id) }
                }))
              }
              Text(criterionIDs.isEmpty ? "조건을 선택하지 않으면 연결하지 않은 보고로 남습니다." : "선택한 조건의 현재 버전과 연결합니다. 조건 충족이나 승인을 뜻하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              Text("보고자가 실제 검토했다고 명시한 코드 상태").font(.subheadline)
              Text("앱의 기록 시점 상태와 별도로 보관합니다. 알 수 없는 값은 비워 두세요. 현재 상태를 대신 채우지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
              TextField("검토했다고 보고한 전체 HEAD (선택)", text: $claimedHead)
                .font(.system(size: 12, design: .monospaced))
              TextField("검토했다고 보고한 변경 상태 해시 (선택)", text: $claimedSnapshot)
                .font(.system(size: 12, design: .monospaced))
              HStack {
                TextField("제공자 (예: Claude, 직접 검토)", text: $provider)
                TextField("정확한 모델 / 버전 (선택)", text: $providerModel)
              }
              Picker("보고 완료 상태", selection: $reportStatus) {
                Text("확인하지 못함").tag("unknown")
                Text("완료했다고 보고").tag("completed")
                Text("미완료").tag("incomplete")
                Text("도구 오류").tag("tool_error")
              }
              Text("미완료·도구 오류·미확인은 통과 결과가 적혀 있어도 검토 완료 근거로 취급하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Text("결과와 근거").font(.subheadline)
          TextEditor(text: $note).font(.system(size: 13)).frame(height: 130).border(WorkbenchTheme.line)
            .accessibilityLabel("결과와 근거")
          if model.supportsWorkflow {
            Text("근거 파일 / 링크 · 한 줄에 하나씩 (내용은 읽거나 전송하지 않습니다)").font(.subheadline)
            TextEditor(text: $artifacts).font(.system(size: 12)).frame(height: 65).border(WorkbenchTheme.line)
              .accessibilityLabel("근거 파일 / 링크")
          }
        }.padding(.trailing, 8)
      }
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("보고로 저장") {
          Task {
            let refs = artifacts.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if await model.record(kind: kind, verdict: verdict, command: command, note: note,
              criterionIDs: criterionIDs.sorted(), claimedReviewedState: claimedState,
              provider: provider, model: providerModel, artifacts: refs, reportStatus: reportStatus, at: identity) { dismiss() }
          }
        }.keyboardShortcut(.defaultAction).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 720, height: model.supportsWorkflow ? 660 : 490)
      .disabled(model.working || identity != model.identity)
  }
}

private struct HandoffEditor: View {
  @Binding var text: String
  let title: String
  let canCopy: () -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.headline)
      Text("생성 시점의 경로·변경 파일명·기록이 포함됩니다. 현재 상태와 다를 수 있으므로 전달할 내용을 확인하고 수정하세요.")
        .font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 440)
        .border(WorkbenchTheme.line).accessibilityLabel(title)
      HStack {
        if copied { Text("복사했습니다.").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("초안 복사") {
          guard canCopy() else { return }
          NSPasteboard.general.clearContents(); copied = NSPasteboard.general.setString(text, forType: .string)
        }.keyboardShortcut(.defaultAction).disabled(!canCopy())
      }
    }.padding(24).frame(width: 760, height: 650)
  }
}

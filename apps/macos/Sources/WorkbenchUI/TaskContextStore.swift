import Combine
import Foundation
import WorkbenchProtocol

struct ContextDraft: Equatable {
  var revision: Int
  var purpose: String
  var criteria: String
  var references: String
  var notes: String
  var workflowRevision: Int?
  var criteriaEntries: [WorkflowCriterionDraft]
  var guides: [WorkflowGuideReference]
  init(_ context: TaskContext, workflow: TaskWorkflowDefinition? = nil) {
    revision = context.revision; purpose = context.purpose
    criteria = context.criteria.joined(separator: "\n")
    references = context.references.joined(separator: "\n"); notes = context.notes
    workflowRevision = workflow?.revision
    criteriaEntries = workflow?.criteria.map(WorkflowCriterionDraft.init) ?? []
    guides = workflow?.guides ?? []
  }
}

@MainActor
public final class TaskContextStore: ObservableObject {
  @Published public private(set) var bundle: TaskContextBundle?
  @Published public private(set) var workflow: TaskWorkflowBundle?
  @Published public private(set) var workflowMessage: String?
  @Published var draft: ContextDraft?
  @Published public private(set) var working = false
  // Unlike visible-scope `working`, this count survives navigation/reset until each RPC returns.
  @Published private(set) var inFlightWorkCount = 0
  // Session-only uncertainty survives navigation; an update asks the user to inspect it.
  private(set) var updateUncertainWriteOrigins: Set<String> = []
  private(set) var updateUncertainWriteRevision: UInt64 = 0
  @Published public private(set) var loaded = false
  @Published public private(set) var message: String?
  private var client: ServiceClient?
  private var location: WorktreeSelection?
  private var contextOperationID: String?
  private var operation: WorkbenchOperation?
  private var scopeResolved = false
  private var title = ""
  private var updateOriginDescription = ""
  private var scope = ""
  private var token = UUID()
  private var scopeToken = UUID()
  private var activeWork: UUID?
  private var writeEpoch = UUID()
  private var drafts: [String: ContextDraft] = [:]
  private var loading = false
  private var lastReadFailure: String?
  public var identity: String { token.uuidString }
  public var supportsWorkflow: Bool { bundle?.workflowVersion == 2 && workflow != nil }
  public var guideRepositoryIDs: [String] {
    operation?.repos.map(\.id) ?? location.map { [$0.repoId] } ?? []
  }
  public var isDirty: Bool {
    guard let draft, let context = bundle?.context else { return false }
    let saved = ContextDraft(context, workflow: workflow?.workflow)
    let criteriaChanged = draft.workflowRevision == nil ? draft.criteria != saved.criteria
      : draft.criteriaEntries != saved.criteriaEntries || draft.guides != saved.guides
    return draft.purpose != saved.purpose || criteriaChanged
      || draft.references != saved.references || draft.notes != saved.notes
  }
  func reset() {
    rememberDraft()
    token = UUID(); scopeToken = UUID(); activeWork = nil
    client = nil; location = nil; contextOperationID = nil; operation = nil; scopeResolved = false; scope = ""; bundle = nil
    workflow = nil; workflowMessage = nil
    draft = nil; loaded = false; message = nil; working = false; loading = false
  }
  private func rememberDraft() {
    if let draft, isDirty || bundle == nil { drafts[scope] = draft }
    else { drafts.removeValue(forKey: scope) }
  }
  private func beginWork() -> UUID {
    inFlightWorkCount += 1
    let id = UUID(); activeWork = id; writeEpoch = UUID(); working = true; message = nil; return id
  }
  private func finishWork(_ id: UUID) {
    inFlightWorkCount -= 1
    if activeWork == id { activeWork = nil; working = false }
  }
  func configure(client: ServiceClient, workspace: String, location: WorktreeSelection,
                 contextOperationID: String?, operation: WorkbenchOperation?,
                 operationResolved: Bool = true, title: String, updateOrigin: String? = nil) {
    // Folder identity and context identity are independent: an original folder
    // can still show Task context, and missing Task metadata must never select repo scope.
    let contextID = contextOperationID ?? location.opId
    let matchingOperation = operation.flatMap { $0.id == contextID ? $0 : nil }
    let resolved = contextID == nil || (operationResolved && matchingOperation?.repos.contains {
      $0.id == location.repoId
    } == true && (location.opId == nil || location.opId == contextID))
    let scopeKey = contextID.map { id in
      matchingOperation.map { "task:\($0.taskId)" } ?? "unresolved-operation:\(id)"
    } ?? "repo:\(location.repoId)"
    let key = workspace + ":" + scopeKey
    if key != scope || location != self.location || resolved != scopeResolved {
      rememberDraft()
      token = UUID(); loaded = false; loading = false; message = nil
      if key != scope {
        scopeToken = UUID(); activeWork = nil; working = false
        bundle = nil; workflow = nil; workflowMessage = nil; draft = drafts[key]
      }
    }
    scope = key; self.client = client; self.location = location
    self.contextOperationID = contextID; self.operation = matchingOperation
    self.scopeResolved = resolved; self.title = title
    updateOriginDescription = updateOrigin ?? title
    if !resolved {
      loaded = false
      message = "선택한 작업 정보를 확인하지 못했습니다. 작성 내용은 유지됩니다. 새로고침으로 작업을 다시 확인한 뒤 저장해 주세요."
    }
  }
  private func params(target: Bool = true) -> [String: JSONValue] {
    guard let location else { return [:] }
    var values: [String: JSONValue] = ["repo_id": .string(location.repoId)]
    if target, let id = location.opId { values["op_id"] = .string(id) }
    if let contextOperationID { values["context_op_id"] = .string(contextOperationID) }
    return values
  }
  private func accept(_ result: TaskContextBundle) {
    guard result.context.revision >= (bundle?.context.revision ?? 0) else { return }
    let dirty = isDirty || (bundle == nil && draft != nil)
    if bundle != result { bundle = result }
    if !dirty { let saved = ContextDraft(result.context, workflow: workflow?.workflow); if draft != saved { draft = saved } }
    if !loaded { loaded = true }
  }
  private func acceptWorkflow(_ result: TaskWorkflowBundle, replaceDraft: Bool = false) {
    guard result.context.revision >= (bundle?.context.revision ?? 0) else { return }
    let dirty = isDirty || (bundle == nil && draft != nil)
    workflow = result
    bundle = TaskContextBundle(context: result.context, verifications: result.verifications, workflowVersion: 2)
    if !dirty || replaceDraft { draft = ContextDraft(result.context, workflow: result.workflow) }
    workflowMessage = result.canWrite ? nil
      : "이전 버전에서 작업 기록이 바뀌었습니다. 조건 연결 이력을 보존한 채 현재 기록으로 다시 시작할 수 있습니다."
    loaded = scopeResolved
  }
  public func refresh() async {
    guard let client, scopeResolved, !loading, !working else { return }
    loading = true
    let version = token
    let epoch = writeEpoch
    defer { if version == token { loading = false } }
    do {
      let result: TaskContextBundle = try await client.call("get_task_context", params: params())
      guard version == token && epoch == writeEpoch else { return }
      if result.workflowVersion == 2 {
        let rich: TaskWorkflowBundle = try await client.call("get_task_workflow", params: params())
        guard version == token && epoch == writeEpoch else { return }
        acceptWorkflow(rich)
      } else {
        workflow = nil
        workflowMessage = "연결된 엔진은 조건별 근거 연결을 지원하지 않습니다. 기존 작업 정보와 기록은 사용할 수 있습니다."
        accept(result)
      }
      if message == lastReadFailure && lastReadFailure != nil { message = nil }
      lastReadFailure = nil
    } catch {
      guard version == token && epoch == writeEpoch else { return }
      loaded = false
      message = (error as? ServiceFailure)?.code == "unknown_method"
        ? "현재 엔진은 작업 정보를 지원하지 않습니다. 앱과 엔진을 업데이트한 뒤 다시 연결해 주세요."
        : "작업 정보를 읽지 못했습니다. 새로고침해 주세요."
      lastReadFailure = message
    }
  }
  func reloadDraft() {
    guard let context = bundle?.context else { return }
    draft = ContextDraft(context, workflow: workflow?.workflow); message = nil
  }
  private func rememberUncertainWrite(_ error: any Error, origin: String) {
    if let failure = error as? ServiceFailure {
      guard failure.code.hasSuffix("outcome_unknown") else { return }
    } else if (error as? TransportFailure)?.requestMayHaveBeenSent == false { return }
    // A second unknown request at the same origin still invalidates prior consent.
    updateUncertainWriteRevision += 1
    updateUncertainWriteOrigins.insert(HandoffText.field(origin))
  }
  public func save() async {
    guard let client, let draft, scopeResolved, loaded, !working else { return }
    if bundle?.workflowVersion == 2 {
      guard workflow?.canWrite == true, let revision = draft.workflowRevision else {
        message = "현재 저장본을 확인한 뒤 다시 불러오세요. 작성 내용은 유지했습니다."; return
      }
      var values = params(target: false)
      values["expected_context_revision"] = .number(Double(draft.revision))
      values["expected_workflow_revision"] = .number(Double(revision))
      values["purpose"] = .string(draft.purpose); values["notes"] = .string(draft.notes)
      values["references"] = .array(draft.references.components(separatedBy: .newlines).map(JSONValue.string))
      values["criteria"] = .array(draft.criteriaEntries.map { .object(["id": .string($0.id), "text": .string($0.text)]) })
      values["guides"] = .array(draft.guides.map(Self.guideJSON))
      _ = await writeWorkflow("save_task_workflow", values: values, replaceDraft: true)
      return
    }
    guard draft.workflowRevision == nil else {
      message = "새 형식으로 작성한 내용이 있습니다. 새 엔진에 연결하거나 현재 저장본을 명시적으로 불러온 뒤 저장하세요."; return
    }
    var values = params(target: false)
    values["expected_revision"] = .number(Double(draft.revision))
    values["purpose"] = .string(draft.purpose)
    for (key, text) in [("criteria", draft.criteria), ("references", draft.references)] {
      values[key] = .array(text.components(separatedBy: .newlines).map { .string($0) })
    }
    values["notes"] = .string(draft.notes)
    let work = beginWork()
    defer { finishWork(work) }
    let version = scopeToken
    let updateOrigin = updateOriginDescription
    do {
      let result: TaskContextBundle = try await client.call("save_task_context", params: values)
      // A metadata lookup can become unavailable while this confirmed save is
      // in flight. The scope token still proves which draft owns the reply;
      // retain its new revision without authorizing another unresolved write.
      guard version == scopeToken else { return }
      bundle = result; self.draft = ContextDraft(result.context); loaded = scopeResolved
      drafts.removeValue(forKey: scope)
      if scopeResolved { message = "이 기기의 작업 이력에 저장했습니다." }
    } catch {
      rememberUncertainWrite(error, origin: updateOrigin)
      guard version == scopeToken else { return }
      message = UserFacingFailure.message(error)
    }
  }
  public func runCheck(snapshot: String, at location: WorktreeSelection) async {
    guard location == self.location else { return }
    var values = params(); values["snapshot_hash"] = .string(snapshot)
    _ = await write("run_git_check", values: values)
  }
  public func record(kind: String, verdict: String, command: String, note: String,
                     criterionIDs: [String] = [], claimedReviewedState: WorkflowClaimedState? = nil,
                     provider: String = "", model: String = "", artifacts: [String] = [],
                     reportStatus: String = "unknown", at identity: String) async -> Bool {
    guard identity == self.identity else { return false }
    var values = params()
    values["kind"] = .string(kind); values["verdict"] = .string(verdict)
    values["command"] = .string(command); values["note"] = .string(note)
    if bundle?.workflowVersion == 2 {
      guard let revisions = workflowRevisions(), !isDirty else {
        message = "작업 정보를 저장하거나 현재 저장본을 불러온 뒤 기록하세요."; return false
      }
      values.merge(revisions) { _, new in new }
      values["criterion_ids"] = .array(criterionIDs.map(JSONValue.string))
      values["claimed_reviewed_state"] = claimedReviewedState.map {
        .object(["head": $0.head.map(JSONValue.string) ?? .null,
                 "snapshot_hash": $0.snapshotHash.map(JSONValue.string) ?? .null])
      } ?? .null
      values["provider"] = .string(provider); values["model"] = .string(model)
      values["artifacts"] = .array(artifacts.map(JSONValue.string)); values["report_status"] = .string(reportStatus)
      return await writeWorkflow("record_workflow_report", values: values, needsSnapshot: true)
    }
    guard criterionIDs.isEmpty, claimedReviewedState == nil, provider.isEmpty, model.isEmpty,
      artifacts.isEmpty, reportStatus == "unknown" else {
      message = "현재 엔진은 조건 연결과 검토 메타데이터를 지원하지 않습니다. 입력은 유지했습니다."; return false
    }
    return await write("record_verification_report", values: values)
  }
  private static func guideJSON(_ guide: WorkflowGuideReference) -> JSONValue {
    .object(["id": .string(guide.id), "repo_id": .string(guide.repoId), "kind": .string(guide.kind),
      "path": .string(guide.path), "expected_sha256": guide.expectedSha256.map(JSONValue.string) ?? .null])
  }
  private func workflowRevisions() -> [String: JSONValue]? {
    guard let workflow, workflow.canWrite, let context = bundle?.context else { return nil }
    return ["expected_context_revision": .number(Double(context.revision)),
      "expected_workflow_revision": .number(Double(workflow.workflow.revision))]
  }
  private func writeWorkflow(_ method: String, values: [String: JSONValue],
                             replaceDraft: Bool = false, needsSnapshot: Bool = false) async -> Bool {
    guard let client, scopeResolved, loaded, !working,
      replaceDraft || !isDirty else { message = "작성 내용을 저장하거나 현재 저장본을 확인한 뒤 진행하세요."; return false }
    let work = beginWork(); defer { finishWork(work) }
    let version = scopeToken, locationVersion = token
    let updateOrigin = updateOriginDescription
    var submitted = false
    do {
      var values = values
      if needsSnapshot {
        let status: RepositoryStatus = try await client.call("get_repo_status", params: params())
        guard locationVersion == token, scopeResolved else { return false }
        values["snapshot_hash"] = .string(status.snapshotHash)
      }
      submitted = true
      let result: TaskWorkflowBundle = try await client.call(method, params: values)
      guard version == scopeToken else { return false }
      acceptWorkflow(result, replaceDraft: replaceDraft)
      if replaceDraft { drafts.removeValue(forKey: scope) }
      if scopeResolved { message = "이 기기의 작업 이력에 저장했습니다." }
      return true
    } catch {
      if submitted { rememberUncertainWrite(error, origin: updateOrigin) }
      guard version == scopeToken else { return false }
      message = UserFacingFailure.message(error)
      return false
    }
  }
  public func resetWorkflow(at identity: String) async -> Bool {
    guard identity == self.identity, let workflow, workflow.compatibility == "legacy_changed", !isDirty else { return false }
    var values = params()
    values["expected_context_revision"] = .number(Double(workflow.context.revision))
    values["expected_workflow_revision"] = .number(Double(workflow.workflow.revision))
    return await writeWorkflow("reset_task_workflow", values: values, replaceDraft: true)
  }
  public func readGuide(id: String, at identity: String) async -> VerificationGuideRead? {
    guard identity == self.identity, let client, let revisions = workflowRevisions(), loaded,
      scopeResolved, !working, !isDirty,
      workflow?.workflow.guides.contains(where: { $0.id == id && $0.repoId == location?.repoId }) == true else { return nil }
    var values = params(); values.merge(revisions) { _, new in new }; values["guide_id"] = .string(id)
    let work = beginWork(); defer { finishWork(work) }
    let version = token
    do {
      let result: VerificationGuideRead = try await client.call("read_verification_guide", params: values)
      guard version == token, scopeResolved else { return nil }
      return result
    } catch {
      if version == token { message = UserFacingFailure.message(error) }
      return nil
    }
  }
  public func pinGuide(_ read: VerificationGuideRead, guideID: String, at identity: String) async -> Bool {
    guard identity == self.identity, let location, read.repoId == location.repoId, read.opId == location.opId,
      let workflow, workflow.canWrite, !working, !isDirty, loaded,
      let index = draft?.guides.firstIndex(where: { $0.id == guideID && $0.repoId == read.repoId && $0.path == read.path }) else { return false }
    draft?.guides[index].expectedSha256 = read.sha256
    await save()
    return self.workflow?.workflow.guides.first(where: { $0.id == guideID })?.expectedSha256 == read.sha256 && !isDirty
  }
  private func write(_ method: String, values: [String: JSONValue]) async -> Bool {
    guard let client, scopeResolved, loaded, !working, !isDirty else {
      message = isDirty ? "작성 중인 작업 정보를 먼저 저장하거나 저장본을 다시 불러온 뒤 진행해 주세요." : "작업 정보를 불러오는 중이거나 다른 검사를 진행 중입니다. 잠시 후 다시 시도해 주세요."
      return false
    }
    let work = beginWork()
    defer { finishWork(work) }
    let version = scopeToken
    let updateOrigin = updateOriginDescription
    do {
      let result: TaskContextBundle = try await client.call(method, params: values)
      guard version == scopeToken, scopeResolved else { return false }
      accept(result)
      if result.workflowVersion == 2 {
        do {
          let rich: TaskWorkflowBundle = try await client.call("get_task_workflow", params: params())
          guard version == scopeToken, scopeResolved else { return false }
          acceptWorkflow(rich)
        } catch {
          guard version == scopeToken else { return false }
          loaded = false
          workflowMessage = "검사 기록은 저장했지만 조건 연결 정보를 읽지 못했습니다. 새로고침해 주세요."
        }
      }
      return true
    } catch {
      rememberUncertainWrite(error, origin: updateOrigin)
      guard version == scopeToken else { return false }
      message = (error as? ServiceFailure)?.code == "stale_snapshot"
        ? "검사 전에 변경이 생겼습니다. 새로고침한 뒤 다시 검사하세요."
        : "기록을 완료하지 못했습니다. 새로고침한 뒤 다시 시도하세요."
    }
    return false
  }
  /// Collect individual observations; partial worktrees never imply an integration pass.
  public func handoff(purpose: TaskRequestPurpose = .handoff) async -> String? {
    guard let client, let location, scopeResolved, loaded, !working, !isDirty else {
      message = isDirty ? "작성 중인 작업 정보를 먼저 저장하거나 저장본을 다시 불러온 뒤 인수인계를 만들어 주세요." : "작업 정보를 불러온 뒤 인수인계를 다시 만들어 주세요."
      return nil
    }
    let work = beginWork()
    let version = token
    let contextParams = params()
    let capturedOperation = operation
    let capturedTitle = title
    defer { finishWork(work) }
    do {
      var start: TaskContextBundle = try await client.call("get_task_context", params: contextParams)
      guard version == token else { message = "수집 중 위치가 바뀌었습니다. 현재 위치에서 인수인계를 다시 만들어 주세요."; return nil }
      var collectedWorkflow: TaskWorkflowBundle?
      if start.workflowVersion == 2 {
        let rich: TaskWorkflowBundle = try await client.call("get_task_workflow", params: contextParams)
        guard version == token else { return nil }
        guard rich.canWrite else {
          message = "이전 버전에서 바뀐 조건 기록을 확인한 뒤 다시 인수인계를 만들어 주세요."; return nil
        }
        acceptWorkflow(rich); collectedWorkflow = rich
        start = TaskContextBundle(context: rich.context, verifications: rich.verifications, workflowVersion: 2)
      } else { accept(start) }
      let c = start.context
      var text = "# \(HandoffText.field(capturedTitle)) · 인수인계\n\n생성: \(Date().ISO8601Format())\n작업: \(capturedOperation?.taskId ?? "저장소 단위 기록")\n작업 정보 revision: \(c.revision)\n완료 조건 식별자: \(c.requirementsHash)\n\n## 목적 (작성자 기록)\n\(HandoffText.block(c.purpose.isEmpty ? "미작성" : c.purpose))\n## 완료 조건 (작성자 기록)\n"
      text += c.criteria.isEmpty ? "미작성\n" : c.criteria.map { "- \(HandoffText.field($0))" }.joined(separator: "\n") + "\n"
      if let rich = collectedWorkflow {
        text += "\n## 조건 식별자 · 연결은 작성자의 보고이며 충족 인증이 아님\n"
        text += rich.workflow.criteria.map {
          "- \(HandoffText.field($0.id)) · 조건 버전 \($0.revision): \(HandoffText.field($0.text))"
        }.joined(separator: "\n") + "\n"
      }
      text += "\n## 저장소별 앱 관찰\n각 저장소는 개별 시점의 관찰입니다. 통합 검증/승인을 뜻하지 않습니다.\n검증 이력은 최근 50개 중 대상별 최근 5개를 포함합니다. 원본 출력은 로컬 작업 이력에서 확인하세요.\n"
      var targets: [(String, String?, String, Bool)] = []
      if let op = capturedOperation {
        targets = op.repos.map { ($0.id, op.id, "작업용 폴더 · \(StatusText.label($0.state))", $0.hasWorktree) }
      }
      if capturedOperation == nil || location.opId == nil {
        targets.append((location.repoId, nil, "원래 프로젝트 폴더", true))
      }
      for (repo, op, label, exists) in targets {
        text += "\n### \(HandoffText.field(repo)) · \(label)\n"
        guard exists else {
          text += "현재 상태 미조회: 워크트리 준비 전. 성공으로 판단하지 마세요.\n다음 확인: 작업용 폴더를 준비한 뒤 실제 코드와 검증 상태를 확인하세요.\n"
          continue
        }
        var observedSnapshot: String?
        var observedHead: String?
        var observedConflict = false
        var values: [String: JSONValue] = ["repo_id": .string(repo)]
        if let op { values["op_id"] = .string(op) }
        do {
          let status: RepositoryStatus = try await client.call("get_repo_status", params: values)
          observedSnapshot = status.snapshotHash
          observedHead = status.snapshot.head
          observedConflict = status.conflict
          text += "관찰: \(Date().ISO8601Format())\n경로: \(HandoffText.field(status.path))\n브랜치: \(HandoffText.field(status.snapshot.branch))\nHEAD: \(status.snapshot.head)\n변경 상태: \(status.snapshotHash)\n충돌/진행 중 Git 작업: \(status.conflict)\n변경 파일: \(status.files.count)개\n"
          text += status.files.prefix(100).map { "- \(HandoffText.field($0.path)) [스테이징: \($0.isStaged), 작업 변경: \($0.isWorking)]" }.joined(separator: "\n") + "\n"
          if status.files.count > 100 { text += "(앞의 100개만 표시)\n" }
        } catch { text += "현재 상태 미조회: \(HandoffText.field(String(String(describing: error).prefix(300)))). 부분 수집이며 검증 통과가 아닙니다.\n" }
        let summary = TaskEvidenceSummary(context: c, receipts: start.verifications,
          repoID: repo, opID: op, snapshot: observedSnapshot, conflict: observedConflict)
        text += "\n검증 요약: \(summary.headline)\n다음 확인: \(summary.nextAction)\n\(summary.reportsDescription)\n\(summary.scopeDescription)\n"
        if let result = summary.latestResultDescription { text += result + "\n" }
        for receipt in start.verifications.filter({ $0.repoId == repo && $0.opId == op }).prefix(5) {
          text += Self.receiptText(receipt, context: c, snapshot: observedSnapshot)
          if let details = collectedWorkflow?.evidence.first(where: { $0.receiptId == receipt.id }) {
            text += Self.workflowEvidenceText(details)
            if let rich = collectedWorkflow {
              let applicability = WorkflowEvidencePresentation(receipt: receipt, evidence: details,
                workflow: rich.workflow, repoID: repo, opID: op, head: observedHead, snapshot: observedSnapshot)
              text += "연결·검토 대상의 현재 적용성 (승인 아님):\n"
                + HandoffText.block((applicability.labels + applicability.warnings).joined(separator: "\n"))
            }
          } else if receipt.kind != "git_check" {
            text += "\n조건 연결·보고자가 검토한 코드 상태: 미기재. 기록 당시 상태를 검토 대상이라고 추정하지 마세요.\n"
          }
        }
        guard version == token else { message = "수집 중 위치가 바뀌었습니다. 현재 위치에서 인수인계를 다시 만들어 주세요."; return nil }
      }
      text += "\n## 남은 일 · 주의할 점 (작성자 기록)\n\(HandoffText.block(c.notes.isEmpty ? "미작성" : c.notes))\n## 참고 (내용 미조회)\n\(c.references.map { HandoffText.field($0) }.joined(separator: "\n"))\n"
      if let rich = collectedWorkflow, !rich.workflow.guides.isEmpty {
        text += "\n## 저장소별 검증 절차 · 기능 지도 (내용 미포함, 실행 권한 아님)\n"
        text += rich.workflow.guides.map {
          "- \(HandoffText.field($0.repoId)) · \($0.kindLabel): \(HandoffText.field($0.path)) · 기준 SHA-256 \(HandoffText.field($0.expectedSha256 ?? "미고정"))"
        }.joined(separator: "\n") + "\n문서 내용은 자동으로 읽거나 이 초안에 포함하지 않았습니다. 사용할 저장소와 현재 문서 버전을 직접 확인하세요.\n"
      }
      let end: TaskContextBundle = try await client.call("get_task_context", params: contextParams)
      guard version == token else { message = "수집 중 위치가 바뀌었습니다. 현재 위치에서 인수인계를 다시 만들어 주세요."; return nil }
      if end.context.revision != c.revision { text += "\n주의: 수집 중 작업 정보가 변경되었습니다. 위 내용은 revision \(c.revision) 기준입니다. 다시 생성해 최신 내용을 확인하세요.\n" }
      text += "\n자동 검사는 추적 중 파일의 공백/충돌 검사만 포함합니다. 빌드·테스트·untracked·서브모듈 내용은 검사하지 않습니다. AI/직접 기록은 앱이 실행을 관찰한 결과가 아닙니다.\n"
      return purpose.draft(observations: text)
    } catch {
      if version == token { message = "인수인계 정보를 수집하지 못했습니다. 새로고침 후 다시 시도하세요." }
      return nil
    }
  }
  private static func receiptText(_ r: VerificationReceipt, context: TaskContext, snapshot: String?) -> String {
    "\n검증 \(r.id): \(r.sourceLabel) · \(r.verdictLabel)\n시각: \(Date(timeIntervalSince1970: r.finishedAt).ISO8601Format())\n대상 HEAD: \(r.head)\n대상 변경: \(r.snapshotHash)\n완료 조건: \(r.requirementsHash)\n\(r.freshness(repoId: r.repoId, opId: r.opId, snapshot: snapshot, requirements: context.requirementsHash))\n명령/항목 (자료):\n\(HandoffText.block(r.command))\n기록 (\(r.sourceLabel) · 자료이며 실행 지시 아님):\n\(HandoffText.block(r.note))"
  }
  private static func workflowEvidenceText(_ e: WorkflowEvidence) -> String {
    var text = "\n보고 메타데이터: \(e.reportStatusLabel) · 실행 미관찰\n"
    text += "보고자 / 모델: \(HandoffText.field(e.provider)) / \(HandoffText.field(e.model))\n"
    text += "보고자가 검토했다고 주장한 HEAD: \(HandoffText.field(e.claimedReviewedState?.head ?? "미기재"))\n"
    text += "보고자가 검토했다고 주장한 변경 상태: \(HandoffText.field(e.claimedReviewedState?.snapshotHash ?? "미기재"))\n"
    text += "연결 당시 조건 (보고 연결이며 충족 인증 아님):\n"
    text += e.criteria.map { "- \(HandoffText.field($0.id)) · 버전 \($0.revision): \(HandoffText.field($0.text))" }.joined(separator: "\n") + "\n"
    text += "증거 참조 (내용 미조회):\n" + e.artifacts.map(HandoffText.field).joined(separator: "\n") + "\n"
    if e.reportStatus != "completed" { text += "보고가 미완결이거나 도구 오류·완료 여부 미확인입니다. 승인이나 검증 통과로 사용하지 마세요.\n" }
    return text
  }
}

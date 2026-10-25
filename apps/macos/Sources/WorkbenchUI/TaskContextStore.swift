import Combine
import Foundation
import WorkbenchProtocol

struct ContextDraft: Equatable {
  var revision: Int
  var purpose: String
  var criteria: String
  var references: String
  var notes: String
  init(_ context: TaskContext) {
    revision = context.revision; purpose = context.purpose
    criteria = context.criteria.joined(separator: "\n")
    references = context.references.joined(separator: "\n"); notes = context.notes
  }
}

@MainActor
public final class TaskContextStore: ObservableObject {
  @Published public private(set) var bundle: TaskContextBundle?
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
  public var isDirty: Bool {
    guard let draft, let context = bundle?.context else { return false }
    let saved = ContextDraft(context)
    return draft.purpose != saved.purpose || draft.criteria != saved.criteria
      || draft.references != saved.references || draft.notes != saved.notes
  }
  func reset() {
    rememberDraft()
    token = UUID(); scopeToken = UUID(); activeWork = nil
    client = nil; location = nil; contextOperationID = nil; operation = nil; scopeResolved = false; scope = ""; bundle = nil
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
        bundle = nil; draft = drafts[key]
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
    if !dirty { let saved = ContextDraft(result.context); if draft != saved { draft = saved } }
    if !loaded { loaded = true }
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
      accept(result)
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
    draft = ContextDraft(context); message = nil
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
  public func record(kind: String, verdict: String, command: String, note: String, at identity: String) async -> Bool {
    guard identity == self.identity else { return false }
    var values = params()
    values["kind"] = .string(kind); values["verdict"] = .string(verdict)
    values["command"] = .string(command); values["note"] = .string(note)
    return await write("record_verification_report", values: values)
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
      let start: TaskContextBundle = try await client.call("get_task_context", params: contextParams)
      guard version == token else { message = "수집 중 위치가 바뀌었습니다. 현재 위치에서 인수인계를 다시 만들어 주세요."; return nil }
      accept(start)
      let c = start.context
      var text = "# \(HandoffText.field(capturedTitle)) · 인수인계\n\n생성: \(Date().ISO8601Format())\n작업: \(capturedOperation?.taskId ?? "저장소 단위 기록")\n작업 정보 revision: \(c.revision)\n완료 조건 식별자: \(c.requirementsHash)\n\n## 목적 (작성자 기록)\n\(HandoffText.block(c.purpose.isEmpty ? "미작성" : c.purpose))\n## 완료 조건 (작성자 기록)\n"
      text += c.criteria.isEmpty ? "미작성\n" : c.criteria.map { "- \(HandoffText.field($0))" }.joined(separator: "\n") + "\n"
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
        var observedConflict = false
        var values: [String: JSONValue] = ["repo_id": .string(repo)]
        if let op { values["op_id"] = .string(op) }
        do {
          let status: RepositoryStatus = try await client.call("get_repo_status", params: values)
          observedSnapshot = status.snapshotHash
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
        }
        guard version == token else { message = "수집 중 위치가 바뀌었습니다. 현재 위치에서 인수인계를 다시 만들어 주세요."; return nil }
      }
      text += "\n## 남은 일 · 주의할 점 (작성자 기록)\n\(HandoffText.block(c.notes.isEmpty ? "미작성" : c.notes))\n## 참고 (내용 미조회)\n\(c.references.map { HandoffText.field($0) }.joined(separator: "\n"))\n"
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
}

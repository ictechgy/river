import Foundation
import Testing
import WorkbenchProtocol
@testable import WorkbenchUI

private func workflowFixture(receipts: [[String: Any]] = [], metadata: [[String: Any]] = []) throws -> TaskWorkflowBundle {
  let object: [String: Any] = ["version": 2, "compatibility": "current", "context": ["revision": 2, "purpose": "Drafts",
    "criteria": ["A", "B"], "references": [], "notes": "", "requirements_hash": "legacy"], "verifications": receipts,
    "workflow": ["revision": 3, "context_revision": 2, "intent_hash": "intent", "criteria": [
      ["id": "a", "revision": 1, "text": "A"], ["id": "b", "revision": 2, "text": "B"]], "guides": [], "retired_count": 1],
    "evidence": metadata, "history": []]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(TaskWorkflowBundle.self, from: JSONSerialization.data(withJSONObject: object))
}
private func workflowReceiptJSON(id: String = "r", repo: String = "api", op: String? = nil,
                                 verdict: String = "passed", kind: String = "ai_report") -> [String: Any] {
  ["id": id, "repo_id": repo, "op_id": op as Any? ?? NSNull(), "path": "/synthetic/\(repo)", "branch": "main",
    "head": "recording-head", "snapshot_hash": "recording-snapshot", "after_snapshot_hash": NSNull(), "requirements_hash": "legacy",
    "kind": kind, "verdict": verdict, "started_at": 1, "finished_at": 2, "command": "", "note": "report", "output": "", "truncated": false]
}
private func workflowReceipt(verdict: String = "passed") throws -> VerificationReceipt {
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(VerificationReceipt.self, from: JSONSerialization.data(withJSONObject: workflowReceiptJSON(verdict: verdict)))
}
private func workflowMetadataJSON(id: String = "r", criteria: [[String: Any]] = [], intent: String = "intent",
                                  head: String = "reviewed-head", snapshot: String = "reviewed-snapshot",
                                  status: String = "completed") -> [String: Any] {
  ["receipt_id": id, "criteria": criteria, "intent_hash": intent,
    "claimed_reviewed_state": ["head": head, "snapshot_hash": snapshot],
    "provider": "explicit-provider", "model": "explicit-model", "artifacts": [], "report_status": status]
}
private func workflowVisibleWarnings(_ bundle: TaskWorkflowBundle, repo: String? = "api", op: String? = nil,
                                     head: String? = "reviewed-head", snapshot: String? = "reviewed-snapshot") -> [String] {
  WorkflowEvidencePresentation.visibleWarnings(bundle, repoID: repo, opID: op, head: head, snapshot: snapshot)
}

@Test func duplicateCriterionGetsNewUUIDButEditsAndOrderRetainID() {
  var a = WorkflowCriterionDraft(text: "Same"), b = WorkflowCriterionDraft(text: "Same")
  let aID = a.id, bID = b.id
  #expect(UUID(uuidString: aID) != nil)
  #expect(aID != bID)
  a.text = "Edited"; b.text = "Edited"
  var rows = [a, b]; rows.swapAt(0, 1)
  #expect(rows.map(\.id) == [bID, aID])
  let duplicate = WorkflowCriterionDraft.duplicate(a)
  #expect(duplicate.text == a.text)
  #expect(UUID(uuidString: duplicate.id) != nil)
  #expect(duplicate.id != aID && duplicate.id != bID)
  rows.removeAll { $0.id == aID }
  #expect(rows.map(\.id) == [bID])
}

@Test func unrelatedCriterionEditDoesNotInvalidateMatchingCriterionBinding() throws {
  let bundle = try workflowFixture()
  let evidence = WorkflowEvidence(receiptId: "r", criteria: [.init(id: "a", revision: 1, text: "A")], intentHash: "intent",
    claimedReviewedState: .init(head: "reviewed-head", snapshotHash: "reviewed-snapshot"), reportStatus: "completed")
  let p = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: evidence, workflow: bundle.workflow,
    repoID: "api", opID: nil, head: "reviewed-head", snapshot: "reviewed-snapshot")
  #expect(!p.warnings.contains { $0.contains("조건 변경") })
  #expect(p.labels.contains("보고한 변경 상태와 일치 · 실행 미관찰"))
}

@Test func changedAndDeletedBindingsRemainExplicitWithoutClaimingFulfillment() throws {
  let bundle = try workflowFixture()
  let evidence = WorkflowEvidence(receiptId: "r", criteria: [.init(id: "b", revision: 1, text: "Old B"),
      .init(id: "removed", revision: 1, text: "Deleted")], intentHash: "old-intent", reportStatus: "incomplete")
  let p = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: evidence, workflow: bundle.workflow,
    repoID: "api", opID: nil, head: "current", snapshot: "current")
  #expect(p.warnings.contains("연결 후 조건 변경: B"))
  #expect(p.warnings.contains("삭제된 조건의 기록: Deleted"))
  #expect(p.warnings.contains("기록 후 목적·참고 변경"))
  #expect(p.warnings.contains("보고 미완료"))
  #expect(p.warnings.contains("보고자가 검토한 코드 상태 미기재"))
}

@Test func recordingHeadNeverSuppliesMissingClaimedStateAndToolErrorsStayVisible() throws {
  let bundle = try workflowFixture()
  for status in ["unknown", "incomplete", "tool_error"] {
    let evidence = WorkflowEvidence(receiptId: "r", criteria: [], intentHash: "intent", reportStatus: status)
    let p = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: evidence, workflow: bundle.workflow,
      repoID: "api", opID: nil, head: "recording-head", snapshot: "recording-snapshot")
    #expect(p.warnings.contains("보고자가 검토한 코드 상태 미기재"))
    #expect(p.warnings.contains(evidence.reportStatusLabel))
    #expect(!p.labels.contains { $0.contains("상태와 일치") })
  }
}

@Test func headOnlyClaimDoesNotVerifyDirtyTreeAndOtherScopeStaysUnqueried() throws {
  let bundle = try workflowFixture()
  let evidence = WorkflowEvidence(receiptId: "r", criteria: [], intentHash: "intent", claimedReviewedState: .init(head: "head"), reportStatus: "completed")
  let p = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: evidence, workflow: bundle.workflow,
    repoID: "api", opID: nil, head: "head", snapshot: "dirty")
  #expect(p.warnings.contains("작업 폴더 변경 상태 미기재 · HEAD만으로 현재 변경을 판단하지 않음"))
  let other = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: evidence, workflow: bundle.workflow,
    repoID: "other", opID: nil, head: "head", snapshot: "dirty")
  #expect(other.labels.contains("이 대상의 현재 코드 상태 미조회"))
}

@Test func unlinkedLegacyEvidenceRemainsUnknownEvenIfRecordingBasisMatches() throws {
  let bundle = try workflowFixture()
  let p = WorkflowEvidencePresentation(receipt: try workflowReceipt(), evidence: nil, workflow: bundle.workflow,
    repoID: "api", opID: nil, head: "recording-head", snapshot: "recording-snapshot")
  #expect(p.labels == ["조건 연결 정보 없음 · 과거 기록은 자동 연결하지 않음"])
  #expect(p.warnings == ["보고 메타데이터 없음 · 검토한 코드 상태 미확인"])
}

@Test func completedUnlinkedStaleClaimWarnsWithHistoryCollapsed() throws {
  let bundle = try workflowFixture(receipts: [workflowReceiptJSON()], metadata: [workflowMetadataJSON()])
  let warnings = workflowVisibleWarnings(bundle, head: "new-head", snapshot: "new-snapshot")
  #expect(warnings == ["코드·조건·대상 적용성 재확인 1개"])
  let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
    workflow: bundle.workflow, repoID: "api", opID: nil, head: "new-head", snapshot: "new-snapshot")
  #expect(p.needsApplicabilityCheck)
  #expect(p.warnings.contains("보고한 HEAD가 현재와 다름"))
  #expect(p.warnings.contains("보고한 변경 상태가 현재와 다름"))
}

@Test func deletedOnlyBindingWarnsEvenWithMatchingFullCodeClaim() throws {
  let bundle = try workflowFixture(receipts: [workflowReceiptJSON()], metadata: [workflowMetadataJSON(
    criteria: [["id": "deleted", "revision": 1, "text": "No active row remains"]])])
  #expect(workflowVisibleWarnings(bundle) == ["코드·조건·대상 적용성 재확인 1개"])
  let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
    workflow: bundle.workflow, repoID: "api", opID: nil, head: "reviewed-head", snapshot: "reviewed-snapshot")
  #expect(p.needsApplicabilityCheck)
  #expect(p.warnings.contains("삭제된 조건의 기록: No active row remains"))
}

@Test func completedUnknownResultWarnsIndividuallyAndInCollapsedSummary() throws {
  let bundle = try workflowFixture(receipts: [workflowReceiptJSON(verdict: "unknown")], metadata: [workflowMetadataJSON()])
  #expect(workflowVisibleWarnings(bundle) == ["결과 미확인 보고 1개"])
  let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
    workflow: bundle.workflow, repoID: "api", opID: nil, head: "reviewed-head", snapshot: "reviewed-snapshot")
  #expect(p.warnings.contains("보고 결과 미확인"))
  #expect(!p.needsApplicabilityCheck)
}

@Test func otherFolderAndUnavailableCurrentStateStayUnqueriedDespiteMatchingClaims() throws {
  for (repo, op, head, snapshot) in [("other", nil as String?, "reviewed-head" as String?, "reviewed-snapshot" as String?),
    ("api", "task", "reviewed-head", "reviewed-snapshot"), ("api", nil, nil, nil)] {
    let bundle = try workflowFixture(receipts: [workflowReceiptJSON()], metadata: [workflowMetadataJSON()])
    #expect(workflowVisibleWarnings(bundle, repo: repo, op: op, head: head, snapshot: snapshot)
      == ["코드·조건·대상 적용성 재확인 1개"])
    let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
      workflow: bundle.workflow, repoID: repo, opID: op, head: head, snapshot: snapshot)
    #expect(p.needsApplicabilityCheck)
    #expect(p.labels.contains("이 대상의 현재 코드 상태 미조회"))
    #expect(!p.labels.contains("보고한 변경 상태와 일치 · 실행 미관찰"))
  }
}

@Test func completedPassedMatchingUnlinkedReportDoesNotInventAnApplicabilityWarning() throws {
  let bundle = try workflowFixture(receipts: [workflowReceiptJSON()], metadata: [workflowMetadataJSON()])
  #expect(workflowVisibleWarnings(bundle).isEmpty)
  let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
    workflow: bundle.workflow, repoID: "api", opID: nil, head: "reviewed-head", snapshot: "reviewed-snapshot")
  #expect(p.warnings.isEmpty)
  #expect(!p.needsApplicabilityCheck)
  #expect(p.labels.contains("연결한 완료 조건 없음"))
}

@Test func collapsedWarningsRespectContextWideFirstFiftyBeforeFilteringReports() throws {
  let checks = (0..<50).map { workflowReceiptJSON(id: "check-\($0)", kind: "git_check") }
  let outsideBound = workflowReceiptJSON(id: "old-report", verdict: "unknown")
  let metadata = workflowMetadataJSON(id: "old-report", head: "stale", snapshot: "stale", status: "tool_error")
  let excluded = try workflowFixture(receipts: checks + [outsideBound], metadata: [metadata])
  #expect(workflowVisibleWarnings(excluded).isEmpty)
  let included = try workflowFixture(receipts: Array(checks.prefix(49)) + [outsideBound], metadata: [metadata])
  let warnings = workflowVisibleWarnings(included)
  #expect(warnings.contains("결과 미확인 보고 1개"))
  #expect(warnings.contains("미완료·도구 오류·완료 여부 미확인 1개"))
  #expect(warnings.contains("코드·조건·대상 적용성 재확인 1개"))
}

@Test func changedCriterionAndIntentRemainDistinctFromStatusAndBasisWarnings() throws {
  for metadata in [workflowMetadataJSON(criteria: [["id": "b", "revision": 1, "text": "Old B"]]),
    workflowMetadataJSON(intent: "older-intent")] {
    let bundle = try workflowFixture(receipts: [workflowReceiptJSON()], metadata: [metadata])
    #expect(workflowVisibleWarnings(bundle) == ["코드·조건·대상 적용성 재확인 1개"])
    let p = WorkflowEvidencePresentation(receipt: try #require(bundle.verifications.first), evidence: bundle.evidence.first,
      workflow: bundle.workflow, repoID: "api", opID: nil, head: "reviewed-head", snapshot: "reviewed-snapshot")
    #expect(p.needsApplicabilityCheck)
  }
}

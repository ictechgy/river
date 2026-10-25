import Foundation
import Testing
import WorkbenchProtocol
@testable import WorkbenchUI

private func workflowFixture(_ evidence: [WorkflowEvidence] = []) throws -> TaskWorkflowBundle {
  let object: [String: Any] = ["version": 2, "compatibility": "current", "context": ["revision": 2, "purpose": "Drafts",
    "criteria": ["A", "B"], "references": [], "notes": "", "requirements_hash": "legacy"], "verifications": [],
    "workflow": ["revision": 3, "context_revision": 2, "intent_hash": "intent", "criteria": [
      ["id": "a", "revision": 1, "text": "A"], ["id": "b", "revision": 2, "text": "B"]], "guides": [], "retired_count": 1],
    "evidence": [], "history": []]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(TaskWorkflowBundle.self, from: JSONSerialization.data(withJSONObject: object))
}
private func workflowReceipt(verdict: String = "passed") throws -> VerificationReceipt {
  let object: [String: Any] = ["id": "r", "repo_id": "api", "op_id": NSNull(), "path": "/synthetic/api", "branch": "main",
    "head": "recording-head", "snapshot_hash": "recording-snapshot", "after_snapshot_hash": NSNull(), "requirements_hash": "legacy",
    "kind": "ai_report", "verdict": verdict, "started_at": 1, "finished_at": 2, "command": "", "note": "report", "output": "", "truncated": false]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(VerificationReceipt.self, from: JSONSerialization.data(withJSONObject: object))
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

import Foundation
import Testing
import WorkbenchProtocol
@testable import WorkbenchUI

private func evidenceContext(purpose: String = "문제 해결", criteria: [String] = ["관찰 가능한 결과"],
                             requirements: String = "requirements-1") throws -> TaskContext {
  let object: [String: Any] = ["revision": 1, "purpose": purpose, "criteria": criteria,
    "references": [], "notes": "", "requirements_hash": requirements]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(TaskContext.self, from: JSONSerialization.data(withJSONObject: object))
}

private func evidenceReceipt(id: String = "check", repo: String = "api", op: String? = "task",
                             kind: String = "git_check", verdict: String = "passed",
                             before: String = "code-1", after: String? = "code-1",
                             requirements: String = "requirements-1", finished: Double = 2) throws -> VerificationReceipt {
  let object: [String: Any] = ["id": id, "repo_id": repo, "op_id": op as Any? ?? NSNull(),
    "path": "/tmp/synthetic", "branch": "refs/heads/main", "head": "head-1",
    "snapshot_hash": before, "after_snapshot_hash": after as Any? ?? NSNull(),
    "requirements_hash": requirements, "kind": kind, "verdict": verdict,
    "started_at": finished - 1, "finished_at": finished,
    "command": "git diff --check", "note": "", "output": "", "truncated": false]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(VerificationReceipt.self, from: JSONSerialization.data(withJSONObject: object))
}

private func evidenceSummary(_ receipts: [VerificationReceipt] = [], context: TaskContext? = nil,
                             repo: String = "api", op: String? = "task", snapshot: String? = "code-1",
                             conflict: Bool = false) throws -> TaskEvidenceSummary {
  TaskEvidenceSummary(context: try context ?? evidenceContext(), receipts: receipts,
    repoID: repo, opID: op, snapshot: snapshot, conflict: conflict)
}

@Test func evidenceSummaryGuidesMissingPurposeAndCriteriaWithoutCompletingEither() throws {
  let missingPurpose = try evidenceSummary(context: evidenceContext(purpose: " \n\t", criteria: []))
  #expect(missingPurpose.missingPurpose)
  #expect(missingPurpose.missingCriteria)
  #expect(missingPurpose.state == .missingPurpose)
  #expect(missingPurpose.observation == .noAppCheck)
  let missingCriteria = try evidenceSummary(context: evidenceContext(criteria: [" ", "\n"]))
  #expect(missingCriteria.state == .missingCriteria)
  #expect(missingCriteria.nextAction.contains("조건"))
}

@Test func evidenceSummaryRequiresQueriedCurrentStateEvenWhenPassWasRecorded() throws {
  for snapshot: String? in [nil, ""] {
    let summary = try evidenceSummary([evidenceReceipt()], snapshot: snapshot)
    #expect(summary.state == .statusUnavailable)
    #expect(summary.observation == .statusUnavailable)
    #expect(summary.latestCheckID == "check")
  }
  #expect(try evidenceSummary([evidenceReceipt()], repo: "").state == .statusUnavailable)
}

@Test func evidenceSummaryOnlyCallsStableMatchingTrackedHygieneCurrent() throws {
  let summary = try evidenceSummary([evidenceReceipt()])
  #expect(summary.state == .currentPass)
  #expect(summary.headline == "현재 공백·충돌 검사 통과")
  #expect(summary.nextAction.contains("따로 확인"))
  #expect(summary.scopeDescription.contains("완료 조건·빌드·테스트·병합 가능 여부는 판단하지 않습니다"))
  #expect(summary.reportedCount == 0)
}

@Test func evidenceSummaryUsesLatestFailureInsteadOfAnOlderPass() throws {
  let summary = try evidenceSummary([
    evidenceReceipt(id: "new-failure", verdict: "failed", finished: 3),
    evidenceReceipt(id: "old-pass", finished: 2),
  ])
  #expect(summary.state == .currentFailure)
  #expect(summary.latestCheckID == "new-failure")
}

@Test func evidenceSummaryJournalOrderSurvivesClockReversalAndEqualTimestamps() throws {
  for failedTime in [1.0, 3.0] {
    let summary = try evidenceSummary([
      evidenceReceipt(id: "new-failure", verdict: "failed", finished: failedTime),
      evidenceReceipt(id: "old-pass", finished: 3),
    ])
    #expect(summary.state == .currentFailure)
    #expect(summary.latestCheckID == "new-failure")
  }
  let newPass = try evidenceSummary([
    evidenceReceipt(id: "new-pass", finished: 1),
    evidenceReceipt(id: "old-failure", verdict: "failed", finished: 3),
  ])
  #expect(newPass.state == .currentPass)
  #expect(newPass.latestCheckID == "new-pass")
}

@Test func evidenceSummaryRetainsRecordedFailureWhenApplicabilityChanges() throws {
  let failure = try evidenceReceipt(verdict: "failed")
  let changedRequirements = try evidenceSummary([failure], context: evidenceContext(requirements: "requirements-2"))
  #expect(changedRequirements.state == .requirementsChanged)
  #expect(changedRequirements.latestResultDescription?.contains("기록: 실패") == true)
  #expect(changedRequirements.latestResultDescription?.contains("적용 여부는 따로 확인") == true)
  let changedCode = try evidenceSummary([failure], snapshot: "code-2")
  #expect(changedCode.state == .codeChanged)
  #expect(changedCode.latestResultDescription?.contains("기록: 실패") == true)
  let unavailable = try evidenceSummary([failure], snapshot: nil)
  #expect(unavailable.state == .statusUnavailable)
  #expect(unavailable.latestResultDescription?.contains("기록: 실패") == true)
}

@Test func evidenceSummarySeparatesMissingIntentFromMatchingObservation() throws {
  let summary = try evidenceSummary([evidenceReceipt()], context: evidenceContext(criteria: []))
  #expect(summary.state == .missingCriteria)
  #expect(summary.observation == .currentPass)
  #expect(summary.latestResultDescription == "현재 공백·충돌 검사 통과")
  #expect(try evidenceSummary([evidenceReceipt()]).latestResultDescription == nil)
}

@Test func evidenceSummaryRejectsMissingAfterStateAndChangesDuringCheck() throws {
  let receipts = [
    try evidenceReceipt(after: nil),
    try evidenceReceipt(after: "code-2"),
    try evidenceReceipt(before: "code-0", after: "code-1"),
    try evidenceReceipt(verdict: "unknown"),
    try evidenceReceipt(verdict: "not-a-known-verdict"),
    try evidenceReceipt(before: "", after: ""),
  ]
  for receipt in receipts {
    let summary = try evidenceSummary([receipt])
    #expect(summary.state == .uncertainCheck)
    #expect(summary.state != .currentPass)
  }
}

@Test func evidenceSummaryDoesNotResurrectOldPassAfterNewUnknownCheck() throws {
  let summary = try evidenceSummary([
    evidenceReceipt(id: "new-unknown", verdict: "unknown", after: nil),
    evidenceReceipt(id: "old-pass"),
  ])
  #expect(summary.state == .uncertainCheck)
  #expect(summary.latestCheckID == "new-unknown")
}

@Test func evidenceSummarySeparatesChangedRequirementsFromChangedCode() throws {
  let check = try evidenceReceipt()
  let changedRequirements = try evidenceSummary([check], context: evidenceContext(requirements: "requirements-2"))
  #expect(changedRequirements.state == .requirementsChanged)
  let changedCode = try evidenceSummary([check], snapshot: "code-2")
  #expect(changedCode.state == .codeChanged)
  let bothChanged = try evidenceSummary([check], context: evidenceContext(requirements: "requirements-2"), snapshot: "code-2")
  #expect(bothChanged.state == .requirementsChanged)
  #expect(try evidenceSummary([check], context: evidenceContext(requirements: "")).state == .uncertainCheck)
}

@Test func evidenceSummaryDoesNotUseAnotherRepositoryOrAnotherFolder() throws {
  let receipts = [
    try evidenceReceipt(id: "sibling-repo", repo: "ios"),
    try evidenceReceipt(id: "sibling-operation", op: "another-task"),
    try evidenceReceipt(id: "original-folder", op: nil),
  ]
  let summary = try evidenceSummary(receipts)
  #expect(summary.state == .noAppCheck)
  #expect(summary.targetReceiptCount == 0)
  #expect(summary.latestCheckID == nil)
  let originalFolder = try evidenceSummary(receipts, op: nil)
  #expect(originalFolder.state == .currentPass)
  #expect(originalFolder.latestCheckID == "original-folder")
}

@Test func evidenceSummaryCountsOnlyTargetReportsAndNeverObservesTheirPass() throws {
  let reports = [
    try evidenceReceipt(id: "ai", kind: "ai_report"),
    try evidenceReceipt(id: "human", kind: "human_report"),
    try evidenceReceipt(id: "sibling-ai", repo: "ios", kind: "ai_report"),
    try evidenceReceipt(id: "original-human", op: nil, kind: "human_report"),
  ]
  let summary = try evidenceSummary(reports)
  #expect(summary.state == .noAppCheck)
  #expect(summary.reportedCount == 2)
  #expect(summary.targetReceiptCount == 2)
  #expect(summary.reportsDescription.contains("실행 미관찰"))
  let failure = try evidenceSummary(reports + [evidenceReceipt(verdict: "failed")])
  #expect(failure.state == .currentFailure)
  #expect(failure.reportedCount == 2)
}

@Test func evidenceSummaryBoundsOverallJournalBeforeTargetFiltering() throws {
  let siblings = try (0..<50).map { index in
    try evidenceReceipt(id: "sibling-\(index)", repo: "ios", kind: "ai_report")
  }
  let summary = try evidenceSummary(siblings + [evidenceReceipt(id: "outside-bound")])
  #expect(summary.state == .noAppCheck)
  #expect(summary.targetReceiptCount == 0)
  #expect(summary.reportedCount == 0)
  #expect(summary.latestCheckID == nil)
}

@Test func evidenceSummaryKeepsFailuresUncertaintyAndConflictsVisibleWithoutIntent() throws {
  let missingIntent = try evidenceContext(purpose: "", criteria: [])
  let failed = try evidenceSummary([evidenceReceipt(verdict: "failed")], context: missingIntent)
  #expect(failed.state == .currentFailure)
  #expect(failed.missingPurpose && failed.missingCriteria)
  let unknown = try evidenceSummary([evidenceReceipt(after: nil)], context: missingIntent)
  #expect(unknown.state == .uncertainCheck)
  let unavailable = try evidenceSummary(context: missingIntent, snapshot: nil)
  #expect(unavailable.state == .statusUnavailable)
  let conflict = try evidenceSummary([evidenceReceipt()], context: missingIntent, conflict: true)
  #expect(conflict.state == .conflict)
  #expect(conflict.observation == .conflict)
}

@Test func evidenceSummaryMissingIntentDoesNotEraseMatchingAppObservation() throws {
  let summary = try evidenceSummary([evidenceReceipt()], context: evidenceContext(purpose: ""))
  #expect(summary.state == .missingPurpose)
  #expect(summary.observation == .currentPass)
  #expect(summary.latestCheckID == "check")
}

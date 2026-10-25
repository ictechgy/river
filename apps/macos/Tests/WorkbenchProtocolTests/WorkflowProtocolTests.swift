import Foundation
import Testing
@testable import WorkbenchProtocol

private func decodeWorkflowValue<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: object))
}
private func workflowContextValue() -> [String: Any] { ["revision": 4, "purpose": "Preserve drafts", "criteria": ["Duplicate", "Duplicate"],
  "references": [], "notes": "", "requirements_hash": "legacy-global"] }

@Test func absentWorkflowCapabilityKeepsLegacyBundleDecodable() throws {
  let bundle = try decodeWorkflowValue(TaskContextBundle.self, ["context": workflowContextValue(), "verifications": []])
  #expect(bundle.workflowVersion == nil)
  #expect(bundle.context.criteria == ["Duplicate", "Duplicate"])
  #expect(bundle.verifications.isEmpty)
}

@Test func explicitWorkflowCapabilityIsSeparateFromLegacyJournal() throws {
  let bundle = try decodeWorkflowValue(TaskContextBundle.self, ["context": workflowContextValue(), "verifications": [], "workflow_version": 2])
  #expect(bundle.workflowVersion == 2)
  #expect(bundle.context.requirementsHash == "legacy-global")
}

@Test func workflowWirePreservesDistinctCriterionIdentityAndClaimedBasis() throws {
  let first = "019abcd1-1111-4111-8111-111111111111", second = "019abcd1-2222-4222-8222-222222222222"
  let bundle = try decodeWorkflowValue(TaskWorkflowBundle.self, [
    "version": 2, "compatibility": "current", "context": workflowContextValue(), "verifications": [],
    "workflow": ["revision": 8, "context_revision": 4, "intent_hash": "intent", "criteria": [
      ["id": first, "revision": 1, "text": "Duplicate"], ["id": second, "revision": 3, "text": "Duplicate"]],
      "guides": [["id": "guide", "repo_id": "api", "kind": "feature_map", "path": "docs/map.md", "expected_sha256": NSNull()]], "retired_count": 1],
    "evidence": [["receipt_id": "receipt", "criteria": [["id": second, "revision": 2, "text": "Earlier text"]],
      "intent_hash": "earlier-intent", "claimed_reviewed_state": ["head": "claimed-head", "snapshot_hash": NSNull()],
      "provider": "provider", "model": "explicit-model", "artifacts": ["report.txt"], "report_status": "tool_error"]],
    "history": [["revision": 7, "context_revision": 3, "saved_at": 100, "criterion_count": 2]]])
  #expect(bundle.canWrite)
  #expect(bundle.workflow.criteria.map(\.id) == [first, second])
  #expect(bundle.evidence.first?.claimedReviewedState?.head == "claimed-head")
  #expect(bundle.evidence.first?.claimedReviewedState?.snapshotHash == nil)
  #expect(bundle.evidence.first?.reportStatus == "tool_error")
  #expect(bundle.workflow.guides.first?.expectedSha256 == nil)
  #expect(bundle.history.first?.contextRevision == 3)
}

@Test func absentClaimedCodeNeverUsesRecordingTimeCode() throws {
  let evidence = try decodeWorkflowValue(WorkflowEvidence.self, ["receipt_id": "old", "criteria": [], "intent_hash": "intent",
    "provider": "", "model": "", "artifacts": [], "report_status": "unknown"])
  #expect(evidence.claimedReviewedState == nil)
  #expect(evidence.reportStatusLabel == "보고 완료 여부 미확인")
}

@Test func guideReadResponseRetainsObservedAndPinnedHashesSeparately() throws {
  let read = try decodeWorkflowValue(VerificationGuideRead.self, ["repo_id": "api", "op_id": NSNull(), "path": "docs/verify.md",
    "sha256": "observed", "expected_sha256": "pinned", "status": "changed", "content": "$(must remain plain text)",
    "format": "plain_text", "read_at": 123])
  #expect(read.sha256 != read.expectedSha256)
  #expect(read.content == "$(must remain plain text)")
  #expect(read.opId == nil)
}

@Test func unknownWorkflowCompatibilityAndVersionCannotEnableWrites() throws {
  for (version, compatibility) in [(2, "legacy_changed"), (2, "future-state"), (3, "current")] {
    let bundle = try decodeWorkflowValue(TaskWorkflowBundle.self, ["version": version, "compatibility": compatibility,
      "context": workflowContextValue(), "verifications": [], "workflow": ["revision": 1, "context_revision": 4,
        "intent_hash": "intent", "criteria": [], "guides": [], "retired_count": 0], "evidence": [], "history": []])
    #expect(!bundle.canWrite)
  }
}

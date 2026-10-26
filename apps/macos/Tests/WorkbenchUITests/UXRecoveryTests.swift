import Foundation
import Testing
import WorkbenchProtocol
@testable import WorkbenchUI

private func recoveryOperation(_ errors: [String?], materialize: Bool = true) throws -> WorkbenchOperation {
  let repos: [[String: Any]] = errors.enumerated().map { index, error in
    var repo: [String: Any] = [
      "plan": ["repo_id": "repo-\(index)", "base_ref": "refs/heads/main", "base_oid": "base",
        "branch_ref": "refs/heads/feature/task", "worktree_path": "/synthetic/task/repo-\(index)",
        "policy": [:]],
      "state": error == nil ? "ready" : "failed", "attempts": 1,
    ]
    if let error { repo["error_code"] = error }
    return repo
  }
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(WorkbenchOperation.self, from: JSONSerialization.data(withJSONObject: [
    "schema_version": 1, "id": "operation", "task_id": "task", "plan_id": "plan",
    "status": "partial_failure", "materialize": materialize, "repos": repos,
  ]))
}

@Test func branchCollisionNeedsAFreshPlanForBothPreparationModesAndKeepsReadySiblings() throws {
  for materialize in [true, false] {
    let operation = try recoveryOperation([nil, "branch_collision"], materialize: materialize)
    let original = operation
    #expect(operation.requiresNewPlan)
    #expect(operation.newPlanRecoveryHint?.contains("같은 이름의 브랜치") == true)
    #expect(operation.newPlanRecoveryHint?.contains("원래 폴더가 바뀌어") == false)
    #expect(operation.newPlanRecoveryHint?.contains("기존 폴더와 브랜치는 유지") == true)
    #expect(operation == original)
    #expect(operation.repos.first?.state == "ready")
    #expect(operation.repos.last?.plan.branchRef == "refs/heads/feature/task")
  }
}

@Test func recoveryExplainsAllPlanIdentityFailuresWithoutDisablingOrdinaryRetries() throws {
  let sourceChanged = try recoveryOperation(["stale_source_snapshot"])
  #expect(sourceChanged.requiresNewPlan)
  #expect(sourceChanged.newPlanRecoveryHint?.contains("원래 폴더가 바뀌어") == true)
  #expect(sourceChanged.newPlanRecoveryHint?.contains("같은 이름의 브랜치") == false)
  let both = try recoveryOperation(["stale_source_snapshot", "branch_collision", nil])
  #expect(both.requiresNewPlan)
  #expect(both.newPlanRecoveryHint?.contains("원래 폴더가 바뀌고 같은 이름의 브랜치") == true)
  let ordinaryFailure = try recoveryOperation(["recipe_timeout", nil])
  #expect(!ordinaryFailure.requiresNewPlan)
  #expect(ordinaryFailure.newPlanRecoveryHint == nil)
  #expect(ordinaryFailure.canRetry)
}

@Test func firstDiffReadIsPendingUntilTheRepositoryIsKnown() {
  #expect(DiffSelectionPresentation(repositoryAvailable: false, diffAvailable: false,
    validatingSelection: true, selectionCheckFailed: false, pendingWorktree: false,
    isViewingStash: false) == .initialLoading)
  // A confirmed clean repository still uses the normal empty-content path.
  #expect(DiffSelectionPresentation(repositoryAvailable: true, diffAvailable: false,
    validatingSelection: false, selectionCheckFailed: false, pendingWorktree: false,
    isViewingStash: false) == .review)
  // Cached content remains visible while its current state is validated.
  #expect(DiffSelectionPresentation(repositoryAvailable: true, diffAvailable: true,
    validatingSelection: true, selectionCheckFailed: false, pendingWorktree: false,
    isViewingStash: false) == .review)
}

@Test func diffSelectionFailuresAndUnpreparedFoldersDoNotBecomeEndlessInitialLoading() {
  #expect(DiffSelectionPresentation(repositoryAvailable: false, diffAvailable: false,
    validatingSelection: true, selectionCheckFailed: true, pendingWorktree: false,
    isViewingStash: false) == .validationFailure)
  #expect(DiffSelectionPresentation(repositoryAvailable: false, diffAvailable: false,
    validatingSelection: true, selectionCheckFailed: false, pendingWorktree: true,
    isViewingStash: false) == .pendingWorktree)
  #expect(DiffSelectionPresentation(repositoryAvailable: false, diffAvailable: false,
    validatingSelection: true, selectionCheckFailed: true, pendingWorktree: true,
    isViewingStash: false) == .validationFailure)
  #expect(DiffSelectionPresentation(repositoryAvailable: true, diffAvailable: true,
    validatingSelection: true, selectionCheckFailed: true, pendingWorktree: false,
    isViewingStash: false) == .review)
  #expect(DiffSelectionPresentation(repositoryAvailable: false, diffAvailable: false,
    validatingSelection: true, selectionCheckFailed: false, pendingWorktree: false,
    isViewingStash: true) == .review)
}

private func taskPlanPreview() throws -> TaskPlan {
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(TaskPlan.self, from: JSONSerialization.data(withJSONObject: [
    "schema_version": 1, "id": "expired-preview", "snapshot_hash": "snapshot",
    "repos": [], "warnings": [], "expires_at": 1,
  ]))
}

@Test func expiredTaskPlanCannotRemainTheNextExecutablePreview() throws {
  var preview: TaskPlan? = try taskPlanPreview()
  #expect(TaskPlanRecovery.discardExpiredPreview(&preview,
    after: ServiceFailure(code: "stale_plan", message: "expired")))
  #expect(preview == nil)
}

@Test func transientAndUnknownSubmissionFailuresNeverSilentlyReplaceTaskPlans() throws {
  for code in ["repository_busy", "preparation_queue_full", "unknown_plan", "branch_collision"] {
    var preview: TaskPlan? = try taskPlanPreview()
    #expect(!TaskPlanRecovery.discardExpiredPreview(&preview,
      after: ServiceFailure(code: code, message: code)))
    #expect(preview?.id == "expired-preview")
  }
  var preview: TaskPlan? = try taskPlanPreview()
  #expect(!TaskPlanRecovery.discardExpiredPreview(&preview, after: TransportFailure.invalidReply))
  #expect(preview?.id == "expired-preview")
}

import Testing
@testable import WorkbenchUI

private func availableGuidance() -> TaskGuidanceAvailability {
  TaskGuidanceAvailability(loaded: true, working: false, dirty: false,
    workspaceBusy: false, validatingSelection: false, repositoryAvailable: true,
    runningOperation: false, workflowWritable: true)
}

@Test func guidanceStartsFromAnExistingCheckoutWithoutChangesOrPriorReports() {
  // No branch, staged-file count, Git-check receipt or AI report is a prerequisite.
  let state = availableGuidance()
  #expect(state.canEditContext)
  #expect(state.canCopyRequest)
  #expect(state.canRecordReport)
  #expect(state.requestBlocker == nil)
}

@Test func guidanceRequiresSavedContextForCopyAndReportsButKeepsEditingAvailable() {
  var state = availableGuidance()
  state.dirty = true
  #expect(state.canEditContext)
  #expect(!state.canCopyRequest)
  #expect(!state.canRecordReport)
  #expect(state.requestBlocker?.contains("먼저 저장") == true)
}

@Test func guidanceWaitsForLoadedContextAndDoesNotOverlapActiveWork() {
  var unloaded = availableGuidance()
  unloaded.loaded = false
  #expect(!unloaded.canEditContext && !unloaded.canCopyRequest && !unloaded.canRecordReport)
  #expect(unloaded.requestBlocker != nil)
  var working = availableGuidance()
  working.working = true
  #expect(!working.canEditContext && !working.canCopyRequest && !working.canRecordReport)
  var busy = availableGuidance()
  busy.workspaceBusy = true
  #expect(busy.canEditContext)
  #expect(!busy.canCopyRequest && !busy.canRecordReport)
}

@Test func collectingContextRemainsSeparateFromRecordingAgainstAValidatedFolder() {
  var state = availableGuidance()
  state.validatingSelection = true
  #expect(state.canCopyRequest)
  #expect(!state.canRecordReport)
  state.validatingSelection = false
  state.repositoryAvailable = false
  #expect(state.canCopyRequest)
  #expect(!state.canRecordReport)
  state.repositoryAvailable = true
  state.runningOperation = true
  #expect(state.canCopyRequest)
  #expect(!state.canRecordReport)
}

@Test func conflictingWorkflowKeepsTheEditorAvailableWithoutOfferingInvalidDrafts() {
  var state = availableGuidance()
  state.workflowWritable = false
  #expect(state.canEditContext)
  #expect(!state.canCopyRequest && !state.canRecordReport)
  #expect(state.requestBlocker != nil)
}

@Test func reportInputNeverInventsUnknownReviewedCodeState() {
  #expect(TaskReportInput.claimedState(head: "", snapshot: "") == nil)
  #expect(TaskReportInput.claimedState(head: " \n", snapshot: "\t ") == nil)
  let headOnly = TaskReportInput.claimedState(head: " explicitly-reviewed-head \n", snapshot: "")
  #expect(headOnly?.head == "explicitly-reviewed-head")
  #expect(headOnly?.snapshotHash == nil)
  let snapshotOnly = TaskReportInput.claimedState(head: "", snapshot: " reviewed-worktree ")
  #expect(snapshotOnly?.head == nil)
  #expect(snapshotOnly?.snapshotHash == "reviewed-worktree")
}

@Test func reportCompletionWarningsRemainVisibleForUnknownIncompleteAndToolErrors() {
  #expect(TaskReportInput.completionWarning("unknown") != nil)
  #expect(TaskReportInput.completionWarning("incomplete")?.contains("미완료") == true)
  #expect(TaskReportInput.completionWarning("tool_error")?.contains("도구 오류") == true)
  #expect(TaskReportInput.completionWarning("unrecognized-status") != nil)
  #expect(TaskReportInput.completionWarning("completed") == nil)
}

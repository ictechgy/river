import Foundation
import WorkbenchProtocol

/// Availability follows existing editor/copy/report guards, never a workflow score.
struct TaskGuidanceAvailability: Equatable {
  var loaded: Bool
  var working: Bool
  var dirty: Bool
  var workspaceBusy: Bool
  var validatingSelection: Bool
  var repositoryAvailable: Bool
  var runningOperation: Bool
  var workflowWritable: Bool

  var canEditContext: Bool { loaded && !working }
  var canCopyRequest: Bool { loaded && !working && !dirty && !workspaceBusy && workflowWritable }
  var canRecordReport: Bool {
    canCopyRequest && !validatingSelection && repositoryAvailable && !runningOperation
  }
  var requestBlocker: String? {
    if dirty { return "작성 중인 목적·완료 조건을 먼저 저장하면 그 내용으로 AI 요청을 만들 수 있습니다." }
    if !loaded { return "작업 정보를 불러온 뒤 작성하거나 AI 요청을 복사할 수 있습니다." }
    if !workflowWritable { return "바뀐 작업 정보를 확인한 뒤 AI 요청과 결과 기록을 사용할 수 있습니다." }
    return nil
  }
}

enum TaskReportInput {
  /// Unknown claims stay absent; current repository observations are never substituted.
  static func claimedState(head: String, snapshot: String) -> WorkflowClaimedState? {
    let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !head.isEmpty || !snapshot.isEmpty else { return nil }
    return WorkflowClaimedState(head: head.isEmpty ? nil : head,
      snapshotHash: snapshot.isEmpty ? nil : snapshot)
  }

  static func completionWarning(_ status: String) -> String? {
    switch status {
    case "completed": nil
    case "incomplete": "미완료 보고입니다. 통과로 적어도 검토 완료 근거가 되지 않습니다."
    case "tool_error": "도구 오류가 있는 보고입니다. 실행하지 못한 확인과 오류를 결과에 남겨 주세요."
    default: "보고 완료 여부를 확인하지 못했습니다. 실제로 끝낸 확인과 남은 확인을 구분해 주세요."
    }
  }
}

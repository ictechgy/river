import WorkbenchProtocol

enum TaskPlanRecovery {
  /// An expired preview cannot be executed again. Keep the separate form inputs
  /// and require the user to review a fresh plan before another execution.
  @discardableResult
  static func discardExpiredPreview<Plan>(_ plan: inout Plan?, after error: any Error) -> Bool {
    guard let failure = error as? ServiceFailure, failure.code == "stale_plan" else { return false }
    plan = nil
    return true
  }
}

import Foundation

public struct TaskContext: Decodable, Sendable, Equatable {
  public let revision: Int
  public let purpose: String
  public let criteria: [String]
  public let references: [String]
  public let notes: String
  public let requirementsHash: String
}
public struct TaskContextBundle: Decodable, Sendable, Equatable {
  public let context: TaskContext
  public let verifications: [VerificationReceipt]
  /// Absent for older engines: keep the legacy editor and report flow available.
  public let workflowVersion: Int?
  public init(context: TaskContext, verifications: [VerificationReceipt], workflowVersion: Int? = nil) {
    self.context = context; self.verifications = verifications; self.workflowVersion = workflowVersion
  }
}
public struct VerificationReceipt: Decodable, Identifiable, Sendable, Equatable {
  public let id: String
  public let repoId: String
  public let opId: String?
  public let path: String
  public let branch: String
  public let head: String
  public let snapshotHash: String
  public let afterSnapshotHash: String?
  public let requirementsHash: String
  public let kind: String
  public let verdict: String
  public let startedAt: Double
  public let finishedAt: Double
  public let command: String
  public let note: String
  public let output: String
  public let truncated: Bool
  public var sourceLabel: String {
    switch kind { case "git_check": "앱이 실행한 공백·충돌 검사"; case "ai_report": "AI가 보고한 결과"; default: "직접 적은 결과" }
  }
  public var verdictLabel: String {
    switch verdict { case "passed": "통과"; case "failed": "실패"; default: "확인 필요" }
  }
  public func freshness(repoId: String?, opId: String?, snapshot: String?, requirements: String?) -> String {
    var labels: [String] = []
    if kind != "git_check" { labels.append("실행을 관찰하지 않은 보고 · 기록 시점의 상태만 첨부") }
    if requirementsHash != requirements { labels.append("완료 조건 변경 · 영향 확인 필요") }
    if self.repoId != repoId || self.opId != opId || snapshot == nil {
      labels.append("이 대상의 현재 상태 미조회")
    } else if snapshotHash != snapshot {
      labels.append("이전 코드 상태의 기록")
    } else if kind == "git_check" {
      labels.append(afterSnapshotHash == snapshotHash ? "현재 코드 상태와 일치" : "검사 중 상태 변경 또는 확인 실패")
    }
    return labels.joined(separator: " · ")
  }
}

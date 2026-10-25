import Foundation
import WorkbenchProtocol

/// Editor identity is explicit and independent of text, order, or duplicate content.
struct WorkflowCriterionDraft: Equatable, Identifiable {
  var id: String
  var text: String
  init(id: String = UUID().uuidString.lowercased(), text: String = "") {
    self.id = id; self.text = text
  }
  init(_ criterion: WorkflowCriterion) { id = criterion.id; text = criterion.text }
  static func duplicate(_ entry: Self) -> Self { Self(text: entry.text) }
}

struct WorkflowEvidencePresentation: Equatable {
  let labels: [String]
  let warnings: [String]

  init(receipt: VerificationReceipt, evidence: WorkflowEvidence?, workflow: TaskWorkflowDefinition,
       repoID: String?, opID: String?, head: String?, snapshot: String?) {
    var labels: [String] = [], warnings: [String] = []
    guard let evidence else {
      self.labels = ["조건 연결 정보 없음 · 과거 기록은 자동 연결하지 않음"]
      self.warnings = receipt.kind == "git_check" ? [] : ["보고 메타데이터 없음 · 검토한 코드 상태 미확인"]
      return
    }
    if evidence.criteria.isEmpty { labels.append("연결한 완료 조건 없음") }
    for binding in evidence.criteria {
      guard let current = workflow.criteria.first(where: { $0.id == binding.id }) else {
        warnings.append("삭제된 조건의 기록: \(binding.text)"); continue
      }
      if current.revision != binding.revision {
        warnings.append("연결 후 조건 변경: \(current.text)")
      }
    }
    if evidence.intentHash != workflow.intentHash { warnings.append("기록 후 목적·참고 변경") }
    labels.append(evidence.reportStatusLabel)
    if evidence.reportStatus != "completed" { warnings.append(evidence.reportStatusLabel) }
    let claim = evidence.claimedReviewedState
    if claim?.head?.isEmpty != false && claim?.snapshotHash?.isEmpty != false {
      warnings.append("보고자가 검토한 코드 상태 미기재")
    } else {
      if claim?.head?.isEmpty != false { warnings.append("보고자가 검토한 HEAD 미기재") }
      if claim?.snapshotHash?.isEmpty != false { warnings.append("작업 폴더 변경 상태 미기재 · HEAD만으로 현재 변경을 판단하지 않음") }
    }
    if receipt.repoId != repoID || receipt.opId != opID || snapshot?.isEmpty != false {
      labels.append("이 대상의 현재 코드 상태 미조회")
    } else if let claim {
      if let claimedHead = claim.head, !claimedHead.isEmpty, let head, claimedHead != head {
        warnings.append("보고한 HEAD가 현재와 다름")
      }
      if let claimedSnapshot = claim.snapshotHash, !claimedSnapshot.isEmpty, claimedSnapshot != snapshot {
        warnings.append("보고한 변경 상태가 현재와 다름")
      }
      if claim.snapshotHash?.isEmpty == false && claim.snapshotHash == snapshot {
        labels.append("보고한 변경 상태와 일치 · 실행 미관찰")
      }
    }
    if receipt.verdict == "failed" { warnings.append("실패로 보고된 기록") }
    self.labels = labels; self.warnings = warnings
  }

  /// Counts only the bounded service response, never claims all-time coverage.
  static func visibleWarnings(_ bundle: TaskWorkflowBundle) -> [String] {
    let reports = bundle.verifications.prefix(50).filter { $0.kind != "git_check" }
    let metadata = Dictionary(bundle.evidence.map { ($0.receiptId, $0) }, uniquingKeysWith: { first, _ in first })
    let failures = reports.filter { $0.verdict == "failed" }.count
    let unfinished = reports.filter { metadata[$0.id]?.reportStatus != "completed" }.count
    let missingBasis = reports.filter {
      let state = metadata[$0.id]?.claimedReviewedState
      return state?.head?.isEmpty != false || state?.snapshotHash?.isEmpty != false
    }.count
    var result: [String] = []
    if failures > 0 { result.append("실패 보고 \(failures)개") }
    if unfinished > 0 { result.append("미완료·도구 오류·완료 여부 미확인 \(unfinished)개") }
    if missingBasis > 0 { result.append("검토 상태 일부·전체 미기재 \(missingBasis)개") }
    return result
  }
}

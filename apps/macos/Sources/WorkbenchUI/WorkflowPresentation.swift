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
  /// Code, condition, intent, or target applicability needs another observation.
  /// Report errors, unknown results, and missing claims remain separate warnings.
  let needsApplicabilityCheck: Bool

  init(receipt: VerificationReceipt, evidence: WorkflowEvidence?, workflow: TaskWorkflowDefinition,
       repoID: String?, opID: String?, head: String?, snapshot: String?) {
    var labels: [String] = [], warnings: [String] = []
    let targetUnqueried = receipt.repoId != repoID || receipt.opId != opID
      || head?.isEmpty != false || snapshot?.isEmpty != false
    var needsApplicabilityCheck = targetUnqueried
    if receipt.kind != "git_check" {
      if receipt.verdict == "failed" { warnings.append("실패로 보고된 기록") }
      else if receipt.verdict != "passed" { warnings.append("보고 결과 미확인") }
    }
    guard let evidence else {
      labels.append("조건 연결 정보 없음 · 과거 기록은 자동 연결하지 않음")
      if targetUnqueried { labels.append("이 대상의 현재 코드 상태 미조회") }
      if receipt.kind != "git_check" { warnings.append("보고 메타데이터 없음 · 검토한 코드 상태 미확인") }
      self.labels = labels; self.warnings = warnings
      self.needsApplicabilityCheck = needsApplicabilityCheck
      return
    }
    if evidence.criteria.isEmpty { labels.append("연결한 완료 조건 없음") }
    for binding in evidence.criteria {
      guard let current = workflow.criteria.first(where: { $0.id == binding.id }) else {
        warnings.append("삭제된 조건의 기록: \(binding.text)")
        needsApplicabilityCheck = true; continue
      }
      if current.revision != binding.revision {
        warnings.append("연결 후 조건 변경: \(current.text)")
        needsApplicabilityCheck = true
      }
    }
    if evidence.intentHash != workflow.intentHash {
      warnings.append("기록 후 목적·참고 변경")
      needsApplicabilityCheck = true
    }
    labels.append(evidence.reportStatusLabel)
    if evidence.reportStatus != "completed" { warnings.append(evidence.reportStatusLabel) }
    let claim = evidence.claimedReviewedState
    if claim?.head?.isEmpty != false && claim?.snapshotHash?.isEmpty != false {
      warnings.append("보고자가 검토한 코드 상태 미기재")
    } else {
      if claim?.head?.isEmpty != false { warnings.append("보고자가 검토한 HEAD 미기재") }
      if claim?.snapshotHash?.isEmpty != false { warnings.append("작업 폴더 변경 상태 미기재 · HEAD만으로 현재 변경을 판단하지 않음") }
    }
    if targetUnqueried {
      labels.append("이 대상의 현재 코드 상태 미조회")
    } else if let claim {
      if let claimedHead = claim.head, !claimedHead.isEmpty, claimedHead != head {
        warnings.append("보고한 HEAD가 현재와 다름")
        needsApplicabilityCheck = true
      }
      if let claimedSnapshot = claim.snapshotHash, !claimedSnapshot.isEmpty, claimedSnapshot != snapshot {
        warnings.append("보고한 변경 상태가 현재와 다름")
        needsApplicabilityCheck = true
      }
      if claim.snapshotHash?.isEmpty == false && claim.snapshotHash == snapshot {
        labels.append("보고한 변경 상태와 일치 · 실행 미관찰")
      }
    }
    self.labels = labels; self.warnings = warnings
    self.needsApplicabilityCheck = needsApplicabilityCheck
  }

  /// Counts only the bounded service response, never claims all-time coverage.
  /// Iterate receipts directly: deleted-only or unlinked reports have no active row.
  static func visibleWarnings(_ bundle: TaskWorkflowBundle, repoID: String?, opID: String?,
                              head: String?, snapshot: String?) -> [String] {
    let reports = bundle.verifications.prefix(50).filter { $0.kind != "git_check" }
    let metadata = Dictionary(bundle.evidence.map { ($0.receiptId, $0) }, uniquingKeysWith: { first, _ in first })
    let failures = reports.filter { $0.verdict == "failed" }.count
    let unknownResults = reports.filter { $0.verdict != "passed" && $0.verdict != "failed" }.count
    let unfinished = reports.filter { metadata[$0.id]?.reportStatus != "completed" }.count
    let missingBasis = reports.filter {
      let state = metadata[$0.id]?.claimedReviewedState
      return state?.head?.isEmpty != false || state?.snapshotHash?.isEmpty != false
    }.count
    let applicability = reports.filter {
      Self(receipt: $0, evidence: metadata[$0.id], workflow: bundle.workflow,
        repoID: repoID, opID: opID, head: head, snapshot: snapshot).needsApplicabilityCheck
    }.count
    var result: [String] = []
    if failures > 0 { result.append("실패 보고 \(failures)개") }
    if unknownResults > 0 { result.append("결과 미확인 보고 \(unknownResults)개") }
    if unfinished > 0 { result.append("미완료·도구 오류·완료 여부 미확인 \(unfinished)개") }
    if missingBasis > 0 { result.append("검토 상태 일부·전체 미기재 \(missingBasis)개") }
    if applicability > 0 { result.append("코드·조건·대상 적용성 재확인 \(applicability)개") }
    return result
  }
}

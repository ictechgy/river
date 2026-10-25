import Foundation
import WorkbenchProtocol

/// A bounded summary of recorded evidence for one folder, never a completion or merge verdict.
struct TaskEvidenceSummary: Equatable {
  enum State: Equatable {
    case missingPurpose, missingCriteria, statusUnavailable, conflict, noAppCheck
    case currentPass, currentFailure, uncertainCheck, requirementsChanged, codeChanged
  }

  let missingPurpose: Bool
  let missingCriteria: Bool
  let observation: State
  let reportedCount: Int
  let targetReceiptCount: Int
  let latestCheckID: String?
  let latestCheckVerdict: String?

  init(context: TaskContext, receipts: [VerificationReceipt], repoID: String, opID: String?,
       snapshot: String?, conflict: Bool = false) {
    missingPurpose = context.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    missingCriteria = context.criteria.allSatisfy {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // The service returns the newest 50 records across the entire context. Apply
    // that bound before target filtering, so an older sibling-displaced pass is
    // never recovered as evidence for this folder.
    let target = receipts.prefix(50).filter { $0.repoId == repoID && $0.opId == opID }
    targetReceiptCount = target.count
    reportedCount = target.filter { $0.kind == "ai_report" || $0.kind == "human_report" }.count
    // Journal order, not wall-clock timestamps, identifies the latest record.
    // A clock correction must not resurrect an older pass over a newer failure.
    let latestCheck = target.first { $0.kind == "git_check" }
    latestCheckID = latestCheck?.id
    latestCheckVerdict = latestCheck?.verdict
    if conflict {
      observation = .conflict
    } else if repoID.isEmpty || snapshot?.isEmpty != false {
      observation = .statusUnavailable
    } else {
      observation = latestCheck.map {
        Self.observation(for: $0, context: context, snapshot: snapshot)
      } ?? .noAppCheck
    }
  }

  /// Missing intent guides the next step without changing the separate app observation.
  var state: State {
    switch observation {
    case .conflict, .statusUnavailable, .currentFailure, .uncertainCheck: return observation
    default: break
    }
    if missingPurpose { return .missingPurpose }
    if missingCriteria { return .missingCriteria }
    return observation
  }

  var headline: String {
    switch state {
    case .missingPurpose: "작업 목적이 비어 있습니다"
    case .missingCriteria: "완료 조건이 비어 있습니다"
    case .statusUnavailable: "현재 폴더 상태를 확인하지 못했습니다"
    case .conflict: "충돌 또는 진행 중인 Git 작업이 있습니다"
    case .noAppCheck: "이 폴더의 최근 앱 검사 기록이 없습니다"
    case .currentPass: "현재 공백·충돌 검사 통과"
    case .currentFailure: "현재 공백·충돌 검사 실패"
    case .uncertainCheck: "최근 앱 검사 결과를 확인해야 합니다"
    case .requirementsChanged: "검사 뒤 완료 조건이 바뀌었습니다"
    case .codeChanged: "검사 뒤 코드 상태가 바뀌었습니다"
    }
  }

  var nextAction: String {
    switch state {
    case .missingPurpose: "해결할 문제와 원하는 결과를 적어 주세요."
    case .missingCriteria: "완료를 판단할 조건을 적어 주세요."
    case .statusUnavailable: "현재 폴더를 새로고침해 상태를 확인하세요."
    case .conflict: "변경 화면에서 충돌과 진행 중인 Git 작업을 확인하세요."
    case .noAppCheck: "공백·충돌 검사를 실행해 현재 기록을 남기세요."
    case .currentPass: "빌드·테스트와 완료 조건은 따로 확인하세요."
    case .currentFailure: "검사 출력을 확인하고 수정한 뒤 다시 검사하세요."
    case .uncertainCheck: "상태를 새로고침한 뒤 다시 검사하세요."
    case .requirementsChanged: "바뀐 완료 조건의 영향을 확인하고 다시 검사하세요."
    case .codeChanged: "현재 변경을 확인한 뒤 다시 검사하세요."
    }
  }

  var scopeDescription: String {
    "최근 50개 기록 중 현재 폴더만 요약합니다. 앱 검사는 추적 파일의 공백·충돌만 확인하며, 완료 조건·빌드·테스트·병합 가능 여부는 판단하지 않습니다."
  }

  var reportsDescription: String {
    "직접 / AI 보고 \(reportedCount)개 · 실행 미관찰"
  }

  /// Keep a recorded failure visible when a newer requirement or code state
  /// makes its applicability uncertain and the full history is collapsed.
  var latestResultDescription: String? {
    guard let verdict = latestCheckVerdict, verdict == "passed" || verdict == "failed" else { return nil }
    if observation == .currentPass || observation == .currentFailure {
      return state == observation ? nil
        : (observation == .currentPass ? "현재 공백·충돌 검사 통과" : "현재 공백·충돌 검사 실패")
    }
    return "최근 앱 검사 기록: \(verdict == "failed" ? "실패" : "통과") · 현재 상태 적용 여부는 따로 확인"
  }

  private static func observation(for receipt: VerificationReceipt, context: TaskContext,
                                  snapshot: String?) -> State {
    guard let snapshot, !snapshot.isEmpty else { return .statusUnavailable }
    // No after-state, changed-during-check, or an unknown verdict can establish
    // a stable observation, even when its before-state happens to match now.
    guard !receipt.snapshotHash.isEmpty,
      receipt.afterSnapshotHash == receipt.snapshotHash,
      receipt.verdict == "passed" || receipt.verdict == "failed"
    else { return .uncertainCheck }
    guard !context.requirementsHash.isEmpty, !receipt.requirementsHash.isEmpty else {
      return .uncertainCheck
    }
    guard receipt.requirementsHash == context.requirementsHash else { return .requirementsChanged }
    guard receipt.snapshotHash == snapshot else { return .codeChanged }
    return receipt.verdict == "passed" ? .currentPass : .currentFailure
  }

}

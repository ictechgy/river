import Foundation

/// Versioned sidecar. Legacy journal receipts and their recording-time basis stay unchanged.
public struct TaskWorkflowBundle: Decodable, Sendable, Equatable {
  public let version: Int
  public let compatibility: String
  public let context: TaskContext
  public let verifications: [VerificationReceipt]
  public let workflow: TaskWorkflowDefinition
  public let evidence: [WorkflowEvidence]
  public let history: [WorkflowHistoryEntry]
  public var canWrite: Bool { version == 2 && compatibility == "current" }
}

public struct TaskWorkflowDefinition: Decodable, Sendable, Equatable {
  public let revision: Int
  public let contextRevision: Int
  public let intentHash: String
  public let criteria: [WorkflowCriterion]
  public let guides: [WorkflowGuideReference]
  public let retiredCount: Int
}

public struct WorkflowCriterion: Decodable, Identifiable, Sendable, Equatable {
  public let id: String
  public let revision: Int
  public let text: String
  public init(id: String, revision: Int, text: String) {
    self.id = id; self.revision = revision; self.text = text
  }
}

public struct WorkflowGuideReference: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var repoId: String
  public var kind: String
  public var path: String
  public var expectedSha256: String?
  public init(id: String = UUID().uuidString.lowercased(), repoId: String, kind: String = "procedure",
              path: String = "", expectedSha256: String? = nil) {
    self.id = id; self.repoId = repoId; self.kind = kind; self.path = path
    self.expectedSha256 = expectedSha256
  }
  public var kindLabel: String { kind == "feature_map" ? "기능 지도" : "검증 절차" }
}

/// The author's claim; never inferred from the receipt's recording-time HEAD or snapshot.
public struct WorkflowClaimedState: Codable, Sendable, Equatable {
  public let head: String?
  public let snapshotHash: String?
  public init(head: String? = nil, snapshotHash: String? = nil) {
    self.head = head; self.snapshotHash = snapshotHash
  }
}

public struct WorkflowEvidence: Decodable, Sendable, Equatable {
  public let receiptId: String
  public let criteria: [WorkflowCriterion]
  public let intentHash: String
  public let claimedReviewedState: WorkflowClaimedState?
  public let provider: String
  public let model: String
  public let artifacts: [String]
  public let reportStatus: String
  public init(receiptId: String, criteria: [WorkflowCriterion], intentHash: String,
              claimedReviewedState: WorkflowClaimedState? = nil, provider: String = "",
              model: String = "", artifacts: [String] = [], reportStatus: String = "unknown") {
    self.receiptId = receiptId; self.criteria = criteria; self.intentHash = intentHash
    self.claimedReviewedState = claimedReviewedState; self.provider = provider; self.model = model
    self.artifacts = artifacts; self.reportStatus = reportStatus
  }
  public var reportStatusLabel: String {
    switch reportStatus {
    case "completed": "완료했다고 보고"
    case "incomplete": "보고 미완료"
    case "tool_error": "도구 오류가 있는 보고"
    default: "보고 완료 여부 미확인"
    }
  }
}

public struct WorkflowHistoryEntry: Decodable, Sendable, Equatable {
  public let revision: Int
  public let contextRevision: Int
  public let savedAt: Double
  public let criterionCount: Int
}

public struct VerificationGuideRead: Decodable, Sendable, Equatable {
  public let repoId: String
  public let opId: String?
  public let path: String
  public let sha256: String
  public let expectedSha256: String?
  public let status: String
  public let content: String
  public let format: String
  public let readAt: Double
}

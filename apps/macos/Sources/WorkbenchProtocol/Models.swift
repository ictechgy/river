import Foundation
import CryptoKit

public enum JSONValue: Codable, Sendable, Equatable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let value = try? c.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? c.decode(String.self) {
      self = .string(value)
    } else if let value = try? c.decode(Double.self) {
      self = .number(value)
    } else if let value = try? c.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
}

public struct WorkspaceInfo: Decodable, Sendable, Identifiable {
  public let schemaVersion: Int
  public let id: String
  public let repositories: [RepositoryInfo]
  public let groups: [GroupInfo]
}
public struct RepositoryInfo: Decodable, Sendable, Identifiable {
  public let id: String
  public let path: String
}
public struct GroupInfo: Decodable, Sendable, Identifiable {
  public let id: String
  public let parentGroupId: String?
  public let templateId: String?
}
public struct HistoryCommit: Decodable, Sendable, Equatable, Identifiable {
  public let oid: String
  public let parents: [String]
  public let refs: String
  public let subject: String
  public let author: String
  public let timestamp: String
  public var id: String { oid }
}
public struct GitBranch: Decodable, Sendable, Equatable, Identifiable {
  public let fullRef: String
  public let name: String
  public let isRemote: Bool
  public let tipOid: String
  public let upstream: String
  public let subject: String
  public let timestamp: String
  public let worktreePath: String
  public let current: Bool
  public var id: String { fullRef }
}
public struct FileChange: Decodable, Sendable, Equatable, Identifiable {
  public let path: String
  public let index: String
  public let worktree: String
  public let reviewKey: String?
  public var id: String { path }
  public var isStaged: Bool { index != " " && index != "?" }
  public var isWorking: Bool { worktree != " " || index == "?" }
}
public struct GitSnapshot: Decodable, Sendable, Equatable {
  public let head: String
  public let branch: String
  public let indexHash: String
}
public struct RepositoryStatus: Decodable, Sendable, Equatable {
  public let path: String
  public let snapshotHash: String
  public let snapshot: GitSnapshot
  public let files: [FileChange]
  public let graph: [HistoryCommit]
  public let refs: [String]
  public let worktrees: String
  public let conflict: Bool
  public let gitVersion: String
  public let fileStagingVersion: Int?
}
public struct FileDiff: Decodable, Sendable {
  public let snapshotHash: String
  public let path: String
  public let staged: Bool
  public let header: String
  public let hunks: [String]
  public let text: String
  public let canStageHunks: Bool
  public let reviewKey: String?
  public let contentIdentity: String
  public let encodingWarning: String?
  public let parsedHunks: [ParsedHunk]
  public let displayLimitExceeded: Bool
  private enum CodingKeys: String, CodingKey {
    case snapshotHash, path, staged, header, hunks, text, canStageHunks, reviewKey, encodingWarning
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    snapshotHash = try values.decode(String.self, forKey: .snapshotHash)
    path = try values.decode(String.self, forKey: .path)
    staged = try values.decode(Bool.self, forKey: .staged)
    header = try values.decode(String.self, forKey: .header)
    hunks = try values.decode([String].self, forKey: .hunks)
    text = try values.decode(String.self, forKey: .text)
    canStageHunks = try values.decode(Bool.self, forKey: .canStageHunks)
    reviewKey = try values.decodeIfPresent(String.self, forKey: .reviewKey)
    encodingWarning = try values.decodeIfPresent(String.self, forKey: .encodingWarning)
    contentIdentity = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    displayLimitExceeded = text.utf8.count > 512 * 1024
      || text.utf8.lazy.filter { $0 == 10 }.prefix(5001).count > 5000
    parsedHunks = displayLimitExceeded ? [] : DiffLines.parse(hunks)
  }
}
public struct GitStash: Decodable, Sendable, Equatable, Identifiable {
  public let oid: String
  public let selector: String
  public let subject: String
  public let timestamp: String
  public var id: String { "\(oid):\(selector)" }
  public var date: Date? { Double(timestamp).map { Date(timeIntervalSince1970: $0) } }
}
public struct StashDetail: Decodable, Sendable {
  public let oid: String
  public let files: [FileChange]
}
public struct VersionInputs: Decodable, Sendable, Equatable {
  public let marketingVersion: String
  public let localBuild: String
}
public struct ResolvedPolicy: Decodable, Sendable, Equatable {
  public let recipe: String?
  public let inputs: VersionInputs?
}
public struct PlannedRepository: Decodable, Sendable, Equatable, Identifiable {
  public let repoId: String
  public let baseRef: String
  public let baseOid: String
  public let branchRef: String
  public let worktreePath: String
  public let recipeHash: String?
  public let policy: ResolvedPolicy
  public var id: String { repoId }
}
public struct TaskPlan: Decodable, Sendable, Identifiable {
  public let schemaVersion: Int
  public let id: String
  public let snapshotHash: String
  public let repos: [PlannedRepository]
  public let warnings: [String]
  public let expiresAt: UInt64
}
public struct TaskRepository: Decodable, Sendable, Equatable, Identifiable {
  public let plan: PlannedRepository
  public let state: String
  public let errorCode: String?
  public let attempts: Int
  public let baseline: GitSnapshot?
  public let postcondition: VersionInputs?
  public var id: String { plan.repoId }
  public var hasWorktree: Bool { baseline != nil }
}
public struct WorkbenchOperation: Decodable, Sendable, Equatable, Identifiable {
  public let schemaVersion: Int
  public let id: String
  public let taskId: String
  public let planId: String
  public let status: String
  public let materialize: Bool
  public let repos: [TaskRepository]
  public var isRunning: Bool { status == "queued" || status == "running" }
  public var canRetry: Bool {
    ["failed", "partial_failure", "cancelled", "needs_recovery"].contains(status)
  }
  public var canMaterialize: Bool {
    status == "waiting_for_worktree" || (!materialize && canRetry)
  }
}
public struct TaskDetail: Decodable, Sendable, Identifiable {
  public struct Request: Decodable, Sendable {
    public let label: String
    public let groupId: String
    public let taskSlug: String
  }
  public let id: String
  public let request: Request
  public let operationId: String
}
public struct OperationEvent: Decodable, Sendable, Identifiable {
  public let sequence: Int
  public let operationId: String
  public let timestamp: UInt64
  public let status: String
  public var id: Int { sequence }
}
public struct MutationResult: Decodable, Sendable { public let view: RepositoryStatus? }
extension WorkbenchOperation {
  public var requiresNewPlan: Bool { repos.contains { $0.errorCode == "stale_source_snapshot" } }
}

public enum StatusText {
  public static func label(_ value: String) -> String {
    switch value {
    case "ready": "준비 완료"
    case "partial_failure": "일부 실패"
    case "waiting_for_worktree": "워크트리 대기"
    case "running", "preparing": "준비 중"
    case "queued", "planned": "대기 중"
    case "branch_intent", "branch_created": "브랜치 생성"
    case "materializing": "워크트리 생성"
    case "checked_out": "체크아웃 완료"
    case "needs_recovery": "복구 필요"
    case "failed": "준비 실패"
    case "cancelled": "취소됨"
    default: value
    }
  }
}

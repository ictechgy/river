import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import Testing
import WorkbenchProtocol
@testable import WorkbenchRuntime
@testable import WorkbenchUI

// Private, synthetic Unix service. No app runtime, user repositories or app data.
private final class TestService: @unchecked Sendable {
  let path = "/tmp/agw-state-\(UUID().uuidString.prefix(10)).sock"
  private let stop = Flag()
  init(_ reply: @escaping @Sendable ([String: Any]) -> [String: Any]?) throws {
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }}
    guard bound == 0, Darwin.listen(listener, 16) == 0 else { Darwin.close(listener); throw POSIXError(.EIO) }
    let stop = self.stop
    // Blocking accept must not consume the shared Dispatch worker pool. With
    // many concurrent fixtures it can otherwise queue replies behind idle listeners.
    Thread.detachNewThread {
      Thread.current.name = "river.test-service.accept"
      defer { Darwin.close(listener) }
      while !stop.value {
        let peer = Darwin.accept(listener, nil, nil)
        if peer < 0 { break }
        if stop.value { Darwin.close(peer); break }
        // Reply closures deliberately block on test gates. Give each peer its
        // own thread so those gates cannot starve unrelated fixture requests.
        Thread.detachNewThread {
          Thread.current.name = "river.test-service.peer"
          defer { Darwin.close(peer) }
          var noSignal: Int32 = 1
          _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
          var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
          while data.count < 1024 * 1024 {
            let n = recv(peer, &buffer, buffer.count, 0)
            if n <= 0 { return }; data.append(contentsOf: buffer.prefix(n))
            if data.contains(10) { break }
          }
          guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = reply(request),
            var bytes = try? JSONSerialization.data(withJSONObject: response) else { return }
          bytes.append(10)
          bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
              let n = send(peer, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
              if n <= 0 { return }; offset += n
            }
          }
        }
      }
    }
  }
  deinit {
    stop.value = true
    let wake = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(wake, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }}
    Darwin.close(wake); Darwin.unlink(path)
  }
}
@Test func syntheticServiceAdmissionSurvivesManyIdleListeners() async throws {
  let services = try (0..<96).map { _ in
    try TestService { _ in ["schema_version": 1, "result": true] }
  }
  let client = ServiceClient(socketPath: services[0].path, timeoutSeconds: 1)
  let admitted: Bool = try await client.call("admission_probe")
  #expect(admitted)
  // Keep every listener alive through the reply; this reproduces the previous
  // shared-pool exhaustion instead of reducing fixture concurrency.
  withExtendedLifetime(services) {}
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock(); private var stored = false
  var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
private final class Replies: @unchecked Sendable {
  let lock = NSLock()
  var revision = 1; var purpose = "saved"; var diffFails = true; var statusFails = false
  var includeTask = false; var taskFails = false; var eventsFail = false
  var contextScopes: [String] = []
  var diffCalls = 0; var notifications = 0; var stageCalls = 0
  var canStageHunks = true
  var holdGet = false; var holdSave = false
  let arrived = Flag(); let gate = DispatchSemaphore(value: 0)
  func context() -> [String: Any] {
    ["context": ["revision": revision, "purpose": purpose, "criteria": [], "references": [], "notes": "", "requirements_hash": "goal-\(revision)"], "verifications": []]
  }
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let p = request["params"] as? [String: Any] ?? [:]
    let held: [String: Any]? = lock.withLock {
      if method == "get_task_context", holdGet { holdGet = false; return context() }
      if method == "save_task_context", holdSave { holdSave = false; return [:] }
      return nil
    }
    if let held { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(3))
      if method == "get_task_context" { return ["schema_version": 1, "result": held] }
    }
    return lock.withLock {
      var value: Any = [:]
      switch method {
      case "list_workspaces": value = [["schema_version": 1, "id": "space", "repositories": [["id": "a", "path": "/tmp/synthetic"]], "groups": []]]
      case "list_operations": value = includeTask ? [operationJSON()] : []
      case "get_task":
        if taskFails { return ["schema_version": 1, "error": ["code": "task_missing", "message": "synthetic metadata failure"]] }
        value = ["id": "task", "operation_id": "op", "request": ["label": "Synthetic Task", "group_id": "group", "task_slug": "work"]]
      case "events":
        if eventsFail { return ["schema_version": 1, "error": ["code": "events_failed", "message": "synthetic history failure"]] }
        value = [Any]()
      case "list_stashes": value = [Any]()
      case "get_task_context": contextScopes.append(p["op_id"] as? String ?? "repo"); value = context()
      case "save_task_context": revision += 1; purpose = p["purpose"] as? String ?? ""; value = context()
      case "get_repo_status":
        if statusFails { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic status failure"]] }
        value = ["path": "/tmp/synthetic", "snapshot_hash": "code", "snapshot": ["head": "head", "branch": "refs/heads/main", "index_hash": "index"], "files": [["path": "a.swift", "index": " ", "worktree": "M"]], "graph": [], "refs": [], "worktrees": "", "conflict": false, "git_version": "test"]
      case "get_diff":
        diffCalls += 1
        if diffFails { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic diff failure"]] }
        value = ["snapshot_hash": "code", "path": "a.swift", "staged": false, "header": "header\n", "hunks": ["@@ -1 +1 @@\n-a\n+b\n"], "text": "header\n@@ -1 +1 @@\n-a\n+b\n", "can_stage_hunks": canStageHunks]
      case "stage_hunk": stageCalls += 1
      default: break
      }
      return ["schema_version": 1, "result": value]
    }
  }
}

private final class BranchReplies: @unchecked Sendable {
  let lock = NSLock()
  let root: String
  var worktreePath = ""
  var historyCalls = 0
  var notifications = 0
  var branchesFail = false
  var pendingTask = false
  var branchCalls = 0
  var tip = "head"
  var historyFails = false
  var holdHistory = false
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  init(root: String) { self.root = root }
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let hold = lock.withLock {
      if method == "get_branch_history", holdHistory { holdHistory = false; return true }
      return false
    }
    if hold { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
    return lock.withLock {
      var value: Any = [Any]()
      switch method {
      case "list_workspaces": value = [["schema_version": 1, "id": "space", "repositories": [["id": "a", "path": root]], "groups": []]]
      case "list_operations":
        if pendingTask {
          var op = operationJSON()
          op["status"] = "waiting_for_worktree"
          op["repos"] = (op["repos"] as! [[String: Any]]).map { repo in
            var repo = repo; repo["state"] = "waiting_for_worktree"; repo.removeValue(forKey: "baseline"); return repo
          }
          value = [op]
        }
      case "get_task": value = ["id": "task", "operation_id": "op", "request": ["label": "Pending Task", "group_id": "group", "task_slug": "work"]]
      case "get_task_context": value = ["context": ["revision": 1, "purpose": "", "criteria": [], "references": [], "notes": "", "requirements_hash": "goal"], "verifications": []]
      case "get_repo_status": value = ["path": root, "snapshot_hash": "code", "snapshot": ["head": "head", "branch": "refs/heads/main", "index_hash": "index"], "files": [], "graph": [], "refs": ["refs/heads/main", "refs/heads/feature"], "worktrees": worktreePath, "conflict": false, "git_version": "test"]
      case "list_branches":
        branchCalls += 1
        if branchesFail { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic failure"]] }
        value = [["full_ref": "refs/heads/feature", "name": "feature", "is_remote": false, "tip_oid": tip, "upstream": "", "subject": "commit", "timestamp": "1", "worktree_path": worktreePath, "current": false]]
      case "get_branch_history":
        historyCalls += 1
        if historyFails { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic history failure"]] }
        value = [["oid": tip, "parents": [], "refs": "", "subject": "commit", "author": "test", "timestamp": "1"]]
      default: break
      }
      return ["schema_version": 1, "result": value]
    }
  }
}

private final class SubmissionReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  var heldMethod = ""
  var executeCalls = 0
  var commitCalls = 0
  var handshakeFails = false
  var executeFailure = ""
  var diffIsBinary = false
  var submittedMessage = ""
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    let hold = lock.withLock {
      if method == "execute_plan" { executeCalls += 1 }
      if method == "commit" { commitCalls += 1; submittedMessage = params["message"] as? String ?? "" }
      return method == heldMethod
    }
    if hold { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
    if method == "plan_task" {
      return ["schema_version": 1, "result": ["schema_version": 1, "id": "plan", "snapshot_hash": "code", "repos": [], "warnings": [], "expires_at": 9_999_999_999]]
    }
    if method == "list_workspaces", lock.withLock({ handshakeFails }) {
      return ["schema_version": 1, "error": ["code": "workspace_failed", "message": "synthetic handshake failure"]]
    }
    if method == "execute_plan" {
      switch lock.withLock({ executeFailure }) {
      case "decode": return ["schema_version": 1, "result": ["broken": true]]
      case "service": return ["schema_version": 1, "error": ["code": "preparation_queue_full", "message": "full"]]
      default: return ["schema_version": 1, "result": operationJSON(id: "submitted-op")]
      }
    }
    var reply = base.respond(request)
    if method == "get_repo_status", var status = reply["result"] as? [String: Any] {
      status["files"] = [["path": "a.swift", "index": "M", "worktree": " "]]
      reply["result"] = status
    }
    if method == "get_diff", var diff = reply["result"] as? [String: Any] {
      diff["staged"] = params["staged"] as? Bool ?? false
      if lock.withLock({ diffIsBinary }) {
        diff["hunks"] = [String](); diff["text"] = "Binary files differ"; diff["can_stage_hunks"] = false
      }
      reply["result"] = diff
    }
    return reply
  }
}

@Test @MainActor func commitKeepsTextTypedAfterSubmissionAndClearsUneditedDraft() async throws {
  let replies = SubmissionReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.commitMessage = "submitted message"
  replies.lock.withLock { replies.heldMethod = "commit" }
  let submit = Task { await store.commit() }; try await wait(replies.arrived)
  store.commitMessage = "new text typed during commit"
  replies.gate.signal(); await submit.value
  #expect(replies.lock.withLock { replies.submittedMessage } == "submitted message")
  #expect(store.commitMessage == "new text typed during commit")
  replies.arrived.value = false
  store.commitMessage = "same words"
  let repeated = Task { await store.commit() }; try await wait(replies.arrived)
  store.commitMessage = "edited words"; store.commitMessage = "same words"
  replies.gate.signal(); await repeated.value
  #expect(store.commitMessage == "same words") // Equal text can still be a newer draft revision.
  replies.lock.withLock { replies.heldMethod = "" }
  await store.commit(); #expect(store.commitMessage.isEmpty)
}

@Test @MainActor func newPlansAndCloneWaitForActiveGitMutation() async throws {
  let replies = SubmissionReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let plan = try await store.planTask(group: "group", label: "Task", slug: "task", mode: "isolated")
  store.commitMessage = "held commit"
  replies.lock.withLock { replies.heldMethod = "commit" }
  let committing = Task { await store.commit() }; try await wait(replies.arrived)
  do { _ = try await store.planTask(group: "group", label: "Another Task", slug: "other", mode: "isolated"); Issue.record("Planned while busy") }
  catch UIError.busy {}
  do { try await store.executePlan(plan, key: "do-not-submit"); Issue.record("Submitted while busy") }
  catch UIError.busy {}
  do { try await store.cloneRepository(url: "https://git.example/repo", destination: URL(fileURLWithPath: "/tmp/unused")); Issue.record("Cloned while busy") }
  catch UIError.busy {}
  #expect(replies.lock.withLock { replies.executeCalls } == 0)
  replies.gate.signal(); await committing.value
}

private final class GitMutationReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  let workspaceID: String
  var failure = ""
  var refreshFailsAfterWrite = false
  private var calls: [String] = []
  private var head = "head-1"
  private var index = "index-1"
  init(workspaceID: String = "origin-project") {
    self.workspaceID = workspaceID
    base.diffFails = false
  }
  var writeCount: Int { lock.withLock { calls.count } }
  func respond(_ request: [String: Any]) -> [String: Any]? {
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    if method == "commit" || method == "stage_hunk" {
      return lock.withLock {
        calls.append(method)
        // Simulate Git accepting the write before its reply is lost or malformed.
        if failure != "reject" {
          if method == "commit" { head = "head-2" }
          index = "index-2"
        }
        switch failure {
        case "disconnect": return nil
        case "decode": return ["schema_version": 1, "result": ["view": "malformed status"]]
        case "reject": return ["schema_version": 1, "error": ["code": "stale_snapshot", "message": "changed before submission"]]
        case "git_write_outcome_unknown", "write_outcome_unknown":
          return ["schema_version": 1, "error": ["code": failure, "message": "lost completion"]]
        default: return ["schema_version": 1, "result": [:]]
        }
      }
    }
    if method == "list_workspaces" {
      return ["schema_version": 1, "result": [["schema_version": 1, "id": workspaceID,
        "repositories": [["id": "a", "path": "/tmp/write-origin"], ["id": "b", "path": "/tmp/write-other-folder"]], "groups": []]]]
    }
    var reply = base.respond(request)
    if method == "get_repo_status", var status = reply["result"] as? [String: Any] {
      let state = lock.withLock { (head, index, refreshFailsAfterWrite && !calls.isEmpty) }
      if state.2 { return ["schema_version": 1, "error": ["code": "git_failed", "message": "optional refresh failed"]] }
      status["path"] = params["repo_id"] as? String == "b" ? "/tmp/write-other-folder" : "/tmp/write-origin"
      status["snapshot_hash"] = state.1 == "index-1" ? "code" : "code-2"
      status["snapshot"] = ["head": state.0, "branch": "refs/heads/main", "index_hash": state.1]
      status["files"] = [["path": "a.swift", "index": "M", "worktree": "M"]]
      reply["result"] = status
    }
    if method == "get_diff", var diff = reply["result"] as? [String: Any] {
      diff["snapshot_hash"] = lock.withLock { index == "index-1" ? "code" : "code-2" }
      diff["staged"] = params["staged"] as? Bool ?? false
      reply["result"] = diff
    }
    return reply
  }
}

@Test(arguments: ["disconnect", "decode", "git_write_outcome_unknown", "write_outcome_unknown"]) @MainActor
func ambiguousCommitKeepsDraftAndWarnsBeforeRepeat(failure: String) async throws {
  let replies = GitMutationReplies(); replies.failure = failure
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); store.commitMessage = "retain the submitted draft"
  await store.commit()
  #expect(store.repository?.snapshot.head == "head-2")
  #expect(store.commitMessage == "retain the submitted draft")
  let warning = try #require(store.submissionWarnings.first)
  #expect(store.submissionWarnings.count == 1); #expect(warning.id.hasPrefix(server.path))
  #expect(warning.workspaceTitle == "origin-project"); #expect(warning.workspacePath == "/tmp/write-origin")
  #expect(warning.message.contains("커밋")); #expect(warning.message.contains("반복하기 전에"))
  await store.refresh(); await store.connect()
  #expect(store.submissionWarnings == [warning]); #expect(replies.writeCount == 1)
  #expect(store.commitMessage == "retain the submitted draft")
}

@Test(arguments: ["disconnect", "decode", "git_write_outcome_unknown", "write_outcome_unknown"]) @MainActor
func ambiguousStagingWarnsForTheSubmittedFile(failure: String) async throws {
  let replies = GitMutationReplies(); replies.failure = failure
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); store.commitMessage = "retain my draft"
  await store.stageHunk(0)
  #expect(store.repository?.snapshot.indexHash == "index-2")
  #expect(store.commitMessage == "retain my draft")
  let warning = try #require(store.submissionWarnings.first)
  #expect(store.submissionWarnings.count == 1); #expect(warning.workspacePath == "/tmp/write-origin")
  #expect(warning.message.contains("스테이징")); #expect(warning.message.contains("a.swift"))
  await store.refresh(); #expect(replies.writeCount == 1)
}

@Test @MainActor func ambiguousGitWriteNoticeKeepsItsOriginAfterNavigationAndWorkspaceSwitch() async throws {
  let first = GitMutationReplies(); first.failure = "disconnect"
  let second = GitMutationReplies(workspaceID: "destination-project")
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  store.commitMessage = "origin draft"; await store.commit()
  let warning = try #require(store.submissionWarnings.first)
  store.select(.init(repoId: "b")); await store.refresh(forceDiff: true)
  #expect(store.repository?.path == "/tmp/write-other-folder"); #expect(store.submissionWarnings == [warning])
  store.socketPath = serverB.path; await store.connect()
  #expect(store.workspaceTitle == "destination-project"); #expect(store.submissionWarnings == [warning])
  #expect(warning.workspaceTitle == "origin-project"); #expect(warning.workspacePath == "/tmp/write-origin")
  store.socketPath = serverA.path; await store.connect()
  store.select(.init(repoId: "a")); await store.refresh(forceDiff: true)
  #expect(store.commitMessage == "origin draft"); #expect(store.submissionWarnings == [warning])
  #expect(first.writeCount == 1); #expect(second.writeCount == 0)
}

@Test(arguments: ["commit", "stage_hunk"]) @MainActor
func explicitGitMutationRejectionDoesNotWarnOfUnknownOutcome(method: String) async throws {
  let replies = GitMutationReplies(); replies.failure = "reject"
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); store.commitMessage = "keep rejected draft"
  if method == "commit" { await store.commit() } else { await store.stageHunk(0) }
  #expect(store.submissionWarnings.isEmpty); #expect(store.error != nil)
  #expect(store.repository?.snapshot.head == "head-1"); #expect(store.repository?.snapshot.indexHash == "index-1")
  #expect(store.commitMessage == "keep rejected draft"); #expect(replies.writeCount == 1)
}

@Test(arguments: ["commit", "stage_hunk"]) @MainActor
func confirmedGitMutationWithFailedRefreshKeepsKnownOutcome(method: String) async throws {
  let replies = GitMutationReplies(); replies.refreshFailsAfterWrite = true
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); store.commitMessage = "submitted draft"
  if method == "commit" { await store.commit() } else { await store.stageHunk(0) }
  #expect(store.submissionWarnings.isEmpty); #expect(store.error != nil)
  #expect(store.commitMessage == (method == "commit" ? "" : "submitted draft"))
  #expect(replies.writeCount == 1)
}

@Test @MainActor func plansAndDelayedSubmissionsCannotCrossWorkspaceSessions() async throws {
  let first = SubmissionReplies(); let second = SubmissionReplies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  first.lock.withLock { first.heldMethod = "plan_task" }
  let oldPlan = Task { try await store.planTask(group: "group", label: "A", slug: "a", mode: "materialize") }
  try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  first.gate.signal()
  do { _ = try await oldPlan.value; Issue.record("Old workspace plan was published") }
  catch UIError.workspaceChanged {}
  first.lock.withLock { first.heldMethod = "" }; first.arrived.value = false
  store.socketPath = serverA.path; await store.connect()
  let plan = try await store.planTask(group: "group", label: "A", slug: "a", mode: "materialize")
  first.lock.withLock { first.heldMethod = "execute_plan" }
  let oldSubmit = Task { try await store.executePlan(plan, key: "one-submission") }
  try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  first.gate.signal()
  do { try await oldSubmit.value; Issue.record("Old workspace operation was published") }
  catch UIError.workspaceChangedAfterSubmission {}
  #expect(store.error == UIError.workspaceChangedAfterSubmission.localizedDescription)
  #expect(store.operations.isEmpty); #expect(store.selection?.opId == nil)
  do { try await store.executePlan(plan, key: "same-plan"); Issue.record("Foreign plan was executed") }
  catch UIError.workspaceChanged {}
  #expect(second.lock.withLock { second.executeCalls } == 0)
  #expect(first.lock.withLock { first.executeCalls } == 1)
  // Reset sheet identity only after the destination workspace has arrived;
  // otherwise its onAppear would initialize the old workspace's group.
  let sheetSession = store.workspaceSession
  first.arrived.value = false
  first.lock.withLock { first.heldMethod = "list_workspaces" }
  store.socketPath = serverA.path
  let reconnect = Task { await store.connect() }; try await wait(first.arrived)
  #expect(store.workspaceSession == sheetSession)
  first.gate.signal(); await reconnect.value
  #expect(store.workspaceSession != sheetSession)
}

private final class SlowDiffReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  var arrived: Set<String> = []
  let gate = DispatchSemaphore(value: 0)
  init() { base.diffFails = false }
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let path = (request["params"] as? [String: Any])?["path"] as? String ?? ""
    if method == "get_diff" && path.hasPrefix("held-") {
      lock.withLock { _ = arrived.insert(path) }
      _ = gate.wait(timeout: .now() + .seconds(5))
    }
    var reply = base.respond(request)
    if method == "get_diff", var diff = reply["result"] as? [String: Any] {
      diff["path"] = path; reply["result"] = diff
    }
    return reply
  }
}

@Test @MainActor func supersededDiffReadsReleaseTransportCapacityForLatestSelection() async throws {
  let replies = SlowDiffReplies(); let server = try TestService { replies.respond($0) }
  defer { for _ in 0..<8 { replies.gate.signal() } }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  for i in 0..<8 {
    let path = "held-\(i).swift"; store.chooseFile(path)
    for _ in 0..<100 {
      if replies.lock.withLock({ replies.arrived.contains(path) }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(replies.lock.withLock { replies.arrived.contains(path) })
  }
  store.chooseFile("latest.swift")
  for _ in 0..<100 {
    if store.diff?.path == "latest.swift" { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(store.diff?.path == "latest.swift"); #expect(store.diffError == nil)
}

@Test @MainActor func branchObservationSeesTipChangesOutsideStatusAndPreservesInFlightHistory() async throws {
  let replies = BranchReplies(root: "/tmp/branch-old-tip")
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); let model = BranchBrowserModel()
  await store.connect(); await model.load(store)
  let identity = BranchRefreshIdentity(store)
  replies.lock.withLock { replies.holdHistory = true }
  let branch = try #require(model.branches.first)
  let history = Task { await model.select(branch, store: store) }
  try await wait(replies.arrived)
  await model.load(store) // Unchanged metadata must not invalidate this history request.
  #expect(model.loadingHistory)
  replies.gate.signal(); await history.value
  #expect(model.commits.count == 1)
  let observation = Task { await model.observe(store, interval: .milliseconds(5), isActive: { true }) }
  defer { observation.cancel() }
  replies.lock.withLock { replies.tip = "older-ref-tip" }
  await store.refresh(); #expect(identity == BranchRefreshIdentity(store)); #expect(!store.pendingWorktree)
  for _ in 0..<100 {
    if model.commits.first?.oid == "older-ref-tip" { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(model.selectedBranch?.tipOid == "older-ref-tip")
  #expect(model.commits.first?.oid == "older-ref-tip")
  observation.cancel(); await observation.value
  replies.lock.withLock { replies.historyFails = true }
  await model.select(try #require(model.branches.first), store: store)
  let error = model.error; let calls = replies.lock.withLock { replies.historyCalls }
  await model.load(store)
  #expect(error != nil); #expect(model.error == error)
  #expect(replies.lock.withLock { replies.historyCalls } == calls)
}

@Test @MainActor func branchWorktreeOccupancyRefreshPreservesUnchangedHistory() async throws {
  let replies = BranchReplies(root: "/tmp/branch-origin")
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path)
  let model = BranchBrowserModel()
  await store.connect(); await model.load(store)
  #expect(model.branches.count == 1); #expect(model.commits.count == 1)
  let before = BranchRefreshIdentity(store)
  replies.lock.withLock { replies.worktreePath = "/tmp/external-worktree" }
  await store.refresh()
  #expect(before.head == BranchRefreshIdentity(store).head)
  #expect(before.refs == BranchRefreshIdentity(store).refs)
  #expect(before.graph == BranchRefreshIdentity(store).graph)
  #expect(before != BranchRefreshIdentity(store))
  await model.load(store)
  #expect(model.branches.first?.worktreePath == "/tmp/external-worktree")
  #expect(replies.lock.withLock { replies.historyCalls } == 1)
  replies.lock.withLock { replies.worktreePath = "" }
  await store.refresh(); await model.load(store)
  #expect(model.branches.first?.worktreePath == "")
  #expect(replies.lock.withLock { replies.historyCalls } == 1)
  let subscription = model.objectWillChange.sink { replies.lock.withLock { replies.notifications += 1 } }
  await model.load(store)
  #expect(replies.lock.withLock { replies.notifications } == 0)
  _ = subscription
}

@Test @MainActor func branchCacheIsScopedToWorkspaceAndRejectsLateHistory() async throws {
  let first = BranchReplies(root: "/tmp/branch-first")
  let second = BranchReplies(root: "/tmp/branch-second")
  let serverA = try TestService { first.respond($0) }
  let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path)
  let model = BranchBrowserModel()
  await store.connect(); await model.load(store)
  let identityA = BranchRefreshIdentity(store)
  let branch = try #require(model.branches.first)
  first.lock.withLock { first.holdHistory = true }
  let oldRead = Task { await model.select(branch, store: store) }
  try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  #expect(identityA != BranchRefreshIdentity(store))
  #expect(identityA.location == store.selection) // Same repo ID is insufficient.
  second.lock.withLock { second.branchesFail = true }
  await model.load(store)
  #expect(model.branches.isEmpty); #expect(model.commits.isEmpty); #expect(model.error != nil)
  first.gate.signal(); await oldRead.value
  #expect(model.commits.isEmpty)
  second.lock.withLock { second.branchesFail = false }
  await model.load(store)
  #expect(model.commits.count == 1)
  #expect(second.lock.withLock { second.historyCalls } == 1)
}

@Test @MainActor func pendingTaskBranchObservationRefreshesWithoutStatusAndStopsOnCancel() async throws {
  let replies = BranchReplies(root: "/tmp/branch-pending")
  replies.pendingTask = true
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path)
  let model = BranchBrowserModel()
  await store.connect(); store.select(.init(repoId: "a", opId: "op"))
  for _ in 0..<200 {
    if !store.validatingSelection { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(store.pendingWorktree); #expect(store.repository == nil)
  let identity = BranchRefreshIdentity(store)
  let active = Flag()
  let observation = Task { await model.observe(store, interval: .milliseconds(5), isActive: { active.value }) }
  defer { observation.cancel() }
  for _ in 0..<200 {
    if model.commits.count == 1 { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  replies.lock.withLock { replies.worktreePath = "/tmp/external-pending" }
  await store.refresh()
  #expect(identity == BranchRefreshIdentity(store)) // No status-driven invalidation is available.
  let inactiveCalls = replies.lock.withLock { replies.branchCalls }
  try await Task.sleep(for: .milliseconds(30))
  #expect(replies.lock.withLock { replies.branchCalls } == inactiveCalls)
  #expect(model.branches.first?.worktreePath == "")
  active.value = true
  for _ in 0..<200 {
    if model.branches.first?.worktreePath == "/tmp/external-pending" { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(model.branches.first?.worktreePath == "/tmp/external-pending")
  store.showingWelcome = true
  // Let any already in-flight request settle before measuring the hidden period.
  try await Task.sleep(for: .milliseconds(30))
  let hiddenCalls = replies.lock.withLock { replies.branchCalls }
  replies.lock.withLock { replies.worktreePath = "" }
  try await Task.sleep(for: .milliseconds(30))
  #expect(replies.lock.withLock { replies.branchCalls } == hiddenCalls)
  #expect(model.branches.first?.worktreePath == "/tmp/external-pending")
  store.showingWelcome = false
  for _ in 0..<200 {
    if model.branches.first?.worktreePath == "" { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(model.branches.first?.worktreePath == "")
  #expect(replies.lock.withLock { replies.historyCalls } == 1)
  observation.cancel(); await observation.value
  let calls = replies.lock.withLock { replies.branchCalls }
  try await Task.sleep(for: .milliseconds(20))
  #expect(replies.lock.withLock { replies.branchCalls } == calls)
}

private func operationJSON(drift: Bool = false, id: String = "op", taskID: String = "task") -> [String: Any] {
  func repo(_ id: String, error: String?) -> [String: Any] {
    var r: [String: Any] = ["plan": ["repo_id": id, "base_ref": "main", "base_oid": "head", "branch_ref": "refs/heads/work", "worktree_path": "/tmp/synthetic-\(id)", "policy": [String: Any]()], "state": error == nil ? "ready" : "needs_recovery", "attempts": 1, "baseline": ["head": "head", "branch": "refs/heads/work", "index_hash": "index"]]
    if let error { r["error_code"] = error }; return r
  }
  return ["schema_version": 1, "id": id, "task_id": taskID, "plan_id": "plan", "status": drift ? "partial_failure" : "ready", "materialize": true,
    "repos": [repo("a", error: drift ? "stale_source_snapshot" : nil), repo("b", error: drift ? "recipe_failed" : nil)]]
}
private func operation() throws -> WorkbenchOperation {
  let value = operationJSON()
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(WorkbenchOperation.self, from: JSONSerialization.data(withJSONObject: value))
}
@MainActor private func wait(_ flag: Flag) async throws {
  for _ in 0..<200 { if flag.value { return }; try await Task.sleep(for: .milliseconds(5)) }
  Issue.record("Expected in-flight request did not arrive")
}

@Test @MainActor func olderContextReadCannotOverwriteSuccessfulSave() async throws {
  let replies = Replies(); let server = try TestService { replies.respond($0) }
  let model = TaskContextStore(); let client = ServiceClient(socketPath: server.path)
  model.configure(client: client, workspace: "space", location: .init(repoId: "a"), contextOperationID: nil, operation: nil, title: "A")
  await model.refresh(); model.draft?.purpose = "new intent"
  replies.lock.withLock { replies.holdGet = true }
  let oldRead = Task { await model.refresh() }; try await wait(replies.arrived)
  await model.save(); replies.gate.signal(); await oldRead.value
  #expect(model.bundle?.context.revision == 2); #expect(model.draft?.purpose == "new intent")
  #expect(!model.isDirty); #expect(!model.working)
}

@Test @MainActor func confirmedContextSaveKeepsRevisionThroughMetadataFailure() async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  store.taskContext.draft?.purpose = "confirmed Task purpose"
  replies.lock.withLock { replies.holdSave = true }
  let saving = Task { await store.taskContext.save() }; try await wait(replies.arrived)
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
  await store.refresh()
  #expect(!store.taskContext.loaded); #expect(store.taskContext.working)
  replies.gate.signal(); await saving.value
  #expect(store.taskContext.bundle?.context.revision == 8)
  #expect(store.taskContext.draft?.revision == 8)
  #expect(!store.taskContext.isDirty); #expect(!store.taskContext.loaded)
  #expect(!store.canEdit); #expect(!store.taskContext.working)
  let requests = replies.lock.withLock { replies.requests.count }
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == requests)
  replies.lock.withLock { replies.lookupFails = false }
  await store.refresh()
  store.taskContext.draft?.notes = "next save uses the confirmed revision"
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 9)
  #expect(store.taskContext.draft?.revision == 9); #expect(!store.taskContext.isDirty)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
}

@Test @MainActor func unsupportedHunksRemainReadableButCannotSubmitStageWrites() async throws {
  let replies = Replies(); replies.diffFails = false
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect()
  let previous = try #require(store.diff); let selection = try #require(store.selection)
  replies.lock.withLock { replies.canStageHunks = false }
  await store.refresh(forceDiff: true)
  #expect(store.diff?.canStageHunks == false)
  #expect(previous.contentIdentity == store.diff?.contentIdentity)
  #expect(store.canUseRenderedDiff); #expect(store.canMarkRead)
  #expect(store.hunkRequestText(0, instruction: "explain this change") != nil)
  await store.stageHunk(0, from: previous, at: selection)
  await store.stageHunk(0)
  #expect(replies.lock.withLock { replies.stageCalls } == 0)
  #expect(store.error != nil); #expect(store.errorDetails == nil)
}

@Test(arguments: [false, true]) @MainActor
func taskMetadataFailureKeepsReadingSnapshotReadOnly(reconnect: Bool) async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  let status = try #require(store.repository); let diff = try #require(store.diff)
  let id = try #require(store.currentReviewID)
  store.markCurrentFileRead(); store.rememberReviewOffset(240, content: diff.contentIdentity, at: id)
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
  if reconnect { await store.connect() } else { await store.refresh() }
  #expect(store.taskInformationUnavailable); #expect(store.selectionCheckFailed)
  #expect(!store.canEdit); #expect(!store.canMarkRead)
  #expect(store.repository == status)
  #expect(store.diff?.contentIdentity == diff.contentIdentity); #expect(store.diff?.text == diff.text)
  #expect(store.readingCheckpoint?.contentIdentity == diff.contentIdentity)
  #expect(store.currentReviewScrollOffset == 240)
  replies.lock.withLock { replies.lookupFails = false }
  await store.refresh()
  #expect(store.canEdit); #expect(store.currentReadingState == .reviewed)
  #expect(store.currentReviewScrollOffset == 240)
}

@Test @MainActor func failedReconnectKeepsOriginalFolderReadingSnapshotReadOnly() async throws {
  let replies = Replies(); replies.diffFails = false
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect()
  let status = try #require(store.repository); let diff = try #require(store.diff)
  replies.lock.withLock { replies.statusFails = true }
  await store.connect()
  #expect(store.repository == status)
  #expect(store.diff?.contentIdentity == diff.contentIdentity); #expect(store.diff?.text == diff.text)
  #expect(store.selectionCheckFailed); #expect(!store.canEdit)
}

@Test @MainActor func metadataWarningsDoNotReplaceActionErrorsAndResetForNewSelection() async throws {
  let replies = Replies(); replies.diffFails = false
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect()
  store.report(ServiceFailure(code: "stale_snapshot", message: "the submitted write was rejected"))
  let actionError = store.error; let details = store.errorDetails
  replies.lock.withLock { replies.eventsFail = true }
  await store.refresh()
  #expect(store.error == actionError); #expect(store.errorDetails == details)
  store.error = nil
  #expect(store.errorDetails == nil)
  // A different folder must get its own warning even if the message is identical.
  store.select(.init(repoId: "b")); try await settleSelection(store)
  #expect(store.error?.contains("준비 기록") == true)
  store.error = nil
  store.report(ServiceFailure(code: "stale_snapshot", message: "old details"))
  let rendered = try #require(store.diff)
  await store.stageHunk(0, from: rendered, at: .init(repoId: "wrong-folder"))
  #expect(store.errorDetails == nil)
}

@Test @MainActor func taskSaveSurvivesSiblingSwitchAndDirtyDraftSurvivesWorkspaceSwitch() async throws {
  let replies = Replies(); let server = try TestService { replies.respond($0) }
  let model = TaskContextStore(); let client = ServiceClient(socketPath: server.path); let op = try operation()
  model.configure(client: client, workspace: "space", location: .init(repoId: "a", opId: "op"), contextOperationID: "op", operation: op, title: "Task")
  await model.refresh(); model.draft?.purpose = "new task purpose"
  replies.lock.withLock { replies.holdSave = true }
  let saving = Task { await model.save() }; try await wait(replies.arrived)
  model.configure(client: client, workspace: "space", location: .init(repoId: "b", opId: "op"), contextOperationID: "op", operation: op, title: "Task")
  #expect(model.working); replies.gate.signal(); await saving.value
  #expect(model.draft?.revision == 2); #expect(!model.isDirty); #expect(!model.working)
  model.draft?.notes = "unsaved handoff"
  model.reset()
  model.configure(client: client, workspace: "another", location: .init(repoId: "c"), contextOperationID: nil, operation: nil, title: "C")
  await model.refresh()
  model.configure(client: client, workspace: "space", location: .init(repoId: "b", opId: "op"), contextOperationID: "op", operation: op, title: "Task")
  await model.refresh(); #expect(model.draft?.notes == "unsaved handoff"); #expect(model.isDirty)
  model.reloadDraft()
  model.configure(client: client, workspace: "another", location: .init(repoId: "c"), contextOperationID: nil, operation: nil, title: "C")
  await model.refresh()
  replies.lock.withLock { replies.revision = 3; replies.purpose = "external update" }
  model.configure(client: client, workspace: "space", location: .init(repoId: "b", opId: "op"), contextOperationID: "op", operation: op, title: "Task")
  await model.refresh(); #expect(model.draft?.purpose == "external update"); #expect(!model.isDirty)
}

@Test @MainActor func diffFailureStopsLoadingAndPollingRetryAndTypingDoesNotPublishWholeStore() async throws {
  let replies = Replies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); #expect(store.diffError != nil); #expect(store.diff == nil)
  let calls = replies.lock.withLock { replies.diffCalls }
  await store.refresh(); #expect(replies.lock.withLock { replies.diffCalls } == calls)
  replies.lock.withLock { replies.diffFails = false }
  await store.retryDiff(); #expect(store.diffError == nil); #expect(store.canUseRenderedDiff)
  let subscription = store.objectWillChange.sink { replies.lock.withLock { replies.notifications += 1 } }
  store.commitMessage = "draft A"
  #expect(replies.lock.withLock { replies.notifications } == 0)
  await store.refresh(); #expect(replies.lock.withLock { replies.notifications } == 0)
  let other = try TestService { replies.respond($0) }
  store.socketPath = other.path; await store.connect(); store.commitMessage = "draft B"
  store.socketPath = server.path; await store.connect(); #expect(store.commitMessage == "draft A")
  replies.lock.withLock { replies.statusFails = true }
  await store.refresh()
  #expect(store.selectionCheckFailed); #expect(store.validatingSelection); #expect(!store.canEdit)
  store.error = nil
  replies.lock.withLock { replies.notifications = 0 }
  await store.refresh(); #expect(store.error == nil)
  #expect(replies.lock.withLock { replies.notifications } == 0)
  replies.lock.withLock { replies.statusFails = false }
  await store.refresh(); #expect(!store.selectionCheckFailed); #expect(store.canEdit)
  _ = subscription
}

@Test @MainActor func auxiliaryMetadataFailuresDoNotLockCoherentGitStateAndTaskScopeCanBeLeft() async throws {
  let replies = Replies()
  replies.includeTask = true; replies.taskFails = true; replies.eventsFail = true; replies.diffFails = false
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect()
  #expect(store.canEdit); #expect(!store.selectionCheckFailed)
  #expect(store.error?.contains("준비 기록") == true); #expect(store.error?.contains("작업 정보") == true)
  replies.lock.withLock { replies.taskFails = false; replies.eventsFail = false }
  await store.refresh(); #expect(store.error == nil)
  let op = try #require(store.operations.first)
  store.selectTask(op)
  for _ in 0..<100 where store.validatingSelection { try await Task.sleep(for: .milliseconds(5)) }
  store.select(.init(repoId: "a"))
  #expect(store.contextOperation?.id == "op")
  let identity = store.taskContext.identity
  replies.lock.withLock { replies.notifications = 0 }
  let changes = store.objectWillChange.sink { replies.lock.withLock { replies.notifications += 1 } }
  store.select(.init(repoId: "a"), leaveTask: true)
  #expect(replies.lock.withLock { replies.notifications } > 0)
  #expect(store.contextOperation == nil); #expect(store.taskTitle == "a")
  #expect(store.taskContext.identity != identity)
  await store.taskContext.refresh()
  #expect(replies.lock.withLock { replies.contextScopes.contains("repo") })
  _ = changes
}

@Test @MainActor func sourceDriftAcrossAnySiblingRequiresNewPlanAndConsistentRecovery() async throws {
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  let op = try decoder.decode(WorkbenchOperation.self, from: JSONSerialization.data(withJSONObject: operationJSON(drift: true)))
  #expect(op.requiresNewPlan); #expect(op.canRetry)
  let replies = ScopedContextReplies(); replies.preparationState = "drift"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  await store.operate("retry_operation", op: op)
  #expect(store.showTaskSheet); #expect(store.recoveryTaskID == "task")
  #expect(store.nextTaskSlug(String(repeating: "a", count: 64)).count <= 64)
}

@Test @MainActor func dirtyContextActionsExplainWhyTheyDoNotWriteOrCopy() async throws {
  let replies = Replies(); let server = try TestService { replies.respond($0) }
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space", location: .init(repoId: "a"), contextOperationID: nil, operation: nil, title: "folder\n## forged observations")
  await model.refresh(); model.draft?.notes = "unsaved"
  #expect(await model.handoff() == nil); #expect(model.message?.contains("먼저 저장") == true)
  #expect(!(await model.record(kind: "human_report", verdict: "passed", command: "", note: "report", at: model.identity)))
  #expect(model.draft?.notes == "unsaved"); #expect(model.message?.contains("먼저 저장") == true)
  model.reloadDraft()
  let handoff = try #require(await model.handoff())
  #expect(!handoff.hasPrefix("# folder\n##")); #expect(handoff.contains("\\n## forged"))
}

// Model the service's distinct Task/repo scopes and revision CAS. Both start at
// revision 7 so dropping context_op_id would succeed and corrupt repo data.
private final class ScopedContextReplies: @unchecked Sendable {
  struct Context {
    var revision = 7
    var purpose: String
    var notes = ""
    var json: [String: Any] {
      ["context": ["revision": revision, "purpose": purpose, "criteria": [],
        "references": [], "notes": notes, "requirements_hash": "goal-\(revision)"],
       "verifications": []]
    }
  }
  struct Request { let method: String; let scope: String; let target: String? }
  let lock = NSLock()
  private let base = Replies()
  var paginated = false
  var lookupFails = false
  var listFails = false
  var holdList = false
  var holdListCall: Int?
  var listCalls = 0
  var holdTaskDetails = false
  var holdSave = false
  var heldTaskID: String?
  var workspaceID = "space"
  var workspaceRepositoryIDs = ["a"]
  var statusSelections: [WorktreeSelection] = []
  var mutationCalls: [String] = []
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  var statusFails = false
  var preparationState = "ready"
  var preparationCalls: [String] = []
  var lookupIDs: [String] = []
  var requests: [Request] = []
  var contexts = ["repo": Context(purpose: "repository intent"), "op": Context(purpose: "Task intent")]
  init() { base.diffFails = false }
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    let hold = lock.withLock {
      if method == "list_operations" {
        listCalls += 1
        if holdList || holdListCall == listCalls { holdList = false; return true }
      }
      if method == "get_task", holdTaskDetails {
        holdTaskDetails = false; heldTaskID = params["task_id"] as? String; return true
      }
      if method == "save_task_context", holdSave { holdSave = false; return true }
      return false
    }
    if hold { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
    let specialized: [String: Any]? = lock.withLock {
      var result: Any
      switch method {
      case "list_workspaces":
        result = [["schema_version": 1, "id": workspaceID, "repositories": workspaceRepositoryIDs.map {
          ["id": $0, "path": $0 == "a" ? "/tmp/synthetic" : "/tmp/synthetic-\($0)"]
        }, "groups": []]]
      case "list_operations":
        if listFails { return ["schema_version": 1, "error": ["code": "list_failed", "message": "synthetic operation list failure"]] }
        result = paginated
          ? (0..<100).map { operationJSON(id: "new-\($0)", taskID: "new-task-\($0)") }
          : [currentOperation()]
      case "get_operation":
        let id = params["op_id"] as? String ?? ""
        lookupIDs.append(id)
        if lookupFails || id != "op" {
          return ["schema_version": 1, "error": ["code": "unknown_operation", "message": "synthetic lookup failure"]]
        }
        result = currentOperation()
      case "retry_operation", "materialize", "cancel_operation":
        preparationCalls.append(method); result = currentOperation()
      case "get_repo_status":
        statusSelections.append(.init(repoId: params["repo_id"] as? String ?? "", opId: params["op_id"] as? String))
        if statusFails { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic status failure"]] }
        return nil
      case "commit", "stage_hunk", "execute_plan", "configure_remote":
        mutationCalls.append(method); return nil
      case "get_task":
        let id = params["task_id"] as? String ?? ""
        result = ["id": id, "operation_id": id == "task" ? "op" : id,
          "request": ["label": "Task \(id)", "group_id": "group", "task_slug": "work"]]
      case "get_task_context", "save_task_context", "run_git_check", "record_verification_report":
        // save_task_context deliberately has no op_id in the real protocol.
        let target = params["op_id"] as? String
        let scope = params["context_op_id"] as? String ?? (method == "save_task_context" ? nil : target) ?? "repo"
        requests.append(Request(method: method, scope: scope, target: target))
        guard var context = contexts[scope] else {
          return ["schema_version": 1, "error": ["code": "unknown_operation", "message": "synthetic scope missing"]]
        }
        if method == "save_task_context" {
          guard params["expected_revision"] as? Int == context.revision else {
            return ["schema_version": 1, "error": ["code": "stale_task_context", "message": "synthetic revision conflict"]]
          }
          context.revision += 1; context.purpose = params["purpose"] as? String ?? ""
          context.notes = params["notes"] as? String ?? ""; contexts[scope] = context
        }
        result = context.json
      default: return nil
      }
      return ["schema_version": 1, "result": result]
    }
    return specialized ?? base.respond(request)
  }
  private func currentOperation() -> [String: Any] {
    if preparationState == "drift" { return operationJSON(drift: true) }
    var op = operationJSON()
    if preparationState != "ready" {
      op["status"] = preparationState
      op["repos"] = (op["repos"] as! [[String: Any]]).map { value in
        var repo = value; repo["state"] = preparationState; return repo
      }
    }
    return op
  }
}

@MainActor private func settleSelection(_ store: WorkbenchStore) async throws {
  for _ in 0..<200 {
    await store.refresh()
    if !store.validatingSelection { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Synthetic selection did not settle")
}

@Test @MainActor func paginatedTaskContextKeepsReadSaveScopeAndOriginalFolderIdentity() async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  #expect(store.taskContext.bundle?.context.purpose == "repository intent")
  let task = try #require(store.operations.first)
  store.selectTask(task); try await settleSelection(store)
  #expect(store.taskContext.bundle?.context.purpose == "Task intent")
  store.taskContext.draft?.purpose = "edited Task intent"
  replies.lock.withLock { replies.paginated = true }
  await store.refresh()
  #expect(store.operations.count == 100); #expect(!store.operations.contains { $0.id == "op" })
  #expect(store.operation?.id == "op"); #expect(store.contextOperation?.id == "op")
  #expect(store.repository != nil); #expect(store.canEdit)
  #expect(store.taskContext.draft?.purpose == "edited Task intent")
  #expect(replies.lock.withLock { replies.lookupIDs.contains("op") })
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.purpose } == "edited Task intent")
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 8)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.purpose } == "repository intent")
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
  let save = try #require(replies.lock.withLock { replies.requests.last { $0.method == "save_task_context" } })
  #expect(save.scope == "op"); #expect(save.target == nil)

  store.select(.init(repoId: "a")); try await settleSelection(store)
  #expect(store.selection?.opId == nil); #expect(store.contextOperation?.id == "op")
  #expect(store.taskContext.bundle?.context.purpose == "edited Task intent")
  let originalRead = try #require(replies.lock.withLock { replies.requests.last { $0.method == "get_task_context" } })
  #expect(originalRead.scope == "op"); #expect(originalRead.target == nil)
  store.taskContext.draft?.notes = "shared unsaved Task notes"
  store.select(.init(repoId: "b", opId: "op")); try await settleSelection(store)
  #expect(store.taskContext.draft?.notes == "shared unsaved Task notes")
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.notes } == "shared unsaved Task notes")
  #expect(replies.lock.withLock { replies.contexts["repo"]?.notes } == "")
}

@Test @MainActor func unresolvedTaskMetadataFailsClosedAndRecoversDraftWithoutRepoWrites() async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  store.taskContext.draft?.purpose = "keep this Task draft"
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
  await store.refresh()
  #expect(store.contextOperation?.id == "op"); #expect(!store.taskContext.loaded)
  #expect(store.taskContext.message?.contains("새로고침") == true); #expect(!store.canEdit)
  let requestCount = replies.lock.withLock { replies.requests.count }
  await store.taskContext.save()
  #expect(!(await store.taskContext.record(kind: "human_report", verdict: "passed", command: "", note: "report", at: store.taskContext.identity)))
  #expect(await store.taskContext.handoff() == nil)
  #expect(replies.lock.withLock { replies.requests.count } == requestCount)

  store.select(.init(repoId: "a")); try await settleSelection(store)
  #expect(store.selection?.opId == nil); #expect(store.contextOperation?.id == "op")
  #expect(store.canEdit); #expect(!store.taskContext.loaded)
  #expect(store.taskContext.draft?.purpose == "keep this Task draft")
  // Reconnect also drops the display metadata cache; the explicit Task ID still
  // cannot turn this original-folder selection into repo context.
  await store.reconnect()
  #expect(!store.taskContext.loaded); #expect(store.taskTitle == "작업 정보 확인 필요")
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == requestCount)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.purpose } == "repository intent")

  replies.lock.withLock { replies.lookupFails = false }
  await store.refresh()
  #expect(store.taskContext.loaded); #expect(store.contextOperation?.id == "op")
  #expect(store.taskContext.draft?.purpose == "keep this Task draft")
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.purpose } == "keep this Task draft")
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
  store.select(.init(repoId: "a"), leaveTask: true)
  await store.taskContext.refresh()
  #expect(store.contextOperation == nil)
  #expect(store.taskContext.bundle?.context.purpose == "repository intent")
}

@Test(arguments: [false, true]) @MainActor
func selectedLookupFailureBlocksContextBeforeUnrelatedTaskDetailsFinish(originalFolder: Bool) async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  if originalFolder { store.select(.init(repoId: "a")); try await settleSelection(store) }
  #expect(store.taskContext.loaded)
  store.taskContext.draft?.notes = "keep this unsaved Task draft"
  let contextRequests = replies.lock.withLock { replies.requests.count }
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true; replies.holdTaskDetails = true }
  let refreshing = Task { await store.refresh() }; try await wait(replies.arrived)
  #expect(replies.lock.withLock { replies.heldTaskID } == "new-task-0")
  #expect(store.contextOperation?.id == "op"); #expect(store.taskInformationLookupFailed)
  #expect(store.contextTaskInformationUnavailable); #expect(!store.taskContext.loaded)
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == contextRequests)
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 7)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
  #expect(store.taskContext.draft?.notes == "keep this unsaved Task draft")
  #expect(store.taskContext.isDirty)
  replies.gate.signal(); await refreshing.value
  #expect(!store.taskContext.loaded)
  #expect(store.taskContext.draft?.notes == "keep this unsaved Task draft")
  replies.lock.withLock { replies.lookupFails = false }
  await store.refresh()
  #expect(!store.contextTaskInformationUnavailable); #expect(store.taskContext.loaded)
  #expect(store.taskContext.draft?.notes == "keep this unsaved Task draft")
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.notes } == "keep this unsaved Task draft")
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 8)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
}

@Test @MainActor func unresolvedSelectedTaskIsLookupFailureRatherThanUnpreparedFolder() async throws {
  let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
  await store.connect() // Drops the pinned cache while retaining the selected Task ID.
  #expect(store.selection?.opId == "op")
  #expect(store.taskInformationUnavailable); #expect(!store.pendingWorktree)
  #expect(store.taskInformationLookupFailed)
  #expect(store.preparationHint == store.taskInformationHint)
  #expect(store.preparationHint.contains("읽지 못했습니다"))
  #expect(store.selectionCheckFailed); #expect(store.validatingSelection); #expect(!store.canEdit)
  #expect(store.error?.contains("폴더 정보를 확인") == true)
  replies.lock.withLock { replies.lookupFails = false }
  await store.refresh()
  #expect(!store.taskInformationUnavailable); #expect(!store.selectionCheckFailed)
  #expect(store.repository != nil); #expect(store.canEdit)
}

@Test @MainActor func rapidDiffNavigationCoalescesBeforeServerAdmission() async throws {
  let replies = Replies(); replies.diffFails = false
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let before = replies.lock.withLock { replies.diffCalls }
  for _ in 0..<40 {
    store.chooseFile("a.swift")
    try await Task.sleep(for: .milliseconds(1))
  }
  for _ in 0..<100 {
    if store.diff?.path == "a.swift" { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(store.diff?.path == "a.swift")
  #expect(replies.lock.withLock { replies.diffCalls } == before + 1)
  await store.refresh(); #expect(store.canEdit); #expect(!store.selectionCheckFailed)
}

@Test @MainActor func firstBranchListIsAvailableWhileInitialHistoryIsStillLoading() async throws {
  let replies = BranchReplies(root: "/tmp/branch-initial-slow-history")
  replies.holdHistory = true
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let model = BranchBrowserModel()
  let loading = Task { await model.load(store) }; try await wait(replies.arrived)
  #expect(model.branches.count == 1); #expect(!model.loading); #expect(model.loadingHistory)
  replies.gate.signal(); await loading.value
  #expect(model.commits.count == 1)
}

@Test @MainActor func restoredTaskShowsLookupProgressBeforeAnyMetadataFailure() async throws {
  let replies = SubmissionReplies(); replies.base.includeTask = true
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  replies.lock.withLock { replies.heldMethod = "list_operations" }; replies.arrived.value = false
  let reconnect = Task { await store.connect() }; try await wait(replies.arrived)
  #expect(store.taskInformationUnavailable); #expect(!store.taskInformationLookupFailed)
  #expect(store.taskInformationTitle == "작업 정보 확인 중…")
  #expect(store.preparationHint.contains("확인하고 있습니다"))
  #expect(!store.preparationHint.contains("읽지 못했습니다"))
  replies.gate.signal(); await reconnect.value
  #expect(!store.taskInformationUnavailable)
}

@Test @MainActor func exampleAutoSelectionClearsRepoContextBeforeTaskRefresh() async throws {
  let replies = ScopedContextReplies(); replies.holdListCall = 2
  let server = try TestService { replies.respond($0) }
  let isolated = URL(fileURLWithPath: "/tmp/river-example-runtime-\(UUID().uuidString)")
  let store = WorkbenchStore(runtime: WorkspaceRuntime(storageDirectory: isolated, runtimeDirectory: isolated))
  let recent = RecentWorkspace(id: UUID(), name: "Example", repositoryPath: "/tmp/synthetic", isExample: true, lastOpened: Date())
  let opening = Task { await store.openWorkspace(message: "Example") { WorkspaceSession(recent: recent, socketPath: server.path) } }
  try await wait(replies.arrived)
  #expect(replies.lock.withLock { replies.listCalls } == 2)
  #expect(store.selection?.opId == "op"); #expect(store.contextOperation?.id == "op")
  #expect(store.validatingSelection); #expect(!store.taskContext.loaded)
  #expect(store.taskContext.bundle == nil)
  let contextRequests = replies.lock.withLock { replies.requests.count }
  store.taskContext.draft?.notes = "Task notes typed while loading"
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == contextRequests)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
  replies.gate.signal(); await opening.value
  #expect(!store.validatingSelection); #expect(store.taskContext.loaded)
  #expect(store.taskContext.bundle?.context.purpose == "Task intent")
  #expect(store.taskContext.draft?.notes == "")
  store.taskContext.draft?.notes = "Task notes after loading"
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.contexts["op"]?.notes } == "Task notes after loading")
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 8)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.revision } == 7)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.notes } == "")
  let save = try #require(replies.lock.withLock { replies.requests.last { $0.method == "save_task_context" } })
  #expect(save.scope == "op"); #expect(save.target == nil)
}

@Test @MainActor func failedWorkspaceHandshakeKeepsCommittedIdentityClientAndDrafts() async throws {
  let first = SubmissionReplies(); first.base.diffFails = false
  let second = SubmissionReplies(); second.handshakeFails = true; second.heldMethod = "list_workspaces"
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let isolated = URL(fileURLWithPath: "/tmp/river-store-runtime-\(UUID().uuidString)")
  let store = WorkbenchStore(runtime: WorkspaceRuntime(storageDirectory: isolated, runtimeDirectory: isolated))
  let recentA = RecentWorkspace(id: UUID(), name: "Project A", repositoryPath: "/tmp/project-a", isExample: false, lastOpened: Date())
  let recentB = RecentWorkspace(id: UUID(), name: "Project B", repositoryPath: "/tmp/project-b", isExample: false, lastOpened: Date())
  await store.openWorkspace(message: "A") { WorkspaceSession(recent: recentA, socketPath: serverA.path) }
  store.commitMessage = "A commit draft"; store.taskContext.draft?.purpose = "A purpose draft"
  let contextIdentity = store.taskContext.identity
  let sheetIdentity = store.workspaceSession
  let attempt = Task { await store.openWorkspace(message: "B") { WorkspaceSession(recent: recentB, socketPath: serverB.path) } }
  try await wait(second.arrived)
  #expect(store.workspaceTitle == "Project A"); #expect(store.socketPath == serverA.path)
  #expect(!store.canEdit)
  await store.commit()
  #expect(first.lock.withLock { first.commitCalls } == 0)
  second.gate.signal(); await attempt.value
  #expect(store.workspaceTitle == "Project A"); #expect(store.socketPath == serverA.path)
  #expect(store.workspaceSession == sheetIdentity); #expect(store.taskContext.identity == contextIdentity)
  #expect(store.canEdit); #expect(store.commitMessage == "A commit draft")
  #expect(store.taskContext.draft?.purpose == "A purpose draft")
  // A directly edited developer socket must never authorize writes using client A.
  store.socketPath = serverB.path
  #expect(!store.canEdit); await store.commit()
  second.lock.withLock { second.heldMethod = "" }
  await store.connect()
  #expect(store.socketPath == serverA.path); #expect(store.workspaceTitle == "Project A")
  #expect(first.lock.withLock { first.commitCalls } == 0)
  #expect(second.lock.withLock { second.commitCalls } == 0)
  #expect(store.commitMessage == "A commit draft")
  await store.commit()
  #expect(first.lock.withLock { first.commitCalls } == 1)
  #expect(second.lock.withLock { second.commitCalls } == 0)
}

@Test @MainActor func mutableDeveloperSocketCannotRebindInFlightHandshake() async throws {
  let first = SubmissionReplies(); let second = SubmissionReplies(); second.heldMethod = "list_workspaces"
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  store.commitMessage = "A draft"
  let sheetIdentity = store.workspaceSession
  store.socketPath = serverB.path
  let connection = Task { await store.connect() }; try await wait(second.arrived)
  store.socketPath = "/tmp/never-connect-this.sock"
  second.gate.signal(); await connection.value
  #expect(store.workspaceSession == sheetIdentity); #expect(store.commitMessage == "A draft")
  #expect(!store.canEdit); await store.commit()
  #expect(first.lock.withLock { first.commitCalls } == 0)
  #expect(second.lock.withLock { second.commitCalls } == 0)
  store.socketPath = serverA.path
  #expect(store.canEdit)
}

@Test @MainActor func unresolvedOperationDisablesEveryPreparationPathInOriginalFolder() async throws {
  for state in ["waiting_for_worktree", "failed", "drift"] {
    let replies = ScopedContextReplies(); replies.preparationState = state
    let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    let op = try #require(store.operations.first)
    store.selectTask(op); try await settleSelection(store)
    store.select(.init(repoId: "a")); try await settleSelection(store)
    let before = store.preparationEligibility(for: op.id)
    #expect(before.materialize || before.retry || before.recovery)
    store.taskContext.draft?.notes = "retain notes"
    replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
    await store.refresh()
    #expect(store.selection?.opId == nil); #expect(store.contextOperation?.id == op.id)
    #expect(store.contextTaskInformationUnavailable); #expect(store.taskInformationLookupFailed)
    #expect(store.taskTitle == "작업 정보 확인 필요")
    let blocked = store.preparationEligibility(for: op.id)
    #expect(!blocked.materialize && !blocked.retry && !blocked.recovery)
    await store.operate("materialize", op: op); await store.operate("retry_operation", op: op)
    store.beginRecovery(op)
    #expect(!store.showTaskSheet); #expect(store.recoveryTaskID == nil)
    #expect(replies.lock.withLock { replies.preparationCalls.isEmpty })
    #expect(store.taskContext.draft?.notes == "retain notes")
    replies.lock.withLock { replies.lookupFails = false }
    await store.refresh()
    let restored = store.preparationEligibility(for: op.id)
    #expect(restored.materialize || restored.retry || restored.recovery)
    #expect(store.taskContext.loaded); #expect(store.taskContext.draft?.notes == "retain notes")
  }
}

@Test @MainActor func listFailureMarksTaskContextFailedAndStatusFailureDoesNot() async throws {
  for originalFolder in [false, true] {
    let replies = ScopedContextReplies(); let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
    if originalFolder { store.select(.init(repoId: "a")); try await settleSelection(store) }
    store.taskContext.draft?.purpose = "retain purpose"; store.commitMessage = "retain commit"
    replies.lock.withLock { replies.listFails = true }
    await store.refresh()
    #expect(store.taskInformationLookupFailed); #expect(store.contextTaskInformationUnavailable)
    #expect(store.taskInformationTitle == "작업 정보 확인 필요"); #expect(!store.taskContext.loaded)
    let calls = replies.lock.withLock { replies.requests.count }
    await store.taskContext.save()
    #expect(replies.lock.withLock { replies.requests.count } == calls)
    #expect(store.selectionCheckFailed); #expect(!store.canEdit)
    // Reconnect clears summaries before list failure; this must also be failed, not checking.
    await store.connect()
    #expect(store.taskInformationLookupFailed); #expect(store.taskTitle == "작업 정보 확인 필요")
    replies.lock.withLock { replies.listFails = false }
    await store.refresh()
    #expect(!store.contextTaskInformationUnavailable); #expect(store.taskContext.loaded)
    #expect(store.taskContext.draft?.purpose == "retain purpose"); #expect(store.commitMessage == "retain commit")
    replies.lock.withLock { replies.statusFails = true }
    await store.refresh()
    #expect(!store.taskInformationLookupFailed); #expect(!store.contextTaskInformationUnavailable)
    #expect(store.taskContext.loaded); #expect(store.selectionCheckFailed)
  }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func unresolvedRunningOperationStillAllowsExplicitCancellation(reconnect: Bool, pinned: Bool) async throws {
  let replies = ScopedContextReplies(); replies.preparationState = "running"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let op = try #require(store.operations.first)
  store.selectTask(op); try await settleSelection(store)
  if pinned {
    replies.lock.withLock { replies.paginated = true }
    await store.refresh()
    #expect(!store.operations.contains { $0.id == op.id })
    #expect(store.contextOperation?.id == op.id)
  }
  replies.lock.withLock { replies.listFails = true }
  if reconnect { await store.connect() } else { await store.refresh() }
  let eligibility = store.preparationEligibility(for: op.id)
  #expect(store.contextOperation?.id == op.id); #expect(store.hasRunningOperation)
  #expect(store.taskInformationUnavailable); #expect(!store.canEdit); #expect(!store.taskContext.loaded)
  #expect(eligibility.cancel); #expect(!eligibility.retry && !eligibility.materialize && !eligibility.recovery)
  await store.operate("cancel_operation", op: op)
  #expect(replies.lock.withLock { replies.preparationCalls } == ["cancel_operation"])
  replies.lock.withLock { replies.listFails = false; replies.preparationState = "ready" }
  await store.refresh()
  #expect(!store.preparationEligibility(for: op.id).cancel); #expect(!store.hasRunningOperation)
  #expect(!store.taskInformationUnavailable); #expect(store.taskContext.loaded); #expect(store.canEdit)
}

@Test(arguments: [false, true]) @MainActor
func reconnectBlocksRetainedTaskContextBeforeOperationMetadataArrives(originalFolder: Bool) async throws {
  let replies = ScopedContextReplies(); replies.preparationState = "running"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let op = try #require(store.operations.first)
  store.selectTask(op); try await settleSelection(store)
  if originalFolder { store.select(.init(repoId: "a")); try await settleSelection(store) }
  store.taskContext.draft?.notes = "retain reconnect notes"
  let contextRequests = replies.lock.withLock { replies.requests.count }
  replies.lock.withLock { replies.holdList = true; replies.listFails = true }
  let reconnect = Task { await store.connect() }; try await wait(replies.arrived)
  #expect(store.contextOperation?.id == op.id); #expect(store.contextTaskInformationUnavailable)
  #expect(!store.taskContext.loaded); #expect(!store.canEdit)
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == contextRequests)
  replies.gate.signal(); await reconnect.value
  let eligibility = store.preparationEligibility(for: op.id)
  #expect(eligibility.cancel); #expect(!eligibility.materialize && !eligibility.retry && !eligibility.recovery)
  #expect(store.taskInformationLookupFailed); #expect(!store.canEdit); #expect(!store.taskContext.loaded)
  await store.operate("materialize", op: op); await store.operate("retry_operation", op: op)
  store.beginRecovery(op); await store.taskContext.save()
  #expect(replies.lock.withLock { replies.preparationCalls.isEmpty })
  #expect(replies.lock.withLock { replies.requests.count } == contextRequests)
  #expect(!store.showTaskSheet); #expect(store.recoveryTaskID == nil)
  #expect(store.taskContext.draft?.notes == "retain reconnect notes")
  replies.lock.withLock { replies.listFails = false; replies.preparationState = "ready" }
  await store.refresh()
  #expect(!store.preparationEligibility(for: op.id).cancel); #expect(!store.hasRunningOperation)
  #expect(store.taskContext.loaded); #expect(store.canEdit)
  #expect(store.taskContext.draft?.notes == "retain reconnect notes")
}

@Test(arguments: [false, true]) @MainActor
func reconnectCancellationMetadataDoesNotCrossWorkspaces(sameSocket: Bool) async throws {
  let first = ScopedContextReplies(); first.preparationState = "running"
  let second = ScopedContextReplies(); second.listFails = true
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  let op = try #require(store.operations.first)
  store.selectTask(op); try await settleSelection(store)
  first.lock.withLock { first.paginated = true }
  await store.refresh() // The running target is now held only by the selected Task pin.
  #expect(!store.operations.contains { $0.id == op.id }); #expect(store.contextOperation?.id == op.id)
  first.lock.withLock { first.listFails = true; if sameSocket { first.workspaceID = "other-space" } }
  if !sameSocket { store.socketPath = serverB.path }
  await store.connect()
  #expect(store.operations.isEmpty); #expect(store.contextOperation == nil); #expect(!store.hasRunningOperation)
  #expect(!store.preparationEligibility(for: op.id).cancel); #expect(!store.canEdit)
  await store.operate("cancel_operation", op: op)
  #expect(first.lock.withLock { first.preparationCalls.isEmpty })
  #expect(second.lock.withLock { second.preparationCalls.isEmpty })

  first.lock.withLock { first.workspaceID = "space" }
  store.socketPath = serverA.path; await store.connect()
  #expect(store.selection?.opId == op.id); #expect(store.contextTaskInformationUnavailable)
  #expect(store.contextOperation == nil); #expect(!store.hasRunningOperation)
  #expect(!store.preparationEligibility(for: op.id).cancel)
  await store.operate("cancel_operation", op: op)
  #expect(first.lock.withLock { first.preparationCalls.isEmpty })
}

@Test @MainActor func submissionTransportAndDecodeFailuresKeepOriginWarningAcrossSwitches() async throws {
  for failure in ["disconnect", "decode"] {
    let first = SubmissionReplies(); first.heldMethod = "execute_plan"; first.executeFailure = failure
    let second = SubmissionReplies()
    let serverA = try TestService { request in
      if request["method"] as? String == "execute_plan", failure == "disconnect" {
        _ = first.respond(request); return nil // Request accepted, connection lost before response.
      }
      return first.respond(request)
    }
    let serverB = try TestService { second.respond($0) }
    let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
    let plan = try await store.planTask(group: "group", label: "A", slug: "a", mode: "materialize")
    let submission = Task { try await store.executePlan(plan, key: "once") }
    try await wait(first.arrived)
    store.socketPath = serverB.path; await store.connect()
    first.gate.signal()
    do { try await submission.value; Issue.record("Uncertain submission succeeded") }
    catch UIError.submissionOutcomeUnknown {}
    #expect(store.submissionWarnings.count == 1)
    let warning = try #require(store.submissionWarnings.first)
    #expect(warning.id.hasPrefix(serverA.path)); #expect(warning.workspacePath == "/tmp/synthetic")
    #expect(warning.message.contains("같은 요청을 반복하기 전에"))
    #expect(store.operations.isEmpty); #expect(store.selection?.opId == nil)
    store.error = nil; await store.refresh(); await store.connect()
    #expect(store.submissionWarnings == [warning])
    #expect(first.lock.withLock { first.executeCalls } == 1)
    #expect(second.lock.withLock { second.executeCalls } == 0)
    store.dismissSubmissionWarning(warning.id); #expect(store.submissionWarnings.isEmpty)
  }
}

@Test @MainActor func explicitSubmissionRejectionDoesNotCreateUnknownOutcomeWarning() async throws {
  let replies = SubmissionReplies(); replies.executeFailure = "service"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let plan = try await store.planTask(group: "group", label: "A", slug: "a", mode: "materialize")
  do { try await store.executePlan(plan, key: "rejected"); Issue.record("Expected rejection") }
  catch let failure as ServiceFailure { #expect(failure.code == "preparation_queue_full") }
  #expect(store.submissionWarnings.isEmpty)
  #expect(replies.lock.withLock { replies.executeCalls } == 1)
}

@Test @MainActor func reconnectPreservesSheetIdentityButInvalidatesPlan() async throws {
  let replies = SubmissionReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let sheetIdentity = store.workspaceSession; let planGeneration = store.planSession
  let plan = try await store.planTask(group: "group", label: "typed name", slug: "typed-slug", mode: "branch_only")
  await store.connect()
  #expect(store.workspaceSession == sheetIdentity); #expect(store.planSession != planGeneration)
  do { try await store.executePlan(plan, key: "old"); Issue.record("Stale plan executed") }
  catch UIError.planInvalidated {}
  #expect(replies.lock.withLock { replies.executeCalls } == 0)
}

@Test @MainActor func manualRefreshReloadsDiffWithIdenticalGitSnapshotAndWaitsForPolling() async throws {
  let replies = SubmissionReplies(); replies.base.diffFails = false
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.chooseStaged(true)
  for _ in 0..<100 { if store.diff != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
  #expect(store.diff?.hunks.count == 1)
  let before = replies.base.lock.withLock { replies.base.diffCalls }
  replies.lock.withLock { replies.diffIsBinary = true }
  await store.refresh()
  #expect(replies.base.lock.withLock { replies.base.diffCalls } == before)
  #expect(store.diff?.hunks.count == 1)
  replies.lock.withLock { replies.heldMethod = "list_operations" }
  let polling = Task { await store.refresh() }; try await wait(replies.arrived)
  let manual = Task { await store.refresh(forceDiff: true) }
  await Task.yield()
  replies.lock.withLock { replies.heldMethod = "" }; replies.gate.signal()
  await polling.value; await manual.value
  #expect(store.repository?.snapshotHash == "code")
  #expect(store.diff?.hunks.isEmpty == true); #expect(store.diff?.text == "Binary files differ")
  #expect(replies.base.lock.withLock { replies.base.diffCalls } == before + 1)
}

private final class StashReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  var deleted = false
  init() { base.diffFails = false }
  func respond(_ request: [String: Any]) -> [String: Any] {
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    if method == "list_stashes" {
      let entries: [[String: Any]] = lock.withLock { deleted ? [] : [
        ["oid": "stash-oid", "selector": "stash@{0}", "subject": "saved review", "timestamp": "1"],
      ] }
      return ["schema_version": 1, "result": entries]
    }
    if method == "get_stash" {
      return ["schema_version": 1, "result": ["oid": "stash-oid", "files": [
        ["path": "stash.swift", "index": "M", "worktree": " "],
      ]]]
    }
    var reply = base.respond(request)
    if method == "get_repo_status", var status = reply["result"] as? [String: Any] {
      status["files"] = [["path": "a.swift", "index": "M", "worktree": "M"],
                         ["path": "b.swift", "index": "M", "worktree": " "]]
      reply["result"] = status
    }
    if method == "get_diff" || method == "get_stash_diff" {
      reply = base.respond(["method": "get_diff", "params": params])
      var diff = reply["result"] as! [String: Any]
      diff["path"] = params["path"] as? String ?? ""
      diff["staged"] = method == "get_diff" && (params["staged"] as? Bool ?? false)
      reply["result"] = diff
    }
    return reply
  }
}

@Test(arguments: ["return", "deleted", "reconnect", "navigation"]) @MainActor
func stashReviewRestoresPreviousStagedFile(exit: String) async throws {
  let replies = StashReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.staged = true; store.selectedFile = "b.swift"; await store.refresh(forceDiff: true)
  let id = try #require(store.currentReviewID)
  let diff = try #require(store.diff)
  store.markCurrentFileRead(); store.rememberReviewOffset(240, content: diff.contentIdentity, at: id)
  store.chooseStash(try #require(store.stashes.first))
  #expect(!store.staged)
  await store.refresh(forceDiff: true)
  #expect(store.isViewingStash)
  if exit == "deleted" {
    replies.lock.withLock { replies.deleted = true }; await store.refresh()
  } else {
    if exit == "reconnect" { await store.connect() }
    if exit == "navigation" {
      store.select(.init(repoId: "b")); try await settleSelection(store)
      store.select(.init(repoId: "a")); try await settleSelection(store)
    }
    #expect(store.isViewingStash); #expect(!store.staged)
    store.showWorkingChanges()
  }
  #expect(!store.isViewingStash); #expect(store.staged); #expect(store.selectedFile == "b.swift")
  #expect(store.currentReviewID == id)
  await store.refresh(forceDiff: true)
  #expect(store.diff?.path == "b.swift"); #expect(store.diff?.staged == true)
  #expect(store.currentReadingState == .reviewed); #expect(store.currentReviewScrollOffset == 240)
}

private final class RemoteReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  var hash = "remote-1"
  var failure = ""
  var holdRead = false
  var holdWrite = false
  var snapshot = "code"
  var calls: [(String, [String: Any])] = []
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  func state() -> [String: Any] {
    ["state_hash": hash, "repository_path": "/tmp/synthetic", "branch": "refs/heads/main", "head": "head", "clean": true,
     "remotes": [["name": "origin", "fetch_url": "https://gitlab.example/team/repo.git", "push_url": "https://gitlab.example/team/repo.git", "supported": true,
                  "branches": [["name": "main", "oid": "head"]]]], "upstream_remote": "origin", "upstream_branch": "main", "ahead": 1, "behind": 0]
  }
  func respond(_ request: [String: Any]) -> [String: Any]? {
    let method = request["method"] as? String ?? ""
    guard method == "get_remote_state" || method.hasSuffix("_remote") else {
      var reply = base.respond(request)
      if method == "get_repo_status", var status = reply["result"] as? [String: Any] {
        status["snapshot_hash"] = lock.withLock { snapshot }; reply["result"] = status
      }
      return reply
    }
    let captured = lock.withLock { () -> ([String: Any], Bool, String) in
      calls.append((method, request["params"] as? [String: Any] ?? [:]))
      let held = method == "get_remote_state" ? holdRead : holdWrite
      return (state(), held, failure)
    }
    if captured.1 { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
    if method == "get_remote_state" { return ["schema_version": 1, "result": captured.0] }
    switch captured.2 {
    case "disconnect": return nil
    case "decode": return ["schema_version": 1, "result": ["bad": true]]
    case "reject": return ["schema_version": 1, "error": ["code": "stale_remote_state", "message": "state changed"]]
    case "unknown": return ["schema_version": 1, "error": ["code": "remote_outcome_unknown", "message": "connection lost"]]
    default: return ["schema_version": 1, "result": ["state": captured.0, "refresh_required": false, "message": "Fetch 완료"]]
    }
  }
  var writeCount: Int { lock.withLock { calls.filter { $0.0 != "get_remote_state" }.count } }
}

@Test(arguments: ["commit", "execute_plan", "configure_remote"]) @MainActor
func oversizedUnsentWritesKeepDraftAndDoNotWarnOfUnknownOutcome(method: String) async throws {
  let git = GitMutationReplies(); let submission = SubmissionReplies(); let remote = RemoteReplies()
  let server = try TestService { request in
    let name = request["method"] as? String ?? ""
    if name == "plan_task" || name == "execute_plan" { return submission.respond(request) }
    if name == "get_remote_state" || name.hasSuffix("_remote") { return remote.respond(request) }
    return git.respond(request)
  }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  #expect(store.canEdit)
  let oversized = String(repeating: "x", count: 1024 * 1024)
  store.commitMessage = oversized
  switch method {
  case "commit":
    await store.commit()
    #expect(store.error?.contains("요청 크기 제한") == true)
  case "execute_plan":
    let plan = try await store.planTask(group: "group", label: "Task", slug: "task", mode: "isolated")
    do { try await store.executePlan(plan, key: oversized); Issue.record("Oversized plan submission succeeded") }
    catch TransportFailure.oversizedRequest {}
  default:
    await store.loadRemoteState()
    let plan = try store.remotePlan(.configure, remote: "origin")
    do {
      try await store.executeRemote(plan, configuration: "update", url: oversized)
      Issue.record("Oversized remote configuration succeeded")
    } catch TransportFailure.oversizedRequest {}
    #expect(store.remoteError?.contains("요청 크기 제한") == true)
  }
  #expect(store.submissionWarnings.isEmpty)
  #expect(store.commitMessage == oversized)
  #expect(store.repository?.snapshot.head == "head-1")
  #expect(git.writeCount == 0); #expect(submission.lock.withLock { submission.executeCalls } == 0)
  #expect(remote.writeCount == 0)
}

@Test @MainActor func remoteActionsStayDisabledUntilCurrentSnapshotHasRemoteMetadata() async throws {
  let replies = RemoteReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  #expect(!store.canUseRemotes)
  await store.loadRemoteState(); #expect(store.canUseRemotes)
  let plan = try store.remotePlan(.push, remote: "origin", branch: "main")
  replies.lock.withLock { replies.snapshot = "code-2" }
  await store.refresh()
  #expect(!store.canUseRemotes)
  do { try await store.executeRemote(plan); Issue.record("Stale snapshot allowed remote mutation") }
  catch UIError.staleRemote { store.reportRemote(UIError.staleRemote) }
  #expect(store.remoteError?.contains("원격 정보") == true); #expect(replies.writeCount == 0)
  await store.loadRemoteState(); #expect(store.canUseRemotes)
}

@Test @MainActor func remoteRequestsUseActualFolderScopeAndPreserveReviewDrafts() async throws {
  let replies = RemoteReplies(); replies.base.includeTask = true; replies.base.diffFails = false
  let server = try TestService { replies.respond($0) }; let store = WorkbenchStore(socketPath: server.path)
  await store.connect(); store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  await store.loadRemoteState()
  let taskPlan = try store.remotePlan(.fetch, remote: "origin")
  try await store.executeRemote(taskPlan)
  #expect(replies.lock.withLock { replies.calls.first(where: { $0.0 == "fetch_remote" })?.1["op_id"] as? String } == "op")
  store.select(.init(repoId: "a")); try await settleSelection(store)
  #expect(store.contextOperation != nil); #expect(store.selection?.opId == nil)
  store.commitMessage = "retain my commit draft"
  let file = store.selectedFile; let staged = store.staged
  await store.loadRemoteState()
  let originalPlan = try store.remotePlan(.fetch, remote: "origin")
  try await store.executeRemote(originalPlan)
  #expect(replies.lock.withLock { replies.calls.last(where: { $0.0 == "fetch_remote" })?.1["op_id"] } == nil)
  #expect(store.commitMessage == "retain my commit draft"); #expect(store.selectedFile == file); #expect(store.staged == staged)
  #expect(store.selection?.opId == nil); #expect(store.remoteMessage == "Fetch 완료")
}

@Test @MainActor func remoteConfirmationsCannotCrossConnectionsOrDisplayedState() async throws {
  let replies = RemoteReplies(); let server = try TestService { replies.respond($0) }
  let other = RemoteReplies(); let serverB = try TestService { other.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect(); await store.loadRemoteState()
  let plan = try store.remotePlan(.push, remote: "origin", branch: "main")
  replies.lock.withLock { replies.hash = "remote-2" }; await store.loadRemoteState()
  do { try await store.executeRemote(plan); Issue.record("Stale remote state accepted") } catch UIError.staleRemote {}
  #expect(replies.writeCount == 0)
  let changed = try store.remotePlan(.push, remote: "origin", branch: "main")
  await store.connect(); await store.loadRemoteState() // Same-workspace reconnect invalidates consent.
  do { try await store.executeRemote(changed); Issue.record("Old connection accepted") } catch UIError.staleRemote {}
  #expect(replies.writeCount == 0)
  let reconnected = try store.remotePlan(.pull, remote: "origin", branch: "main")
  store.socketPath = serverB.path; await store.connect()
  do { try await store.executeRemote(reconnected); Issue.record("Foreign project accepted") } catch UIError.staleRemote {}
  #expect(replies.writeCount == 0); #expect(other.writeCount == 0)
}

@Test @MainActor func lateRemoteReadsCannotPublishIntoNewWorkspace() async throws {
  let first = RemoteReplies(); let second = RemoteReplies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  first.lock.withLock { first.holdRead = true }
  let read = Task { await store.loadRemoteState() }; try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  second.lock.withLock { second.hash = "second" }; await store.loadRemoteState()
  first.gate.signal(); await read.value
  #expect(store.remoteState?.stateHash == "second"); #expect(!store.remoteLoading)
}

@Test(arguments: ["disconnect", "decode", "unknown", "reject"]) @MainActor
func remoteUnknownOutcomeIsOriginBoundAndExplicitRejectionIsKnown(failure: String) async throws {
  let first = RemoteReplies(); first.failure = failure; first.holdWrite = true
  let second = RemoteReplies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect(); await store.loadRemoteState()
  let plan = try store.remotePlan(.push, remote: "origin", branch: "main")
  let write = Task { try await store.executeRemote(plan) }; try await wait(first.arrived)
  #expect(store.remoteBusy)
  store.socketPath = serverB.path; await store.connect(); #expect(!store.remoteBusy)
  first.gate.signal()
  do { try await write.value; Issue.record("Failed remote write succeeded") }
  catch { if failure == "reject" { #expect(error is ServiceFailure) } else { #expect(error is UIError) } }
  #expect(store.remoteError == nil)
  #expect(store.submissionWarnings.count == (failure == "reject" ? 0 : 1))
  if let warning = store.submissionWarnings.first {
    #expect(warning.id.hasPrefix(serverA.path)); #expect(warning.workspacePath == "/tmp/synthetic")
    #expect(warning.message.contains("Push · origin / main"))
  }
  await store.refresh(); await store.loadRemoteState()
  #expect(first.writeCount == 1); #expect(second.writeCount == 0)
}

@Test(arguments: ["handshake", "recent-read"]) @MainActor
func completedCloneKeepsKnownOutcomeWhenFollowUpReadsFail(phase: String) async throws {
  let replies = Replies(); let server = try TestService { replies.respond($0) }
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-clone-handshake-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-clone-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: sockets) }
  let helper = folder.appendingPathComponent("helper")
  let script = """
  #!/usr/bin/python3
  import sys,json,pathlib,socket,os
  if sys.argv[1]=='clone':
      pathlib.Path(sys.argv[3]).mkdir();print(json.dumps({'path':sys.argv[3]}));sys.exit(0)
  if sys.argv[1]=='inspect':
      print(json.dumps({'id':'new-repo','path':sys.argv[2]}));sys.exit(0)
  if sys.argv[1]=='workspace':
      pathlib.Path(sys.argv[3]).write_text('{}');sys.exit(0)
  recent_failure=\(phase == "recent-read" ? "True" : "False")
  recent_file=pathlib.Path(sys.argv[2]).parents[2]/'recent.json'
  handshakes=0
  listener=socket.socket(socket.AF_UNIX);listener.bind(sys.argv[-1]);listener.listen(16)
  while True:
      peer,_=listener.accept()
      request=json.loads(peer.makefile('rb').readline());stopping=request['method']=='shutdown_if_idle'
      if request['method']=='list_workspaces':
          handshakes+=1
          if recent_failure and handshakes==2:
              recent_file.unlink();recent_file.mkdir()
          result=[{'schema_version':1,'id':'clone-project','repositories':[{'id':'new-repo','path':'/tmp/clone-synthetic'}],'groups':[]}] if recent_failure else []
          response={'schema_version':1,'result':result}
      elif stopping:response={'schema_version':1,'result':{'stopping':True}}
      else:response={'schema_version':1,'error':{'code':'git_failed','message':'optional display read failed'}}
      peer.sendall((json.dumps(response)+'\\n').encode());peer.close()
      if stopping:break
  listener.close();os.unlink(sys.argv[-1])
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let runtime = WorkspaceRuntime(storageDirectory: folder.appendingPathComponent("data"), runtimeDirectory: sockets, helperURL: helper)
  let store = WorkbenchStore(socketPath: server.path, runtime: runtime)
  await store.connect(); let session = store.workspaceSession; let selection = store.selection
  store.commitMessage = "keep this draft"
  let destination = folder.appendingPathComponent("new-repo")
  if phase == "handshake" {
    do { try await store.cloneRepository(url: "https://gitlab.example/team/repo.git", destination: destination); Issue.record("Expected final handshake failure") }
    catch StartupFailure.cloneCreated(let path) { #expect(path == destination.path) }
    #expect(store.workspaceSession == session); #expect(store.socketPath == server.path)
    #expect(store.selection == selection); #expect(store.commitMessage == "keep this draft")
  } else {
    try await store.cloneRepository(url: "https://gitlab.example/team/repo.git", destination: destination)
    #expect(store.workspace?.id == "clone-project"); #expect(store.workspaceSession != session)
    #expect(store.selection?.repoId == "new-repo")
    #expect(store.error?.contains("복제와 프로젝트 열기는 완료했습니다") == true)
    #expect(store.error?.contains("최근 프로젝트 목록") == true)
  }
  #expect(FileManager.default.fileExists(atPath: destination.path)); #expect(!store.busy)
  #expect(store.submissionWarnings.isEmpty)
  await runtime.stopIdleServices()
}

// Use real production views and AppKit dispatch: opacity and hit-testing alone
// do not unregister SwiftUI keyboard shortcuts or resign a native text editor.
@Suite(.serialized) @MainActor
struct FocusedDockKeyboardRegressionTests {
  @Test func restoringLayoutKeepsVisibleCommitEditorResponderAndTyping() async throws {
    let replies = GitMutationReplies()
    let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    let suite = "river-dock-restore-editor-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = LayoutPreferences(defaults: defaults); layout.apply(.balanced)
    store.commitMessage = "visible enlarged commit draft"
    let (window, host) = mount(store: store, layout: layout, defaults: defaults)
    defer { window.close() }
    try await settle(host)
    layout.focusPane(.commit)
    try await settle(host)
    let editor = try #require(textViews(in: host).first { $0.isEditable && $0.string == store.commitMessage })
    #expect(window.makeFirstResponder(editor))
    window.sendEvent(try key(window, characters: "x", code: 7))
    try await settle(host)
    let draftBeforeRestore = store.commitMessage
    #expect(draftBeforeRestore != "visible enlarged commit draft")
    #expect(window.firstResponder === editor)

    layout.restorePaneLayout()
    try await settle(host)
    #expect(layout.focusedPane == nil)
    #expect(window.firstResponder === editor)
    #expect(textViews(in: host).contains { $0 === editor })
    window.sendEvent(try key(window, characters: "y", code: 16))
    try await settle(host)
    #expect(store.commitMessage != draftBeforeRestore)
    #expect(editor.string == store.commitMessage)
    #expect(replies.writeCount == 0)
    withExtendedLifetime(server) {}
  }

  @Test func escapeRestoresFocusedPaneThroughWindowDispatch() async throws {
    let replies = GitMutationReplies()
    let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    let suite = "river-dock-escape-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = LayoutPreferences(defaults: defaults); layout.apply(.balanced)
    store.commitMessage = "Escape must preserve this draft"
    let (window, host) = mount(store: store, layout: layout, defaults: defaults)
    defer { window.close() }
    try await settle(host)
    let configuration = layout.configuration
    let storedConfiguration = defaults.data(forKey: "workbench.layout.v1")
    for _ in 0..<2 {
      layout.focusPane(.diff)
      try await settle(host)
      #expect(layout.focusedPane == .diff)
      window.sendEvent(try key(window, characters: "\u{1b}", code: 53))
      try await settle(host)
      #expect(layout.focusedPane == nil)
      #expect(layout.configuration == configuration)
      #expect(defaults.data(forKey: "workbench.layout.v1") == storedConfiguration)
    }
    #expect(store.commitMessage == "Escape must preserve this draft")
    #expect(replies.writeCount == 0)
    withExtendedLifetime(server) {}
  }

  @Test func hiddenCommitShortcutCannotWriteAndRestoredCommitCan() async throws {
    let replies = GitMutationReplies()
    let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    let suite = "river-dock-shortcut-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = LayoutPreferences(defaults: defaults); layout.apply(.balanced)
    store.commitMessage = "visible commit positive control"
    #expect(store.canEdit); #expect(store.stagedCount == 1)
    let (window, host) = mount(store: store, layout: layout, defaults: defaults)
    defer { window.close() }
    try await settle(host)

    #expect(
      window.performKeyEquivalent(
        with: try key(window, characters: "\r", code: 36, modifiers: .command)))
    try await awaitWrites(1, replies: replies, store: store)
    #expect(replies.writeCount == 1); #expect(store.commitMessage.isEmpty)

    store.commitMessage = "hidden commit must stay a draft"
    layout.focusPane(.diff)
    try await settle(host)
    #expect(
      !window.performKeyEquivalent(
        with: try key(window, characters: "\r", code: 36, modifiers: .command)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(replies.writeCount == 1)
    #expect(store.commitMessage == "hidden commit must stay a draft")
    #expect(store.submissionWarnings.isEmpty)

    layout.restorePaneLayout()
    try await settle(host)
    #expect(
      window.performKeyEquivalent(
        with: try key(window, characters: "\r", code: 36, modifiers: .command)))
    try await awaitWrites(2, replies: replies, store: store)
    #expect(replies.writeCount == 2); #expect(store.commitMessage.isEmpty)
    withExtendedLifetime(server) {}
  }

  @Test func focusingDiffResignsHiddenEditorOnlyInItsOwningWindow() async throws {
    let replies = GitMutationReplies()
    let server = try TestService { replies.respond($0) }
    let store = WorkbenchStore(socketPath: server.path); await store.connect()
    let suite = "river-dock-editor-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = LayoutPreferences(defaults: defaults); layout.apply(.balanced)
    store.commitMessage = "visible editor draft"
    let (window, host) = mount(store: store, layout: layout, defaults: defaults)
    defer { window.close() }
    try await settle(host)
    let editor = try #require(
      textViews(in: host).first { $0.isEditable && $0.string == store.commitMessage })
    #expect(window.makeFirstResponder(editor)); #expect(window.firstResponder === editor)
    window.sendEvent(try key(window, characters: "x", code: 7))
    try await settle(host)
    let visibleDraft = store.commitMessage
    #expect(visibleDraft != "visible editor draft")  // Prove native text input reaches the visible editor.

    let otherEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    otherEditor.string = "another window keeps its responder"
    let otherWindow = NSWindow(
      contentRect: NSRect(x: -19000, y: -19000, width: 300, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    otherWindow.isReleasedWhenClosed = false; otherWindow.contentView = otherEditor
    otherWindow.makeKeyAndOrderFront(nil)
    defer { otherWindow.close() }
    #expect(otherWindow.makeFirstResponder(otherEditor))
    #expect(otherWindow.firstResponder === otherEditor)
    #expect(window.firstResponder === editor)

    layout.focusPane(.diff)
    try await settle(host)
    #expect(window.firstResponder !== editor)
    #expect(otherWindow.firstResponder === otherEditor)
    window.sendEvent(try key(window, characters: "y", code: 16))
    try await settle(host)
    #expect(store.commitMessage == visibleDraft)
    #expect(editor.string == visibleDraft)
    #expect(otherEditor.string == "another window keeps its responder")
    #expect(replies.writeCount == 0)
    withExtendedLifetime(server) {}
  }

  private func mount(store: WorkbenchStore, layout: LayoutPreferences, defaults: UserDefaults)
    -> (NSWindow, NSHostingView<WorkbenchRoot>)
  {
    _ = NSApplication.shared
    let host = NSHostingView(
      rootView: WorkbenchRoot(
        store: store, layout: layout,
        reading: ReadingPreferences(defaults: defaults)))
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil)
    return (window, host)
  }
  private func key(
    _ window: NSWindow, characters: String, code: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: code))
  }
  private func settle(_ host: NSView) async throws {
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(15))
    }
    host.layoutSubtreeIfNeeded()
  }
  private func awaitWrites(_ count: Int, replies: GitMutationReplies, store: WorkbenchStore)
    async throws
  {
    for _ in 0..<200 {
      if replies.writeCount >= count && !store.busy { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Production commit shortcut did not complete its synthetic request")
  }
  private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
  }
}

@Test @MainActor func repositoryNavigationPreservesFolderKindTaskContextAndPerFolderDrafts() async throws {
  let replies = ScopedContextReplies(); replies.workspaceRepositoryIDs = ["a", "b"]
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let task = try #require(store.operations.first)
  store.selectTask(task); try await settleSelection(store)
  store.commitMessage = "task folder a draft"
  store.taskContext.draft?.notes = "shared unsaved Task notes"

  store.select(.init(repoId: "a")); try await settleSelection(store)
  store.commitMessage = "original folder a draft"
  let originalReview = store.currentReviewID
  let readsBeforeSameRepository = replies.lock.withLock { replies.statusSelections.count }
  store.selectRepository("a")
  try await Task.sleep(for: .milliseconds(20))
  #expect(store.selection == WorktreeSelection(repoId: "a"))
  #expect(store.currentReviewID == originalReview)
  #expect(store.commitMessage == "original folder a draft")
  #expect(replies.lock.withLock { replies.statusSelections.count } == readsBeforeSameRepository)

  store.selectRepository("b"); try await settleSelection(store)
  #expect(store.selection == WorktreeSelection(repoId: "b"))
  #expect(store.contextOperation?.id == "op")
  #expect(store.taskContext.draft?.notes == "shared unsaved Task notes")
  #expect(replies.lock.withLock { replies.statusSelections.last } == WorktreeSelection(repoId: "b"))
  #expect(store.commitMessage.isEmpty)
  store.commitMessage = "original folder b draft"
  store.selectRepository("a"); try await settleSelection(store)
  #expect(store.commitMessage == "original folder a draft")

  store.select(.init(repoId: "a", opId: task.id)); try await settleSelection(store)
  #expect(store.commitMessage == "task folder a draft")
  store.selectRepository("b"); try await settleSelection(store)
  #expect(store.selection == WorktreeSelection(repoId: "b", opId: task.id))
  #expect(store.contextOperation?.id == task.id)
  #expect(store.taskContext.draft?.notes == "shared unsaved Task notes")
  #expect(replies.lock.withLock { replies.statusSelections.last } == WorktreeSelection(repoId: "b", opId: task.id))
  #expect(store.commitMessage.isEmpty)
  store.commitMessage = "task folder b draft"
  store.selectRepository("a"); try await settleSelection(store)
  #expect(store.commitMessage == "task folder a draft")
  let taskReview = store.currentReviewID
  let taskReadsBeforeSameRepository = replies.lock.withLock { replies.statusSelections.count }
  store.selectRepository("a")
  try await Task.sleep(for: .milliseconds(20))
  #expect(store.selection == WorktreeSelection(repoId: "a", opId: task.id))
  #expect(store.currentReviewID == taskReview)
  #expect(store.commitMessage == "task folder a draft")
  #expect(replies.lock.withLock { replies.statusSelections.count } == taskReadsBeforeSameRepository)

  store.select(.init(repoId: "a")); try await settleSelection(store)
  store.selectRepository("b"); try await settleSelection(store)
  #expect(store.commitMessage == "original folder b draft")
  store.select(.init(repoId: "b", opId: task.id)); try await settleSelection(store)
  #expect(store.commitMessage == "task folder b draft")
  #expect(store.taskContext.draft?.notes == "shared unsaved Task notes")
  #expect(replies.lock.withLock { replies.mutationCalls.isEmpty })
}

@Test(arguments: [false, true]) @MainActor
func repositoryNavigationPreservesUnresolvedContextAndLeavesKnownNonmemberContext(reconnect: Bool) async throws {
  let replies = ScopedContextReplies(); replies.workspaceRepositoryIDs = ["a", "b", "c"]
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectTask(try #require(store.operations.first)); try await settleSelection(store)
  store.select(.init(repoId: "a")); try await settleSelection(store)
  store.taskContext.draft?.notes = "Task draft must not become repository notes"
  replies.lock.withLock { replies.paginated = true; replies.lookupFails = true }
  await store.refresh()
  if reconnect { await store.connect() } // Also cover unresolved context with no retained operation summary.
  #expect(store.contextTaskInformationUnavailable); #expect(!store.taskContext.loaded)
  let contextRequests = replies.lock.withLock { replies.requests.count }

  store.selectRepository("b"); try await settleSelection(store)
  #expect(store.selection == WorktreeSelection(repoId: "b"))
  #expect(store.contextOperation?.id == (reconnect ? nil : "op"))
  #expect(!store.taskContext.loaded)
  if !reconnect { #expect(store.taskContext.draft?.notes == "Task draft must not become repository notes") }
  await store.taskContext.save()
  #expect(replies.lock.withLock { replies.requests.count } == contextRequests)
  #expect(replies.lock.withLock { replies.contexts["repo"]?.notes } == "")
  #expect(replies.lock.withLock { replies.contexts["op"]?.revision } == 7)

  replies.lock.withLock { replies.paginated = false; replies.lookupFails = false }
  await store.refresh()
  #expect(store.taskContext.loaded)
  #expect(store.taskContext.draft?.notes == "Task draft must not become repository notes")
  store.selectRepository("c"); try await settleSelection(store)
  #expect(store.selection == WorktreeSelection(repoId: "c"))
  #expect(store.contextOperation == nil)
  #expect(store.taskContext.bundle?.context.purpose == "repository intent")
  #expect(store.taskContext.draft?.notes == "")
  #expect(replies.lock.withLock { replies.statusSelections.last } == WorktreeSelection(repoId: "c"))
  #expect(replies.lock.withLock { replies.mutationCalls.isEmpty })
}

@Test @MainActor func updateRestartWaitsForRemoteWriteInPreviousWorkspace() async throws {
  let first = RemoteReplies(); let second = RemoteReplies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect(); await store.loadRemoteState()
  #expect(store.updateRestartBlocker == nil)
  let plan = try store.remotePlan(.fetch, remote: "origin")
  first.lock.withLock { first.holdWrite = true }
  let write = Task { try await store.executeRemote(plan) }; try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  #expect(!store.busy && !store.remoteBusy)
  #expect(store.updateRestartBlocker?.contains("원격 Git 작업") == true)
  first.gate.signal(); try await write.value
  #expect(store.updateRestartBlocker == nil)
}

@Test @MainActor func updateRestartWaitsForContextWriteAfterVisibleScopeReset() async throws {
  let first = Replies(); let second = Replies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  store.taskContext.draft?.purpose = "save in the first workspace"
  first.lock.withLock { first.holdSave = true }
  let write = Task { await store.taskContext.save() }; try await wait(first.arrived)
  #expect(store.taskContext.inFlightWorkCount == 1)
  store.socketPath = serverB.path; await store.connect()
  #expect(!store.taskContext.working)
  #expect(store.updateRestartBlocker?.contains("작업 정보 저장") == true)
  first.gate.signal(); await write.value
  #expect(store.taskContext.inFlightWorkCount == 0)
  #expect(store.updateRestartBlocker == nil)
}

@Test @MainActor func updateRestartRetainsOldWorkspaceTaskUntilDirectLookupConfirmsCompletion() async throws {
  let first = ScopedContextReplies(); first.preparationState = "running"
  let second = Replies()
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  #expect(store.hasRunningOperation && store.updateRestartBlocker != nil)
  store.socketPath = serverB.path; await store.connect()
  #expect(!store.hasRunningOperation)
  #expect(store.updateRestartBlocker?.contains("워크트리 준비") == true)
  await store.refresh()
  #expect(store.updateRestartBlocker != nil)
  first.lock.withLock { first.paginated = true; first.lookupFails = true; first.preparationState = "ready" }
  store.socketPath = serverA.path; await store.connect()
  #expect(!store.hasRunningOperation && store.updateRestartBlocker != nil)
  first.lock.withLock { first.lookupFails = false }
  await store.refresh()
  #expect(first.lock.withLock { first.lookupIDs.contains("op") })
  #expect(store.updateRestartBlocker == nil)
}

@Test @MainActor func updateRestartRequiresInspectionWarningForUnknownWriteWithoutClearingOriginalNotice() async throws {
  let replies = RemoteReplies(); replies.failure = "unknown"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect(); await store.loadRemoteState()
  let plan = try store.remotePlan(.push, remote: "origin", branch: "main")
  do { try await store.executeRemote(plan); Issue.record("Unknown write was reported as success") }
  catch UIError.remoteOutcomeUnknown {}
  #expect(!store.busy && !store.remoteBusy)
  #expect(store.updateRestartBlocker == nil)
  #expect(store.updateRestartWarning?.contains("처리 결과") == true)
  #expect(store.submissionWarnings.count == 1)
  store.dismissSubmissionWarning(try #require(store.submissionWarnings.first).id)
  #expect(store.updateRestartBlocker == nil && store.updateRestartWarning == nil)
}

@Test @MainActor func updateRestartTracksAcceptedTaskSubmissionAcrossWorkspaceSwitch() async throws {
  let first = SubmissionReplies(); first.heldMethod = "execute_plan"
  let second = SubmissionReplies()
  let serverA = try TestService { request in
    var response = first.respond(request)
    if request["method"] as? String == "execute_plan", var operation = response["result"] as? [String: Any] {
      operation["status"] = "running"; response["result"] = operation
    }
    return response
  }
  let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  let plan = try await store.planTask(group: "group", label: "A", slug: "a", mode: "materialize")
  let submit = Task { try await store.executePlan(plan, key: "one-accepted-submission") }
  try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  #expect(!store.busy && !store.hasRunningOperation)
  #expect(store.updateRestartBlocker != nil)
  first.gate.signal()
  do { try await submit.value; Issue.record("Old submission was published in the new workspace") }
  catch UIError.workspaceChangedAfterSubmission {}
  #expect(store.operations.isEmpty)
  #expect(store.updateRestartBlocker?.contains("워크트리 준비") == true)
}

@Test @MainActor func updateRestartRetainsContextUncertaintyAfterSwitchWithoutBlockingForever() async throws {
  let first = Replies(); first.holdSave = true
  let second = Replies()
  let serverA = try TestService { request in
    if request["method"] as? String == "save_task_context" {
      _ = first.respond(request); return nil
    }
    return first.respond(request)
  }
  let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  store.taskContext.draft?.purpose = "uncertain original workspace save"
  let save = Task { await store.taskContext.save() }; try await wait(first.arrived)
  store.socketPath = serverB.path; await store.connect()
  #expect(store.updateRestartBlocker != nil)
  first.gate.signal(); await save.value
  #expect(store.updateRestartBlocker == nil)
  #expect(store.updateRestartWarning?.contains("작업 정보 변경 결과") == true)
  await store.refresh()
  #expect(store.updateRestartWarning != nil)
}

@Test(arguments: ["oversized", "rejected"]) @MainActor
func updateRestartDoesNotInventContextUncertaintyForKnownRejectedWrites(failure: String) async throws {
  let replies = Replies()
  let server = try TestService { request in
    if request["method"] as? String == "save_task_context" {
      return ["schema_version": 1, "error": ["code": "stale_task_context", "message": "known rejection"]]
    }
    return replies.respond(request)
  }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.taskContext.draft?.notes = failure == "oversized" ? String(repeating: "x", count: 2 * 1024 * 1024) : "rejected notes"
  await store.taskContext.save()
  #expect(store.taskContext.message != nil)
  #expect(store.updateRestartBlocker == nil && store.updateRestartWarning == nil)
  #expect(store.taskContext.isDirty)
}

@Test(arguments: ["materialize", "retry_operation"]) @MainActor
func confirmedPreparationReceiptBlocksUpdateWhenFollowingMetadataReadFails(method: String) async throws {
  let first = ScopedContextReplies()
  first.preparationState = method == "materialize" ? "waiting_for_worktree" : "failed"
  let other = Replies()
  let serverA = try TestService { request in
    var response = first.respond(request)
    if request["method"] as? String == method, var op = response["result"] as? [String: Any] {
      op["status"] = "running"; response["result"] = op
      first.lock.withLock { first.listFails = true }
    }
    return response
  }
  let serverB = try TestService { other.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  let operation = try #require(store.operations.first)
  let eligibility = store.preparationEligibility(for: operation.id)
  #expect(method == "materialize" ? eligibility.materialize : eligibility.retry)
  #expect(store.updateRestartBlocker == nil)
  await store.operate(method, op: operation)
  #expect(!store.busy && !store.hasRunningOperation)
  #expect(first.lock.withLock { first.preparationCalls } == [method])
  #expect(store.updateRestartBlocker != nil)
  store.socketPath = serverB.path; await store.connect()
  #expect(store.updateRestartBlocker != nil)
  first.lock.withLock { first.listFails = false; first.preparationState = "ready" }
  await store.refresh()
  #expect(store.updateRestartBlocker != nil)
  store.socketPath = serverA.path; await store.connect()
  #expect(store.updateRestartBlocker == nil)
}

@Test(arguments: ["same-origin", "fifth-hidden-origin"]) @MainActor
func everyUncertainContextWriteChangesConsentIdentityBeyondVisibleOriginPrefix(scenario: String) async throws {
  let replies = Replies()
  let server = try TestService { request in
    if request["method"] as? String == "save_task_context" {
      return ["schema_version": 1, "error": ["code": "write_outcome_unknown", "message": "synthetic uncertain write"]]
    }
    return replies.respond(request)
  }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let client = ServiceClient(socketPath: server.path)
  func write(origin: String) async {
    store.taskContext.configure(
      client: client, workspace: "fixture-" + origin, location: .init(repoId: "a"),
      contextOperationID: nil, operation: nil, title: origin, updateOrigin: origin)
    await store.taskContext.refresh()
    store.taskContext.draft?.notes = "another uncertain change"
    await store.taskContext.save()
  }
  let originalOrigins = scenario == "same-origin" ? ["A"] : ["A", "B", "C", "D"]
  for origin in originalOrigins { await write(origin: origin) }
  let displayed = try #require(store.updateRestartWarning)
  let identity = store.updateRestartConsentIdentity
  let revision = store.taskContext.updateUncertainWriteRevision
  await write(origin: scenario == "same-origin" ? "A" : "Z-hidden-fifth")
  #expect(store.updateRestartBlocker == nil)
  #expect(store.updateRestartWarning == displayed)
  #expect(store.taskContext.updateUncertainWriteRevision == revision + 1)
  #expect(store.updateRestartConsentIdentity != identity)
  #expect(store.taskContext.updateUncertainWriteOrigins.count == (scenario == "same-origin" ? 1 : 5))
}

@Test @MainActor func replacementUnknownSubmissionWithSameDisplayChangesFullConsentIdentity() async throws {
  let replies = RemoteReplies(); replies.failure = "unknown"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  func uncertainPush() async throws {
    await store.loadRemoteState()
    let plan = try store.remotePlan(.push, remote: "origin", branch: "main")
    do { try await store.executeRemote(plan); Issue.record("Expected an uncertain remote reply") }
    catch UIError.remoteOutcomeUnknown {}
  }
  try await uncertainPush()
  let warning = try #require(store.submissionWarnings.first)
  let displayed = store.updateRestartWarning
  let identity = store.updateRestartConsentIdentity
  store.dismissSubmissionWarning(warning.id)
  try await uncertainPush()
  #expect(store.submissionWarnings.count == 1)
  #expect(store.submissionWarnings.first?.id != warning.id)
  #expect(store.updateRestartWarning == displayed)
  #expect(store.updateRestartConsentIdentity != identity)
}

// Keep the real context/store RPC path; only supply evidence absent from the
// older shared fixture. These helpers do not execute or simulate a Git check.
private func requestReceiptJSON(id: String, repo: String = "a", op: String? = "op",
                                verdict: String = "passed", requirements: String = "goal-7") -> [String: Any] {
  ["id": id, "repo_id": repo, "op_id": op as Any? ?? NSNull(),
   "path": "/tmp/synthetic-\(repo)", "branch": "refs/heads/work", "head": "head",
   "snapshot_hash": "code", "after_snapshot_hash": "code", "requirements_hash": requirements,
   "kind": "git_check", "verdict": verdict, "started_at": 1, "finished_at": 2,
   "command": "git diff --check", "note": "", "output": "", "truncated": false]
}

private func requestContextEvidence(_ response: [String: Any], receipts: [[String: Any]]) -> [String: Any] {
  var response = response
  guard var bundle = response["result"] as? [String: Any],
    var context = bundle["context"] as? [String: Any] else { return response }
  context["criteria"] = ["Check the actual feature behavior"]
  bundle["context"] = context; bundle["verifications"] = receipts; response["result"] = bundle
  return response
}

private func requestObservationSection(_ text: String, heading: String) throws -> String {
  let headingRange = try #require(text.range(of: "\n### \(heading)"))
  let remaining = text[headingRange.upperBound...]
  let nextSection = [remaining.range(of: "\n### ")?.lowerBound,
    remaining.range(of: "\n## ")?.lowerBound].compactMap { $0 }.min() ?? text.endIndex
  return String(text[headingRange.lowerBound..<nextSection])
}

@Test @MainActor func verificationRequestKeepsTaskAndOriginalFolderEvidenceSeparate() async throws {
  let replies = ScopedContextReplies()
  let server = try TestService { request in
    let response = replies.respond(request)
    guard request["method"] as? String == "get_task_context" else { return response }
    return requestContextEvidence(response, receipts: [
      requestReceiptJSON(id: "task-a-failed", verdict: "failed"),
      requestReceiptJSON(id: "task-b-passed", repo: "b"),
      requestReceiptJSON(id: "original-a-passed", op: nil),
    ])
  }
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space",
    location: .init(repoId: "a"), contextOperationID: "op", operation: try operation(), title: "Task")
  await model.refresh()
  let draft = try #require(await model.handoff(purpose: .verify))
  let taskA = try requestObservationSection(draft, heading: "\"a\" · 작업용 폴더")
  let originalA = try requestObservationSection(draft, heading: "\"a\" · 원래 프로젝트 폴더")
  #expect(taskA.contains("검증 요약: 현재 공백·충돌 검사 실패"))
  #expect(taskA.contains("검증 task-a-failed:"))
  #expect(!taskA.contains("original-a-passed"))
  #expect(originalA.contains("검증 요약: 현재 공백·충돌 검사 통과"))
  #expect(originalA.contains("검증 original-a-passed:"))
  #expect(!originalA.contains("task-a-failed"))
  #expect(replies.lock.withLock { replies.statusSelections } == [
    .init(repoId: "a", opId: "op"), .init(repoId: "b", opId: "op"), .init(repoId: "a"),
  ])
  #expect(replies.lock.withLock { replies.requests.allSatisfy {
    $0.method == "get_task_context" && $0.scope == "op" && $0.target == nil
  } })
  #expect(replies.lock.withLock { replies.mutationCalls.isEmpty })
}

@Test @MainActor func verificationRequestStatusFailureCannotPromoteStoredPass() async throws {
  let replies = ScopedContextReplies(); replies.statusFails = true
  let server = try TestService { request in
    let response = replies.respond(request)
    guard request["method"] as? String == "get_task_context" else { return response }
    return requestContextEvidence(response, receipts: [requestReceiptJSON(id: "old-pass", op: nil)])
  }
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space",
    location: .init(repoId: "a"), contextOperationID: nil, operation: nil, title: "A")
  await model.refresh()
  let draft = try #require(await model.handoff(purpose: .verify))
  let original = try requestObservationSection(draft, heading: "\"a\" · 원래 프로젝트 폴더")
  #expect(original.contains("현재 상태 미조회:"))
  #expect(original.contains("검증 요약: 현재 폴더 상태를 확인하지 못했습니다"))
  #expect(!original.contains("검증 요약: 현재 공백·충돌 검사 통과"))
  #expect(original.contains("검증 old-pass:"))
  #expect(original.contains("이 대상의 현재 상태 미조회"))
  #expect(replies.lock.withLock { replies.statusSelections } == [.init(repoId: "a")])
  #expect(replies.lock.withLock { replies.requests.allSatisfy { $0.method == "get_task_context" } })
}

@Test @MainActor func verificationRequestKeepsReadFailedAndUnpreparedSiblingsActionable() async throws {
  let replies = ScopedContextReplies()
  let server = try TestService { request in
    let response = replies.respond(request)
    let method = request["method"] as? String
    if method == "get_task_context" {
      return requestContextEvidence(response, receipts: [
        requestReceiptJSON(id: "a-pass"), requestReceiptJSON(id: "b-old-pass", repo: "b"),
        requestReceiptJSON(id: "c-old-pass", repo: "c"),
      ])
    }
    if method == "get_repo_status", (request["params"] as? [String: Any])?["repo_id"] as? String == "b" {
      return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic sibling unavailable"]]
    }
    return response
  }
  var value = operationJSON()
  var repos = try #require(value["repos"] as? [[String: Any]])
  var pending = try #require(repos.last)
  var plan = try #require(pending["plan"] as? [String: Any])
  plan["repo_id"] = "c"; plan["worktree_path"] = "/tmp/synthetic-c"
  pending["plan"] = plan; pending["state"] = "waiting_for_worktree"; pending.removeValue(forKey: "baseline")
  repos.append(pending); value["repos"] = repos
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  let op = try decoder.decode(WorkbenchOperation.self, from: JSONSerialization.data(withJSONObject: value))
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space",
    location: .init(repoId: "a", opId: "op"), contextOperationID: "op", operation: op, title: "Task")
  await model.refresh()
  let draft = try #require(await model.handoff(purpose: .verify))
  let observed = try requestObservationSection(draft, heading: "\"a\" · 작업용 폴더")
  let failed = try requestObservationSection(draft, heading: "\"b\" · 작업용 폴더")
  let unprepared = try requestObservationSection(draft, heading: "\"c\" · 작업용 폴더")
  #expect(observed.contains("검증 요약: 현재 공백·충돌 검사 통과"))
  #expect(failed.contains("검증 요약: 현재 폴더 상태를 확인하지 못했습니다"))
  #expect(failed.contains("다음 확인:"))
  #expect(!failed.contains("검증 요약: 현재 공백·충돌 검사 통과"))
  #expect(unprepared.contains("현재 상태 미조회: 워크트리 준비 전"))
  #expect(unprepared.contains("다음 확인:"))
  #expect(!unprepared.contains("검증 c-old-pass:"))
  #expect(replies.lock.withLock { replies.statusSelections } == [
    .init(repoId: "a", opId: "op"), .init(repoId: "b", opId: "op"),
  ])
  #expect(!draft.contains("원래 프로젝트 폴더"))
}

@Test @MainActor func verificationRequestInvalidatesOldRequirementsAndDisclosesCollectionDrift() async throws {
  let replies = Replies()
  let server = try TestService { request in
    let response = replies.respond(request)
    if request["method"] as? String == "get_task_context" {
      return requestContextEvidence(response, receipts: [
        requestReceiptJSON(id: "previous-goal-pass", op: nil, requirements: "goal-1"),
      ])
    }
    if request["method"] as? String == "get_repo_status" {
      replies.lock.withLock { replies.revision = 3 }
    }
    return response
  }
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space",
    location: .init(repoId: "a"), contextOperationID: nil, operation: nil, title: "A")
  await model.refresh()
  replies.lock.withLock { replies.revision = 2 }
  let draft = try #require(await model.handoff(purpose: .verify))
  #expect(draft.contains("완료 조건 식별자: goal-2"))
  #expect(draft.contains("검증 요약: 검사 뒤 완료 조건이 바뀌었습니다"))
  #expect(!draft.contains("검증 요약: 현재 공백·충돌 검사 통과"))
  #expect(draft.contains("수집 중 작업 정보가 변경되었습니다"))
  #expect(draft.contains("revision 2 기준"))
  #expect(draft.contains("조건 충족이나 실행을 River가 인증한 결과가 아닙니다"))
  #expect(!model.isDirty)
}

@Test @MainActor func verificationRequestNavigationDuringCollectionReturnsNoOriginDraft() async throws {
  let replies = Replies(); replies.purpose = "origin-only purpose"
  let server = try TestService { request in
    requestContextEvidence(replies.respond(request), receipts: [])
  }
  let model = TaskContextStore(); let client = ServiceClient(socketPath: server.path)
  model.configure(client: client, workspace: "space", location: .init(repoId: "a"),
    contextOperationID: nil, operation: nil, title: "Origin")
  await model.refresh()
  replies.lock.withLock { replies.holdGet = true }
  let collecting = Task { await model.handoff(purpose: .verify) }
  try await wait(replies.arrived)
  model.configure(client: client, workspace: "space", location: .init(repoId: "b"),
    contextOperationID: nil, operation: nil, title: "Destination")
  replies.lock.withLock { replies.purpose = "destination-only purpose"; replies.revision = 2 }
  await model.refresh()
  replies.gate.signal()
  #expect(await collecting.value == nil)
  #expect(model.bundle?.context.purpose == "destination-only purpose")
  #expect(model.draft?.purpose == "destination-only purpose")
  #expect(!model.isDirty)
  #expect(!model.working)
  #expect(model.inFlightWorkCount == 0)
}

// Workflow v2 service fixture. Existing fixtures intentionally retain the legacy response.
private final class WorkflowReplies: @unchecked Sendable {
  let lock = NSLock()
  let legacy = Replies()
  var capability = true
  var compatibility = "current"
  var contextRevision = 1
  var workflowRevision = 1
  var purpose = "Saved purpose"
  var criteria: [[String: Any]] = [
    ["id": "22222222-2222-4222-8222-222222222222", "revision": 1, "text": "Duplicate"],
    ["id": "33333333-3333-4333-8333-333333333333", "revision": 1, "text": "Duplicate"],
  ]
  var guides: [[String: Any]] = []
  var receipts: [[String: Any]] = []
  var evidence: [[String: Any]] = []
  var requests: [(method: String, params: [String: Any])] = []
  var saveFailure: String?
  var dropSaveReply = false
  var holdStatus = false
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  private func context() -> [String: Any] {
    ["revision": contextRevision, "purpose": purpose, "criteria": criteria.map { $0["text"] as? String ?? "" },
      "references": [], "notes": "", "requirements_hash": "goal-\(contextRevision)"]
  }
  private func bundle() -> [String: Any] {
    ["version": 2, "compatibility": compatibility, "context": context(), "verifications": receipts,
      "workflow": ["revision": workflowRevision, "context_revision": contextRevision, "intent_hash": "intent",
        "criteria": criteria, "guides": guides, "retired_count": 0], "evidence": evidence, "history": []]
  }
  func respond(_ request: [String: Any]) -> [String: Any]? {
    let method = request["method"] as? String ?? ""
    let p = request["params"] as? [String: Any] ?? [:]
    let hold = lock.withLock {
      requests.append((method, p))
      if method == "get_repo_status", holdStatus { holdStatus = false; return true }
      return false
    }
    if hold { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
    switch method {
    case "get_task_context", "get_task_workflow", "save_task_workflow", "record_workflow_report", "reset_task_workflow", "read_verification_guide":
      return lock.withLock {
        var result: [String: Any]
        switch method {
        case "get_task_context":
          result = ["context": context(), "verifications": receipts]
          if capability { result["workflow_version"] = 2 }
        case "get_task_workflow": result = bundle()
        case "save_task_workflow":
          if dropSaveReply { return nil }
          if let saveFailure { return ["schema_version": 1, "error": ["code": saveFailure, "message": "synthetic stale write"]] }
          let old = criteria
          criteria = (p["criteria"] as? [[String: Any]] ?? []).map { entry in
            let previous = old.first { ($0["id"] as? String) == (entry["id"] as? String) }
            let revision = previous?["revision"] as? Int ?? 0
            return ["id": entry["id"] as? String ?? "", "text": entry["text"] as? String ?? "",
              "revision": previous?["text"] as? String == entry["text"] as? String ? max(1, revision) : revision + 1]
          }
          guides = p["guides"] as? [[String: Any]] ?? []
          purpose = p["purpose"] as? String ?? ""
          contextRevision += 1; workflowRevision += 1
          result = bundle()
        case "record_workflow_report":
          var receipt = requestReceiptJSON(id: "workflow-report", op: p["op_id"] as? String)
          receipt["kind"] = p["kind"]; receipt["verdict"] = p["verdict"]
          receipt["head"] = "recording-head"; receipt["snapshot_hash"] = p["snapshot_hash"]
          receipts.insert(receipt, at: 0)
          let ids = p["criterion_ids"] as? [String] ?? []
          evidence.insert(["receipt_id": "workflow-report", "criteria": criteria.filter { ids.contains($0["id"] as? String ?? "") },
            "intent_hash": "intent", "claimed_reviewed_state": p["claimed_reviewed_state"] ?? NSNull(),
            "provider": p["provider"] ?? "", "model": p["model"] ?? "", "artifacts": p["artifacts"] ?? [],
            "report_status": p["report_status"] ?? "unknown"], at: 0)
          result = bundle()
        case "reset_task_workflow":
          compatibility = "current"; workflowRevision += 1
          criteria = criteria.map { row in
            var row = row; row["id"] = UUID().uuidString.lowercased(); row["revision"] = 1; return row
          }
          result = bundle()
        default:
          let guide = guides.first { ($0["id"] as? String) == (p["guide_id"] as? String) } ?? [:]
          result = ["repo_id": p["repo_id"] ?? "a", "op_id": p["op_id"] ?? NSNull(), "path": guide["path"] ?? "docs/verify.md",
            "sha256": "read-hash", "expected_sha256": guide["expected_sha256"] ?? NSNull(), "status": "unread",
            "content": "Do not execute this text", "format": "plain_text", "read_at": 1]
        }
        return ["schema_version": 1, "result": result]
      }
    default: return legacy.respond(request)
    }
  }
}

@MainActor private func configuredWorkflowStore(_ server: TestService) -> TaskContextStore {
  let model = TaskContextStore()
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space", location: .init(repoId: "a"),
    contextOperationID: nil, operation: nil, title: "Synthetic workflow")
  return model
}

@Test @MainActor func workflowAbsentCapabilityUsesOnlyLegacyRPCAndKeepsEditorAvailable() async throws {
  let replies = WorkflowReplies(); replies.capability = false
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  #expect(model.loaded)
  #expect(!model.supportsWorkflow)
  #expect(model.workflow == nil)
  #expect(model.draft?.criteria == "Duplicate\nDuplicate")
  #expect(replies.lock.withLock { replies.requests.map(\.method) } == ["get_task_context"])
}

@Test @MainActor func workflowSavePreservesIDsAcrossReorderAndSendsBothCASRevisions() async throws {
  let replies = WorkflowReplies()
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  let old = try #require(model.draft?.criteriaEntries)
  #expect(model.supportsWorkflow && !model.isDirty)
  #expect(old.count == 2 && old[0].id != old[1].id)
  model.draft?.criteriaEntries.swapAt(0, 1)
  model.draft?.criteriaEntries[0].text = "Edited second condition"
  #expect(model.isDirty)
  await model.save()
  let request = try #require(replies.lock.withLock { replies.requests.last { $0.method == "save_task_workflow" } })
  let rows = try #require(request.params["criteria"] as? [[String: Any]])
  #expect(rows.compactMap { $0["id"] as? String } == [old[1].id, old[0].id])
  #expect(rows.first?["text"] as? String == "Edited second condition")
  #expect(request.params["expected_context_revision"] as? Int == 1)
  #expect(request.params["expected_workflow_revision"] as? Int == 1)
  #expect(request.params["expected_revision"] == nil)
  #expect(model.draft?.revision == 2 && model.draft?.workflowRevision == 2)
  #expect(model.workflow?.workflow.criteria.first?.revision == 2)
  #expect(!model.isDirty)
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "save_task_context" } })
}

@Test @MainActor func workflowCapabilityChangesKeepTheDraftRepresentationAndBlockIncompatibleSaves() async throws {
  for startsRich in [true, false] {
    let replies = WorkflowReplies(); replies.capability = startsRich
    replies.guides = [["id": "44444444-4444-4444-8444-444444444444", "repo_id": "a",
      "kind": "procedure", "path": "docs/saved.md", "expected_sha256": NSNull()]]
    let server = try TestService { replies.respond($0) }
    let model = configuredWorkflowStore(server)
    await model.refresh()
    if startsRich {
      model.draft?.criteriaEntries[0].text = "Recover this unsaved rich condition"
      model.draft?.guides[0].path = "docs/unsaved.md"
    } else { model.draft?.criteria = "Recover this unsaved legacy condition" }
    let preserved = model.draft
    replies.lock.withLock { replies.capability = !startsRich }
    await model.refresh()
    #expect(model.supportsWorkflow == !startsRich)
    // ContextEditor uses this draft-format selector, independently of engine capability.
    #expect(model.draftUsesWorkflow == startsRich)
    #expect(model.draft == preserved && model.isDirty)
    await model.save()
    #expect(model.draft == preserved)
    #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "save_task_context" || $0.method == "save_task_workflow" } })
    replies.lock.withLock { replies.capability = startsRich }
    await model.refresh()
    #expect(model.draft == preserved && model.draftUsesWorkflow == startsRich)
    // An explicit reload, rather than a capability change, replaces unsaved input.
    replies.lock.withLock { replies.capability = !startsRich }
    await model.refresh(); model.reloadDraft()
    #expect(model.draftUsesWorkflow == !startsRich)
    #expect(!model.isDirty)
    #expect(model.draft?.criteria == "Duplicate\nDuplicate")
    if !startsRich { #expect(model.draft?.guides.first?.path == "docs/saved.md") }
  }
}

@Test @MainActor func workflowCleanDowngradeOpensTheLegacyEditorWithoutInventingUnsavedChanges() async throws {
  let replies = WorkflowReplies()
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  #expect(model.draftUsesWorkflow && !model.isDirty)
  replies.lock.withLock { replies.capability = false }
  await model.refresh()
  #expect(!model.supportsWorkflow && !model.draftUsesWorkflow && !model.isDirty)
  model.draft?.criteria = "New legacy edit"
  #expect(model.isDirty)
}

@Test @MainActor func emptyWorkflowDeletionsSurviveDowngradeRefreshNavigationAndReconnectUntilReload() async throws {
  for deletingGuides in [false, true] {
    let replies = WorkflowReplies()
    if deletingGuides {
      replies.criteria = []
      replies.guides = [["id": "44444444-4444-4444-8444-444444444444", "repo_id": "a",
        "kind": "procedure", "path": "docs/saved.md", "expected_sha256": NSNull()]]
    }
    let server = try TestService { replies.respond($0) }
    let model = configuredWorkflowStore(server)
    await model.refresh()
    if deletingGuides { model.draft?.guides = [] } else { model.draft?.criteriaEntries = [] }
    let deletion = model.draft
    #expect(model.isDirty)
    replies.lock.withLock { replies.capability = false }
    for _ in 0..<3 {
      await model.refresh()
      #expect(model.draft == deletion && model.isDirty && model.draftUsesWorkflow)
    }
    let client = ServiceClient(socketPath: server.path)
    model.configure(client: client, workspace: "space", location: .init(repoId: "b"),
      contextOperationID: nil, operation: nil, title: "Other folder")
    await model.refresh()
    model.configure(client: client, workspace: "space", location: .init(repoId: "a"),
      contextOperationID: nil, operation: nil, title: "Return to deletion")
    await model.refresh(); await model.refresh()
    #expect(model.draft == deletion && model.isDirty && model.draftUsesWorkflow)
    replies.lock.withLock { replies.capability = true }
    await model.refresh(); await model.refresh()
    #expect(model.draft == deletion && model.isDirty && model.supportsWorkflow)
    #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "save_task_context" || $0.method == "save_task_workflow" } })
    model.reloadDraft()
    #expect(!model.isDirty)
    if deletingGuides { #expect(model.draft?.guides.count == 1) }
    else { #expect(model.draft?.criteriaEntries.count == 2) }
  }
}

@Test @MainActor func workflowStaleAndUncertainSaveRetainIdentityAndDraftWithoutReplay() async throws {
  for transportFailure in [false, true] {
    let replies = WorkflowReplies()
    let server = try TestService { replies.respond($0) }
    let model = configuredWorkflowStore(server)
    await model.refresh()
    let id = model.draft?.criteriaEntries.first?.id
    model.draft?.criteriaEntries[0].text = "Unsaved intent"
    replies.lock.withLock { replies.saveFailure = transportFailure ? nil : "workflow_conflict"; replies.dropSaveReply = transportFailure }
    await model.save()
    #expect(model.isDirty)
    #expect(model.draft?.criteriaEntries.first?.id == id)
    #expect(model.draft?.criteriaEntries.first?.text == "Unsaved intent")
    #expect(model.draft?.revision == 1 && model.draft?.workflowRevision == 1)
    #expect(model.message != nil)
    #expect(replies.lock.withLock { replies.requests.filter { $0.method == "save_task_workflow" }.count } == 1)
    #expect(model.inFlightWorkCount == 0 && !model.working)
    #expect(model.updateUncertainWriteOrigins.isEmpty == !transportFailure)
  }
}

@Test @MainActor func workflowReportKeepsUnknownClaimSeparateFromRecordingObservation() async throws {
  let replies = WorkflowReplies()
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  let id = try #require(model.draft?.criteriaEntries.first?.id)
  let recorded = await model.record(kind: "ai_report", verdict: "passed", command: "test", note: "Reported result",
    criterionIDs: [id], provider: "provider", model: "exact-model", artifacts: ["logs/test.txt"], reportStatus: "tool_error", at: model.identity)
  #expect(recorded)
  let request = try #require(replies.lock.withLock { replies.requests.last { $0.method == "record_workflow_report" } })
  #expect(request.params["claimed_reviewed_state"] is NSNull)
  #expect(request.params["snapshot_hash"] as? String == "code")
  #expect(request.params["criterion_ids"] as? [String] == [id])
  #expect(request.params["report_status"] as? String == "tool_error")
  #expect(model.workflow?.evidence.first?.claimedReviewedState == nil)
  #expect(model.workflow?.verifications.first?.head == "recording-head")
  #expect(model.workflow?.evidence.first?.reportStatus == "tool_error")
  #expect(model.workflow?.evidence.first?.provider == "provider")
  #expect(model.workflow?.evidence.first?.artifacts == ["logs/test.txt"])
}

@Test @MainActor func workflowNavigationDuringRecordingStatusReadNeverSubmitsOriginReport() async throws {
  let replies = WorkflowReplies()
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  replies.lock.withLock { replies.holdStatus = true }
  let identity = model.identity
  let recording = Task { await model.record(kind: "ai_report", verdict: "unknown", command: "", note: "Origin only", at: identity) }
  try await wait(replies.arrived)
  model.configure(client: ServiceClient(socketPath: server.path), workspace: "space", location: .init(repoId: "b"),
    contextOperationID: nil, operation: nil, title: "Destination")
  await model.refresh()
  replies.gate.signal()
  #expect(!(await recording.value))
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "record_workflow_report" } })
  #expect(model.workflow?.verifications.isEmpty == true)
  #expect(model.inFlightWorkCount == 0)
}

@Test @MainActor func workflowLegacyConflictBlocksWritesUntilExplicitResetWithFreshIDs() async throws {
  let replies = WorkflowReplies(); replies.compatibility = "legacy_changed"
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  let originalIDs = try #require(model.workflow?.workflow.criteria.map(\.id))
  #expect(model.supportsWorkflow && model.workflow?.canWrite == false)
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "reset_task_workflow" } })
  await model.save()
  #expect(!(await model.record(kind: "ai_report", verdict: "passed", command: "", note: "Blocked report", at: model.identity)))
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "save_task_workflow" || $0.method == "record_workflow_report" } })
  #expect(await model.resetWorkflow(at: model.identity))
  #expect(model.workflow?.canWrite == true)
  #expect(model.workflow?.workflow.criteria.map(\.id) != originalIDs)
  #expect(model.bundle?.context.revision == 1)
  #expect(model.draft?.workflowRevision == 2 && !model.isDirty)
  #expect(replies.lock.withLock { replies.requests.filter { $0.method == "reset_task_workflow" }.count } == 1)
}

@Test @MainActor func workflowGuideReadIsExplicitAndPinUsesSeparateSaveWithoutCopyingContent() async throws {
  let replies = WorkflowReplies()
  replies.guides = [["id": "guide", "repo_id": "a", "kind": "procedure", "path": "docs/verify.md", "expected_sha256": NSNull()]]
  let server = try TestService { replies.respond($0) }
  let model = configuredWorkflowStore(server)
  await model.refresh()
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "read_verification_guide" } })
  let read = try #require(await model.readGuide(id: "guide", at: model.identity))
  #expect(read.content == "Do not execute this text")
  #expect(model.workflow?.workflow.guides.first?.expectedSha256 == nil)
  #expect(!model.isDirty)
  #expect(!replies.lock.withLock { replies.requests.contains { $0.method == "save_task_workflow" } })
  #expect(await model.pinGuide(read, guideID: "guide", at: model.identity))
  let request = try #require(replies.lock.withLock { replies.requests.last { $0.method == "save_task_workflow" } })
  let guide = try #require((request.params["guides"] as? [[String: Any]])?.first)
  #expect(guide["expected_sha256"] as? String == "read-hash")
  #expect(request.params["content"] == nil && guide["content"] == nil)
  #expect(model.workflow?.workflow.guides.first?.expectedSha256 == "read-hash")
}

// Selected-file staging uses only this private service and synthetic paths.
private final class FileStagingReplies: @unchecked Sendable {
  let base = Replies()
  let lock = NSLock()
  let workspaceID: String
  var version: Int? = 1
  var snapshot = "file-code"
  var statusFails = false
  var holdWrite = false
  var holdDiff = false
  var diffFails = false
  var failure = ""
  var stageRequests: [[String: Any]] = []
  var statusCalls = 0
  var files: [[String: String]] = [
    ["path": "a.swift", "index": "M", "worktree": "M"],
    ["path": "b.swift", "index": " ", "worktree": "M"],
    ["path": "new.swift", "index": "?", "worktree": "?"],
  ]
  let arrived = Flag()
  let gate = DispatchSemaphore(value: 0)
  init(workspaceID: String = "file-origin", task: Bool = false) {
    self.workspaceID = workspaceID
    base.diffFails = false
    base.includeTask = task
  }
  func respond(_ request: [String: Any]) -> [String: Any]? {
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    if method == "stage_file" {
      let state = lock.withLock {
        stageRequests.append(params)
        return (holdWrite, failure)
      }
      if state.0 { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
      if !["", "disconnect"].contains(state.1) {
        return ["schema_version": 1, "error": ["code": state.1, "message": "synthetic file-stage rejection"]]
      }
      lock.withLock {
        if let index = files.firstIndex(where: { $0["path"] == params["path"] as? String }) {
          if params["staged"] as? Bool == true {
            let wasNew = files[index]["index"] == "A"
            files[index]["index"] = wasNew ? "?" : " "
            files[index]["worktree"] = wasNew ? "?" : "M"
          } else {
            files[index]["index"] = files[index]["index"] == "?" ? "A" : "M"
            files[index]["worktree"] = " "
          }
        }
        snapshot = "file-code-\(stageRequests.count)"
      }
      return state.1 == "disconnect" ? nil : ["schema_version": 1, "result": [:]]
    }
    if method == "list_workspaces" {
      return ["schema_version": 1, "result": [["schema_version": 1, "id": workspaceID,
        "repositories": [["id": "a", "path": "/tmp/\(workspaceID)-a"], ["id": "b", "path": "/tmp/\(workspaceID)-b"]], "groups": []]]]
    }
    if method == "get_repo_status" {
      return lock.withLock {
        statusCalls += 1
        if statusFails { return ["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic status failure"]] }
        let repo = params["repo_id"] as? String ?? "a"
        let folder = params["op_id"] == nil ? "/tmp/\(workspaceID)-\(repo)" : "/tmp/synthetic-\(repo)"
        var value: [String: Any] = ["path": folder, "snapshot_hash": snapshot,
          "snapshot": ["head": "head", "branch": "refs/heads/main", "index_hash": snapshot],
          "files": files, "graph": [], "refs": [], "worktrees": "", "conflict": false, "git_version": "test"]
        if let version { value["file_staging_version"] = version }
        return ["schema_version": 1, "result": value]
      }
    }
    if method == "get_diff" {
      let response: ([String: Any], Bool) = lock.withLock {
        if diffFails {
          return (["schema_version": 1, "error": ["code": "git_failed", "message": "synthetic diff failure"]], holdDiff)
        }
        let path = params["path"] as? String ?? ""
        let isNew = path == "new.swift"
        let hunks = isNew ? [] : ["@@ -1 +1 @@\n-a\n+b\n"]
        return (["schema_version": 1, "result": ["snapshot_hash": snapshot, "path": path,
          "staged": params["staged"] as? Bool ?? false, "header": isNew ? "" : "header\n",
          "hunks": hunks, "text": isNew ? "" : "header\n" + hunks.joined(), "can_stage_hunks": !isNew]], holdDiff)
      }
      if response.1 { arrived.value = true; _ = gate.wait(timeout: .now() + .seconds(5)) }
      return response.0
    }
    return base.respond(request)
  }
}

@Test @MainActor func selectedFileStagingWaitsForTheDisplayedSnapshotDuringRefresh() async throws {
  let replies = FileStagingReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  #expect(store.canStageSelectedFile)
  let oldSnapshot = try #require(store.diff?.snapshotHash)
  replies.lock.withLock { replies.snapshot = "newer-file-code"; replies.holdDiff = true }
  let refreshing = Task { await store.refresh() }
  try await wait(replies.arrived)
  #expect(store.repository?.snapshotHash == "newer-file-code")
  #expect(store.diff?.snapshotHash == oldSnapshot)
  #expect(!store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.isEmpty })
  replies.lock.withLock { replies.holdDiff = false }; replies.gate.signal()
  await refreshing.value
  #expect(store.diff?.snapshotHash == "newer-file-code")
  #expect(store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.count } == 1)
  #expect(replies.lock.withLock { replies.stageRequests.first?["snapshot_hash"] as? String } == "newer-file-code")
}

@Test @MainActor func selectedFileStagingRequiresACurrentPreviewAfterFailureAndCancellation() async throws {
  let replies = FileStagingReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  replies.lock.withLock { replies.snapshot = "failed-file-code"; replies.diffFails = true }
  await store.refresh()
  #expect(store.diff == nil && store.diffError != nil)
  #expect(!store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.isEmpty })
  replies.lock.withLock { replies.diffFails = false; replies.holdDiff = true }
  let refreshing = Task { await store.refresh(forceDiff: true) }
  try await wait(replies.arrived)
  store.chooseFile("new.swift") // Cancels the held old-path request and clears its rendered identity.
  #expect(!store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.isEmpty })
  replies.lock.withLock { replies.holdDiff = false }; replies.gate.signal()
  await refreshing.value
  await store.refresh(forceDiff: true)
  #expect(store.diff?.path == "new.swift" && store.diff?.snapshotHash == "failed-file-code")
  #expect(store.diff?.hunks.isEmpty == true)
  #expect(store.canStageSelectedFile)
}

@Test(arguments: [nil, 0, 2] as [Int?]) @MainActor
func selectedFileStagingRequiresTheAdvertisedEngineVersion(version: Int?) async throws {
  let replies = FileStagingReplies(); replies.version = version
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  #expect(store.repository?.fileStagingVersion == version)
  #expect(!store.canStageSelectedFile); #expect(store.canMarkRead)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.isEmpty })
  #expect(replies.base.lock.withLock { replies.base.stageCalls } == 0)
  #expect(store.error?.contains("엔진") == true)
}

@Test(arguments: [false, true]) @MainActor
func selectedFileStagingCapturesSourceAndIndexSideInTheChosenFolder(task: Bool) async throws {
  let replies = FileStagingReplies(task: task)
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  if task { store.select(.init(repoId: "a", opId: "op")); try await settleSelection(store) }
  let originalSnapshot = try #require(store.repository?.snapshotHash)
  #expect(store.canStageSelectedFile)
  await store.stageSelectedFile()
  let stage = try #require(replies.lock.withLock { replies.stageRequests.first })
  #expect(stage["repo_id"] as? String == "a")
  #expect(stage["op_id"] as? String == (task ? "op" : nil))
  #expect(stage["path"] as? String == "a.swift")
  #expect(stage["snapshot_hash"] as? String == originalSnapshot)
  #expect(stage["staged"] as? Bool == false)
  #expect(stage["hunk_index"] == nil && stage["diff_hash"] == nil)
  #expect(store.repository?.files.first { $0.path == "a.swift" }?.worktree == " ")
  #expect(store.repository?.files.first { $0.path == "b.swift" }?.worktree == "M")
  #expect(store.repository?.files.first { $0.path == "new.swift" }?.index == "?")

  store.chooseStaged(true); await store.refresh(forceDiff: true)
  let stagedSnapshot = try #require(store.repository?.snapshotHash)
  await store.stageSelectedFile()
  let unstage = try #require(replies.lock.withLock { replies.stageRequests.last })
  #expect(replies.lock.withLock { replies.stageRequests.count } == 2)
  #expect(unstage["repo_id"] as? String == "a")
  #expect(unstage["op_id"] as? String == (task ? "op" : nil))
  #expect(unstage["path"] as? String == "a.swift")
  #expect(unstage["snapshot_hash"] as? String == stagedSnapshot)
  #expect(unstage["staged"] as? Bool == true)
  #expect(store.repository?.files.first { $0.path == "a.swift" }?.index == " ")
  #expect(store.selectedFile.isEmpty); #expect(store.diff == nil)
  #expect(replies.base.lock.withLock { replies.base.stageCalls } == 0)
}

@Test @MainActor func selectedNewFileCanStageWithoutAnOrdinaryHunkPreview() async throws {
  let replies = FileStagingReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  store.selectedFile = "new.swift"; await store.refresh(forceDiff: true)
  #expect(store.diff?.hunks.isEmpty == true); #expect(store.diff?.canStageHunks == false)
  #expect(store.selectedFileChange?.index == "?"); #expect(store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.first?["path"] as? String } == "new.swift")
  #expect(store.repository?.files.first { $0.path == "new.swift" }?.index == "A")
  #expect(store.repository?.files.first { $0.path == "b.swift" }?.worktree == "M")
}

@Test @MainActor func selectedFileStagingRejectsOldFileSideFolderAndStatus() async throws {
  let replies = FileStagingReplies(); let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  let location = try #require(store.selection); let snapshot = try #require(store.repository?.snapshotHash)
  store.chooseFile("b.swift")
  await store.stageFile("a.swift", staged: false, expectedSnapshot: snapshot, at: location)
  store.chooseFile("a.swift"); store.chooseStaged(true)
  await store.stageFile("a.swift", staged: false, expectedSnapshot: snapshot, at: location)
  store.chooseStaged(false); store.select(.init(repoId: "b")); try await settleSelection(store)
  await store.stageFile("a.swift", staged: false, expectedSnapshot: snapshot, at: location)
  store.select(location); try await settleSelection(store)
  replies.lock.withLock { replies.snapshot = "external-change" }
  await store.refresh(forceDiff: true)
  await store.stageFile("a.swift", staged: false, expectedSnapshot: snapshot, at: location)
  replies.lock.withLock { replies.statusFails = true }
  await store.refresh()
  #expect(store.selectionCheckFailed); #expect(!store.canStageSelectedFile)
  await store.stageSelectedFile()
  #expect(replies.lock.withLock { replies.stageRequests.isEmpty })
  #expect(replies.base.lock.withLock { replies.base.stageCalls } == 0)
}

@Test @MainActor func rejectedFileStagingDoesNotFallBackToHunkWritesOrRetry() async throws {
  let replies = FileStagingReplies(); replies.failure = "unknown_method"
  let server = try TestService { replies.respond($0) }
  let store = WorkbenchStore(socketPath: server.path); await store.connect()
  await store.stageSelectedFile(); await store.refresh()
  #expect(replies.lock.withLock { replies.stageRequests.count } == 1)
  #expect(replies.base.lock.withLock { replies.base.stageCalls } == 0)
  #expect(store.submissionWarnings.isEmpty); #expect(store.error?.contains("버전") == true)
}

@Test @MainActor func lateFileStagingOutcomeKeepsItsOriginAndDoesNotPublishIntoTheNextWorkspace() async throws {
  let first = FileStagingReplies(); first.holdWrite = true; first.failure = "disconnect"
  let second = FileStagingReplies(workspaceID: "file-destination")
  let serverA = try TestService { first.respond($0) }; let serverB = try TestService { second.respond($0) }
  let store = WorkbenchStore(socketPath: serverA.path); await store.connect()
  store.commitMessage = "origin draft"
  let readsBeforeWrite = first.lock.withLock { first.statusCalls }
  let submission = Task { await store.stageSelectedFile() }; try await wait(first.arrived)
  store.chooseFile("b.swift")
  store.socketPath = serverB.path
  first.gate.signal(); await submission.value
  #expect(first.lock.withLock { first.statusCalls } == readsBeforeWrite)
  await store.connect()
  #expect(store.workspaceTitle == "file-destination")
  #expect(store.repository?.path == "/tmp/file-destination-a")
  #expect(store.repository?.snapshotHash == "file-code")
  #expect(store.commitMessage.isEmpty); #expect(store.error == nil)
  let warning = try #require(store.submissionWarnings.first)
  #expect(warning.workspaceTitle == "file-origin")
  #expect(warning.workspacePath == "/tmp/file-origin-a")
  #expect(warning.message.contains("a.swift")); #expect(!warning.message.contains("b.swift"))
  #expect(first.lock.withLock { first.stageRequests.count } == 1)
  #expect(second.lock.withLock { second.stageRequests.isEmpty })
}

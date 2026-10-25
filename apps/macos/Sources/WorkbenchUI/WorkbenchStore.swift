import AppKit
import Combine
import Foundation
import WorkbenchProtocol
import WorkbenchRuntime

public struct WorktreeSelection: Hashable, Sendable {
  public let repoId: String
  public let opId: String?
  public init(repoId: String, opId: String? = nil) {
    self.repoId = repoId
    self.opId = opId
  }
}

public struct WorkspaceTaskPlan: Sendable {
  public let details: TaskPlan
  fileprivate let session: UUID
  fileprivate let socket: String
}

public struct TaskSubmissionWarning: Identifiable, Equatable {
  public let id: String
  public let workspaceTitle: String
  public let workspacePath: String
  public let message: String
}

public struct PreparationEligibility {
  public let materialize: Bool
  public let retry: Bool
  public let recovery: Bool
  public let cancel: Bool
}

@MainActor
public final class WorkbenchStore: ObservableObject {
  @Published public var socketPath: String
  @Published public private(set) var workspace: WorkspaceInfo?
  @Published public private(set) var workspaceSession = UUID()
  @Published public private(set) var planSession = UUID()
  @Published public private(set) var submissionWarnings: [TaskSubmissionWarning] = []
  @Published public private(set) var operations: [WorkbenchOperation] = []
  @Published public private(set) var tasks: [String: TaskDetail] = [:]
  @Published public private(set) var selection: WorktreeSelection?
  @Published public private(set) var repository: RepositoryStatus?
  @Published public private(set) var diff: FileDiff?
  @Published public private(set) var diffError: String?
  @Published public private(set) var selectionCheckFailed = false
  private struct DiffReadID: Equatable {
    let location: WorktreeSelection
    let path: String
    let staged: Bool
    let stash: String?
    let snapshot: String?
  }
  private var failedDiffRead: DiffReadID?
  private var lastRefreshFailure: String?
  private var lastMetadataFailure: String?
  @Published private var contextWorking = false
  private var contextWorkObserver: AnyCancellable?
  private var contextFlightObserver: AnyCancellable?
  @Published private var contextWorkInFlight = false
  @Published private var pendingTaskSubmissions = 0
  private var updateUnknownTaskSubmissionRevision: UInt64 = 0
  // Running tasks remain relevant to updates after switching to another workspace.
  private struct UpdateWorkspaceIdentity: Hashable {
    let socket: String
    let workspaceID: String
  }
  @Published private var updateRunningOperations: [UpdateWorkspaceIdentity: Set<String>] = [:]
  private var updateWorkspaceNames: [UpdateWorkspaceIdentity: String] = [:]
  @Published public private(set) var stashes: [GitStash] = []
  @Published public private(set) var selectedStashOID: String?
  @Published public private(set) var stashDetail: StashDetail?
  @Published public private(set) var stashError: String?
  @Published public private(set) var stashFocusRequest = 0
  @Published public private(set) var events: [OperationEvent] = []
  @Published public private(set) var busy = false
  @Published public var error: String? {
    didSet { if error == nil { errorDetails = nil } }
  }
  @Published public private(set) var errorDetails: String?
  @Published public private(set) var recentWorkspaces: [RecentWorkspace] = []
  @Published public var showingWelcome = true
  @Published public private(set) var startupMessage: String?
  @Published public var selectedFile = ""
  @Published public var staged = false
  @Published public var splitDiff = true
  @Published public var historyTab = "history"
  public let commitDraft = CommitDraft()
  public var commitMessage: String { get { commitDraft.message } set { commitDraft.message = newValue } }
  @Published public var showTaskSheet = false
  public var recoveryTaskID: String?
  @Published public var showBranches = false
  @Published public var showCloneSheet = false
  @Published public private(set) var remoteState: RemoteState?
  @Published public private(set) var remoteLoading = false
  @Published public private(set) var remoteError: String?
  @Published public private(set) var remoteMessage: String?
  @Published private var remoteMutations: Set<RemoteScope> = []
  private var remoteReadID = UUID()
  private var remoteScope: RemoteScope?
  private var remoteSnapshot: String?

  public private(set) var lastUpdated: Date?
  @Published public private(set) var validatingSelection = false
  @Published public var onlyUnreviewedFiles = false
  private var readingSession = ReviewSession()
  public let taskContext = TaskContextStore()

  private func reviewID(path: String, staged: Bool) -> ReviewFileID? {
    selection.map { ReviewFileID(location: $0, path: path, staged: staged, stashOID: selectedStashOID) }
  }
  var currentReviewID: ReviewFileID? { reviewID(path: selectedFile, staged: staged) }
  public var displayedFiles: [FileChange] {
    guard onlyUnreviewedFiles, !isViewingStash else { return visibleFiles }
    return visibleFiles.filter { reviewState(for: $0) != .reviewed }
  }
  public func reviewState(for file: FileChange) -> FileReviewState {
    guard !isViewingStash, let id = reviewID(path: file.path, staged: staged) else { return .unread }
    if validatingSelection { return .checking }
    let state = readingSession.state(for: id, key: file.reviewKey ?? repository?.snapshotHash ?? "")
    if state == .reviewed, file.path == selectedFile, let diff,
      diff.snapshotHash == repository?.snapshotHash,
      let checkpoint = readingSession.checkpoints[id], checkpoint.contentIdentity != diff.contentIdentity
    { return .needsReview }
    return state
  }
  public var readingCheckpoint: ReadingCheckpoint? {
    guard !isViewingStash, let id = currentReviewID else { return nil }
    return readingSession.checkpoints[id]
  }
  public var currentReadingState: FileReviewState {
    guard let file = visibleFiles.first(where: { $0.path == selectedFile }) else { return .unread }
    return reviewState(for: file)
  }
  public var canUseRenderedDiff: Bool {
    guard !isViewingStash, !busy, !validatingSelection, let diff, let repository else { return false }
    return diff.path == selectedFile && diff.staged == staged && !diff.hunks.isEmpty
      && diff.encodingWarning == nil && !diff.displayLimitExceeded
      && diff.snapshotHash == repository.snapshotHash
  }
  public var canMarkRead: Bool {
    guard canUseRenderedDiff, let diff else { return false }
    return diff.text.utf8.count + diff.hunks.reduce(0, { $0 + $1.utf8.count }) <= ReviewSession.maximumCheckpointBytes
  }
  public func markCurrentFileRead() {
    guard canMarkRead, let diff, let id = currentReviewID else { return }
    objectWillChange.send()
    _ = readingSession.mark(diff, at: id)
  }
  public func clearCurrentReadingCheckpoint() {
    guard let id = currentReviewID else { return }
    objectWillChange.send()
    readingSession.unmark(id)
  }
  public var changedReadingHunks: Set<Int> {
    guard let diff, let id = currentReviewID else { return [] }
    return readingSession.changedHunks(in: diff, at: id)
  }
  public var removedReadingHunks: Int {
    guard let diff, let id = currentReviewID else { return 0 }
    return readingSession.removedHunkCount(in: diff, at: id)
  }
  func rememberReviewOffset(_ y: Double, content: String, at id: ReviewFileID) {
    readingSession.rememberOffset(y, content: content, at: id)
  }
  func reviewOffset(content: String, at id: ReviewFileID) -> Double {
    readingSession.offset(content: content, at: id)
  }
  public var currentReviewScrollOffset: Double {
    guard let diff, let id = currentReviewID else { return 0 }
    return reviewOffset(content: diff.contentIdentity, at: id)
  }
  func hunkRequest(_ index: Int, from rendered: FileDiff, at location: WorktreeSelection) -> HunkRequest? {
    guard canUseRenderedDiff, let selection, let repository,
      location == selection, rendered.path == selectedFile, rendered.staged == staged,
      rendered.contentIdentity == diff?.contentIdentity, rendered.snapshotHash == repository.snapshotHash,
      rendered.hunks.indices.contains(index)
    else { return nil }
    let patch = rendered.header + rendered.hunks[index]
    guard patch.utf8.count <= 128 * 1024 else { return nil }
    return HunkRequest(
      repository: selection.repoId, folder: repository.path, task: taskTitle,
      branch: repository.snapshot.branch, head: repository.snapshot.head, path: rendered.path,
      staged: rendered.staged, snapshot: rendered.snapshotHash, patch: patch)
  }
  public func hunkRequestText(_ index: Int, instruction: String) -> String? {
    guard let diff, let selection else { return nil }
    return hunkRequest(index, from: diff, at: selection)?.text(instruction: instruction)
  }

  private var client: ServiceClient?
  private var generation = UUID()
  private var diffGeneration = UUID()
  private var diffRequest: Task<FileDiff, any Error>?
  private var refreshing = false
  private var eventCursor = 0
  private let runtime: WorkspaceRuntime
  private var currentWorkspace: RecentWorkspace?
  private var connectedSocketPath: String?
  private var didStart = false
  @Published private var contextOperationID: String?
  // The recent list is paginated. Keep only the selected/context summaries
  // separately so an older Task retains its identity without growing that list.
  @Published private var pinnedOperations: [String: WorkbenchOperation] = [:]
  @Published private var unresolvedOperationIDs: Set<String> = []
  private var activeContextOperationID: String? { selection?.opId ?? contextOperationID }
  private var activeOperationIDs: Set<String> {
    Set([selection?.opId, activeContextOperationID].compactMap { $0 })
  }
  private struct LocationDraft {
    let selectedFile: String
    let staged: Bool
    let commitMessage: String
  }
  private struct CachedLocation {
    let repository: RepositoryStatus?
    let diff: FileDiff?
    let stashes: [GitStash]
    let selectedStashOID: String?
    let stashDetail: StashDetail?
    let workingReview: WorkingReview?
    let lastUpdated: Date?
  }
  private struct WorkingReview {
    let path: String
    let staged: Bool
  }
  private var workingReview: WorkingReview?
  // Keep review data for six recent folders. Small drafts survive review-cache eviction.
  private var locationDrafts: [WorktreeSelection: LocationDraft] = [:]
  private var workspaceDrafts: [String: [WorktreeSelection: LocationDraft]] = [:]
  private var workspaceSelections: [String: WorktreeSelection] = [:]
  private var workspaceContexts: [String: String] = [:]
  private var restoredWorkspaceSelection = false
  private var locationCache: [WorktreeSelection: CachedLocation] = [:]
  private var cacheOrder: [WorktreeSelection] = []

  public init(
    socketPath: String = ProcessInfo.processInfo.environment["WORKBENCH_SOCKET"] ?? "",
    runtime: WorkspaceRuntime = WorkspaceRuntime()
  ) {
    self.socketPath = socketPath
    self.runtime = runtime
    contextWorkObserver = taskContext.$working.removeDuplicates().dropFirst().sink { [weak self] in self?.contextWorking = $0 }
    contextFlightObserver = taskContext.$inFlightWorkCount.removeDuplicates().sink { [weak self] in self?.contextWorkInFlight = $0 > 0 }
  }
  public var canReconnect: Bool { currentWorkspace != nil || !socketPath.isEmpty }
  public var workspaceTitle: String { currentWorkspace?.name ?? workspace?.id ?? "작업공간" }
  public func startup() async {
    guard !didStart else { return }
    didStart = true
    do { recentWorkspaces = try await runtime.recentWorkspaces() } catch { report(error) }
    // Explicit development injection is optional; Finder launches need no environment setup.
    if !socketPath.isEmpty { await connect() }
  }
  public func chooseRepository() {
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "저장소 열기"
    panel.message = "Git으로 관리하는 프로젝트 폴더를 선택하세요."
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in await self?.openRepository(url) }
    }
  }
  public func openRepository(_ url: URL) async {
    await openWorkspace(message: "저장소 여는 중…") { try await self.runtime.openRepository(url) }
  }
  public func openExample() async {
    await openWorkspace(message: "예제 준비 중…") { try await self.runtime.openExample() }
  }
  public func openRecent(_ recent: RecentWorkspace) async {
    await openWorkspace(message: "\(recent.name) 여는 중…") {
      try await self.runtime.openRecent(recent)
    }
  }
  public func reconnect() async {
    if let currentWorkspace { await openRecent(currentWorkspace) } else { await connect() }
  }
  public func stopIdleServices() async { await runtime.stopIdleServices() }
  /// Installation must consider every outstanding write, rather than only the visible folder.
  public var updateRestartBlocker: String? {
    if busy || pendingTaskSubmissions > 0 { return "저장소를 열거나 변경하는 작업이 진행 중입니다. 완료된 뒤 다시 시도해 주세요." }
    if !remoteMutations.isEmpty { return "다른 폴더를 포함해 원격 Git 작업이 진행 중입니다. 완료된 뒤 다시 시도해 주세요." }
    if contextWorking || contextWorkInFlight { return "작업 정보 저장 또는 검사 기록이 진행 중입니다. 완료된 뒤 다시 시도해 주세요." }
    if hasRunningOperation || !updateRunningOperations.isEmpty {
      let names = updateRunningOperations.keys.compactMap { updateWorkspaceNames[$0] }.sorted()
      return "워크트리 준비 작업이 진행 중이거나 완료 여부를 확인해야 합니다. \(names.isEmpty ? "해당 저장소" : names.joined(separator: ", "))를 열어 상태를 새로고침한 뒤 다시 시도해 주세요."
    }
    return nil
  }
  /// Uncertainty needs a fresh, explicit user acknowledgement; it is not proof a job still runs.
  public var updateRestartWarning: String? {
    var warnings: [String] = []
    if !unresolvedOperationIDs.isEmpty {
      warnings.append("선택한 작업 상태를 확인하지 못했습니다. 해당 저장소와 작업의 실제 상태를 확인하세요.")
    }
    if !submissionWarnings.isEmpty {
      let origins = Array(Set(submissionWarnings.map { HandoffText.field($0.workspaceTitle) + " · " + HandoffText.field($0.workspacePath) })).sorted().prefix(4)
      warnings.append("처리 결과를 확인하지 못한 변경 요청 \(submissionWarnings.count)개가 있습니다: " + origins.joined(separator: "; ") + ". 화면의 원래 알림과 실제 Git 상태를 확인하세요.")
    }
    if !taskContext.updateUncertainWriteOrigins.isEmpty {
      warnings.append("작업 정보 변경 결과를 확인하지 못한 위치가 있습니다: " + taskContext.updateUncertainWriteOrigins.sorted().prefix(4).joined(separator: "; ") + ". 저장소의 작업 정보와 검사 기록을 확인하세요.")
    }
    return warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
  }
  /// Display is bounded independently; every uncertain request contributes to consent identity.
  public var updateRestartConsentIdentity: [String] {
    ["context-writes:\(taskContext.updateUncertainWriteRevision)",
     "task-submissions:\(updateUnknownTaskSubmissionRevision)"]
      + submissionWarnings.map { "submission:" + $0.id }.sorted()
      + unresolvedOperationIDs.map { "unresolved:" + workspaceSession.uuidString + ":" + $0 }.sorted()
  }
  private func rememberUpdateOperation(_ operation: WorkbenchOperation, identity: UpdateWorkspaceIdentity, title: String) {
    var running = updateRunningOperations[identity] ?? []
    if operation.isRunning { running.insert(operation.id) } else { running.remove(operation.id) }
    let next = running.isEmpty ? nil : running
    if updateRunningOperations[identity] != next { updateRunningOperations[identity] = next }
    if !running.isEmpty { updateWorkspaceNames[identity] = HandoffText.field(title) }
    else { updateWorkspaceNames.removeValue(forKey: identity) }
  }
  func openWorkspace(message: String, work: () async throws -> WorkspaceSession) async {
    guard !busy else { return }
    busy = true
    startupMessage = message
    error = nil
    errorDetails = nil
    defer {
      busy = false
      startupMessage = nil
    }
    do {
      let session = try await work()
      let returningToSameWorkspace = connectedSocketPath == session.socketPath
      try await connectToService(socket: session.socketPath, recent: session.recent)
      recentWorkspaces = try await runtime.recentWorkspaces()
      if session.recent.isExample && !returningToSameWorkspace && !restoredWorkspaceSelection { await selectFirstPreparedTaskAfterOpening() }
    } catch { report(error) }
  }
  private func selectFirstPreparedTaskAfterOpening() async {
    if let op = operations.first(where: { $0.repos.contains { $0.hasWorktree } }),
      let repo = op.repos.first(where: { $0.hasWorktree })
    {
      generation = UUID()
      cancelDiffRead()
      selection = .init(repoId: repo.id, opId: op.id)
      contextOperationID = op.id
      validatingSelection = true
      configureTaskContext()
      clearStashReview()
      repository = nil
      diff = nil
      selectedFile = ""
      await refresh()
    }
  }
  public func report(_ failure: any Error) {
    errorDetails = failure.localizedDescription
    error = UserFacingFailure.message(failure)
    if case .helper(let details) = failure as? StartupFailure { errorDetails = details }
  }
  private func operationSummary(for id: String?) -> WorkbenchOperation? {
    guard let id else { return nil }
    return pinnedOperations[id] ?? operations.first { $0.id == id }
  }
  public var operation: WorkbenchOperation? { operationSummary(for: selection?.opId) }
  public var contextOperation: WorkbenchOperation? {
    operationSummary(for: activeContextOperationID)
  }
  public var taskDetail: TaskDetail? { operation.flatMap { tasks[$0.taskId] } }
  public var taskRepository: TaskRepository? {
    operation?.repos.first { $0.id == selection?.repoId }
  }
  public var taskTitle: String {
    if contextTaskInformationUnavailable { return taskInformationTitle }
    return contextOperation.map { title(for: $0) }
      ?? (activeContextOperationID != nil ? "작업 정보 확인 필요" : selection?.repoId)
      ?? "River"
  }
  public var hasRunningOperation: Bool {
    operations.contains { $0.isRunning } || pinnedOperations.values.contains { $0.isRunning }
  }
  public var visibleFiles: [FileChange] {
    if isViewingStash { return stashDetail?.files ?? [] }
    return repository?.files.filter { staged ? $0.isStaged : $0.isWorking } ?? []
  }
  public var isViewingStash: Bool { selectedStashOID != nil }
  public var selectedStash: GitStash? { stashes.first { $0.oid == selectedStashOID } }
  public var stagedCount: Int { repository?.files.filter(\.isStaged).count ?? 0 }
  public var selectedFileChange: FileChange? { visibleFiles.first { $0.path == selectedFile } }
  public var canStageSelectedFile: Bool { fileStagingUnavailableReason == nil }
  public var fileStagingUnavailableReason: String? {
    if isViewingStash { return "Stash는 읽기 전용입니다." }
    if selectionCheckFailed { return "최신 상태를 확인하지 못했습니다. 새로고침한 뒤 스테이징하세요." }
    if taskPreparationIncomplete { return preparationHint }
    if repository == nil || validatingSelection { return "현재 폴더의 파일 상태를 확인하고 있습니다." }
    if repository?.conflict == true { return "충돌 또는 진행 중인 Git 작업을 해결한 뒤 스테이징하세요." }
    if hasRunningOperation { return "저장소 준비가 끝나면 스테이징할 수 있습니다." }
    if contextWorking { return "검사나 작업 기록 수집이 끝나면 스테이징할 수 있습니다." }
    if busy || remoteBusy { return "현재 작업이 끝나면 스테이징할 수 있습니다." }
    if !canEdit { return "작업공간 연결을 확인한 뒤 스테이징할 수 있습니다." }
    if repository?.fileStagingVersion != 1 {
      return "연결된 작업 엔진은 파일 전체 스테이징을 지원하지 않습니다. 엔진을 업데이트한 뒤 다시 연결하세요."
    }
    if selectedFileChange == nil { return "현재 목록에서 스테이징할 파일을 선택하세요." }
    if diffError != nil { return "변경 표시를 읽지 못했습니다. 새로고침한 뒤 파일 전체를 확인하고 스테이징하세요." }
    if diffRequest != nil || diff?.path != selectedFile || diff?.staged != staged
      || diff?.snapshotHash != repository?.snapshotHash {
      return "선택한 파일의 최신 변경을 불러오고 있습니다. 변경 표시가 갱신된 뒤 스테이징하세요."
    }
    return nil
  }
  public var taskInformationUnavailable: Bool {
    guard let id = selection?.opId else { return false }
    return unresolvedOperationIDs.contains(id) || taskRepository == nil
  }
  public var taskInformationLookupFailed: Bool {
    activeContextOperationID.map { unresolvedOperationIDs.contains($0) } ?? false
  }
  public var contextTaskInformationUnavailable: Bool {
    guard let id = activeContextOperationID else { return false }
    return unresolvedOperationIDs.contains(id) || contextOperation == nil
  }
  public var taskInformationTitle: String {
    taskInformationLookupFailed ? "작업 정보 확인 필요" : "작업 정보 확인 중…"
  }
  public var taskInformationHint: String {
    taskInformationLookupFailed
      ? "작업 정보를 읽지 못했습니다. 새로고침한 뒤 폴더를 확인해 주세요."
      : "저장된 작업과 폴더 정보를 확인하고 있습니다. 확인이 끝나면 변경을 편집할 수 있습니다."
  }
  public var pendingWorktree: Bool { !taskInformationUnavailable && taskRepository?.hasWorktree == false }
  public var pendingWorktreeTitle: String {
    if operation?.isRunning == true { return "작업 폴더 준비 중" }
    if ["failed", "needs_recovery", "cancelled"].contains(taskRepository?.state ?? "") { return "작업 폴더 준비 중단" }
    return "워크트리 준비 대기"
  }
  public var pendingWorktreeHint: String {
    if operation?.isRunning == true { return "저장소 준비가 끝나면 변경 내용을 확인할 수 있습니다." }
    if operation?.requiresNewPlan == true {
      return "계획을 만든 뒤 원래 폴더가 바뀌었습니다. 원래 변경은 유지됩니다. 현재 상태를 기준으로 새 작업을 만들어 주세요."
    }
    if ["failed", "needs_recovery", "cancelled"].contains(taskRepository?.state ?? "") {
      return "위 저장소의 준비 상태와 오류를 확인한 뒤 재시도하세요. 원래 프로젝트 폴더의 변경은 계속 확인할 수 있습니다."
    }
    return "위의 ‘워크트리 준비’를 눌러 작업용 폴더를 만드세요."
  }
  public var preparationHint: String {
    if taskInformationUnavailable { return taskInformationHint }
    if operation?.requiresNewPlan == true {
      return "원래 폴더가 바뀌어 이 계획을 계속할 수 없습니다. ‘새 작업 만들기’로 현재 상태에서 준비하세요. 기존 폴더와 브랜치는 유지됩니다."
    }
    if pendingWorktree { return pendingWorktreeHint }
    if taskRepository?.state == "cancelled" { return "준비가 취소되었습니다. 위 저장소에서 재시도한 뒤 변경을 편집할 수 있습니다." }
    return "이 작업 폴더의 준비가 끝나면 변경을 편집할 수 있습니다. 위 저장소의 상태와 오류를 확인해 주세요."
  }
  public func beginRecovery(_ operation: WorkbenchOperation) {
    guard preparationEligibility(for: operation.id).recovery,
      let current = operationSummary(for: operation.id) else { return }
    recoveryTaskID = current.taskId
    showTaskSheet = true
  }
  public func nextTaskSlug(_ base: String) -> String {
    let root = String(base.prefix(55))
    var number = 2
    while operations.flatMap(\.repos).contains(where: { $0.plan.branchRef.hasSuffix("/\(root)-\(number)") }) { number += 1 }
    return "\(root)-\(number)"
  }
  public var taskPreparationIncomplete: Bool {
    guard let id = selection?.opId else { return false }
    return unresolvedOperationIDs.contains(id) || taskRepository?.state != "ready"
  }
  public var canEdit: Bool {
    !isViewingStash && repository != nil && repository?.conflict != true && !busy
      && !hasRunningOperation && !remoteBusy && !validatingSelection && !taskPreparationIncomplete && !contextWorking
      && socketPath == connectedSocketPath
  }
  public func preparationEligibility(for id: String) -> PreparationEligibility {
    let op = operationSummary(for: id)
    let connected = client != nil && socketPath == connectedSocketPath && !busy
    let resolved = connected && !unresolvedOperationIDs.contains(id) && op != nil
    let canPrepare = resolved && !hasRunningOperation
    return PreparationEligibility(
      materialize: canPrepare && op?.canMaterialize == true && op?.requiresNewPlan != true,
      retry: canPrepare && op?.canRetry == true && op?.requiresNewPlan != true,
      recovery: canPrepare && op?.canRetry == true && op?.requiresNewPlan == true,
      // Cancellation is a safety action against an already-known operation ID.
      // The service verifies its current state; stale metadata must not trap a running job.
      cancel: connected && op?.isRunning == true)
  }
  public func title(for op: WorkbenchOperation) -> String {
    tasks[op.taskId]?.request.label ?? op.repos.first?.plan.branchRef.components(separatedBy: "/")
      .last ?? String(op.id.prefix(8))
  }

  public func connect() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    let requestedSocket = socketPath
    do {
      try await connectToService(socket: requestedSocket)
    } catch {
      if socketPath == requestedSocket, let connectedSocketPath { socketPath = connectedSocketPath }
      report(error)
    }
  }
  // Keep every published workspace identity and client from the old connection
  // until the candidate handshake succeeds. Failed candidates preserve its drafts.
  private func connectToService(socket: String, recent: RecentWorkspace? = nil) async throws {
    let requestedSocket = socketPath
    let candidate = ServiceClient(socketPath: socket)
    let spaces: [WorkspaceInfo] = try await candidate.call("list_workspaces")
    guard let workspace = spaces.first else { throw UIError.emptyWorkspace }
    guard socketPath == requestedSocket else { throw UIError.workspaceChanged }
    let restoring = connectedSocketPath == socket && self.workspace?.id == workspace.id
    rememberLocation()
    if let oldSocket = connectedSocketPath, let oldWorkspace = self.workspace {
      let oldKey = oldSocket + ":" + oldWorkspace.id
      workspaceDrafts[oldKey] = locationDrafts
      workspaceSelections[oldKey] = selection
      workspaceContexts[oldKey] = contextOperationID
    }
    let workspaceKey = socket + ":" + workspace.id
    let restoredSelection = restoring ? selection : workspaceSelections[workspaceKey]
    let restoredContext = restoring ? contextOperationID : workspaceContexts[workspaceKey]
    restoredWorkspaceSelection = restoredSelection != nil
    invalidateRemoteContext()
    self.client = candidate
    self.workspace = workspace
    currentWorkspace = recent ?? (restoring ? currentWorkspace : nil)
    socketPath = socket
    connectedSocketPath = socket
    planSession = UUID()
    generation = UUID()
    cancelDiffRead()
    clearDiffFailure()
    selectionCheckFailed = false
    lastRefreshFailure = nil
    lastMetadataFailure = nil
    if !restoring {
      workspaceSession = UUID()
      taskContext.reset()
      locationCache.removeAll()
      locationDrafts = workspaceDrafts[workspaceKey] ?? [:]
      cacheOrder.removeAll()
      readingSession = ReviewSession()
      onlyUnreviewedFiles = false
    }
    if restoring {
      // Retain only known running targets for explicit cancellation if metadata
      // recovery fails. These summaries cannot authorize preparation or edits.
      operations.removeAll { !$0.isRunning }
      pinnedOperations = pinnedOperations.filter { $0.value.isRunning }
      unresolvedOperationIDs = Set(operations.map(\.id)).union(pinnedOperations.keys)
    } else {
      operations = []
      pinnedOperations = [:]
      unresolvedOperationIDs = []
    }
    contextOperationID = restoredContext
    let cached = restoring ? restoredSelection.flatMap { locationCache[$0] } : nil
    stashes = cached?.stashes ?? []
    stashError = nil
    clearStashReview()
    selectedStashOID = cached?.selectedStashOID
    stashDetail = cached?.stashDetail
    workingReview = cached?.workingReview
    tasks = [:]
    events = []
    eventCursor = 0
    selection = restoredSelection ?? workspace.repositories.first.map { .init(repoId: $0.id) }
    repository = cached?.repository
    diff = cached?.diff
    let restoredDraft = selection.flatMap { locationDrafts[$0] }
    selectedFile = restoredDraft?.selectedFile ?? ""
    staged = restoredDraft?.staged ?? false
    commitMessage = restoredDraft?.commitMessage ?? ""
    lastUpdated = cached?.lastUpdated
    validatingSelection = true
    showingWelcome = false
    configureTaskContext()
    // A prior workspace read may still be finishing. It cannot publish after generation changed.
    while refreshing { try await Task.sleep(for: .milliseconds(20)) }
    await refresh()
  }

  public func selectRepository(_ id: String) {
    // Repository navigation preserves the explicitly chosen folder kind.
    // Task context may remain active while reviewing an original checkout.
    select(.init(repoId: id, opId: selection?.opId))
  }
  public func select(_ value: WorktreeSelection, leaveTask: Bool = false) {
    let contextID = value.opId ?? (leaveTask || contextOperation?.repos.contains(where: { $0.id == value.repoId }) == false ? nil : activeContextOperationID)
    guard !busy, value != selection || contextID != contextOperationID else { return }
    if value == selection {
      contextOperationID = contextID
      configureTaskContext()
      Task { await taskContext.refresh() }
      return
    }
    invalidateRemoteContext()
    clearDiffFailure()
    selectionCheckFailed = false
    lastRefreshFailure = nil
    lastMetadataFailure = nil
    rememberLocation()
    let version = UUID()
    generation = version
    cancelDiffRead()
    contextOperationID = contextID
    selection = value
    configureTaskContext()
    let cached = locationCache[value]
    let draft = locationDrafts[value]
    stashes = cached?.stashes ?? []
    stashError = nil
    selectedStashOID = cached?.selectedStashOID
    stashDetail = cached?.stashDetail
    workingReview = cached?.workingReview
    repository = cached?.repository
    diff = cached?.diff
    selectedFile = draft?.selectedFile ?? ""
    staged = draft?.staged ?? false
    commitMessage = draft?.commitMessage ?? ""
    lastUpdated = cached?.lastUpdated
    validatingSelection = true
    error = nil
    errorDetails = nil
    Task {
      // A superseded read may still be in flight. Refresh this selection as soon as it ends.
      while refreshing {
        guard generation == version else { return }
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard generation == version, validatingSelection else { return }
      await refresh()
    }
  }
  private func rememberLocation() {
    guard let selection else { return }
    locationDrafts[selection] = LocationDraft(
      selectedFile: selectedFile, staged: staged, commitMessage: commitMessage)
    // Large diffs are fetched again; retaining every diff would undermine the memory budget.
    let cachedDiff = diff.flatMap {
      $0.text.utf8.count + $0.header.utf8.count + $0.hunks.reduce(0) { $0 + $1.utf8.count }
        <= 512 * 1024 ? $0 : nil
    }
    locationCache[selection] = CachedLocation(
      repository: repository, diff: cachedDiff, stashes: stashes,
      selectedStashOID: selectedStashOID, stashDetail: stashDetail,
      workingReview: workingReview, lastUpdated: lastUpdated)
    cacheOrder.removeAll { $0 == selection }
    cacheOrder.append(selection)
    while cacheOrder.count > 6 { locationCache.removeValue(forKey: cacheOrder.removeFirst()) }
  }
  public func selectTask(_ op: WorkbenchOperation) {
    guard let repo = op.repos.first(where: { $0.state == "ready" }) ?? op.repos.first else {
      return
    }
    select(.init(repoId: repo.id, opId: op.id))
  }
  public func selectInitialTask(preferredRepository: String? = nil) async {
    if let op = operations.first(where: { $0.repos.contains { $0.hasWorktree } })
      ?? operations.first
    {
      if let preferredRepository, op.repos.contains(where: { $0.id == preferredRepository }) {
        select(.init(repoId: preferredRepository, opId: op.id))
      } else {
        selectTask(op)
      }
      // Wait for any in-flight old selection read to finish, then refresh this one.
      while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
      await refresh()
    }
  }

  public func refresh(forceDiff: Bool = false) async {
    if forceDiff && refreshing {
      let version = generation
      while refreshing {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        guard version == generation else { return }
      }
    }
    guard let client, !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let version = generation
    let location = selection
    var metadataFailures: [String] = []
    do {
      let ops: [WorkbenchOperation]
      do {
        ops = try await client.call("list_operations")
      } catch {
        guard version == generation else { return }
        unresolvedOperationIDs.formUnion(activeOperationIDs)
        unresolvedOperationIDs.formUnion(operations.map(\.id))
        unresolvedOperationIDs.formUnion(pinnedOperations.keys)
        configureTaskContext()
        throw error
      }
      guard version == generation else { return }
      if operations != ops { operations = ops }
      let updateSocket = connectedSocketPath ?? socketPath
      let updateIdentity = UpdateWorkspaceIdentity(socket: updateSocket, workspaceID: workspace?.id ?? "")
      let previouslyRunning = updateRunningOperations[updateIdentity] ?? []
      for op in ops { rememberUpdateOperation(op, identity: updateIdentity, title: workspaceTitle) }
      // list_operations is paginated. Absence cannot prove an old running task finished.
      for id in previouslyRunning.subtracting(Set(ops.map(\.id))).subtracting(activeOperationIDs).sorted() {
        do {
          let op: WorkbenchOperation = try await client.call("get_operation", params: ["op_id": .string(id)])
          guard version == generation else { return }
          guard op.id == id else { continue }
          rememberUpdateOperation(op, identity: updateIdentity, title: workspaceTitle)
        } catch {
          guard version == generation else { return }
          // Keep the restart block until this same service confirms a terminal status.
        }
      }
      let requiredIDs = activeOperationIDs
      var pinned: [String: WorkbenchOperation] = [:]
      var unresolved: Set<String> = []
      for id in requiredIDs.sorted() {
        if let listed = ops.first(where: { $0.id == id }) {
          pinned[id] = listed
        } else {
          do {
            let value: WorkbenchOperation = try await client.call("get_operation", params: ["op_id": .string(id)])
            guard version == generation, requiredIDs == activeOperationIDs else { return }
            guard value.id == id else { throw UIError.operationIdentityMismatch }
            pinned[id] = value
          } catch {
            guard version == generation, requiredIDs == activeOperationIDs else { return }
            // Keep known identity/drafts for display, but never authorize Task
            // context or worktree edits using a summary that failed to refresh.
            pinned[id] = pinnedOperations[id]
            unresolved.insert(id)
            metadataFailures.append("선택한 작업 정보를 확인하지 못했습니다.")
          }
        }
      }
      if pinnedOperations != pinned { pinnedOperations = pinned }
      for op in pinned.values { rememberUpdateOperation(op, identity: updateIdentity, title: workspaceTitle) }
      if unresolvedOperationIDs != unresolved { unresolvedOperationIDs = unresolved }
      // Apply lookup authority before awaiting unrelated display metadata.
      configureTaskContext()
      let neededDetails = pinned.values.sorted { $0.id < $1.id } + ops.filter { !requiredIDs.contains($0.id) }
      for op in neededDetails.filter({ tasks[$0.taskId] == nil }).prefix(8) {
        do {
          let detail: TaskDetail = try await client.call("get_task", params: ["task_id": .string(op.taskId)])
          guard version == generation else { return }
          tasks[detail.id] = detail
        } catch {
          guard version == generation else { return }
          metadataFailures.append("작업 정보를 읽지 못했습니다.")
        }
      }
      configureTaskContext()
      await taskContext.refresh()
      guard version == generation else { return }
      do {
        let newEvents: [OperationEvent] = try await client.call("events", params: ["cursor": .number(Double(eventCursor)), "latest": .bool(eventCursor == 0)])
        guard version == generation else { return }
        if !newEvents.isEmpty { events.append(contentsOf: newEvents) }
        if let last = newEvents.last { eventCursor = last.sequence }
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
      } catch {
        guard version == generation else { return }
        metadataFailures.append("준비 기록을 읽지 못했습니다.")
      }
      if let location {
        do {
          let entries: [GitStash] = try await client.call(
            "list_stashes", params: ["repo_id": .string(location.repoId)])
          guard version == generation else { return }
          if stashes != entries { stashes = entries }
          if stashError != nil { stashError = nil }
          if let selectedStashOID, !entries.contains(where: { $0.oid == selectedStashOID }) {
            let previousReview = workingReview
            clearStashReview()
            cancelDiffRead()
            diff = nil
            staged = previousReview?.staged ?? false
            selectedFile = previousReview?.path ?? ""
            stashError = "선택한 stash가 외부에서 삭제되었습니다. 현재 변경으로 돌아왔습니다."
          }
        } catch {
          guard version == generation else { return }
          stashError = "Stash 목록을 읽지 못했습니다. 새로고침해 주세요."
        }
        if let opId = location.opId, !unresolvedOperationIDs.contains(opId),
          let target = operationSummary(for: opId)?.repos.first(where: { $0.id == location.repoId }),
          !target.hasWorktree
        {
          if repository != nil { repository = nil }
          if !isViewingStash && diff != nil { diff = nil }
        } else if !taskInformationUnavailable {
          let status: RepositoryStatus = try await client.call(
            "get_repo_status", params: params(for: location))
          guard version == generation else { return }
          let changed = repository?.snapshotHash != status.snapshotHash
          if repository != status { repository = status }
          if !isViewingStash {
            if !visibleFiles.contains(where: { $0.path == selectedFile }) {
              let fallback = visibleFiles.first?.path ?? ""
              if selectedFile != fallback { selectedFile = fallback }
            }
            if forceDiff { clearDiffFailure() }
            if selectedFile.isEmpty {
              clearDiffFailure()
              cancelDiffRead()
              diff = nil
            } else if forceDiff || changed || diff?.path != selectedFile || diff?.staged != staged {
              await loadDiff()
            }
          }
        }
        if isViewingStash {
          if stashDetail == nil {
            await loadStashDetail()
          } else {
            if !visibleFiles.contains(where: { $0.path == selectedFile }) {
              let fallback = visibleFiles.first?.path ?? ""
              if selectedFile != fallback { selectedFile = fallback }
            }
            if forceDiff { clearDiffFailure() }
            if forceDiff || diff?.path != selectedFile { await loadDiff() }
          }
        }
      }
      guard version == generation else { return }
      if taskInformationUnavailable {
        if !validatingSelection { validatingSelection = true }
        if !selectionCheckFailed { selectionCheckFailed = true }
      } else {
        lastUpdated = Date()
        if validatingSelection { validatingSelection = false }
        if selectionCheckFailed { selectionCheckFailed = false }
      }
      let metadataMessage = metadataFailures.isEmpty ? nil : Array(Set(metadataFailures)).sorted().joined(separator: " ")
        + (taskInformationUnavailable ? " 새로고침으로 작업과 폴더 정보를 확인해 주세요." : " 파일의 현재 상태는 별도로 확인했습니다. 새로고침으로 기록을 다시 불러오세요.")
      if let metadataMessage, metadataMessage != lastMetadataFailure,
        error == nil || error == lastMetadataFailure || error == lastRefreshFailure
      { error = metadataMessage; errorDetails = nil }
      if metadataMessage == nil, error == lastMetadataFailure, lastMetadataFailure != nil { error = nil; errorDetails = nil }
      lastMetadataFailure = metadataMessage
      if error == lastRefreshFailure && lastRefreshFailure != nil { error = nil; errorDetails = nil }
      lastRefreshFailure = nil
    } catch {
      guard version == generation else { return }
      // Keep mutation guards until a fresh coherent read succeeds. An error
      // is no longer presented as endless loading or re-opened every poll.
      if !validatingSelection { validatingSelection = true }
      if !selectionCheckFailed { selectionCheckFailed = true }
      let message = UserFacingFailure.message(error)
      if lastRefreshFailure != message {
        report(error)
        lastRefreshFailure = message
      }
    }
  }
  private func configureTaskContext() {
    guard let client, let selection, let workspace, let connectedSocketPath else { return }
    taskContext.configure(client: client, workspace: connectedSocketPath + ":" + workspace.id,
      location: selection, contextOperationID: activeContextOperationID, operation: contextOperation,
      operationResolved: activeContextOperationID.map { !unresolvedOperationIDs.contains($0) } ?? true,
      title: taskTitle,
      updateOrigin: workspaceTitle + " · " + (workspace.repositories.first { $0.id == selection.repoId }?.path ?? connectedSocketPath) + " · " + taskTitle)
  }
  public func chooseFile(_ path: String, staged: Bool? = nil) {
    clearDiffFailure()
    cancelDiffRead()
    if let staged { self.staged = staged }
    selectedFile = path
    diff = nil
    Task { await loadDiff(debounce: true) }
  }
  public func chooseStaged(_ value: Bool) {
    clearDiffFailure()
    cancelDiffRead()
    clearStashReview()
    staged = value
    if !visibleFiles.contains(where: { $0.path == selectedFile }) {
      selectedFile = visibleFiles.first?.path ?? ""
    }
    diff = nil
    Task { await loadDiff(debounce: true) }
  }
  private func loadDiff(debounce: Bool = false) async {
    cancelDiffRead()
    let version = UUID()
    diffGeneration = version
    guard let client, let selection, !selectedFile.isEmpty, repository != nil || isViewingStash
    else {
      diff = nil
      return
    }
    let locationVersion = generation
    let readID = DiffReadID(location: selection, path: selectedFile, staged: staged,
      stash: selectedStashOID, snapshot: repository?.snapshotHash)
    guard failedDiffRead != readID else { return }
    diffError = nil
    var values = params(for: selection)
    values["path"] = .string(selectedFile)
    values["staged"] = .bool(staged)
    let stashOID = selectedStashOID
    if let stashOID { values["stash_oid"] = .string(stashOID) }
    let request = Task<FileDiff, any Error> {
      // Coalesce navigation bursts before admitting expensive server reads.
      // Socket cancellation cannot undo a read already running in the engine.
      if debounce { try await Task.sleep(for: .milliseconds(80)) }
      try Task.checkCancellation()
      return try await client.call(stashOID == nil ? "get_diff" : "get_stash_diff", params: values)
    }
    diffRequest = request
    defer { if version == diffGeneration { diffRequest = nil } }
    do {
      let value = try await withTaskCancellationHandler {
        try await request.value
      } onCancel: { request.cancel() }
      guard
        version == diffGeneration && locationVersion == generation && stashOID == selectedStashOID
      else { return }
      diff = value
      failedDiffRead = nil
    } catch {
      if error is CancellationError { return }
      if version == diffGeneration && locationVersion == generation {
        diff = nil
        failedDiffRead = readID
        diffError = UserFacingFailure.message(error)
      }
    }
  }
  private func cancelDiffRead() {
    diffGeneration = UUID()
    diffRequest?.cancel()
    diffRequest = nil
  }
  private func clearDiffFailure() { diffError = nil; failedDiffRead = nil }
  public func retryDiff() async { clearDiffFailure(); await loadDiff() }
  private func clearStashReview() {
    selectedStashOID = nil
    stashDetail = nil
    workingReview = nil
  }
  public func revealStashes() { stashFocusRequest += 1 }
  public func chooseStash(_ stash: GitStash) {
    guard !busy else { return }
    clearDiffFailure()
    cancelDiffRead()
    if !isViewingStash { workingReview = WorkingReview(path: selectedFile, staged: staged) }
    selectedStashOID = stash.oid
    stashDetail = nil
    staged = false
    selectedFile = ""
    diff = nil
    Task { await loadStashDetail() }
  }
  private func loadStashDetail() async {
    guard let client, let selection, let requestedOID = selectedStashOID else { return }
    let version = generation
    do {
      let detail: StashDetail = try await client.call(
        "get_stash",
        params: [
          "repo_id": .string(selection.repoId), "stash_oid": .string(requestedOID),
        ])
      guard generation == version && selectedStashOID == requestedOID else { return }
      stashDetail = detail
      stashError = nil
      if !visibleFiles.contains(where: { $0.path == selectedFile }) {
        selectedFile = visibleFiles.first?.path ?? ""
      }
      await loadDiff()
    } catch {
      guard generation == version && selectedStashOID == requestedOID else { return }
      stashError = "Stash 내용을 읽지 못했습니다. 목록을 새로고침해 주세요."
    }
  }
  public func showWorkingChanges() {
    clearDiffFailure()
    let previousReview = workingReview
    clearStashReview()
    cancelDiffRead()
    staged = previousReview?.staged ?? false
    selectedFile = previousReview?.path ?? ""
    if !visibleFiles.contains(where: { $0.path == selectedFile }) {
      selectedFile = visibleFiles.first?.path ?? ""
    }
    diff = nil
    Task { await loadDiff() }
  }
  public func stageHunk(_ index: Int) async {
    guard let selection, let diff else { return }
    await stageHunk(index, from: diff, at: selection)
  }
  public func stageSelectedFile() async {
    guard let selection, let repository else { return }
    await stageFile(selectedFile, staged: staged, expectedSnapshot: repository.snapshotHash, at: selection)
  }
  public func stageFile(_ path: String, staged: Bool, expectedSnapshot: String, at location: WorktreeSelection) async {
    guard let client, location == selection, canStageSelectedFile,
      path == selectedFile, staged == self.staged, expectedSnapshot == repository?.snapshotHash
    else {
      error = fileStagingUnavailableReason
        ?? "선택한 파일이나 변경 상태가 바뀌었습니다. 현재 파일을 다시 확인한 뒤 스테이징하세요."
      errorDetails = nil
      return
    }
    var values = params(for: location)
    values["path"] = .string(path)
    values["staged"] = .bool(staged)
    values["snapshot_hash"] = .string(expectedSnapshot)
    await mutation("stage_file", action: "파일 전체 \(staged ? "스테이징 취소" : "스테이징") · \(path)") {
      let _: MutationResult = try await client.call("stage_file", params: values)
    }
  }
  public func stageHunk(_ index: Int, from diff: FileDiff, at selection: WorktreeSelection) async {
    guard let client, selection == self.selection, canEdit, canUseRenderedDiff,
      diff.canStageHunks, self.diff?.canStageHunks == true, diff.hunks.indices.contains(index),
      diff.contentIdentity == self.diff?.contentIdentity, diff.snapshotHash == repository?.snapshotHash,
      diff.path == selectedFile, diff.staged == staged else {
      error = "변경이 바뀌었거나 확인 중입니다. 현재 변경을 다시 확인한 뒤 스테이징하세요."
      errorDetails = nil
      return
    }
    var values = params(for: selection)
    values["path"] = .string(diff.path)
    values["staged"] = .bool(diff.staged)
    values["hunk_index"] = .number(Double(index))
    values["snapshot_hash"] = .string(diff.snapshotHash)
    values["diff_hash"] = .string(diff.contentIdentity)
    await mutation("stage_hunk", action: "부분 \(diff.staged ? "스테이징 취소" : "스테이징") · \(diff.path)") {
      let _: MutationResult = try await client.call("stage_hunk", params: values)
    }
  }
  public func commit(expectedSnapshot: String? = nil, at location: WorktreeSelection? = nil) async {
    guard let client, let selection, let repository, canEdit, stagedCount > 0,
      location == nil || location == selection,
      !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    var values = params(for: selection)
    values["snapshot_hash"] = .string(expectedSnapshot ?? repository.snapshotHash)
    let submittedMessage = commitMessage
    let submittedRevision = commitDraft.revision
    values["message"] = .string(submittedMessage)
    await mutation("commit", action: "커밋") {
      let _: MutationResult = try await client.call("commit", params: values)
      if self.commitDraft.revision == submittedRevision { self.commitMessage = "" }
    }
  }
  public func operate(_ method: String, op: WorkbenchOperation) async {
    guard let client else { return }
    let eligibility = preparationEligibility(for: op.id)
    if ["retry_operation", "materialize"].contains(method), eligibility.recovery {
      if let current = operationSummary(for: op.id) { beginRecovery(current) }
      return
    }
    guard (method == "materialize" && eligibility.materialize)
      || (method == "retry_operation" && eligibility.retry)
      || (method == "cancel_operation" && eligibility.cancel) else { return }
    let updateIdentity = UpdateWorkspaceIdentity(
      socket: connectedSocketPath ?? socketPath, workspaceID: workspace?.id ?? "")
    let originTitle = workspaceTitle
    await mutation(method) {
      let receipt: WorkbenchOperation = try await client.call(method, params: ["op_id": .string(op.id)])
      // The confirmed receipt is authoritative even if follow-up reads fail or the user navigates.
      self.rememberUpdateOperation(receipt, identity: updateIdentity, title: originTitle)
    }
  }
  public func planTask(group: String, label: String, slug: String, mode: String) async throws
    -> WorkspaceTaskPlan
  {
    guard !busy, !remoteBusy else { throw UIError.busy }
    guard let client, let socket = connectedSocketPath else { throw UIError.notConnected }
    let session = planSession
    guard socketPath == socket else { throw UIError.workspaceChanged }
    let details: TaskPlan = try await client.call(
      "plan_task",
      params: [
        "group_id": .string(group), "label": .string(label), "task_slug": .string(slug),
        "mode": .string(mode),
      ])
    guard socketPath == socket, connectedSocketPath == socket else { throw UIError.workspaceChanged }
    guard planSession == session, self.client === client else { throw UIError.planInvalidated }
    return WorkspaceTaskPlan(details: details, session: session, socket: socket)
  }
  public func listBranches() async throws -> [GitBranch] {
    guard let client, let selection else { throw UIError.notConnected }
    return try await client.call("list_branches", params: params(for: selection))
  }
  public func branchHistory(_ branch: GitBranch) async throws -> [HistoryCommit] {
    guard let client, let selection else { throw UIError.notConnected }
    return try await client.call(
      "get_branch_history",
      params: [
        "repo_id": .string(selection.repoId), "branch_ref": .string(branch.fullRef),
        "tip_oid": .string(branch.tipOid),
      ])
  }
  public func executePlan(_ plan: WorkspaceTaskPlan, key: String) async throws {
    guard !busy, !remoteBusy else { throw UIError.busy }
    guard let client else { throw UIError.notConnected }
    guard plan.socket == socketPath, socketPath == connectedSocketPath else { throw UIError.workspaceChanged }
    guard plan.session == planSession else { throw UIError.planInvalidated }
    let originTitle = workspaceTitle
    let updateIdentity = UpdateWorkspaceIdentity(socket: plan.socket, workspaceID: workspace?.id ?? "")
    let originPath = currentWorkspace?.repositoryPath ?? workspace?.repositories.first?.path ?? plan.socket
    let warningID = plan.socket + ":" + key
    pendingTaskSubmissions += 1
    defer { pendingTaskSubmissions -= 1 }
    let op: WorkbenchOperation
    do {
      op = try await client.call(
        "execute_plan", params: ["plan_id": .string(plan.details.id), "idempotency_key": .string(key)])
    } catch {
      guard !(error is ServiceFailure),
        (error as? TransportFailure)?.requestMayHaveBeenSent != false else { throw error }
      updateUnknownTaskSubmissionRevision += 1
      let warning = TaskSubmissionWarning(id: warningID, workspaceTitle: originTitle,
        workspacePath: originPath, message: UIError.submissionOutcomeUnknown.localizedDescription)
      if !submissionWarnings.contains(where: { $0.id == warningID }) { submissionWarnings.append(warning) }
      throw UIError.submissionOutcomeUnknown
    }
    rememberUpdateOperation(op, identity: updateIdentity, title: originTitle)
    guard plan.session == planSession, self.client === client, plan.socket == socketPath
    else {
      report(UIError.workspaceChangedAfterSubmission)
      throw UIError.workspaceChangedAfterSubmission
    }
    if !operations.contains(where: { $0.id == op.id }) { operations.insert(op, at: 0) }
    selectTask(op)
    await refresh()
  }
  public func dismissSubmissionWarning(_ id: String) {
    submissionWarnings.removeAll { $0.id == id }
  }
  private func mutation(_ method: String, action: String? = nil, _ work: () async throws -> Void) async {
    let originSocket = connectedSocketPath ?? socketPath
    let originGeneration = generation
    let originSelection = selection
    let originTitle = workspaceTitle
    let originPath = repository?.path ?? currentWorkspace?.repositoryPath
      ?? workspace?.repositories.first?.path ?? originSocket
    let warningID = originSocket + ":" + method + ":" + UUID().uuidString
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await work()
    } catch {
      let service = error as? ServiceFailure
      let unknown = action != nil && (error as? TransportFailure)?.requestMayHaveBeenSent != false && (service == nil
        || ["git_write_outcome_unknown", "write_outcome_unknown"].contains(service?.code ?? ""))
      if unknown, let action {
        submissionWarnings.append(TaskSubmissionWarning(id: warningID, workspaceTitle: originTitle,
          workspacePath: originPath, message: "\(action)\n\(UIError.gitWriteOutcomeUnknown.localizedDescription)"))
      }
      if generation == originGeneration, selection == originSelection, socketPath == originSocket {
        report(unknown ? UIError.gitWriteOutcomeUnknown : error)
      }
    }
    // Reading the display after a confirmed reply cannot change the write's outcome.
    while refreshing {
      guard generation == originGeneration, selection == originSelection, socketPath == originSocket else { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard generation == originGeneration, selection == originSelection, socketPath == originSocket else { return }
    await refresh()
  }
  private func params(for value: WorktreeSelection) -> [String: JSONValue] {
    var params: [String: JSONValue] = ["repo_id": .string(value.repoId)]
    if let id = value.opId { params["op_id"] = .string(id) }
    return params
  }
  public func openCurrentWorktree() {
    if let path = repository?.path {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }
  }
  public func copyCurrentPath() {
    guard let path = repository?.path else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }
}

enum UIError: LocalizedError {
  case busy, staleRemote, remoteOutcomeUnknown, gitWriteOutcomeUnknown, emptyWorkspace, notConnected, operationIdentityMismatch, workspaceChanged, workspaceChangedAfterSubmission, submissionOutcomeUnknown, planInvalidated
  var errorDescription: String? {
    switch self {
    case .busy: "다른 작업을 진행 중입니다. 완료된 뒤 다시 시도해 주세요."
    case .staleRemote: "저장소나 원격 정보가 바뀌었습니다. 원격 정보를 새로 읽고 다시 확인해 주세요."
    case .remoteOutcomeUnknown: "원격 작업의 완료 여부를 확인하지 못했습니다. 같은 요청을 반복하기 전에 이 프로젝트의 Git 상태와 서버의 브랜치를 확인해 주세요."
    case .gitWriteOutcomeUnknown: "Git 변경의 완료 여부를 확인하지 못했습니다. 같은 동작을 반복하기 전에 이 폴더의 변경 상태와 Git 기록을 확인해 주세요."
    case .emptyWorkspace: "등록된 워크스페이스가 없습니다."
    case .notConnected: "로컬 서비스에 먼저 연결하세요."
    case .operationIdentityMismatch: "선택한 작업과 다른 정보가 반환되었습니다. 새로고침해 주세요."
    case .workspaceChanged: "프로젝트가 바뀌었습니다. 현재 프로젝트에서 계획을 다시 확인해 주세요."
    case .workspaceChangedAfterSubmission: "프로젝트가 바뀌었습니다. 이전 요청의 실행 여부는 이전 프로젝트의 작업 목록에서 확인해 주세요."
    case .submissionOutcomeUnknown: "작업 준비 요청의 접수 여부를 확인하지 못했습니다. 같은 요청을 반복하기 전에 이 프로젝트의 작업 목록과 실제 Git 상태를 확인해 주세요."
    case .planInvalidated: "다시 연결하여 이전 계획을 사용할 수 없습니다. 입력은 유지했습니다. 현재 상태로 계획을 다시 확인해 주세요."
    }
  }
}

fileprivate struct RemoteScope: Hashable, Sendable {
  let session: UUID
  let connection: UUID
  let socket: String
  let location: WorktreeSelection
}
public enum RemoteAction: String, Sendable {
  case fetch = "fetch_remote", pull = "pull_remote", push = "push_remote", configure = "configure_remote"
  public var label: String {
    switch self { case .fetch: "Fetch"; case .pull: "Pull"; case .push: "Push"; case .configure: "원격 설정" }
  }
}
public struct RemoteActionPlan: Identifiable, Sendable {
  public let id: UUID
  public let action: RemoteAction
  public let repositoryID: String
  public let repositoryPath: String
  public let localBranch: String?
  public let remote: String
  public let url: String
  public let branch: String
  public let stateHash: String
  fileprivate let snapshot: String?
  fileprivate let scope: RemoteScope
  fileprivate let title: String
}

extension WorkbenchStore {
  private var currentRemoteScope: RemoteScope? {
    guard client != nil, let selection, let socket = connectedSocketPath, socketPath == socket else { return nil }
    return RemoteScope(session: workspaceSession, connection: planSession, socket: socket, location: selection)
  }
  public var remoteBusy: Bool { currentRemoteScope.map { remoteMutations.contains($0) } ?? false }
  public var canUseRemotes: Bool {
    !busy && !validatingSelection && !taskPreparationIncomplete && !hasRunningOperation
      && currentRemoteScope != nil && repository != nil && remoteState != nil
      && remoteScope == currentRemoteScope && remoteSnapshot == repository?.snapshotHash
  }
  public func reportRemote(_ failure: any Error) { remoteError = UserFacingFailure.message(failure) }
  private func invalidateRemoteContext() {
    remoteReadID = UUID(); remoteState = nil; remoteScope = nil; remoteSnapshot = nil
    remoteLoading = false; remoteError = nil; remoteMessage = nil
  }
  public func loadRemoteState() async {
    guard let client, let scope = currentRemoteScope else { return }
    let request = UUID(); remoteReadID = request
    remoteLoading = true; remoteError = nil
    let snapshot = repository?.snapshotHash
    defer { if remoteReadID == request { remoteLoading = false } }
    do {
      let state: RemoteState = try await client.call("get_remote_state", params: params(for: scope.location))
      guard request == remoteReadID, currentRemoteScope == scope, self.client === client,
        snapshot == repository?.snapshotHash else { return }
      remoteState = state; remoteScope = scope; remoteSnapshot = snapshot
    } catch {
      guard request == remoteReadID, currentRemoteScope == scope else { return }
      remoteState = nil; remoteScope = nil; remoteError = UserFacingFailure.message(error)
    }
  }
  public func remotePlan(_ action: RemoteAction, remote name: String, branch: String = "") throws -> RemoteActionPlan {
    guard canUseRemotes, !remoteBusy, !remoteLoading, let scope = currentRemoteScope,
      scope == remoteScope, let state = remoteState, remoteSnapshot == repository?.snapshotHash
    else { throw UIError.staleRemote }
    let remote = state.remotes.first { $0.name == name }
    if action != .configure {
      guard let remote, remote.supported else { throw UIError.staleRemote }
    }
    if action == .pull || action == .push {
      guard state.branch != nil, state.head != nil, !branch.isEmpty else { throw UIError.staleRemote }
    }
    return RemoteActionPlan(id: UUID(), action: action, repositoryID: scope.location.repoId,
      repositoryPath: state.repositoryPath, localBranch: state.branchName, remote: name,
      url: action == .push ? (remote?.pushUrl ?? "") : (remote?.fetchUrl ?? ""), branch: branch,
      stateHash: state.stateHash, snapshot: remoteSnapshot, scope: scope, title: workspaceTitle)
  }
  public func executeRemote(_ plan: RemoteActionPlan, configuration: String? = nil,
                            url: String? = nil, pushURL: String? = nil) async throws {
    guard let client, currentRemoteScope == plan.scope, remoteScope == plan.scope,
      canUseRemotes, !remoteBusy, remoteState?.stateHash == plan.stateHash,
      repository?.snapshotHash == plan.snapshot else { throw UIError.staleRemote }
    var values = params(for: plan.scope.location)
    values["expected_state_hash"] = .string(plan.stateHash)
    if plan.action == .configure {
      guard let configuration, ["add", "update", "remove"].contains(configuration) else { throw UIError.staleRemote }
      values["action"] = .string(configuration); values["name"] = .string(plan.remote)
      if let url { values["url"] = .string(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
      if let pushURL, !pushURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        values["push_url"] = .string(pushURL.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    } else {
      values["remote"] = .string(plan.remote)
      if plan.action == .pull || plan.action == .push { values["branch"] = .string(plan.branch) }
    }
    remoteMutations.insert(plan.scope); remoteError = nil; remoteMessage = nil
    defer { remoteMutations.remove(plan.scope) }
    let result: RemoteMutationResult
    do {
      result = try await client.call(plan.action.rawValue, params: values)
    } catch {
      let service = error as? ServiceFailure
      let unknown = (error as? TransportFailure)?.requestMayHaveBeenSent != false
        && (service == nil || ["write_outcome_unknown", "git_write_outcome_unknown", "remote_outcome_unknown"].contains(service?.code ?? ""))
      if unknown {
        let warning = TaskSubmissionWarning(id: plan.scope.socket + ":remote:" + plan.id.uuidString,
          workspaceTitle: plan.title, workspacePath: plan.repositoryPath,
          message: "\(plan.action.label) · \(plan.remote) / \(plan.branch)\n\(UIError.remoteOutcomeUnknown.localizedDescription)")
        submissionWarnings.append(warning)
      }
      if currentRemoteScope == plan.scope {
        remoteState = nil; remoteScope = nil
        remoteError = unknown ? UIError.remoteOutcomeUnknown.localizedDescription : UserFacingFailure.message(error)
      }
      throw unknown ? UIError.remoteOutcomeUnknown : error
    }
    // The result belongs to the captured folder, even when navigation changed during the request.
    guard currentRemoteScope == plan.scope, self.client === client else { return }
    remoteState = result.state; remoteScope = result.state == nil ? nil : plan.scope
    remoteSnapshot = repository?.snapshotHash
    remoteMessage = result.message + (result.refreshRequired ? " 원격 정보를 새로고침해 주세요." : "")
    // Git success is already established. Optional display refresh cannot relabel it as a failed write.
    await refresh(forceDiff: true)
    guard currentRemoteScope == plan.scope else { return }
    await loadRemoteState()
  }
  public func cloneRepository(url: String, destination: URL) async throws {
    guard !busy else { throw UIError.busy }
    busy = true; startupMessage = "저장소 복제 중…"
    defer { busy = false; startupMessage = nil }
    do {
      let session = try await runtime.cloneRepository(url: url, destination: destination)
      do { try await connectToService(socket: session.socketPath, recent: session.recent) }
      catch { throw StartupFailure.cloneCreated(session.recent.repositoryPath) }
      // The clone and workspace handshake are already confirmed. A recent-list
      // read failure is display metadata and must not invite a duplicate clone.
      do { recentWorkspaces = try await runtime.recentWorkspaces() }
      catch {
        errorDetails = error.localizedDescription
        self.error = "복제와 프로젝트 열기는 완료했습니다. 최근 프로젝트 목록을 읽지 못했습니다."
      }
    } catch {
      if case StartupFailure.cloneOutcomeUnknown(let path) = error {
        submissionWarnings.append(TaskSubmissionWarning(id: "clone:" + UUID().uuidString,
          workspaceTitle: destination.lastPathComponent, workspacePath: path, message: error.localizedDescription))
      }
      throw error
    }
  }
}

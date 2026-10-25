import AppKit
import SwiftUI
import WorkbenchProtocol
import WorkbenchRuntime
import WorkbenchUI

/// Renders our own live-data native view offscreen. Does not automate other apps or capture the desktop.
@main
struct NativePreview {
  @MainActor static func main() async throws {
    guard [3, 4, 6].contains(CommandLine.arguments.count) else {
      print(
        "usage: workbench-native-preview SOCKET|--welcome|--example OUTPUT.png [light|dark [WIDTH HEIGHT]]"
      )
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let dark = CommandLine.arguments.count >= 4 && CommandLine.arguments[3] == "dark"
    let highContrast = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_HIGH_CONTRAST"] == "1"
    let width = CommandLine.arguments.count == 6 ? Double(CommandLine.arguments[4]) ?? 1440 : 1440
    let height = CommandLine.arguments.count == 6 ? Double(CommandLine.arguments[5]) ?? 960 : 960
    guard (1100...3000).contains(width), (720...2000).contains(height) else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    app.appearance = NSAppearance(
      named: highContrast
        ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        : (dark ? .darkAqua : .aqua))
    let mode = CommandLine.arguments[1]
    let previewStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agw-preview-\(UUID().uuidString)")
    let runtime = WorkspaceRuntime(storageDirectory: previewStorage)
    let store = WorkbenchStore(socketPath: mode.hasPrefix("--") ? "" : mode, runtime: runtime)
    let preferenceSuite = "agw-preview-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: preferenceSuite)!
    defer { defaults.removePersistentDomain(forName: preferenceSuite) }
    let layout = LayoutPreferences(defaults: defaults)
    let reading = ReadingPreferences(defaults: defaults)
    let diffPresentation = DiffPresentationModel()
    if let value = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_CODE_SIZE"],
      let size = Double(value)
    {
      reading.setCodeSize(size)
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_COMPACT"] == "1" {
      reading.setDensity(.compact)
    }
    // The harness controls AppKit appearance, including Increase Contrast.
    layout.appearance = .system
    let dockSession = DockDragSession()
    if let name = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_LAYOUT"],
      let preset = LayoutPreset(rawValue: name)
    {
      layout.apply(preset)
    }
    if let name = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_GRAPH"],
      let placement = GraphPlacement(rawValue: name)
    {
      layout.update { $0.graph = placement }
    }
    if let visible = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_INSPECTOR"] {
      layout.update { $0.inspector = visible == "1" ? .visible : .hidden }
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_HISTORY"] == "0" {
      layout.update { $0.historyExpanded = false }
    }
    if mode == "--example" {
      await store.openExample()
    } else if mode != "--welcome" {
      await store.connect()
      await store.selectInitialTask(
        preferredRepository: ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_REPO"])
      // Socket-mode probes can exercise write guards even for a plain Stash render.
      try requireSyntheticFixture(store)
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_READINESS"] == "1" {
        try await verifyPreparationReadiness(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_STAGED"] == "1" {
        guard store.stagedCount > 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
        store.chooseStaged(true)
        store.commitMessage = "로그인 상태 처리 개선"
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_SWITCH"] == "1" {
        try await verifyFolderSwitching(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_REVIEW"] == "1"
        || ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_PERSONALIZATION"] == "1"
      {
        store.chooseFile("Sources/Session.swift", staged: false)
        for _ in 0..<200 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_CONTEXT"] == "1" {
        try await verifyTaskContext(store)
        layout.hidePane(.graph)
        layout.hidePane(.commit)
        layout.showPane(.details)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_ORIGINAL"] == "1",
        let selection = store.selection
      {
        store.select(.init(repoId: selection.repoId))
        try await waitForSelection(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_STASH"] == "1" {
        guard let stash = store.stashes.first else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        let originalHash = store.repository?.snapshotHash
        store.chooseStash(stash)
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard store.isViewingStash, store.stashDetail != nil, store.diff != nil, !store.canEdit,
          store.error == nil
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        // Exercise the actual store's read-only guards and return navigation, not OS clicks.
        store.commitMessage = "로그인 세션 처리 개선"
        await store.stageHunk(0)
        guard let stagingRefusal = store.error,
          stagingRefusal == "변경이 바뀌었거나 확인 중입니다. 현재 변경을 다시 확인한 뒤 스테이징하세요."
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        await store.commit()
        var values: [String: JSONValue] = ["repo_id": .string(store.selection!.repoId)]
        if let opID = store.selection?.opId { values["op_id"] = .string(opID) }
        let checked: RepositoryStatus = try await ServiceClient(socketPath: mode).call(
          "get_repo_status", params: values)
        guard checked.snapshotHash == originalHash, store.error == stagingRefusal else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        store.showWorkingChanges()
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard !store.isViewingStash, store.diff?.snapshotHash == originalHash else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        store.chooseStash(stash)
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard store.isViewingStash, store.stashDetail != nil,
          store.diff?.snapshotHash == stash.oid, !store.canEdit, store.error == stagingRefusal
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        // The probe deliberately triggered this visible read-only refusal.
        // Clear it only after the independent status check and navigation assertions.
        store.error = nil
        print(
          "Verified stash read-only guards, current snapshot preservation and return navigation")
      }
    }
    guard
      mode == "--welcome"
        || (store.workspace != nil && (store.repository != nil || store.pendingWorktree)
          && store.error == nil)
    else {
      throw NSError(
        domain: "NativePreview", code: 1,
        userInfo: [NSLocalizedDescriptionKey: store.error ?? "No prepared worktree to render"])
    }
    let branchModel = BranchBrowserModel()
    let branchMode = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_BRANCHES"] == "1"
    if branchMode {
      let selection = store.selection
      let before = store.repository?.snapshotHash
      await branchModel.load(store)
      guard branchModel.error == nil, branchModel.branches.contains(where: \.current),
        let remote = branchModel.branches.first(where: \.isRemote)
      else { throw CocoaError(.validationMissingMandatoryProperty) }
      branchModel.query = "origin/"
      guard !branchModel.filteredBranches.isEmpty,
        branchModel.filteredBranches.allSatisfy(\.isRemote)
      else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
      branchModel.query = ""
      await branchModel.select(remote, store: store)
      guard branchModel.error == nil, branchModel.commits.first?.oid == remote.tipOid,
        store.selection == selection, store.repository?.snapshotHash == before
      else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
      print(
        "Verified actual local/remote branch list, search and pinned per-branch history without folder selection changes"
      )
    }
    let remoteMode = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_REMOTE"] == "1"
    if remoteMode { await store.loadRemoteState() }
    let settingsMode =
      ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_LAYOUT_SETTINGS"] == "1"
    if settingsMode { _ = try seedSavedLayouts(layout) }
    var personalizationRequestedLayout: LayoutConfiguration?
    var personalizationPreviousLayout: LayoutConfiguration?
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_PERSONALIZATION"] == "1" {
      personalizationRequestedLayout = layout.configuration
      layout.apply(.classic)
      personalizationPreviousLayout = layout.configuration
      layout.apply(.balanced)
    }
    let content: AnyView
    if settingsMode {
      content = AnyView(
        LayoutOptions(
          layout: layout, reading: reading,
          initialSection: LayoutOptionsSection(
            rawValue: ProcessInfo.processInfo.environment[
              "WORKBENCH_PREVIEW_LAYOUT_SETTINGS_SECTION"]
              ?? "layouts") ?? .layouts
        )
        .background(Color(nsColor: .windowBackgroundColor)))
    } else if branchMode {
      content = AnyView(BranchesView(store: store, model: branchModel))
    } else {
      content = AnyView(
        WorkbenchRoot(
          store: store,
          layout: layout, dockSession: dockSession, reading: reading,
          diffPresentation: diffPresentation
        ).overlay(alignment: .topTrailing) {
          if remoteMode {
            RemotePreviewOverlay(store: store).padding(.top, 100).padding(.trailing, 16)
          }
        })
    }
    let view = NSHostingView(
      rootView:
        content
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active)
        .frame(width: settingsMode ? 520 : width, height: settingsMode ? 620 : height))
    view.frame = NSRect(
      x: 0, y: 0, width: settingsMode ? 520 : width, height: settingsMode ? 620 : height)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    // Let SwiftUI resolve native control layout in this process's run loop.
    try await Task.sleep(for: .milliseconds(500))
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_REVIEW"] == "1" {
      try await verifyReviewContinuity(store, view: view, layout: layout)
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_DOCKING"] == "1" {
      try await verifyDocking(
        store, layout: layout, drag: dockSession, defaults: defaults, socket: mode)
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_PERSONALIZATION"] == "1" {
      try await verifyPersonalization(
        store, layout: layout, reading: reading, presentation: diffPresentation,
        drag: dockSession, defaults: defaults, view: view, socket: mode,
        requestedLayout: personalizationRequestedLayout!,
        focusPrevious: personalizationPreviousLayout!)
    }
    let dockScene = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_DOCK_SCENE"] ?? "default"
    if dockScene != "default" {
      layout.hidePane(.details)
      if dockScene == "free" {
        layout.showPane(.commit)
        try await Task.sleep(for: .milliseconds(100))
        try await dock(.stash, beside: .diff, edge: .left, layout: layout, drag: dockSession)
        try await dock(.graph, beside: .commit, edge: .bottom, layout: layout, drag: dockSession)
        try await dock(.files, beside: .diff, edge: .bottom, layout: layout, drag: dockSession)
      } else if dockScene == "tabs" {
        try await dock(.files, beside: .diff, edge: .center, layout: layout, drag: dockSession)
        try await dock(.graph, beside: .diff, edge: .center, layout: layout, drag: dockSession)
        layout.selectPane(.diff)
      } else if dockScene == "drag-preview" {
        guard let frame = dockSession.frames[.diff] else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        dockSession.drag(.stash, to: CGPoint(x: frame.minX + 20, y: frame.midY))
      } else if dockScene == "branches" {
        layout.showPane(.branches)
      } else if dockScene == "empty" {
        for pane in WorkbenchPane.allCases { layout.hidePane(pane) }
      }
      try await Task.sleep(for: .milliseconds(dockScene == "branches" ? 500 : 160))
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_LAYOUT"] == "1" {
      let savedLayout = layout.configuration
      let selection = store.selection
      let snapshot = store.repository?.snapshotHash
      let selectedFile = store.selectedFile
      let staged = store.staged
      let draft = store.commitMessage
      for preset in LayoutPreset.allCases {
        layout.apply(preset)
        try await Task.sleep(for: .milliseconds(60))
        view.layoutSubtreeIfNeeded()
        guard store.selection == selection, store.repository?.snapshotHash == snapshot,
          store.selectedFile == selectedFile, store.staged == staged, store.commitMessage == draft,
          LayoutPreferences(defaults: defaults).configuration == layout.configuration
        else { throw CocoaError(.validationMissingMandatoryProperty) }
      }
      layout.update { $0 = savedLayout }
      try await Task.sleep(for: .milliseconds(60))
      if let selection, !mode.hasPrefix("--") {
        var params: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
        if let opID = selection.opId { params["op_id"] = .string(opID) }
        let checked: RepositoryStatus = try await ServiceClient(socketPath: mode).call(
          "get_repo_status", params: params)
        guard checked.snapshotHash == snapshot else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
      }
      print(
        "Verified layout presets and saved settings with the same mounted native root; live selection, file, staging and draft preserved"
      )
    }
    if let name = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_FOCUS_PANE"],
      let pane = WorkbenchPane(rawValue: name)
    {
      layout.showPane(pane)
      layout.focusPane(pane)
      try await settle(view)
    }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("Rendered native SwiftUI/AppKit view: \(CommandLine.arguments[2])")
    window.contentView = nil
    await store.stopIdleServices()
    if mode.hasPrefix("--") { try? FileManager.default.removeItem(at: previewStorage) }
  }

  @MainActor private static func requireSyntheticFixture(_ store: WorkbenchStore) throws {
    guard let value = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_FIXTURE_ROOT"] else {
      throw NSError(
        domain: "PreviewScope", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Mutation probes require scripts/native_preview.py's private synthetic fixture"
        ])
    }
    let root = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
    let parent = root.deletingLastPathComponent()
    let temporary = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().standardizedFileURL
    func inside(_ path: String) -> Bool {
      let components = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        .pathComponents
      return components.starts(with: root.pathComponents)
        && components.count > root.pathComponents.count
    }
    guard root.lastPathComponent == "fixture",
      parent.lastPathComponent.hasPrefix("workbench-preview-"),
      parent.deletingLastPathComponent().pathComponents == temporary.pathComponents,
      let marker = try? String(
        contentsOf: root.appendingPathComponent(".native-preview-fixture"), encoding: .utf8),
      URL(fileURLWithPath: marker).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        == root.pathComponents,
      let repositories = store.workspace?.repositories, !repositories.isEmpty,
      repositories.allSatisfy({ inside($0.path) }),
      store.repository.map({ inside($0.path) }) ?? true
    else {
      throw NSError(
        domain: "PreviewScope", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "Refused verification outside the synthetic preview fixture"
        ])
    }
  }

  @MainActor private static func waitForSelection(_ store: WorkbenchStore) async throws {
    for _ in 0..<1000 {
      if !store.validatingSelection { return }
      if let error = store.error {
        throw NSError(
          domain: "NativePreview", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CocoaError(.validationMissingMandatoryProperty)
  }

  @MainActor private static func diffScroll(in view: NSView) -> NSScrollView? {
    if view.identifier?.rawValue == "workbench.diff-scroll-position" {
      return view.enclosingScrollView
    }
    for child in view.subviews {
      if let found = diffScroll(in: child) { return found }
    }
    return nil
  }

  @MainActor private static func verifyTaskContext(_ store: WorkbenchStore) async throws {
    guard let selection = store.selection, let opID = selection.opId, let initial = store.repository
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let client = ServiceClient(socketPath: store.socketPath)
    let model = store.taskContext
    await model.refresh()
    guard let originalWorkflow = model.workflow, originalWorkflow.canWrite else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let firstID = UUID().uuidString.lowercased(), secondID = UUID().uuidString.lowercased()
    let guideID = UUID().uuidString.lowercased()
    var values: [String: JSONValue] = [
      "repo_id": .string(selection.repoId), "context_op_id": .string(opID),
      "expected_context_revision": .number(Double(originalWorkflow.context.revision)),
      "expected_workflow_revision": .number(Double(originalWorkflow.workflow.revision)),
      "purpose": .string("앱을 다시 열어도 로그인 상태가 이어지도록 세션 복원을 개선합니다."),
      "criteria": .array([
        .object(["id": .string(firstID), "text": .string("재시작 후 세션이 복원된다")]),
        .object(["id": .string(secondID), "text": .string("만료된 세션은 로그인 화면으로 돌아간다")]),
      ]),
      "references": .array([.string("docs/session-recovery.md")]),
      "notes": .string("오프라인·만료 세션 테스트를 추가하고 API 저장소의 준비 실패를 확인해야 합니다."),
      "guides": .array([.object(["id": .string(guideID), "repo_id": .string(selection.repoId),
        "kind": .string("procedure"), "path": .string("README.md"), "expected_sha256": .null])]),
    ]
    let _: TaskWorkflowBundle = try await client.call("save_task_workflow", params: values)
    await model.refresh()
    guard model.bundle?.context.revision == 1,
      let guide = await model.readGuide(id: guideID, at: model.identity), guide.status == "unread",
      !guide.content.isEmpty, await model.pinGuide(guide, guideID: guideID, at: model.identity),
      let pinned = await model.readGuide(id: guideID, at: model.identity), pinned.status == "matching"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    await model.runCheck(snapshot: initial.snapshotHash, at: selection)
    guard model.bundle?.verifications.first?.kind == "git_check",
      model.bundle?.verifications.first?.verdict == "passed"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let beforeCount = model.bundle?.verifications.count
    let staleRecord = await model.record(kind: "human_report", verdict: "passed", command: "", note: "must not save", at: "obsolete-screen")
    guard !staleRecord, model.bundle?.verifications.count == beforeCount else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let recorded = await model.record(kind: "ai_report", verdict: "passed", command: "swift test (synthetic AI report)",
      note: "합성 AI 보고입니다. 앱은 테스트 실행을 관찰하지 않았습니다.",
      criterionIDs: [firstID], claimedReviewedState: .init(head: initial.snapshot.head, snapshotHash: initial.snapshotHash),
      provider: "Synthetic fixture", model: "fixture-only", artifacts: ["evidence/session-test.log"],
      reportStatus: "incomplete", at: model.identity)
    guard recorded, let report = model.bundle?.verifications.first, report.kind == "ai_report",
      report.afterSnapshotHash == nil, let metadata = model.workflow?.evidence.first,
      metadata.criteria.first?.id == firstID, metadata.criteria.first?.revision == 1,
      metadata.reportStatus == "incomplete", metadata.claimedReviewedState?.snapshotHash == initial.snapshotHash
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let file = URL(fileURLWithPath: initial.path).appendingPathComponent("Sources/Session.swift")
    let original = try String(contentsOf: file, encoding: .utf8)
    try (original + "// whitespace fixture   \n").write(to: file, atomically: false, encoding: .utf8)
    await store.refresh()
    guard let changed = store.repository, changed.snapshotHash != initial.snapshotHash,
      changed.snapshot.head == initial.snapshot.head, changed.snapshot.indexHash == initial.snapshot.indexHash
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    await model.runCheck(snapshot: changed.snapshotHash, at: selection)
    guard model.bundle?.verifications.first?.verdict == "failed", let current = model.workflow else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    values["expected_context_revision"] = .number(Double(current.context.revision))
    values["expected_workflow_revision"] = .number(Double(current.workflow.revision))
    values["criteria"] = .array([
      .object(["id": .string(secondID), "text": .string("만료된 세션은 로그인 화면으로 돌아간다")]),
      .object(["id": .string(firstID), "text": .string("오프라인에서도 재시작 후 세션이 복원된다")]),
    ])
    values["guides"] = .array([.object(["id": .string(guideID), "repo_id": .string(selection.repoId),
      "kind": .string("procedure"), "path": .string("README.md"), "expected_sha256": .string(guide.sha256)])])
    let _: TaskWorkflowBundle = try await client.call("save_task_workflow", params: values)
    await model.refresh()
    guard let updated = model.workflow, updated.workflow.criteria.first?.id == secondID,
      updated.workflow.criteria.first?.revision == 1, updated.workflow.criteria.last?.id == firstID,
      updated.workflow.criteria.last?.revision == 2,
      updated.evidence.first?.criteria.first?.revision == 1,
      let handoff = await model.handoff(), handoff.contains("### \"api\""), handoff.contains("### \"ios-app\""),
      handoff.contains("오프라인에서도"), handoff.contains("보고자가 검토했다고 주장한"),
      handoff.contains("보고 미완료"), handoff.contains("기준 SHA-256"),
      !handoff.contains(guide.content), handoff.contains("통합 검증/승인을 뜻하지 않습니다")
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try handoff.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).deletingPathExtension().appendingPathExtension("handoff.txt"), atomically: true, encoding: .utf8)
    let revision = model.bundle?.context.revision
    await store.connect()
    guard store.taskContext.bundle?.context.revision == revision,
      store.taskContext.bundle?.verifications.count == 3,
      store.taskContext.workflow?.workflow.criteria.last?.id == firstID,
      store.repository?.snapshot.head == initial.snapshot.head,
      store.repository?.snapshot.indexHash == initial.snapshot.indexHash
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    print("Verified stable criterion IDs/revisions/reorder, linked incomplete report, separate claimed basis, explicit guide read/pin, persistence/reconnect, failed whitespace check, multi-repo handoff without guide content and unchanged HEAD/index")
  }

  @MainActor private static func verifyReviewContinuity(
    _ store: WorkbenchStore, view: NSView, layout: LayoutPreferences
  ) async throws {
    guard let selection = store.selection, let repo = store.repository, let diff = store.diff,
      store.canMarkRead, diff.path == "Sources/Session.swift", diff.hunks.count == 2,
      let scroll = diffScroll(in: view),
      (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 300
    else {
      throw NSError(
        domain: "ReviewProbe", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing long mounted diff"])
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 280))
    scroll.reflectScrolledClipView(scroll.contentView)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    guard abs(store.currentReviewScrollOffset - 280) < 2 else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.markCurrentFileRead()
    guard store.currentReadingState == .reviewed,
      let request = store.hunkRequestText(0, instruction: "Handle an empty session"),
      request.contains(repo.path), request.contains(diff.snapshotHash),
      request.contains(diff.hunks[0]),
      !request.contains(diff.hunks[1])
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.onlyUnreviewedFiles = true
    guard !store.displayedFiles.contains(where: { $0.path == diff.path }) else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.onlyUnreviewedFiles = false
    store.commitMessage = "검토 중인 로그인 변경"
    store.select(.init(repoId: selection.repoId))
    try await waitForSelection(store)
    store.select(selection)
    guard !store.canMarkRead else { throw CocoaError(.validationMissingMandatoryProperty) }
    try await waitForSelection(store)
    try await Task.sleep(for: .milliseconds(200))
    view.layoutSubtreeIfNeeded()
    guard store.currentReadingState == .reviewed,
      store.commitMessage == "검토 중인 로그인 변경",
      abs((diffScroll(in: view)?.contentView.bounds.minY ?? -1) - 280) < 2,
      store.repository?.snapshotHash == repo.snapshotHash
    else {
      throw NSError(
        domain: "ReviewProbe", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Reading/scroll restoration failed"])
    }
    let saved = layout.configuration
    layout.dockPane(.diff, nextTo: .files, edge: .bottom)
    try await Task.sleep(for: .milliseconds(200))
    layout.update { $0 = saved }
    try await Task.sleep(for: .milliseconds(200))
    guard abs((diffScroll(in: view)?.contentView.bounds.minY ?? -1) - 280) < 2 else {
      throw NSError(
        domain: "ReviewProbe", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Docking lost scroll position"])
    }
    // External edits only touch this probe's newly-created synthetic worktree.
    let peer = URL(fileURLWithPath: repo.path).appendingPathComponent("README.md")
    let savedPeer = try Data(contentsOf: peer)
    try (savedPeer + Data("\n// Unrelated external edit\n".utf8)).write(to: peer)
    await store.refresh()
    guard store.currentReadingState == .reviewed else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try savedPeer.write(to: peer)
    let file = URL(fileURLWithPath: repo.path).appendingPathComponent(diff.path)
    let source = try Data(contentsOf: file)
    try (source + Data("// External change after reading\n".utf8)).write(to: file)
    await store.refresh()
    try await Task.sleep(for: .milliseconds(200))
    guard store.currentReadingState == .needsReview, store.changedReadingHunks == [1],
      store.readingCheckpoint?.text == diff.text, store.currentReviewScrollOffset == 0,
      abs(diffScroll(in: view)?.contentView.bounds.minY ?? -1) < 2,
      store.repository?.snapshot.head == repo.snapshot.head,
      store.repository?.snapshot.indexHash == repo.snapshot.indexHash
    else {
      throw NSError(
        domain: "ReviewProbe", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "External edit did not invalidate reading/scroll"])
    }
    // Fault-inject only the synthetic original's config. A refused status must
    // keep the existing mounted diff readable without authorizing a write.
    if let original = store.workspace?.repositories.first(where: { $0.id == selection.repoId }),
      let sibling = store.workspace?.repositories.first(where: { $0.id != selection.repoId }),
      let mounted = diffScroll(in: view)
    {
      let config = URL(fileURLWithPath: original.path).appendingPathComponent(".git/config")
      let saved = try Data(contentsOf: config)
      defer { try? saved.write(to: config, options: .atomic) }
      mounted.contentView.scroll(to: NSPoint(x: 0, y: 180))
      mounted.reflectScrolledClipView(mounted.contentView)
      NotificationCenter.default.post(
        name: NSScrollView.didEndLiveScrollNotification, object: mounted)
      let y = mounted.contentView.bounds.minY
      let rendered = store.diff?.contentIdentity
      try Data(
        (String(decoding: saved, as: UTF8.self) + "\n[core]\nworktree = \(sibling.path)\n").utf8
      ).write(to: config, options: .atomic)
      await store.refresh()
      try await Task.sleep(for: .milliseconds(200))
      view.layoutSubtreeIfNeeded()
      guard store.selectionCheckFailed, !store.canEdit, store.diff?.contentIdentity == rendered,
        diffScroll(in: view) === mounted, abs(mounted.contentView.bounds.minY - y) < 2
      else {
        throw NSError(
          domain: "ReviewProbe", code: 5,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed validation unmounted the cached read-only diff"
          ])
      }
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw CocoaError(.fileWriteUnknown)
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let failureImage = URL(fileURLWithPath: CommandLine.arguments[2]).deletingPathExtension()
        .appendingPathExtension("validation-failed.png")
      guard let failurePNG = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try failurePNG.write(to: failureImage)
      try saved.write(to: config, options: .atomic)
      await store.refresh()
      try await Task.sleep(for: .milliseconds(100))
      guard store.canEdit, !store.selectionCheckFailed else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
    } else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    print(
      "Verified mounted diff scroll restoration across folders/docking, reading checkpoints, unrelated edits, own-file invalidation, unchanged Git HEAD/index, snapshot-bound selected-hunk handoff and cached read-only diff continuity through validation failure/recovery"
    )
  }

  @MainActor private static func verifyPreparationReadiness(_ store: WorkbenchStore) async throws {
    guard let initial = store.selection, let operation = store.operation,
      let unfinished = operation.repos.first(where: { $0.state != "ready" && $0.hasWorktree }),
      let ready = operation.repos.first(where: { $0.state == "ready" }), !operation.isRunning
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.select(.init(repoId: unfinished.id, opId: operation.id))
    try await waitForSelection(store)
    guard store.repository != nil, store.taskPreparationIncomplete, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let snapshot = store.repository?.snapshotHash
    store.select(.init(repoId: unfinished.id))
    try await waitForSelection(store)
    guard !store.taskPreparationIncomplete, store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(.init(repoId: ready.id, opId: operation.id))
    try await waitForSelection(store)
    guard !store.taskPreparationIncomplete, store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(.init(repoId: unfinished.id, opId: operation.id))
    try await waitForSelection(store)
    guard store.repository?.snapshotHash == snapshot, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(initial)
    try await waitForSelection(store)
    print(
      "Verified unfinished task is read-only while original folder and Ready sibling stay editable; snapshot preserved"
    )
  }

  @MainActor private static func settle(_ view: NSView) async throws {
    // Switching navigation rebuilds the outer container before its dock canvas receives
    // the new size. An offscreen host needs multiple layout/run-loop passes.
    for _ in 0..<3 {
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
      }
      try await Task.sleep(for: .milliseconds(80))
    }
  }

  @MainActor private static func seedSavedLayouts(_ layout: LayoutPreferences) throws -> (
    UUID, UUID
  ) {
    let original = layout.configuration
    let review = try layout.saveCurrentLayout(named: "나의 검토")
    layout.apply(.tracks)
    layout.update { $0.splitDiff = !original.splitDiff }
    layout.showPane(.branches)
    let branches = try layout.saveCurrentLayout(named: "브랜치 살펴보기")
    layout.applySavedLayout(review)
    return (review, branches)
  }

  @MainActor private static func verifyPersonalization(
    _ store: WorkbenchStore, layout: LayoutPreferences, reading: ReadingPreferences,
    presentation: DiffPresentationModel, drag: DockDragSession, defaults: UserDefaults,
    view: NSView, socket: String, requestedLayout: LayoutConfiguration,
    focusPrevious: LayoutConfiguration
  ) async throws {
    try requireSyntheticFixture(store)
    guard let selection = store.selection, let diff = store.diff, !store.selectedFile.isEmpty,
      !store.isViewingStash
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "A mounted current-file review is required"])
    }
    let requestedReading = reading.configuration
    let originalDraft = store.commitMessage
    let originalFilter = presentation.onlyChangedHunks
    store.commitMessage = "개인 화면 구성 검증 중인 커밋 초안"
    let draft = store.commitMessage
    let file = store.selectedFile
    let staged = store.staged
    let stash = store.selectedStashOID
    let snapshot = store.repository?.snapshotHash
    let appearance = layout.appearance
    func preserved(_ step: String) throws {
      guard store.selection == selection, store.selectedFile == file, store.staged == staged,
        store.selectedStashOID == stash, store.commitMessage == draft,
        store.repository?.snapshotHash == snapshot, store.diff?.text == diff.text,
        store.diff?.contentIdentity == diff.contentIdentity,
        store.diff?.snapshotHash == diff.snapshotHash, presentation.onlyChangedHunks,
        layout.appearance == appearance
      else {
        throw NSError(
          domain: "PersonalizationProbe", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Review identity or draft changed during \(step)"])
      }
    }
    var params: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
    if let operation = selection.opId { params["op_id"] = .string(operation) }
    let client = ServiceClient(socketPath: socket)
    let selectedBefore: RepositoryStatus = try await client.call("get_repo_status", params: params)
    let originalParams: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
    let originalBefore: RepositoryStatus = try await client.call(
      "get_repo_status", params: originalParams)

    // This balanced tree was established before mounting, so focus geometry is
    // measured independently of later repository-navigation container changes.
    try await settle(view)
    presentation.onlyChangedHunks = true
    let baseline = layout.configuration
    guard layout.configuration == baseline, let before = drag.frames[.diff],
      before.width > 100, before.height > 100
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Applying baseline layout did not produce mounted Diff geometry"
        ])
    }
    let encodedBefore = defaults.data(forKey: "workbench.layout.v1")
    let undoAvailable = layout.canUndoDock
    layout.focusPane(.diff)
    try await settle(view)
    guard let focused = drag.frames[.diff], layout.focusedPane == .diff,
      focused.width > before.width + 30 || focused.height > before.height + 30,
      layout.configuration == baseline,
      defaults.data(forKey: "workbench.layout.v1") == encodedBefore,
      layout.canUndoDock == undoAvailable,
      drag.frames.keys.allSatisfy({ $0 == .diff })
    else {
      let details = drag.frames.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(
        separator: "; ")
      throw NSError(
        domain: "PersonalizationProbe", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Mounted focus geometry failed: before=\(before), focused=\(String(describing: drag.frames[.diff])), pane=\(String(describing: layout.focusedPane)), configuration=\(layout.configuration == baseline), bytes=\(defaults.data(forKey: "workbench.layout.v1") == encodedBefore), undo=\(layout.canUndoDock == undoAvailable); \(details)"
        ])
    }
    try preserved("mounted focus")
    layout.restorePaneLayout()
    try await settle(view)
    guard let restored = drag.frames[.diff], abs(restored.width - before.width) < 1,
      abs(restored.height - before.height) < 1,
      layout.configuration == baseline,
      defaults.data(forKey: "workbench.layout.v1") == encodedBefore,
      layout.canUndoDock == undoAvailable
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 12,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Focus restore mismatch: before=\(before), restored=\(String(describing: drag.frames[.diff])), configuration=\(layout.configuration == baseline), bytes=\(defaults.data(forKey: "workbench.layout.v1") == encodedBefore), undo=\(layout.canUndoDock == undoAvailable)"
        ])
    }
    try preserved("focus restore")
    // The previous full configuration is a behavioral check of unchanged undo history.
    layout.undoDock()
    try await settle(view)
    guard layout.configuration == focusPrevious else {
      throw NSError(
        domain: "PersonalizationProbe", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Temporary focus added or consumed an undo step"])
    }
    layout.apply(.balanced)
    let ids = try seedSavedLayouts(layout)
    try await settle(view)
    try preserved("saved-layout creation")
    guard let alternate = layout.savedLayouts.first(where: { $0.id == ids.1 })?.configuration,
      alternate.navigation != baseline.navigation, alternate.splitDiff != baseline.splitDiff,
      alternate.dock?.sameArrangement(as: baseline.dock!) == false,
      layout.dockLayout.sameArrangement(as: baseline.dock!),
      layout.configuration.navigation == baseline.navigation,
      layout.configuration.splitDiff == baseline.splitDiff
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 10,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Saved layout setup did not preserve the baseline configuration"
        ])
    }
    layout.undoDock()
    try await settle(view)
    guard layout.configuration == alternate else {
      throw NSError(
        domain: "PersonalizationProbe", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Undo failed to restore navigation, Diff style and dock together"
        ])
    }
    try preserved("full configuration undo")
    layout.applySavedLayout(ids.0)
    try await settle(view)
    try await dock(.diff, beside: .files, edge: .bottom, layout: layout, drag: drag)
    try preserved("moving Diff")
    layout.apply(.classic)
    try await settle(view)
    try preserved("preset application")
    layout.applySavedLayout(ids.1)
    try await settle(view)
    try preserved("saved layout application with different repository navigation")
    guard LayoutPreferences(defaults: defaults).savedLayouts == layout.savedLayouts else {
      throw NSError(
        domain: "PersonalizationProbe", code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Saved layout library failed persistence round trip"])
    }
    let beforeReadingChange = layout.configuration
    reading.setCodeSize(requestedReading.codeSize == 18 ? 16 : 18)
    reading.setDensity(requestedReading.density == .compact ? .comfortable : .compact)
    try await settle(view)
    guard layout.configuration == beforeReadingChange,
      ReadingPreferences(defaults: defaults).configuration == reading.configuration
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 14,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Reading preferences changed the arrangement or failed persistence"
        ])
    }
    try preserved("independent reading preferences")

    let selectedAfter: RepositoryStatus = try await client.call("get_repo_status", params: params)
    let originalAfter: RepositoryStatus = try await client.call(
      "get_repo_status", params: originalParams)
    guard selectedBefore.snapshotHash == selectedAfter.snapshotHash,
      originalBefore.snapshotHash == originalAfter.snapshotHash
    else {
      throw NSError(
        domain: "PersonalizationProbe", code: 6,
        userInfo: [
          NSLocalizedDescriptionKey: "Git snapshot changed during presentation-only operations"
        ])
    }
    layout.update { $0 = requestedLayout }
    reading.setCodeSize(requestedReading.codeSize)
    reading.setDensity(requestedReading.density)
    presentation.onlyChangedHunks = originalFilter
    store.commitMessage = originalDraft
    try await settle(view)
    func frame(_ rect: CGRect) -> [String: Double] {
      ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    let report: [String: Any] = [
      "sameMountedRoot": true, "namedLayouts": layout.savedLayouts.map(\.name),
      "fullConfigurationUndo": true, "focusPersistenceAndUndoUnchanged": true,
      "focusGeometry": [
        "before": frame(before), "focused": frame(focused), "restored": frame(restored),
      ],
      "reviewIdentityPreserved": true, "draftAndDiffPreserved": true,
      "filterPreservedAcrossFocusMovePresetAndSavedLayout": true,
      "readingPreferencesIndependent": true, "hiddenSiblingDropTargetsExcluded": true,
      "selectedSnapshotBefore": selectedBefore.snapshotHash,
      "selectedSnapshotAfter": selectedAfter.snapshotHash,
      "originalSnapshotBefore": originalBefore.snapshotHash,
      "originalSnapshotAfter": originalAfter.snapshotHash,
      "scope":
        "Own mounted SwiftUI root and actual presentation APIs; independent Git status reads before/after. No OS input, zero-RPC, VoiceOver or performance claim.",
    ]
    if let path = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_PERSONALIZATION_REPORT"] {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path))
    }
    print(
      "Verified same-root named layouts/full undo, actual focus geometry/restore, persistent review filter/draft/Diff identity and unchanged selected/original Git snapshots"
    )
  }

  @MainActor private static func dock(
    _ pane: WorkbenchPane, beside target: WorkbenchPane,
    edge: DockEdge, layout: LayoutPreferences, drag: DockDragSession
  ) async throws {
    try await Task.sleep(for: .milliseconds(80))
    guard let rect = drag.frames[target] else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let point: CGPoint
    switch edge {
    case .left: point = .init(x: rect.minX + 20, y: rect.midY)
    case .right: point = .init(x: rect.maxX - 20, y: rect.midY)
    case .top: point = .init(x: rect.midX, y: rect.minY + 20)
    case .bottom: point = .init(x: rect.midX, y: rect.maxY - 20)
    case .center: point = .init(x: rect.midX, y: rect.midY)
    }
    drag.drag(pane, to: point)
    // Every tab in one group shares a drop region; its representative pane may differ.
    guard drag.target?.edge == edge,
      let hitPane = drag.target?.pane, drag.frames[hitPane] == rect
    else {
      throw NSError(
        domain: "NativeDock", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Incorrect pane drop target"])
    }
    drag.finish(in: layout)
    try await Task.sleep(for: .milliseconds(100))
  }

  @MainActor private static func verifyDocking(
    _ store: WorkbenchStore, layout: LayoutPreferences,
    drag: DockDragSession, defaults: UserDefaults, socket: String
  ) async throws {
    let original = layout.configuration
    let selection = store.selection
    let snapshot = store.repository?.snapshotHash
    let file = store.selectedFile
    let diff = store.diff?.text
    let staged = store.staged
    let message = store.commitMessage
    // Focus starts with two panes; materialize a target for the same drag scenario.
    layout.showPane(.commit)
    try await Task.sleep(for: .milliseconds(100))
    layout.hidePane(.details)
    try await dock(.stash, beside: .diff, edge: .left, layout: layout, drag: drag)
    guard let stash = drag.frames[.stash], let review = drag.frames[.diff],
      stash.maxX <= review.minX
    else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await dock(.graph, beside: .commit, edge: .bottom, layout: layout, drag: drag)
    guard let graph = drag.frames[.graph], let commit = drag.frames[.commit],
      graph.minY >= commit.maxY
    else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await dock(.files, beside: .diff, edge: .bottom, layout: layout, drag: drag)
    let split = layout.dockLayout
    try await dock(.stash, beside: .graph, edge: .center, layout: layout, drag: drag)
    guard drag.frames[.stash] == drag.frames[.graph] else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    layout.undoDock()
    guard layout.dockLayout == split else { throw CocoaError(.validationMissingMandatoryProperty) }
    let restored = LayoutPreferences(defaults: defaults)
    guard restored.dockLayout == layout.dockLayout,
      store.selection == selection, store.repository?.snapshotHash == snapshot,
      store.selectedFile == file, store.diff?.text == diff, store.staged == staged,
      store.commitMessage == message
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    if let selection {
      var params: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
      if let opID = selection.opId { params["op_id"] = .string(opID) }
      let status: RepositoryStatus = try await ServiceClient(socketPath: socket).call(
        "get_repo_status", params: params)
      guard status.snapshotHash == snapshot else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
    }
    layout.update { $0 = original }
    try await Task.sleep(for: .milliseconds(100))
    print(
      "Verified arbitrary pane splits/tabs from mounted geometry through the actual drag controller, undo, saved tree and live Git review preservation"
    )
  }

  @MainActor private static func verifyFolderSwitching(_ store: WorkbenchStore) async throws {
    guard let task = store.selection, let opID = task.opId, let repo = store.repository,
      let diff = store.diff,
      let otherRepo = store.operation?.repos.first(where: { $0.id != task.repoId && $0.hasWorktree }
      )
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let path = store.selectedFile
    let staged = store.staged
    store.commitMessage = "작업 폴더의 작성 중인 커밋"
    store.select(.init(repoId: task.repoId))
    try await waitForSelection(store)
    guard store.repository?.path != repo.path else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.commitMessage = "원래 폴더의 별도 커밋 초안"
    let started = ContinuousClock.now
    store.select(task)
    let restored = started.duration(to: .now)
    // These assertions run synchronously, before the next service read can finish.
    guard store.repository?.path == repo.path, store.repository?.snapshotHash == repo.snapshotHash,
      store.diff?.text == diff.text, store.selectedFile == path, store.staged == staged,
      store.commitMessage == "작업 폴더의 작성 중인 커밋", store.validatingSelection, !store.canEdit
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try await waitForSelection(store)
    store.select(.init(repoId: otherRepo.id, opId: opID))
    try await waitForSelection(store)
    store.commitMessage = "다른 저장소의 커밋 초안"
    store.select(task)
    guard store.repository?.path == repo.path, store.commitMessage == "작업 폴더의 작성 중인 커밋"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    // Rapid selection changes must not publish a superseded response.
    store.select(.init(repoId: task.repoId))
    guard store.commitMessage == "원래 폴더의 별도 커밋 초안" else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let file = URL(fileURLWithPath: repo.path).appendingPathComponent("Sources/Session.swift")
    let saved = try Data(contentsOf: file)
    defer { try? saved.write(to: file) }
    var edited = saved
    edited.append(Data("// External edit while another folder is active\n".utf8))
    try edited.write(to: file)
    store.select(task)
    guard store.repository?.snapshotHash == repo.snapshotHash, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await waitForSelection(store)
    guard store.selection == task, store.repository?.snapshotHash != repo.snapshotHash,
      store.commitMessage == "작업 폴더의 작성 중인 커밋", store.canEdit
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try saved.write(to: file)
    await store.refresh()
    let reconnectedHash = store.repository?.snapshotHash
    await store.reconnect()
    guard store.selection == task, store.repository?.snapshotHash == reconnectedHash,
      store.selectedFile == path, store.staged == staged,
      store.commitMessage == "작업 폴더의 작성 중인 커밋"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.select(.init(repoId: task.repoId))
    guard store.commitMessage == "원래 폴더의 별도 커밋 초안" else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await waitForSelection(store)
    store.select(task)
    try await waitForSelection(store)
    print(
      "Verified immediate review/draft restoration across repositories, folders and reconnect; external drift revalidated before editing. Synchronous restore: \(restored)"
    )
  }
}

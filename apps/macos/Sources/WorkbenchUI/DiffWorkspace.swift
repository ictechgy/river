import SwiftUI
import WorkbenchProtocol

struct DiffWorkspace: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var presentation: DiffPresentationModel
  var openTaskInformation: (() -> Void)? = nil
  @State private var previousReading: PresentedReading?
  @State private var request: HunkRequest?
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(
          DiffLines.displayText(
            store.selectedFile.isEmpty ? "파일 선택" : (store.selectedFile as NSString).lastPathComponent
          )
        )
        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        .help(DiffLines.displayText(store.selectedFile)).accessibilityLabel(
          DiffLines.displayText(store.selectedFile.isEmpty ? "파일 선택" : store.selectedFile))
        Text(
          store.isViewingStash
            ? "\(store.selectedStash?.selector ?? "Stash") · 읽기 전용" : store.staged ? "커밋에 포함" : "스테이징 전"
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Picker("Diff 표시", selection: $store.splitDiff) {
          Text("나란히").tag(true)
          Text("한 화면").tag(false)
        }.labelsHidden().pickerStyle(.segmented).frame(width: 134).font(.system(size: 12))
      }.padding(.horizontal, 14).frame(minHeight: 40).background(WorkbenchTheme.canvas)
      Divider()
      if !store.selectedFile.isEmpty && !store.isViewingStash {
        fileStagingToolbar
        Divider()
      }
      if store.taskPreparationIncomplete && !store.pendingWorktree && !store.isViewingStash {
        Label(store.preparationHint, systemImage: "exclamationmark.triangle")
          .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        Divider()
      }
      if store.selectionCheckFailed && store.repository != nil && store.diff != nil
        && !store.isViewingStash
      {
        HStack {
          Label("최신 상태 확인 실패 · 마지막 화면을 읽기 전용으로 표시합니다", systemImage: "exclamationmark.triangle")
          Spacer()
          Button("새로고침") { Task { await store.refresh(forceDiff: true) } }
        }.font(.system(size: 12)).padding(10).background(WorkbenchTheme.warning.opacity(0.10))
          .accessibilityIdentifier("workbench.validation-failure")
        Divider()
      }
      if let warning = store.diff?.encodingWarning {
        Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12))
          .foregroundStyle(WorkbenchTheme.warning).padding(12).frame(
            maxWidth: .infinity, alignment: .leading)
        Divider()
      }
      if store.selectionCheckFailed && (store.repository == nil || store.diff == nil)
        && !store.isViewingStash
      {
        ContentUnavailableView {
          Label("현재 변경을 확인하지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
          Text("파일 상태를 확인한 뒤 편집할 수 있습니다.")
        } actions: {
          Button("새로고침") { Task { await store.refresh(forceDiff: true) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.pendingWorktree && !store.isViewingStash {
        ContentUnavailableView(
          store.pendingWorktreeTitle, systemImage: "externaldrive.badge.plus",
          description: Text(store.pendingWorktreeHint)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let failure = store.diffError {
        ContentUnavailableView {
          Label("변경 내용을 읽지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
          Text(failure)
        } actions: {
          Button("다시 시도") { Task { await store.retryDiff() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff, diff.displayLimitExceeded {
        ContentUnavailableView(
          "이 변경은 Git에서 확인해 주세요", systemImage: "doc.text.magnifyingglass",
          description: Text(
            "5,000줄 또는 512 KiB를 넘는 변경은 앱에서 펼치지 않습니다. 파일을 나누어 검토하거나 Git에서 전체 변경을 확인해 주세요.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff, !diff.hunks.isEmpty {
        let renderedLocation = store.selection
        if !store.isViewingStash && !diff.canStageHunks {
          Text("이 파일 형식이나 변경 종류는 부분 스테이징을 지원하지 않습니다. 파일 전체 변경을 확인한 뒤 위의 버튼을 사용하세요.")
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
          Divider()
        }
        if !store.isViewingStash { readingToolbar(diff) }
        let changed = store.changedReadingHunks
        GeometryReader { geometry in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
              if presentation.onlyChangedHunks && changed.isEmpty {
                ContentUnavailableView(
                  "새로 달라진 변경 묶음이 없습니다", systemImage: "checkmark.rectangle",
                  description: Text(
                    store.removedReadingHunks > 0
                      ? "이전 검토의 일부 변경 묶음이 사라졌습니다. ‘이전 검토’와 전체 변경을 함께 확인하세요."
                      : "전체 변경을 다시 확인하려면 ‘달라진 변경’을 끄세요.")
                )
                .padding(20)
              }
              ForEach(
                diff.parsedHunks.filter {
                  !presentation.onlyChangedHunks || changed.contains($0.id)
                }
              ) { hunk in
                HunkView(
                  hunk: hunk, split: store.splitDiff, staged: diff.staged,
                  availableWidth: geometry.size.width,
                  canStage: store.canEdit && store.canUseRenderedDiff && diff.canStageHunks,
                  readOnly: store.isViewingStash,
                  changedSinceReading: store.readingCheckpoint != nil && changed.contains(hunk.id),
                  canRequest: store.canUseRenderedDiff
                    && diff.header.utf8.count + diff.hunks[hunk.id].utf8.count <= 128 * 1024,
                  request: {
                    if let renderedLocation {
                      request = store.hunkRequest(hunk.id, from: diff, at: renderedLocation)
                    }
                  }
                ) {
                  if let selection = renderedLocation {
                    Task { await store.stageHunk(hunk.id, from: diff, at: selection) }
                  }
                }
              }
            }.frame(width: geometry.size.width, alignment: .topLeading)
              .background {
                if let id = store.currentReviewID {
                  ReviewScrollPosition(
                    store: store, id: id, content: diff.contentIdentity,
                    enabled: !presentation.onlyChangedHunks
                  ).frame(width: 0, height: 0)
                }
              }
          }
        }
      } else if store.selectedFile.isEmpty {
        ContentUnavailableView {
          Label(
            store.isViewingStash ? "Stash의 파일을 선택하세요" : store.staged ? "커밋에 포함한 파일이 없습니다" : "검토할 변경이 없습니다",
            systemImage: store.isViewingStash ? "archivebox" : "checkmark.circle")
        } description: {
          Text(
            store.isViewingStash
              ? (store.stashError ?? "왼쪽 파일 목록에서 저장된 변경을 확인하세요.")
              : store.staged
                ? "1. ‘스테이징 전’에서 파일 선택 → 2. Diff에서 스테이징 → 3. 커밋 메시지 작성 후 커밋"
                : "작업 목적과 완료 조건을 기록한 뒤 코드를 바꾸세요. 변경이 생기면 파일 선택 → 스테이징 → 커밋 순서로 진행합니다.")
        } actions: {
          if !store.isViewingStash, let openTaskInformation {
            Button("작업 정보에서 목적·완료 조건 작성", systemImage: "text.alignleft", action: openTaskInformation)
              .buttonStyle(.bordered).accessibilityIdentifier("workbench.empty-diff-task-information")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff {
        ContentUnavailableView(
          store.selectedFileChange?.index == "?" && !store.isViewingStash
            ? "아직 Git에 추가하지 않은 새 파일입니다" : "일반 텍스트 Diff를 표시할 수 없습니다",
          systemImage: "doc.text.magnifyingglass",
          description: Text(
            store.isViewingStash
              ? "표시할 텍스트 변경이 없습니다. 파일 종류나 실행 권한 변경을 확인하세요."
              : store.selectedFileChange?.index == "?"
                ? "이 파일의 일반 텍스트 Diff를 표시하지 못했습니다. 파일 내용을 확인한 뒤 ‘파일 전체 스테이징’으로 커밋에 포함하세요."
                : "바이너리·파일 종류·실행 권한 등은 Git에서 확인하세요. 확인한 파일은 위의 파일 전체 버튼으로 스테이징하거나 취소할 수 있습니다.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
          if !diff.text.isEmpty {
            Text(DiffLines.displayMultilineText(diff.text)).font(
              .system(size: 10, design: .monospaced)
            ).textSelection(.enabled)
              .padding(20)
          }
        }
      } else {
        ProgressView("Diff를 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(WorkbenchTheme.canvas)
      .onChange(of: store.currentReviewID) { _, _ in presentation.onlyChangedHunks = false }
      .sheet(item: $request) { HunkRequestSheet(request: $0) }
      .sheet(item: $previousReading) { reading in
        let checkpoint = reading.checkpoint
        let checkpointDisplay = DiffLines.displayMultilineText(checkpoint.text)
        VStack(alignment: .leading, spacing: 14) {
          Text("이전 검토 당시의 변경").font(.headline)
          Text(checkpoint.date, format: .dateTime.month().day().hour().minute())
            .font(.caption).foregroundStyle(.secondary)
          ScrollView([.horizontal, .vertical]) {
            Text(checkpointDisplay).font(.system(size: 12, design: .monospaced))
              .textSelection(.enabled).padding(12)
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if checkpointDisplay != checkpoint.text {
            Text("제어·방향 문자를 기호로 표시합니다. 원본 검토 기록은 그대로 유지됩니다.")
              .font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Text("읽기 전용 · 이 기록으로 staging하지 않습니다.").font(.caption)
            Spacer()
            Button("닫기") { previousReading = nil }.keyboardShortcut(.cancelAction)
          }
        }.padding(20).frame(width: 700, height: 520)
      }
  }

  private var fileStagingToolbar: some View {
    let path = store.selectedFile
    let staged = store.staged
    let snapshot = store.repository?.snapshotHash
    let location = store.selection
    return HStack(alignment: .top, spacing: 10) {
      Button(staged ? "파일 전체 스테이징 취소" : "파일 전체 스테이징") {
        if let snapshot, let location {
          Task { await store.stageFile(path, staged: staged, expectedSnapshot: snapshot, at: location) }
        }
      }.buttonStyle(.bordered).tint(WorkbenchTheme.accentText).controlSize(.regular)
        .font(.system(size: 12)).fixedSize()
        .disabled(!store.canStageSelectedFile)
        .accessibilityIdentifier("workbench.stage-file")
        .accessibilityLabel("\(DiffLines.displayText(path)) 파일 전체 \(staged ? "스테이징 취소" : "스테이징")")
        .help(staged ? "이 파일만 커밋 대상에서 제외합니다. 작업 폴더 내용은 유지됩니다."
          : "선택한 파일의 모든 변경만 스테이징합니다. 다른 파일은 추가하지 않습니다.")
      Text(store.fileStagingUnavailableReason
        ?? (staged ? "이 파일을 커밋 대상에서 제외합니다. 작업 폴더 내용은 유지됩니다." : "이 파일의 모든 변경을 커밋에 포함합니다."))
        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }.padding(.horizontal, 14).padding(.vertical, 8).background(WorkbenchTheme.canvas)
  }

  @ViewBuilder private func readingToolbar(_ diff: FileDiff) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if store.currentReadingState != .unread && !store.selectionCheckFailed {
          Label {
            Text(store.currentReadingState.label)
              .foregroundStyle(WorkbenchTheme.secondaryText)
          } icon: {
            Image(
              systemName: store.currentReadingState == .reviewed ? "checkmark.circle.fill" : "eye"
            )
            .foregroundStyle(
              store.currentReadingState == .reviewed
                ? WorkbenchTheme.success
                : store.currentReadingState == .needsReview
                  ? WorkbenchTheme.warning : WorkbenchTheme.secondaryText)
          }.font(.system(size: 12))
            .help("현재 작업공간 세션의 개인 읽기 기록입니다. 테스트 통과나 병합 승인이 아닙니다.")
        }
        Spacer(minLength: 0)
        if let checkpoint = store.readingCheckpoint {
          Menu {
            Button("이전 검토 보기") { previousReading = PresentedReading(checkpoint: checkpoint) }
            if checkpoint.contentIdentity != diff.contentIdentity || presentation.onlyChangedHunks {
              Toggle("달라진 변경만 표시", isOn: $presentation.onlyChangedHunks)
            }
          } label: {
            Label(
              presentation.onlyChangedHunks ? "달라진 변경" : "검토 기록",
              systemImage: presentation.onlyChangedHunks
                ? "line.3.horizontal.decrease.circle.fill" : "clock.arrow.circlepath"
            )
            .foregroundStyle(
              presentation.onlyChangedHunks
                ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
          }.font(.system(size: 12)).menuStyle(.borderlessButton).fixedSize()
            .help("이전 개인 읽기 기록을 확인합니다. ‘달라진 변경’에는 줄 위치나 문맥 변경도 포함됩니다.")
        }
        Button(store.currentReadingState == .reviewed ? "검토 표시 해제" : "파일 검토함") {
          if store.currentReadingState == .reviewed {
            store.clearCurrentReadingCheckpoint()
          } else {
            store.markCurrentFileRead()
          }
          presentation.onlyChangedHunks = false
        }.font(.system(size: 12)).buttonStyle(.borderless).disabled(!store.canMarkRead)
          .help("개인 읽기 기록이며 테스트 통과나 병합 승인이 아닙니다. 큰 diff(512 KiB 초과)는 기록하지 않습니다.")
      }
      if store.currentReadingState == .needsReview, let checkpoint = store.readingCheckpoint {
        Text(
          checkpoint.contentIdentity == diff.contentIdentity
            ? "브랜치·HEAD 또는 스테이징 기준이 바뀌었습니다. 전체 변경을 다시 확인하세요."
            : "검토 이후 달라진 hunk \(store.changedReadingHunks.count)개 · 이전 hunk \(store.removedReadingHunks)개가 사라지거나 교체됨"
        )
        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.warning).fixedSize(
          horizontal: false, vertical: true)
      }
    }.padding(.horizontal, 14).padding(.vertical, 8).background(WorkbenchTheme.canvas)
    Divider()
  }
}

private struct PresentedReading: Identifiable {
  let id = UUID()
  let checkpoint: ReadingCheckpoint
}

private struct HunkView: View {
  @Environment(\.riverReading) private var reading
  let hunk: ParsedHunk
  let split: Bool
  let staged: Bool
  let availableWidth: CGFloat
  let canStage: Bool
  let readOnly: Bool
  let changedSinceReading: Bool
  let canRequest: Bool
  let request: () -> Void
  let stage: () -> Void

  var body: some View {
    let digits = hunk.unified.reduce(1) { count, row in
      max(count, String(max(row.oldNumber ?? 0, row.newNumber ?? 0)).count)
    }
    let numberWidth = reading.lineNumberWidth(digits: digits)
    VStack(spacing: 0) {
      HStack {
        Text("변경 \(hunk.id + 1)").font(.system(size: 12, weight: .semibold)).fixedSize().help(
          DiffLines.displayText(hunk.header))
        Text(DiffLines.displayText(hunk.header)).font(.system(size: 12, design: .monospaced))
          .foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(1).truncationMode(.middle)
        if changedSinceReading {
          Text("검토 후 변경").font(.system(size: 12)).foregroundStyle(WorkbenchTheme.accentText)
        }
        Spacer()
        if readOnly {
          Image(systemName: "lock").foregroundStyle(.secondary)
            .accessibilityLabel("Stash · 읽기 전용").help("Stash · 읽기 전용")
        } else {
          Menu("AI 요청") {
            Button("수정 요청문 만들기…", action: request)
            Text("요청문을 직접 복사해 전달합니다.")
          }.font(.system(size: 12)).menuStyle(.borderlessButton).fixedSize()
            .disabled(!canRequest).help(
              "이 변경을 담은 AI용 요청문을 만들어 직접 복사합니다. 자동 전송·실행하지 않습니다. · 128 KiB 이내")
          Button(staged ? "이 변경만 스테이징 취소" : "이 변경만 스테이징", action: stage)
            .buttonStyle(.bordered).tint(WorkbenchTheme.accentText).controlSize(.regular).font(
              .system(size: 12)
            ).disabled(!canStage)
            .accessibilityLabel("변경 \(hunk.id + 1) \(staged ? "스테이징 취소" : "스테이징")")
            .help(staged ? "이 변경 묶음의 스테이징을 취소합니다." : "이 변경 묶음만 스테이징합니다.")
        }
      }.padding(.horizontal, 14).frame(height: 36).background(WorkbenchTheme.panel)
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          if split {
            HStack {
              Text(staged ? "마지막 커밋" : "이전 내용").frame(maxWidth: .infinity, alignment: .leading)
              Text(staged ? "커밋할 내용" : "변경 후").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(
              height: reading.splitHeaderHeight)
            ForEach(hunk.split) { row in
              HStack(spacing: 0) {
                CodeCell(cell: row.before, numberWidth: numberWidth).frame(
                  minWidth: 280, maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(WorkbenchTheme.line).frame(width: 0.5)
                CodeCell(cell: row.after, numberWidth: numberWidth).frame(
                  minWidth: 280, maxWidth: .infinity, alignment: .leading)
              }.fixedSize(horizontal: false, vertical: true)
            }
          } else {
            ForEach(hunk.unified) { row in
              HStack(spacing: 0) {
                Text(row.oldNumber.map(String.init) ?? "").frame(
                  width: numberWidth, alignment: .trailing)
                Text(row.newNumber.map(String.init) ?? "").frame(
                  width: numberWidth, alignment: .trailing
                )
                .padding(.trailing, 14)
                Text(
                  (row.kind == .addition ? "+ " : row.kind == .deletion ? "- " : "  ")
                    + DiffLines.displayText(row.text)
                )
                .foregroundStyle(WorkbenchTheme.primaryText).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true).frame(
                  maxWidth: .infinity, alignment: .leading)
              }.font(.system(size: reading.codeSize, design: .monospaced)).foregroundStyle(
                .secondary
              ).frame(
                minWidth: max(560, availableWidth), minHeight: reading.codeRowHeight,
                maxHeight: reading.codeRowHeight, alignment: .leading
              )
              .background(lineBackground(row.kind))
            }
          }
        }.frame(minWidth: max(560, availableWidth), maxWidth: .infinity, alignment: .leading)
      }.frame(
        height: reading.hunkHeight(
          rows: split ? hunk.split.count : hunk.unified.count, split: split))
      Divider()
    }
  }
}
private struct CodeCell: View {
  @Environment(\.riverReading) private var reading
  let cell: DiffCell?
  let numberWidth: CGFloat
  var body: some View {
    HStack(spacing: 12) {
      Text(cell?.number.map(String.init) ?? "").foregroundStyle(WorkbenchTheme.secondaryText).frame(
        width: numberWidth, height: reading.codeRowHeight, alignment: .trailing
      )
      .background(lineGutterBackground(cell?.kind ?? .context))
      Text(cell?.kind == .addition ? "+" : cell?.kind == .deletion ? "-" : " ")
        .frame(width: 8).accessibilityHidden(true)
      Text(DiffLines.displayText(cell?.text ?? " ")).textSelection(.enabled).fixedSize(
        horizontal: true, vertical: true)
      if cell?.noNewline == true {
        Text("개행 없음").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 10)
    }.font(.system(size: reading.codeSize, design: .monospaced)).foregroundStyle(
      WorkbenchTheme.primaryText
    )
    .frame(height: reading.codeRowHeight).padding(.horizontal, 6)
    .background(lineBackground(cell?.kind ?? .context))
    .accessibilityLabel(cell?.codeAccessibilityLabel ?? "빈 행")
  }
}

extension DiffCell {
  var codeAccessibilityLabel: String {
    "\(kind == .addition ? "추가" : kind == .deletion ? "삭제" : "") \(number.map(String.init) ?? "") \(DiffLines.displayText(text))"
  }
}

private func lineBackground(_ kind: LineKind) -> Color {
  switch kind {
  case .addition: WorkbenchTheme.addBackground
  case .deletion: WorkbenchTheme.deleteBackground
  default: .clear
  }
}
private func lineGutterBackground(_ kind: LineKind) -> Color {
  switch kind {
  case .addition: WorkbenchTheme.addGutter
  case .deletion: WorkbenchTheme.deleteGutter
  default: .clear
  }
}

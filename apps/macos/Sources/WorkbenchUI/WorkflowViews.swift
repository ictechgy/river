import SwiftUI
import WorkbenchProtocol

struct WorkflowCriteriaView: View {
  let bundle: TaskWorkflowBundle
  let repoID: String?
  let opID: String?
  let head: String?
  let snapshot: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("완료 조건").font(.system(size: 12, weight: .semibold))
      if bundle.workflow.criteria.isEmpty {
        Text("완료를 판단할 조건을 적어 두세요.").foregroundStyle(.secondary)
      }
      ForEach(bundle.workflow.criteria) { criterion in
        let recentIDs = Set(bundle.verifications.prefix(50).map(\.id))
        let linked = bundle.evidence.filter { recentIDs.contains($0.receiptId) && $0.criteria.contains { $0.id == criterion.id } }
        let needsReview = linked.filter { evidence in
          guard let receipt = bundle.verifications.first(where: { $0.id == evidence.receiptId }) else { return true }
          let presentation = WorkflowEvidencePresentation(receipt: receipt, evidence: evidence,
            workflow: bundle.workflow, repoID: repoID, opID: opID, head: head, snapshot: snapshot)
          return !presentation.warnings.isEmpty || presentation.needsApplicabilityCheck
        }.count
        DisclosureGroup {
          Text("조건 ID \(criterion.id) · 버전 \(criterion.revision)")
            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
          if linked.isEmpty { Text("조회한 최근 기록에 이 조건과 연결한 보고가 없습니다.").foregroundStyle(.secondary) }
          ForEach(linked, id: \.receiptId) { evidence in
            if let receipt = bundle.verifications.first(where: { $0.id == evidence.receiptId }) {
              let presentation = WorkflowEvidencePresentation(receipt: receipt, evidence: evidence,
                workflow: bundle.workflow, repoID: repoID, opID: opID, head: head, snapshot: snapshot)
              VStack(alignment: .leading, spacing: 3) {
                Text("\(receipt.repoId) · \(receipt.opId == nil ? "원래 폴더" : "작업용 폴더") · \(receipt.verdictLabel)")
                Text(presentation.labels.joined(separator: " · ")).foregroundStyle(.secondary)
                if !presentation.warnings.isEmpty {
                  Text(presentation.warnings.joined(separator: " · ")).foregroundStyle(WorkbenchTheme.warning)
                }
                Text("기록 ID \(receipt.id)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
              }.padding(.top, 6)
            }
          }
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(criterion.text).fixedSize(horizontal: false, vertical: true)
            Text("연결 보고 \(linked.count)개 · 조건 충족 판정 아님").font(.system(size: 11)).foregroundStyle(.secondary)
            if needsReview > 0 {
              Text("적용 여부를 다시 확인할 기록 \(needsReview)개").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.warning)
            }
          }
        }
      }
      Text("최근 50개 기록에서 연결을 찾습니다. 조건 순서가 바뀌어도 연결은 유지되며, 조건 내용·목적·코드 변경은 따로 확인합니다.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.font(.system(size: 12))
  }
}

struct WorkflowCriterionEditor: View {
  @Binding var entries: [WorkflowCriterionDraft]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("완료 조건").font(.subheadline)
        Spacer()
        Button("조건 추가", systemImage: "plus") { entries.append(WorkflowCriterionDraft()) }
          .disabled(entries.count >= 30)
      }
      Text("수정·이동하면 같은 조건으로 유지됩니다. 복제하면 새 조건이 됩니다.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        HStack(alignment: .top, spacing: 6) {
          TextField("완료를 판단할 조건", text: textBinding(entry.id), axis: .vertical)
            .lineLimit(1...4).accessibilityLabel("완료 조건 \(index + 1)")
          Button { move(entry.id, by: -1) } label: { Image(systemName: "arrow.up") }
            .help("위로 이동").accessibilityLabel("조건 \(index + 1) 위로 이동").disabled(index == 0)
          Button { move(entry.id, by: 1) } label: { Image(systemName: "arrow.down") }
            .help("아래로 이동").accessibilityLabel("조건 \(index + 1) 아래로 이동").disabled(index == entries.count - 1)
          Button { entries.insert(.duplicate(entry), at: index + 1) } label: { Image(systemName: "plus.square.on.square") }
            .help("새 조건으로 복제").accessibilityLabel("조건 \(index + 1) 새 조건으로 복제").disabled(entries.count >= 30)
          Button { entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
            .help("조건 삭제 · 저장된 과거 연결은 유지됩니다").accessibilityLabel("조건 \(index + 1) 삭제")
        }.buttonStyle(.borderless)
      }
    }
  }
  private func textBinding(_ id: String) -> Binding<String> {
    Binding(get: { entries.first { $0.id == id }?.text ?? "" }, set: { value in
      if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].text = value }
    })
  }
  private func move(_ id: String, by offset: Int) {
    guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
    entries.swapAt(index, index + offset)
  }
}

struct WorkflowGuideEditor: View {
  @Binding var guides: [WorkflowGuideReference]
  let repositoryIDs: [String]
  var body: some View {
    DisclosureGroup("검증 절차 · 기능 지도 \(guides.count)개") {
      VStack(alignment: .leading, spacing: 10) {
        Text("저장소 안의 상대 경로만 지정합니다. 내용은 ‘읽기’를 눌렀을 때만 읽고, 실행하거나 AI에 보내지 않습니다.")
          .font(.caption).foregroundStyle(.secondary)
        ForEach($guides) { $guide in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Picker("저장소", selection: $guide.repoId) {
                ForEach(repositoryIDs, id: \.self) { Text($0).tag($0) }
              }
              Picker("종류", selection: $guide.kind) {
                Text("검증 절차").tag("procedure"); Text("기능 지도").tag("feature_map")
              }
              Button("삭제", systemImage: "minus.circle") { guides.removeAll { $0.id == guide.id } }.labelStyle(.iconOnly)
                .help("참고 삭제")
            }
            TextField("예: docs/verification.md", text: $guide.path).font(.system(size: 12, design: .monospaced))
              .onChange(of: guide.path) { _, _ in guide.expectedSha256 = nil }
              .onChange(of: guide.repoId) { _, _ in guide.expectedSha256 = nil }
            if let hash = guide.expectedSha256 {
              Text("읽고 고정한 SHA-256: \(hash)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
              Button("고정 해시 지우기") { guide.expectedSha256 = nil }.font(.caption)
            } else { Text("아직 읽은 버전을 고정하지 않았습니다.").font(.caption).foregroundStyle(.secondary) }
          }.padding(.vertical, 4)
        }
        Button("참고 추가", systemImage: "plus") {
          if let repoID = repositoryIDs.first { guides.append(WorkflowGuideReference(repoId: repoID)) }
        }.disabled(guides.count >= 10 || repositoryIDs.isEmpty)
      }.padding(.top, 6)
    }.font(.system(size: 12))
  }
}

struct WorkflowGuidesView: View {
  @ObservedObject var model: TaskContextStore
  let selectedRepoID: String?
  @State private var preview: VerificationGuideRead?
  @State private var selectedGuideID = ""
  @State private var capturedIdentity = ""
  var body: some View {
    if let workflow = model.workflow, !workflow.workflow.guides.isEmpty {
      DisclosureGroup("검증 절차 · 기능 지도 \(workflow.workflow.guides.count)개") {
        VStack(alignment: .leading, spacing: 8) {
          Text("내용을 읽거나 실행한 상태가 아닙니다. 현재 폴더의 저장소에 속한 참고만 명시적으로 읽습니다.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(workflow.workflow.guides) { guide in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 3) {
                Text("\(guide.repoId) · \(guide.kindLabel)").font(.system(size: 12, weight: .medium))
                Text(guide.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text(guide.expectedSha256 == nil ? "고정한 버전 없음" : "읽은 버전 고정됨 · 현재 파일은 미조회")
                  .font(.system(size: 11)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 4)
              Button("읽기") {
                let identity = model.identity
                Task {
                  guard let result = await model.readGuide(id: guide.id, at: identity), identity == model.identity else { return }
                  selectedGuideID = guide.id; capturedIdentity = identity; preview = result
                }
              }.disabled(!model.loaded || model.working || model.isDirty || guide.repoId != selectedRepoID || !workflow.canWrite)
            }
          }
        }.padding(.top, 6)
      }.font(.system(size: 12))
      .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
        if let preview {
          VerificationGuidePreview(model: model, read: preview, guideID: selectedGuideID, identity: capturedIdentity)
        }
      }
      .onChange(of: model.identity) { _, _ in preview = nil }
    }
  }
}

private struct VerificationGuidePreview: View {
  @ObservedObject var model: TaskContextStore
  let read: VerificationGuideRead
  let guideID: String
  let identity: String
  @Environment(\.dismiss) private var dismiss
  @State private var pinned = false
  private var statusLabel: String {
    switch read.status {
    case "matching": "고정한 버전과 일치합니다."
    case "changed": "고정한 버전에서 내용이 바뀌었습니다. 영향을 확인하세요."
    default: "이 파일의 기준 버전은 아직 고정하지 않았습니다."
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(read.repoId) · \(read.path)").font(.headline).lineLimit(2).help(read.path).textSelection(.enabled)
      Text(statusLabel).font(.callout).foregroundStyle(read.status == "changed" ? WorkbenchTheme.warning : WorkbenchTheme.secondaryText)
      Text("일반 텍스트로 최대 64 KiB를 읽습니다. 링크·명령·포함 파일은 열거나 실행하지 않으며, 내용은 인수인계에 자동 복사하지 않습니다.")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(read.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
      }.frame(minHeight: 300).background(WorkbenchTheme.canvas).border(WorkbenchTheme.line)
      Text("SHA-256 \(read.sha256)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
      Text("읽은 시각: \(Date(timeIntervalSince1970: read.readAt).formatted()) · 이후 변경은 다시 읽어 확인하세요.")
        .font(.caption).foregroundStyle(.secondary)
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
      HStack {
        if pinned { Text("읽은 버전을 기준으로 저장했습니다.").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("이 읽은 버전을 기준으로 저장") {
          Task { pinned = await model.pinGuide(read, guideID: guideID, at: identity) }
        }.disabled(pinned || model.working || model.isDirty || model.identity != identity)
      }
    }.padding(24).frame(width: 740, height: 640)
      .onChange(of: model.identity) { _, _ in dismiss() }
  }
}

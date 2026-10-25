# Task workflow

River keeps task intent, criterion-linked reports and repository verification references in the existing **작업 정보** pane. It helps a person inspect what a report refers to and what needs another check. It does not decide whether a criterion is fulfilled, approve a merge, invoke an AI provider, or execute a guide.

## Write criteria with a stable identity

Open **작성 · 수정**, describe the purpose, and add completion-criterion rows. Save before recording a report or generating a draft.

| Action | Identity and history |
| --- | --- |
| Edit a criterion | Keeps its ID and advances its criterion version. Earlier reports retain the earlier text and version. |
| Move a row | Keeps its ID and version. Position does not identify a criterion. |
| Duplicate a row | Creates a new UUID, even when the text is identical. |
| Delete a row | Removes it from the active list while retaining historical versions and report bindings. The retired ID cannot be reused. |

Existing duplicate strings receive distinct IDs when the new engine first creates the workflow sidecar. River never reconstructs identity from similar text or list position. Reordering or editing another criterion does not invalidate an unchanged criterion binding. A purpose or ordinary-reference change is identified separately; existing Git checks also retain their original whole-context requirements hash.

Expand a criterion to inspect its linked recent reports, the criterion version used, and applicability warnings. A report linked to an earlier version, a changed purpose, another folder, or an unqueried current state needs inspection. A link count is not a completion score. Deleted-condition bindings remain in the receipt details; they do not silently attach to a new condition with similar text.

The service returns the most recent **50 receipts across the task context**, not 50 per repository. Linked evidence is limited to those returned receipts. An absent recent link does not mean no older report exists. Context-version summary queries return the latest **10** summaries; stored versions and evidence are retained independently of these response bounds.

## Record what was reported and what was observed

Choose **직접 / AI 결과 기록…** and select the current criteria the report addresses. Leaving all criteria unchecked creates an explicitly unlinked report. Saving captures the selected criterion IDs, versions and text together under the current context and workflow revisions; a stale revision or unknown ID is rejected.

Record these separately:

- **Reported result:** passed, failed, or unknown, plus the command/item and explanatory note. The command text is not executed.
- **Claimed reviewed state:** the full HEAD and/or River change-state hash the author explicitly says they reviewed. Leave unknown values empty. River does not fill these from the current folder or the recording-time observation.
- **Provenance and evidence references:** provider, exact model/version when known, and literal artifact paths or links. River does not read, fetch, upload or authenticate those references.
- **Report completion status:** completed, incomplete, tool error, or unknown. A “passed” result with an incomplete, failed-tool or unknown report status does not establish that the review completed.

Receipt details also retain the app's repository/folder, HEAD and change-state observation at recording time. That observation identifies where the record was made; it does not certify which code the reporter examined. A claimed state matching the current state remains an unobserved author report. HEAD alone does not describe uncommitted working-folder changes. Missing or partial claims, report errors and failures stay visible in the compact warnings and report labels.

Older receipts remain unchanged and explicitly unlinked. There is no automatic retroactive matching of criteria or backfilling of claimed review state. Record a new report if you need to make a new explicit statement about an older result.

River's own **공백 · 충돌 마커 검사** remains a separate app-run observation. Its tracked-file hygiene scope does not establish build/test success, criterion fulfillment, or merge readiness.

## Connect a verification procedure or feature map

In **작성 · 수정**, expand **검증 절차 · 기능 지도**, add a reference, and choose its repository, kind and relative path, for example `docs/verification.md`. These references are scoped to the repository or the repositories participating in the task. Saving a reference does not probe or read the file.

After saving, select the reference's repository and the original or task folder you want to inspect. In the pane's reference disclosure, press **읽기**. Reads use that actual selected repository/worktree root; a sibling repository's guide cannot be read through the current target.

Supported inputs are regular UTF-8 files of at most **65,536 bytes (64 KiB)** with the case-insensitive extensions `.md`, `.txt`, `.mdc`, or `.rst`. Paths must be relative and cannot contain traversal, empty components, backslashes or control characters. Symlinks in the file or directory path, including the root path, are rejected. Directories and special files are rejected. The reader does not follow network links, expand includes, render executable Markdown, or run commands.

The preview shows plain text, its read time and SHA-256 of the exact bytes read:

| State | Meaning |
| --- | --- |
| No pinned version | No expected content hash has been saved. |
| Matching | The just-read bytes match the saved expected hash. |
| Changed | The just-read bytes differ from the saved expected hash; inspect the changes before updating the pin. |

Reading does not change task information. Choose **이 읽은 버전을 기준으로 저장** to explicitly save the read hash as the expected version. Changing a guide's repository or path in the editor clears the previous pin. A pin records document bytes; it does not mean the procedure ran, its instructions are correct, or a particular report followed it. Add relevant document/version references to a report yourself when needed. A read is a point-in-time observation; read again to detect subsequent changes.

Up to **30 active criteria**, **10 ordinary references**, **10 guide references**, and **10 artifact references per report** are supported. Text fields and IPC also have bounded sizes. A rejected read or stale save preserves the draft or reference; it does not fall back to an external file or silently repeat a write.

## Carry the context forward

Use **검증 요청 · 인수인계 초안** to preview and edit a handoff or verification request before copying. The draft includes active criterion IDs and versions, bounded recent report bindings, claimed review state separately from recording-time observations, report metadata, and guide repository/path/pinned-hash references. Each repository's current state is collected independently; unavailable or unprepared folders remain unqueried.

The generated draft includes up to the most recent **5 returned receipts per target**, drawn from the context-wide latest 50. It does not include guide contents or fetch artifact references. Copying remains explicit; River does not contact a provider. Check the destination, current code and any changed context before passing the draft on. Scope changes dismiss editors and read previews rather than applying their results to another target.

## Older engines and conflicting legacy writes

Workflow v2 uses separate side tables for criterion identity, versions and evidence metadata. Existing `TaskContext` and verification-receipt JSON schemas, old receipt bytes, and the legacy requirements-hash algorithm remain compatible. Initial sidecar migration does not rewrite the old context or invent receipt links. Explicit subsequent saves update the compatible context projection as well as the new typed state atomically.

An older engine omits the capability marker. River keeps the existing text editor and legacy reports available and explains that rich features require an updated engine and reconnect. It does not kill a borrowed engine. A rich unsaved draft is preserved when reconnecting to an older engine and cannot be silently saved as plain text; copy it first, or deliberately reload the compatible saved context.

After migration, a new engine rejects an old client's legacy save with `workflow_upgrade_required` so it cannot erase criterion identity. An actual older engine may still write the legacy projection. The new engine detects a revision or full-body mismatch as `legacy_changed`, shows the current legacy text separately from previous typed history, and blocks rich writes until recovery.

To recover, preserve any unsaved input, use **현재 저장본 불러오기** where needed, then explicitly confirm **현재 작성본으로 조건 ID 새로 만들기…**. Reset creates fresh IDs from the current legacy criteria, retains old versions and evidence, and preserves valid guide references. It never guesses which former condition the new text represents or reconnects old reports automatically. Reset is a history-preserving identity reset, not an undo of the older writer's changes.

See [AI workflow direction and research](ai-workflow.md) and the [design contract](../DESIGN.md).

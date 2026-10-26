# Design

## Source of truth

- **Status:** Active. **Last refreshed:** 2026-10-26.
- **Current direction:** River Clear. The product owner approved the two-column Focus arrangement and fresh water-colored palette after a Claude/Codex design discussion. The native implementation uses these as the starting arrangement and appearance for new preferences.
- **Primary surfaces:** Native macOS welcome screen, Git review workspace, task planning/preparation, and task information.
- **Evidence:** [Product scope](README.md), [River Clear rules](docs/design/river-clear.md), [familiar Git layouts](docs/design/familiar-git-layouts.md), and [current limitations](docs/limitations.md). Implementation lives in [WorkbenchUI](apps/macos/Sources/WorkbenchUI), particularly `WorkbenchTheme`, `LayoutPreferences`, `DockWorkspace`, `WorkspaceContextHeader`, and `FolderLocationControl`.
- **Personalization extension:** Actual Claude, Devin and Grok design advice and peer exchanges informed the [personal workspace contract](docs/customization.md). Named full-configuration snapshots were chosen deliberately; advisors differed on whether Diff style belongs in them. No claim of provider implementation approval or measured performance follows from design advice.
- This document is the active design contract. A design proposal or advisor suggestion becomes a product rule only after adoption and implementation; historical discussion does not override current behavior.

## Brand

- **Name:** River (리버). **Concept:** Many rivers. One ocean. The streams of work and Git branches come together into the software we build.
- **Icon:** The approved G artwork, “유리 속의 바다” (an ocean within glass). Preserve the selected glass pool, incoming amber/teal/lilac light, aqua center, and transparent outer corners. This icon is distinct from the historical layout G, now available through the optional repository-track navigation.
- **Personality:** Clear, calm, precise, practical. Water-colored chrome surrounds quiet, opaque reading surfaces.
- **Trust signals:** Actual repository/branch/folder identity, explicit preparation outcomes, scoped actions, and checks distinguished from reports.
- **Avoid:** Decorative activity, invented success, ocean metaphors in operational labels, copied competitor branding, heavy glass effects over code, and claims of measured speed without benchmarks.

## Product goals

- Review and commit changes across repositories and linked worktrees while preserving the original checkout.
- Keep current location clear, preserve the user's review context, and retain successful siblings when another repository fails preparation.
- Reduce simultaneous visual elements: start with files and Diff, open supporting panels when needed, and keep exceptional states visible.
- **Non-goals:** Automatic AI execution, automatic merge/deployment, broad history rewriting, or a web-based desktop shell. See the [supported scope](README.md#current-limitations).
- **Success signals:** Users can identify the current repository and folder, resume a review after switching locations, find Stash/branches, and recover from a failed operation without confusing it with success. These are design goals, not completed usability-study findings.
- **First-use correction:** A real-project trial exposed that list filters were mistaken for staging actions and the intent/AI/evidence flow was not discoverable. Provide explicit selected-file staging/unstaging, retain optional hunk actions, and explain the next action in the existing files/Diff/task surfaces. Do not add a mandatory setup wizard or a permanent process dashboard.

## Personas and jobs

- **Primary users:** Developers working across local repositories, including developers collaborating with coding agents.
- **Jobs:** Read changes, stage selected files or text hunks, write deliberate commits, prepare related branches/worktrees, inspect branch history and Stash, and record task intent and evidence.
- **Guided task use:** An existing checkout can hold task intent without first creating another branch/worktree. Explain purpose/criteria → copy editable context to the user's AI tool → inspect actual results and record evidence → review/stage/commit. Describe these as user actions, never automatic AI-DLC phase completion or integration approval.
- **Context:** Desktop and keyboard use, familiar Git GUI conventions, multiple working directories, and occasional preparation or connection failures.

## Information architecture

- The compact header has task/workspace selection and named access to task information, history, all branches, Stash, and commit. Refresh and layout remain adjacent.
- The repository row shows repository navigation, actual branch or detached HEAD, folder kind, and identifying folder basename. Normal tab navigation uses two 48pt context rows before the work area. Optional tracks retain their own repository navigation; exceptional notices may need more space.
- The folder button opens selectable full-path text, path copy, Finder, and explicit task/original-folder choices. A planned folder is labeled as not yet prepared. Unresolved task metadata is distinct from a known pending directory.
- **Focus** starts with files and broad unified Diff. **Balanced** adds one utility group containing commit, Stash, and task information. Classic, Code Review, and Repository Tracks remain alternative starting arrangements.
- Every files, Diff, graph, branches, commit, Stash, or task-information pane remains independently dockable. Opening an existing pane selects it. Opening a missing commit/Stash/details pane reuses an existing utility group; otherwise it opens beside Diff. History opens below Diff and branches alongside Diff as a tab.
- A preset initializes a tree; it does not constrain later placement. Save nested splits, ratios, active tabs, hidden panes, and diff style. Preserve existing saved layouts. Resizing does not silently rearrange or hide panes.
- **Personal layouts:** Keep the current arrangement automatically, and let users explicitly save named full-layout snapshots for different jobs. Switching a saved layout or factory arrangement is reversible and preserves repository selection, review state, and drafts. Appearance and reading preferences remain independent. Existing `workbench.layout.v1` preferences must continue to load.
- **Pane enlargement:** A pane can temporarily fill the work area with an explicit return action. Retain the complete dock tree and its ratios rather than hiding its siblings or overwriting saved preferences. This is distinct from the two-pane Focus starting arrangement.
- Stash selection is read-only and replaces the file/Diff content; explicit return restores current changes. Branch selection reads history without checkout. Both use real Git data.
- Task information records purpose, completion criteria, references, notes, checks, and reports. App-run observations are distinct from human/AI reports. Hunk requests and handoff drafts use explicit preview/copy; the app does not invoke providers.
- **Evidence and next action:** In task information, show a compact current-folder summary before the expandable receipt history. Keep failure, unknown, changed-code/requirements and unavailable observations visible while history is collapsed. State the recent-record bound and keep author reports separate. A matching Git check proves only its tracked hygiene scope; it never establishes criterion fulfillment, test success or merge readiness. Reuse this summary per repository in handoff, including unprepared or unqueried targets. Existing preview/copy offers only handoff and verification-request drafts; preserve edits, dismiss on scope change, and state that collected observations may be older than the current code. Verification requests ask for actual behavior and inspectable evidence, without invoking an agent or reading reference content. [Workflow direction](docs/ai-workflow.md).
- **Condition and evidence identity:** Task information edits completion criteria as stable rows. Editing retains the ID and advances its version; moving retains both; duplicating makes a new ID; deleting keeps past bindings and versions. Recent linked reports open under each condition. Show changed/deleted bindings, unknown or incomplete reports, missing claimed code state, and unqueried targets without turning report counts into completion scores. Historical receipts remain unlinked unless their author explicitly records a new report; do not infer links from matching text or position.
- **Reported review basis:** Separate the author's claimed reviewed HEAD and change snapshot, provider/model, literal artifact references, and report-completion status from the app's observation at recording time. Leave unknown claims empty. A matching claim remains an unobserved report; incomplete, tool-error, unknown, failed, or changed-state records must remain apparent with details collapsed. Never label a condition fulfilled or a change approved on this basis.
- **Repository verification references:** Keep procedures and feature maps inside the existing Task information editor and a named disclosure. Each reference identifies its repository, kind, relative path, and optional pinned SHA-256. Read only after an explicit action in that repository's selected folder, show bounded plain text and pin status, and require a separate action to save the read hash. No automatic Markdown execution, includes, network fetches, or guide-content copying into handoff. Pinning records document bytes, not execution or procedural compliance. See [Task workflow](docs/task-workflow.md).
- **Workflow compatibility:** Capability-gate rich editing on the engine's version marker and keep older-engine text editing/reporting available. Preserve rich drafts when reconnecting to an older engine rather than downgrading them silently. If a legacy writer changed the compatible projection, present the current legacy text separately from previous typed history, block rich writes, and offer explicit reset with fresh condition IDs while retaining history. Keep draft copy/reload reachable; never guess identity or terminate a borrowed engine to upgrade it.
- **App updates:** Put ‘업데이트 확인…’ in the native River menu and automatic-check preferences in native Settings. Keep update controls out of the Git workspace toolbar. Check daily by default; download and installation require user action. Before restarting, block active work across all visited locations and explain session draft loss or uncertain outcomes. Pending installation remains reachable after choosing Later.
- **Remote operations:** A named `원격` disclosure sits beside the current-folder context in both tab and repository-track navigation. Keep remote selection, endpoint details, fetched branches, synchronization, and URL management in that disclosure; do not add a permanent action row or pane. Clone is a secondary welcome/menu action with one sheet.

## Design principles

1. **Keep context visible and details reachable.** Show repository, branch, and folder identity; place full paths and normal explanations in explicit disclosure.
2. **Let code lead.** Use one draggable title row per pane, restrained metadata, quiet hunk actions, and a filled commit action. Avoid duplicate titles and repeated healthy-state badges.
3. **Expose exceptions.** Preparation failure, unknown write outcome, stale/read-only state, planned folders, and excluded untracked files remain visible and actionable.
4. **Preserve the user's arrangement and work.** Moving or hiding a pane must not mutate Git, select another repository, or erase a draft. Fresh defaults never overwrite a saved layout.
5. **Keep familiar Git semantics.** Staging, committing, task preparation, reading checkpoints, and verification are separate operations. A reading mark is not approval or merge readiness.

## Visual language

- **Color:** Clear Shallows (`맑은 물`) is the default light appearance; Clear Deep (`깊은 물`) and system appearance are independently saved choices. [Exact tokens and contrast](docs/design/river-clear.md#color-tokens) live in `WorkbenchTheme`.
- **Surfaces:** Water-colored chrome/navigation, opaque code canvas, and selection. Panel reuses navigation; elevated surfaces reuse canvas. Brand amber/lilac belong to the icon and welcome signature, not status.
- **Typography:** System sans for controls and metadata; monospace for code, paths, OIDs, and refs. Normal controls use 12–13pt, task title 15pt. Small secondary metadata must not replace readable primary labels.
- **Reading controls:** Persist code size and comfortable/compact row spacing separately from layouts. Derive diff text, gutters, and total hunk height from the same metrics so larger text cannot clip. Density must retain source signs, file identity, paths, and safety notices.
- **Rhythm:** 4pt spacing units, two 48pt normal header rows, modest pane padding, subtle dividers, and restrained rounded controls. Preserve room for code rather than adding decorative cards.
- **Motion:** Focus and state feedback only. Respect Reduce Motion and Reduce Transparency. Code surfaces remain opaque.
- **Imagery:** The approved raster app icon, SF Symbols, and native Git graph edges derived from actual parent OIDs. Task grouping must not masquerade as Git ancestry.

## Components

- Reuse `WelcomeView`, `WorkspaceContextHeader`, `RepositoryTabs`/`RepositoryTracks`, `CurrentFolderContext`, `DockWorkspace`, `WorkspaceSidebar`, `DiffWorkspace`, `CommitComposer`, `TaskInspector`, `TaskContextView`, `BranchesView`, and `NewTaskSheet`.
- Pane title rows provide drag, placement, and hide controls. Normal body content should not repeat the pane title. Required context, filters, counts, and read-only state may remain in body toolbars.
- Personalization uses one named screen-configuration entry point with progressively disclosed layout, panel, and reading controls. Use accurate miniatures of real dock trees instead of indistinguishable preset symbols. Keep all panels accessible from a native View menu and preserve named access to Stash and branches.
- Reuse theme tokens and shared `ChromeButtonStyle`/`PrimaryActionStyle`. Hunk staging is a quiet outlined action; its availability and warning semantics remain unchanged.
- **Staging discovery:** Name the source lists `스테이징 전` and `커밋에 포함` (or equally explicit Git terms) and distinguish their filters from real write buttons. Offer visible selected-file actions including new files when the connected engine advertises support. File staging affects only the selected file; partial staging remains separately labeled. Explain capability, conflict, stale/read-only and unsupported-file blockers near the action. Git snapshots and service authorization remain authoritative; never substitute a shell command from the UI.
- **AI guidance:** Put the existing editable context/request-copy action before result recording in Task information, with one short numbered explanation of how to use an external AI tool. Keep advanced report provenance inside a named disclosure and keep unknown/incomplete/tool-error status visible. A clean Diff offers a direct route to writing task intent. Keep the existing handoff and verification request types and make handoff include its intended instruction, with collected source material quoted separately.
- Keep the commit target and staged count in the action. Show hook/signing behavior nearby and explain that new files must be explicitly staged before inclusion.
- **Ownership:** `WorkbenchUI` owns native views/tokens and presentation state; `WorkbenchProtocol` owns typed wire models; `WorkbenchRuntime` owns engine startup and local registration. Rust owns Git operations and authorization.

## Accessibility

- WCAG 2.2 AA contrast is an implementation target; complete native accessibility certification remains open.
- Use native buttons, menus, fields, sheets, and meaningful accessibility labels/values. Full location values must be available even when visually truncated.
- Keep placement actions reachable without dragging and critical controls available without hover. Provide visible focus and text/icons alongside color.
- The folder disclosure and pane actions must be operable by keyboard. Preserve existing shortcuts and Escape dismissal.
- Dedicated Increase Contrast colors strengthen lines and text. Code remains selectable; diff additions/deletions retain signs and semantics. Token contrast calculations do not replace VoiceOver or keyboard testing.
- Diff rows expose embedded line controls and bidirectional controls as visible glyphs. The raw patch remains unchanged for hashing and staging. Previous-reading sheets retain the captured read-only snapshot when live selection changes.

## Responsive behavior

- Primary reference size is 1440×960; minimum workspace size is 1100×720.
- Preserve the dock tree at narrow sizes. Nested splits honor pane minimums and scroll when necessary instead of overlapping or silently relocating panes.
- Long branches, folders, and task names truncate with full values available. The folder kind and named Stash/branch entry points retain clear identities.
- Branch search/list and history stack within narrow branch panes. Short panes scroll their content; Stash uses the available pane height without a second capped list.

## Interaction states

- **Loading:** Restore coherent cached review content while validating it; block edits until validation succeeds. Without a cached repository and Diff, show explicit initial loading before any clean/empty result. Planned folders and validation failures retain their distinct states. A failed lookup is an error, not an endless spinner.
- **Empty:** Welcome offers a repository picker, synthetic example, and recent workspaces. Normal setup never asks for socket paths or terminal commands. Empty panels describe their next useful action concisely.
- **Error:** Give a concrete recovery action and preserve location/drafts. Cached Diff stays visible but read-only after validation failure. Partial preparation keeps completed repositories available.
- **Plan recovery:** An expired execution preview returns to the same filled-in form and requires a fresh preview before execution. Source drift or a branch collision during preparation directs the user to a new task plan; do not repeat an immutable invalid plan or delete existing branches/folders to make it pass.
- **Success:** Show real per-repository readiness; avoid permanent celebratory cards or repeated ready badges. A task folder becomes selectable only with its true state.
- **Disabled:** Explain actual blockers: read-only Stash, unsupported/oversized diff, conflicts, unresolved task, unstaged work, or validation in progress. Do not imply an unavailable operation succeeded.
- **Reconnect:** Publish a candidate workspace only after its handshake. Same-workspace reconnect preserves drafts and invalidates executable plans. Old responses cannot replace newer workspace/location state.
- **Unknown outcome:** Keep an origin-project notice during the app session; require inspection before repeating a write. Never silently replay a mutation.
- **Remote writes:** Pull and push confirmation identifies the actual repository, folder, local branch, remote URL, and target branch. Freeze that identity with the reviewed state; switching folders/workspaces invalidates submission. A successful push remains successful if the subsequent refresh fails. Pull uses fast-forward integration and requires a clean folder; show concrete blockers. Network progress belongs to its originating location and must not erase commit drafts or move the user's selection.
- **Refresh:** Explicit refresh re-reads selected Diff even with unchanged content snapshots. Background polling uses the cheaper unchanged-state path and pauses while inactive. Location/workspace changes cancel the obsolete client read wait so current validation can start immediately; only the owning refresh may clear its loading state. This does not claim cancellation of server-side work. Discover workflow capability per connection, then read rich task information directly and publish only changed values. Fall back to older-engine discovery only for an unsupported method; preserve errors and drafts.

## Content voice

- Use concise Korean UI labels with familiar Git terms. English README is canonical; Korean documentation must describe the same supported behavior.
- Prefer explicit `작업용 폴더`, `원래 프로젝트 폴더`, and `예정 작업 폴더` over ambiguous numbered locations or unexplained “checkout.”
- Describe what a check actually ran. Reports, personal reading marks, and app-observed results must not borrow each other's authority.
- Keep technical paths, hashes, and advanced diagnostics available through disclosure. Do not put internal transport setup in normal product flows.

## Implementation constraints

- Native SwiftUI/AppKit and SwiftPM, macOS 14+ source target; Rust local service. No Tauri/WebView/Node runtime in the active app.
- `WorkbenchTheme` owns semantic colors. Appearance persists separately from layout. Internal application identifiers/data paths remain compatible with existing registrations.
- Git writes require fresh authorization and scoped snapshots. Presentation caching never authorizes writes. Original checkout, pinned plan, recipe trust, and stale-response protections remain intact.
- Git hooks, fsmonitor, and external signing programs are disabled; app commits are unsigned. Configured external filters are rejected. Status, Diff and hygiene-check content processes use private metadata/config/index and frozen attributes. Their Git 2.43 requirement has a concrete update explanation. Worktree materialization and commit retain a separate live-configuration boundary; do not describe this as universal Git isolation. See [limitations](docs/limitations.md) rather than weakening policy for a cleaner screen.
- Retain bounded caches, diffs, history, and IPC. Avoid unnecessary re-fetches, full-store publication, layout-triggered Git work, and parsing during pointer movement. Large-repository performance is not yet benchmarked.
- Remote Git transport uses provider-neutral SSH/HTTPS. The first implementation uses existing SSH agent/default identities and known-host files, or the trusted macOS Git keychain helper. Provider login, arbitrary credential helpers, SSH aliases/proxies, filesystem remotes, and automatic credential prompts are outside this version. See [remote contract](docs/remotes.md) for exact boundaries.
- Validate Swift/Rust checks, real process boundaries, and native renders with synthetic Git data. Record OS input, keyboard, VoiceOver, supported-version, and performance validation separately; a screenshot does not establish them.

## Open questions

- [ ] Product owner: choose a license for the project. The authorized public testing alpha retains the disclosed `UNLICENSED` status; distribution does not imply that licensing is resolved.
- [ ] QA: complete OS-level keyboard/VoiceOver testing and verify long names and dense custom layouts across supported systems.
- [ ] Performance: measure repository switching, worktree creation against Git CLI, and idle/active memory on large repositories before making performance claims.
- [ ] Distribution: complete Apple notarization and minimum-supported-macOS runtime validation. Developer ID-signed DMG packaging is available; see [release notes](docs/releases/v0.1.0-alpha.3.md).

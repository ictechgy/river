# River

<img src="apps/macos/Resources/AppIcon.png" alt="River app icon" width="96" height="96">

**English (canonical)** · [한국어](README.ko.md)

**A native macOS Git app for reviewing work across repositories and worktrees.**

**Many rivers. One ocean.** Our streams of work come together into the software we build.

> Early alpha. Downloadable macOS builds are available for testing. There is no stable release yet, and the license is still undecided.

The app UI and detailed guides are currently in Korean. English translations of UI labels below are provided for reference. **[Start with a real project: staging and AI workflow (한국어)](docs/getting-started.md).**

## Install on macOS

**[Download River 0.1.0-alpha.10 for Apple Silicon](https://github.com/ictechgy/river/releases/download/v0.1.0-alpha.10/River-0.1.0-alpha.10-macos-arm64.dmg)** · [Release notes and checksums](https://github.com/ictechgy/river/releases/tag/v0.1.0-alpha.10)

- **Apple Silicon (arm64) only.** This release does not include an Intel build.
- **macOS 14 or later is the declared target.** Runtime testing has only covered macOS 27.0.1; compatibility with older supported versions has not been verified.
- **Apple command-line Git is required.** Git 2.43 or later is required for isolated status, Diff and Git hygiene checks. If `/usr/bin/git --version` does not work, install Apple's [Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) with `xcode-select --install`. The built-in example also requires `python3` for its preparation recipes. River includes its app and engine; Rust, Swift, Node, and a source build are not required to use the download.

1. Download and open the `.dmg` file.
2. Drag **River.app** into **Applications**.
3. Eject the River disk image, then open **River** from **Applications**.
4. Choose **Explore the example** (`예제로 먼저 둘러보기`) to try synthetic repositories before opening your own project.

**Updates:** Starting with alpha.6, River checks for new releases automatically. Use **River → 업데이트 확인…** or **Settings → 업데이트** to check manually or disable automatic checks. Download, installation and restart require your choice. Save session drafts before restarting; active work postpones installation. **Alpha.5 and earlier need one manual installation of the current release.** See [updates](docs/updates.md).

The app, bundled engine, and DMG have verified Developer ID signatures. This alpha is **not notarized by Apple**, so macOS may block its first launch. See the [release notes](docs/releases/v0.1.0-alpha.10.md) for verification details.

If macOS blocks opening because it cannot verify the developer or check the app, review the release status and source first. If you choose to continue, use **System Settings → Privacy & Security → Open Anyway** after attempting to open River, then confirm **Open**, as described in [Apple's guide](https://support.apple.com/en-us/102445).

![River Clear native workbench with a changed-file list and broad unified diff on light water-colored surfaces](docs/images/workbench-light.png)

*An actual SwiftUI/AppKit view rendered with synthetic Git repositories. The Focus layout starts with files and a broad diff; reference panels open when you need them.*

## What it does

Open an existing Git repository to review, stage and commit changes in its current folder. You can record a purpose, completion criteria and verification evidence there without creating a Task or worktree.

For separate or parallel work, a **Task** can create branches and prepare working directories (Git linked worktrees) across repositories configured in a **workspace**. The original checkout stays in place; completed preparation is retained if another repository fails.

| Feature | Available today |
| --- | --- |
| Worktree-first tasks | Create branches and prepare working directories across configured repositories, inspect each repository's status or failure, and retry explicitly. |
| Review and commit | Stage or unstage a selected file, including new files; optionally select text hunks. Review split or unified diffs and commit only staged changes. |
| Branches and stash | Search local and remote-tracking branches, inspect recent history as of the last fetch, see linked worktree locations, and browse stash files and diffs read-only. |
| Remote Git | Manage SSH/HTTPS remotes, clone repositories, fetch branch heads, pull with fast-forward integration, and push one branch. The transport works independently of GitHub, GitLab, Bitbucket or self-hosted provider APIs. |
| Review continuity | Restore file, diff, and scroll state within the same workspace, then refresh Git state. Commit drafts last for the app session; personal review and scroll state last for the current workspace session. |
| Movable panes | Freely split, move, tab or hide panels. Keep up to 20 named layouts, enlarge a pane temporarily, and adjust code size and spacing independently of the layout. |
| Review alongside AI tools | Follow purpose → external AI request → actual results/evidence → review and commit. Track stable criteria and linked reports, read or pin verification guides, and preview/copy requests. |

The app does not call AI models directly. Copy a request into Claude, Codex, Grok, or another tool you use. Results entered by an AI or a person are stored as **reports**, separately from checks the app actually ran. The task panel summarizes recent evidence for the current folder; criterion fulfillment is not inferred. [Task workflow guide](docs/task-workflow.md) · [AI workflow direction](docs/ai-workflow.md).

<details>
<summary>Make the workspace your own</summary>

![River screen configuration and named layouts](docs/images/layout-customization.png)

Save named layouts with real previews, then adjust code size and spacing independently. [Customization guide](docs/customization.md).

</details>

<details>
<summary>See the dark appearance</summary>

![River Clear native workbench in its ocean-navy dark appearance](docs/images/workbench-dark.png)

Choose **Clear Shallows / Clear Deep / System** (`맑은 물 / 깊은 물 / 시스템 설정`) in **Layout** (`화면 구성`). Appearance changes keep your pane arrangement.

</details>

<details>
<summary>See the branches view</summary>

![Branches pane showing branches, linked working directories, commit IDs, subjects, and authors](docs/images/workbench-branches.png)

Selecting a branch reads its history without checking it out. This synthetic example shows local and remote-tracking branches alongside the original and task working directories.

</details>

## First launch

The app starts its bundled engine automatically; you do not need to enter a connection address or Unix socket path.

1. Choose **Open repository…** (`저장소 열기…`) and check the repository, branch and folder shown at the top. Opening a folder alone does not modify its files, HEAD or index, or grant trust to preparation scripts.
2. In **Before staging** (`스테이징 전`), select one changed file and read its Diff.
3. Click **Stage entire file** (`파일 전체 스테이징`) above the Diff. Staging selects changes for the next commit. For supported text changes, **Stage this change only** (`이 변경만 스테이징`) selects a hunk instead.
4. Switch to **Included in commit** (`커밋에 포함`) and check the selection. **Unstage entire file** (`파일 전체 스테이징 취소`) removes that file from the commit selection and preserves its working-folder content.
5. Open **Write commit** (`커밋 작성`), enter a message, check the target and staged count, then commit.

The two file-list labels are filters; the Diff buttons perform staging. New files must be explicitly staged too. A disabled button explains the current blocker. **Explore the example** (`예제로 먼저 둘러보기`) creates two synthetic repositories in the app's storage if you want to try this first. See the [step-by-step guide (한국어)](docs/getting-started.md).

Example creation only affects synthetic repositories. **Open repository…** currently registers a single-repository workspace with no preparation recipes. Multi-repository and recipe configurations are demonstrated by the built-in example and the [CLI examples (Korean)](docs/cli.md). Creating, editing, or importing these configurations through the GUI is not implemented yet.

Running a new task for a project registered with **Open repository…** creates a `feature/<task_slug>` branch ref in the original repository. `materialize` also creates a separate working directory under the app data location; `branch_only` creates only the ref and leaves the directory pending. Registration defaults to the current branch at the time of first registration, falling back to the first local branch for a detached HEAD, or `main` if none exists. Check the base branch and OID in the plan before executing it.

## Use it with an AI tool

Open **Task & AI guidance** (`작업·AI 안내`) in the top toolbar. It opens the existing **Task information** (`작업 정보`) pane with four steps:

1. Write and save the purpose and observable completion criteria.
2. Use **Preview/copy AI request** (`2. AI 요청 미리보기 · 복사`), choose a work-context or verification draft, review it, and paste it into your AI tool.
3. After implementation, check the actual behavior and record results, evidence and anything still unverified with **Record actual results/evidence** (`3. 실제 확인 후 결과 · 근거 기록…`). Claimed code state and provider/model are optional; leave unknown values empty.
4. Return to files, review the Diff, stage the intended changes and commit.

For example, “preserve the email after a failed login” becomes a purpose and testable criteria, an AI implementation request, a real failed-login check with logs or screenshots, then a reviewed commit. A reported pass or a clean Git check does not establish that the feature works. This connects human decisions, code and evidence for an AI-DLC-style workflow; River does not run an AI lifecycle or approve its stages. [Practical guide (한국어)](docs/getting-started.md#ai와-작은-기능-하나-진행하기).

## Keep working

- **Check the location:** Repository, branch, folder kind, and folder name stay visible. Open the folder control for the full path and to switch between a task's working directory and the original project directory. Pending or failed preparation is not shown as successful.
- **Resume a review:** Switching directories within a workspace restores the recent file, diff, and scroll position. Saved intent, completion criteria, and verification records remain in the journal. Commit drafts last for the current app session. Personal review and scroll state clear when you switch workspaces or quit.
- **Keep the review focused:** A fresh layout starts with files and a broad diff. Named toolbar actions open history, all branches, Stash, commit, and Task & AI guidance. Commit, Stash, and task details share an existing utility tab group when opened, keeping extra panels contained.
- **Arrange the panes:** Drag a pane title to another pane's left, right, top, or bottom edge to split, or to its center to combine them as tabs. **Layout** (`화면 구성`) offers Focus, Balanced, Classic, Code Review, and Repository Tracks as starting arrangements, plus pane visibility and undo. Existing saved layouts are preserved; select Focus explicitly to adopt the new starting arrangement. Each arrangement remains freely customizable. Save your own named layouts with real previews, or temporarily enlarge a panel without changing the saved tree. The native View menu exposes panel placement and shortcuts. See the [customization guide](docs/customization.md).
- **Choose the colors:** Clear Shallows is the default light appearance. Clear Deep and System are available in **Layout**, and the choice is saved separately from pane positions.
- **Connect a remote:** Open **Remote** (`원격`) beside the current folder to manage URLs and synchronize branches. Pull and push show their exact targets before submission. Clone is available from the welcome screen and application menu. Authentication uses existing SSH agent/default identities and known-host files, or Apple's Git keychain helper for HTTPS; provider login and custom SSH aliases/helpers are not included. See the [remote guide](docs/remotes.md).
- **Separate checks from reports:** **Whitespace and conflict-marker check** (`공백 · 충돌 마커 검사`) runs `git diff --check` on tracked and staged changes and checks Git conflict and in-progress operation state. It does not build or test the project, or inspect untracked file contents or submodule contents.

More workspace controls: `⌘⌥1`–`⌘⌥6` toggle panels, `⌘⌥Z` undoes screen configuration, and `⌃⌘↩` enlarges Diff or returns to the layout. Code size (11–20 pt) and code/file-list spacing are separate from layout snapshots.

Shortcuts: `⌘O` open repository · `⌘N` new task · `⌘R` refresh · `⌘⌥I` toggle the commit pane · `⌘↩` commit while that pane is active · `⌘⌥L` layout.

Settings, recent projects, and the task journal live in `~/Library/Application Support/AgentGitWorkbench`. The recent menu holds up to 30 entries; existing workspace registrations are looked up separately. Restoration depends on those registrations being readable.

## Current limitations

- **Not implemented:** Provider OAuth/PR APIs, force push, general branch checkout/rename/deletion (branches can be created only through task preparation), discard, merge/rebase/conflict-resolution UI, history rewriting, arbitrary-line staging, stash apply/delete, automatic AI calls, CI/build/merge execution, and Windows/Linux GUIs.
- **Remote boundaries:** SSH/HTTPS only. Custom SSH configuration, interactive authentication, arbitrary credential helpers, filesystem remotes, URL rewrites, multiple endpoints and partial clones are unsupported. Pull requires a clean folder and a fast-forward; divergent history is rejected. See the [exact policy and recovery behavior](docs/remotes.md).
- **Git execution policy:** The app does not run Git fsmonitor, hooks, or external signing programs. App-created commits do not run hooks and are unsigned, including when `commit.gpgsign=true`. Configured external clean/smudge/process commands cause status/diff reads, preparation, and writes to be rejected. Global LFS filter commands trigger this restriction even when the repository does not use LFS. Working-folder status, Diff and Git hygiene checks use private Git metadata, index and frozen attributes; executable filter definitions cannot enter those content reads. Worktree materialization and commit still use a preflight check against live configuration, so concurrent configuration edits remain outside that write boundary. See [limitations](docs/limitations.md). In the repository, inspect configured commands with `git config --show-origin --get-regexp '^filter\..*\.(clean|smudge|process)$'`.
- **Preparation and writes:** Working directories are prepared without changing the original checkout. A changed source snapshot or trust basis stops execution; there is no silent replanning or recovery through reset/clean. Recipes are not an OS security sandbox.
- **Staging and resources:** Selected-file staging is limited to 32 MiB per file and a 64 MiB index, requires a supporting engine, and rejects conflicts, submodules, special files, unsafe paths and unsupported conversion attributes. Text-hunk support is narrower. Graph and branch history show at most 80 recent commits. Diff display is capped at 5,000 lines and 512 KiB. Speed, memory, and energy use on large repositories have not been measured.
- **Recovery and refresh:** Lost preparation responses leave an origin-project notice for the app session; check that project's task list and Git state before repeating work. These notices do not survive an app restart. Use Refresh after changing Git attributes or diff settings. A read already started in the engine may continue after the client cancels it.
- **Distribution and validation:** The current prerelease DMG is for Apple Silicon. See its [release notes](docs/releases/v0.1.0-alpha.10.md) for signature and notarization status. Intel builds, runtime testing on macOS 14–26, OS-level input testing, and VoiceOver validation are not complete.

See [limitations and known issues (Korean)](docs/limitations.md) for details.

## Development and validation

### Build from source

You need macOS, Xcode with Swift 6 or later, Rust/Cargo, Git, and Python 3. Validation used full Xcode; a Command Line Tools-only build setup has not been tested. The Rust code uses edition 2024.

The tested environment is macOS 27.0.1, Swift 6.4, Rust 1.97.1, Git 2.54.0, and Python 3.9.6. These are tested versions, not a complete minimum-version compatibility matrix.

```sh
git clone https://github.com/ictechgy/river.git
cd river
python3 scripts/build_macos.py
open "build/macos/River.app"
```

The script builds the Rust engine and Swift app into an ad-hoc development-signed bundle. No Node, npm, or web server is required. For release packaging and signing options, see the [development guide (Korean)](docs/development.md).

### Validation

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path apps/macos
```

The validation workflow uses Rust and Swift tests, Rust formatting and Clippy checks, and native synthetic scenarios against the real Rust service. Scenarios cover selected-file staging, task context and reports; screens are rendered offscreen with SwiftUI/AppKit. See the [release notes](docs/releases/v0.1.0-alpha.10.md) for release-specific results. The package/updater Python suite is rerun for this release. Previous public GitHub/GitLab clone/fetch checks are historical evidence; remote clean-folder status now also uses the isolated content-read context and its regression suite. There is no CI yet. These checks do not establish behavior on real user repositories, OS-driven update installation/relaunch, or performance on large repositories.

Detailed guides are currently in Korean:

- [First real-project commit and AI workflow](docs/getting-started.md)
- [Development setup and validation commands](docs/development.md)
- [Architecture and execution boundaries](docs/architecture.md)
- [CLI, workspace, and recipe examples](docs/cli.md)
- [Limitations and known issues](docs/limitations.md)
- [Design principles](DESIGN.md) and [River Clear interface rules](docs/design/river-clear.md)

The license has not been chosen. Cargo metadata currently declares `UNLICENSED`.

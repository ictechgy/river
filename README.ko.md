# River

<img src="apps/macos/Resources/AppIcon.png" alt="River 앱 아이콘" width="96" height="96">

[English (원본)](README.md) · **한국어**

이 문서의 원본은 [영어 README](README.md)입니다.

**여러 저장소와 워크트리 사이에서 코드 검토를 이어가는 네이티브 macOS Git 앱.**

A native macOS Git app for reviewing work across repositories and worktrees.

**우리가 만드는 강줄기들이 모여 큰 바다를 만듭니다. 바다는 함께 만드는 소프트웨어입니다.**

> 초기 알파 단계입니다. 테스트용 macOS 앱을 다운로드할 수 있습니다. 안정 버전은 아직 없으며 라이선스는 미확정입니다.

## macOS에 설치하기

**[Apple Silicon용 River 0.1.0-alpha.7 다운로드](https://github.com/ictechgy/river/releases/download/v0.1.0-alpha.7/River-0.1.0-alpha.7-macos-arm64.dmg)** · [릴리스 정보와 체크섬](https://github.com/ictechgy/river/releases/tag/v0.1.0-alpha.7)

- **Apple Silicon(arm64) 전용입니다.** 이번 릴리스에는 Intel 빌드가 없습니다.
- **선언된 지원 대상은 macOS 14 이상입니다.** 실행 검증은 macOS 27.0.1에서만 했으며, 이전 버전에서의 호환성은 아직 확인하지 않았습니다.
- **Apple 명령줄 Git이 필요하며 원격 기능은 Git 2.41 이상을 요구합니다.** `/usr/bin/git --version`이 동작하지 않으면 `xcode-select --install`로 Apple의 [Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)를 설치하세요. 내장 예제의 준비 스크립트에는 `python3`도 필요합니다. 앱과 엔진이 함께 들어 있으므로 다운로드한 앱을 쓰기 위해 Rust·Swift·Node를 설치하거나 소스를 빌드할 필요는 없습니다.

1. `.dmg` 파일을 다운로드해 엽니다.
2. **River.app**을 **응용 프로그램(Applications)** 폴더로 끌어 놓습니다.
3. River 디스크 이미지를 추출한 뒤 **응용 프로그램** 폴더에서 **River**를 엽니다.
4. **예제로 먼저 둘러보기**를 선택해 합성 저장소로 사용해 본 뒤 자신의 프로젝트를 여세요.

**업데이트:** alpha.6부터 새 버전을 자동 확인합니다. **River → 업데이트 확인…** 또는 **설정 → 업데이트**에서 직접 확인하거나 자동 확인을 끌 수 있습니다. 다운로드·설치·재시작은 사용자가 선택합니다. 재시작 전에 임시 입력을 저장하세요. 진행 중 작업이 있으면 설치를 미룹니다. **alpha.5 이하는 현재 버전을 한 번 직접 설치해야 합니다.** [업데이트 안내](docs/updates.md)를 참고하세요.

앱·내장 엔진·DMG의 Developer ID 서명을 검증했습니다. 이번 알파는 **Apple 공증(notarization)을 받지 않아** 첫 실행이 차단될 수 있습니다. 자세한 검증 상태는 [릴리스 정보](docs/releases/v0.1.0-alpha.7.md)를 확인하세요.

macOS가 개발자를 확인할 수 없거나 앱을 검사할 수 없다는 이유로 실행을 막으면 릴리스 상태와 다운로드 출처를 먼저 확인하세요. 계속 진행하기로 했다면 River 실행을 한 번 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기(Open Anyway)**에서 허용하고 **열기**를 확인합니다. 자세한 절차는 [Apple 안내](https://support.apple.com/en-us/102445)를 따르세요.

![옅은 물빛 배경 위에 변경 파일 목록과 넓은 한 화면 Diff를 표시한 River Clear 네이티브 작업 화면](docs/images/workbench-light.png)

*실제 SwiftUI/AppKit 화면을 합성 Git 저장소로 렌더링했습니다. 집중 배치는 파일과 넓은 Diff로 시작하고, 필요한 패널을 열어 사용합니다.*

## 어떤 작업을 할 수 있나요?

설정된 여러 저장소에 작업 브랜치와 별도의 작업용 폴더(Git linked worktree)를 하나의 **Task**로 함께 준비하고, 변경을 저장소별로 검토·커밋합니다. 처음 연 프로젝트 폴더는 그대로 두며, 준비가 일부 실패해도 완료된 저장소의 결과는 유지합니다. 이 구성을 작업공간(workspace)이라고 부릅니다.

| 기능 | 현재 지원 범위 |
| --- | --- |
| 워크트리 중심 작업 | 설정된 저장소들의 브랜치 생성, 작업용 폴더 준비, 저장소별 상태·실패 확인과 명시적 재시도 |
| 코드 검토와 커밋 | 변경 파일, 나란히/한 화면 Diff, 텍스트 hunk 단위 스테이징·해제, staged 변경 커밋 |
| 브랜치와 Stash | 로컬·원격 추적 브랜치 검색과 최근 기록(마지막 fetch 기준), 연결된 폴더 표시, Stash 파일·Diff 읽기 전용 조회 |
| 원격 Git | SSH/HTTPS 원격 URL 관리, clone, 브랜치 fetch, 빨리 감기 pull, 단일 브랜치 push. GitHub·GitLab·Bitbucket·자체 Git 서버의 공통 Git 프로토콜을 사용합니다. |
| 전환 상태 유지 | 같은 작업공간에서 파일·Diff·스크롤을 복원하고 Git 상태 재확인. 커밋 초안은 앱 세션 동안, 개인 검토·스크롤은 현재 작업공간 세션 동안 유지 |
| 자유로운 화면 구성 | 모든 패널을 분할·이동·탭 결합·숨김. 이름 있는 배치 최대 20개, 임시 패널 확대, 배치와 독립적인 코드 글자·간격·색상 설정 |
| AI와 함께 검토 | 현재 폴더의 검증 상태·다음 확인 요약, hunk 수정 요청·검증 요청·인수인계 초안 복사, 작업 목적·완료 조건·결과 기록 |

앱이 AI 모델을 직접 호출하지는 않습니다. 복사한 요청문을 Claude·Codex·Grok 등 사용 중인 도구에 전달하는 방식입니다. AI나 사람이 적은 결과는 **보고**로 보관하며, 앱이 실제 실행한 검사 결과와 구분합니다. 작업 패널은 현재 폴더의 최근 근거를 요약하며, 완료 조건 충족을 추정하지 않습니다. [AI 작업 흐름과 보강 방향](docs/ai-workflow.md)을 참고하세요.

<details>
<summary>내 배치와 읽기 설정 보기</summary>

![River screen configuration and named layouts](docs/images/layout-customization.png)

실제 배치 미리보기를 보며 이름으로 저장하고, 코드 글자·간격은 따로 설정합니다. [사용자 설정 안내](docs/customization.md).

</details>

<details>
<summary>어두운 색상 보기</summary>

![짙은 바다색을 적용한 River Clear 네이티브 작업 화면](docs/images/workbench-dark.png)

**화면 구성**에서 **맑은 물 / 깊은 물 / 시스템 설정**을 선택합니다. 색상을 바꿔도 패널 배치는 유지됩니다.

</details>

<details>
<summary>전체 브랜치 화면 보기</summary>

![브랜치와 연결된 폴더, 커밋 ID·제목·작성자를 표시하는 브랜치 pane](docs/images/workbench-branches.png)

브랜치를 선택하면 기록을 조회합니다. 이 동작으로 checkout하지 않습니다. 위 합성 예제는 로컬·원격 추적 브랜치와 원래 프로젝트·작업용 폴더의 연결을 보여줍니다.

</details>

## 처음 실행하기

앱은 번들에 포함된 엔진을 자동으로 실행하므로, 연결 주소나 Unix 소켓 경로를 입력할 필요가 없습니다.

1. 시작 화면에서 **예제로 먼저 둘러보기**를 선택합니다. 앱 전용 위치에 합성 저장소 두 개와 준비 작업을 만듭니다.
2. 저장소를 골라 상단의 브랜치와 **작업용 폴더 / 원래 프로젝트 폴더**를 확인합니다. 폴더 버튼을 누르면 전체 경로 조회·복사, Finder에서 열기, 폴더 전환을 할 수 있습니다.
3. 변경을 읽고 **스테이징**을 누른 뒤, 커밋 pane에서 메시지를 작성합니다.
4. 자신의 프로젝트는 **저장소 열기…**로 선택합니다. 폴더를 여는 것만으로 파일·HEAD·index를 변경하거나 준비 스크립트를 신뢰하지 않습니다.

예제 생성은 합성 저장소에만 적용됩니다. **저장소 열기…**로 연 프로젝트는 현재 단일 저장소 작업공간으로 등록되며 준비 recipe가 없습니다. 다중 저장소와 recipe 구성은 내장 예제와 [CLI 예제](docs/cli.md)에서 확인할 수 있습니다. GUI에서 이 구성을 만들거나 편집하거나, 별도 설정 파일을 가져오는 기능은 아직 없습니다.

**저장소 열기…**로 등록한 프로젝트에서 새 작업을 실행하면 원래 저장소에 `feature/<task_slug>` 브랜치 ref가 생깁니다. `materialize`는 앱 데이터 위치 아래에 별도 작업용 폴더를 만들고, `branch_only`는 ref만 만든 뒤 폴더를 준비 대기로 둡니다. 일반 등록은 최초 등록 시점의 현재 브랜치를 기본 기준으로 설정합니다(detached HEAD이면 첫 로컬 브랜치, 없으면 `main`). 실행 전 계획 화면의 기준 브랜치·OID를 확인하세요.

## 작업을 이어가는 방법

- **위치부터 확인:** 저장소·브랜치·폴더 종류·폴더 이름을 계속 표시합니다. 폴더 버튼에서 전체 경로를 확인하고 Task의 작업용 폴더와 원래 프로젝트 폴더를 전환합니다. 준비 대기·실패 상태를 성공으로 표시하지 않습니다.
- **검토 상태 유지:** 같은 작업공간에서 폴더를 오가면 최근 파일·Diff·스크롤 위치를 복원합니다. 저장한 작업 목적·완료 조건·검증 기록은 앱 기록(journal)에 남습니다. 커밋 초안은 현재 앱 세션에 한정하고, 개인 검토·스크롤 기록은 다른 작업공간으로 전환하거나 앱을 종료하면 사라집니다.
- **검토에 집중:** 새 배치는 파일과 넓은 Diff로 시작합니다. 상단의 이름이 적힌 버튼으로 기록·전체 브랜치·Stash·커밋·작업 정보를 엽니다. 커밋·Stash·작업 정보는 이미 열린 보조 패널이 있으면 그 영역에 탭으로 모입니다.
- **직접 배치:** pane 제목을 끌어 다른 pane의 좌·우·위·아래에 나누거나 중앙에 탭으로 합칩니다. **화면 구성**에서 집중·균형·클래식·코드 검토·저장소 트랙 배치, 패널 표시, 배치 되돌리기를 선택합니다. 기존에 저장한 배치는 유지하므로 새 기본 구성을 쓰려면 집중을 직접 선택하세요. 모든 배치는 이후 자유롭게 바꿀 수 있습니다. 실제 미리보기를 보며 내 배치를 저장하거나, 저장 배치를 바꾸지 않고 패널만 잠시 확대하세요. 메뉴 막대의 보기(View)에서도 배치와 단축키를 찾을 수 있습니다. [사용자 설정 안내](docs/customization.md)를 확인하세요.
- **색상 선택:** 기본값은 밝은 **맑은 물**입니다. **화면 구성**에서 **깊은 물** 또는 **시스템 설정**으로 바꿀 수 있으며, 색상은 패널 배치와 별도로 저장합니다.
- **원격 연결:** 현재 폴더 옆 **원격**에서 URL을 관리하고 브랜치를 동기화합니다. Pull·push는 실제 대상 확인 후 실행하며 clone은 시작 화면과 앱 메뉴에서 엽니다. 인증은 기존 SSH agent·기본 키·known-host 파일 또는 HTTPS용 Apple Git 키체인 helper를 사용합니다. 제공자 로그인·SSH 별칭·임의 helper는 포함하지 않습니다. 자세한 범위는 [원격 가이드](docs/remotes.md)를 확인하세요.
- **검증과 보고 구분:** **공백 · 충돌 마커 검사**는 추적 파일과 스테이징의 `git diff --check`, Git 충돌·진행 상태를 검사합니다. 빌드·테스트 결과가 아니며 추적되지 않은 새 파일·서브모듈 내용은 검사 범위 밖입니다.

추가 화면 단축키: `⌘⌥1`–`⌘⌥6` 패널 표시 전환 · `⌘⌥Z` 화면 구성 되돌리기 · `⌃⌘↩` Diff 확대/원래 배치. 코드 글자(11–20 pt)와 코드·파일 목록 간격은 저장 배치와 별도로 유지됩니다.

`⌘O` 저장소 열기 · `⌘N` 새 작업 · `⌘R` 갱신 · `⌘⌥I` 커밋 패널 표시 전환 · `⌘↩` 활성 커밋 패널에서 커밋 · `⌘⌥L` 화면 구성.

설정·최근 프로젝트·작업 기록(journal)은 `~/Library/Application Support/AgentGitWorkbench`에 저장합니다. 최근 메뉴는 최대 30개이며 기존 작업공간 등록은 별도로 찾습니다. 이 복원은 정상적으로 읽을 수 있는 등록을 기준으로 합니다.

## 현재 제한

- **지원 전:** 제공자 OAuth·PR API, 강제 push, 브랜치 checkout·이름 변경·삭제(생성은 Task 준비로만 가능), 변경 되돌리기(discard), merge·rebase·충돌 해결 UI, history rewriting, 임의 행 스테이징, Stash 적용·삭제, 자동 AI 실행·CI·빌드·병합, Windows/Linux GUI.
- **원격 범위:** SSH/HTTPS를 지원합니다. 사용자 SSH 설정·대화형 인증·임의 credential helper·파일 경로 원격·URL 재작성·복수 endpoint·partial clone은 지원하지 않습니다. Pull은 깨끗한 폴더에서 빨리 감기로만 실행하며 분기된 이력은 거부합니다. [정확한 정책과 복구 동작](docs/remotes.md)을 확인하세요.
- **Git 실행 정책:** fsmonitor·hook·외부 서명 프로그램을 실행하지 않습니다. 앱에서 만든 커밋에는 Git hook이 적용되지 않으며 서명도 하지 않습니다(`commit.gpgsign=true`인 경우 포함). 외부 clean/smudge/process 명령이 설정되면 상태·Diff 조회와 작업 준비·쓰기가 거부됩니다. 해당 저장소가 LFS를 쓰지 않아도 전역 LFS 필터 명령이 있으면 같은 제한을 받습니다. 저장소 안에서 `git config --show-origin --get-regexp '^filter\..*\.(clean|smudge|process)$'`로 값이 있는 항목을 확인할 수 있습니다.
- **준비와 쓰기:** 원래 checkout을 바꾸지 않고 작업용 폴더를 준비합니다. source snapshot이나 신뢰 기준이 바뀌면 중단하며, 조용히 재계획하거나 reset/clean으로 복구하지 않습니다. Recipe는 OS 보안 sandbox가 아닙니다.
- **표시와 자원:** 그래프·브랜치 기록은 최근 최대 80개 커밋, Diff 표시는 5,000줄·512 KiB로 제한합니다. 대형 저장소의 속도·메모리·에너지는 아직 계측하지 않았습니다.
- **복구와 새로고침:** 준비 요청의 응답을 잃으면 앱 세션에 원래 프로젝트 안내가 남습니다. 작업을 반복하기 전에 해당 프로젝트의 작업 목록과 Git 상태를 확인해야 하며, 안내는 앱 재시작 뒤 복원되지 않습니다. Git 속성·Diff 설정을 바꾼 뒤에는 새로고침하세요. 이미 엔진에서 시작한 읽기는 클라이언트가 취소해도 계속될 수 있습니다.
- **배포와 검증:** 현재 사전 릴리스 DMG는 Apple Silicon용입니다. 서명·notarization 상태는 [릴리스 정보](docs/releases/v0.1.0-alpha.7.md)를 확인하세요. Intel 빌드, macOS 14–26 실행, OS 입력 및 VoiceOver 검증은 완료하지 않았습니다.

자세한 범위와 알려진 문제는 [현재 제한](docs/limitations.md)을 확인하세요.

## 개발과 검증

### 소스에서 빌드하기

필요한 도구는 macOS, Swift 6 이상을 포함한 Xcode, Rust/Cargo, Git, Python 3입니다. 검증에는 전체 Xcode를 사용했으며 Command Line Tools만 설치한 빌드 환경은 검증하지 않았습니다. Rust 코드는 edition 2024를 사용합니다.

검증 환경은 macOS 27.0.1 / Swift 6.4 / Rust 1.97.1 / Git 2.54.0 / Python 3.9.6입니다. 이 목록은 테스트한 버전이며 전체 최소 버전 호환성 표는 아닙니다.

```sh
git clone https://github.com/ictechgy/river.git
cd river
python3 scripts/build_macos.py
open "build/macos/River.app"
```

빌드 스크립트가 Rust 엔진과 Swift 앱을 함께 빌드해 개발용 ad-hoc 서명으로 묶습니다. Node·npm·웹 서버는 필요 없습니다. 배포 패키징과 서명 옵션은 [개발 가이드](docs/development.md)를 확인하세요.

### 검증

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path apps/macos
```

2026-10-25 개발자 로컬 실행에서 **Swift 190개 테스트**를 통과했습니다. 변경하지 않은 Python·Rust 소스는 alpha.6의 **Python 56개**, alpha.5의 **Rust 119개** 테스트 검증을 유지합니다. 합성 CLI·네이티브 통신 시나리오와 공개 GitHub·GitLab 읽기 전용 clone·fetch 검사도 통과했습니다. CI는 아직 없으며 실제 사용자 저장소나 대형 저장소 성능을 검증한 수치도 아닙니다.

- [개발 환경·검증 명령](docs/development.md)
- [구조와 실행 경계](docs/architecture.md)
- [CLI·workspace·recipe 예제](docs/cli.md)
- [현재 제한과 알려진 문제](docs/limitations.md)
- [디자인 원칙](DESIGN.md)과 [River Clear 구성 규칙](docs/design/river-clear.md)

라이선스는 아직 정하지 않았습니다. 현재 Cargo 메타데이터는 `UNLICENSED`입니다.

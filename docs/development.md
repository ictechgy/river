# 개발과 검증

macOS 네이티브 앱은 `apps/macos`, 공통 Rust 엔진은 `crates`에 있습니다. SwiftPM의 최소 도구 버전은 6.0, Rust edition은 2024입니다. 검증한 버전은 루트 [README](../README.md)에 적었습니다.

## 빌드

```sh
python3 scripts/build_macos.py
open "build/macos/River.app"
```

기본값은 debug 빌드와 ad-hoc 개발용 서명입니다. 버전과 build 번호를 지정한 로컬 release 빌드는 아래와 같습니다. 앱 빌드만으로 DMG 생성·notarization·배포 업로드를 수행하지 않습니다.

```sh
python3 scripts/build_macos.py --configuration release --version 0.1.0-alpha.10 --build-number 11
```

`--output`으로 앱 번들의 출력 경로를 지정할 수 있습니다. `--sign-identity`를 생략하면 ad-hoc 서명을 사용합니다. 버전 `0.1.0-alpha.10`은 앱의 `RiverReleaseVersion`, 숫자 부분 `0.1.0`은 `CFBundleShortVersionString`, build 번호 `11`는 `CFBundleVersion`에 기록합니다.

## DMG 패키징과 배포

일반 설치 방법은 [README](../README.md#install-on-macos), 현재 공개 아티팩트의 상태는 [0.1.0-alpha.10 릴리스 정보](releases/v0.1.0-alpha.10.md)에 있습니다. 개발자가 로컬에서 만드는 ad-hoc 빌드와 공개 릴리스의 서명·notarization 상태는 별도로 확인하세요.

패키징 스크립트는 별도의 release 빌드를 만들고 앱과 내장 엔진의 architecture가 같은지 확인합니다. 새 빌드는 커밋한 깨끗한 소스에서 실행해야 합니다. 추적 파일의 변경, 런타임 소스 폴더와 `.cargo`의 미추적 파일, 빌드 중 소스 변경이 있으면 중단합니다. 같은 출력 폴더의 동시 패키징은 잠금으로 거부합니다. `--version`과 `--build-number`는 패키징할 때 매번 지정해야 합니다. 기본 출력 위치는 `dist/`입니다. Cargo가 이번 빌드에서 보고한 실행 파일을 내장하므로 target 폴더·target triple 설정을 따르며, release 빌드는 `--locked`로 의존성 잠금을 유지합니다. manifest의 소스 provenance는 저장소 커밋과 소스 변경 여부를 기록하며, 설치한 컴파일러·사용자 전역 Cargo 설정까지 재현성을 보증하지 않습니다. Cargo workspace 버전은 내부 crate 버전이고 배포 앱의 버전·build 번호는 명시한 plist 값으로 별도 관리합니다.

전체 추적 파일 중 `assume-unchanged` 또는 `skip-worktree`가 설정된 경로가 있으면 파일 내용이 HEAD와 같아도 패키징을 중단합니다. 이 플래그는 `git status`와 `git diff`에서 실제 파일 변경을 숨길 수 있으므로 빌드 전과 빌드 후 모두 확인합니다. 오류가 나면 `git ls-files -v`로 확인하세요. 경로 앞의 소문자 표시는 `assume-unchanged`, `S` 또는 `s`는 `skip-worktree`를 뜻합니다. 해당 파일의 로컬 내용을 먼저 검토하고 보관한 뒤 플래그를 해제할지, 별도의 깨끗한 checkout에서 릴리스를 만들지 결정하세요. 패키징 스크립트는 파일 내용이나 index 플래그를 바꾸지 않으며 Git의 선택적 index 갱신도 수행하지 않습니다.

```sh
python3 scripts/package_macos.py --version 0.1.0-alpha.10 --build-number 11
```

Apple Silicon 호스트에서의 출력은 다음과 같습니다. x86_64나 universal2는 실제 앱·엔진 바이너리가 해당 architecture일 때만 그 이름으로 표시하며, 현재 공개 릴리스는 arm64만 제공합니다.

```text
dist/River-0.1.0-alpha.10-macos-arm64.dmg
dist/River-0.1.0-alpha.10-macos-arm64.dmg.sha256
dist/River-0.1.0-alpha.10-macos-arm64.manifest.json
```

DMG에는 `River.app`과 `Applications` 링크가 들어 있습니다. `--output-dir`로 출력 폴더를 바꿀 수 있습니다. 이미 빌드한 release 앱은 `--app /absolute/path/River.app`으로 지정할 수 있지만 요청 버전·build 번호가 일치해야 하며, 이 옵션은 앱을 다시 서명하거나 그 앱의 소스 커밋을 보증하지 않습니다. 이때 `--sign-identity`를 함께 지정하면 같은 개발 팀의 인증서로 DMG만 서명합니다.

Developer ID로 서명하려면 로컬 키체인의 인증서 이름을 지정합니다. 아래 이름과 프로필은 자신의 환경 값으로 바꾸세요.

```sh
python3 scripts/package_macos.py \
  --version 0.1.0-alpha.10 --build-number 11 \
  --sign-identity "Developer ID Application: YOUR NAME (TEAMID)"
```

Apple notarization을 수행할 수 있는 환경에서는 `--notary-profile river-notary`를 추가합니다. `river-notary`는 `notarytool`에 미리 저장한 로컬 키체인 프로필 이름입니다. 이 옵션은 Developer ID 서명이 필요하며 Apple 제출·승인 확인과 ticket 부착을 수행합니다. 프로필을 생략한 DMG를 notarized로 표기하면 안 됩니다. notarization을 요청했는데 실패한 경우에도 릴리스가 성공한 것으로 간주하지 않습니다.

DMG를 공개하기 전에는 만들어진 파일 자체를 검증합니다. 이 명령은 이미지를 검사하고 읽기 전용으로 마운트한 뒤 앱을 복사해 서명을 확인합니다.

```sh
python3 scripts/package_macos.py --verify-dmg dist/River-0.1.0-alpha.10-macos-arm64.dmg
cd dist
shasum -a 256 -c River-0.1.0-alpha.10-macos-arm64.dmg.sha256
```

실제 Finder에서도 DMG를 열고 앱을 Applications로 복사한 다음 이미지를 추출하고 실행하세요. 공개 릴리스에는 DMG·SHA-256 파일·manifest를 함께 첨부하고, 실제 확인한 architecture·서명·notarization·실행 환경을 릴리스 정보에 기록합니다. 빌드·패키징 스크립트는 GitHub 업로드를 수행하지 않습니다.

## 단위·통합 테스트

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path apps/macos
python3 scripts/test_ios_adapter.py
python3 scripts/test_git_execution.py
python3 scripts/test_package_macos.py
```

Rust 테스트는 원래 폴더·index 보존, 고정 계획·recipe 신뢰, 부분 실패·취소·재개, journal/idempotency, hunk stage·commit 등을 합성 fixture로 검사합니다. Swift 테스트는 소켓·스키마, 초안·Task 문맥, 늦은 응답·조회 실패, 분할·도킹·검토 상태를 검사합니다. 검증 결과는 해당 소스 버전에만 적용합니다.

## 실제 프로세스 경계 검증

Python harness는 CLI 바이너리와 Swift probe/renderer를 사용합니다. 깨끗한 checkout에서는 먼저 모두 빌드하세요.

```sh
cargo build --workspace
swift build --package-path apps/macos
python3 scripts/build_macos.py
python3 scripts/smoke.py
python3 scripts/native_smoke.py
python3 scripts/remote_smoke.py
python3 scripts/startup_smoke.py
# 별도로 만든 배포 앱의 엔진을 검사할 때:
python3 scripts/startup_smoke.py --app /absolute/path/River.app
```

- `smoke.py`: 실제 Unix 소켓 요청으로 branch-only → materialize → 부분 실패 → 재개를 실행하고 Git 결과를 교차 확인합니다.
- `native_smoke.py`: 제품과 같은 Swift 클라이언트로 Rust 엔진을 호출해 준비·부분 스테이징·커밋·Stash·브랜치 조회를 검사합니다.
- `remote_smoke.py`: 실제 CLI·소켓으로 원격 URL 관리·stale 상태·endpoint 변경·안전하지 않은 URL·대상 보존을 검사합니다. 선택적 `--public-url https://host/group/project.git`는 임시 폴더에서 해당 공개 저장소를 clone·fetch하며 서버로 push하지 않습니다.
- `startup_smoke.py`: 패키징한 helper의 위치 이동, 연결 환경 변수 없는 시작, 재시작·다른 인스턴스·예제 재사용을 검사합니다.

새 임시 저장소만 사용하며 결과를 독립 Git 명령으로 확인합니다. 이 harness는 기존 사용자 앱을 조작하는 마우스·키보드 E2E나 성능 벤치마크가 아닙니다. 일부 fixture는 실행 후 `/tmp`에 남습니다.

## 실제 네이티브 화면 렌더

위 프로세스 경계 검증의 Rust·Swift 빌드를 마친 뒤 실행합니다.

```sh
python3 scripts/native_preview.py /tmp/workbench-light.png --appearance light --layout focus --scene review
python3 scripts/native_preview.py /tmp/workbench-dark.png --appearance dark --layout balanced --scene partial --stashes
python3 scripts/native_preview.py /tmp/workbench-branches.png --appearance light --width 1100 --height 800 --scene waiting --branches --dock-scene branches
```

실제 Rust 서비스와 새 합성 Git 상태에 연결한 SwiftUI/AppKit content view입니다. PNG와 같은 이름의 JSON에 사용한 fixture와 상태를 기록합니다. 데스크톱 전체 캡처나 OS 입력·접근성 검증으로 해석하지 않습니다.

`--layout focus`는 파일·Diff의 2열 집중 배치, `--layout balanced`는 커밋·Stash·작업 정보 탭을 더한 3열 균형 배치를 사용합니다. `--appearance`는 배치와 독립적으로 적용합니다. 미리보기는 격리된 설정을 사용하므로 사용자가 저장한 앱 배치를 바꾸지 않습니다. 실제 앱에서는 **화면 구성**에서 배치와 색상을 각각 선택하며, 기존 저장 배치는 새 기본값으로 덮어쓰지 않습니다.

## 소스 안내

```text
apps/macos/             SwiftUI/AppKit 앱, 런타임, IPC 클라이언트와 테스트
crates/domain/          Task·계획·operation·공개 계약
crates/git-adapter/     Git argv, 출력 파싱, snapshot·읽기/쓰기 경계
crates/recipe-runner/   고정 recipe 실행·범위 검사
crates/operation-service/ SQLite journal, 잠금, 준비·조회·mutation, Unix IPC
crates/cli/             fixture·workspace·trust·serve·rpc·schema 명령
adapters/ios-version/   합성 xcconfig 고정값 adapter
schemas/               Rust 타입에서 생성한 공개 JSON Schema
scripts/               빌드와 합성 검증 harness
```

작업 조건의 안정 ID·보고 메타데이터·검증 문서는 [작업 흐름 안내](task-workflow.md)를 따릅니다. v1 영속 JSON은 그대로 두고 별도 테이블과 v2 RPC로 확장하며, `schemas/task-workflow.json`과 `schemas/verification-guide.json`도 Rust 타입에서 내보냅니다.

스키마 재생성:

```sh
cargo run -p workbench-cli -- schemas schemas
```

수정할 때는 화면의 성공 표시만 보지 말고 Git HEAD·index·파일·worktree 상태를 확인하세요. 준비 변경과 staging·commit은 별도 동작으로 유지하고, 불명확한 쓰기 결과를 자동 반복하지 않습니다.

## Signed app updates

Sparkle 2.10.0 is pinned in `apps/macos/Package.resolved`. Release builds embed and sign the complete framework and preserve its license. Follow [the update release procedure](updates.md) after publishing the immutable DMG; the signed feed uses a separate `updates` branch and does not change the application source commit.

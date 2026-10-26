# CLI·workspace·recipe 예제

일반 앱 사용에는 이 설정이 필요 없습니다. 엔진 API를 살펴보거나 새 workspace 구성을 개발할 때 사용하는 예제입니다.

## 합성 workspace 실행

새 임시 디렉터리를 만들고 CLI를 빌드합니다. 예제는 새 합성 저장소 두 개를 생성하며 실제 사용자 프로젝트를 입력으로 받지 않습니다.

```sh
cargo build --workspace
AGW_DEMO_ROOT="$(mktemp -d /tmp/agw-demo.XXXXXX)"
target/debug/workbench fixture "$AGW_DEMO_ROOT/fixture"
target/debug/workbench trust "$AGW_DEMO_ROOT/fixture/workspace.json" api.set-version@1
target/debug/workbench trust "$AGW_DEMO_ROOT/fixture/workspace.json" ios-app.set-version@1
mkdir -m 700 "$AGW_DEMO_ROOT/state"
printf 'Socket path: %s\n' "$AGW_DEMO_ROOT/state/service.sock"
target/debug/workbench serve "$AGW_DEMO_ROOT/fixture/workspace.json" "$AGW_DEMO_ROOT/state/journal.sqlite" "$AGW_DEMO_ROOT/state/service.sock"
```

`serve`는 포그라운드에서 실행됩니다. 다음 요청은 다른 터미널에서 클론한 프로젝트 디렉터리(`target/debug/workbench`가 있는 위치)로 이동한 뒤 실행하세요. 합성 fixture 저장소 안에서 실행하는 것이 아닙니다. `AGW_SOCKET`은 첫 터미널에 출력된 **실제 경로로 바꿉니다**. 아래 `ABC123`은 예시입니다.

```sh
AGW_SOCKET="/tmp/agw-demo.ABC123/state/service.sock"
echo '{"method":"list_workspaces"}' | target/debug/workbench rpc "$AGW_SOCKET"
echo '{"method":"plan_task","params":{"group_id":"ios-2-4","label":"로그인 개선","task_slug":"login","mode":"branch_only"}}' | target/debug/workbench rpc "$AGW_SOCKET"
```

`plan_task`는 계획을 반환합니다. `branch_only`는 실행해도 ref만 만들고 작업용 폴더는 준비 대기로 둡니다. 처음부터 준비하려면 `mode`를 `materialize`로 지정합니다. 반환된 plan ID를 넣어 아래 JSON을 `rpc`의 표준 입력으로 전달합니다.

```json
{"method":"execute_plan","params":{"plan_id":"RETURNED_PLAN_ID","idempotency_key":"login-request-1"}}
{"method":"get_operation","params":{"op_id":"RETURNED_OPERATION_ID"}}
{"method":"materialize","params":{"op_id":"RETURNED_OPERATION_ID"}}
{"method":"retry_operation","params":{"op_id":"RETURNED_OPERATION_ID"}}
```

각 줄은 별도 요청입니다. 첫 실행은 아래처럼 전달합니다. `PLAN_ID`를 `plan_task` 응답의 `result.id`로 바꾸세요.

```sh
PLAN_ID="RETURNED_PLAN_ID"
printf '{"method":"execute_plan","params":{"plan_id":"%s","idempotency_key":"login-request-1"}}' "$PLAN_ID" \
  | target/debug/workbench rpc "$AGW_SOCKET"
```

`execute_plan`은 operation을 즉시 반환하며 응답의 `result.id`가 이후 요청의 `RETURNED_OPERATION_ID`입니다. 준비 결과는 `get_operation`으로 조회합니다. 계획은 15분간 유효하며 실행 시 source snapshot과 신뢰 기준을 재검증합니다. 같은 key·같은 plan은 같은 operation이고, 같은 key·다른 plan은 `idempotency_conflict`입니다. 결과가 불명확하면 `get_operation_by_key`로 먼저 확인하며 쓰기를 자동 반복하지 않습니다.

## 조회와 쓰기 경계

`get_repo_status`·`get_diff`·Git 위생 검사는 격리된 속성 조회를 위해 Apple Git 2.43 이상이 필요합니다. 지원하지 않는 버전은 `content_read_git_upgrade_required`, 지원 범위를 벗어난 설정·속성 구성은 `unsupported_content_read`로 중단합니다.

- `get_repo_status`: `repo_id`. Task 작업용 폴더라면 `op_id`도 지정합니다.
- `get_diff`: `repo_id`, `path`, 선택적으로 `staged`(기본 `false`)와 `op_id`.
- `list_branches`: `repo_id`, 선택적으로 `op_id`. `get_branch_history`는 `repo_id`, `branch_ref`(목록의 `full_ref`), `tip_oid`로 대상을 고정합니다.
- `list_stashes`: `repo_id`. `get_stash`: `repo_id`, `stash_oid`. `get_stash_diff`: `repo_id`, `stash_oid`, `path`. 저장소 공통 Stash를 OID로 고정해 읽습니다.
- `stage_hunk`: `repo_id`, `path`, `hunk_index`, `snapshot_hash`, `diff_hash`, 선택적으로 `staged`(기본 `false`)와 `op_id`. `diff_hash`는 현재 `get_diff` 응답의 `text`를 UTF-8로 인코딩한 bytes의 SHA-256입니다. 응답 기준을 그대로 사용하며 임의 patch를 받지 않습니다.
- `stage_file`: `repo_id`, `path`, `snapshot_hash`, 선택적으로 `staged`(기본 `false`)와 `op_id`. `false`는 선택한 파일 전체를 포함하고, `true`는 해당 파일 전체를 index에서 HEAD 상태로 돌립니다. 작업 파일·HEAD는 바꾸지 않습니다. HEAD에 없던 추가 파일은 index에서만 제거하며 초기 커밋 전에도 취소할 수 있습니다. 일반 파일 전체 스테이징에는 Apple Git 2.42 이상이 필요합니다. 새 엔진의 `get_repo_status.file_staging_version: 1`을 확인한 뒤 사용합니다. 전체 파일 목록을 받는 API가 아닙니다.
- `commit`: `repo_id`, `snapshot_hash`, `message`, 선택적으로 `op_id`. Task 쓰기 전 Ready 상태와 Git 대상을 다시 확인합니다. `snapshot_hash`는 같은 대상의 최신 `get_repo_status` 응답에서 얻습니다.
- `events`: `cursor`(기본 0) 뒤의 이벤트를 읽습니다. `latest: true`는 초기 화면용 최근 tail 조회입니다.

`stage_file`·`stage_hunk`·`commit`은 서비스 안에서 다른 쓰기가 진행 중이면 `repository_busy`로 즉시 거부합니다.

선택적인 `op_id`·`context_op_id`는 생략하거나 `null`로 지정할 수 있습니다. 지정한 ID는 공백만으로 이루어지지 않은 문자열이어야 하며, 다른 자료형이나 빈 ID는 `invalid_parameter`로 거부합니다. `get_diff`·`stage_file`·`stage_hunk`의 `staged`는 생략하면 `false`이며, 지정할 때는 JSON boolean이어야 합니다(`null`도 거부).

`stage_file`·`stage_hunk`·`commit`과 Task context 요청은 정의되지 않은 필드를 거부합니다. 예를 들어 `op_id`를 `opid`로 잘못 입력한 쓰기 요청이 원본 저장소에 적용되지 않습니다.

CLI는 성공 시 0, 명령 실패 시 1(오류 JSON은 stderr)로 끝납니다. `rpc`가 서비스 오류 응답을 받으면 2입니다. Unix 소켓은 짧은 사용자 소유 전용 경로에 두세요. 앱은 이 경로를 자동으로 관리합니다.

## 작업 조건·보고·검증 문서

새 Task context 응답의 `workflow_version: 2`는 확장 기능 지원 표시입니다. `get_task_workflow`로 현재 조건 ID·개정·보고 연결을 읽고, `save_task_workflow`로 목적·조건·참고·검증 문서 목록을 저장합니다. 저장에는 조회한 `expected_context_revision`과 `expected_workflow_revision`이 모두 필요합니다.

`record_workflow_report`는 선택한 `criterion_ids`, `claimed_reviewed_state`, `provider`, `model`, `artifacts`, `report_status`를 기록합니다. 기록 시 관찰한 코드와 보고자가 검토했다고 밝힌 코드를 구분하며, 완료 조건 충족을 판정하지 않습니다. `read_verification_guide`는 선택한 저장소·폴더의 등록 문서 하나를 명시적으로 읽습니다. 호출 필드와 응답 타입은 [Task workflow 스키마](../schemas/task-workflow.json), [문서 읽기 스키마](../schemas/verification-guide.json) 및 [사용 안내](task-workflow.md)를 참고하세요. 전송 envelope의 버전은 계속 1입니다.

확장 기록 생성 후 구형 `save_task_context`는 거부합니다. 구형 엔진이 기존 기록을 변경한 경우 `legacy_changed`로 표시하며 자동으로 조건을 재연결하지 않습니다. 두 개정 번호를 확인한 명시적 `reset_task_workflow`만 현재 텍스트로 새 ID를 만들고 과거 이력을 보존합니다.

## 구성 파일

`fixture`가 만든 `workspace.json`과 [공개 스키마](../schemas/workspace.json)를 함께 읽으면 저장소·그룹·recipe 구성을 확인할 수 있습니다. 실제 저장소의 초기 등록은 아래 명령을 사용하며 JSON을 지정한 새 경로에 작성합니다.

```sh
target/debug/workbench inspect /absolute/path/to/repository
target/debug/workbench workspace /absolute/path/to/repository /new/private/path/workspace.json
```

경로는 사용 환경에 맞게 바꿔야 합니다. `workspace`는 recipe가 없는 단일 저장소 설정을 만듭니다. 등록만으로 원래 checkout·HEAD·index를 바꾸지 않습니다. 작업을 실행하면 원래 저장소에 `feature/<task_slug>` 브랜치 ref가 생깁니다. `materialize`는 설정 파일 옆 `worktrees/` 아래에 작업용 폴더를 만들고, `branch_only`는 ref만 만든 뒤 폴더를 준비 대기로 둡니다.

다중 저장소·recipe가 필요하면 공개 스키마와 fixture를 기준으로 첫 `serve` 전에 설정을 작성하세요. 설정·계약·실행 파일·script hash를 검토한 뒤 명시적으로 `trust`하고, journal과 함께 보존하세요. 현재 실행 중인 workspace 설정을 임의로 교체하면 config hash 불일치로 기존 journal을 열지 못할 수 있습니다.

위 `ios-2-4` 그룹은 합성 fixture의 값입니다. `workspace`로 등록한 단일 저장소의 기본 그룹은 `개발`입니다.

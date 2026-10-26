import Foundation
import Darwin
import WorkbenchProtocol
import WorkbenchRuntime

enum UserFacingFailure {
  static func message(_ error: any Error) -> String {
    if let error = error as? UIError { return error.localizedDescription }
    if let startup = error as? StartupFailure { return startup.localizedDescription }
    if let transport = error as? TransportFailure {
      switch transport {
      case .oversizedReply: return "표시할 변경 내용이 너무 큽니다. 파일을 나누어 검토하거나 Git에서 확인해 주세요."
      case .unsupportedSchema: return "앱과 작업 엔진의 버전이 맞지 않습니다. 업데이트한 앱을 다시 열어 주세요."
      case .system(let action, let code) where code == ETIMEDOUT
        || (code == EAGAIN && ["수신", "전송"].contains(action)):
        return "작업 엔진의 응답이 지연되었습니다. 현재 변경 상태를 새로고침한 뒤 다시 시도해 주세요."
      case .oversizedRequest: return "입력 내용이 요청 크기 제한을 넘었습니다. 내용을 줄여 다시 시도해 주세요."
      case .invalidReply: return "작업 엔진의 응답을 읽지 못했습니다. 현재 변경 상태를 새로고침해 주세요."
      default: return "작업 엔진에 연결하지 못했습니다. ‘다시 연결’을 눌러 작업을 이어가세요."
      }
    }
    if let service = error as? ServiceFailure {
      switch service.code {
      case "stale_remote_state": return "폴더나 원격 정보가 바뀌었습니다. 원격 정보를 새로 읽고 다시 확인해 주세요."
      case "invalid_remote_url", "unsupported_remote_transport": return "SSH 또는 HTTPS 저장소 URL을 입력해 주세요. URL에 비밀번호나 토큰을 넣지 마세요."
      case "invalid_remote_name": return "원격 이름에는 영문·숫자·하이픈·밑줄을 사용해 주세요."
      case "invalid_remote_branch", "remote_branch_required": return "현재 로컬 브랜치와 보낼 원격 브랜치 이름을 확인해 주세요."
      case "unsupported_git_version": return "원격 기능에는 Apple Git 2.41 이상이 필요합니다. Xcode 또는 Command Line Tools를 업데이트해 주세요."
      case "unsupported_alternate_command": return "외부 Git 명령 설정이 있어 원격 연결을 중단했습니다. Git 설정의 core.alternateRefsCommand를 확인해 주세요."
      case "invalid_remote_fetch_result": return "받아 온 브랜치 정보를 안전하게 확인하지 못했습니다. Git 버전과 원격 상태를 확인한 뒤 새로고침해 주세요."
      case "remote_branch_missing": return "원격 저장소에 해당 브랜치가 없습니다. Fetch 후 대상 브랜치를 다시 선택해 주세요."
      case "remote_worktree_dirty": return "현재 폴더의 변경을 커밋하거나 정리한 뒤 Pull해 주세요."
      case "remote_pull_blocked": return "Git 작업이 진행 중이거나 작업 폴더 상태를 안전하게 확인하지 못해 Pull하지 않았습니다. 현재 변경과 충돌·진행 중 Git 작업을 확인하고 정리한 뒤 새로고침해 주세요."
      case "remote_pull_not_fast_forward": return "로컬과 원격 이력이 갈라져 있어 Pull하지 않았습니다. 별도로 병합하거나 rebase한 뒤 다시 확인해 주세요."
      case "remote_push_rejected": return "서버가 Push를 거절했습니다. 원격의 새 커밋이나 브랜치 보호 규칙을 확인해 주세요."
      case "remote_connection_failed": return "원격 서버에 연결하지 못했습니다. URL·권한과 SSH 키·서버 신뢰 또는 macOS Git Keychain 인증을 확인해 주세요."
      case "remote_not_found", "remote_name_conflict": return "원격 이름이 없거나 이미 사용 중입니다. 원격 정보를 새로 읽고 이름을 확인해 주세요."
      case "remote_not_local": return "이 원격은 프로젝트 밖의 Git 설정에 등록되어 있습니다. 해당 설정에서 수정해 주세요."
      case "remote_outcome_unknown": return UIError.remoteOutcomeUnknown.localizedDescription
      case "unsupported_remote_config", "unsupported_remote_command", "unsupported_remote_endpoints", "unsupported_url_rewrite", "unsupported_partial_clone", "unsupported_http_config", "unsupported_http_configuration", "unsupported_repository_format": return "현재 Git 연결 설정을 지원하지 않습니다. 원격 URL·URL 재작성·전송 명령·HTTP 설정을 확인해 주세요. 사용자 지정 SSH 설정은 지원하지 않습니다."
      case "unsupported_external_filter": return "Git 외부 필터가 등록되어 있습니다. 현재 버전은 실제 사용 여부와 관계없이 전역 설정을 포함한 외부 필터 환경을 지원하지 않습니다."
      case "content_read_git_upgrade_required": return "변경 내용을 안전하게 조회하려면 Apple Git 2.43 이상이 필요합니다. Xcode 또는 Command Line Tools를 업데이트한 뒤 다시 열어 주세요."
      case "unsupported_content_read": return "이 저장소의 Git 설정이나 속성 구성을 현재 지원하지 않아 변경 내용을 읽지 못했습니다. 오류 상세 내용과 Git에서 실제 변경 상태를 확인해 주세요."
      case "file_staging_git_upgrade_required": return "일반 파일 전체 스테이징에는 Apple Git 2.42 이상이 필요합니다. Xcode 또는 Command Line Tools를 업데이트해 주세요."
      case "unsupported_file_conversion": return "이 파일의 Git 속성이나 변환 설정을 안전하게 처리할 수 없어 스테이징하지 않았습니다. .gitattributes와 전역·저장소 속성 설정을 Git에서 확인해 주세요."
      case "unsafe_task_worktree", "wrong_task_branch": return "작업 폴더의 위치나 브랜치가 바뀌었습니다. 원래 폴더와 브랜치를 복구한 뒤 새로고침해 주세요."
      case "unsafe_source_repository": return "원래 저장소의 Git 위치 설정이 바뀌었습니다. 저장소 설정을 확인하고 다시 열어 주세요."
      case "git_unavailable": return "Git을 실행하지 못했습니다. macOS의 Command Line Tools 또는 Xcode 설치 상태를 확인해 주세요."
      case "unknown_method": return "앱과 작업 엔진의 기능 버전이 맞지 않습니다. 앱을 완전히 종료한 뒤 업데이트한 앱을 다시 열어 주세요."
      case "unsafe_repository_lock": return "저장소의 작업 잠금 파일이 일반 파일이 아니거나 안전하지 않습니다. Git 폴더의 workbench.operation.lock을 확인해 주세요."
      case "invalid_label": return "작업 이름은 줄바꿈 없이 200바이트 이내로 입력해 주세요."
      case "unsupported_hunk_change": return "이 변경은 앱에서 부분 스테이징할 수 없습니다. Git에서 파일 종류와 전체 변경을 확인해 주세요."
      case "invalid_file_stage_path", "file_not_changed_on_requested_side": return "선택한 파일의 변경 상태가 바뀌었습니다. 새로고침한 뒤 해당 목록에서 파일을 다시 선택해 주세요."
      case "file_stage_too_large": return "32 MiB를 넘는 파일은 앱에서 스테이징할 수 없습니다. Git에서 파일을 확인하고 추가해 주세요."
      case "journal_configuration_mismatch": return "저장한 작업 기록과 저장소 구성이 맞지 않습니다. 기존 기록을 다른 설정으로 열 수 없습니다."
      case "stale_source_snapshot": return "계획을 만든 뒤 원래 프로젝트 폴더가 바뀌었습니다. 현재 변경은 유지됩니다. 현재 상태를 기준으로 새 작업을 만들어 주세요."
      case "unsupported_submodule_or_directory": return "이 저장소에는 아직 지원하지 않는 하위 저장소나 특수 파일이 있습니다. Git에서 해당 항목을 확인해 주세요."
      case "unsupported_nested_repository": return "프로젝트 안에 별도의 Git 저장소가 있습니다. 중첩 저장소나 에이전트 작업 폴더를 .gitignore에 추가하거나 프로젝트 밖으로 옮긴 뒤 다시 확인해 주세요."
      case "unsafe_relative_path", "symlink_parent": return "파일 경로를 안전하게 읽을 수 없습니다. 프로젝트 안의 중첩 저장소나 심볼릭 링크를 Git에서 확인해 주세요."
      case "result_too_large": return "표시할 변경 내용이 너무 큽니다. 파일을 나누어 검토하거나 Git에서 확인해 주세요."
      case "git_timeout": return "Git 조회가 오래 걸려 중단했습니다. 저장소와 디스크 상태를 확인한 뒤 다시 시도해 주세요."
      case "git_write_outcome_unknown": return "Git 쓰기의 완료 여부를 확인하지 못했습니다. 같은 동작을 반복하기 전에 새로고침과 Git 기록을 확인해 주세요. 잠금 파일은 실행 중인 Git 작업이 없는지 확인한 뒤 처리하세요."
      case "git_failed" where service.message.contains("index.lock"): return "Git 잠금 파일이 있어 쓰기를 완료하지 못했습니다. 다른 Git 작업이 실행 중인지 먼저 확인해 주세요."
      case "git_failed" where service.message.contains("Author identity unknown") || service.message.contains("unable to auto-detect email"): return "커밋 작성자 이름과 이메일이 설정되지 않았습니다. Git의 user.name과 user.email을 설정한 뒤 다시 커밋해 주세요."
      case "invalid_slug": return "브랜치 이름에는 영문·숫자·하이픈을 사용해 주세요. 64자 이내이며 하이픈으로 시작할 수 없습니다."
      case "unsupported_encoding", "unsupported_filename_encoding": return "이 항목의 문자 인코딩을 읽을 수 없습니다. Git에서 원본 인코딩을 확인해 주세요."
      case "branch_collision": return "같은 이름의 브랜치가 이미 있습니다. 다른 작업 이름으로 새 계획을 만들어 주세요."
      case "worktree_collision": return "작업 폴더가 이미 있습니다. 기존 폴더를 확인하고 다른 브랜치 이름으로 새 계획을 만들어 주세요."
      case "stale_plan": return "실행 계획의 유효 시간이 지났습니다. 현재 상태로 계획을 다시 확인해 주세요."
      case "untrusted_recipe": return "준비 스크립트가 아직 신뢰 등록되지 않았습니다. 스크립트와 실행 프로그램을 확인하고 등록한 뒤 다시 계획해 주세요."
      case "service_stopping": return "작업 엔진을 종료하고 있습니다. 잠시 후 저장소를 다시 열어 주세요."
      case "unexpected_changes": return "준비 스크립트가 허용한 범위 밖의 파일을 바꿨습니다. 변경을 확인한 뒤 복구 여부를 결정해 주세요."
      case "recipe_failed", "recipe_timeout": return "준비 스크립트를 완료하지 못했습니다. 작업 폴더의 변경과 준비 기록을 확인한 뒤 다시 시도해 주세요."
      case "stale_snapshot", "stale_read_snapshot": return "파일이 외부에서 변경되었습니다. 새로고침한 뒤 다시 시도해 주세요."
      case "stale_diff": return "변경 표시 기준이 바뀌었습니다. Diff를 다시 읽고 스테이징할 변경을 확인해 주세요."
      case "repo_locked", "repository_busy", "service_busy": return "다른 작업이 저장소를 사용 중입니다. 잠시 후 다시 시도해 주세요."
      case "preparation_queue_full": return "준비 작업이 가득 찼습니다. 진행 중인 작업이 끝나거나 취소가 완료된 뒤 다시 시도해 주세요."
      case "task_not_ready": return "이 저장소의 준비가 끝나지 않았습니다. 준비 결과를 확인하고 완료한 뒤 편집해 주세요."
      case "context_conflict": return "다른 화면에서 저장한 내용이 있습니다. 입력은 유지했습니다. 새로고침 후 저장본을 확인해 주세요."
      case "workflow_conflict": return "조건이나 검증 절차가 다른 화면에서 바뀌었습니다. 입력은 유지했습니다. 새로고침 후 저장본을 확인해 주세요."
      case "workflow_legacy_changed", "workflow_upgrade_required": return "이전 버전에서 변경한 작업 기록이 있습니다. 새 조건 연결 정보를 확인하고 현재 기록으로 다시 시작해 주세요."
      case "workflow_retired_or_foreign_id", "unknown_workflow_criterion": return "삭제되거나 다른 작업에 속한 조건입니다. 현재 조건을 다시 불러와 선택해 주세요."
      case "invalid_workflow_criteria", "invalid_workflow_id": return "완료 조건을 확인해 주세요. 비어 있지 않은 조건을 30개까지 저장할 수 있습니다."
      case "invalid_claimed_reviewed_state": return "검토했다고 보고할 HEAD는 40자 또는 64자, 변경 상태는 64자의 16진수 값으로 입력하세요. 모르면 비워 두세요."
      case "invalid_verification_metadata": return "보고자·모델·증거 참조를 확인해 주세요. 긴 로그는 핵심 내용과 참조 경로로 줄여 주세요."
      case "invalid_workflow_guides", "guide_scope_mismatch", "guide_repo_mismatch": return "검증 문서의 저장소·상대 경로·기준 SHA-256을 확인해 주세요. 문서는 10개까지 연결할 수 있습니다."
      case "guide_invalid_path", "guide_unsupported_format", "guide_too_large", "guide_unsafe_path", "guide_invalid_utf8", "guide_unreadable", "unknown_verification_guide": return "이 문서를 읽을 수 없습니다. 저장소 안의 일반 텍스트 문서인지, 상대 경로와 크기(64 KiB 이하)를 확인해 주세요."
      case "invalid_task_context": return "입력 범위를 확인해 주세요. 목적 2,000자, 완료 조건 30개·각 300자, 참고 10개, 남은 일 5,000자까지 저장할 수 있습니다."
      case "invalid_verification_report": return "결과와 근거를 입력해 주세요. 긴 로그나 명령 설명은 핵심 내용으로 줄여 다시 저장해 주세요."
      default: break
      }
    }
    return "작업을 완료하지 못했습니다. 변경 사항을 확인한 뒤 다시 시도해 주세요."
  }
}

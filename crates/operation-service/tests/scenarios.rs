use serde_json::{Value, json};
use std::{
    fs,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use workbench_domain::*;
use workbench_git as git;
use workbench_service::{Request, Service, fixtures, load_workspace};

// Concurrent macOS fork/exec can briefly inherit an owner FD. Wait for release,
// without retrying any failed persistence assertion or accepting another error.
fn reopen_context_journal(workspace: &Workspace, path: &std::path::Path) -> Arc<Service> {
    let start = Instant::now();
    loop {
        match Service::open(workspace.clone(), path) {
            Ok(service) => return service,
            Err(error)
                if error.to_string() == "service_already_running"
                    && start.elapsed() < Duration::from_secs(2) =>
            {
                thread::sleep(Duration::from_millis(5))
            }
            Err(error) => panic!("failed to reopen journal: {error}"),
        }
    }
}

fn context_save(repo: &str, revision: u64) -> Value {
    json!({"repo_id":repo,"expected_revision":revision,"purpose":"로그인 상태 복원",
        "criteria":["재시작 후 세션 복원", "실패 시 오류 표시"],"references":["docs/login.md"],"notes":"오프라인 케이스 확인"})
}

#[test]
fn commit_preserves_the_reviewed_message_under_repository_cleanup_config() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    git::git(path, &["config", "commit.cleanup", "strip"]).unwrap();
    fs::write(path.join("notes.txt"), "message regression\n").unwrap();
    git::git(path, &["add", "notes.txt"]).unwrap();
    let message = "Preserve this message\n\n# keep me\n\n";
    f.rpc("commit", json!({"repo_id":"ios-app","message":message,"snapshot_hash":digest(&git::snapshot(path).unwrap()).unwrap()}));
    let object = git::git(path, &["cat-file", "commit", "HEAD"]).unwrap();
    assert_eq!(object.split_once("\n\n").unwrap().1, message);
}

#[test]
fn diff_keeps_blank_context_prefixes_under_repository_config() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    fs::write(path.join("notes.txt"), "before\n\nold\nafter\n").unwrap();
    git::git(path, &["add", "notes.txt"]).unwrap();
    git::git(path, &["commit", "-m", "blank context baseline"]).unwrap();
    git::git(path, &["config", "diff.suppressBlankEmpty", "true"]).unwrap();
    fs::write(path.join("notes.txt"), "before\n\nnew\nafter\n").unwrap();
    let diff = git::diff(path, "notes.txt", false).unwrap();
    assert!(
        diff.text.contains(" before\n \n-old\n+new\n after\n"),
        "{}",
        diff.text
    );
    git::git(path, &["stash", "push", "--", "notes.txt"]).unwrap();
    let oid = git::git(path, &["rev-parse", "stash@{0}"]).unwrap();
    let diff = git::stash_diff(path, oid.trim(), "notes.txt").unwrap();
    assert!(
        diff.text.contains(" before\n \n-old\n+new\n after\n"),
        "{}",
        diff.text
    );
}

#[test]
fn selected_file_rpc_is_capability_gated_strict_fresh_and_never_replayed() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    let untouched_index = git::git_bytes(path, &["show", ":notes.txt"]).unwrap();
    fs::write(path.join("new-file"), "new reviewed content\n").unwrap();
    fs::write(path.join("notes.txt"), "unselected worktree\n").unwrap();
    let original_head = git::oid(path, "HEAD").unwrap();
    let status = f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert_eq!(status["file_staging_version"], 1);
    let params =
        json!({"repo_id":"ios-app","path":"new-file","snapshot_hash":status["snapshot_hash"]});
    let original = git::snapshot(path).unwrap();
    for (field, bad) in [
        ("staged", json!(null)),
        ("staged", json!("false")),
        ("op_id", json!(false)),
        ("op_id", json!("")),
        ("unknown", json!(true)),
    ] {
        let mut malformed = params.clone();
        malformed[field] = bad;
        let response = f.service.dispatch(Request {
            method: "stage_file".into(),
            params: malformed,
        });
        assert_eq!(response.error.unwrap().code, "invalid_parameter");
        assert_eq!(git::snapshot(path).unwrap(), original);
    }
    let result = f.rpc("stage_file", params.clone());
    assert_eq!(result["status"], "staged");
    assert_eq!(result["refresh_required"], false);
    assert_eq!(result["view"]["file_staging_version"], 1);
    assert_eq!(
        git::git(path, &["show", ":new-file"]).unwrap(),
        "new reviewed content\n"
    );
    assert_eq!(
        git::git_bytes(path, &["show", ":notes.txt"]).unwrap(),
        untouched_index
    );
    let after = git::snapshot(path).unwrap();
    let replay = f.service.dispatch(Request {
        method: "stage_file".into(),
        params,
    });
    assert_eq!(replay.error.unwrap().code, "stale_snapshot");
    assert_eq!(git::snapshot(path).unwrap(), after);
    f.rpc("stage_file", json!({"repo_id":"ios-app","path":"new-file","staged":true,"snapshot_hash":result["view"]["snapshot_hash"]}));
    assert!(
        git::git_bytes(path, &["ls-files", "--", "new-file"])
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        fs::read(path.join("new-file")).unwrap(),
        b"new reviewed content\n"
    );
    assert_eq!(
        fs::read(path.join("notes.txt")).unwrap(),
        b"unselected worktree\n"
    );
    assert_eq!(git::oid(path, "HEAD").unwrap(), original_head);
}

#[test]
fn selected_file_rpc_targets_only_the_authorized_ready_task_folder() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "selected-file-scope");
    assert_eq!(op.status, "ready");
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let task = &op
        .repos
        .iter()
        .find(|repo| repo.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    fs::write(source.join("new-file"), "original source\n").unwrap();
    fs::write(task.join("new-file"), "task selected\n").unwrap();
    let source_before = git::snapshot(source).unwrap();
    let task_head = git::oid(task, "HEAD").unwrap();
    let status = f.rpc(
        "get_repo_status",
        json!({"repo_id":"ios-app","op_id":op.id}),
    );
    let params = json!({"repo_id":"ios-app","op_id":op.id,"path":"new-file","snapshot_hash":status["snapshot_hash"]});
    let lock = workbench_service::repo_lock(task).unwrap();
    let busy = f.service.dispatch(Request {
        method: "stage_file".into(),
        params: params.clone(),
    });
    assert_eq!(busy.error.unwrap().code, "repository_busy");
    drop(lock);
    let result = f.rpc("stage_file", params);
    assert_eq!(result["view"]["path"], task.to_str().unwrap());
    assert_eq!(
        git::git(task, &["show", ":new-file"]).unwrap(),
        "task selected\n"
    );
    assert_eq!(git::snapshot(source).unwrap(), source_before);
    assert_eq!(git::oid(task, "HEAD").unwrap(), task_head);
    let mut stale = json!({"repo_id":"ios-app","op_id":op.id,"path":"new-file","staged":true,"snapshot_hash":result["view"]["snapshot_hash"]});
    stale["op_id"] = json!("missing-operation");
    assert!(
        f.service
            .dispatch(Request {
                method: "stage_file".into(),
                params: stale
            })
            .error
            .is_some()
    );
    assert_eq!(git::snapshot(source).unwrap(), source_before);
}

#[test]
fn malformed_optional_scope_never_falls_back_to_the_original_repository() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "typed-rpc-scope");
    assert_eq!(op.status, "ready");
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let task = &op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    fs::write(source.join("notes.txt"), "unstaged original change\n").unwrap();
    fs::write(source.join("staged.txt"), "original commit candidate\n").unwrap();
    git::git(source, &["add", "--", "staged.txt"]).unwrap();
    let diff = git::diff(source, "notes.txt", false).unwrap();
    let before = [source, task].map(|path| {
        let snapshot = git::snapshot(path).unwrap();
        let git_dir = git::git_path(path, &["rev-parse", "--absolute-git-dir"]).unwrap();
        let index = git_dir.join("index");
        (snapshot, index.clone(), fs::read(index).unwrap())
    });
    let original_context = f.rpc("get_task_context", json!({"repo_id":"ios-app"}));
    let task_context = f.rpc(
        "get_task_context",
        json!({"repo_id":"ios-app","op_id":op.id}),
    );
    let report = json!({"repo_id":"ios-app","kind":"human_report","verdict":"passed","command":"manual check","note":"must not be saved"});
    for malformed in [
        json!(false),
        json!(123),
        json!([]),
        json!({"expected_task":op.id}),
        json!(""),
        json!(" \t"),
    ] {
        for (method, mut params) in [
            ("list_branches", json!({"repo_id":"ios-app"})),
            (
                "get_branch_history",
                json!({"repo_id":"ios-app","branch_ref":"refs/heads/main","tip_oid":before[0].0.head}),
            ),
            ("list_stashes", json!({"repo_id":"ios-app"})),
            (
                "get_stash",
                json!({"repo_id":"ios-app","stash_oid":before[0].0.head}),
            ),
            (
                "get_stash_diff",
                json!({"repo_id":"ios-app","stash_oid":before[0].0.head,"path":"notes.txt"}),
            ),
            ("get_repo_status", json!({"repo_id":"ios-app"})),
            ("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"})),
            (
                "stage_hunk",
                json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":diff.snapshot_hash,"diff_hash":hash(diff.text.as_bytes())}),
            ),
            (
                "stage_file",
                json!({"repo_id":"ios-app","path":"notes.txt","snapshot_hash":diff.snapshot_hash}),
            ),
            (
                "commit",
                json!({"repo_id":"ios-app","snapshot_hash":diff.snapshot_hash,"message":"must not commit the original"}),
            ),
            ("get_task_context", json!({"repo_id":"ios-app"})),
            (
                "run_git_check",
                json!({"repo_id":"ios-app","snapshot_hash":diff.snapshot_hash}),
            ),
            ("record_verification_report", report.clone()),
        ] {
            params["op_id"] = malformed.clone();
            let response = f.service.dispatch(Request {
                method: method.into(),
                params,
            });
            assert_eq!(
                response.error.unwrap().code,
                "invalid_parameter",
                "{method}: {malformed}"
            );
            assert!(response.result.is_none());
        }
        for (method, mut params) in [
            (
                "get_task_context",
                json!({"repo_id":"ios-app","op_id":op.id}),
            ),
            ("save_task_context", context_save("ios-app", 0)),
            (
                "run_git_check",
                json!({"repo_id":"ios-app","snapshot_hash":diff.snapshot_hash}),
            ),
            ("record_verification_report", report.clone()),
        ] {
            params["context_op_id"] = malformed.clone();
            let response = f.service.dispatch(Request {
                method: method.into(),
                params,
            });
            assert_eq!(
                response.error.unwrap().code,
                "invalid_parameter",
                "{method}: {malformed}"
            );
            assert!(response.result.is_none());
        }
    }
    for (method, typo, mut params) in [
        (
            "stage_hunk",
            "opid",
            json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":diff.snapshot_hash,"diff_hash":hash(diff.text.as_bytes())}),
        ),
        (
            "commit",
            "opid",
            json!({"repo_id":"ios-app","snapshot_hash":diff.snapshot_hash,"message":"must not commit the original"}),
        ),
        (
            "save_task_context",
            "context_opid",
            context_save("ios-app", 0),
        ),
        (
            "run_git_check",
            "opid",
            json!({"repo_id":"ios-app","snapshot_hash":diff.snapshot_hash}),
        ),
        ("record_verification_report", "opid", report),
    ] {
        params[typo] = json!(op.id);
        let response = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert!(
            response.error.is_some(),
            "{method} accepted misspelled scope {typo}"
        );
        assert!(response.result.is_none());
    }
    for (path, (snapshot, index, bytes)) in [source, task].into_iter().zip(before) {
        assert_eq!(
            snapshot,
            git::snapshot(path).unwrap(),
            "HEAD/index/files changed at {path:?}"
        );
        assert_eq!(
            bytes,
            fs::read(index).unwrap(),
            "raw index changed at {path:?}"
        );
    }
    assert_eq!(
        original_context,
        f.rpc("get_task_context", json!({"repo_id":"ios-app"}))
    );
    assert_eq!(
        task_context,
        f.rpc(
            "get_task_context",
            json!({"repo_id":"ios-app","op_id":op.id})
        )
    );
    let db = rusqlite::Connection::open(f.home.join("journal.sqlite")).unwrap();
    for table in ["task_contexts", "verification_receipts"] {
        let count: i64 = db
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "malformed scope created a row in {table}");
    }

    // Validation takes precedence even when resolving the repository would fail.
    fs::rename(source, source.with_extension("moved")).unwrap();
    for method in [
        "list_branches",
        "get_repo_status",
        "get_diff",
        "stage_hunk",
        "commit",
        "run_git_check",
        "record_verification_report",
    ] {
        let response = f.service.dispatch(Request {
            method: method.into(),
            params: json!({"repo_id":"ios-app","op_id":123}),
        });
        assert_eq!(
            response.error.unwrap().code,
            "invalid_parameter",
            "{method}"
        );
    }
}

#[test]
fn malformed_staged_values_are_rejected_without_changing_git() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    fs::write(path.join("notes.txt"), "unstaged change\n").unwrap();
    let diff = git::diff(path, "notes.txt", false).unwrap();
    let before = git::snapshot(path).unwrap();
    let index = fs::read(path.join(".git/index")).unwrap();
    for malformed in [Value::Null, json!(0), json!("false"), json!([]), json!({})] {
        for method in ["get_diff", "stage_hunk"] {
            let response = f.service.dispatch(Request { method: method.into(), params: json!({"repo_id":"ios-app","path":"notes.txt","staged":malformed,"hunk_index":0,"snapshot_hash":diff.snapshot_hash,"diff_hash":hash(diff.text.as_bytes())}) });
            assert_eq!(
                response.error.unwrap().code,
                "invalid_parameter",
                "{method}: {malformed}"
            );
        }
    }
    assert_eq!(before, git::snapshot(path).unwrap());
    assert_eq!(index, fs::read(path.join(".git/index")).unwrap());
    fs::rename(path, path.with_extension("moved")).unwrap();
    for method in ["get_diff", "stage_hunk"] {
        let response = f.service.dispatch(Request {
            method: method.into(),
            params: json!({"repo_id":"ios-app","staged":"false"}),
        });
        assert_eq!(response.error.unwrap().code, "invalid_parameter");
    }
}

#[test]
fn omitted_null_and_valid_optional_scope_preserve_original_and_task_actions() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "valid-rpc-scope");
    assert_eq!(op.status, "ready");
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let task = &op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    let original = f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert_eq!(
        original,
        f.rpc("get_repo_status", json!({"repo_id":"ios-app","op_id":null}))
    );
    let task_view = f.rpc(
        "get_repo_status",
        json!({"repo_id":"ios-app","op_id":op.id}),
    );
    assert_eq!(
        task_view["snapshot_hash"],
        digest(&git::snapshot(task).unwrap()).unwrap()
    );
    for op_id in [Value::Null, json!(op.id)] {
        f.rpc("list_branches", json!({"repo_id":"ios-app","op_id":op_id}));
        let mut save = context_save("ios-app", 0);
        save["context_op_id"] = op_id.clone();
        f.rpc("save_task_context", save);
        let loaded = f.rpc(
            "get_task_context",
            json!({"repo_id":"ios-app","op_id":op_id,"context_op_id":null}),
        );
        assert_eq!(loaded["context"]["revision"], 1);
    }
    for (path, op_id) in [(source, Value::Null), (task, json!(op.id))] {
        let other = if path == source { task } else { source };
        let other_before = git::snapshot(other).unwrap();
        fs::write(path.join("notes.txt"), "scoped change\n").unwrap();
        let diff = f.rpc(
            "get_diff",
            json!({"repo_id":"ios-app","op_id":op_id,"path":"notes.txt"}),
        );
        assert_eq!(
            diff,
            f.rpc(
                "get_diff",
                json!({"repo_id":"ios-app","op_id":op_id,"path":"notes.txt","staged":false})
            )
        );
        let staged = f.rpc("stage_hunk", json!({"repo_id":"ios-app","op_id":op_id,"path":"notes.txt","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
        let committed = f.rpc("commit", json!({"repo_id":"ios-app","op_id":op_id,"snapshot_hash":staged["view"]["snapshot_hash"],"message":"Commit to the explicit scope"}));
        assert_eq!(committed["status"], "committed");
        assert_eq!(other_before, git::snapshot(other).unwrap());
        let checked = f.rpc("run_git_check", json!({"repo_id":"ios-app","op_id":op_id,"context_op_id":null,"snapshot_hash":committed["view"]["snapshot_hash"]}));
        assert_eq!(checked["verifications"][0]["op_id"], op_id);
        let reported = f.rpc("record_verification_report", json!({"repo_id":"ios-app","op_id":op_id,"context_op_id":null,"kind":"human_report","verdict":"passed","command":"manual check","note":"explicit scope"}));
        assert_eq!(reported["verifications"][0]["op_id"], op_id);
        assert_eq!(reported["verifications"][0]["path"], path.to_str().unwrap());
    }
}

#[test]
fn operation_key_lookup_finds_the_original_without_list_order_or_pagination() {
    let f = Fixture::new();
    let plan = f
        .service
        .plan(Fixture::request(Mode::BranchOnly, "example-key"))
        .unwrap();
    let first = f.service.execute(&plan.id, "welcome-example-key").unwrap();
    let first = wait(&f.service, &first.id);
    let later = f
        .service
        .plan(Fixture::request(Mode::BranchOnly, "newer-key"))
        .unwrap();
    let newer = f.service.execute(&later.id, "newer-key").unwrap();
    let newer = wait(&f.service, &newer.id);
    assert_ne!(first.id, newer.id);
    let found = f.rpc(
        "get_operation_by_key",
        json!({"idempotency_key":"welcome-example-key"}),
    );
    assert_eq!(found["operation"]["id"], first.id);
    assert!(
        f.rpc(
            "get_operation_by_key",
            json!({"idempotency_key":"not-present"})
        )["operation"]
            .is_null()
    );
    let missing = f.service.dispatch(Request {
        method: "get_operation_by_key".into(),
        params: json!({"idempotency_key":""}),
    });
    assert_eq!(missing.error.unwrap().code, "invalid_idempotency_key");
}

#[test]
fn embedded_repositories_are_explicitly_unsupported_and_common_dir_locks_never_queue() {
    let f = Fixture::new();
    let ios = &f.workspace.repo("ios-app").unwrap().path;
    let api = &f.workspace.repo("api").unwrap().path;
    let lock = workbench_service::repo_lock(ios).unwrap();
    let start = Instant::now();
    assert!(
        format!("{:#}", workbench_service::repo_lock(ios).unwrap_err()).contains("repository_busy")
    );
    assert!(start.elapsed() < Duration::from_secs(1));
    drop(lock);
    drop(workbench_service::repo_lock(ios).unwrap());
    let lock_path = git::common_dir(ios)
        .unwrap()
        .join("workbench.operation.lock");
    fs::remove_file(&lock_path).unwrap();
    let external = f.home.join("must-not-be-created");
    std::os::unix::fs::symlink(&external, &lock_path).unwrap();
    assert!(
        format!("{:#}", workbench_service::repo_lock(ios).unwrap_err())
            .contains("unsafe_repository_lock")
    );
    assert!(!external.exists());
    fs::remove_file(&lock_path).unwrap();
    fs::create_dir_all(ios.join("vendor")).unwrap();
    git::git(
        ios,
        &["clone", "--no-local", api.to_str().unwrap(), "vendor/tool"],
    )
    .unwrap();
    assert!(
        git::git_bytes(ios, &["ls-files", "--others", "--exclude-standard", "-z"])
            .unwrap()
            .split(|b| *b == 0)
            .any(|p| p == b"vendor/tool/")
    );
    let response = f.service.dispatch(Request {
        method: "get_repo_status".into(),
        params: json!({"repo_id":"ios-app"}),
    });
    assert_eq!(
        response.error.unwrap().code,
        "unsupported_nested_repository"
    );
    fs::write(ios.join(".gitignore"), "vendor/\n").unwrap();
    fs::create_dir_all(ios.join(".agents")).unwrap();
    git::git(
        api,
        &[
            "worktree",
            "add",
            "-b",
            "nested-agent",
            ios.join(".agents/wt").to_str().unwrap(),
            "HEAD",
        ],
    )
    .unwrap();
    assert!(ios.join(".agents/wt/.git").is_file());
    assert_eq!(
        git::view(ios).unwrap_err().to_string(),
        "unsupported_nested_repository"
    );
    fs::write(ios.join(".gitignore"), "vendor/\n.agents/\n").unwrap();
    assert!(git::view(ios).is_ok());
}

#[test]
fn changed_git_presentation_cannot_stage_a_different_hunk_on_the_same_snapshot() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    let mut lines: Vec<_> = (1..=40).map(|n| format!("line {n}\n")).collect();
    lines[2] = "selected edit\n".into();
    lines[32] = "unselected edit\n".into();
    fs::write(path.join("notes.txt"), lines.concat()).unwrap();
    let rendered = git::diff(path, "notes.txt", false).unwrap();
    assert_eq!(rendered.hunks.len(), 2);
    let before = git::snapshot(path).unwrap();
    git::git(path, &["config", "diff.interHunkContext", "1000"]).unwrap();
    let changed = git::diff(path, "notes.txt", false).unwrap();
    assert_eq!(changed.hunks.len(), 1);
    assert_eq!(rendered.snapshot_hash, changed.snapshot_hash);
    let response = f.service.dispatch(Request {
        method: "stage_hunk".into(),
        params: json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,
            "snapshot_hash":rendered.snapshot_hash,"diff_hash":hash(rendered.text.as_bytes())}),
    });
    assert_eq!(response.error.unwrap().code, "stale_diff");
    assert_eq!(before, git::snapshot(path).unwrap());
    let missing = f.service.dispatch(Request { method: "stage_hunk".into(),
        params: json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":rendered.snapshot_hash}) });
    assert_eq!(missing.error.unwrap().code, "missing_parameter");
    assert_eq!(before, git::snapshot(path).unwrap());
}

#[test]
fn builtin_aliases_do_not_execute_and_retargeted_originals_are_rejected() {
    let f = Fixture::new();
    let repo = f.workspace.repo("ios-app").unwrap();
    for name in ["rev-parse", "config", "status", "diff", "log"] {
        git::git(
            &repo.path,
            &[
                "config",
                &format!("alias.{name}"),
                "!touch alias-must-not-run",
            ],
        )
        .unwrap();
    }
    f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert!(
        !repo.path.join("alias-must-not-run").exists(),
        "Git builtins take precedence over aliases"
    );
    let other = &f.workspace.repo("api").unwrap().path;
    git::git(
        &repo.path,
        &["config", "core.worktree", other.to_str().unwrap()],
    )
    .unwrap();
    for method in [
        "get_repo_status",
        "list_stashes",
        "list_branches",
        "stage_hunk",
    ] {
        let response = f.service.dispatch(Request {
            method: method.into(),
            params: json!({"repo_id":"ios-app"}),
        });
        assert_eq!(response.error.unwrap().code, "unsafe_source_repository");
    }
    assert!(!other.join("alias-must-not-run").exists());
}

#[test]
fn large_files_keep_status_available_and_non_utf8_hunks_are_read_only_with_exact_file_staging() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    fs::File::create(path.join("large.bin"))
        .unwrap()
        .set_len(40 * 1024 * 1024)
        .unwrap();
    let view = f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert!(
        view["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["path"] == "large.bin")
    );
    fs::write(path.join("notes.txt"), b"legacy text \xbe\xc8\xb3\xe7\n").unwrap();
    let before = git::snapshot(path).unwrap();
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"}));
    assert_eq!(diff["can_stage_hunks"], false);
    assert!(
        diff["encoding_warning"]
            .as_str()
            .unwrap()
            .contains("부분 스테이징은 지원하지 않습니다")
    );
    let rejected = f.service.dispatch(Request { method:"stage_hunk".into(), params:json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}) });
    assert_eq!(rejected.error.unwrap().code, "unsupported_hunk_change");
    assert_eq!(before, git::snapshot(path).unwrap());
    let result = f.rpc(
        "stage_file",
        json!({"repo_id":"ios-app","path":"notes.txt","snapshot_hash":diff["snapshot_hash"]}),
    );
    assert_eq!(
        git::git_bytes(path, &["show", ":notes.txt"]).unwrap(),
        b"legacy text \xbe\xc8\xb3\xe7\n"
    );
    assert_eq!(
        fs::read(path.join("notes.txt")).unwrap(),
        b"legacy text \xbe\xc8\xb3\xe7\n"
    );
    assert_eq!(result["view"]["snapshot"]["head"], before.head);
}

#[test]
fn task_context_persists_and_rejects_lost_updates_without_git_mutation() {
    let f = Fixture::new();
    let repo = &f.workspace.repositories[0];
    let before = git::snapshot(&repo.path).unwrap();
    let saved = f.rpc("save_task_context", context_save(&repo.id, 0));
    assert_eq!(saved["context"]["revision"], 1);
    let response = f.service.dispatch(Request {
        method: "save_task_context".into(),
        params: context_save(&repo.id, 0),
    });
    assert_eq!(response.error.unwrap().code, "context_conflict");
    let mut oversized = context_save(&repo.id, 1);
    oversized["purpose"] = json!("a".repeat(8_001));
    assert!(
        f.service
            .dispatch(Request {
                method: "save_task_context".into(),
                params: oversized
            })
            .error
            .is_some()
    );
    assert_eq!(before, git::snapshot(&repo.path).unwrap());
    let repo_id = repo.id.clone();
    drop(f.service);
    let reopened = reopen_context_journal(&f.workspace, &f.home.join("journal.sqlite"));
    let response = reopened.dispatch(Request {
        method: "get_task_context".into(),
        params: json!({"repo_id":repo_id}),
    });
    assert_eq!(response.result.unwrap()["context"], saved["context"]);
}

#[test]
fn task_context_is_shared_across_task_repos_but_not_original_or_another_task() {
    let f = Fixture::new();
    let op = f.execute(Mode::BranchOnly, "context-shared");
    let a = &op.repos[0].plan.repo_id;
    let b = &op.repos[1].plan.repo_id;
    let mut save = context_save(a, 0);
    save["context_op_id"] = json!(op.id);
    let saved = f.rpc("save_task_context", save);
    let sibling = f.rpc("get_task_context", json!({"repo_id":b,"op_id":op.id}));
    assert_eq!(saved["context"], sibling["context"]);
    let original = f.rpc("get_task_context", json!({"repo_id":a}));
    assert_eq!(original["context"]["revision"], 0);
    let original_in_task = f.rpc(
        "get_task_context",
        json!({"repo_id":a,"context_op_id":op.id}),
    );
    assert_eq!(original_in_task["context"], saved["context"]);
    let other = f.execute(Mode::BranchOnly, "context-other");
    let response = f.service.dispatch(Request {
        method: "get_task_context".into(),
        params: json!({"repo_id":a,"op_id":other.id,"context_op_id":op.id}),
    });
    assert_eq!(response.error.unwrap().code, "task_context_mismatch");
}

#[test]
fn observed_git_checks_capture_failure_snapshots_and_stale_checks_never_run() {
    let f = Fixture::new();
    let repo = &f.workspace.repositories[0];
    let clean = git::snapshot(&repo.path).unwrap();
    let hash = digest(&clean).unwrap();
    let result = f.rpc(
        "run_git_check",
        json!({"repo_id":repo.id,"snapshot_hash":hash}),
    );
    let receipt = &result["verifications"][0];
    assert_eq!(receipt["kind"], "git_check");
    assert_eq!(receipt["verdict"], "passed");
    assert_eq!(receipt["snapshot_hash"], receipt["after_snapshot_hash"]);
    let file = repo.path.join("Config/Version.xcconfig");
    let original = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        format!("{original}\n// bad trailing whitespace   \n"),
    )
    .unwrap();
    let stale = f.service.dispatch(Request {
        method: "run_git_check".into(),
        params: json!({"repo_id":repo.id,"snapshot_hash":hash}),
    });
    assert_eq!(stale.error.unwrap().code, "stale_snapshot");
    let before = git::snapshot(&repo.path).unwrap();
    let failed = f.rpc(
        "run_git_check",
        json!({"repo_id":repo.id,"snapshot_hash":digest(&before).unwrap()}),
    );
    assert_eq!(failed["verifications"].as_array().unwrap().len(), 2);
    assert_eq!(failed["verifications"][0]["verdict"], "failed");
    assert!(
        failed["verifications"][0]["output"]
            .as_str()
            .unwrap()
            .contains("trailing whitespace")
    );
    assert_eq!(
        before,
        git::snapshot(&repo.path).unwrap(),
        "verification must preserve HEAD/index/files"
    );
    git::git(&repo.path, &["add", "--", "Config/Version.xcconfig"]).unwrap();
    fs::write(&file, original).unwrap();
    let before = git::snapshot(&repo.path).unwrap();
    let index = f.rpc(
        "run_git_check",
        json!({"repo_id":repo.id,"snapshot_hash":digest(&before).unwrap()}),
    );
    assert_eq!(
        index["verifications"][0]["verdict"], "failed",
        "staged whitespace must also fail"
    );
    assert_eq!(before, git::snapshot(&repo.path).unwrap());
}

#[test]
fn fixed_git_check_discloses_untracked_exclusion_and_detects_markers_and_in_progress_git() {
    let f = Fixture::new();
    let repo = &f.workspace.repositories[0];
    fs::write(
        repo.path.join("untracked.txt"),
        "<<<<<<< untracked marker   \n",
    )
    .unwrap();
    let check = || {
        let before = git::snapshot(&repo.path).unwrap();
        let result = f.rpc(
            "run_git_check",
            json!({"repo_id":repo.id,"snapshot_hash":digest(&before).unwrap()}),
        );
        assert_eq!(before, git::snapshot(&repo.path).unwrap());
        result
    };
    let untracked = check();
    assert_eq!(untracked["verifications"][0]["verdict"], "passed");
    assert!(
        untracked["verifications"][0]["note"]
            .as_str()
            .unwrap()
            .contains("새 파일")
    );
    let file = repo.path.join("Config/Version.xcconfig");
    let original = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        format!("{original}\n<<<<<<< HEAD\none\n=======\ntwo\n>>>>>>> peer\n"),
    )
    .unwrap();
    let marker = check();
    assert_eq!(marker["verifications"][0]["verdict"], "failed");
    fs::write(&file, original).unwrap();
    fs::write(
        git::common_dir(&repo.path).unwrap().join("MERGE_HEAD"),
        git::oid(&repo.path, "HEAD").unwrap(),
    )
    .unwrap();
    let in_progress = check();
    assert_eq!(in_progress["verifications"][0]["verdict"], "failed");
    assert!(
        in_progress["verifications"][0]["output"]
            .as_str()
            .unwrap()
            .contains("integration_in_progress")
    );
}

#[test]
fn reports_cannot_forge_observed_results_and_criteria_identity_is_independent() {
    let f = Fixture::new();
    let repo = &f.workspace.repositories[0];
    let saved = f.rpc("save_task_context", context_save(&repo.id, 0));
    let report = json!({"repo_id":repo.id,"kind":"ai_report","verdict":"passed","command":"touch MUST_NOT_EXIST","note":"AI says tests passed"});
    let reported = f.rpc("record_verification_report", report.clone());
    let receipt = &reported["verifications"][0];
    assert_eq!(receipt["kind"], "ai_report");
    assert!(receipt["after_snapshot_hash"].is_null());
    assert!(!repo.path.join("MUST_NOT_EXIST").exists());
    let mut forged = report;
    forged["kind"] = json!("git_check");
    assert!(
        f.service
            .dispatch(Request {
                method: "record_verification_report".into(),
                params: forged
            })
            .error
            .is_some()
    );
    let mut notes = context_save(&repo.id, 1);
    notes["notes"] = json!("새 인수인계 메모");
    let changed_notes = f.rpc("save_task_context", notes);
    assert_eq!(
        saved["context"]["requirements_hash"],
        changed_notes["context"]["requirements_hash"]
    );
    let mut criteria = context_save(&repo.id, 2);
    criteria["criteria"] = json!(["오프라인 로그인 추가"]);
    let changed = f.rpc("save_task_context", criteria);
    assert_ne!(
        changed["context"]["requirements_hash"],
        receipt["requirements_hash"]
    );
    assert_eq!(
        changed["verifications"][0], *receipt,
        "historical evidence is append-only, not rewritten for new goals"
    );
    drop(f.service);
    let reopened = reopen_context_journal(&f.workspace, &f.home.join("journal.sqlite"));
    let result = reopened
        .dispatch(Request {
            method: "get_task_context".into(),
            params: json!({"repo_id":repo.id}),
        })
        .result
        .unwrap();
    assert_eq!(result["verifications"][0], *receipt);
}

#[test]
fn reading_keys_follow_file_bytes_and_git_context_without_mutating_git() {
    let f = Fixture::new();
    let path = &f.workspace.repositories[0].path;
    let file = "Config/Version.xcconfig";
    let original = fs::read(path.join(file)).unwrap();
    let mut modified = original.clone();
    modified.extend_from_slice(b"\n// first review\n");
    fs::write(path.join(file), &modified).unwrap();
    let key = |view: &git::RepoView| {
        view.files
            .iter()
            .find(|f| f.path == file)
            .unwrap()
            .review_key
            .clone()
            .unwrap()
    };
    let before = git::snapshot(path).unwrap();
    let first = git::view(path).unwrap();
    let diff = git::diff(path, file, false).unwrap();
    assert_eq!(Some(key(&first)), diff.review_key);
    assert_eq!(before, git::snapshot(path).unwrap());
    fs::write(path.join("unrelated-review.txt"), "peer edit").unwrap();
    let peer = git::view(path).unwrap();
    assert_ne!(first.snapshot_hash, peer.snapshot_hash);
    assert_eq!(
        key(&first),
        key(&peer),
        "unrelated working edits must retain reading"
    );
    modified.extend_from_slice(b"// changed after review\n");
    fs::write(path.join(file), modified).unwrap();
    let edited = git::view(path).unwrap();
    assert_ne!(key(&peer), key(&edited));
    git::git(path, &["add", "--", "unrelated-review.txt"]).unwrap();
    let staged = git::view(path).unwrap();
    assert_ne!(
        key(&edited),
        key(&staged),
        "changed index conservatively invalidates context"
    );
    git::git(path, &["checkout", "-b", "review-context"]).unwrap();
    let branch = git::view(path).unwrap();
    assert_ne!(key(&staged), key(&branch));
    assert_eq!(
        Some(key(&branch)),
        git::diff(path, file, false).unwrap().review_key
    );
}

struct Fixture {
    _temp: TempDir,
    workspace: Workspace,
    service: Arc<Service>,
    home: std::path::PathBuf,
}

#[test]
fn remote_configuration_is_provider_neutral_and_bound_to_the_reviewed_state() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let before = git::snapshot(source).unwrap();
    let initial = f.rpc("get_remote_state", json!({"repo_id":"ios-app"}));
    assert_eq!(initial["repository_path"], source.to_str().unwrap());
    assert!(initial["remotes"].as_array().unwrap().is_empty());
    let added = f.rpc(
        "configure_remote",
        json!({"repo_id":"ios-app", "expected_state_hash":initial["state_hash"],
        "action":"add", "name":"company", "url":"https://gitlab.example.test/group/project.git",
        "push_url":"git@bitbucket.example.test:team/project.git"}),
    );
    assert_eq!(added["refresh_required"], false);
    let remote = &added["state"]["remotes"][0];
    assert_eq!(remote["name"], "company");
    assert_eq!(
        remote["fetch_url"],
        "https://gitlab.example.test/group/project.git"
    );
    assert_eq!(
        remote["push_url"],
        "git@bitbucket.example.test:team/project.git"
    );
    assert_eq!(remote["supported"], true);
    let rejected = f.service.dispatch(Request {
        method: "configure_remote".into(),
        params: json!({"repo_id":"ios-app", "expected_state_hash":initial["state_hash"],
            "action":"remove", "name":"company"}),
    });
    assert_eq!(rejected.error.unwrap().code, "stale_remote_state");
    let updated = f.rpc(
        "configure_remote",
        json!({"repo_id":"ios-app", "expected_state_hash":added["state"]["state_hash"],
        "action":"update", "name":"company", "url":"ssh://git@git.example.test/team/project.git"}),
    );
    assert_eq!(
        updated["state"]["remotes"][0]["fetch_url"],
        "ssh://git@git.example.test/team/project.git"
    );
    let removed = f.rpc(
        "configure_remote",
        json!({"repo_id":"ios-app", "expected_state_hash":updated["state"]["state_hash"],
        "action":"remove", "name":"company"}),
    );
    assert!(removed["state"]["remotes"].as_array().unwrap().is_empty());
    assert_eq!(before, git::snapshot(source).unwrap());
}

#[test]
fn remote_endpoint_drift_rejects_every_network_action_before_transport() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    git::git(
        source,
        &[
            "remote",
            "add",
            "origin",
            "https://gitlab.example.test/team/first.git",
        ],
    )
    .unwrap();
    let reviewed = f.rpc("get_remote_state", json!({"repo_id":"ios-app"}));
    git::git(
        source,
        &[
            "remote",
            "set-url",
            "origin",
            "https://gitlab.example.test/team/changed.git",
        ],
    )
    .unwrap();
    let before = git::snapshot(source).unwrap();
    for method in ["fetch_remote", "pull_remote", "push_remote"] {
        let mut params = json!({"repo_id":"ios-app", "expected_state_hash":reviewed["state_hash"], "remote":"origin"});
        if method != "fetch_remote" {
            params["branch"] = json!("main");
        }
        let response = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(
            response.error.unwrap().code,
            "stale_remote_state",
            "{method}"
        );
    }
    assert_eq!(before, git::snapshot(source).unwrap());
    assert_eq!(
        git::git(source, &["remote", "get-url", "origin"])
            .unwrap()
            .trim(),
        "https://gitlab.example.test/team/changed.git"
    );
}

#[test]
fn remote_requests_strictly_validate_parameters_without_scope_fallback() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let initial = f.rpc("get_remote_state", json!({"repo_id":"ios-app"}));
    let configure = json!({"repo_id":"ios-app", "expected_state_hash":initial["state_hash"],
        "action":"add", "name":"origin", "url":"https://git.example.test/team/project.git"});
    let network = json!({"repo_id":"ios-app", "expected_state_hash":initial["state_hash"], "remote":"origin"});
    for (method, base) in [
        ("get_remote_state", json!({"repo_id":"ios-app"})),
        ("configure_remote", configure.clone()),
        ("fetch_remote", network.clone()),
        ("pull_remote", {
            let mut p = network.clone();
            p["branch"] = json!("main");
            p
        }),
        ("push_remote", {
            let mut p = network.clone();
            p["branch"] = json!("main");
            p
        }),
    ] {
        for malformed in [
            json!(false),
            json!(0),
            json!([]),
            json!({}),
            json!(""),
            json!(" \t"),
        ] {
            let mut params = base.clone();
            params["op_id"] = malformed;
            let result = f.service.dispatch(Request {
                method: method.into(),
                params,
            });
            assert_eq!(result.error.unwrap().code, "invalid_parameter", "{method}");
        }
        let mut params = base;
        params["opid"] = json!("typo");
        let result = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(result.error.unwrap().code, "invalid_parameter", "{method}");
    }
    for params in [
        {
            let mut p = configure.clone();
            p["expected_state_hash"] = json!("wrong");
            p
        },
        {
            let mut p = configure.clone();
            p["action"] = json!("rename");
            p
        },
        {
            let mut p = configure.clone();
            p["url"] = Value::Null;
            p
        },
        {
            let mut p = configure.clone();
            p["action"] = json!("remove");
            p
        },
        {
            let mut p = configure.clone();
            p["name"] = json!("a".repeat(201));
            p
        },
    ] {
        let response = f.service.dispatch(Request {
            method: "configure_remote".into(),
            params,
        });
        assert_eq!(response.error.unwrap().code, "invalid_parameter");
    }
    assert!(git::git(source, &["remote"]).unwrap().trim().is_empty());
}

#[test]
fn remote_mutations_use_the_selected_ready_worktree_and_common_directory_lock() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "remote-selected-folder");
    assert_eq!(op.status, "ready");
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let task = &op
        .repos
        .iter()
        .find(|repo| repo.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    let original = f.rpc("get_remote_state", json!({"repo_id":"ios-app"}));
    let selected = f.rpc(
        "get_remote_state",
        json!({"repo_id":"ios-app", "op_id":op.id}),
    );
    assert_eq!(selected["repository_path"], task.to_str().unwrap());
    assert_ne!(selected["state_hash"], original["state_hash"]);
    let mut params = json!({"repo_id":"ios-app", "op_id":op.id, "expected_state_hash":original["state_hash"],
        "action":"add", "name":"origin", "url":"https://git.example.test/team/project.git"});
    let stale = f.service.dispatch(Request {
        method: "configure_remote".into(),
        params: params.clone(),
    });
    assert_eq!(stale.error.unwrap().code, "stale_remote_state");
    params["expected_state_hash"] = selected["state_hash"].clone();
    let lock = workbench_service::repo_lock(source).unwrap();
    let busy = f.service.dispatch(Request {
        method: "configure_remote".into(),
        params: params.clone(),
    });
    assert_eq!(busy.error.unwrap().code, "repository_busy");
    drop(lock);
    let snapshots = [git::snapshot(source).unwrap(), git::snapshot(task).unwrap()];
    let success = f.rpc("configure_remote", params);
    assert_eq!(success["state"]["repository_path"], task.to_str().unwrap());
    assert_eq!(
        snapshots,
        [git::snapshot(source).unwrap(), git::snapshot(task).unwrap()]
    );
    let shared = f.rpc("get_remote_state", json!({"repo_id":"ios-app"}));
    assert_eq!(shared["remotes"][0]["name"], "origin");
    let waiting = f.execute(Mode::BranchOnly, "remote-waiting-folder");
    let blocked = f.service.dispatch(Request {method:"configure_remote".into(),
        params:json!({"repo_id":"ios-app", "op_id":waiting.id, "expected_state_hash":shared["state_hash"],
            "action":"remove", "name":"origin"})});
    assert_eq!(blocked.error.unwrap().code, "task_not_ready");
}
impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let home = temp.path().join("fixture with spaces 한글");
        fixtures::create(&home).unwrap();
        for id in ["api.set-version@1", "ios-app.set-version@1"] {
            fixtures::trust(&home.join("workspace.json"), id).unwrap();
        }
        let workspace = load_workspace(&home.join("workspace.json")).unwrap();
        let service = Service::open(workspace.clone(), &home.join("journal.sqlite")).unwrap();
        Self {
            _temp: temp,
            workspace,
            service,
            home,
        }
    }
    fn request(mode: Mode, slug: &str) -> TaskRequest {
        TaskRequest {
            group_id: "ios-2-4".into(),
            label: "로그인 개선".into(),
            task_slug: slug.into(),
            mode,
            repo_overrides: Default::default(),
        }
    }
    fn execute(&self, mode: Mode, slug: &str) -> Operation {
        let plan = self.service.plan(Self::request(mode, slug)).unwrap();
        let op = self.service.execute(&plan.id, slug).unwrap();
        wait(&self.service, &op.id)
    }
    fn rpc(&self, method: &str, params: Value) -> Value {
        let response = self.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert!(response.error.is_none(), "{:?}", response.error);
        response.result.unwrap()
    }
}
fn wait(service: &Service, id: &str) -> Operation {
    let start = Instant::now();
    loop {
        let op = service.operation(id).unwrap();
        if op.status != "queued" && op.status != "running" {
            return op;
        }
        assert!(
            start.elapsed() < Duration::from_secs(20),
            "timed out waiting for operation"
        );
        thread::sleep(Duration::from_millis(20));
    }
}
fn originals(workspace: &Workspace) -> Vec<Snapshot> {
    workspace
        .repositories
        .iter()
        .map(|r| git::snapshot(&r.path).unwrap())
        .collect()
}

#[test]
fn stash_review_is_shared_read_only_and_uses_stable_oids() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    assert_eq!(
        f.rpc("list_stashes", json!({"repo_id":"ios-app"})),
        json!([])
    );
    let tracked = source.join("Config/Version.xcconfig");
    fs::write(
        &tracked,
        format!(
            "{}\n// stash_tracked_token\n",
            fs::read_to_string(&tracked).unwrap()
        ),
    )
    .unwrap();
    let untracked = "한글 draft\nwith spaces.txt";
    fs::write(source.join(untracked), "stash_untracked_token\n").unwrap();
    git::git(
        source,
        &["stash", "push", "-u", "-m", "로그인 세션 변경 보류"],
    )
    .unwrap();
    let older = f.rpc("list_stashes", json!({"repo_id":"ios-app"}))[0]["oid"]
        .as_str()
        .unwrap()
        .to_string();
    let op = f.execute(Mode::Materialize, "stash-review");
    assert_eq!(op.status, "ready");
    let linked = &op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    fs::write(linked.join("linked draft.txt"), "linked worktree stash\n").unwrap();
    git::git(
        linked,
        &["stash", "push", "-u", "-m", "로그인 화면 초안 보류"],
    )
    .unwrap();
    let before = originals(&f.workspace);
    let linked_before = git::snapshot(linked).unwrap();
    let stash_log = git::git_bytes(source, &["reflog", "show", "refs/stash"]).unwrap();
    let entries = f.rpc("list_stashes", json!({"repo_id":"ios-app", "op_id":op.id}));
    assert_eq!(entries.as_array().unwrap().len(), 2);
    assert_eq!(entries[1]["oid"], older);
    assert_eq!(git::stashes(linked).unwrap()[1].oid, older);
    let graph = git::view(source).unwrap().graph;
    assert!(entries.as_array().unwrap().iter().all(|entry| {
        graph
            .iter()
            .all(|commit| commit.oid != entry["oid"].as_str().unwrap())
    }));
    let detail = f.rpc("get_stash", json!({"repo_id":"ios-app", "stash_oid":older}));
    assert!(
        detail["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["path"] == untracked)
    );
    for (file, token) in [
        ("Config/Version.xcconfig", "stash_tracked_token"),
        (untracked, "stash_untracked_token"),
    ] {
        let diff = f.rpc(
            "get_stash_diff",
            json!({"repo_id":"ios-app", "stash_oid":older, "path":file}),
        );
        assert!(diff["text"].as_str().unwrap().contains(token));
        assert_eq!(diff["can_stage_hunks"], false);
        assert!(!diff["hunks"].as_array().unwrap().is_empty());
    }
    assert_eq!(before, originals(&f.workspace));
    assert_eq!(linked_before, git::snapshot(linked).unwrap());
    assert_eq!(
        stash_log,
        git::git_bytes(source, &["reflog", "show", "refs/stash"]).unwrap()
    );
    assert_eq!(f.rpc("list_stashes", json!({"repo_id":"api"})), json!([]));
    let foreign = f.service.dispatch(Request {
        method: "get_stash".into(),
        params: json!({"repo_id":"api","stash_oid":older}),
    });
    assert!(foreign.error.is_some());
    git::git(linked, &["stash", "drop", "stash@{0}"]).unwrap();
    let moved = f.rpc("list_stashes", json!({"repo_id":"ios-app"}));
    assert_eq!(moved[0]["selector"], "stash@{0}");
    assert_eq!(moved[0]["oid"], older);
    assert_eq!(
        f.rpc("get_stash", json!({"repo_id":"ios-app","stash_oid":older}))["oid"],
        older
    );
    let rejected = f.service.dispatch(Request {
        method: "get_stash_diff".into(),
        params: json!({"repo_id":"ios-app","stash_oid":older,"path":"../outside"}),
    });
    assert!(rejected.error.is_some());
}

#[test]
fn branch_browser_reads_local_remote_and_linked_history_without_checkout() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let base = git::oid(source, "HEAD").unwrap();
    git::git(source, &["branch", "feature/한글-login"]).unwrap();
    git::git(source, &["update-ref", "refs/remotes/origin/main", &base]).unwrap();
    git::git(
        source,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ],
    )
    .unwrap();
    git::git(
        source,
        &[
            "config",
            "remote.origin.url",
            "https://example.invalid/synthetic.git",
        ],
    )
    .unwrap();
    git::git(
        source,
        &[
            "config",
            "remote.origin.fetch",
            "+refs/heads/*:refs/remotes/origin/*",
        ],
    )
    .unwrap();
    git::git(source, &["branch", "--set-upstream-to=origin/main", "main"]).unwrap();
    let waiting = f.execute(Mode::BranchOnly, "branch-browser");
    let before = originals(&f.workspace);
    let waiting_refs = f.rpc(
        "list_branches",
        json!({"repo_id":"ios-app","op_id":waiting.id}),
    );
    assert!(
        waiting_refs
            .as_array()
            .unwrap()
            .iter()
            .all(|b| b["current"] == false)
    );
    let _: Value = f.rpc("materialize", json!({"op_id":waiting.id}));
    let ready = wait(&f.service, &waiting.id);
    assert_eq!(ready.status, "ready");
    let linked = &ready
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    let linked_before = git::snapshot(linked).unwrap();
    let values = f.rpc(
        "list_branches",
        json!({"repo_id":"ios-app","op_id":ready.id}),
    );
    let branches = values.as_array().unwrap();
    assert!(
        branches
            .iter()
            .any(|b| b["name"] == "feature/한글-login" && b["is_remote"] == false)
    );
    assert!(
        branches
            .iter()
            .any(|b| b["name"] == "origin/main" && b["is_remote"] == true)
    );
    assert!(!branches.iter().any(|b| b["name"] == "origin/HEAD"));
    assert_eq!(branches.iter().filter(|b| b["current"] == true).count(), 1);
    let current = branches.iter().find(|b| b["current"] == true).unwrap();
    assert_eq!(current["worktree_path"], linked.to_str().unwrap());
    let main = branches.iter().find(|b| b["name"] == "main").unwrap();
    assert_eq!(main["upstream"], "origin/main");
    let history = f.rpc(
        "get_branch_history",
        json!({"repo_id":"ios-app","branch_ref":"refs/remotes/origin/main","tip_oid":base}),
    );
    assert_eq!(history[0]["oid"], base);
    assert_eq!(before, originals(&f.workspace));
    assert_eq!(linked_before, git::snapshot(linked).unwrap());
    let stale = f.service.dispatch(Request {method:"get_branch_history".into(),params:json!({"repo_id":"ios-app","branch_ref":"refs/heads/main","tip_oid":"0".repeat(40)})});
    assert!(stale.error.is_some());
    let invalid = f.service.dispatch(Request {
        method: "get_branch_history".into(),
        params: json!({"repo_id":"ios-app","branch_ref":"--all","tip_oid":base}),
    });
    assert!(invalid.error.is_some());
}
fn assert_versions(op: &Operation) {
    for repo in &op.repos {
        assert_eq!(repo.state, RepoState::Ready, "{repo:?}");
        let values = workbench_runner::inspect(&repo.plan.worktree_path).unwrap();
        assert_eq!(values.local_build, "241");
        assert_eq!(values.marketing_version, "2.4.0");
        let status = git::git(&repo.plan.worktree_path, &["status", "--porcelain=v1"]).unwrap();
        assert_eq!(status.trim(), "M Config/Version.xcconfig");
        assert!(
            git::git_bytes(&repo.plan.worktree_path, &["diff", "--cached"])
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            git::oid(&repo.plan.worktree_path, "HEAD").unwrap(),
            repo.plan.base_oid
        );
        assert_eq!(
            git::git(&repo.plan.worktree_path, &["symbolic-ref", "HEAD"])
                .unwrap()
                .trim(),
            repo.plan.branch_ref
        );
    }
}

#[test]
fn branch_only_materializes_without_touching_dirty_originals_and_deduplicates() {
    let f = Fixture::new();
    // Preserve a dirty index as well as unstaged and untracked original files.
    git::git(
        &f.workspace.repo("ios-app").unwrap().path,
        &["add", "notes.txt"],
    )
    .unwrap();
    let before = originals(&f.workspace);
    let plan = f
        .service
        .plan(Fixture::request(Mode::BranchOnly, "login"))
        .unwrap();
    for repo in &plan.repos {
        assert_eq!(repo.policy_origins["base_ref"], "group:ios-2-4");
        assert_eq!(repo.policy_origins["inputs"], "group:mobile");
        assert_eq!(
            repo.base_oid,
            git::oid(
                &f.workspace.repo(&repo.repo_id).unwrap().path,
                "refs/heads/release/2.4"
            )
            .unwrap()
        );
        // A moving group base ref must not change the OID already pinned in this plan.
        git::git(
            &f.workspace.repo(&repo.repo_id).unwrap().path,
            &["update-ref", &repo.base_ref, "HEAD^"],
        )
        .unwrap();
    }
    let initial = f.service.execute(&plan.id, "same-key").unwrap();
    let op = wait(&f.service, &initial.id);
    assert_eq!(op.status, "waiting_for_worktree");
    for repo in &op.repos {
        assert!(!repo.plan.worktree_path.exists());
        assert_eq!(repo.attempts, 0);
        assert_eq!(
            git::oid(
                &f.workspace.repo(&repo.plan.repo_id).unwrap().path,
                &repo.plan.branch_ref
            )
            .unwrap(),
            repo.plan.base_oid
        );
    }
    assert_eq!(before, originals(&f.workspace));
    let repeated = f.service.execute(&plan.id, "same-key").unwrap();
    assert_eq!(initial.id, repeated.id);
    f.service.resume(&op.id, true).unwrap();
    let op = wait(&f.service, &op.id);
    assert_eq!(op.status, "ready", "{op:?}");
    assert_versions(&op);
    assert_eq!(before, originals(&f.workspace));
    let worktrees = git::git(
        &f.workspace.repositories[0].path,
        &["worktree", "list", "--porcelain"],
    )
    .unwrap();
    assert_eq!(
        worktrees
            .lines()
            .filter(|l| l.starts_with("worktree "))
            .count(),
        2
    );
    let events = f.service.events(0).unwrap();
    let cursor = events.last().unwrap().sequence;
    assert!(events.len() > 8);
    assert!(f.service.events(cursor).unwrap().is_empty());
    assert_eq!(
        f.service.execute(&plan.id, "same-key").unwrap().repos[0].attempts,
        1
    );
    for repo in &plan.repos {
        git::git(
            &f.workspace.repo(&repo.repo_id).unwrap().path,
            &["update-ref", &repo.base_ref, &repo.base_oid],
        )
        .unwrap();
    }
    let second = f
        .service
        .plan(Fixture::request(Mode::BranchOnly, "other"))
        .unwrap();
    assert!(
        f.service
            .execute(&second.id, "same-key")
            .unwrap_err()
            .to_string()
            .contains("idempotency_conflict")
    );
    assert_eq!(
        f.service
            .task(&op.task_id)
            .unwrap()
            .policy_snapshot
            .snapshot_hash,
        plan.snapshot_hash
    );
}

#[test]
fn partial_failure_retries_only_failed_repo() {
    let f = Fixture::new();
    let before = originals(&f.workspace);
    fs::write(f.home.join("api.fail"), "synthetic failure").unwrap();
    let op = f.execute(Mode::Materialize, "partial");
    assert_eq!(op.status, "partial_failure", "{op:?}");
    let ios = op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap();
    assert_eq!(ios.state, RepoState::Ready);
    assert_eq!(ios.attempts, 1);
    let successful_snapshot = git::snapshot(&ios.plan.worktree_path).unwrap();
    let api = op.repos.iter().find(|r| r.plan.repo_id == "api").unwrap();
    assert_eq!(api.error_code.as_deref(), Some("recipe_failed"));
    fs::remove_file(f.home.join("api.fail")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    let resumed = wait(&f.service, &op.id);
    assert_eq!(resumed.status, "ready", "{resumed:?}");
    assert_versions(&resumed);
    assert_eq!(
        resumed
            .repos
            .iter()
            .find(|r| r.plan.repo_id == "ios-app")
            .unwrap()
            .attempts,
        1
    );
    assert_eq!(
        successful_snapshot,
        git::snapshot(&ios.plan.worktree_path).unwrap()
    );
    assert_eq!(before, originals(&f.workspace));
}

#[test]
fn retry_preserves_user_progress_in_a_ready_repository() {
    let f = Fixture::new();
    let originals_before = originals(&f.workspace);
    fs::write(f.home.join("api.fail"), "synthetic failure").unwrap();
    let op = f.execute(Mode::Materialize, "retry-with-user-progress");
    assert_eq!(op.status, "partial_failure");
    let ios = op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap();
    let path = &ios.plan.worktree_path;
    let diff = f.rpc(
        "get_diff",
        json!({"repo_id":"ios-app","op_id":op.id,"path":"Config/Version.xcconfig"}),
    );
    let staged = f.rpc("stage_hunk", json!({"repo_id":"ios-app","op_id":op.id,"path":"Config/Version.xcconfig","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    f.rpc("commit", json!({"repo_id":"ios-app","op_id":op.id,"message":"Keep completed user progress","snapshot_hash":staged["view"]["snapshot_hash"]}));
    fs::write(path.join("notes.txt"), "user edit after commit\n").unwrap();
    fs::write(path.join("new draft.txt"), "untracked draft\n").unwrap();
    let user_progress = git::snapshot(path).unwrap();
    fs::remove_file(f.home.join("api.fail")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    let resumed = wait(&f.service, &op.id);
    assert_eq!(resumed.status, "ready", "{resumed:?}");
    let finished = resumed
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap();
    assert_eq!(finished.attempts, ios.attempts);
    assert_eq!(finished.result_snapshot, ios.result_snapshot);
    assert_eq!(git::snapshot(path).unwrap(), user_progress);
    assert_eq!(originals(&f.workspace), originals_before);
}

#[test]
fn task_path_alias_cannot_read_or_mutate_the_original_checkout() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "task-alias");
    assert_eq!(op.status, "ready");
    let repo = op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let original = git::snapshot(source).unwrap();
    fs::rename(
        &repo.plan.worktree_path,
        repo.plan.worktree_path.with_extension("moved"),
    )
    .unwrap();
    std::os::unix::fs::symlink(source, &repo.plan.worktree_path).unwrap();
    for (method, extra) in [
        ("get_repo_status", json!({})),
        ("get_diff", json!({"path":"notes.txt"})),
        (
            "stage_hunk",
            json!({"path":"notes.txt","hunk_index":0,"snapshot_hash":digest(&original).unwrap()}),
        ),
        (
            "commit",
            json!({"message":"Must never reach the original","snapshot_hash":digest(&original).unwrap()}),
        ),
    ] {
        let mut params = json!({"repo_id":"ios-app","op_id":op.id});
        params
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let response = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(
            response.error.unwrap().code,
            "unsafe_task_worktree",
            "{method}"
        );
    }
    assert_eq!(git::snapshot(source).unwrap(), original);
}

#[test]
fn repository_git_programs_do_not_run_without_a_trust_contract() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    let marker = f._temp.path().join("external-program-ran");
    let program = f._temp.path().join("untrusted-program");
    fs::write(
        &program,
        format!("#!/bin/sh\ntouch '{}'\n", marker.display()),
    )
    .unwrap();
    fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
    let hooks = f._temp.path().join("hooks");
    fs::create_dir(&hooks).unwrap();
    for name in [
        "pre-commit",
        "post-commit",
        "post-checkout",
        "reference-transaction",
    ] {
        fs::copy(&program, hooks.join(name)).unwrap();
    }
    for (key, value) in [
        ("core.fsmonitor", program.to_str().unwrap()),
        ("core.hooksPath", hooks.to_str().unwrap()),
        ("commit.gpgSign", "true"),
        ("gpg.program", program.to_str().unwrap()),
    ] {
        git::git(path, &["config", key, value]).unwrap();
    }
    f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    let op = f.execute(Mode::Materialize, "no-untrusted-git-programs");
    assert_eq!(op.status, "ready", "{op:?}");
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"}));
    let staged = f.rpc("stage_hunk", json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    f.rpc("commit", json!({"repo_id":"ios-app","message":"Synthetic safe commit","snapshot_hash":staged["view"]["snapshot_hash"]}));
    assert!(!marker.exists(), "monitor, hooks or signer executed");
    let safe_hash = digest(&git::snapshot(path).unwrap()).unwrap();
    git::git(
        path,
        &[
            "config",
            "filter.untrusted.clean",
            program.to_str().unwrap(),
        ],
    )
    .unwrap();
    fs::write(
        path.join(".git/info/attributes"),
        "notes.txt filter=untrusted\n",
    )
    .unwrap();
    fs::write(path.join("notes.txt"), "filter-sensitive dirty content\n").unwrap();
    for (method, params) in [
        ("get_repo_status", json!({"repo_id":"ios-app"})),
        ("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"})),
        (
            "stage_hunk",
            json!({"repo_id":"ios-app","path":"notes.txt","snapshot_hash":safe_hash,"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes()),"hunk_index":0}),
        ),
        (
            "commit",
            json!({"repo_id":"ios-app","message":"blocked","snapshot_hash":safe_hash}),
        ),
    ] {
        let response = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(response.error.unwrap().code, "unsupported_external_filter");
    }
    assert_eq!(
        f.service
            .plan(Fixture::request(Mode::Materialize, "filter-plan"))
            .unwrap_err()
            .to_string(),
        "unsupported_external_filter"
    );
    assert!(!marker.exists(), "filter program executed");
}

#[test]
fn configured_diff_prefixes_do_not_break_hunk_staging() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    git::git(path, &["config", "diff.noprefix", "true"]).unwrap();
    git::git(path, &["config", "diff.mnemonicPrefix", "true"]).unwrap();
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"}));
    assert_eq!(diff["can_stage_hunks"], true);
    let staged = f.rpc("stage_hunk", json!({"repo_id":"ios-app","path":"notes.txt","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    let diff = f.rpc(
        "get_diff",
        json!({"repo_id":"ios-app","path":"notes.txt","staged":true}),
    );
    assert_eq!(staged["view"]["snapshot_hash"], diff["snapshot_hash"]);
    f.rpc("stage_hunk", json!({"repo_id":"ios-app","path":"notes.txt","staged":true,"hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
}

#[test]
fn operation_rpc_payloads_are_bounded_independently_of_file_snapshots() {
    let f = Fixture::new();
    let mut op = f.execute(Mode::Materialize, "summary-payload");
    let files: std::collections::BTreeMap<_, _> = (0..5000)
        .map(|i| {
            (
                format!("synthetic/long/path/file-{i}.txt"),
                format!("file:644:{}", "a".repeat(64)),
            )
        })
        .collect();
    for repo in &mut op.repos {
        repo.plan.source_snapshot.files = files.clone();
        repo.baseline.as_mut().unwrap().files = files.clone();
        repo.result_snapshot.as_mut().unwrap().files = files.clone();
    }
    let db = rusqlite::Connection::open(f.home.join("journal.sqlite")).unwrap();
    for i in 0..10 {
        let mut entry = op.clone();
        entry.id = format!("synthetic-operation-{i}");
        entry.plan_id = format!("synthetic-plan-{i}");
        entry.idempotency_key = format!("synthetic-key-{i}");
        db.execute(
            "INSERT INTO operations(id,key,plan_id,body) VALUES(?1,?2,?3,?4)",
            rusqlite::params![
                entry.id,
                entry.idempotency_key,
                entry.plan_id,
                serde_json::to_string(&entry).unwrap()
            ],
        )
        .unwrap();
    }
    let summaries = f.rpc("list_operations", json!({}));
    assert!(serde_json::to_vec(&summaries).unwrap().len() < 128 * 1024);
    let decoded: Vec<Operation<SnapshotSummary>> = serde_json::from_value(summaries).unwrap();
    let summary = decoded
        .iter()
        .find(|o| o.id == "synthetic-operation-0")
        .unwrap();
    assert_eq!(
        summary.repos[0].baseline.as_ref().unwrap().files_count,
        5000
    );
    assert_eq!(
        summary.repos[0].plan.source_snapshot.snapshot_hash,
        digest(&op.repos[0].plan.source_snapshot).unwrap()
    );
    let retained = f.service.operation("synthetic-operation-0").unwrap();
    assert_eq!(retained.repos[0].baseline.as_ref().unwrap().files, files);
    let view = f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert!(view["snapshot"].get("files").is_none());
}

#[test]
fn ignored_recipe_output_is_detected_and_preserved() {
    let f = Fixture::new();
    let source = &f.workspace.repo("api").unwrap().path;
    let script = source.join("scripts/set_ios_version.py");
    let text = fs::read_to_string(&script).unwrap();
    fs::write(&script, format!("from pathlib import Path\nPath('ignored-evidence.log').write_text('undeclared output')\n{text}")).unwrap();
    git::git(source, &["add", "scripts/set_ios_version.py"]).unwrap();
    git::git(source, &["commit", "-m", "Synthetic ignored write"]).unwrap();
    git::git(source, &["branch", "-f", "release/2.4", "HEAD"]).unwrap();
    fs::write(source.join(".git/info/exclude"), "ignored-evidence.log\n").unwrap();
    fixtures::trust(&f.home.join("workspace.json"), "api.set-version@1").unwrap();
    let service = Service::open(
        load_workspace(&f.home.join("workspace.json")).unwrap(),
        &f.home.join("scope-test.sqlite"),
    )
    .unwrap();
    let plan = service
        .plan(Fixture::request(Mode::Materialize, "ignored-output"))
        .unwrap();
    let op = service.execute(&plan.id, "ignored-output").unwrap();
    let op = wait(&service, &op.id);
    assert_eq!(
        op.repos[0].error_code.as_deref(),
        Some("unexpected_changes")
    );
    assert_eq!(
        fs::read_to_string(op.repos[0].plan.worktree_path.join("ignored-evidence.log")).unwrap(),
        "undeclared output"
    );
}

#[test]
fn shutdown_and_mutation_contention_are_decided_by_the_service() {
    let f = Fixture::new();
    fs::write(f.home.join("api.sleep"), "1").unwrap();
    let plan = f
        .service
        .plan(Fixture::request(Mode::Materialize, "busy-control"))
        .unwrap();
    let op = f.service.execute(&plan.id, "busy-control").unwrap();
    let start = Instant::now();
    while !f
        .service
        .operation(&op.id)
        .unwrap()
        .repos
        .iter()
        .any(|r| r.state == RepoState::Preparing)
    {
        assert!(start.elapsed() < Duration::from_secs(5));
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(f.rpc("shutdown_if_idle", json!({}))["stopping"], false);
    for (method, params) in [
        (
            "plan_task",
            serde_json::to_value(Fixture::request(Mode::Materialize, "busy-plan")).unwrap(),
        ),
        (
            "commit",
            json!({"repo_id":"ios-app","message":"must not be queued","snapshot_hash":"unused"}),
        ),
    ] {
        let start = Instant::now();
        let response = f.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(response.error.unwrap().code, "repository_busy");
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    f.service.cancel(&op.id).unwrap();
    assert_eq!(wait(&f.service, &op.id).status, "cancelled");
    fs::remove_file(f.home.join("api.sleep")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    assert_eq!(wait(&f.service, &op.id).status, "ready");
    assert_eq!(f.rpc("shutdown_if_idle", json!({}))["stopping"], true);
    assert!(f.service.is_stopping());
    assert!(
        f.service
            .execute(&plan.id, "after-shutdown")
            .unwrap_err()
            .to_string()
            .contains("service_stopping")
    );
    let response = f.service.dispatch(Request {
        method: "commit".into(),
        params: json!({"repo_id":"ios-app"}),
    });
    assert_eq!(response.error.unwrap().code, "service_stopping");
}

#[test]
fn existing_checkout_recovery_rejects_common_and_worktree_specific_filters() {
    use std::os::unix::fs::PermissionsExt;
    for local_to_worktree in [false, true] {
        let f = Fixture::new();
        let op = f.execute(Mode::BranchOnly, "existing-filter");
        let repo = &op.repos[0];
        let source = &f.workspace.repo(&repo.plan.repo_id).unwrap().path;
        fs::create_dir_all(repo.plan.worktree_path.parent().unwrap()).unwrap();
        git::git(
            source,
            &[
                "worktree",
                "add",
                repo.plan.worktree_path.to_str().unwrap(),
                repo.plan.branch_ref.strip_prefix("refs/heads/").unwrap(),
            ],
        )
        .unwrap();
        let marker = f._temp.path().join("filter-executed");
        let program = f._temp.path().join("clean-filter");
        fs::write(
            &program,
            format!("#!/bin/sh\ntouch '{}'\ncat\n", marker.display()),
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(
            source.join(".git/info/attributes"),
            "notes.txt filter=untrusted\n",
        )
        .unwrap();
        if local_to_worktree {
            git::git(source, &["config", "extensions.worktreeConfig", "true"]).unwrap();
            git::git(
                &repo.plan.worktree_path,
                &[
                    "config",
                    "--worktree",
                    "filter.untrusted.clean",
                    program.to_str().unwrap(),
                ],
            )
            .unwrap();
        } else {
            git::git(
                source,
                &[
                    "config",
                    "filter.untrusted.clean",
                    program.to_str().unwrap(),
                ],
            )
            .unwrap();
        }
        let notes = repo.plan.worktree_path.join("notes.txt");
        let mut data = fs::read(&notes).unwrap();
        data[0] ^= 1;
        fs::write(notes, data).unwrap();
        f.service.resume(&op.id, true).unwrap();
        let resumed = wait(&f.service, &op.id);
        assert_eq!(
            resumed.repos[0].error_code.as_deref(),
            Some("unsupported_external_filter")
        );
        assert!(
            !marker.exists(),
            "filter executed during existing-checkout recovery"
        );
    }
}

#[test]
fn shutdown_checks_queued_work_outside_the_display_page() {
    let f = Fixture::new();
    let op = f.execute(Mode::BranchOnly, "shutdown-page");
    let db = rusqlite::Connection::open(f.home.join("journal.sqlite")).unwrap();
    for i in 0..101 {
        let mut record = op.clone();
        record.id = format!("page-{i}");
        record.plan_id = format!("page-plan-{i}");
        record.idempotency_key = format!("page-key-{i}");
        record.status = if i == 0 { "queued" } else { "ready" }.into();
        db.execute(
            "INSERT INTO operations(id,key,plan_id,body) VALUES(?1,?2,?3,?4)",
            rusqlite::params![
                record.id,
                record.idempotency_key,
                record.plan_id,
                serde_json::to_string(&record).unwrap()
            ],
        )
        .unwrap();
    }
    assert!(
        !f.service
            .operations()
            .unwrap()
            .iter()
            .any(|o| o.status == "queued")
    );
    assert_eq!(f.rpc("shutdown_if_idle", json!({}))["stopping"], false);
    db.execute(
        "UPDATE operations SET body=json_set(body,'$.status','ready') WHERE id='page-0'",
        [],
    )
    .unwrap();
    assert_eq!(f.rpc("shutdown_if_idle", json!({}))["stopping"], true);
}

#[test]
fn intent_to_add_empty_file_is_distinct_from_a_reviewed_staged_addition() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    git::git(source, &["add", "notes.txt"]).unwrap();
    fs::write(source.join("empty.txt"), "").unwrap();
    git::git(source, &["add", "-N", "empty.txt"]).unwrap();
    let reviewed = git::snapshot(source).unwrap();
    let original_head = reviewed.head.clone();
    git::git(source, &["add", "empty.txt"]).unwrap();
    assert_ne!(
        reviewed.index_hash,
        git::snapshot(source).unwrap().index_hash
    );
    let response = f.service.dispatch(Request { method: "commit".into(), params: json!({
        "repo_id":"ios-app", "message":"Must reject external extra file", "snapshot_hash":digest(&reviewed).unwrap()
    }) });
    assert_eq!(response.error.unwrap().code, "stale_snapshot");
    assert_eq!(git::oid(source, "HEAD").unwrap(), original_head);
}

#[test]
fn reviewed_hunk_preserves_whitespace_despite_repository_apply_policy() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    fs::write(
        source.join("notes.txt"),
        b"baseline trailing whitespace   \nsecond baseline\t \n",
    )
    .unwrap();
    git::git(source, &["add", "notes.txt"]).unwrap();
    git::git(source, &["commit", "-m", "Synthetic whitespace baseline"]).unwrap();
    git::git(source, &["config", "apply.whitespace", "fix"]).unwrap();
    let reviewed = b"reviewed line with trailing spaces   \nsecond line\t \n";
    fs::write(source.join("notes.txt"), reviewed).unwrap();
    let before = git::git_bytes(source, &["show", ":notes.txt"]).unwrap();
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app", "path":"notes.txt"}));
    f.rpc("stage_hunk", json!({"repo_id":"ios-app", "path":"notes.txt", "hunk_index":0, "snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    assert_eq!(
        git::git_bytes(source, &["show", ":notes.txt"]).unwrap(),
        reviewed
    );
    assert_eq!(fs::read(source.join("notes.txt")).unwrap(), reviewed);
    let staged = f.rpc(
        "get_diff",
        json!({"repo_id":"ios-app", "path":"notes.txt", "staged":true}),
    );
    f.rpc("stage_hunk", json!({"repo_id":"ios-app", "path":"notes.txt", "hunk_index":0, "staged":true, "snapshot_hash":staged["snapshot_hash"],"diff_hash":hash(staged["text"].as_str().unwrap().as_bytes())}));
    assert_eq!(
        git::git_bytes(source, &["show", ":notes.txt"]).unwrap(),
        before
    );
    assert_eq!(fs::read(source.join("notes.txt")).unwrap(), reviewed);
}

#[test]
fn index_stat_refresh_does_not_invalidate_a_pinned_plan() {
    let f = Fixture::new();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let plan = f
        .service
        .plan(Fixture::request(Mode::Materialize, "index-cache-only"))
        .unwrap();
    let before = git::snapshot(source).unwrap();
    let raw_before = fs::read(source.join(".git/index")).unwrap();
    fs::File::open(source.join("Config/Version.xcconfig"))
        .unwrap()
        .set_times(
            fs::FileTimes::new()
                .set_modified(std::time::SystemTime::now() + Duration::from_secs(5)),
        )
        .unwrap();
    // An external Git client updates index stat metadata; dirty fixture files make exit 1 valid.
    let status = std::process::Command::new("git")
        .current_dir(source)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["-c", "core.fsmonitor=false", "update-index", "--refresh"])
        .output()
        .unwrap()
        .status;
    assert!(matches!(status.code(), Some(0 | 1)));
    assert_ne!(raw_before, fs::read(source.join(".git/index")).unwrap());
    assert_eq!(before, git::snapshot(source).unwrap());
    let op = f.service.execute(&plan.id, "index-cache-only").unwrap();
    assert_eq!(wait(&f.service, &op.id).status, "ready");
}

#[test]
fn task_git_control_file_cannot_be_replaced_with_original_metadata() {
    let f = Fixture::new();
    let op = f.execute(Mode::Materialize, "metadata-alias");
    let repo = op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap();
    let source = &f.workspace.repo("ios-app").unwrap().path;
    let before = git::snapshot(source).unwrap();
    let control = repo.plan.worktree_path.join(".git");
    fs::rename(&control, control.with_extension("saved")).unwrap();
    std::os::unix::fs::symlink(source.join(".git"), &control).unwrap();
    let response = f.service.dispatch(Request {
        method: "get_repo_status".into(),
        params: json!({"repo_id":"ios-app","op_id":op.id}),
    });
    assert_eq!(response.error.unwrap().code, "unsafe_task_worktree");
    assert_eq!(before, git::snapshot(source).unwrap());
}

#[test]
fn escaped_recipe_descendant_cannot_keep_output_drain_blocked() {
    let f = Fixture::new();
    let source = &f.workspace.repo("api").unwrap().path;
    let script = source.join("scripts/set_ios_version.py");
    let pid_file = f._temp.path().join("synthetic-descendant.pid");
    fs::write(&script, format!("import subprocess, sys\nfrom pathlib import Path\np = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'], start_new_session=True)\nPath({:?}).write_text(str(p.pid))\n", pid_file.to_str().unwrap())).unwrap();
    fixtures::trust(&f.home.join("workspace.json"), "api.set-version@1").unwrap();
    let workspace = load_workspace(&f.home.join("workspace.json")).unwrap();
    let start = Instant::now();
    let result = workbench_runner::run(
        workspace.recipe("api.set-version@1").unwrap(),
        source,
        &IosInputs {
            marketing_version: "2.4.0".into(),
            local_build: "241".into(),
        },
        Arc::new(std::sync::atomic::AtomicBool::new(false)),
    );
    // Only this probe's just-created detached child is cleaned up.
    let pid: i32 = fs::read_to_string(pid_file).unwrap().parse().unwrap();
    if start.elapsed() < Duration::from_secs(8) {
        std::process::Command::new("/bin/kill")
            .args(["-KILL", &pid.to_string()])
            .status()
            .unwrap();
    }
    result.unwrap();
    assert!(
        start.elapsed() < Duration::from_secs(2),
        "escaped pipe delayed recipe completion"
    );
}

#[test]
fn concurrent_lost_responses_return_one_operation() {
    let f = Fixture::new();
    let plan = f
        .service
        .plan(Fixture::request(Mode::Materialize, "concurrent"))
        .unwrap();
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let service = f.service.clone();
            let plan_id = plan.id.clone();
            thread::spawn(move || service.execute(&plan_id, "shared-request").unwrap().id)
        })
        .collect();
    let ids: Vec<_> = workers.into_iter().map(|h| h.join().unwrap()).collect();
    assert!(ids.iter().all(|id| id == &ids[0]));
    let op = wait(&f.service, &ids[0]);
    assert_eq!(op.status, "ready", "{op:?}");
    assert!(op.repos.iter().all(|r| r.attempts == 1));
    assert_versions(&op);
}

#[test]
fn cancellation_racing_preparation_never_strands_running_rows_or_reopens_ready() {
    let f = Fixture::new();
    let before = originals(&f.workspace);
    for index in 0..8 {
        let slug = format!("cancel-race-{index}");
        let plan = f
            .service
            .plan(Fixture::request(Mode::Materialize, &slug))
            .unwrap();
        let created = f.service.execute(&plan.id, &slug).unwrap();
        let service = f.service.clone();
        let id = created.id.clone();
        let canceller = thread::spawn(move || {
            // Different arrival points exercise cancellation during materialization and recipes.
            thread::sleep(Duration::from_millis(index * 20));
            let _ = service.cancel(&id);
        });
        let completed = wait(&f.service, &created.id);
        canceller.join().unwrap();
        let durable = f.service.operation(&created.id).unwrap();
        assert!(
            !matches!(durable.status.as_str(), "queued" | "running"),
            "{durable:?}"
        );
        assert_eq!(durable.status, completed.status);
        if durable.repos.iter().all(|r| r.state == RepoState::Ready) {
            assert_eq!(durable.status, "ready");
        }
    }
    assert_eq!(before, originals(&f.workspace));
    assert_eq!(f.rpc("shutdown_if_idle", json!({}))["stopping"], true);
}

#[test]
fn stale_source_and_foreign_branch_are_preserved() {
    let f = Fixture::new();
    let plan = f
        .service
        .plan(Fixture::request(Mode::Materialize, "stale"))
        .unwrap();
    let first = f.workspace.repo(&plan.repos[0].repo_id).unwrap();
    fs::write(
        first.path.join("local-only.txt"),
        "external edit after planning",
    )
    .unwrap();
    let created = f.service.execute(&plan.id, "stale").unwrap();
    let op = wait(&f.service, &created.id);
    assert_eq!(
        op.repos[0].error_code.as_deref(),
        Some("stale_source_snapshot")
    );
    assert!(!git::ref_exists(&first.path, &plan.repos[0].branch_ref).unwrap());
    assert_eq!(
        fs::read_to_string(first.path.join("local-only.txt")).unwrap(),
        "external edit after planning"
    );
    let plan = f
        .service
        .plan(Fixture::request(Mode::BranchOnly, "collision"))
        .unwrap();
    let repo = f.workspace.repo(&plan.repos[0].repo_id).unwrap();
    git::git(&repo.path, &["branch", "feature/2.4/collision"]).unwrap();
    let op = f.service.execute(&plan.id, "collision").unwrap();
    let op = wait(&f.service, &op.id);
    assert_eq!(op.repos[0].error_code.as_deref(), Some("branch_collision"));
}

#[test]
fn cancellation_and_timeout_preserve_worktrees_then_resume_fixed_inputs() {
    let f = Fixture::new();
    fs::write(f.home.join("api.sleep"), "sleep").unwrap();
    let plan = f
        .service
        .plan(Fixture::request(Mode::Materialize, "cancel"))
        .unwrap();
    let created = f.service.execute(&plan.id, "cancel").unwrap();
    let start = Instant::now();
    loop {
        let op = f.service.operation(&created.id).unwrap();
        if op.repos[0].state == RepoState::Preparing {
            break;
        }
        assert!(matches!(op.status.as_str(), "queued" | "running"), "{op:?}");
        assert!(start.elapsed() < Duration::from_secs(8));
        thread::sleep(Duration::from_millis(10));
    }
    let read_start = Instant::now();
    let live = f.rpc("get_repo_status", json!({"repo_id":"ios-app"}));
    assert!(live["snapshot_hash"].is_string());
    assert!(
        read_start.elapsed() < Duration::from_secs(2),
        "reads waited behind recipe process"
    );
    f.service.cancel(&created.id).unwrap();
    let op = wait(&f.service, &created.id);
    assert_eq!(op.status, "cancelled");
    assert!(op.repos[0].plan.worktree_path.exists());
    fs::remove_file(f.home.join("api.sleep")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    let op = wait(&f.service, &op.id);
    assert_eq!(op.status, "ready", "{op:?}");
    fs::write(f.home.join("api.sleep"), "sleep").unwrap();
    let timeout = f.execute(Mode::Materialize, "timeout");
    assert_eq!(timeout.status, "partial_failure");
    assert_eq!(
        timeout.repos[0].error_code.as_deref(),
        Some("recipe_timeout")
    );
    assert!(timeout.repos[0].plan.worktree_path.exists());
}

#[test]
fn locked_worktree_blocks_preparation_then_resumes_after_unlock() {
    let f = Fixture::new();
    fs::write(f.home.join("api.fail"), "fail").unwrap();
    let op = f.execute(Mode::Materialize, "locked");
    let api = &op.repos[0].plan.worktree_path;
    git::git(
        &f.workspace.repo("api").unwrap().path,
        &["worktree", "lock", api.to_str().unwrap()],
    )
    .unwrap();
    fs::remove_file(f.home.join("api.fail")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    let locked = wait(&f.service, &op.id);
    assert_eq!(
        locked.repos[0].error_code.as_deref(),
        Some("worktree_locked")
    );
    assert_eq!(locked.repos[0].attempts, 1);
    git::git(
        &f.workspace.repo("api").unwrap().path,
        &["worktree", "unlock", api.to_str().unwrap()],
    )
    .unwrap();
    f.service.resume(&op.id, false).unwrap();
    let ready = wait(&f.service, &op.id);
    assert_eq!(ready.status, "ready", "{ready:?}");
    assert_eq!(ready.repos[1].attempts, 1);
}

#[test]
fn hunk_stage_unstage_commit_uses_snapshot_and_preserves_unselected_edits() {
    let f = Fixture::new();
    let path = &f.workspace.repo("ios-app").unwrap().path;
    let mut lines: Vec<_> = (1..=40).map(|n| format!("line {n}\n")).collect();
    lines[2] = "selected first edit\n".into();
    lines[32] = "unselected second edit\n".into();
    fs::write(path.join("notes.txt"), lines.concat()).unwrap();
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"}));
    assert_eq!(diff["hunks"].as_array().unwrap().len(), 2);
    let stage = json!({"repo_id":"ios-app","path":"notes.txt","staged":false,"hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())});
    f.rpc("stage_hunk", stage.clone());
    let index = git::git(path, &["show", ":notes.txt"]).unwrap();
    assert!(index.contains("selected first edit"));
    assert!(!index.contains("unselected second edit"));
    let rejected = f.service.dispatch(Request {
        method: "stage_hunk".into(),
        params: stage,
    });
    assert_eq!(rejected.error.unwrap().code, "stale_snapshot");
    let diff = f.rpc(
        "get_diff",
        json!({"repo_id":"ios-app","path":"notes.txt","staged":true}),
    );
    f.rpc("stage_hunk",json!({"repo_id":"ios-app","path":"notes.txt","staged":true,"hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    assert!(
        git::git_bytes(path, &["diff", "--cached"])
            .unwrap()
            .is_empty()
    );
    let diff = f.rpc("get_diff", json!({"repo_id":"ios-app","path":"notes.txt"}));
    let staged=f.rpc("stage_hunk",json!({"repo_id":"ios-app","path":"notes.txt","staged":false,"hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":hash(diff["text"].as_str().unwrap().as_bytes())}));
    f.rpc("commit",json!({"repo_id":"ios-app","message":"Stage only the selected hunk","snapshot_hash":staged["view"]["snapshot_hash"]}));
    let committed = git::git(path, &["show", "HEAD:notes.txt"]).unwrap();
    assert!(committed.contains("selected first edit"));
    assert!(!committed.contains("unselected second edit"));
    assert!(
        fs::read_to_string(path.join("notes.txt"))
            .unwrap()
            .contains("unselected second edit")
    );
    assert!(path.join("local-only.txt").exists());
}

#[test]
fn untrusted_and_changed_recipe_and_invalid_group_inputs_are_rejected() {
    let f = Fixture::new();
    let mut workspace = f.workspace.clone();
    workspace.recipes[0].trusted_hash = None;
    let service = Service::open(workspace, &f.home.join("untrusted.sqlite")).unwrap();
    assert!(
        service
            .plan(Fixture::request(Mode::Materialize, "untrusted"))
            .unwrap_err()
            .to_string()
            .contains("untrusted_recipe")
    );
    let path = &f.workspace.repo("api").unwrap().path;
    fs::write(path.join("scripts/set_ios_version.py"), "print('changed')").unwrap();
    assert!(
        f.service
            .plan(Fixture::request(Mode::Materialize, "changed"))
            .unwrap_err()
            .to_string()
            .contains("untrusted_recipe")
    );
    for slug in ["../escape", "x/y", "-x", "a;echo"] {
        assert!(
            f.service
                .plan(Fixture::request(Mode::Materialize, slug))
                .is_err()
        );
    }
    let mut workspace = f.workspace.clone();
    workspace.groups[0].parent_group_id = Some("ios-2-4".into());
    assert!(
        workspace
            .validate()
            .unwrap_err()
            .to_string()
            .contains("cyclic_group")
    );
    let mut workspace = f.workspace.clone();
    workspace.templates[0].repos.get_mut("api").unwrap().recipe = Some("unknown".into());
    assert!(workspace.validate().is_err());
}

#[test]
fn symlinked_write_target_and_external_drift_block_retry() {
    let f = Fixture::new();
    fs::write(f.home.join("api.fail"), "fail").unwrap();
    let op = f.execute(Mode::Materialize, "drift");
    let path = &op.repos[0].plan.worktree_path;
    fs::write(path.join("notes.txt"), "external edit while failed").unwrap();
    fs::remove_file(f.home.join("api.fail")).unwrap();
    f.service.resume(&op.id, false).unwrap();
    let resumed = wait(&f.service, &op.id);
    assert_eq!(
        resumed.repos[0].error_code.as_deref(),
        Some("stale_snapshot")
    );
    assert_eq!(resumed.repos[0].attempts, 1);
    let external = f.home.join("external.xcconfig");
    fs::write(&external, "untouched").unwrap();
    let config = f
        .workspace
        .repo("api")
        .unwrap()
        .path
        .join("Config/Version.xcconfig");
    fs::remove_file(&config).unwrap();
    std::os::unix::fs::symlink(&external, &config).unwrap();
    assert!(
        f.service
            .plan(Fixture::request(Mode::Materialize, "symlink"))
            .is_err()
    );
    assert_eq!(fs::read_to_string(external).unwrap(), "untouched");
}

#[test]
fn journal_reconciles_lost_completion_without_reexecuting_script() {
    let temp = TempDir::new().unwrap();
    let home = temp.path().join("crash-fixture");
    fixtures::create(&home).unwrap();
    for id in ["api.set-version@1", "ios-app.set-version@1"] {
        fixtures::trust(&home.join("workspace.json"), id).unwrap();
    }
    let workspace = load_workspace(&home.join("workspace.json")).unwrap();
    let db = home.join("journal.sqlite");
    let service = Service::open(workspace.clone(), &db).unwrap();
    let plan = service
        .plan(Fixture::request(Mode::Materialize, "crash"))
        .unwrap();
    let op = service.execute(&plan.id, "lost-response").unwrap();
    let mut op = wait(&service, &op.id);
    assert_eq!(op.status, "ready");
    // Fault injection at the durable boundary: side effects exist; completion checkpoint was lost.
    op.status = "running".into();
    for r in &mut op.repos {
        r.state = RepoState::Preparing;
        r.result_snapshot = None;
        r.postcondition = None;
    }
    drop(service);
    thread::sleep(Duration::from_millis(50));
    let connection = rusqlite::Connection::open(&db).unwrap();
    connection
        .execute(
            "UPDATE operations SET body=?1 WHERE id=?2",
            rusqlite::params![serde_json::to_string(&op).unwrap(), op.id],
        )
        .unwrap();
    drop(connection);
    fs::write(home.join("api.fail"), "would fail if reexecuted").unwrap();
    fs::write(home.join("ios-app.fail"), "would fail if reexecuted").unwrap();
    let service = Service::open(workspace, &db).unwrap();
    assert_eq!(service.operation(&op.id).unwrap().status, "needs_recovery");
    service.resume(&op.id, false).unwrap();
    let resumed = wait(&service, &op.id);
    assert_eq!(resumed.status, "ready", "{resumed:?}");
    assert!(resumed.repos.iter().all(|r| r.attempts == 1));
    assert_versions(&resumed);
    assert_eq!(
        service.execute(&plan.id, "lost-response").unwrap().id,
        op.id
    );
}

#[test]
fn no_recipe_recovery_keeps_the_observed_preparation_snapshot_scope() {
    let f = Fixture::new();
    let mut workspace = f.workspace.clone();
    workspace.recipes.clear();
    for template in &mut workspace.templates {
        for policy in template.repos.values_mut() {
            policy.recipe = None;
        }
    }
    let database = f.home.join("no-recipe.sqlite");
    let service = Service::open(workspace, &database).unwrap();
    let plan = service
        .plan(Fixture::request(Mode::Materialize, "no-recipe-scope"))
        .unwrap();
    let created = service.execute(&plan.id, "no-recipe-scope").unwrap();
    let mut op = wait(&service, &created.id);
    assert_eq!(op.status, "ready");
    let worktree = &op.repos[0].plan.worktree_path;
    fs::write(
        git::common_dir(worktree).unwrap().join("info/exclude"),
        ".observed-ignored\n",
    )
    .unwrap();
    fs::write(
        worktree.join(".observed-ignored"),
        "present at the stored observation\n",
    )
    .unwrap();
    let observed = git::preparation_snapshot(worktree).unwrap();
    assert!(observed.files.contains_key(".observed-ignored"));
    // Fault-inject an existing failed-finalization checkpoint, with no subsequent user drift.
    op.status = "needs_recovery".into();
    op.repos[0].state = RepoState::NeedsRecovery;
    op.repos[0].result_snapshot = Some(observed.clone());
    rusqlite::Connection::open(database)
        .unwrap()
        .execute(
            "UPDATE operations SET body=?1 WHERE id=?2",
            rusqlite::params![serde_json::to_string(&op).unwrap(), op.id],
        )
        .unwrap();
    service.resume(&op.id, true).unwrap();
    let recovered = wait(&service, &op.id);
    assert_eq!(recovered.status, "ready", "{recovered:?}");
    assert_eq!(recovered.repos[0].result_snapshot.as_ref(), Some(&observed));
}

#[test]
fn undeclared_script_changes_stop_and_preserve_evidence() {
    let temp = TempDir::new().unwrap();
    let home = temp.path().join("scope");
    fixtures::create(&home).unwrap();
    let config = home.join("workspace.json");
    let workspace: Workspace = serde_json::from_slice(&fs::read(&config).unwrap()).unwrap();
    let api = &workspace.repo("api").unwrap().path;
    let script = api.join("scripts/set_ios_version.py");
    let source = fs::read_to_string(&script).unwrap();
    fs::write(&script,format!("from pathlib import Path\nPath('undeclared.txt').write_text('preserved evidence')\n{source}")).unwrap();
    git::git(api, &["add", "scripts/set_ios_version.py"]).unwrap();
    git::git(api, &["commit", "-m", "Synthetic scope violation"]).unwrap();
    git::git(api, &["branch", "-f", "release/2.4", "HEAD"]).unwrap();
    for id in ["api.set-version@1", "ios-app.set-version@1"] {
        fixtures::trust(&config, id).unwrap();
    }
    let service = Service::open(
        load_workspace(&config).unwrap(),
        &home.join("journal.sqlite"),
    )
    .unwrap();
    let plan = service
        .plan(Fixture::request(Mode::Materialize, "scope"))
        .unwrap();
    let op = service.execute(&plan.id, "scope").unwrap();
    let op = wait(&service, &op.id);
    assert_eq!(
        op.repos[0].error_code.as_deref(),
        Some("unexpected_changes")
    );
    assert_eq!(
        fs::read_to_string(op.repos[0].plan.worktree_path.join("undeclared.txt")).unwrap(),
        "preserved evidence"
    );
    service.resume(&op.id, false).unwrap();
    let op = wait(&service, &op.id);
    assert_eq!(op.repos[0].attempts, 1);
}

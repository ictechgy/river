use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use workbench_domain::*;
use workbench_git as git;
use workbench_service::{Request, Service, fixtures, load_workspace};

struct Fixture {
    _temp: TempDir,
    home: PathBuf,
    workspace: Workspace,
    service: Arc<Service>,
}
impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let home = temp.path().join("workflow fixture");
        fixtures::create(&home).unwrap();
        for recipe in ["api.set-version@1", "ios-app.set-version@1"] {
            fixtures::trust(&home.join("workspace.json"), recipe).unwrap();
        }
        let workspace = load_workspace(&home.join("workspace.json")).unwrap();
        let service = Service::open(workspace.clone(), &home.join("journal.sqlite")).unwrap();
        Self {
            _temp: temp,
            home,
            workspace,
            service,
        }
    }
    fn rpc(&self, method: &str, params: Value) -> Value {
        rpc(&self.service, method, params)
    }
    fn reject(&self, method: &str, params: Value, code: &str) {
        let response = self.service.dispatch(Request {
            method: method.into(),
            params,
        });
        assert_eq!(response.error.unwrap().code, code);
    }
    fn get(&self, repo: &str) -> Value {
        self.rpc("get_task_workflow", json!({"repo_id":repo}))
    }
    fn legacy(&self, criteria: Value) -> Value {
        self.rpc("save_task_context",json!({"repo_id":"ios-app","expected_revision":0,"purpose":"ship safely","criteria":criteria,
            "references":["docs/spec.md"],"notes":"legacy notes"}))
    }
    fn snapshot(&self, repo: &str) -> String {
        digest(&git::snapshot(&self.workspace.repo(repo).unwrap().path).unwrap()).unwrap()
    }
    fn report(&self, bundle: &Value, ids: Value) -> Value {
        json!({"repo_id":"ios-app","expected_context_revision":bundle["context"]["revision"],"expected_workflow_revision":bundle["workflow"]["revision"],
            "snapshot_hash":self.snapshot("ios-app"),"kind":"ai_report","verdict":"passed","command":"external review",
            "note":"reviewer reports passing","criterion_ids":ids,"claimed_reviewed_state":null,"provider":"provider","model":"model",
            "artifacts":["reports/review.txt"],"report_status":"completed"})
    }
    fn rows(&self, table: &str) -> Vec<String> {
        let db = Connection::open(self.home.join("journal.sqlite")).unwrap();
        let mut s = db
            .prepare(&format!("SELECT body FROM {table} ORDER BY rowid"))
            .unwrap();
        s.query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }
}
fn rpc(service: &Arc<Service>, method: &str, params: Value) -> Value {
    let response = service.dispatch(Request {
        method: method.into(),
        params,
    });
    assert!(response.error.is_none(), "{}: {:?}", method, response.error);
    response.result.unwrap()
}
fn save(bundle: &Value, criteria: Value) -> Value {
    json!({"repo_id":"ios-app","expected_context_revision":bundle["context"]["revision"],"expected_workflow_revision":bundle["workflow"]["revision"],
        "purpose":bundle["context"]["purpose"],"criteria":criteria,"references":bundle["context"]["references"],"notes":bundle["context"]["notes"],
        "guides":bundle["workflow"]["guides"]})
}
fn criteria(bundle: &Value) -> Value {
    json!(
        bundle["workflow"]["criteria"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| json!({"id":c["id"],"text":c["text"]}))
            .collect::<Vec<_>>()
    )
}
fn fresh_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn reopen(workspace: Workspace, path: &std::path::Path) -> Arc<Service> {
    let start = Instant::now();
    loop {
        match Service::open(workspace.clone(), path) {
            Ok(s) => return s,
            Err(e)
                if e.to_string() == "service_already_running"
                    && start.elapsed() < Duration::from_secs(2) =>
            {
                thread::sleep(Duration::from_millis(5))
            }
            Err(e) => panic!("reopen: {e}"),
        }
    }
}

#[test]
fn migration_keeps_duplicate_identities_and_legacy_json_across_reopen() {
    let f = Fixture::new();
    f.legacy(json!(["same", "same", "different"]));
    f.rpc("record_verification_report",json!({"repo_id":"ios-app","kind":"human_report","verdict":"failed","command":"old review","note":"old failure"}));
    let context_before = f.rows("task_contexts");
    let receipts_before = f.rows("verification_receipts");
    assert_eq!(
        f.rpc("get_task_context", json!({"repo_id":"ios-app"}))["workflow_version"],
        2
    );
    // Ordinary legacy reads advertise capability without migrating the scope.
    let db = Connection::open(f.home.join("journal.sqlite")).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM workflow_states", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(db);
    let migrated = f.get("ios-app");
    let rows = migrated["workflow"]["criteria"].as_array().unwrap();
    assert_ne!(rows[0]["id"], rows[1]["id"]);
    assert_eq!(rows[0]["revision"], 1);
    assert_eq!(rows[1]["revision"], 1);
    assert!(migrated["evidence"].as_array().unwrap().is_empty());
    assert_eq!(f.rows("task_contexts"), context_before);
    assert_eq!(f.rows("verification_receipts"), receipts_before);
    let path = f.home.join("journal.sqlite");
    let workspace = f.workspace.clone();
    drop(f.service);
    let service = reopen(workspace, &path);
    let reopened = rpc(&service, "get_task_workflow", json!({"repo_id":"ios-app"}));
    assert_eq!(migrated["workflow"], reopened["workflow"]);
    assert_eq!(reopened["verifications"][0]["verdict"], "failed");
    let db = Connection::open(path).unwrap();
    let persisted: String = db
        .query_row("SELECT body FROM verification_receipts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(persisted, receipts_before[0]);
}

#[test]
fn reorder_edit_duplicate_and_delete_preserve_bindings_and_retired_ids() {
    let f = Fixture::new();
    f.legacy(json!(["first", "second"]));
    let initial = f.get("ios-app");
    let first = initial["workflow"]["criteria"][0]["id"].clone();
    let second = initial["workflow"]["criteria"][1]["id"].clone();
    f.rpc("record_workflow_report", f.report(&initial, json!([first])));
    let receipt_bytes = f.rows("verification_receipts");
    let evidence_bytes = f.rows("workflow_evidence");
    let reordered = f.rpc(
        "save_task_workflow",
        save(
            &initial,
            json!([{"id":second,"text":"second"},{"id":first,"text":"first"}]),
        ),
    );
    assert_eq!(reordered["workflow"]["criteria"][1]["revision"], 1);
    assert_ne!(
        reordered["context"]["requirements_hash"],
        initial["context"]["requirements_hash"]
    );
    assert_eq!(
        reordered["workflow"]["intent_hash"],
        initial["workflow"]["intent_hash"]
    );
    let new = fresh_id();
    let edited=f.rpc("save_task_workflow",save(&reordered,json!([{"id":second,"text":"edited"},{"id":first,"text":"first"},{"id":new,"text":"first"}])));
    assert_eq!(edited["workflow"]["criteria"][0]["revision"], 2);
    assert_eq!(edited["workflow"]["criteria"][1]["revision"], 1);
    assert_eq!(edited["evidence"][0]["criteria"][0]["id"], first);
    assert_eq!(edited["evidence"][0]["criteria"][0]["revision"], 1);
    let deleted = f.rpc(
        "save_task_workflow",
        save(
            &edited,
            json!([{"id":second,"text":"edited"},{"id":new,"text":"first"}]),
        ),
    );
    assert_eq!(deleted["workflow"]["retired_count"], 1);
    let mut restore = criteria(&deleted).as_array().unwrap().clone();
    restore.push(json!({"id":first,"text":"new meaning"}));
    f.reject(
        "save_task_workflow",
        save(&deleted, json!(restore)),
        "workflow_retired_or_foreign_id",
    );
    assert_eq!(f.rows("verification_receipts"), receipt_bytes);
    assert_eq!(f.rows("workflow_evidence"), evidence_bytes);
    assert_eq!(f.get("ios-app")["workflow"], deleted["workflow"]);
}

#[test]
fn stale_saves_reports_and_foreign_or_duplicate_ids_leave_no_partial_rows() {
    let f = Fixture::new();
    f.legacy(json!(["first"]));
    let initial = f.get("ios-app");
    let foreign = f.get("api");
    let foreign = f.rpc("save_task_workflow", {
        let mut p = save(&foreign, json!([{"id":fresh_id(),"text":"api condition"}]));
        p["repo_id"] = json!("api");
        p
    });
    let foreign_id = foreign["workflow"]["criteria"][0]["id"].clone();
    let current = f.rpc("save_task_workflow", save(&initial, criteria(&initial)));
    let context_before = f.rows("task_contexts");
    let history_before = f.rows("workflow_versions");
    f.reject(
        "save_task_workflow",
        save(&initial, json!([{"id":fresh_id(),"text":"stale"}])),
        "workflow_conflict",
    );
    f.reject(
        "record_workflow_report",
        f.report(&initial, json!([initial["workflow"]["criteria"][0]["id"]])),
        "workflow_conflict",
    );
    f.reject(
        "save_task_workflow",
        save(&current, json!([{"id":foreign_id,"text":"wrong scope"}])),
        "workflow_retired_or_foreign_id",
    );
    let id = current["workflow"]["criteria"][0]["id"].clone();
    f.reject(
        "save_task_workflow",
        save(&current, json!([{"id":id,"text":"a"},{"id":id,"text":"b"}])),
        "invalid_workflow_criteria",
    );
    f.reject(
        "record_workflow_report",
        f.report(&current, json!([fresh_id()])),
        "unknown_workflow_criterion",
    );
    assert_eq!(f.rows("task_contexts"), context_before);
    assert_eq!(f.rows("workflow_versions"), history_before);
    assert!(f.rows("verification_receipts").is_empty());
    assert!(f.rows("workflow_evidence").is_empty());
}

#[test]
fn concurrent_saves_commit_one_projection_history_and_id_registry_atomically() {
    let f = Fixture::new();
    f.legacy(json!(["first"]));
    let initial = f.get("ios-app");
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let mut threads = Vec::new();
    for label in ["writer one", "writer two"] {
        let service = f.service.clone();
        let barrier = barrier.clone();
        let request = save(&initial, json!([{"id":fresh_id(),"text":label}]));
        threads.push(thread::spawn(move || {
            barrier.wait();
            service.dispatch(Request {
                method: "save_task_workflow".into(),
                params: request,
            })
        }));
    }
    let responses: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(responses.iter().filter(|r| r.result.is_some()).count(), 1);
    assert_eq!(
        responses
            .iter()
            .filter_map(|r| r.error.as_ref())
            .next()
            .unwrap()
            .code,
        "workflow_conflict"
    );
    let current = f.get("ios-app");
    assert_eq!(current["context"]["revision"], 2);
    assert_eq!(current["workflow"]["revision"], 2);
    assert_eq!(f.rows("workflow_versions").len(), 2);
    let db = Connection::open(f.home.join("journal.sqlite")).unwrap();
    let registered: i64 = db
        .query_row("SELECT COUNT(*) FROM workflow_ids", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        registered, 2,
        "losing writer must not register its new criterion ID"
    );
    let text = current["workflow"]["criteria"][0]["text"].clone();
    assert_eq!(current["context"]["criteria"][0], text);
}

#[test]
fn old_engine_rewrite_requires_explicit_reset_preserving_history_and_reports() {
    let mut f = Fixture::new();
    f.legacy(json!(["before"]));
    let initial = f.get("ios-app");
    f.rpc(
        "record_workflow_report",
        f.report(&initial, json!([initial["workflow"]["criteria"][0]["id"]])),
    );
    f.reject("save_task_context",json!({"repo_id":"ios-app","expected_revision":1,"purpose":"old client","criteria":[],"references":[],"notes":""}),"workflow_upgrade_required");
    let receipts_before = f.rows("verification_receipts");
    let evidence_before = f.rows("workflow_evidence");
    let versions_before = f.rows("workflow_versions");
    // Simulate a sequential older engine: identical revision and changed notes
    // still invalidates the exact-body guard, even though requirements match.
    let mut legacy = initial["context"].clone();
    legacy["notes"] = json!("old engine changed only notes");
    let journal = f.home.join("journal.sqlite");
    drop(f.service);
    let db = Connection::open(&journal).unwrap();
    db.execute(
        "UPDATE task_contexts SET body=?1 WHERE scope='repo:ios-app'",
        [serde_json::to_string_pretty(&legacy).unwrap()],
    )
    .unwrap();
    drop(db);
    f.service = reopen(f.workspace.clone(), &journal);
    let conflict = f.get("ios-app");
    assert_eq!(conflict["compatibility"], "legacy_changed");
    assert_eq!(conflict["context"]["notes"], legacy["notes"]);
    assert_eq!(conflict["workflow"], initial["workflow"]);
    f.reject(
        "save_task_workflow",
        save(&conflict, criteria(&conflict)),
        "workflow_legacy_changed",
    );
    f.reject(
        "record_workflow_report",
        f.report(&conflict, json!([])),
        "workflow_legacy_changed",
    );
    let reset=f.rpc("reset_task_workflow",json!({"repo_id":"ios-app","expected_context_revision":conflict["context"]["revision"],"expected_workflow_revision":conflict["workflow"]["revision"]}));
    assert_eq!(reset["compatibility"], "current");
    assert_ne!(
        reset["workflow"]["criteria"][0]["id"],
        initial["workflow"]["criteria"][0]["id"]
    );
    assert_eq!(reset["workflow"]["retired_count"], 1);
    assert_eq!(reset["context"], conflict["context"]);
    assert_eq!(f.rows("verification_receipts"), receipts_before);
    assert_eq!(f.rows("workflow_evidence"), evidence_before);
    assert_eq!(
        &f.rows("workflow_versions")[..versions_before.len()],
        versions_before.as_slice()
    );
}

#[test]
fn report_keeps_claimed_examined_state_separate_from_recording_and_status() {
    let f = Fixture::new();
    f.legacy(json!(["condition"]));
    let initial = f.get("ios-app");
    let actual = git::snapshot(&f.workspace.repo("ios-app").unwrap().path).unwrap();
    for status in ["completed", "incomplete", "tool_error", "unknown"] {
        let mut report = f.report(&initial, json!([initial["workflow"]["criteria"][0]["id"]]));
        report["report_status"] = json!(status);
        report["claimed_reviewed_state"] =
            json!({"head":"a".repeat(40),"snapshot_hash":"b".repeat(64)});
        let recorded = f.rpc("record_workflow_report", report);
        assert_eq!(recorded["verifications"][0]["head"], actual.head);
        assert_eq!(
            recorded["verifications"][0]["snapshot_hash"],
            digest(&actual).unwrap()
        );
        assert_eq!(
            recorded["evidence"][0]["claimed_reviewed_state"]["head"],
            "a".repeat(40)
        );
        assert_eq!(recorded["evidence"][0]["report_status"], status);
        assert_eq!(recorded["verifications"][0]["verdict"], "passed");
    }
    let recorded = f.rpc("record_workflow_report", f.report(&initial, json!([])));
    assert!(recorded["evidence"][0]["claimed_reviewed_state"].is_null());
    assert!(
        recorded["evidence"][0]["criteria"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let before = f.rows("verification_receipts");
    for (key, value, code) in [
        (
            "claimed_reviewed_state",
            json!({"head":"HEAD","snapshot_hash":null}),
            "invalid_claimed_reviewed_state",
        ),
        ("snapshot_hash", json!("c".repeat(64)), "stale_snapshot"),
        (
            "artifacts",
            json!(["x".repeat(2_049)]),
            "invalid_verification_metadata",
        ),
    ] {
        let mut p = f.report(&initial, json!([]));
        p[key] = value;
        f.reject("record_workflow_report", p, code);
    }
    let mut forged = f.report(&initial, json!([]));
    forged["kind"] = json!("git_check");
    assert!(
        f.service
            .dispatch(Request {
                method: "record_workflow_report".into(),
                params: forged
            })
            .error
            .is_some()
    );
    assert_eq!(f.rows("verification_receipts"), before);
}

#[test]
fn history_and_extensions_are_bounded_without_rewriting_old_evidence() {
    let f = Fixture::new();
    f.legacy(json!(["condition"]));
    let mut current = f.get("ios-app");
    for n in 0..12 {
        let mut p = save(&current, criteria(&current));
        p["notes"] = json!(format!("revision {n}"));
        current = f.rpc("save_task_workflow", p);
    }
    assert_eq!(current["history"].as_array().unwrap().len(), 10);
    assert_eq!(f.rows("workflow_versions").len(), 13);
    let report = f.report(&current, json!([current["workflow"]["criteria"][0]["id"]]));
    // Fifty-two genuine receipt writes exercise the actual retrieval window.
    for _ in 0..52 {
        f.rpc("record_workflow_report", report.clone());
    }
    let current = f.get("ios-app");
    assert_eq!(current["verifications"].as_array().unwrap().len(), 50);
    assert_eq!(current["evidence"].as_array().unwrap().len(), 50);
    assert_eq!(f.rows("verification_receipts").len(), 52);
    assert_eq!(f.rows("workflow_evidence").len(), 52);
    let receipt_bytes = f.rows("verification_receipts");
    let extension_bytes = f.rows("workflow_evidence");
    // A newest legacy report remains visible and unlinked. It consumes one
    // place in the fifty-receipt window without pulling older metadata in.
    f.rpc("record_verification_report",json!({"repo_id":"ios-app","kind":"human_report","verdict":"unknown","command":"legacy report","note":"no v2 metadata"}));
    let current = f.get("ios-app");
    let receipts = current["verifications"].as_array().unwrap();
    let extensions = current["evidence"].as_array().unwrap();
    assert_eq!(receipts.len(), 50);
    assert_eq!(receipts[0]["command"], "legacy report");
    assert_eq!(extensions.len(), 49);
    for (receipt, extension) in receipts[1..].iter().zip(extensions) {
        assert_eq!(receipt["id"], extension["receipt_id"]);
    }
    assert_eq!(&f.rows("verification_receipts")[..52], receipt_bytes);
    assert_eq!(f.rows("workflow_evidence"), extension_bytes);
}

#[test]
fn guides_read_selected_repository_literal_text_and_pins_without_context_mutation() {
    let f = Fixture::new();
    let initial = f.get("ios-app");
    let path = &f.workspace.repo("ios-app").unwrap().path;
    fs::create_dir(path.join("docs")).unwrap();
    let text = "# Procedure\n$(touch never-created)\ninclude: /etc/passwd\n";
    fs::write(path.join("docs/check.md"), text).unwrap();
    let guide_id = fresh_id();
    let mut p = save(&initial, json!([]));
    p["guides"] = json!([{"id":guide_id,"repo_id":"ios-app","kind":"procedure","path":"docs/check.md","expected_sha256":null}]);
    let saved = f.rpc("save_task_workflow", p);
    let context_bytes = f.rows("task_contexts");
    let versions = f.rows("workflow_versions");
    let read = json!({"repo_id":"ios-app","guide_id":guide_id,"expected_context_revision":saved["context"]["revision"],"expected_workflow_revision":saved["workflow"]["revision"]});
    let contents = f.rpc("read_verification_guide", read.clone());
    assert_eq!(contents["content"], text);
    assert_eq!(contents["status"], "unread");
    assert_eq!(contents["sha256"], hash(text));
    assert_eq!(contents["format"], "plain_text");
    assert!(!path.join("never-created").exists());
    assert_eq!(f.rows("task_contexts"), context_bytes);
    assert_eq!(f.rows("workflow_versions"), versions);
    let mut p = save(&saved, criteria(&saved));
    p["guides"][0]["expected_sha256"] = contents["sha256"].clone();
    let pinned = f.rpc("save_task_workflow", p);
    let mut read = read;
    read["expected_context_revision"] = pinned["context"]["revision"].clone();
    read["expected_workflow_revision"] = pinned["workflow"]["revision"].clone();
    assert_eq!(
        f.rpc("read_verification_guide", read.clone())["status"],
        "matching"
    );
    fs::write(path.join("docs/check.md"), "changed").unwrap();
    assert_eq!(f.rpc("read_verification_guide", read)["status"], "changed");
    for bad in [
        "../outside.md",
        "/etc/passwd",
        "docs/../check.md",
        "https://example.test/a.md",
        "docs/file.sh",
    ] {
        let mut p = save(&pinned, criteria(&pinned));
        p["guides"][0]["path"] = json!(bad);
        assert!(
            f.service
                .dispatch(Request {
                    method: "save_task_workflow".into(),
                    params: p
                })
                .error
                .is_some(),
            "{bad}"
        );
    }
}

#[test]
fn workflow_rpc_rejects_malformed_optional_scopes_before_fallback() {
    let f = Fixture::new();
    for method in [
        "get_task_workflow",
        "save_task_workflow",
        "reset_task_workflow",
        "record_workflow_report",
        "read_verification_guide",
    ] {
        for key in ["op_id", "context_op_id"] {
            for value in [json!(""), json!(" "), json!(false), json!(3), json!([])] {
                let mut p = json!({"repo_id":"ios-app"});
                p[key] = value;
                f.reject(method, p, "invalid_parameter");
            }
        }
    }
    assert!(f.rows("workflow_states").is_empty());
    assert!(f.rows("task_contexts").is_empty());
}

#[test]
fn task_guides_and_reports_keep_repository_and_worktree_scope_explicit() {
    let f = Fixture::new();
    let plan = f
        .service
        .plan(TaskRequest {
            group_id: "ios-2-4".into(),
            label: "workflow task".into(),
            task_slug: "workflow-scope".into(),
            mode: Mode::Materialize,
            repo_overrides: Default::default(),
        })
        .unwrap();
    let op = f.service.execute(&plan.id, "workflow-scope-key").unwrap();
    let start = Instant::now();
    let op = loop {
        let current = f.service.operation(&op.id).unwrap();
        if !["queued", "running"].contains(&current.status.as_str()) {
            break current;
        }
        assert!(start.elapsed() < Duration::from_secs(20));
        thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(op.status, "ready");
    let initial = f.rpc(
        "get_task_workflow",
        json!({"repo_id":"ios-app","op_id":op.id}),
    );
    let api_id = fresh_id();
    let ios_id = fresh_id();
    let mut p = save(
        &initial,
        json!([{"id":fresh_id(),"text":"shared criterion"}]),
    );
    p["context_op_id"] = json!(op.id);
    p["guides"] = json!([
        {"id":api_id,"repo_id":"api","kind":"feature_map","path":"notes.txt","expected_sha256":null},
        {"id":ios_id,"repo_id":"ios-app","kind":"procedure","path":"notes.txt","expected_sha256":null}]);
    let saved = f.rpc("save_task_workflow", p);
    let read = json!({"repo_id":"ios-app","op_id":op.id,"guide_id":api_id,"expected_context_revision":saved["context"]["revision"],"expected_workflow_revision":saved["workflow"]["revision"]});
    f.reject("read_verification_guide", read, "guide_repo_mismatch");
    let worktree = &op
        .repos
        .iter()
        .find(|r| r.plan.repo_id == "ios-app")
        .unwrap()
        .plan
        .worktree_path;
    fs::write(worktree.join("notes.txt"), "TASK FILE\n").unwrap();
    let read = json!({"repo_id":"ios-app","op_id":op.id,"guide_id":ios_id,"expected_context_revision":saved["context"]["revision"],"expected_workflow_revision":saved["workflow"]["revision"]});
    assert_eq!(
        f.rpc("read_verification_guide", read)["content"],
        "TASK FILE\n"
    );
    let mut report = f.report(&saved, json!([saved["workflow"]["criteria"][0]["id"]]));
    report["op_id"] = json!(op.id);
    report["snapshot_hash"] = json!(digest(&git::snapshot(worktree).unwrap()).unwrap());
    let recorded = f.rpc("record_workflow_report", report);
    assert_eq!(recorded["verifications"][0]["op_id"], op.id);
    assert_eq!(
        recorded["verifications"][0]["path"],
        worktree.to_str().unwrap()
    );
    let sibling = f.rpc("get_task_workflow", json!({"repo_id":"api","op_id":op.id}));
    assert_eq!(sibling["workflow"], saved["workflow"]);
    assert_eq!(sibling["verifications"][0]["repo_id"], "ios-app");
    assert!(
        f.get("ios-app")["verifications"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let mut bad = save(&saved, criteria(&saved));
    bad["context_op_id"] = json!(op.id);
    bad["guides"][0]["repo_id"] = json!("missing");
    assert!(
        f.service
            .dispatch(Request {
                method: "save_task_workflow".into(),
                params: bad
            })
            .error
            .is_some()
    );
}

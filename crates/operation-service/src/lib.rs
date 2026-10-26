pub mod fixtures;
pub mod ipc;
pub mod registration;
mod remotes;
mod task_context;
mod task_workflow;
mod verification_guide;
use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
use workbench_domain::*;
use workbench_git as git;
use workbench_runner as runner;

// Includes the running worker and workers waiting for mutation ownership. A
// cancelled worker retains its slot until it has actually exited.
const MAX_ADMITTED_PREPARATIONS: usize = 8;

// Ref creation and checkout each retain their independent 120s write budget.
// Read phases also have intrinsic 30s caps; reserve enough for the serial
// trust, baseline, reconciliation and postcondition observations around a recipe.
fn preparation_repo_budget(recipe_seconds: u64) -> Duration {
    Duration::from_secs(recipe_seconds.saturating_add(2 * 120 + 10 * 30))
}

fn preparation_read_control<T>(
    cancelled: Arc<AtomicBool>,
    budget: Duration,
    work: impl FnOnce() -> T,
) -> T {
    git::with_read_cancellation(cancelled, || git::with_deadline(budget, work))
}

#[cfg(test)]
type PreparationObserver = Box<dyn FnMut(&str, usize, &Operation) + Send>;

fn request_budget_seconds(method: &str) -> u64 {
    match method {
        "configure_remote" | "fetch_remote" | "pull_remote" | "push_remote" => 345,
        // These clients wait 180s. write_budget reserves 10s before launching
        // one write with its own 120s budget, then refresh gets at most 15s.
        // A 40s preflight leaves nominal response/scheduling headroom; giving
        // preflight the entire client budget would let writes outlive it.
        "stage_hunk" | "stage_file" | "commit" => 40,
        _ => 25,
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub fn id() -> String {
    Uuid::new_v4().to_string()
}
pub fn load_workspace(path: &Path) -> Result<Workspace> {
    let mut workspace: Workspace = serde_json::from_slice(&fs::read(path)?)?;
    workspace.validate()?;
    ensure!(
        workspace.worktree_root.is_absolute(),
        "worktree_root_must_be_absolute"
    );
    fs::create_dir_all(&workspace.worktree_root)?;
    ensure!(
        !fs::symlink_metadata(&workspace.worktree_root)?
            .file_type()
            .is_symlink(),
        "symlink_worktree_root"
    );
    workspace.worktree_root = fs::canonicalize(&workspace.worktree_root)?;
    let mut common = std::collections::BTreeSet::new();
    for repo in &mut workspace.repositories {
        repo.path = git::root(&repo.path)?;
        ensure!(
            common.insert(git::common_dir(&repo.path)?),
            "duplicate_repository_identity"
        );
    }
    Ok(workspace)
}

pub struct Service {
    pub workspace: Workspace,
    repository_identities: BTreeMap<String, PathBuf>,
    summaries: Mutex<BTreeMap<String, Operation<SnapshotSummary>>>,
    db: Mutex<Connection>,
    mutations: Mutex<()>,
    active: Mutex<BTreeMap<String, Arc<AtomicBool>>>,
    stopping: AtomicBool,
    #[cfg(test)]
    preparation_observer: Mutex<Option<PreparationObserver>>,
    _owner: File,
}
impl Service {
    pub fn open(workspace: Workspace, db_path: &Path) -> Result<Arc<Self>> {
        workspace.validate()?;
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let owner = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(db_path.with_extension("owner.lock"))?;
        owner
            .try_lock_exclusive()
            .context("service_already_running")?;
        let db = Connection::open(db_path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS task_contexts(scope TEXT PRIMARY KEY, body TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS verification_receipts(id TEXT PRIMARY KEY, scope TEXT NOT NULL, body TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS verification_scope ON verification_receipts(scope);
          CREATE TABLE IF NOT EXISTS workflow_states(scope TEXT PRIMARY KEY, body TEXT NOT NULL, legacy_revision INTEGER NOT NULL, legacy_body_hash TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS workflow_versions(scope TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, saved_at INTEGER NOT NULL, PRIMARY KEY(scope,revision));
          CREATE TABLE IF NOT EXISTS workflow_ids(id TEXT PRIMARY KEY, scope TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS workflow_ids_scope ON workflow_ids(scope);
          CREATE TABLE IF NOT EXISTS workflow_evidence(receipt_id TEXT PRIMARY KEY REFERENCES verification_receipts(id), scope TEXT NOT NULL, body TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS plans(id TEXT PRIMARY KEY, body TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, plan_id TEXT NOT NULL UNIQUE, body TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS operations_task_id ON operations(json_extract(body, '$.task_id'));
          CREATE INDEX IF NOT EXISTS operations_status ON operations(json_extract(body, '$.status'));
          CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL, timestamp INTEGER NOT NULL, status TEXT NOT NULL);")?;
        let config_hash = digest(&workspace)?;
        let stored: Option<String> = db
            .query_row(
                "SELECT value FROM metadata WHERE key='config_hash'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        // A different configuration cannot reinterpret operations in an existing journal.
        ensure!(
            stored.as_ref().is_none_or(|s| s == &config_hash),
            "journal_configuration_mismatch"
        );
        db.execute(
            "INSERT OR IGNORE INTO metadata(key,value) VALUES('config_hash',?1)",
            [&config_hash],
        )?;
        let service = Arc::new(Self {
            #[cfg(test)]
            preparation_observer: Mutex::new(None),
            summaries: Mutex::new(BTreeMap::new()),
            repository_identities: workspace
                .repositories
                .iter()
                .map(|repo| {
                    ensure!(
                        git::root(&repo.path)? == repo.path,
                        "unsafe_source_repository"
                    );
                    Ok((repo.id.clone(), git::common_dir(&repo.path)?))
                })
                .collect::<Result<_>>()?,
            workspace,
            db: Mutex::new(db),
            mutations: Mutex::new(()),
            active: Mutex::new(BTreeMap::new()),
            stopping: AtomicBool::new(false),
            _owner: owner,
        });
        // Restart does not spawn unknown external commands. Explicit retry reconciles Git.
        let recovering: Vec<Operation> = {
            let db = service.db();
            let mut stmt = db.prepare("SELECT body FROM operations WHERE json_extract(body, '$.status') IN ('running','queued')")?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
            rows.map(|r| Ok(serde_json::from_str(&r?)?))
                .collect::<Result<_>>()?
        };
        for mut op in recovering {
            if op.status == "running" || op.status == "queued" {
                op.status = "needs_recovery".into();
                service.save(&op)?;
            }
        }
        Ok(service)
    }
    fn db(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.db.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn save(&self, op: &Operation) -> Result<()> {
        let mut db = self.db();
        let tx = db.transaction()?;
        let mut persisted = op.clone();
        if op.status == "running" {
            // A progress checkpoint must not clear a concurrent cancellation request.
            let requested: bool = tx.query_row(
                "SELECT json_extract(body,'$.cancel_requested') FROM operations WHERE id=?1",
                [&op.id],
                |row| row.get(0),
            )?;
            persisted.cancel_requested |= requested;
        }
        tx.execute(
            "UPDATE operations SET body=?1 WHERE id=?2",
            params![serde_json::to_string(&persisted)?, op.id],
        )?;
        tx.execute(
            "INSERT INTO events(operation_id,timestamp,status) VALUES(?1,?2,?3)",
            params![op.id, now() as i64, op.status],
        )?;
        tx.commit()?;
        self.cache_summary(&persisted)?;
        Ok(())
    }
    // Call while holding the DB guard: summary and authoritative operation
    // checkpoints cannot be reordered by a concurrent read/save/cancellation.
    fn cache_summary(&self, op: &Operation) -> Result<Operation<SnapshotSummary>> {
        let summary = op.summary()?;
        let mut cache = self.summaries.lock().unwrap_or_else(|e| e.into_inner());
        if cache.len() >= 128
            && !cache.contains_key(&op.id)
            && let Some(old) = cache.keys().next().cloned()
        {
            cache.remove(&old);
        }
        cache.insert(op.id.clone(), summary.clone());
        Ok(summary)
    }
    fn operation_summary(&self, id: &str) -> Result<Operation<SnapshotSummary>> {
        let db = self.db();
        if let Some(value) = self
            .summaries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .cloned()
        {
            return Ok(value);
        }
        let body: String = db
            .query_row("SELECT body FROM operations WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .context("unknown_operation")?;
        self.cache_summary(&serde_json::from_str(&body)?)
    }
    fn operation_summaries(&self) -> Result<Vec<Operation<SnapshotSummary>>> {
        let ids = {
            let db = self.db();
            let mut stmt = db.prepare("SELECT id FROM operations ORDER BY rowid DESC LIMIT 100")?;
            stmt.query_map([], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        ids.iter()
            .map(|id| {
                git::check_deadline()?;
                self.operation_summary(id)
            })
            .collect()
    }
    fn operation_summary_for_key(&self, key: &str) -> Result<Option<Operation<SnapshotSummary>>> {
        ensure!(
            !key.is_empty() && key.len() <= 128,
            "invalid_idempotency_key"
        );
        let id: Option<String> = {
            let db = self.db();
            db.query_row("SELECT id FROM operations WHERE key=?1", [key], |row| {
                row.get(0)
            })
            .optional()?
        };
        id.map(|id| self.operation_summary(&id)).transpose()
    }
    pub fn operations(&self) -> Result<Vec<Operation>> {
        let db = self.db();
        let mut stmt = db.prepare("SELECT body FROM operations ORDER BY rowid DESC LIMIT 100")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        rows.map(|r| Ok(serde_json::from_str(&r?)?)).collect()
    }
    pub fn operation(&self, id: &str) -> Result<Operation> {
        let data: String = self
            .db()
            .query_row("SELECT body FROM operations WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .context("unknown_operation")?;
        Ok(serde_json::from_str(&data)?)
    }
    pub fn plan(&self, request: TaskRequest) -> Result<Plan> {
        let _guard = self
            .mutations
            .try_lock()
            .map_err(|_| anyhow::anyhow!("repository_busy"))?;
        ensure!(!self.is_stopping(), "service_stopping");
        let resolved = self.workspace.resolve(&request)?;
        let plan_id = id();
        let mut repos = vec![];
        for (repo_id, policy, policy_origins) in resolved {
            let repo = self.workspace.repo(&repo_id)?;
            self.target(&repo_id, None)?;
            let _lock = repo_lock(&repo.path)?;
            git::no_conflicts(&repo.path)?;
            let base_ref = policy.base_ref.clone().context("missing_base_ref")?;
            ensure!(
                base_ref.starts_with("refs/heads/") || base_ref.starts_with("refs/remotes/"),
                "base_must_be_named_ref"
            );
            let base_oid = git::oid(&repo.path, &base_ref)?;
            let pattern = policy
                .branch_pattern
                .as_ref()
                .context("missing_branch_pattern")?;
            ensure!(
                pattern.contains("{task_slug}"),
                "branch_pattern_requires_slug"
            );
            let branch_ref = format!(
                "refs/heads/{}",
                pattern.replace("{task_slug}", &request.task_slug)
            );
            git::validate_branch(&repo.path, &branch_ref)?;
            ensure!(
                !git::ref_exists(&repo.path, &branch_ref)?,
                "branch_collision"
            );
            let worktree_path = self
                .workspace
                .worktree_root
                .join(format!("{}-{}", request.task_slug, &plan_id[..8]))
                .join(&hash(repo_id.as_bytes())[..12]);
            ensure!(!worktree_path.exists(), "worktree_collision");
            let recipe_hash = if let Some(id) = &policy.recipe {
                let recipe = self.workspace.recipe(id)?;
                ensure!(recipe.repo_id == repo_id, "recipe_repo_mismatch");
                // Also verify script/writes exist in the pinned base, not just dirty original checkout.
                let trust = runner::trusted(recipe, &repo.path)?;
                let script = git::git_bytes(
                    &repo.path,
                    &["show", &format!("{base_oid}:{}", recipe.script)],
                )?;
                ensure!(
                    hash(script) == runner::script_hash(recipe, &repo.path)?,
                    "base_recipe_hash_mismatch"
                );
                for path in &recipe.writes {
                    git::git_bytes(
                        &repo.path,
                        &["cat-file", "-e", &format!("{base_oid}:{path}")],
                    )?;
                }
                Some(trust)
            } else {
                None
            };
            repos.push(PlannedRepo {
                repo_id,
                common_id: hash(git::common_dir(&repo.path)?.as_os_str().as_encoded_bytes()),
                base_ref,
                base_oid,
                branch_ref,
                worktree_path,
                source_snapshot: git::snapshot(&repo.path)?,
                policy,
                policy_origins,
                recipe_hash,
            });
        }
        let snapshot_hash = digest(&repos)?;
        let plan = Plan { schema_version:1,id:plan_id, request,config_hash:digest(&self.workspace)?,snapshot_hash,expires_at:now()+900,repos,warnings:vec!["준비 스크립트의 쓰기 범위는 변경 감지 규칙입니다. 실행을 OS에서 격리하지는 않습니다.".into(), "빌드 번호는 이 작업에 입력한 고정값입니다. 다른 배포에서 같은 번호를 쓰지 않았는지는 별도로 확인하세요.".into()] };
        self.db().execute(
            "INSERT INTO plans(id,body) VALUES(?1,?2)",
            params![plan.id, serde_json::to_string(&plan)?],
        )?;
        Ok(plan)
    }
    fn get_plan(&self, id: &str) -> Result<Plan> {
        let body: String = self
            .db()
            .query_row("SELECT body FROM plans WHERE id=?1", [id], |r| r.get(0))
            .context("unknown_plan")?;
        Ok(serde_json::from_str(&body)?)
    }
    pub fn execute(self: &Arc<Self>, plan_id: &str, key: &str) -> Result<Operation> {
        let active = self.active.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(!self.is_stopping(), "service_stopping");
        ensure!(
            !key.is_empty() && key.len() <= 128,
            "invalid_idempotency_key"
        );
        let payload_hash = digest(&json!({"plan_id":plan_id}))?;
        let mut db = self.db();
        let tx = db.transaction()?;
        let existing: Option<String> = tx
            .query_row("SELECT body FROM operations WHERE key=?1", [key], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(body) = existing {
            let op: Operation = serde_json::from_str(&body)?;
            ensure!(op.payload_hash == payload_hash, "idempotency_conflict");
            return Ok(op);
        }
        ensure!(
            active.len() < MAX_ADMITTED_PREPARATIONS,
            "preparation_queue_full"
        );
        let body: String = tx
            .query_row("SELECT body FROM plans WHERE id=?1", [plan_id], |r| {
                r.get(0)
            })
            .context("unknown_plan")?;
        let plan: Plan = serde_json::from_str(&body)?;
        ensure!(
            plan.expires_at >= now() && plan.config_hash == digest(&self.workspace)?,
            "stale_plan"
        );
        let op = Operation {
            schema_version: 1,
            id: id(),
            task_id: id(),
            plan_id: plan_id.into(),
            idempotency_key: key.into(),
            payload_hash,
            status: "queued".into(),
            materialize: plan.request.mode == Mode::Materialize,
            cancel_requested: false,
            repos: plan
                .repos
                .iter()
                .cloned()
                .map(|plan| TaskRepo {
                    plan,
                    state: RepoState::Planned,
                    error_code: None,
                    attempts: 0,
                    baseline: None,
                    result_snapshot: None,
                    postcondition: None,
                })
                .collect(),
            warnings: plan.warnings,
        };
        tx.execute(
            "INSERT INTO operations(id,key,plan_id,body) VALUES(?1,?2,?3,?4)",
            params![op.id, key, plan_id, serde_json::to_string(&op)?],
        )
        .context("plan_already_executed")?;
        tx.execute(
            "INSERT INTO events(operation_id,timestamp,status) VALUES(?1,?2,'queued')",
            params![op.id, now() as i64],
        )?;
        tx.commit()?;
        self.cache_summary(&op)?;
        drop(db);
        self.start(&op.id, active)?;
        Ok(op)
    }
    fn start(
        self: &Arc<Self>,
        id: &str,
        mut active: MutexGuard<'_, BTreeMap<String, Arc<AtomicBool>>>,
    ) -> Result<()> {
        ensure!(!self.is_stopping(), "service_stopping");
        ensure!(!active.contains_key(id), "operation_running");
        let flag = Arc::new(AtomicBool::new(false));
        active.insert(id.into(), flag.clone());
        drop(active);
        let this = self.clone();
        let id = id.to_owned();
        thread::spawn(move || {
            let result = {
                let _guard = this.mutations.lock().unwrap_or_else(|e| e.into_inner());
                this.run(&id, flag.clone())
            };
            // Release mutation ownership before publishing completion. Cancel, retry and
            // shutdown observe the terminal save and active removal as one transition.
            let mut active = this.active.lock().unwrap_or_else(|e| e.into_inner());
            let result = result.and_then(|mut op| {
                op.cancel_requested = flag.load(Ordering::SeqCst);
                if op.repos.iter().all(|repo| repo.state == RepoState::Ready) {
                    op.status = "ready".into();
                } else if op
                    .repos
                    .iter()
                    .all(|repo| repo.state == RepoState::WaitingForWorktree)
                {
                    op.status = "waiting_for_worktree".into();
                } else if op.cancel_requested {
                    op.status = "cancelled".into();
                }
                this.save(&op)
            });
            if let Err(e) = result
                && let Ok(mut op) = this.operation(&id)
            {
                op.status = "needs_recovery".into();
                op.cancel_requested |= flag.load(Ordering::SeqCst);
                op.warnings
                    .push(format!("Service error: {}", fail_code(&e)));
                let _ = this.save(&op);
            }
            active.remove(&id);
        });
        Ok(())
    }
    pub fn resume(self: &Arc<Self>, id: &str, materialize: bool) -> Result<Operation> {
        // Hold active map until metadata update is durable, closing duplicate retry races.
        let active = self.active.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(!self.is_stopping(), "service_stopping");
        ensure!(!active.contains_key(id), "operation_running");
        let mut op = self.operation(id)?;
        ensure!(op.status != "ready", "operation_already_ready");
        ensure!(
            op.status != "waiting_for_worktree" || materialize,
            "materialize_required"
        );
        ensure!(
            active.len() < MAX_ADMITTED_PREPARATIONS,
            "preparation_queue_full"
        );
        if materialize {
            op.materialize = true;
        }
        op.cancel_requested = false;
        op.status = "queued".into();
        self.save(&op)?;
        self.start(id, active)?;
        self.operation(id)
    }
    pub fn cancel(&self, id: &str) -> Result<Operation> {
        let active = self.active.lock().unwrap_or_else(|e| e.into_inner());
        let flag = active.get(id).context("operation_not_running")?;
        let mut db = self.db();
        let tx = db.transaction()?;
        let body: String =
            tx.query_row("SELECT body FROM operations WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        let mut op: Operation = serde_json::from_str(&body)?;
        if !matches!(op.status.as_str(), "queued" | "running") {
            return Ok(op);
        }
        // Update only the cancellation field; worker checkpoints own all preparation state.
        tx.execute(
            "UPDATE operations SET body=json_set(body,'$.cancel_requested',json('true')) WHERE id=?1",
            [id],
        )?;
        tx.commit()?;
        flag.store(true, Ordering::SeqCst);
        op.cancel_requested = true;
        self.cache_summary(&op)?;
        Ok(op)
    }
    fn run(&self, id: &str, cancelled: Arc<AtomicBool>) -> Result<Operation> {
        let op = self.operation(id)?;
        let budgets: Vec<_> = op
            .repos
            .iter()
            .map(|repo| {
                let recipe_seconds = repo
                    .plan
                    .policy
                    .recipe
                    .as_ref()
                    .map(|id| {
                        self.workspace
                            .recipe(id)
                            .map(|recipe| recipe.timeout_seconds)
                    })
                    .transpose()?
                    .unwrap_or(0);
                Ok(preparation_repo_budget(recipe_seconds))
            })
            .collect::<Result<_>>()?;
        let worker_budget = budgets
            .iter()
            .copied()
            .fold(Duration::ZERO, Duration::saturating_add);
        preparation_read_control(cancelled.clone(), worker_budget, || {
            self.run_controlled(op, cancelled, &budgets)
        })
    }
    #[cfg(test)]
    fn observe_preparation(&self, phase: &str, index: usize, op: &Operation) {
        if let Some(observer) = self.preparation_observer.lock().unwrap().as_mut() {
            observer(phase, index, op);
        }
    }
    fn run_controlled(
        &self,
        mut op: Operation,
        cancelled: Arc<AtomicBool>,
        budgets: &[Duration],
    ) -> Result<Operation> {
        op.status = "running".into();
        self.save(&op)?;
        for (i, budget) in budgets.iter().enumerate().take(op.repos.len()) {
            // Ready is a completed preparation checkpoint, not the current review state.
            // User edits, staging and commits in this folder must survive a peer's retry.
            if op.repos[i].state == RepoState::Ready {
                continue;
            }
            if cancelled.load(Ordering::SeqCst) {
                op.cancel_requested = true;
                break;
            }
            let plan = op.repos[i].plan.clone();
            let repo = self.workspace.repo(&plan.repo_id)?;
            let result = git::with_deadline(*budget, || -> Result<()> {
                #[cfg(test)]
                self.observe_preparation("before_source_read", i, &op);
                git::check_deadline()?;
                self.target(&plan.repo_id, None)?;
                let _lock = repo_lock(&repo.path)?;
                self.target(&plan.repo_id, None)?;
                ensure!(
                    git::snapshot(&repo.path)? == plan.source_snapshot,
                    "stale_source_snapshot"
                );
                git::no_conflicts(&repo.path)?;
                if op.repos[i].state == RepoState::Planned {
                    ensure!(
                        !git::ref_exists(&repo.path, &plan.branch_ref)?,
                        "branch_collision"
                    );
                    op.repos[i].state = RepoState::BranchIntent;
                    self.save(&op)?;
                }
                git::create_branch(&repo.path, &plan.branch_ref, &plan.base_oid, &op.id)?;
                op.repos[i].state = RepoState::BranchCreated;
                self.save(&op)?;
                if !op.materialize {
                    op.repos[i].state = RepoState::WaitingForWorktree;
                    op.repos[i].error_code = None;
                    self.save(&op)?;
                    return Ok(());
                }
                // The generated path has no user-controlled directory components.
                let parent = plan
                    .worktree_path
                    .parent()
                    .context("invalid_worktree_path")?;
                fs::create_dir_all(parent)?;
                ensure!(
                    fs::canonicalize(parent)?.parent()
                        == Some(self.workspace.worktree_root.as_path()),
                    "unsafe_worktree_path"
                );
                ensure!(
                    !fs::symlink_metadata(parent)?.file_type().is_symlink(),
                    "symlink_worktree_path"
                );
                op.repos[i].state = RepoState::Materializing;
                self.save(&op)?;
                if !plan.worktree_path.exists() {
                    ensure!(op.repos[i].baseline.is_none(), "worktree_missing");
                    git::git(
                        &repo.path,
                        &[
                            "worktree",
                            "add",
                            "--",
                            plan.worktree_path
                                .to_str()
                                .context("invalid_path_encoding")?,
                            plan.branch_ref
                                .strip_prefix("refs/heads/")
                                .context("invalid_branch")?,
                        ],
                    )?;
                }
                ensure!(
                    !fs::symlink_metadata(&plan.worktree_path)?
                        .file_type()
                        .is_symlink(),
                    "symlink_worktree_path"
                );
                git::verify_checkout(
                    &plan.worktree_path,
                    &repo.path,
                    &plan.branch_ref,
                    &plan.base_oid,
                )?;
                if let Some(previous) = &op.repos[i].result_snapshot {
                    ensure!(
                        previous == &git::preparation_snapshot(&plan.worktree_path)?,
                        "stale_snapshot"
                    );
                }
                if op.repos[i].baseline.is_none() {
                    ensure!(
                        git::status_bytes(&plan.worktree_path)?.is_empty(),
                        "dirty_new_worktree"
                    );
                    op.repos[i].baseline = Some(git::preparation_snapshot(&plan.worktree_path)?);
                }
                op.repos[i].state = RepoState::CheckedOut;
                self.save(&op)?;
                if let Some(recipe_id) = &plan.policy.recipe {
                    let recipe = self.workspace.recipe(recipe_id)?;
                    ensure!(
                        Some(runner::trusted(recipe, &plan.worktree_path)?) == plan.recipe_hash,
                        "recipe_hash_changed"
                    );
                    let inputs = plan.policy.inputs.as_ref().context("missing_inputs")?;
                    let baseline = op.repos[i]
                        .baseline
                        .as_ref()
                        .context("missing_baseline")?
                        .clone();
                    // Reconcile a lost completion response before replaying the fixed-input adapter.
                    if let Ok(after) =
                        runner::postcondition(recipe, &plan.worktree_path, inputs, &baseline)
                    {
                        op.repos[i].result_snapshot = Some(after);
                    } else {
                        git::check_deadline()?;
                        verify_scope(
                            recipe,
                            &baseline,
                            &git::preparation_snapshot(&plan.worktree_path)?,
                        )?;
                        op.repos[i].state = RepoState::Preparing;
                        op.repos[i].attempts += 1;
                        self.save(&op)?;
                        let result =
                            runner::run(recipe, &plan.worktree_path, inputs, cancelled.clone());
                        #[cfg(test)]
                        self.observe_preparation("after_recipe", i, &op);
                        // Record only a completed observation. Cancellation or a
                        // deadline keeps the previous receipt/checkpoint intact;
                        // neither failure justifies an unbounded recovery scan.
                        op.repos[i].result_snapshot =
                            Some(git::preparation_snapshot(&plan.worktree_path)?);
                        self.save(&op)?;
                        verify_scope(
                            recipe,
                            &baseline,
                            op.repos[i]
                                .result_snapshot
                                .as_ref()
                                .context("missing_result")?,
                        )?;
                        result?;
                        op.repos[i].result_snapshot = Some(runner::postcondition(
                            recipe,
                            &plan.worktree_path,
                            inputs,
                            &baseline,
                        )?);
                    }
                    op.repos[i].postcondition = Some(inputs.clone());
                } else {
                    op.repos[i].result_snapshot =
                        Some(git::preparation_snapshot(&plan.worktree_path)?);
                }
                ensure!(
                    git::snapshot(&repo.path)? == plan.source_snapshot,
                    "stale_source_snapshot"
                );
                op.repos[i].state = RepoState::Ready;
                op.repos[i].error_code = None;
                self.save(&op)?;
                Ok(())
            });
            if let Err(error) = result {
                let code = fail_code(&error);
                op.repos[i].state = if code == "cancelled" {
                    RepoState::Cancelled
                } else if code.starts_with("unexpected") || code.starts_with("stale") {
                    RepoState::NeedsRecovery
                } else {
                    RepoState::Failed
                };
                op.repos[i].error_code = Some(code);
                self.save(&op)?;
            }
        }
        let ready = op
            .repos
            .iter()
            .filter(|r| r.state == RepoState::Ready)
            .count();
        let waiting = op
            .repos
            .iter()
            .all(|r| r.state == RepoState::WaitingForWorktree);
        op.cancel_requested = cancelled.load(Ordering::SeqCst);
        op.status = if ready == op.repos.len() {
            "ready"
        } else if waiting {
            "waiting_for_worktree"
        } else if op.cancel_requested {
            "cancelled"
        } else if ready > 0 {
            "partial_failure"
        } else if op.repos.iter().any(|r| r.state == RepoState::NeedsRecovery) {
            "needs_recovery"
        } else {
            "failed"
        }
        .into();
        Ok(op)
    }
    pub fn task(&self, task_id: &str) -> Result<Task> {
        let (operation_id, plan_id): (String, String) = self
            .db()
            .query_row(
                "SELECT id,plan_id FROM operations WHERE json_extract(body, '$.task_id')=?1",
                [task_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .context("unknown_task")?;
        let plan = self.get_plan(&plan_id)?;
        Ok(Task {
            schema_version: 1,
            id: task_id.into(),
            request: plan.request.clone(),
            policy_snapshot: plan,
            operation_id,
        })
    }
    pub fn events(&self, cursor: i64) -> Result<Vec<Event>> {
        ensure!(cursor >= 0, "invalid_cursor");
        let db = self.db();
        let mut stmt = db.prepare("SELECT sequence,operation_id,timestamp,status FROM events WHERE sequence>?1 ORDER BY sequence LIMIT 200")?;
        Ok(stmt
            .query_map([cursor], |r| {
                Ok(Event {
                    sequence: r.get(0)?,
                    operation_id: r.get(1)?,
                    timestamp: r.get::<_, i64>(2)? as u64,
                    status: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<_, _>>()?)
    }
    fn recent_events(&self) -> Result<Vec<Event>> {
        let db = self.db();
        let mut stmt = db.prepare("SELECT sequence,operation_id,timestamp,status FROM (SELECT sequence,operation_id,timestamp,status FROM events ORDER BY sequence DESC LIMIT 200) ORDER BY sequence")?;
        Ok(stmt
            .query_map([], |r| {
                Ok(Event {
                    sequence: r.get(0)?,
                    operation_id: r.get(1)?,
                    timestamp: r.get::<_, i64>(2)? as u64,
                    status: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    fn target(&self, repo_id: &str, op_id: Option<&str>) -> Result<PathBuf> {
        let repo = self.workspace.repo(repo_id)?;
        ensure!(
            git::root(&repo.path).context("unsafe_source_repository")? == repo.path
                && self.repository_identities.get(repo_id) == Some(&git::common_dir(&repo.path)?),
            "unsafe_source_repository"
        );
        if let Some(id) = op_id {
            let op = self.operation_summary(id)?;
            let r = op
                .repos
                .iter()
                .find(|r| r.plan.repo_id == repo_id)
                .context("unknown_task_repo")?;
            ensure!(r.baseline.is_some(), "worktree_not_ready");
            ensure!(
                !fs::symlink_metadata(&r.plan.worktree_path)?
                    .file_type()
                    .is_symlink()
                    && fs::canonicalize(&r.plan.worktree_path)? == r.plan.worktree_path
                    && git::root(&r.plan.worktree_path)? == r.plan.worktree_path
                    && r.plan.worktree_path != fs::canonicalize(&repo.path)?,
                "unsafe_task_worktree"
            );
            ensure!(
                git::common_dir(&r.plan.worktree_path)? == git::common_dir(&repo.path)?,
                "wrong_repository"
            );
            let control = r.plan.worktree_path.join(".git");
            let git_dir = fs::canonicalize(git::git_path(
                &r.plan.worktree_path,
                &["rev-parse", "--absolute-git-dir"],
            )?)?;
            ensure!(
                fs::symlink_metadata(&control)?.file_type().is_file()
                    && git_dir.parent()
                        == Some(git::common_dir(&repo.path)?.join("worktrees").as_path())
                    && fs::canonicalize(git::path_from_record(&fs::read_to_string(
                        git_dir.join("gitdir"),
                    )?)?)?
                        == control,
                "unsafe_task_worktree"
            );
            ensure!(
                git::git(&r.plan.worktree_path, &["symbolic-ref", "-q", "HEAD"])?.trim()
                    == r.plan.branch_ref,
                "wrong_task_branch"
            );
            Ok(r.plan.worktree_path.clone())
        } else {
            Ok(repo.path.clone())
        }
    }
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }
    fn shutdown_if_idle(&self) -> Result<bool> {
        let active = self.active.lock().unwrap_or_else(|e| e.into_inner());
        let Ok(_guard) = self.mutations.try_lock() else {
            return Ok(false);
        };
        let pending: bool = self.db().query_row(
            "SELECT EXISTS(SELECT 1 FROM operations WHERE json_extract(body,'$.status') IN ('queued','running'))",
            [], |row| row.get(0),
        )?;
        if !active.is_empty() || pending {
            return Ok(false);
        }
        // start/resume and Git mutations recheck this flag under the same locks.
        self.stopping.store(true, Ordering::SeqCst);
        Ok(true)
    }
    pub fn dispatch(self: &Arc<Self>, request: Request) -> Response {
        // Preparation workers have their own budgets. Reads must fit the 30s
        // client wait; mutations reserve time for their separately bounded write.
        let timeout = request_budget_seconds(&request.method);
        let result = git::with_deadline(std::time::Duration::from_secs(timeout), || {
            self.handle(request)
        });
        match result {
            Ok(value) => Response {
                schema_version: 1,
                result: Some(value),
                error: None,
            },
            Err(e) => Response {
                schema_version: 1,
                result: None,
                error: Some(ErrorBody {
                    code: fail_code(&e),
                    message: e.to_string(),
                }),
            },
        }
    }
    fn handle(self: &Arc<Self>, request: Request) -> Result<Value> {
        if request.method == "shutdown_if_idle" {
            return Ok(json!({"stopping":self.shutdown_if_idle()?}));
        }
        ensure!(!self.is_stopping(), "service_stopping");
        let p = request.params;
        let string = |key: &str| -> Result<&str> {
            p.get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow::anyhow!("missing_parameter: {key}"))
        };
        match request.method.as_str() {
            "get_remote_state" | "configure_remote" | "fetch_remote" | "pull_remote" | "push_remote" => {
                self.handle_remotes(&request.method, p)
            }
            "get_task_context" | "save_task_context" | "run_git_check" | "record_verification_report" => {
                optional_id(&p, "op_id")?;
                optional_id(&p, "context_op_id")?;
                self.handle_task_context(&request.method, p)
            }
            "get_task_workflow" | "save_task_workflow" | "reset_task_workflow" | "record_workflow_report" | "read_verification_guide" => {
                optional_id(&p, "op_id")?;
                optional_id(&p, "context_op_id")?;
                self.handle_task_workflow(&request.method, p)
            }
            "list_workspaces" => Ok(json!([{"schema_version":1,"id":self.workspace.id,"repositories":self.workspace.repositories,"groups":self.workspace.groups}])),
            "list_recipes" => Ok(json!(self.workspace.recipes.iter().map(|r|json!({"id":r.id,"repo_id":r.repo_id,"revision":r.revision,"writes":r.writes,"trusted":r.trusted_hash.is_some(),"target":r.target,"configuration":r.configuration})).collect::<Vec<_>>())),
            "plan_task" => Ok(serde_json::to_value(self.plan(serde_json::from_value(p)?)?.summary()?)?),
            "execute_plan" => Ok(serde_json::to_value(self.execute(string("plan_id")?,string("idempotency_key")?)?.summary()?)?),
            "get_operation" => Ok(serde_json::to_value(self.operation_summary(string("op_id")?)?)?),
            "get_operation_by_key" => Ok(json!({"operation":self.operation_summary_for_key(string("idempotency_key")?)?})),
            "list_operations" => Ok(serde_json::to_value(self.operation_summaries()?)?),
            "get_task" => Ok(serde_json::to_value(self.task(string("task_id")?)?.summary()?)?),
            "retry_operation" => Ok(serde_json::to_value(self.resume(string("op_id")?,false)?.summary()?)?),
            "materialize" => Ok(serde_json::to_value(self.resume(string("op_id")?,true)?.summary()?)?),
            "cancel_operation" => Ok(serde_json::to_value(self.cancel(string("op_id")?)?.summary()?)?),
            "events" => Ok(serde_json::to_value(if p.get("latest").and_then(Value::as_bool).unwrap_or(false) { self.recent_events()? } else { self.events(p.get("cursor").and_then(Value::as_i64).unwrap_or(0))? })?),
            "list_branches" => {
                let repo_id = string("repo_id")?;
                let op_id = optional_id(&p, "op_id")?;
                let source = &self.target(repo_id, None)?;
                let viewed = if let Some(id) = op_id {
                    let op = self.operation_summary(id)?;
                    let repo = op.repos.iter().find(|r| r.plan.repo_id == repo_id).context("unknown_task_repo")?;
                    if repo.baseline.is_some() { Some(self.target(repo_id, Some(id))?) } else { None }
                } else { Some(source.clone()) };
                Ok(serde_json::to_value(git::branches(source, viewed.as_deref())?)?)
            }
            "get_branch_history" => {
                optional_id(&p, "op_id")?;
                let source = &self.target(string("repo_id")?, None)?;
                Ok(serde_json::to_value(git::branch_history(source, string("branch_ref")?, string("tip_oid")?)?)?)
            }
            "list_stashes" | "get_stash" | "get_stash_diff" => {
                // refs/stash is repository-wide, including when a Task has no worktree yet.
                optional_id(&p, "op_id")?;
                let path = &self.target(string("repo_id")?, None)?;
                match request.method.as_str() {
                    "list_stashes" => Ok(serde_json::to_value(git::stashes(path)?)?),
                    "get_stash" => Ok(serde_json::to_value(git::stash_detail(path, string("stash_oid")?)?)?),
                    _ => Ok(serde_json::to_value(git::stash_diff(path, string("stash_oid")?, string("path")?)?)?),
                }
            }
            "get_repo_status" | "get_diff" => {
                let op_id=optional_id(&p, "op_id")?;
                let staged=if request.method == "get_diff" { optional_bool(&p, "staged", false)? } else { false };
                let path=self.target(string("repo_id")?,op_id)?;
                // Reads must not wait behind preparation or hide cancel controls.
                // The Git adapter checks before/after snapshots for drift.
                if request.method == "get_repo_status" { Ok(serde_json::to_value(git::view(&path)?)?) }
                else { Ok(serde_json::to_value(git::diff(&path,string("path")?,staged)?)?) }
            }
            "stage_hunk" | "stage_file" | "commit" => {
                let repo_id=string("repo_id")?;
                let allowed: &[&str] = if request.method == "stage_hunk" {
                    &["repo_id", "op_id", "path", "staged", "hunk_index", "snapshot_hash", "diff_hash"]
                } else if request.method == "stage_file" {
                    &["repo_id", "op_id", "path", "staged", "snapshot_hash"]
                } else {
                    &["repo_id", "op_id", "snapshot_hash", "message"]
                };
                reject_unknown_parameters(&p, allowed)?;
                let op_id=optional_id(&p, "op_id")?;
                let staged=if request.method != "commit" { optional_bool(&p, "staged", false)? } else { false };
                let _guard=self.mutations.try_lock().map_err(|_| anyhow::anyhow!("repository_busy"))?;
                ensure!(!self.is_stopping(), "service_stopping");
                if let Some(id)=op_id {
                    let op=self.operation_summary(id)?;
                    let repo=op.repos.iter().find(|repo| repo.plan.repo_id==repo_id).context("unknown_task_repo")?;
                    ensure!(repo.state==RepoState::Ready, "task_not_ready");
                }
                // Resolve after waiting for preparation/mutation, never reuse a queued target.
                let path=self.target(repo_id,op_id)?;
                let _lock=repo_lock(&path)?;
                let path=self.target(repo_id,op_id)?;
                match request.method.as_str() {
                    "stage_file" => {
                        git::stage_file(&path,string("path")?,staged,string("snapshot_hash")?)?;
                        let view = git::fresh_deadline(std::time::Duration::from_secs(15), || git::view(&path)).ok();
                        Ok(json!({"status":"staged","refresh_required":view.is_none(),"view":view}))
                    }
                    "stage_hunk" => {
                        git::stage_hunk(&path,string("path")?,staged,p.get("hunk_index").and_then(Value::as_u64).context("missing_hunk_index")? as usize,string("snapshot_hash")?,string("diff_hash")?)?;
                        let view = git::fresh_deadline(std::time::Duration::from_secs(15), || git::view(&path)).ok();
                        Ok(json!({"status":"staged","refresh_required":view.is_none(),"view":view}))
                    }
                    "commit" => {
                        git::no_conflicts(&path)?;
                        ensure!(digest(&git::snapshot(&path)?)?==string("snapshot_hash")?, "stale_snapshot");
                        let message=string("message")?; ensure!(!message.trim().is_empty() && message.len()<=10000, "invalid_commit_message");
                        ensure!(!git::git_bytes(&path,&["diff","--cached","--name-only"])?.is_empty(), "empty_index");
                        git::command(&path,&["commit","--cleanup=verbatim","-F","-"],Some(message.as_bytes()))?;
                        let view = git::fresh_deadline(std::time::Duration::from_secs(15), || git::view(&path)).ok();
                        Ok(json!({"status":"committed","head":view.as_ref().map(|v| &v.snapshot.head),"refresh_required":view.is_none(),"view":view}))
                    }
                    _ => bail!("unknown_method"),
                }
            }
            _ => bail!("unknown_method"),
        }
    }
}

// A malformed optional scope must never become the original repository scope.
// Null remains equivalent to omission, matching the typed context requests.
fn optional_id<'a>(params: &'a Value, key: &str) -> Result<Option<&'a str>> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value)),
        _ => bail!("invalid_parameter: {key} must be a nonempty string or null"),
    }
}

fn optional_bool(params: &Value, key: &str, default: bool) -> Result<bool> {
    match params.get(key) {
        None => Ok(default),
        Some(Value::Bool(value)) => Ok(*value),
        _ => bail!("invalid_parameter: {key} must be a boolean"),
    }
}

fn reject_unknown_parameters(params: &Value, allowed: &[&str]) -> Result<()> {
    let params = params
        .as_object()
        .context("invalid_parameter: expected an object")?;
    for key in params.keys() {
        ensure!(
            allowed.contains(&key.as_str()),
            "invalid_parameter: unknown field {key}"
        );
    }
    Ok(())
}

fn verify_scope(recipe: &Recipe, before: &Snapshot, after: &Snapshot) -> Result<()> {
    git::with_deadline(git::READ_PHASE_TIMEOUT, || {
        verify_scope_inner(recipe, before, after)
    })
}
fn verify_scope_inner(recipe: &Recipe, before: &Snapshot, after: &Snapshot) -> Result<()> {
    git::check_deadline()?;
    ensure!(
        before.head == after.head
            && before.branch == after.branch
            && before.index_hash == after.index_hash,
        "unexpected_git_change"
    );
    for path in before.files.keys().chain(after.files.keys()) {
        git::check_deadline()?;
        ensure!(
            before.files.get(path) == after.files.get(path) || recipe.writes.contains(path),
            "unexpected_changes"
        );
    }
    Ok(())
}
pub fn repo_lock(path: &Path) -> Result<File> {
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(git::common_dir(path)?.join("workbench.operation.lock"))
        .context("unsafe_repository_lock")?;
    let metadata = lock.metadata()?;
    ensure!(
        metadata.is_file() && metadata.uid() == unsafe { libc::getuid() },
        "unsafe_repository_lock"
    );
    // A second service may own the same common-dir. Never queue a write past
    // the caller's lifetime; let it retry after observing current Git state.
    lock.try_lock_exclusive().context("repository_busy")?;
    Ok(lock)
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub method: String,
    #[serde(default)]
    pub params: Value,
}
#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}
#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub schema_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorBody>,
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn interactive_write_after_preflight(method: &str) {
        let temp = tempfile::TempDir::new().unwrap();
        let home = temp.path().join("fixture");
        let workspace = fixtures::create(&home).unwrap();
        let path = workspace.repo("ios-app").unwrap().path.clone();
        let service = Service::open(workspace, &home.join("journal.sqlite")).unwrap();
        let file = "Config/Version.xcconfig";
        let changed =
            "// budget fixture\nMARKETING_VERSION = 2.4.0\nCURRENT_PROJECT_VERSION = 241\n";
        let original_head = git::oid(&path, "HEAD").unwrap();
        let untouched = fs::read(path.join("notes.txt")).unwrap();
        fs::write(path.join(file), changed).unwrap();
        let params = if method == "commit" {
            git::git(&path, &["add", "--", file]).unwrap();
            json!({"repo_id":"ios-app", "snapshot_hash":digest(&git::snapshot(&path).unwrap()).unwrap(), "message":"mutation budget regression"})
        } else if method == "stage_file" {
            json!({"repo_id":"ios-app", "path":file, "snapshot_hash":digest(&git::snapshot(&path).unwrap()).unwrap()})
        } else {
            let diff = git::diff(&path, file, false).unwrap();
            json!({"repo_id":"ios-app", "path":file, "hunk_index":0, "snapshot_hash":diff.snapshot_hash, "diff_hash":hash(diff.text.as_bytes())})
        };
        // Model twenty seconds of preflight already consumed, without a slow
        // wall-clock sleep. The real dispatch keeps this outer remaining budget.
        let remaining = Duration::from_secs(request_budget_seconds(method) - 20);
        let response = git::with_deadline(remaining, || {
            service.dispatch(Request {
                method: method.into(),
                params,
            })
        });
        assert!(response.error.is_none(), "{method}: {:?}", response.error);
        assert_eq!(
            git::git(&path, &["show", &format!(":{file}")]).unwrap(),
            changed
        );
        assert_eq!(fs::read(path.join("notes.txt")).unwrap(), untouched);
        if method == "commit" {
            assert_ne!(git::oid(&path, "HEAD").unwrap(), original_head);
            assert!(
                git::git_bytes(&path, &["diff", "--cached", "--name-only"])
                    .unwrap()
                    .is_empty()
            );
        } else {
            assert_eq!(git::oid(&path, "HEAD").unwrap(), original_head);
        }
    }

    #[test]
    fn hunk_staging_has_time_for_validation_after_twenty_seconds_of_preflight() {
        interactive_write_after_preflight("stage_hunk");
    }

    #[test]
    fn file_staging_has_time_for_validation_after_twenty_seconds_of_preflight() {
        interactive_write_after_preflight("stage_file");
    }

    #[test]
    fn committing_has_time_for_validation_after_twenty_seconds_of_preflight() {
        interactive_write_after_preflight("commit");
    }

    fn fixture(slug: &str) -> (tempfile::TempDir, Arc<Service>, Plan) {
        let temp = tempfile::TempDir::new().unwrap();
        let home = temp.path().join("fixture");
        fixtures::create(&home).unwrap();
        for recipe in ["api.set-version@1", "ios-app.set-version@1"] {
            fixtures::trust(&home.join("workspace.json"), recipe).unwrap();
        }
        let workspace = load_workspace(&home.join("workspace.json")).unwrap();
        let service = Service::open(workspace, &home.join("journal.sqlite")).unwrap();
        let plan = service
            .plan(TaskRequest {
                group_id: "ios-2-4".into(),
                label: "queued cancellation".into(),
                task_slug: slug.into(),
                mode: Mode::Materialize,
                repo_overrides: BTreeMap::new(),
            })
            .unwrap();
        (temp, service, plan)
    }

    fn terminal(service: &Service, id: &str) -> Operation {
        let start = Instant::now();
        loop {
            let operation = service.operation(id).unwrap();
            if !matches!(operation.status.as_str(), "queued" | "running") {
                return operation;
            }
            assert!(start.elapsed() < Duration::from_secs(10));
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn drained(service: &Service) {
        let start = Instant::now();
        while !service.active.lock().unwrap().is_empty() {
            assert!(start.elapsed() < Duration::from_secs(10));
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn preparation_control_bounds_workers_without_clamping_a_long_recipe() {
        assert_eq!(preparation_repo_budget(300), Duration::from_secs(840));
        assert!(preparation_repo_budget(300) > preparation_repo_budget(0));
        let result =
            preparation_read_control(Arc::new(AtomicBool::new(false)), Duration::ZERO, || {
                git::with_deadline(git::READ_PHASE_TIMEOUT, git::check_deadline)
            });
        assert_eq!(result.unwrap_err().to_string(), "git_timeout");
        git::check_deadline().unwrap();
    }

    #[test]
    fn worker_cancellation_context_reaches_strict_git_reads_before_any_write() {
        let (_temp, service, plan) = fixture("worker-read-cancel");
        let gate = service.mutations.lock().unwrap();
        let created = service.execute(&plan.id, "worker-read-cancel").unwrap();
        let flag = service
            .active
            .lock()
            .unwrap()
            .get(&created.id)
            .unwrap()
            .clone();
        let path = service
            .workspace
            .repo(&plan.repos[0].repo_id)
            .unwrap()
            .path
            .clone();
        *service.preparation_observer.lock().unwrap() = Some(Box::new(move |phase, index, _| {
            if phase == "before_source_read" && index == 0 {
                flag.store(true, Ordering::SeqCst);
                assert_eq!(git::snapshot(&path).unwrap_err().to_string(), "cancelled");
            }
        }));
        drop(gate);
        let completed = terminal(&service, &created.id);
        drained(&service);
        assert_eq!(completed.status, "cancelled");
        assert_eq!(completed.repos[0].state, RepoState::Cancelled);
        assert_eq!(completed.repos[0].error_code.as_deref(), Some("cancelled"));
        for repo in &completed.repos {
            assert!(!repo.plan.worktree_path.exists());
            assert!(
                !git::ref_exists(
                    &service.workspace.repo(&repo.plan.repo_id).unwrap().path,
                    &repo.plan.branch_ref
                )
                .unwrap()
            );
        }
    }

    #[test]
    fn post_recipe_cancellation_keeps_ready_peers_and_the_last_completed_checkpoint() {
        let (_temp, service, plan) = fixture("post-recipe-read-cancel");
        let gate = service.mutations.lock().unwrap();
        let created = service
            .execute(&plan.id, "post-recipe-read-cancel")
            .unwrap();
        let flag = service
            .active
            .lock()
            .unwrap()
            .get(&created.id)
            .unwrap()
            .clone();
        let checkpoint = Arc::new(Mutex::new(None));
        let captured = checkpoint.clone();
        *service.preparation_observer.lock().unwrap() = Some(Box::new(move |phase, index, op| {
            if phase == "after_recipe" && index == 1 {
                *captured.lock().unwrap() = Some(op.repos[index].clone());
                flag.store(true, Ordering::SeqCst);
            }
        }));
        drop(gate);
        let completed = terminal(&service, &created.id);
        drained(&service);
        let before = checkpoint.lock().unwrap().take().unwrap();
        assert_eq!(completed.status, "cancelled");
        assert_eq!(completed.repos[0].state, RepoState::Ready);
        let cancelled = &completed.repos[1];
        assert_eq!(cancelled.state, RepoState::Cancelled);
        assert_eq!(cancelled.error_code.as_deref(), Some("cancelled"));
        assert_eq!(cancelled.baseline, before.baseline);
        assert_eq!(cancelled.result_snapshot, before.result_snapshot);
        assert_eq!(cancelled.postcondition, before.postcondition);
        assert_eq!(cancelled.attempts, before.attempts);
        // The successful script write survives the interrupted observation.
        assert_eq!(
            runner::inspect(&cancelled.plan.worktree_path).unwrap(),
            cancelled.plan.policy.inputs.clone().unwrap()
        );
        assert_eq!(
            git::snapshot(
                &service
                    .workspace
                    .repo(&cancelled.plan.repo_id)
                    .unwrap()
                    .path
            )
            .unwrap(),
            cancelled.plan.source_snapshot
        );
    }

    #[test]
    fn task_and_pending_lookups_use_indexes_and_follow_checkpoint_updates() {
        let (_temp, service, plan) = fixture("journal-index");
        for (sql, index) in [
            (
                "EXPLAIN QUERY PLAN SELECT id,plan_id FROM operations WHERE json_extract(body, '$.task_id')='task'",
                "operations_task_id",
            ),
            (
                "EXPLAIN QUERY PLAN SELECT EXISTS(SELECT 1 FROM operations WHERE json_extract(body, '$.status') IN ('running','queued'))",
                "operations_status",
            ),
            (
                "EXPLAIN QUERY PLAN SELECT body FROM operations WHERE json_extract(body, '$.status') IN ('running','queued')",
                "operations_status",
            ),
        ] {
            let db = service.db();
            let mut stmt = db.prepare(sql).unwrap();
            let rows = stmt.query_map([], |row| row.get::<_, String>(3)).unwrap();
            assert!(
                rows.map(Result::unwrap)
                    .any(|detail| detail.contains(index)),
                "{sql}"
            );
        }
        let gate = service.mutations.lock().unwrap();
        let op = service.execute(&plan.id, "journal-index").unwrap();
        assert_eq!(service.task(&op.task_id).unwrap().operation_id, op.id);
        let pending = || {
            service.db().query_row("SELECT COUNT(*) FROM operations WHERE json_extract(body, '$.status') IN ('running','queued')", [], |row| row.get::<_, i64>(0)).unwrap()
        };
        assert_eq!(pending(), 1);
        service.cancel(&op.id).unwrap();
        drop(gate);
        assert_eq!(terminal(&service, &op.id).status, "cancelled");
        drained(&service);
        assert_eq!(pending(), 0);
        assert_eq!(service.task(&op.task_id).unwrap().operation_id, op.id);
        assert!(service.shutdown_if_idle().unwrap());
    }

    #[test]
    fn summary_miss_keeps_db_ownership_until_cache_publication() {
        let (_temp, service, plan) = fixture("summary-read-order");
        let gate = service.mutations.lock().unwrap();
        let op = service.execute(&plan.id, "summary-read-order").unwrap();
        service.cancel(&op.id).unwrap();
        let mut cache = service.summaries.lock().unwrap();
        cache.remove(&op.id);
        let reader_service = service.clone();
        let reader_id = op.id.clone();
        let reader = thread::spawn(move || reader_service.operation_summary(&reader_id).unwrap());
        // Reader blocks on the cache while retaining DB ownership; a writer
        // cannot publish a terminal row in between its read and write-back.
        let start = Instant::now();
        while service.db.try_lock().is_ok() {
            assert!(start.elapsed() < Duration::from_secs(5));
            thread::yield_now();
        }
        let mut terminal_op = op.clone();
        terminal_op.status = "cancelled".into();
        terminal_op.cancel_requested = true;
        let writer_service = service.clone();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let writer = thread::spawn(move || {
            entered_tx.send(()).unwrap();
            writer_service.save(&terminal_op).unwrap();
            done_tx.send(()).unwrap();
        });
        entered_rx.recv().unwrap();
        assert!(done_rx.recv_timeout(Duration::from_millis(30)).is_err());
        drop(cache);
        assert_eq!(reader.join().unwrap().status, "queued");
        writer.join().unwrap();
        assert_eq!(
            service.operation_summary(&op.id).unwrap().status,
            "cancelled"
        );
        drop(gate);
        assert_eq!(terminal(&service, &op.id).status, "cancelled");
        drained(&service);
    }

    #[test]
    fn initial_event_tail_is_recent_and_cursor_reads_still_increment() {
        let (_temp, service, _plan) = fixture("event-tail");
        {
            let mut db = service.db();
            let tx = db.transaction().unwrap();
            for _ in 0..1200 {
                tx.execute("INSERT INTO events(operation_id,timestamp,status) VALUES('synthetic-history',1,'ready')", []).unwrap();
            }
            tx.commit().unwrap();
        }
        let recent = service.recent_events().unwrap();
        assert_eq!(recent.len(), 200);
        assert_eq!(recent.first().unwrap().sequence, 1001);
        assert_eq!(recent.last().unwrap().sequence, 1200);
        assert_eq!(service.events(0).unwrap().first().unwrap().sequence, 1);
        service.db().execute("INSERT INTO events(operation_id,timestamp,status) VALUES('synthetic-new',2,'ready')", []).unwrap();
        let next = service.events(1200).unwrap();
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].sequence, 1201);
    }

    #[test]
    fn non_ready_task_writes_are_rejected_while_failed_worktree_remains_readable() {
        let (temp, service, plan) = fixture("failed-read-only");
        fs::write(
            temp.path().join("fixture/api.fail"),
            "synthetic recipe failure",
        )
        .unwrap();
        let op = service.execute(&plan.id, "failed-read-only").unwrap();
        let result = terminal(&service, &op.id);
        drained(&service);
        let failed = result
            .repos
            .iter()
            .find(|r| r.plan.repo_id == "api")
            .unwrap();
        assert!(failed.baseline.is_some());
        assert_ne!(failed.state, RepoState::Ready);
        let before = git::snapshot(&failed.plan.worktree_path).unwrap();
        let read = service.dispatch(Request {
            method: "get_repo_status".into(),
            params: json!({"repo_id":"api","op_id":op.id}),
        });
        assert!(read.error.is_none());
        for (method, params) in [
            (
                "stage_file",
                json!({"repo_id":"api","op_id":op.id,"path":"Config/Version.xcconfig","snapshot_hash":"unused"}),
            ),
            (
                "stage_hunk",
                json!({"repo_id":"api","op_id":op.id,"path":"Config/Version.xcconfig","hunk_index":0,"snapshot_hash":"unused","diff_hash":"unused"}),
            ),
            (
                "commit",
                json!({"repo_id":"api","op_id":op.id,"snapshot_hash":"unused","message":"must not write"}),
            ),
        ] {
            let response = service.dispatch(Request {
                method: method.into(),
                params,
            });
            assert_eq!(response.error.unwrap().code, "task_not_ready");
        }
        assert_eq!(git::snapshot(&failed.plan.worktree_path).unwrap(), before);
    }

    #[test]
    fn preparation_admission_bounds_bursts_and_preserves_replay_cancel_and_resume() {
        let (_temp, service, seed) = fixture("admission-seed");
        let mut request = seed.request.clone();
        request.mode = Mode::BranchOnly;
        request.task_slug = "admission-resume".into();
        let waiting_plan = service.plan(request).unwrap();
        let waiting = service
            .execute(&waiting_plan.id, "admission-resume")
            .unwrap();
        assert_eq!(
            terminal(&service, &waiting.id).status,
            "waiting_for_worktree"
        );
        drained(&service);
        let waiting_before = serde_json::to_value(service.operation(&waiting.id).unwrap()).unwrap();

        let plans: Vec<_> = (0..MAX_ADMITTED_PREPARATIONS + 4)
            .map(|index| {
                let mut request = seed.request.clone();
                request.task_slug = format!("admission-{index}");
                service.plan(request).unwrap()
            })
            .collect();
        // Keep every accepted worker alive before its first Git side effect.
        let gate = service.mutations.lock().unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(plans.len()));
        let results = thread::scope(|scope| {
            let handles: Vec<_> = plans
                .iter()
                .enumerate()
                .map(|(index, plan)| {
                    let service = service.clone();
                    let barrier = barrier.clone();
                    scope.spawn(move || {
                        barrier.wait();
                        (
                            index,
                            service.execute(&plan.id, &format!("admission-{index}")),
                        )
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .collect::<Vec<_>>()
        });
        let accepted: Vec<_> = results
            .iter()
            .filter_map(|(i, r)| r.as_ref().ok().map(|op| (*i, op)))
            .collect();
        let rejected: Vec<_> = results.iter().filter(|(_, r)| r.is_err()).collect();
        assert_eq!(accepted.len(), MAX_ADMITTED_PREPARATIONS);
        assert_eq!(rejected.len(), 4);
        assert_eq!(
            service.active.lock().unwrap().len(),
            MAX_ADMITTED_PREPARATIONS
        );
        for (_, result) in &rejected {
            assert_eq!(
                fail_code(result.as_ref().unwrap_err()),
                "preparation_queue_full"
            );
        }
        let (index, first) = accepted[0];
        assert_eq!(
            service
                .execute(&plans[index].id, &format!("admission-{index}"))
                .unwrap()
                .id,
            first.id
        );
        assert_eq!(
            service
                .execute(&seed.id, &format!("admission-{index}"))
                .unwrap_err()
                .to_string(),
            "idempotency_conflict"
        );
        let events_before = service.events(0).unwrap().len();
        assert_eq!(
            service.resume(&waiting.id, true).unwrap_err().to_string(),
            "preparation_queue_full"
        );
        assert_eq!(
            serde_json::to_value(service.operation(&waiting.id).unwrap()).unwrap(),
            waiting_before
        );
        assert_eq!(service.events(0).unwrap().len(), events_before);
        let stored: i64 = service
            .db()
            .query_row("SELECT COUNT(*) FROM operations", [], |row| row.get(0))
            .unwrap();
        assert_eq!(stored, (MAX_ADMITTED_PREPARATIONS + 1) as i64);
        assert!(!service.shutdown_if_idle().unwrap());
        for (_, op) in &accepted {
            service.cancel(&op.id).unwrap();
        }
        // Cancellation must not release capacity while its worker still waits.
        let rejected_index = rejected[0].0;
        let retry_key = format!("admission-{rejected_index}");
        assert_eq!(
            service
                .execute(&plans[rejected_index].id, &retry_key)
                .unwrap_err()
                .to_string(),
            "preparation_queue_full"
        );
        drop(gate);
        for (index, op) in &accepted {
            assert_eq!(terminal(&service, &op.id).status, "cancelled");
            for repo in &plans[*index].repos {
                assert!(!repo.worktree_path.exists());
                assert!(
                    !git::ref_exists(
                        &service.workspace.repo(&repo.repo_id).unwrap().path,
                        &repo.branch_ref
                    )
                    .unwrap()
                );
            }
        }
        drained(&service);
        let gate = service.mutations.lock().unwrap();
        let retried = service
            .execute(&plans[rejected_index].id, &retry_key)
            .unwrap();
        service.cancel(&retried.id).unwrap();
        drop(gate);
        assert_eq!(terminal(&service, &retried.id).status, "cancelled");
        drained(&service);
        service.resume(&waiting.id, true).unwrap();
        assert_eq!(terminal(&service, &waiting.id).status, "ready");
        drained(&service);
        assert!(service.shutdown_if_idle().unwrap());
    }

    #[test]
    fn summary_cache_matches_queued_cancellation_and_terminal_checkpoints() {
        let (_temp, service, plan) = fixture("summary-cache");
        let gate = service.mutations.lock().unwrap();
        let created = service.execute(&plan.id, "summary-cache").unwrap();
        let assert_current = || {
            let full = service.operation(&created.id).unwrap().summary().unwrap();
            let cached = service.operation_summary(&created.id).unwrap();
            assert_eq!(
                serde_json::to_value(full).unwrap(),
                serde_json::to_value(cached).unwrap()
            );
        };
        assert_current();
        service.cancel(&created.id).unwrap();
        assert!(
            service
                .operation_summary(&created.id)
                .unwrap()
                .cancel_requested
        );
        assert_current();
        drop(gate);
        let completed = terminal(&service, &created.id);
        assert_eq!(completed.status, "cancelled");
        assert_current();
    }

    #[test]
    fn cancellation_preserves_checkpoints_and_terminal_publication() {
        let (_temp, service, plan) = fixture("cancel-before-worker");
        // Gate the real worker before any Git side effect; no timing sleep is involved.
        let gate = service.mutations.lock().unwrap();
        let created = service.execute(&plan.id, "queued-cancellation").unwrap();
        assert!(service.cancel(&created.id).unwrap().cancel_requested);
        assert!(service.operation(&created.id).unwrap().cancel_requested);
        let mut stale_checkpoint = created.clone();
        stale_checkpoint.status = "running".into();
        stale_checkpoint
            .warnings
            .push("checkpoint progress retained".into());
        service.save(&stale_checkpoint).unwrap();
        let durable = service.operation(&created.id).unwrap();
        assert!(durable.cancel_requested);
        assert!(
            durable
                .warnings
                .contains(&"checkpoint progress retained".into())
        );
        drop(gate);
        let start = Instant::now();
        loop {
            let operation = service.operation(&created.id).unwrap();
            if !matches!(operation.status.as_str(), "queued" | "running") {
                assert_eq!(operation.status, "cancelled");
                assert!(
                    operation
                        .repos
                        .iter()
                        .all(|r| r.state == RepoState::Planned)
                );
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(5));
            thread::sleep(Duration::from_millis(5));
        }
        for repo in &plan.repos {
            assert!(!repo.worktree_path.exists());
            assert!(
                !git::ref_exists(
                    &service.workspace.repo(&repo.repo_id).unwrap().path,
                    &repo.branch_ref
                )
                .unwrap()
            );
        }
        service.resume(&created.id, true).unwrap();
        let start = Instant::now();
        loop {
            let operation = service.operation(&created.id).unwrap();
            if !matches!(operation.status.as_str(), "queued" | "running") {
                assert_eq!(operation.status, "ready", "{operation:?}");
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(10));
            thread::sleep(Duration::from_millis(5));
        }
        // Fault-inject the exact boundary after terminal save and before active removal.
        let late_flag = Arc::new(AtomicBool::new(false));
        service
            .active
            .lock()
            .unwrap()
            .insert(created.id.clone(), late_flag.clone());
        let before = serde_json::to_value(service.operation(&created.id).unwrap()).unwrap();
        let events_before = service.events(0).unwrap().len();
        assert_eq!(service.cancel(&created.id).unwrap().status, "ready");
        assert!(!late_flag.load(Ordering::SeqCst));
        assert_eq!(
            before,
            serde_json::to_value(service.operation(&created.id).unwrap()).unwrap()
        );
        assert_eq!(events_before, service.events(0).unwrap().len());
        service.active.lock().unwrap().remove(&created.id);
        assert!(service.shutdown_if_idle().unwrap());
    }

    #[test]
    fn failed_terminal_save_records_recovery_instead_of_orphaning_running_state() {
        let (_temp, service, plan) = fixture("terminal-write-fault");
        service
            .db()
            .execute_batch(
                "CREATE TRIGGER reject_ready BEFORE UPDATE ON operations
             WHEN json_extract(NEW.body,'$.status')='ready'
             BEGIN SELECT RAISE(FAIL,'synthetic_terminal_save_failure'); END;",
            )
            .unwrap();
        let created = service.execute(&plan.id, "terminal-write-fault").unwrap();
        let failed = terminal(&service, &created.id);
        assert_eq!(failed.status, "needs_recovery", "{failed:?}");
        assert!(failed.repos.iter().all(|r| r.state == RepoState::Ready));
        assert!(
            failed
                .warnings
                .iter()
                .any(|w| w.starts_with("Service error:"))
        );
        assert_eq!(
            service.cancel(&created.id).unwrap_err().to_string(),
            "operation_not_running"
        );
        let attempts: Vec<_> = failed.repos.iter().map(|r| r.attempts).collect();
        service
            .db()
            .execute_batch("DROP TRIGGER reject_ready")
            .unwrap();
        service.resume(&created.id, true).unwrap();
        let recovered = terminal(&service, &created.id);
        assert_eq!(recovered.status, "ready", "{recovered:?}");
        assert_eq!(
            attempts,
            recovered
                .repos
                .iter()
                .map(|r| r.attempts)
                .collect::<Vec<_>>()
        );
        assert!(service.shutdown_if_idle().unwrap());
    }

    #[test]
    fn late_cancel_keeps_completed_branch_only_preparation_materializable() {
        let (_temp, service, _plan) = fixture("unused-materialized-plan");
        let plan = service
            .plan(TaskRequest {
                group_id: "ios-2-4".into(),
                label: "branch-only completion".into(),
                task_slug: "branch-only-late-cancel".into(),
                mode: Mode::BranchOnly,
                repo_overrides: BTreeMap::new(),
            })
            .unwrap();
        let gate = service.mutations.lock().unwrap();
        let created = service
            .execute(&plan.id, "branch-only-late-cancel")
            .unwrap();
        let active = service.active.lock().unwrap();
        let flag = active.get(&created.id).unwrap().clone();
        drop(gate);
        // Hold final publication while the real worker completes every branch creation.
        let start = Instant::now();
        loop {
            let operation = service.operation(&created.id).unwrap();
            if operation
                .repos
                .iter()
                .all(|r| r.state == RepoState::WaitingForWorktree)
            {
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(10));
            thread::sleep(Duration::from_millis(5));
        }
        // Inject a cancellation accepted at the terminal publication boundary.
        service.db().execute(
            "UPDATE operations SET body=json_set(body,'$.cancel_requested',json('true')) WHERE id=?1",
            [&created.id],
        ).unwrap();
        flag.store(true, Ordering::SeqCst);
        drop(active);
        let waiting = terminal(&service, &created.id);
        assert_eq!(waiting.status, "waiting_for_worktree");
        assert!(waiting.cancel_requested);
        service.resume(&created.id, true).unwrap();
        assert_eq!(terminal(&service, &created.id).status, "ready");
        assert!(service.shutdown_if_idle().unwrap());
    }
}

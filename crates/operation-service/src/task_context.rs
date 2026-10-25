use super::*;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextTarget {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SaveContext {
    repo_id: String,
    context_op_id: Option<String>,
    expected_revision: u64,
    purpose: String,
    criteria: Vec<String>,
    references: Vec<String>,
    notes: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckRequest {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
    snapshot_hash: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ReportKind {
    HumanReport,
    AiReport,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReportRequest {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
    kind: ReportKind,
    verdict: Verdict,
    command: String,
    note: String,
}

impl Service {
    pub(super) fn context_scope(
        &self,
        repo: &str,
        op: Option<&str>,
        context: Option<&str>,
    ) -> Result<String> {
        self.workspace.repo(repo)?;
        if let Some(context) = context.or(op) {
            let context = self.operation_summary(context)?;
            ensure!(
                context.repos.iter().any(|r| r.plan.repo_id == repo),
                "unknown_task_repo"
            );
            if let Some(op) = op {
                ensure!(
                    self.operation_summary(op)?.task_id == context.task_id,
                    "task_context_mismatch"
                );
            }
            Ok(format!("task:{}", context.task_id))
        } else {
            Ok(format!("repo:{repo}"))
        }
    }
    pub(super) fn read_context(db: &Connection, scope: &str) -> Result<TaskContext> {
        let body: Option<String> = db
            .query_row(
                "SELECT body FROM task_contexts WHERE scope=?1",
                [scope],
                |r| r.get(0),
            )
            .optional()?;
        let mut context = body
            .map(|s| serde_json::from_str(&s))
            .transpose()?
            .unwrap_or_default();
        TaskContext::normalize(&mut context)?;
        Ok(context)
    }
    fn context_bundle(&self, scope: &str) -> Result<TaskContextBundle> {
        let db = self.db();
        let context = Self::read_context(&db, scope)?;
        let mut stmt = db.prepare(
            "SELECT body FROM verification_receipts WHERE scope=?1 ORDER BY rowid DESC LIMIT 50",
        )?;
        let rows = stmt.query_map([scope], |r| r.get::<_, String>(0))?;
        let verifications = rows
            .map(|r| Ok(serde_json::from_str(&r?)?))
            .collect::<Result<_>>()?;
        Ok(TaskContextBundle {
            workflow_version: Some(2),
            context,
            verifications,
        })
    }
    fn save_receipt(&self, scope: &str, receipt: &VerificationReceipt) -> Result<()> {
        self.db().execute(
            "INSERT INTO verification_receipts(id,scope,body) VALUES(?1,?2,?3)",
            params![receipt.id, scope, serde_json::to_string(receipt)?],
        )?;
        Ok(())
    }
    pub(super) fn handle_task_context(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "get_task_context" => {
                let p: ContextTarget = serde_json::from_value(params)?;
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                Ok(serde_json::to_value(self.context_bundle(&scope)?)?)
            }
            "save_task_context" => {
                let p: SaveContext = serde_json::from_value(params)?;
                let scope = self.context_scope(&p.repo_id, None, p.context_op_id.as_deref())?;
                let mut context = TaskContext {
                    revision: p
                        .expected_revision
                        .checked_add(1)
                        .context("context_revision_overflow")?,
                    purpose: p.purpose,
                    criteria: p.criteria,
                    references: p.references,
                    notes: p.notes,
                    requirements_hash: String::new(),
                };
                context.normalize()?;
                {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let upgraded: bool = tx.query_row(
                        "SELECT EXISTS(SELECT 1 FROM workflow_states WHERE scope=?1)",
                        [&scope],
                        |r| r.get(0),
                    )?;
                    ensure!(
                        !upgraded,
                        "workflow_upgrade_required: use the workflow editor to preserve criterion identities"
                    );
                    ensure!(
                        Self::read_context(&tx, &scope)?.revision == p.expected_revision,
                        "context_conflict: reload the saved context before editing again"
                    );
                    tx.execute("INSERT INTO task_contexts(scope,body) VALUES(?1,?2) ON CONFLICT(scope) DO UPDATE SET body=excluded.body",
                        params![scope, serde_json::to_string(&context)?])?;
                    tx.commit()?;
                }
                Ok(serde_json::to_value(self.context_bundle(&scope)?)?)
            }
            "run_git_check" => {
                let p: CheckRequest = serde_json::from_value(params)?;
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                let _guard = self
                    .mutations
                    .try_lock()
                    .map_err(|_| anyhow::anyhow!("repository_busy"))?;
                ensure!(!self.is_stopping(), "service_stopping");
                let path = self.target(&p.repo_id, p.op_id.as_deref())?;
                let _lock = repo_lock(&path)?;
                let path = self.target(&p.repo_id, p.op_id.as_deref())?;
                let before = git::snapshot(&path)?;
                ensure!(digest(&before)? == p.snapshot_hash, "stale_snapshot");
                let requirements_hash = Self::read_context(&self.db(), &scope)?.requirements_hash;
                let started_at = now();
                let (mut verdict, mut output, truncated) = git::check_changes(&path)?;
                let after = git::snapshot(&path).and_then(|s| digest(&s));
                let after_snapshot_hash = match after {
                    Ok(hash) => {
                        if hash != p.snapshot_hash {
                            verdict = Verdict::Unknown;
                            output.push_str("Repository changed during verification.\n");
                        }
                        Some(hash)
                    }
                    Err(error) => {
                        verdict = Verdict::Unknown;
                        output.push_str(&format!("After-state unavailable: {error}\n"));
                        None
                    }
                };
                let receipt = VerificationReceipt { id: id(), repo_id: p.repo_id, op_id: p.op_id, path,
                    branch: before.branch, head: before.head, snapshot_hash: p.snapshot_hash, after_snapshot_hash,
                    requirements_hash, kind: EvidenceKind::GitCheck, verdict, started_at, finished_at: now(),
                    command: "git diff --check (working + index); Git conflict/in-progress check".into(),
                    note: "추적 중인 파일과 스테이징만 검사했습니다. 새 파일·서브모듈 내용·빌드·테스트는 검사하지 않았습니다.".into(),
                    output, truncated };
                self.save_receipt(&scope, &receipt)?;
                Ok(serde_json::to_value(self.context_bundle(&scope)?)?)
            }
            "record_verification_report" => {
                let p: ReportRequest = serde_json::from_value(params)?;
                ensure!(
                    !p.note.trim().is_empty() && p.note.len() <= 20_000 && p.command.len() <= 2_000,
                    "invalid_verification_report"
                );
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                let path = self.target(&p.repo_id, p.op_id.as_deref())?;
                let snapshot = git::snapshot(&path)?;
                let receipt = VerificationReceipt {
                    id: id(),
                    repo_id: p.repo_id,
                    op_id: p.op_id,
                    path,
                    snapshot_hash: digest(&snapshot)?,
                    branch: snapshot.branch,
                    head: snapshot.head,
                    after_snapshot_hash: None,
                    requirements_hash: Self::read_context(&self.db(), &scope)?.requirements_hash,
                    kind: match p.kind {
                        ReportKind::HumanReport => EvidenceKind::HumanReport,
                        ReportKind::AiReport => EvidenceKind::AiReport,
                    },
                    verdict: p.verdict,
                    started_at: now(),
                    finished_at: now(),
                    command: p.command.trim().into(),
                    note: p.note.trim().into(),
                    output: String::new(),
                    truncated: false,
                };
                self.save_receipt(&scope, &receipt)?;
                Ok(serde_json::to_value(self.context_bundle(&scope)?)?)
            }
            _ => bail!("unknown_method"),
        }
    }
}

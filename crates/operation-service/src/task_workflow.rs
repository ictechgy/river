//! Typed workflow metadata lives beside (never inside) the legacy journal JSON.
//! Every write compares the exact legacy projection and both revisions, so a
//! sequential old-engine rewrite cannot silently reassign criterion identity.
use super::*;
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CriterionInput {
    id: String,
    text: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Save {
    repo_id: String,
    context_op_id: Option<String>,
    expected_context_revision: u64,
    expected_workflow_revision: u64,
    purpose: String,
    criteria: Vec<CriterionInput>,
    references: Vec<String>,
    notes: String,
    guides: Vec<GuideReference>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reset {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
    expected_context_revision: u64,
    expected_workflow_revision: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ReportKind {
    HumanReport,
    AiReport,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Report {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
    expected_context_revision: u64,
    expected_workflow_revision: u64,
    snapshot_hash: String,
    kind: ReportKind,
    verdict: Verdict,
    command: String,
    note: String,
    criterion_ids: Vec<String>,
    claimed_reviewed_state: Option<ClaimedReviewedState>,
    provider: String,
    model: String,
    artifacts: Vec<String>,
    report_status: ReportStatus,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GuideRead {
    repo_id: String,
    op_id: Option<String>,
    context_op_id: Option<String>,
    guide_id: String,
    expected_context_revision: u64,
    expected_workflow_revision: u64,
}

#[derive(Serialize, Deserialize)]
struct Version {
    context: TaskContext,
    workflow: TaskWorkflowState,
}
struct State {
    context: TaskContext,
    workflow: TaskWorkflowState,
    legacy_body_hash: String,
    compatible: bool,
}

fn uuid(value: &str) -> Result<()> {
    let parsed = Uuid::parse_str(value).context("invalid_workflow_id")?;
    ensure!(
        parsed.hyphenated().to_string() == value.to_ascii_lowercase(),
        "invalid_workflow_id"
    );
    // One canonical spelling prevents alternate textual aliases of one UUID.
    ensure!(
        value == parsed.hyphenated().to_string(),
        "invalid_workflow_id"
    );
    Ok(())
}
fn hex(value: &str, lengths: &[usize]) -> bool {
    lengths.contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn next(value: u64) -> Result<u64> {
    value.checked_add(1).context("workflow_revision_overflow")
}
fn legacy_body(db: &Connection, scope: &str) -> Result<Option<String>> {
    Ok(db
        .query_row(
            "SELECT body FROM task_contexts WHERE scope=?1",
            [scope],
            |r| r.get(0),
        )
        .optional()?)
}
fn intent(context: &TaskContext) -> Result<String> {
    digest(&(&context.purpose, &context.references))
}
fn register_id(db: &Connection, scope: &str, id: &str) -> Result<()> {
    db.execute(
        "INSERT INTO workflow_ids(id,scope) VALUES(?1,?2)",
        params![id, scope],
    )?;
    Ok(())
}
fn save_state(
    db: &Connection,
    scope: &str,
    context: &TaskContext,
    state: &TaskWorkflowState,
    body_hash: &str,
) -> Result<()> {
    db.execute("INSERT INTO workflow_states(scope,body,legacy_revision,legacy_body_hash) VALUES(?1,?2,?3,?4) ON CONFLICT(scope) DO UPDATE SET body=excluded.body,legacy_revision=excluded.legacy_revision,legacy_body_hash=excluded.legacy_body_hash",
        params![scope,serde_json::to_string(state)?,i64::try_from(context.revision)?,body_hash])?;
    // Never replace old versions: even reset appends a fresh immutable version.
    db.execute(
        "INSERT INTO workflow_versions(scope,revision,body,saved_at) VALUES(?1,?2,?3,?4)",
        params![
            scope,
            i64::try_from(state.revision)?,
            serde_json::to_string(&Version {
                context: context.clone(),
                workflow: state.clone()
            })?,
            i64::try_from(now())?
        ],
    )?;
    Ok(())
}
fn fresh_criteria(
    db: &Connection,
    scope: &str,
    criteria: &[String],
) -> Result<Vec<WorkflowCriterion>> {
    criteria
        .iter()
        .map(|text| {
            let criterion = WorkflowCriterion {
                id: id(),
                revision: 1,
                text: text.clone(),
            };
            register_id(db, scope, &criterion.id)?;
            Ok(criterion)
        })
        .collect()
}
fn retired_count(db: &Connection, scope: &str, active: usize) -> Result<u64> {
    let total: i64 = db.query_row(
        "SELECT COUNT(*) FROM workflow_ids WHERE scope=?1",
        [scope],
        |r| r.get(0),
    )?;
    Ok(u64::try_from(total)?.saturating_sub(active as u64))
}

impl Service {
    /// Call only while holding a transaction. First use migrates duplicate text
    /// occurrences independently without rewriting any legacy JSON or receipt.
    fn workflow_state(db: &Connection, scope: &str) -> Result<State> {
        let context = Self::read_context(db, scope)?;
        let body_hash = digest(&legacy_body(db, scope)?)?;
        let stored: Option<(String, i64, String)> = db
            .query_row(
                "SELECT body,legacy_revision,legacy_body_hash FROM workflow_states WHERE scope=?1",
                [scope],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((body, revision, expected)) = stored {
            let workflow = serde_json::from_str(&body)?;
            Ok(State {
                compatible: u64::try_from(revision)? == context.revision && expected == body_hash,
                context,
                workflow,
                legacy_body_hash: body_hash,
            })
        } else {
            let criteria = fresh_criteria(db, scope, &context.criteria)?;
            let workflow = TaskWorkflowState {
                revision: 1,
                context_revision: context.revision,
                intent_hash: intent(&context)?,
                criteria,
                guides: vec![],
                retired_count: 0,
            };
            save_state(db, scope, &context, &workflow, &body_hash)?;
            Ok(State {
                context,
                workflow,
                legacy_body_hash: body_hash,
                compatible: true,
            })
        }
    }
    fn workflow_cas(state: &State, context_revision: u64, workflow_revision: u64) -> Result<()> {
        ensure!(
            state.compatible,
            "workflow_legacy_changed: explicitly reset workflow identities after inspecting the legacy changes"
        );
        Self::workflow_revisions(state, context_revision, workflow_revision)
    }
    fn workflow_revisions(
        state: &State,
        context_revision: u64,
        workflow_revision: u64,
    ) -> Result<()> {
        ensure!(
            state.context.revision == context_revision
                && state.workflow.revision == workflow_revision,
            "workflow_conflict: reload the saved workflow before editing again"
        );
        Ok(())
    }
    fn workflow_bundle(&self, scope: &str) -> Result<TaskWorkflowBundle> {
        let mut db = self.db();
        let tx = db.transaction()?;
        let state = Self::workflow_state(&tx, scope)?;
        let mut verifications = Vec::new();
        let mut evidence = Vec::new();
        {
            // Metadata is optional and unique per receipt. Select the same
            // newest fifty journal rows in one statement; older unlinked rows
            // must neither disappear nor expand the retrieval window.
            let mut stmt = tx.prepare("SELECT r.body,e.body FROM verification_receipts r LEFT JOIN workflow_evidence e ON e.receipt_id=r.id AND e.scope=r.scope WHERE r.scope=?1 ORDER BY r.rowid DESC LIMIT 50")?;
            for row in stmt.query_map([scope], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
            })? {
                let (receipt, metadata) = row?;
                verifications.push(serde_json::from_str::<VerificationReceipt>(&receipt)?);
                if let Some(body) = metadata {
                    evidence.push(serde_json::from_str(&body)?);
                }
            }
        }
        let history = {
            let mut stmt = tx.prepare("SELECT revision,body,saved_at FROM workflow_versions WHERE scope=?1 ORDER BY revision DESC LIMIT 10")?;
            stmt.query_map([scope], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })?
            .map(|r| {
                let (revision, body, saved_at) = r?;
                let version: Version = serde_json::from_str(&body)?;
                Ok(WorkflowHistoryEntry {
                    revision: u64::try_from(revision)?,
                    context_revision: version.context.revision,
                    saved_at: u64::try_from(saved_at)?,
                    criterion_count: version.workflow.criteria.len() as u64,
                })
            })
            .collect::<Result<_>>()?
        };
        tx.commit()?;
        Ok(TaskWorkflowBundle {
            version: 2,
            compatibility: if state.compatible {
                "current"
            } else {
                "legacy_changed"
            }
            .into(),
            context: state.context,
            verifications,
            workflow: state.workflow,
            evidence,
            history,
        })
    }
    fn validate_guides(
        &self,
        guides: &mut [GuideReference],
        op: Option<&str>,
        context: Option<&str>,
        scope: &str,
    ) -> Result<()> {
        ensure!(
            guides.len() <= 10,
            "invalid_workflow_guides: at most ten guides"
        );
        let mut ids = BTreeSet::new();
        for guide in guides {
            uuid(&guide.id)?;
            ensure!(
                ids.insert(&guide.id),
                "invalid_workflow_guides: duplicate guide ID"
            );
            ensure!(
                self.context_scope(&guide.repo_id, op, context)? == scope,
                "guide_scope_mismatch"
            );
            verification_guide::validate_guide_path(&guide.path)?;
            if let Some(pin) = &mut guide.expected_sha256 {
                ensure!(
                    hex(pin, &[64]),
                    "invalid_workflow_guides: invalid SHA-256 pin"
                );
                *pin = pin.to_ascii_lowercase();
            }
        }
        Ok(())
    }
    pub(super) fn handle_task_workflow(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "get_task_workflow" => {
                let p: Target = serde_json::from_value(params)?;
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                Ok(serde_json::to_value(self.workflow_bundle(&scope)?)?)
            }
            "save_task_workflow" => {
                let mut p: Save = serde_json::from_value(params)?;
                let scope = self.context_scope(&p.repo_id, None, p.context_op_id.as_deref())?;
                self.validate_guides(&mut p.guides, None, p.context_op_id.as_deref(), &scope)?;
                ensure!(
                    p.criteria.len() <= 30,
                    "invalid_task_context: at most thirty criteria"
                );
                let mut context = TaskContext {
                    revision: next(p.expected_context_revision)?,
                    purpose: p.purpose,
                    criteria: p.criteria.iter().map(|c| c.text.clone()).collect(),
                    references: p.references,
                    notes: p.notes,
                    requirements_hash: String::new(),
                };
                context.normalize()?;
                // Empty rows must not silently drop an identity during normalization.
                ensure!(
                    context.criteria.len() == p.criteria.len(),
                    "invalid_workflow_criteria: empty criterion"
                );
                {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let old = Self::workflow_state(&tx, &scope)?;
                    Self::workflow_cas(
                        &old,
                        p.expected_context_revision,
                        p.expected_workflow_revision,
                    )?;
                    let mut ids = BTreeSet::new();
                    let mut criteria = Vec::new();
                    for (input, text) in p.criteria.into_iter().zip(&context.criteria) {
                        uuid(&input.id)?;
                        ensure!(
                            ids.insert(input.id.clone()),
                            "invalid_workflow_criteria: duplicate ID"
                        );
                        let revision = if let Some(previous) =
                            old.workflow.criteria.iter().find(|c| c.id == input.id)
                        {
                            if previous.text == *text {
                                previous.revision
                            } else {
                                next(previous.revision)?
                            }
                        } else {
                            let owner: Option<String> = tx
                                .query_row(
                                    "SELECT scope FROM workflow_ids WHERE id=?1",
                                    [&input.id],
                                    |r| r.get(0),
                                )
                                .optional()?;
                            ensure!(
                                owner.is_none(),
                                "workflow_retired_or_foreign_id: deleted or foreign criterion IDs cannot be reused"
                            );
                            register_id(&tx, &scope, &input.id)?;
                            1
                        };
                        criteria.push(WorkflowCriterion {
                            id: input.id,
                            revision,
                            text: text.clone(),
                        });
                    }
                    let workflow = TaskWorkflowState {
                        revision: next(old.workflow.revision)?,
                        context_revision: context.revision,
                        intent_hash: intent(&context)?,
                        retired_count: retired_count(&tx, &scope, criteria.len())?,
                        criteria,
                        guides: p.guides,
                    };
                    let body = serde_json::to_string(&context)?;
                    tx.execute("INSERT INTO task_contexts(scope,body) VALUES(?1,?2) ON CONFLICT(scope) DO UPDATE SET body=excluded.body",params![scope,body])?;
                    save_state(&tx, &scope, &context, &workflow, &digest(&Some(body))?)?;
                    tx.commit()?;
                }
                Ok(serde_json::to_value(self.workflow_bundle(&scope)?)?)
            }
            "reset_task_workflow" => {
                let p: Reset = serde_json::from_value(params)?;
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                // Validate any preserved guide scopes before taking the database lock.
                let existing = self.workflow_bundle(&scope)?;
                let mut guides = existing.workflow.guides;
                self.validate_guides(
                    &mut guides,
                    p.op_id.as_deref(),
                    p.context_op_id.as_deref(),
                    &scope,
                )?;
                {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let old = Self::workflow_state(&tx, &scope)?;
                    Self::workflow_revisions(
                        &old,
                        p.expected_context_revision,
                        p.expected_workflow_revision,
                    )?;
                    ensure!(!old.compatible, "workflow_reset_not_required");
                    let criteria = fresh_criteria(&tx, &scope, &old.context.criteria)?;
                    let workflow = TaskWorkflowState {
                        revision: next(old.workflow.revision)?,
                        context_revision: old.context.revision,
                        intent_hash: intent(&old.context)?,
                        retired_count: retired_count(&tx, &scope, criteria.len())?,
                        criteria,
                        guides,
                    };
                    save_state(&tx, &scope, &old.context, &workflow, &old.legacy_body_hash)?;
                    tx.commit()?;
                }
                Ok(serde_json::to_value(self.workflow_bundle(&scope)?)?)
            }
            "record_workflow_report" => {
                let mut p: Report = serde_json::from_value(params)?;
                ensure!(
                    !p.note.trim().is_empty() && p.note.len() <= 20_000 && p.command.len() <= 2_000,
                    "invalid_verification_report"
                );
                ensure!(
                    p.provider.len() <= 200
                        && p.model.len() <= 200
                        && p.artifacts.len() <= 10
                        && p.artifacts
                            .iter()
                            .all(|a| !a.trim().is_empty() && a.len() <= 2_048),
                    "invalid_verification_metadata"
                );
                ensure!(
                    p.criterion_ids.len() <= 30
                        && p.criterion_ids.iter().collect::<BTreeSet<_>>().len()
                            == p.criterion_ids.len(),
                    "invalid_workflow_criteria"
                );
                ensure!(hex(&p.snapshot_hash, &[64]), "invalid_snapshot_hash");
                if let Some(claimed) = &mut p.claimed_reviewed_state {
                    ensure!(
                        claimed.head.is_some() || claimed.snapshot_hash.is_some(),
                        "invalid_claimed_reviewed_state"
                    );
                    if let Some(head) = &mut claimed.head {
                        ensure!(hex(head, &[40, 64]), "invalid_claimed_reviewed_state");
                        *head = head.to_ascii_lowercase();
                    }
                    if let Some(snapshot) = &mut claimed.snapshot_hash {
                        ensure!(hex(snapshot, &[64]), "invalid_claimed_reviewed_state");
                        *snapshot = snapshot.to_ascii_lowercase();
                    }
                }
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
                let snapshot = git::snapshot(&path)?;
                ensure!(digest(&snapshot)? == p.snapshot_hash, "stale_snapshot");
                {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let state = Self::workflow_state(&tx, &scope)?;
                    Self::workflow_cas(
                        &state,
                        p.expected_context_revision,
                        p.expected_workflow_revision,
                    )?;
                    let criteria = p
                        .criterion_ids
                        .iter()
                        .map(|id| {
                            state
                                .workflow
                                .criteria
                                .iter()
                                .find(|c| &c.id == id)
                                .cloned()
                                .context("unknown_workflow_criterion")
                        })
                        .collect::<Result<Vec<_>>>()?;
                    let receipt = VerificationReceipt {
                        id: id(),
                        repo_id: p.repo_id,
                        op_id: p.op_id,
                        path,
                        branch: snapshot.branch,
                        head: snapshot.head,
                        snapshot_hash: p.snapshot_hash,
                        after_snapshot_hash: None,
                        requirements_hash: state.context.requirements_hash,
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
                    let evidence = WorkflowEvidence {
                        receipt_id: receipt.id.clone(),
                        criteria,
                        intent_hash: state.workflow.intent_hash,
                        claimed_reviewed_state: p.claimed_reviewed_state,
                        provider: p.provider.trim().into(),
                        model: p.model.trim().into(),
                        artifacts: p.artifacts,
                        report_status: p.report_status,
                    };
                    tx.execute(
                        "INSERT INTO verification_receipts(id,scope,body) VALUES(?1,?2,?3)",
                        params![receipt.id, scope, serde_json::to_string(&receipt)?],
                    )?;
                    tx.execute(
                        "INSERT INTO workflow_evidence(receipt_id,scope,body) VALUES(?1,?2,?3)",
                        params![receipt.id, scope, serde_json::to_string(&evidence)?],
                    )?;
                    tx.commit()?;
                }
                Ok(serde_json::to_value(self.workflow_bundle(&scope)?)?)
            }
            "read_verification_guide" => {
                let p: GuideRead = serde_json::from_value(params)?;
                let scope =
                    self.context_scope(&p.repo_id, p.op_id.as_deref(), p.context_op_id.as_deref())?;
                let guide = {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let state = Self::workflow_state(&tx, &scope)?;
                    Self::workflow_cas(
                        &state,
                        p.expected_context_revision,
                        p.expected_workflow_revision,
                    )?;
                    let guide = state
                        .workflow
                        .guides
                        .iter()
                        .find(|g| g.id == p.guide_id)
                        .cloned()
                        .context("unknown_verification_guide")?;
                    ensure!(guide.repo_id == p.repo_id, "guide_repo_mismatch");
                    tx.commit()?;
                    guide
                };
                let root = self.target(&p.repo_id, p.op_id.as_deref())?;
                let file = verification_guide::read_guide_file(&root, &guide.path)?;
                // Revalidate after the bounded filesystem read before returning a
                // preview labeled with this context revision.
                {
                    let mut db = self.db();
                    let tx = db.transaction()?;
                    let state = Self::workflow_state(&tx, &scope)?;
                    Self::workflow_cas(
                        &state,
                        p.expected_context_revision,
                        p.expected_workflow_revision,
                    )?;
                    tx.commit()?;
                }
                let status = match &guide.expected_sha256 {
                    None => "unread",
                    Some(pin) if pin == &file.sha256 => "matching",
                    Some(_) => "changed",
                };
                Ok(serde_json::to_value(VerificationGuideContents {
                    repo_id: p.repo_id,
                    op_id: p.op_id,
                    path: file.path,
                    sha256: file.sha256,
                    expected_sha256: guide.expected_sha256,
                    status: status.into(),
                    content: file.content,
                    format: "plain_text".into(),
                    read_at: now(),
                })?)
            }
            _ => bail!("unknown_method"),
        }
    }
}

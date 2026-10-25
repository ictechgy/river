use anyhow::{Result, bail, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
};
mod task_context;
pub use task_context::*;
mod task_workflow;
pub use task_workflow::*;
mod remotes;
pub use remotes::*;

pub type ResolvedPolicy = (String, Policy, BTreeMap<String, String>);

pub fn hash(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}
pub fn digest(value: &impl Serialize) -> Result<String> {
    Ok(hash(serde_json::to_vec(value)?))
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub base_ref: Option<String>,
    pub branch_pattern: Option<String>,
    pub recipe: Option<String>,
    pub inputs: Option<IosInputs>,
}
impl Policy {
    pub fn overlay(&mut self, other: &Self, source: &str, origins: &mut BTreeMap<String, String>) {
        macro_rules! field {
            ($f:ident) => {
                if other.$f.is_some() {
                    self.$f = other.$f.clone();
                    origins.insert(stringify!($f).into(), source.into());
                }
            };
        }
        field!(base_ref);
        field!(branch_pattern);
        field!(recipe);
        field!(inputs);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BranchGroup {
    pub id: String,
    pub parent_group_id: Option<String>,
    pub template_id: Option<String>,
    #[serde(default)]
    pub policy: Policy,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskTemplate {
    pub id: String,
    pub repos: BTreeMap<String, Policy>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Repository {
    pub id: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct IosInputs {
    pub marketing_version: String,
    pub local_build: String,
}
impl IosInputs {
    pub fn validate(&self) -> Result<()> {
        let parts: Vec<_> = self.marketing_version.split('.').collect();
        ensure!(
            parts.len() == 3
                && parts.iter().all(|p| !p.is_empty()
                    && p.len() <= 6
                    && p.bytes().all(|b| b.is_ascii_digit())),
            "invalid_inputs: marketing_version must be three numeric components"
        );
        ensure!(
            !self.local_build.is_empty()
                && self.local_build.len() <= 9
                && self.local_build.bytes().all(|b| b.is_ascii_digit()),
            "invalid_inputs: local_build must be explicit digits"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Recipe {
    pub id: String,
    pub repo_id: String,
    pub revision: u32,
    pub executable: PathBuf,
    pub script: String,
    pub writes: Vec<String>,
    pub timeout_seconds: u64,
    pub target: String,
    pub configuration: String,
    /// Only the explicit local `trust` command writes this pin. No RPC can change it.
    pub trusted_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub schema_version: u32,
    pub id: String,
    pub worktree_root: PathBuf,
    #[serde(default)]
    pub user_defaults: Policy,
    #[serde(default)]
    pub policy: Policy,
    pub repositories: Vec<Repository>,
    pub groups: Vec<BranchGroup>,
    pub templates: Vec<TaskTemplate>,
    pub recipes: Vec<Recipe>,
}
impl Workspace {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.schema_version == 1, "unsupported_schema");
        fn unique<'a>(ids: impl Iterator<Item = &'a String>) -> Result<()> {
            let mut seen = BTreeSet::new();
            for id in ids {
                ensure!(
                    !id.is_empty() && seen.insert(id),
                    "duplicate_or_empty_id: {id}"
                );
            }
            Ok(())
        }
        unique(self.repositories.iter().map(|v| &v.id))?;
        unique(self.groups.iter().map(|v| &v.id))?;
        unique(self.templates.iter().map(|v| &v.id))?;
        unique(self.recipes.iter().map(|v| &v.id))?;
        for group in &self.groups {
            self.lineage(&group.id)?;
            if let Some(t) = &group.template_id {
                ensure!(
                    self.templates.iter().any(|v| &v.id == t),
                    "unknown_template: {t}"
                );
            }
        }
        for t in &self.templates {
            ensure!(!t.repos.is_empty(), "empty_template");
            for (id, p) in &t.repos {
                self.repo(id)?;
                self.validate_policy(p, Some(id))?;
            }
        }
        self.validate_policy(&self.user_defaults, None)?;
        self.validate_policy(&self.policy, None)?;
        for g in &self.groups {
            self.validate_policy(&g.policy, None)?;
        }
        for r in &self.recipes {
            self.repo(&r.repo_id)?;
            ensure!(
                r.timeout_seconds > 0 && r.timeout_seconds <= 300,
                "invalid_timeout"
            );
            ensure!(r.executable.is_absolute(), "executable_must_be_absolute");
            safe_relative(&r.script)?;
            ensure!(
                r.writes == ["Config/Version.xcconfig"],
                "unsupported_adapter: initial adapter only supports Config/Version.xcconfig"
            );
            ensure!(
                !r.target.is_empty() && !r.configuration.is_empty(),
                "missing_target_configuration"
            );
        }
        Ok(())
    }
    fn validate_policy(&self, p: &Policy, repo: Option<&String>) -> Result<()> {
        if let Some(id) = &p.recipe {
            let r = self.recipe(id)?;
            if let Some(repo) = repo {
                ensure!(&r.repo_id == repo, "recipe_repo_mismatch");
            }
        }
        if let Some(inputs) = &p.inputs {
            inputs.validate()?;
        }
        Ok(())
    }
    pub fn repo(&self, id: &str) -> Result<&Repository> {
        self.repositories
            .iter()
            .find(|v| v.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown_repo: {id}"))
    }
    pub fn recipe(&self, id: &str) -> Result<&Recipe> {
        self.recipes
            .iter()
            .find(|v| v.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown_recipe: {id}"))
    }
    pub fn lineage(&self, id: &str) -> Result<Vec<&BranchGroup>> {
        let mut result = vec![];
        let mut current = Some(id);
        let mut seen = BTreeSet::new();
        while let Some(id) = current {
            ensure!(seen.insert(id), "cyclic_group: {id}");
            let group = self
                .groups
                .iter()
                .find(|v| v.id == id)
                .ok_or_else(|| anyhow::anyhow!("unknown_group: {id}"))?;
            result.push(group);
            current = group.parent_group_id.as_deref();
        }
        result.reverse();
        Ok(result)
    }
    pub fn resolve(&self, request: &TaskRequest) -> Result<Vec<ResolvedPolicy>> {
        self.validate()?;
        ensure!(
            !request.label.trim().is_empty()
                && request.label.len() <= 200
                && !request.label.contains(['\n', '\r']),
            "invalid_label"
        );
        ensure!(
            !request.task_slug.is_empty()
                && request.task_slug.len() <= 64
                && request
                    .task_slug
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && !request.task_slug.starts_with('-'),
            "invalid_slug"
        );
        let lineage = self.lineage(&request.group_id)?;
        let template_id = lineage
            .iter()
            .rev()
            .find_map(|g| g.template_id.as_ref())
            .ok_or_else(|| anyhow::anyhow!("missing_template"))?;
        let template = self
            .templates
            .iter()
            .find(|t| &t.id == template_id)
            .ok_or_else(|| anyhow::anyhow!("unknown_template"))?;
        for id in request.repo_overrides.keys() {
            ensure!(template.repos.contains_key(id), "override_outside_template");
        }
        let mut out = vec![];
        for (repo, template_policy) in &template.repos {
            let mut policy = Policy::default();
            let mut origins = BTreeMap::new();
            policy.overlay(&self.user_defaults, "user_defaults", &mut origins);
            policy.overlay(&self.policy, "workspace", &mut origins);
            for group in &lineage {
                policy.overlay(&group.policy, &format!("group:{}", group.id), &mut origins);
            }
            policy.overlay(
                template_policy,
                &format!("template:{template_id}:{repo}"),
                &mut origins,
            );
            if let Some(p) = request.repo_overrides.get(repo) {
                // Command/recipe selection remains configuration-owned; agents supply values only.
                ensure!(
                    p.recipe.is_none() && p.base_ref.is_none() && p.branch_pattern.is_none(),
                    "task_override_inputs_only"
                );
                policy.overlay(p, "task_inputs", &mut origins);
            }
            self.validate_policy(&policy, Some(repo))?;
            ensure!(
                policy.base_ref.is_some() && policy.branch_pattern.is_some(),
                "incomplete_policy"
            );
            if policy.recipe.is_some() {
                ensure!(policy.inputs.is_some(), "missing_recipe_inputs");
            }
            out.push((repo.clone(), policy, origins));
        }
        Ok(out)
    }
}

pub fn safe_relative(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && !value.contains('\\')
            && value
                .split('/')
                .all(|s| !s.is_empty() && s != "." && s != ".."),
        "unsafe_relative_path"
    );
    ensure!(
        !std::path::Path::new(value).is_absolute(),
        "unsafe_relative_path"
    );
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    BranchOnly,
    Materialize,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskRequest {
    pub group_id: String,
    pub label: String,
    pub task_slug: String,
    pub mode: Mode,
    #[serde(default)]
    pub repo_overrides: BTreeMap<String, Policy>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Snapshot {
    pub head: String,
    pub branch: String,
    pub index_hash: String,
    pub files: BTreeMap<String, String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SnapshotSummary {
    pub head: String,
    pub branch: String,
    pub index_hash: String,
    pub snapshot_hash: String,
    pub files_count: usize,
}
impl Snapshot {
    pub fn summary(&self) -> Result<SnapshotSummary> {
        Ok(SnapshotSummary {
            head: self.head.clone(),
            branch: self.branch.clone(),
            index_hash: self.index_hash.clone(),
            snapshot_hash: digest(self)?,
            files_count: self.files.len(),
        })
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PlannedRepo<S = Snapshot> {
    pub repo_id: String,
    pub common_id: String,
    pub base_ref: String,
    pub base_oid: String,
    pub branch_ref: String,
    pub worktree_path: PathBuf,
    pub source_snapshot: S,
    pub policy: Policy,
    pub policy_origins: BTreeMap<String, String>,
    pub recipe_hash: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Plan<S = Snapshot> {
    pub schema_version: u32,
    pub id: String,
    pub request: TaskRequest,
    pub config_hash: String,
    pub snapshot_hash: String,
    pub expires_at: u64,
    pub repos: Vec<PlannedRepo<S>>,
    pub warnings: Vec<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RepoState {
    Planned,
    BranchIntent,
    BranchCreated,
    WaitingForWorktree,
    Materializing,
    CheckedOut,
    Preparing,
    Ready,
    Failed,
    Cancelled,
    NeedsRecovery,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskRepo<S = Snapshot> {
    pub plan: PlannedRepo<S>,
    pub state: RepoState,
    pub error_code: Option<String>,
    pub attempts: u32,
    pub baseline: Option<S>,
    pub result_snapshot: Option<S>,
    pub postcondition: Option<IosInputs>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Operation<S = Snapshot> {
    pub schema_version: u32,
    pub id: String,
    pub task_id: String,
    pub plan_id: String,
    pub idempotency_key: String,
    pub payload_hash: String,
    pub status: String,
    pub materialize: bool,
    pub cancel_requested: bool,
    pub repos: Vec<TaskRepo<S>>,
    pub warnings: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Task<S = Snapshot> {
    pub schema_version: u32,
    pub id: String,
    pub request: TaskRequest,
    pub policy_snapshot: Plan<S>,
    pub operation_id: String,
}
// Journal types retain full immutable observations; RPC types expose only their
// identity and digest, so polling never transfers one entry for every repo file.
impl PlannedRepo {
    pub fn summary(&self) -> Result<PlannedRepo<SnapshotSummary>> {
        Ok(PlannedRepo {
            repo_id: self.repo_id.clone(),
            common_id: self.common_id.clone(),
            base_ref: self.base_ref.clone(),
            base_oid: self.base_oid.clone(),
            branch_ref: self.branch_ref.clone(),
            worktree_path: self.worktree_path.clone(),
            source_snapshot: self.source_snapshot.summary()?,
            policy: self.policy.clone(),
            policy_origins: self.policy_origins.clone(),
            recipe_hash: self.recipe_hash.clone(),
        })
    }
}
impl Plan {
    pub fn summary(&self) -> Result<Plan<SnapshotSummary>> {
        Ok(Plan {
            schema_version: self.schema_version,
            id: self.id.clone(),
            request: self.request.clone(),
            config_hash: self.config_hash.clone(),
            snapshot_hash: self.snapshot_hash.clone(),
            expires_at: self.expires_at,
            repos: self
                .repos
                .iter()
                .map(PlannedRepo::summary)
                .collect::<Result<_>>()?,
            warnings: self.warnings.clone(),
        })
    }
}
impl Operation {
    pub fn summary(&self) -> Result<Operation<SnapshotSummary>> {
        Ok(Operation {
            schema_version: self.schema_version,
            id: self.id.clone(),
            task_id: self.task_id.clone(),
            plan_id: self.plan_id.clone(),
            idempotency_key: self.idempotency_key.clone(),
            payload_hash: self.payload_hash.clone(),
            status: self.status.clone(),
            materialize: self.materialize,
            cancel_requested: self.cancel_requested,
            repos: self
                .repos
                .iter()
                .map(|repo| {
                    Ok(TaskRepo {
                        plan: repo.plan.summary()?,
                        state: repo.state,
                        error_code: repo.error_code.clone(),
                        attempts: repo.attempts,
                        baseline: repo.baseline.as_ref().map(Snapshot::summary).transpose()?,
                        result_snapshot: repo
                            .result_snapshot
                            .as_ref()
                            .map(Snapshot::summary)
                            .transpose()?,
                        postcondition: repo.postcondition.clone(),
                    })
                })
                .collect::<Result<_>>()?,
            warnings: self.warnings.clone(),
        })
    }
}
impl Task {
    pub fn summary(&self) -> Result<Task<SnapshotSummary>> {
        Ok(Task {
            schema_version: self.schema_version,
            id: self.id.clone(),
            request: self.request.clone(),
            policy_snapshot: self.policy_snapshot.summary()?,
            operation_id: self.operation_id.clone(),
        })
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Event {
    pub sequence: i64,
    pub operation_id: String,
    pub timestamp: u64,
    pub status: String,
}

pub fn fail_code(error: &anyhow::Error) -> String {
    let s = error.to_string();
    let first = s.split(':').next().unwrap_or("operation_failed");
    if first.len() <= 64 && first.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') {
        first.into()
    } else {
        "operation_failed".into()
    }
}

pub fn require_schema(version: u32) -> Result<()> {
    if version != 1 {
        bail!("unsupported_schema");
    }
    Ok(())
}

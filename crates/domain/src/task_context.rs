use crate::*;

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskContext {
    pub revision: u64,
    pub purpose: String,
    pub criteria: Vec<String>,
    pub references: Vec<String>,
    pub notes: String,
    pub requirements_hash: String,
}
impl TaskContext {
    pub fn normalize(&mut self) -> Result<()> {
        self.purpose = self.purpose.trim().into();
        self.notes = self.notes.trim().into();
        for items in [&mut self.criteria, &mut self.references] {
            *items = items
                .iter()
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
                .collect();
        }
        ensure!(
            self.purpose.chars().count() <= 2_000
                && self.notes.chars().count() <= 5_000
                && self.criteria.len() <= 30
                && self.criteria.iter().all(|s| s.chars().count() <= 300)
                && self.references.len() <= 10
                && self.references.iter().all(|s| s.len() <= 2_048),
            "invalid_task_context: context exceeds limits"
        );
        self.requirements_hash = digest(&(&self.purpose, &self.criteria, &self.references))?;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceKind {
    GitCheck,
    HumanReport,
    AiReport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Passed,
    Failed,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct VerificationReceipt {
    pub id: String,
    pub repo_id: String,
    pub op_id: Option<String>,
    pub path: PathBuf,
    pub branch: String,
    pub head: String,
    pub snapshot_hash: String,
    pub after_snapshot_hash: Option<String>,
    pub requirements_hash: String,
    pub kind: EvidenceKind,
    pub verdict: Verdict,
    pub started_at: u64,
    pub finished_at: u64,
    pub command: String,
    pub note: String,
    pub output: String,
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskContextBundle {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_version: Option<u32>,
    pub context: TaskContext,
    pub verifications: Vec<VerificationReceipt>,
}

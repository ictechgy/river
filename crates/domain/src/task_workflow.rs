use crate::*;

/// Stable identity and immutable text revision. A link is a report association,
/// never a statement that a condition has been fulfilled.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkflowCriterion {
    pub id: String,
    pub revision: u64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum GuideKind {
    Procedure,
    FeatureMap,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GuideReference {
    pub id: String,
    pub repo_id: String,
    pub kind: GuideKind,
    pub path: String,
    pub expected_sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskWorkflowState {
    pub revision: u64,
    pub context_revision: u64,
    pub intent_hash: String,
    pub criteria: Vec<WorkflowCriterion>,
    pub guides: Vec<GuideReference>,
    pub retired_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ClaimedReviewedState {
    pub head: Option<String>,
    pub snapshot_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReportStatus {
    Completed,
    Incomplete,
    ToolError,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkflowEvidence {
    pub receipt_id: String,
    pub criteria: Vec<WorkflowCriterion>,
    pub intent_hash: String,
    pub claimed_reviewed_state: Option<ClaimedReviewedState>,
    pub provider: String,
    pub model: String,
    pub artifacts: Vec<String>,
    pub report_status: ReportStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct WorkflowHistoryEntry {
    pub revision: u64,
    pub context_revision: u64,
    pub saved_at: u64,
    pub criterion_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskWorkflowBundle {
    pub version: u32,
    pub compatibility: String,
    pub context: TaskContext,
    pub verifications: Vec<VerificationReceipt>,
    pub workflow: TaskWorkflowState,
    pub evidence: Vec<WorkflowEvidence>,
    pub history: Vec<WorkflowHistoryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct VerificationGuideContents {
    pub repo_id: String,
    pub op_id: Option<String>,
    pub path: String,
    pub sha256: String,
    pub expected_sha256: Option<String>,
    pub status: String,
    pub content: String,
    pub format: String,
    pub read_at: u64,
}

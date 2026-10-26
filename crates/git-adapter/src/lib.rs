mod content_read;
mod deadline;
mod file_conversion;
mod file_hash;
mod file_staging;
pub use deadline::{
    READ_PHASE_TIMEOUT, check_deadline, fresh_deadline, with_deadline, with_read_cancellation,
};
pub use file_staging::stage_file;
mod process;
pub mod remotes;
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use workbench_domain::{Snapshot, SnapshotSummary, digest, hash, safe_relative};

pub fn git(path: &Path, args: &[&str]) -> Result<String> {
    String::from_utf8(git_bytes(path, args)?).context("unsupported_encoding")
}
/// Decode one Git filesystem-path record. Only its final LF is a terminator;
/// spaces, tabs, CRs and any preceding LFs belong to the pathname.
/// Do not pass output containing several path records: embedded LFs make that
/// format ambiguous. The same rule applies to Git's `gitdir` backlink file.
pub fn path_from_record(record: &str) -> Result<PathBuf> {
    let path = record.strip_suffix('\n').unwrap_or(record);
    ensure!(
        !path.is_empty() && !path.contains('\0'),
        "unsupported_git_path_encoding"
    );
    Ok(PathBuf::from(path))
}
/// Run a fixed Git command that emits exactly one filesystem path.
pub fn git_path(path: &Path, args: &[&str]) -> Result<PathBuf> {
    path_from_record(&git(path, args)?)
}
pub fn git_bytes(path: &Path, args: &[&str]) -> Result<Vec<u8>> {
    command(path, args, None)
}
fn git_version(path: &Path) -> Result<String> {
    static VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    if let Some(version) = VERSION.get() {
        return Ok(version.clone());
    }
    let version = git(path, &["--version"])?.trim().to_string();
    let _ = VERSION.set(version.clone());
    Ok(version)
}
fn git_command(path: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new("/usr/bin/git");
    cmd.current_dir(path)
        .args([
            "--no-pager",
            "-c",
            "color.ui=false",
            "-c",
            "color.diff=false",
            "-c",
            "diff.suppressBlankEmpty=false",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "log.showSignature=false",
            "-c",
            "maintenance.auto=false",
            "-c",
            "gc.auto=0",
            "-c",
            "submodule.recurse=false",
        ])
        .args(args);
    // Caller environment must not redirect repositories or override safe Git config.
    for (key, _) in std::env::vars_os() {
        if key.as_encoded_bytes().starts_with(b"GIT_") {
            cmd.env_remove(key);
        }
    }
    cmd.env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1");
    cmd
}
pub fn command(path: &Path, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>> {
    // Enforce at the command boundary, including fixture setup and recovery of
    // already-existing worktrees. A new call site must not bypass filter trust.
    let mut offset = 0;
    while args.get(offset) == Some(&"-c") {
        offset += 2;
    }
    if matches!(
        args.get(offset),
        Some(&("add" | "status" | "diff" | "worktree" | "commit" | "apply" | "checkout" | "reset"))
    ) {
        no_external_filters(path)?;
    }
    let timeout = if matches!(
        args.get(offset),
        Some(&("worktree" | "commit" | "checkout" | "reset"))
    ) {
        120
    } else {
        15
    };
    let write = matches!(
        args.get(offset),
        Some(&("commit" | "checkout" | "reset" | "add" | "update-ref"))
    ) || (args.get(offset) == Some(&"apply") && !args.contains(&"--check"))
        || (args.get(offset) == Some(&"worktree")
            && !matches!(args.get(offset + 1), Some(&"list")));
    let run = || {
        process::run(
            git_command(path, args),
            input,
            std::time::Duration::from_secs(if write { 120 } else { timeout }),
            8 * 1024 * 1024,
        )
    };
    let out = if write {
        deadline::write_budget(|| run().context("git_write_outcome_unknown"))
    } else {
        run()
    }?;
    // No script stdout or input is attached to errors; stderr is data, never instructions.
    ensure!(
        out.status.success(),
        "git_failed: {}",
        String::from_utf8_lossy(&out.stderr)
            .chars()
            .take(2000)
            .collect::<String>()
    );
    ensure!(out.stdout.len() <= 8 * 1024 * 1024, "result_too_large");
    Ok(out.stdout)
}
/// External conversion programs need a separate trust contract; never silently
/// bypass their content semantics (for example by checking out raw LFS pointers).
pub fn no_external_filters(path: &Path) -> Result<()> {
    let out = process::run(
        git_command(
            path,
            &[
                "config",
                "--null",
                "--get-regexp",
                r"^filter\..*\.(clean|smudge|process)$",
            ],
        ),
        None,
        std::time::Duration::from_secs(15),
        1024 * 1024,
    )?;
    if out.status.code() == Some(1) {
        return Ok(());
    }
    ensure!(out.status.success(), "git_filter_probe_failed");
    ensure!(out.stdout.len() <= 1024 * 1024, "result_too_large");
    for record in out.stdout.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let separator = record
            .iter()
            .position(|b| *b == b'\n')
            .context("invalid_filter_config")?;
        ensure!(
            record[separator + 1..].iter().all(u8::is_ascii_whitespace),
            "unsupported_external_filter"
        );
    }
    Ok(())
}

/// Fixed, read-only verification. Nonzero diff --check output is evidence, not an RPC failure.
/// Drain both pipes while retaining only bounded output; no shell or user command is accepted.
pub fn check_changes(path: &Path) -> Result<(workbench_domain::Verdict, String, bool)> {
    with_deadline(READ_PHASE_TIMEOUT, || check_changes_inner(path))
}
fn check_changes_inner(path: &Path) -> Result<(workbench_domain::Verdict, String, bool)> {
    use std::time::Duration;
    use workbench_domain::Verdict;
    let snapshot = snapshot(path)?;
    let context = content_read::ContentReadContext::capture(path, &snapshot, None)?;
    let mut verdict = Verdict::Passed;
    let mut output = String::new();
    let mut truncated = false;
    for staged in [false, true] {
        let mut args = vec![
            "-c",
            "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab",
            "diff",
            "--check",
            "--no-ext-diff",
            "--no-textconv",
            "--ignore-submodules=all",
        ];
        if staged {
            args.push("--cached");
        }
        args.push("--");
        let time_limit = match deadline::budget(Duration::from_secs(10)) {
            Ok(limit) => limit,
            Err(_) => {
                output.push_str("Verification deadline reached; remaining checks not run.\n");
                return Ok((Verdict::Unknown, output, truncated));
            }
        };
        let result = with_deadline(time_limit, || context.output(&args, None, 8 * 1024 * 1024));
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                truncated |= error.to_string() == "result_too_large";
                output.push_str(&format!("Git check incomplete: {error}\n"));
                verdict = Verdict::Unknown;
                continue;
            }
        };
        let status = result.status;
        truncated |= result.stdout.len() > 8_192 || result.stderr.len() > 8_192;
        let out = &result.stdout[..result.stdout.len().min(8_192)];
        let err = &result.stderr[..result.stderr.len().min(8_192)];
        output.push_str(&format!(
            "{}: exit {:?}{}\n{}{}\n",
            if staged { "index" } else { "working tree" },
            status.code(),
            "",
            String::from_utf8_lossy(out),
            String::from_utf8_lossy(err)
        ));
        if !matches!(status.code(), Some(0..=3)) {
            verdict = Verdict::Unknown;
        } else if !status.success() && verdict != Verdict::Unknown {
            verdict = Verdict::Failed;
        }
    }
    if let Err(error) = no_conflicts(path) {
        output.push_str(&format!("Git conflict / in-progress check: {error}\n"));
        if !matches!(
            error.to_string().as_str(),
            "merge_conflict" | "integration_in_progress"
        ) {
            verdict = Verdict::Unknown;
        } else if verdict != Verdict::Unknown {
            verdict = Verdict::Failed;
        }
    }
    context.validate()?;
    ensure!(snapshot == crate::snapshot(path)?, "stale_read_snapshot");
    Ok((verdict, output, truncated))
}

/// A clean/status read shares the same immutable conversion boundary as view.
pub fn status_bytes(path: &Path) -> Result<Vec<u8>> {
    with_deadline(READ_PHASE_TIMEOUT, || {
        let snapshot = snapshot(path)?;
        let context = content_read::ContentReadContext::capture(path, &snapshot, None)?;
        let output = context.bytes(&[
            "-c",
            "status.renames=false",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=all",
        ])?;
        context.validate()?;
        ensure!(snapshot == crate::snapshot(path)?, "stale_read_snapshot");
        Ok(output)
    })
}
pub fn root(path: &Path) -> Result<PathBuf> {
    let path = fs::canonicalize(path).context("invalid_repo_path")?;
    let root = fs::canonicalize(git_path(&path, &["rev-parse", "--show-toplevel"])?)?;
    ensure!(root == path, "repo_path_must_be_root");
    Ok(root)
}
pub fn common_dir(path: &Path) -> Result<PathBuf> {
    Ok(fs::canonicalize(git_path(
        path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?)?)
}
pub fn oid(path: &Path, reference: &str) -> Result<String> {
    ensure!(
        !reference.starts_with('-') && !reference.contains('\0'),
        "invalid_ref"
    );
    Ok(git(
        path,
        &[
            "rev-parse",
            "--verify",
            "--end-of-options",
            &format!("{reference}^{{commit}}"),
        ],
    )?
    .trim()
    .into())
}
pub fn ref_exists(path: &Path, reference: &str) -> Result<bool> {
    // rev-parse missing ref is expected; do not use this function to mask any mutation failure.
    let out = process::run(
        git_command(path, &["show-ref", "--verify", "--quiet", reference]),
        None,
        std::time::Duration::from_secs(15),
        1024,
    )?
    .status;
    match out.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => bail!("git_ref_probe_failed"),
    }
}
pub fn validate_branch(path: &Path, branch: &str) -> Result<()> {
    ensure!(
        branch.starts_with("refs/heads/") && branch.len() > 11,
        "invalid_branch"
    );
    git(path, &["check-ref-format", branch])?;
    Ok(())
}
pub fn no_conflicts(path: &Path) -> Result<()> {
    ensure!(
        git_bytes(path, &["ls-files", "-u", "-z"])?.is_empty(),
        "merge_conflict"
    );
    // All five integration markers are per-worktree. Resolve their directory
    // in one process, without ambiguous LF-delimited multiple-path output.
    // Nothing is cached: linked-worktree state may change between reads.
    let git_dir = git_path(path, &["rev-parse", "--absolute-git-dir"])?;
    for marker in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    ] {
        ensure!(!git_dir.join(marker).exists(), "integration_in_progress");
    }
    Ok(())
}
pub fn files(path: &Path) -> Result<BTreeMap<String, String>> {
    with_deadline(READ_PHASE_TIMEOUT, || snapshot_files(path, false, false))
}
fn snapshot_files(
    path: &Path,
    include_ignored: bool,
    presentation_cache: bool,
) -> Result<BTreeMap<String, String>> {
    let mut args = vec!["ls-files", "--cached", "--others", "-z"];
    if !include_ignored {
        args.push("--exclude-standard");
    }
    let listed = git_bytes(path, &args)?;
    let mut result = BTreeMap::new();
    for item in listed.split(|b| *b == 0).filter(|v| !v.is_empty()) {
        check_deadline()?;
        let name = std::str::from_utf8(item).context("unsupported_filename_encoding")?;
        // Git represents embedded repositories/worktrees as a trailing-slash
        // directory entry. Reject explicitly before generic path validation.
        ensure!(!name.ends_with('/'), "unsupported_nested_repository");
        safe_relative(name)?;
        let file = path.join(name);
        // A tracked symlink parent must never make snapshot reads escape the worktree.
        let mut cursor = path.to_path_buf();
        let components: Vec<_> = Path::new(name).components().collect();
        for c in &components[..components.len() - 1] {
            cursor.push(c);
            if cursor.exists() {
                ensure!(
                    !fs::symlink_metadata(&cursor)?.file_type().is_symlink(),
                    "symlink_parent"
                );
            }
        }
        let value = match fs::symlink_metadata(&file) {
            Ok(meta) if meta.file_type().is_symlink() => format!(
                "symlink:{}",
                hash(fs::read_link(&file)?.as_os_str().as_encoded_bytes())
            ),
            Ok(meta) if meta.is_file() => file_hash::value(&file, &meta, presentation_cache)?,
            Ok(_) => bail!("unsupported_submodule_or_directory"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => "missing".into(),
            Err(e) => return Err(e.into()),
        };
        result.insert(name.into(), value);
    }
    Ok(result)
}
pub fn snapshot(path: &Path) -> Result<Snapshot> {
    with_deadline(READ_PHASE_TIMEOUT, || {
        no_external_filters(path)?;
        snapshot_with_scope(path, false, false)
    })
}
pub fn preparation_snapshot(path: &Path) -> Result<Snapshot> {
    // Ignored output is still an undeclared recipe write. Only task preparation
    // scans it; ordinary review must not hash ignored build/cache directories.
    with_deadline(READ_PHASE_TIMEOUT, || {
        no_external_filters(path)?;
        snapshot_with_scope(path, true, false)
    })
}
fn snapshot_with_scope(
    path: &Path,
    include_ignored: bool,
    presentation_cache: bool,
) -> Result<Snapshot> {
    let branch = git(path, &["symbolic-ref", "-q", "HEAD"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let head = if !branch.is_empty() && !ref_exists(path, &branch)? {
        String::new()
    } else {
        oid(path, "HEAD")?
    };
    Ok(Snapshot {
        head,
        branch,
        // Index stat-cache refreshes are not staged-content changes. Include all
        // stages/modes/OIDs/paths, without writing a tree or altering the index.
        index_hash: digest(&(
            hash(git_bytes(path, &["ls-files", "--stage", "-z"])?),
            // ls-files alone omits intent-to-add. Cached raw diff distinguishes
            // an empty ITA entry from a real staged empty-file addition.
            hash(cached_index_metadata(path)?),
        ))?,
        files: snapshot_files(path, include_ignored, presentation_cache)?,
    })
}
// This exact cached raw command reads only index/HEAD metadata. It neither
// opens working files for conversion nor runs external diff/text conversion.
// Keeping the argv private prevents a flag-based exemption for public commands.
fn cached_index_metadata(path: &Path) -> Result<Vec<u8>> {
    let output = process::run(
        git_command(
            path,
            &[
                "diff",
                "--cached",
                "--raw",
                "-z",
                "--no-abbrev",
                "--no-renames",
                "--no-ext-diff",
                "--no-textconv",
                "--ignore-submodules=none",
                "--ita-invisible-in-index",
                "--",
            ],
        ),
        None,
        std::time::Duration::from_secs(15),
        8 * 1024 * 1024,
    )?;
    ensure!(
        output.status.success(),
        "git_failed: cached index metadata unavailable"
    );
    Ok(output.stdout)
}
pub fn verify_checkout(path: &Path, source: &Path, branch: &str, expected_oid: &str) -> Result<()> {
    let locked = git_path(
        path,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "locked",
        ],
    )?;
    ensure!(!locked.exists(), "worktree_locked");
    ensure!(
        root(path)? == fs::canonicalize(path)?,
        "wrong_worktree_root"
    );
    ensure!(common_dir(path)? == common_dir(source)?, "wrong_repository");
    let snap = snapshot(path)?;
    ensure!(
        snap.branch == branch && snap.head == expected_oid,
        "wrong_checkout"
    );
    no_conflicts(path)
}
pub fn create_branch(path: &Path, branch: &str, base: &str, op: &str) -> Result<()> {
    validate_branch(path, branch)?;
    if ref_exists(path, branch)? {
        ensure!(oid(path, branch)? == base, "branch_collision");
        let log = git(path, &["reflog", "show", "-1", "--format=%gs", branch])?;
        ensure!(log.trim() == format!("workbench:{op}"), "branch_collision");
    } else {
        let zero = "0".repeat(base.len());
        git(
            path,
            &[
                "update-ref",
                "--create-reflog",
                "-m",
                &format!("workbench:{op}"),
                branch,
                base,
                &zero,
            ],
        )?;
    }
    Ok(())
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Commit {
    pub oid: String,
    pub parents: Vec<String>,
    pub refs: String,
    pub subject: String,
    pub author: String,
    pub timestamp: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Branch {
    pub full_ref: String,
    pub name: String,
    pub is_remote: bool,
    pub tip_oid: String,
    pub upstream: String,
    pub subject: String,
    pub timestamp: String,
    pub worktree_path: String,
    pub current: bool,
}
pub fn branches(path: &Path, viewed_worktree: Option<&Path>) -> Result<Vec<Branch>> {
    let current = viewed_worktree
        .map(|p| git(p, &["symbolic-ref", "-q", "HEAD"]).unwrap_or_default())
        .unwrap_or_default();
    // NUL fields preserve whitespace/newlines in linked worktree paths. Git adds
    // exactly one newline after each explicitly NUL-terminated format record.
    let data = git_bytes(
        path,
        &[
            "for-each-ref",
            "--sort=refname",
            "--format=%(refname)%00%(objectname)%00%(upstream:short)%00%(subject)%00%(committerdate:iso8601-strict)%00%(worktreepath)%00%(symref)%00",
            "refs/heads",
            "refs/remotes",
        ],
    )?;
    let mut fields = data.split(|b| *b == 0).collect::<Vec<_>>();
    if fields.last().is_some_and(|f| *f == b"\n" || f.is_empty()) {
        fields.pop();
    }
    ensure!(fields.len() % 7 == 0, "invalid_branch_list");
    let mut result = vec![];
    for row in fields.chunks_exact(7) {
        let reference = std::str::from_utf8(row[0].strip_prefix(b"\n").unwrap_or(row[0]))?;
        // origin/HEAD is an alias, not an additional remote branch.
        if !row[6].is_empty() {
            continue;
        }
        result.push(Branch {
            full_ref: reference.into(),
            name: reference
                .strip_prefix("refs/heads/")
                .or_else(|| reference.strip_prefix("refs/remotes/"))
                .context("invalid_branch_ref")?
                .into(),
            is_remote: reference.starts_with("refs/remotes/"),
            tip_oid: std::str::from_utf8(row[1])?.into(),
            upstream: std::str::from_utf8(row[2])?.into(),
            subject: std::str::from_utf8(row[3])?.into(),
            timestamp: std::str::from_utf8(row[4])?.into(),
            worktree_path: std::str::from_utf8(row[5])?.into(),
            current: reference == current.trim(),
        });
    }
    Ok(result)
}
pub fn branch_history(path: &Path, reference: &str, expected_oid: &str) -> Result<Vec<Commit>> {
    let branch = branches(path, None)?
        .into_iter()
        .find(|b| b.full_ref == reference)
        .context("unknown_branch")?;
    ensure!(branch.tip_oid == expected_oid, "stale_branch");
    let log = git_bytes(
        path,
        &[
            "log",
            "--topo-order",
            "-80",
            "--format=%H%x00%P%x00%D%x00%s%x00%an%x00%aI",
            &branch.tip_oid,
            "--",
        ],
    )?;
    Ok(parse_commits(&String::from_utf8_lossy(&log)))
}
fn parse_commits(log: &str) -> Vec<Commit> {
    log.lines()
        .filter_map(|line| {
            let f: Vec<_> = line.split('\0').collect();
            (f.len() == 6).then(|| Commit {
                oid: f[0].into(),
                parents: f[1].split_whitespace().map(Into::into).collect(),
                refs: f[2].into(),
                subject: f[3].into(),
                author: f[4].into(),
                timestamp: f[5].into(),
            })
        })
        .collect()
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileStatus {
    pub path: String,
    pub index: String,
    pub worktree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_key: Option<String>,
}
// A reading checkpoint is scoped to file bytes AND its Git comparison context.
// Unrelated working-file edits do not invalidate it; any HEAD/branch/index change
// conservatively does. Reuse the existing snapshot, without extra Git/file reads.
fn review_key(snapshot: &Snapshot, file: &str) -> Result<String> {
    digest(&(
        file,
        &snapshot.head,
        &snapshot.branch,
        &snapshot.index_hash,
        snapshot.files.get(file),
    ))
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoView {
    pub file_staging_version: u32,
    pub path: PathBuf,
    pub snapshot_hash: String,
    pub snapshot: SnapshotSummary,
    pub files: Vec<FileStatus>,
    pub graph: Vec<Commit>,
    pub refs: Vec<String>,
    pub worktrees: String,
    pub conflict: bool,
    pub git_version: String,
}
pub fn view(path: &Path) -> Result<RepoView> {
    with_deadline(READ_PHASE_TIMEOUT, || view_inner(path))
}
fn view_inner(path: &Path) -> Result<RepoView> {
    let snapshot = snapshot_with_scope(path, false, true)?;
    let context = content_read::ContentReadContext::capture(path, &snapshot, None)?;
    let status = context.bytes(&[
        "-c",
        "status.renames=false",
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignore-submodules=all",
    ])?;
    let mut files = vec![];
    for row in status.split(|v| *v == 0).filter(|v| !v.is_empty()) {
        ensure!(row.len() >= 4, "invalid_status");
        files.push(FileStatus {
            path: std::str::from_utf8(&row[3..])?.into(),
            index: String::from_utf8(vec![row[0]])?,
            worktree: String::from_utf8(vec![row[1]])?,
            review_key: Some(review_key(&snapshot, std::str::from_utf8(&row[3..])?)?),
        });
    }
    let log = git_bytes(
        path,
        &[
            "log",
            "--exclude=refs/stash",
            "--all",
            "--topo-order",
            "-80",
            "--format=%H%x00%P%x00%D%x00%s%x00%an%x00%aI",
        ],
    )?;
    let graph = parse_commits(&String::from_utf8_lossy(&log));
    let refs = git(
        path,
        &[
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
            "refs/remotes",
        ],
    )?
    .lines()
    .map(Into::into)
    .collect();
    ensure!(
        snapshot == snapshot_with_scope(path, false, true)?,
        "stale_read_snapshot"
    );
    context.validate()?;
    let conflict = match no_conflicts(path) {
        Ok(()) => false,
        Err(error)
            if matches!(
                error.to_string().as_str(),
                "merge_conflict" | "integration_in_progress"
            ) =>
        {
            true
        }
        Err(error) => return Err(error),
    };
    Ok(RepoView {
        file_staging_version: 1,
        path: path.into(),
        snapshot_hash: digest(&snapshot)?,
        snapshot: snapshot.summary()?,
        files,
        graph,
        refs,
        worktrees: git(path, &["worktree", "list", "--porcelain"])?,
        conflict,
        git_version: git_version(path)?,
    })
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diff {
    pub snapshot_hash: String,
    pub path: String,
    pub staged: bool,
    pub header: String,
    pub hunks: Vec<String>,
    pub text: String,
    pub can_stage_hunks: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding_warning: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StashEntry {
    pub oid: String,
    pub selector: String,
    pub subject: String,
    pub timestamp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StashDetail {
    pub oid: String,
    pub files: Vec<FileStatus>,
}

pub fn stashes(path: &Path) -> Result<Vec<StashEntry>> {
    if !ref_exists(path, "refs/stash")? {
        return Ok(vec![]);
    }
    let data = git_bytes(
        path,
        &[
            "reflog",
            "show",
            "-z",
            "--format=%H%x00%gd%x00%gs%x00%ct",
            "refs/stash",
        ],
    )?;
    let mut fields = data.split(|b| *b == 0).collect::<Vec<_>>();
    if fields.last() == Some(&&b""[..]) {
        fields.pop();
    }
    ensure!(fields.len() % 4 == 0, "invalid_stash_log");
    fields
        .chunks_exact(4)
        .map(|f| {
            Ok(StashEntry {
                oid: std::str::from_utf8(f[0])?.into(),
                selector: std::str::from_utf8(f[1])?.into(),
                subject: std::str::from_utf8(f[2])?.into(),
                timestamp: std::str::from_utf8(f[3])?.into(),
            })
        })
        .collect()
}

pub fn stash_detail(path: &Path, requested_oid: &str) -> Result<StashDetail> {
    // Use immutable OIDs, never a moving stash@{n} supplied by the UI.
    ensure!(
        stashes(path)?.iter().any(|s| s.oid == requested_oid),
        "stash_not_found"
    );
    let base = oid(path, &format!("{requested_oid}^1"))?;
    let names = git_bytes(
        path,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--name-status",
            "-z",
            &base,
            requested_oid,
            "--",
        ],
    )?;
    let mut fields = names.split(|b| *b == 0).collect::<Vec<_>>();
    if fields.last() == Some(&&b""[..]) {
        fields.pop();
    }
    ensure!(fields.len() % 2 == 0, "invalid_stash_files");
    let mut files = BTreeMap::new();
    for pair in fields.chunks_exact(2) {
        let name = std::str::from_utf8(pair[1])?;
        safe_relative(name)?;
        files.insert(
            name.to_string(),
            FileStatus {
                path: name.into(),
                index: " ".into(),
                worktree: std::str::from_utf8(pair[0])?.into(),
                review_key: None,
            },
        );
    }
    // A stash made with -u/-a records untracked files in an optional third parent.
    let parents = git(path, &["rev-list", "--parents", "-n", "1", requested_oid])?;
    if let Some(untracked) = parents.split_whitespace().nth(3) {
        for name in git_bytes(
            path,
            &["ls-tree", "-r", "--name-only", "-z", untracked, "--"],
        )?
        .split(|b| *b == 0)
        .filter(|b| !b.is_empty())
        {
            let name = std::str::from_utf8(name)?;
            safe_relative(name)?;
            files.insert(
                name.to_string(),
                FileStatus {
                    path: name.into(),
                    index: "?".into(),
                    worktree: "?".into(),
                    review_key: None,
                },
            );
        }
    }
    Ok(StashDetail {
        oid: requested_oid.into(),
        files: files.into_values().collect(),
    })
}

pub fn stash_diff(path: &Path, requested_oid: &str, file: &str) -> Result<Diff> {
    safe_relative(file)?;
    let detail = stash_detail(path, requested_oid)?;
    let item = detail
        .files
        .iter()
        .find(|f| f.path == file)
        .context("unknown_stash_file")?;
    let text = if item.index == "?" {
        git(
            path,
            &[
                "show",
                "--format=",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--unified=3",
                &format!("{requested_oid}^3"),
                "--",
                file,
            ],
        )?
    } else {
        git(
            path,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--unified=3",
                &format!("{requested_oid}^1"),
                requested_oid,
                "--",
                file,
            ],
        )?
    };
    Ok(parse_diff(text, requested_oid.into(), file, false, false))
}

pub fn diff(path: &Path, file: &str, staged: bool) -> Result<Diff> {
    with_deadline(READ_PHASE_TIMEOUT, || diff_inner(path, file, staged))
}
fn diff_inner(path: &Path, file: &str, staged: bool) -> Result<Diff> {
    safe_relative(file)?;
    let snap = snapshot_with_scope(path, false, true)?;
    // A literal Git pathspec can still select a whole directory. Bind the
    // request to an exact file, including tracked files missing on disk.
    // Staged deletions are absent from snapshot.files, so retain their review
    // through exact NUL-delimited index/HEAD names, without a disk-file check.
    let exact_file = snap.files.contains_key(file) || {
        let names = git_bytes(
            path,
            &[
                "diff",
                "--cached",
                "--name-only",
                "-z",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--",
                file,
            ],
        )?;
        names.strip_suffix(&[0]) == Some(file.as_bytes())
    };
    ensure!(exact_file, "invalid_diff_path");
    let mut args = vec![
        "diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--unified=3",
    ];
    if staged {
        args.push("--cached");
    }
    args.extend(["--", file]);
    let context = content_read::ContentReadContext::capture(path, &snap, Some(file))?;
    let mut bytes = context.bytes(&args)?;
    if !staged
        && bytes.is_empty()
        && let Some(preview) = file_staging::untracked_preview(path, file, &snap, &context)?
    {
        bytes = preview;
    }
    let invalid_encoding = std::str::from_utf8(&bytes).is_err();
    let text = String::from_utf8_lossy(&bytes).into_owned();
    ensure!(
        text.split_inclusive('\n')
            .filter(|line| line.starts_with("diff --git "))
            .count()
            <= 1,
        "unsupported_multi_file_diff"
    );
    ensure!(
        snap == snapshot_with_scope(path, false, true)?,
        "stale_read_snapshot"
    );
    context.validate()?;
    let mut diff = parse_diff(text, digest(&snap)?, file, staged, !invalid_encoding);
    if invalid_encoding {
        diff.encoding_warning = Some("UTF-8로 읽을 수 없는 문자를 대체해 표시했습니다. 부분 스테이징은 지원하지 않습니다. 파일 전체 스테이징은 원본 바이트를 사용하므로 정확한 인코딩을 확인하세요.".into());
    }
    if !staged
        && diff.text.is_empty()
        && snap
            .files
            .get(file)
            .is_some_and(|value| value.starts_with("symlink:"))
        && git_bytes(path, &["ls-files", "--stage", "-z", "--", file])?.is_empty()
    {
        diff.encoding_warning = Some("새 심볼릭 링크의 일반 텍스트 Diff는 표시하지 않습니다. 파일 전체 스테이징은 링크 대상 경로만 포함하며 대상 파일을 읽지 않습니다.".into());
    }
    diff.review_key = Some(review_key(&snap, file)?);
    Ok(diff)
}
fn parse_diff(
    text: String,
    snapshot_hash: String,
    file: &str,
    staged: bool,
    editable: bool,
) -> Diff {
    let mut header = String::new();
    let mut hunks: Vec<String> = vec![];
    for line in text.split_inclusive('\n') {
        if line.starts_with("@@ ") {
            hunks.push(String::new());
        }
        if let Some(last) = hunks.last_mut() {
            last.push_str(line);
        } else {
            header.push_str(line);
        }
    }
    let can_stage_hunks = editable
        // Body lines carry a diff prefix, so an unprefixed boundary cannot be
        // mistaken for source text, even when a filename or line is quoted.
        && text
            .split_inclusive('\n')
            .filter(|line| line.starts_with("diff --git "))
            .count()
            == 1
        && !hunks.is_empty()
        && !header.contains("new file mode")
        && !header.contains("deleted file mode")
        && !header.contains("old mode")
        && !header.contains("Binary files");
    Diff {
        snapshot_hash,
        path: file.into(),
        staged,
        header,
        hunks,
        text,
        can_stage_hunks,
        review_key: None,
        encoding_warning: None,
    }
}
pub fn stage_hunk(
    path: &Path,
    file: &str,
    staged: bool,
    index: usize,
    expected: &str,
    expected_diff: &str,
) -> Result<()> {
    no_conflicts(path)?;
    let diff = diff(path, file, staged)?;
    ensure!(diff.snapshot_hash == expected, "stale_snapshot");
    // Git attributes/config may change hunk boundaries without changing file,
    // HEAD or index bytes. Stage only the exact diff the caller reviewed.
    ensure!(hash(diff.text.as_bytes()) == expected_diff, "stale_diff");
    ensure!(diff.can_stage_hunks, "unsupported_hunk_change");
    ensure!(digest(&snapshot(path)?)? == expected, "stale_snapshot");
    let hunk = diff.hunks.get(index).context("invalid_hunk")?;
    let patch = format!("{}{hunk}", diff.header);
    let mut args = vec!["apply", "--cached", "--whitespace=nowarn", "--check"];
    if staged {
        args.push("--reverse");
    }
    command(path, &args, Some(patch.as_bytes()))?;
    args.retain(|arg| *arg != "--check");
    command(path, &args, Some(patch.as_bytes()))?;
    Ok(())
}

//! Selected-file index changes. Build from immutable reviewed bytes, then publish
//! under Git's own index lock; never ask `git add` to reread a moving worktree.
use crate::{
    check_deadline, deadline, git, git_bytes, git_command, git_path, no_conflicts,
    no_external_filters, process, snapshot,
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};
use tempfile::NamedTempFile;
use workbench_domain::{Snapshot, digest, hash, safe_relative};

const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_INDEX_BYTES: u64 = 64 * 1024 * 1024;

/// A new regular file has no index side for ordinary `git diff`. Diff immutable
/// captured bytes through Git's bounded no-index reader, never a live symlink.
pub(super) fn untracked_preview(
    path: &Path,
    file: &str,
    reviewed: &Snapshot,
) -> Result<Option<Vec<u8>>> {
    if index_entry(
        &git_bytes(path, &["ls-files", "--stage", "-z", "--", file])?,
        file,
    )?
    .is_some()
    {
        return Ok(None);
    }
    let Some(fingerprint) = reviewed.files.get(file) else {
        return Ok(None);
    };
    if fingerprint == "missing" || fingerprint.starts_with("symlink:") {
        return Ok(None);
    }
    let Replacement::Captured {
        bytes,
        mode,
        symlink: false,
    } = capture(path, file, reviewed, None)?
    else {
        return Ok(None);
    };
    let mut captured = tempfile::NamedTempFile::new()?;
    captured.write_all(&bytes)?;
    captured.flush()?;
    let captured_path = captured
        .path()
        .to_str()
        .context("unsupported_filename_encoding")?;
    no_external_filters(path)?;
    let output = process::run(
        git_command(
            path,
            &[
                "diff",
                "--no-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--unified=3",
                "--",
                "/dev/null",
                captured_path,
            ],
        ),
        None,
        Duration::from_secs(15),
        8 * 1024 * 1024,
    )?;
    ensure!(
        matches!(output.status.code(), Some(0 | 1)),
        "git_failed: new file preview unavailable"
    );
    let old_name = quote_path("a/", file);
    let new_name = quote_path("b/", file);
    let mut result = Vec::new();
    let mut body = false;
    for line in output.stdout.split_inclusive(|b| *b == b'\n') {
        body |= line.starts_with(b"@@ ");
        if !body && line.starts_with(b"diff --git ") {
            result.extend_from_slice(format!("diff --git {old_name} {new_name}\n").as_bytes());
        } else if !body && line.starts_with(b"new file mode ") {
            result.extend_from_slice(format!("new file mode {mode}\n").as_bytes());
        } else if !body && line.starts_with(b"+++ ") {
            result.extend_from_slice(format!("+++ {new_name}\n").as_bytes());
        } else if !body && line.starts_with(b"Binary files ") {
            result.extend_from_slice(
                format!("Binary files /dev/null and {new_name} differ\n").as_bytes(),
            );
        } else {
            result.extend_from_slice(line);
        }
    }
    // Empty new files still have a useful file-addition header from no-index.
    Ok(Some(result))
}

fn quote_path(prefix: &str, file: &str) -> String {
    let joined = format!("{prefix}{file}");
    if joined
        .bytes()
        .all(|byte| (b'!'..=b'~').contains(&byte) && byte != b'"' && byte != b'\\')
    {
        return joined;
    }
    let mut quoted = String::from("\"");
    for byte in joined.bytes() {
        match byte {
            b'"' => quoted.push_str("\\\""),
            b'\\' => quoted.push_str("\\\\"),
            b'\n' => quoted.push_str("\\n"),
            b'\r' => quoted.push_str("\\r"),
            b'\t' => quoted.push_str("\\t"),
            b' '..=b'~' => quoted.push(byte as char),
            _ => quoted.push_str(&format!("\\{byte:03o}")),
        }
    }
    quoted.push('"');
    quoted
}

/// `staged == false` stages this file's entire worktree state; `true` restores
/// only its index entry to reviewed HEAD (or removes an addition/unborn entry).
pub fn stage_file(path: &Path, file: &str, staged: bool, expected: &str) -> Result<()> {
    stage_file_with_hooks(path, file, staged, expected, || Ok(()), || Ok(()))
}

#[cfg(test)]
fn stage_file_with_hook(
    path: &Path,
    file: &str,
    staged: bool,
    expected: &str,
    before_publish: impl FnOnce() -> Result<()>,
) -> Result<()> {
    stage_file_with_hooks(path, file, staged, expected, || Ok(()), before_publish)
}

fn stage_file_with_hooks(
    path: &Path,
    file: &str,
    staged: bool,
    expected: &str,
    before_conversion: impl FnOnce() -> Result<()>,
    before_publish: impl FnOnce() -> Result<()>,
) -> Result<()> {
    safe_relative(file)?;
    ensure!(!file.contains('\0'), "unsafe_relative_path");
    no_external_filters(path)?;
    no_conflicts(path)?;
    // The real Git index lock blocks other well-behaved Git writers throughout
    // review, candidate construction and publication, including other services.
    let mut transaction = IndexTransaction::new(path)?;
    let reviewed = snapshot(path)?;
    ensure!(digest(&reviewed)? == expected, "stale_snapshot");
    ensure_status_member(path, file, staged)?;
    let index_entries = git_bytes(path, &["ls-files", "--stage", "-z"])?;
    let current = index_entry(&index_entries, file)?;
    let head = head_entry(path, &reviewed, file)?;
    for entry in [current.as_ref(), head.as_ref()].into_iter().flatten() {
        ensure!(entry.mode != "160000", "unsupported_submodule_or_directory");
    }

    // Capture and bind the source before creating any staged blob. A file that
    // changes during/after this capture cannot contribute unreviewed bytes.
    let replacement = if staged {
        head.map(Replacement::Existing)
            .unwrap_or(Replacement::Remove)
    } else {
        capture(path, file, &reviewed, current.as_ref())?
    };
    let conversion = if matches!(&replacement, Replacement::Captured { symlink: false, .. }) {
        Some(crate::file_conversion::Conversion::capture(
            path,
            file,
            current
                .as_ref()
                .map(|entry| (entry.mode.as_str(), entry.oid.as_str())),
        )?)
    } else {
        None
    };
    ensure!(snapshot(path)? == reviewed, "stale_snapshot");
    no_external_filters(path)?;
    no_conflicts(path)?;

    deadline::write_budget(|| {
        transaction.prepare(path)?;
        let entry = match replacement {
            Replacement::Existing(entry) => Some(entry),
            Replacement::Remove => None,
            Replacement::Captured {
                bytes,
                mode,
                symlink,
            } => {
                // Never run conversion in the live repository: a filter can
                // appear between a probe and exec. Only isolated Git converts.
                no_external_filters(path)?;
                before_conversion()?;
                let bytes = if symlink {
                    bytes
                } else {
                    conversion
                        .as_ref()
                        .context("missing_conversion_context")?
                        .convert(file, &bytes)?
                };
                let oid = candidate_command(
                    path,
                    transaction.candidate.path(),
                    &["hash-object", "-w", "--no-filters", "--stdin"],
                    Some(&bytes),
                )?;
                let oid = String::from_utf8(oid)?.trim().to_string();
                ensure!(
                    matches!(oid.len(), 40 | 64) && oid.bytes().all(|c| c.is_ascii_hexdigit()),
                    "invalid_blob_oid"
                );
                Some(Entry { mode, oid })
            }
        };
        if let Some(entry) = entry {
            let record = format!("{} {}\t{}\0", entry.mode, entry.oid, file);
            candidate_command(
                path,
                transaction.candidate.path(),
                &["update-index", "-z", "--index-info"],
                Some(record.as_bytes()),
            )?;
        } else {
            candidate_command(
                path,
                transaction.candidate.path(),
                &["update-index", "--force-remove", "--", file],
                None,
            )?;
        }
        let candidate_entries = candidate_command(
            path,
            transaction.candidate.path(),
            &["ls-files", "--stage", "-z"],
            None,
        )?;
        ensure!(
            without_entry(&index_entries, file)? == without_entry(&candidate_entries, file)?,
            "unexpected_index_change"
        );
        before_publish()?;
        no_external_filters(path)?;
        no_conflicts(path)?;
        if let Some(conversion) = conversion {
            ensure!(conversion.same_context(path, file)?, "stale_snapshot");
        }
        ensure!(snapshot(path)? == reviewed, "stale_snapshot");
        transaction.publish()?;
        Ok(())
    })
}

fn ensure_status_member(path: &Path, file: &str, staged: bool) -> Result<()> {
    // No rename expansion: a tracked rename is represented as independently
    // selectable deletion/addition entries, so neither path stages its sibling.
    let status = git_bytes(
        path,
        &[
            "-c",
            "status.renames=false",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ],
    )?;
    let mut found = false;
    for row in status.split(|b| *b == 0).filter(|row| !row.is_empty()) {
        ensure!(row.len() >= 4, "invalid_status");
        if &row[3..] == file.as_bytes() {
            found = true;
            let changed = if staged {
                row[0] != b' ' && row[0] != b'?'
            } else {
                row[1] != b' '
            };
            if changed {
                return Ok(());
            }
        }
    }
    ensure!(!found, "file_not_changed_on_requested_side");
    bail!("invalid_file_stage_path")
}

#[derive(Clone)]
struct Entry {
    mode: String,
    oid: String,
}

fn index_entry(records: &[u8], file: &str) -> Result<Option<Entry>> {
    let mut result = None;
    for row in records.split(|b| *b == 0).filter(|row| !row.is_empty()) {
        let tab = row
            .iter()
            .position(|b| *b == b'\t')
            .context("invalid_index_entry")?;
        if &row[tab + 1..] == file.as_bytes() {
            let fields: Vec<_> = std::str::from_utf8(&row[..tab])?.split(' ').collect();
            ensure!(
                fields.len() == 3 && fields[2] == "0" && result.is_none(),
                "merge_conflict"
            );
            result = Some(Entry {
                mode: fields[0].into(),
                oid: fields[1].into(),
            });
        }
    }
    Ok(result)
}

fn head_entry(path: &Path, reviewed: &Snapshot, file: &str) -> Result<Option<Entry>> {
    if reviewed.head.is_empty() {
        return Ok(None);
    }
    let records = git_bytes(path, &["ls-tree", "-z", &reviewed.head, "--", file])?;
    let Some(row) = records.strip_suffix(&[0]) else {
        ensure!(records.is_empty(), "invalid_tree_entry");
        return Ok(None);
    };
    let tab = row
        .iter()
        .position(|b| *b == b'\t')
        .context("invalid_tree_entry")?;
    ensure!(
        &row[tab + 1..] == file.as_bytes(),
        "invalid_file_stage_path"
    );
    let fields: Vec<_> = std::str::from_utf8(&row[..tab])?.split(' ').collect();
    ensure!(
        fields.len() == 3 && fields[1] == "blob",
        "unsupported_submodule_or_directory"
    );
    Ok(Some(Entry {
        mode: fields[0].into(),
        oid: fields[2].into(),
    }))
}

enum Replacement {
    Existing(Entry),
    Remove,
    Captured {
        bytes: Vec<u8>,
        mode: String,
        symlink: bool,
    },
}

fn capture(
    path: &Path,
    file: &str,
    reviewed: &Snapshot,
    current: Option<&Entry>,
) -> Result<Replacement> {
    let full = path.join(file);
    let fingerprint = reviewed
        .files
        .get(file)
        .context("invalid_file_stage_path")?;
    let metadata = match fs::symlink_metadata(&full) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ensure!(fingerprint == "missing", "stale_snapshot");
            return Ok(Replacement::Remove);
        }
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() {
        let bytes = fs::read_link(&full)?
            .as_os_str()
            .as_encoded_bytes()
            .to_vec();
        ensure!(
            *fingerprint == format!("symlink:{}", hash(&bytes)),
            "stale_snapshot"
        );
        return Ok(Replacement::Captured {
            bytes,
            mode: "120000".into(),
            symlink: true,
        });
    }
    ensure!(metadata.is_file(), "unsupported_submodule_or_directory");
    ensure!(metadata.len() <= MAX_FILE_BYTES, "file_stage_too_large");
    let mut opened = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&full)?;
    ensure!(
        opened.metadata()?.is_file(),
        "unsupported_submodule_or_directory"
    );
    let mut bytes = Vec::new();
    Read::by_ref(&mut opened)
        .take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    check_deadline()?;
    ensure!(bytes.len() as u64 <= MAX_FILE_BYTES, "file_stage_too_large");
    ensure!(
        *fingerprint == format!("file:{:o}:{}", metadata.mode() & 0o777, hash(&bytes)),
        "stale_snapshot"
    );
    let filemode = git(
        path,
        &[
            "config",
            "--bool",
            "--default=true",
            "--get",
            "core.filemode",
        ],
    )?;
    let mode = if filemode.trim() == "false" {
        current
            .filter(|entry| entry.mode == "100644" || entry.mode == "100755")
            .map_or_else(|| "100644".into(), |entry| entry.mode.clone())
    } else if metadata.mode() & 0o100 != 0 {
        "100755".into()
    } else {
        "100644".into()
    };
    // On platforms/checkouts that materialize symlinks as ordinary files, Git
    // still stages their literal target bytes with the existing symlink mode.
    let symlink = current.is_some_and(|entry| entry.mode == "120000")
        && git(
            path,
            &[
                "config",
                "--bool",
                "--default=true",
                "--get",
                "core.symlinks",
            ],
        )?
        .trim()
            == "false";
    Ok(Replacement::Captured {
        bytes,
        mode: if symlink { "120000".into() } else { mode },
        symlink,
    })
}

fn without_entry(records: &[u8], file: &str) -> Result<Vec<Vec<u8>>> {
    let mut result = vec![];
    for row in records.split(|b| *b == 0).filter(|row| !row.is_empty()) {
        let tab = row
            .iter()
            .position(|b| *b == b'\t')
            .context("invalid_index_entry")?;
        if &row[tab + 1..] != file.as_bytes() {
            result.push(row.to_vec());
        }
    }
    Ok(result)
}

fn candidate_command(
    path: &Path,
    index: &Path,
    args: &[&str],
    input: Option<&[u8]>,
) -> Result<Vec<u8>> {
    let mut command = git_command(path, &[&["-c", "core.splitIndex=false"][..], args].concat());
    // This is the only environment override: the private candidate, never an
    // inherited GIT_INDEX_FILE. All other safe Git defaults remain in force.
    command.env("GIT_INDEX_FILE", index);
    let output = process::run(command, input, Duration::from_secs(120), 8 * 1024 * 1024)?;
    ensure!(
        output.status.success(),
        "git_failed: {}",
        String::from_utf8_lossy(&output.stderr)
            .chars()
            .take(2000)
            .collect::<String>()
    );
    Ok(output.stdout)
}

struct IndexTransaction {
    index: PathBuf,
    lock_path: PathBuf,
    lock: File,
    original: Option<Vec<u8>>,
    candidate: NamedTempFile,
    published: bool,
}
impl IndexTransaction {
    fn new(path: &Path) -> Result<Self> {
        let index = git_path(
            path,
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        )?;
        let mut lock_name = index.as_os_str().to_os_string();
        lock_name.push(".lock");
        let lock_path = PathBuf::from(lock_name);
        let lock = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&lock_path)
            .context("repository_busy")?;
        // Install cleanup before fallible reads/candidate creation.
        let setup = || -> Result<_> {
            let original = read_index(&index)?;
            let candidate = tempfile::Builder::new()
                .prefix("river-index-")
                .tempfile_in(index.parent().context("invalid_index_path")?)?;
            Ok((original, candidate))
        };
        let (original, candidate) = match setup() {
            Ok(value) => value,
            Err(error) => {
                if same_file(&lock, &lock_path) {
                    let _ = fs::remove_file(&lock_path);
                }
                return Err(error);
            }
        };
        Ok(Self {
            index,
            lock_path,
            lock,
            original,
            candidate,
            published: false,
        })
    }
    fn prepare(&mut self, path: &Path) -> Result<()> {
        if let Some(original) = &self.original {
            self.candidate.write_all(original)?;
            self.candidate.flush()?;
        } else {
            fs::remove_file(self.candidate.path())?;
            candidate_command(path, self.candidate.path(), &["read-tree", "--empty"], None)?;
        }
        Ok(())
    }
    fn publish(&mut self) -> Result<()> {
        // Catch a writer that ignored index.lock, including stat/flag changes
        // which the semantic review snapshot intentionally does not contain.
        ensure!(read_index(&self.index)? == self.original, "stale_snapshot");
        let candidate = read_index(self.candidate.path())?.context("missing_candidate_index")?;
        self.lock.write_all(&candidate)?;
        self.lock.sync_all()?;
        ensure!(self.owns_lock(), "repository_busy");
        fs::rename(&self.lock_path, &self.index).context("git_write_outcome_unknown")?;
        self.published = true;
        Ok(())
    }
    fn owns_lock(&self) -> bool {
        same_file(&self.lock, &self.lock_path)
    }
}
impl Drop for IndexTransaction {
    fn drop(&mut self) {
        if !self.published && self.owns_lock() {
            let _ = fs::remove_file(&self.lock_path);
        }
        let mut candidate_lock = self.candidate.path().as_os_str().to_os_string();
        candidate_lock.push(".lock");
        let _ = fs::remove_file(PathBuf::from(candidate_lock));
    }
}
fn same_file(opened: &File, path: &Path) -> bool {
    match (opened.metadata(), fs::symlink_metadata(path)) {
        (Ok(opened), Ok(current)) => {
            current.is_file() && current.dev() == opened.dev() && current.ino() == opened.ino()
        }
        _ => false,
    }
}
fn read_index(index: &Path) -> Result<Option<Vec<u8>>> {
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(index)
    {
        Ok(mut file) => {
            ensure!(file.metadata()?.is_file(), "unsafe_index_file");
            ensure!(
                file.metadata()?.len() <= MAX_INDEX_BYTES,
                "result_too_large"
            );
            let mut bytes = Vec::new();
            Read::by_ref(&mut file)
                .take(MAX_INDEX_BYTES + 1)
                .read_to_end(&mut bytes)?;
            ensure!(bytes.len() as u64 <= MAX_INDEX_BYTES, "result_too_large");
            Ok(Some(bytes))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).context("unsafe_index_file"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> tempfile::TempDir {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path();
        git(path, &["init", "-b", "main"]).unwrap();
        git(path, &["config", "user.name", "Synthetic staging test"]).unwrap();
        git(path, &["config", "user.email", "staging@example.invalid"]).unwrap();
        fs::write(path.join("selected"), "before\n").unwrap();
        git(path, &["add", "--", "selected"]).unwrap();
        git(path, &["commit", "-m", "baseline"]).unwrap();
        fs::write(path.join("selected"), "reviewed\n").unwrap();
        temp
    }

    #[test]
    fn changed_source_between_candidate_and_publish_is_rejected_without_staging_it() {
        let temp = fixture();
        let path = temp.path();
        let original_index = fs::read(path.join(".git/index")).unwrap();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let error = stage_file_with_hook(path, "selected", false, &reviewed, || {
            fs::write(path.join("selected"), "unreviewed\n")?;
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "stale_snapshot");
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), original_index);
        assert_eq!(git(path, &["show", ":selected"]).unwrap(), "before\n");
        assert_eq!(
            fs::read_to_string(path.join("selected")).unwrap(),
            "unreviewed\n"
        );
        assert!(!path.join(".git/index.lock").exists());
    }

    #[test]
    fn raw_index_change_ignoring_git_lock_is_never_overwritten() {
        let temp = fixture();
        let path = temp.path();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let original = fs::read(path.join(".git/index")).unwrap();
        // An assume-unchanged flag changes raw index bytes while Git still
        // exposes the same modes/OIDs. The semantic snapshot alone is not CAS.
        let mut other = tempfile::NamedTempFile::new_in(path.join(".git")).unwrap();
        other.write_all(&original).unwrap();
        candidate_command(
            path,
            other.path(),
            &["update-index", "--assume-unchanged", "--", "selected"],
            None,
        )
        .unwrap();
        let external = fs::read(other.path()).unwrap();
        assert_ne!(external, original);
        let error = stage_file_with_hook(path, "selected", false, &reviewed, || {
            fs::write(path.join(".git/index"), &external)?;
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "stale_snapshot");
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), external);
        assert!(!path.join(".git/index.lock").exists());
    }

    #[test]
    fn candidate_failure_preserves_index_and_cleans_locks() {
        let temp = fixture();
        let path = temp.path();
        let original = fs::read(path.join(".git/index")).unwrap();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let error = stage_file_with_hook(path, "selected", false, &reviewed, || {
            bail!("injected_failure")
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "injected_failure");
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), original);
        assert!(!path.join(".git/index.lock").exists());
        assert!(!fs::read_dir(path.join(".git")).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .as_encoded_bytes()
                .starts_with(b"river-index-")
        }));
    }

    #[test]
    fn replaced_lock_is_never_published_or_removed_as_our_own() {
        let temp = fixture();
        let path = temp.path();
        let original = fs::read(path.join(".git/index")).unwrap();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let error = stage_file_with_hook(path, "selected", false, &reviewed, || {
            fs::remove_file(path.join(".git/index.lock"))?;
            fs::write(path.join(".git/index.lock"), "external lock replacement")?;
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "repository_busy");
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), original);
        assert_eq!(
            fs::read(path.join(".git/index.lock")).unwrap(),
            b"external lock replacement"
        );
    }

    #[test]
    fn driver_installed_after_the_probe_never_executes_or_publishes() {
        for (driver, value) in [
            ("clean", "touch driver-must-not-run; cat"),
            ("process", "touch driver-must-not-run; cat"),
            ("required", "true"),
        ] {
            let temp = fixture();
            let path = temp.path();
            fs::write(path.join(".gitattributes"), "selected text filter=late\n").unwrap();
            let original = fs::read(path.join(".git/index")).unwrap();
            let reviewed = digest(&snapshot(path).unwrap()).unwrap();
            let error = stage_file_with_hooks(
                path,
                "selected",
                false,
                &reviewed,
                || {
                    git(path, &["config", &format!("filter.late.{driver}"), value])?;
                    Ok(())
                },
                || Ok(()),
            )
            .unwrap_err();
            assert_eq!(error.to_string(), "unsupported_external_filter");
            assert!(!path.join("driver-must-not-run").exists());
            assert_eq!(fs::read(path.join(".git/index")).unwrap(), original);
            assert_eq!(fs::read(path.join("selected")).unwrap(), b"reviewed\n");
            assert!(!path.join(".git/index.lock").exists());
        }
    }

    #[test]
    fn included_config_and_global_attribute_driver_swap_never_executes_or_publishes() {
        let temp = fixture();
        let path = temp.path();
        let included = path.join(".git/included-config");
        let attributes = path.join(".git/global-attributes");
        fs::write(&included, "[core]\n\tautocrlf = true\n").unwrap();
        fs::write(&attributes, "selected text filter=undefined\n").unwrap();
        git(
            path,
            &["config", "include.path", included.to_str().unwrap()],
        )
        .unwrap();
        git(
            path,
            &[
                "config",
                "core.attributesFile",
                attributes.to_str().unwrap(),
            ],
        )
        .unwrap();
        let original = fs::read(path.join(".git/index")).unwrap();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let error = stage_file_with_hooks(path, "selected", false, &reviewed, || {
            fs::write(&attributes, "selected text filter=late\n")?;
            fs::write(&included, "[core]\n\tautocrlf = false\n[filter \"late\"]\n\tclean = touch included-driver-must-not-run; cat\n")?;
            Ok(())
        }, || Ok(())).unwrap_err();
        assert_eq!(error.to_string(), "unsupported_external_filter");
        assert!(!path.join("included-driver-must-not-run").exists());
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), original);
    }

    #[test]
    fn info_attributes_changed_outside_the_snapshot_reject_publication() {
        let temp = fixture();
        let path = temp.path();
        fs::write(path.join(".git/info/attributes"), "selected text eol=lf\n").unwrap();
        let original = fs::read(path.join(".git/index")).unwrap();
        let reviewed = digest(&snapshot(path).unwrap()).unwrap();
        let error = stage_file_with_hooks(
            path,
            "selected",
            false,
            &reviewed,
            || {
                fs::write(path.join(".git/info/attributes"), "selected -text\n")?;
                Ok(())
            },
            || Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "stale_snapshot");
        assert_eq!(fs::read(path.join(".git/index")).unwrap(), original);
    }
}

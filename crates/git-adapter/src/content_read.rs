//! A read transaction may inspect the real worktree, but conversion never loads
//! its live configuration or attributes. Only frozen data enters this Gitdir.
use crate::{check_deadline, file_conversion, git, git_bytes, git_command, git_path, process};
use anyhow::{Context, Result, ensure};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Output},
    time::{Duration, SystemTime},
};
use workbench_domain::{Snapshot, safe_relative};

const SMALL: usize = 1024 * 1024;
const TOTAL: usize = 8 * SMALL;
const INDEX: usize = 64 * SMALL;

#[derive(Eq)]
struct FrozenFile {
    bytes: Vec<u8>,
    modified: SystemTime,
}
// Timestamps are copied for Git's stat-cache semantics, not content identity.
// Native metadata reads may freshen an otherwise byte-identical index.
impl PartialEq for FrozenFile {
    fn eq(&self, other: &Self) -> bool {
        self.bytes == other.bytes
    }
}

#[derive(PartialEq, Eq)]
struct Inputs {
    config: Vec<u8>,
    format: String,
    git_dir: PathBuf,
    common: PathBuf,
    head: Vec<u8>,
    refs: Vec<u8>,
    index: Option<FrozenFile>,
    shared: Option<(PathBuf, FrozenFile)>,
    // Every optional source retains absence as well as bytes. Entries include
    // external attributes/excludes and applicable .gitignore/.gitattributes.
    sources: BTreeMap<PathBuf, Option<Vec<u8>>>,
    attributes: BTreeMap<String, Vec<u8>>,
    global_attributes: Vec<u8>,
    info_attributes: Vec<u8>,
    exclude: Option<Vec<u8>>,
    tree_source: Option<String>,
    settings: BTreeMap<String, Option<String>>,
}

pub(super) struct ContentReadContext {
    _temp: tempfile::TempDir,
    metadata: PathBuf,
    source: PathBuf,
    inputs: Inputs,
    snapshot: Snapshot,
    selected: Option<String>,
    attr_tree: String,
}
impl ContentReadContext {
    pub(super) fn capture(
        path: &Path,
        snapshot: &Snapshot,
        selected: Option<&str>,
    ) -> Result<Self> {
        let source = fs::canonicalize(path).context("invalid_repo_path")?;
        let path = source.as_path();
        let inputs = Inputs::capture(path, snapshot, selected)?;
        let temp = tempfile::TempDir::new()?;
        let metadata = temp.path().join("metadata");
        fs::create_dir_all(metadata.join("objects/info"))?;
        fs::create_dir_all(metadata.join("refs"))?;
        fs::create_dir_all(metadata.join("info"))?;
        let config = if inputs.format == "sha256" {
            "[core]\nrepositoryformatversion = 1\nbare = false\n[extensions]\nobjectformat = sha256\n"
        } else {
            "[core]\nrepositoryformatversion = 0\nbare = false\n"
        };
        fs::write(metadata.join("config"), config)?;
        fs::write(metadata.join("HEAD"), &inputs.head)?;
        fs::write(metadata.join("packed-refs"), &inputs.refs)?;
        if let Some(index) = &inputs.index {
            write_frozen(&metadata.join("index"), index)?;
        }
        if let Some((source, bytes)) = &inputs.shared {
            write_frozen(
                &metadata.join(source.file_name().context("unsupported_content_read")?),
                bytes,
            )?;
        }
        for name in ["shallow", "info/sparse-checkout", "info/exclude"] {
            let source = if name == "info/sparse-checkout" {
                inputs.git_dir.join(name)
            } else {
                inputs.common.join(name)
            };
            if let Some(Some(bytes)) = inputs.sources.get(&source) {
                fs::write(metadata.join(name), bytes)?;
            }
        }
        fs::write(
            metadata.join("frozen-global-attributes"),
            &inputs.global_attributes,
        )?;
        fs::write(metadata.join("info/attributes"), &inputs.info_attributes)?;
        fs::write(
            metadata.join("frozen-excludes"),
            inputs.exclude.as_deref().unwrap_or_default(),
        )?;
        let mut context = Self {
            _temp: temp,
            metadata,
            source: path.into(),
            inputs,
            snapshot: snapshot.clone(),
            selected: selected.map(str::to_string),
            attr_tree: String::new(),
        };
        // --attr-source was introduced in Git 2.43. Probe the actual /usr/bin/git
        // capability rather than trusting a different shell Git's version.
        static ATTR_SOURCE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        let supported = if let Some(supported) = ATTR_SOURCE.get() {
            *supported
        } else {
            let probe = context.output(
                &["--attr-source=HEAD", "check-attr", "--stdin"],
                Some(b""),
                SMALL,
            )?;
            let stderr = String::from_utf8_lossy(&probe.stderr);
            let supported =
                !stderr.contains("unknown option") && !stderr.contains("unknown switch");
            let _ = ATTR_SOURCE.set(supported);
            supported
        };
        ensure!(supported, "content_read_git_upgrade_required");
        context.attr_tree = if let Some(tree) = &context.inputs.tree_source {
            tree.clone()
        } else {
            context.build_attribute_tree()?
        };
        Ok(context)
    }
    fn build_attribute_tree(&self) -> Result<String> {
        if self.inputs.attributes.is_empty() {
            let output = self.output(&["mktree"], Some(b""), SMALL)?;
            ensure!(output.status.success(), "unsupported_content_read");
            return Ok(std::str::from_utf8(&output.stdout)?.trim().to_string());
        }
        let index = self.metadata.join("attribute-index");
        let run = |args: &[&str], input: Option<&[u8]>| -> Result<Vec<u8>> {
            let mut command = self.command(args);
            command.env("GIT_INDEX_FILE", &index);
            let output = process::run(command, input, Duration::from_secs(15), TOTAL)?;
            ensure!(output.status.success(), "unsupported_content_read");
            Ok(output.stdout)
        };
        run(&["read-tree", "--empty"], None)?;
        let mut entries = Vec::new();
        // Batch blob creation avoids one subprocess per applicable directory.
        for (batch, chunk) in self
            .inputs
            .attributes
            .iter()
            .collect::<Vec<_>>()
            .chunks(128)
            .enumerate()
        {
            let mut paths = Vec::new();
            for (offset, (_, bytes)) in chunk.iter().enumerate() {
                check_deadline()?;
                let path = self.metadata.join(format!("attr-{batch}-{offset}"));
                fs::write(&path, bytes)?;
                paths.push(path);
            }
            let mut command = self.command(&["hash-object", "-w", "--no-filters", "--"]);
            command.args(&paths);
            let output = process::run(command, None, Duration::from_secs(15), SMALL)?;
            ensure!(output.status.success(), "unsupported_content_read");
            let oids = std::str::from_utf8(&output.stdout)?
                .lines()
                .collect::<Vec<_>>();
            ensure!(oids.len() == chunk.len(), "unsupported_content_read");
            for ((name, _), oid) in chunk.iter().zip(oids) {
                entries.extend_from_slice(format!("100644 {oid}\t{name}\0").as_bytes());
            }
            for path in paths {
                fs::remove_file(path)?;
            }
        }
        run(&["update-index", "-z", "--index-info"], Some(&entries))?;
        Ok(std::str::from_utf8(&run(&["write-tree"], None)?)?
            .trim()
            .to_string())
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut command = git_command(&self.source, &[]);
        command
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_ATTR_NOSYSTEM", "1")
            .env(
                "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                quote_alternate(&self.inputs.common.join("objects")),
            );
        if !self.attr_tree.is_empty() {
            command.env("GIT_ATTR_SOURCE", &self.attr_tree);
        }
        for (key, value) in &self.inputs.settings {
            command.arg("-c").arg(
                value
                    .as_ref()
                    .map_or_else(|| key.clone(), |v| format!("{key}={v}")),
            );
        }
        for (key, value) in [
            (
                "core.attributesFile",
                self.metadata.join("frozen-global-attributes"),
            ),
            ("core.excludesFile", self.metadata.join("frozen-excludes")),
        ] {
            let mut setting = OsString::from(format!("{key}="));
            setting.push(value);
            command.arg("-c").arg(setting);
        }
        command
            .arg("--git-dir")
            .arg(&self.metadata)
            .arg("--work-tree")
            .arg(&self.source)
            .args(args);
        command
    }
    pub(super) fn output(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        limit: usize,
    ) -> Result<Output> {
        process::run(self.command(args), input, Duration::from_secs(15), limit)
    }
    pub(super) fn bytes(&self, args: &[&str]) -> Result<Vec<u8>> {
        let output = self.output(args, None, TOTAL)?;
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
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.inputs == Inputs::capture(&self.source, &self.snapshot, self.selected.as_deref())?,
            "stale_read_snapshot"
        );
        Ok(())
    }
}

fn allowed(key: &str) -> bool {
    matches!(
        key,
        "core.autocrlf"
            | "core.eol"
            | "core.safecrlf"
            | "core.checkroundtripencoding"
            | "core.filemode"
            | "core.symlinks"
            | "core.ignorecase"
            | "core.precomposeunicode"
            | "core.trustctime"
            | "core.checkstat"
            | "core.ignorestat"
            | "core.quotepath"
            | "core.abbrev"
            | "core.bigfilethreshold"
            | "core.sparsecheckout"
            | "core.sparsecheckoutcone"
            | "index.sparse"
            | "diff.algorithm"
            | "diff.indentheuristic"
            | "diff.mnemonicprefix"
            | "diff.noprefix"
            | "diff.relative"
            | "diff.renamelimit"
            | "diff.ignoresubmodules"
            | "diff.ignoreSubmodules"
            | "diff.submodule"
            | "diff.wordregex"
            | "diff.interhunkcontext"
            | "diff.context"
            | "diff.renames"
            | "status.renames"
            | "status.showuntrackedfiles"
    ) || (key.starts_with("diff.")
        && key.rsplit_once('.').is_some_and(|(_, suffix)| {
            matches!(
                suffix,
                "binary" | "wordregex" | "funcname" | "xfuncname" | "algorithm"
            )
        }))
}
impl Inputs {
    fn capture(path: &Path, snapshot: &Snapshot, selected: Option<&str>) -> Result<Self> {
        check_deadline()?;
        let config = git_bytes(path, &["config", "--includes", "--null", "--list"])?;
        ensure!(config.len() <= SMALL, "unsupported_content_read");
        let mut settings = BTreeMap::new();
        let mut attr_source = None;
        let mut format = "sha1".to_string();
        for row in config.split(|b| *b == 0).filter(|row| !row.is_empty()) {
            check_deadline()?;
            let split = row.iter().position(|b| *b == b'\n');
            let raw_key = std::str::from_utf8(&row[..split.unwrap_or(row.len())])?;
            let key = raw_key.to_ascii_lowercase();
            let value = split
                .map(|n| std::str::from_utf8(&row[n + 1..]).map(str::to_string))
                .transpose()?;
            if key == "extensions.objectformat" {
                format = value.clone().context("unsupported_content_read")?;
            }
            if key.starts_with("filter.")
                && key
                    .rsplit_once('.')
                    .is_some_and(|(_, suffix)| matches!(suffix, "clean" | "smudge" | "process"))
            {
                let executable = value.as_ref().context("invalid_filter_config")?;
                ensure!(
                    executable.bytes().all(|byte| byte.is_ascii_whitespace()),
                    "unsupported_external_filter"
                );
            }
            if key == "attr.tree" {
                attr_source = value.clone();
            }
            if key.starts_with("filter.") && key.ends_with(".required") {
                // Let Git parse boolean spelling, including a valueless true.
                let out = process::run(
                    git_command(path, &["config", "--type=bool", "--get", raw_key]),
                    None,
                    Duration::from_secs(15),
                    SMALL,
                )?;
                ensure!(
                    out.status.success() && out.stdout == b"false\n",
                    "unsupported_external_filter"
                );
            }
            if allowed(&key) {
                settings.insert(raw_key.to_string(), value);
            }
        }
        let git_dir = git_path(path, &["rev-parse", "--absolute-git-dir"])?;
        let common = crate::common_dir(path)?;
        ensure!(
            matches!(format.as_str(), "sha1" | "sha256"),
            "unsupported_content_read"
        );
        let head = read(&git_dir.join("HEAD"), SMALL)?.context("unsupported_content_read")?;
        let refs = git_bytes(path, &["for-each-ref", "--format=%(objectname) %(refname)"])?;
        let index = read_stamped(&git_dir.join("index"), INDEX)?;
        let shared_path = git(path, &["rev-parse", "--shared-index-path"])?;
        let shared = if shared_path == "\n" || shared_path.is_empty() {
            None
        } else {
            let resolved = crate::path_from_record(&shared_path)?;
            let resolved = if resolved.is_absolute() {
                resolved
            } else {
                path.join(resolved)
            };
            ensure!(
                resolved
                    .file_name()
                    .is_some_and(|n| n.as_encoded_bytes().starts_with(b"sharedindex.")),
                "unsupported_content_read"
            );
            Some((
                resolved.clone(),
                read_stamped(&resolved, INDEX)?.context("unsupported_content_read")?,
            ))
        };
        let mut sources = BTreeMap::new();
        let total = std::cell::Cell::new(0usize);
        let mut capture = |source: PathBuf| -> Result<Option<Vec<u8>>> {
            let bytes = read(&source, SMALL)?;
            total.set(total.get() + bytes.as_ref().map_or(0, Vec::len));
            ensure!(total.get() <= TOTAL, "unsupported_content_read");
            sources.insert(source, bytes.clone());
            Ok(bytes)
        };
        let mut global_attributes = Vec::new();
        for variable in ["GIT_ATTR_SYSTEM", "GIT_ATTR_GLOBAL"] {
            let source = file_conversion::attribute_path(path, variable).map_err(|error| {
                if error.to_string() == "file_staging_git_upgrade_required" {
                    anyhow::anyhow!("content_read_git_upgrade_required")
                } else {
                    error
                }
            })?;
            if let Some(bytes) = capture(source)? {
                global_attributes.extend_from_slice(strip_bom(&bytes));
            }
            global_attributes.push(b'\n');
        }
        let mut info_attributes = capture(common.join("info/attributes"))?.unwrap_or_default();
        info_attributes.extend_from_slice(b"\n* -filter\n");
        // config --path expands tilde and included config origins exactly as Git
        // does. The default global ignore file is specified by gitignore(5).
        let excludes = process::run(
            git_command(
                path,
                &["config", "--null", "--path", "--get", "core.excludesfile"],
            ),
            None,
            Duration::from_secs(15),
            SMALL,
        )?;
        let exclude_path = if excludes.status.success() {
            let bytes = excludes
                .stdout
                .strip_suffix(&[0])
                .context("unsupported_content_read")?;
            let value = PathBuf::from(std::str::from_utf8(bytes)?);
            if value.is_absolute() {
                value
            } else {
                path.join(value)
            }
        } else {
            ensure!(
                excludes.status.code() == Some(1),
                "unsupported_content_read"
            );
            std::env::var_os("XDG_CONFIG_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
                })
                .join("git/ignore")
        };
        let exclude = capture(exclude_path)?;
        // Git's info directory is common in linked worktrees; sparse-checkout is
        // per-worktree. Capture both exact resolved locations when applicable.
        for source in [
            common.join("shallow"),
            common.join("info/exclude"),
            git_dir.join("info/sparse-checkout"),
            common.join("objects/info/alternates"),
        ] {
            capture(source)?;
        }
        let mut ancestors = BTreeSet::from([PathBuf::new()]);
        for name in snapshot.files.keys().map(String::as_str).chain(selected) {
            check_deadline()?;
            safe_relative(name)?;
            let mut parent = Path::new(name).parent();
            let mut depth = 0;
            while let Some(dir) = parent {
                check_deadline()?;
                depth += 1;
                ensure!(depth <= 128, "unsupported_content_read");
                ancestors.insert(dir.to_path_buf());
                ensure!(ancestors.len() <= 16_384, "unsupported_content_read");
                parent = dir.parent();
            }
        }
        ensure!(ancestors.len() <= 16_384, "unsupported_content_read");
        let indexed = git_bytes(path, &["ls-files", "--stage", "-z"])?;
        let mut index_attrs = BTreeMap::new();
        for row in indexed.split(|b| *b == 0).filter(|r| !r.is_empty()) {
            check_deadline()?;
            let tab = row
                .iter()
                .position(|b| *b == b'\t')
                .context("unsupported_content_read")?;
            let name = std::str::from_utf8(&row[tab + 1..])?;
            if Path::new(name)
                .file_name()
                .is_some_and(|n| n == ".gitattributes")
            {
                let fields: Vec<_> = std::str::from_utf8(&row[..tab])?.split(' ').collect();
                ensure!(
                    fields.len() == 3
                        && fields[2] == "0"
                        && matches!(fields[0], "100644" | "100755"),
                    "unsupported_content_read"
                );
                index_attrs.insert(name.to_string(), fields[1].to_string());
            }
        }
        let mut attributes = BTreeMap::new();
        for dir in ancestors {
            check_deadline()?;
            capture(path.join(&dir).join(".gitignore"))?;
            let relative = dir.join(".gitattributes");
            let name = relative.to_str().context("unsupported_content_read")?;
            let working = capture(path.join(&relative))?;
            if let Some(bytes) = working {
                attributes.insert(name.to_string(), strip_bom(&bytes).to_vec());
            } else if let Some(oid) = index_attrs.get(name) {
                let bytes = file_conversion::source_blob(path, oid, SMALL)?;
                total.set(total.get() + bytes.len());
                ensure!(total.get() <= TOTAL, "unsupported_content_read");
                attributes.insert(name.to_string(), bytes);
            }
        }
        let tree_source = if let Some(source) = attr_source {
            ensure!(
                !source.starts_with('-') && !source.contains('\0'),
                "unsupported_content_read"
            );
            let out = process::run(
                git_command(
                    path,
                    &[
                        "rev-parse",
                        "--verify",
                        "--end-of-options",
                        &format!("{source}^{{tree}}"),
                    ],
                ),
                None,
                Duration::from_secs(15),
                SMALL,
            )?;
            if out.status.success() {
                Some(std::str::from_utf8(&out.stdout)?.trim().to_string())
            } else {
                return Err(anyhow::anyhow!(
                    "unsupported_content_read: invalid attr.tree"
                ));
            }
        } else {
            None
        };
        Ok(Self {
            config,
            format,
            git_dir,
            common,
            head,
            refs,
            index,
            shared,
            sources,
            attributes,
            global_attributes,
            info_attributes,
            exclude,
            tree_source,
            settings,
        })
    }
}
fn strip_bom(bytes: &[u8]) -> &[u8] {
    bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes)
}
fn quote_alternate(path: &Path) -> OsString {
    // Git's alternates environment accepts a C-quoted entry, even with ':' or LF.
    let mut value = String::from("\"");
    for byte in path.as_os_str().as_encoded_bytes() {
        match byte {
            b'"' => value.push_str("\\\""),
            b'\\' => value.push_str("\\\\"),
            b' '..=b'~' => value.push(*byte as char),
            _ => value.push_str(&format!("\\{byte:03o}")),
        }
    }
    value.push('"');
    value.into()
}
fn write_frozen(path: &Path, file: &FrozenFile) -> Result<()> {
    fs::write(path, &file.bytes)?;
    // Git's racy-clean test uses the index file mtime. A fresh copy would make
    // recent same-size worktree edits incorrectly appear clean.
    fs::File::open(path)?.set_times(fs::FileTimes::new().set_modified(file.modified))?;
    Ok(())
}
fn read(path: &Path, limit: usize) -> Result<Option<Vec<u8>>> {
    Ok(read_stamped(path, limit)?.map(|file| file.bytes))
}
fn read_stamped(path: &Path, limit: usize) -> Result<Option<FrozenFile>> {
    check_deadline()?;
    let metadata = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => anyhow::bail!("unsupported_content_read"),
    };
    ensure!(
        metadata.is_file() && metadata.len() <= limit as u64,
        "unsupported_content_read"
    );
    let stamp = |m: &fs::Metadata| {
        (
            m.dev(),
            m.ino(),
            m.len(),
            m.mode(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        )
    };
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .context("unsupported_content_read")?;
    ensure!(
        stamp(&file.metadata()?) == stamp(&metadata),
        "stale_read_snapshot"
    );
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        check_deadline()?;
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        ensure!(
            bytes.len() + n <= limit && bytes.len() + n <= metadata.len() as usize,
            "stale_read_snapshot"
        );
        bytes.extend_from_slice(&buffer[..n]);
    }
    ensure!(
        stamp(&file.metadata()?) == stamp(&metadata)
            && stamp(&fs::symlink_metadata(path)?) == stamp(&metadata),
        "stale_read_snapshot"
    );
    Ok(Some(FrozenFile {
        bytes,
        modified: metadata.modified()?,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::Cell, rc::Rc};

    fn fixture(format: &str) -> tempfile::TempDir {
        let temp = tempfile::TempDir::new().unwrap();
        git(
            temp.path(),
            &["init", "-b", "main", &format!("--object-format={format}")],
        )
        .unwrap();
        git(temp.path(), &["config", "user.name", "Synthetic Reviewer"]).unwrap();
        git(
            temp.path(),
            &["config", "user.email", "review@example.invalid"],
        )
        .unwrap();
        git(temp.path(), &["config", "core.autocrlf", "false"]).unwrap();
        temp
    }
    fn commit(path: &Path) {
        git(path, &["add", "--", "."]).unwrap();
        git(path, &["commit", "-m", "Synthetic baseline"]).unwrap();
    }
    fn parity(path: &Path, selected: &str) {
        let snapshot = crate::snapshot(path).unwrap();
        let context = ContentReadContext::capture(path, &snapshot, Some(selected)).unwrap();
        let original_index = read(&context.inputs.git_dir.join("index"), INDEX).unwrap();
        for args in [
            vec![
                "-c",
                "status.renames=false",
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--ignore-submodules=all",
            ],
            vec![
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--",
                selected,
            ],
            vec![
                "diff",
                "--cached",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--",
                selected,
            ],
        ] {
            assert_eq!(
                context.bytes(&args).unwrap(),
                git_bytes(path, &args).unwrap(),
                "{args:?}"
            );
        }
        context.validate().unwrap();
        assert_eq!(
            original_index,
            read(&context.inputs.git_dir.join("index"), INDEX).unwrap()
        );
        assert_eq!(snapshot, crate::snapshot(path).unwrap());
    }
    #[test]
    fn ordinary_unborn_sha256_and_split_index_reads_preserve_bytes_and_flags() {
        for format in ["sha1", "sha256"] {
            let temp = fixture(format);
            let path = temp.path();
            fs::write(path.join("selected"), b"first\n").unwrap();
            parity(path, "selected"); // untracked/unborn, no index or refs yet
            commit(path);
            fs::write(path.join("selected"), b"second\n").unwrap();
            fs::write(path.join("unchanged"), b"sibling\n").unwrap();
            git(path, &["add", "--", "unchanged"]).unwrap();
            git(
                path,
                &["update-index", "--skip-worktree", "--", "unchanged"],
            )
            .unwrap();
            git(path, &["update-index", "--split-index"]).unwrap();
            parity(path, "selected");
            let flags = git(path, &["ls-files", "-v"]).unwrap();
            assert!(flags.contains("S unchanged"));
        }
    }
    #[test]
    fn builtin_diff_driver_subsection_names_remain_case_sensitive() {
        let temp = fixture("sha1");
        let path = temp.path();
        git(path, &["config", "diff.MixedCase.xfuncname", "^FUNCTION.*"]).unwrap();
        fs::write(path.join(".gitattributes"), "selected diff=MixedCase\n").unwrap();
        fs::write(
            path.join("selected"),
            b"FUNCTION synthetic\n1\n2\n3\n4\n5\nold\n7\n8\n9\n",
        )
        .unwrap();
        commit(path);
        fs::write(
            path.join("selected"),
            b"FUNCTION synthetic\n1\n2\n3\n4\n5\nnew\n7\n8\n9\n",
        )
        .unwrap();
        parity(path, "selected");
        assert!(
            crate::diff(path, "selected", false)
                .unwrap()
                .text
                .contains("@@ -4,7 +4,7 @@ FUNCTION synthetic")
        );
    }
    #[test]
    fn copied_index_preserves_racy_clean_detection_for_same_size_recent_edits() {
        let temp = fixture("sha1");
        let path = temp.path();
        git(path, &["config", "core.trustctime", "false"]).unwrap();
        git(path, &["config", "core.checkstat", "minimal"]).unwrap();
        let file = path.join("selected");
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        fs::write(&file, b"old\n").unwrap();
        fs::File::open(&file)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
        commit(path);
        fs::File::open(path.join(".git/index"))
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
        fs::write(&file, b"new\n").unwrap();
        fs::File::open(&file)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
        let native = git_bytes(
            path,
            &["diff", "--no-ext-diff", "--no-textconv", "--", "selected"],
        )
        .unwrap();
        assert!(String::from_utf8_lossy(&native).contains("+new"));
        let diff = crate::diff(path, "selected", false).unwrap();
        assert!(diff.text.contains("+new"), "{}", diff.text);
        parity(path, "selected");
    }
    #[test]
    fn shallow_and_literal_repository_paths_keep_the_frozen_object_context() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("repository:with\nnewline");
        fs::create_dir(&path).unwrap();
        git(&path, &["init", "-b", "main"]).unwrap();
        git(&path, &["config", "user.name", "Synthetic Reviewer"]).unwrap();
        git(&path, &["config", "user.email", "review@example.invalid"]).unwrap();
        fs::write(path.join("selected"), b"first\n").unwrap();
        commit(&path);
        fs::write(path.join("selected"), b"second\n").unwrap();
        commit(&path);
        let head = crate::oid(&path, "HEAD").unwrap();
        fs::write(path.join(".git/shallow"), format!("{head}\n")).unwrap();
        fs::write(path.join("selected"), b"reviewed\n").unwrap();
        parity(&path, "selected");
        let snapshot = crate::snapshot(&path).unwrap();
        let context = ContentReadContext::capture(&path, &snapshot, Some("selected")).unwrap();
        assert_eq!(
            context.bytes(&["rev-list", "--count", "HEAD"]).unwrap(),
            b"1\n"
        );
        context.validate().unwrap();
    }
    #[test]
    fn linked_worktree_uses_frozen_head_common_attributes_and_excludes() {
        let temp = fixture("sha1");
        let path = temp.path();
        fs::write(path.join("selected"), b"first\n").unwrap();
        commit(path);
        let linked = temp.path().join("linked");
        git(
            path,
            &["worktree", "add", "-b", "linked", linked.to_str().unwrap()],
        )
        .unwrap();
        fs::write(path.join(".git/info/attributes"), "selected text eol=lf\n").unwrap();
        fs::write(path.join(".git/info/exclude"), "ignored-by-info\n").unwrap();
        fs::write(linked.join("selected"), b"first\r\n").unwrap();
        fs::write(linked.join("ignored-by-info"), b"ignored\n").unwrap();
        parity(&linked, "selected");
        assert!(
            !String::from_utf8_lossy(&crate::status_bytes(&linked).unwrap())
                .contains("ignored-by-info")
        );
    }
    #[test]
    fn raw_attributes_macros_bom_includes_encoding_and_ignore_precedence_match_git() {
        let temp = fixture("sha1");
        let path = temp.path();
        fs::create_dir(path.join("sub")).unwrap();
        fs::write(
            path.join(".gitattributes"),
            b"\xef\xbb\xbf[attr]normalized text ident\nsub/* normalized eol=lf\n",
        )
        .unwrap();
        fs::write(
            path.join("sub/.gitattributes"),
            "selected text=set ident=set\n",
        )
        .unwrap();
        let global = path.join(".git/global-attrs");
        fs::write(&global, b"\xef\xbb\xbfsub/* -text\n").unwrap();
        let excludes = path.join(".git/global-ignore");
        fs::write(&excludes, "ignored-global\n").unwrap();
        let included = path.join(".git/included");
        fs::write(
            &included,
            format!(
                "[core]\nattributesFile = {}\nexcludesFile = {}\nautocrlf = true\n",
                global.display(),
                excludes.display()
            ),
        )
        .unwrap();
        git(
            path,
            &["config", "include.path", included.to_str().unwrap()],
        )
        .unwrap();
        fs::write(path.join("sub/selected"), b"before\r\n$Id: value $\r\n").unwrap();
        fs::write(path.join(".gitignore"), "ignored-root\n").unwrap();
        commit(path);
        fs::write(path.join("sub/selected"), b"after\r\n$Id: value $\r\n").unwrap();
        fs::write(path.join("ignored-root"), "ignored\n").unwrap();
        fs::write(path.join("ignored-global"), "ignored\n").unwrap();
        parity(path, "sub/selected");
        fs::write(
            path.join(".git/info/attributes"),
            "sub/selected text eol=lf ident\n",
        )
        .unwrap();
        parity(path, "sub/selected");
        // The tree reader must retain index-fallback BOM bytes verbatim.
        git(path, &["add", "--", ".gitattributes"]).unwrap();
        fs::remove_file(path.join(".gitattributes")).unwrap();
        parity(path, "sub/selected");
        fs::write(
            path.join(".gitattributes"),
            "sub/selected working-tree-encoding=UTF-16LE text\n",
        )
        .unwrap();
        let bytes = "encoded\r\n"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>();
        fs::write(path.join("sub/selected"), bytes).unwrap();
        parity(path, "sub/selected");
    }
    #[test]
    fn ignored_attribute_file_in_tracked_directory_and_attr_tree_are_honored() {
        let temp = fixture("sha1");
        let path = temp.path();
        fs::create_dir(path.join("sub")).unwrap();
        fs::write(path.join("sub/selected"), b"line\n").unwrap();
        fs::write(path.join(".gitignore"), "**/.gitattributes\n").unwrap();
        commit(path);
        fs::write(
            path.join("sub/.gitattributes"),
            b"\xef\xbb\xbfselected text eol=lf\n",
        )
        .unwrap();
        fs::write(path.join("sub/selected"), b"line\r\n").unwrap();
        parity(path, "sub/selected");
        fs::write(path.join(".gitattributes"), "sub/selected text eol=lf\n").unwrap();
        git(path, &["add", "-f", "--", ".gitattributes"]).unwrap();
        git(path, &["commit", "-m", "Frozen attributes"]).unwrap();
        git(path, &["config", "attr.tree", "HEAD"]).unwrap();
        fs::write(path.join(".gitattributes"), "sub/selected -text\n").unwrap();
        parity(path, "sub/selected");
    }
    #[test]
    fn late_clean_process_and_attribute_driver_swaps_never_execute_for_content_reads() {
        for operation in ["view", "diff", "check", "preview", "status"] {
            for driver in ["clean", "process"] {
                let temp = fixture("sha1");
                let path = temp.path();
                fs::write(path.join("selected"), b"before\n").unwrap();
                fs::write(path.join("sibling"), b"sibling\n").unwrap();
                fs::write(
                    path.join(".gitattributes"),
                    "selected filter=late\nsibling filter=late\n",
                )
                .unwrap();
                commit(path);
                fs::write(path.join("selected"), b"after \n").unwrap();
                fs::write(path.join("new-file"), b"new \n").unwrap();
                let before = crate::snapshot(path).unwrap();
                let index = fs::read(path.join(".git/index")).unwrap();
                let source = path.to_path_buf();
                let marker = path.join("filter-ran");
                let marker_for_hook = marker.clone();
                let fired = Rc::new(Cell::new(false));
                let hook_fired = fired.clone();
                let result = process::observe_commands(
                    move |command| {
                        let args = command
                            .get_args()
                            .map(|a| a.to_string_lossy().into_owned())
                            .collect::<Vec<_>>();
                        let private = args.iter().any(|a| a == "--git-dir");
                        let content = args.iter().any(|a| a == "status" || a == "diff");
                        if private && content && !hook_fired.replace(true) {
                            // Install after all probes, at the first actual content
                            // subprocess. Even an unrelated tracked sibling driver
                            // must never be loaded by a whole-worktree status read.
                            let config = source.join(".git/config");
                            let mut raw = fs::read(&config).unwrap();
                            raw.extend_from_slice(
                                format!(
                                    "\n[filter \"late\"]\n{driver} = sh -c 'touch \"{}\"; cat'\n",
                                    marker_for_hook.display()
                                )
                                .as_bytes(),
                            );
                            fs::write(config, raw).unwrap();
                            fs::write(source.join(".gitattributes"), "* filter=late\n").unwrap();
                        }
                    },
                    || -> Result<()> {
                        match operation {
                            "view" => {
                                crate::view(path)?;
                            }
                            "diff" => {
                                crate::diff(path, "selected", false)?;
                            }
                            "check" => {
                                crate::check_changes(path)?;
                            }
                            "preview" => {
                                crate::diff(path, "new-file", false)?;
                            }
                            _ => {
                                crate::status_bytes(path)?;
                            }
                        }
                        Ok(())
                    },
                );
                assert!(fired.get(), "hook missed {operation}/{driver}");
                let code = result.unwrap_err().to_string();
                assert!(
                    matches!(
                        code.as_str(),
                        "unsupported_external_filter" | "stale_read_snapshot"
                    ),
                    "{operation}/{driver}: {code}"
                );
                assert!(!marker.exists(), "filter executed in {operation}/{driver}");
                assert_eq!(index, fs::read(path.join(".git/index")).unwrap());
                assert_eq!(fs::read(path.join("selected")).unwrap(), b"after \n");
                assert_eq!(fs::read(path.join("sibling")).unwrap(), b"sibling\n");
                // Direct file bytes and HEAD remain unchanged; config/attrs are
                // deliberately changed by the adversarial test itself.
                assert_eq!(before.head, crate::oid(path, "HEAD").unwrap());
            }
        }
    }
    #[test]
    fn include_and_external_attribute_mutation_invalidate_frozen_context() {
        let temp = fixture("sha1");
        let path = temp.path();
        fs::write(path.join("selected"), b"line\n").unwrap();
        commit(path);
        let attrs = path.join(".git/globalattrs");
        fs::write(&attrs, "selected text\n").unwrap();
        let included = path.join(".git/included");
        fs::write(
            &included,
            format!("[core]\nattributesFile = {}\n", attrs.display()),
        )
        .unwrap();
        git(
            path,
            &["config", "include.path", included.to_str().unwrap()],
        )
        .unwrap();
        let snapshot = crate::snapshot(path).unwrap();
        let context = ContentReadContext::capture(path, &snapshot, None).unwrap();
        fs::write(attrs, "selected -text\n").unwrap();
        assert_eq!(
            context.validate().unwrap_err().to_string(),
            "stale_read_snapshot"
        );
        fs::write(included, "[filter \"late\"]\nprocess = false\n").unwrap();
        assert_eq!(
            context.validate().unwrap_err().to_string(),
            "unsupported_external_filter"
        );
    }
    #[test]
    fn required_undefined_driver_and_symlink_context_reject_without_writes() {
        let temp = fixture("sha1");
        let path = temp.path();
        fs::write(path.join("selected"), b"line\n").unwrap();
        commit(path);
        let index = fs::read(path.join(".git/index")).unwrap();
        git(path, &["config", "filter.MixedCase.required", "false"]).unwrap();
        crate::view(path).unwrap();
        git(path, &["config", "filter.undefined.required", "true"]).unwrap();
        assert_eq!(
            crate::view(path).unwrap_err().to_string(),
            "unsupported_external_filter"
        );
        git(path, &["config", "--unset", "filter.undefined.required"]).unwrap();
        std::os::unix::fs::symlink("selected", path.join(".gitattributes")).unwrap();
        assert_eq!(
            crate::view(path).unwrap_err().to_string(),
            "unsupported_content_read"
        );
        assert_eq!(index, fs::read(path.join(".git/index")).unwrap());
    }
}

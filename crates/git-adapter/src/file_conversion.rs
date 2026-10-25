//! Git conversion in a private configuration/attribute context. No source
//! repository, system/global configuration, include, or filter driver is loaded
//! by any subprocess which performs Git's built-in content conversion.
use crate::{git, git_bytes, git_command, git_path, process};
use anyhow::{Context, Result, ensure};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const ATTRIBUTE_LIMIT: usize = 1024 * 1024;
const CONTEXT_LIMIT: usize = 4 * 1024 * 1024;
const BLOB_LIMIT: usize = 64 * 1024 * 1024;
const CONFIG_KEYS: [&str; 4] = [
    "core.autocrlf",
    "core.eol",
    "core.safecrlf",
    "core.checkroundtripencoding",
];

#[derive(PartialEq, Eq)]
struct ContextFiles {
    format: String,
    config: BTreeMap<String, Option<String>>,
    system: Option<Vec<u8>>,
    global: Option<Vec<u8>>,
    info: Option<Vec<u8>>,
    worktree: Vec<AttributeSource>,
}
#[derive(PartialEq, Eq)]
struct Blob {
    mode: String,
    oid: String,
    bytes: Vec<u8>,
}
#[derive(PartialEq, Eq)]
struct AttributeSource {
    relative: PathBuf,
    worktree: Option<Vec<u8>>,
    indexed: Option<Blob>,
}
pub(super) struct Conversion {
    context: ContextFiles,
    baseline: Option<Blob>,
}
impl Conversion {
    pub(super) fn capture(path: &Path, file: &str, current: Option<(&str, &str)>) -> Result<Self> {
        let context = ContextFiles::capture(path, file)?;
        let baseline = current
            .map(|(mode, oid)| -> Result<Blob> {
                Ok(Blob {
                    mode: mode.into(),
                    oid: oid.into(),
                    bytes: source_blob(path, oid, BLOB_LIMIT)?,
                })
            })
            .transpose()?;
        Ok(Self { context, baseline })
    }
    pub(super) fn same_context(&self, path: &Path, file: &str) -> Result<bool> {
        Ok(self.context == ContextFiles::capture(path, file)?)
    }
    pub(super) fn convert(&self, file: &str, bytes: &[u8]) -> Result<Vec<u8>> {
        let temp = tempfile::TempDir::new()?;
        let worktree = temp.path().join("worktree");
        fs::create_dir(&worktree)?;
        let root = worktree.as_path();
        // Metadata is a sibling of the private worktree, so a selected logical
        // pathname (including filesystem aliases) cannot overwrite its config.
        let git_dir = root.with_file_name("git-metadata");
        // No templates, source alternates, includes, inherited filter settings,
        // global/system config or system attributes can enter this repository.
        self.run(
            root,
            &[
                "init",
                "--quiet",
                "--template=",
                "--initial-branch=main",
                &format!("--object-format={}", self.context.format),
            ],
            None,
            ATTRIBUTE_LIMIT,
        )?;
        // Git strips a BOM separately in each filesystem attribute source.
        let strip_bom = |bytes: &[u8]| {
            bytes
                .strip_prefix(b"\xef\xbb\xbf")
                .unwrap_or(bytes)
                .to_vec()
        };
        let mut global = strip_bom(self.context.system.as_deref().unwrap_or_default());
        global.push(b'\n');
        global.extend_from_slice(&strip_bom(
            self.context.global.as_deref().unwrap_or_default(),
        ));
        fs::write(git_dir.join("frozen-global-attributes"), global)?;
        let mut info = self.context.info.clone().unwrap_or_default();
        info.extend_from_slice(b"\n* -filter\n");
        fs::create_dir_all(git_dir.join("info"))?;
        fs::write(git_dir.join("info/attributes"), info)?;
        for source in &self.context.worktree {
            if let Some(bytes) = &source.worktree {
                let destination = root.join(&source.relative);
                fs::create_dir_all(
                    destination
                        .parent()
                        .context("unsupported_file_conversion")?,
                )?;
                fs::write(destination, bytes)?;
            }
            // Keep missing worktree attributes absent. Git's index attribute
            // reader differs from its filesystem reader (including BOM rules).
            if let Some(blob) = &source.indexed {
                self.import_blob(
                    root,
                    source
                        .relative
                        .to_str()
                        .context("unsupported_file_conversion")?,
                    blob,
                )?;
            }
        }
        if let Some(blob) = &self.baseline {
            self.import_blob(root, file, blob)?;
        }
        // add reads the private index as well as attributes, preserving Git's
        // index-attribute fallback and existing-CRLF rules. Only immutable bytes
        // are materialized here; source worktree paths are never passed to add.
        let selected = root.join(file);
        fs::create_dir_all(selected.parent().context("unsupported_file_conversion")?)?;
        fs::write(selected, bytes)?;
        self.run(root, &["add", "--", file], None, ATTRIBUTE_LIMIT)?;
        let entries = self.run(
            root,
            &["ls-files", "--stage", "-z", "--", file],
            None,
            ATTRIBUTE_LIMIT,
        )?;
        let tab = entries
            .iter()
            .position(|byte| *byte == b'\t')
            .context("unsupported_file_conversion")?;
        ensure!(
            entries[tab + 1..].strip_suffix(&[0]) == Some(file.as_bytes()),
            "unsupported_file_conversion"
        );
        let oid = std::str::from_utf8(&entries[..tab])?
            .split(' ')
            .nth(1)
            .context("unsupported_file_conversion")?;
        self.run(root, &["cat-file", "blob", oid], None, BLOB_LIMIT)
    }
    fn import_blob(&self, root: &Path, file: &str, blob: &Blob) -> Result<()> {
        let oid = self.run(
            root,
            &["hash-object", "-w", "--no-filters", "--stdin"],
            Some(&blob.bytes),
            ATTRIBUTE_LIMIT,
        )?;
        ensure!(
            std::str::from_utf8(&oid)?.trim() == blob.oid,
            "unsupported_file_conversion"
        );
        let entry = format!("{} {}\t{file}\0", blob.mode, blob.oid);
        self.run(
            root,
            &["update-index", "-z", "--index-info"],
            Some(entry.as_bytes()),
            ATTRIBUTE_LIMIT,
        )?;
        Ok(())
    }
    fn command(&self, root: &Path, args: &[&str]) -> Command {
        let mut command = git_command(root, &[]);
        let git_dir = root.with_file_name("git-metadata");
        let mut attributes_setting = std::ffi::OsString::from("core.attributesFile=");
        attributes_setting.push(git_dir.join("frozen-global-attributes"));
        command
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_ATTR_NOSYSTEM", "1")
            .arg("-c")
            .arg(attributes_setting);
        for (key, value) in &self.context.config {
            command.arg("-c").arg(
                value
                    .as_ref()
                    .map_or_else(|| key.clone(), |value| format!("{key}={value}")),
            );
        }
        command
            .arg("--git-dir")
            .arg(git_dir)
            .arg("--work-tree")
            .arg(root)
            .args(args);
        command
    }
    fn run(
        &self,
        root: &Path,
        args: &[&str],
        input: Option<&[u8]>,
        limit: usize,
    ) -> Result<Vec<u8>> {
        let output = process::run(
            self.command(root, args),
            input,
            Duration::from_secs(30),
            limit,
        )?;
        // Private paths and conversion input are not user-facing diagnostics.
        ensure!(output.status.success(), "unsupported_file_conversion");
        Ok(output.stdout)
    }
}

impl ContextFiles {
    fn capture(path: &Path, file: &str) -> Result<Self> {
        let format = git(path, &["rev-parse", "--show-object-format"])?
            .trim()
            .to_string();
        ensure!(
            matches!(format.as_str(), "sha1" | "sha256"),
            "unsupported_file_conversion"
        );
        let output = process::run(
            git_command(path, &["config", "--includes", "--null", "--list"]),
            None,
            Duration::from_secs(15),
            ATTRIBUTE_LIMIT,
        )?;
        ensure!(output.status.success(), "unsupported_file_conversion");
        // A required driver with no executable definition is still a required
        // content contract. Omitting it must reject rather than stage raw data.
        let required = process::run(
            git_command(
                path,
                &[
                    "config",
                    "--null",
                    "--type=bool",
                    "--get-regexp",
                    r"^filter\..*\.required$",
                ],
            ),
            None,
            Duration::from_secs(15),
            ATTRIBUTE_LIMIT,
        )?;
        ensure!(
            matches!(required.status.code(), Some(0 | 1)),
            "unsupported_file_conversion"
        );
        for row in required
            .stdout
            .split(|byte| *byte == 0)
            .filter(|row| !row.is_empty())
        {
            ensure!(row.ends_with(b"\nfalse"), "unsupported_external_filter");
        }
        let mut config = BTreeMap::new();
        for record in output
            .stdout
            .split(|byte| *byte == 0)
            .filter(|row| !row.is_empty())
        {
            let split = record.iter().position(|byte| *byte == b'\n');
            let key =
                std::str::from_utf8(&record[..split.unwrap_or(record.len())])?.to_ascii_lowercase();
            ensure!(key != "attr.tree", "unsupported_file_conversion");
            if CONFIG_KEYS.contains(&key.as_str()) {
                let value = split
                    .map(|split| std::str::from_utf8(&record[split + 1..]).map(str::to_string))
                    .transpose()?;
                config.insert(key, value);
            }
        }
        let system = read_attribute(&attribute_path(path, "GIT_ATTR_SYSTEM")?)?;
        let global = read_attribute(&attribute_path(path, "GIT_ATTR_GLOBAL")?)?;
        let info = read_attribute(&git_path(
            path,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "info/attributes",
            ],
        )?)?;
        let mut worktree = vec![];
        let mut parent = PathBuf::new();
        let components: Vec<_> = Path::new(file).components().collect();
        ensure!(components.len() <= 128, "unsupported_file_conversion");
        for component in
            std::iter::once(None).chain(components[..components.len() - 1].iter().map(Some))
        {
            if let Some(component) = component {
                parent.push(component);
            }
            let relative = parent.join(".gitattributes");
            let working = read_attribute(&path.join(&relative))?;
            let indexed = if working.is_none() {
                index_attribute(path, &relative)?
            } else {
                None
            };
            worktree.push(AttributeSource {
                relative,
                worktree: working,
                indexed,
            });
        }
        let total = system.as_ref().map_or(0, Vec::len)
            + global.as_ref().map_or(0, Vec::len)
            + info.as_ref().map_or(0, Vec::len)
            + worktree
                .iter()
                .map(|source| {
                    source.worktree.as_ref().map_or(0, Vec::len)
                        + source.indexed.as_ref().map_or(0, |blob| blob.bytes.len())
                })
                .sum::<usize>();
        ensure!(total <= CONTEXT_LIMIT, "unsupported_file_conversion");
        Ok(Self {
            format,
            config,
            system,
            global,
            info,
            worktree,
        })
    }
}
fn attribute_path(path: &Path, variable: &str) -> Result<PathBuf> {
    let output = process::run(
        git_command(path, &["var", variable]),
        None,
        Duration::from_secs(15),
        16 * 1024,
    )?;
    ensure!(output.status.success(), "file_staging_git_upgrade_required");
    let value = crate::path_from_record(std::str::from_utf8(&output.stdout)?)?;
    Ok(if value.is_absolute() {
        value
    } else {
        path.join(value)
    })
}
fn index_attribute(path: &Path, relative: &Path) -> Result<Option<Blob>> {
    let name = relative.to_str().context("unsupported_file_conversion")?;
    let entries = git_bytes(path, &["ls-files", "--stage", "-z", "--", name])?;
    if entries.is_empty() {
        return Ok(None);
    }
    let row = entries
        .strip_suffix(&[0])
        .context("unsupported_file_conversion")?;
    let tab = row
        .iter()
        .position(|byte| *byte == b'\t')
        .context("unsupported_file_conversion")?;
    ensure!(
        &row[tab + 1..] == name.as_bytes(),
        "unsupported_file_conversion"
    );
    let fields: Vec<_> = std::str::from_utf8(&row[..tab])?.split(' ').collect();
    ensure!(
        fields.len() == 3 && fields[2] == "0" && matches!(fields[0], "100644" | "100755"),
        "unsupported_file_conversion"
    );
    Ok(Some(Blob {
        mode: fields[0].into(),
        oid: fields[1].into(),
        bytes: source_blob(path, fields[1], ATTRIBUTE_LIMIT)?,
    }))
}
fn source_blob(path: &Path, oid: &str, limit: usize) -> Result<Vec<u8>> {
    let output = process::run(
        git_command(path, &["cat-file", "blob", oid]),
        None,
        Duration::from_secs(15),
        limit,
    )?;
    ensure!(output.status.success(), "unsupported_file_conversion");
    Ok(output.stdout)
}
fn read_attribute(path: &Path) -> Result<Option<Vec<u8>>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => anyhow::bail!("unsupported_file_conversion"),
    };
    ensure!(
        metadata.is_file() && metadata.len() <= ATTRIBUTE_LIMIT as u64,
        "unsupported_file_conversion"
    );
    let mut opened = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .context("unsupported_file_conversion")?;
    let stamp = |metadata: &fs::Metadata| {
        (
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mode(),
            metadata.mtime(),
            metadata.mtime_nsec(),
            metadata.ctime(),
            metadata.ctime_nsec(),
        )
    };
    ensure!(
        stamp(&opened.metadata()?) == stamp(&metadata),
        "stale_snapshot"
    );
    let mut bytes = Vec::new();
    opened
        .by_ref()
        .take(ATTRIBUTE_LIMIT as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= ATTRIBUTE_LIMIT,
        "unsupported_file_conversion"
    );
    ensure!(
        stamp(&opened.metadata()?) == stamp(&metadata)
            && stamp(&fs::symlink_metadata(path)?) == stamp(&metadata),
        "stale_snapshot"
    );
    Ok(Some(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> tempfile::TempDir {
        let temp = tempfile::TempDir::new().unwrap();
        git(temp.path(), &["init", "-b", "main"]).unwrap();
        git(temp.path(), &["config", "core.autocrlf", "false"]).unwrap();
        temp
    }
    fn equivalence(
        path: &Path,
        file: &str,
        bytes: &[u8],
        baseline: Option<(&str, &str)>,
    ) -> Vec<u8> {
        let conversion = Conversion::capture(path, file, baseline).unwrap();
        let actual = conversion.convert(file, bytes).unwrap();
        // Reference add is restricted to this owned synthetic fixture, with no
        // external definitions or concurrent config changes. Production performs
        // conversion only in its private repository.
        crate::no_external_filters(path).unwrap();
        let selected = path.join(file);
        fs::create_dir_all(selected.parent().unwrap()).unwrap();
        fs::write(selected, bytes).unwrap();
        git(path, &["add", "--", file]).unwrap();
        let expected = git_bytes(path, &["show", &format!(":{file}")]).unwrap();
        assert_eq!(actual, expected);
        actual
    }
    #[test]
    fn raw_attributes_preserve_boolean_and_literal_set_semantics() {
        let temp = fixture();
        let path = temp.path();
        let bytes = b"first\r\n$Id: expanded $\r\n";
        fs::write(path.join(".gitattributes"), "selected text ident\n").unwrap();
        assert_eq!(equivalence(path, "selected", bytes, None), b"first\n$Id$\n");
        fs::write(path.join(".gitattributes"), "selected text=set ident=set\n").unwrap();
        assert_eq!(equivalence(path, "selected", bytes, None), bytes);
    }
    #[test]
    fn global_bom_macros_nested_and_info_attributes_keep_precedence_and_includes() {
        let temp = fixture();
        let path = temp.path();
        fs::create_dir(path.join("sub")).unwrap();
        let global = path.join(".git/global-attributes");
        fs::write(
            &global,
            b"\xef\xbb\xbf[attr]expanded text ident\n*.txt expanded eol=lf\n",
        )
        .unwrap();
        git(
            path,
            &["config", "core.attributesFile", global.to_str().unwrap()],
        )
        .unwrap();
        let included = path.join(".git/included");
        fs::write(&included, "[core]\n\tautocrlf\n\teol = crlf\n").unwrap();
        git(
            path,
            &["config", "include.path", included.to_str().unwrap()],
        )
        .unwrap();
        fs::write(path.join("sub/.gitattributes"), "*.txt -text\n").unwrap();
        fs::write(
            path.join(".git/info/attributes"),
            "sub/file.txt text eol=lf\n",
        )
        .unwrap();
        assert_eq!(
            equivalence(path, "sub/file.txt", b"line\r\n$Id: value $\r\n", None),
            b"line\n$Id$\n"
        );
    }
    #[test]
    fn index_fallback_keeps_its_blob_bom_behavior_and_existing_crlf_context() {
        let temp = fixture();
        let path = temp.path();
        for bom in [false, true] {
            let attrs = if bom {
                b"\xef\xbb\xbfselected text\n".as_slice()
            } else {
                b"selected text\n".as_slice()
            };
            fs::write(path.join(".gitattributes"), attrs).unwrap();
            git(path, &["add", "--", ".gitattributes"]).unwrap();
            fs::remove_file(path.join(".gitattributes")).unwrap();
            let actual = equivalence(path, "selected", b"line\r\n", None);
            assert_eq!(
                actual,
                if bom {
                    b"line\r\n".as_slice()
                } else {
                    b"line\n".as_slice()
                }
            );
        }
        git(
            path,
            &["update-index", "--force-remove", "--", ".gitattributes"],
        )
        .unwrap();
        fs::write(path.join("selected"), b"old\r\n").unwrap();
        git(path, &["add", "--", "selected"]).unwrap();
        let oid = git(path, &["rev-parse", ":selected"]).unwrap();
        git(path, &["config", "core.autocrlf", "true"]).unwrap();
        assert_eq!(
            equivalence(path, "selected", b"new\r\n", Some(("100644", oid.trim()))),
            b"new\r\n"
        );
    }
    #[test]
    fn working_tree_encoding_uses_git_conversion_and_system_global_file_boundaries() {
        let temp = fixture();
        let path = temp.path();
        fs::write(
            path.join(".gitattributes"),
            "selected working-tree-encoding=UTF-16LE text eol=lf\n",
        )
        .unwrap();
        let bytes: Vec<_> = "hello\r\n"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert_eq!(equivalence(path, "selected", &bytes, None), b"hello\n");
        let conversion = Conversion {
            context: ContextFiles {
                format: "sha1".into(),
                config: BTreeMap::new(),
                system: Some(b"\xef\xbb\xbfselected -text".to_vec()),
                global: Some(b"\xef\xbb\xbfselected text eol=lf\n".to_vec()),
                info: None,
                worktree: vec![],
            },
            baseline: None,
        };
        assert_eq!(
            conversion.convert("selected", b"line\r\n").unwrap(),
            b"line\n"
        );
    }
    #[test]
    fn tree_attribute_source_and_symlink_attributes_reject_without_conversion() {
        let temp = fixture();
        let path = temp.path();
        git(path, &["config", "attr.tree", "HEAD"]).unwrap();
        assert!(
            matches!(Conversion::capture(path, "selected", None), Err(error) if error.to_string() == "unsupported_file_conversion")
        );
        git(path, &["config", "--unset", "attr.tree"]).unwrap();
        std::os::unix::fs::symlink("outside", path.join(".gitattributes")).unwrap();
        assert!(
            matches!(Conversion::capture(path, "selected", None), Err(error) if error.to_string() == "unsupported_file_conversion")
        );
    }
}

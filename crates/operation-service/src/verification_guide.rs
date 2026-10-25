//! Explicit, bounded reads of repository-local verification notes.
//!
//! Notes are data: no Markdown rendering, includes, command execution, or network
//! access takes place here. Extensions are ASCII case-insensitive. Every path
//! component, including the supplied absolute repository root, is opened through
//! a directory descriptor with `O_NOFOLLOW`; changing a pathname to a symlink
//! cannot redirect an already opened descriptor outside the selected root.

use anyhow::{Result, anyhow, ensure};
use std::{
    ffi::{CStr, CString},
    fs::File,
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::ffi::OsStrExt,
    },
    path::{Component, Path},
};

const MAX_GUIDE_BYTES: usize = 65_536;

#[derive(Debug)]
pub(super) struct GuideContents {
    pub path: String,
    pub sha256: String,
    pub content: String,
}

/// Validate references without opening or probing any path. Saving a reference
/// must not silently read the guide or turn it into an execution instruction.
pub(super) fn validate_guide_path(reference: &str) -> Result<()> {
    ensure!(
        !reference.is_empty()
            && !reference.starts_with('/')
            && !reference.contains('\\')
            && !reference.chars().any(char::is_control)
            && reference
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."),
        "guide_invalid_path"
    );
    let extension = reference.rsplit_once('.').map(|(_, extension)| extension);
    ensure!(
        extension.is_some_and(|extension| ["md", "txt", "mdc", "rst"]
            .iter()
            .any(|allowed| extension.eq_ignore_ascii_case(allowed))),
        "guide_unsupported_format"
    );
    Ok(())
}

/// Read an explicitly selected guide from the actual repository/worktree root.
/// No errors include file content, underlying OS messages, or resolved paths.
pub(super) fn read_guide_file(root: &Path, reference: &str) -> Result<GuideContents> {
    validate_guide_path(reference)?;
    let mut directory = open_root(root)?;
    let mut components = reference.split('/').peekable();
    while let Some(component) = components.next() {
        let name = CString::new(component).map_err(|_| anyhow!("guide_invalid_path"))?;
        let is_directory = components.peek().is_some();
        let opened = open_at(directory.as_raw_fd(), &name, is_directory)?;
        if is_directory {
            directory = opened;
            continue;
        }

        let metadata = opened.metadata().map_err(|_| anyhow!("guide_unreadable"))?;
        ensure!(metadata.is_file(), "guide_unsafe_path");
        ensure!(metadata.len() <= MAX_GUIDE_BYTES as u64, "guide_too_large");
        // Recheck the actual read length: an initially small regular file can
        // grow after fstat. O_NONBLOCK prevents FIFO opens from hanging before
        // the regular-file check; no bytes are read from special files.
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        opened
            .take((MAX_GUIDE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| anyhow!("guide_unreadable"))?;
        ensure!(bytes.len() <= MAX_GUIDE_BYTES, "guide_too_large");
        let sha256 = workbench_domain::hash(&bytes);
        let content = String::from_utf8(bytes).map_err(|_| anyhow!("guide_invalid_utf8"))?;
        return Ok(GuideContents {
            path: reference.to_owned(),
            sha256,
            content,
        });
    }
    Err(anyhow!("guide_invalid_path"))
}

fn open_root(root: &Path) -> Result<File> {
    ensure!(root.is_absolute(), "guide_unsafe_path");
    let mut components = root.components();
    ensure!(
        components.next() == Some(Component::RootDir),
        "guide_unsafe_path"
    );
    // Start at the filesystem root rather than opening the whole repository
    // path, which would follow symlinks in one of its parent components.
    let descriptor = unsafe {
        libc::open(
            c"/".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(descriptor >= 0, "guide_unsafe_path");
    // SAFETY: the successful open returned a new descriptor owned by this File.
    let mut directory = unsafe { File::from_raw_fd(descriptor) };
    for component in components {
        let Component::Normal(name) = component else {
            return Err(anyhow!("guide_unsafe_path"));
        };
        let name = CString::new(name.as_bytes()).map_err(|_| anyhow!("guide_unsafe_path"))?;
        directory = open_at(directory.as_raw_fd(), &name, true)?;
    }
    Ok(directory)
}

fn open_at(directory: RawFd, name: &CStr, is_directory: bool) -> Result<File> {
    let mut flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
    if is_directory {
        flags |= libc::O_DIRECTORY;
    }
    // SAFETY: directory is held open by the caller and name is NUL-terminated.
    // No creation flag is set, so a mode argument is unnecessary.
    let descriptor = unsafe { libc::openat(directory, name.as_ptr(), flags) };
    ensure!(descriptor >= 0, "guide_unsafe_path");
    // SAFETY: a successful openat returned a new descriptor owned by this File.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::{ffi::OsStrExt, fs::symlink},
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        thread,
    };
    use tempfile::TempDir;

    fn root() -> (TempDir, std::path::PathBuf) {
        let temporary = tempfile::tempdir().unwrap();
        let canonical = temporary.path().canonicalize().unwrap();
        (temporary, canonical)
    }

    fn error(root: &Path, reference: &str) -> String {
        read_guide_file(root, reference).unwrap_err().to_string()
    }

    #[test]
    fn reads_unicode_and_hashes_exact_raw_bytes_without_normalizing() {
        let (_temporary, root) = root();
        let reference = "안내 문서/검증.MD";
        let content = "# 검증 🌊\r\n\u{feff}git status\n";
        fs::create_dir(root.join("안내 문서")).unwrap();
        fs::write(root.join(reference), content).unwrap();
        let actual = read_guide_file(&root, reference).unwrap();
        assert_eq!(actual.path, reference);
        assert_eq!(actual.content, content);
        assert_eq!(actual.sha256, workbench_domain::hash(content.as_bytes()));
    }

    #[test]
    fn validates_supported_formats_without_touching_the_filesystem() {
        for reference in [
            "README.md",
            "notes.TXT",
            ".cursor/rules/verify.MdC",
            "docs/guide.rst",
        ] {
            validate_guide_path(reference).unwrap();
        }
        for reference in ["guide.sh", "guide", "guide.md.exe", "guide.html"] {
            assert_eq!(
                validate_guide_path(reference).unwrap_err().to_string(),
                "guide_unsupported_format"
            );
        }
    }

    #[test]
    fn rejects_absolute_traversal_empty_and_control_paths() {
        let (_temporary, root) = root();
        for reference in [
            "",
            "/outside.md",
            "../outside.md",
            "docs/../../outside.md",
            "./guide.md",
            "docs/./guide.md",
            "docs//guide.md",
            "docs/",
            "guide.md/",
            "docs\\guide.md",
            "C:\\guide.md",
            "guide\0.md",
            "guide\n.md",
            "guide\r.md",
            "guide\t.md",
            "guide\u{7f}.md",
            "guide\u{85}.md",
        ] {
            assert_eq!(
                error(&root, reference),
                "guide_invalid_path",
                "{reference:?}"
            );
        }
    }

    #[test]
    fn accepts_exact_size_boundary_and_rejects_larger_files() {
        let (_temporary, root) = root();
        let content = "a".repeat(MAX_GUIDE_BYTES);
        fs::write(root.join("guide.md"), &content).unwrap();
        assert_eq!(read_guide_file(&root, "guide.md").unwrap().content, content);
        fs::write(root.join("guide.md"), "a".repeat(MAX_GUIDE_BYTES + 1)).unwrap();
        assert_eq!(error(&root, "guide.md"), "guide_too_large");
    }

    #[test]
    fn rejects_invalid_utf8_without_echoing_the_bytes() {
        let (_temporary, root) = root();
        fs::write(root.join("guide.txt"), [0xf0, 0x28, 0x8c, 0xbc]).unwrap();
        assert_eq!(error(&root, "guide.txt"), "guide_invalid_utf8");
    }

    #[test]
    fn accepts_empty_regular_file() {
        let (_temporary, root) = root();
        fs::write(root.join("guide.md"), []).unwrap();
        let actual = read_guide_file(&root, "guide.md").unwrap();
        assert_eq!(actual.content, "");
        assert_eq!(
            actual.sha256,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn rejects_final_symlink_even_when_its_target_is_inside_repository() {
        let (_temporary, root) = root();
        fs::write(root.join("real.md"), "internal").unwrap();
        symlink("real.md", root.join("guide.md")).unwrap();
        assert_eq!(error(&root, "guide.md"), "guide_unsafe_path");
    }

    #[test]
    fn rejects_final_external_symlink_and_intermediate_symlink() {
        let (_temporary, root) = root();
        let (_outside, outside) = self::root();
        fs::write(outside.join("external.md"), "private outside contents").unwrap();
        symlink(outside.join("external.md"), root.join("guide.md")).unwrap();
        symlink(&outside, root.join("docs")).unwrap();
        assert_eq!(error(&root, "guide.md"), "guide_unsafe_path");
        assert_eq!(error(&root, "docs/external.md"), "guide_unsafe_path");
    }

    #[test]
    fn rejects_symlink_in_root_and_in_root_ancestor() {
        let (_temporary, root) = root();
        fs::create_dir_all(root.join("real/repo")).unwrap();
        fs::write(root.join("real/repo/guide.md"), "internal").unwrap();
        symlink(root.join("real/repo"), root.join("repo-link")).unwrap();
        symlink(root.join("real"), root.join("ancestor-link")).unwrap();
        assert_eq!(
            error(&root.join("repo-link"), "guide.md"),
            "guide_unsafe_path"
        );
        assert_eq!(
            error(&root.join("ancestor-link/repo"), "guide.md"),
            "guide_unsafe_path"
        );
        assert_eq!(
            error(Path::new("relative-root"), "guide.md"),
            "guide_unsafe_path"
        );
    }

    #[test]
    fn rejects_directory_fifo_and_missing_files_without_blocking() {
        let (_temporary, root) = root();
        fs::create_dir(root.join("directory.md")).unwrap();
        assert_eq!(error(&root, "directory.md"), "guide_unsafe_path");
        let fifo = CString::new(root.join("pipe.md").as_os_str().as_bytes()).unwrap();
        // SAFETY: the path is an owned temporary directory and valid C string.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert_eq!(error(&root, "pipe.md"), "guide_unsafe_path");
        assert_eq!(error(&root, "missing.md"), "guide_unsafe_path");
    }

    #[test]
    fn does_not_execute_commands_fetch_links_or_expand_includes() {
        let (_temporary, root) = root();
        let content = "```sh\ntouch SHOULD_NOT_EXIST\n```\n!include ../secret.md\nhttps://127.0.0.1:1/private\n$(touch ALSO_NOT_CREATED)\n";
        fs::write(root.join("guide.mdc"), content).unwrap();
        assert_eq!(
            read_guide_file(&root, "guide.mdc").unwrap().content,
            content
        );
        assert!(!root.join("SHOULD_NOT_EXIST").exists());
        assert!(!root.join("ALSO_NOT_CREATED").exists());
    }

    #[test]
    fn concurrent_intermediate_symlink_swap_never_reads_external_target() {
        let (_temporary, root) = root();
        let (_outside, outside) = self::root();
        fs::create_dir(root.join("docs")).unwrap();
        fs::write(root.join("docs/guide.md"), "inside").unwrap();
        fs::write(outside.join("guide.md"), "outside secret").unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let writer_stop = Arc::clone(&stop);
        let writer_root = root.clone();
        let writer = thread::spawn(move || {
            while !writer_stop.load(Ordering::Relaxed) {
                fs::rename(writer_root.join("docs"), writer_root.join("parked")).unwrap();
                symlink(&outside, writer_root.join("docs")).unwrap();
                fs::remove_file(writer_root.join("docs")).unwrap();
                fs::rename(writer_root.join("parked"), writer_root.join("docs")).unwrap();
            }
        });
        let mut external_read = false;
        for _ in 0..1_000 {
            if let Ok(actual) = read_guide_file(&root, "docs/guide.md") {
                external_read |= actual.content != "inside";
            }
        }
        stop.store(true, Ordering::Relaxed);
        writer.join().unwrap();
        assert!(!external_read);
    }
}

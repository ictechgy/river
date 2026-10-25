use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
};
use tempfile::TempDir;
use workbench_domain::digest;
use workbench_git as git;

struct Fixture {
    temp: TempDir,
}
impl Fixture {
    fn new(unborn: bool) -> Self {
        let fixture = Self {
            temp: TempDir::new().unwrap(),
        };
        let path = fixture.path();
        git::git(path, &["init", "-b", "main"]).unwrap();
        git::git(path, &["config", "user.name", "Synthetic staging test"]).unwrap();
        git::git(path, &["config", "user.email", "staging@example.invalid"]).unwrap();
        if !unborn {
            for name in ["selected", "sibling", "deleted"] {
                fs::write(path.join(name), format!("{name} baseline\n")).unwrap();
            }
            git::git(path, &["add", "--all"]).unwrap();
            git::git(path, &["commit", "-m", "baseline"]).unwrap();
        }
        fixture
    }
    fn path(&self) -> &Path {
        self.temp.path()
    }
    fn stage(&self, file: &str, staged: bool) {
        let expected = digest(&git::snapshot(self.path()).unwrap()).unwrap();
        git::stage_file(self.path(), file, staged, &expected).unwrap();
    }
    fn index(&self, file: &str) -> Vec<u8> {
        git::git_bytes(self.path(), &["show", &format!(":{file}")]).unwrap()
    }
    fn absent(&self, file: &str) {
        assert!(
            git::git_bytes(self.path(), &["ls-files", "--stage", "-z", "--", file])
                .unwrap()
                .is_empty()
        );
    }
}

#[test]
fn entire_selected_file_stages_and_unstages_without_touching_partial_siblings_or_worktree() {
    let f = Fixture::new(false);
    let head = git::oid(f.path(), "HEAD").unwrap();
    fs::write(f.path().join("sibling"), "staged sibling\n").unwrap();
    git::git(f.path(), &["add", "--", "sibling"]).unwrap();
    fs::write(f.path().join("sibling"), "unstaged sibling\n").unwrap();
    git::git(
        f.path(),
        &["update-index", "--assume-unchanged", "--", "sibling"],
    )
    .unwrap();
    let sibling_flags =
        git::git_bytes(f.path(), &["ls-files", "--debug", "--", "sibling"]).unwrap();
    fs::write(f.path().join("selected"), "selected first staged\n").unwrap();
    git::git(f.path(), &["add", "--", "selected"]).unwrap();
    fs::write(f.path().join("selected"), "selected entire worktree\n").unwrap();
    f.stage("selected", false);
    assert_eq!(f.index("selected"), b"selected entire worktree\n");
    f.stage("selected", true);
    assert_eq!(f.index("selected"), b"selected baseline\n");
    assert_eq!(f.index("sibling"), b"staged sibling\n");
    assert_eq!(
        git::git_bytes(f.path(), &["ls-files", "--debug", "--", "sibling"]).unwrap(),
        sibling_flags
    );
    assert_eq!(
        fs::read(f.path().join("selected")).unwrap(),
        b"selected entire worktree\n"
    );
    assert_eq!(
        fs::read(f.path().join("sibling")).unwrap(),
        b"unstaged sibling\n"
    );
    assert_eq!(git::oid(f.path(), "HEAD").unwrap(), head);
}

#[test]
fn new_binary_literal_paths_round_trip_with_unborn_head_and_existing_head() {
    let names = [
        "new.bin",
        "-option",
        ":(glob)*",
        "[literal]?*",
        "space \"한글\"\tline\nend",
    ];
    for unborn in [false, true] {
        let f = Fixture::new(unborn);
        for name in names {
            fs::write(f.path().join(name), [0, 255, 1, 13, 10]).unwrap();
        }
        for name in names {
            f.stage(name, false);
            assert_eq!(f.index(name), [0, 255, 1, 13, 10]);
            f.stage(name, true);
            f.absent(name);
            assert_eq!(fs::read(f.path().join(name)).unwrap(), [0, 255, 1, 13, 10]);
        }
        if unborn {
            assert!(git::snapshot(f.path()).unwrap().head.is_empty());
        }
    }
}

#[test]
fn deleted_files_and_recreated_staged_deletions_preserve_worktree_and_other_entries() {
    let f = Fixture::new(false);
    fs::remove_file(f.path().join("deleted")).unwrap();
    f.stage("deleted", false);
    f.absent("deleted");
    f.stage("deleted", true);
    assert_eq!(f.index("deleted"), b"deleted baseline\n");
    assert!(!f.path().join("deleted").exists());
    f.stage("deleted", false);
    fs::write(f.path().join("deleted"), "recreated reviewed\n").unwrap();
    f.stage("deleted", false);
    assert_eq!(f.index("deleted"), b"recreated reviewed\n");
    assert_eq!(f.index("sibling"), b"sibling baseline\n");
}

#[test]
fn symlinks_are_literal_targets_and_executable_modes_round_trip() {
    let f = Fixture::new(false);
    symlink("../outside-do-not-follow", f.path().join("new-link")).unwrap();
    f.stage("new-link", false);
    assert_eq!(f.index("new-link"), b"../outside-do-not-follow");
    assert!(
        git::git(f.path(), &["ls-files", "--stage", "--", "new-link"])
            .unwrap()
            .starts_with("120000 ")
    );
    f.stage("new-link", true);
    assert!(
        fs::symlink_metadata(f.path().join("new-link"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    fs::write(f.path().join("script"), "#!/bin/sh\ntrue\n").unwrap();
    fs::set_permissions(f.path().join("script"), fs::Permissions::from_mode(0o755)).unwrap();
    f.stage("script", false);
    assert!(
        git::git(f.path(), &["ls-files", "--stage", "--", "script"])
            .unwrap()
            .starts_with("100755 ")
    );
    f.stage("script", true);
    f.absent("script");
}

#[test]
fn built_in_normalization_matches_add_and_external_filters_remain_rejected() {
    let f = Fixture::new(false);
    fs::write(f.path().join(".gitattributes"), "*.txt text eol=lf\n").unwrap();
    fs::write(f.path().join("normalize.txt"), b"one\r\ntwo\r\n").unwrap();
    f.stage("normalize.txt", false);
    assert_eq!(f.index("normalize.txt"), b"one\ntwo\n");
    assert_eq!(
        fs::read(f.path().join("normalize.txt")).unwrap(),
        b"one\r\ntwo\r\n"
    );
    git::git(
        f.path(),
        &["config", "filter.untrusted.clean", "touch must-not-run"],
    )
    .unwrap();
    let index_before = fs::read(f.path().join(".git/index")).unwrap();
    let error = git::stage_file(f.path(), "normalize.txt", true, "unused").unwrap_err();
    assert_eq!(error.to_string(), "unsupported_external_filter");
    assert_eq!(fs::read(f.path().join(".git/index")).unwrap(), index_before);
    assert!(!f.path().join("must-not-run").exists());
}

#[test]
fn renamed_paths_are_independent_and_directory_clean_unsafe_stale_requests_never_write() {
    let f = Fixture::new(false);
    fs::rename(f.path().join("selected"), f.path().join("renamed")).unwrap();
    f.stage("renamed", false);
    assert_eq!(f.index("selected"), b"selected baseline\n");
    f.stage("selected", false);
    f.absent("selected");
    f.stage("renamed", true);
    f.absent("renamed");
    f.stage("selected", true);
    assert_eq!(f.index("selected"), b"selected baseline\n");
    fs::create_dir(f.path().join("directory")).unwrap();
    fs::write(f.path().join("directory/new"), "reviewed\n").unwrap();
    let snapshot = git::snapshot(f.path()).unwrap();
    let expected = digest(&snapshot).unwrap();
    let original = fs::read(f.path().join(".git/index")).unwrap();
    for name in [
        "directory",
        "sibling",
        "../escape",
        "/absolute",
        ":(glob)**",
        "bad\0path",
    ] {
        assert!(
            git::stage_file(f.path(), name, false, &expected).is_err(),
            "{name:?}"
        );
        assert_eq!(fs::read(f.path().join(".git/index")).unwrap(), original);
    }
    fs::write(f.path().join("directory/new"), "unreviewed\n").unwrap();
    assert_eq!(
        git::stage_file(f.path(), "directory/new", false, &expected)
            .unwrap_err()
            .to_string(),
        "stale_snapshot"
    );
    assert_eq!(fs::read(f.path().join(".git/index")).unwrap(), original);
    fs::write(f.path().join(".git/index.lock"), "other writer").unwrap();
    assert_eq!(
        git::stage_file(f.path(), "directory/new", false, &expected)
            .unwrap_err()
            .to_string(),
        "repository_busy"
    );
    assert_eq!(
        fs::read(f.path().join(".git/index.lock")).unwrap(),
        b"other writer"
    );
}

#[test]
fn new_regular_text_and_binary_previews_are_bounded_read_only_and_preserve_literal_names() {
    let f = Fixture::new(false);
    for (name, bytes) in [
        (
            "new \"한글\"\t[entry]\nfile.txt",
            b"review new text\nsecond line\n".as_slice(),
        ),
        ("new-empty", b"".as_slice()),
        ("new-binary", b"binary\0bytes\xff".as_slice()),
    ] {
        fs::write(f.path().join(name), bytes).unwrap();
        let before = git::snapshot(f.path()).unwrap();
        let diff = git::diff(f.path(), name, false).unwrap();
        assert!(!diff.can_stage_hunks);
        assert!(diff.text.contains("new file mode"), "{}", diff.text);
        assert!(!diff.text.contains("/var/folders/") && !diff.text.contains("/tmp/"));
        if name.ends_with("file.txt") {
            assert!(diff.text.contains("+review new text\n+second line\n"));
        }
        if name == "new-binary" {
            assert!(diff.text.contains("Binary files /dev/null"));
        }
        assert_eq!(git::snapshot(f.path()).unwrap(), before);
        assert_eq!(fs::read(f.path().join(name)).unwrap(), bytes);
    }
    let outside = TempDir::new().unwrap();
    fs::write(
        outside.path().join("private-target"),
        "must not preview external bytes\n",
    )
    .unwrap();
    symlink(
        outside.path().join("private-target"),
        f.path().join("new-link"),
    )
    .unwrap();
    let diff = git::diff(f.path(), "new-link", false).unwrap();
    assert!(diff.text.is_empty());
    assert!(diff.encoding_warning.is_some());
    assert!(!diff.can_stage_hunks);
}

#[test]
fn sha256_unborn_index_and_split_indexes_preserve_selected_scope() {
    let temp = TempDir::new().unwrap();
    git::git(
        temp.path(),
        &["init", "-b", "main", "--object-format=sha256"],
    )
    .unwrap();
    fs::write(temp.path().join("first"), "sha256 addition\n").unwrap();
    for staged in [false, true] {
        let expected = digest(&git::snapshot(temp.path()).unwrap()).unwrap();
        git::stage_file(temp.path(), "first", staged, &expected).unwrap();
    }
    assert!(
        git::git_bytes(temp.path(), &["ls-files", "--stage", "-z"])
            .unwrap()
            .is_empty()
    );
    assert!(git::snapshot(temp.path()).unwrap().head.is_empty());

    let f = Fixture::new(false);
    git::git(f.path(), &["update-index", "--split-index"]).unwrap();
    git::git(
        f.path(),
        &["update-index", "--skip-worktree", "--", "sibling"],
    )
    .unwrap();
    // Converting split storage to a full index clears Git's transient
    // CE_UPDATE_IN_BASE bit. Its persistent skip-worktree flag must survive.
    let before = git::git_bytes(f.path(), &["ls-files", "-v", "--stage", "--", "sibling"]).unwrap();
    fs::write(f.path().join("selected"), "split index edit\n").unwrap();
    f.stage("selected", false);
    assert_eq!(f.index("selected"), b"split index edit\n");
    assert_eq!(
        git::git_bytes(f.path(), &["ls-files", "-v", "--stage", "--", "sibling"]).unwrap(),
        before
    );
    f.stage("selected", true);
    assert_eq!(f.index("selected"), b"selected baseline\n");
    assert_eq!(
        git::git_bytes(f.path(), &["ls-files", "-v", "--stage", "--", "sibling"]).unwrap(),
        before
    );
}

#[test]
fn staging_bounds_capture_and_disables_hooks_and_fsmonitor() {
    let f = Fixture::new(false);
    let hook = f.path().join(".git/hooks/post-index-change");
    fs::write(&hook, "#!/bin/sh\ntouch hook-must-not-run\n").unwrap();
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    let monitor = f.path().join(".git/fsmonitor-test");
    fs::write(&monitor, "#!/bin/sh\ntouch fsmonitor-must-not-run\n").unwrap();
    fs::set_permissions(&monitor, fs::Permissions::from_mode(0o755)).unwrap();
    git::git(
        f.path(),
        &["config", "core.fsmonitor", monitor.to_str().unwrap()],
    )
    .unwrap();
    fs::write(f.path().join("selected"), "safe stage\n").unwrap();
    f.stage("selected", false);
    assert!(!f.path().join("hook-must-not-run").exists());
    assert!(!f.path().join("fsmonitor-must-not-run").exists());
    let large = fs::File::create(f.path().join("oversized")).unwrap();
    large.set_len(32 * 1024 * 1024 + 1).unwrap();
    let expected = digest(&git::snapshot(f.path()).unwrap()).unwrap();
    let original = fs::read(f.path().join(".git/index")).unwrap();
    assert_eq!(
        git::stage_file(f.path(), "oversized", false, &expected)
            .unwrap_err()
            .to_string(),
        "file_stage_too_large"
    );
    assert_eq!(fs::read(f.path().join(".git/index")).unwrap(), original);
    fs::write(f.path().join(".git/MERGE_HEAD"), "integration in progress").unwrap();
    assert_eq!(
        git::stage_file(f.path(), "oversized", false, &expected)
            .unwrap_err()
            .to_string(),
        "integration_in_progress"
    );
    assert_eq!(fs::read(f.path().join(".git/index")).unwrap(), original);
}

#[test]
fn regular_file_modes_match_git_add_when_filemode_is_disabled_or_only_group_executable() {
    for (filemode, mode) in [("false", 0o755), ("true", 0o645)] {
        let f = Fixture::new(false);
        git::git(f.path(), &["config", "core.filemode", filemode]).unwrap();
        fs::write(f.path().join("new-mode"), "mode comparison\n").unwrap();
        fs::set_permissions(f.path().join("new-mode"), fs::Permissions::from_mode(mode)).unwrap();
        f.stage("new-mode", false);
        let ours =
            git::git_bytes(f.path(), &["ls-files", "--stage", "-z", "--", "new-mode"]).unwrap();
        git::git(
            f.path(),
            &["update-index", "--force-remove", "--", "new-mode"],
        )
        .unwrap();
        git::git(f.path(), &["add", "--", "new-mode"]).unwrap();
        assert_eq!(
            ours,
            git::git_bytes(f.path(), &["ls-files", "--stage", "-z", "--", "new-mode"]).unwrap()
        );
    }
}

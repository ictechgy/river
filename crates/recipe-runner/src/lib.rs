use anyhow::{Context, Result, bail, ensure};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    os::fd::AsRawFd,
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use workbench_domain::{IosInputs, Recipe, Snapshot, digest, safe_relative};

fn read_regular_file(
    path: &Path,
    maximum: Option<u64>,
    mut consume: impl FnMut(&[u8]),
) -> Result<()> {
    workbench_git::check_deadline()?;
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let before = file.metadata()?;
    ensure!(before.is_file(), "unsafe_recipe_file");
    ensure!(
        maximum.is_none_or(|max| before.len() <= max),
        "recipe_file_too_large"
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
    ensure!(
        stamp(&before) == stamp(&fs::symlink_metadata(path)?),
        "stale_read_snapshot"
    );
    let mut buffer = [0; 64 * 1024];
    let mut size = 0u64;
    loop {
        workbench_git::check_deadline()?;
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        ensure!(size <= before.len(), "stale_read_snapshot");
        consume(&buffer[..n]);
        workbench_git::check_deadline()?;
    }
    ensure!(
        size == before.len()
            && stamp(&before) == stamp(&file.metadata()?)
            && stamp(&before) == stamp(&fs::symlink_metadata(path)?),
        "stale_read_snapshot"
    );
    Ok(())
}

fn file_hash(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    read_regular_file(path, None, |bytes| hasher.update(bytes))?;
    Ok(format!("{:x}", hasher.finalize()))
}

pub fn contained_file(root: &Path, relative: &str) -> Result<PathBuf> {
    workbench_git::check_deadline()?;
    safe_relative(relative)?;
    let root = fs::canonicalize(root)?;
    let mut path = root.clone();
    for part in Path::new(relative).components() {
        workbench_git::check_deadline()?;
        path.push(part);
        ensure!(
            !fs::symlink_metadata(&path)
                .context("missing_recipe_file")?
                .file_type()
                .is_symlink(),
            "recipe_symlink"
        );
    }
    ensure!(
        fs::canonicalize(&path)?.starts_with(&root) && path.is_file(),
        "unsafe_recipe_file"
    );
    Ok(path)
}
pub fn trust_hash(recipe: &Recipe, root: &Path) -> Result<String> {
    workbench_git::with_deadline(workbench_git::READ_PHASE_TIMEOUT, || {
        trust_hash_inner(recipe, root)
    })
}
pub fn script_hash(recipe: &Recipe, root: &Path) -> Result<String> {
    workbench_git::with_deadline(workbench_git::READ_PHASE_TIMEOUT, || {
        file_hash(&contained_file(root, &recipe.script)?)
    })
}
fn trust_hash_inner(recipe: &Recipe, root: &Path) -> Result<String> {
    let script = contained_file(root, &recipe.script)?;
    for file in &recipe.writes {
        contained_file(root, file)?;
    }
    let mut contract = recipe.clone();
    contract.trusted_hash = None;
    ensure!(
        fs::metadata(&recipe.executable)?.permissions().mode() & 0o111 != 0,
        "executable_unavailable"
    );
    // Registered executables may be symlinks (for example /usr/bin/python3).
    // Resolve once, then read a regular file without following a replacement.
    let executable = fs::canonicalize(&recipe.executable)?;
    digest(&(contract, file_hash(&script)?, file_hash(&executable)?))
}
pub fn trusted(recipe: &Recipe, root: &Path) -> Result<String> {
    let actual = trust_hash(recipe, root)?;
    ensure!(
        recipe.trusted_hash.as_ref() == Some(&actual),
        "untrusted_recipe"
    );
    Ok(actual)
}
pub fn inspect(root: &Path) -> Result<IosInputs> {
    workbench_git::with_deadline(workbench_git::READ_PHASE_TIMEOUT, || inspect_inner(root))
}
fn inspect_inner(root: &Path) -> Result<IosInputs> {
    let path = contained_file(root, "Config/Version.xcconfig")?;
    let mut bytes = Vec::new();
    read_regular_file(&path, Some(64 * 1024), |chunk| {
        bytes.extend_from_slice(chunk)
    })?;
    let text = String::from_utf8(bytes).context("unsupported_xcconfig")?;
    let mut values = std::collections::BTreeMap::new();
    for line in text.lines() {
        workbench_git::check_deadline()?;
        let line = line.trim();
        if line.is_empty() || line.starts_with("//") {
            continue;
        }
        let (key, value) = line.split_once('=').context("unsupported_xcconfig")?;
        ensure!(
            ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"].contains(&key.trim()),
            "unsupported_xcconfig"
        );
        ensure!(
            values.insert(key.trim(), value.trim()).is_none(),
            "ambiguous_xcconfig"
        );
    }
    let inputs = IosInputs {
        marketing_version: values
            .get("MARKETING_VERSION")
            .context("missing_version_key")?
            .to_string(),
        local_build: values
            .get("CURRENT_PROJECT_VERSION")
            .context("missing_build_key")?
            .to_string(),
    };
    inputs.validate()?;
    Ok(inputs)
}
pub fn postcondition(
    recipe: &Recipe,
    root: &Path,
    expected: &IosInputs,
    baseline: &Snapshot,
) -> Result<Snapshot> {
    workbench_git::with_deadline(workbench_git::READ_PHASE_TIMEOUT, || {
        postcondition_inner(recipe, root, expected, baseline)
    })
}
fn postcondition_inner(
    recipe: &Recipe,
    root: &Path,
    expected: &IosInputs,
    baseline: &Snapshot,
) -> Result<Snapshot> {
    trusted(recipe, root)?;
    let after = workbench_git::preparation_snapshot(root)?;
    ensure!(
        baseline.head == after.head
            && baseline.branch == after.branch
            && baseline.index_hash == after.index_hash,
        "unexpected_git_change"
    );
    for path in baseline.files.keys().chain(after.files.keys()) {
        workbench_git::check_deadline()?;
        ensure!(
            baseline.files.get(path) == after.files.get(path) || recipe.writes.contains(path),
            "unexpected_changes"
        );
    }
    ensure!(&inspect(root)? == expected, "postcondition_failed");
    Ok(after)
}
pub fn run(
    recipe: &Recipe,
    root: &Path,
    inputs: &IosInputs,
    cancelled: Arc<AtomicBool>,
) -> Result<()> {
    workbench_git::with_read_cancellation(cancelled.clone(), || {
        run_controlled(recipe, root, inputs, cancelled)
    })
}
fn run_controlled(
    recipe: &Recipe,
    root: &Path,
    inputs: &IosInputs,
    cancelled: Arc<AtomicBool>,
) -> Result<()> {
    inputs.validate()?;
    trusted(recipe, root)?;
    // The first adapter has no secret fields. Stdout/stderr are deliberately discarded,
    // so untrusted script output cannot leak into the journal or error response.
    let mut cmd = Command::new(&recipe.executable);
    cmd.arg("-I")
        .arg(contained_file(root, &recipe.script)?)
        .arg("--input-json-stdin")
        .current_dir(root)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    workbench_git::check_deadline()?;
    let mut child = cmd.spawn().context("recipe_spawn_failed")?;
    let stdout = child.stdout.take().context("recipe_stdout")?;
    let stderr = child.stderr.take().context("recipe_stderr")?;
    // Drain the pipes with bounded retained output (zero), including noisy scripts.
    let stdout_fd = stdout.as_raw_fd();
    let stderr_fd = stderr.as_raw_fd();
    let drain_done = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = [
        (stdout.map_reader(), stdout_fd),
        (stderr.map_reader(), stderr_fd),
    ]
    .into_iter()
    .map(|(mut r, fd)| {
        let done = drain_done.clone();
        thread::spawn(move || {
            let mut buf = [0; 4096];
            while !done.load(Ordering::SeqCst) {
                let mut descriptor = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                let ready = unsafe { libc::poll(&mut descriptor, 1, 20) };
                if ready > 0 && r.read(&mut buf).unwrap_or(0) == 0 {
                    break;
                }
            }
        })
    })
    .collect();
    let payload = serde_json::to_vec(inputs)?;
    let write_result = child
        .stdin
        .take()
        .context("recipe_stdin")?
        .write_all(&payload);
    let start = Instant::now();
    let mut stopped = None;
    let mut read_error = None;
    let status = loop {
        // Observe exit without reaping: the leader's PID/PGID cannot be reused
        // until descendants are signalled and Child::wait finally reaps it.
        let exited = observe_recipe_exit(&mut child, |pid| {
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid,
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result == 0 {
                Ok(info.si_pid == pid as i32)
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
        let exited = match exited {
            Ok(exited) => exited,
            Err(error) => break Err(error),
        };
        if exited {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            break child.wait().context("recipe_wait_failed");
        }
        read_error = workbench_git::check_deadline().err().or(read_error);
        let stop = cancelled.load(Ordering::SeqCst)
            || start.elapsed() >= Duration::from_secs(recipe.timeout_seconds)
            || read_error.is_some()
            || write_result.is_err();
        if stop && stopped.is_none() {
            stopped = Some(Instant::now());
            // Separate process group; do not signal the workbench itself.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGTERM);
            }
        }
        if stopped.is_some_and(|s| s.elapsed() >= Duration::from_millis(500)) {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
        }
        thread::sleep(Duration::from_millis(20));
    };
    // An escaped descendant may retain a pipe. It cannot hold preparation open
    // after the trusted leader exited; output is deliberately not retained.
    drain_done.store(true, Ordering::SeqCst);
    for reader in readers {
        let _ = reader.join();
    }
    let status = status?;
    if cancelled.load(Ordering::SeqCst) {
        bail!("cancelled");
    }
    if let Some(error) = read_error {
        return Err(error);
    }
    workbench_git::check_deadline()?;
    ensure!(stopped.is_none(), "recipe_timeout");
    write_result.context("recipe_stdin_failed")?;
    ensure!(status.success(), "recipe_failed: exit {:?}", status.code());
    Ok(())
}

fn observe_recipe_exit(
    child: &mut Child,
    mut observe: impl FnMut(u32) -> std::io::Result<bool>,
) -> Result<bool> {
    loop {
        match observe(child.id()) {
            Ok(exited) => return Ok(exited),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                // Confirm this is still our live, unreaped child before sending
                // a group signal; ECHILD must never signal a reused PID/PGID.
                if matches!(child.try_wait(), Ok(None)) {
                    unsafe {
                        libc::kill(-(child.id() as i32), libc::SIGKILL);
                    }
                    let _ = child.wait();
                }
                bail!("recipe_wait_failed");
            }
        }
    }
}

trait BoxReader {
    fn map_reader(self) -> Box<dyn Read + Send>;
}
impl<T: Read + Send + 'static> BoxReader for T {
    fn map_reader(self) -> Box<dyn Read + Send> {
        Box::new(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Recipe) {
        let temp = tempfile::TempDir::new().unwrap();
        fs::create_dir(temp.path().join("scripts")).unwrap();
        fs::create_dir(temp.path().join("Config")).unwrap();
        fs::write(temp.path().join("scripts/prepare.py"), "trusted script").unwrap();
        fs::write(
            temp.path().join("Config/Version.xcconfig"),
            "MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n",
        )
        .unwrap();
        let actual = temp.path().join("actual-executable");
        fs::write(&actual, "#!/bin/sh\nexec sleep 30\n").unwrap();
        fs::set_permissions(&actual, fs::Permissions::from_mode(0o755)).unwrap();
        let executable = temp.path().join("executable");
        std::os::unix::fs::symlink(&actual, &executable).unwrap();
        let mut recipe = Recipe {
            id: "test".into(),
            repo_id: "test".into(),
            revision: 1,
            executable,
            script: "scripts/prepare.py".into(),
            writes: vec!["Config/Version.xcconfig".into()],
            timeout_seconds: 300,
            target: "test".into(),
            configuration: "test".into(),
            trusted_hash: None,
        };
        recipe.trusted_hash = Some(trust_hash(&recipe, temp.path()).unwrap());
        (temp, recipe)
    }

    #[test]
    fn streaming_trust_hash_preserves_contract_hashes_and_executable_symlinks() {
        let (temp, recipe) = fixture();
        let mut contract = recipe.clone();
        contract.trusted_hash = None;
        let expected = digest(&(
            contract,
            workbench_domain::hash(fs::read(temp.path().join(&recipe.script)).unwrap()),
            workbench_domain::hash(fs::read(&recipe.executable).unwrap()),
        ))
        .unwrap();
        assert_eq!(trusted(&recipe, temp.path()).unwrap(), expected);
        assert_eq!(
            script_hash(&recipe, temp.path()).unwrap(),
            workbench_domain::hash(fs::read(temp.path().join(&recipe.script)).unwrap())
        );
    }

    #[test]
    fn cancellation_interrupts_large_and_growing_recipe_reads_after_one_chunk() {
        for growing in [false, true] {
            let temp = tempfile::TempDir::new().unwrap();
            let path = temp.path().join("large");
            fs::File::create(&path)
                .unwrap()
                .set_len(64 * 1024 * 1024)
                .unwrap();
            let flag = Arc::new(AtomicBool::new(false));
            let mut chunks = 0;
            let error = workbench_git::with_read_cancellation(flag.clone(), || {
                read_regular_file(&path, None, |_| {
                    chunks += 1;
                    if growing {
                        fs::OpenOptions::new()
                            .write(true)
                            .open(&path)
                            .unwrap()
                            .set_len(128 * 1024 * 1024)
                            .unwrap();
                    }
                    flag.store(true, Ordering::SeqCst);
                })
            })
            .unwrap_err();
            assert_eq!(error.to_string(), "cancelled");
            assert_eq!(chunks, 1);
        }
    }

    #[test]
    fn trust_and_inspection_honor_cancellation_and_read_deadlines() {
        let (temp, recipe) = fixture();
        workbench_git::with_read_cancellation(Arc::new(AtomicBool::new(true)), || {
            assert_eq!(
                trust_hash(&recipe, temp.path()).unwrap_err().to_string(),
                "cancelled"
            );
            assert_eq!(
                script_hash(&recipe, temp.path()).unwrap_err().to_string(),
                "cancelled"
            );
            assert_eq!(inspect(temp.path()).unwrap_err().to_string(), "cancelled");
        });
        workbench_git::with_deadline(Duration::ZERO, || {
            assert_eq!(
                trust_hash(&recipe, temp.path()).unwrap_err().to_string(),
                "git_timeout"
            );
            assert_eq!(
                script_hash(&recipe, temp.path()).unwrap_err().to_string(),
                "git_timeout"
            );
            assert_eq!(inspect(temp.path()).unwrap_err().to_string(), "git_timeout");
        });
        fs::write(
            temp.path().join("Config/Version.xcconfig"),
            vec![b' '; 64 * 1024 + 1],
        )
        .unwrap();
        assert_eq!(
            inspect(temp.path()).unwrap_err().to_string(),
            "recipe_file_too_large"
        );
    }

    #[test]
    fn recipe_process_honors_worker_deadline_without_changing_its_configured_timeout() {
        let (temp, recipe) = fixture();
        assert_eq!(recipe.timeout_seconds, 300);
        let start = Instant::now();
        let error = workbench_git::with_deadline(Duration::from_millis(100), || {
            run(
                &recipe,
                temp.path(),
                &IosInputs {
                    marketing_version: "1.0.0".into(),
                    local_build: "1".into(),
                },
                Arc::new(AtomicBool::new(false)),
            )
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "git_timeout");
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn interrupted_wait_retries_and_fatal_wait_reaps_owned_child() {
        let mut child = Command::new("/bin/sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let mut attempts = 0;
        let exited = observe_recipe_exit(&mut child, |_| {
            attempts += 1;
            if attempts <= 2 {
                Err(std::io::ErrorKind::Interrupted.into())
            } else {
                Ok(false)
            }
        })
        .unwrap();
        assert!(!exited);
        assert_eq!(attempts, 3);
        let error =
            observe_recipe_exit(&mut child, |_| Err(std::io::ErrorKind::InvalidInput.into()))
                .unwrap_err();
        assert_eq!(error.to_string(), "recipe_wait_failed");
        assert!(!child.try_wait().unwrap().unwrap().success());
    }
}

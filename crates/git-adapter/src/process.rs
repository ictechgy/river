//! Bounded pipes and lifetime for fixed Git invocations, including stdin writes.
use anyhow::{Context, Result, ensure};
use std::{
    io::{Read, Write},
    os::{fd::AsRawFd, unix::process::CommandExt},
    process::{Command, Output, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[cfg(test)]
type CommandObserver = Box<dyn FnMut(&Command)>;
#[cfg(test)]
thread_local! { static COMMAND_OBSERVER: std::cell::RefCell<Option<CommandObserver>> = const { std::cell::RefCell::new(None) }; }
#[cfg(test)]
pub(super) fn observe_commands<T>(
    observer: impl FnMut(&Command) + 'static,
    work: impl FnOnce() -> T,
) -> T {
    struct Restore(Option<CommandObserver>);
    impl Drop for Restore {
        fn drop(&mut self) {
            COMMAND_OBSERVER.with(|slot| {
                slot.replace(self.0.take());
            });
        }
    }
    let _restore = Restore(COMMAND_OBSERVER.with(|slot| slot.replace(Some(Box::new(observer)))));
    work()
}

pub(super) fn run(
    mut command: Command,
    input: Option<&[u8]>,
    timeout: Duration,
    limit: usize,
) -> Result<Output> {
    let timeout = crate::deadline::budget(timeout)?;
    #[cfg(test)]
    COMMAND_OBSERVER.with(|slot| {
        if let Some(observer) = slot.borrow_mut().as_mut() {
            observer(&command);
        }
    });
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = command.spawn().context("git_unavailable")?;
    let done = Arc::new(AtomicBool::new(false));
    let overflow = Arc::new(AtomicBool::new(false));
    let stdout = drain(
        child.stdout.take().context("git_stdout")?,
        limit,
        done.clone(),
        Some(overflow.clone()),
    );
    let stderr = drain(
        child.stderr.take().context("git_stderr")?,
        16 * 1024,
        done.clone(),
        None,
    );
    let writer = input.map(|bytes| {
        let mut pipe = child.stdin.take().expect("piped stdin");
        let bytes = bytes.to_vec();
        let done = done.clone();
        thread::spawn(move || -> std::io::Result<()> {
            let fd = pipe.as_raw_fd();
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            let mut offset = 0;
            while offset < bytes.len() && !done.load(Ordering::SeqCst) {
                let mut poll = libc::pollfd {
                    fd,
                    events: libc::POLLOUT,
                    revents: 0,
                };
                if unsafe { libc::poll(&mut poll, 1, 20) } <= 0 {
                    continue;
                }
                match pipe.write(&bytes[offset..bytes.len().min(offset + 4096)]) {
                    Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
                    Ok(n) => offset += n,
                    Err(e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            || e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(e) => return Err(e),
                }
            }
            if offset != bytes.len() {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            Ok(())
        })
    });
    let start = Instant::now();
    let (status, timed_out) = loop {
        // Keep the leader unreaped until its group has been signalled, so its
        // PID/PGID cannot be reused between exit observation and cleanup.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            // Never signal a PGID if the OS could not confirm child ownership.
            break (Err(anyhow::anyhow!("git_wait_failed")), false);
        }
        if info.si_pid == child.id() as i32
            || start.elapsed() >= timeout
            || overflow.load(Ordering::SeqCst)
        {
            let timed_out = info.si_pid != child.id() as i32 && start.elapsed() >= timeout;
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            break (child.wait().context("git_wait_failed"), timed_out);
        }
        thread::sleep(Duration::from_millis(5));
    };
    done.store(true, Ordering::SeqCst);
    let (stdout, out_complete) = stdout
        .join()
        .map_err(|_| anyhow::anyhow!("git_output_reader_failed"))??;
    let (mut stderr, err_complete) = stderr
        .join()
        .map_err(|_| anyhow::anyhow!("git_output_reader_failed"))??;
    let write = writer
        .map(|w| {
            w.join()
                .map_err(|_| anyhow::anyhow!("git_input_writer_failed"))
        })
        .transpose()?
        .transpose();
    let status = status?;
    ensure!(!timed_out, "git_timeout");
    ensure!(!overflow.load(Ordering::SeqCst), "result_too_large");
    ensure!(out_complete && err_complete, "git_output_incomplete");
    if status.success() {
        write.context("git_stdin_failed")?;
    }
    if stderr.len() == 16 * 1024 {
        stderr.extend_from_slice(b"\n[diagnostics truncated]");
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn drain(
    mut pipe: impl Read + AsRawFd + Send + 'static,
    limit: usize,
    done: Arc<AtomicBool>,
    overflow: Option<Arc<AtomicBool>>,
) -> thread::JoinHandle<std::io::Result<(Vec<u8>, bool)>> {
    thread::spawn(move || {
        let mut kept = Vec::new();
        let mut buffer = [0; 8192];
        let mut finished_at = None;
        loop {
            if done.load(Ordering::SeqCst) {
                let finish = finished_at.get_or_insert_with(Instant::now);
                if finish.elapsed() > Duration::from_millis(200) {
                    return Ok((kept, false));
                }
            }
            let mut poll = libc::pollfd {
                fd: pipe.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut poll, 1, 20) };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                continue;
            }
            let n = pipe.read(&mut buffer)?;
            if n == 0 {
                return Ok((kept, true));
            }
            let count = n.min(limit.saturating_sub(kept.len()));
            kept.extend_from_slice(&buffer[..count]);
            if count != n
                && let Some(ref flag) = overflow
            {
                flag.store(true, Ordering::SeqCst);
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn shell(script: &str) -> Command {
        let mut c = Command::new("/bin/sh");
        c.args(["-c", script]);
        c
    }
    #[test]
    fn both_pipes_drain_and_retained_diagnostics_are_bounded() {
        let out = run(shell("i=0; while [ $i -lt 10000 ]; do echo diagnostics >&2; i=$((i+1)); done; printf result"), None, Duration::from_secs(5), 1024).unwrap();
        assert!(out.status.success());
        assert_eq!(out.stdout, b"result");
        assert!(out.stderr.len() <= 16 * 1024 + 30);
    }
    #[test]
    fn stdout_and_blocked_stdin_have_bounded_lifetimes() {
        let error = run(
            shell("while :; do printf 'too much output'; done"),
            None,
            Duration::from_secs(2),
            1024,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "result_too_large");
        let start = Instant::now();
        let error = run(
            shell("sleep 30"),
            Some(&vec![0; 1024 * 1024]),
            Duration::from_millis(100),
            1024,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "git_timeout");
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn request_deadline_overrides_command_budget_and_restores_after_scope() {
        let start = Instant::now();
        let result = crate::with_deadline(Duration::from_millis(100), || {
            run(shell("exec sleep 30"), None, Duration::from_secs(30), 1024)
        });
        assert_eq!(result.unwrap_err().to_string(), "git_timeout");
        assert!(start.elapsed() < Duration::from_secs(2));
        crate::check_deadline().unwrap();
    }
}

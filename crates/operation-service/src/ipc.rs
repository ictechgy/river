use crate::{Request, Response, Service};
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use std::{
    fs,
    io::{BufRead, BufReader, BufWriter, Read, Write},
    os::fd::AsRawFd,
    os::unix::{
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt},
        net::{SocketAddr, UnixListener, UnixStream},
    },
    path::Path,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};

const MAX_REQUEST: u64 = 1024 * 1024;
const MAX_HANDLERS: usize = 32;
const FRAME_TIMEOUT: Duration = Duration::from_secs(10);
pub fn serve(service: Arc<Service>, socket: &Path) -> Result<()> {
    serve_with_accept(service, socket, UnixListener::accept)
}
fn serve_with_accept(
    service: Arc<Service>,
    socket: &Path,
    mut accept: impl FnMut(&UnixListener) -> std::io::Result<(UnixStream, SocketAddr)>,
) -> Result<()> {
    let parent = socket.parent().context("socket_parent_required")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let meta = fs::symlink_metadata(parent)?;
    ensure!(
        meta.is_dir()
            && !meta.file_type().is_symlink()
            && meta.uid() == unsafe { libc_uid() }
            && meta.permissions().mode() & 0o077 == 0,
        "unsafe_socket_directory"
    );
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(socket.with_extension("socket.lock"))?;
    lock.try_lock_exclusive().context("socket_in_use")?;
    if let Ok(meta) = fs::symlink_metadata(socket) {
        ensure!(
            meta.file_type().is_socket()
                && meta.uid() == unsafe { libc_uid() }
                && UnixStream::connect(socket).is_err(),
            "socket_in_use"
        );
        fs::remove_file(socket)?;
    }
    let listener = UnixListener::bind(socket)?;
    listener.set_nonblocking(true)?;
    fs::set_permissions(socket, fs::Permissions::from_mode(0o600))?;
    let mut handlers = Vec::new();
    let mut listener_error = None;
    while !service.is_stopping() {
        // Reap under sustained accepts too, and bound Git reads and idle peers.
        handlers.retain(|handler: &thread::JoinHandle<()>| !handler.is_finished());
        match accept(&listener) {
            Ok((stream, _)) => {
                if stream.set_nonblocking(false).is_err() {
                    continue;
                }
                if handlers.len() >= MAX_HANDLERS {
                    reject_busy(stream);
                    continue;
                }
                let service = service.clone();
                handlers.push(thread::spawn(move || {
                    let _ = handle(service, stream);
                }));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                let mut descriptor = libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // A shutdown RPC sets stopping; poll bounds the final wakeup
                // without waking every 10 ms while the workspace is idle.
                unsafe {
                    libc::poll(&mut descriptor, 1, 250);
                }
            }
            Err(error) if transient_accept_error(&error) => {
                // Resource pressure and disconnected peers affect this accept,
                // not the listener's lifetime. Rate-limit retries under fd pressure.
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => {
                service
                    .stopping
                    .store(true, std::sync::atomic::Ordering::SeqCst);
                listener_error = Some(error);
                break;
            }
        }
    }
    drop(listener);
    // The shutdown response is fully written before the process exits. Existing
    // read requests can finish; no new mutation is accepted after stopping=true.
    for handler in handlers {
        let _ = handler.join();
    }
    // A fatal listener error must not terminate a preparation in the middle of
    // a Git write or trusted recipe. New admissions already see stopping=true.
    while !service
        .active
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .is_empty()
    {
        thread::sleep(Duration::from_millis(10));
    }
    let cleanup = fs::remove_file(socket);
    drop(lock);
    if let Some(error) = listener_error {
        return Err(error.into());
    }
    cleanup?;
    Ok(())
}
fn reject_busy(mut stream: UnixStream) {
    let deadline = Instant::now() + Duration::from_millis(100);
    let mut writer = DeadlineWriter {
        stream: &mut stream,
        deadline,
    };
    if writer.write_all(b"{\"schema_version\":1,\"error\":{\"code\":\"service_busy\",\"message\":\"Too many concurrent requests; retry shortly.\"}}\n").is_err() { return; }
    // A caller sends its frame before reading. Closing with unread request
    // bytes can reset the connection or give it EPIPE instead of service_busy.
    // Drain just one bounded frame, without dispatch or another handler. Share
    // the short deadline with the reply so an idle peer cannot stall accepts.
    let reader = DeadlineReader {
        stream: &stream,
        deadline,
    };
    let _ = BufReader::new(reader.take(MAX_REQUEST + 1)).read_until(b'\n', &mut Vec::new());
}
fn transient_accept_error(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::Interrupted | std::io::ErrorKind::ConnectionAborted
    ) || matches!(
        error.raw_os_error(),
        Some(libc::EMFILE | libc::ENFILE | libc::ENOBUFS | libc::ENOMEM | libc::EPROTO)
    )
}
unsafe fn libc_uid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}
fn handle(service: Arc<Service>, mut stream: UnixStream) -> Result<()> {
    let mut line = String::new();
    let reader = DeadlineReader {
        stream: &stream,
        deadline: Instant::now() + FRAME_TIMEOUT,
    };
    BufReader::new(reader.take(MAX_REQUEST + 1)).read_line(&mut line)?;
    ensure!(
        line.len() as u64 <= MAX_REQUEST && line.ends_with('\n'),
        "invalid_request_frame"
    );
    let request: Request = serde_json::from_str(&line)?;
    let response = service.dispatch(request);
    let writer = DeadlineWriter {
        stream: &mut stream,
        deadline: Instant::now() + FRAME_TIMEOUT,
    };
    let mut writer = BufWriter::new(writer);
    serde_json::to_writer(&mut writer, &response)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

fn remaining(deadline: Instant) -> std::io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::TimedOut, "IPC frame deadline"))
}
struct DeadlineReader<'a> {
    stream: &'a UnixStream,
    deadline: Instant,
}
impl Read for DeadlineReader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.stream
            .set_read_timeout(Some(remaining(self.deadline)?))?;
        self.stream.read(buffer)
    }
}
struct DeadlineWriter<'a> {
    stream: &'a mut UnixStream,
    deadline: Instant,
}
impl Write for DeadlineWriter<'_> {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.stream
            .set_write_timeout(Some(remaining(self.deadline)?))?;
        self.stream.write(buffer)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}
pub fn call(socket: &Path, request: &Request) -> Result<Response> {
    let mut stream = UnixStream::connect(socket).context("service_unavailable")?;
    let timeout = if matches!(
        request.method.as_str(),
        "configure_remote" | "fetch_remote" | "pull_remote" | "push_remote"
    ) {
        360
    } else if matches!(
        request.method.as_str(),
        "stage_hunk" | "stage_file" | "commit"
    ) {
        180
    } else {
        30
    };
    stream.set_read_timeout(Some(Duration::from_secs(timeout)))?;
    serde_json::to_writer(&mut stream, request)?;
    stream.write_all(b"\n")?;
    let mut line = String::new();
    BufReader::new(stream.take(16 * 1024 * 1024)).read_line(&mut line)?;
    ensure!(line.ends_with('\n'), "invalid_response_frame");
    Ok(serde_json::from_str(&line)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_service(home: &Path) -> Arc<Service> {
        let workspace = crate::fixtures::create(home).unwrap();
        Service::open(workspace, &home.join("journal.sqlite")).unwrap()
    }
    #[test]
    fn existing_socket_parent_permissions_are_never_changed() {
        let temp = tempfile::TempDir::new().unwrap();
        let service = fixture_service(&temp.path().join("fixture"));
        let parent = temp.path().join("shared");
        fs::create_dir(&parent).unwrap();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o750)).unwrap();
        let error = serve_with_accept(service, &parent.join("engine.sock"), |_| {
            Err(std::io::Error::from_raw_os_error(libc::EBADF))
        })
        .unwrap_err();
        assert_eq!(error.to_string(), "unsafe_socket_directory");
        assert_eq!(
            fs::metadata(parent).unwrap().permissions().mode() & 0o777,
            0o750
        );
    }
    #[test]
    fn transient_accept_errors_do_not_end_the_listener() {
        let temp = tempfile::TempDir::new().unwrap();
        let service = fixture_service(&temp.path().join("fixture"));
        let socket = temp.path().join("ipc/service.sock");
        let running = service.clone();
        let path = socket.clone();
        let server = thread::spawn(move || {
            let mut errors = [
                libc::ECONNABORTED,
                libc::EMFILE,
                libc::ENFILE,
                libc::ENOMEM,
                libc::ENOBUFS,
                libc::EINTR,
            ]
            .into_iter();
            serve_with_accept(running, &path, |listener| match errors.next() {
                Some(error) => Err(std::io::Error::from_raw_os_error(error)),
                None => listener.accept(),
            })
        });
        let start = Instant::now();
        while !socket.exists() {
            assert!(start.elapsed() < Duration::from_secs(3));
            thread::sleep(Duration::from_millis(5));
        }
        let response = call(
            &socket,
            &Request {
                method: "list_workspaces".into(),
                params: serde_json::json!({}),
            },
        );
        service.shutdown_if_idle().unwrap();
        let result = server.join().unwrap();
        assert!(result.is_ok(), "{result:?}");
        assert!(response.unwrap().error.is_none());
    }
    #[test]
    fn fatal_accept_error_drains_preparation_workers_and_removes_socket() {
        let temp = tempfile::TempDir::new().unwrap();
        let service = fixture_service(&temp.path().join("fixture"));
        service.active.lock().unwrap().insert(
            "in-flight".into(),
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
        );
        let socket = temp.path().join("ipc/service.sock");
        let path = socket.clone();
        let running = service.clone();
        let server = thread::spawn(move || {
            serve_with_accept(running, &path, |_| {
                Err(std::io::Error::from_raw_os_error(libc::EBADF))
            })
        });
        let start = Instant::now();
        while !service.is_stopping() {
            assert!(start.elapsed() < Duration::from_secs(3));
            thread::sleep(Duration::from_millis(2));
        }
        // Hold the admitted worker until the refusal check completes, ensuring
        // the listener closes before draining rather than after the last join.
        let probe_start = Instant::now();
        let refused = loop {
            if UnixStream::connect(&socket).is_err() {
                break true;
            }
            if probe_start.elapsed() >= Duration::from_millis(60) {
                break false;
            }
            thread::sleep(Duration::from_millis(2));
        };
        let draining = !server.is_finished();
        service.active.lock().unwrap().remove("in-flight");
        let result = server.join().unwrap();
        assert!(result.is_err());
        assert!(draining);
        assert!(
            refused,
            "listener still accepted connections while draining"
        );
        assert!(service.is_stopping());
        assert!(!socket.exists());
    }
    #[test]
    fn a_dribbling_peer_cannot_reset_the_frame_deadline() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let sender = thread::spawn(move || {
            for _ in 0..20 {
                if client.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        let mut reader = DeadlineReader {
            stream: &server,
            deadline: start + Duration::from_millis(100),
        };
        assert!(reader.read_to_end(&mut Vec::new()).is_err());
        assert!(start.elapsed() < Duration::from_millis(350));
        drop(server);
        sender.join().unwrap();
    }
    #[test]
    fn non_reading_peer_cannot_block_a_response_forever() {
        let (mut server, _client) = UnixStream::pair().unwrap();
        let start = Instant::now();
        let mut writer = DeadlineWriter {
            stream: &mut server,
            deadline: start + Duration::from_millis(100),
        };
        assert!(writer.write_all(&vec![0; 4 * 1024 * 1024]).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn busy_response_survives_a_request_larger_than_the_socket_buffer() {
        let (server, mut client) = UnixStream::pair().unwrap();
        client
            .set_write_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let size: libc::c_int = 4096;
        assert_eq!(
            unsafe {
                libc::setsockopt(
                    client.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_SNDBUF,
                    (&size as *const libc::c_int).cast(),
                    std::mem::size_of_val(&size) as libc::socklen_t,
                )
            },
            0
        );
        let worker = thread::spawn(move || reject_busy(server));
        let mut frame = vec![b' '; 128 * 1024];
        frame.extend_from_slice(b"{\"method\":\"list_workspaces\",\"params\":{}}\n");
        let sent = client.write_all(&frame);
        let mut response = String::new();
        let received = BufReader::new(&client).read_line(&mut response);
        drop(client);
        worker.join().unwrap();
        assert!(
            sent.is_ok(),
            "overload dropped a still-writing request: {sent:?}"
        );
        received.unwrap();
        let response: Response = serde_json::from_str(&response).unwrap();
        assert_eq!(response.error.unwrap().code, "service_busy");
    }
    #[test]
    fn a_busy_peer_that_never_sends_does_not_stall_the_listener() {
        let (server, _idle_client) = UnixStream::pair().unwrap();
        let start = Instant::now();
        reject_busy(server);
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn idle_connections_are_bounded_and_service_recovers_after_disconnect() {
        let temp = tempfile::TempDir::new().unwrap();
        let home = temp.path().join("fixture");
        let workspace = crate::fixtures::create(&home).unwrap();
        let service = Service::open(workspace, &home.join("journal.sqlite")).unwrap();
        let socket = temp.path().join("ipc/service.sock");
        let running = service.clone();
        let path = socket.clone();
        let server = thread::spawn(move || serve(running, &path).unwrap());
        let start = Instant::now();
        while !socket.exists() {
            assert!(start.elapsed() < Duration::from_secs(3));
            thread::sleep(Duration::from_millis(5));
        }
        let clients: Vec<_> = (0..MAX_HANDLERS)
            .map(|_| UnixStream::connect(&socket).unwrap())
            .collect();
        let busy = call(
            &socket,
            &Request {
                method: "list_workspaces".into(),
                params: serde_json::json!({}),
            },
        );
        drop(clients);
        let recovered = loop {
            let response = call(
                &socket,
                &Request {
                    method: "list_workspaces".into(),
                    params: serde_json::json!({}),
                },
            );
            if response.as_ref().is_ok_and(|r| r.error.is_none())
                || start.elapsed() > Duration::from_secs(5)
            {
                break response;
            }
            thread::sleep(Duration::from_millis(5));
        };
        // Shutdown through the owning service so even a failing assertion has
        // no orphan listener or sleeping test thread.
        assert!(service.shutdown_if_idle().unwrap());
        server.join().unwrap();
        assert_eq!(busy.unwrap().error.unwrap().code, "service_busy");
        assert!(recovered.unwrap().error.is_none());
    }
}

//! Only presentation reads may reuse hashes. Plans, mutations and verification
//! always hash bytes again, so a cached display cannot authorize stale writes.
use anyhow::{Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, Metadata, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    size: u64,
    mode: u32,
    mtime: (i64, i64),
    ctime: (i64, i64),
}
impl From<&Metadata> for Stamp {
    fn from(m: &Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            size: m.len(),
            mode: m.mode(),
            mtime: (m.mtime(), m.mtime_nsec()),
            ctime: (m.ctime(), m.ctime_nsec()),
        }
    }
}
#[derive(Default)]
struct Cache {
    entries: BTreeMap<PathBuf, (Stamp, String)>,
    ranks: BTreeSet<([u8; 32], PathBuf)>,
    bytes: usize,
}
impl Cache {
    fn cost(path: &Path, value: &str) -> usize {
        2 * path.as_os_str().len() + value.len() + std::mem::size_of::<Stamp>() + 32
    }
    fn insert(
        &mut self,
        path: &Path,
        stamp: Stamp,
        value: String,
        capacity: usize,
        byte_limit: usize,
    ) {
        let cost = Self::cost(path, &value);
        let rank: [u8; 32] = Sha256::digest(path.as_os_str().as_encoded_bytes()).into();
        let key = (rank, path.to_path_buf());
        if let Some((_, old)) = self.entries.remove(path) {
            self.bytes -= Self::cost(path, &old);
            self.ranks.remove(&key);
        }
        if cost > byte_limit {
            return;
        }
        // Stable bottom-hash admission resists sequential scans larger than the
        // cache. FIFO and plain LRU both thrash at zero hits on repeated scans.
        while self.entries.len() >= capacity || self.bytes + cost > byte_limit {
            let Some(worst) = self.ranks.last() else {
                return;
            };
            if &key >= worst {
                return;
            }
            let old = self.ranks.pop_last().unwrap();
            if let Some((_, value)) = self.entries.remove(&old.1) {
                self.bytes -= Self::cost(&old.1, &value);
            }
        }
        self.bytes += cost;
        self.ranks.insert(key);
        self.entries.insert(path.to_path_buf(), (stamp, value));
    }
}
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
fn cache() -> std::sync::MutexGuard<'static, Cache> {
    CACHE
        .get_or_init(|| Mutex::new(Cache::default()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}
#[cfg(test)]
thread_local! { static BYTES_READ: std::sync::atomic::AtomicU64 = const { std::sync::atomic::AtomicU64::new(0) }; }
#[cfg(test)]
type ChunkObserver = Box<dyn FnMut()>;
#[cfg(test)]
thread_local! { static CHUNK_OBSERVER: std::cell::RefCell<Option<ChunkObserver>> = const { std::cell::RefCell::new(None) }; }

#[cfg(test)]
fn observe_chunks<T>(observer: impl FnMut() + 'static, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<ChunkObserver>);
    impl Drop for Restore {
        fn drop(&mut self) {
            CHUNK_OBSERVER.with(|slot| {
                slot.replace(self.0.take());
            });
        }
    }
    let _restore = Restore(CHUNK_OBSERVER.with(|slot| slot.replace(Some(Box::new(observer)))));
    work()
}

pub(super) fn value(path: &Path, metadata: &Metadata, presentation_cache: bool) -> Result<String> {
    crate::with_deadline(crate::deadline::READ_PHASE_TIMEOUT, || {
        value_inner(path, metadata, presentation_cache)
    })
}

fn value_inner(path: &Path, metadata: &Metadata, presentation_cache: bool) -> Result<String> {
    crate::check_deadline()?;
    let stamp = Stamp::from(metadata);
    if presentation_cache
        && let Some((stored, value)) = cache().entries.get(path)
        && stored == &stamp
    {
        return Ok(value.clone());
    }
    let mut file: File = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    ensure!(
        Stamp::from(&file.metadata()?) == stamp,
        "stale_read_snapshot"
    );
    let mut hasher = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut size = 0u64;
    loop {
        crate::check_deadline()?;
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
        size += n as u64;
        #[cfg(test)]
        BYTES_READ.with(|bytes| bytes.fetch_add(n as u64, std::sync::atomic::Ordering::SeqCst));
        #[cfg(test)]
        CHUNK_OBSERVER.with(|slot| {
            if let Some(observer) = slot.borrow_mut().as_mut() {
                observer();
            }
        });
        crate::check_deadline()?;
        // A growing file cannot extend this strict read indefinitely, even
        // when a writer keeps appending faster than the reader reaches EOF.
        ensure!(size <= stamp.size, "stale_read_snapshot");
    }
    ensure!(
        size == stamp.size
            && Stamp::from(&file.metadata()?) == stamp
            && Stamp::from(&fs::symlink_metadata(path)?) == stamp,
        "stale_read_snapshot"
    );
    let value = format!("file:{:o}:{:x}", metadata.mode() & 0o777, hasher.finalize());
    if presentation_cache {
        cache().insert(path, stamp, value.clone(), 65_536, 16 * 1024 * 1024);
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn cancellation_interrupts_large_and_growing_strict_hashes_between_chunks() {
        for growing in [false, true] {
            let temp = tempfile::TempDir::new().unwrap();
            let path = temp.path().join("large");
            File::create(&path)
                .unwrap()
                .set_len(64 * 1024 * 1024)
                .unwrap();
            let metadata = fs::symlink_metadata(&path).unwrap();
            let flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let cancel = flag.clone();
            let observed = path.clone();
            let chunks = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let seen = chunks.clone();
            let error = crate::deadline::with_read_cancellation(flag, || {
                observe_chunks(
                    move || {
                        seen.fetch_add(1, Ordering::SeqCst);
                        if growing {
                            OpenOptions::new()
                                .write(true)
                                .open(&observed)
                                .unwrap()
                                .set_len(128 * 1024 * 1024)
                                .unwrap();
                        }
                        cancel.store(true, Ordering::SeqCst);
                    },
                    || value(&path, &metadata, false),
                )
            })
            .unwrap_err();
            assert_eq!(error.to_string(), "cancelled");
            assert_eq!(chunks.load(Ordering::SeqCst), 1);
        }
    }

    #[test]
    fn growing_hash_does_not_read_beyond_the_original_size() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("growing");
        fs::write(&path, vec![0; 64 * 1024]).unwrap();
        let metadata = fs::symlink_metadata(&path).unwrap();
        let append = path.clone();
        let error = observe_chunks(
            move || {
                let file = OpenOptions::new().write(true).open(&append).unwrap();
                file.set_len(file.metadata().unwrap().len() + 64 * 1024)
                    .unwrap();
            },
            || value(&path, &metadata, false),
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "stale_read_snapshot");
    }
    #[test]
    fn oversized_sequential_scans_retain_a_stable_bounded_working_set() {
        let temp = tempfile::TempDir::new().unwrap();
        let stamp = Stamp::from(&fs::metadata(temp.path()).unwrap());
        let mut cache = Cache::default();
        for n in 0..70_000 {
            cache.insert(
                Path::new(&format!("file-{n:05}")),
                stamp.clone(),
                "hash".into(),
                65_536,
                16 * 1024 * 1024,
            );
        }
        assert_eq!(cache.entries.len(), 65_536);
        let mut hits = 0;
        for n in 0..70_000 {
            let path = PathBuf::from(format!("file-{n:05}"));
            if cache.entries.contains_key(&path) {
                hits += 1;
            } else {
                cache.insert(
                    &path,
                    stamp.clone(),
                    "hash".into(),
                    65_536,
                    16 * 1024 * 1024,
                );
            }
        }
        assert_eq!(hits, 65_536);
        assert!(cache.bytes <= 16 * 1024 * 1024);
    }
    #[test]
    fn display_cache_skips_bytes_but_strict_reads_and_same_size_edits_do_not() {
        let temp = tempfile::TempDir::new().unwrap();
        let path = temp.path().join("data");
        fs::write(&path, vec![b'a'; 4096]).unwrap();
        let metadata = fs::symlink_metadata(&path).unwrap();
        BYTES_READ.with(|bytes| bytes.store(0, Ordering::SeqCst));
        let first = value(&path, &metadata, true).unwrap();
        assert_eq!(value(&path, &metadata, true).unwrap(), first);
        assert_eq!(BYTES_READ.with(|bytes| bytes.load(Ordering::SeqCst)), 4096);
        assert_eq!(value(&path, &metadata, false).unwrap(), first);
        assert_eq!(BYTES_READ.with(|bytes| bytes.load(Ordering::SeqCst)), 8192);
        fs::write(&path, vec![b'b'; 4096]).unwrap();
        File::open(&path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(metadata.modified().unwrap()))
            .unwrap();
        let changed = value(&path, &fs::symlink_metadata(&path).unwrap(), true).unwrap();
        assert_ne!(changed, first);
        assert_eq!(
            BYTES_READ.with(|bytes| bytes.load(Ordering::SeqCst)),
            12_288
        );
        let large = temp.path().join("large");
        File::create(&large)
            .unwrap()
            .set_len(33 * 1024 * 1024)
            .unwrap();
        assert!(
            value(&large, &fs::metadata(&large).unwrap(), false)
                .unwrap()
                .starts_with("file:")
        );
    }
}

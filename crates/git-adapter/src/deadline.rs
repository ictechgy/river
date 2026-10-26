use anyhow::{Result, ensure};
use std::{
    cell::{Cell, RefCell},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
thread_local! { static END: Cell<Option<Instant>> = const { Cell::new(None) }; }
thread_local! {
    static CANCELLED: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
    static CANCELLATION_SUSPENDED: Cell<bool> = const { Cell::new(false) };
}
/// A strict read phase is bounded even when no request owns the current thread.
pub const READ_PHASE_TIMEOUT: Duration = Duration::from_secs(30);

/// Cancellation is scoped to the worker thread; pipe-draining threads are
/// stopped by their owning process runner after it observes this flag.
pub fn with_read_cancellation<T>(flag: Arc<AtomicBool>, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<Arc<AtomicBool>>);
    impl Drop for Restore {
        fn drop(&mut self) {
            CANCELLED.with(|slot| {
                slot.replace(self.0.take());
            });
        }
    }
    let _restore = Restore(CANCELLED.with(|slot| slot.replace(Some(flag))));
    work()
}

fn without_read_cancellation<T>(work: impl FnOnce() -> T) -> T {
    struct Restore(bool);
    impl Drop for Restore {
        fn drop(&mut self) {
            CANCELLATION_SUSPENDED.set(self.0);
        }
    }
    let _restore = Restore(CANCELLATION_SUSPENDED.replace(true));
    work()
}
pub fn with_deadline<T>(duration: Duration, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<Instant>);
    impl Drop for Restore {
        fn drop(&mut self) {
            END.set(self.0);
        }
    }
    let previous = END.get();
    let end = Instant::now() + duration;
    END.set(Some(previous.map_or(end, |old| old.min(end))));
    let _restore = Restore(previous);
    work()
}
pub fn check_deadline() -> Result<()> {
    budget(Duration::from_secs(120)).map(|_| ())
}
/// Reserve time before a side effect. Once started, a write owns its bounded
/// lifetime instead of inheriting a nearly exhausted presentation deadline.
pub(super) fn write_budget<T>(work: impl FnOnce() -> Result<T>) -> Result<T> {
    reserved_write_budget(Duration::from_secs(10), work)
}
fn reserved_write_budget<T>(minimum: Duration, work: impl FnOnce() -> Result<T>) -> Result<T> {
    ensure!(budget(Duration::from_secs(120))? >= minimum, "git_timeout");
    // Admission is cancellable, but an admitted write must run to its bounded
    // outcome. Killing it for read cancellation would make its outcome unknown.
    without_read_cancellation(|| fresh_deadline(Duration::from_secs(120), work))
}
pub fn fresh_deadline<T>(duration: Duration, work: impl FnOnce() -> T) -> T {
    let previous = END.replace(None);
    struct Restore(Option<Instant>);
    impl Drop for Restore {
        fn drop(&mut self) {
            END.set(self.0);
        }
    }
    let _restore = Restore(previous);
    with_deadline(duration, work)
}
pub(super) fn budget(maximum: Duration) -> Result<Duration> {
    ensure!(
        CANCELLATION_SUSPENDED.get()
            || !CANCELLED.with(|slot| slot
                .borrow()
                .as_ref()
                .is_some_and(|flag| flag.load(Ordering::SeqCst))),
        "cancelled"
    );
    if let Some(end) = END.get() {
        let remaining = end.saturating_duration_since(Instant::now());
        ensure!(!remaining.is_zero(), "git_timeout");
        Ok(maximum.min(remaining))
    } else {
        Ok(maximum)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn write_is_rejected_before_start_or_keeps_its_own_budget() {
        let started = Cell::new(false);
        let rejected = with_deadline(Duration::from_millis(20), || {
            write_budget(|| {
                started.set(true);
                Ok(())
            })
        });
        assert_eq!(rejected.unwrap_err().to_string(), "git_timeout");
        assert!(!started.get());
        with_deadline(Duration::from_millis(100), || {
            reserved_write_budget(Duration::from_millis(50), || {
                std::thread::sleep(Duration::from_millis(150));
                assert!(budget(Duration::from_secs(120))? > Duration::from_secs(100));
                Ok(())
            })
            .unwrap();
            assert_eq!(check_deadline().unwrap_err().to_string(), "git_timeout");
        });
        check_deadline().unwrap();
    }

    #[test]
    fn cancellation_refuses_admission_but_does_not_interrupt_an_admitted_write() {
        let flag = Arc::new(AtomicBool::new(false));
        with_read_cancellation(flag.clone(), || {
            write_budget(|| {
                flag.store(true, Ordering::SeqCst);
                check_deadline()?;
                write_budget(|| {
                    check_deadline()?;
                    Ok(())
                })?;
                Ok(())
            })
            .unwrap();
            assert_eq!(check_deadline().unwrap_err().to_string(), "cancelled");
            let started = Cell::new(false);
            let rejected = write_budget(|| {
                started.set(true);
                Ok(())
            });
            assert_eq!(rejected.unwrap_err().to_string(), "cancelled");
            assert!(!started.get());
        });
        check_deadline().unwrap();
    }

    #[test]
    fn nested_read_control_restores_outer_deadline_and_cancellation() {
        let flag = Arc::new(AtomicBool::new(true));
        with_read_cancellation(flag, || {
            with_read_cancellation(Arc::new(AtomicBool::new(false)), || {
                with_deadline(Duration::ZERO, || {
                    assert_eq!(check_deadline().unwrap_err().to_string(), "git_timeout");
                });
                check_deadline().unwrap();
            });
            assert_eq!(check_deadline().unwrap_err().to_string(), "cancelled");
        });
        check_deadline().unwrap();
    }
}

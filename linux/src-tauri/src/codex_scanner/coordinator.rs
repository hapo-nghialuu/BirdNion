use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::LazyLock;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static GENERATION: AtomicU64 = AtomicU64::new(0);
static ACTIVE_STATE: LazyLock<Mutex<Option<ActiveScan>>> = LazyLock::new(|| Mutex::new(None));

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveScan {
    pub generation: u64,
    pub completed: u32,
    pub total: u32,
    pub fingerprint: String,
}

pub struct EpisodeGuard;

impl Drop for EpisodeGuard {
    fn drop(&mut self) {
        *ACTIVE_STATE.lock().unwrap() = None;
    }
}

pub fn try_begin() -> Option<(u64, EpisodeGuard)> {
    // Claim and publish the episode under one lock. Joiners can therefore
    // never observe "active" without the matching generation/progress.
    let mut active_state = ACTIVE_STATE.lock().unwrap();
    if active_state.is_some() {
        return None;
    }
    // Keep the command path O(1): journal I/O and validation belong to the
    // background worker. A wall-clock floor also keeps generations monotonic
    // across process restarts without opening the journal here.
    let wall_clock_floor = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(u64::MAX as u128) as u64
        });
    let mut current = GENERATION.load(Ordering::Acquire);
    let generation = loop {
        let next = current.saturating_add(1).max(wall_clock_floor);
        match GENERATION.compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => break next,
            Err(observed) => current = observed,
        }
    };
    *active_state = Some(ActiveScan {
        generation,
        completed: 0,
        total: 0,
        fingerprint: format!("generation-{generation}"),
    });
    Some((generation, EpisodeGuard))
}

pub fn current() -> Option<ActiveScan> {
    ACTIVE_STATE.lock().unwrap().clone()
}

pub fn update(generation: u64, completed: usize, total: usize, fingerprint: String) {
    let mut state = ACTIVE_STATE.lock().unwrap();
    let Some(active) = state.as_mut() else {
        return;
    };
    if active.generation != generation {
        return;
    }
    active.completed = completed.min(u32::MAX as usize) as u32;
    active.total = total.min(u32::MAX as usize) as u32;
    active.fingerprint = fingerprint;
}

#[cfg(test)]
fn reset_for_test() {
    *ACTIVE_STATE.lock().unwrap() = None;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::LazyLock;
    use std::sync::Mutex;

    static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    #[test]
    fn concurrent_episode_is_singleflight() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_for_test();
        let first = try_begin().unwrap();
        assert!(try_begin().is_none());
        drop(first);
        assert!(try_begin().is_some());
        reset_for_test();
    }

    #[test]
    fn active_generation_is_shared_with_joiners_and_clears_after_drop() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_for_test();
        assert!(current().is_none());
        let (generation, guard) = try_begin().unwrap();
        assert_eq!(
            current(),
            Some(ActiveScan {
                generation,
                completed: 0,
                total: 0,
                fingerprint: format!("generation-{generation}"),
            })
        );
        assert!(try_begin().is_none());
        assert_eq!(current().unwrap().generation, generation);
        drop(guard);
        assert!(current().is_none());
    }

    #[test]
    fn active_progress_updates_without_creating_a_second_worker() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_for_test();
        let (generation, guard) = try_begin().unwrap();
        update(generation, 2, 5, "fp-2".into());
        assert_eq!(
            current(),
            Some(ActiveScan {
                generation,
                completed: 2,
                total: 5,
                fingerprint: "fp-2".into(),
            })
        );
        assert!(try_begin().is_none());
        drop(guard);
        reset_for_test();
    }

    #[test]
    fn episode_claim_uses_process_local_state_without_journal_seed() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_for_test();
        let before = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let (generation, guard) = try_begin().unwrap();
        assert!(generation >= before);
        drop(guard);
        reset_for_test();
    }
}

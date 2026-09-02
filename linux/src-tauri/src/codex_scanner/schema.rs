use serde::{Deserialize, Serialize};

pub const JOURNAL_VERSION: u32 = 3;
pub const JOURNAL_PRODUCER: &str = "birdnion-linux-codex-v3";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingGeneration {
    pub id: u64,
    pub completed: u32,
    pub progress_fingerprint: String,
    #[serde(default)]
    pub priority: Option<super::priority::PriorityCursor>,
    #[serde(default)]
    pub engine: Option<super::incremental::State>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommittedGeneration {
    pub id: u64,
    pub completed_at_ms: i64,
    #[serde(default)]
    pub priority: Option<super::priority::PriorityCursor>,
    #[serde(default)]
    pub engine: Option<super::incremental::State>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScanJournal {
    pub version: u32,
    pub producer: String,
    pub timezone: String,
    #[serde(default)]
    pub committed: Option<CommittedGeneration>,
    #[serde(default)]
    pub pending: Option<PendingGeneration>,
}

impl ScanJournal {
    pub fn validate(&self) -> bool {
        let valid_priority = |priority: Option<&super::priority::PriorityCursor>| {
            priority.is_none_or(|cursor| cursor.validate())
        };
        self.version == JOURNAL_VERSION
            && self.producer == JOURNAL_PRODUCER
            && self.timezone.len() <= 64
            && !self.timezone.chars().any(char::is_control)
            && self.committed.as_ref().is_none_or(|committed| {
                committed.id > 0
                    && valid_priority(committed.priority.as_ref())
                    && committed
                        .engine
                        .as_ref()
                        .is_none_or(|engine| engine.generation == committed.id && engine.validate())
            })
            && self.pending.as_ref().is_none_or(|pending| {
                pending.id > 0
                    && self
                        .committed
                        .as_ref()
                        .is_none_or(|committed| pending.id > committed.id)
                    && valid_priority(pending.priority.as_ref())
                    && pending.engine.as_ref().is_some_and(|engine| {
                        engine.generation == pending.id
                            && pending.completed as usize == engine.completed.len()
                            && pending.progress_fingerprint == engine.fingerprint
                            && engine.validate()
                    })
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_private_or_escaping_locator() {
        let build = |locator: &str| ScanJournal {
            version: JOURNAL_VERSION,
            producer: JOURNAL_PRODUCER.into(),
            timezone: "+07:00".into(),
            committed: None,
            pending: Some(PendingGeneration {
                id: 1,
                completed: 0,
                progress_fingerprint: locator.into(),
                priority: None,
                engine: Some(super::super::incremental::State::test_state(locator)),
            }),
        };
        assert!(build(&"a".repeat(64)).validate());
        assert!(!build("not-a-digest").validate());
        assert!(!build(&"g".repeat(64)).validate());
    }

    #[test]
    fn rejects_invalid_committed_priority_cursor() {
        let journal = ScanJournal {
            version: JOURNAL_VERSION,
            producer: JOURNAL_PRODUCER.into(),
            timezone: "+07:00".into(),
            committed: Some(CommittedGeneration {
                id: 1,
                completed_at_ms: 0,
                priority: Some(super::super::priority::PriorityCursor {
                    db_identity: "a".repeat(64),
                    coverage_since_epoch: 0,
                    last_rowid: 1,
                    target_rowid: 1,
                    validation_rowid: 0,
                    validation_target_rowid: 0,
                    source_digests: Default::default(),
                    anchors: vec![super::super::priority::PriorityAnchor {
                        rowid: 1,
                        digest: "b".repeat(64),
                    }],
                    turns: Default::default(),
                    request_sources: Default::default(),
                    priority_completions: [(
                        "short".into(),
                        [(1, "gpt-5".into())].into_iter().collect(),
                    )]
                    .into_iter()
                    .collect(),
                    pending_completions: Default::default(),
                    pending_order: Default::default(),
                }),
                engine: Some(super::super::incremental::State::test_state(
                    &"c".repeat(64),
                )),
            }),
            pending: None,
        };
        assert!(!journal.validate());
    }

    #[test]
    fn compact_committed_marker_is_valid_without_duplicate_engine() {
        let journal = ScanJournal {
            version: JOURNAL_VERSION,
            producer: JOURNAL_PRODUCER.into(),
            timezone: "+07:00".into(),
            committed: Some(CommittedGeneration {
                id: 7,
                completed_at_ms: 1,
                priority: None,
                engine: None,
            }),
            pending: None,
        };
        assert!(journal.validate());
    }

    #[test]
    fn pending_generation_must_match_its_engine_progress() {
        let engine = super::super::incremental::State::test_state(&"a".repeat(64));
        let journal = ScanJournal {
            version: JOURNAL_VERSION,
            producer: JOURNAL_PRODUCER.into(),
            timezone: "+07:00".into(),
            committed: None,
            pending: Some(PendingGeneration {
                id: engine.generation,
                completed: 1,
                progress_fingerprint: engine.fingerprint.clone(),
                priority: None,
                engine: Some(engine),
            }),
        };
        assert!(!journal.validate());
    }
}

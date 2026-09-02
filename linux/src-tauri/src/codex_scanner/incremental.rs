use chrono::DateTime;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::fs::{File, Metadata};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

pub(super) const MAX_PASS_TIME: Duration = Duration::from_millis(500);
pub(super) const MAX_PASS_BYTES: usize = 16 * 1024 * 1024;
pub(super) const FILE_QUANTUM: usize = 4 * 1024 * 1024;
pub(super) const MAX_DISCOVERY_ENTRIES: usize = 512;
const MAX_DEPTH: usize = 3;
const MAX_LOGICAL_LINE: usize = 256 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) enum Phase {
    Discover,
    Parse,
    Complete,
    Failed(Failure),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) enum Failure {
    RootUnavailable,
    DirectoryChanged,
    FileUnavailable,
    FileReplaced,
    InvalidLocator,
    NoProgress,
    Cycle,
    Journal,
    RecordLimit,
}

/// A path capability without a path: directories are numeric Codex date
/// components and the file is addressed by its stable sorted entry index.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct PrivateLocator {
    pub root_slot: u8,
    pub dirs: Vec<String>,
    pub entry_cookie: i64,
    pub name_hash: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct DirectoryCursor {
    pub root_slot: u8,
    pub dirs: Vec<String>,
    pub dev: u64,
    pub inode: u64,
    pub mtime_ns: i128,
    pub next_cookie: i64,
    #[serde(default)]
    pub last_entry: Option<DirectoryEntryAnchor>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct DirectoryEntryAnchor {
    pub entry_cookie: i64,
    pub name_hash: String,
    pub dev: u64,
    pub inode: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct FrozenFile {
    pub locator: PrivateLocator,
    pub dir_dev: u64,
    pub dir_inode: u64,
    pub dir_mtime_ns: i128,
    pub dev: u64,
    pub inode: u64,
    pub frozen_size: u64,
    pub frozen_mtime_ns: i128,
    pub target_eof: u64,
    pub content_anchor: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct ParsedProject {
    pub key: String,
    pub basename: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct ParsedFile {
    pub session_hash: Option<String>,
    pub fork_parent_hash: Option<String>,
    pub fork_timestamp_ms: Option<i64>,
    pub active_model: String,
    pub current_turn: Option<String>,
    pub next_sequence: u64,
    #[cfg(test)]
    #[serde(skip)]
    pub records: Vec<SafeRecord>,
}

impl Default for ParsedFile {
    fn default() -> Self {
        Self {
            session_hash: None,
            fork_parent_hash: None,
            fork_timestamp_ms: None,
            active_model: "gpt-5".into(),
            current_turn: None,
            next_sequence: 0,
            #[cfg(test)]
            records: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct FileWork {
    pub frozen: FrozenFile,
    pub committed_offset: u64,
    pub read_offset: u64,
    pub discarding_oversized_line: bool,
    pub finished: bool,
    #[serde(default)]
    pub record_generation: u64,
    pub parsed: ParsedFile,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct IncrementalState {
    pub generation: u64,
    pub modified_since_ms: Option<i64>,
    pub phase: Phase,
    pub discovery: VecDeque<DirectoryCursor>,
    #[serde(default)]
    pub sealed_directories: Vec<DirectoryCursor>,
    pub files: Vec<FileWork>,
    pub queue: VecDeque<usize>,
    pub completed: Vec<usize>,
    #[serde(default)]
    pub progress_revision: u64,
    pub fingerprint: String,
    #[serde(default)]
    pub reuse_files: Vec<FileWork>,
}

pub(super) type State = IncrementalState;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) enum SafeRecord {
    Meta {
        session: Option<String>,
        parent: Option<String>,
        timestamp_ms: Option<i64>,
        project_key: Option<String>,
        project_name: Option<String>,
        retraction_id: Option<String>,
    },
    ProjectInvalid,
    Model(String),
    CurrentTurn(String),
    Token {
        timestamp_ms: i64,
        input: i64,
        cached: i64,
        output: i64,
        total: i64,
        cumulative: Option<(i64, i64, i64, i64)>,
        turn: Option<String>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PassOutcome {
    Progress,
    Complete,
    Incomplete,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PassResult {
    pub phase: Phase,
    pub entries: usize,
    pub bytes: usize,
    pub progressed: bool,
}

impl IncrementalState {
    pub fn discover(generation: u64, roots: &[PathBuf]) -> Result<Self, Failure> {
        if roots.len() > u8::MAX as usize {
            return Err(Failure::InvalidLocator);
        }
        let mut discovery = VecDeque::new();
        for (slot, root) in roots.iter().enumerate() {
            let Ok(meta) = std::fs::metadata(root) else {
                continue;
            };
            if !meta.is_dir() {
                continue;
            }
            let (dev, inode) = identity(&meta);
            discovery.push_back(DirectoryCursor {
                root_slot: slot as u8,
                dirs: Vec::new(),
                dev,
                inode,
                mtime_ns: mtime_ns(&meta),
                next_cookie: 0,
                last_entry: None,
            });
        }
        if discovery.is_empty() {
            return Err(Failure::RootUnavailable);
        }
        let mut value = Self {
            generation,
            modified_since_ms: None,
            phase: Phase::Discover,
            discovery,
            sealed_directories: Vec::new(),
            files: Vec::new(),
            queue: VecDeque::new(),
            completed: Vec::new(),
            progress_revision: 0,
            fingerprint: String::new(),
            reuse_files: Vec::new(),
        };
        value.fingerprint = value.progress_fingerprint();
        Ok(value)
    }

    pub fn progress_fingerprint(&self) -> String {
        digest(&[
            b"codex-incremental-progress-v2",
            self.generation.to_string().as_bytes(),
            self.progress_revision.to_string().as_bytes(),
            format!("{:?}", self.phase).as_bytes(),
            self.files.len().to_string().as_bytes(),
            self.queue.len().to_string().as_bytes(),
            self.completed.len().to_string().as_bytes(),
            self.discovery.len().to_string().as_bytes(),
            self.sealed_directories.len().to_string().as_bytes(),
        ])
    }

    pub fn run_discovery_pass<F>(&mut self, roots: &[PathBuf], mut persist: F) -> PassResult
    where
        F: FnMut(&Self) -> Result<(), String>,
    {
        self.transactional_pass(|state| state.discover_inner(roots, None), &mut persist)
    }

    pub fn run_parse_pass_with_spool<F>(
        &mut self,
        roots: &[PathBuf],
        spool: &mut super::incremental_spool::Spool,
        mut persist: F,
    ) -> PassResult
    where
        F: FnMut(&Self) -> Result<(), String>,
    {
        self.transactional_pass(|state| state.parse_inner(roots, spool), &mut persist)
    }

    #[cfg(test)]
    pub fn run_parse_pass<F>(&mut self, roots: &[PathBuf], persist: F) -> PassResult
    where
        F: FnMut(&Self) -> Result<(), String>,
    {
        let mut spool = super::incremental_spool::Spool::open_memory().expect("open Codex spool");
        self.run_parse_pass_with_spool(roots, &mut spool, persist)
    }

    fn transactional_pass<F, P>(&mut self, work: F, persist: &mut P) -> PassResult
    where
        F: FnOnce(&mut Self) -> PassResult,
        P: FnMut(&Self) -> Result<(), String>,
    {
        let old_phase = self.phase.clone();
        let old_counts = (
            self.discovery.len(),
            self.files.len(),
            self.queue.len(),
            self.completed.len(),
        );
        let mut result = work(self);
        let new_counts = (
            self.discovery.len(),
            self.files.len(),
            self.queue.len(),
            self.completed.len(),
        );
        result.progressed = result.entries > 0
            || result.bytes > 0
            || self.phase != old_phase
            || new_counts != old_counts;
        if !result.progressed && !matches!(self.phase, Phase::Complete | Phase::Failed(_)) {
            self.phase = Phase::Failed(Failure::NoProgress);
        } else if result.progressed {
            self.progress_revision = self.progress_revision.saturating_add(1);
        }
        if persist(self).is_err() {
            self.phase = Phase::Failed(Failure::Journal);
        }
        self.fingerprint = self.progress_fingerprint();
        result.phase = self.phase.clone();
        result
    }

    fn discover_inner(
        &mut self,
        roots: &[PathBuf],
        mut spool: Option<&mut super::incremental_spool::Spool>,
    ) -> PassResult {
        if self.phase != Phase::Discover {
            return pass(&self.phase, 0, 0);
        }
        let started = Instant::now();
        let mut entries = 0;
        while entries < MAX_DISCOVERY_ENTRIES && started.elapsed() < MAX_PASS_TIME {
            let Some(mut cursor) = self.discovery.pop_front() else {
                break;
            };
            let Some(root) = roots.get(cursor.root_slot as usize) else {
                self.phase = Phase::Failed(Failure::RootUnavailable);
                break;
            };
            let dir = cursor
                .dirs
                .iter()
                .fold(root.clone(), |p, n| p.join(n.to_string()));
            let Ok(meta) = std::fs::metadata(&dir) else {
                self.phase = Phase::Failed(Failure::DirectoryChanged);
                break;
            };
            if identity(&meta) != (cursor.dev, cursor.inode) {
                self.phase = Phase::Failed(Failure::DirectoryChanged);
                break;
            }
            if mtime_ns(&meta) != cursor.mtime_ns {
                self.phase = Phase::Failed(Failure::DirectoryChanged);
                break;
            }
            let mut reader = match resume_directory(&dir, &cursor) {
                Ok(value) => value,
                Err(_) => {
                    self.phase = Phase::Failed(Failure::DirectoryChanged);
                    break;
                }
            };
            let mut exhausted = false;
            while entries < MAX_DISCOVERY_ENTRIES && started.elapsed() < MAX_PASS_TIME {
                let Some((cookie, name, path)) = reader.next() else {
                    exhausted = true;
                    break;
                };
                cursor.next_cookie = reader.cookie();
                entries += 1;
                let Ok(meta) = std::fs::symlink_metadata(&path) else {
                    self.phase = Phase::Failed(Failure::DirectoryChanged);
                    break;
                };
                let (entry_dev, entry_inode) = identity(&meta);
                cursor.last_entry = Some(DirectoryEntryAnchor {
                    entry_cookie: cookie,
                    name_hash: digest(&[b"codex-directory-entry-v1", name.as_bytes()]),
                    dev: entry_dev,
                    inode: entry_inode,
                });
                if meta.file_type().is_symlink() {
                    continue;
                }
                if meta.is_dir() {
                    if cursor.dirs.len() >= MAX_DEPTH {
                        continue;
                    }
                    if !valid_date_component(&name, cursor.dirs.len()) {
                        continue;
                    }
                    let mut dirs = cursor.dirs.clone();
                    dirs.push(name);
                    let (dev, inode) = identity(&meta);
                    self.discovery.push_back(DirectoryCursor {
                        root_slot: cursor.root_slot,
                        dirs,
                        dev,
                        inode,
                        mtime_ns: mtime_ns(&meta),
                        next_cookie: 0,
                        last_entry: None,
                    });
                } else if meta.is_file()
                    && name.starts_with("rollout-")
                    && name.ends_with(".jsonl")
                    && self
                        .modified_since_ms
                        .is_none_or(|cutoff| mtime_ns(&meta) >= cutoff as i128 * 1_000_000)
                {
                    let locator = PrivateLocator {
                        root_slot: cursor.root_slot,
                        dirs: cursor.dirs.clone(),
                        entry_cookie: cookie,
                        name_hash: digest(&[b"codex-rollout-name-v1", name.as_bytes()]),
                    };
                    let (dev, inode) = (entry_dev, entry_inode);
                    self.files.push(FileWork {
                        frozen: FrozenFile {
                            locator,
                            dir_dev: cursor.dev,
                            dir_inode: cursor.inode,
                            dir_mtime_ns: cursor.mtime_ns,
                            dev,
                            inode,
                            frozen_size: meta.len(),
                            frozen_mtime_ns: mtime_ns(&meta),
                            target_eof: meta.len(),
                            content_anchor: match content_anchor(&path, meta.len()) {
                                Ok(value) => value,
                                Err(_) => {
                                    self.phase = Phase::Failed(Failure::FileUnavailable);
                                    break;
                                }
                            },
                        },
                        committed_offset: 0,
                        read_offset: 0,
                        discarding_oversized_line: false,
                        finished: meta.len() == 0,
                        record_generation: self.generation,
                        parsed: ParsedFile::default(),
                    });
                }
            }
            if matches!(self.phase, Phase::Failed(_)) {
                break;
            }
            let unchanged = std::fs::metadata(&dir).is_ok_and(|meta| {
                identity(&meta) == (cursor.dev, cursor.inode) && mtime_ns(&meta) == cursor.mtime_ns
            });
            if !unchanged {
                self.phase = Phase::Failed(Failure::DirectoryChanged);
                break;
            }
            if !exhausted {
                self.discovery.push_front(cursor);
            } else {
                self.sealed_directories.push(cursor);
            }
        }
        if self.discovery.is_empty() && matches!(self.phase, Phase::Discover) {
            let inventory_unchanged = self.sealed_directories.iter().all(|cursor| {
                let Some(root) = roots.get(cursor.root_slot as usize) else {
                    return false;
                };
                let dir = cursor
                    .dirs
                    .iter()
                    .fold(root.clone(), |path, part| path.join(part));
                std::fs::metadata(dir).is_ok_and(|meta| {
                    identity(&meta) == (cursor.dev, cursor.inode)
                        && mtime_ns(&meta) == cursor.mtime_ns
                })
            });
            if !inventory_unchanged {
                self.phase = Phase::Failed(Failure::DirectoryChanged);
                return pass(&self.phase, entries, 0);
            }
            self.files.sort_by_key(|f| f.frozen.locator.clone());
            self.reuse_discovered_files(roots, spool.as_deref_mut());
            self.queue = self
                .files
                .iter()
                .enumerate()
                .filter_map(|(i, f)| (!f.finished).then_some(i))
                .collect();
            self.phase = if self.queue.is_empty() {
                Phase::Complete
            } else {
                Phase::Parse
            };
        }
        pass(&self.phase, entries, 0)
    }

    fn parse_inner(
        &mut self,
        roots: &[PathBuf],
        spool: &mut super::incremental_spool::Spool,
    ) -> PassResult {
        if self.phase != Phase::Parse {
            return pass(&self.phase, 0, 0);
        }
        let started = Instant::now();
        let mut bytes = 0;
        while bytes < MAX_PASS_BYTES && started.elapsed() < MAX_PASS_TIME {
            let Some(index) = self.queue.pop_front() else {
                self.phase = Phase::Complete;
                break;
            };
            match parse_quantum(
                &mut self.files[index],
                roots,
                MAX_PASS_BYTES - bytes,
                self.generation,
                spool,
            ) {
                Ok(read) => bytes += read,
                Err(reason) => {
                    self.phase = Phase::Failed(reason);
                    break;
                }
            }
            if !self.files[index].finished {
                self.queue.push_back(index);
            } else if !self.completed.contains(&index) {
                self.completed.push(index);
            }
            if self.queue.is_empty() {
                self.phase = Phase::Complete;
                break;
            }
        }
        pass(&self.phase, 0, bytes)
    }

    fn reuse_discovered_files(
        &mut self,
        roots: &[PathBuf],
        mut spool: Option<&mut super::incremental_spool::Spool>,
    ) {
        for file in &mut self.files {
            let Some(old) = self.reuse_files.iter().find(|old| {
                old.frozen.locator.root_slot == file.frozen.locator.root_slot
                    && old.frozen.locator.dirs == file.frozen.locator.dirs
                    && old.frozen.locator.name_hash == file.frozen.locator.name_hash
                    && old.frozen.dev == file.frozen.dev
                    && old.frozen.inode == file.frozen.inode
            }) else {
                continue;
            };
            if file.frozen.target_eof < old.committed_offset {
                continue;
            }
            let Ok((path, _)) = resolve_file(&file.frozen, roots) else {
                continue;
            };
            if content_anchor(&path, old.frozen.target_eof).ok().as_deref()
                != Some(old.frozen.content_anchor.as_str())
            {
                continue;
            }
            file.committed_offset = old.committed_offset;
            file.read_offset = old.committed_offset;
            file.parsed = old.parsed.clone();
            let _ = spool.as_deref_mut();
            file.record_generation = old.record_generation;
            file.finished = file.frozen.target_eof == old.frozen.target_eof && old.finished;
        }
        self.reuse_files.clear();
    }

    pub fn validate(&self) -> bool {
        self.generation > 0
            && is_digest(&self.fingerprint)
            && self.modified_since_ms.is_none_or(|value| value >= 0)
            && self.discovery.iter().all(valid_cursor)
            && self.sealed_directories.iter().all(valid_cursor)
            && self.files.iter().all(|file| {
                valid_locator(&file.frozen.locator)
                    && file.committed_offset <= file.read_offset
                    && file.read_offset <= file.frozen.target_eof
                    && is_digest(&file.frozen.content_anchor)
                    && valid_parsed(&file.parsed)
            })
            && self
                .reuse_files
                .iter()
                .all(|file| valid_locator(&file.frozen.locator) && valid_parsed(&file.parsed))
            && self
                .queue
                .iter()
                .chain(self.completed.iter())
                .all(|index| *index < self.files.len())
    }

    #[cfg(test)]
    pub fn test_state(locator: &str) -> Self {
        let mut state = Self {
            generation: 1,
            modified_since_ms: None,
            phase: Phase::Complete,
            discovery: VecDeque::new(),
            sealed_directories: Vec::new(),
            files: Vec::new(),
            queue: VecDeque::new(),
            completed: Vec::new(),
            progress_revision: 0,
            fingerprint: locator.into(),
            reuse_files: Vec::new(),
        };
        if is_digest(locator) {
            state.fingerprint = locator.into();
        }
        state
    }
}

pub(super) fn discover(
    generation: u64,
    roots: &[PathBuf],
    modified_since: Option<DateTime<chrono::Local>>,
) -> Result<State, Failure> {
    let mut state = State::discover(generation, roots)?;
    state.modified_since_ms = modified_since.map(|value| value.timestamp_millis());
    state.fingerprint = state.progress_fingerprint();
    Ok(state)
}

pub(super) fn hydrate(
    state: &mut State,
    roots: &[PathBuf],
    _modified_since: Option<DateTime<chrono::Local>>,
) -> bool {
    if !state.validate() {
        return false;
    }
    if state
        .files
        .iter()
        .any(|file| resolve_file(&file.frozen, roots).is_err())
    {
        return false;
    }
    state.fingerprint = state.progress_fingerprint();
    true
}

pub(super) fn refresh(
    generation: u64,
    roots: &[PathBuf],
    committed: &State,
    modified_since: Option<DateTime<chrono::Local>>,
) -> Result<State, Failure> {
    if committed.phase != Phase::Complete {
        return Err(Failure::InvalidLocator);
    }
    let mut state = State::discover(generation, roots)?;
    state.modified_since_ms = modified_since.map(|v| v.timestamp_millis());
    state.reuse_files = committed.files.clone();
    state.fingerprint = state.progress_fingerprint();
    Ok(state)
}

pub(super) fn run_pass(
    state: &mut State,
    roots: &[PathBuf],
    spool: &mut super::incremental_spool::Spool,
) -> PassOutcome {
    let result = match state.phase {
        Phase::Discover => state.transactional_pass(
            |state| state.discover_inner(roots, Some(spool)),
            &mut |_| Ok(()),
        ),
        Phase::Parse => state.run_parse_pass_with_spool(roots, spool, |_| Ok(())),
        Phase::Complete => return PassOutcome::Complete,
        Phase::Failed(_) => return PassOutcome::Incomplete,
    };
    match result.phase {
        Phase::Complete => PassOutcome::Complete,
        Phase::Failed(_) => PassOutcome::Incomplete,
        _ => PassOutcome::Progress,
    }
}

#[cfg(test)]
pub(super) fn materialize(
    state: &State,
    roots: &[PathBuf],
) -> Result<Vec<(PathBuf, Vec<SafeRecord>)>, Failure> {
    if state.phase != Phase::Complete {
        return Err(Failure::NoProgress);
    }
    state
        .files
        .iter()
        .map(|file| {
            let (path, _) = resolve_file(&file.frozen, roots)?;
            Ok((path, file.parsed.records.clone()))
        })
        .collect()
}

fn valid_cursor(cursor: &DirectoryCursor) -> bool {
    cursor.dirs.len() <= MAX_DEPTH
        && cursor
            .dirs
            .iter()
            .enumerate()
            .all(|(depth, part)| valid_date_component(part, depth))
        && cursor.next_cookie >= 0
        && cursor
            .last_entry
            .as_ref()
            .is_none_or(|entry| entry.entry_cookie >= 0 && is_digest(&entry.name_hash))
        && (cursor.next_cookie == 0 || cursor.last_entry.is_some())
}

fn valid_locator(locator: &PrivateLocator) -> bool {
    locator.dirs.len() <= MAX_DEPTH
        && locator
            .dirs
            .iter()
            .enumerate()
            .all(|(depth, part)| valid_date_component(part, depth))
        && locator.entry_cookie >= 0
        && is_digest(&locator.name_hash)
}

fn valid_date_component(value: &str, depth: usize) -> bool {
    let expected = if depth == 0 { 4 } else { 2 };
    value.len() == expected && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_parsed(parsed: &ParsedFile) -> bool {
    parsed.active_model.len() <= 160
        && parsed
            .current_turn
            .as_ref()
            .is_none_or(|value| is_digest(value))
        && parsed
            .session_hash
            .as_ref()
            .is_none_or(|value| is_digest(value))
        && parsed
            .fork_parent_hash
            .as_ref()
            .is_none_or(|value| is_digest(value))
        && parsed.next_sequence <= i64::MAX as u64
}

pub(super) fn valid_record(record: &SafeRecord) -> bool {
    match record {
        SafeRecord::Meta {
            session,
            parent,
            project_key,
            project_name,
            retraction_id,
            ..
        } => {
            session.as_ref().is_none_or(|value| is_digest(value))
                && parent.as_ref().is_none_or(|value| is_digest(value))
                && project_key.as_ref().is_none_or(|value| is_digest(value))
                && retraction_id.as_ref().is_none_or(|value| is_digest(value))
                && project_name
                    .as_ref()
                    .is_none_or(|value| value.len() <= 320 && !value.chars().any(char::is_control))
        }
        SafeRecord::ProjectInvalid => true,
        SafeRecord::Model(value) => value.len() <= 160 && !value.chars().any(char::is_control),
        SafeRecord::CurrentTurn(value) => is_digest(value),
        SafeRecord::Token { turn, .. } => turn.as_ref().is_none_or(|value| is_digest(value)),
    }
}

fn parse_quantum(
    work: &mut FileWork,
    roots: &[PathBuf],
    pass_left: usize,
    generation: u64,
    spool: &mut super::incremental_spool::Spool,
) -> Result<usize, Failure> {
    let (path, _) = resolve_file(&work.frozen, roots)?;
    let mut file = open_nofollow(&path)?;
    let meta = file.metadata().map_err(|_| Failure::FileUnavailable)?;
    let (dev, inode) = identity(&meta);
    if (dev, inode) != (work.frozen.dev, work.frozen.inode) {
        return Err(Failure::FileReplaced);
    }
    if meta.len() < work.frozen.target_eof {
        return Err(Failure::FileUnavailable);
    }
    if meta.len() == work.frozen.frozen_size && mtime_ns(&meta) != work.frozen.frozen_mtime_ns {
        return Err(Failure::FileReplaced);
    }
    if content_anchor_from_file(&mut file, work.frozen.target_eof)
        .ok()
        .as_deref()
        != Some(work.frozen.content_anchor.as_str())
    {
        return Err(Failure::FileReplaced);
    }
    let remaining = (work.frozen.target_eof - work.read_offset) as usize;
    if remaining == 0 {
        work.finished = true;
        return Ok(0);
    }
    let amount = remaining.min(FILE_QUANTUM).min(pass_left);
    if amount == 0 {
        return Ok(0);
    }
    file.seek(SeekFrom::Start(work.read_offset))
        .map_err(|_| Failure::FileUnavailable)?;
    let mut data = vec![0; amount];
    file.read_exact(&mut data)
        .map_err(|_| Failure::FileUnavailable)?;
    let at_eof = work.read_offset + amount as u64 == work.frozen.target_eof;
    if work.discarding_oversized_line {
        if let Some(pos) = data.iter().position(|b| *b == b'\n') {
            work.read_offset += pos as u64 + 1;
            work.committed_offset = work.read_offset;
            work.discarding_oversized_line = false;
            data.drain(..=pos);
        } else {
            work.read_offset += amount as u64;
            if at_eof {
                work.finished = true;
            }
            return Ok(amount);
        }
    }
    let boundary = data.iter().rposition(|b| *b == b'\n').map(|p| p + 1);
    if let Some(end) = boundary {
        let mut parsed = work.parsed.clone();
        let mut records = Vec::new();
        for line in data[..end].split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            if line.len() <= MAX_LOGICAL_LINE {
                if let Ok(value) = serde_json::from_slice::<Value>(line) {
                    parse_value_into(&mut parsed, &value, &mut records)?;
                }
            }
        }
        let key = file_key(work);
        if work.record_generation != 0 && work.record_generation != generation {
            spool
                .copy_file(work.record_generation, &key, generation, &key)
                .map_err(|_| Failure::Journal)?;
        }
        spool
            .append(generation, &key, work.parsed.next_sequence, &records)
            .map_err(|_| Failure::Journal)?;
        parsed.next_sequence = parsed
            .next_sequence
            .checked_add(records.len() as u64)
            .ok_or(Failure::Journal)?;
        work.parsed = parsed;
        work.record_generation = generation;
        #[cfg(test)]
        work.parsed.records.extend(records.iter().cloned());
        work.read_offset += end as u64;
        work.committed_offset = work.read_offset;
        if work.read_offset == work.frozen.target_eof {
            work.finished = true;
        }
    } else if at_eof {
        work.finished = true; // truncated frozen tail; boundary checkpoint is unchanged
    } else if amount > MAX_LOGICAL_LINE {
        work.read_offset += amount as u64;
        work.discarding_oversized_line = true;
    }
    Ok(amount)
}

fn parse_value_into(
    out: &mut ParsedFile,
    obj: &Value,
    records: &mut Vec<SafeRecord>,
) -> Result<(), Failure> {
    let payload = obj.get("payload");
    match obj.get("type").and_then(Value::as_str) {
        Some("session_meta") => {
            if let Some(p) = payload {
                let field =
                    |keys: &[&str]| keys.iter().find_map(|k| p.get(*k).and_then(Value::as_str));
                let raw_session = field(&["id", "session_id", "sessionId"]);
                let session = raw_session.map(session_hash);
                if out.session_hash.is_none() {
                    out.session_hash = session.clone();
                }
                if out.fork_parent_hash.is_none() {
                    out.fork_parent_hash =
                        field(&["forked_from_id", "forkedFromId"]).map(session_hash);
                    out.fork_timestamp_ms = field(&["timestamp"])
                        .or_else(|| obj.get("timestamp").and_then(Value::as_str))
                        .and_then(epoch_ms);
                }
                let incoming = field(&["cwd"]).and_then(project);
                let retraction_id = raw_session
                    .zip(incoming.as_ref())
                    .map(|(session, value)| retraction_hash(session, &value.key));
                push_record(
                    records,
                    SafeRecord::Meta {
                        session,
                        parent: out.fork_parent_hash.clone(),
                        timestamp_ms: out.fork_timestamp_ms,
                        project_key: incoming.as_ref().map(|v| v.key.clone()),
                        project_name: incoming.as_ref().map(|v| v.basename.clone()),
                        retraction_id,
                    },
                )?;
                if field(&["cwd"]).is_some() && incoming.is_none() {
                    push_record(records, SafeRecord::ProjectInvalid)?;
                }
            }
        }
        Some("turn_context") => {
            if let Some(model) = payload.and_then(|p| p.get("model")).and_then(Value::as_str) {
                out.active_model = sanitize(model, 160);
                push_record(records, SafeRecord::Model(out.active_model.clone()))?;
            }
        }
        Some("event_msg")
            if payload.and_then(|p| p.get("type")).and_then(Value::as_str)
                == Some("task_started") =>
        {
            if let Some(raw) = payload
                .and_then(|p| {
                    p.get("turn_id")
                        .or_else(|| p.get("turnId"))
                        .or_else(|| p.get("id"))
                })
                .and_then(Value::as_str)
            {
                let turn = turn_hash(raw);
                out.current_turn = Some(turn.clone());
                push_record(records, SafeRecord::CurrentTurn(turn))?;
            }
        }
        Some("event_msg") => {
            if let Some(p) =
                payload.filter(|p| p.get("type").and_then(Value::as_str) == Some("token_count"))
            {
                let Some(info) = p.get("info") else {
                    return Ok(());
                };
                let Some(last) = info.get("last_token_usage") else {
                    return Ok(());
                };
                let Some(timestamp_ms) = obj
                    .get("timestamp")
                    .and_then(Value::as_str)
                    .and_then(epoch_ms)
                else {
                    return Ok(());
                };
                let raw_turn = p
                    .get("turn_id")
                    .or_else(|| p.get("turnId"))
                    .or_else(|| p.get("id"))
                    .or_else(|| info.get("turn_id"))
                    .or_else(|| info.get("turnId"))
                    .or_else(|| info.get("id"))
                    .and_then(Value::as_str);
                let turn_hash = raw_turn.map(turn_hash).or_else(|| out.current_turn.clone());
                let (input, cached, output, total) = totals(last);
                push_record(
                    records,
                    SafeRecord::Token {
                        timestamp_ms,
                        input,
                        cached,
                        output,
                        total,
                        cumulative: info.get("total_token_usage").map(totals),
                        turn: turn_hash,
                    },
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
fn parse_value(out: &mut ParsedFile, obj: &Value) -> Result<(), Failure> {
    let mut records = Vec::new();
    parse_value_into(out, obj, &mut records)?;
    out.records.extend(records);
    Ok(())
}

fn push_record(out: &mut Vec<SafeRecord>, record: SafeRecord) -> Result<(), Failure> {
    debug_assert!(valid_record(&record));
    out.push(record);
    Ok(())
}

pub(super) fn file_key(work: &FileWork) -> String {
    locator_digest(&work.frozen.locator)
}

pub(super) fn resolved_path(work: &FileWork, roots: &[PathBuf]) -> Result<PathBuf, Failure> {
    resolve_file(&work.frozen, roots).map(|value| value.0)
}

fn resolve_file(frozen: &FrozenFile, roots: &[PathBuf]) -> Result<(PathBuf, Metadata), Failure> {
    let root = roots
        .get(frozen.locator.root_slot as usize)
        .ok_or(Failure::RootUnavailable)?;
    let dir = frozen
        .locator
        .dirs
        .iter()
        .fold(root.clone(), |p, n| p.join(n.to_string()));
    let dir_meta = std::fs::metadata(&dir).map_err(|_| Failure::DirectoryChanged)?;
    if identity(&dir_meta) != (frozen.dir_dev, frozen.dir_inode) {
        return Err(Failure::DirectoryChanged);
    }
    let path = resolve_entry(
        &dir,
        frozen.locator.entry_cookie,
        b"codex-rollout-name-v1",
        &frozen.locator.name_hash,
        frozen.dev,
        frozen.inode,
    )?;
    let meta = std::fs::symlink_metadata(&path).map_err(|_| Failure::FileUnavailable)?;
    Ok((path, meta))
}

fn resume_directory(dir: &Path, cursor: &DirectoryCursor) -> Result<CookieDir, Failure> {
    let Some(anchor) = cursor.last_entry.as_ref() else {
        return CookieDir::open(dir, 0).map_err(|_| Failure::DirectoryChanged);
    };
    let mut reader =
        CookieDir::open(dir, anchor.entry_cookie).map_err(|_| Failure::DirectoryChanged)?;
    if next_matches(
        &mut reader,
        b"codex-directory-entry-v1",
        &anchor.name_hash,
        anchor.dev,
        anchor.inode,
    )? {
        return Ok(reader);
    }
    let mut fallback = CookieDir::open(dir, 0).map_err(|_| Failure::DirectoryChanged)?;
    let started = Instant::now();
    for _ in 0..MAX_DISCOVERY_ENTRIES {
        if started.elapsed() >= MAX_PASS_TIME {
            break;
        }
        let Some((_, name, path)) = fallback.next() else {
            break;
        };
        let meta = std::fs::symlink_metadata(path).map_err(|_| Failure::DirectoryChanged)?;
        if digest(&[b"codex-directory-entry-v1", name.as_bytes()]) == anchor.name_hash
            && identity(&meta) == (anchor.dev, anchor.inode)
        {
            return Ok(fallback);
        }
    }
    Err(Failure::DirectoryChanged)
}

fn resolve_entry(
    dir: &Path,
    cookie: i64,
    domain: &[u8],
    name_hash: &str,
    dev: u64,
    inode: u64,
) -> Result<PathBuf, Failure> {
    let mut reader = CookieDir::open(dir, cookie).map_err(|_| Failure::DirectoryChanged)?;
    if let Some(path) = matching_next(&mut reader, domain, name_hash, dev, inode)? {
        return Ok(path);
    }
    let mut fallback = CookieDir::open(dir, 0).map_err(|_| Failure::DirectoryChanged)?;
    let started = Instant::now();
    for _ in 0..MAX_DISCOVERY_ENTRIES {
        if started.elapsed() >= MAX_PASS_TIME {
            break;
        }
        let Some((_, name, path)) = fallback.next() else {
            break;
        };
        let meta = std::fs::symlink_metadata(&path).map_err(|_| Failure::FileUnavailable)?;
        if digest(&[domain, name.as_bytes()]) == name_hash && identity(&meta) == (dev, inode) {
            return Ok(path);
        }
    }
    Err(Failure::FileReplaced)
}

fn next_matches(
    reader: &mut CookieDir,
    domain: &[u8],
    name_hash: &str,
    dev: u64,
    inode: u64,
) -> Result<bool, Failure> {
    Ok(matching_next(reader, domain, name_hash, dev, inode)?.is_some())
}

fn matching_next(
    reader: &mut CookieDir,
    domain: &[u8],
    name_hash: &str,
    dev: u64,
    inode: u64,
) -> Result<Option<PathBuf>, Failure> {
    let Some((_, name, path)) = reader.next() else {
        return Ok(None);
    };
    let meta = std::fs::symlink_metadata(&path).map_err(|_| Failure::FileUnavailable)?;
    Ok(
        (digest(&[domain, name.as_bytes()]) == name_hash && identity(&meta) == (dev, inode))
            .then_some(path),
    )
}

fn content_anchor(path: &Path, eof: u64) -> Result<String, Failure> {
    let mut file = open_nofollow(path)?;
    content_anchor_from_file(&mut file, eof)
}

fn content_anchor_from_file(file: &mut File, eof: u64) -> Result<String, Failure> {
    let mut hasher = Sha256::new();
    let prefix_len = eof.min(4096) as usize;
    let mut prefix = vec![0; prefix_len];
    file.read_exact(&mut prefix)
        .map_err(|_| Failure::FileUnavailable)?;
    hasher.update(&prefix);
    if eof > 4096 {
        file.seek(SeekFrom::Start(eof - 4096))
            .map_err(|_| Failure::FileUnavailable)?;
        let mut suffix = vec![0; 4096];
        file.read_exact(&mut suffix)
            .map_err(|_| Failure::FileUnavailable)?;
        hasher.update(&suffix);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn open_nofollow(path: &Path) -> Result<File, Failure> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| Failure::FileUnavailable)
}

struct CookieDir {
    raw: *mut libc::DIR,
    base: PathBuf,
    #[cfg(target_os = "macos")]
    logical_position: i64,
    #[cfg(target_os = "macos")]
    skip_remaining: i64,
}

impl CookieDir {
    fn open(path: &Path, cookie: i64) -> std::io::Result<Self> {
        use std::os::unix::ffi::OsStrExt;
        let encoded = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        let raw = unsafe { libc::opendir(encoded.as_ptr()) };
        if raw.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        #[cfg(not(target_os = "macos"))]
        if cookie != 0 {
            unsafe { libc::seekdir(raw, cookie as libc::c_long) };
        }
        Ok(Self {
            raw,
            base: path.to_path_buf(),
            #[cfg(target_os = "macos")]
            logical_position: cookie,
            #[cfg(target_os = "macos")]
            skip_remaining: cookie,
        })
    }

    fn cookie(&self) -> i64 {
        #[cfg(target_os = "macos")]
        {
            self.logical_position
        }
        #[cfg(not(target_os = "macos"))]
        {
            unsafe { libc::telldir(self.raw) as i64 }
        }
    }

    fn next(&mut self) -> Option<(i64, String, PathBuf)> {
        loop {
            #[cfg(not(target_os = "macos"))]
            let cookie = self.cookie();
            let entry = unsafe { libc::readdir(self.raw) };
            if entry.is_null() {
                return None;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            if name == "." || name == ".." {
                continue;
            }
            #[cfg(target_os = "macos")]
            if self.skip_remaining > 0 {
                self.skip_remaining -= 1;
                continue;
            }
            #[cfg(target_os = "macos")]
            let cookie = {
                let value = self.logical_position;
                self.logical_position += 1;
                value
            };
            return Some((cookie, name.clone(), self.base.join(name)));
        }
    }
}

impl Drop for CookieDir {
    fn drop(&mut self) {
        unsafe { libc::closedir(self.raw) };
    }
}

fn project(raw: &str) -> Option<ParsedProject> {
    if raw.chars().any(char::is_control) {
        return None;
    }
    let path = Path::new(raw);
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    let basename = sanitize(normalized.file_name()?.to_str()?, 80);
    if basename.is_empty() || basename == "." || basename == ".." {
        return None;
    }
    let identity = normalized.to_str()?;
    let mut hasher = Sha256::new();
    hasher.update(b"codex:cwd-v1\0");
    hasher.update(identity.as_bytes());
    Some(ParsedProject {
        key: hex::encode(hasher.finalize()),
        basename,
    })
}

fn totals(v: &Value) -> (i64, i64, i64, i64) {
    let get = |k| v.get(k).and_then(Value::as_i64).unwrap_or(0);
    (
        get("input_tokens"),
        get("cached_input_tokens"),
        get("output_tokens"),
        get("total_tokens"),
    )
}
fn epoch_ms(raw: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|v| v.timestamp_millis())
}
fn sanitize(raw: &str, max: usize) -> String {
    raw.chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect::<String>()
        .trim()
        .to_owned()
}
fn session_hash(raw: &str) -> String {
    digest(&[b"codex-session-v1", raw.as_bytes()])
}
fn turn_hash(raw: &str) -> String {
    digest(&[b"codex-priority-turn-v1", raw.as_bytes()])
}
fn retraction_hash(session: &str, project: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"codex:project-retraction-v1\0");
    hasher.update(session.as_bytes());
    hasher.update(b"\0");
    hasher.update(project.as_bytes());
    hex::encode(hasher.finalize())
}
fn locator_digest(locator: &PrivateLocator) -> String {
    digest(&[
        b"locator-v1",
        serde_json::to_string(locator)
            .unwrap_or_default()
            .as_bytes(),
    ])
}
fn digest(parts: &[&[u8]]) -> String {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
        h.update([0]);
    }
    hex::encode(h.finalize())
}
fn pass(phase: &Phase, entries: usize, bytes: usize) -> PassResult {
    PassResult {
        phase: phase.clone(),
        entries,
        bytes,
        progressed: false,
    }
}

#[cfg(unix)]
fn identity(meta: &Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev(), meta.ino())
}
#[cfg(unix)]
fn mtime_ns(meta: &Metadata) -> i128 {
    use std::os::unix::fs::MetadataExt;
    meta.mtime() as i128 * 1_000_000_000 + meta.mtime_nsec() as i128
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::fs;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
    fn temp() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "birdnion-incremental-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        p
    }
    fn line(id: usize) -> String {
        format!(
            r#"{{"timestamp":"2026-09-01T00:00:00Z","type":"event_msg","payload":{{"type":"token_count","turn_id":"turn-{id}","info":{{"last_token_usage":{{"input_tokens":1,"cached_input_tokens":0,"output_tokens":2,"total_tokens":3}}}}}}}}"#
        )
    }
    fn token_records(parsed: &ParsedFile) -> impl Iterator<Item = &SafeRecord> {
        parsed
            .records
            .iter()
            .filter(|record| matches!(record, SafeRecord::Token { .. }))
    }
    fn finish_discovery(state: &mut IncrementalState, roots: &[PathBuf]) -> usize {
        let mut passes = 0;
        while state.phase == Phase::Discover {
            state.run_discovery_pass(roots, |_| Ok(()));
            passes += 1;
            assert!(
                passes < 600,
                "phase={:?} cursors={:?}",
                state.phase,
                state.discovery
            );
        }
        passes
    }
    fn finish_parse(state: &mut IncrementalState, roots: &[PathBuf]) {
        while state.phase == Phase::Parse {
            state.run_parse_pass(roots, |_| Ok(()));
        }
    }

    #[test]
    fn discovers_513_across_passes_without_duplicates_and_privacy_leak() {
        let root = temp();
        for i in 0..513 {
            fs::write(root.join(format!("rollout-secret-{i:04}.jsonl")), line(i)).unwrap();
        }
        let mut state = IncrementalState::discover(1, std::slice::from_ref(&root)).unwrap();
        assert!(finish_discovery(&mut state, std::slice::from_ref(&root)) >= 2);
        assert_eq!(state.files.len(), 513);
        let unique = state
            .files
            .iter()
            .map(|f| f.frozen.locator.name_hash.clone())
            .collect::<BTreeSet<_>>();
        assert_eq!(unique.len(), 513);
        let json = serde_json::to_string(&state).unwrap();
        assert!(!json.contains("secret"));
        assert!(!json.contains(root.to_str().unwrap()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovery_fails_closed_when_inventory_changes_between_passes() {
        let root = temp();
        for i in 0..513 {
            fs::write(root.join(format!("rollout-{i:04}.jsonl")), line(i)).unwrap();
        }
        let mut state = IncrementalState::discover(1, std::slice::from_ref(&root)).unwrap();
        state.run_discovery_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(state.phase, Phase::Discover);
        fs::write(root.join("rollout-new.jsonl"), line(999)).unwrap();
        state.run_discovery_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(state.phase, Phase::Failed(Failure::DirectoryChanged));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn corpus_above_previous_file_ceiling_completes() {
        let root = temp();
        fs::write(root.join("rollout-boundary.jsonl"), []).unwrap();
        let mut template = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut template, std::slice::from_ref(&root));
        let mut state = discover(2, std::slice::from_ref(&root), None).unwrap();
        state.files = vec![template.files[0].clone(); 32_768];
        state.discover_inner(std::slice::from_ref(&root), None);
        assert_eq!(state.phase, Phase::Complete);
        assert_eq!(state.files.len(), 32_769);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persisted_discovery_uses_its_original_cutoff_across_restart() {
        let root = temp();
        for i in 0..513 {
            fs::write(root.join(format!("rollout-{i:04}.jsonl")), line(i)).unwrap();
        }
        let cutoff = DateTime::parse_from_rfc3339("2026-09-01T00:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Local);
        let mut state = discover(1, std::slice::from_ref(&root), Some(cutoff)).unwrap();
        state.run_discovery_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(state.phase, Phase::Discover);
        let bytes = serde_json::to_vec(&state).unwrap();

        let mut plus_millisecond: State = serde_json::from_slice(&bytes).unwrap();
        assert!(hydrate(
            &mut plus_millisecond,
            std::slice::from_ref(&root),
            Some(cutoff + chrono::Duration::milliseconds(1)),
        ));

        let mut plus_day: State = serde_json::from_slice(&bytes).unwrap();
        assert!(hydrate(
            &mut plus_day,
            std::slice::from_ref(&root),
            Some(cutoff + chrono::Duration::days(1)),
        ));
        finish_discovery(&mut plus_day, std::slice::from_ref(&root));
        assert_eq!(plus_day.files.len(), 513);
        assert_eq!(plus_day.modified_since_ms, Some(cutoff.timestamp_millis()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persisted_directory_cookie_is_verified_with_identity_fallback() {
        let root = temp();
        for i in 0..513 {
            fs::write(root.join(format!("rollout-{i:04}.jsonl")), line(i)).unwrap();
        }
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        state.run_discovery_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(state.phase, Phase::Discover);
        let bytes = serde_json::to_vec(&state).unwrap();

        let mut portable: State = serde_json::from_slice(&bytes).unwrap();
        portable.discovery[0]
            .last_entry
            .as_mut()
            .unwrap()
            .entry_cookie = i64::MAX / 2;
        finish_discovery(&mut portable, std::slice::from_ref(&root));
        assert_eq!(portable.phase, Phase::Parse);
        assert_eq!(portable.files.len(), 513);

        let mut invalid: State = serde_json::from_slice(&bytes).unwrap();
        invalid.discovery[0].last_entry.as_mut().unwrap().name_hash = digest(&[b"missing-entry"]);
        invalid.run_discovery_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(invalid.phase, Phase::Failed(Failure::DirectoryChanged));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restart_roundtrip_resumes_parse_and_freezes_eof() {
        let root = temp();
        let path = root.join("rollout-private.jsonl");
        fs::write(&path, format!("{}\n", line(1))).unwrap();
        let mut state = IncrementalState::discover(1, std::slice::from_ref(&root)).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(format!("{}\n", line(2)).as_bytes())
            .unwrap();
        let bytes = serde_json::to_vec(&state).unwrap();
        let mut resumed: IncrementalState = serde_json::from_slice(&bytes).unwrap();
        finish_parse(&mut resumed, std::slice::from_ref(&root));
        assert_eq!(resumed.files[0].parsed.next_sequence, 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn manifest_survives_new_directory_entry_until_next_generation() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        fs::write(root.join("rollout-b.jsonl"), format!("{}\n", line(2))).unwrap();
        finish_parse(&mut state, std::slice::from_ref(&root));
        assert_eq!(state.phase, Phase::Complete);
        assert_eq!(
            materialize(&state, std::slice::from_ref(&root))
                .unwrap()
                .len(),
            1
        );

        let mut next = refresh(2, std::slice::from_ref(&root), &state, None).unwrap();
        finish_discovery(&mut next, std::slice::from_ref(&root));
        assert_eq!(next.files.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn more_than_legacy_record_cap_converges_without_dropping() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        state.files[0].parsed.next_sequence = 262_144;
        let mut spool = super::super::incremental_spool::Spool::open_memory().unwrap();
        state.parse_inner(std::slice::from_ref(&root), &mut spool);
        assert_eq!(state.phase, Phase::Complete);
        assert_eq!(state.files[0].parsed.next_sequence, 262_145);
        assert_eq!(spool.count(1, &file_key(&state.files[0])), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn replacement_and_directory_mutation_fail_closed() {
        let root = temp();
        let path = root.join("rollout-a.jsonl");
        fs::write(&path, format!("{}\n", line(1))).unwrap();
        let mut replaced = IncrementalState::discover(1, std::slice::from_ref(&root)).unwrap();
        finish_discovery(&mut replaced, std::slice::from_ref(&root));
        fs::remove_file(&path).unwrap();
        fs::write(&path, format!("{}\n", line(2))).unwrap();
        replaced.run_parse_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert!(matches!(replaced.phase, Phase::Failed(_)));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn no_progress_and_refresh_are_deterministic() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let mut state = IncrementalState::discover(1, std::slice::from_ref(&root)).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        finish_parse(&mut state, std::slice::from_ref(&root));
        let mut warm = refresh(2, std::slice::from_ref(&root), &state, None).unwrap();
        finish_discovery(&mut warm, std::slice::from_ref(&root));
        assert_eq!(
            warm.files
                .iter()
                .map(|f| &f.frozen.locator)
                .collect::<Vec<_>>(),
            state
                .files
                .iter()
                .map(|f| &f.frozen.locator)
                .collect::<Vec<_>>()
        );
        let mut stalled = warm.clone();
        stalled.queue.clear();
        stalled.run_parse_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert_eq!(stalled.phase, Phase::Complete);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_secondary_root_is_skipped() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let missing = root.join("archived_sessions");
        let mut state = discover(1, &[root.clone(), missing], None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        assert_eq!(state.files.len(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn valid_json_without_newline_does_not_commit() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), line(1)).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        finish_parse(&mut state, std::slice::from_ref(&root));
        assert_eq!(state.files[0].committed_offset, 0);
        assert_eq!(token_records(&state.files[0].parsed).count(), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn warm_refresh_discovers_new_file_and_reads_only_append() {
        let root = temp();
        let first = root.join("rollout-a.jsonl");
        fs::write(&first, format!("{}\n", line(1))).unwrap();
        let mut committed = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut committed, std::slice::from_ref(&root));
        finish_parse(&mut committed, std::slice::from_ref(&root));
        fs::OpenOptions::new()
            .append(true)
            .open(&first)
            .unwrap()
            .write_all(format!("{}\n", line(2)).as_bytes())
            .unwrap();
        fs::write(root.join("rollout-b.jsonl"), format!("{}\n", line(3))).unwrap();
        let mut next = refresh(2, std::slice::from_ref(&root), &committed, None).unwrap();
        finish_discovery(&mut next, std::slice::from_ref(&root));
        finish_parse(&mut next, std::slice::from_ref(&root));
        assert_eq!(next.files.len(), 2);
        assert_eq!(
            next.files
                .iter()
                .map(|file| token_records(&file.parsed).count())
                .sum::<usize>(),
            3,
            "phase={:?} files={:?}",
            next.phase,
            next.files
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restart_preserves_refresh_reuse_candidates() {
        let root = temp();
        let path = root.join("rollout-a.jsonl");
        fs::write(&path, format!("{}\n", line(1))).unwrap();
        let mut committed = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut committed, std::slice::from_ref(&root));
        finish_parse(&mut committed, std::slice::from_ref(&root));
        for i in 0..512 {
            fs::write(root.join(format!("ignored-{i:04}")), []).unwrap();
        }

        let pending = refresh(2, std::slice::from_ref(&root), &committed, None).unwrap();
        let bytes = serde_json::to_vec(&pending).unwrap();
        let mut resumed: State = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(resumed.reuse_files.len(), 1);
        assert!(hydrate(&mut resumed, std::slice::from_ref(&root), None));
        finish_discovery(&mut resumed, std::slice::from_ref(&root));
        assert_eq!(resumed.files.len(), 1);
        assert_eq!(
            resumed.files[0].committed_offset,
            committed.files[0].committed_offset
        );
        assert_eq!(
            resumed.files[0].parsed.next_sequence,
            committed.files[0].parsed.next_sequence
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn same_inode_same_size_rewrite_does_not_reuse_committed_records() {
        let root = temp();
        let path = root.join("rollout-a.jsonl");
        fs::write(&path, format!("{}\n", line(1))).unwrap();
        let mut committed = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut committed, std::slice::from_ref(&root));
        finish_parse(&mut committed, std::slice::from_ref(&root));

        fs::write(&path, format!("{}\n", line(9))).unwrap();
        let mut next = refresh(2, std::slice::from_ref(&root), &committed, None).unwrap();
        finish_discovery(&mut next, std::slice::from_ref(&root));
        assert_eq!(next.files[0].read_offset, 0);
        finish_parse(&mut next, std::slice::from_ref(&root));
        let expected_turn = turn_hash("turn-9");
        assert!(token_records(&next.files[0].parsed).any(|record| {
            matches!(record, SafeRecord::Token { turn: Some(turn), .. } if turn == &expected_turn)
        }));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cutoff_and_leading_zero_date_directory_are_preserved() {
        let root = temp();
        let dated = root.join("2026/09/02");
        fs::create_dir_all(&dated).unwrap();
        fs::write(dated.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let future = chrono::Local::now() + chrono::Duration::days(1);
        let mut excluded = discover(1, std::slice::from_ref(&root), Some(future)).unwrap();
        finish_discovery(&mut excluded, std::slice::from_ref(&root));
        assert!(excluded.files.is_empty());
        let mut included = discover(2, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut included, std::slice::from_ref(&root));
        assert_eq!(included.files[0].frozen.locator.dirs, ["2026", "09", "02"]);
        finish_parse(&mut included, std::slice::from_ref(&root));
        assert_eq!(token_records(&included.files[0].parsed).count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn oversized_complete_line_is_discarded_but_following_event_survives() {
        let root = temp();
        let mut content = vec![b' '; 300 * 1024];
        content.push(b'\n');
        content.extend_from_slice(line(1).as_bytes());
        content.push(b'\n');
        fs::write(root.join("rollout-a.jsonl"), content).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        finish_parse(&mut state, std::slice::from_ref(&root));
        assert_eq!(token_records(&state.files[0].parsed).count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn line_larger_than_quantum_discards_then_converges() {
        let root = temp();
        let mut content = vec![b'x'; FILE_QUANTUM + 17];
        content.push(b'\n');
        content.extend_from_slice(line(7).as_bytes());
        content.push(b'\n');
        fs::write(root.join("rollout-a.jsonl"), content).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        finish_parse(&mut state, std::slice::from_ref(&root));
        assert_eq!(token_records(&state.files[0].parsed).count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pass_budgets_and_fifo_quantum_are_enforced() {
        let root = temp();
        for index in 0..4 {
            let mut content = vec![b'x'; FILE_QUANTUM + 128];
            content.push(b'\n');
            fs::write(root.join(format!("rollout-{index}.jsonl")), content).unwrap();
        }
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        let result = state.run_parse_pass(std::slice::from_ref(&root), |_| Ok(()));
        assert!(result.bytes <= MAX_PASS_BYTES);
        assert!(state
            .files
            .iter()
            .all(|file| file.read_offset <= FILE_QUANTUM as u64));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn valid_line_at_pass_byte_boundary_is_retried_not_discarded() {
        let root = temp();
        let mut valid = line(99).into_bytes();
        valid.resize(200 * 1024, b' ');
        valid.push(b'\n');
        fs::write(root.join("rollout-a.jsonl"), valid).unwrap();

        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        let mut spool = super::super::incremental_spool::Spool::open_memory().unwrap();
        let first = parse_quantum(
            &mut state.files[0],
            std::slice::from_ref(&root),
            100 * 1024,
            state.generation,
            &mut spool,
        )
        .unwrap();
        assert_eq!(first, 100 * 1024);
        let target = &state.files[0];
        assert_eq!(target.read_offset, 0);
        assert!(!target.discarding_oversized_line);

        parse_quantum(
            &mut state.files[0],
            std::slice::from_ref(&root),
            FILE_QUANTUM,
            state.generation,
            &mut spool,
        )
        .unwrap();
        let target = &state.files[0];
        assert_eq!(token_records(&target.parsed).count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn task_started_and_project_conflict_keep_ordered_safe_records() {
        let mut parsed = ParsedFile::default();
        parse_value(
            &mut parsed,
            &serde_json::json!({"type":"session_meta","payload":{
            "id":"session-private","timestamp":"2026-09-01T00:00:00Z","cwd":"/work/alpha"}}),
        )
        .unwrap();
        parse_value(
            &mut parsed,
            &serde_json::json!({"type":"event_msg","payload":{
            "type":"task_started","turn_id":"turn-private"}}),
        )
        .unwrap();
        parse_value(
            &mut parsed,
            &serde_json::from_str::<Value>(&line(1)).unwrap(),
        )
        .unwrap();
        parse_value(
            &mut parsed,
            &serde_json::json!({"type":"session_meta","payload":{
            "id":"session-private","timestamp":"2026-09-01T00:00:00Z","cwd":"/work/beta"}}),
        )
        .unwrap();
        assert!(matches!(parsed.records[1], SafeRecord::CurrentTurn(_)));
        let projects = parsed
            .records
            .iter()
            .filter_map(|record| match record {
                SafeRecord::Meta {
                    project_key: Some(key),
                    ..
                } => Some(key),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(projects.len(), 2);
        assert_ne!(projects[0], projects[1]);
        let json = serde_json::to_string(&parsed).unwrap();
        assert!(!json.contains("session-private"));
        assert!(!json.contains("turn-private"));
        assert!(!json.contains("/work/"));
    }

    #[test]
    fn queue_rotation_does_not_change_progress_fingerprint() {
        let root = temp();
        for index in 0..2 {
            fs::write(
                root.join(format!("rollout-{index}.jsonl")),
                format!("{}\n", line(index)),
            )
            .unwrap();
        }
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        let before = state.progress_fingerprint();
        state.queue.rotate_left(1);
        assert_eq!(state.progress_fingerprint(), before);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn progress_fingerprint_excludes_parsed_payload() {
        let root = temp();
        fs::write(root.join("rollout-a.jsonl"), format!("{}\n", line(1))).unwrap();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        finish_discovery(&mut state, std::slice::from_ref(&root));
        let before = state.progress_fingerprint();
        state.files[0]
            .parsed
            .records
            .extend(std::iter::repeat_n(SafeRecord::ProjectInvalid, 100_000));
        assert_eq!(state.progress_fingerprint(), before);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn no_progress_terminates_episode() {
        let root = temp();
        let mut state = discover(1, std::slice::from_ref(&root), None).unwrap();
        let result = state.transactional_pass(|value| pass(&value.phase, 0, 0), &mut |_| Ok(()));
        assert_eq!(result.phase, Phase::Failed(Failure::NoProgress));
        fs::remove_dir_all(root).unwrap();
    }
}

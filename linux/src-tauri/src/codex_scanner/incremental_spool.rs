use rusqlite::{params, Connection, OpenFlags};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::incremental::SafeRecord;
use super::{CodexFileScan, CodexTokenEvent, CodexTotals, ProjectIdentity};

const DB_NAME: &str = "codex-scan-spool.sqlite";

pub(super) struct Spool {
    connection: Connection,
}

impl Spool {
    #[cfg(test)]
    pub(super) fn open_memory() -> Result<Self, String> {
        let connection = Connection::open_in_memory().map_err(|error| error.to_string())?;
        Self::initialize(connection, None)
    }

    pub(super) fn open_default() -> Result<Self, String> {
        let directory = crate::config::support_dir().ok_or("Codex spool path unavailable")?;
        fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        Self::open(&directory.join(DB_NAME))
    }

    pub(super) fn open(path: &Path) -> Result<Self, String> {
        let parent = path.parent().ok_or("Codex spool parent unavailable")?;
        let file_name = path.file_name().ok_or("Codex spool name unavailable")?;
        // Resolve existing parent aliases (notably macOS /var -> /private/var)
        // before SQLITE_OPEN_NOFOLLOW. The final database component remains
        // un-followed and is identity-checked across sqlite3_open_v2.
        let opened_path = parent
            .canonicalize()
            .map_err(|error| error.to_string())?
            .join(file_name);
        match fs::symlink_metadata(&opened_path) {
            Ok(metadata) if !metadata.file_type().is_file() => {
                return Err("Codex spool must be a regular file".into());
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                create_private_file(&opened_path)?;
            }
            Err(error) => return Err(error.to_string()),
        }
        let expected =
            file_identity(&fs::symlink_metadata(&opened_path).map_err(|error| error.to_string())?);
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NOFOLLOW;
        let connection =
            Connection::open_with_flags(&opened_path, flags).map_err(|error| error.to_string())?;
        let current = fs::symlink_metadata(&opened_path).map_err(|error| error.to_string())?;
        if !current.file_type().is_file() || file_identity(&current) != expected {
            return Err("Codex spool changed while opening".into());
        }
        Self::initialize(connection, Some(&opened_path))
    }

    fn initialize(connection: Connection, path: Option<&Path>) -> Result<Self, String> {
        connection
            .busy_timeout(Duration::from_millis(250))
            .map_err(|error| error.to_string())?;
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA synchronous=FULL;
                 PRAGMA temp_store=FILE;
                 CREATE TABLE IF NOT EXISTS records (
                   generation INTEGER NOT NULL,
                   file_key TEXT NOT NULL,
                   sequence INTEGER NOT NULL,
                   payload BLOB NOT NULL,
                   PRIMARY KEY (generation, file_key, sequence)
                 ) WITHOUT ROWID;
                 CREATE INDEX IF NOT EXISTS records_by_file
                   ON records(generation, file_key, sequence);",
            )
            .map_err(|error| error.to_string())?;
        if let Some(path) = path {
            set_private_permissions(path)?;
        }
        Ok(Self { connection })
    }

    pub(super) fn append(
        &mut self,
        generation: u64,
        file_key: &str,
        start_sequence: u64,
        records: &[SafeRecord],
    ) -> Result<(), String> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|error| error.to_string())?;
        {
            let mut statement = transaction
                .prepare_cached(
                    "INSERT OR IGNORE INTO records(generation,file_key,sequence,payload)
                     VALUES (?1,?2,?3,?4)",
                )
                .map_err(|error| error.to_string())?;
            for (offset, record) in records.iter().enumerate() {
                let sequence = start_sequence
                    .checked_add(offset as u64)
                    .ok_or("Codex spool sequence overflow")?;
                let payload = serde_json::to_vec(record).map_err(|error| error.to_string())?;
                statement
                    .execute(params![
                        generation as i64,
                        file_key,
                        sequence as i64,
                        payload
                    ])
                    .map_err(|error| error.to_string())?;
            }
        }
        transaction.commit().map_err(|error| error.to_string())
    }

    pub(super) fn copy_file(
        &self,
        source_generation: u64,
        source_key: &str,
        generation: u64,
        file_key: &str,
    ) -> Result<(), String> {
        self.connection
            .execute(
                "INSERT OR IGNORE INTO records(generation,file_key,sequence,payload)
                 SELECT ?3,?4,sequence,payload FROM records
                 WHERE generation=?1 AND file_key=?2",
                params![
                    source_generation as i64,
                    source_key,
                    generation as i64,
                    file_key
                ],
            )
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    pub(super) fn for_each_file<F>(
        &self,
        generation: u64,
        file_key: &str,
        mut consume: F,
    ) -> Result<(), String>
    where
        F: FnMut(SafeRecord) -> Result<(), String>,
    {
        let mut statement = self
            .connection
            .prepare_cached(
                "SELECT payload FROM records WHERE generation=?1 AND file_key=?2 ORDER BY sequence",
            )
            .map_err(|error| error.to_string())?;
        let mut rows = statement
            .query(params![generation as i64, file_key])
            .map_err(|error| error.to_string())?;
        while let Some(row) = rows.next().map_err(|error| error.to_string())? {
            let payload: Vec<u8> = row.get(0).map_err(|error| error.to_string())?;
            let record = serde_json::from_slice(&payload).map_err(|error| error.to_string())?;
            consume(record)?;
        }
        Ok(())
    }

    pub(super) fn stream_file<F>(
        &self,
        generation: u64,
        file_key: &str,
        deadline: Instant,
        mut consume: F,
    ) -> Result<(), String>
    where
        F: FnMut(CodexTokenEvent) -> Result<(), String>,
    {
        let mut model = String::from("gpt-5");
        let mut current_turn = None;
        self.for_each_file(generation, file_key, |record| {
            if Instant::now() >= deadline {
                return Err("Codex aggregation deadline exceeded".into());
            }
            match record {
                SafeRecord::Model(value) => model = value,
                SafeRecord::CurrentTurn(value) => current_turn = Some(value),
                SafeRecord::Token {
                    timestamp_ms,
                    input,
                    cached,
                    output,
                    total,
                    cumulative,
                    turn,
                } => {
                    use chrono::TimeZone;
                    let Some(ts) = chrono::Local.timestamp_millis_opt(timestamp_ms).single() else {
                        return Ok(());
                    };
                    consume(CodexTokenEvent {
                        ts,
                        model: model.clone(),
                        last: CodexTotals {
                            input,
                            cached,
                            output,
                            total,
                        },
                        total: cumulative.map(|value| CodexTotals {
                            input: value.0,
                            cached: value.1,
                            output: value.2,
                            total: value.3,
                        }),
                        turn_hash: turn.or_else(|| current_turn.clone()),
                    })?;
                }
                _ => {}
            }
            Ok(())
        })
    }

    pub(super) fn summarize_file(
        &self,
        generation: u64,
        file_key: String,
        deadline: Instant,
    ) -> Result<FileSummary, String> {
        let mut scan = CodexFileScan::default();
        let mut token_count = 0_u64;
        let mut retraction_token_count = None;
        self.for_each_file(generation, &file_key, |record| {
            if Instant::now() >= deadline {
                return Err("Codex aggregation deadline exceeded".into());
            }
            match &record {
                SafeRecord::Meta {
                    project_key,
                    project_name,
                    ..
                } => {
                    let incoming =
                        project_key
                            .as_ref()
                            .zip(project_name.as_ref())
                            .map(|(key, name)| ProjectIdentity {
                                key: key.clone(),
                                display_name: name.clone(),
                            });
                    let invalid = incoming.is_none();
                    let conflicts = matches!(
                        (scan.project.as_ref(), incoming.as_ref()),
                        (Some(current), Some(next)) if current.key != next.key
                    ) || (scan.project.is_some() && invalid);
                    if retraction_token_count.is_none()
                        && !scan.project_ambiguous
                        && (invalid || conflicts)
                    {
                        retraction_token_count = Some(token_count);
                    }
                    let mut model = String::new();
                    let mut turn = None;
                    super::apply_safe_record(&mut scan, &mut model, &mut turn, &record);
                }
                SafeRecord::ProjectInvalid => {
                    if retraction_token_count.is_none()
                        && !scan.project_ambiguous
                        && scan.project.is_some()
                    {
                        retraction_token_count = Some(token_count);
                    }
                    super::update_file_project(&mut scan, None);
                }
                SafeRecord::Token { .. } => token_count += 1,
                _ => {}
            }
            Ok(())
        })?;
        let retraction_source = retraction_token_count.map(|limit| RetractionSource {
            generation,
            file_key: file_key.clone(),
            token_limit: limit,
            retraction_id: scan.precomputed_retraction_id.clone(),
        });
        Ok(FileSummary {
            generation,
            file_key,
            session_id: scan.session_id,
            forked_from_id: scan.forked_from_id,
            fork_ts: scan.fork_ts,
            project: scan.project,
            project_ambiguous: scan.project_ambiguous,
            retraction_project: scan.retraction_project,
            retraction_source,
            precomputed_retraction_id: scan.precomputed_retraction_id,
            token_count,
        })
    }

    pub(super) fn prune_unreferenced(
        &mut self,
        retained: &std::collections::HashSet<(u64, String)>,
    ) -> Result<(), String> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let files = {
            let mut statement = transaction
                .prepare("SELECT DISTINCT generation, file_key FROM records")
                .map_err(|error| error.to_string())?;
            let values = statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| error.to_string())?;
            values
        };
        for (generation, file_key) in files {
            if generation >= 0 && !retained.contains(&(generation as u64, file_key.clone())) {
                transaction
                    .execute(
                        "DELETE FROM records WHERE generation=?1 AND file_key=?2",
                        params![generation, file_key],
                    )
                    .map_err(|error| error.to_string())?;
            }
        }
        transaction.commit().map_err(|error| error.to_string())
    }

    #[cfg(test)]
    pub(super) fn count(&self, generation: u64, file_key: &str) -> usize {
        self.connection
            .query_row(
                "SELECT count(*) FROM records WHERE generation=?1 AND file_key=?2",
                params![generation as i64, file_key],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or_default() as usize
    }
}

pub(super) struct RetractionSource {
    pub generation: u64,
    pub file_key: String,
    pub token_limit: u64,
    pub retraction_id: Option<String>,
}

pub(super) struct FileSummary {
    pub generation: u64,
    pub file_key: String,
    pub session_id: Option<String>,
    pub forked_from_id: Option<String>,
    pub fork_ts: Option<chrono::DateTime<chrono::Local>>,
    pub project: Option<ProjectIdentity>,
    pub project_ambiguous: bool,
    pub retraction_project: Option<ProjectIdentity>,
    pub retraction_source: Option<RetractionSource>,
    pub precomputed_retraction_id: Option<String>,
    pub token_count: u64,
}

#[cfg(unix)]
fn file_identity(metadata: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
fn file_identity(metadata: &fs::Metadata) -> (u64, u64) {
    (metadata.len(), 0)
}

#[cfg(unix)]
fn create_private_file(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn create_private_file(path: &Path) -> Result<(), String> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[cfg(unix)]
fn set_private_permissions(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn set_private_permissions(_path: &Path) -> Result<(), String> {
    Ok(())
}

pub(super) fn path() -> Option<PathBuf> {
    crate::config::support_dir().map(|directory| directory.join(DB_NAME))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_is_idempotent_and_streamed_in_sequence() {
        let mut spool = Spool::open_memory().unwrap();
        let rows = vec![
            SafeRecord::ProjectInvalid,
            SafeRecord::Model("gpt-5".into()),
        ];
        spool.append(7, "file", 0, &rows).unwrap();
        spool.append(7, "file", 0, &rows).unwrap();
        assert_eq!(spool.count(7, "file"), 2);
        let mut observed = Vec::new();
        spool
            .for_each_file(7, "file", |record| {
                observed.push(record);
                Ok(())
            })
            .unwrap();
        assert_eq!(observed, rows);
    }

    #[test]
    fn aggregation_stream_obeys_expired_deadline() {
        let mut spool = Spool::open_memory().unwrap();
        spool
            .append(7, "file", 0, &[SafeRecord::Model("gpt-5".into())])
            .unwrap();
        let result = spool.stream_file(7, "file", Instant::now(), |_| Ok(()));
        assert!(result.is_err());
    }

    #[test]
    fn committed_batch_survives_reopen_and_replay() {
        let directory =
            std::env::temp_dir().join(format!("birdnion-spool-restart-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        let path = directory.join("spool.sqlite");
        let rows = vec![
            SafeRecord::ProjectInvalid,
            SafeRecord::Model("gpt-5".into()),
        ];
        {
            let mut spool = Spool::open(&path).unwrap();
            spool.append(9, "file", 0, &rows).unwrap();
        }
        {
            let mut spool = Spool::open(&path).unwrap();
            spool.append(9, "file", 0, &rows).unwrap();
            assert_eq!(spool.count(9, "file"), 2);
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pruning_keeps_only_referenced_generation_file_pairs() {
        let mut spool = Spool::open_memory().unwrap();
        let row = [SafeRecord::ProjectInvalid];
        spool.append(1, "keep", 0, &row).unwrap();
        spool.append(1, "stale", 0, &row).unwrap();
        spool.append(2, "keep", 0, &row).unwrap();

        spool
            .prune_unreferenced(&[(1, "keep".to_string())].into_iter().collect())
            .unwrap();

        assert_eq!(spool.count(1, "keep"), 1);
        assert_eq!(spool.count(1, "stale"), 0);
        assert_eq!(spool.count(2, "keep"), 0);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_and_uses_private_mode() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let directory =
            std::env::temp_dir().join(format!("birdnion-spool-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        let target = directory.join("target");
        fs::write(&target, b"").unwrap();
        let link = directory.join("link");
        symlink(&target, &link).unwrap();
        assert!(Spool::open(&link).is_err());

        let path = directory.join("private.sqlite");
        let mut spool = Spool::open(&path).unwrap();
        spool
            .append(1, "file", 0, &[SafeRecord::ProjectInvalid])
            .unwrap();
        for candidate in [
            path.clone(),
            PathBuf::from(format!("{}-wal", path.display())),
            PathBuf::from(format!("{}-shm", path.display())),
        ] {
            if candidate.exists() {
                assert_eq!(
                    fs::metadata(candidate).unwrap().permissions().mode() & 0o777,
                    0o600
                );
            }
        }
        fs::remove_dir_all(directory).unwrap();
    }
}

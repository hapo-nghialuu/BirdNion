use super::schema::ScanJournal;
use std::io::{self, Write};
use std::path::PathBuf;

const MAX_BYTES: u64 = 64 * 1024 * 1024;

pub fn path() -> Option<PathBuf> {
    crate::config::support_dir().map(|dir| dir.join("codex-scan-journal.json"))
}

pub fn load() -> Option<ScanJournal> {
    let path = path()?;
    let metadata = std::fs::symlink_metadata(&path).ok()?;
    if !metadata.file_type().is_file() || metadata.len() > MAX_BYTES {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    let journal: ScanJournal = serde_json::from_slice(&bytes).ok()?;
    journal.validate().then_some(journal)
}

pub fn save(journal: &ScanJournal) -> Result<(), String> {
    if !journal.validate() {
        return Err("invalid Codex scan journal".into());
    }
    let path = path().ok_or("Codex scan journal path unavailable")?;
    let mut bytes = LimitedBuffer::new(MAX_BYTES as usize);
    serde_json::to_writer(&mut bytes, journal).map_err(|error| {
        if bytes.exceeded {
            "Codex scan journal exceeds 64 MiB".into()
        } else {
            error.to_string()
        }
    })?;
    crate::platform::atomic_file::write_private_atomic(&path, &bytes)
        .map_err(|error| error.to_string())
}

struct LimitedBuffer {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}

impl LimitedBuffer {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(limit.min(1024 * 1024)),
            limit,
            exceeded: false,
        }
    }
}

impl Write for LimitedBuffer {
    fn write(&mut self, input: &[u8]) -> io::Result<usize> {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        if input.len() > remaining {
            self.exceeded = true;
            return Err(io::Error::new(
                io::ErrorKind::FileTooLarge,
                "Codex scan journal exceeds size limit",
            ));
        }
        self.bytes.extend_from_slice(input);
        Ok(input.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl std::ops::Deref for LimitedBuffer {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_serializer_stops_allocating_at_the_limit() {
        let mut output = LimitedBuffer::new(8);
        output.write_all(b"12345678").unwrap();
        let error = output.write_all(b"9").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::FileTooLarge);
        assert!(output.exceeded);
        assert_eq!(output.len(), 8);
    }
}

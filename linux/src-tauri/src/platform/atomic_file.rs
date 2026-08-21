use std::{
    ffi::OsString,
    fs::File,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

const STALE_TEMP_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_STALE_TEMPS_PER_WRITE: usize = 16;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub fn write_private_atomic(path: &Path, contents: &[u8]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "atomic file path has no parent",
        )
    })?;
    ensure_private_directory(parent)?;
    cleanup_stale_temps(path);

    let (temp, mut file) = create_temp(path)?;
    let mut guard = TempGuard(Some(temp.clone()));
    file.write_all(contents)?;
    file.sync_all()?;
    drop(file);

    replace_same_directory(&temp, path)?;
    guard.0 = None;
    sync_parent(parent)?;
    Ok(())
}

pub fn ensure_private_directory(path: &Path) -> io::Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    super::atomic_file_windows::set_private_directory_acl(path)?;
    Ok(())
}

pub fn write_private_json_atomic<T>(path: &Path, contents: &[u8]) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    match std::fs::read(path) {
        Ok(existing) => serde_json::from_slice::<T>(&existing)
            .map(|_| ())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    write_private_atomic(path, contents)
}

fn create_temp(path: &Path) -> io::Result<(PathBuf, File)> {
    for _ in 0..16 {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = temp_path(path, sequence)?;
        match open_private_temp(&temp) {
            Ok(file) => return Ok((temp, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "unable to allocate unique atomic temp file",
    ))
}

#[cfg(not(windows))]
fn open_private_temp(path: &Path) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[cfg(windows)]
fn open_private_temp(path: &Path) -> io::Result<File> {
    super::atomic_file_windows::open_private_temp(path)
}

fn temp_path(path: &Path, sequence: u64) -> io::Result<PathBuf> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "atomic file path has no name")
    })?;
    let mut temp_name = OsString::from(name);
    temp_name.push(format!(".birdnion-{}-{sequence}.tmp", std::process::id()));
    Ok(path.with_file_name(temp_name))
}

fn cleanup_stale_temps(path: &Path) {
    let Some(parent) = path.parent() else { return };
    let Some(name) = path.file_name() else { return };
    let mut prefix = name.to_os_string();
    prefix.push(".birdnion-");
    let prefix = prefix.to_string_lossy();
    let Ok(entries) = std::fs::read_dir(parent) else {
        return;
    };
    let mut matching_entries = 0usize;
    for entry in entries.flatten() {
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(prefix.as_ref())
        {
            continue;
        }
        matching_entries += 1;
        if matching_entries > MAX_STALE_TEMPS_PER_WRITE {
            break;
        }
        let is_stale = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .and_then(|modified| modified.elapsed().map_err(io::Error::other))
            .is_ok_and(|age| age >= STALE_TEMP_AGE);
        if is_stale {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(not(windows))]
fn replace_same_directory(temp: &Path, destination: &Path) -> io::Result<()> {
    std::fs::rename(temp, destination)
}

#[cfg(windows)]
fn replace_same_directory(temp: &Path, destination: &Path) -> io::Result<()> {
    #[link(name = "Kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    let existing = wide_path(temp)?;
    let new = wide_path(destination)?;
    // SAFETY: both buffers are NUL-terminated and remain alive for the call.
    if unsafe {
        MoveFileExW(
            existing.as_ptr(),
            new.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } != 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(windows)]
use super::atomic_file_windows::wide_path;

#[cfg(unix)]
fn sync_parent(parent: &Path) -> io::Result<()> {
    File::open(parent)?.sync_all()
}

#[cfg(not(unix))]
fn sync_parent(_parent: &Path) -> io::Result<()> {
    Ok(())
}

struct TempGuard(Option<PathBuf>);

impl Drop for TempGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

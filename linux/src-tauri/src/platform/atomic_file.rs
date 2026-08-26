use std::{
    ffi::{OsStr, OsString},
    fs::File,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    sync::Arc,
    time::Duration,
};

const STALE_TEMP_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_STALE_TEMPS_PER_WRITE: usize = 16;
const MAX_VALIDATED_JSON_BYTES: usize = 8 * 1024 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConditionalWriteOutcome {
    Written,
    Conflict,
}

/// Stable identity for one opened directory. Codex auth revisions use this
/// instead of a pathname so renaming an account home cannot silently retarget
/// an in-flight provider refresh.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct DirectoryIdentity {
    device: u64,
    inode: u64,
}

/// An opened directory kept alive across async work. Every `*_at` operation
/// below is relative to this descriptor; no credential pathname is resolved
/// again after the provider starts its fetch.
#[derive(Clone)]
pub struct BoundDirectory {
    #[cfg(unix)]
    file: Arc<File>,
    identity: DirectoryIdentity,
}

impl std::fmt::Debug for BoundDirectory {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BoundDirectory")
            .field("identity", &self.identity)
            .finish_non_exhaustive()
    }
}

impl PartialEq for BoundDirectory {
    fn eq(&self, other: &Self) -> bool {
        self.identity == other.identity
    }
}

impl Eq for BoundDirectory {}

impl BoundDirectory {
    /// Open a real directory without following a final symlink/reparse point.
    /// Non-Unix platforms fail closed until they have equivalent handle-relative
    /// primitives.
    pub fn open(path: &Path) -> io::Result<Self> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;

            let mut options = std::fs::OpenOptions::new();
            options.read(true).custom_flags(
                libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            );
            return Self::from_file(options.open(path)?);
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "handle-relative directory operations are unsupported on this platform",
            ))
        }
    }

    /// Bind one direct child directory through this already-opened parent.
    pub fn open_child_directory(&self, name: &OsStr) -> io::Result<Self> {
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};

            let name = unix_file_name(name)?;
            // SAFETY: `name` is NUL-terminated and `self.file` remains alive.
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY
                        | libc::O_CLOEXEC
                        | libc::O_DIRECTORY
                        | libc::O_NOFOLLOW
                        | libc::O_NONBLOCK,
                )
            };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: `openat` returned a new owned descriptor.
            return Self::from_file(unsafe { File::from_raw_fd(fd) });
        }
        #[cfg(not(unix))]
        {
            let _ = name;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "handle-relative directory operations are unsupported on this platform",
            ))
        }
    }

    pub fn identity(&self) -> DirectoryIdentity {
        self.identity
    }

    pub(crate) fn identity_parts(&self) -> (u64, u64) {
        (self.identity.device, self.identity.inode)
    }

    pub fn matches_metadata(&self, metadata: &std::fs::Metadata) -> bool {
        directory_identity(metadata).is_some_and(|identity| identity == self.identity)
    }

    pub fn child_directory_has_identity(&self, name: &OsStr, expected: DirectoryIdentity) -> bool {
        self.open_child_directory(name)
            .is_ok_and(|directory| directory.identity == expected)
    }

    pub(crate) fn remove_file_if_present(&self, name: &OsStr) -> io::Result<()> {
        unlink_file_at_if_present(self, name)?;
        self.sync_all()
    }

    /// Open or create a private regular lock file relative to this directory.
    /// Keeping the descriptor lookup on the same dirfd as the protected data
    /// prevents a parent-path rename from splitting the lock and data routes.
    pub(crate) fn open_private_lock_file_at(&self, name: &OsStr) -> io::Result<File> {
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            use std::os::unix::fs::{MetadataExt, PermissionsExt};

            let name = unix_file_name(name)?;
            // SAFETY: `name` is NUL-terminated and `self.file` remains alive.
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_CLOEXEC
                        | libc::O_NOFOLLOW
                        | libc::O_NONBLOCK,
                    0o600,
                )
            };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: `openat` returned a new owned descriptor.
            let file = unsafe { File::from_raw_fd(fd) };
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.nlink() != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "lock entry is not a private regular file",
                ));
            }
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            return Ok(file);
        }
        #[cfg(not(unix))]
        {
            let _ = name;
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "handle-relative lock files are unsupported on this platform",
            ))
        }
    }

    #[cfg(unix)]
    fn from_file(file: File) -> io::Result<Self> {
        let metadata = file.metadata()?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "opened path is not a real directory",
            ));
        }
        let identity = directory_identity(&metadata).ok_or_else(|| {
            io::Error::new(io::ErrorKind::Unsupported, "directory identity unavailable")
        })?;
        Ok(Self {
            file: Arc::new(file),
            identity,
        })
    }

    fn sync_all(&self) -> io::Result<()> {
        #[cfg(unix)]
        {
            return self.file.sync_all();
        }
        #[cfg(not(unix))]
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "handle-relative directory sync is unsupported on this platform",
        ))
    }
}

#[cfg(unix)]
fn directory_identity(metadata: &std::fs::Metadata) -> Option<DirectoryIdentity> {
    use std::os::unix::fs::MetadataExt;

    Some(DirectoryIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

#[cfg(not(unix))]
fn directory_identity(_metadata: &std::fs::Metadata) -> Option<DirectoryIdentity> {
    None
}

/// Read one regular file relative to a previously bound directory.
pub fn read_regular_file_bounded_at(
    directory: &BoundDirectory,
    name: &OsStr,
    maximum: usize,
) -> io::Result<Option<Vec<u8>>> {
    let Some(file) = open_read_descriptor_at(directory, name)? else {
        return Ok(None);
    };
    read_bounded_descriptor(file, maximum)
}

#[cfg(unix)]
fn open_read_descriptor_at(directory: &BoundDirectory, name: &OsStr) -> io::Result<Option<File>> {
    use std::os::fd::{AsRawFd, FromRawFd};

    let name = unix_file_name(name)?;
    // SAFETY: `name` is NUL-terminated and the directory descriptor is live.
    let fd = unsafe {
        libc::openat(
            directory.file.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd >= 0 {
        // SAFETY: `openat` returned a new owned descriptor.
        return Ok(Some(unsafe { File::from_raw_fd(fd) }));
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::NotFound {
        Ok(None)
    } else {
        Err(error)
    }
}

#[cfg(not(unix))]
fn open_read_descriptor_at(_directory: &BoundDirectory, _name: &OsStr) -> io::Result<Option<File>> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "handle-relative reads are unsupported on this platform",
    ))
}

fn read_bounded_descriptor(file: File, maximum: usize) -> io::Result<Option<Vec<u8>>> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "existing path is not a regular file",
        ));
    }
    if metadata.len() > maximum as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("existing file exceeds {maximum} byte limit"),
        ));
    }

    let initial_capacity = usize::try_from(metadata.len())
        .unwrap_or(maximum)
        .min(maximum);
    let mut contents = Vec::with_capacity(initial_capacity);
    file.take(maximum.saturating_add(1) as u64)
        .read_to_end(&mut contents)?;
    if contents.len() > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("existing file exceeds {maximum} byte limit"),
        ));
    }
    Ok(Some(contents))
}

/// Read one existing regular file through the descriptor that was opened.
///
/// `O_NONBLOCK` keeps FIFOs from waiting for a writer, while `O_NOFOLLOW`
/// rejects symlinks before any target bytes are observed. The descriptor
/// metadata check and the limited read cover special files, sparse files, and
/// files that grow after `metadata()` without a path-based check/read race.
pub fn read_regular_file_bounded(path: &Path, maximum: usize) -> io::Result<Option<Vec<u8>>> {
    let Some(file) = open_read_descriptor(path)? else {
        return Ok(None);
    };
    read_bounded_descriptor(file, maximum)
}

fn open_read_descriptor(path: &Path) -> io::Result<Option<File>> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }

    match options.open(path) {
        Ok(file) => Ok(Some(file)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            match std::fs::symlink_metadata(path) {
                Err(metadata_error) if metadata_error.kind() == io::ErrorKind::NotFound => Ok(None),
                Ok(_) => Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "existing path could not be opened without following links",
                )),
                Err(metadata_error) => Err(metadata_error),
            }
        }
        Err(error) => Err(error),
    }
}

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
    if contents.len() > MAX_VALIDATED_JSON_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("JSON document exceeds {MAX_VALIDATED_JSON_BYTES} byte limit"),
        ));
    }
    if let Some(existing) = read_regular_file_bounded(path, MAX_VALIDATED_JSON_BYTES)? {
        serde_json::from_slice::<T>(&existing)
            .map(|_| ())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    }
    write_private_atomic(path, contents)
}

/// Replace an existing JSON document only when its exact bytes still match
/// `expected`.
///
/// A regular compare followed by `rename()` is not a CAS: an external process
/// can replace the destination in that gap. This transaction first stages the
/// new private file, then atomically *claims* the current destination into a
/// fixed recovery name with a no-replace rename. The claimed file is checked
/// through a bounded, no-follow descriptor before the staged file is installed
/// with another no-replace rename. A competing writer therefore wins without
/// being overwritten. A prior claimed file is restored after a crash when the
/// destination is absent.
///
/// Linux/POSIX has no single syscall that means "replace this path iff these
/// bytes are unchanged". The short claim window can make the destination
/// transiently absent, but every conflict path either restores the claimed
/// file without replacement or leaves a newer external destination untouched.
pub fn write_private_json_atomic_if_unchanged<T>(
    path: &Path,
    contents: &[u8],
    expected: &[u8],
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_unchanged_impl::<T, _>(path, contents, expected, || {})
}

/// Heal a conditional-write claim left behind by a process crash. Auth readers
/// call this before treating a missing destination as a signed-out state.
pub fn recover_private_json_atomic<T>(path: &Path) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "atomic file path has no parent",
        )
    })?;
    let backup = conditional_backup_path(path)?;
    recover_conditional_backup::<T>(path, &backup, parent)
}

/// Heal a conditional-write claim relative to one stable directory binding.
pub fn recover_private_json_atomic_at<T>(directory: &BoundDirectory, name: &OsStr) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let backup = suffixed_name(name, ".birdnion-cas-backup")?;
    recover_conditional_backup_at::<T>(directory, name, &backup)
}

/// Conditional JSON replace that never leaves the bound directory descriptor.
/// `Written` confirms this descriptor transaction only; callers that own a
/// higher-level route/revision must revalidate it before surfacing success.
pub fn write_private_json_atomic_if_unchanged_at<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    contents: &[u8],
    expected: &[u8],
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_matches_at::<T>(directory, name, contents, Some(expected))
}

/// Create a JSON file only when absent (`None`) or replace it only when the
/// exact current bytes still match (`Some`). Both branches recover an earlier
/// claim first and remain relative to the same directory descriptor.
/// `Written` confirms this descriptor transaction only; callers that own a
/// higher-level route/revision must revalidate it before surfacing success.
pub fn write_private_json_atomic_if_matches_at<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    contents: &[u8],
    expected: Option<&[u8]>,
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_matches_at_impl::<T, _>(directory, name, contents, expected, || {})
}

#[cfg(test)]
pub(crate) fn write_private_json_atomic_if_unchanged_at_with_hook<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    contents: &[u8],
    expected: &[u8],
    before_claim: impl FnOnce(),
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_matches_at_with_hook::<T>(
        directory,
        name,
        contents,
        Some(expected),
        before_claim,
    )
}

#[cfg(test)]
pub(crate) fn write_private_json_atomic_if_matches_at_with_hook<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    contents: &[u8],
    expected: Option<&[u8]>,
    before_commit: impl FnOnce(),
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_matches_at_impl::<T, _>(
        directory,
        name,
        contents,
        expected,
        before_commit,
    )
}

fn write_private_json_atomic_if_matches_at_impl<T, F>(
    directory: &BoundDirectory,
    name: &OsStr,
    contents: &[u8],
    expected: Option<&[u8]>,
    before_commit: F,
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
    F: FnOnce(),
{
    validate_json_document::<T>(contents)?;
    if let Some(expected) = expected {
        validate_json_document::<T>(expected)?;
    }
    let backup = suffixed_name(name, ".birdnion-cas-backup")?;
    recover_conditional_backup_at::<T>(directory, name, &backup)?;

    let (temp_name, mut file) = create_temp_at(directory, name)?;
    let mut guard = BoundTempGuard {
        directory: directory.clone(),
        name: Some(temp_name.clone()),
    };
    file.write_all(contents)?;
    file.sync_all()?;
    drop(file);

    before_commit();

    let Some(expected) = expected else {
        match rename_no_replace_at(directory, &temp_name, name) {
            Ok(()) => guard.name = None,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::AlreadyExists | io::ErrorKind::NotFound
                ) =>
            {
                return Ok(ConditionalWriteOutcome::Conflict)
            }
            Err(error) => return Err(error),
        }
        let postcondition =
            read_regular_file_bounded_at(directory, name, MAX_VALIDATED_JSON_BYTES)?;
        let outcome = if postcondition.as_deref() == Some(contents) {
            ConditionalWriteOutcome::Written
        } else {
            ConditionalWriteOutcome::Conflict
        };
        directory.sync_all()?;
        return Ok(outcome);
    };

    match rename_no_replace_at(directory, name, &backup) {
        Ok(()) => {}
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::AlreadyExists
            ) =>
        {
            return Ok(ConditionalWriteOutcome::Conflict)
        }
        Err(error) => return Err(error),
    }

    let claimed = match read_regular_file_bounded_at(directory, &backup, MAX_VALIDATED_JSON_BYTES) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => {
            restore_claimed_destination_at(directory, &backup, name)?;
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "claimed destination disappeared before validation",
            ));
        }
        Err(error) => {
            restore_claimed_destination_at(directory, &backup, name)?;
            return Err(error);
        }
    };

    if claimed != expected {
        restore_claimed_destination_at(directory, &backup, name)?;
        return Ok(ConditionalWriteOutcome::Conflict);
    }

    match rename_no_replace_at(directory, &temp_name, name) {
        Ok(()) => guard.name = None,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            discard_backup_if_destination_is_valid_at::<T>(directory, name, &backup)?;
            return Ok(ConditionalWriteOutcome::Conflict);
        }
        Err(error) => {
            restore_claimed_destination_at(directory, &backup, name)?;
            return Err(error);
        }
    }

    let postcondition = read_regular_file_bounded_at(directory, name, MAX_VALIDATED_JSON_BYTES)?;
    let outcome = if postcondition.as_deref() == Some(contents) {
        ConditionalWriteOutcome::Written
    } else {
        ConditionalWriteOutcome::Conflict
    };
    unlink_file_at_if_present(directory, &backup)?;
    directory.sync_all()?;
    Ok(outcome)
}

#[cfg(test)]
pub(crate) fn write_private_json_atomic_if_unchanged_with_hook<T>(
    path: &Path,
    contents: &[u8],
    expected: &[u8],
    after_staging: impl FnOnce(),
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
{
    write_private_json_atomic_if_unchanged_impl::<T, _>(path, contents, expected, after_staging)
}

fn write_private_json_atomic_if_unchanged_impl<T, F>(
    path: &Path,
    contents: &[u8],
    expected: &[u8],
    after_staging: F,
) -> io::Result<ConditionalWriteOutcome>
where
    T: serde::de::DeserializeOwned,
    F: FnOnce(),
{
    validate_json_document::<T>(contents)?;
    validate_json_document::<T>(expected)?;

    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "atomic file path has no parent",
        )
    })?;
    ensure_private_directory(parent)?;
    let backup = conditional_backup_path(path)?;
    recover_conditional_backup::<T>(path, &backup, parent)?;
    cleanup_stale_temps(path);

    let (temp, mut file) = create_temp(path)?;
    let mut guard = TempGuard(Some(temp.clone()));
    file.write_all(contents)?;
    file.sync_all()?;
    drop(file);

    // Test hooks model an uncooperative CLI writer in the exact gap after the
    // caller's compare and after staging, immediately before the path claim.
    after_staging();

    match rename_no_replace(path, &backup) {
        Ok(()) => {}
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::AlreadyExists
            ) =>
        {
            return Ok(ConditionalWriteOutcome::Conflict)
        }
        Err(error) => return Err(error),
    }

    let claimed = match read_regular_file_bounded(&backup, MAX_VALIDATED_JSON_BYTES) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => {
            restore_claimed_destination(&backup, path, parent)?;
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "claimed destination disappeared before validation",
            ));
        }
        Err(error) => {
            restore_claimed_destination(&backup, path, parent)?;
            return Err(error);
        }
    };

    if claimed != expected {
        restore_claimed_destination(&backup, path, parent)?;
        return Ok(ConditionalWriteOutcome::Conflict);
    }

    match rename_no_replace(&temp, path) {
        Ok(()) => guard.0 = None,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            discard_backup_if_destination_is_valid::<T>(path, &backup, parent)?;
            return Ok(ConditionalWriteOutcome::Conflict);
        }
        Err(error) => {
            restore_claimed_destination(&backup, path, parent)?;
            return Err(error);
        }
    }

    // If an external writer immediately superseded our commit, its document
    // remains authoritative and the caller receives a conflict, never a retry
    // that overwrites it with the stale refresh result.
    let postcondition = read_regular_file_bounded(path, MAX_VALIDATED_JSON_BYTES)?;
    let outcome = if postcondition.as_deref() == Some(contents) {
        ConditionalWriteOutcome::Written
    } else {
        ConditionalWriteOutcome::Conflict
    };
    remove_file_if_present(&backup)?;
    sync_parent(parent)?;
    Ok(outcome)
}

fn validate_json_document<T>(contents: &[u8]) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    if contents.len() > MAX_VALIDATED_JSON_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("JSON document exceeds {MAX_VALIDATED_JSON_BYTES} byte limit"),
        ));
    }
    serde_json::from_slice::<T>(contents)
        .map(|_| ())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn recover_conditional_backup<T>(path: &Path, backup: &Path, parent: &Path) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let Some(backup_contents) = read_regular_file_bounded(backup, MAX_VALIDATED_JSON_BYTES)? else {
        return Ok(());
    };
    validate_json_document::<T>(&backup_contents)?;

    match read_regular_file_bounded(path, MAX_VALIDATED_JSON_BYTES)? {
        None => match rename_no_replace(backup, path) {
            Ok(()) => sync_parent(parent),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                discard_backup_if_destination_is_valid::<T>(path, backup, parent)
            }
            Err(error) => Err(error),
        },
        Some(current) => {
            validate_json_document::<T>(&current)?;
            remove_file_if_present(backup)?;
            sync_parent(parent)
        }
    }
}

fn recover_conditional_backup_at<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    backup: &OsStr,
) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let Some(backup_contents) =
        read_regular_file_bounded_at(directory, backup, MAX_VALIDATED_JSON_BYTES)?
    else {
        return Ok(());
    };
    validate_json_document::<T>(&backup_contents)?;

    match read_regular_file_bounded_at(directory, name, MAX_VALIDATED_JSON_BYTES)? {
        None => match rename_no_replace_at(directory, backup, name) {
            Ok(()) => directory.sync_all(),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                discard_backup_if_destination_is_valid_at::<T>(directory, name, backup)
            }
            Err(error) => Err(error),
        },
        Some(current) => {
            validate_json_document::<T>(&current)?;
            unlink_file_at_if_present(directory, backup)?;
            directory.sync_all()
        }
    }
}

fn restore_claimed_destination_at(
    directory: &BoundDirectory,
    backup: &OsStr,
    name: &OsStr,
) -> io::Result<()> {
    match rename_no_replace_at(directory, backup, name) {
        Ok(()) => directory.sync_all(),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}

fn discard_backup_if_destination_is_valid_at<T>(
    directory: &BoundDirectory,
    name: &OsStr,
    backup: &OsStr,
) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let current = read_regular_file_bounded_at(directory, name, MAX_VALIDATED_JSON_BYTES)?
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "external destination disappeared during conflict recovery",
            )
        })?;
    validate_json_document::<T>(&current)?;
    unlink_file_at_if_present(directory, backup)?;
    directory.sync_all()
}

fn restore_claimed_destination(backup: &Path, path: &Path, parent: &Path) -> io::Result<()> {
    match rename_no_replace(backup, path) {
        Ok(()) => sync_parent(parent),
        // A newer external writer owns the destination. Keep the claimed file
        // in the private recovery path rather than replacing that writer.
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}

fn discard_backup_if_destination_is_valid<T>(
    path: &Path,
    backup: &Path,
    parent: &Path,
) -> io::Result<()>
where
    T: serde::de::DeserializeOwned,
{
    let current = read_regular_file_bounded(path, MAX_VALIDATED_JSON_BYTES)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "external destination disappeared during conflict recovery",
        )
    })?;
    validate_json_document::<T>(&current)?;
    remove_file_if_present(backup)?;
    sync_parent(parent)
}

fn remove_file_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn conditional_backup_path(path: &Path) -> io::Result<PathBuf> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "atomic file path has no name")
    })?;
    let mut backup_name = OsString::from(name);
    backup_name.push(".birdnion-cas-backup");
    Ok(path.with_file_name(backup_name))
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

fn create_temp_at(directory: &BoundDirectory, name: &OsStr) -> io::Result<(OsString, File)> {
    for _ in 0..16 {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_name = suffixed_name(
            name,
            &format!(".birdnion-{}-{sequence}.tmp", std::process::id()),
        )?;
        match open_private_temp_at(directory, &temp_name) {
            Ok(file) => return Ok((temp_name, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "unable to allocate unique atomic temp file",
    ))
}

#[cfg(unix)]
fn open_private_temp_at(directory: &BoundDirectory, name: &OsStr) -> io::Result<File> {
    use std::os::fd::{AsRawFd, FromRawFd};

    let name = unix_file_name(name)?;
    // SAFETY: `name` is NUL-terminated and the directory descriptor is live.
    let fd = unsafe {
        libc::openat(
            directory.file.as_raw_fd(),
            name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            0o600,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: `openat` returned a new owned descriptor.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

#[cfg(not(unix))]
fn open_private_temp_at(_directory: &BoundDirectory, _name: &OsStr) -> io::Result<File> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "handle-relative temp creation is unsupported on this platform",
    ))
}

fn suffixed_name(name: &OsStr, suffix: &str) -> io::Result<OsString> {
    validate_file_name(name)?;
    let mut suffixed = name.to_os_string();
    suffixed.push(suffix);
    Ok(suffixed)
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

#[cfg(target_os = "linux")]
fn rename_no_replace_at(
    directory: &BoundDirectory,
    source: &OsStr,
    destination: &OsStr,
) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    let source = unix_file_name(source)?;
    let destination = unix_file_name(destination)?;
    // SAFETY: both names are NUL-terminated and the directory descriptor lives
    // for the full call.
    if unsafe {
        libc::renameat2(
            directory.file.as_raw_fd(),
            source.as_ptr(),
            directory.file.as_raw_fd(),
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_vendor = "apple")]
fn rename_no_replace_at(
    directory: &BoundDirectory,
    source: &OsStr,
    destination: &OsStr,
) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    let source = unix_file_name(source)?;
    let destination = unix_file_name(destination)?;
    // SAFETY: both names are NUL-terminated and the directory descriptor lives
    // for the full call.
    if unsafe {
        libc::renameatx_np(
            directory.file.as_raw_fd(),
            source.as_ptr(),
            directory.file.as_raw_fd(),
            destination.as_ptr(),
            libc::RENAME_EXCL,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
fn rename_no_replace_at(
    _directory: &BoundDirectory,
    _source: &OsStr,
    _destination: &OsStr,
) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "handle-relative conditional replace is unsupported on this platform",
    ))
}

#[cfg(unix)]
fn unlink_file_at_if_present(directory: &BoundDirectory, name: &OsStr) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    let name = unix_file_name(name)?;
    // SAFETY: `name` is NUL-terminated and the directory descriptor is live.
    if unsafe { libc::unlinkat(directory.file.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::NotFound {
        Ok(())
    } else {
        Err(error)
    }
}

#[cfg(not(unix))]
fn unlink_file_at_if_present(_directory: &BoundDirectory, _name: &OsStr) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "handle-relative unlink is unsupported on this platform",
    ))
}

fn validate_file_name(name: &OsStr) -> io::Result<()> {
    let mut components = Path::new(name).components();
    let is_single_normal = matches!(
        components.next(),
        Some(std::path::Component::Normal(component)) if component == name
    ) && components.next().is_none();
    if is_single_normal {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "handle-relative operation requires one file name",
        ))
    }
}

#[cfg(unix)]
fn unix_file_name(name: &OsStr) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;

    validate_file_name(name)?;
    std::ffi::CString::new(name.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "file name contains a NUL byte"))
}

#[cfg(target_os = "linux")]
fn rename_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    let source = unix_path(source)?;
    let destination = unix_path(destination)?;
    // SAFETY: both C strings are NUL-terminated and remain alive for the call.
    if unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_vendor = "apple")]
fn rename_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    let source = unix_path(source)?;
    let destination = unix_path(destination)?;
    // SAFETY: both C strings are NUL-terminated and remain alive for the call.
    if unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
fn unix_path(path: &Path) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "atomic file path contains a NUL byte",
        )
    })
}

#[cfg(windows)]
fn rename_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    #[link(name = "Kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }

    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    let existing = wide_path(source)?;
    let new = wide_path(destination)?;
    // SAFETY: both buffers are NUL-terminated and remain alive for the call.
    if unsafe { MoveFileExW(existing.as_ptr(), new.as_ptr(), MOVEFILE_WRITE_THROUGH) } != 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(any(target_os = "linux", target_vendor = "apple", windows)))]
fn rename_no_replace(_source: &Path, _destination: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "conditional atomic replace is unsupported on this platform",
    ))
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

struct BoundTempGuard {
    directory: BoundDirectory,
    name: Option<OsString>,
}

impl Drop for BoundTempGuard {
    fn drop(&mut self) {
        if let Some(name) = self.name.take() {
            let _ = unlink_file_at_if_present(&self.directory, &name);
        }
    }
}

#[cfg(all(test, unix))]
mod bound_directory_tests {
    use super::*;
    use std::ffi::OsStr;

    fn temp_root(tag: &str) -> PathBuf {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "birdnion-bound-atomic-{tag}-{}-{sequence}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn bound_conditional_write_never_follows_swapped_parent() {
        use std::os::unix::fs::symlink;

        let root = temp_root("parent-swap");
        let home = root.join("home");
        let detached = root.join("detached");
        let outside = root.join("outside");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let name = OsStr::new("credentials.json");
        let original = br#"{"value":"old"}"#;
        let replacement = br#"{"value":"new"}"#;
        std::fs::write(home.join(name), original).unwrap();
        std::fs::write(outside.join(name), original).unwrap();
        let directory = BoundDirectory::open(&home).unwrap();

        let outcome = write_private_json_atomic_if_unchanged_at_with_hook::<serde_json::Value>(
            &directory,
            name,
            replacement,
            original,
            || {
                std::fs::rename(&home, &detached).unwrap();
                symlink(&outside, &home).unwrap();
            },
        )
        .unwrap();

        assert_eq!(outcome, ConditionalWriteOutcome::Written);
        assert_eq!(std::fs::read(outside.join(name)).unwrap(), original);
        assert_eq!(std::fs::read(detached.join(name)).unwrap(), replacement);
        std::fs::remove_file(&home).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bound_child_directory_rejects_symlink() {
        use std::os::unix::fs::symlink;

        let root = temp_root("child-symlink");
        let outside = root.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&outside, root.join("managed-account")).unwrap();
        let directory = BoundDirectory::open(&root).unwrap();

        assert!(directory
            .open_child_directory(OsStr::new("managed-account"))
            .is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bound_recovery_stays_with_original_directory() {
        use std::os::unix::fs::symlink;

        let root = temp_root("recovery-swap");
        let home = root.join("home");
        let detached = root.join("detached");
        let outside = root.join("outside");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let name = OsStr::new("credentials.json");
        let backup = suffixed_name(name, ".birdnion-cas-backup").unwrap();
        let original = br#"{"value":"old"}"#;
        std::fs::write(home.join(&backup), original).unwrap();
        std::fs::write(outside.join(name), br#"{"value":"outside"}"#).unwrap();
        let directory = BoundDirectory::open(&home).unwrap();
        std::fs::rename(&home, &detached).unwrap();
        symlink(&outside, &home).unwrap();

        recover_private_json_atomic_at::<serde_json::Value>(&directory, name).unwrap();

        assert_eq!(std::fs::read(detached.join(name)).unwrap(), original);
        assert_eq!(
            std::fs::read(outside.join(name)).unwrap(),
            br#"{"value":"outside"}"#
        );
        std::fs::remove_file(&home).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bound_conditional_write_reports_byte_conflict() {
        let root = temp_root("byte-conflict");
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let name = OsStr::new("credentials.json");
        let current = br#"{"value":"current"}"#;
        std::fs::write(home.join(name), current).unwrap();
        let directory = BoundDirectory::open(&home).unwrap();

        let outcome = write_private_json_atomic_if_unchanged_at::<serde_json::Value>(
            &directory,
            name,
            br#"{"value":"new"}"#,
            br#"{"value":"stale"}"#,
        )
        .unwrap();

        assert_eq!(outcome, ConditionalWriteOutcome::Conflict);
        assert_eq!(std::fs::read(home.join(name)).unwrap(), current);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bound_create_if_absent_never_replaces_existing_file() {
        let root = temp_root("create-if-absent");
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let name = OsStr::new("credentials.json");
        let directory = BoundDirectory::open(&home).unwrap();
        let initial = br#"{"value":"initial"}"#;

        assert_eq!(
            write_private_json_atomic_if_matches_at::<serde_json::Value>(
                &directory, name, initial, None,
            )
            .unwrap(),
            ConditionalWriteOutcome::Written
        );
        assert_eq!(
            write_private_json_atomic_if_matches_at::<serde_json::Value>(
                &directory,
                name,
                br#"{"value":"replacement"}"#,
                None,
            )
            .unwrap(),
            ConditionalWriteOutcome::Conflict
        );
        assert_eq!(std::fs::read(home.join(name)).unwrap(), initial);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bound_create_if_absent_hook_loses_to_concurrent_creator() {
        let root = temp_root("create-race");
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let name = OsStr::new("credentials.json");
        let destination = home.join(name);
        let directory = BoundDirectory::open(&home).unwrap();
        let concurrent = br#"{"value":"concurrent"}"#;

        let outcome = write_private_json_atomic_if_matches_at_with_hook::<serde_json::Value>(
            &directory,
            name,
            br#"{"value":"staged"}"#,
            None,
            || std::fs::write(&destination, concurrent).unwrap(),
        )
        .unwrap();

        assert_eq!(outcome, ConditionalWriteOutcome::Conflict);
        assert_eq!(std::fs::read(destination).unwrap(), concurrent);
        std::fs::remove_dir_all(root).unwrap();
    }
}

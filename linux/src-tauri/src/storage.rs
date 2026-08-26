//! Per-provider on-disk data footprint — Rust mirror of the macOS
//! `ProviderStorage`. Sums regular-file sizes under each provider's known
//! data directories, skipping symlinks so aliased/shared trees aren't
//! double-counted.

use std::path::PathBuf;

use crate::platform::paths::{
    app_config_root_from, app_local_data_root_from, claude_config_dirs_from, codex_home_from,
    current_env, grok_home_from, user_home_from, EnvMap, Platform,
};

const MAX_STORAGE_SCAN_DEPTH: usize = 16;
const MAX_STORAGE_SCAN_ENTRIES: usize = 100_000;

/// Known on-disk locations per provider id (BirdNion `settings.json` ids).
/// Providers without local data return an empty list (command returns 0).
fn home_relative_paths(id: &str, home: &std::path::Path) -> Vec<PathBuf> {
    let p = |rel: &str| home.join(rel);
    match id {
        "gemini" => vec![p(".gemini"), p(".config/gemini")],
        "copilot" => vec![p(".config/github-copilot")],
        "opencode" | "opencodego" => vec![p(".config/opencode"), p(".local/share/opencode")],
        "cursor" => vec![p(".config/Cursor"), p(".cursor")],
        "kiro" => vec![p(".kiro")],
        _ => vec![],
    }
}

fn candidate_paths_from(id: &str, env: &EnvMap, platform: Platform) -> Vec<PathBuf> {
    match id {
        "claude" => claude_config_dirs_from(env, platform),
        "codex" => codex_home_from(env, platform).into_iter().collect(),
        "grok" => grok_home_from(env, platform).into_iter().collect(),
        _ if platform == Platform::Unix => user_home_from(env, platform)
            .map(|home| home_relative_paths(id, &home))
            .unwrap_or_default(),
        _ => windows_provider_paths(id, env),
    }
}

fn windows_provider_paths(id: &str, env: &EnvMap) -> Vec<PathBuf> {
    let home = user_home_from(env, Platform::Windows);
    let roaming = app_config_root_from(env, Platform::Windows);
    let local = app_local_data_root_from(env, Platform::Windows);
    match id {
        "gemini" => home.into_iter().map(|path| path.join(".gemini")).collect(),
        "copilot" => roaming
            .into_iter()
            .map(|path| path.join("github-copilot"))
            .collect(),
        "opencode" | "opencodego" => roaming
            .into_iter()
            .map(|path| path.join("opencode"))
            .chain(local.into_iter().map(|path| path.join("opencode")))
            .collect(),
        "cursor" => roaming
            .into_iter()
            .map(|path| path.join("Cursor"))
            .chain(home.into_iter().map(|path| path.join(".cursor")))
            .collect(),
        _ => Vec::new(),
    }
}

/// Sums regular-file sizes under `id`'s candidate directories. Symlinks
/// (both the dir entry itself and nested ones) are skipped. Missing paths
/// are silently ignored. Root paths, unreadable trees and scans that hit the
/// depth/entry budget return unavailable instead of a misleading partial
/// total. Runs on a blocking thread because provider trees can be large.
#[tauri::command]
pub async fn provider_storage(id: String) -> Result<u64, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let candidates = candidate_paths_from(&id, &current_env(), Platform::current());
        if candidates.is_empty() && has_storage_contract(&id) {
            return Err("Không xác định được thư mục dữ liệu provider".to_string());
        }
        candidates.into_iter().try_fold(0u64, |total, path| {
            scan_dir_size(&path, Platform::current()).map(|bytes| total.saturating_add(bytes))
        })
    })
    .await
    .map_err(|_| "Không thể tính dung lượng provider".to_string())?
}

fn has_storage_contract(id: &str) -> bool {
    matches!(
        id,
        "claude"
            | "codex"
            | "grok"
            | "gemini"
            | "copilot"
            | "opencode"
            | "opencodego"
            | "cursor"
            | "kiro"
    )
}

/// Walks one directory (or measures one file), summing regular-file sizes.
/// Skips symlinks and rejects truncated scans so callers never display a
/// partial value as the complete footprint.
fn scan_dir_size(path: &std::path::Path, platform: Platform) -> Result<u64, String> {
    scan_dir_size_with_limits(
        path,
        platform,
        MAX_STORAGE_SCAN_DEPTH,
        MAX_STORAGE_SCAN_ENTRIES,
    )
}

fn scan_dir_size_with_limits(
    path: &std::path::Path,
    platform: Platform,
    max_depth: usize,
    max_entries: usize,
) -> Result<u64, String> {
    if max_entries == 0 {
        return Err("Storage scan vượt giới hạn an toàn".to_string());
    }
    let meta = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(_) => return Err("Không thể đọc thư mục provider".to_string()),
    };
    if is_link_like(&meta) {
        return Ok(0);
    }
    if meta.is_file() {
        return Ok(meta.len());
    }
    if !meta.is_dir() {
        return Ok(0);
    }
    let canonical = std::fs::canonicalize(path)
        .map_err(|_| "Không thể xác minh thư mục provider".to_string())?;
    if is_filesystem_root(&canonical, platform) {
        return Err("Không quét thư mục gốc filesystem".to_string());
    }

    let mut total = 0u64;
    let mut entries = 0usize;
    let walker = walkdir::WalkDir::new(&canonical)
        .max_depth(max_depth)
        .into_iter()
        .filter_entry(|entry| {
            entry.depth() == 0
                || std::fs::symlink_metadata(entry.path())
                    .map(|metadata| !is_link_like(&metadata))
                    .unwrap_or(true)
        });
    for entry in walker {
        let entry = entry.map_err(|_| "Storage scan không đầy đủ".to_string())?;
        entries += 1;
        if entries > max_entries {
            return Err("Storage scan vượt giới hạn an toàn".to_string());
        }
        let metadata = std::fs::symlink_metadata(entry.path())
            .map_err(|_| "Storage scan không đầy đủ".to_string())?;
        if is_link_like(&metadata) {
            continue;
        }
        if metadata.is_dir() && entry.depth() == max_depth {
            let has_children = std::fs::read_dir(entry.path())
                .map(|mut children| children.next().is_some())
                .unwrap_or(true);
            if has_children {
                return Err("Storage scan vượt giới hạn an toàn".to_string());
            }
        } else if metadata.is_file() {
            total = total.saturating_add(metadata.len());
        }
    }
    Ok(total)
}

fn is_link_like(metadata: &std::fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        return metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }
    #[cfg(not(windows))]
    false
}

fn is_filesystem_root(path: &std::path::Path, platform: Platform) -> bool {
    match platform {
        Platform::Unix => path.parent().is_none(),
        Platform::Windows => {
            let mut raw = path.to_string_lossy().replace('/', "\\");
            if raw
                .get(..11)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case(r"\\?\Volume{"))
            {
                if let Some(close) = raw.find('}') {
                    if raw[close + 1..].trim_matches('\\').is_empty() {
                        return true;
                    }
                }
            }
            if raw
                .get(..8)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case(r"\\?\UNC\"))
            {
                raw = format!(r"\\{}", raw.get(8..).unwrap_or_default());
            } else if raw.starts_with(r"\\?\") {
                raw = raw[4..].to_string();
            }
            let trimmed = raw.trim_end_matches('\\');
            if trimmed.is_empty() {
                return true;
            }
            if let Some(rest) = trimmed.strip_prefix(r"\\") {
                let mut parts = rest.split('\\').filter(|part| !part.is_empty());
                let Some(_server) = parts.next() else {
                    return true;
                };
                let Some(_share) = parts.next() else {
                    return true;
                };
                let mut depth = 0usize;
                for part in parts {
                    if part == ".." {
                        depth = depth.saturating_sub(1);
                    } else if part != "." {
                        depth += 1;
                    }
                }
                return depth == 0;
            }
            let Some((drive, rest)) = trimmed.split_once(':') else {
                return false;
            };
            if drive.len() != 1 {
                return false;
            }
            let mut depth = 0usize;
            for part in rest.split('\\').filter(|part| !part.is_empty()) {
                if part == ".." {
                    depth = depth.saturating_sub(1);
                } else if part != "." {
                    depth += 1;
                }
            }
            depth == 0
        }
    }
}

/// "1.2 GB" / "348 KB" — file-style (base-1000) units, matches macOS
/// `ByteCountFormatter(.file)`.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: &[&str] = &["bytes", "KB", "MB", "GB", "TB", "PB"];
    if bytes == 0 {
        return "Zero KB".to_string();
    }
    if bytes < 1000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64;
    let mut unit_idx = 0;
    while value >= 1000.0 && unit_idx < UNITS.len() - 1 {
        value /= 1000.0;
        unit_idx += 1;
    }
    let precision = if value < 10.0 { 1 } else { 0 };
    format!("{:.*} {}", precision, value, UNITS[unit_idx])
}

#[tauri::command]
pub fn format_storage_bytes(bytes: u64) -> String {
    format_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_bytes() {
        assert_eq!(format_bytes(0), "Zero KB");
    }

    #[test]
    fn sub_kb() {
        assert_eq!(format_bytes(512), "512 bytes");
    }

    #[test]
    fn kilobytes() {
        assert_eq!(format_bytes(348_000), "348 KB");
    }

    #[test]
    fn megabytes_low_precision() {
        assert_eq!(format_bytes(1_200_000_000), "1.2 GB");
    }

    #[test]
    fn megabytes_no_decimal_above_ten() {
        assert_eq!(format_bytes(45_000_000), "45 MB");
    }

    #[test]
    fn unknown_provider_has_no_candidates() {
        let env = [("HOME".into(), "/tmp/does-not-matter".into())]
            .into_iter()
            .collect();
        assert!(candidate_paths_from("unknown-provider", &env, Platform::Unix).is_empty());
    }

    #[test]
    fn known_provider_without_home_is_unavailable_not_unknown() {
        assert!(candidate_paths_from("codex", &EnvMap::new(), Platform::Windows).is_empty());
        assert!(has_storage_contract("codex"));
        assert!(!has_storage_contract("unknown-provider"));
    }

    #[test]
    fn claude_candidates_include_dotclaude() {
        let env = [("HOME".into(), "/home/x".into())].into_iter().collect();
        let paths = candidate_paths_from("claude", &env, Platform::Unix);
        assert!(paths.contains(&PathBuf::from("/home/x/.claude")));
    }

    #[test]
    fn grok_candidates_include_dotgrok() {
        let env = [("HOME".into(), "/home/x".into())].into_iter().collect();
        let paths = candidate_paths_from("grok", &env, Platform::Unix);
        assert!(paths.contains(&PathBuf::from("/home/x/.grok")));
    }

    #[test]
    fn kiro_candidate_and_contract_use_dotkiro() {
        let env = [("HOME".into(), "/home/x".into())].into_iter().collect();

        assert_eq!(
            candidate_paths_from("kiro", &env, Platform::Unix),
            vec![PathBuf::from("/home/x/.kiro")]
        );
        assert!(has_storage_contract("kiro"));
    }

    #[test]
    fn kiro_candidate_path_reports_its_bounded_size() {
        let home =
            std::env::temp_dir().join(format!("birdnion-test-kiro-storage-{}", std::process::id()));
        let kiro = home.join(".kiro");
        let nested = kiro.join("sessions").join("cli");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(kiro.join("config.json"), vec![0u8; 40]).unwrap();
        std::fs::write(nested.join("session.json"), vec![0u8; 60]).unwrap();
        let env = [("HOME".into(), home.as_os_str().to_os_string())]
            .into_iter()
            .collect();

        let candidates = candidate_paths_from("kiro", &env, Platform::Unix);
        assert_eq!(candidates, vec![kiro]);
        assert_eq!(
            scan_dir_size_with_limits(&candidates[0], Platform::Unix, 16, 100),
            Ok(100)
        );

        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn windows_tier_zero_candidates_keep_explicit_overrides() {
        let env = [
            ("USERPROFILE".into(), r"C:\Users\me".into()),
            (
                "CLAUDE_CONFIG_DIR".into(),
                r"D:\Claude One,D:\Claude Two".into(),
            ),
            ("CODEX_HOME".into(), r"D:\Codex".into()),
            ("GROK_HOME".into(), r"D:\Grok".into()),
        ]
        .into_iter()
        .collect();
        assert_eq!(
            candidate_paths_from("claude", &env, Platform::Windows),
            vec![
                PathBuf::from(r"D:\Claude One"),
                PathBuf::from(r"D:\Claude Two")
            ]
        );
        assert_eq!(
            candidate_paths_from("codex", &env, Platform::Windows),
            vec![PathBuf::from(r"D:\Codex")]
        );
        assert_eq!(
            candidate_paths_from("grok", &env, Platform::Windows),
            vec![PathBuf::from(r"D:\Grok")]
        );
    }

    #[test]
    fn scan_missing_dir_is_zero() {
        assert_eq!(
            scan_dir_size(
                std::path::Path::new("/nonexistent/does-not-exist-xyz"),
                Platform::Unix
            ),
            Ok(0)
        );
    }

    #[test]
    fn scan_invalid_path_is_unavailable_not_zero() {
        assert!(scan_dir_size_with_limits(
            std::path::Path::new("\0invalid"),
            Platform::Unix,
            16,
            100
        )
        .is_err());
    }

    #[test]
    fn scan_regular_file_sums_its_own_size() {
        let dir = std::env::temp_dir().join(format!("birdnion-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("f.txt");
        std::fs::write(&file, b"hello world").unwrap();
        assert_eq!(scan_dir_size(&file, Platform::Unix), Ok(11));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_dir_sums_nested_files_skips_symlinks() {
        let dir = std::env::temp_dir().join(format!("birdnion-test-dir-{}", std::process::id()));
        let nested = dir.join("nested");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(dir.join("a.txt"), vec![0u8; 100]).unwrap();
        std::fs::write(nested.join("b.txt"), vec![0u8; 50]).unwrap();
        #[cfg(unix)]
        {
            let _ = std::os::unix::fs::symlink(dir.join("a.txt"), dir.join("link.txt"));
        }
        assert_eq!(scan_dir_size(&dir, Platform::Unix), Ok(150));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn storage_scan_rejects_unix_windows_and_unc_roots() {
        assert!(is_filesystem_root(
            std::path::Path::new("/"),
            Platform::Unix
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"C:\"),
            Platform::Windows
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"\\server\share"),
            Platform::Windows
        ));
        assert!(!is_filesystem_root(
            std::path::Path::new(r"C:\Users\me\.claude"),
            Platform::Windows
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"C:\Users\me\..\.."),
            Platform::Windows
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"\\server\share\folder\.."),
            Platform::Windows
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"\\?\UNC\server\share"),
            Platform::Windows
        ));
        assert!(is_filesystem_root(
            std::path::Path::new(r"\\?\C:\"),
            Platform::Windows
        ));
    }

    #[test]
    fn storage_scan_honors_entry_budget() {
        let dir = std::env::temp_dir().join(format!("birdnion-test-budget-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for index in 0..3 {
            std::fs::write(dir.join(format!("{index}.txt")), vec![0u8; 10]).unwrap();
        }
        let measured = scan_dir_size_with_limits(&dir, Platform::Unix, 16, 2);
        assert!(measured.is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn storage_scan_rejects_canonical_unix_root_alias() {
        assert!(scan_dir_size_with_limits(
            std::path::Path::new("/tmp/.."),
            Platform::Unix,
            16,
            100
        )
        .is_err());
    }
}

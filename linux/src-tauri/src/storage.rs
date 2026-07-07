//! Per-provider on-disk data footprint — Rust mirror of the macOS
//! `ProviderStorage`. Sums regular-file sizes under each provider's known
//! data directories, skipping symlinks so aliased/shared trees aren't
//! double-counted.

use std::path::PathBuf;

/// Known on-disk locations per provider id (BirdNion `settings.json` ids).
/// Providers without local data return an empty list (command returns 0).
fn candidate_paths(id: &str, home: &std::path::Path) -> Vec<PathBuf> {
    let p = |rel: &str| home.join(rel);
    match id {
        "claude" => vec![p(".claude"), p(".config/claude")],
        "codex" => {
            if let Ok(custom) = std::env::var("CODEX_HOME") {
                if !custom.trim().is_empty() {
                    return vec![PathBuf::from(custom)];
                }
            }
            vec![p(".codex")]
        }
        "gemini" => vec![p(".gemini"), p(".config/gemini")],
        "copilot" => vec![p(".config/github-copilot")],
        "opencode" | "opencodego" => vec![p(".config/opencode"), p(".local/share/opencode")],
        "cursor" => vec![p(".config/Cursor"), p(".cursor")],
        _ => vec![],
    }
}

/// Sums regular-file sizes under `id`'s candidate directories. Symlinks
/// (both the dir entry itself and nested ones) are skipped. Missing paths
/// are silently ignored — mirrors macOS best-effort scan semantics.
#[tauri::command]
pub fn provider_storage(id: String) -> u64 {
    let home = match std::env::var("HOME") {
        Ok(h) if !h.trim().is_empty() => PathBuf::from(h),
        _ => return 0,
    };
    candidate_paths(&id, &home)
        .into_iter()
        .map(|path| scan_dir_size(&path))
        .sum()
}

/// Walks one directory (or measures one file), summing regular-file sizes.
/// Skips symlinks entirely so shared/aliased trees aren't double-counted.
fn scan_dir_size(path: &std::path::Path) -> u64 {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.is_file() {
        return meta.len();
    }
    if !meta.is_dir() {
        return 0;
    }
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .metadata()
                .map(|m| !m.file_type().is_symlink() && m.is_file())
                .unwrap_or(false)
        })
        .map(|entry| entry.metadata().map(|m| m.len()).unwrap_or(0))
        .sum()
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
        let home = std::path::Path::new("/tmp/does-not-matter");
        assert!(candidate_paths("unknown-provider", home).is_empty());
    }

    #[test]
    fn claude_candidates_include_dotclaude() {
        let home = std::path::Path::new("/home/x");
        let paths = candidate_paths("claude", home);
        assert!(paths.contains(&home.join(".claude")));
    }

    #[test]
    fn scan_missing_dir_is_zero() {
        assert_eq!(scan_dir_size(std::path::Path::new("/nonexistent/does-not-exist-xyz")), 0);
    }

    #[test]
    fn scan_regular_file_sums_its_own_size() {
        let dir = std::env::temp_dir().join(format!("birdnion-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("f.txt");
        std::fs::write(&file, b"hello world").unwrap();
        assert_eq!(scan_dir_size(&file), 11);
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
        assert_eq!(scan_dir_size(&dir), 150);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

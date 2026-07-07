//! GitHub-releases update check — Rust mirror of the macOS `UpdateChecker`.
//! BirdNion Linux ships via a distro package/AppImage with no built-in
//! updater, so this compares the newest non-draft release tag against the
//! running version and links out to the release page.

use serde::{Deserialize, Serialize};

const RELEASES_URL: &str = "https://api.github.com/repos/hapo-nghialuu/BirdNion/releases?per_page=20";

#[derive(Deserialize, Debug, Clone, PartialEq)]
struct GitHubRelease {
    #[serde(rename = "tag_name")]
    tag_name: String,
    #[serde(rename = "html_url")]
    html_url: String,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    draft: bool,
}

#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub version: String,
    pub url: String,
}

/// Queries GitHub Releases and returns the newest applicable version newer
/// than `current_version`, or `None` when already up to date / on error.
#[tauri::command]
pub async fn check_update(channel: String, current_version: String) -> Result<Option<UpdateInfo>, String> {
    let client = crate::providers::shared_client();
    let resp = client
        .get(RELEASES_URL)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let releases: Vec<GitHubRelease> = resp.json().await.map_err(|e| e.to_string())?;
    Ok(pick_latest(&releases, &channel, &current_version).map(|r| UpdateInfo {
        version: r.tag_name.clone(),
        url: r.html_url.clone(),
    }))
}

/// Pure picker (unit-tested): drops drafts, drops prereleases on the stable
/// channel, then returns the highest tag that is newer than `current` — None
/// when up to date. `channel == "beta"` includes prereleases.
fn pick_latest<'a>(releases: &'a [GitHubRelease], channel: &str, current: &str) -> Option<&'a GitHubRelease> {
    releases
        .iter()
        .filter(|r| !r.draft && (channel == "beta" || !r.prerelease))
        .filter(|r| semver_is_newer(&r.tag_name, current))
        .max_by(|a, b| {
            if semver_is_newer(&a.tag_name, &b.tag_name) {
                std::cmp::Ordering::Greater
            } else if semver_is_newer(&b.tag_name, &a.tag_name) {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Equal
            }
        })
}

/// Parsed semver-ish tag: numeric dot components + whether it has a
/// prerelease suffix ("-beta.1" etc). Strips a leading "v".
fn parse_version(raw: &str) -> (Vec<u64>, bool) {
    let s = raw.trim();
    let s = s.strip_prefix('v').or_else(|| s.strip_prefix('V')).unwrap_or(s);
    let mut parts = s.splitn(2, '-');
    let numeric = parts.next().unwrap_or("");
    let is_prerelease = parts.next().is_some();
    let numbers = numeric.split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect();
    (numbers, is_prerelease)
}

/// True when `candidate` is strictly newer than `current`. Numeric
/// component-wise compare; a prerelease sorts BELOW the same release version
/// ("1.2.0-beta.1" < "1.2.0").
pub fn semver_is_newer(candidate: &str, current: &str) -> bool {
    let (c_nums, c_pre) = parse_version(candidate);
    let (r_nums, r_pre) = parse_version(current);
    let len = c_nums.len().max(r_nums.len());
    for i in 0..len {
        let a = c_nums.get(i).copied().unwrap_or(0);
        let b = r_nums.get(i).copied().unwrap_or(0);
        if a != b {
            return a > b;
        }
    }
    // Equal numeric parts: candidate is newer only when current is a
    // prerelease and candidate is the final release.
    r_pre && !c_pre
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_patch_wins() {
        assert!(semver_is_newer("0.8.6", "0.8.5"));
        assert!(!semver_is_newer("0.8.5", "0.8.6"));
    }

    #[test]
    fn strips_leading_v() {
        assert!(semver_is_newer("v1.2.3", "1.2.2"));
    }

    #[test]
    fn equal_versions_not_newer() {
        assert!(!semver_is_newer("1.2.3", "1.2.3"));
    }

    #[test]
    fn prerelease_current_final_candidate_is_newer() {
        assert!(semver_is_newer("1.2.0", "1.2.0-beta.1"));
    }

    #[test]
    fn prerelease_candidate_final_current_is_not_newer() {
        assert!(!semver_is_newer("1.2.0-beta.1", "1.2.0"));
    }

    #[test]
    fn missing_components_default_to_zero() {
        assert!(semver_is_newer("1.3", "1.2.9"));
        assert!(!semver_is_newer("1.2", "1.2.0"));
    }

    fn release(tag: &str, prerelease: bool, draft: bool) -> GitHubRelease {
        GitHubRelease {
            tag_name: tag.to_string(),
            html_url: format!("https://example.com/{tag}"),
            prerelease,
            draft,
        }
    }

    #[test]
    fn pick_latest_stable_skips_prerelease_and_draft() {
        let releases = vec![
            release("0.9.0-beta.1", true, false),
            release("0.8.7", false, true),
            release("0.8.6", false, false),
        ];
        let picked = pick_latest(&releases, "stable", "0.8.5").unwrap();
        assert_eq!(picked.tag_name, "0.8.6");
    }

    #[test]
    fn pick_latest_beta_includes_prerelease() {
        let releases = vec![release("0.9.0-beta.1", true, false), release("0.8.6", false, false)];
        let picked = pick_latest(&releases, "beta", "0.8.5").unwrap();
        assert_eq!(picked.tag_name, "0.9.0-beta.1");
    }

    #[test]
    fn pick_latest_none_when_up_to_date() {
        let releases = vec![release("0.8.6", false, false)];
        assert!(pick_latest(&releases, "stable", "0.8.6").is_none());
    }
}

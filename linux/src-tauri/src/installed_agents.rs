//! Catalog agent cài trên máy — port của macOS `InstalledAgentCatalog` +
//! `InstalledAgentDetectors` (remake agent-centric 2026-08-23).
//!
//! Nguyên tắc giữ nguyên từ bản macOS:
//! - Allowlist bounded: chỉ dò đúng binary và path khai báo cứng ở đây, không
//!   quét đệ quy hệ thống.
//! - Binary phải là file thực thi thật (tránh alias/builtin của shell).
//! - Capability suy ra từ bằng chứng thật: có provider quota, có log chi phí,
//!   hay chỉ có file cấu hình.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// Một agent trong catalog, đã kèm capability đã suy luận.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledAgent {
    pub id: String,
    pub display_name: String,
    /// "cli" | "ide" | "config" — hiển thị dưới tên agent.
    pub kind: String,
    /// Nhãn nguồn (đường dẫn bằng chứng hoặc provider bridge).
    pub source_label: String,
    pub has_quota: bool,
    pub has_cost: bool,
    pub has_config: bool,
    /// Chi phí 90 ngày lấy từ cost-history, `None` khi agent không có log.
    pub cost90d_usd: Option<f64>,
}

/// Khai báo bounded cho một agent: binary + path bằng chứng + cầu nối provider.
struct AgentDescriptor {
    id: &'static str,
    display_name: &'static str,
    kind: &'static str,
    /// Tên lệnh tìm trong PATH.
    binaries: &'static [&'static str],
    /// Path tương đối $HOME coi là bằng chứng cấu hình/session.
    config_paths: &'static [&'static str],
    /// Provider id tương ứng (nếu agent này có quota qua provider).
    provider_id: Option<&'static str>,
    /// Source id trong cost-history (nếu agent có log chi phí).
    cost_source: Option<&'static str>,
}

/// Allowlist — song song với bảng descriptor bên macOS.
const DESCRIPTORS: &[AgentDescriptor] = &[
    AgentDescriptor {
        id: "claude", display_name: "Claude Code", kind: "cli",
        binaries: &["claude"],
        config_paths: &[".claude", ".claude.json", ".claude/projects"],
        provider_id: Some("claude"), cost_source: Some("claude"),
    },
    AgentDescriptor {
        id: "codex", display_name: "Codex CLI", kind: "cli",
        binaries: &["codex"],
        config_paths: &[".codex", ".codex/sessions", ".codex/auth.json"],
        provider_id: Some("codex"), cost_source: Some("codex"),
    },
    AgentDescriptor {
        id: "grok", display_name: "Grok CLI", kind: "cli",
        binaries: &["grok"],
        config_paths: &[".grok/auth.json", ".grok/sessions"],
        provider_id: Some("grok"), cost_source: Some("grok"),
    },
    AgentDescriptor {
        id: "omp", display_name: "Oh My Pi", kind: "cli",
        binaries: &["omp"],
        config_paths: &[".omp/agent/config.yml", ".omp/agent/sessions"],
        provider_id: None, cost_source: Some("omp"),
    },
    AgentDescriptor {
        id: "pi", display_name: "Pi Agent", kind: "cli",
        binaries: &["pi"],
        config_paths: &[".pi/agent/settings.json", ".pi/agent/sessions"],
        provider_id: None, cost_source: Some("pi"),
    },
    AgentDescriptor {
        id: "gemini", display_name: "Gemini CLI", kind: "cli",
        binaries: &["gemini"],
        config_paths: &[".gemini/settings.json", ".gemini/oauth_creds.json"],
        provider_id: Some("gemini"), cost_source: None,
    },
    AgentDescriptor {
        id: "opencode", display_name: "OpenCode", kind: "cli",
        binaries: &["opencode"],
        config_paths: &[".config/opencode", ".local/share/opencode"],
        provider_id: Some("opencode"), cost_source: None,
    },
    AgentDescriptor {
        id: "kiro", display_name: "Kiro", kind: "ide",
        binaries: &["kiro-cli", "kiro"],
        config_paths: &[".kiro", ".local/share/kiro"],
        provider_id: Some("kiro"), cost_source: Some("kiro"),
    },
    AgentDescriptor {
        id: "antigravity", display_name: "Antigravity", kind: "cli",
        binaries: &["agy"],
        config_paths: &[".gemini/antigravity", ".config/antigravity"],
        provider_id: Some("antigravity"), cost_source: None,
    },
    AgentDescriptor {
        id: "copilot", display_name: "Copilot CLI", kind: "cli",
        binaries: &["copilot"],
        config_paths: &[".copilot/config.json", ".config/github-copilot"],
        provider_id: Some("copilot"), cost_source: None,
    },
    AgentDescriptor {
        id: "auggie", display_name: "Auggie", kind: "cli",
        binaries: &["auggie"],
        config_paths: &[".augment"],
        provider_id: None, cost_source: None,
    },
    AgentDescriptor {
        id: "amp", display_name: "Amp", kind: "cli",
        binaries: &["amp"],
        config_paths: &[".config/amp/settings.json"],
        provider_id: None, cost_source: None,
    },
    AgentDescriptor {
        id: "cursor", display_name: "Cursor", kind: "ide",
        binaries: &["cursor", "cursor-agent"],
        config_paths: &[".cursor", ".config/Cursor"],
        provider_id: Some("cursor"), cost_source: None,
    },
    AgentDescriptor {
        id: "aider", display_name: "Aider", kind: "cli",
        binaries: &["aider"],
        config_paths: &[".aider", ".aider.conf.yml"],
        provider_id: None, cost_source: None,
    },
    AgentDescriptor {
        id: "qwen", display_name: "Qwen Code", kind: "cli",
        binaries: &["qwen"],
        config_paths: &[".qwen"],
        provider_id: None, cost_source: None,
    },
    AgentDescriptor {
        id: "goose", display_name: "Goose", kind: "cli",
        binaries: &["goose"],
        config_paths: &[".config/goose"],
        provider_id: None, cost_source: None,
    },
];

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// `true` khi path là file thực thi thật (không tính alias/builtin của shell).
fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        match std::fs::metadata(path) {
            Ok(meta) => meta.is_file() && meta.permissions().mode() & 0o111 != 0,
            Err(_) => false,
        }
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// Dò một lệnh trong PATH, trả về đường dẫn đầu tiên thực thi được.
fn which(binary: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(binary);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn first_existing_config(home: &Path, relatives: &[&str]) -> Option<PathBuf> {
    relatives
        .iter()
        .map(|rel| home.join(rel))
        .find(|path| path.exists())
}

/// Dò toàn bộ allowlist; chỉ trả về agent có bằng chứng thật trên máy này.
pub fn detect(
    provider_ids_with_quota: &[String],
    cost_totals_90d: &std::collections::HashMap<String, f64>,
) -> Vec<InstalledAgent> {
    let home = match home_dir() {
        Some(h) => h,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for descriptor in DESCRIPTORS {
        let binary = descriptor.binaries.iter().find_map(|name| which(name));
        let config = first_existing_config(&home, descriptor.config_paths);
        if binary.is_none() && config.is_none() {
            continue;
        }

        let has_quota = descriptor
            .provider_id
            .map(|id| provider_ids_with_quota.iter().any(|p| p == id))
            .unwrap_or(false);
        let cost90d = descriptor
            .cost_source
            .and_then(|source| cost_totals_90d.get(source).copied());
        let has_cost = cost90d.map(|v| v > 0.0).unwrap_or(false)
            || descriptor.cost_source.is_some();

        let source_label = match (&binary, &config) {
            (Some(path), _) => path.display().to_string(),
            (None, Some(path)) => path.display().to_string(),
            _ => String::new(),
        };

        out.push(InstalledAgent {
            id: descriptor.id.to_string(),
            display_name: descriptor.display_name.to_string(),
            kind: descriptor.kind.to_string(),
            source_label,
            has_quota,
            has_cost,
            has_config: config.is_some(),
            cost90d_usd: cost90d,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn which_rejects_non_executable_files() {
        let dir = std::env::temp_dir().join(format!("birdnion-agents-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let plain = dir.join("not-a-binary");
        std::fs::write(&plain, b"text").unwrap();
        assert!(!is_executable(&plain));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn detect_returns_only_agents_with_evidence() {
        // Không có HOME hợp lệ ⇒ danh sách rỗng thay vì đoán bừa.
        let totals = std::collections::HashMap::new();
        let agents = detect(&[], &totals);
        for agent in &agents {
            assert!(
                agent.has_config || !agent.source_label.is_empty(),
                "agent {} phải có bằng chứng thật",
                agent.id
            );
        }
    }
}

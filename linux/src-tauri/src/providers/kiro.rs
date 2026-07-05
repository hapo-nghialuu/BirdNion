//! Kiro (AWS) quota provider — port of `KiroProvider.swift`.
//!
//! Resolves the `kiro` or `kiro-cli` binary from PATH, then runs:
//!   - `kiro-cli whoami` — verifies login; parses email (best-effort).
//!   - `kiro-cli chat --no-interactive /usage` — usage output with credits
//!     %, plan, reset date. ANSI codes are stripped before parsing.
//! Hard timeout of 25s total (20s usage cmd + 3s whoami).

use std::process::{Command, Stdio};
use std::time::Duration;

use regex::Regex;

use crate::providers::{display_name, ProviderStatus, QuotaWindow};

pub async fn fetch(cfg: &crate::config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let id = cfg.id.clone();
    // CLI I/O is blocking; run on a blocking thread so we don't stall the
    // async executor while `kiro-cli` runs.
    tokio_run(move || fetch_blocking(&id, &name)).await
}

async fn tokio_run<F: FnOnce() -> ProviderStatus + Send + 'static>(f: F) -> ProviderStatus {
    match tauri::async_runtime::spawn_blocking(f).await {
        Ok(status) => status,
        Err(_) => ProviderStatus::failure("kiro", "Kiro", "Kiro CLI lỗi: task panicked"),
    }
}

fn fetch_blocking(id: &str, name: &str) -> ProviderStatus {
    let Some(binary) = resolve_binary() else {
        return ProviderStatus::failure(id, name, "Chưa cài Kiro CLI");
    };

    let whoami_out = run_command(&binary, &["whoami"], Duration::from_secs(3)).ok();
    let email = whoami_out.as_deref().and_then(|out| {
        let stripped = strip_ansi(out);
        let lower = stripped.to_lowercase();
        if lower.contains("not logged in") || lower.contains("login required") {
            None
        } else {
            parse_whoami_email(&stripped)
        }
    });

    let usage_out = match run_command(&binary, &["chat", "--no-interactive", "/usage"], Duration::from_secs(20)) {
        Ok(o) => o,
        Err(e) => return ProviderStatus::failure(id, name, e),
    };
    let stripped = strip_ansi(&usage_out);
    let lower = stripped.to_lowercase();
    if lower.contains("not logged in")
        || lower.contains("login required")
        || lower.contains("failed to initialize auth portal")
        || lower.contains("kiro-cli login")
        || lower.contains("oauth error")
    {
        return ProviderStatus::failure(id, name, "Chưa đăng nhập Kiro. Chạy 'kiro-cli login' trong Terminal");
    }

    match parse_usage(&stripped, email.as_deref()) {
        Ok(status) => status,
        Err(msg) => ProviderStatus::failure(id, name, msg),
    }
}

fn resolve_binary() -> Option<String> {
    ["kiro", "kiro-cli"].iter().find_map(|n| which(n))
}

fn which(name: &str) -> Option<String> {
    let out = Command::new("which").arg(name).stderr(Stdio::null()).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() { None } else { Some(path) }
}

/// Runs a kiro-cli subcommand with a hard timeout, killing the process on
/// expiry. Uses a helper thread + channel since std::process has no native
/// timeout support.
fn run_command(binary: &str, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut child = Command::new(binary)
        .args(args)
        .env("TERM", "xterm-256color")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Không khởi động được kiro-cli: {e}"))?;

    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("Kiro CLI timeout".to_string());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("kiro-cli lỗi: {e}")),
        }
    }

    let output = child.wait_with_output().map_err(|e| format!("kiro-cli lỗi: {e}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let combined = if stdout.trim().is_empty() { stderr } else { stdout };
    if !output.status.success() && combined.trim().is_empty() {
        return Err(format!("kiro-cli thoát với code {}", output.status.code().unwrap_or(-1)));
    }
    Ok(combined)
}

/// Strips ANSI CSI and OSC escape sequences from CLI output.
fn strip_ansi(text: &str) -> String {
    let re = Regex::new(r"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07").unwrap();
    re.replace_all(text, "").to_string()
}

fn parse_whoami_email(stripped: &str) -> Option<String> {
    for line in stripped.lines() {
        let t = line.trim();
        if t.to_lowercase().contains("email:") {
            let val = Regex::new(r"(?i)^\s*email:\s*").unwrap().replace(t, "").trim().to_string();
            if !val.is_empty() {
                return Some(val);
            }
        } else if t.contains('@') && !t.contains(' ') {
            return Some(t.to_string());
        }
    }
    None
}

fn first_capture(text: &str, pattern: &str) -> Option<String> {
    let re = Regex::new(pattern).ok()?;
    re.captures(text)?.get(1).map(|m| m.as_str().trim().to_string())
}

fn extract_numbers(text: &str) -> Vec<f64> {
    let re = Regex::new(r"\d+\.?\d*").unwrap();
    re.find_iter(text).filter_map(|m| m.as_str().parse().ok()).collect()
}

fn parse_plan_name(text: &str) -> String {
    if let Some(cap) = first_capture(text, r"Plan:[ \t]*(.+)") {
        let line = cap.lines().next().unwrap_or(&cap).trim();
        if !line.is_empty() {
            return line.to_string();
        }
    }
    if let Some(m) = Regex::new(r"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)").unwrap().find(text) {
        let line = m.as_str();
        if let Some(plan) = line.split('|').last() {
            let plan = plan.trim();
            if !plan.is_empty() {
                return format_plan_name(plan);
            }
        }
    }
    if let Some(m) = Regex::new(r"\|[ \t]*(KIRO[ \t]+\w+)").unwrap().find(text) {
        let raw = m.as_str().replace('|', "");
        return format_plan_name(raw.trim());
    }
    "Kiro".to_string()
}

fn format_plan_name(raw: &str) -> String {
    raw.split(' ')
        .map(|w| {
            if w.eq_ignore_ascii_case("KIRO") {
                "Kiro".to_string()
            } else {
                let mut c = w.chars();
                match c.next() {
                    Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_reset_date(text: &str) -> Option<i64> {
    let m = Regex::new(r"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})").unwrap().find(text)?;
    let seg = m.as_str();
    let date_re = Regex::new(r"\d{4}-\d{2}-\d{2}|\d{2}/\d{2}").unwrap();
    let date_str = date_re.find(seg)?.as_str();
    parse_date_string(date_str)
}

fn parse_date_string(s: &str) -> Option<i64> {
    if s.contains('-') {
        let d = chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok()?;
        return Some(d.and_hms_opt(0, 0, 0)?.and_utc().timestamp());
    }
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() != 2 {
        return None;
    }
    let month: u32 = parts[0].parse().ok()?;
    let day: u32 = parts[1].parse().ok()?;
    let now = chrono::Utc::now();
    let year = now.format("%Y").to_string().parse::<i32>().ok()?;
    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
        let ts = d.and_hms_opt(0, 0, 0)?.and_utc();
        if ts.timestamp() > now.timestamp() {
            return Some(ts.timestamp());
        }
    }
    let d = chrono::NaiveDate::from_ymd_opt(year + 1, month, day)?;
    Some(d.and_hms_opt(0, 0, 0)?.and_utc().timestamp())
}

fn parse_bonus_credits(text: &str) -> Option<(f64, f64, Option<i64>)> {
    let m = Regex::new(r"Bonus credits:\s*(\d+\.?\d*)/(\d+)").unwrap().find(text)?;
    let nums = extract_numbers(m.as_str());
    if nums.len() < 2 {
        return None;
    }
    let expiry = Regex::new(r"expires in (\d+) days?")
        .unwrap()
        .find(text)
        .and_then(|em| extract_numbers(em.as_str()).first().map(|n| *n as i64));
    Some((nums[0], nums[1], expiry))
}

/// Main parse from stripped usage output → ProviderStatus. Mirrors
/// KiroStatusProbe's regex-based parsing (unit-tested).
pub fn parse_usage(stripped: &str, account_email: Option<&str>) -> Result<ProviderStatus, String> {
    let trimmed = stripped.trim();
    if trimmed.is_empty() {
        return Err("Output trống từ kiro-cli".to_string());
    }
    if trimmed.to_lowercase().contains("could not retrieve usage information") {
        return Err("kiro-cli không lấy được thông tin usage".to_string());
    }

    let plan_name = parse_plan_name(stripped);
    let resets_at = parse_reset_date(stripped);

    let mut credits_percent = 0.0;
    let mut matched_percent = false;
    if let Some(m) = Regex::new(r"█+\s*(\d+)%").unwrap().find(stripped) {
        if let Some(num) = Regex::new(r"\d+").unwrap().find(m.as_str()) {
            credits_percent = num.as_str().parse().unwrap_or(0.0);
            matched_percent = true;
        }
    }

    let mut credits_used = 0.0;
    let mut credits_total = 50.0;
    let mut matched_credits = false;
    if let Some(m) = Regex::new(r"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered").unwrap().find(stripped) {
        let nums = extract_numbers(m.as_str());
        if nums.len() >= 2 {
            credits_used = nums[0];
            credits_total = nums[1];
            matched_credits = true;
        }
    }
    if !matched_percent && matched_credits && credits_total > 0.0 {
        credits_percent = (credits_used / credits_total) * 100.0;
    }

    let lower = stripped.to_lowercase();
    let is_managed_plan = lower.contains("managed by admin") || lower.contains("managed by organization");
    let is_new_format = first_capture(stripped, r"Plan:[ \t]*(.+)").is_some();
    if is_new_format && is_managed_plan && !matched_percent && !matched_credits {
        return Ok(ProviderStatus {
            id: "kiro".into(),
            display_name: "Kiro".into(),
            windows: vec![QuotaWindow { label: "Credits".into(), used_pct: 0, remaining_pct: 100, subtitle: None, resets_at: None }],
            last_updated: chrono::Utc::now().timestamp(),
            account_label: account_email.map(String::from),
            ..Default::default()
        });
    }

    if !matched_percent && !matched_credits {
        return Err("Không tìm thấy thông tin usage trong output kiro-cli".to_string());
    }

    let used_pct = (credits_percent.round() as i32).clamp(0, 100);
    let remaining_pct = 100 - used_pct;

    let overage_credits_used = first_capture(stripped, r"(?i)Credits used:\s*(\d+\.?\d*)").and_then(|s| s.parse::<f64>().ok());
    let overage_cost_usd = first_capture(stripped, r"(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD").and_then(|s| s.parse::<f64>().ok());
    let has_manage_url = stripped.contains("https://app.kiro.dev/account/usage");

    let mut subtitle = if matched_credits { Some(format!("{credits_used:.2} / {credits_total:.0} credits")) } else { None };
    if remaining_pct == 0 && has_manage_url {
        let hint = "Nâng cấp tại app.kiro.dev";
        subtitle = Some(match subtitle {
            Some(s) => format!("{s} · {hint}"),
            None => hint.to_string(),
        });
    }

    let mut windows = vec![QuotaWindow {
        label: "Credits".into(),
        used_pct,
        remaining_pct,
        subtitle,
        resets_at,
    }];

    if let Some((used, total, expiry_days)) = parse_bonus_credits(stripped) {
        let bonus_used_pct = if total > 0.0 { ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32 } else { 0 };
        let bonus_expiry = expiry_days.map(|d| chrono::Utc::now().timestamp() + d * 86_400);
        windows.push(QuotaWindow {
            label: "Bonus Credits".into(),
            used_pct: bonus_used_pct,
            remaining_pct: 100 - bonus_used_pct,
            subtitle: Some(format!("{used:.2} / {total:.0} bonus")),
            resets_at: bonus_expiry,
        });
    }

    if overage_cost_usd.is_some() || overage_credits_used.is_some() {
        let mut parts = Vec::new();
        if let Some(u) = overage_credits_used {
            parts.push(format!("{u:.2} credits"));
        }
        if let Some(c) = overage_cost_usd {
            parts.push(format!("~${c:.2}"));
        }
        windows.push(QuotaWindow {
            label: "Vượt hạn mức".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: Some(if parts.is_empty() { "Đang bật".to_string() } else { parts.join(" · ") }),
            resets_at: None,
        });
    }

    let _ = plan_name; // Rust ProviderStatus has no plan_name field.
    Ok(ProviderStatus {
        id: "kiro".into(),
        display_name: "Kiro".into(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: account_email.map(String::from),
        credits_remaining: Some(credits_total - credits_used),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_percent_and_credits() {
        let output = "Plan: Q Developer Pro\n████████ 42%\n(21.00 of 50 covered in plan)\nresets on 2027-01-01\n";
        let s = parse_usage(output, Some("boss@example.com")).unwrap();
        assert!(s.error.is_none());
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.account_label.as_deref(), Some("boss@example.com"));
        assert!(s.windows[0].resets_at.is_some());
    }

    #[test]
    fn managed_plan_without_usage_defaults_to_full_remaining() {
        let output = "Plan: Enterprise\nManaged by Admin\n";
        let s = parse_usage(output, None).unwrap();
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].remaining_pct, 100);
    }

    #[test]
    fn empty_output_is_error() {
        assert!(parse_usage("", None).is_err());
    }

    #[test]
    fn no_recognizable_usage_is_error() {
        assert!(parse_usage("Some unrelated CLI banner text", None).is_err());
    }
}

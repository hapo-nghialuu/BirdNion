//! Kiro (AWS) quota provider — port of `KiroProvider.swift`.
//!
//! Resolves the `kiro` or `kiro-cli` binary from PATH, then runs (mirroring
//! CodexBar's KiroStatusProbe):
//!   - `kiro-cli whoami` — verifies login; parses email + auth method.
//!   - `kiro-cli chat --no-interactive /usage` — usage output with credits
//!     %, plan, reset date, bonus credits, overage status/cost.
//!   - `kiro-cli chat --no-interactive /context` — context-window % (best-effort).
//!   - `kiro-cli --version` — CLI version for the info grid (best-effort).
//! ANSI codes are stripped before parsing.
//!
//! Transport: pipes with an idle cutoff — once output starts, 4s (usage) of
//! silence ends the read with the text kept, since recent Kiro CLIs can keep
//! their TUI alive after printing. The macOS PTY fallback (for very old CLIs
//! that write nothing to pipes) is not ported: it needs a pty crate and those
//! releases predate the Linux CLI.

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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

    // whoami: email + auth method; its logged-out verdict upgrades a failed
    // usage probe into a clearer "not logged in" message.
    let whoami = run_command(&binary, &["whoami"], Duration::from_secs(3), Duration::from_millis(1500)).ok();
    let mut whoami_logged_out = false;
    let (email, auth_method) = match whoami.as_ref() {
        Some(res) => {
            if is_login_required(&res.output) {
                whoami_logged_out = true;
                (None, None)
            } else {
                parse_whoami(&strip_ansi(&res.output))
            }
        }
        None => (None, None),
    };

    let usage = match run_command(&binary, &["chat", "--no-interactive", "/usage"], Duration::from_secs(20), Duration::from_secs(4)) {
        Ok(o) => o,
        Err(e) => {
            if whoami_logged_out {
                return not_logged_in(id, name);
            }
            return ProviderStatus::failure(id, name, e);
        }
    };
    if is_login_required(&usage.output) {
        return not_logged_in(id, name);
    }
    let stripped = strip_ansi(&usage.output);
    // An idle-stopped result is fine when the parser understands it; a
    // naturally-exited result must have exit code 0.
    if usage.stopped_after_output {
        if parse_usage(&stripped, None, None, None, None).is_err() {
            return ProviderStatus::failure(id, name, "Kiro CLI timeout");
        }
    } else if usage.termination_status != 0 {
        let msg = stripped.trim();
        return ProviderStatus::failure(
            id,
            name,
            if msg.is_empty() {
                format!("kiro-cli thoát với code {}", usage.termination_status)
            } else {
                msg.to_string()
            },
        );
    }

    // Context breakdown + version are best-effort; never fail the fetch.
    let context_pct = run_command(&binary, &["chat", "--no-interactive", "/context"], Duration::from_secs(8), Duration::from_secs(3))
        .ok()
        .and_then(|res| parse_context_percent(&strip_ansi(&res.output)));
    let version = detect_version(&binary);

    match parse_usage(&stripped, email.as_deref(), auth_method.as_deref(), context_pct, version.as_deref()) {
        Ok(status) => status,
        Err(_) if whoami_logged_out => not_logged_in(id, name),
        Err(msg) => ProviderStatus::failure(id, name, msg),
    }
}

fn not_logged_in(id: &str, name: &str) -> ProviderStatus {
    ProviderStatus::failure(id, name, "Chưa đăng nhập Kiro. Chạy 'kiro-cli login' trong Terminal")
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

/// Runs `kiro-cli --version` (5s, best-effort); strips the "kiro-cli " prefix.
fn detect_version(binary: &str) -> Option<String> {
    let res = run_command(binary, &["--version"], Duration::from_secs(5), Duration::from_secs(2)).ok()?;
    if res.termination_status != 0 && !res.stopped_after_output {
        return None;
    }
    let stripped = strip_ansi(&res.output);
    let line = stripped.lines().map(str::trim).find(|l| !l.is_empty())?;
    Some(line.strip_prefix("kiro-cli ").unwrap_or(line).to_string())
}

struct KiroCliResult {
    output: String,
    termination_status: i32,
    /// The process was cut off by the idle/deadline watchdog after producing
    /// output — the text is usable but the exit status is not.
    stopped_after_output: bool,
}

/// Runs a kiro-cli subcommand with a hard deadline plus an idle cutoff:
/// reader threads drain stdout/stderr incrementally, and once output has
/// started, `idle_timeout` of silence ends the read with the text kept
/// (recent Kiro CLIs can keep their TUI alive after printing).
fn run_command(binary: &str, args: &[&str], timeout: Duration, idle_timeout: Duration) -> Result<KiroCliResult, String> {
    let mut child = Command::new(binary)
        .args(args)
        .env("TERM", "xterm-256color")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Không khởi động được kiro-cli: {e}"))?;

    struct Captured {
        stdout: Vec<u8>,
        stderr: Vec<u8>,
        last_activity: Option<Instant>,
    }
    let captured = Arc::new(Mutex::new(Captured { stdout: Vec::new(), stderr: Vec::new(), last_activity: None }));

    let mut readers = Vec::new();
    if let Some(mut out) = child.stdout.take() {
        let cap = Arc::clone(&captured);
        readers.push(std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = out.read(&mut buf) {
                if n == 0 { break; }
                let mut c = cap.lock().unwrap();
                c.stdout.extend_from_slice(&buf[..n]);
                c.last_activity = Some(Instant::now());
            }
        }));
    }
    if let Some(mut err) = child.stderr.take() {
        let cap = Arc::clone(&captured);
        readers.push(std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = err.read(&mut buf) {
                if n == 0 { break; }
                let mut c = cap.lock().unwrap();
                c.stderr.extend_from_slice(&buf[..n]);
                c.last_activity = Some(Instant::now());
            }
        }));
    }

    let start = Instant::now();
    let mut stopped_after_output = false;
    let exit_status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                let has_output = {
                    let c = captured.lock().unwrap();
                    c.last_activity.is_some()
                };
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    if !has_output {
                        return Err("Kiro CLI timeout".to_string());
                    }
                    stopped_after_output = true;
                    break None;
                }
                if has_output {
                    let idle = {
                        let c = captured.lock().unwrap();
                        c.last_activity.map(|t| t.elapsed()).unwrap_or_default()
                    };
                    if idle >= idle_timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        stopped_after_output = true;
                        break None;
                    }
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("kiro-cli lỗi: {e}")),
        }
    };
    for r in readers {
        let _ = r.join();
    }

    let c = captured.lock().unwrap();
    let stdout = String::from_utf8_lossy(&c.stdout).to_string();
    let stderr = String::from_utf8_lossy(&c.stderr).to_string();
    let combined = if stdout.trim().is_empty() { stderr } else { stdout };
    let termination_status = exit_status.and_then(|s| s.code()).unwrap_or(0);
    if !stopped_after_output && termination_status != 0 && combined.trim().is_empty() {
        return Err(format!("kiro-cli thoát với code {termination_status}"));
    }
    Ok(KiroCliResult { output: combined, termination_status, stopped_after_output })
}

/// Strips ANSI CSI and OSC escape sequences from CLI output.
fn strip_ansi(text: &str) -> String {
    let re = Regex::new(r"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07").unwrap();
    re.replace_all(text, "").to_string()
}

fn is_login_required(output: &str) -> bool {
    let lower = strip_ansi(output).to_lowercase();
    lower.contains("not logged in")
        || lower.contains("login required")
        || lower.contains("failed to initialize auth portal")
        || lower.contains("kiro-cli login")
        || lower.contains("oauth error")
}

/// Parses whoami output for email + auth method ("Logged in with X").
fn parse_whoami(stripped: &str) -> (Option<String>, Option<String>) {
    let mut email = None;
    let mut auth_method = None;
    for line in stripped.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        let lower = t.to_lowercase();
        if lower.contains("logged in with") {
            let val = Regex::new(r"(?i)^\s*logged in with\s+").unwrap().replace(t, "").trim().to_string();
            if !val.is_empty() {
                auth_method = Some(val);
            }
        } else if lower.contains("email:") {
            let val = Regex::new(r"(?i)^\s*email:\s*").unwrap().replace(t, "").trim().to_string();
            if !val.is_empty() {
                email = Some(val);
            }
        } else if email.is_none() && t.contains('@') && !t.contains(' ') {
            email = Some(t.to_string());
        }
    }
    (email, auth_method)
}

/// "Context window: 12.5% used" from `/context` output.
fn parse_context_percent(stripped: &str) -> Option<f64> {
    first_capture(stripped, r"(?i)Context window:\s*(\d+\.?\d*)%\s+used").and_then(|s| s.parse().ok())
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
            return display_plan_name(line);
        }
    }
    if let Some(m) = Regex::new(r"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)").unwrap().find(text) {
        let line = m.as_str();
        if let Some(plan) = line.split('|').last() {
            let plan = plan.trim();
            if !plan.is_empty() {
                return display_plan_name(plan);
            }
        }
    }
    if let Some(m) = Regex::new(r"\|[ \t]*(KIRO[ \t]+\w+)").unwrap().find(text) {
        let raw = m.as_str().replace('|', "");
        return display_plan_name(raw.trim());
    }
    "Kiro".to_string()
}

/// Whitespace-collapsed display form; KIRO-branded names get title-cased
/// ("KIRO  FREE" → "Kiro Free"), others pass through cleaned.
fn display_plan_name(raw: &str) -> String {
    let cleaned = Regex::new(r"\s+").unwrap().replace_all(raw.trim(), " ").to_string();
    if !cleaned.to_lowercase().contains("kiro") {
        return if cleaned.is_empty() { raw.to_string() } else { cleaned };
    }
    cleaned
        .split(' ')
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

fn bonus_window(bonus: Option<(f64, f64, Option<i64>)>) -> Option<QuotaWindow> {
    let (used, total, expiry_days) = bonus?;
    let bonus_used_pct = if total > 0.0 { ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32 } else { 0 };
    let bonus_expiry = expiry_days.map(|d| chrono::Utc::now().timestamp() + d * 86_400);
    Some(QuotaWindow {
        label: "Bonus Credits".into(),
        used_pct: bonus_used_pct,
        remaining_pct: 100 - bonus_used_pct,
        subtitle: Some(format!("{used:.2} / {total:.0} bonus")),
        resets_at: bonus_expiry,
        window_seconds: None,
    })
}

/// Overage window — shown when the plan reports pay-as-you-go usage or an
/// explicit "Overages: …" status line (Enabled/Disabled).
fn overage_window(status: Option<&str>, credits_used: Option<f64>, cost_usd: Option<f64>) -> Option<QuotaWindow> {
    if status.is_none() && credits_used.is_none() && cost_usd.is_none() {
        return None;
    }
    let mut parts = Vec::new();
    if let Some(u) = credits_used {
        parts.push(format!("{u:.2} credits"));
    }
    if let Some(c) = cost_usd {
        parts.push(format!("~${c:.2}"));
    }
    let subtitle = if parts.is_empty() {
        status.map(String::from).unwrap_or_else(|| "Đang bật".to_string())
    } else {
        parts.join(" · ")
    };
    Some(QuotaWindow {
        label: "Vượt hạn mức".into(),
        used_pct: 0,
        remaining_pct: 100,
        subtitle: Some(subtitle),
        resets_at: None,
        window_seconds: None,
    })
}

/// Main parse from stripped usage output → ProviderStatus. Mirrors
/// KiroStatusProbe's regex-based parsing (unit-tested).
pub fn parse_usage(
    stripped: &str,
    account_email: Option<&str>,
    auth_method: Option<&str>,
    context_percent: Option<f64>,
    version: Option<&str>,
) -> Result<ProviderStatus, String> {
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

    // Bonus + overage are parsed for every plan shape (managed included).
    let bonus = parse_bonus_credits(stripped);
    let overages_status = first_capture(stripped, r"(?i)Overages:\s*([^\n]+)")
        .map(|s| strip_ansi(&s).trim().to_string())
        .filter(|s| !s.is_empty());
    let overage_credits_used = first_capture(stripped, r"(?i)Credits used:\s*(\d+\.?\d*)").and_then(|s| s.parse::<f64>().ok());
    let overage_cost_usd = first_capture(stripped, r"(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD").and_then(|s| s.parse::<f64>().ok());
    let has_manage_url = stripped.contains("https://app.kiro.dev/account/usage");

    let lower = stripped.to_lowercase();
    let is_managed_plan = lower.contains("managed by admin") || lower.contains("managed by organization");
    let is_new_format = first_capture(stripped, r"Plan:[ \t]*(.+)").is_some();
    if is_new_format && is_managed_plan && !matched_percent && !matched_credits {
        // Managed plans hide plan credits but may still report bonus and
        // overage — keep those windows instead of dropping them.
        let mut windows = vec![QuotaWindow {
            label: "Credits".into(),
            used_pct: 0,
            remaining_pct: 100,
            subtitle: None,
            resets_at: None,
            window_seconds: None,
        }];
        if let Some(w) = bonus_window(bonus) {
            windows.push(w);
        }
        if let Some(w) = overage_window(overages_status.as_deref(), overage_credits_used, overage_cost_usd) {
            windows.push(w);
        }
        return Ok(ProviderStatus {
            id: "kiro".into(),
            display_name: "Kiro".into(),
            windows,
            last_updated: chrono::Utc::now().timestamp(),
            account_label: account_email.map(String::from),
            plan_name: Some(plan_name),
            source_label: auth_method.map(String::from),
            version: version.map(String::from),
            kiro_context_percent: context_percent,
            ..Default::default()
        });
    }

    if !matched_percent && !matched_credits {
        return Err("Không tìm thấy thông tin usage trong output kiro-cli".to_string());
    }

    let used_pct = (credits_percent.round() as i32).clamp(0, 100);
    let remaining_pct = 100 - used_pct;

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
        window_seconds: None,
    }];
    if let Some(w) = bonus_window(bonus) {
        windows.push(w);
    }
    if let Some(w) = overage_window(overages_status.as_deref(), overage_credits_used, overage_cost_usd) {
        windows.push(w);
    }

    Ok(ProviderStatus {
        id: "kiro".into(),
        display_name: "Kiro".into(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: account_email.map(String::from),
        credits_remaining: Some(credits_total - credits_used),
        plan_name: Some(plan_name),
        source_label: auth_method.map(String::from),
        version: version.map(String::from),
        kiro_context_percent: context_percent,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_percent_and_credits() {
        let output = "Plan: Q Developer Pro\n████████ 42%\n(21.00 of 50 covered in plan)\nresets on 2027-01-01\n";
        let s = parse_usage(output, Some("boss@example.com"), None, None, None).unwrap();
        assert!(s.error.is_none());
        assert_eq!(s.windows[0].used_pct, 42);
        assert_eq!(s.account_label.as_deref(), Some("boss@example.com"));
        assert_eq!(s.plan_name.as_deref(), Some("Q Developer Pro"));
        assert!(s.windows[0].resets_at.is_some());
    }

    #[test]
    fn full_output_with_auth_context_and_overage() {
        let output = "Plan: Q Developer Pro\n████████ 42%\n(21.00 of 50 covered in plan)\nBonus credits:\n10.00/100 credits used, expires in 88 days\nOverages: Enabled\nCredits used: 5.25\nEst. cost: $1.31 USD\n";
        let s = parse_usage(output, Some("boss@example.com"), Some("AWS Builder ID"), Some(12.5), Some("1.23.1")).unwrap();
        assert_eq!(s.windows.len(), 3);
        assert_eq!(s.windows[1].label, "Bonus Credits");
        assert_eq!(s.windows[1].used_pct, 10);
        assert_eq!(s.windows[2].subtitle.as_deref(), Some("5.25 credits · ~$1.31"));
        assert_eq!(s.source_label.as_deref(), Some("AWS Builder ID"));
        assert_eq!(s.version.as_deref(), Some("1.23.1"));
        assert_eq!(s.kiro_context_percent, Some(12.5));
        assert_eq!(s.credits_remaining, Some(29.0));
    }

    #[test]
    fn managed_plan_keeps_bonus_and_overage() {
        let output = "Plan: Enterprise\nManaged by Admin\nBonus credits:\n2.00/20 credits used, expires in 10 days\nOverages: Disabled\n";
        let s = parse_usage(output, None, None, None, None).unwrap();
        let labels: Vec<&str> = s.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, vec!["Credits", "Bonus Credits", "Vượt hạn mức"]);
        assert_eq!(s.windows[0].remaining_pct, 100);
        assert_eq!(s.windows[2].subtitle.as_deref(), Some("Disabled"));
    }

    #[test]
    fn whoami_parses_email_and_auth_method() {
        let (email, method) = parse_whoami("Logged in with AWS Builder ID\nEmail: boss@example.com\n");
        assert_eq!(email.as_deref(), Some("boss@example.com"));
        assert_eq!(method.as_deref(), Some("AWS Builder ID"));
    }

    #[test]
    fn context_percent_parses() {
        assert_eq!(parse_context_percent("Context window: 12.5% used"), Some(12.5));
        assert_eq!(parse_context_percent("no context"), None);
    }

    #[test]
    fn kiro_plan_names_are_title_cased() {
        assert_eq!(display_plan_name("KIRO  FREE"), "Kiro Free");
        assert_eq!(display_plan_name("Q Developer Pro"), "Q Developer Pro");
    }

    #[test]
    fn empty_output_is_error() {
        assert!(parse_usage("", None, None, None, None).is_err());
    }

    #[test]
    fn no_recognizable_usage_is_error() {
        assert!(parse_usage("Some unrelated CLI banner text", None, None, None, None).is_err());
    }
}

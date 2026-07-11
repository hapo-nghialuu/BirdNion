//! Kilo Code quota provider — port of `KiloProvider.swift`.
//!
//! Auth: config `apiKey` (or `KILO_API_KEY` env) first, then the Kilo CLI
//! session token at `~/.local/share/kilo/auth.json` (same as the macOS app)
//! with `$XDG_CONFIG_HOME/kilocode/auth.json` as a fallback.
//!
//! Endpoint: tRPC batch GET
//!   `https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod`
//!   `?batch=1&input={"0":{"json":null},"1":{"json":null},"2":{"json":null}}`
//! Response: array of `{result:{data:{json:<payload>}}}` or `{error:{...}}`
//! entries, one per procedure (index-aligned).

use serde_json::Value;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const BASE_URL: &str = "https://app.kilo.ai/api/trpc";
const PROCEDURES: [&str; 3] = ["user.getCreditBlocks", "kiloPass.getState", "user.getAutoTopUpPaymentMethod"];
const OPTIONAL_PROCEDURES: [&str; 1] = ["user.getAutoTopUpPaymentMethod"];

/// CLI session file candidates, first hit wins: the Swift app reads
/// `~/.local/share/kilo/auth.json`; the XDG config variant is kept as a
/// fallback for CLI builds that use it.
fn cli_auth_paths() -> Vec<std::path::PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let xdg = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| format!("{home}/.config"));
    vec![
        std::path::PathBuf::from(&home).join(".local/share/kilo/auth.json"),
        std::path::PathBuf::from(xdg).join("kilocode/auth.json"),
    ]
}

/// Resolves the bearer token: config `api_key` (or `KILO_API_KEY` env) first,
/// then the CLI session file. Returns `(token, label)`.
fn resolve_token(cfg: &config::Provider) -> Option<(String, String)> {
    if let Some(key) = config::api_key(cfg).or_else(|| std::env::var("KILO_API_KEY").ok().filter(|s| !s.trim().is_empty())) {
        let label = cfg.account_label.clone().unwrap_or_else(|| key.chars().take(8).collect());
        return Some((key, label));
    }
    let token = read_cli_token()?;
    let label = format!("{}… (CLI)", token.chars().take(8).collect::<String>());
    Some((token, label))
}

/// Reads the Kilo CLI session token from the first readable auth file.
/// Supports the nested `{"kilo":{"access":"..."}}` shape plus legacy
/// top-level `token`/`access_token` keys. Non-fatal on any I/O/parse error.
fn read_cli_token() -> Option<String> {
    cli_auth_paths()
        .into_iter()
        .find_map(|p| std::fs::read_to_string(p).ok())
        .and_then(|contents| parse_cli_token(&contents))
}

fn parse_cli_token(contents: &str) -> Option<String> {
    let json: Value = serde_json::from_str(contents).ok()?;
    if let Some(access) = json.get("kilo").and_then(|k| k.get("access")).and_then(Value::as_str) {
        let t = access.trim();
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }
    for key in ["token", "access_token"] {
        if let Some(t) = json.get(key).and_then(Value::as_str) {
            let trimmed = t.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn make_batch_url() -> Result<reqwest::Url, String> {
    let joined = PROCEDURES.join(",");
    let input = serde_json::to_string(
        &(0..PROCEDURES.len())
            .map(|i| (i.to_string(), serde_json::json!({"json": null})))
            .collect::<serde_json::Map<_, _>>(),
    )
    .map_err(|e| format!("Encoding input thất bại: {e}"))?;
    let base = format!("{BASE_URL}/{joined}");
    reqwest::Url::parse_with_params(&base, &[("batch", "1"), ("input", input.as_str())])
        .map_err(|e| format!("Không thể tạo URL batch: {e}"))
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let Some((token, label)) = resolve_token(cfg) else {
        return ProviderStatus::failure(&cfg.id, &name, "Chưa cấu hình API key cho Kilo Code (hoặc đăng nhập CLI)");
    };

    let url = match make_batch_url() {
        Ok(u) => u,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Lỗi tạo URL: {e}")),
    };

    let client = shared_client();
    let resp = client.get(url).bearer_auth(&token).header("Accept", "application/json").send().await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}")),
    };

    match resp.status().as_u16() {
        200..=299 => {}
        401 | 403 => return ProviderStatus::failure(&cfg.id, &name, "Xác thực thất bại. Kiểm tra lại API key."),
        404 => return ProviderStatus::failure(&cfg.id, &name, "Endpoint không tồn tại (HTTP 404). Kilo tRPC path có thể đã thay đổi."),
        code @ 500..=599 => return ProviderStatus::failure(&cfg.id, &name, format!("Kilo API tạm thời không khả dụng (HTTP {code}).")),
        code => return ProviderStatus::failure(&cfg.id, &name, format!("HTTP {code}")),
    }

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => return ProviderStatus::failure(&cfg.id, &name, format!("Network: {e}")),
    };
    parse_batch_response(&bytes, &cfg.id, &name, &label)
}

/// Pure tRPC batch response → ProviderStatus (unit-tested).
fn parse_batch_response(bytes: &[u8], id: &str, name: &str, account_label: &str) -> ProviderStatus {
    let root: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(_) => return ProviderStatus::failure(id, name, "Response JSON không hợp lệ"),
    };
    let Some(entries) = response_entries(&root) else {
        return ProviderStatus::failure(id, name, "Định dạng tRPC batch không nhận ra");
    };

    let mut payloads: [Option<&Value>; 3] = [None, None, None];
    for (index, procedure) in PROCEDURES.iter().enumerate() {
        let Some(entry) = entries.get(&index) else { continue };
        if let Some(err) = trpc_error(entry) {
            if !OPTIONAL_PROCEDURES.contains(procedure) {
                return ProviderStatus::failure(id, name, err);
            }
            continue;
        }
        payloads[index] = result_payload(entry);
    }

    let credit_snap = parse_credits(payloads[0]);
    let pass_snap = parse_pass(payloads[1]);
    let base_plan = parse_plan_name(payloads[1]);
    let auto_top_up = parse_auto_top_up(payloads[2]);
    let plan_name = decorate_plan_name(base_plan, &auto_top_up);
    let now = chrono::Utc::now().timestamp();

    let mut windows = Vec::new();
    if let Some(total) = credit_snap.total.filter(|t| *t > 0.0) {
        let used = credit_snap.used.unwrap_or(0.0);
        let used_pct = ((used / total) * 100.0).round().clamp(0.0, 100.0) as i32;
        windows.push(QuotaWindow {
            label: "Credits".into(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: Some(format!("${used:.2} / ${total:.2}")),
            resets_at: None,
            window_seconds: None,
        });
    } else if credit_snap.total == Some(0.0) {
        windows.push(QuotaWindow {
            label: "Credits".into(),
            used_pct: 100,
            remaining_pct: 0,
            subtitle: Some("$0.00 / $0.00".into()),
            resets_at: None,
            window_seconds: None,
        });
    }

    if let Some(pass_total) = pass_snap.total.filter(|t| *t > 0.0) {
        let pass_used = pass_snap.used.unwrap_or(0.0);
        let bonus = pass_snap.bonus.unwrap_or(0.0);
        let base_credits = (pass_total - bonus).max(0.0);
        let used_pct = ((pass_used / pass_total) * 100.0).round().clamp(0.0, 100.0) as i32;
        let mut subtitle = format!("${pass_used:.2} / ${base_credits:.2}");
        if bonus > 0.0 {
            subtitle += &format!(" (+ ${bonus:.2} bonus)");
        }
        windows.push(QuotaWindow {
            label: "Kilo Pass".into(),
            used_pct,
            remaining_pct: 100 - used_pct,
            subtitle: Some(subtitle),
            resets_at: pass_snap.resets_at,
            window_seconds: None,
        });
    }

    let account_label_final = match &plan_name {
        Some(p) if !p.is_empty() => format!("{account_label} · {p}"),
        _ => account_label.to_string(),
    };

    ProviderStatus {
        id: id.to_string(),
        display_name: name.to_string(),
        windows,
        last_updated: now,
        account_label: Some(account_label_final),
        credits_remaining: credit_snap.remaining,
        ..Default::default()
    }
}

fn response_entries(root: &Value) -> Option<std::collections::HashMap<usize, Value>> {
    if let Some(arr) = root.as_array() {
        return Some(arr.iter().take(PROCEDURES.len()).cloned().enumerate().collect());
    }
    if let Some(obj) = root.as_object() {
        if obj.contains_key("result") || obj.contains_key("error") {
            return Some(std::collections::HashMap::from([(0, root.clone())]));
        }
        let indexed: std::collections::HashMap<usize, Value> = obj
            .iter()
            .filter_map(|(k, v)| k.parse::<usize>().ok().filter(|i| *i < PROCEDURES.len()).map(|i| (i, v.clone())))
            .collect();
        if !indexed.is_empty() {
            return Some(indexed);
        }
    }
    None
}

fn trpc_error(entry: &Value) -> Option<String> {
    let error_obj = entry.get("error")?;
    let code = nested_string(error_obj, &["json", "data", "code"])
        .or_else(|| nested_string(error_obj, &["data", "code"]))
        .or_else(|| nested_string(error_obj, &["code"]));
    let message = nested_string(error_obj, &["json", "message"]).or_else(|| nested_string(error_obj, &["message"]));
    let combined = [&code, &message].iter().filter_map(|s| s.as_deref()).collect::<Vec<_>>().join(" ").to_lowercase();
    if combined.contains("unauthorized") || combined.contains("forbidden") {
        return Some("Xác thực thất bại. Kiểm tra lại API key.".to_string());
    }
    Some(format!("Lỗi tRPC: {}", code.or(message).unwrap_or_else(|| "unknown".to_string())))
}

fn nested_string(v: &Value, path: &[&str]) -> Option<String> {
    let mut cursor = v;
    for key in path {
        cursor = cursor.get(key)?;
    }
    cursor.as_str().map(String::from)
}

fn result_payload(entry: &Value) -> Option<&Value> {
    let result = entry.get("result")?;
    if let Some(data_obj) = result.get("data") {
        if let Some(json) = data_obj.get("json") {
            return if json.is_null() { None } else { Some(json) };
        }
        return Some(data_obj);
    }
    if let Some(json) = result.get("json") {
        return if json.is_null() { None } else { Some(json) };
    }
    None
}

struct CreditSnapshot {
    used: Option<f64>,
    total: Option<f64>,
    remaining: Option<f64>,
}

fn parse_credits(payload: Option<&Value>) -> CreditSnapshot {
    let Some(payload) = payload else { return CreditSnapshot { used: None, total: None, remaining: None } };

    if let Some(blocks) = payload.get("creditBlocks").and_then(Value::as_array) {
        let mut total_sum = 0.0;
        let mut remain_sum = 0.0;
        let mut saw_total = false;
        let mut saw_remain = false;
        for block in blocks {
            if let Some(amt) = block.get("amount_mUsd").and_then(Value::as_f64) {
                total_sum += amt / 1_000_000.0;
                saw_total = true;
            }
            if let Some(bal) = block.get("balance_mUsd").and_then(Value::as_f64) {
                remain_sum += bal / 1_000_000.0;
                saw_remain = true;
            }
        }
        if saw_total || saw_remain {
            let total = saw_total.then(|| total_sum.max(0.0));
            let remaining = saw_remain.then(|| remain_sum.max(0.0));
            let used = total.zip(remaining).map(|(t, r)| (t - r).max(0.0));
            return CreditSnapshot { used, total, remaining };
        }
    }

    if let Some(bal_milli) = payload.get("totalBalance_mUsd").and_then(Value::as_f64) {
        let bal = (bal_milli / 1_000_000.0).max(0.0);
        return CreditSnapshot { used: Some(0.0), total: Some(bal), remaining: Some(bal) };
    }

    CreditSnapshot {
        used: payload.get("used").and_then(Value::as_f64),
        total: payload.get("total").and_then(Value::as_f64),
        remaining: payload.get("remaining").and_then(Value::as_f64),
    }
}

struct PassSnapshot {
    used: Option<f64>,
    total: Option<f64>,
    bonus: Option<f64>,
    resets_at: Option<i64>,
}

fn subscription_data(payload: Option<&Value>) -> Option<&Value> {
    let payload = payload?;
    if let Some(sub) = payload.get("subscription") {
        return if sub.is_null() { None } else { Some(sub) };
    }
    let has_shape = payload.get("currentPeriodUsageUsd").is_some()
        || payload.get("currentPeriodBaseCreditsUsd").is_some()
        || payload.get("tier").is_some();
    has_shape.then_some(payload)
}

fn parse_pass(payload: Option<&Value>) -> PassSnapshot {
    let Some(sub) = subscription_data(payload) else {
        return PassSnapshot { used: None, total: None, bonus: None, resets_at: None };
    };
    let used = sub.get("currentPeriodUsageUsd").and_then(Value::as_f64).map(|v| v.max(0.0));
    let base = sub.get("currentPeriodBaseCreditsUsd").and_then(Value::as_f64).map(|v| v.max(0.0));
    let bonus = sub.get("currentPeriodBonusCreditsUsd").and_then(Value::as_f64).unwrap_or(0.0).max(0.0);
    let total = base.map(|b| b + bonus);
    let resets_at = ["nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt"]
        .iter()
        .find_map(|k| sub.get(k).and_then(parse_date));
    PassSnapshot { used, total, bonus: (bonus > 0.0).then_some(bonus), resets_at }
}

fn parse_plan_name(payload: Option<&Value>) -> Option<String> {
    let sub = subscription_data(payload)?;
    let tier = sub.get("tier").and_then(Value::as_str)?.trim();
    if tier.is_empty() {
        return Some("Kilo Pass".to_string());
    }
    Some(plan_name_for_tier(tier))
}

fn plan_name_for_tier(tier: &str) -> String {
    match tier {
        "tier_19" => "Starter".to_string(),
        "tier_49" => "Pro".to_string(),
        "tier_199" => "Expert".to_string(),
        other => other.to_string(),
    }
}

struct AutoTopUpSnapshot {
    enabled: Option<bool>,
    method: Option<String>,
}

fn parse_auto_top_up(payload: Option<&Value>) -> AutoTopUpSnapshot {
    let Some(obj) = payload else { return AutoTopUpSnapshot { enabled: None, method: None } };
    let enabled = obj
        .get("enabled")
        .or_else(|| obj.get("isEnabled"))
        .or_else(|| obj.get("active"))
        .and_then(Value::as_bool);
    let method = obj
        .get("paymentMethod")
        .or_else(|| obj.get("paymentMethodType"))
        .or_else(|| obj.get("method"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    AutoTopUpSnapshot { enabled, method }
}

fn decorate_plan_name(base: Option<String>, auto_top_up: &AutoTopUpSnapshot) -> Option<String> {
    if auto_top_up.enabled != Some(true) {
        return base;
    }
    let top_up_label = match &auto_top_up.method {
        Some(m) if !m.is_empty() => format!("Auto top-up: {m}"),
        _ => "Auto top-up: enabled".to_string(),
    };
    match base {
        Some(b) if !b.is_empty() => Some(format!("{b} · {top_up_label}")),
        _ => Some(top_up_label),
    }
}

fn parse_date(v: &Value) -> Option<i64> {
    if let Some(n) = v.as_f64() {
        return Some(epoch_to_ts(n));
    }
    let s = v.as_str()?.trim();
    if s.is_empty() {
        return None;
    }
    if let Ok(n) = s.parse::<f64>() {
        return Some(epoch_to_ts(n));
    }
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp())
}

fn epoch_to_ts(value: f64) -> i64 {
    let seconds = if value.abs() > 10_000_000_000.0 { value / 1000.0 } else { value };
    seconds as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_cli_token_nested_shape() {
        let raw = r#"{"kilo":{"access":"tok-123"}}"#;
        assert_eq!(parse_cli_token(raw).as_deref(), Some("tok-123"));
    }

    #[test]
    fn parses_cli_token_legacy_shape() {
        let raw = r#"{"access_token":"legacy-tok"}"#;
        assert_eq!(parse_cli_token(raw).as_deref(), Some("legacy-tok"));
    }

    #[test]
    fn malformed_cli_token_json_is_none() {
        assert!(parse_cli_token("not json").is_none());
        assert!(parse_cli_token(r#"{"other":1}"#).is_none());
    }

    #[test]
    fn parses_full_batch_response_credits_and_pass() {
        let body = json!([
            {"result": {"data": {"json": {"creditBlocks": [{"amount_mUsd": 10_000_000, "balance_mUsd": 6_800_000}]}}}},
            {"result": {"data": {"json": {"subscription": {"tier": "tier_49", "currentPeriodUsageUsd": 12.5, "currentPeriodBaseCreditsUsd": 49.0, "nextBillingAt": "2026-08-01T00:00:00Z"}}}}},
            {"result": {"data": {"json": {"enabled": true, "paymentMethod": "visa"}}}}
        ]);
        let bytes = serde_json::to_vec(&body).unwrap();
        let s = parse_batch_response(&bytes, "kilo", "Kilo", "sk-12345678");
        assert_eq!(s.windows.len(), 2);
        assert_eq!(s.windows[0].label, "Credits");
        assert_eq!(s.windows[0].used_pct, 32);
        assert_eq!(s.windows[1].label, "Kilo Pass");
        assert!(s.account_label.unwrap().contains("Pro"));
        assert!((s.credits_remaining.unwrap() - 6.8).abs() < 0.001);
    }

    #[test]
    fn unauthorized_trpc_error_is_surfaced() {
        let body = json!([{"error": {"json": {"data": {"code": "UNAUTHORIZED"}, "message": "no"}}}]);
        let bytes = serde_json::to_vec(&body).unwrap();
        let s = parse_batch_response(&bytes, "kilo", "Kilo", "label");
        assert_eq!(s.error.as_deref(), Some("Xác thực thất bại. Kiểm tra lại API key."));
    }

    #[test]
    fn optional_procedure_error_is_non_fatal() {
        let body = json!([
            {"result": {"data": {"json": {"creditBlocks": [{"amount_mUsd": 1_000_000, "balance_mUsd": 500_000}]}}}},
            {"result": {"data": {"json": null}}},
            {"error": {"message": "not found"}}
        ]);
        let bytes = serde_json::to_vec(&body).unwrap();
        let s = parse_batch_response(&bytes, "kilo", "Kilo", "label");
        assert!(s.error.is_none());
        assert_eq!(s.windows.len(), 1);
    }

    #[test]
    fn invalid_json_is_error() {
        let s = parse_batch_response(b"not json", "kilo", "Kilo", "label");
        assert_eq!(s.error.as_deref(), Some("Response JSON không hợp lệ"));
    }

    #[test]
    fn zero_balance_is_explicit_exhausted_window() {
        let body = json!([
            {"result": {"data": {"json": {"totalBalance_mUsd": 0}}}},
            {"result": {"data": {"json": null}}},
            {"result": {"data": {"json": null}}}
        ]);
        let bytes = serde_json::to_vec(&body).unwrap();
        let s = parse_batch_response(&bytes, "kilo", "Kilo", "label");
        assert_eq!(s.windows.len(), 1);
        assert_eq!(s.windows[0].used_pct, 100);
    }
}

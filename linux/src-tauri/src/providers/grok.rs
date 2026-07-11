//! Grok (xAI) quota provider — port of macOS `GrokProvider` (web billing path).
//!
//! Reads `~/.grok/auth.json` (or `$GROK_HOME/auth.json`) for bearer + identity,
//! then POSTs empty gRPC-web body to GetGrokCreditsConfig.

use serde_json::Value;
use std::path::PathBuf;

use crate::config;
use crate::providers::{display_name, shared_client, ProviderStatus, QuotaWindow};

const BILLING_URL: &str =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let name = display_name(cfg);
    let creds = match load_credentials() {
        Ok(c) => c,
        Err(e) => {
            return ProviderStatus::failure(
                &cfg.id,
                &name,
                format!("{e}. Chạy `grok login` hoặc đăng nhập grok.com."),
            )
        }
    };

    match fetch_web_billing(&creds.token).await {
        Ok((used_pct, resets_at)) => {
            let used = used_pct.round().clamp(0.0, 100.0) as i32;
            let label = cycle_label(resets_at);
            ProviderStatus {
                id: cfg.id.clone(),
                display_name: name,
                windows: vec![QuotaWindow {
                    label,
                    used_pct: used,
                    remaining_pct: 100 - used,
                    subtitle: None,
                    resets_at,
                    window_seconds: None,
                }],
                last_updated: chrono::Utc::now().timestamp(),
                account_label: cfg
                    .account_label
                    .clone()
                    .or(creds.email),
                // macOS parity: planName = loginMethod, source "grok-web".
                plan_name: creds.login_method,
                source_label: Some("grok-web".to_string()),
                ..Default::default()
            }
        }
        Err(e) => {
            // Identity-only when billing fails but auth file exists.
            if creds.email.is_some() {
                ProviderStatus {
                    id: cfg.id.clone(),
                    display_name: name,
                    windows: vec![],
                    last_updated: chrono::Utc::now().timestamp(),
                    error: Some(e),
                    account_label: cfg.account_label.clone().or(creds.email),
                    ..Default::default()
                }
            } else {
                ProviderStatus::failure(&cfg.id, &name, e)
            }
        }
    }
}

struct GrokCreds {
    token: String,
    email: Option<String>,
    /// macOS `GrokCredentials.loginMethod`: oidc → "SuperGrok", legacy
    /// browser-session entries → "session".
    login_method: Option<String>,
}

fn grok_home() -> PathBuf {
    if let Ok(h) = std::env::var("GROK_HOME") {
        let h = h.trim();
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    dirs_home().join(".grok")
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

fn load_credentials() -> Result<GrokCreds, String> {
    let path = grok_home().join("auth.json");
    let data = std::fs::read_to_string(&path).map_err(|_| {
        "Grok auth.json not found".to_string()
    })?;
    let root: Value = serde_json::from_str(&data).map_err(|e| format!("auth.json: {e}"))?;
    let obj = root.as_object().ok_or("auth.json invalid")?;

    let mut oidc: Option<(&str, &Value)> = None;
    let mut legacy: Option<(&str, &Value)> = None;
    for (scope, entry) in obj {
        let key = entry.get("key").and_then(Value::as_str).unwrap_or("");
        if key.is_empty() {
            continue;
        }
        if scope.starts_with("https://auth.x.ai::") {
            oidc = Some((scope.as_str(), entry));
        } else if scope.contains("sign-in") {
            legacy = Some((scope.as_str(), entry));
        }
    }
    let is_oidc = oidc.is_some();
    let entry = oidc.or(legacy).ok_or("auth.json missing tokens")?.1;
    let token = entry
        .get("key")
        .and_then(Value::as_str)
        .ok_or("missing key")?
        .to_string();
    let email = entry
        .get("email")
        .and_then(Value::as_str)
        .map(str::to_string);
    let login_method = Some(if is_oidc { "SuperGrok" } else { "session" }.to_string());
    Ok(GrokCreds { token, email, login_method })
}

async fn fetch_web_billing(token: &str) -> Result<(f64, Option<i64>), String> {
    let client = shared_client();
    // Empty gRPC-web frame: flags=0 + 4-byte big-endian length 0
    let body = vec![0u8, 0, 0, 0, 0];
    let resp = client
        .post(BILLING_URL)
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/grpc-web+proto")
        .header("x-grpc-web", "1")
        .header("x-user-agent", "connect-es/2.1.1")
        .header("Accept", "*/*")
        .header("Origin", "https://grok.com")
        .header("Referer", "https://grok.com/?_s=usage")
        .header("User-Agent", "BirdNion/1.0")
        .body(body)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    // gRPC status can ride in the HTTP headers on trailers-only responses.
    if let Some(err) = grpc_status_error(
        resp.headers().get("grpc-status").and_then(|v| v.to_str().ok()),
        resp.headers().get("grpc-message").and_then(|v| v.to_str().ok()),
    ) {
        return Err(err);
    }
    let bytes = resp.bytes().await.map_err(|e| format!("Network: {e}"))?;
    if let Some(err) = grpc_trailer_error(&bytes) {
        return Err(err);
    }
    parse_grpc_web_usage(&bytes, chrono::Utc::now().timestamp())
}

/// Non-zero `grpc-status` → human error (auth failures get a re-login hint)
/// — port of `GrokWebBillingError.rpcFailed` + `isAuthenticationFailure`.
fn grpc_status_error(status: Option<&str>, message: Option<&str>) -> Option<String> {
    let status: i64 = status?.trim().parse().ok()?;
    if status == 0 {
        return None;
    }
    let message = message.unwrap_or("").to_string();
    let lower = message.to_lowercase();
    let is_auth = status == 16
        || (status == 7
            && (lower.contains("bad-credentials")
                || lower.contains("unauthenticated")
                || lower.contains("access token")
                || lower.contains("could not be validated")));
    Some(if is_auth {
        "Grok từ chối đăng nhập — đăng nhập lại grok.com hoặc chạy `grok login`.".to_string()
    } else {
        format!("Grok billing RPC lỗi {status}: {message}")
    })
}

/// Scans trailer frames (flags & 0x80) for `grpc-status`/`grpc-message`.
fn grpc_trailer_error(data: &[u8]) -> Option<String> {
    let mut i = 0usize;
    while i + 5 <= data.len() {
        let flags = data[i];
        let len = u32::from_be_bytes([data[i + 1], data[i + 2], data[i + 3], data[i + 4]]) as usize;
        let start = i + 5;
        let end = start.checked_add(len)?;
        if end > data.len() {
            return None;
        }
        if flags & 0x80 != 0 {
            let text = String::from_utf8_lossy(&data[start..end]);
            let mut status = None;
            let mut message = None;
            for line in text.lines() {
                let Some((k, v)) = line.split_once(':') else { continue };
                match k.trim().to_lowercase().as_str() {
                    "grpc-status" => status = Some(v.trim().to_string()),
                    "grpc-message" => message = Some(v.trim().to_string()),
                    _ => {}
                }
            }
            if let Some(err) = grpc_status_error(status.as_deref(), message.as_deref()) {
                return Some(err);
            }
        }
        i = end;
    }
    None
}

// --- structured protobuf scan — port of macOS GrokWebBillingFetcher --------
//
// The old implementation scanned EVERY byte offset for a plausible f32 in
// 0..=100 and stopped at the first non-zero hit — misaligned garbage floats
// near the payload start made it report "0% used" while macOS showed 47%.
// macOS walks the protobuf structure instead: `credit_usage_percent` is the
// fixed32 at field #1 (shallowest path wins), the reset timestamp prefers
// path [1,5,1], and "no usage yet" only counts when a usage period exists.

#[derive(Default)]
struct ProtobufScan {
    fixed32: Vec<(Vec<u64>, f32, usize)>,
    varints: Vec<(Vec<u64>, u64)>,
}

fn scan_protobuf(bytes: &[u8], depth: usize, path: &mut Vec<u64>, order: &mut usize, scan: &mut ProtobufScan) {
    let mut i = 0usize;
    while i < bytes.len() {
        let field_start = i;
        let Some((key, key_len)) = read_varint(&bytes[i..]) else {
            i = field_start + 1;
            continue;
        };
        if key == 0 {
            i = field_start + 1;
            continue;
        }
        i += key_len;
        let field_number = key >> 3;
        let wire_type = key & 0x07;
        path.push(field_number);
        match wire_type {
            0 => {
                if let Some((value, n)) = read_varint(&bytes[i..]) {
                    scan.varints.push((path.clone(), value));
                    i += n;
                } else {
                    path.pop();
                    i = field_start + 1;
                    continue;
                }
            }
            1 => {
                if i + 8 > bytes.len() {
                    path.pop();
                    return;
                }
                i += 8;
            }
            2 => {
                let Some((len, n)) = read_varint(&bytes[i..]) else {
                    path.pop();
                    i = field_start + 1;
                    continue;
                };
                let len = len as usize;
                if len > bytes.len() - i - n {
                    path.pop();
                    i = field_start + 1;
                    continue;
                }
                i += n;
                if depth < 4 {
                    scan_protobuf(&bytes[i..i + len], depth + 1, path, order, scan);
                }
                i += len;
            }
            5 => {
                if i + 4 > bytes.len() {
                    path.pop();
                    return;
                }
                let bits = u32::from_le_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
                scan.fixed32.push((path.clone(), f32::from_bits(bits), *order));
                *order += 1;
                i += 4;
            }
            _ => {
                path.pop();
                i = field_start + 1;
                continue;
            }
        }
        path.pop();
    }
}

fn grpc_web_data_frames(data: &[u8]) -> Vec<&[u8]> {
    let mut frames = Vec::new();
    let mut i = 0usize;
    while i < data.len() {
        if i + 5 > data.len() {
            return Vec::new();
        }
        let flags = data[i];
        let len = u32::from_be_bytes([data[i + 1], data[i + 2], data[i + 3], data[i + 4]]) as usize;
        let start = i + 5;
        let Some(end) = start.checked_add(len) else { return Vec::new() };
        if end > data.len() {
            return Vec::new();
        }
        if flags & 0x80 == 0 {
            frames.push(&data[start..end]);
        }
        i = end;
    }
    frames
}

fn looks_like_protobuf(data: &[u8]) -> bool {
    data.first()
        .map(|b| {
            let field = b >> 3;
            let wire = b & 0x07;
            field > 0 && matches!(wire, 0 | 1 | 2 | 5)
        })
        .unwrap_or(false)
}

/// `(used_percent, resets_at)` — port of `parseGRPCWebResponse`.
fn parse_grpc_web_usage(data: &[u8], now: i64) -> Result<(f64, Option<i64>), String> {
    let mut frames = grpc_web_data_frames(data);
    if frames.is_empty() && looks_like_protobuf(data) {
        frames = vec![data];
    }
    if frames.is_empty() {
        return Err("Grok billing: response không có payload protobuf".to_string());
    }

    let mut scan = ProtobufScan::default();
    let mut order = 0usize;
    for frame in &frames {
        scan_protobuf(frame, 0, &mut Vec::new(), &mut order, &mut scan);
    }

    // credit_usage_percent: fixed32 at field #1 — shallowest path, then
    // earliest occurrence.
    let percent = scan
        .fixed32
        .iter()
        .filter(|(path, value, _)| {
            path.last() == Some(&1) && value.is_finite() && (0.0..=100.0).contains(value)
        })
        .min_by_key(|(path, _, order)| (path.len(), *order))
        .map(|(_, value, _)| *value as f64);

    // Reset timestamp: plausible future unix seconds; prefer path [1,5,1].
    let reset_fields: Vec<(&[u64], i64)> = scan
        .varints
        .iter()
        .filter_map(|(path, value)| {
            if (1_700_000_000..=2_100_000_000).contains(value) && (*value as i64) > now {
                Some((path.as_slice(), *value as i64))
            } else {
                None
            }
        })
        .collect();
    let reset = reset_fields
        .iter()
        .filter(|(path, _)| *path == [1, 5, 1])
        .map(|(_, ts)| *ts)
        .min()
        .or_else(|| reset_fields.iter().map(|(_, ts)| *ts).min());

    // "No usage yet": zero only when the payload proves a usage period exists.
    let has_usage_period = scan.varints.iter().any(|(path, value)| {
        path.starts_with(&[1, 6]) || (path.as_slice() == [1, 8, 1] && (*value == 1 || *value == 2))
    });
    let no_usage_yet = percent.is_none() && scan.fixed32.is_empty() && reset.is_some() && has_usage_period;

    let pct = percent
        .or(if no_usage_yet { Some(0.0) } else { None })
        .ok_or_else(|| "Không parse được usage Grok".to_string())?;
    Ok((pct, reset))
}

fn read_varint(data: &[u8]) -> Option<(u64, usize)> {
    let mut result = 0u64;
    let mut shift = 0;
    for (i, b) in data.iter().enumerate() {
        result |= ((*b as u64) & 0x7f) << shift;
        if *b & 0x80 == 0 {
            return Some((result, i + 1));
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
    None
}

fn cycle_label(resets_at: Option<i64>) -> String {
    let Some(ts) = resets_at else {
        return "Credits".into();
    };
    let now = chrono::Utc::now().timestamp();
    let days = ((ts - now) as f64 / 86400.0).round() as i64;
    if (4..=12).contains(&days) {
        "Tuần".into()
    } else if (20..=45).contains(&days) {
        "Tháng".into()
    } else {
        "Credits".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cycle_label_weekly() {
        let now = chrono::Utc::now().timestamp();
        assert_eq!(cycle_label(Some(now + 6 * 86400)), "Tuần");
        assert_eq!(cycle_label(Some(now + 30 * 86400)), "Tháng");
        assert_eq!(cycle_label(None), "Credits");
    }

    // --- protobuf test builders ---------------------------------------

    fn varint_bytes(mut v: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let byte = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(byte);
                break;
            }
            out.push(byte | 0x80);
        }
        out
    }

    fn key(num: u64, wire: u64) -> Vec<u8> {
        varint_bytes((num << 3) | wire)
    }

    fn varint_field(num: u64, v: u64) -> Vec<u8> {
        [key(num, 0), varint_bytes(v)].concat()
    }

    fn fixed32_field(num: u64, v: f32) -> Vec<u8> {
        [key(num, 5), v.to_le_bytes().to_vec()].concat()
    }

    fn len_delim(num: u64, inner: &[u8]) -> Vec<u8> {
        [key(num, 2), varint_bytes(inner.len() as u64), inner.to_vec()].concat()
    }

    fn grpc_frame(payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8];
        out.extend((payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    const NOW: i64 = 1_800_000_000;
    const RESET: u64 = 1_800_300_000;

    #[test]
    fn parses_percent_at_field_one_ignoring_garbage_floats() {
        // message { 1: { 2: garbage-denormal, 1: 47.0, 5: { 1: reset } } }
        // The old byte-scanner locked onto the first random f32 in 0..=100
        // (misaligned/denormal garbage) and reported 0% used.
        let inner5 = varint_field(1, RESET);
        let inner1 = [
            fixed32_field(2, 1.5e-39_f32), // field #2 → must be ignored
            fixed32_field(1, 47.0),
            len_delim(5, &inner5),
        ]
        .concat();
        let payload = len_delim(1, &inner1);
        let (pct, reset) = parse_grpc_web_usage(&grpc_frame(&payload), NOW).unwrap();
        assert!((pct - 47.0).abs() < 0.01);
        assert_eq!(reset, Some(RESET as i64));
    }

    #[test]
    fn shallowest_field_one_float_wins() {
        // Deep [1,3,1] float must lose to the shallow [1,1] float.
        let deep = len_delim(3, &fixed32_field(1, 99.0));
        let inner1 = [deep, fixed32_field(1, 12.0)].concat();
        let payload = len_delim(1, &inner1);
        let (pct, _) = parse_grpc_web_usage(&grpc_frame(&payload), NOW).unwrap();
        assert!((pct - 12.0).abs() < 0.01);
    }

    #[test]
    fn missing_percent_with_usage_period_is_zero_used() {
        // No fixed32 at all + future reset + usage-period marker ([1,6,…]).
        let inner5 = varint_field(1, RESET);
        let inner6 = varint_field(1, 2);
        let inner1 = [len_delim(5, &inner5), len_delim(6, &inner6)].concat();
        let payload = len_delim(1, &inner1);
        let (pct, reset) = parse_grpc_web_usage(&grpc_frame(&payload), NOW).unwrap();
        assert_eq!(pct, 0.0);
        assert_eq!(reset, Some(RESET as i64));
    }

    #[test]
    fn missing_percent_without_usage_period_is_parse_error() {
        let inner1 = len_delim(5, &varint_field(1, RESET));
        let payload = len_delim(1, &inner1);
        assert!(parse_grpc_web_usage(&grpc_frame(&payload), NOW).is_err());
    }

    #[test]
    fn trailer_grpc_status_surfaces_error() {
        let text = b"grpc-status: 16\r\ngrpc-message: unauthenticated";
        let mut data = vec![0x80u8];
        data.extend((text.len() as u32).to_be_bytes());
        data.extend_from_slice(text);
        let err = grpc_trailer_error(&data).unwrap();
        assert!(err.contains("grok login"));
        // Status 0 must stay silent.
        let ok = b"grpc-status: 0";
        let mut data0 = vec![0x80u8];
        data0.extend((ok.len() as u32).to_be_bytes());
        data0.extend_from_slice(ok);
        assert!(grpc_trailer_error(&data0).is_none());
    }
}

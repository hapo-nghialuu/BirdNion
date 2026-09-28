import Foundation
import JavaScriptCore

// JavaScript provider plugins, compatible with CodexBar's `defineProvider()`
// contract (see docs/codexbar-upstream-research.md and upstream
// `Resources/Plugins/codexbar-plugin.d.ts`). Each plugin file calls
// `defineProvider({id, name, endpoints, auth, settings, fetchUsage(ctx)})`;
// `fetchUsage` may be async — every ctx bridge resolves synchronously, so the
// whole continuation chain lands in the JSContext microtask queue and settles
// when `evaluateScript` returns.

// MARK: - Manifest

struct PluginAuth: Decodable {
    /// "bearer" | "x-api-key" | "header" | "authorization-scheme"
    let type: String
    /// Settings key whose secret is injected (e.g. "ATLASCLOUD_API_KEY").
    let secret: String
    /// For type "header".
    let header: String?
    /// For type "authorization-scheme" (e.g. "Basic").
    let scheme: String?
}

struct PluginSetting: Decodable {
    let key: String
    let title: String
    let subtitle: String?
    let type: String? // "plain" | "secure"
}

/// Endpoints may be plain origin strings or `{setting, policy}` objects —
/// the URL comes from a user setting, so the origin is resolved at fetch time.
enum PluginEndpoint {
    case origin(URL)
    case setting(key: String, policy: String)
}

struct PluginManifest {
    let id: String
    let name: String
    let iconMonogram: String?
    let iconTint: String?
    let topLevel: Bool
    let endpoints: [PluginEndpoint]
    let auth: PluginAuth?
    let settings: [PluginSetting]
    let capabilities: Set<String>
}

// MARK: - Errors

enum PluginFailKind: String {
    case authenticationExpired, missingCredential, permissionDenied
    case rateLimited, providerUnavailable, parseFailure, networkFailure, apiFailure
}

struct PluginFetchError: Error {
    let kind: PluginFailKind
    let message: String
}

enum PluginEngineError: Error {
    case invalidDefinition(String)
    case duplicateID(String)
    case endpointNotAllowed(String)
    case engineFailure(String)
}

// MARK: - Snapshot model (CodexBarUsageSnapshot subset)

struct PluginRateWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Double?
    let resetsAt: PluginTimestamp?
    let resetDescription: String?
    let usageKnown: Bool?
}

struct PluginNamedRateWindow: Decodable {
    let id: String
    let title: String
    let usageKnown: Bool?
    /// Either flat (`usedPercent`, ...) or nested `window` — handled via
    /// custom decode.
    let window: PluginRateWindow?
    let usedPercent: Double?
    let windowMinutes: Double?
    let resetsAt: PluginTimestamp?
    let resetDescription: String?

    var rateWindow: PluginRateWindow {
        window ?? PluginRateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            usageKnown: usageKnown)
    }
}

/// `resetsAt` arrives as ISO-8601 string or epoch seconds.
enum PluginTimestamp: Decodable {
    case date(Date)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            if let d = Self.iso.date(from: s) ?? Self.isoPlain.date(from: s) {
                self = .date(d); return
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO date")
        }
        if let n = try? c.decode(Double.self) {
            self = .date(Date(timeIntervalSince1970: n)); return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a timestamp")
    }

    var date: Date { switch self { case .date(let d): return d } }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

struct PluginCostSnapshot: Decodable {
    let used: Double?
    let limit: Double?
    let currency: String?
    let balance: Double?
}

struct PluginIdentity: Decodable {
    let email: String?
    let organization: String?
    let loginMethod: String?
}

struct PluginUsageSnapshot: Decodable {
    let empty: Bool?
    let primary: PluginRateWindow?
    let secondary: PluginRateWindow?
    let tertiary: PluginRateWindow?
    let extraWindows: [PluginNamedRateWindow]?
    let cost: PluginCostSnapshot?
    let identity: PluginIdentity?
    /// Present when the plugin returned `CodexBarFetchResult` ({usage, sourceLabel}).
    let usage: PluginUsageSnapshotBox?
    let sourceLabel: String?

    // Indirect box to allow the recursive union.
    struct PluginUsageSnapshotBox: Decodable {
        let empty: Bool?
        let primary: PluginRateWindow?
        let secondary: PluginRateWindow?
        let tertiary: PluginRateWindow?
        let extraWindows: [PluginNamedRateWindow]?
        let cost: PluginCostSnapshot?
        let identity: PluginIdentity?
    }

    var effective: PluginUsageSnapshot {
        if let u = usage {
            return PluginUsageSnapshot(
                empty: u.empty, primary: u.primary, secondary: u.secondary,
                tertiary: u.tertiary, extraWindows: u.extraWindows, cost: u.cost,
                identity: u.identity, usage: nil, sourceLabel: sourceLabel)
        }
        return self
    }
}

// MARK: - HTTP transport

struct PluginHTTPResponse {
    let url: String
    let status: Int
    let headers: [String: String]
    let bodyText: String
}

/// Injectable for tests. Default implementation is synchronous URLSession.
typealias PluginHTTPTransport = (URLRequest, TimeInterval) throws -> PluginHTTPResponse

// MARK: - Engine

final class PluginEngine {
    /// Implicitly unwrapped so ctx bridges installed during `init` may capture
    /// `self` and read it lazily once the manifest is parsed.
    private(set) var manifest: PluginManifest!
    /// Secret resolution: env var named after the settings key wins, then the
    /// provider's stored apiKey. Injectable for tests.
    var secretResolver: (String) -> String? = { key in
        ProcessInfo.processInfo.environment[key]?.trimmedNonEmpty
    }
    /// URL-valued setting resolution (endpoint `{setting, policy}` bases):
    /// env var named after the key wins, then the provider's configured
    /// baseURL. Never falls back to apiKey — a credential is not a URL.
    var settingResolver: (String) -> String? = { key in
        ProcessInfo.processInfo.environment[key]?.trimmedNonEmpty
    }
    private let injectedTransport: PluginHTTPTransport?
    /// Injectable for tests. The default is a synchronous URLSession whose
    /// redirects are contained to the manifest's declared origins — a 3xx to
    /// an undeclared host is surfaced to JS instead of being followed with
    /// the injected auth header attached.
    lazy var transport: PluginHTTPTransport = {
        injectedTransport ?? Self.makeURLSessionTransport(allow: { [weak self] url in
            self?.isAllowed(url: url) ?? false
        })
    }()

    private let context: JSContext
    private let queue: DispatchQueue

    /// Build an engine from plugin source. `source` must call
    /// `defineProvider(...)` exactly once.
    ///
    /// Ordering is deliberate: the prelude (defineProvider + ctx) is evaluated
    /// first, then the plugin source, then the manifest is parsed, and only
    /// then are native bridges installed. A plugin that calls `ctx.*` at
    /// top level therefore sees an undefined `__birdnionHttp` and throws a
    /// JS error — instead of reaching a native bridge before `manifest`
    /// exists. (Same ordering as the Rust engine.)
    init(source: String,
         transport: PluginHTTPTransport? = nil,
         queueLabel: String = "birdnion.plugin") throws {
        self.injectedTransport = transport
        self.queue = DispatchQueue(label: queueLabel + ".serial")
        self.context = JSContext(virtualMachine: JSVirtualMachine())!
        try queue.sync {
            context.exceptionHandler = { ctx, exc in ctx?.exception = exc }
            context.evaluateScript(Self.prelude)
            context.evaluateScript(source)
            if let exc = context.exception {
                throw PluginEngineError.invalidDefinition("plugin source threw: \(exc)")
            }
            self.manifest = try Self.readManifest(from: context)
            installBridge()
        }
    }

    var id: String { manifest.id }

    // MARK: Manifest extraction

    private static func readManifest(from context: JSContext) throws -> PluginManifest {
        guard let def = context.objectForKeyedSubscript("__birdnionPluginDef"),
              !def.isUndefined, !def.isNull
        else { throw PluginEngineError.invalidDefinition("defineProvider() was never called") }
        context.evaluateScript(
            "globalThis.__birdnionManifestJSON = JSON.stringify(__birdnionPluginDef)")
        guard let json = context.objectForKeyedSubscript("__birdnionManifestJSON")?.toString(),
              let data = json.data(using: .utf8)
        else { throw PluginEngineError.invalidDefinition("manifest serialization failed") }

        struct Raw: Decodable {
            struct EndpointObj: Decodable { let setting: String; let policy: String }
            struct Icon: Decodable { let monogram: String?; let tint: String? }
            let id: String
            let name: String
            let icon: Icon?
            let topLevel: Bool?
            let endpoints: [EndpointJSON]?
            let auth: PluginAuth?
            let settings: [PluginSetting]?
            let capabilities: [String]?
        }
        enum EndpointJSON: Decodable {
            case origin(String), obj(Raw.EndpointObj)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .origin(s); return }
                self = .obj(try c.decode(Raw.EndpointObj.self))
            }
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let id = raw.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.range(of: "^[a-z][a-z0-9_-]*$",
                                    options: .regularExpression) != nil
        else { throw PluginEngineError.invalidDefinition("bad provider id \"\(raw.id)\"") }
        var endpoints: [PluginEndpoint] = []
        for e in raw.endpoints ?? [] {
            switch e {
            case .origin(let s):
                guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                      scheme == "https", url.host != nil
                else { throw PluginEngineError.invalidDefinition("endpoint must be an https origin: \(s)") }
                endpoints.append(.origin(url))
            case .obj(let o):
                guard ["https", "https-or-loopback-http", "https-or-private-network-http"]
                        .contains(o.policy)
                else { throw PluginEngineError.invalidDefinition("bad endpoint policy \(o.policy)") }
                endpoints.append(.setting(key: o.setting, policy: o.policy))
            }
        }
        return PluginManifest(
            id: id, name: raw.name, iconMonogram: raw.icon?.monogram,
            iconTint: raw.icon?.tint, topLevel: raw.topLevel ?? false,
            endpoints: endpoints, auth: raw.auth, settings: raw.settings ?? [],
            capabilities: Set(raw.capabilities ?? []))
    }

    // MARK: Fetch

    /// Runs `fetchUsage(ctx)` synchronously on the engine queue. All ctx bridges
    /// resolve immediately, so the returned promise chain settles when the
    /// evaluate call returns. Throws PluginFetchError for `ctx.fail.*`.
    func fetchUsage() throws -> PluginUsageSnapshot {
        try queue.sync {
            context.evaluateScript("globalThis.__birdnionResult = undefined")
            context.evaluateScript("""
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
            """)
            if let exc = context.exception {
                throw PluginEngineError.engineFailure("fetchUsage threw: \(exc)")
            }
            guard let result = context.objectForKeyedSubscript("__birdnionResult"),
                  !result.isUndefined, !result.isNull
            else {
                throw PluginEngineError.engineFailure("fetchUsage did not settle")
            }
            if let errObj = result.objectForKeyedSubscript("err"), !errObj.isUndefined {
                let kindRaw = errObj.objectForKeyedSubscript("kind")?.toString() ?? ""
                let message = errObj.objectForKeyedSubscript("message")?.toString() ?? "plugin error"
                let kind = PluginFailKind(rawValue: kindRaw) ?? .apiFailure
                throw PluginFetchError(kind: kind, message: message)
            }
            guard let ok = result.objectForKeyedSubscript("ok")?.toString(),
                  let data = ok.data(using: .utf8)
            else { throw PluginEngineError.engineFailure("empty fetch result") }
            return try JSONDecoder().decode(PluginUsageSnapshot.self, from: data)
        }
    }

    // MARK: JS bridge

    /// Native bridges are installed only after the manifest is parsed —
    /// top-level plugin code must not reach them (see `init`).
    private func installBridge() {
        installNativeHTTP()
        installNativeSettings()
        installNativeStorage()
        installNativeFormat()
    }

    /// Validates a request URL against the manifest's declared endpoints.
    private func isAllowed(url: URL) -> Bool {
        guard let manifest else { return false }
        for endpoint in manifest.endpoints {
            switch endpoint {
            case .origin(let allowed):
                if sameOrigin(url, allowed) { return true }
            case .setting(let key, let policy):
                guard let raw = settingResolver(key), let base = URL(string: raw),
                      let host = base.host
                else { continue }
                if sameOrigin(url, base) { return true }
                let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
                if policy != "https",
                   url.scheme?.lowercased() == "http",
                   (isLoopback || (policy == "https-or-private-network-http" && Self.isPrivateIPv4(host))),
                   url.host?.lowercased() == host.lowercased() {
                    return true
                }
            }
        }
        return false
    }

    /// RFC 1918 private IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."),
              let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) })
        else { return false }
        return (16...31).contains(second)
    }

    private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard a.scheme?.lowercased() == b.scheme?.lowercased(),
              a.host?.lowercased() == b.host?.lowercased(),
              (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
        else { return false }
        return true
    }

    private func installNativeHTTP() {
        let block: @convention(block) (String) -> Any? = { [weak self] requestJSON in
            guard let self,
                  let data = requestJSON.data(using: .utf8),
                  let req = try? JSONDecoder().decode(HTTPRequestJSON.self, from: data),
                  let url = URL(string: req.url)
            else {
                return ["error": "bad request"]
            }
            guard self.isAllowed(url: url) else {
                return ["error": "endpoint not allowed: \(url.absoluteString)"]
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = req.method
            for (k, v) in req.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
            if let body = req.body { urlRequest.httpBody = body.data(using: .utf8) }
            self.injectAuth(into: &urlRequest)
            let timeout = min(max(req.timeoutSeconds ?? 15, 1), 90)
            do {
                let r = try self.transport(urlRequest, timeout)
                return ["url": r.url, "status": r.status, "headers": r.headers, "bodyText": r.bodyText]
            } catch {
                return ["error": "transport: \(error.localizedDescription)"]
            }
        }
        context.setObject(block, forKeyedSubscript: "__birdnionHttp" as NSString)
    }

    private struct HTTPRequestJSON: Decodable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: String?
        let timeoutSeconds: TimeInterval?
    }

    /// Injects the declared auth header natively — the JS side never sees the
    /// raw secret.
    private func injectAuth(into request: inout URLRequest) {
        guard let auth = manifest.auth,
              let secret = secretResolver(auth.secret), !secret.isEmpty else { return }
        switch auth.type {
        case "bearer":
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case "x-api-key":
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        case "header":
            if let header = auth.header { request.setValue(secret, forHTTPHeaderField: header) }
        case "authorization-scheme":
            if let scheme = auth.scheme {
                request.setValue("\(scheme) \(secret)", forHTTPHeaderField: "Authorization")
            }
        default: break
        }
    }

    private func installNativeSettings() {
        let get: @convention(block) (String) -> String? = { [weak self] key in
            guard let self, let manifest = self.manifest else { return nil }
            // Only keys the plugin declares resolve at all — otherwise JS
            // could read arbitrary process env vars (HOME, GITHUB_TOKEN, ...)
            // through this bridge. Upstream plugins declare every key they
            // read in `settings` or `endpoints`, so this is contract-safe.
            let urlValued = key.hasSuffix("URL")
                || key.hasSuffix("_ENDPOINT") || key.hasSuffix("_ORIGIN")
            let declared = manifest.settings.contains { $0.key == key }
                || manifest.endpoints.contains {
                    if case .setting(let k, _) = $0 { return k == key }
                    return false
                }
            guard declared else { return nil }
            // URL-valued settings resolve to the provider's configured base
            // URL — never to a credential.
            return urlValued ? self.settingResolver(key) : self.secretResolver(key)
        }
        context.setObject(get, forKeyedSubscript: "__birdnionGetSecret" as NSString)
    }

    private func installNativeStorage() {
        let fileFor: () -> URL = { [weak self] in
            Self.pluginStorageDir
                .appendingPathComponent(self?.manifest?.id ?? "unknown", isDirectory: true)
                .appendingPathComponent("storage.json")
        }
        let allowed = { [weak self] in self?.manifest?.capabilities.contains("persistent-storage") == true }
        let load: @convention(block) (String) -> String? = { [weak self] key in
            guard allowed(), let self else { return nil }
            return self.storageRead(file: fileFor())[key]
        }
        let store: @convention(block) (String, String) -> Bool = { [weak self] key, value in
            guard allowed(), let self else { return false }
            var map = self.storageRead(file: fileFor())
            map[key] = value
            return self.storageWrite(file: fileFor(), map: map)
        }
        let remove: @convention(block) (String) -> Bool = { [weak self] key in
            guard allowed(), let self else { return false }
            var map = self.storageRead(file: fileFor())
            map.removeValue(forKey: key)
            return self.storageWrite(file: fileFor(), map: map)
        }
        context.setObject(load, forKeyedSubscript: "__birdnionStorageGet" as NSString)
        context.setObject(store, forKeyedSubscript: "__birdnionStorageSet" as NSString)
        context.setObject(remove, forKeyedSubscript: "__birdnionStorageRemove" as NSString)
    }

    private static var pluginStorageDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/birdnion/plugins", isDirectory: true)
    }

    private func storageRead(file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private func storageWrite(file: URL, map: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    private func installNativeFormat() {
        let usd: @convention(block) (Double) -> String = { UsageFormatter.usdString($0) }
        let currency: @convention(block) (Double, String) -> String = { value, code in
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = code
            f.locale = Locale(identifier: "en_US")
            return f.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
        }
        let number: @convention(block) (Double, JSValue?) -> String = { value, opts in
            let f = NumberFormatter()
            f.numberStyle = .decimal
            if let min = opts?.objectForKeyedSubscript("minimumFractionDigits"), min.isNumber {
                f.minimumFractionDigits = Int(min.toInt32())
            }
            if let max = opts?.objectForKeyedSubscript("maximumFractionDigits"), max.isNumber {
                f.maximumFractionDigits = Int(max.toInt32())
            }
            f.locale = Locale(identifier: "en_US")
            return f.string(from: NSNumber(value: value)) ?? String(value)
        }
        context.setObject(usd, forKeyedSubscript: "__birdnionFormatUSD" as NSString)
        context.setObject(currency, forKeyedSubscript: "__birdnionFormatCurrency" as NSString)
        context.setObject(number, forKeyedSubscript: "__birdnionFormatNumber" as NSString)

        let nextDaily: @convention(block) (String, Int) -> Double = { tz, hour in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: tz) ?? .current
            let next = cal.nextDate(after: Date(), matching: DateComponents(hour: hour),
                                    matchingPolicy: .nextTime)
            return (next ?? Date()).timeIntervalSince1970 * 1000
        }
        let log: @convention(block) (JSValue) -> Void = { value in
            NSLog("[birdnion-plugin] %@", value.toString() ?? "")
        }
        context.setObject(nextDaily, forKeyedSubscript: "__birdnionNextDailyReset" as NSString)
        context.setObject(log, forKeyedSubscript: "__birdnionLog" as NSString)
    }

    // MARK: Default transport

    /// Blocks redirects to non-allowlisted origins. URLSession forwards the
    /// request headers — including the natively injected `Authorization` —
    /// to redirect targets, so following a 3xx cross-host would leak the
    /// plugin's secret. Allowed targets still redirect transparently;
    /// anything else surfaces the 3xx to JS, which can re-request the
    /// Location itself (it will be allowlist-checked like any request).
    final class RedirectGate: NSObject, URLSessionTaskDelegate {
        let allow: (URL) -> Bool
        init(allow: @escaping (URL) -> Bool) { self.allow = allow }
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(allow) == true ? request : nil)
        }
    }

    /// Synchronous URLSession GET/POST with a response cap and redirect
    /// containment to declared origins.
    static func makeURLSessionTransport(allow: @escaping (URL) -> Bool) -> PluginHTTPTransport {
        { request, timeout in
            final class Box { var response: PluginHTTPResponse?; var error: Error? }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            var req = request
            req.timeoutInterval = timeout
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            let session = URLSession(
                configuration: config,
                delegate: RedirectGate(allow: allow),
                delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: req) { data, response, error in
                defer { sem.signal() }
                if let error { box.error = error; return }
                guard let http = response as? HTTPURLResponse else {
                    box.error = PluginEngineError.engineFailure("non-HTTP response"); return
                }
                let capped = (data ?? Data()).prefix(1_048_576)
                let text = String(decoding: capped, as: UTF8.self)
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers[String(describing: k).lowercased()] = String(describing: v)
                }
                box.response = PluginHTTPResponse(
                    url: http.url?.absoluteString ?? req.url?.absoluteString ?? "",
                    status: http.statusCode, headers: headers, bodyText: text)
            }
            task.resume()
            if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
                task.cancel()
                throw PluginFetchError(kind: .networkFailure, message: "request timed out")
            }
            if let error = box.error {
                throw PluginFetchError(kind: .networkFailure, message: error.localizedDescription)
            }
            return box.response!
        }
    }

    // MARK: JS prelude — builds ctx and defineProvider

    static let prelude = #"""
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
        env: { timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC" },
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
    """#
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

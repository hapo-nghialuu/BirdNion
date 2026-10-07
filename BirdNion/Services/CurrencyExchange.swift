import Foundation

/// Manages exchange rates for converting USD-denominated cost estimates into
/// the user's preferred currency. Ported from CodexBar's `CurrencyExchange`.
///
/// Rates come from ExchangeRate-API (open.er-api.com), cached 24h in
/// UserDefaults; the hardcoded table below is the offline fallback.
final class CurrencyExchange: @unchecked Sendable {
    static let shared = CurrencyExchange()

    static let supportedCurrencies = CurrencyExchange.currencies.map(\.code)

    /// Picker order, symbols, and offline rates share one catalog.
    /// Fallback rates are approximate mid-market values used only when no
    /// cached or live rates are available.
    private static let currencies: [(code: String, symbol: String, rate: Double)] = [
        ("USD", "$", 1.0),
        ("VND", "₫", 25962.0),
        ("GBP", "£", 0.79),
        ("EUR", "€", 0.92),
        ("CZK", "Kč", 21.0),
        ("CNY", "¥", 7.27),
        ("JPY", "¥", 154.0),
        ("KRW", "₩", 1428.90),
        ("CAD", "$", 1.38),
        ("AUD", "$", 1.55),
        ("HKD", "$", 7.80),
        ("TWD", "NT$", 32.30),
        ("SGD", "$", 1.34),
        ("INR", "₹", 84.50),
        ("CHF", "Fr.", 0.80),
        ("AED", "د.إ", 3.6725),
        ("TRY", "₺", 48.5),
        ("NZD", "$", 1.761),
        ("SEK", "kr", 9.908),
        ("NOK", "kr", 9.480),
        ("DKK", "kr", 6.554),
        ("PLN", "zł", 3.838),
        ("BRL", "R$", 5.117),
        ("MXN", "$", 17.47),
        ("ZAR", "R", 16.36),
        ("THB", "฿", 33.37),
        ("IDR", "Rp", 17836.0),
        ("UAH", "₴", 44.86),
    ]

    static func pickerLabel(for code: String) -> String? {
        guard let currency = currencies.first(where: { $0.code == code }) else { return nil }
        return "\(currency.code) (\(currency.symbol))"
    }

    static func symbol(for code: String) -> String {
        currencies.first(where: { $0.code == code })?.symbol ?? code
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var rates = Dictionary(uniqueKeysWithValues: CurrencyExchange.currencies.map { ($0.code, $0.rate) })
    private var lastFetchTime: Date?

    private static let userDefaultsKey = "BirdNion.CurrencyExchangeRates"
    private static let lastFetchKey = "BirdNion.CurrencyExchangeLastFetch"

    convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let cached = defaults.dictionary(forKey: Self.userDefaultsKey) as? [String: Double] {
            self.rates.merge(cached) { _, new in new }
        }
        self.lastFetchTime = defaults.object(forKey: Self.lastFetchKey) as? Date
    }

    /// USD amount → target currency. `nil` when the rate is unavailable so
    /// callers cannot relabel the unconverted amount as the target currency.
    func convert(usdAmount: Double, to currencyCode: String) -> Double? {
        let target = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !target.isEmpty, target != "USD" else { return usdAmount }
        guard let rate = lock.withLock({ self.rates[target] }), rate > 0 else { return nil }
        return usdAmount * rate
    }

    static func requiresLiveRates(preferredCurrencyCode: String) -> Bool {
        let code = preferredCurrencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code != "AUTO" && code != "USD" && Self.supportedCurrencies.contains(code)
    }

    /// Fetches latest rates when the user picked a non-USD currency and the
    /// cache is stale (>24h). On failure the cached/fallback table stays in use.
    func fetchLatestRatesIfNeeded(preferredCurrencyCode: String) async {
        guard Self.requiresLiveRates(preferredCurrencyCode: preferredCurrencyCode) else { return }
        if let lastFetch = self.lock.withLock({ self.lastFetchTime }),
           Date().timeIntervalSince(lastFetch) < 86_400 {
            return
        }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            struct ExchangeResponse: Decodable {
                let result: String
                let rates: [String: Double]?
            }
            let decoded = try JSONDecoder().decode(ExchangeResponse.self, from: data)
            if decoded.result == "success", let newRates = decoded.rates {
                self.lock.withLock {
                    self.rates.merge(newRates) { _, new in new }
                    self.lastFetchTime = Date()
                }
                self.defaults.set(newRates, forKey: Self.userDefaultsKey)
                self.defaults.set(Date(), forKey: Self.lastFetchKey)
            }
        } catch {
            // Keep using cached/fallback rates.
        }
    }
}

/// Resolves the user's preferred display currency. `"auto"` follows the
/// system locale currency when it's in the supported catalog, else USD.
enum PreferredCurrency {
    static let defaultsKey = "preferredCurrencyCode"

    static var preference: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "auto"
    }

    /// Resolved ISO code used for formatting ("auto" → system currency code,
    /// falling back to USD when unsupported).
    static var resolvedCode: String {
        let preference = Self.preference
        if preference.lowercased() != "auto" {
            return CurrencyExchange.supportedCurrencies.contains(preference.uppercased())
                ? preference.uppercased()
                : "USD"
        }
        let localeCode = Locale.current.currencyCode?.uppercased() ?? "USD"
        return CurrencyExchange.supportedCurrencies.contains(localeCode) ? localeCode : "USD"
    }

    /// Display/convert a USD amount in the preferred currency. Falls back to
    /// en_US USD formatting when conversion isn't possible.
    static func format(usd amount: Double, wholeFraction: Bool = false) -> String {
        let code = Self.resolvedCode
        if code == "USD" { return Self.formatUSD(amount, whole: wholeFraction) }
        guard let converted = CurrencyExchange.shared.convert(usdAmount: amount, to: code) else {
            return Self.formatUSD(amount, whole: wholeFraction)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = Locale(identifier: "en_US")
        // High-denominator currencies (VND, IDR, JPY, KRW...) read better
        // without cents even for small amounts.
        let maxDigits = (wholeFraction || code != "USD" && converted >= 100) ? 0 : 2
        formatter.maximumFractionDigits = maxDigits
        formatter.minimumFractionDigits = maxDigits
        if let string = formatter.string(from: NSNumber(value: converted)) {
            return string
        }
        return "\(CurrencyExchange.symbol(for: code))\(Self.plainNumber(converted, digits: maxDigits))"
    }

    private static func formatUSD(_ amount: Double, whole: Bool) -> String {
        // Preserve the prior display rule: whole-dollar output, or the
        // fractional variant dropping cents at $1000+.
        let digits = (whole || amount >= 1000) ? 0 : 2
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = digits
        return formatter.string(from: NSNumber(value: amount))
            ?? String(format: "$%.\(digits)f", amount)
    }

    private static func plainNumber(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

import Foundation

/// Provider-specific spend/budget snapshot (e.g. Claude "Extra usage" monthly
/// spend vs limit). Surfaced in the providers detail panel's cost row.
///
/// Hand-ported from CodexBar (reference only — BirdNion does not link
/// CodexBarCore). Only the fields BirdNion actually renders are kept.
struct ProviderCostSnapshot: Equatable, Codable, Sendable {
    let used: Double
    let limit: Double
    let currencyCode: String
    /// Human-friendly period label (e.g. "Monthly"). nil when not exposed.
    let period: String?
    /// Optional renewal/reset timestamp for the period.
    let resetsAt: Date?
    /// Optional amount restored on the next regeneration tick for providers
    /// with rolling credit recovery.
    let nextRegenAmount: Double?
    /// This account's own contribution when `used`/`limit` describe a
    /// shared/pooled budget. nil when the budget is already personal.
    let personalUsed: Double?
    /// Remaining prepaid/credit balance, distinct from `personalUsed`.
    let balance: Double?
    let updatedAt: Date

    init(used: Double,
         limit: Double,
         currencyCode: String,
         period: String? = nil,
         resetsAt: Date? = nil,
         nextRegenAmount: Double? = nil,
         personalUsed: Double? = nil,
         balance: Double? = nil,
         updatedAt: Date) {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.period = period
        self.resetsAt = resetsAt
        self.nextRegenAmount = nextRegenAmount
        self.personalUsed = personalUsed
        self.balance = balance
        self.updatedAt = updatedAt
    }
}

/// Currency/number formatting helpers. Hand-ported subset of CodexBar's
/// `UsageFormatter` — only what BirdNion's cost rows render. Uses an explicit
/// en_US locale so values format consistently regardless of system locale
/// (e.g. pt-BR users still see "$54.72", not "US$ 54,72").
enum UsageFormatter {
    static func usdString(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}

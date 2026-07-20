import SwiftUI

// MARK: - Provider cost / quota charts (P4 module split)

extension ProvidersPane {
    /// Quota windows + credits (mockup: QUOTA). Cost blocks render as a
    /// sibling card via `costSection` so headers match THÔNG TIN / QUOTA /
    /// CHI PHÍ without changing control behavior.
    @ViewBuilder
    func usageSection(_ row: BirdNionConfigStore.Provider) -> some View {
        let s = status(for: row.id)
        SettingsCard(header: L10n.t("settings.section.quota", language)) {
            if let s, !s.windows.isEmpty {
                ForEach(Array(s.windows.enumerated()), id: \.element.id) { i, w in
                    quotaWindowRow(w)
                    if i < s.windows.count - 1 { SettingsRowDivider() }
                }
                if s.creditsRemaining != nil || s.creditsUnlimited {
                    SettingsRowDivider()
                    creditsRow(s.creditsRemaining, unlimited: s.creditsUnlimited)
                }
            } else if s == nil || s?.windows.isEmpty == true {
                // Empty placeholder only when there's truly no data — cost /
                // extras below can still render so the panel stays useful
                // even when OAuth fails.
                Text(row.enabled == true
                     ? L10n.t("provider.noData.enabled", language)
                     : L10n.t("provider.noData.disabled", language))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            // Claude web extras (email/org/extra rate windows) stay with quota
            // data — not token-cost estimates.
            if row.id == "claude", let extras = s?.webExtras {
                SettingsRowDivider()
                webExtrasRows(extras)
            }
        }
        costSection(row, status: s)
    }

    /// Token / web cost card (mockup: CHI PHÍ). Only renders when there is
    /// something to show so empty providers do not get a blank cost card.
    @ViewBuilder
    func costSection(_ row: BirdNionConfigStore.Provider, status s: ProviderStatus?) -> some View {
        let hasCodexCost = row.id == "codex" && (codexCost.map { !$0.isEmpty } ?? false)
        let hasClaudeWebCost = row.id == "claude" && s?.cost != nil
        let hasClaudeLocalCost = row.id == "claude" && (claudeCost.map { !$0.isEmpty } ?? false)
        if hasCodexCost || hasClaudeWebCost || hasClaudeLocalCost {
            SettingsCard(header: L10n.t("settings.section.cost", language)) {
                if row.id == "codex", let cost = codexCost, !cost.isEmpty {
                    costRows(cost)
                }
                if row.id == "claude", let cost = s?.cost {
                    webCostRow(cost)
                    if let local = claudeCost, !local.isEmpty { SettingsRowDivider() }
                }
                if row.id == "claude", let cost = claudeCost, !cost.isEmpty {
                    costRows(cost)
                }
            }
        }
    }

    func quotaWindowRow(_ w: QuotaWindow) -> some View {
        let isWeek = w.label.contains("Tuần")
        let barTextColor = SettingsTheme.quotaColor(remaining: w.remainingPct)
        let barFillColor = SettingsTheme.quotaFillColor(remaining: w.remainingPct)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowLabel(w.label, preference: language).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(w.remainingPct)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barTextColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(w.remainingPct) / 100), height: 8)
                }
            }
            .frame(height: 8)

            // Pace line: reserve (weekly) on the left, reset countdown on the right.
            let pace = WindowPace(window: w)
            if pace != nil || (w.subtitle?.isEmpty == false) {
                HStack(alignment: .firstTextBaseline) {
                    if isWeek, let r = pace?.reservePct, r > 0 {
                        Text(L10n.f("provider.reserve", language, r))
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                    Spacer(minLength: 6)
                    if let rt = pace?.resetText {
                        Text(L10n.f("provider.resetAfter", language, rt))
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                }
                if isWeek, let pace {
                    Text(pace.lastsUntilReset
                         ? L10n.t("provider.enoughUntilReset", language)
                         : L10n.t("provider.mayRunOut", language))
                        .font(.system(size: 10))
                        .foregroundStyle(pace.lastsUntilReset ? SettingsTheme.secondary : SettingsTheme.warning)
                }
                if let sub = w.subtitle, !sub.isEmpty {
                    Text(L10n.providerText(sub, preference: language))
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Remaining credit balance line (Codex). Shown only when the provider
    /// reports a credits figure.
    func creditsRow(_ credits: Double?, unlimited: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("provider.credits", language))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer()
            Text(unlimited ? L10n.t("provider.unlimited", language) : creditsText(credits ?? 0))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func creditsText(_ credits: Double) -> String {
        let amount = credits.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(credits))
            : String(format: "%.2f", credits)
        return credits <= 0
            ? L10n.t("provider.outOfCredits", language)
            : L10n.f("provider.creditsLeft", language, amount)
    }

    /// Token cost rows (Codex + Claude). Dollar amounts are estimates (tokens ×
    /// price table), so they're prefixed with "≈"; token counts are exact.
    /// Both `CodexCostSummary` and `ClaudeCostSummary` carry the same 4
    /// fields, so we forward to a single renderer.
    func costRows(_ cost: CodexCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    func costRows(_ cost: ClaudeCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    func costRowsImpl(todayUSD: Double, todayTokens: Int,
                              last30USD: Double, last30Tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            costLine(L10n.t("provider.today", language), usd: todayUSD, tokens: todayTokens)
            costLine(L10n.t("provider.last30", language), usd: last30USD, tokens: last30Tokens)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Claude cost row, CodexBar parity. Renders a progress bar (used% of
    /// monthly limit), the dollar amount on the right, a "X% used" line, and
    /// an optional "Resets in Nd" countdown sourced from `cost.resetsAt`.
    /// Matches CodexBar's `ProviderCostSection` layout: title + percent +
    /// spend line + reset countdown.
    func webCostRow(_ cost: ProviderCostSnapshot) -> some View {
        let usedPct = cost.limit > 0
            ? Int(min(100, max(0, (cost.used / cost.limit * 100).rounded())))
            : 0
        let remaining = max(0, cost.limit - cost.used)
        let barColor = SettingsTheme.usedFillColor(usedPercent: usedPct)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("provider.cost", language))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(UsageFormatter.usdString(cost.used)) / \(UsageFormatter.usdString(cost.limit))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SettingsTheme.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(usedPct) / 100), height: 8)
                }
            }
            .frame(height: 8)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.f("provider.usedRemaining", language, usedPct, UsageFormatter.usdString(remaining)))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.secondary)
                Spacer(minLength: 6)
                if let reset = cost.resetsAt {
                    Text(L10n.f("provider.resetAfter", language, Self.resetCountdown(to: reset)))
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                } else if let period = cost.period {
                    Text(period)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Compact countdown to a future date. Mirrors `WindowPace.format` but
    /// skips the "< 1m" branch so a sub-minute reset still reads "0m".
    /// "1d 4h", "4h 12m", "12m", "<1m".
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Claude web/CLI account identity rows. Surfaces email, organization,
    /// and login method when `webExtras` carries them — replaces CodexBar's
    /// `ProviderDetailInfoGrid` "Account" + "Auth" rows so the user can
    /// confirm which Claude.ai account the cookie/CLI session belongs to
    /// when OAuth is offline.
    @ViewBuilder
    func webExtrasRows(_ extras: ClaudeWebExtras) -> some View {
        if let email = extras.accountEmail, !email.isEmpty {
            webInfoRow(label: L10n.t("provider.email", language), value: email)
        }
        if let org = extras.accountOrganization, !org.isEmpty {
            webInfoRow(label: L10n.t("provider.organization", language), value: org)
        }
        if let method = extras.loginMethod, !method.isEmpty {
            webInfoRow(label: L10n.t("provider.login", language), value: method)
        }
        if let source = extras.sourceLabel, !source.isEmpty {
            webInfoRow(label: L10n.t("provider.source", language).uppercased(), value: source.uppercased())
        }
        // Named extra windows (e.g. "Daily Routines", "Sonnet") from the
        // web/CLI/OAuth sources. Previously plumbed but never rendered.
        ForEach(extras.extraRateWindows) { w in
            extraRateWindowRow(w)
        }
    }

    /// Compact progress row for a named extra rate window (Daily Routines, etc.).
    func extraRateWindowRow(_ w: ClaudeExtraRateWindow) -> some View {
        let remaining = max(0, 100 - w.usedPercent)
        let barTextColor = SettingsTheme.quotaColor(remaining: remaining)
        let barFillColor = SettingsTheme.quotaFillColor(remaining: remaining)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(remaining)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barTextColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(remaining) / 100), height: 8)
                }
            }
            .frame(height: 8)
            if let reset = w.resetsAt {
                Text(L10n.f("provider.resetAfter", language, Self.resetCountdown(to: reset)))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            } else if let desc = w.resetDescription, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func webInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(SettingsTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    func costLine(_ label: String, usd: Double, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer()
            Text("≈$\(String(format: "%.2f", usd)) · \(Self.formatTokens(tokens))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsTheme.primary)
        }
    }

    /// Compact token count: 1_234_567 → "1.2M", 12_345 → "12.3K".
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

}

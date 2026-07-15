// Single-source 30-day chart card — port of the macOS ClaudeUsageChartCard /
// CodexUsageChartCard: today + 30d summary, per-day USD bars, hovered-day
// per-model breakdown, estimated-total footer.

import { DailyUsage, UsageReport, usd, tokens, tokensShort, dayLabel } from "./usage";
import { t } from "./i18n";

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function summaryColumn(label: string, amount: number | null, tokenCount: number, trailing = false) {
  const col = el("div", `summary-col${trailing ? " trailing" : ""}`);
  col.append(el("div", "summary-label", label));
  if (amount !== null) col.append(el("div", "summary-amount", usd(amount)));
  col.append(el("div", "summary-tokens", tokens(tokenCount)));
  return col;
}

function showDetail(detail: HTMLElement, day: DailyUsage) {
  detail.textContent = "";
  detail.append(el("div", "day-detail-head",
    `${dayLabel(day.date)} · ${tokens(day.tokens)} · ${usd(day.usd)}`));
  for (const m of day.models) {
    const row = el("div", "source-row");
    row.append(el("span", "model-name", m.name));
    row.append(el("span", "source-amount", `${tokensShort(m.tokens)} · ${usd(m.usd)}`));
    detail.append(row);
  }
}

export function sourceChartCard(
  report: UsageReport,
  source: "claude" | "codex" | "grok" | "kiro",
): HTMLElement {
  const card = el("section", "card");
  const daily30 = report.daily.slice(-30);
  const latestActive = [...daily30].reverse().find((d) => d.tokens > 0);
  const barClass = source === "claude" ? "claude"
    : source === "codex" ? "codex"
    : source === "kiro" ? "kiro"
    : "grok";
  const footnoteKey = source === "claude" ? "claudeFootnote"
    : source === "codex" ? "codexFootnote"
    : source === "kiro" ? "kiroFootnote"
    : "grokFootnote";

  const summary = el("div", "summary-row");
  summary.append(summaryColumn(t("today"), report.todayUsd, report.todayTokens));
  summary.append(summaryColumn(`30 ${t("days")}`, report.last30Usd, report.last30Tokens, true));
  summary.append(summaryColumn(t("latestTokens"), null, latestActive?.tokens ?? 0, true));
  card.append(summary);

  const detail = el("div", "day-detail");
  // Bar height by tokens (parity with All chart card).
  const max = Math.max(...daily30.map((d) => d.tokens), 1);
  const chart = el("div", "bar-chart");
  for (const day of daily30) {
    const col = el("div", "bar-col");
    col.title = `${dayLabel(day.date)}: ${tokens(day.tokens)} · ${usd(day.usd)}`;
    if (day.tokens > 0) {
      const bar = el("div", `bar-seg solo ${barClass}`);
      bar.style.height = `${Math.max((day.tokens / max) * 100, 5)}%`;
      col.append(bar);
    } else {
      col.append(el("div", "bar-idle"));
    }
    col.addEventListener("mouseenter", () => showDetail(detail, day));
    chart.append(col);
  }
  card.append(chart, detail);
  if (latestActive) showDetail(detail, latestActive);

  card.append(el("div", "est-total", `${t("estTotal", { n: 30 })}: ${tokens(report.last30Tokens)}`));
  if (report.topModel) {
    card.append(el("div", "footnote", `${t("topModel")}: ${report.topModel}`));
  }
  card.append(el("div", "footnote", t(footnoteKey)));
  return card;
}

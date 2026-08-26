// Single-source 30-day chart card — port of macOS provider cost charts.
// Model breakdown is click-to-pin (hidden by default); hover only highlights.

import { DailyUsage, UsageReport, usd, tokens, tokensAndUsd, dayLabel } from "./usage";
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
  const models = [...day.models]
    .filter((m) => m.tokens > 0 || m.usd > 0)
    .sort((a, b) => (b.tokens - a.tokens) || (b.usd - a.usd))
    .slice(0, 6);
  if (models.length === 0) {
    detail.append(el("div", "footnote", t("noModelBreakdown") || "No model breakdown."));
    return;
  }
  for (const m of models) {
    const row = el("div", "source-row");
    row.append(el("span", "model-name", m.name));
    row.append(el("span", "source-amount", tokensAndUsd(m.tokens, m.usd)));
    detail.append(row);
  }
}

function clearDetail(detail: HTMLElement) {
  detail.textContent = "";
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
    : source === "grok" ? "grok" : "kiro";
  const footnoteKey = source === "claude" ? "claudeFootnote"
    : source === "codex" ? "codexFootnote"
    : source === "grok" ? "grokFootnote" : "kiroFootnote";

  const summary = el("div", "summary-row");
  summary.append(summaryColumn(t("today"), report.todayUsd, report.todayTokens));
  summary.append(summaryColumn(`30 ${t("days")}`, report.last30Usd, report.last30Tokens, true));
  summary.append(summaryColumn(t("latestTokens"), null, latestActive?.tokens ?? 0, true));
  card.append(summary);

  // Default empty — detail only after click (macOS parity).
  const detail = el("div", "day-detail");
  let pinnedKey: string | null = null;
  const dayKey = (d: DailyUsage) => String(d.date);

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
    // Hover chỉ highlight, không mở gì — đúng như macOS `onHover` ở chart
    // của tab provider (khác chart tab All, chỗ đó hover mở panel phụ).
    col.addEventListener("mouseenter", () => col.classList.add("hovered"));
    col.addEventListener("mouseleave", () => col.classList.remove("hovered"));
    col.addEventListener("click", () => {
      const key = dayKey(day);
      if (pinnedKey === key) {
        pinnedKey = null;
        clearDetail(detail);
        col.classList.remove("pinned");
      } else {
        chart.querySelectorAll(".bar-col.pinned").forEach((el) => el.classList.remove("pinned"));
        pinnedKey = key;
        col.classList.add("pinned");
        showDetail(detail, day);
      }
    });
    chart.append(col);
  }
  card.append(chart, detail);

  card.append(el("div", "est-total", `${t("estTotal", { n: 30 })}: ${tokens(report.last30Tokens)}`));
  card.append(el("div", "footnote", t(footnoteKey)));
  return card;
}

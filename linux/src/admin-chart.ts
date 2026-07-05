// Claude Admin API org dashboard card — port of `ClaudeAdminUsageChartCard`
// in QuotaPanel.swift: 30d + latest cost/tokens columns, per-day cost bars,
// top model + top cost line. Rendered on the claude tab only when an admin
// key is configured and the snapshot fetch succeeds.

import { usd, tokens } from "./usage";
import { currentLang } from "./i18n";

export type ModelBreakdown = { name: string; totalTokens: number };
export type CostBreakdown = { name: string; costUsd: number };
export type Summary = { costUsd: number; totalTokens: number };
export type DailyBucket = { day: string; costUsd: number; totalTokens: number };

export type ClaudeAdminSnapshot = {
  daily: DailyBucket[];
  last30Days: Summary;
  latestDay: Summary;
  topModels: ModelBreakdown[];
  topCostItems: CostBreakdown[];
};

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function summaryColumn(label: string, amount: number, tokenCount: number, trailing = false) {
  const col = el("div", `summary-col${trailing ? " trailing" : ""}`);
  col.append(el("div", "summary-label", label));
  col.append(el("div", "summary-amount", usd(amount)));
  col.append(el("div", "summary-tokens", tokens(tokenCount)));
  return col;
}

export function adminChartCard(snapshot: ClaudeAdminSnapshot): HTMLElement {
  const vi = currentLang() === "vi";
  const card = el("section", "card");

  card.append(el("div", "summary-label", vi ? "Admin API · Tổ chức (30 ngày)" : "Admin API · Org (30 days)"));

  const summary = el("div", "summary-row");
  summary.append(summaryColumn(vi ? "30 ngày" : "30 days", snapshot.last30Days.costUsd, snapshot.last30Days.totalTokens));
  summary.append(summaryColumn(vi ? "Mới nhất" : "Latest", snapshot.latestDay.costUsd, snapshot.latestDay.totalTokens, true));
  card.append(summary);

  const max = Math.max(...snapshot.daily.map((d) => d.costUsd), 0.01);
  const chart = el("div", "bar-chart");
  for (const day of snapshot.daily) {
    const col = el("div", "bar-col");
    col.title = `${day.day}: ${usd(day.costUsd)} · ${tokens(day.totalTokens)}`;
    if (day.costUsd > 0) {
      const bar = el("div", "bar-seg solo mono");
      bar.style.height = `${Math.max((day.costUsd / max) * 100, 5)}%`;
      col.append(bar);
    } else {
      col.append(el("div", "bar-idle"));
    }
    chart.append(col);
  }
  card.append(chart);

  const topModel = snapshot.topModels[0];
  if (topModel) {
    card.append(el("div", "footnote", `${vi ? "Model nhiều nhất: " : "Top model: "}${topModel.name}`));
  }
  const topCost = snapshot.topCostItems[0];
  if (topCost) {
    card.append(el("div", "footnote", `${vi ? "Chi nhiều nhất: " : "Top cost: "}${topCost.name} · ${usd(topCost.costUsd)}`));
  }
  return card;
}

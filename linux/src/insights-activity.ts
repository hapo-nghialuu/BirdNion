// Insights → Hoạt động: heatmap 52 tuần + stats, port của macOS
// `agent-activity-content.swift` / `WeeklyActivityBucketBuilder`.
//
// Dữ liệu lấy từ cost-history đã quét (không gọi mạng). Tuần thiếu dữ liệu để
// TRỐNG chứ không nội suy — giữ nguyên nguyên tắc "không fabricate" của bản
// macOS. Đậm nhạt theo token, USD chỉ xuất hiện ở tooltip và hàng stats.

import { Combined, CombinedDay, usd, tokens as tokensLabel } from "./usage";
import { t } from "./i18n";

const WEEKS = 52;
const CELL = 10;

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

type Cell = { date: string; usd: number; tokens: number; hasData: boolean };

/** Dựng lưới tuần×thứ từ dải ngày liên tục kết thúc hôm nay. */
export function weeklyGrid(daily: CombinedDay[], now: Date = new Date()): Cell[][] {
  const byDate = new Map(daily.map((d) => [d.date, d]));
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  // Lùi về thứ Hai của tuần hiện tại rồi trải ngược 52 cột.
  const weekday = (end.getDay() + 6) % 7; // 0 = thứ Hai
  const lastMonday = new Date(end);
  lastMonday.setDate(end.getDate() - weekday);

  const columns: Cell[][] = [];
  for (let w = WEEKS - 1; w >= 0; w--) {
    const column: Cell[] = [];
    for (let d = 0; d < 7; d++) {
      const date = new Date(lastMonday);
      date.setDate(lastMonday.getDate() - w * 7 + d);
      const key = ymd(date);
      const entry = byDate.get(key);
      column.push({
        date: key,
        usd: entry?.usd ?? 0,
        tokens: entry?.tokens ?? 0,
        hasData: entry != null,
      });
    }
    columns.push(column);
  }
  return columns;
}

function ymd(date: Date): string {
  const m = `${date.getMonth() + 1}`.padStart(2, "0");
  const d = `${date.getDate()}`.padStart(2, "0");
  return `${date.getFullYear()}-${m}-${d}`;
}

function heatLevel(tokenCount: number, max: number): number {
  if (tokenCount <= 0 || max <= 0) return 0;
  const fraction = tokenCount / max;
  if (fraction <= 0.25) return 1;
  if (fraction <= 0.5) return 2;
  if (fraction <= 0.75) return 3;
  return 4;
}

/** Chuỗi ngày hoạt động liên tiếp tính đến hôm nay (hôm nay chưa hoạt động
 *  thì không phá streak — ngày chưa kết thúc). */
export function streakDays(daily: CombinedDay[]): number {
  let streak = 0;
  let i = daily.length - 1;
  if (i >= 0 && !daily[i].active) i--;
  while (i >= 0 && daily[i].active) { streak++; i--; }
  return streak;
}

export function activityContent(combined: Combined): HTMLElement {
  const wrap = el("div", "insights-activity");
  const grid = weeklyGrid(combined.daily);
  const cells = grid.flat();
  const maxTokens = Math.max(...cells.map((c) => c.tokens), 1);
  const activeDays = combined.daily.filter((d) => d.active).length;
  const totalUsd = combined.daily.reduce((sum, d) => sum + d.usd, 0);

  const head = el("div", "insights-activity-head");
  head.append(el("span", "insights-activity-title",
    t("insightsSegmentActivity").toUpperCase()));
  head.append(el("span", "insights-activity-meta",
    `${usd(totalUsd)} · ${activeDays} ${t("activeDaysWord")}`));
  wrap.append(head);

  const board = el("div", "insights-activity-board");
  const labels = el("div", "insights-activity-labels");
  const weekdayLabels = ["mon", "", "wed", "", "fri", "", "sun"];
  for (const key of weekdayLabels) {
    labels.append(el("span", "insights-activity-weekday",
      key ? t(`weekday.${key}`) : ""));
  }
  board.append(labels);

  const gridEl = el("div", "insights-activity-grid");
  for (const column of grid) {
    const col = el("div", "insights-activity-col");
    for (const cell of column) {
      const box = el("span", `insights-activity-cell level-${heatLevel(cell.tokens, maxTokens)}`);
      box.style.width = `${CELL}px`;
      box.style.height = `${CELL}px`;
      box.title = cell.tokens > 0
        ? `${cell.date}: ${tokensLabel(cell.tokens)} · ${usd(cell.usd)}`
        : `${cell.date}: ${t("noActivity")}`;
      // Heatmap trong Settings → Phân tích KHÔNG tương tác: macOS
      // `agent-activity-content.swift` chỉ có tooltip, không hover/click.
      // Drill-down theo ngày nằm ở panel Hoạt động mở từ hàng stats tab All.
      col.append(box);
    }
    gridEl.append(col);
  }
  board.append(gridEl);
  wrap.append(board);

  const legend = el("div", "insights-activity-legend");
  legend.append(el("span", "insights-activity-legend-label", t("less")));
  for (let level = 0; level <= 4; level++) {
    legend.append(el("span", `insights-activity-cell level-${level}`));
  }
  legend.append(el("span", "insights-activity-legend-label", t("more")));
  legend.append(el("span", "insights-activity-legend-note", t("shadedByTokens")));
  wrap.append(legend);

  wrap.append(statsRow(combined, activeDays));
  return wrap;
}

function statsRow(combined: Combined, activeDays: number): HTMLElement {
  const row = el("div", "insights-activity-stats");
  const peak = combined.daily.reduce((best, d) => (d.usd > (best?.usd ?? 0) ? d : best),
    null as CombinedDay | null);
  const totalUsd = combined.daily.reduce((sum, d) => sum + d.usd, 0);
  const avg = activeDays > 0 ? totalUsd / activeDays : 0;

  row.append(stat(t("peakDay"), usd(peak?.usd ?? 0)));
  row.append(stat(t("avgPerActiveDay"), usd(avg)));
  row.append(stat(t("streak"), `${streakDays(combined.daily)} ${t("daysWord")}`));
  return row;
}

function stat(label: string, value: string): HTMLElement {
  const cell = el("div", "insights-activity-stat");
  cell.append(el("span", "insights-activity-stat-label", label.toUpperCase()));
  cell.append(el("span", "insights-activity-stat-value", value));
  return cell;
}

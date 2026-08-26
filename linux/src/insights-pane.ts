// Usage Insights + Cost by Project. All data comes from the read-only
// `project_insights_report` command; switching views never starts a scan.

import { invoke } from "@tauri-apps/api/core";
import { t } from "./i18n";
import { tokens, usd, combine, USAGE_SOURCE_IDS } from "./usage";
import type { UsageReport, UsageSourceId } from "./usage";
import { activityContent } from "./insights-activity";

export type InsightConfidence = {
  source: string;
  state: "live" | "history" | "unavailable";
  scannedAt: number | null;
};

export type ProjectRanking = {
  projectKey: string;
  displayName: string;
  source: string;
  capability: "exact" | "derivedPath" | "unknown";
  isUnknown: boolean;
  usd: number;
  tokens: number;
};

type SourceTotal = { source: string; usd: number; tokens: number };
type ModelTotal = SourceTotal & { name: string };
type DetailDay = { date: string; usd: number; tokens: number };
type DetailModel = { name: string; usd: number; tokens: number };

export type InsightsPeriodDays = 1 | 7 | 30 | 90;

export type ProjectInsightsReport = {
  days: InsightsPeriodDays;
  overview: {
    current7Usd: number;
    current7Tokens: number;
    previous7Usd: number;
    previous7Tokens: number;
    changePct: number | null;
    topSource: SourceTotal | null;
    topModel: ModelTotal | null;
    topProject: ProjectRanking | null;
    confidence: InsightConfidence[];
  };
  projects: ProjectRanking[];
  selectedProject: {
    project: ProjectRanking;
    daily: DetailDay[];
    models: DetailModel[];
  } | null;
};

/** 3 segment như macOS: tổng quan / hoạt động / dự án. */
export type InsightsSegment = "overview" | "activity" | "projects";

const SEGMENT_KEY = "birdnion.insightsSegment";
const DAYS_KEY = "birdnion.insightsDays";
const PROJECT_KEY = "birdnion.insightsProjectKey";
const USAGE_SOURCES: readonly UsageSourceId[] = USAGE_SOURCE_IDS;
const SOURCE_NAMES: Readonly<Record<string, string>> = {
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
  kiro: "Kiro",
  omp: "Oh My Pi",
  pi: "Pi",
};

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function sourceName(source: string): string {
  return SOURCE_NAMES[source] ?? source;
}

function projectName(project: ProjectRanking | null): string {
  if (!project) return t("insightsNoProject");
  return project.isUnknown ? t("insightsUnknownProject") : project.displayName;
}

function deltaLabel(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return "—";
  const rounded = Math.round(value);
  return `${rounded >= 0 ? "+" : ""}${rounded}%`;
}

function confidenceLabel(items: InsightConfidence[], includeUnavailableNames = false): string {
  const included = items.filter((item) => item.state !== "unavailable");
  const live = included.filter((item) => item.state === "live").length;
  const unavailable = items.filter((item) => item.state === "unavailable");
  let label: string;
  if (included.length === 0) label = t("insightsConfidenceUnavailable");
  else if (live === items.length) label = t("insightsConfidenceLive");
  else label = t("insightsConfidenceMixed", { live, total: items.length });
  if (!includeUnavailableNames || unavailable.length === 0) return label;
  return `${label} · ${t("confidence.state.unavailable")}: ${unavailable
    .map((item) => sourceName(item.source)).join(", ")}`;
}

export function fetchProjectInsightsReport(
  days: InsightsPeriodDays = 7,
  projectKey: string | null = null,
): Promise<ProjectInsightsReport | null> {
  return invoke<ProjectInsightsReport>("project_insights_report", { days, projectKey })
    .catch(() => null);
}

type AuthorizedRequestResult<T> = {
  current: boolean;
  value: T | null;
};

type UsageReports = Record<UsageSourceId, UsageReport | null>;

type SourceAuthorizationDependencies = {
  readCanonicalSources: () => Promise<ReadonlySet<UsageSourceId> | null>;
};

function intersectSources(
  started: ReadonlySet<UsageSourceId>,
  final: ReadonlySet<UsageSourceId>,
): ReadonlySet<UsageSourceId> {
  return new Set(USAGE_SOURCES.filter((source) => started.has(source) && final.has(source)));
}

/** Every Insights request owns a generation and two authorization snapshots.
 * Unknown authorization fails closed; a newer request invalidates all older
 * completions before they can reach the DOM. */
function createSourceAuthorizedRequestCoordinator(
  dependencies: SourceAuthorizationDependencies,
) {
  let activeGeneration = 0;
  const readSources = () => dependencies.readCanonicalSources().catch(() => null);

  return {
    invalidate(): void {
      activeGeneration += 1;
    },
    async run<T>(
      request: (started: ReadonlySet<UsageSourceId>) => Promise<T | null>,
      restrict: (value: T, allowed: ReadonlySet<UsageSourceId>) => T | null,
    ): Promise<AuthorizedRequestResult<T>> {
      const generation = ++activeGeneration;
      const started = await readSources();
      if (generation !== activeGeneration) return { current: false, value: null };
      if (!started) return { current: true, value: null };

      const value = await request(started).catch(() => null);
      const final = await readSources();
      if (generation !== activeGeneration) return { current: false, value: null };
      if (value == null || !final) return { current: true, value: null };
      return { current: true, value: restrict(value, intersectSources(started, final)) };
    },
  };
}

async function readCanonicalUsageSources(): Promise<ReadonlySet<UsageSourceId> | null> {
  try {
    const sourceIds = await invoke<unknown>("enabled_local_usage_source_ids");
    if (!Array.isArray(sourceIds)) return null;
    return new Set(USAGE_SOURCES.filter((source) => sourceIds.includes(source)));
  } catch {
    return null;
  }
}

type ActivityRequestDependencies = SourceAuthorizationDependencies & {
  scanSource: (source: UsageSourceId) => Promise<UsageReport | null>;
};

export function createInsightsActivityRequestCoordinator(
  dependencies: ActivityRequestDependencies,
) {
  const authorization = createSourceAuthorizedRequestCoordinator(dependencies);
  return {
    invalidate: () => authorization.invalidate(),
    load: () => authorization.run(
      async (started) => {
        const entries = await Promise.all(USAGE_SOURCES.map(async (source) => [
          source,
          started.has(source) ? await dependencies.scanSource(source).catch(() => null) : null,
        ] as const));
        return Object.fromEntries(entries) as UsageReports;
      },
      (reports, allowed) => Object.fromEntries(USAGE_SOURCES.map((source) => [
        source,
        allowed.has(source) ? reports[source] : null,
      ])) as UsageReports,
    ),
  };
}

function reportUsesOnlySources(
  report: ProjectInsightsReport,
  allowed: ReadonlySet<UsageSourceId>,
): boolean {
  const sources = [
    ...report.overview.confidence.map((item) => item.source),
    report.overview.topSource?.source,
    report.overview.topModel?.source,
    report.overview.topProject?.source,
    ...report.projects.map((project) => project.source),
    report.selectedProject?.project.source,
  ].filter((source): source is string => source != null);
  return sources.every((source) => allowed.has(source as UsageSourceId));
}

type HistoryRequestDependencies = SourceAuthorizationDependencies & {
  fetchReport: (
    days: InsightsPeriodDays,
    projectKey: string | null,
  ) => Promise<ProjectInsightsReport | null>;
};

export function createInsightsHistoryRequestCoordinator(
  dependencies: HistoryRequestDependencies,
) {
  const authorization = createSourceAuthorizedRequestCoordinator(dependencies);
  return {
    invalidate: () => authorization.invalidate(),
    load: (days: InsightsPeriodDays, projectKey: string | null) => authorization.run(
      () => dependencies.fetchReport(days, projectKey),
      (report, allowed) => reportUsesOnlySources(report, allowed) ? report : null,
    ),
  };
}

/** Exactly one compact All-tab card. Layout mirrors budget card (title · hero · foot). */
export function insightsHighlightCard(
  report: ProjectInsightsReport | null,
  onOpen: () => void,
): HTMLElement {
  const button = el("button", "card insights-highlight");
  button.setAttribute("type", "button");
  button.setAttribute("aria-label", t("insightsOpenDetails"));
  button.addEventListener("click", onOpen);

  const head = el("div", "insights-highlight-head");
  head.append(el("span", "summary-label", t("insightsTitle")));
  const headMeta = el("span", "insights-highlight-head-meta");
  headMeta.append(el("span", "insights-highlight-confidence",
    report ? confidenceLabel(report.overview.confidence) : t("insightsConfidenceUnavailable")));
  headMeta.append(el("span", "insights-highlight-chevron", "›"));
  head.append(headMeta);

  const pulse = el("div", "insights-highlight-pulse");
  pulse.append(el("span", "insights-highlight-current",
    report ? usd(report.overview.current7Usd) : t("insightsUnavailable")));
  pulse.append(el("span", "insights-delta", deltaLabel(report?.overview.changePct ?? null)));

  const meta = el("div", "insights-highlight-meta");
  meta.append(el("span", "insights-highlight-project",
    t("insightsTopProject", { project: projectName(report?.overview.topProject ?? null) })));
  button.append(head, pulse, meta);
  return button;
}

function paneHeader(): HTMLElement {
  const head = el("div", "sw-pane-header");
  head.append(el("div", "sw-pane-title", t("settingsTabInsights")));
  head.append(el("div", "sw-pane-subtitle", t("insightsSubtitle")));
  return head;
}

function segmentControl(active: InsightsSegment, onChange: (segment: InsightsSegment) => void): HTMLElement {
  const control = el("div", "insights-segments");
  for (const segment of ["overview", "activity", "projects"] as const) {
    const label = segment === "overview" ? t("insightsOverview")
      : segment === "activity" ? t("insightsSegmentActivity")
        : t("insightsProjects");
    const button = el("button", `insights-segment${active === segment ? " active" : ""}`, label);
    button.setAttribute("type", "button");
    button.addEventListener("click", () => onChange(segment));
    control.append(button);
  }
  return control;
}

function periodControl(
  active: InsightsPeriodDays,
  onChange: (days: InsightsPeriodDays) => void,
): HTMLElement {
  const control = el("div", "insights-periods");
  const options: Array<{ days: InsightsPeriodDays; label: string }> = [
    { days: 1, label: t("insightsPeriodToday") },
    { days: 7, label: "7d" },
    { days: 30, label: "30d" },
    { days: 90, label: "90d" },
  ];
  for (const option of options) {
    const button = el(
      "button",
      `insights-period${active === option.days ? " active" : ""}`,
      option.label,
    );
    button.setAttribute("type", "button");
    button.addEventListener("click", () => onChange(option.days));
    control.append(button);
  }
  return control;
}

/** Overview: view bar only. Projects: view + period, both leading (no stretch). */
function insightsToolbar(
  segment: InsightsSegment,
  days: InsightsPeriodDays,
  onSegment: (segment: InsightsSegment) => void,
  onDays: (days: InsightsPeriodDays) => void,
): HTMLElement {
  const row = el("div", "insights-toolbar");
  row.append(segmentControl(segment, onSegment));
  if (segment === "projects") row.append(periodControl(days, onDays));
  return row;
}

function overviewSummary(report: ProjectInsightsReport): string {
  const overview = report.overview;
  const lines = [
    t("insightsCopyPulse", {
      current: usd(overview.current7Usd),
      previous: usd(overview.previous7Usd),
      change: deltaLabel(overview.changePct),
    }),
  ];
  if (overview.topSource) lines.push(t("insightsCopySource", { source: sourceName(overview.topSource.source) }));
  if (overview.topModel) lines.push(t("insightsCopyModel", { model: overview.topModel.name }));
  lines.push(t("insightsTopProject", { project: projectName(overview.topProject) }));
  lines.push(confidenceLabel(overview.confidence, true));
  return lines.join("\n");
}

function overviewView(report: ProjectInsightsReport): HTMLElement {
  const wrap = el("div", "insights-overview");
  const pulse = el("section", "insights-panel");
  const head = el("div", "insights-panel-head");
  head.append(el("span", "sw-section-header", t("insightsWeeklyPulse")));
  head.append(el("span", "insights-delta", deltaLabel(report.overview.changePct)));
  pulse.append(head);
  const values = el("div", "insights-metric-grid");
  values.append(metric(t("insightsCurrent7"), usd(report.overview.current7Usd), tokens(report.overview.current7Tokens)));
  values.append(metric(t("insightsPrevious7"), usd(report.overview.previous7Usd), tokens(report.overview.previous7Tokens)));
  pulse.append(values);

  const leaders = el("section", "insights-panel insights-leaders");
  leaders.append(insightRow(t("insightsTopSourceLabel"), report.overview.topSource ? sourceName(report.overview.topSource.source) : "—"));
  leaders.append(insightRow(t("insightsTopModelLabel"), report.overview.topModel?.name ?? "—"));
  leaders.append(insightRow(
    t("insightsConfidenceLabel"),
    confidenceLabel(report.overview.confidence, true),
  ));

  const copy = el("button", "sw-pill-btn", t("insightsCopySummary"));
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(overviewSummary(report));
      copy.textContent = t("aboutCopied");
      setTimeout(() => { copy.textContent = t("insightsCopySummary"); }, 1500);
    } catch {
      copy.textContent = t("insightsCopyFailed");
      setTimeout(() => { copy.textContent = t("insightsCopySummary"); }, 1500);
    }
  });
  wrap.append(pulse, leaders, copy);
  return wrap;
}

function metric(label: string, value: string, sub: string): HTMLElement {
  const item = el("div", "insights-metric");
  item.append(el("div", "insights-metric-label", label));
  item.append(el("div", "insights-metric-value", value));
  item.append(el("div", "insights-metric-sub", sub));
  return item;
}

function insightRow(label: string, value: string): HTMLElement {
  const row = el("div", "insights-row");
  row.append(el("span", "insights-row-label", label));
  row.append(el("span", "insights-row-value", value));
  return row;
}

function projectsView(
  report: ProjectInsightsReport,
  onSelect: (key: string) => void,
): HTMLElement {
  const wrap = el("div", "insights-projects");

  const list = el("div", "insights-project-list");
  if (report.projects.length === 0) {
    list.append(el("div", "empty", t("insightsNoProjects")));
  } else {
    const totalUsd = report.projects.reduce((sum, project) => sum + project.usd, 0);
    const head = el("div", "insights-project-head");
    head.append(el("span", "insights-project-head-name", t("insightsProjects")));
    head.append(el("span", "insights-project-head-pct", "%"));
    head.append(el("span", "insights-project-head-usd", "$"));
    list.append(head);
    for (const project of report.projects) {
      const selected = report.selectedProject?.project.projectKey === project.projectKey;
      const row = el("button", `insights-project-row${selected ? " active" : ""}`);
      const identity = el("span", "insights-project-identity");
      identity.append(el("span", "insights-project-name", projectName(project)));
      identity.append(el("span", "insights-project-source",
        `${sourceName(project.source)} · ${project.isUnknown
          ? t("insightsUnknownAttribution")
          : project.capability === "exact" ? t("insightsExactAttribution") : t("insightsDerivedAttribution")}`));
      const share = totalUsd > 0 ? Math.round((project.usd / totalUsd) * 100) : 0;
      const pct = el("span", "insights-project-pct", `${share}%`);
      const amount = el("span", "insights-project-amount");
      amount.append(el("span", "insights-project-usd", usd(project.usd)));
      amount.append(el("span", "insights-project-tokens", tokens(project.tokens)));
      row.append(identity, pct, amount);
      row.addEventListener("click", () => onSelect(project.projectKey));
      list.append(row);
    }
  }
  wrap.append(list);
  if (report.selectedProject) wrap.append(projectDetail(report.selectedProject));
  return wrap;
}

function projectDetail(detail: NonNullable<ProjectInsightsReport["selectedProject"]>): HTMLElement {
  const section = el("section", "insights-detail");
  section.append(el("div", "insights-detail-title", projectName(detail.project)));
  const models = el("div", "insights-detail-models");
  models.append(el("div", "sw-section-header", t("insightsModelBreakdown")));
  if (detail.models.length === 0) models.append(el("div", "insights-muted", t("insightsNoModelBreakdown")));
  for (const model of detail.models) models.append(insightRow(model.name, `${usd(model.usd)} · ${tokens(model.tokens)}`));
  const days = el("div", "insights-detail-days");
  days.append(el("div", "sw-section-header", t("insightsDailyBreakdown")));
  for (const day of detail.daily.filter((item) => item.usd > 0 || item.tokens > 0).reverse()) {
    days.append(insightRow(day.date, `${usd(day.usd)} · ${tokens(day.tokens)}`));
  }
  section.append(models, days);
  return section;
}

/** Segment "Hoạt động": heatmap 52 tuần dựng từ báo cáo cost đã quét. */
function activityView(
  requests: ReturnType<typeof createInsightsActivityRequestCoordinator>,
): HTMLElement {
  const host = el("div", "insights-activity-host");
  host.append(el("div", "loading", "…"));
  void (async () => {
    const result = await requests.load();
    if (!result.current) return;
    host.textContent = "";
    if (!result.value) {
      host.append(el("div", "empty", t("insightsLoadError")));
      return;
    }
    const reports = result.value;
    host.append(activityContent(combine(
      reports.claude,
      reports.codex,
      reports.grok,
      reports.omp,
      reports.pi,
      reports.kiro,
    )));
  })();
  return host;
}


export async function insightsPane(): Promise<HTMLElement> {
  const page = el("div", "settings-page insights-page");
  const activityRequests = createInsightsActivityRequestCoordinator({
    readCanonicalSources: readCanonicalUsageSources,
    scanSource: (source) => invoke<UsageReport | null>(`${source}_usage_report`),
  });
  const historyRequests = createInsightsHistoryRequestCoordinator({
    readCanonicalSources: readCanonicalUsageSources,
    fetchReport: fetchProjectInsightsReport,
  });
  const savedSegment = localStorage.getItem(SEGMENT_KEY);
  let segment: InsightsSegment = savedSegment === "projects" ? "projects"
    : savedSegment === "activity" ? "activity" : "overview";
  const savedDays = Number(localStorage.getItem(DAYS_KEY));
  let days: InsightsPeriodDays =
    savedDays === 1 || savedDays === 30 || savedDays === 90 ? savedDays : 7;
  let selectedKey = localStorage.getItem(PROJECT_KEY);
  const loadReport = async (requestedDays: InsightsPeriodDays, requestedKey: string | null) => {
    let resolvedKey = requestedKey;
    const first = await historyRequests.load(requestedDays, resolvedKey);
    if (!first.current) return { current: false, report: null, selectedKey: resolvedKey };
    let next = first.value;
    if (!next) return { current: true, report: null, selectedKey: resolvedKey };
    const selectedIsVisible = next.projects.some((project) => project.projectKey === resolvedKey);
    if (next.projects.length === 0) {
      resolvedKey = null;
    } else if (!selectedIsVisible) {
      resolvedKey = next.projects[0].projectKey;
      const selected = await historyRequests.load(requestedDays, resolvedKey);
      if (!selected.current) return { current: false, report: null, selectedKey: resolvedKey };
      if (!selected.value) return { current: true, report: null, selectedKey: resolvedKey };
      next = selected.value;
    }
    return { current: true, report: next, selectedKey: resolvedKey };
  };
  const persistSelection = (key: string | null) => {
    if (key) localStorage.setItem(PROJECT_KEY, key);
    else localStorage.removeItem(PROJECT_KEY);
  };
  const initial = await loadReport(days, selectedKey);
  let report = initial.report;
  selectedKey = initial.selectedKey;
  persistSelection(selectedKey);
  let reportSeq = 0;

  const render = () => {
    page.textContent = "";
    page.append(paneHeader());
    page.append(insightsToolbar(
      segment,
      days,
      (next) => {
        segment = next;
        localStorage.setItem(SEGMENT_KEY, next);
        render();
      },
      changeDays,
    ));
    if (!report) {
      activityRequests.invalidate();
      page.append(el("div", "empty", t("insightsLoadError")));
      return;
    }
    if (segment === "overview") {
      activityRequests.invalidate();
      page.append(overviewView(report));
    } else if (segment === "activity") {
      page.append(activityView(activityRequests));
    } else {
      activityRequests.invalidate();
      page.append(projectsView(report, selectProject));
    }
  };

  const refresh = async () => {
    const seq = ++reportSeq;
    const requestedDays = days;
    const requestedKey = selectedKey;
    const next = await loadReport(requestedDays, requestedKey);
    if (seq !== reportSeq || !next.current) return;
    report = next.report;
    selectedKey = next.selectedKey;
    persistSelection(selectedKey);
    render();
  };
  const changeDays = (next: InsightsPeriodDays) => {
    days = next;
    localStorage.setItem(DAYS_KEY, String(next));
    void refresh();
  };
  const selectProject = (key: string) => {
    selectedKey = key;
    localStorage.setItem(PROJECT_KEY, key);
    void refresh();
  };
  render();
  return page;
}

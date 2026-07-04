import { invoke } from "@tauri-apps/api/core";
import { combine, UsageReport } from "./usage";
import { chartCard, heatmapCard, topModelsCard } from "./all-tab";

async function load() {
  const app = document.querySelector("#app")!;
  const [claude, codex] = await Promise.all([
    invoke<UsageReport | null>("claude_usage_report").catch(() => null),
    invoke<UsageReport | null>("codex_usage_report").catch(() => null),
  ]);

  app.textContent = "";
  if (!claude && !codex) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent =
      "Không tìm thấy log Claude Code (~/.claude) hoặc Codex (~/.codex) trên máy này.";
    app.append(empty);
    return;
  }

  const combined = combine(claude, codex);
  app.append(chartCard(combined, claude?.hourly ?? []));
  app.append(heatmapCard(combined));
  if (combined.topModels.length > 0) {
    app.append(topModelsCard(combined));
  }
}

window.addEventListener("DOMContentLoaded", () => {
  load().catch((err) => {
    const app = document.querySelector("#app")!;
    app.textContent = `Lỗi khi quét: ${err}`;
  });
});

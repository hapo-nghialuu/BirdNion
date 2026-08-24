// Cầu nối từ popover sang cửa sổ panel phụ (`panel.html`).
//
// Cùng semantics macOS: hover mở panel transient rồi tự đóng sau debounce khi
// chuột rời; click ghim panel lại, khi đã ghim thì hover không chiếm chỗ nữa
// và chỉ nút ✕ trong panel mới đóng được.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { CombinedDay, CombinedModel } from "./usage";
import type { AgentPanelPayload, AgentTabId } from "./agent-panel-payload";

const CLOSE_DELAY_MS = 140;

let pinned = false;
let closeTimer: number | null = null;
/** Loại nội dung panel đang mở — quyết định phạm vi đóng khi đổi kỳ. */
let openKind: "day" | "models" | "agent" | "activity" | null = null;

function cancelPendingClose(): void {
  if (closeTimer != null) {
    clearTimeout(closeTimer);
    closeTimer = null;
  }
}

async function show(payload: unknown, isPinned: boolean): Promise<void> {
  cancelPendingClose();
  // Hover không được đè panel đang ghim.
  if (!isPinned && pinned) return;
  pinned = isPinned;
  openKind = (payload as { kind?: typeof openKind }).kind ?? null;
  try {
    await invoke("open_side_panel", { payload, pinned: isPinned });
  } catch {
    // Panel là phụ trợ: lỗi mở cửa sổ không được làm hỏng popover.
  }
}

/** Hover rời: đóng sau debounce, chỉ khi chưa ghim — rê chuột giữa các cột
 *  liền kề sẽ re-enter trước deadline nên panel không nháy. */
export function closeTransientPanel(): void {
  if (pinned) return;
  cancelPendingClose();
  closeTimer = window.setTimeout(() => {
    closeTimer = null;
    if (pinned) return;
    void invoke("close_side_panel").catch(() => { /* phụ trợ */ });
  }, CLOSE_DELAY_MS);
}

/** Đóng dứt khoát (nút ✕, hoặc khi panel không còn hợp lệ). */
export function closePinnedPanel(): void {
  cancelPendingClose();
  pinned = false;
  openKind = null;
  void invoke("close_side_panel").catch(() => { /* phụ trợ */ });
}

/** Đổi kỳ thời gian: chỉ đóng panel NGÀY — ngày đã ghim không còn thuộc cửa
 *  sổ mới. Panel agent/hoạt động vẫn hợp lệ nên giữ nguyên, đúng như macOS
 *  `closeDayDetail()` (`guard content == .day`). */
export function closeDayPanelOnly(): void {
  if (openKind !== "day") return;
  closePinnedPanel();
}

export function isPanelPinned(): boolean {
  return pinned;
}

// Panel tự đóng (nút ✕ trong cửa sổ phụ) — nhả cờ ghim để hover mở lại được.
void listen("birdnion-panel-closed", () => {
  cancelPendingClose();
  pinned = false;
  openKind = null;
});

export function showDayPanel(
  day: CombinedDay,
  windowUsd: number,
  windowLabel: string,
  isPinned: boolean,
): void {
  void show({ kind: "day", pinned: isPinned, day, windowUsd, windowLabel }, isPinned);
}

export function showModelsPanel(models: CombinedModel[], mode: "model" | "token"): void {
  void show({ kind: "models", models, mode }, false);
}

/** `initialTab` chọn tab mở đầu theo nguồn click (hàng quota/cost/config) —
 *  parity macOS `AgentDetailPanelCoordinator.show(initialTab:)`. */
export function showAgentPanel(
  payload: AgentPanelPayload,
  initialTab: AgentTabId,
  isPinned = true,
): void {
  void show({ ...payload, initialTab }, isPinned);
}

export function showActivityPanel(
  cells: { date: string; usd: number; tokens: number }[],
  peakUsd: number,
  avgUsd: number,
  streak: number,
  longestStreak: number,
  isPinned = true,
): void {
  void show({ kind: "activity", cells, peakUsd, avgUsd, streak, longestStreak }, isPinned);
}

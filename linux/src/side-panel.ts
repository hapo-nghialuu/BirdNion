// Cầu nối từ popover sang cửa sổ panel phụ (`panel.html`).
//
// Cùng semantics macOS: hover mở panel transient rồi tự đóng sau debounce khi
// chuột rời; click ghim panel lại, khi đã ghim thì hover không chiếm chỗ nữa
// và chỉ nút ✕ trong panel mới đóng được.

import { invoke } from "@tauri-apps/api/core";
import type { CombinedDay, CombinedModel } from "./usage";

const CLOSE_DELAY_MS = 140;

let pinned = false;
let closeTimer: number | null = null;

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

/** Đóng dứt khoát (đổi period, đổi tab, ✕ trong panel). */
export function closePinnedPanel(): void {
  cancelPendingClose();
  pinned = false;
  void invoke("close_side_panel").catch(() => { /* phụ trợ */ });
}

export function isPanelPinned(): boolean {
  return pinned;
}

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

export function showAgentPanel(
  agentId: string,
  displayName: string,
  rows: { label: string; value: string }[],
  isPinned = true,
): void {
  void show({ kind: "agent", agentId, displayName, rows }, isPinned);
}

export function showActivityPanel(
  cells: { date: string; usd: number; tokens: number }[],
  peakUsd: number,
  avgUsd: number,
  streak: number,
): void {
  void show({ kind: "activity", cells, peakUsd, avgUsd, streak }, true);
}

// Dedicated entry for the Settings webview — never mounts the popover/load/tick loop.
import { mountSettingsWindow } from "./settings-window";
import { t } from "./i18n";
import { initTheme } from "./theme";

declare global {
  interface Window {
    __BIRDNION_MODE__?: string;
  }
}

window.__BIRDNION_MODE__ = "settings";

window.addEventListener("DOMContentLoaded", () => {
  initTheme();
  void mountSettingsWindow()
    .catch((err) => {
      const app = document.querySelector("#app");
      if (app) app.textContent = `${t("loadError")}: ${err}`;
      console.error("settings mount failed", err);
    });
});

// Inline SVG marks matching SF Symbols used by macOS BirdNion Settings
// (SettingsTab.icon + popover footer). currentColor stroke style.

export type SettingsIconId =
  | "gearshape"
  | "square.grid.2x2"
  | "terminal"
  | "eye"
  | "eye.slash"
  | "slider.horizontal.3"
  | "info.circle"
  | "power"
  | "arrow.clockwise";

/** Minimal outline icons at 24×24, visually close to SF Symbols @ 20pt. */
const PATHS: Record<SettingsIconId, string> = {
  gearshape: `
    <path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"
      d="M12 8.2a3.8 3.8 0 1 0 0 7.6 3.8 3.8 0 0 0 0-7.6z"/>
    <path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"
      d="M12 3.2v1.6M12 19.2v1.6M4.9 6.3l1.1 1.1M18 17.6l1.1 1.1M3.2 12h1.6M19.2 12h1.6M4.9 17.7l1.1-1.1M18 6.4l1.1-1.1"/>
    <path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"
      d="M9.2 4.4l.6 1.7-1.4 1.1-1.8-.3-.9 1.5 1.2 1.3-.3 1.8 1.5.9 1.1-1.4 1.7.6 1.1 1.4.9-1.5 1.8.3 1.3-1.2-.3-1.8 1.5-.9-.9-1.5-1.8.3-1.4-1.1.6-1.7h-1.8z"/>`,

  "square.grid.2x2": `
    <rect x="3.5" y="3.5" width="7.2" height="7.2" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.55"/>
    <rect x="13.3" y="3.5" width="7.2" height="7.2" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.55"/>
    <rect x="3.5" y="13.3" width="7.2" height="7.2" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.55"/>
    <rect x="13.3" y="13.3" width="7.2" height="7.2" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.55"/>`,

  terminal: `
    <rect x="2.8" y="4.2" width="18.4" height="15.6" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.55"/>
    <path d="M6.8 9.2l3.2 2.8-3.2 2.8" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M12.2 14.8H17" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>`,

  eye: `
    <path d="M2.2 12s3.4-6.2 9.8-6.2S21.8 12 21.8 12s-3.4 6.2-9.8 6.2S2.2 12 2.2 12z"
      fill="none" stroke="currentColor" stroke-width="1.55" stroke-linejoin="round"/>
    <circle cx="12" cy="12" r="2.5" fill="none" stroke="currentColor" stroke-width="1.55"/>`,

  "eye.slash": `
    <path d="M3.2 3.2l17.6 17.6" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>
    <path d="M9.4 9.6A3 3 0 0 0 12 15a3 3 0 0 0 2.4-1.2" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>
    <path d="M6.4 6.8C4.2 8.1 2.6 10.1 2.2 12c0 0 3.4 6.2 9.8 6.2 1.4 0 2.7-.3 3.8-.7M10 5.9c.6-.1 1.3-.2 2-.2 6.4 0 9.8 6.3 9.8 6.3-.5 1-1.4 2.2-2.6 3.2" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"/>`,

  "slider.horizontal.3": `
    <path d="M3.5 7h17M3.5 12h17M3.5 17h17" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>
    <circle cx="8.5" cy="7" r="2.15" fill="currentColor"/>
    <circle cx="15.5" cy="12" r="2.15" fill="currentColor"/>
    <circle cx="10.5" cy="17" r="2.15" fill="currentColor"/>`,

  "info.circle": `
    <circle cx="12" cy="12" r="8.25" fill="none" stroke="currentColor" stroke-width="1.55"/>
    <path d="M12 10.6v5.4" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
    <circle cx="12" cy="7.9" r="0.95" fill="currentColor"/>`,

  power: `
    <path d="M12 3.2v8.2" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
    <path d="M7.05 6.15a7.1 7.1 0 1 0 9.9 0" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>`,

  "arrow.clockwise": `
    <path d="M19.6 12a7.6 7.6 0 1 1-2.2-5.3" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"/>
    <path d="M19.6 4.2v5.2h-5.2" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"/>`,
};

// Cleaner gear using classic cog outline
PATHS.gearshape = `
  <path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"
    d="M10.1 3.6h3.8l.5 2.1 1.9.8 1.9-1.1 2.7 2.7-1.1 1.9.8 1.9 2.1.5v3.8l-2.1.5-.8 1.9 1.1 1.9-2.7 2.7-1.9-1.1-1.9.8-.5 2.1h-3.8l-.5-2.1-1.9-.8-1.9 1.1-2.7-2.7 1.1-1.9-.8-1.9-2.1-.5v-3.8l2.1-.5.8-1.9-1.1-1.9 2.7-2.7 1.9 1.1 1.9-.8.5-2.1z"/>
  <circle cx="12" cy="12" r="3.1" fill="none" stroke="currentColor" stroke-width="1.5"/>`;

export function settingsIcon(id: SettingsIconId, className = "sw-icon"): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", className);
  svg.innerHTML = PATHS[id];
  return svg;
}

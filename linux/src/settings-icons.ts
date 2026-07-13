// Settings / popover icons — match macOS SF Symbols used by SettingsTab:
// gearshape · square.grid.2x2 · terminal · eye · slider.horizontal.3 · info.circle
// Rendered at 20×20 in the tab bar (viewBox 24×24, regular stroke ~1.5–1.7).

export type SettingsIconId =
  | "gearshape"
  | "square.grid.2x2"
  | "terminal"
  | "eye"
  | "eye.slash"
  | "slider.horizontal.3"
  | "info.circle"
  | "power"
  | "arrow.clockwise"
  | "person"
  | "key";

/** Shared outline attrs — SF regular weight optical match at 20pt. */
const O = 'fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"';

/**
 * Path geometry based on SF Symbol silhouettes (not filled glyphs).
 * Tuned so tabs read like the macOS Settings toolbar, not generic Material icons.
 */
const PATHS: Record<SettingsIconId, string> = {
  // SF `gearshape` — continuous 6-tooth cog + hub (Heroicons cog-6-tooth silhouette).
  gearshape: `
    <path ${O} d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.076.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.431.992a6.76 6.76 0 0 1 0 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.02-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 0 1 0-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281Z"/>
    <path ${O} d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/>`,

  // SF `square.grid.2x2` — four equal rounded squares, ~2.8pt gap.
  "square.grid.2x2": `
    <rect x="3.75" y="3.75" width="6.85" height="6.85" rx="1.5" ${O}/>
    <rect x="13.4" y="3.75" width="6.85" height="6.85" rx="1.5" ${O}/>
    <rect x="3.75" y="13.4" width="6.85" height="6.85" rx="1.5" ${O}/>
    <rect x="13.4" y="13.4" width="6.85" height="6.85" rx="1.5" ${O}/>`,

  // SF `terminal` — soft window, chevron prompt, cursor bar.
  terminal: `
    <rect x="3.1" y="4.6" width="17.8" height="14.8" rx="2.5" ${O}/>
    <path ${O} d="M7.15 9.55l2.75 2.35-2.75 2.35"/>
    <path ${O} d="M12.15 14.25h4.7"/>`,

  // SF `eye`
  eye: `
    <path ${O} d="M2.7 12s3.4-5.7 9.3-5.7S21.3 12 21.3 12s-3.4 5.7-9.3 5.7S2.7 12 2.7 12Z"/>
    <circle cx="12" cy="12" r="2.45" ${O}/>`,

  // SF `eye.slash`
  "eye.slash": `
    <path ${O} d="M3.35 3.5l17.3 17.3"/>
    <path ${O} d="M9.6 9.75A2.45 2.45 0 0 0 12 14.45c.5 0 .97-.15 1.35-.42"/>
    <path ${O} d="M6.65 7C4.7 8.2 3.3 10 2.7 12c0 0 3.4 5.7 9.3 5.7 1.3 0 2.45-.25 3.45-.65"/>
    <path ${O} d="M10.2 6.25c.55-.12 1.15-.18 1.8-.18 5.9 0 9.3 5.7 9.3 5.7-.4.9-1.1 1.85-2 2.7"/>`,

  // SF `slider.horizontal.3` — three tracks, knobs at staggered X.
  "slider.horizontal.3": `
    <path ${O} d="M3.6 7h16.8"/>
    <path ${O} d="M3.6 12h16.8"/>
    <path ${O} d="M3.6 17h16.8"/>
    <circle cx="8.1" cy="7" r="2" fill="currentColor" stroke="none"/>
    <circle cx="15.7" cy="12" r="2" fill="currentColor" stroke="none"/>
    <circle cx="10.5" cy="17" r="2" fill="currentColor" stroke="none"/>`,

  // SF `info.circle`
  "info.circle": `
    <circle cx="12" cy="12" r="8.15" ${O}/>
    <path ${O} d="M12 10.9v5"/>
    <circle cx="12" cy="8" r="0.9" fill="currentColor" stroke="none"/>`,

  // SF `power` (Claude Code / power button)
  power: `
    <path ${O} d="M12 3.75v7.2"/>
    <path ${O} d="M7.25 6.7a6.75 6.75 0 1 0 9.5 0"/>`,

  // SF `arrow.clockwise` (popover refresh)
  "arrow.clockwise": `
    <path ${O} d="M19.25 12A7.25 7.25 0 1 1 17.1 6.9"/>
    <path ${O} d="M19.25 4.7v4.75H14.5"/>`,

  // SF `person.crop.circle` (accounts section)
  person: `
    <circle cx="12" cy="12" r="8.15" ${O}/>
    <circle cx="12" cy="10" r="2.6" ${O}/>
    <path ${O} d="M6.8 18.1a6.4 6.4 0 0 1 10.4 0"/>`,

  // SF `key.fill` outline (ElevenLabs multi-key switcher)
  key: `
    <circle cx="8.2" cy="12" r="3.4" ${O}/>
    <path ${O} d="M11.2 12h8.3"/>
    <path ${O} d="M16.4 12v2.4"/>
    <path ${O} d="M18.7 12v1.7"/>`,
};

export function settingsIcon(id: SettingsIconId, className = "sw-icon"): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "24");
  svg.setAttribute("height", "24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", className);
  svg.innerHTML = PATHS[id] ?? PATHS.gearshape;
  return svg;
}

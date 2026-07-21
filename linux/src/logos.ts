// Provider logo marks for the icon-only tab strip (macOS ProviderLogoMark parity).
// Assets live in public/logos/ (copied from Assets.xcassets).

const EXT: Record<string, "svg" | "png"> = {
  minimax: "png",
  hapo: "png",
};

/** Absolute-ish public path for a provider logo, or null when unknown. */
export function logoUrl(id: string): string | null {
  const known = new Set([
    "claude", "codex", "grok", "openai", "ollama", "minimax", "hapo",
    "openrouter", "deepseek", "zai", "elevenlabs", "deepgram", "groq",
    "copilot", "kilo", "commandcode", "freemodel", "mimo", "alibaba",
    "cursor", "gemini", "kiro", "opencode", "opencodego", "antigravity", "bedrock",
  ]);
  if (!known.has(id)) return null;
  const ext = EXT[id] ?? "svg";
  return `/logos/${id}.${ext}`;
}

/**
 * Build a logo mark.
 * - Default: colored <img> (settings sidebar / detail).
 * - Class containing `tab-logo-mono`: CSS mask + currentColor-style fill so
 *   the popover tab strip can tint secondary/blue like macOS ProviderLogoMark.
 */
export function logoMark(id: string, className = "tab-logo"): HTMLElement {
  const url = logoUrl(id);
  const mono = className.includes("tab-logo-mono");

  if (url && mono) {
    const wrap = document.createElement("span");
    wrap.className = className;
    wrap.setAttribute("role", "img");
    wrap.setAttribute("aria-label", id);
    // Mask the brand SVG so background-color becomes the icon ink.
    wrap.style.maskImage = `url("${url}")`;
    wrap.style.webkitMaskImage = `url("${url}")`;
    wrap.style.maskSize = "contain";
    wrap.style.webkitMaskSize = "contain";
    wrap.style.maskRepeat = "no-repeat";
    wrap.style.webkitMaskRepeat = "no-repeat";
    wrap.style.maskPosition = "center";
    wrap.style.webkitMaskPosition = "center";
    return wrap;
  }

  if (url) {
    const img = document.createElement("img");
    img.className = className;
    img.src = url;
    img.alt = id;
    img.draggable = false;
    img.onerror = () => {
      img.replaceWith(monogram(id, className));
    };
    return img;
  }
  return monogram(id, className);
}

function monogram(id: string, className: string): HTMLElement {
  const span = document.createElement("span");
  span.className = `${className} tab-logo-letter`;
  span.textContent = (id[0] ?? "?").toUpperCase();
  return span;
}

/**
 * Brand tint per provider — mirrors macOS VocabbyTheme.providerTint.
 * [light, dark] pairs where the dark scheme needs a lifted tone
 * (grok #111827 and commandcode #000 vanish on dark surfaces).
 */
const PROVIDER_TINT: Record<string, [string, string]> = {
  codex: ["#49A3B0", "#49A3B0"],
  minimax: ["#FE603C", "#FE603C"],
  openrouter: ["#6467F2", "#6467F2"],
  deepseek: ["#527DF0", "#527DF0"],
  zai: ["#E85A6A", "#E85A6A"],
  claude: ["#CC7C5E", "#CC7C5E"],
  deepgram: ["#6467F2", "#6467F2"],
  groq: ["#F56844", "#F56844"],
  grok: ["#111827", "#C8CCD6"],
  openai: ["#0F826E", "#0F826E"],
  ollama: ["#888888", "#888888"],
  copilot: ["#A855F7", "#A855F7"],
  kilo: ["#F27027", "#F27027"],
  commandcode: ["#000000", "#E5E5E5"],
  freemodel: ["#22C55E", "#22C55E"],
  mimo: ["#FF6900", "#FF6900"],
  alibaba: ["#FF6A00", "#FF6A00"],
  cursor: ["#00BFA5", "#00BFA5"],
  gemini: ["#AB87EA", "#AB87EA"],
  kiro: ["#8B47F9", "#8B47F9"],
  opencode: ["#3B82F6", "#3B82F6"],
  opencodego: ["#3B82F6", "#3B82F6"],
  antigravity: ["#60BA7E", "#60BA7E"],
  bedrock: ["#FF9900", "#FF9900"],
};

/** CSS light-dark() pair for the chip tint; undefined → fall back to secondary. */
export function providerTintCss(id: string): string | undefined {
  const pair = PROVIDER_TINT[id];
  if (!pair) return undefined;
  return pair[0] === pair[1] ? pair[0] : `light-dark(${pair[0]}, ${pair[1]})`;
}

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

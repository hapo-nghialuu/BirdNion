// Provider logo marks for the icon-only tab strip (macOS ProviderLogoMark parity).
// Assets live in public/logos/ (copied from Assets.xcassets).

const EXT: Record<string, "svg" | "png"> = {
  minimax: "png",
  hapo: "png",
  aider: "png",
  goose: "png",
};

/** Absolute-ish public path for a provider logo, or null when unknown. */
export function logoUrl(id: string): string | null {
  const known = new Set([
    "claude", "codex", "grok", "openai", "ollama", "minimax", "hapo",
    "openrouter", "tryapi", "deepseek", "zai", "elevenlabs", "hiyo", "deepgram", "groq",
    "copilot", "kilo", "commandcode", "freemodel", "mimo", "alibaba",
    "cursor", "gemini", "kiro", "opencode", "opencodego", "antigravity", "bedrock",
    // Agent không phải provider — cần logo cho Cost by / danh sách agent cài đặt.
    "omp", "pi", "aider", "amp", "auggie", "goose", "qwen",
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
  // Tab strip tự đặt `--tab-tint`; chỗ khác thì tô ngay bằng màu brand.
  const tinted = !mono && !NATURAL_COLOR_LOGOS.has(id);

  if (url && (mono || tinted)) {
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
    wrap.style.display = "inline-block";
    if (tinted) {
      wrap.style.backgroundColor = LOGO_INK[id] ?? providerTintCss(id) ?? "var(--text2)";
    }
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
  tryapi: ["#5B6CFF", "#5B6CFF"],
  deepseek: ["#527DF0", "#527DF0"],
  hiyo: ["#527DF0", "#527DF0"],
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
  // elevenlabs/auggie/pi bám màu chữ như macOS (mark gốc gần như đen/trắng).
  elevenlabs: ["#16150F", "#F2F0E8"],
  auggie: ["#16150F", "#F2F0E8"],
  pi: ["#06B6D4", "#22D3EE"],
  omp: ["#8B5CF6", "#A78BFA"],
  qwen: ["#FF6A00", "#FF6A00"],
};

/**
 * Mark giữ NGUYÊN màu gốc — phần còn lại là template (một màu, `none`,
 * `currentColor` hoặc trắng) nên phải tô mới nhìn thấy được. Đây chính là
 * chỗ macOS phân biệt `logo(name)` với `logo(name, brand:)`.
 *
 * Không tô thì grok/claude/commandcode... ra trắng trên nền sáng, và mọi mark
 * gần-đen sẽ biến mất ở theme tối.
 */
const NATURAL_COLOR_LOGOS = new Set(["minimax", "hapo", "aider", "goose", "amp", "omp"]);

/**
 * Màu mực của mark khi đứng trong danh sách (hàng agent, panel, settings).
 * KHÁC với `providerTintCss` dùng cho chip tab: macOS tô Codex/Pi/Auggie bằng
 * màu chữ chứ không phải màu thương hiệu, nên chip teal không được lan sang
 * logo trong hàng. Id không có ở đây thì lùi về màu tab.
 */
const LOGO_INK: Record<string, string> = {
  codex: "var(--text)",
  pi: "var(--text)",
  auggie: "var(--text)",
  elevenlabs: "var(--text)",
};

/** CSS light-dark() pair for the chip tint; undefined → fall back to secondary. */
export function providerTintCss(id: string): string | undefined {
  const pair = PROVIDER_TINT[id];
  if (!pair) return undefined;
  return pair[0] === pair[1] ? pair[0] : `light-dark(${pair[0]}, ${pair[1]})`;
}

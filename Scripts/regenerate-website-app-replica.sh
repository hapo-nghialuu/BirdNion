#!/bin/bash
# Regenerates the landing page's app-UI replica from the Linux UI sources.
#
# The "three answers" frames on website/ are HTML replicas of real BirdNion
# screens. Their CSS is not hand-written: every linux/src/styles.css rule that
# names one of the replica's classes is copied verbatim, in source order, with
# a shared `.app-replica` prefix. The prefix keeps the copied rules from leaking
# into the landing page while leaving their relative cascade unchanged, so the
# replica keeps looking like the app. The provider logos are copied the same way.
#
# Run after changing linux/src/styles.css or the logos below, then commit the
# regenerated files together with that change.
#
#   Scripts/regenerate-website-app-replica.sh          # rewrite the generated files
#   Scripts/regenerate-website-app-replica.sh --check  # verify only, non-zero if stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSS_OUT="$ROOT/website/styles/app-replica.css"
LOGO_DIR="$ROOT/website/assets/logos"
LOGOS=(claude codex grok)

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="$ROOT" OUT="$TMP/app-replica.css" python3 - <<'PY'
import os
import re
import subprocess
import textwrap

ROOT = os.environ["ROOT"]
SRC = "linux/src/styles.css"
CLASSES = """card provider-stack provider-header-card provider-head-row provider-head-text provider-name provider-meta
provider-logo-plate provider-logo-ink tab-logo-mono provider-body-card quota-summary quota-summary-label quota-summary-row
quota-summary-pct quota-summary-right quota-summary-meta provider-divider window-row window-head window-label window-pct
window-track window-fill window-foot window-subtitle mb-vis mb-vis-label mb-vis-switch mb-vis-knob provider-error
provider-error-actions sw-pill-btn panel-root panel-content panel-head panel-head-text panel-title panel-subtitle panel-close
quota-agenda-panel quota-agenda-panel-head quota-agenda-panel-icon quota-agenda-row quota-agenda-logo quota-agenda-identity
quota-agenda-agent quota-agenda-provider quota-agenda-percent quota-agenda-reset-line quota-agenda-window quota-agenda-reset
quota-agenda-meta quota-agenda-source quota-agenda-account quota-agenda-freshness quota-agenda-chevron quota-agenda-trust
container app-body""".split()
SKIP_PARTS = ('data-theme="dark"', "popover-capped")
# Element selectors for the page itself; a substring test would also drop .app-body.
PAGE_ELEMENT = re.compile(r"^(html|body)(?![\w-])")
# logos.ts PROVIDER_TINT / LOGO_INK, light theme.
LOGO_INK = {"claude": "#CC7C5E", "codex": "var(--text)", "grok": "#111827"}

css = re.sub(r"/\*.*?\*/", "", open(os.path.join(ROOT, SRC)).read(), flags=re.S)
commit = subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%h", "--", SRC],
                        capture_output=True, text=True, check=True).stdout.strip()


def top_level(text):
    i = 0
    while True:
        brace = text.find("{", i)
        if brace == -1:
            return
        depth, j = 1, brace + 1
        while depth:
            depth += {"{": 1, "}": -1}.get(text[j], 0)
            j += 1
        yield text[i:brace].strip(), text[brace + 1:j - 1].strip()
        i = j


def declarations(body):
    return "\n".join(f"  {d.strip()};" for d in body.split(";") if d.strip())


target = re.compile(r"\.(" + "|".join(map(re.escape, CLASSES)) + r")(?![\w-])")
tokens, rules = None, []
for selector, body in top_level(css):
    if selector.startswith("@"):
        # The replica has one fixed size; @media/@supports variants are not copied.
        continue
    if tokens is None and " ".join(selector.split()).startswith(':root, [data-theme="light"]'):
        tokens = body
        continue
    if not target.search(selector):
        continue
    kept = [f".app-replica {p.strip()}" for p in selector.split(",")
            if not any(s in p for s in SKIP_PARTS) and not PAGE_ELEMENT.match(p.strip())]
    if kept:
        rules.append(",\n".join(kept) + " {\n" + declarations(body) + "\n}")

if tokens is None:
    raise SystemExit(f"error: light-theme token block not found in {SRC}")

class_list = "\n".join(" * " + line for line in textwrap.wrap(" ".join(CLASSES), 88, break_on_hyphens=False))
logo_css = "\n\n".join(
    f".app-replica .replica-logo-{id} {{\n  -webkit-mask-image: url(\"../assets/logos/{id}.svg\");\n"
    f"  mask-image: url(\"../assets/logos/{id}.svg\");\n}}\n\n"
    f".app-replica .replica-logo-{id}.replica-tint {{ background-color: {ink}; }}"
    for id, ink in LOGO_INK.items())
rule_css = "\n\n".join(rules)

out = f"""/* Scoped replica of the BirdNion Linux UI for landing-page illustrations.
 * Generated from {SRC} at {commit} by Scripts/regenerate-website-app-replica.sh:
 * every rule whose selector names one of these classes is copied verbatim in source
 * order, each prefixed with `.app-replica` so it cannot leak into the landing page.
 * Dark-theme and popover-window rules are left out. Regenerate instead of editing.
 *
{class_list} */

.app-replica {{
{declarations(tokens)}
  color: var(--primary);
  text-align: left;
}}

.app-replica,
.app-replica * {{
  box-sizing: border-box;
}}

{rule_css}

/* logos.ts logoMark(): the brand SVG is a mask and background-color is the ink. */
.app-replica .replica-logo {{
  display: inline-block;
  -webkit-mask-size: contain;
  mask-size: contain;
  -webkit-mask-repeat: no-repeat;
  mask-repeat: no-repeat;
  -webkit-mask-position: center;
  mask-position: center;
}}

{logo_css}
"""
open(os.environ["OUT"], "w").write(out)
print(f"{len(rules)} rules from {SRC} at {commit}")
PY

if [ "$CHECK" -eq 1 ]; then
  stale=0
  if ! cmp -s "$TMP/app-replica.css" "$CSS_OUT"; then
    echo "stale: website/styles/app-replica.css" >&2
    stale=1
  fi
  for id in "${LOGOS[@]}"; do
    if ! cmp -s "$ROOT/linux/public/logos/$id.svg" "$LOGO_DIR/$id.svg"; then
      echo "stale: website/assets/logos/$id.svg" >&2
      stale=1
    fi
  done
  if [ "$stale" -ne 0 ]; then
    echo "Run Scripts/regenerate-website-app-replica.sh and commit the result." >&2
    exit 1
  fi
  echo "app replica is up to date"
  exit 0
fi

cp "$TMP/app-replica.css" "$CSS_OUT"
mkdir -p "$LOGO_DIR"
for id in "${LOGOS[@]}"; do
  cp "$ROOT/linux/public/logos/$id.svg" "$LOGO_DIR/$id.svg"
done
echo "wrote website/styles/app-replica.css and ${#LOGOS[@]} logos"

# BirdNion Landing Page Design Guidelines

> Status: approved design contract for the active Public Proof & Landing initiative. Vercel is the selected static hosting target at `https://birdnion.vercel.app/`. This document defines future behavior; it does not claim the roadmap P0–P5 features are implemented.

## Product outcome

The landing page helps an individual developer move from discovery to a truthful first quota/reset card in roughly five minutes:

```text
Landing → platform install → provider source → real self-test → First Live quota/reset
```

Primary audience: developers using multiple AI coding agents on macOS or Linux. Primary CTA: install. GitHub source and secondary platform downloads remain subordinate.

## Human decision lens

The page is judged first as a human decision journey, not a layout exercise. A first-time visitor should quickly answer:

- Is this for someone who uses the same coding tools I use?
- Will it prevent a quota surprise during real work?
- What must I connect, what will BirdNion read, and what happens when that connection fails?
- Can I verify the claim before trusting the install command?

Lead with the interrupted-work moment and the next useful answer. Provider count, implementation stack and internal terms such as `read path`, `truthful card` or `First Live receipt` remain supporting detail. Translate them into ordinary language before exposing technical precision.

## Visual direction: Friendly Instrument Desk

The website should feel like a cheerful desktop companion sitting beside BirdNion's instrument panel, not a generic AI SaaS template or a children's product.

- Warm paper background `#FBFAF7`, ink `#16150F`, secondary surface `#F3F1EA`, hairline `#E2DFD6`.
- One action accent `#1F4FD8`; semantic success `#1F7A4C`, warning `#8F5F12`, critical `#B4402F`.
- IBM Plex Sans for copy/UI and IBM Plex Mono for code/data. Self-host WOFF2, retain the OFL license, preload at most one critical font and verify Vietnamese glyphs.
- Desktop 12-column grid, max width 1184px. Hero uses 5 columns copy, 1 column space, 6 columns real product capture.
- Mobile is one column with 20px gutters. Narrative alternates 7/5 and 5/7 on larger screens.
- Use whitespace and hairlines before cards, shadows or rounded containers.
- The product UI is the hero. The mascot stays secondary and never covers the headline, primary action, or product evidence.
- `website/assets/birdnion-readme-bird-quota.png` is the approved transparent master derived from the original BirdNion mascot. The hero and README serve its 384px delivery derivative, `website/assets/birdnion-readme-bird-quota-384.png`; do not generate alternate characters without explicit approval.
- Header, footer, and favicon use the existing `docs/images/logo.png` mark.

## Product-truth and asset rules

- Every marketing claim maps to current README, source, release or native receipt.
- Screenshots that prove capability must come from a real build. Generated UI cannot represent the product.
- macOS and Linux claims require corresponding native captures; platform limitations stay visible.
- Demo/sample data must be labelled. Never expose token, email, full path, credential or live personal account data.
- Generated images may supply secondary line art or illustration after art direction is locked; never dashboards, testimonials, user avatars or adoption metrics.
- Use “No BirdNion backend or account”. Do not claim “nothing ever leaves your machine”: enabled connectors can contact their providers.
- Do not advertise Windows, notarization, auto-update, P0–P5 roadmap items or full provider parity without current evidence.

## Anti-slop rejection gate

Reject a design when any item appears without a product-specific rationale:

- centered generic hero with symmetric CTA stack;
- purple/blue gradient or gradient headline as the main aesthetic;
- three equal feature cards, repeated glass panels, glow or neon borders;
- floating provider-logo orbit, large stock 3D art or mascot larger than product proof;
- Inter, Roboto, Space Grotesk or multiple unrelated display fonts;
- fake metric, testimonial, company wall, dashboard or generated screenshot;
- every section using the same border/radius/shadow recipe;
- clichés such as “Elevate”, “Seamless”, “Unleash” or “next-generation”;
- perpetual/decorative motion, parallax, auto-carousel or motion without reduced mode;
- body text below AA contrast, touch targets below 44px or hero media without fixed dimensions.

## Motion, accessibility and performance

- Allow one hero entrance using `opacity` and `translateY(8px)` for 240–280ms. Hover/focus feedback is 150–180ms.
- Animate only `transform` and `opacity`; `prefers-reduced-motion` disables entrance and smooth scrolling.
- Provide skip link, semantic headings/landmarks, visible 2px focus ring, alt text/captions and keyboard-complete interactions.
- Color is never the only meaning. Normal text contrast is at least 4.5:1.
- Declare image dimensions/aspect ratios; lazy-load below-fold media. Hero responsive image target ≤240KB, other images ≤180KB each.
- Suggested project budgets: compressed HTML+CSS+JS ≤100KiB and initial transfer ≤500KiB, excluding app downloads.
- Field targets when data exists: LCP ≤2.5s, INP ≤200ms and CLS ≤0.1 at p75.

## Toolchain

Use the smallest stack that can produce evidence:

| Need | Tool or skill | Contract |
|---|---|---|
| Design intelligence | `hapo-ui-ux-pro-max` references | Its `.venv` CLI is hook-blocked; do not bypass the hook |
| Anti-slop/performance rules | `hapo-frontend-design` | Apply before implementation and at visual review |
| Asset/reference analysis | `hapo-ai-multimodal` | Critic only; cannot approve its own design |
| Reference capture and live inspection | Browser/Chrome DevTools | Record URL/date/rationale; do not copy assets/layouts |
| Responsive/visual regression | Playwright Test | Chromium/Firefox/WebKit × 320/768/1440 in a pinned environment |
| Automated accessibility | `@axe-core/playwright` | Zero violations is required but not full accessibility proof |
| Manual accessibility | Keyboard, 200%/400% zoom, Safari smoke, Accessibility Insights | Required alongside axe |
| Performance | Lighthouse locally; PageSpeed/CrUX after publish | Categories ≥90 in fixed runs; do not chase 100 |
| Final aesthetic approval | Independent human reviewer | Uses the reproducible scorecard below |
| Image generation | Optional secondary illustration | Never product UI, screenshot, testimonial or metric |

Do not add Storybook, Chromatic, Percy, CMS, token compiler, mandatory Figma/Penpot pipeline or JavaScript animation framework for the one-page MVP.

## Objective quality gate

- Full-page snapshots: Chromium/Firefox/WebKit × 320/768/1440; baseline updates require human review.
- No horizontal overflow at 320px; layout remains usable with JavaScript and animation disabled.
- Zero axe violations plus manual keyboard/focus/landmark/zoom/reduced-motion assessment.
- Lighthouse Performance, Accessibility, Best Practices and SEO each ≥90 in a fixed environment using median runs.
- Clean-install and every CTA/download command are verified immediately before launch.

## Independent anti-slop scorecard

Rate each category 1–5. Score = `Σ(weight × rating / 5)`. Pass requires ≥80/100, every rating ≥3 and zero fake claim. Ratings 2/4 interpolate between anchors.

| Category | Weight | Rating 1 | Rating 3 | Rating 5 |
|---|---:|---|---|---|
| Product truth | 25 | Unsupported/incorrect claims | Supported but authority/freshness gaps remain | Current evidence map; zero disguised assumption |
| Composition and rhythm | 20 | Generic symmetric template | Clear hierarchy with generic passages | Deliberate asymmetric rhythm throughout |
| Typography | 15 | Arbitrary/unreadable | Consistent, accessible Plex system | Glyph, measure, data and responsive type all proven |
| BirdNion identity | 15 | Interchangeable with another AI app | Uses product anchors correctly | Instrument Desk is unmistakable without decoration |
| Real screenshots | 10 | Generated/fake product UI | Real but provenance/platform gaps remain | Real two-platform proof with captions/sample labels |
| Specific copy | 10 | Clichés/fake metrics | Mostly concrete | Every promise is concise and evidence-linked |
| Restraint | 5 | Effects overwhelm product | Mostly restrained | Every visual/motion choice improves understanding/action |

The receipt records reviewer, date, category ratings, calculation, concrete findings and `PASS`/`NEEDS FIXES` verdict. Automated tools and AI critics cannot issue this final verdict.

## Private validation and launch gate

Validate with 5–10 developers using at least two AI coding agents. Internal hypotheses—not public benchmarks—are:

- clean install success ≥80%;
- median First Live ≤5 minutes;
- real self-test success within 10 minutes ≥70%;
- qualitative D7 repeat use ≥50%.

Do not public-launch while the same install, First Live or privacy blocker repeats without a recovery path. Launch sequence: GitHub soft launch → Show HN → tailored communities → Product Hunt after feedback is absorbed.

## Unresolved questions

- Whether a custom domain will replace `https://birdnion.vercel.app/` later.
- English-only or bilingual first release.
- Independent visual reviewer ownership.
- Whether the website-only bird mark should replace native app icons; keep the two identities separate until explicitly approved.
- Screenshot sample-data provenance.

---
version: alpha
name: Ankole
description: "Ankole's default visual identity: a Carbon-derived, engineered-not-decorated system of white and cool-gray surfaces, charcoal ink, IBM Plex type in Latin and Simplified Chinese, flat 0px geometry, and one assertive berry accent (#b31b5d) reserved for interaction and emphasis. Written for the artifacts Ankole agents actually produce: slide decks and PDF/DOCX documents first, plus the occasional single-page static HTML report."

colors:
  primary: "#b31b5d"
  primary-hover: "#8f1248"
  primary-active: "#681036"
  primary-tint: "#ffd6e8"
  accent-on-dark: "#f76aa7"
  text-on-color: "#ffffff"
  canvas: "#ffffff"
  layer-01: "#f4f4f4"
  layer-02: "#ffffff"
  layer-03: "#e0e0e0"
  layer-hover: "#e8e8e8"
  field: "#f4f4f4"
  text-primary: "#161616"
  text-secondary: "#525252"
  text-placeholder: "#8d8d8d"
  text-disabled: "#a8a8a8"
  border-subtle: "#e0e0e0"
  border-strong: "#8d8d8d"
  interactive-disabled: "#c6c6c6"
  neutral-strong: "#393939"
  inverse-canvas: "#161616"
  inverse-layer: "#262626"
  inverse-text: "#f4f4f4"
  inverse-text-secondary: "#c6c6c6"
  error: "#da1e28"
  warning: "#f1c21b"
  success: "#24a148"
  info: "#0f62fe"
  chart-1: "#b31b5d"
  chart-2: "#009d9a"
  chart-3: "#0f62fe"
  chart-4: "#f1c21b"
  chart-5: "#a56eff"
  chart-up: "#b31b5d"
  chart-down: "#24a148"

typography:
  display-01:
    fontFamily: IBM Plex Sans
    fontSize: 42px
    fontWeight: 300
    lineHeight: 1.19
    letterSpacing: 0px
  heading-05:
    fontFamily: IBM Plex Sans
    fontSize: 32px
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: 0px
  heading-04:
    fontFamily: IBM Plex Sans
    fontSize: 28px
    fontWeight: 400
    lineHeight: 1.29
    letterSpacing: 0px
  heading-03:
    fontFamily: IBM Plex Sans
    fontSize: 20px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0px
  heading-02:
    fontFamily: IBM Plex Sans
    fontSize: 16px
    fontWeight: 600
    lineHeight: 1.5
    letterSpacing: 0px
  heading-01:
    fontFamily: IBM Plex Sans
    fontSize: 14px
    fontWeight: 600
    lineHeight: 1.29
    letterSpacing: 0.16px
  body-02:
    fontFamily: IBM Plex Sans
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0px
  body-01:
    fontFamily: IBM Plex Sans
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: 0.16px
  body-compact-01:
    fontFamily: IBM Plex Sans
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.29
    letterSpacing: 0.16px
  label-01:
    fontFamily: IBM Plex Sans
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: 0.32px
  code-02:
    fontFamily: IBM Plex Mono
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: 0.32px
  code-01:
    fontFamily: IBM Plex Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: 0.32px
  quotation-01:
    fontFamily: ChillJinshuSong
    fontSize: 20px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0px

rounded:
  none: 0px
  full: 9999px

spacing:
  "01": 2px
  "02": 4px
  "03": 8px
  "04": 12px
  "05": 16px
  "06": 24px
  "07": 32px
  "08": 40px
  "09": 48px
  "10": 64px
  "11": 80px
  "12": 96px
  "13": 160px

components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.text-on-color}"
    typography: "{typography.body-compact-01}"
    rounded: "{rounded.none}"
    padding: 12px 16px
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
    textColor: "{colors.text-on-color}"
  link:
    textColor: "{colors.primary}"
  card:
    backgroundColor: "{colors.layer-01}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body-01}"
    rounded: "{rounded.none}"
    padding: 24px
  tag-brand:
    backgroundColor: "{colors.primary-tint}"
    textColor: "#8f1248"
    typography: "{typography.label-01}"
    rounded: "{rounded.none}"
    padding: 2px 8px
  table-header:
    backgroundColor: "{colors.layer-03}"
    textColor: "{colors.text-primary}"
    typography: "{typography.heading-01}"
    rounded: "{rounded.none}"
    padding: 12px 16px
  callout:
    backgroundColor: "{colors.layer-01}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body-01}"
    rounded: "{rounded.none}"
    padding: 16px
  stat-value:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-primary}"
    typography: "{typography.display-01}"
  stat-label:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-secondary}"
    typography: "{typography.label-01}"
  pull-quote:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-primary}"
    typography: "{typography.quotation-01}"
    rounded: "{rounded.none}"
    padding: 24px
  figure-caption:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-secondary}"
    typography: "{typography.label-01}"
  page-footer:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-secondary}"
    typography: "{typography.label-01}"
  code-block:
    backgroundColor: "{colors.layer-01}"
    textColor: "{colors.text-primary}"
    typography: "{typography.code-02}"
    rounded: "{rounded.none}"
    padding: 16px
  inverse-band:
    backgroundColor: "{colors.inverse-canvas}"
    textColor: "{colors.inverse-text}"
    typography: "{typography.body-01}"
    rounded: "{rounded.none}"
    padding: 48px
---

# Ankole visual identity

This is the installation-wide default visual identity for artifacts produced by Ankole agents. Frontmatter tokens are the normative values; the prose explains how to apply them. The primary media are slide decks and documents (PPTX, PDF, DOCX); the web medium is a single static HTML report or topic page, often with embedded interactive charts. Every artifact ships as a finished, self-contained piece made for reading; interaction, where present, exists to deepen the content.

## Overview

Ankole is an Agent Operating System for long-running digital work. What its agents hand to people is mostly documents in the broad sense — decks, reports, memos, one-page analyses — so this system is tuned for reading: dense with real information, calm under continuous use, and legible months later. The visual language derives from IBM's Carbon Design System and keeps Carbon's engineering discipline — role-based color tokens, a 4px/8px spatial grid, IBM Plex typography, flat square geometry, hierarchy from surface change and hairlines rather than decoration — while replacing IBM Blue with a single berry accent, `{colors.primary}` (#b31b5d).

The personality is precise and quietly confident. Surfaces stay white and cool gray; ink is charcoal, never pure black; the berry accent appears only where the reader should look first or can act. Simplified Chinese and English are first-class together, sharing one type system.

### Design principles

Design here has one task: use the fewest, clearest formal differences that let a reader naturally grasp how pieces of information relate, what the current state is, and what they can do next. Four tests follow, and they decide every case the tokens and rules below do not cover:

- **Every visible difference represents a meaningful difference.** Style variation is information: if two elements look different, readers assume they mean different things. Never vary size, weight, color, or spacing for texture or decoration.
- **Every meaningful difference is perceptible.** When two things differ in role, state, or importance, the formal difference must be decisive at a glance — a full step of the type scale, a full grade of a color scale, a different layer — not a subtlety the reader must hunt for.
- **Consistency by default, contrast by intent.** Solve the same problem the same way everywhere, and spend contrast deliberately on the one thing the reader must see first. Half-hearted contrast reads as a mistake rather than emphasis.
- **Minimum sufficient form.** Nothing essential missing, nothing unnecessary competing for attention. Add a border, color, icon, or ornament only when its absence would lose meaning; when in doubt, remove.

Structure comes before decoration: group related items and align them to shared edges so relationships are visible without boxes; show state explicitly instead of implying it; make the next available action visually unambiguous. When two treatments pass all four tests, choose the quieter one — less color, less weight, less motion.

## Colors

Pick colors by role, not by hex. Every value below has a role name; artifacts should reference roles so light and dark renderings stay consistent.

### Brand scale

The berry scale is Ankole's only brand hue. Grade 60 is the anchor and the sole accent on light surfaces.

| Grade | Hex | Role |
|---|---|---|
| brand-10 | #fff0f6 | Faint brand wash (highlighted table row, rare) |
| brand-20 | #ffd6e8 | `{colors.primary-tint}` — brand tag backgrounds |
| brand-30 | #ffadd1 | Decorative data accents only |
| brand-40 | #f76aa7 | `{colors.accent-on-dark}` — links and accents on dark |
| brand-50 | #d83d82 | Hover state on dark; dark-theme chart accent |
| brand-60 | #b31b5d | `{colors.primary}` — the accent |
| brand-70 | #8f1248 | `{colors.primary-hover}`; text on brand-20 tags |
| brand-80 | #681036 | `{colors.primary-active}` |
| brand-90 | #3f0b22 | Deep brand fields in editorial art, rare |
| brand-100 | #240512 | Near-black brand, rare |

Use the accent scarcely: the keyline on a cover or section title, links, the first chart series, the one number or phrase a slide exists to deliver, and primary actions in interactive reports. Never use berry for headings at large, body text, icon tinting at rest, or background washes. Neutrals are the Carbon gray family (gray-10 #f4f4f4 through gray-100 #161616); do not tint grays with the brand hue.

### Surfaces and layering

Depth comes from alternating surfaces, not shadows. The page sits on `{colors.canvas}`; the first raised zone (cards, callouts, code blocks) uses `{colors.layer-01}`; content nested on a layer returns to white `{colors.layer-02}`; a third step `{colors.layer-03}` marks table headers. Hairlines use `{colors.border-subtle}`; stronger rules and the rare field outline use `{colors.border-strong}`.

### Text

`{colors.text-primary}` (charcoal #161616) carries headings and body. `{colors.text-secondary}` carries labels, captions, metadata, and footers. `{colors.text-placeholder}` and `{colors.text-disabled}` exist for the rare interactive surface. Text on filled controls and dark bands is `{colors.text-on-color}` or `{colors.inverse-text}`. Text selection inverts to `{colors.primary}` behind `{colors.text-on-color}`.

### Semantic

Status colors are Carbon's fixed grades and never substitute for the brand: `{colors.error}` (red-60), `{colors.warning}` (yellow-30), `{colors.success}` (green-50), `{colors.info}` (blue-60). Warning yellow always takes charcoal text and iconography — never white.

### Dark theme

Documents and slides render on the light theme by default; the dark mapping serves screens that ask for it (a dark HTML report, dark slide covers via `inverse-band`). Roles keep their names; values remap:

| Role | Light | Dark |
|---|---|---|
| canvas | #ffffff | #161616 |
| layer-01 / layer-02 / layer-03 | #f4f4f4 / #ffffff / #e0e0e0 | #262626 / #393939 / #525252 |
| text-primary / text-secondary | #161616 / #525252 | #f4f4f4 / #c6c6c6 |
| border-subtle / border-strong | #e0e0e0 / #8d8d8d | #393939 / #8d8d8d |
| accent fill | #b31b5d | #b31b5d (unchanged) |
| hover / active | #8f1248 / #681036 | #d83d82 / #f76aa7 (flips lighter) |
| error / info / success | #da1e28 / #0f62fe / #24a148 | #fa4d56 / #78a9ff / #42be65 |

Berry-60 stays the fill color for accents in both themes, but as small text on dark it fails contrast — use `{colors.accent-on-dark}` (brand-40) or brand-50 for links and text accents on dark surfaces.

### Accessibility

Meet WCAG AA: 4.5:1 for normal text, 3:1 for large text (24px+) and essential graphic boundaries. The shipped pairs pass on light surfaces: berry-60 on white is 6.5:1, charcoal on layer-01 is 15+:1, white on berry-60 and red-60 clears AA. Verify contrast again whenever you stray from tokened pairs.

## Typography

The Agent Computer preinstalls exactly three families, each one TrueType and each
one covering Latin and Simplified Chinese. Artifacts use these local fonts and
never load webfonts:

- **IBM Plex Sans SC** — all UI and document text. The worker maps generic sans and `IBM Plex Sans` requests to it, so either name works; the web console uses its variable CN build for `zh`.
- **IBMPlexMonoSCHalf** — code, identifiers, logs, and technical data. It merges IBM Plex Mono with Simplified Chinese at half-width metrics. The worker maps `IBM Plex Mono` to it, but a tool that matches family names directly, such as Typst, needs the exact name `IBMPlexMonoSCHalf`.
- **ChillJinshuSong（寒蝉锦书宋）** — the serif voice for pull quotes, covers, and long-form editorial or print work. Its real family name is `寒蝉锦书宋`; the worker maps the ASCII name `ChillJinshuSong` to it for CSS, and Typst needs the Chinese name.
- **Fluent Emoji Color** — emoji in every medium. It sits behind all three text families, so an emoji renders in color without naming the family.

Fallback stacks: `'IBM Plex Sans SC', 'IBM Plex Sans', 'Helvetica Neue', Arial, sans-serif` · `'IBM Plex Mono', 'IBMPlexMonoSCHalf', SFMono-Regular, Consolas, monospace` · `'ChillJinshuSong', '寒蝉锦书宋', Georgia, 'Times New Roman', serif`.

### Weight discipline

Sans and mono carry 300 Light, 400 Regular, 500 Medium, 600 SemiBold, and 700 Bold. Weight 300 is reserved for display sizes (42px and up) — the light large headline is the brand's typographic signature. Weight 400 is the default for everything; 600 marks headings and emphasis. Avoid 700: bold display type reads as a different, louder brand. The serif has no SemiBold, so a 600 request in serif text resolves to Bold; set serif pull quotes and covers at 400 or 500 and let sans carry the 600 headings. None of the three families ships italics, so express emphasis with weight or color rather than synthetic italics.

### Type scale

| Token | Face | Size / Weight | Use |
|---|---|---|---|
| `{typography.display-01}` | Sans | 42 / 300 | Cover titles, hero numbers |
| `{typography.heading-05}` | Sans | 32 / 400 | Slide titles, document h1 |
| `{typography.heading-04}` | Sans | 28 / 400 | Document h2, report section titles |
| `{typography.heading-03}` | Sans | 20 / 400 | Document h3, card titles, slide body lead |
| `{typography.heading-02}` | Sans | 16 / 600 | Document h4, subsection headings |
| `{typography.heading-01}` | Sans | 14 / 600 | Table headers, compact headings |
| `{typography.body-02}` | Sans | 16 / 400 | Long-form body |
| `{typography.body-01}` | Sans | 14 / 400 | Default product body, table cells |
| `{typography.body-compact-01}` | Sans | 14 / 400 (lh 1.29) | Buttons, dense rows, tooltips |
| `{typography.label-01}` | Sans | 12 / 400 | Labels, captions, footers, axis text |
| `{typography.code-02}` | Mono | 14 / 400 | Code blocks |
| `{typography.code-01}` | Mono | 12 / 400 | Inline code, log lines |
| `{typography.quotation-01}` | Serif | 20 / 400 | Pull quotes, editorial openers |

The 0.16px letter-spacing on 14px text and 0.32px on 12px text are Carbon precision details — keep them; sizes 16px and above track at 0. Keep `liga` and `kern` on. Use tabular figures (`font-variant-numeric: tabular-nums`) for any column of numbers, metrics, or timestamps.

Use sentence case everywhere — headings, labels, buttons, tabs. No all-caps tracked eyebrows; `{typography.label-01}` in `{colors.text-secondary}` does that job. Hold Latin body lines to roughly 40–75 characters; long-form Chinese body may relax line-height to 1.6–1.7.

## Layout

Space on an 8px grid with 2px and 4px micro-steps. The scale is Carbon's:

| Token | Value | Typical use |
|---|---|---|
| `{spacing.01}`–`{spacing.02}` | 2–4px | Icon-to-badge gaps, hairline offsets |
| `{spacing.03}` | 8px | Icon-to-label, tag gaps, caption-to-figure |
| `{spacing.04}`–`{spacing.05}` | 12–16px | Cell padding, gaps inside cards |
| `{spacing.06}`–`{spacing.07}` | 24–32px | Card padding, gaps between blocks, list rhythm |
| `{spacing.08}`–`{spacing.09}` | 40–48px | Section breaks in documents, slide content gaps |
| `{spacing.10}`–`{spacing.13}` | 64–160px | Page and slide margins, editorial section rhythm |

Ankole artifacts are dense by design, separated by surface change and modest spacing rather than large air — but margins are not negotiable: pages and slides keep generous outer margins (`{spacing.10}`+) so density lives inside a calm frame. Build every page and slide on a small column grid (two or three columns cover almost all layouts), align content to shared edges, and let one measure of body text (40–75 Latin characters) set the column width. Medium-specific page geometry lives in the Slides, Documents & PDF, and Static HTML reports sections below.

## Elevation & Depth

The system is flat. Hierarchy comes from the layering model and 1px hairlines, not shadows. Print media use no shadows at all — cards and callouts rely on surface change and hairlines. On screens, only floating ephemera cast shadows: chart tooltips use `0 1px 2px rgb(0 0 0 / 0.12)`; the rare dialog uses `0 2px 6px rgb(0 0 0 / 0.18)`. No decorative shadows, gradients, glassmorphism, or glow. Keyboard focus in interactive reports is a 2px `{colors.primary}` ring — never remove it.

## Shapes

Corner radius is 0 on everything: cards, callouts, tags, tables, images, chart bars, and buttons. `{rounded.full}` exists only for avatars and status dots. Accent strokes carry meaning in one family: a 2px `{colors.primary}` keyline under a cover or section title, a 3px semantic left border on callouts, and a 2px berry underline for the active tab or table-of-contents entry in interactive reports. Iconography is the Carbon icon library at 16/20/24/32, monochrome (`{colors.text-primary}` or `{colors.text-secondary}`), with color only for status.

## Components

The component vocabulary is document-first: the atoms below are what reports, decks, and pages are made of. When a piece genuinely calls for an embedded control, fields sit on `{colors.field}` with a 1px `{colors.border-strong}` outline and the 2px `{colors.primary}` focus ring.

**Actions and links.** Links use `link` — berry text, underlined on hover in `{colors.primary-hover}`; on dark surfaces links use `{colors.accent-on-dark}`. A real action in an interactive report (download, expand all) is `button-primary`: square, 12px × 16px padding, `{typography.body-compact-01}` label, one per view; a parallel secondary action fills with `{colors.neutral-strong}` charcoal instead. Disabled controls fill with `{colors.interactive-disabled}` and label with `{colors.text-disabled}`.

**Cards and tiles.** Cards are `{colors.layer-01}` with 24px padding and no border; on a layer, tiles return to `{colors.layer-02}` with a `{colors.border-subtle}` hairline. Titles use `{typography.heading-03}`, metadata `{typography.label-01}`.

**Stats.** A KPI block pairs `stat-value` (a display-01 number, tabular figures) with `stat-label` above or below it; a delta line takes `{colors.chart-up}`/`{colors.chart-down}`. Three or four stat blocks in one aligned row summarize a report or open a deck section.

**Tables.** Headers use `table-header` (`{colors.layer-03}`, `{typography.heading-01}`); rows sit on canvas separated by `{colors.border-subtle}` hairlines; numeric columns right-align with tabular figures; zebra striping (`{colors.layer-01}`) only for wide tables. A highlighted row may take a brand-10 wash.

**Callouts.** Notes, warnings, and takeaways use `callout` on `{colors.layer-01}` with a 3px left border and icon in the semantic color — or `{colors.primary}` for a neutral key-takeaway — and text in `{colors.text-primary}`. Never fill a callout body with a saturated color.

**Tags.** Square, `{typography.label-01}`, 2px × 8px padding, built as grade-20 background with grade-70 text of one family — brand (`tag-brand`), gray for neutral states, or a semantic family for status.

**Quotes and captions.** Pull quotes use `pull-quote` in the serif `{typography.quotation-01}` with a 2px berry keyline on the left. Every figure and table carries a `figure-caption` below it — numbered ("Figure 3 · …") when the document cross-references them. Page and slide footers use `page-footer`.

**Code.** Code blocks use `code-block` on `{colors.layer-01}` in `{typography.code-02}`; inline code uses `{typography.code-01}` on a faint `{colors.layer-01}` chip. Dark artifacts may invert code blocks to `{colors.inverse-layer}`.

**Inverse band.** Full-bleed charcoal panels (`inverse-band`) serve covers, section dividers, and closing slides — the only dark surfaces in a light artifact.

## Do's and Don'ts

- Do ship every artifact as a finished, self-contained piece for reading: each element on the page earns its place by serving the content.
- Do reserve berry (#b31b5d) for the reader's entry point: cover keyline, links, chart series 1, the one number that matters, primary action.
- Do keep every corner at 0px; `{rounded.full}` is for avatars and status dots only.
- Do build hierarchy with layers and hairlines; add a shadow only to floating ephemera on screens, never in print.
- Do use sentence case in every heading, label, and button.
- Do keep display type at weight 300 and never bold it; body emphasis is 600.
- Do reference role tokens and verify WCAG AA (4.5:1) when improvising pairs.
- Don't use pure black #000000 anywhere; ink is charcoal #161616.
- Don't introduce a second accent hue, tint neutrals with the brand, or use berry for washes and headings.
- Don't set berry-60 small text on dark surfaces; use brand-40/50 there.
- Don't put white text on warning yellow; it takes charcoal.
- Don't use synthetic italics in Chinese text or all-caps tracked labels anywhere.
- Don't load webfonts in artifacts; the standard families are installed locally.

## Charts & data

Categorical series take `{colors.chart-1}` through `{colors.chart-5}` in order; a single-series chart uses `{colors.chart-1}` alone. Beyond five series, group the tail into "other" rather than inventing hues. On dark, shift to brand-50 #d83d82, teal-40 #08bdba, blue-40 #78a9ff, yellow-30, purple-40 #be95ff.

Directional metrics follow the Chinese market convention (红涨绿跌): `{colors.chart-up}` (berry) marks gains and `{colors.chart-down}` (green) marks declines. This is a deliberate installation default — do not "correct" it to green-up/red-down, and do not reuse `{colors.error}`/`{colors.success}` for deltas.

Keep charts flat: no 3D, gradients, or drop shadows. Gridlines are `{colors.border-subtle}`; axes and captions use `{typography.label-01}` in `{colors.text-secondary}`; lines are 2px; bars are square-cornered. Prefer direct series labels over legends when there are three or fewer series. Series must stay distinguishable in grayscale print — vary dash or marker when hue alone would carry the difference. Interactive charts follow the same palette and rules; tooltips are `{typography.body-compact-01}` on `{colors.layer-02}` with a hairline and the small shadow.

## Slides

Design decks at 1280×720 (16:9). Outer margins hold at `{spacing.10}` 64px; nothing but full-bleed images and the inverse band crosses them. One idea per slide: the title states the takeaway as a sentence in `{typography.heading-05}` ("Latency dropped 40% after the cache change", not "Results"), and the body proves it with one chart, one table, or three to five aligned points.

Keep each slide to at most two type sizes plus one emphasis. Body text on slides never drops below 16px; bullets default to `{typography.heading-03}` size at weight 400. Footers carry deck title and page number in `page-footer` at the margin line. Berry appears at most once per slide — the keyline under the title, the highlighted series, or the one number set in `stat-value`.

Covers and section dividers use `inverse-band` or clean canvas: title in `{typography.display-01}` (Chinese covers may use the serif), a 2px berry keyline, metadata in `{typography.label-01}`. Tables on slides hold to roughly six rows — beyond that, chart it or move it to the appendix.

## Documents & PDF

Default to A4 with 25mm margins. Long-form body is `{typography.body-02}` on screen and 10.5–11pt in print, line-height 1.5 (Chinese 1.6–1.7). Map heading levels h1→`{typography.heading-05}`, h2→`{typography.heading-04}`, h3→`{typography.heading-03}`, h4→`{typography.heading-02}`; give headings `{spacing.08}` above and `{spacing.04}` below so sections breathe without dividers.

Covers carry the title in `{typography.display-01}` with the berry keyline and metadata in `{typography.label-01}`; documents longer than about eight pages get a table of contents. Running footers show document title and page number in `page-footer` above a hairline. Tables, callouts, stats, quotes, and captions follow the Components rules; figures are numbered when the text refers to them. Print stays shadow-free and must survive grayscale — check charts against the grayscale rule before shipping.

## Static HTML reports

The web artifact is one static page — a report or topic page that reads completely from top to bottom, even with JavaScript disabled. Interactivity is progressive enhancement that deepens the same content: explorable charts, anchor navigation, small filters.

Set one centered column at 720–880px (a 40–75 character measure for `{typography.body-02}`), sections separated by `{spacing.10}`–`{spacing.12}` and an optional hairline. The masthead is text: report title in `{typography.heading-05}` or `{typography.display-01}`, date and author in `{typography.label-01}`, hairline below. A light table of contents with anchor links may sit at the top (or as a side rail on wide screens), marking the active entry with the 2px berry rule.

Use the local font stacks (no webfont requests), default to the light theme, and treat `prefers-color-scheme: dark` support as optional via the dark mapping. Keep interaction minimal and legible: links, anchor jumps, chart tooltips, and a small row of square filter tags where filtering genuinely serves the reader. The page should print cleanly to PDF through the Documents & PDF rules, because reports often end their life as one.

## Other media

Spreadsheets style header rows like `table-header`, freeze them, and set numeric columns in tabular figures. HTML email falls back to the system font stacks with inline styles and no webfonts. Terminal output uses semantic colors only. Chat cards and other constrained surfaces drop decoration rather than approximating it with a different style — when a medium cannot honor a rule, omit the ornament, keep the hierarchy.

## Voice & content

Write UI text and artifact copy the way the system looks: plain, precise, calm. Lead buttons and section titles with the point ("Create agent", "Latency dropped 40%"); state errors as what happened plus the next step; avoid exclamation marks and marketing adjectives. In Chinese copy use full-width punctuation, half-width digits, and a space between CJK and Latin or numerals（例如 "部署 3 个 Agent"）. Dates prefer ISO order (2026-07-15). Localize whole sentences; never mix languages mid-sentence in labels.


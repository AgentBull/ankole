---
name: visualization
description: "Design and produce data visualizations, Base chart views, financial K-line charts, network graphs, AntV infographics, and Mermaid diagrams across Pod pages, Applets, Chat, PDF, PPTX, DOCX, and channel deliveries."
default_enabled: true
ankole-runtime: any
category: productivity
tags: [Visualization, Charts, K-Line, Infographic, Mermaid, Graph]
---

# Visualization

This Skill owns how Ankole selects a visual grammar, applies palette and directional conventions, embeds live charts in Pod pages and Applets, writes `<mermaid>` and `<infographic>` diagram blocks, and exports publication-grade SVG or PNG figures with `ankole-viz`.

Read `/drive/DESIGN.md` (or the workspace design contract) first when styling standalone deliverables. Read only the reference file under `references/` that matches the visual grammar you need:

- `references/statistical-g2.md` — categorical, temporal, distribution, dual-axis, hierarchical, and flow charts (`AnkoleChart`, Base `chart` view, `ankole-viz chart`)
- `references/financial-kline.md` — OHLCV candlesticks, intraday baselines, synchronized volume/MACD/RSI sub-panes, trade markers, and yield curves (`AnkoleFinancialChart`, `recordsToFinancialSeries`, `ankole-viz kline`)
- `references/infographic-dsl.md` — structured narrative diagrams, SWOT, timelines, roadmaps, and comparison trees (`<infographic>`, `AnkoleInfographic`, `ankole-viz infographic`)
- `references/graph-g6.md` — entity-relationship networks, hierarchies, radial neighborhoods, and combo clusters (`AnkoleGraph`, `ankole-viz graph`)
- `references/mermaid.md` — procedural flowcharts, sequence diagrams, state machines, and ER diagrams (`<mermaid>`, `ankole-viz mermaid`)
- `references/chat-ui-block.md` — interactive `ui` blocks inside a native chat reply: tabs, sortable tables, headline numbers, inline charts, segmented switches, and follow-up buttons (Chat ` ```ui `)

## Choose the right grammar and surface

Match the cognitive question to one grammar first, then pick the delivery surface:

| Cognitive question | Visual grammar | Pod / Chat / Knowledge surface | Offline file export (`background_job`) |
| --- | --- | --- | --- |
| Headline KPI and delta | Stat & sparkline | Base `chart` (`stat`), Applet `AnkoleStatCard` + `AnkoleSparkline` | `ankole-viz chart` or native table/card |
| Category comparison, trend, share, correlation, distribution | Statistical (AntV G2 v5) | Single-table: Base `chart` view + Doc `<embed>`. Multi-table or custom: Applet `AnkoleChart` | `ankole-viz chart --spec ... --data ... -o fig.svg` |
| OHLCV price action, session gaps, indicators, yield curve | Financial (Lightweight Charts v5) | Applet `AnkoleFinancialChart` | `ankole-viz kline --spec ... --data ... -o kline.png` |
| Multi-hop topology, clusters, hierarchy | Network graph (AntV G6 v5) | Applet `AnkoleGraph` | `ankole-viz graph --spec ... --data ... -o graph.svg` |
| Stages, SWOT, pros/cons, executive takeaways | Narrative infographic (`@antv/infographic`) | Doc `<infographic>` (` ```infographic `), Chat ` ```infographic `, Applet `AnkoleInfographic` | `ankole-viz infographic --input ... -o info.svg` |
| Branching control flow, RPC sequence, state transitions, schema ER | Procedural diagram (Mermaid via Pele) | Doc `<mermaid>`, Knowledge ` ```mermaid `, Chat ` ```mermaid ` | `ankole-viz mermaid --input ... -o flow.svg` |
| A few views of one answer that the reader switches, sorts, or compares | Interactive `ui` block | Chat ` ```ui ` when the turn context says `ui_blocks: interactive` | Markdown table or `ankole-viz chart` |

Never convert an explicit flow, sequence, state machine, or ER diagram into ASCII box art (`+---+`, `|-->|`), and never fabricate raw SVG coordinates by hand when one of these grammars expresses the structure directly.

## Palette and directional rules

1. **Categorical series & 1D focus**: Honor explicit `:select` field option colors first; otherwise assign `{colors.chart-1}` through `{colors.chart-5}` (Cobalt, Celadon, Ochre, Berry, Mulberry — Okabe–Ito CUD separable across protanopia, deuteranopia, and tritanopia) in global rank order. For 1D `column` or `bar` rankings without a second `series` dimension or explicit option colors, keep all regular bars in uniform `{colors.chart-1}` so length carries magnitude without decorative rainbow hues, while coloring `"Other"` (`--chart-other`) and unassigned `null` / `"Empty"` (`--chart-empty`) in distinct neutral grays. Never merge missing values into `"Other"`, and never treat `0` or `false` as empty.
2. **Continuous & diverging scales**: Sequential heatmaps use monotonic luminance ramps matched to figure-ground polarity (dark-is-more on light paper, light-is-more on dark graphite). Mixed negative-and-positive heatmaps automatically switch to a zero-anchored symmetric diverging scale (`--chart-down` ↔ neutral surface `0` ↔ `--chart-up`). Waterfall charts render increments in `--chart-up`, decrements in `--chart-down`, and summary totals in neutral slate `--chart-total`.
3. **Directional movement (`intl` default, `cn` for Mainland China A-shares only)**:
   - Default across all business metrics, global equities, crypto, FX, commodities, and macro series: **green-up / red-down** (`marketConvention: "intl"`, `{colors.chart-up}` for `+`, `{colors.chart-down}` for `-`).
   - Swap to **red-up / green-down** (`marketConvention: "cn"`) **only** when displaying Mainland China A-share (`A股`) equities or A-share indices.
   - Pair directional colors with explicit `+`/`-` or `▲`/`▼` glyphs and `tabular-nums` so sign survives grayscale print and color-vision differences. Keep `chart-up` and `chart-down` separate from operational `success` and `error` tokens.

## Live Pod views vs. Applets

- **Single-table declarative charts**: Create a shared `chart` view on the Base table with `ankole-pod base.create_view` (`type: "chart"`, `config: { chart: { chart_type, query, encoding?, display? } }`), then embed `<embed ref="<base-page-id>" table="<table-id>" view="<view-id>" />` on its own line in the `:doc` Page—or pass an inline JSON `ViewConfig` in `view` when the chart configuration belongs exclusively to one report document.
- **Multi-table joins, interactive financial terminals, or custom simulations**: Build a React Applet with `ankole-pod applet init|build|publish`, importing `AnkoleStatCard`, `AnkoleSparkline`, `AnkoleChart`, `AnkoleFinancialChart`, `AnkoleGraph`, or `AnkoleInfographic` from the root `@ankole/uikit` package and `recordsToFinancialSeries`, `densifyTimeBuckets`, or `formatMetricValue` from `@ankole/applet-sdk`.

## Offline export (`ankole-viz`) and channel rules

Run `ankole-viz --help` inside a Background Agent Job when generating image assets for PDF, PPTX, DOCX, HTML reports, or chat attachments:

- Pass tabular inputs directly from disk via `--data <path.csv|tsv|json|jsonl>` instead of pasting large datasets into inline JSON arguments.
- Validate Mermaid or Infographic syntax cheaply without launching a browser via `ankole-viz validate --kind mermaid|infographic --input <file>`.
- **PDF and print safety**: Typst (`resvg`) and WeasyPrint require Print-Safe SVGs (no `<foreignObject>`, no `var(--...)` CSS variables, no external URLs). `ankole-viz` automatically resolves theme tokens and, when `--pdf-safe` is active or a template emits `<foreignObject>`, rasterizes at `1920px` width (`300 DPI` on an A4 text block) to lossless `.png` and reports the output path in JSON stdout. `kline` always exports lossless `.png` with attribution intact.
- **Feishu / Lark and messaging channels**: Deliver `.png` (`--dpr 2`) for inline chat viewing so mobile and desktop clients render an immediate image preview; attach `.svg` only when the user asks for editable vector source files.

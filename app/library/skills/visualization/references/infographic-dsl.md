# Narrative Infographics (`@antv/infographic`)

Use `<infographic>` (` ```infographic ` in Pod `:doc` pages and Chat, `AnkoleInfographic` in Applets, or `ankole-viz infographic` for PDF/PPTX/DOCX exports) when turning structured qualitative points—roadmaps, phase sequences, SWOT matrices, pros/cons comparisons, or hierarchy summaries—into clean vector diagrams.

> [!IMPORTANT]
> `:knowledge` pages do not render `<infographic>` blocks (` ```infographic ` stays a plain code block in `:knowledge`). In `:knowledge` pages, use ` ```mermaid ` or a Markdown table instead.

## DSL structure (2-space indentation)

Every infographic starts with `infographic <template-name>` on line 1, followed by a `data` block indented with **2 spaces per level**:

```text
infographic sequence-timeline-simple
data
  title Q4 launch milestones
  desc Three-phase rollout across engineering and operations
  sequences
    - label Phase 1 · Core schema
      desc Freeze Pod query and migration contracts
      icon database
    - label Phase 2 · Web workspace
      desc Ship Base chart view and inline embeds
      icon chart
    - label Phase 3 · Worker export
      desc Enable ankole-viz PDF and slide assets
      icon rocket
```

## Built-in starter templates & root collection keys

Match the template family to its root data key:

| Template | Root collection key | Best for |
| --- | --- | --- |
| `list-row-simple-horizontal-arrow` | `lists` | 3–6 parallel pillars, feature cards, or sequential steps |
| `sequence-timeline-simple` | `sequences` | Chronological milestones, release roadmaps, phase plans |
| `compare-swot` | `compares` (4 groups with `children`) | SWOT analysis (Strengths, Weaknesses, Opportunities, Threats) |
| `compare-hierarchy-left-right-circle-node-pill-badge` | `compares` (2 groups with `children`) | Side-by-side pros/cons, before/after, or option A vs. option B |

Example two-sided comparison (`compares`):

```text
infographic compare-hierarchy-left-right-circle-node-pill-badge
data
  title Shared view vs. inline embed
  compares
    - label Shared Base view
      children
        - label Managed under Base schema permissions
        - label Updates every embedding document at once
    - label Inline document config
      children
        - label Scoped to a single report page
        - label Saved with document edit permissions
```

## Offline icons & PDF print safety

- Ankole registers a deterministic offline geometric `<symbol>` loader for icons (`check`, `star`, `arrow`, `user`, `chart`, `clock`, `shield`, `rocket`, `bulb`, `warning`, `code`, `database`, `cloud`, `flag`), so icons never trigger external network requests.
- Validate syntax before saving or exporting with `ankole-viz validate --kind infographic --input ./diagram.infographic`.
- Some complex infographic templates emit HTML `<foreignObject>` wrappers for multi-line text wrapping. When exporting for Pandoc PDF (`--pdf-safe`), `ankole-viz infographic` automatically inspects the SVG and rasterizes `<foreignObject>` templates to `1920px` lossless `.png` so Typst and WeasyPrint preserve every label cleanly.

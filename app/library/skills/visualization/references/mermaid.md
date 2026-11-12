# Procedural & Engineering Diagrams (Mermaid via Pele)

Use ` ```mermaid ` across Pod `:doc` pages, `:knowledge` pages, and Chat replies—or `ankole-viz mermaid` for offline SVG/PNG files—whenever depicting branching workflows, request/response sequences, state machines, or entity-relationship schemas.

## Supported diagram families (`pele` 1.13)

Stick to diagram types backed by deterministic layout and zero external runtime scripts:

1. **Flowcharts (`flowchart TD` / `flowchart LR`)** — approval paths, pipelines, system architecture boundaries (`subgraph`). Use `TD` when >5 stages or wide CJK labels would compress horizontally; use `LR` for compact 3–5 step pipelines.
2. **Sequence diagrams (`sequenceDiagram`)** — multi-actor RPCs, protocol handshakes, async queues.
3. **State diagrams (`stateDiagram-v2`)** — lifecycle transitions, retry/recovery loops.
4. **Class & ER diagrams (`classDiagram`, `erDiagram`)** — domain models, foreign-key cardinalities.

For timelines, SWOT matrices, or executive roadmaps in `:doc` pages or Chat, prefer ` ```infographic ` (see `references/infographic-dsl.md`); in `:knowledge` pages, use `flowchart LR` or a Markdown table.

## Syntax hygiene rules

1. **Quote labels containing punctuation or brackets**: Always write `A[" check(x) -> [ok] "]` rather than `A[check(x) -> [ok]]` so parentheses, colons, slashes, and CJK punctuation never break the parser.
2. **No HTML tags or inline `style` overrides**: Keep node text plain (no `<br>`, `<b>`, or hardcoded `style A fill:#ff0`); Ankole automatically applies light/dark theme tokens.
3. **Keep diagrams scannable**: Cap one diagram at roughly 15–20 nodes. Split larger systems into an overview diagram plus focused subsystem diagrams.
4. **`:doc` vs. `:knowledge` attributes**:
   - In `:doc` pages, `<mermaid view="diagram" theme="dark">` around a fence is supported when non-default view/theme settings are needed; default `view="both"` and `theme="auto"` write a plain ` ```mermaid ` fence.
   - In `:knowledge` pages, only plain ` ```mermaid ` fences (without `view` or `theme` attributes) are valid.
   - To display literal Mermaid source code as an unrendered code sample, wrap the fence in `<pre lang="mermaid">...</pre>`.

## Fast validation & offline export (`ankole-viz`)

`ankole-viz mermaid` renders via `pele` directly in Bun in milliseconds without launching Chromium:

```bash
ankole-viz validate --kind mermaid --input ./flow.mmd
ankole-viz mermaid --input ./flow.mmd -o ./figures/flow.svg
ankole-viz mermaid --input ./flow.mmd -o ./figures/flow.png --dpr 2
```

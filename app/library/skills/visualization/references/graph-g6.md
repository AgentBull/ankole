# Network & Topology Graphs (AntV G6 v5)

Use `AnkoleGraph` (from `@ankole/uikit`) or `ankole-viz graph` when modeling multi-hop entity relationships, dependency graphs, combo clusters, or radial 1-hop neighborhoods where nodes carry explicit semantic types, weights, or cluster memberships. For small static architecture or call-flow diagrams (<15 nodes) inside a document, prefer `<mermaid>` instead.

## Input data contract

`AnkoleGraph` and `ankole-viz graph` accept `nodes`, `edges`, optional `combos`, and `layout` (`'force' | 'hierarchy' | 'combo' | 'radial'`):

```json
{
  "layout": "hierarchy",
  "ariaLabel": "Service dependency topology",
  "nodes": [
    { "id": "gateway", "label": "API Gateway", "tier": "hub", "ramp": "brand" },
    { "id": "auth", "label": "AuthZ", "ramp": "blue", "parentId": "gateway" },
    { "id": "pod", "label": "Pod Store", "ramp": "teal", "parentId": "gateway" }
  ],
  "edges": [
    { "id": "e1", "source": "gateway", "target": "auth", "label": "verifies", "kind": "relation" },
    { "id": "e2", "source": "gateway", "target": "pod", "label": "queries", "kind": "hierarchy" }
  ]
}
```

- **Color ramps (`ramp`)**: `'brand' | 'blue' | 'teal' | 'purple' | 'green' | 'orange' | 'cyan' | 'magenta' | 'yellow' | 'gray'`.
- **Node shapes (`shape`)**: `'circle' | 'diamond' | 'hexagon' | 'rect'` (`tier: 'hub'` defaults to `'diamond'`).

## Offline vector export (`ankole-viz graph`)

`ankole-viz graph` mounts G6 with `@antv/g-svg` (`SVGRenderer`, `animation: false`) to emit true Print-Safe vector `<svg>` markup (or `--format png` for chat previews):

```bash
ankole-viz graph --spec ./topology.json -o ./figures/topology.svg
```

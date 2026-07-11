# Domain Docs

This repository uses a single-context domain documentation layout. Engineering skills should consume its domain documentation as described below.

## Before exploring, read these

- **`CONTEXT.md`** at the repository root.
- **`docs/adr/`** for architectural decisions that touch the area being explored.

If either location does not exist, proceed silently. Do not flag its absence or suggest creating it upfront. The `/domain-modeling` skill, reached through skills such as `/grill-with-docs` and `/improve-codebase-architecture`, creates these files lazily when terms or decisions are actually resolved.

## File structure

```text
/
├── CONTEXT.md
└── docs/
    └── adr/
        ├── 0001-example-decision.md
        └── 0002-another-decision.md
```

## Use the glossary's vocabulary

When output names a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term defined in `CONTEXT.md`. Do not drift to synonyms that the glossary explicitly avoids.

If a needed concept is absent, reconsider whether the language is being invented or note the genuine gap for `/domain-modeling`.

## Flag ADR conflicts

If output contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision.

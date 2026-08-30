---
name: idea-lineage
description: Trace how one idea evolved through memory — first mention, best articulation, reversals, contradictions, abandoned branches, and the current live version, each cited from stored evidence. For a single idea, not a broad concept map or an entity metric history.
default_enabled: true
ankole-runtime: main
---

# Idea lineage

Answer "how did my thinking about X change?" from stored evidence: when the
idea first appeared, when it became sharp, what it displaced, what it
contradicts, and which version is alive now.

## Boundaries

- One idea per run. When one phrase covers several distinct ideas, ask which
  one before you synthesize.
- A metric, role, or status history of an entity is not lineage. Use `delta`
  with the entity and a time window, and say the difference.
- A broad map across many ideas is not lineage. Use `synthesize` with that
  question directly; page-level merge and consolidation belong to background
  memory maintenance, not to you.
- Read-only by default. Write nothing unless the person asks for a saved
  artifact after seeing the answer; then `synthesize` owns the durable page.

## Method

1. **Resolve the target.** Restate the idea in one sentence. `recall` the
   exact phrase and its variants; check `entity` when the idea has a named
   page. Takes come back with holders — a take belongs to its holder and is
   not automatically the owner's current view.
2. **Gather evidence.** `get_page` the top pages behind the strongest hits.
   `delta` over the idea's active period shows when claims were superseded or
   expired — reversals live there. Prefer few high-quality sources over a
   long unsorted pile.
3. **Classify the moments** into seven buckets:
   - **First mention** — the earliest dated evidence.
   - **Best articulation** — the clearest expression, not necessarily the
     newest.
   - **Current live version** — the most recent version that still stands.
   - **Reversals** — where the stance changed direction.
   - **Contradictions** — claims that cannot both hold. Temporal supersession
     is not contradiction.
   - **Abandoned branches** — variants that appeared, then lost support or
     were rejected.
   - **Related ideas** — nearby concepts that shaped or inherited parts.
4. **Write the answer** in the shape below, proportional to the evidence. Do
   not smooth a messy history into a clean arc.

## Output shape

```markdown
## Current live version
[1–3 sentences, with confidence: high / medium / low]

## Lineage
- First mention: [date] — [claim] (page, "short quote")
- Best articulation: [date] — [claim] (page, "short quote")
- Turning point: [date] — [what changed] (page)

## Reversals and contradictions
- [before/after evidence, or "No clear evidence found"]

## Abandoned branches
- [branch] — [why it reads as abandoned, with evidence]

## Evidence gaps
- [bucket] — [what was checked, what is missing]
```

Collapse sections for short answers, but keep the distinctions.

## Quality rules

- Quote exact text for first mention and best articulation.
- Give dates when the evidence has them; write "undated" instead of guessing.
- The person's direct statements are the highest authority on their own
  current view.
- An empty bucket says "no clear evidence found" and what was checked. Never
  patch a gap with a plausible story, and never invent an abandoned branch
  because it makes the story better.
- Mark confidence low when the evidence is one weak snippet, an undated page,
  or a fuzzy semantic match.

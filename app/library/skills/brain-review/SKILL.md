---
name: brain-review
description: "Review Brain memory when a human explicitly asks to review, audit, clean up, or 复盘 the agent's memory. Guides a conversational post-hoc review of knowledge, pinned memory, and skill notes."
default_enabled: true
category: brain
tags: [Brain, Memory, Review, Supervision]
---

# Brain review

Run this review only after a human explicitly asks to review or clean up memory. The human is the evaluator: surface evidence and apply their decisions; do not silently decide which memories are true or obsolete.

## 1. Diagnose without changing memory

Run `memory_health_check` first. Inspect every reported entry that may affect the review with `memory_open` and inspect cited source messages with `memory_browse` when the evidence matters.

Cover all three Brain surfaces:

- current knowledge entries, including unresolved contradictions and `dreaming`-authored blocks;
- the pinned memory entry and any budget warning reported by the health check;
- enabled skills whose agent-specific notes may be stale or contradicted, using `skill_view` to read their current effective content.

Present a short, numbered set of concrete findings with their entry, block, or skill identifiers. Ask the human to judge them. The opening pass is complete only when the human can decide each finding from the evidence shown and no mutation has run.

## 2. Apply the human's decisions

Translate each decision into the smallest structured operation. Reopen an entry immediately before changing it and use its current entry or block lock version with `memory_update`. Update skill notes through `skill_append` or `skill_replace` according to the skill-note rules already in the system prompt.

The conversation's Brain store remains the write boundary. If the requested target is read-only from this conversation, explain which public conversation or Console surface can make the change.

## 3. Verify the result

Reopen every changed entry or skill and confirm that the current projection matches the human's decision. Rerun `memory_health_check` when the decision addressed a reported health finding. Summarize what changed, what remains unresolved, and the identifiers needed for later audit or recovery.

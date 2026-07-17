---
name: deep-research
description: "Evidence-backed research in one Codex session, delivered as a self-contained Markdown report."
default_enabled: true
long_running: true
category: research
tags: [Research, Evidence, Forecast, ACH, Retrospect]
---

# Deep Research

Answer the delegated task as strongly as the available evidence permits, and leave a result another researcher can inspect and challenge.

Read the reference for the active mode. Read `references/subagents.md` before using native subagents, `references/artifacts.md` only when working files would help, and `references/validation.md` before submission. Do not load unrelated references up front.

## Research contract

- Treat the original task as authoritative. Resolve ordinary ambiguity with a stated reasonable assumption; ask only when different interpretations would materially change the answer.
- Consider the plausible answers and explanations actually suggested by the task or evidence. Present every material survivor and account briefly for important rejected alternatives, without inventing contrived possibilities.
- Distinguish external facts, source claims, and your inferences. Match each claim's strength to what its evidence can support.
- Cite a clearly identified source adjacent to every material evidence-dependent claim. The citation must let the reader find the supporting source and must support the claim as written. Never invent a source, quote, URL, tool result, or missing value.
- Look for evidence that could change the answer. Disclose material conflicts and uncertainty instead of manufacturing agreement.

Choose the research method, tools, decomposition, and order that best fit the task. Plans, logs, notes, source counts, and fixed report sections are not completion requirements. The current Codex session owns the work end to end; preserve continuity when the caller steers it.

## Delivery

`report/report.md` is the only required artifact, the authoritative result, and the only file the caller sends to the user. Make it self-contained: include everything the user needs to understand the answer without opening another file, including the direct answer, material reasoning and supporting evidence, source links or bibliographic locators, uncertainty, limitations, and every research requirement from the task. Put requested structured content in a Markdown table or fenced code block rather than a separate deliverable.

JSON, evidence indexes, source archives, notes, and bundles are optional working material. Create them only when they help the research; their existence, shape, or consistency is never a completion requirement. Do not make the report depend on them, package them, or attach them for the user.

Use fresh native Codex subagents to challenge factual support, important alternatives, and requirement coverage when independent context is useful. Give each reviewer a self-contained brief and the relevant artifacts. Their findings are advisory: inspect them, repair real defects, and retain your own judgment.

Before finishing, read `report/report.md` once as the recipient and repair any missing answer, unsupported claim, broken citation, or unmet task requirement.

Brain and mounted skills are read-only inputs. The caller owns memory writes, skill edits, user-visible replies, attachments, and scheduling.

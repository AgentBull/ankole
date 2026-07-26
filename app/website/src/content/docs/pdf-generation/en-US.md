---
title: PDF generation
description: How to set up an agent that creates, checks, and edits PDF files — the pdf skill, the tools it uses, and a worked example.
section: Guides
order: 327
---

PDF generation is a common deliverable — a report, a proposal, a formatted document that must ship as a PDF. Ankole's `pdf` skill handles this through the worker's installed PDF toolchain (Pandoc, two PDF engines, Poppler, QPDF) and runs as a background job. This guide is the practical shape of a PDF-generating agent.

The decisive property, stated up front: the `pdf` skill is a **filesystem-and-tools skill, not a model feature**. The agent uses its shell tools to run Pandoc and the PDF engines; the skill's `SKILL.md` tells it how. There is no `generate_pdf` API call — it is document preparation through the shell, guided by the skill.

## What you need

- **The `pdf` skill enabled.** It is `default_enabled: true`, so it is on for every agent unless overridden. See [Skills](../skills/).
- **The worker image.** The Agent Computer image installs Pandoc, two PDF engines (Typst and LaTeX), Poppler, and QPDF. These are part of the image — you do not install them.
- **A `primary` model profile bound.** The agent writes the source content (Markdown or a document structure), then the skill's tools render it to PDF.

## What the skill does

The `pdf` skill's `SKILL.md` covers three operations:

- **Create** — write source content (typically Markdown), render it to PDF through Pandoc and a PDF engine. The skill knows the engine selection, the font setup, and the output path.
- **Check** — verify a generated PDF (page count, text extraction, font embedding) using Poppler and QPDF. Use this to confirm a PDF is valid before shipping.
- **Edit** — make a text correction to an existing PDF without regenerating the whole document.

The skill runs as a background job (`ankole-runtime: background_job`), so a long PDF render does not block the conversation.

## A worked example

Set up an agent that produces a weekly report as a PDF:

1. Confirm `pdf` skill is enabled (it is by default).
2. Create the agent, author a `MISSION.md`: "Produce a weekly status report as a PDF. Gather the week's metrics from the channel history, write the report in Markdown, render to PDF with Typst, verify with Poppler, and post the PDF to the channel."
3. Add a weekly [schedule](../cron-schedules-ops/).
4. On each fire, the agent gathers context, writes Markdown, calls the `pdf` skill's tools through the shell, verifies the output, and posts the file.

## The `design-md` companion

If the PDF needs visual polish — a brand palette, a specific layout — pair the `pdf` skill with the `design-md` skill. The `pdf` skill's `SKILL.md` says: "If the human has already provided a brand palette or template, match that first. Otherwise, use `design-md` skills and use it as the design reference."

## What this guide is not

It is not a Pandoc or Typst tutorial — the skill knows the tool invocations; the operator's job is to scope the task. It is not a layout-design guide — use the `design-md` skill for visual decisions. And it is not a substitute for reading the `pdf` skill's `SKILL.md` — that file is the authoritative reference for the tool commands.

## Next steps

- For the skill system, read [Skills](../skills/) and [Writing a skill](../writing-a-skill/).
- For the shell tools the skill uses, read [Code execution](../code-execution/).
- For background jobs, read [Background jobs](../background-jobs-ops/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).

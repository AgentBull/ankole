---
title: PDF generation
description: How to set up an agent that creates, checks, and edits PDF files — the pdf skill, the tools it uses, and a worked example.
section: Guides
order: 306
---

Producing polished PDFs—reports, proposals, and formatted deliverables—is a common task for enterprise Agents. Ankole's `pdf` Skill handles document rendering through the PDF toolchain installed on each Worker (Pandoc, Typst, LaTeX, Poppler, and QPDF) and runs inside a Background Agent Job.

Rather than exposing a black-box `generate_pdf` model tool, the `pdf` Skill is a **filesystem-and-shell workflow**: the Agent writes structured source files, invokes Pandoc and the PDF engines from the shell according to `SKILL.md`, and inspects the rendered PDF before delivering it.

## What you need

- **An enabled `pdf` Skill.** Because it ships with `default_enabled: true`, every Agent has it enabled unless you override it. See [Skills](../skills/).
- **The standard Worker image.** The Agent Computer Worker image comes preinstalled with Pandoc, two PDF engines (Typst and LaTeX), Poppler, and QPDF—no extra setup required.
- **A bound `primary` model profile.** The Agent drafts the Markdown or document source, and then runs the Worker's CLI toolchain to compile and check the PDF.

## What the skill does

The `pdf` Skill's `SKILL.md` guides the Agent through three core workflows:

- **Create:** Draft source content (typically Markdown) and compile it to PDF using Pandoc and either Typst or LaTeX, following the Skill's engine-selection, font, and output-path rules.
- **Check:** Inspect a compiled PDF—verifying page count, extracted text, and embedded fonts—with Poppler and QPDF before sharing it.
- **Edit:** Apply targeted text corrections to an existing PDF without regenerating the entire document from scratch.

Because the Skill declares `ankole-runtime: background_job`, long compilation and layout passes run in a Background Agent Job without blocking the conversation.

## A worked example

To set up an Agent that publishes a weekly status report as a PDF:

1. Confirm that the `pdf` Skill is enabled (it is on by default).
2. Create the Agent and write its `MISSION.md`: "Produce a weekly status report as a PDF. Gather the week's metrics from the channel history, write the report in Markdown, render to PDF with Typst, verify with Poppler, and post the PDF to the channel."
3. Configure a weekly [schedule](../schedules/).
4. Each time the schedule fires, the Agent collects the week's updates, writes the Markdown source, compiles and verifies the PDF on its Worker, and posts the finished attachment to the channel.

## The `design-md` companion

When a PDF requires brand colors or bespoke typography and layout, pair `pdf` with the `design-md` Skill. As the `pdf` Skill's `SKILL.md` specifies: "If the human has already provided a brand palette or template, match that first. Otherwise, use `design-md` skills and use it as the design reference."

## What this guide is not

This page is not a Pandoc or Typst manual—the Skill instructions already spell out the CLI flags, leaving you to define the business scope of the deliverable. For visual styling and layout systems, look to the `design-md` Skill, and for exact command syntax, read the `pdf` Skill's `SKILL.md` file directly.

## Next steps

- For the skill system, read [Skills](../skills/) and [Writing a skill](../writing-a-skill/).
- For the shell tools that the skill uses, read [Code execution](../code-execution/).
- For background jobs, read [Background jobs](../background-jobs/).
- For scheduling, read [Schedules](../schedules/).

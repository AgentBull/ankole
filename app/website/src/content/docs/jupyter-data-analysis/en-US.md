---
title: Jupyter data analysis
description: How to set up an agent that runs iterative Python data analysis through a live Jupyter kernel — the jupyter-live-kernel skill, DataFrame inspection, and a worked example.
section: Guides
order: 304
---

Data analysis is inherently iterative: you inspect a DataFrame, refine a query, plot the result, and repeat. Because a one-shot Python process loses its memory as soon as it exits, Ankole provides the `jupyter-live-kernel` Skill, which starts a live Jupyter kernel that the Agent drives across multiple cells.

Because the Jupyter kernel remains **stateful across cells**, variables, DataFrames, library imports, and plot state persist from one call to the next. That persistence lets the Agent explore and transform datasets step by step without reloading files or re-importing packages on every turn.

## What you need

- **An enabled `jupyter-live-kernel` Skill.** This Skill ships with `default_enabled: true`. See [Skills](../skills/).
- **The standard Worker image.** The Agent Computer Worker image already includes Python, Jupyter, and the `hamelnb` kernel.
- **A bound `primary` model profile.** The Agent writes the Python analysis code, and the Worker's Jupyter kernel executes it.

## When to use the kernel vs a one-shot script

Use the live Jupyter kernel when:

- the analysis is **iterative**, requiring repeated inspection and adjustment;
- **in-memory state must persist**, such as a large loaded DataFrame, a fitted model, or initialized libraries;
- the Agent needs to **explore** the schema and distributions before writing its final aggregation or chart.

Use a one-shot Python script (via the `command` tool) when:

- the script is **stateless** and produces its output in a single pass;
- the task is a **batch file transformation** that needs no interactive inspection.

As the Skill's `SKILL.md` notes: "Prefer a one-shot Python process for stateless scripts."

## How the kernel works

The `jupyter-live-kernel` Skill declares `ankole-runtime: background_job`, so it runs inside a Background Agent Job. When invoked, it starts a Jupyter kernel on the Agent's Worker, and the Agent evaluates code cells sequentially through the Skill's helper tools. Every cell runs against the same in-memory kernel process, so variables defined in cell 1 remain available in cell 5.

The kernel stays alive for the duration of the Background Agent Job. Once the Job finishes, the Worker stops the kernel and discards its in-memory variables—treat kernel memory as ephemeral execution state rather than durable storage.

## A worked example

To set up an Agent that analyzes CSV files posted in a team channel:

1. Confirm that the `jupyter-live-kernel` Skill is enabled (it is on by default).
2. Create the Agent and write its `MISSION.md`: "When a CSV appears in the channel, load it into a DataFrame, inspect the schema and summary statistics, identify anomalies, and report findings with a plot."
3. Attach a CSV directly in the chat channel, or upload it to the Agent's drive in the Console and share its file path.
4. The Agent delegates the analysis to a Background Agent Job, starts the Jupyter kernel, loads the CSV, explores the data across cells, renders a plot, and posts the summary back to the channel.

## What this guide is not

This page is not a Python or pandas tutorial—the Agent writes the analysis code while the Skill manages the kernel process. Nor is it a guide to authoring saved `.ipynb` notebooks for humans, since the live kernel exists primarily for the Agent's interactive loop (though the Agent can export a notebook if you ask for one). For exact tool commands and flags, check the Skill's `SKILL.md` file directly.

## Next steps

- For the skill system, read [Skills](../skills/) and [Writing a skill](../writing-a-skill/).
- For the shell tools, read [Code execution](../code-execution/).
- For background jobs, read [Background jobs](../background-jobs/).
- For uploading files for an Agent, read [File management](../file-management/).

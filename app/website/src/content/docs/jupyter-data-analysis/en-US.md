---
title: Jupyter data analysis
description: How to set up an agent that runs iterative Python data analysis through a live Jupyter kernel — the jupyter-live-kernel skill, DataFrame inspection, and a worked example.
section: Guides
order: 328
---

Data analysis is iterative — inspect a DataFrame, adjust a query, plot a result, repeat. A one-shot Python process cannot hold state between calls. The `jupyter-live-kernel` skill solves this by running a live Jupyter kernel the agent drives across multiple cells, preserving state. This guide is the practical shape of a data-analysis agent.

The decisive property, stated up front: the Jupyter kernel is **stateful across cells**. Variables, DataFrames, imports, and plot state persist between the agent's calls. This is what makes iterative analysis possible — the agent does not reload data or re-import libraries on each step.

## What you need

- **The `jupyter-live-kernel` skill enabled.** It is `default_enabled: true`. See [Skills](../skills/).
- **The worker image.** The Agent Computer image installs Python, Jupyter, and the `hamelnb` kernel. These are part of the image.
- **A `primary` model profile bound.** The agent writes the Python code; the kernel executes it.

## When to use the kernel vs a one-shot script

Use the Jupyter kernel when:

- the work is **iterative** — inspect, adjust, re-inspect
- **state must persist** — a loaded DataFrame, a fitted model, an imported library
- the agent needs to **explore** the data shape before writing a final query

Use a one-shot Python process (through `command`) when:

- the script is **stateless** — run once, produce output, done
- the work is a **batch transformation** — convert a file, no inspection needed

The skill's `SKILL.md` says: "Prefer a one-shot Python process for stateless scripts."

## How the kernel works

The `jupyter-live-kernel` skill runs as a background job (`ankole-runtime: background_job`). It starts a Jupyter kernel in the worker, and the agent sends cells to it through the skill's tools. Each cell executes in the kernel's persistent state — variables defined in cell 1 are available in cell 5.

The kernel stays alive for the duration of the background job. When the job ends, the kernel stops and its state is gone — it is ephemeral execution state, not durable.

## A worked example

Set up an agent that analyzes a CSV the team drops in the channel:

1. Confirm `jupyter-live-kernel` skill is enabled (it is by default).
2. Create the agent, author a `MISSION.md`: "When a CSV appears in the channel, load it into a DataFrame, inspect the schema and summary statistics, identify anomalies, and report findings with a plot."
3. In the channel, upload a CSV (through the worker-file routes or by providing a URL).
4. The agent delegates to a background job, starts the kernel, loads the CSV, inspects iteratively, generates a plot, and reports back.

## What this guide is not

It is not a Python or pandas tutorial — the agent writes the code; the skill provides the execution environment. It is not a notebook-authoring guide — the kernel is for the agent's use, not for producing a saved notebook (though the agent can save one if the task asks). And it is not a substitute for reading the skill's `SKILL.md` — that file is the authoritative reference.

## Next steps

- For the skill system, read [Skills](../skills/) and [Writing a skill](../writing-a-skill/).
- For the shell tools, read [Code execution](../code-execution/).
- For background jobs, read [Background jobs](../background-jobs-ops/).
- For uploading files to the worker, read [Worker files](../worker-files/).

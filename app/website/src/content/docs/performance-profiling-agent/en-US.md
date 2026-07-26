---
title: Performance profiling agent
description: How to set up an agent that profiles code performance — identifies slow functions, measures bottlenecks, and reports with evidence.
section: Guides
order: 351
---

A performance profiling agent runs a profiler against the codebase, identifies the slowest functions and the biggest bottlenecks, and reports them with timing data and a suggested optimization direction. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **profiles and reports, it does not optimize**. It measures where time is spent, identifies the hot paths, and suggests what to look at. A human writes the optimization; the agent provides the evidence. The value is in finding the bottleneck fast, not in fixing it.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading profiler output and identifying hot paths requires code comprehension.
- **A signal binding** to the channel where profiling reports post.
- **The repo accessible from the worker**, with a way to run the code under a profiler.

## The workflow

1. **A profiling task arrives** — "profile the API response time for `/payments`," or a scheduled check.
2. **The agent runs the profiler** — the language's profiling tool: `bun --prof`, `node --prof`, `py-spy`, `perf`, or a benchmarking script.
3. **The agent reads the output** — identifies the top N functions by time, the call frequency, and the allocation hot spots.
4. **The agent maps to source** — connects each hot function to its file and line, reads the code, and identifies the likely cause (a nested loop, an N+1 query, an unnecessary allocation).
5. **The agent reports** — a structured report: the top bottlenecks with timing, the source location, the likely cause, and a suggested direction (not a patch).

## What the persona controls

- **Profiling target** — "profile the test suite's slowest 5 tests" vs "profile a specific API endpoint under load."
- **Tool selection** — "use `bun --prof` for Bun code, `py-spy` for Python."
- **Reporting depth** — "top 10 functions by self-time, with source location and one-line diagnosis."
- **What not to do** — "do not write the optimization. Report the bottleneck and suggest a direction. Do not modify the code."

## A worked example

Set up a performance profiling agent for a Bun API:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`coding`.
3. Author `MISSION.md`: "Profile the API by running `bun --prof` against the test suite. Identify the top 10 functions by self-time. For each, report: function name, file:line, self-time, call count, likely cause (loop, allocation, I/O), suggested direction. Do not optimize. Post the report to the channel."
4. In the channel: "Profile the payments endpoint — it's been slow since the last deploy."
5. The agent clones, profiles, reads the output, maps to source, and posts the report.

## What this guide is not

It is not an APM tool — the agent profiles on demand, not in production continuously. It is not an auto-optimizer — it finds the bottleneck; a human fixes it. And it is not a load tester — it profiles correctness-path performance, not behavior under concurrent load (for that, see the [API testing agent](../api-testing-agent/)).

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools (running profilers), read [Code execution](../code-execution/).
- For the coding profile, read [Providers and models](../providers-and-models/).
- For the API testing pattern (related), read [API testing agent](../api-testing-agent/).

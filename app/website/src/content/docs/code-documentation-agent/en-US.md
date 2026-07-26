---
title: Code documentation agent
description: How to set up an agent that reads a codebase and generates or updates documentation — function docs, API references, README sections.
section: Guides
order: 346
---

A code documentation agent reads a codebase, understands the functions and their contracts, and generates or updates documentation — function-level doc comments, API references, README sections, or architecture overviews. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **documents what the code does, not what it should do**. It reads the actual implementation, extracts the contract (parameters, return types, side effects, error cases), and writes documentation that matches the code. It does not invent features the code does not have, and it does not document a planned API that is not implemented. The documentation is a projection of the code, not a specification.

## What you need

- **Git credentials in WorkerEnv** (`GIT_TOKEN`). See [Git integration](../git-integration/).
- **`primary` and `coding` profiles bound** — reading code and writing docs requires code comprehension.
- **A signal binding** to the channel where documentation drafts post.
- **The repo accessible from the worker.**

## The workflow

1. **A documentation task arrives** — "document the public API of the payments module," "update the README for the new auth flow," or a scheduled check for undocumented functions.
2. **The agent clones and reads** — `git clone`, then reads the relevant files through the shell tools (`read-file`, `command` with `grep` or `rg`).
3. **The agent extracts contracts** — for each function or module: parameters, return types, side effects, error cases, dependencies.
4. **The agent writes documentation** — doc comments, Markdown reference pages, or README sections, matching the project's existing documentation style.
5. **The agent posts the draft** — or opens a PR with the documentation changes.

## What the persona controls

- **Scope** — "document public functions only" vs "document every function including private helpers."
- **Style** — "match the existing JSDoc/TSDoc style in the repo. Use the project's voice from existing docs."
- **Depth** — "one-line summary per function" vs "full parameter descriptions, examples, and error cases."
- **Format** — "inline doc comments" vs "separate Markdown reference pages."
- **What not to do** — "do not document planned features. Do not add examples that are not tested. Do not change the code."

## The "match existing" discipline

The most important persona rule for a documentation agent: **match the existing style**. If the repo uses TSDoc with `@param` and `@returns`, the agent writes TSDoc with `@param` and `@returns`. If the README uses a specific heading structure, the agent uses that structure. Inventing a new documentation style is worse than no documentation — it fragments the codebase's voice.

## A worked example

Set up an agent that documents a TypeScript library's public API:

1. Store `GIT_TOKEN` in WorkerEnv.
2. Create the agent, bind `primary`/`heavy`/`coding`.
3. Author `MISSION.md`: "Clone the repo. Read all exported functions in `src/`. For each, extract the contract: parameters, return type, thrown errors, side effects. Write TSDoc comments matching the existing style. Post the diff as a draft for review. Do not change the code. Do not document unexported functions."
4. In the channel: "Document the public API of the payments module on branch `docs/payments`."
5. The agent clones, reads, extracts, writes TSDoc, and posts the diff.

## Delegate large codebases

For a large codebase with many undocumented functions, delegate the reading-and-documenting to a background job (see [Delegation patterns](../delegate-patterns/)). The job processes a batch of files; the agent posts the completed diff when the job finishes.

## What this guide is not

It is not a code generator — the agent writes documentation; it does not write or modify the code itself. It is not an architecture-decision recorder — the agent documents what exists; architecture decisions are written by humans in ADRs. And it is not a substitute for code review — the documentation is a draft; a human verifies it matches the code's intent.

## Next steps

- For git setup, read [Git integration](../git-integration/).
- For the shell tools (reading code), read [Code execution](../code-execution/).
- For the coding profile, read [Providers and models](../providers-and-models/).
- For delegation, read [Delegation patterns](../delegate-patterns/).

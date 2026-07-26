---
title: Memory
description: How an Ankole agent reads and writes long-term memory — the Brain tools (memory_search, memory_open, memory_update, memory_browse, memory_health_check), when the agent uses them, the human/agent/dreaming write-authority modes, and how an operator enables memory by declaring a Brain scope on the conversation.
section: User guide
order: 33
---

Memory is how an Ankole agent keeps what it learned across turns and across conversations. It is a set of worker tools, shipped in `app/agent_computer/src/tools/memory/memory-tools.ts`, that read and write the [Brain](../brain/) subsystem through AIGateway. This page is the operator view: what the tools are, when the agent reaches for them, how memory is scoped, and how you turn it on for a conversation.

The decisive property, stated up front: Brain memory is durable truth, and the agent's working memory — the context of the current turn — is ephemeral. What the agent remembers next week lives in Brain's curated knowledge in PostgreSQL, not in the conversation transcript. If the agent did not write it to Brain, it did not remember it.

## What memory is

The agent does not have a generic "remember" button. It has five focused tools, each with a job, all defined in `app/agent_computer/src/tools/memory/memory-tools.ts`:

- **`memory_search`** (line 231) — search Brain knowledge. The agent supplies a query and a layer (`chat`, `knowledge`, or `all`), and gets back ranked evidence. The description tells the model to check `status`, `result_completeness`, and `degraded_reasons` before trusting an empty result, because an incomplete empty result does not prove nothing matches.
- **`memory_open`** (line 263) — open and read one curated knowledge entry by its canonical name or alias, returning permanent block positions and semantic relations.
- **`memory_update`** (line 290) — apply exactly one structured mutation to a curated entry. This is the write path, and it requires write authority. The control plane derives owner, store, author, and concurrency fences from the entry opened in the same turn.
- **`memory_browse`** (line 316) — browse exact, untrusted chat messages or retained external material, page by page, using the `source_N` aliases a search returned.
- **`memory_health_check`** (line 344) — read the same status the human Console reads: pipeline failures, embedding backlog, memo budget, and curation lints. It is a diagnostic index, not a verdict, and the description tells the agent not to run it automatically.

These tools are the only surface the agent has on long-term memory. Brain itself — embeddings, dreaming, source retention, curation — is the subsystem behind them, documented in the [Brain](../brain/) developer page.

## When the agent uses memory

The tools are not called on every turn. The agent reaches for them when the current turn's context does not establish the answer, or when newer state or exact provenance matters. Concretely:

- **`memory_search`** when the agent needs a fact, a prior decision, or a recalled quote that is not in the working context — and when it must cite where a claim came from.
- **`memory_open`** before any update: the tool description says "open every entry and block immediately before updating it," so the agent never edits blind.
- **`memory_update`** to record a durable fact worth keeping — a decision, a corrected understanding, a new piece of self-knowledge. For ephemeral state (what the agent is doing right now, a tool failure mid-task), the transcript is enough, and writing it to Brain only crowds out durable knowledge.
- **`memory_browse`** to re-read the exact source message behind a citation, or to scan a page of raw chat the search surfaced.
- **`memory_health_check`** only inside a deliberate review — the `brain-review` skill is the path for that, and it runs only when a human explicitly asks to review, audit, clean up, or 复盘 the agent's memory.

The distinction that matters: Brain is for knowledge that must survive the conversation. Working memory — the turn's context — is for the turn. An agent that writes every passing thought to Brain makes the durable store noisier, not smarter.

## How memory is scoped

Every read and write flows through a Brain scope, and that scope is derived only from the declaration on the AIGateway conversation — `conversation.metadata["brain"]`. No channel event, no provider metadata, no ambient runtime state is consulted as a fallback. A scope carries an `owner_uid`, the set of `readable_store_keys`, one `writable_store_key`, and the `current_channel`.

This puts the permission boundary on the conversation declaration, where an operator can see and change it. A public group's default store is `shared`; a direct message defaults to `dm:<uid>`; a confidential channel uses `channel:<id>`. The agent never passes `current`, `shared`, `dm:<uid>`, or `channel:<id>` explicitly — the control plane derives them. The one explicit selection the agent can make is `self`, for knowledge about this agent that must apply across its conversations: its own operating rules, skills, or self-knowledge.

## Write authority: who may write what

A write to curated knowledge carries an authority mode, and the mode is recorded on the row. The modes, from the Brain Knowledge module, are:

- **`:human`** — written by a person, through the Console or a review.
- **`:agent`** — written by the agent from the conversation's writable store.
- **`:dreaming`** — proposed by the Brain dreaming process. Dreaming produces proposed knowledge, and a human reviews it before it becomes fact. A `:dreaming` block is not yet truth; it is a candidate.
- **`:source_learning`** — derived from retained source material.
- **`:mechanical`** — written by an automated pipeline.

This is why `memory_update` derives author and write authority from the entry opened in the turn, rather than letting the agent pick. The agent writes under its own authority, into the store the scope permits. It cannot write as `:human`, and it cannot write dreaming proposals into a store that does not accept them.

## How to enable memory

Memory is not a skill you toggle in the [Agent Library](../agent-library/). The tools ship with the worker and appear on every turn the Agent Computer runs, but they answer nothing unless the conversation declares a Brain scope. Two things must be true for an agent to actually use memory:

1. **The conversation declares a Brain scope.** Set `conversation.metadata["brain"]` so the control plane can derive an `owner_uid`, readable stores, and a writable store. Without this declaration, the tools run against an empty scope and return nothing useful. The declaration is the on-switch.
2. **The agent has a reason to use them.** A persona that tells the agent to keep durable knowledge, and a `brain-review` cadence for human oversight, are what make memory useful rather than inert. See [Agents](../agents/) for how persona and capabilities come together.

For the periodic review of what the agent has remembered, enable the `brain-review` skill — a builtin (`default_enabled: true`) that guides a conversational post-hoc review using the five tools above. It runs only on explicit human request, and the human is the evaluator: the agent surfaces evidence and applies the human's decisions; it does not silently decide which memories are true.

## What the operator does not touch

The tools' RPC paths, the embedding pipeline, and the dreaming scheduler are subsystems behind AIGateway, not operator-tunable flags. If memory returns degraded results, the place to look is `memory_health_check` output (pipeline failures, embedding backlog, curation lints), not a worker environment variable. The durable fix is in Brain itself — see the [Brain](../brain/) developer page — not in the worker image.

## Next steps

- For the subsystem behind these tools — durable knowledge, dreaming, source retention, human review — read the [Brain](../brain/) developer page.
- For the agent's persona, capabilities, and the conversation declaration that scopes memory, read [Agents](../agents/).
- For the skill that guides a periodic memory review, read [Agent Library](../agent-library/) and [Writing a skill](../writing-a-skill/).
- For the worker that runs these tools during a turn, read the [Agent Computer](../agent-computer/) developer page.

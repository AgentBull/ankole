---
title: Multi-agent patterns
description: How more than one agent cooperates on one Ankole installation — separate Principals, shared channels, shared memory, and the human-in-the-loop coordination model. There is no agent-to-agent RPC.
section: Guides
order: 317
---

Once you have more than one agent on an installation, the question is how they cooperate. This page names the patterns Ankole actually supports — and is explicit about the one it does not, because that is the easiest thing to assume and the fastest thing to get wrong.

The decisive property, stated up front: **there is no agent-to-agent RPC.** Agents do not call each other as tools. They are separate Principals with separate sessions, separate memory, and separate permissions, and they cooperate through shared surfaces — channels a human mediates, memory that is shared on purpose, and work one agent delegates to a background job it owns. If your design needs one agent to synchronously invoke another, redesign it; that path does not exist.

## What "more than one agent" actually means

Each agent is a Principal. Each has its own:

- **signal bindings** — a binding is keyed `{agent_uid, binding_name}` against one agent, so two agents in the same chat platform are two bindings, two identities, two reply shapes.
- **sessions** — an actor is `{agent_uid, session_id}`; one agent's turn does not see another agent's session.
- **memory** — Brain scope is derived per agent, from the conversation declaration. What one agent knows, another does not, unless the memory is explicitly shared.
- **permissions** — AuthZ grants are per Principal. Two agents have exactly the authority granted to each, no more.

This separation is the point. A customer-success agent and a coding agent are different people, and they stay that way.

## Pattern 1: shared channel, human-mediated

Two agents bound to the same channel, each addressed by @-mention. The human in the channel decides who to talk to; the agents do not address each other.

- **Shape**: agent A bound to the channel, agent B bound to the same channel (different adapter app or different bot identity). A human @-mentions A or B; the addressed agent wakes.
- **Coordination**: the human. "A, summarize this; B, take the summary and open a PR" is two @-mentions by a human, not a handoff between agents.
- **Fits**: a team channel with a general assistant and a specialist (coding, research) — the human picks the right one.

This is the simplest multi-agent pattern, and usually the right one. It keeps each agent's identity and memory clean, and it keeps a human accountable for which agent does what.

## Pattern 2: shared memory, separate agents

Two agents that need to know the same durable facts — the team's stack, the decisions that have been made, the glossary — but serve different purposes. Use the Brain shared store.

- **Shape**: Brain knowledge scoped to the `brain-shared` owner, readable by both agents through their scope declarations. Each agent still has its own conversation memory; the shared rows are the curated facts both see.
- **Coordination**: the shared knowledge rows. A change a human reviews into shared Brain knowledge is visible to both agents on their next recall.
- **Fits**: a research agent and a coding agent that both need to know "these are the libraries we use."

The shared store is for *curated, reviewed* facts — not for one agent to write into another's working memory. The write authority model still applies: a dreaming proposal is a dreaming write, labeled as such.

## Pattern 3: delegated work, one owner

An agent hands long work to a background job, and the job runs as that same agent — not as a different one. This is the [delegation patterns](../delegate-patterns/) shape; it is single-agent delegation, not multi-agent cooperation, but it is the pattern people reach for when they imagine "agents cooperating."

- **Shape**: agent A calls `create_background_job`; the job's `agent_uid` and `owner_session_id` belong to A; the job wakes A's session when it finishes.
- **Not multi-agent**: the job is A's work, on A's workspace, under A's authority. If you want the result to reach agent B, a human reads A's result and @-mentions B — the human-mediated pattern from Pattern 1.

This is worth saying plainly because "delegate to another agent" is the design people assume exists. It does not; delegation is to a job, not to a peer agent.

## Pattern 4: scheduled fan-out

A schedule fires one agent, which produces something several agents consume — a daily briefing that a human then routes to multiple channels, each served by a different agent.

- **Shape**: a cron schedule on agent A's session produces a summary; A posts it; humans or schedules in other channels pick it up. Each downstream agent is its own binding, its own session.
- **Coordination**: the posted artifact (the summary), not a message between agents.
- **Fits**: one researcher, several channel-specific presenters.

This is Pattern 1 with a scheduled producer. The coordination artifact is the posted text, not an agent-to-agent call.

## When you would want true agent-to-agent

You would want it when one agent's output is another agent's input, synchronously, with no human in between. Ankole does not support that, by design: the human-in-the-loop is a property of the model, not a limitation to work around. If you genuinely need pipelines of agents calling agents, what you want is a single agent whose persona and tools cover the whole pipeline — one Principal, one authority surface, one set of memory — not a mesh of agents talking to each other.

## Operating multiple agents

- **Per-agent least authority.** Each agent gets only the grants it needs. See [Security hardening](../security-hardening/).
- **Per-agent model profiles.** A specialist can run a heavier `primary` than a general assistant. See [Cost management](../cost-management/).
- **Per-agent persona.** Each agent's `MISSION`/`SOUL`/`DESIGN` names its scope, including when to defer to a human rather than answer.
- **Observe per agent.** The [Observability](../observability/) surfaces are per-agent (`/agents/:agent_uid/...`), so you can see what each is doing without mixing them.

## What this guide is not

It is not a catalog of agent-to-agent protocols — there are none, and adding them is not a supported extension. It is not a way to make agents share sessions or authority; those are scoped per Principal by design. And it is not a substitute for the single-agent guides; almost every multi-agent deployment is several single-agent deployments that happen to share a channel or a memory store, and the single-agent patterns are where the work is.

## Next steps

- For the single-agent foundation, read [Agents](../agents/) and [Your first Lark bot](../lark-first-bot/).
- For shared memory, read [Brain](../brain/) (the `brain-shared` owner).
- For delegation (single-agent), read [Delegation patterns](../delegate-patterns/).
- For per-agent authority, read [Principal and AuthZ](../principal-authz/).

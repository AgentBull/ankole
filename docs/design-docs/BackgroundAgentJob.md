# Background Agent Job

Status: implemented

A BackgroundAgentJob is one durable unit of work that continues outside the
main Agent turn that started it. PostgreSQL owns the Job and its lifecycle. The
only runner is CodexRunner.

Agent Plugins and standalone Skills add capabilities to an ordinary Job. They
do not create Job types or change the lifecycle. Deep Research is therefore a
normal Job selecting the `deep-research` Agent Plugin.

## User story

The main Agent calls `background_agent_job` when work should be acknowledged
now and continue durably. The tool has five actions:

- `start` starts a Job and returns after the Job and dispatch event commit;
- `list` lists Jobs visible to the owner scope;
- `status` reads a Job and its bounded execution projection;
- `steer` adds instructions, answers a pending question, or continues a
  resumable succeeded or failed Job;
- `stop` stops queued, waiting, or running work.

`start` accepts:

- required `title` and self-contained `task`;
- optional `background` and `notes`;
- optional `agent_plugin_ids`;
- optional standalone `skill_names`;
- optional explicit `workspace_mounts`;
- optional `model` and `reasoning_effort`.

Owner identity, reply routing, runtime IDs, and lifecycle state are derived from
the authorized parent Turn. Owner conversation history is not copied into the
Job, so `task` must contain the requirements and acceptance criteria needed by
the runner.

Completion, failure, and `waiting_on_user` create durable wakeups for the owner
session. Stopping a Job does not create a wakeup.

## Ownership

The Elixir control plane owns:

- Job and Job Turn rows in PostgreSQL;
- owner scope, authorization, and reply routing;
- Agent Plugin and Skill selection validation, account resolution, and
  workspace resolution at start time;
- status transitions, attempts, dispatch, steer, and stop;
- `job:<job_id>` actor-session serialization and lease recovery;
- terminal commit and owner wakeup;
- RuntimeFabric, REST, and Console projections.

Agent Computer owns:

- the private Job project and Job-specific Codex home;
- current Agent Plugin and Skill resolution, package staging, installation,
  and Skill configuration;
- standalone Skill, MCP, Brain, and web capability projection;
- Codex app-server execution and resume;
- bounded semantic Job Turn observations;
- the generic final execution result.

Codex owns thread state, Plugin and Skill behavior, hooks, native collaboration,
and task execution. Its thread is resumable execution state, while PostgreSQL
remains the durable Job source of truth.

## Durable model

`background_agent_jobs` stores facts shared by every Job:

- identity: `id`, `agent_uid`, `owner_session_id`, source event and tool-call
  IDs, and the captured `reply_route`;
- request: `title`, `task`, optional `background`, and optional `notes`;
- execution: `codex_account_id`, optional `model`, optional
  `reasoning_effort`, and optional `runtime_thread_id`;
- capabilities: selected `agent_plugin_ids`, standalone `skill_names`, and
  `workspace_mounts`;
- lifecycle: `status`, `attempts`, and queued/started/completed timestamps;
- observations: generic `result`, `error`, and `metadata` maps.

`skill_names` contains only standalone Skills. If it is omitted, the control
plane records all standalone Skills effectively enabled for the Agent at that
moment. Agent Plugin member Skills never appear in this array. The Job does not
store package versions, hashes, or member-Skill state.

A workspace mount contains a stable ID, worker-visible source, and access mode:

```json
{
  "id": "workspace",
  "source": "/workspace/user-files/background-agent-jobs/<job-id>/workspace",
  "access": "read_write"
}
```

Mount sources must be normalized paths under `/workspace/user-files/`. The
worker rejects symlink escape, duplicate IDs or sources, and overlap with the
private Job project. When mounts are omitted, the control plane provides the
managed writable mount shown above.

## Capability resolution

At Job start the control plane resolves the target Agent's current library
state to validate selected Agent Plugin IDs and standalone Skill names. It then
persists only those IDs and names.

Before every execution or resume, Agent Computer resolves those selections
against the current enabled Agent Plugin catalog and effective Skill catalog.
A selected Plugin or Skill that is now disabled or missing makes preparation
fail as unavailable. Current package bytes and current member-Skill state apply
automatically; the Job has no capability snapshot, lease, or compatibility
state.

The RuntimeFabric catalog method is `agent_plugin.list`. Worker RPCs use
`background_agent_job.*` for start, read, status transitions, Turn projection,
steering, and stopping.

## Lifecycle

```text
queued
  -> running
       -> waiting_on_user -> running
       -> succeeded
       -> failed
       -> stopped
  -> failed
  -> stopped

succeeded | failed --steer--> queued
```

Only acquisition of a real execution lease increments `attempts`. Placement
failure leaves the Job queued. Attempts exhausted commits failure and wakes the
owner.

A stopped Job cannot resume. A succeeded or failed Job can continue only when
its `runtime_thread_id` anchors resumable Codex state.

Terminal commit and owner wakeup occur in one control-plane transaction.
Success or `waiting_on_user` also requires the lead Job Turn to be durably
closed. Native Codex child Turns are observations of the same execution graph
and do not own the Job terminal state.

Job activity is governed by the actor lease. Worker loss causes recovery and
redispatch; a worker that already persisted the thread ID resumes that thread.
Codex JSON-RPC request timeouts protect individual protocol calls and are not a
maximum Job duration.

## Start and dispatch

Start is idempotent by
`{agent_uid, owner_session_id, source_tool_call_id}`. For a new key, the control
plane:

1. derives owner and reply-route facts from the authorized parent Turn;
2. resolves the Codex account;
3. validates selected Agent Plugin IDs;
4. resolves and records standalone Skill names and workspace mounts;
5. inserts the queued Job and its `background_agent_job.dispatch` actor event
   in one transaction.

The dispatch event targets `{agent_uid, "job:<job_id>"}`. The complete task
stays in PostgreSQL and is read through the fenced Job Turn. Replaying the same
start returns that Job and its original dispatch event; it does not append or
deliver another event, even after attempts or status changes.

## Agent Plugin project setup

Agent Plugin packages live under `app/library/agent-plugins/` and use the
standard Codex manifest:

```text
<agent-plugin-id>/
├── .codex-plugin/plugin.json
├── skills/
├── hooks/                 # optional
└── workspace-template/    # optional Ankole initialization content
```

The current packages use `skills/`, but the standard manifest's `skills`
field is authoritative. Both control-plane discovery and Agent Computer
materialization follow that same declared path.

Each Job has one durable, non-Git private project:

```text
/workspace/user-files/background-agent-jobs/<job-id>/project
```

On first execution CodexRunner:

1. resolves the saved IDs and names against the current enabled catalogs;
2. validates and copies the current complete packages into the Job project;
3. copies every selected `workspace-template/` into the project root;
4. appends SOUL, MISSION, and Job guidance to the project-root `AGENTS.md`,
   creating it when no template supplied one;
5. writes a local marketplace;
6. installs each complete package through Codex `plugin/install`;
7. discovers member Skills with `skills/list`;
8. calls `skills/config/write` by absolute Skill path for every member using
   its current effective state;
9. lists again and verifies the final state before starting the thread.

Only enabled member Skills contribute their Skill-level MCP configuration.
Package-level hooks, resources, MCP configuration, and template content are
present because the parent Agent Plugin was selected.

On resume, CodexRunner requires the private project, resolves the current
catalogs, refreshes the rebuildable package copies and marketplace, repeats
installation and Skill configuration, and resumes the same thread. It does not
copy templates or append `AGENTS.md` again, so template content and later Job
edits remain untouched.

The Job-specific `CODEX_HOME` is outside the project and is never shared with
another Job. External mounts appear inside the sandbox under
`/workspace/workspaces/<mount-id>` and remain caller-owned resources.

## CodexRunner

CodexRunner has no Agent-Plugin-specific execution branches. For each Job Turn
it:

1. reads the fenced Job record;
2. validates the project and mounts;
3. prepares Agent Plugins, Skills, MCP servers, runtime guidance, and Codex
   configuration;
4. starts or resumes the Codex thread;
5. records lead and native child Turns as bounded `ankole_chatml` trajectory,
   progress, and usage observations;
6. accepts steering, stopping, and `request_user_input`;
7. commits a generic result after Codex returns a non-empty final response.

If the first completed Turn has no final response, the runner requests one
generic final report once. A second empty completion fails the Job. The runner
does not interpret package-specific files or run package-specific result code.

`request_user_input` closes the current Turn resumably, puts the Job in
`waiting_on_user`, and wakes the owner. The owner's answer returns through
`steer` to the same Job and thread.

## Model-visible capabilities

A Job can receive:

- the current enabled packages and members for its selected Agent Plugin IDs;
- the current effective standalone Skills matching its saved names;
- the built-in long-running Browser capability on every Job, backed by a
  persistent opaque route materialized immediately before the Codex app-server
  starts;
- fallback web search and fetch capability;
- owner-scoped Brain tools;
- MCP servers contributed by enabled capabilities;
- Codex's built-in execution and native collaboration behavior.

The Browser Skill uses the preconfigured `ankole-browser` CLI and code runner;
it does not give Codex backend/profile source configuration or control-plane
identifiers. This persistent Job route is separate from the ephemeral rendered
fallback used by `web_fetch`, which still returns page content only.

Capabilities are allowlisted. A Job does not inherit every tool available to
the main Agent.

## Deep Research

Deep Research selects `agent_plugin_ids: ["deep-research"]`. Its Skill and
workspace template tell Codex how to research and to produce a self-contained
`report/report.md`. The Job host does not parse that report or give Deep
Research a separate lifecycle. The main Agent verifies the real report before
delivering it to the user.

## Required verification

- package discovery, membership, hashes, symlink and size boundaries;
- global defaults, Agent inheritance, parent gating, and child-state retention;
- rejection of unavailable selected Agent Plugins and Skills on every prepare;
- template copy plus project-root `AGENTS.md` append on first initialization,
  with neither repeated on resume;
- full package installation, absolute-path Skill configuration, final-state
  verification, and enabled-Skill MCP filtering;
- start/list/status/steer/stop, waiting on user, lease recovery, and terminal
  wakeups;
- REST, OpenAPI, and Console projections of current fields;
- a real Deep Research Job producing `report/report.md`;
- a real Office artifact and an explicitly enabled Lark flow;
- Agent Computer image `codex --version` equal to `0.144.5`.

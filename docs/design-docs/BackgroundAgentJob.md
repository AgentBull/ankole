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
session. A success wakeup carries Codex's final response so the main Agent can
resume from that result. The wakeup is delivery plumbing, not a second business
acceptance phase. Stopping a Job does not create a wakeup.

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
- append-only semantic Job Turn observations with bounded presentation pages;
- Codex's final response as the generic execution result.

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

Terminal Jobs retained from the pre-V2 delegation schema remain queryable, but
their old thread and host workdir do not satisfy the V2 runtime contract. The
migration preserves those values in the `background_agent_job_v1` metadata
snapshot, clears the live `runtime_thread_id`, and marks V2 resume as
unsupported. The snapshot is informational user-visible metadata, not trusted
downgrade provenance, so the V2 migration has no automatic down path. Its
canonical workspace mount is a schema placeholder: the
migration neither materializes nor marks that path as managed, so cleanup must
not treat it as owned storage. The immutable pre-Turn event archive remains
control-plane-owned until an explicit export or retention migration removes it.
Both archive foreign keys use `RESTRICT`. Databases that already recorded an
older destructive draft of either migration fail closed and must be restored
from a pre-draft backup; Ankole does not fabricate deleted Jobs or event history.

Terminal commit and owner wakeup occur in one control-plane transaction.
Success or `waiting_on_user` also requires the lead Job Turn to be durably
closed. Native Codex child Turns are observations of the same execution graph
and do not own the Job terminal state.

Job activity is governed by the actor lease. Worker loss causes recovery and
redispatch; a worker that already persisted the thread ID first resumes that
thread. If Codex reports the checkpoint as unknown, including after a crash
between `thread/start` and the first `turn/start`, the runner creates one
replacement thread and replays the original task with bounded attempt history.
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

The dispatch and later steer or stop events are internal Job-session work, not
provider-entry inputs. They retain channel and thread placement but do not copy
the originating `source_entry_id`; removing the message that created a Job does
not delete its dispatch or change its lifecycle. The captured `reply_route`
keeps the origin and completion-delivery facts. Stopping committed work remains
an explicit Job lifecycle operation.

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
5. records lead and native child Turns as append-only `ankole_chatml` trajectory,
   progress, and usage observations;
6. accepts steering, stopping, and `request_user_input`;
7. stores that non-empty Codex final response as the generic Job result, along
   with the stable owner-visible project path and any existing owner-visible
   files observed in `files_changed`, then wakes the owner session so the main
   Agent can continue.

Trajectory groups are appended to PostgreSQL by stable item key and position.
There is no per-Turn item-count or total-byte eviction. The Turn row separately
stores lifecycle, progress, usage, error, and a metadata-only trajectory header.
Status and Console reads expose newest-first cursor pages bounded to `24 KiB`;
that presentation bound may shorten one displayed group but never deletes the
durable semantic sequence. Secret redaction and per-value sanitation happen
before a group crosses the worker boundary.

## Hermes Floor And Job Tradeoffs

| Boundary | Previous Ankole | Hermes reference | Current Ankole | Tradeoff |
| --- | --- | --- | --- | --- |
| Execution attempts | `3` | No BackgroundAgentJob layer; stream stale streak gives up after `5` | `5` real lease acquisitions | More duplicate provider work is possible after worker loss, but a durable long task gets two additional recovery opportunities. |
| Retry backoff | `2/4/8s`, maximum `60s` | Transient retry loop with wider repeated recovery | `5/10/20/40s`, maximum `120s` | Recovery is slower under persistent failure and less likely to amplify a short outage. |
| Durable trajectory | At most `256` runtime items and `256 KiB`; oldest semantic history was evicted | Multi-strategy trajectory compression without a fixed total cap | Append-only PostgreSQL groups, no item-count or total-byte cap; `24 KiB` applies only to one presentation page | PostgreSQL grows with real work, which is the intended SSOT cost; pagination and retention policy must manage reads and storage instead of deleting history during execution. |
| Wall-clock duration | No Job total timeout | No comparable durable Job timeout | No Job total timeout | Liveness comes from progress/worker leases; business deadlines must use `steer` or `stop`. |

If the first completed Turn has no final response, the runner requests one
generic final report once. A second empty completion fails the Job. The runner
does not interpret package-specific files or run package-specific result code.
Job success does not require artifacts, `verification`, or a separate owner-side
acceptance object. The worker reads each aggregate Codex diff as a stream of
file blocks; it retains at most 32 paths and 8 KiB of serialized path data in
session and Turn progress instead of collecting, sorting, or `stat`-ing the full
diff. The generic result includes `project_path`; `files_changed`, `artifacts`,
and `artifact_roots` use the bounded `{total_count, paths, truncated}` shape.
`total_count` preserves the number of observed changed-path candidates across
completed turns, while `artifacts.paths` contains only retained candidates that
resolve to existing owner-visible files. `artifact_roots` contains the private
project plus every writable owner workspace mount, so an omitted key artifact
remains discoverable even when it was written outside `project_path`.

The same 32-entry and 8 KiB path bound is reapplied before worker transport,
durable commit, owner wakeup, status rendering, and model projection. When a
handoff is truncated, the owner uses the existing Job status lookup and inspects
the reported artifact roots; Ankole does not add a separate artifact pagination
lifecycle. Files, reports, commits, and pull requests remain ordinary task
outputs rather than package-specific lifecycle state.

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
Research a separate lifecycle. The generic artifact projection exposes the
report's stable owner-visible path when Codex reports it as changed; the owner
wakeup resumes the main Agent, which decides the next user-facing step through
the ordinary Agent loop.

## Validation plan

These checks validate the implementation path; they are not fields or
acceptance objects required in a successful Job result.

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

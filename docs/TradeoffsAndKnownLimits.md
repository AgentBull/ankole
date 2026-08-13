# Tradeoffs and Known Limits

This page explains what Ankole does not guarantee. Each subsystem design
document describes the related behavior in more detail.

## One Instance Is One Trust Boundary

Each enterprise should operate its own private deployment instance. One instance
contains one set of Agents, accounts, configuration, provider connections, and
data.

Principal and AuthZ control access inside that instance. They do not isolate
organizations that do not trust the same infrastructure. Run a separate
deployment instance for each organization.

## The Worker Container Protects the Host

Ankole treats each Agent Computer container or pod as a trusted, first-party
worker. The container forms the main security barrier around Agent code.

Bubblewrap adds command isolation inside the container. Strong mode mounts a new
`/proc`. Weak mode uses the container's `/proc` when the outer runtime blocks
that mount. The worker reports weak mode and refuses to start if both modes fail.

The current Docker setup grants `SYS_ADMIN` and uses an unconfined seccomp
profile. Kubernetes must grant equivalent kernel access for strong mode.

Bubblewrap does not make hostile code safe inside one trusted worker. Use
separate containers or deployment instances for hostile workloads. An attacker
who controls a worker can control a trusted part of Ankole.

All sandboxes in one Worker can read and write `/var/share`. This directory is
Worker-local and disposable. It is suitable for caches, but it does not isolate
Agents and does not provide durable storage.

## All Workers Must See the Same Agent Files

Every worker in one deployment instance must mount the same `/agents`
filesystem.
A local directory works for one worker. Several workers need shared storage that
supports read and write access from each worker.

Agent Home contains Codex state, Agent documents, user files, installed Skills,
Session workspaces, and Job workspaces. PostgreSQL records when those resources
exist and how Ankole uses them.

WorkerPool keeps one Agent's live work on one worker. It selects that worker
with the Agent UID. New work waits when the selected worker has no capacity.

This placement choice can disappear after a restart. It is not a filesystem
lock and cannot guarantee one execution. A database turn fence rejects an old
worker when two executions overlap.

The control plane does not scan shared storage to discover business data.
Workers report file and Skill changes through explicit protocols.

## Sessions Separate Work, Not All Agent Data

A Session uses the Actor identity `{agent_uid, session_id}` and runs in
`/agents/<agent-key>/sessions/<workspace-id>`. PostgreSQL assigns the stable
model-visible workspace ID from 10000; it does not replace the Actor identity.

Each Session has its own current directory, live processes, and temporary data.
The sandbox also mounts the complete Agent Home, so Sessions for the same Agent
can see shared files, installed Skills, `.codex`, and other same-Agent
workspaces.

Use Sessions to separate current work. Do not use them to hide Agent-owned data
from another Session of the same Agent.

## RuntimeFabric Does Not Store Work

RuntimeFabric carries live traffic through ZeroMQ. This traffic includes turn
control, RPC calls, worker status, flow control, and file data.

ZeroMQ is not a durable queue. PostgreSQL keeps any fact that Ankole must replay,
check, reconcile, or commit after a restart.

`ActorBus` is a name for Actor message behavior. It is not a second transport
API and does not add another set of environment variables.

## Only the Control Plane Commits Business Data

Workers never write AIGateway messages, ActorEvent rows, or provider outbox rows
directly.

AIGateway stores one Response and publishes model events. It does not complete
an ActorEvent or mark a provider delivery as complete.

When its model loop ends, Agent Computer reports the final Response ID.
SignalsGateway checks the turn fence and the Response chain. One database
transaction then completes the ActorEvent and records the final replies.

SignalsGateway does not acknowledge this completion message. If it does not
receive the message, the ActorEvent stays open and the lease can expire. A
terminal Response alone does not prove that the turn completed.

## Provider Delivery Can Repeat

SignalsGateway receives provider events, applies binding rules, starts Agent
work, shows live previews, and sends replies.

A provider acknowledgement confirms only that Ankole received the provider
event. It does not confirm that an Agent replied.

Live previews are temporary. A crash can leave old preview content at the
provider. A terminal model Response does not stop that preview.

Turn completion, an empty result, dead-letter handling, or an explicit stop ends
the preview. The final reply always comes from a stored outbox row.

Ankole can send a provider operation more than once. Adapters use provider
idempotency or reconciliation when available. A visible final reply with an
unknown result retries only inside its attempt budget and carries a
possible-duplicate notice. Other uncertain operations remain
`unknown_after_send`. Every automatic delivery stops at its stored retry limit.

## A Steered Turn Splits Its Record Across Two Events

A `/steer` that reaches the Worker while a Turn runs becomes a separate
ActorEvent. At Turn completion the latest applied steer owns the final reply and
its outbox, so the answer lands under the message the user sent last instead of
the one that opened the Turn.

The AI message stays recorded against the event that opened the Turn, because
that Turn produced it. One Turn therefore writes its record under two
ActorEvents. Neither event alone answers "what did this Turn reply". The
`ai_message_id` on the outbox row is the link, so a reader starts from the
outbox and follows it to the message. A reader that starts from an ActorEvent
and expects both parts under it finds only one of them.

This split is the cost of anchoring the reply where the user is looking. Ankole
accepts it instead of posting the answer under an older message.

## Message Edits and Files Have Provider Limits

SignalsGateway has no common contract for an inbound message edit. An adapter
can report removal only when the provider sends a real removal event.

Removing an older message does not rewrite the complete Response history.
A later turn can receive the removal as a new message event.

File transfer moves files and images for users. It does not keep every past
byte version. An outbound send reads the referenced file as it exists then.

Each provider keeps its own operation and size limits. An adapter must reject
unsupported work instead of pretending that the provider completed it.

## Stateful Responses Use WebSockets

The HTTP Responses endpoint is stateless and rejects stateful fields. Stateful
continuation uses the WebSocket endpoint.

The message graph records where a conversation can continue. A conversation
does not store a second pointer to an active message.

For implicit continuation, one short transaction checks the current visible
leaf, which is the last Response available for continuation. The transaction
then starts the new Response and stores a compaction checkpoint when necessary.

Only one implicit run can start from the current visible leaf. Another caller
receives `response_in_progress`. A caller can set `previous_response_id` to
continue from an earlier Response and create a branch.

AIGateway does not resume half of a provider stream. The live socket updates the
Response that it is generating. A cleanup job marks an abandoned Response as an
error after the grace period.

Automatic compaction uses provider usage already stored with the messages. It
does not guess missing usage from character counts.

Authentication identifies the Principal. Every conversation, message, artifact,
and compaction query also filters by that Principal.

AIGateway stores metadata without interpreting it. It does not inspect
`actor_event_id` or check whether an ActorEvent remains active.

One WebSocket generates one Response at a time. AIGateway rejects
`background=true`. ActorRuntime, not an AIGateway lock, orders Session turns.

`max_tool_calls` limits hosted tools inside one Response. The Agent Computer
iteration limit controls model calls during one worker turn. The two limits
serve different purposes.

## Brain Can Still Store a Wrong Conclusion

Brain stores its records in PostgreSQL. The Markdown from `memory_open` is only
a view of those records.

The saved conversation tells the control plane which Principal and Brain stores
to use. A model cannot expand its access by changing tool arguments. Shared
channels read `shared` and `self`, direct messages also read their `dm:<uid>`
store, and confidential channels can read their `channel:<id>` store. Each
conversation writes only to its default store, except that the Agent can select
its own `self` store.

Brain keeps immutable bytes for a manual file. Pasted text and fetched URL text
become editable entries. A connector-managed document is one read-only shared
mirror of the current source revision, so its stored export can change when the
source changes. Knowledge blocks cite evidence with strict `src:` references.

Dreaming and connector synchronization are the automatic knowledge writers.
The control plane checks access, citations, budgets, locks, mirror ownership,
and requested changes before it commits them. These checks cannot prove that a
conclusion is correct.

The Console status view and `memory_health_check` use the same read-only health
queries. They show observable faults but do not repair knowledge automatically.

## Provider Secrets Stay in the Control Plane

The control plane stores provider details and encrypted secrets. It sends a
worker only a narrower credential when a declared worker capability needs one.

Normal model work receives only an Agent-scoped AIGateway key. The worker keeps
that key in memory.

Do not put live secrets in Agent files, Skill settings, progress updates,
AIGateway requests, or logs.

RuntimeFabric currently assumes private endpoints and trusted workers. It does
not admit public workers or protect traffic on a hostile network.

## Browser State Can Disappear with a Worker

`ankole-browser` runs beside Agent Computer. Agent Computer gives it an opaque
route and prepared connection data. The browser process never calls the control
plane.

One worker supervises one browser daemon. Each route uses a separate local
profile or remote browser session.

Profiles, screenshots, and run files belong to the worker. A daemon can
reconnect to a local browser that still runs. A worker loss removes this state
unless the deployment preserves the browser data directory.

Rendered `web_fetch` uses a temporary route. A Codex Job can keep a route and
reuse login state. Both routes remain inside the worker's trust boundary.

## Long Work Uses BackgroundAgentJob

The model can call only registered tools. Installing a command in the image
does not make that command a model tool.

The `command` tool runs in the foreground. It has a default limit of 180
seconds and no registry for background processes. A caller can choose another
foreground limit.

BackgroundAgentJob handles work that must continue for a long time. The control
plane stores Job state, dispatches work, retries failures, handles cancellation,
and notifies the originating conversation. CodexRunner executes the Job.

A Job has no fixed total duration. Turn leases detect failed executions. A
workflow can steer or stop a Job when it needs a deadline.

Each run uses the Agent Plugin and Skill definitions that are current at that
time. A Job does not keep old package bytes or Skill versions.

Skill discovery combines enabled built-in Skills, Plugin Skills, and installed
Skills. It does not depend on the Control Plane Plugin system.

An enabled MCP-backed Skill calls its selected server through the foreground
`mcporter` CLI. Each call has an explicit time limit and does not create
background work.

## RuntimeEvents Uses One Scheduler per Node

Each control-plane node runs one RuntimeEvents scheduler. PostgreSQL stores
deadlines, and the scheduler creates exact in-memory timers.

Handler tasks run separately, so they do not delay timer bookkeeping. Do not
split the scheduler until measurements show that its timer map or mailbox
limits the system.

## Phoenix and Vite Have Separate Jobs

Phoenix handles routes, authentication, sessions, setup, and the HTML shell.
Vite builds the React applications under `app/webapps`.

`libs/uikit` contains shared UI components. The build generates API clients
from their schemas. Change the schema first, and then regenerate the clients.

## Fast Tests Do Not Prove Live Integrations

The default test suite excludes container, provider, performance, and chaos
end-to-end tests. Run the applicable `tools/e2e/run` mode before you claim that
one of those paths works.

Static review can find a contract mismatch. It cannot prove behavior across a
live worker, provider, database restart, or network failure.

## Features That Ankole Does Not Provide

Ankole currently does not provide:

- public admission for untrusted workers
- a durable ZeroMQ queue
- automatic discovery of business data from worker files
- user-defined SignalsGateway routing rules
- a general workflow engine beyond Schedule and BackgroundAgentJob
- a public OpenAI Conversations object API
- Response delete or cancel endpoints
- named branch views over the AIGateway message graph
- infrastructure isolation for mutually hostile organizations inside one
  deployment instance

A product requirement can change one of these decisions. The change must also
name the owning module, explain how existing data changes, and state how the
team will test it.

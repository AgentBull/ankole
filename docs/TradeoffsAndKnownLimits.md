# Tradeoffs and Known Limits

This page explains what Ankole does not guarantee. Each subsystem design
document describes the related behavior in more detail.

## Tenants Share Site Infrastructure

A site can contain several tenants. Principal, AuthZ, conversation and Brain
queries are restricted to the selected tenant. Missing tenant context fails.
Site administrators can select any tenant's data context.

All tenants trust the site operator and share PostgreSQL, model providers,
Worker providers and the control-plane plugins. Tenant filtering is not a
sandbox for hostile plugins or a substitute for protecting the control plane.
Use separate deployments when organizations cannot share that infrastructure.
See [Tenants](design-docs/Tenants.md).

## A Worker Is One Agent's Computer

Each Agent has its own Worker instance, and Agents never share a
Worker, persistent Home, cache, or credential. The container is the only isolation
boundary: commands, the Codex app-server, Automation scripts, and the browser
run as uid 1000 without an inner sandbox or sudo.

Ankole does not protect a Worker from its own Agent. An Agent can install
user-space software, change its own files, or break its Worker. It cannot
install system packages. The Worker credential stands
for that one Agent only, and the Agent's commands can already read every file
and use every credential of that Agent. A Worker that does not become ready is
rebuilt with a new cache disk after `agent_computer.worker.ready_timeout`.

A Worker container is a trusted, first-party component. Kubernetes can add
gVisor through the Pod template's runtime class. An attacker who controls a
Worker can act as its Agent, but not as another Agent. The control plane that
creates Workers holds the Docker socket or a namespace Role; protect it as a
root-equivalent component.

## Persistent Home and Rebuildable Cache

Agent Home at `/workspace` survives instance deletion and image replacement.
The provider uses a local volume, PVC, R2 backup, Vercel Drive, EFS directory,
AgenticSpace, or OSS prefix.
Codex thread files stay under `/workspace/.codex`; SQLite and process locks
are caches under `/var/cache/ankole`. A rebuild removes the cache after the
old instance is gone. It does not remove Home.

Durability depends on the selected storage. A Docker local volume or a
local-path PVC does not survive loss of its host. Cloudflare saves Home at a
planned stop; a forced platform stop can lose writes after the last backup.
Vercel Drive failure durability and AWS EFS recovery after long MicroVM
suspension still need deployment checks. Real-account checks cover planned
instance replacement, image changes, and short Lambda memory pause. Lambda
storage helpers also need capacity in the account's memory quota. Operators
must back up persistent Home and the control-plane drive. See
[Agent Workers](design-docs/AgentWorkers.md).

Function Compute follows the official Sandbox, NAS, and E2B protocols, but its
AgenticFS and OSS paths still need cloud validation. OSS does not provide full
POSIX semantics. Memory pause and template capture also need an enabled Aliyun
account. ACS remains unavailable until its default hibernation can be shown
to preserve process memory.

The control plane waits for all previous instances, including paused and
terminating ones, to disappear before a new generation. An uncertain create
keeps its generation for retry. Loss of platform access can therefore leave
an Agent waiting; it cannot justify creating a possible second writer.

## Sessions Separate Work, Not All Agent Data

A Session uses the Actor identity `{agent_uid, session_id}` and runs in
`/workspace/sessions/<workspace-id>`. PostgreSQL assigns the stable
model-visible workspace ID from 10000; it does not replace the Actor identity.

Each Session has its own current directory, live processes, and temporary data.
All Sessions of an Agent run on the same Worker and can see its complete Agent
Home, with shared files, installed Skills, and other workspaces of the same
Agent, and the Agent's Codex state.

Use Sessions to separate current work. Do not use them to hide Agent-owned data
from another Session of the same Agent.

## RuntimeFabric Does Not Store Work

RuntimeFabric carries live traffic through one Phoenix Channel per Worker. This
traffic includes turn control, RPC calls, worker status, and flow control.
File bytes move over HTTP through a one-time relay URL.

The worker connection is not a durable queue. PostgreSQL keeps any fact that Ankole must replay,
check, reconcile, or commit after a restart.

`ActorBus` is a name for Actor message behavior. It is not a second transport
API and does not add another set of environment variables.

## Only the Control Plane Commits Business Data

Workers never write AIGateway messages, ActorEvent rows, or provider outbox rows
directly.

AIGateway stores one Response and publishes model events. It does not complete
an ActorEvent or mark a provider delivery as complete.

The control-plane Driver runs the main model loop. Its final transaction
checks the persisted Driver fence, completes the ActorEvents, and records the
final replies. A terminal Response alone does not complete a conversation.
Recovery reads the persisted input and Response tape after a Driver restart.

Codex Jobs run on the Worker. The control plane checks the Job attempt fence
before it commits the Worker's terminal report.

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

A `/steer` that reaches the Driver while a conversation runs becomes a separate
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

## WhatsApp Replies Expire after 24 Hours

Meta closes the WhatsApp customer service window 24 hours after the user's
newest message. Ankole checks that window before every send and stops the reply
with a permanent error instead of calling the Cloud API, so an answer that a
background job or a scheduled push produces after the window never arrives. Only
a paid template message can open a new window, and templates are outside the
adapter's contract. An operator can retry the stopped row from Console after the
user writes again.

The Cloud API also reports a failed delivery asynchronously, after it has
already accepted the send. The outbox row records that send as a success, so
Ankole logs the later failure and cannot repair the delivery by itself. A send
carries no idempotency key and offers no read-back, so an uncertain answer
reports `unknown` and follows the possible-duplicate flow above.

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
`background=true`. The conversation Driver orders Session model requests.

`max_tool_calls` limits hosted tools inside one Response. The conversation Driver
iteration limit controls model calls during one run. The two limits
serve different purposes.

## Compaction Trusts Two Declarations It Cannot Verify

Compaction has one protocol: a request whose input carries a
`compaction_trigger` item. AIGateway answers it on every transport and never
forwards the item alone, so the capability does not depend on a Provider
understanding it. Two decisions under that protocol rest on a declaration
rather than on a fact AIGateway can check.

The first is Provider-native compaction. The `upstream` field of the
`ai_gateway.compaction` settings sends the compaction request to the Provider
instead of writing the summary locally. AIGateway checks the reply before any
of it reaches the caller and falls back to its own summary when the Provider
answers with something else, but that fallback is only possible while the
history holds no Provider-owned compaction state. Once it holds one, only that
same Provider can compact that history: the state is opaque here, and a later
local summary cannot read it. The switch is off by default and is an instance
decision, because the binding it creates outlives the turn that made it.

The second is the `encrypted` tool-parameter marker. A caller declares it, and
every Responses wire forwards it unchanged. Nothing in the marker or its value
says whether the upstream understands it — a client declares it once for a
whole tool set, and the first request is built before any value exists — so
AIGateway does not guess. A Provider that validates against a tool schema it
already knows rejects the request when the marker is removed, which is the
failure that has been observed. A Responses Provider that instead rejects the
marker as unknown would fail rather than fall back; no such Provider has been
seen, and the recovery would be the same shape as the compaction capability
probe. A protocol that cannot express the marker still has it emulated with
AIGateway opaque values, which are encoded, not encrypted, and provide no
secrecy.

## Provider Secrets Stay in the Control Plane

The control plane stores provider details and encrypted secrets. It sends a
worker only a narrower credential when a declared worker capability needs one.

Codex model work receives an Agent-scoped AIGateway key. `AgentCodexRuntime`
keeps it in a private token file under the Agent's Codex Home and refreshes it
for Codex command authentication. The main model loop runs in the control
plane. See [Background Agent Job](design-docs/BackgroundAgentJob.md).

Do not put live secrets in Agent files, Skill settings, progress updates,
AIGateway requests, or logs.

RuntimeFabric currently assumes private endpoints and trusted workers. It does
not admit public workers or protect traffic on a hostile network.

## Offboarding Stops at Ankole's Boundary

Disabling a Human stops new authentication and new work admission in Ankole.
Detection of a provider departure depends on provider events and the periodic
directory sync; a provider outage or an incomplete admission scope delays it,
and manual disablement remains available.

An attempt that passed its start check before the disablement finishes. Ankole
does not interrupt it or recheck the Human between its tool calls.

OIDC Clients receive Back-Channel Logout and can query Introspection, but each
Client applies the result on its own schedule. Ankole sets no end-to-end logout
deadline and cannot report local disablement as proof that every Client has
blocked access.

Ankole does not revoke credentials that it did not issue. A Client's cached
result, a personal provider authorization held outside Ankole, and a Lark CLI
profile that an admitted attempt already selected keep working until their own
expiry. See [Human Offboarding](design-docs/HumanOffboarding.md),
[Browser Sessions](design-docs/BrowserSessions.md), and
[OIDC Server](design-docs/OIDCServer.md).

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

## Durable Wakeups Use Oban

Domain rows in PostgreSQL hold deadlines and completion facts. Their owners
insert Oban jobs in the same transaction. Oban delivers the wakeup; the owner
checks the current domain row before it acts. A periodic Reconciler repairs
lost conversation and Workflow wakeups. Progress in process memory is
reconstructed from input rows and the stored Response chain.

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
- a durable worker message queue
- automatic discovery of business data from worker files
- user-defined SignalsGateway routing rules
- nested Workflows, script changes after a run starts, or a batch-wide Workflow
  token budget
- a public OpenAI Conversations object API
- Response delete or cancel endpoints
- named branch views over the AIGateway message graph
- infrastructure isolation for mutually hostile organizations inside one
  deployment instance

A product requirement can change one of these decisions. The change must also
name the owning module, explain how existing data changes, and state how the
team will test it.

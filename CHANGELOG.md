# Changelog

## Version 2.0.0-alpha.24 (2026-10-25)

- Accept surrounding whitespace in Agent UIDs when binding Automation Jobs,
  queuing runs, and emitting events.

- Add four Pod sharing roles, including record contribution without schema or
  source access. Database pages start with a table, and every page type supports
  child pages. Search includes visible document text.
- Merge Agent document writes, appends, and exact text patches as incremental
  changes. Automation Jobs access Pod through their current authorized attempt.
- Run ESM Applets in identity-bound frames, with Node-compatible backend
  functions, publication environment values, and complete source pull.
  Isolate CPU-bound Applets and stop canceled one-shot programs.
  Deploy the matching Function Runtime image and set its shared internal token.
- Preserve exact Page sharing actions and keep conditional grants separate
  from the Space default role. Use effective actions and valid destinations
  for content controls, moves, copies, and saved work.
- Show child pages from every Page header, including shared private projects.
  Refresh content and permissions when another person changes the workspace
  and when the live connection recovers.
  Keep record drafts and Applet form state through permission changes.
  Keep Applets open when a business operation is denied. Keep authorized root
  creation and movement available when the navigation section is collapsed.
  Prevent browser cache listeners from accumulating across Applet reloads.
- Find documents by their body in command search. Keep search queries when
  users open a result, go Back, or reload.
  Find editable move, copy, and save destinations among read-only search matches.
- Use Applets with view access and check writes against the target data's
  permissions. Read empty attachments as byte arrays. Keep Applet browser
  storage separate for each Principal and Page, with native key and property
  access.
- Build nested module Workers and their media through the Applet project
  build. Present one visible host reload action for Applet failures.

- Collaborate with several people and Agents in one Pod Chat, with explicit
  mentions, Page-based access, personal pins, and shared decision cards.
  Configure Page sharing through the Agent. Set durable standing orders for
  Agents that can intervene in a group room.
- Review saved reasoning and tool steps, manage each Agent's queue and model,
  and use the Chat workspace from a resizable Page Chat panel.
- Keep mention and command completion in the Chat composer, show compact
  queues and current tool activity, and open complete background execution logs.
  Send Page references and quoted messages to the Agent, and honor the group
  setting for unaddressed input when one Agent remains.
- Search earlier Chat history through the existing pager, preserve draft focus
  and quoted text, and order recent rooms by their latest activity.
- Use the Ankole theme for Chat messages, command output, search highlights,
  status indicators, and composer fields.
- Keep room artifacts and unanswered decisions available across history pages.
  Associate interleaved replies with their questions, show each background task
  once, and identify the current Human in Agent input.
- Preserve references in decision answers, recover reference-only edit conflicts,
  and restore colleague mentions when taking back queued input. Keep starter
  suggestions from replacing a draft that the Human has started, and search
  names and Page titles with spaces in active completion.
- Answer decision cards explicitly from the composer with references and files.
  Preserve references when saving messages as Pages. Keep unsaved edits and new
  draft references, and remove deleted Human mentions from edited messages.
  Use recorded Agent targets for edit eligibility and actual tool results for
  live and saved execution status.
- Show queued input once until an Agent starts it, and refresh background-room
  status in the sidebar. Keep the composer focused after sending and code blocks
  stable during streaming. Preserve pin order when settings are saved again and
  restore room titles from their first message or attachment. Show tool failures
  from their execution result.

## Version 2.0.0-alpha.23 (2026-10-23)

- Include Userset grants in Human restoration review and reject approval when
  those grants change. Refresh Page ACL anchors when site administration moves.
- Restore the original Page position on Undo across paginated directories.
  Exclude the full source subtree from move destination search before its limit.
- Keep loaded Console rows visible when the next page fails, with a retry action.
- Apply pinned dependency patches and invalidate each build tree in the control
  plane, core, and standalone plugins, including warm builds.
- Use the shared passwordless authentication core in FOSS and SaaS. Verify real
  email codes through site SMTP, discover active and pending Pods, and bind each
  login method to its tenant Human. Remove local password and SaaS account stores.
- Add Pod administrator settings, invitations, personal login-method changes,
  and self-service exit from unmanaged Pods. Check live Pod login policy and
  protect administrators from policy lockout and last-administrator removal.
- Complete pending Pod invitations through the required verification or SSO.
  Keep the tab's identity when users open account or Pod settings.
- Use recent completed browser verification for personal credential changes
  and permitted Pod exit. Reverification fixes the current tab's member and
  accepts another permitted login source only for that same member.
- Apply login and Guest policy changes to open collaboration channels. Let Pod
  administrators restore suspended members after verified directory recovery
  and permission review.
- Distinguish suspension from offboarding. Offboarding releases personal
  credentials and contacts and prevents old browser proofs from claiming a
  reassigned address. Keep immutable enterprise subjects and work history.
- Carry authentication evidence and interactive Human authority in explicit
  AuthZ Actors. Declare protected Ash actions beside resources and filter Page
  reads through the native anchor authorizer.
- Check retained login credential conflicts before schema or configuration
  migration. Operators must resolve a reported conflict before retrying.
- Match an active member by a verified or directory contact email when a new
  enterprise provider binds that person. Keep their roles, files, and conversations.
- Keep the current Pod signed in after a verified email change. Protect the last
  permitted login method and preserve other open tabs during reauthentication.
- Validate FOSS and SaaS migration addresses before writes. Preserve offline OIDC
  evidence and reject sessions whose original proof cannot be recovered.
- Build the control-plane Torque NIF from source in the release image.

- Add Page-only and container sharing, Page audience rules, lazy directory
  loading, and restricted guest collaboration. Guest access follows the tenant
  setting `pod.allow_external_guests`.
- Use the `site_console:` namespace for Web Console grants and keep Agent
  runtime grants separate. Existing Console grants migrate to explicit
  namespaces. Grant `chat` on `agent:<uid>` and `invoke` on
  `agent:<uid>:tool:<name>` explicitly. An upgrade stops if a rewritten
  condition references `resource`; review those reported grants before retrying.
- Check Page and table access under the operation's database snapshot or row
  lock so concurrent revocation cannot expose newly committed content.
- Keep Human tool grants and Human intersection with Agent Pod permissions
  for Human-derived Workflow, scheduled, and Background Agent Job work.
  Service autonomous work uses Agent permissions.
- Check Guest admission for Pod chat, attachments, Agent catalogs, and live
  event streams. List Trash entries by deletion time after permission checks.
- Keep title filters inside the selected Page list scope. Apply visibility
  before the result limit for favorites and recent Pages.

- Move Pod content and chat, setup, and browser account JSON operations to
  `/api/v2/pod`, `/api/v2/browser/setup`, and `/api/v2/browser`. Update direct callers
  from the generated OpenAPI documents. JSON requests use
  `application/vnd.api+json` and the documented `data` envelope.
- Move native file transfers, Pod event streams, and Applet HTTP routes to
  `/api/v2`. Their media types and streaming protocols stay the same.
- Load every page of Brain lists and object versions in the Console instead
  of stopping at the first 100 records.
- Resolve percent-encoded, case-variant, and UUID target aliases once before
  `/api/v2` permission checks so authorization and execution use the same
  target.
- Keep the caret position and active formatting when typing immediately
  after a keyboard move in the document editor.
- Upgrade bundled Codex to 0.164.0 and match its app-server protocol
  declarations. Upgrade MCPorter to 0.16.0, OfficeCLI to 1.0.158, Lark CLI
  to 1.0.98, kubectl to 1.37.1, and the AWS CLI to 2.38.5. OfficeCLI reports
  a failed save instead of exiting successfully after it drops the edits.
  The Agent OS base database clients are MySQL 9.7.4, PostgreSQL 18.6, and
  ClickHouse 26.9.25.15.

## Version 2.0.0-alpha.22 (2026-10-23)

- Reject a Background Agent Job list cursor from an earlier version. Request
  the first page of the list again.
- Stop a Plugin selection change when the stored `plugins.enabled_ids` value
  cannot be read, instead of replacing it. To recover, remove the value with
  `Ankole.AppConfigure.delete_global_by_key("plugins.enabled_ids")` in a release
  remote console, then select the Plugins again.
- Reduce database timeouts when a Workflow run dispatches or stops hundreds of
  Agent calls.
- Move Console and site administration JSON operations to `/api/v2` and
  `/api/v2/site` through AshJsonApi. This includes configuration, providers and
  credentials, identity and access, Agents, Signals, Jobs, Brain, and Library.
  The moved `/api/v1` routes and their Console OpenAPI document are removed.
  Update external callers from the authenticated v2 OpenAPI documents. Send
  JSON request bodies with `Content-Type: application/vnd.api+json`.
- Use resource documents for v2 resource operations and typed JSON results for
  command and aggregate operations. The OpenAPI documents specify each request
  and response. Paginated resource lists use `page[limit]` and `page[after]`.
  JSON:API errors identify rejected fields and domain failures. Native file
  upload and download, OpenAI-compatible APIs, and authentication protocols keep
  their dedicated routes.
- Set an OIDC Client's `client_type` and `model_aliases` through v2. Create or
  replace an AI Gateway provider with
  `PATCH /api/v2/site/ai-gateway/providers/:provider_id`. Cancel a webhook
  endpoint with `DELETE /api/v2/webhook-endpoints/:id`. Send a manual cron run's
  idempotency key in `data.idempotency_key`.
- Create a Principal with `POST /api/v2/principals`; the one-time password is in
  `meta.initial_password`. Principal records expose `local_credential_status`.
  Worker provider records expose stored credential names in `stored_credentials`.
- Edit Agent Library documents with a content hash to reject stale writes.
  Control Plane Plugin selection shows the active and next-start state.

## Version 2.0.0-alpha.21 (2026-10-23)

- Replace React Router with TanStack Router in the Console and Pod web
  applications.
- Preserve Agent Library edits made during a conflict reload, including when
  that read fails. Ignore obsolete Page recovery responses so a late automatic
  recovery cannot replace edits made after a manual reload.

## Version 2.0.0-alpha.20 (2026-10-22)

- Keep queued Background Agent Jobs waiting while the Agent's Job limit is full,
  even when its Worker is unavailable. Preserve an existing Worker-wait deadline
  until the Worker is observed ready, as Automation Jobs do.
- Wake capacity waiters across an Agent's running Workflows when a task releases
  a slot, including when a failed task queues a retry. Skip Workflows whose own
  concurrency limit is still full.
- Serialize new Workflow and Codex attempt admission with tenant suspension.
  Already admitted attempts retain their completion contract.
- Reject unknown Job status inputs and prevent Job transitions or checkback
  rescheduling from changing ownership, authorization, or creation facts.
- Reject cross-tenant references in identity, work, conversation, Pod, and Brain
  storage. Keep OIDC credentials bound to their original client and login session.
- Keep shared conversation history when an Agent is permanently deleted, and
  clear references to that Agent's deleted Signals.
- Reject malformed durable JSON before committing a tool effect or its receipt.
  Keep private inputs, JSON object keys, and database details out of API and tool
  error responses.
- Show declared validation limits and allowed values in API and tool errors.
  Keep invalid timezone and rule-parser input out of those messages.
- Preserve ordinary Response terminal events through the shared stream loop.
  Keep tool calls rejected by the public budget out of terminal output.
- Reject stale Brain edits, review decisions, and embedding results. Repeated
  review requests keep the first verdict, and late embedding failures cannot
  discard a successfully rebuilt vector.
- Preserve the upstream OIDC authentication time through login. Providers that
  support fresh authentication can satisfy a relying application's forced-login
  request; unsupported providers reject the request explicitly.
- Fix source builds that fail when the dependency cache is empty.

- Function Compute Workers now require the `china-market-ai-providers` Control
  Plane Plugin. Vercel Workers require `vercel-worker-provider`. Select the
  required Plugin IDs before upgrading, then restart the control plane. Saved
  provider configuration, credentials, and Agent storage keep their values.
- Reject Plugin disable while an Agent still uses its Worker providers,
  including paused Workers and pending deletion. New Agent assignments also
  reject a Plugin that is disabled for the next start.
- Use the Control Plane Plugin controls to change Plugin selection. The
  `plugins.enabled_ids` entry is read-only in general Console settings.
- Return HTTP 503 `applet_busy` when all four Pod Applet runtime slots
  are busy instead of panicking in the native isolate pool.
- Validate Background Agent Job status transitions by action across control-plane
  and Worker writes, bound Worker unavailability waits by `ready_timeout_ms`, and
  wake a deferred Job immediately when its Worker becomes ready.
- Reject unknown terminal reply presentation states instead of recording them as
  completed, and keep dead-lettered Signals terminal when later completion paths
  run.

- Retry an OIDC refresh within ten seconds after a lost response with the same
  successor token. Later replay revokes the token family and login session.
- Keep quiet group observations outside conversation admission. Only a committed
  intervention starts a conversation turn; repeated observations reuse the
  durable triage result.
- Give Automation Jobs an independent queue and per-Agent concurrency cap. Keep
  the first Worker-wait deadline across infrastructure retries, and end queued
  retries when their Human authorization is revoked.
- Preserve channel card anchors through failed delivery recovery. Workflow task
  activity now distinguishes sleep deadlines from capacity retries.
- Run Workflow scripts asynchronously in the native runtime so slow scripts do
  not occupy BEAM dirty CPU schedulers needed by authorization.
- Stop a replaced Driver when a tool loses its write fence. Deliver authorized
  Human messages to running Jobs under the same lock order as work admission.
- Keep Worker wait retries separate from Signal deadlines. Job admission checks
  the locked queue head and deadline before it can claim an attempt.
- Recheck Agent and tenant availability before ambient classification and commit.
  A model response cannot commit a judgment after its observation expires.
- Cancel native program tasks when their owning process exits, including forced
  exits. Cron edits, manual runs, fires, and final failure history lock their
  Automation Job consumer before the rule.
- Keep private action and request data out of unexpected Console, tool, and Job
  Driver error logs.
- Treat a killed Worker connection as a lost route without repeating its request.
- Clear unfinished workspace acquisition when a recovered tool round commits,
  so the next tool round can use the ready Worker after a control-plane restart.
- Release a recovered workspace when the model finishes before workspace
  preparation completes. Pure text turns still send no Worker messages.
- Preserve the error stage in hosted image streams. Provider access rejections
  no longer enter capacity retry; rate limits and timeouts stay retryable.

## Version 2.0.0-alpha.19 (2026-10-21)

- Let Background Agent Job threads call the Brain `recall` and `get_page`
  tools. The Worker now serves them through the same read-tool bridge as
  `skill_view`, and a Job no longer declares the hosted Brain tool, so one tool
  name has one executor.
- Give spawned Job support threads the same local tools as the lead thread
  (`skill_view`, `web_search`, `web_fetch`, `request_parent_input`), and wait
  on them for ten minutes by default instead of two.
- Record the full brief of `spawn_agent` and `followup_task` calls in the Job
  trajectory, with the source the Worker read it from.
- List files that a Job wrote through the shell in `files_changed`, not only
  the files the Codex diff reported.
- Attribute every AI Gateway usage record of a Background Agent Job to its
  `job_id`, attempt, Signal, and Session, and show the Job identity on the
  response trace.
- Keep the workspace template and the other inherited fields when a Job
  respawns or a steer continues it, and show `continued_from_job_id` and
  `workspace_owner_job_id` in the Console Job projection.
- Resolve an expired Brain take when dreaming grades it, store `until_date` as
  a date, and report a missing dreaming model in the Brain health status.
- Resolve the Lark bot identity once per application with a cached result and
  a rate-limit backoff instead of on every connection reconciliation, and log
  an unchanged reconciliation error set once with its repeat count instead of
  on every cycle.
- Run the Agent Computer, kernel lint, shared library, and repository lint
  checks in CI, enable the default Credo check set, and build runtime images
  only after the repository checks pass on `main`.

## Version 2.0.0-alpha.18 (2026-10-21)

- Send `strict: false` for Session function tool declarations that do not opt
  in. The Responses API treats a missing `strict` as strict and made the model
  fill every optional parameter, so a configured custom model profile was
  forced on every Background Agent Job.
- Add the hosted Brain declaration of a Codex Job to the tool list that the
  Codex client carries in its `additional_tools` input item. A top-level entry
  stayed unsplit and failed every Job turn on a Responses provider with
  `Unsupported tool type: brain`.
- Restore local sign-in pages on `ankole.localhost` and tenant hosts when the
  development server runs the FOSS edition.

## Version 2.0.0-alpha.17 (2026-10-21)

- Stop a replaced Job attempt and release its Codex thread before the next
  attempt resumes, also on a Worker with no free slot. Retain execution
  through temporary connection failures.
- When the provider omits the message phase, keep the last lead message as the
  Job result only until the lead thread starts more work.
- Tell the Agent to omit `model_profile` on `create_background_job` and
  `workflow` unless the human names a custom profile, and name the default as
  the Agent's standard model.
- Accept the OpenRouter `provider` routing preference as a request-scoped
  provider option.

## Version 2.0.0-alpha.16 (2026-10-21)

- Internal changes only.

## Version 2.0.0-alpha.15 (2026-10-20)

- Sync the block editor engine with Wordgard through `83844a0`. Double-click
  and triple-click selections extend toward either side. Decorations can
  override how marks render. A state with no custom key bindings keeps the
  default keymap. Point lookups, decoration updates from several sources, and
  caret positions at the edges of bidirectional text blocks are fixed.
- Translate Pod editor menus, toolbars, prompts, and accessible names through
  the shared locale catalogs. Changing labels preserves the document and undo
  history.
- Notify new table subscribers when access was already revoked. Release an
  attachment cell's edit snapshot after an upload failure so the next edit can
  use current field versions. Failed saves retain their explicit retry path.
- Keep LINE quote and Telegram reaction lookup failures retryable instead of
  accepting an incorrect classification or channel. Log unexpected context,
  replay recovery, and cancellation failures without exception messages or
  function arguments.

- Use one tenant admission check for Pod hosts and login. Suspended, deleting,
  and missing tenants remain unavailable; maintenance and slug ownership checks
  still see existing tenants.

- Share the Mint WebSocket connection and the single-key token fetch across
  provider clients. Each provider keeps its frames, acknowledgements, reconnect
  timing, and token request. Discord uses the shared connection. A bad Discord
  gateway URL reports `:invalid_websocket_url`.

- Keep local browser connections on validated IP addresses, including page
  resources, redirects, and WebSockets. Cloud metadata stays blocked when
  intranet access is enabled. Custom Chromium proxy arguments now fail; Ankole
  manages that proxy. Remote browser providers still own their connection policy.

- Browser snapshots now use Playwright's AI snapshot. Refs such as `@e2` and
  iframe refs such as `@f1e3` come from that snapshot. A missing or detached
  ref still returns `stale_ref`. Interactive snapshots keep controls visible
  when long static text would fill the output budget.
  Selector snapshots use the remaining command deadline instead of waiting
  without a Playwright timeout.

- Edit Brain page tags in the Console. Tags take part in concurrent edit checks
  and version records. Each tag has its own field, so embedded line breaks stay
  inside the tag. Reload an open tagged page after this upgrade.
- Refresh derived Brain links and timeline work after page edits. Markdown and
  alias links no longer require a Dreaming model; the upgrade schedules one
  model-free link rebuild and preserves completed timeline work.
  Tag and metadata edits retain completed extraction work; pending body or
  title changes still require extraction.
- Keep Pod navigation consistent with page permissions for conditional and
  wildcard grants. Evaluate large page trees with one authorization snapshot.
  Show invalid audience markup in the editor preview.
- Preserve cached and reasoning token details in stored compaction responses.
  Retain an explicit total token count of zero from the Provider.
  Return normal upload errors when a Worker transfer fails during streaming.
- Return field validation for a blank Worker provider selection and keep
  internal identity mapping errors out of Console responses. A concurrent token
  refresh survives cleanup by a reader that saw an older expired token.
- Use packaged application fonts without a public font service. Reject
  Automation Job IDs below 1000 at the API boundary and show blank schedule
  fields as validation errors.
- Include private SaaS frontend utility styles in packaged assets.
- Run the one-time Agent Home drive import with
  `Ankole.Upgrade202610.import_agent_home("/agents")`.
- Reject non-Agent Principals in Pod Space Agent grants, skip deleted
  conversations during Brain slice finalization, normalize Agent directory paths
  before changing ownership, and keep non-absent Telegram preview deletion
  errors visible.

## Version 2.0.0-alpha.14 (2026-10-20)

- Make each control-plane Plugin a local Mix project and place each provider
  client in its matching IM Plugin. Keep one release, Repo, and migration ledger.
  Share matching HTTP and WebSocket primitives without changing provider error,
  response, token, or reconnect behavior. Keep the Feishu frame codec separate
  so the fake platform does not load the control plane.
- Fix Control Plane image builds by including the Worker source used by Webapps
  type checks.
- Remove Control Plane compile-connected cycles by separating pure domain
  declarations from business modules. Publish committed conversation and Session
  changes through their own PubSub contracts, with durable input and delivery
  recovery unchanged. Reject new compile-connected cycles in repository checks.
- Remove Pod sync bindings. The upgrade keeps imported records and removes
  sync metadata.
- Remove Automation Job definition expiry. The upgrade changes expired
  definitions to cancelled so they cannot become active again.
- Redesign the Pod sidebar. Search is a field at the top, Home and Chat stay
  as tabs, and the current page has an ink mark. Drag a page before, after, or
  into another page, or onto the Space or Private heading. A right-click or
  the row's "…" button opens page actions, including rename in place and move
  up or down. Each move and each move to Trash shows an undo action.
- Add an account menu at the bottom of the sidebar. It lists every
  organization that this browser is signed in to, switches between them,
  opens the account chooser, sets the theme, and signs out. A site
  administrator also gets a link to the Site Console.
- Return OfficeCLI screenshot failures in resident mode. Require a fresh PNG
  before replacing output, and retain existing images when capture fails.
- Keep build proxy settings out of the Worker startup environment.
- Keep one pending Checkback wake when its due time changes after 60 seconds.
- Preserve empty and whitespace Workflow results. Check current Human access
  before each replay, cancel pending calls after revocation, and retain results
  from calls admitted before revocation.
- Preserve Unicode characters at the rendered browser text limit. Reject
  invalid Unicode in rendered page text or titles before reporting success.
- Ignore old environment decryption responses after save, clear or remasking.
  Keep replacement values that the operator has edited.
- Accept binary media types for AI Gateway file content downloads. Retain
  token and origin checks and JSON negotiation for other gateway routes.

## Version 2.0.0-alpha.13 (2026-10-19)

- Fix Control Plane image builds that failed because the Applet SDK and Block
  Editor workspaces were missing during dependency installation.

## Version 2.0.0-alpha.12 (2026-10-19)

- Keep every local document draft after repeated external resets, protect
  navigation until each retained draft is handled, and keep an uploading
  Database row mounted when it leaves the viewport. Carry removed message IDs
  across loaded Chat history so a stale response cannot restore deleted text.
- Apply Console save and reveal results to the submitted draft and source.
  Keep later edits dirty, and prevent a late delete response from changing the
  next route. Freeze pending Setup and login controls, and restore the saved
  industry-pack selection when returning to an earlier Setup step.
- Use one caller deadline for automation preparation and execution. Stop the
  command group before removing its files, and do not replay an attempt whose
  execution result is unknown. Keep a browser profile when its saved CDP
  endpoint fails, and signal only a process owned by a live child handle.
- Serialize permission-grant writes and page moves with the tenant tree lock.
  Remove the global grant table lock. Normalize Principal and record IDs before
  cell validation, reuse reverse-field definitions within a Database write,
  and remove per-record reads from sync batches that have no reverse links.
- Expire configuration cache entries after five seconds, initialize a
  generated global value atomically, and reject unavailable default locales
  before storage. Start with the release locale when an older stored default
  is unavailable. Remove test reset and fault handlers from production builds.
- Serialize Graph subscription creation, recovery and deletion for each
  provider. Save the creation secret before the remote request, check remote
  state during recovery, and process disabled providers through the same owner.
  Link Telegram polling tasks to one bot owner across connected nodes, and
  reject stale Feishu SDK token-refresh results.
- Limit concurrent native Applet runs and retained WebSocket output. Accept
  successful CONNECT status codes throughout the 2xx range and parse SSE BOMs
  and CR, LF and CRLF line endings across chunk boundaries. Include shared
  editor, Applet SDK and browser sources in architecture checks and resolve
  runtime imports through workspace exports.
- Limit built-in Database views to records browsers: grid, kanban, and gallery.
  Remove calendar, gantt, and form view types, their presentation code and saved
  configuration fields, and the form submission path. Calendar, timeline, form,
  and chart presentations belong to Applets. The view contract and database
  constraint accept only the three built-in types, and an inline embed with a
  removed type offers repair to grid.
- Read Page content and revision under one lock, bound replay to that revision,
  and submit pending edits after an earlier request is confirmed by broadcast
  but its transport fails. Initialize Space authority only during tenant creation;
  keep permission reads from restoring removed grants and protect grant deletion.
- Require matching schema and record versions for local Database queries. Compile
  shared dependencies once per requested formula, with conditional evaluation.
  Keep copied formulas on copied fields and freeze linked-record choices without
  changing UUID-valued business text.
- Embed Applet images, fonts, and media in build output. Retry a publication that
  removes a requested file without treating that change as lost page access.
  Validate inline view configuration before rendering.
- Centralize Chat command rules and reading-position effects. Keep a new draft
  separate from an unfinished Chat creation, retain its recovery and retry IDs,
  and prevent late request results from changing a newer send. Make Pod user-flow
  checks use the production wake path, verify saved facts and formula behavior,
  and save and reload a real Human edit to an Agent-created research Page.
- Add optional Applet backend routes, built and published with the frontend
  under one Page revision. Run each call in a fresh native V8 isolate with
  caller-authorized Database and file capabilities, configured Agent model
  profiles, cancellation, and time and memory limits. Add SDK route hooks and
  Agent build, publish, and call commands. Reject invalid backend packages
  before publication, and reload a stale frontend without replaying its write.
  Cancel an older page read before fetching a changed Applet revision so a
  delayed response cannot leave the Applet loading.
- Keep embedded Applet text and controls consistent with their full-page view.
  Document typography stops at embedded objects. Reject imports that the host
  cannot provide during build, and let users restart an Applet after a render
  failure without reloading the Pod.
- Keep saved work during Agent Job continuation. Describe the missing outcome
  and reuse existing object IDs instead of treating an incomplete report as
  evidence that no work was saved.
- Check the retained Human authorization before a Session retry, keep activity
  available during reply completion and late preview recovery, and preserve
  newer Applet data after a failed write. Keep pending edits visible without
  changing confirmed records.
- Reduce repeated Pod authentication and page ancestry reads. Check Drive path
  conflicts without loading the complete drive, notify other tabs when a copied
  table adds a Page, and share the sandboxed file download policy. Close a
  document channel when a rejected request confirms lost viewing access. Keep
  access and revision errors ahead of invalid XML in complete document writes.
- Unify Pod navigation and references with one Page type icon, neutral ordinary
  actions, and compact desktop lists. Open the same search and navigation menu
  from the sidebar or Command/Control+K. Keep drafts when opening a new Chat,
  and support J/K navigation in content lists without taking keys from fields.
- Keep view draft feedback flat on the work surface.
- Keep file selection, replacement, and download above the preview. Retain a
  failed selection and reset preview selection after a replacement. Keep mobile
  Chat exit transitions without reopening a closed panel on send completion.
  Make frequent menus immediate, and honor reduced motion for overlays and Chat
  scrolling.
- Explain lost tool-call arguments in provider replay without changing stored
  calls, results, or media parts.
- Keep Pod message history, pending inputs, and execution status consistent
  when a reply finishes during a detail read.
- Check DNS answers for Feishu Markdown image downloads and connect to a
  checked IP with the original HTTPS hostname. Keep intranet access under the
  existing setting and reject cloud metadata targets through DNS and redirects.
- Add durable Pod pages with space and Private navigation, sharing, search,
  favorites, trash, restore, and file previews. Save Conversation text and
  attachments as pages, retain their origins, and keep saved content after a
  Conversation is deleted. Agents use the same page permissions through the
  new `ankole-pod` CLI. Private creation and moves wait for the current Human's
  identity before they can submit. Let editors move Pages when access to the
  Page and its subpages stays unchanged; require full access for moves that can
  change permissions.
- Align Pod page and Database interactions with Notion where the content model
  permits. Keep failed title, cell, form, and view drafts; require explicit
  conflict recovery and shared-view saves. Confirm permanent record and field
  deletion, filter move destinations by actual roles, append new fields and views
  in creation order, and search trash. Freeze pending uploads
  and dialogs, and distinguish temporary realtime failures from access denial.
  Use searchable page pickers, compact forms with Enter submission, and anchored
  property pickers. Keep long dialog actions visible while their bodies scroll.
- Open Pods on their slug subdomain, including `<slug>.ankole.localhost` in local
  development. Use Kernel short UUIDs in Page and Conversation links, with no
  tenant query or `/pod` prefix. Share the browser's logged-in accounts across
  Pod subdomains and allow switching between authorized identities while
  retaining each open document's selected identity.
- Use a single document canvas, compact page actions, and a responsive Page Chat
  panel while retaining Ankole's design tokens and component styles. Keep rapid
  Chat switches and their input in the same committed navigation, and open the
  mobile Chat panel before its message content loads. Make document
  block actions available by touch, keep sharing and table filters beside their
  controls, and keep search aliases out of menu labels.
- Add live document editing with canonical XML validation, operational
  transforms, missed-change recovery, and recoverable drafts after a whole-page
  replacement. Inline Database and applet pages keep their own identity when
  a document reference is removed.
- Add Page-linked Chats that reopen in either the page panel or Conversation
  view with the same current Page. Keep unsent messages and pending sends when
  closing the panel or navigating, warn before unloading a draft, and allow
  copying local input after page access is revoked or a Chat is deleted elsewhere.
  Keep acknowledged messages visible during delayed or failed refreshes.
- Give Pod Chats a Notion AI layout with native steer and editable, reorderable
  message queues. Stop pauses pending inputs across refreshes; Continue resumes
  them and Send now releases one selected input. Reject stale concurrent queue
  edits. Support last-turn editing and regeneration through the real retry
  mechanism, retaining changes already made to Pages, Databases, and applets.
  Copy whole messages or exact code, and load earlier history without losing
  the reading position. Restore the visible message when returning to a Chat,
  with separate positions for the Page panel and Conversation view.
- Upload, paste, or drop Chat attachments with recoverable local drafts, stable
  send retries, and frozen message downloads. Keep incoming file paths separate
  for each message. Preview images and text in the same Chat, retain keyboard
  focus and unsent input, and keep the original download and new-tab actions.
  Limit preview reads and cancel them when the preview closes.
  Let a Chat select an authorized model profile for subsequent
  replies, retaining the model already captured by active and queued inputs.
- Default native Pod research and document requests to editable Pages in both
  main Agent and Background Agent Job instructions. Research Skills keep explicit
  user format requests and deliver saved Page links by default. Keep the original
  Chat source when a completion wake or continued Job creates more Pages.
  Verify each applet action's complete write and saved result, including naming
  fields, and check research examples' numeric conclusions in the delivered body.
- Carry the consumed native Human request separately from a delegated Job task.
  Retain that input version across completion wakes, continuations, and recovery;
  applied Human steers update execution intent without changing Page provenance.
  Editing a previous message creates a new retry input without rewriting the
  original consumed Signal. Scope Job completion and verification instructions
  to Agent-assigned work, leaving Human-reserved interactions for the Human.
- Fix reopening documents with a saved slash query, hide the slash menu when
  the editor loses focus, and apply typed table filters directly without an
  extra focus change. Show the actual parent title in page navigation.
- Load Pod views and the applet runtime on demand, index the page tree once,
  and emit compressed production text assets for the existing static server.
  Fetch the current Page alongside its view and load only Pod and shared
  translations at startup, retaining complete catalogs for other applications.
  Keep page-tree folding choices across remounts, reloads, and same-identity tabs,
  separately for each Pod and document identity.
- Add typed business tables, formulas, field-level edit conflicts, three
  built-in views, filters, statistics, and independent report copies. Humans and Agents query
  and edit the same tables through their own permissions. Runtime limits are
  configurable; there is no per-tenant query concurrency limit. Permanent Agent
  deletion keeps synchronized records and releases their fields for local edits.
- Add React applets with the shared Pod SDK, components, live data, presence,
  atomic publication, and revision replacement. Applet initialization accepts
  existing empty directories and preserves nonempty ones. Mount applets inside
  their documented CSS scope and guide standard controls to the host UIKit.
  Generalize Agent file
  references to include a tenant Pod drive, reuse stored bytes, and remove page
  and table data in batches during purge and tenant deletion.
- Keep Background Agent Job final reports separate from runtime commentary and
  partial answers. Use the existing report retry when a Turn has no final report.
  Compare Job reports with the user's overall goal and continue specific missing
  work before claiming completion, reusing reported verification.
- Shorten the coding-agent guidelines to authorization, contracts, and
  repository boundaries. Commands, layout, and architecture stay in the
  owning files.

## Version 2.0.0-alpha.11 (2026-10-19)

- Return OIDC token authentication errors with the implemented Basic challenge;
  reject unsupported authentication schemes without consuming credentials.
  Reject refresh scopes without `openid` before consuming the credential;
  retain valid scope reduction and the original absolute expiry.
- Keep person and OIDC Client drafts with their current editor source. Freeze
  fields during saves, read fresh Client details before reopening, and ignore
  old responses after navigation or a source change.
- Accept standing orders of up to 4,000 characters, including Chinese text and
  emoji. Return ISO 8601 timestamps when operators read, save, or clear them.
- Reject operator deletion of directory, chat, and signal source groups.
  Retain their memberships and external bindings.
- Keep forgotten Brain pages and timelines out of model reads while retaining
  management history and recovery. Count distinct pages for promotion
  thresholds and keep Human Principal pages at their canonical paths.
- Keep development connection reconcilers running while Phoenix recompiles
  their modules. Restart the development server once after this update.

## Version 2.0.0-alpha.10 (2026-10-18)

- Request Worker startup when an Agent is created, retain the request until
  the Worker connects, and cancel startup when the Agent is deleted. Expire
  stale restored connections without changing the Worker generation or Home.
  Resume pending tool calls after Worker replacement; report an interrupted
  result for an unsafe operation whose outcome is unknown.
- Use compatible published control-plane and PostgreSQL images in Docker
  Compose and Helm. Check existing image overrides before an upgrade: an old
  control-plane image can fail with newer database extensions. Use UTF8 for
  new databases in Compose, bundled Helm PostgreSQL, the source initializer,
  and devkit database creation. Existing databases keep their encoding and
  need a separate backup, encoding conversion, and restore.
- Accept Azure OpenAI v1 endpoints on Foundry resource hosts. Send Chat output
  limits as `max_completion_tokens`; for an older model, set
  `maxTokensParameter` to `max_tokens` in its model profile. Keep Telegram and
  Discord previews on the provider thread.
- Keep password lockout counters consistent with credential timestamps and
  password resets. Reject malformed logout parameters, handle an unparsed
  CSRF request body, and correct OAuth token errors. Redact URL-encoded signal
  capability tokens, reject unknown Brain configuration fields, and preserve
  quota-period precision when only the limit changes.
- Preserve Console drafts and saved values across delayed requests and editor
  reopening. Validate schedule names, tenant slugs, and declared numeric
  bounds; preserve unchanged interval schedules and one pending cron job
  across pause and resume. Correct Brain audience previews, Pod selection,
  Webhook creation results, menu navigation, and upload-dialog actions. Hide
  revealed environment values after save or clear, and keep validation notices
  visible without blocking dialog actions.
- Enforce exact file scopes in find and grep, and preserve Unicode characters
  when clipping results. Wait for Notebook reply and idle messages in either
  order. Let OfficeCLI use the installed Chromium, verify screenshot output,
  and correct Office file-editing guidance. Add behavioral regressions and
  missing test dependencies; keep browser, image, upgrade, and Driver recovery
  checks outside the default fast suites.

## Version 2.0.0-alpha.9 (2026-10-17)

- Add the private SaaS account flow: email sign-in, independent accounts that
  can share an email, Pod creation, verified identity connections, account
  selection, and separate sign-out. SaaS deployments must set
  `ANKOLE_SAAS_DOMAIN`, run their migrations, and configure `saas.email.mail`.
- Send site login codes through Bamboo and verified SMTP TLS. Keep earlier
  codes valid after resends, consume each code once, and update protection
  counters atomically during concurrent cleanup. Keep clear retry results
  and encrypted transport settings.
- Route SaaS console and Pod hosts from one bootstrap domain. Use one-use
  handoffs and independent host cookies, retain pinned page identities, and
  reuse the existing OIDC Client policy and Human access checks. Keep file
  relay URLs on the issuing node, with one-time token checks before browser
  host admission.
- Require explicit Console login admission for site authentication. Keep
  siteadmin checks and FOSS single-host behavior. Load edition runtime
  settings from the compiled configuration owner.

## Version 2.0.0-alpha.8 (2026-10-16)

- Rename Workplace to Pod and let active Human members sign in and work
  without site administration access. Keep each open page bound to its
  authenticated identity and tenant.
- Store independent browser authentications and add OIDC account selection.
  Keep per-identity sign-out separate from browser-wide sign-out. Late login
  responses and RP logout delivery leave accounts signed in after logout usable.
  Validate each pinned request without scanning other accounts. Existing
  browser sessions must sign in again after the migration.
- Build FOSS and SaaS from separate source and asset sets in one Mix
  application. Package the selected locales and migration directories in
  each release, with one Repo and migration ledger. Support concurrent frontend
  preparation and check private TypeScript through the same lint entry. Keep
  build fixtures outside normal test discovery.
- Keep message input revision calculations in Conversations while preserving
  queued and in-flight execution, attachment waiting, and recovery behavior.
- Preserve shipped knowledge after an incomplete inventory read and keep
  independent sets synchronizing. Remove unused lesson text rewriting and
  share the blob collector's live-reference rule between both delete phases.
- Keep save results within the initiating Console editor. Include metadata in
  Brain edit conflicts, reject ordinary writes to deleted pages until restore,
  and reject writes through replaced or disposed block-editor sessions.
- Migrate site administration from a mutable tenant slug to its stable ID,
  and run browser retention once after all tenants' OIDC cleanup.
- Show current Session phases and tool activity in Pod, including late
  joins and reconnects. Add per-Agent background activity to Console with
  separate Job, Workflow, and Automation states, permissions, and pagination.
- Preserve profile fields and department access when enterprise login returns
  a partial observation. Keep unread conversation input after compaction and
  deliver scheduled replies to every eligible native or external target.
- Prepare generated image bytes outside the final Session transaction, retain
  fenced recovery and atomic reply references, and clean up Workflow tasks only
  after commit. Correlate Signal, model, Worker, and delivery stages through
  existing diagnostic identities.
- Return attachment task admission errors for provider retry. Consolidate
  attachment storage and native activity display in their existing owners,
  share image ID validation, and separate foreground commands from exact-byte reads.
- Consolidate queue reads, recovery fields, RPC declarations, and private HTTP
  clients; remove unused production APIs and CLI wrappers. Split provider UI,
  Console schemas, and Rust protocol code by responsibility, and preserve edits
  and navigation when earlier requests complete after the page changes.
- Sync the block editor engine with Wordgard through `d1acec0`. A slice carries
  its context, a change set stores tokens, isolating blocks stay closed, and a
  content height change keeps the cursor in place. Preserve strikethrough when
  Markdown export places punctuation or a tag before adjacent text.
- End foreground command groups before returning and report gaps in retained
  command output. Enforce JSON-RPC byte limits and shared CLI request bounds
  without shortening running operations. Keep fast retry completions from
  leaving Background Jobs running, and deduplicate repeated terminal events.
  Clarify the deployed scope and DNS exception of the optional Worker network
  policy.
- Upgrade bundled Codex to 0.163.0 and match its app-server protocol
  declarations to that version. Install Codex, MCPorter, OfficeCLI, Typst,
  kubectl, and the AWS CLI in the Worker image. Local builds use the pinned
  Agent OS base when `Dockerfile.base` matches it, and build that recipe
  locally when it does not.

## Version 2.0.0-alpha.7 (2026-10-16)

- Let the external-conversation migration run as long as the site's data
  needs: it clears the server statement timeout for its transaction, its raw
  queries no longer use the Repo request timeout, the temporary maps are
  analyzed, and the message and read-mark lookups join `signals` by uuid
  instead of by text, which a 1.x site with tens of thousands of Signals could
  not complete.

## Version 2.0.0-alpha.6 (2026-10-16)

- Set the TLS provider before native I/O starts, so model WebSocket calls work
  when OpenDAL and HTTP clients enable different crypto providers. Report
  native stream panics to the caller instead of leaving the Response open.
- Start the `outbox` queue used by Delivery jobs, so final replies and files
  reach external conversations and pending deliveries resume after restart.
- Keep the public Helm tests independent of private deployment assets.

## Version 2.0.0-alpha.5 (2026-10-16)

- Route every stimulus through `Signals` with one durable intake, source
  deduplication, authorization snapshots, and committed Driver wakeups. Keep
  private kernel provenance separate from external CloudEvents data.
  Reject a route move when the destination already has an enabled route with
  the same name, including CloudEvents routes.
- Store external rooms as shared Conversations. Agents in one room keep
  separate Sessions and model state while reading the same messages and
  standing orders. Migrate history, files, Brain sources, and delivery records
  without copying a room for each Agent. Degrade a removed intervention anchor
  while preserving its judgment and each Agent's progress.
  Share deletion guards across observers so delayed input cannot restore a
  withdrawn message through another Agent or binding.
- Let cron reports appear in native conversations and read new statements from
  the current model branch. Replay completed model history exactly as stored.
  Background edits leave a running turn unchanged; withdrawal of only its read
  background stops it with a context-withdrawn notice. Explicit source withdrawal
  keeps its existing cancellation behavior.
- Preserve pending interactions for undeclared Signal types, including external
  CloudEvents types. Rename provider removal to `conversation.message.removed`
  and migrate stored Signals. Move preview recovery state to Delivery-owned
  records and use one native/external statement operation.
- Replace SignalsGateway with Conversation observation and Delivery contracts
  across all ten channel plugins. Document the final architecture and the
  source-backed comparison with deepseek-harness, pi durable, and qm in all
  four website languages.
- After sign-in, Ankole opens the new Workplace at `/workplace`: an empty
  frame with Home and Chat sidebar tabs. The Workplace has no Console link;
  open the Console at its configured path. First-time setup still opens the
  Console. `ANKOLE_SITE_ADMIN_CONSOLE_PATH` cannot start with `/workplace`.
  Signing out from either app clears the browser's selected data tenant.
- Bring the shared uikit sidebar to the design language and add tabs whose
  active tab is a paper control.
- Keep Console drafts and saved values correct when decryption, saving, or
  restore finishes after an edit or selection change. Preserve unsent WeCom
  text across stream rollover, and compact the Response branch the caller
  selected.
- Keep Session finalization in Run and bind rendered fetch during Worker
  execution preparation. Share workspace locking in Fence and the raw-history
  rule for local compaction. Remove unused gateway wrappers and restrict
  internal compaction interfaces. Make native compaction checks reject local
  fallback.
- Rename the execution runtime to `Sessions`, including its progress and
  tool-receipt tables and saved Oban worker names. The upgrade keeps stored
  progress, receipts, and queued work. Stop old control-plane replicas before
  the upgrade.
- Chat with active Agents in Workplace. Replies appear as they are generated,
  and committed messages remain after a page reload. Retries with the same
  message ID do not add a second message. Disabling an Agent keeps its chats
  read-only; deleting the disabled Agent also deletes its native chats.
- Remove source comments that restate the following code, explain ordinary
  language behavior, or spell out a workaround. Comments that state a
  constraint held outside the local code stay.

## Version 2.0.0-alpha.4 (2026-10-15)

- Allow 2 ms of rounding in the native Retry-After timing test.

## Version 2.0.0-alpha.3 (2026-10-14)

- Start Workers when environment tools or Jobs need them. Agent creation and
  pure conversations do not start a Worker. Keep a Worker join from being lost
  when an earlier readiness query is still in progress.
- Let operators set the Vercel Sandbox lifetime within their account limit.
  Keep each saved instance's lifetime and fix site-level cloud instance lookup.
- Include OSSFS2 and FUSE3 in the amd64 Worker image. Keep Home empty before
  mounting storage and keep build caches out of the image's Home directory.
  Pin local Worker builds to the verified Agent OS base.
  Reconnect OSSFS2 after Aliyun memory resume to prevent reads from waiting
  on unusable TCP connections; a failed reconnection ends the instance so the
  next reconciliation rebuilds it from Home.
- Limit Agent owners to Humans and explain when no owner is available. Repair
  lifecycle and conversation test fixtures, and update verification limits
  and provider setup guidance. Record the reviewed site-level Worker queries.
- Add Agent drive storage through Azure Blob, D1, COS, PostgreSQL, OSS, TOS,
  GCS, SFTP, and WebDAV. Configure the backend at control-plane startup. D1
  and PostgreSQL need an existing storage table; D1 retains its row size limit.
- Upgrade bundled Codex to 0.162.1, MCPorter to 0.14.3, and OfficeCLI to 1.0.157.
  Update the Codex app-server protocol declarations to match the bundled version.
- Use official overseas PostgreSQL repositories for the database image. Install
  the pgvector package without its optional LLVM JIT package.
- Run CEL parsing and evaluation on a larger native stack at the NIF boundary.
  Complex filters no longer exhaust the BEAM dirty CPU scheduler stack.
- Remove the Worker read-tool import cycle and unused AIGateway fetch code.
- Use a local model catalog in the image validation test and remove unused
  fixture providers after file concurrency tests.
- Complete image pair verification and release publication when a workflow
  retry reuses existing images and skips their build jobs.

## Version 2.0.0-alpha.2 (2026-10-12)

- Preserve scheduled replies when a model ends with nonempty ordinary text.
  Silent success still requires the permitted termination tool. Keep legacy
  Agent opening-memory claims and non-prefix OIDC memory order during upgrade.
- Remove obsolete AIGateway forwarding functions. Give conversation run types
  one checked contract with defaults and declare run visibility on each tool.
  Separate Driver trace completion and model deadlines, and native proxy I/O.
- Remove unused Worker and editor code and test fixtures for retired features.
  Check tenant joins against the pinned Ecto adapter and use persisted facts
  and operation telemetry in Driver integration tests.

- Move Worker Providers to the top-level Console navigation beside LLM Providers.
  Update provider editor, Agent, Worker, and readiness links to the new route.
- Add website guides in all four languages for upgrading from 1.x to 2.0,
  WorkerProvider limits and cache disks, and OpenDAL drive storage with local
  folders, S3, and R2. Correct the documented Worker idle-release default.
- Keep caller metadata local at one native provider boundary. Pass model
  profiles through local Response options outside the provider request body.
  Store profiles beside request facts and typed conversation progress in its own
  table. Separate stored Brain originals from packs and pointers; add memory
  only to replay copies. Migrate legacy rows without changing caller text and
  retain checkpoint recovery, memory refresh, and overflow limits.
- Finish scheduled turns through a validated termination tool. Record reply or
  permitted silent success with the tool journal and recover the accepted result
  without a JSON response format or a format-repair request. Nonempty ordinary
  model text also completes as a visible reply.
- Separate pure Worker acquisition and Codex Job supervision from the model
  loop. Reuse ready Workspaces across rounds, keep run types and tool policies
  with their owners, and share finite outcomes, read tools, and failure handling.
  Split response storage, compaction, and native streaming by responsibility.
- Separate site configuration and Worker environment rows from tenant rows.
  Enforce tenant ownership on joins, nested queries, bulk writes, and upserts.
  Keep configuration cache entries and invalidation within their tenant.
  Use one site authorization owner and bound cross-tenant discovery. Rename
  Worker API and protocol resources and migrate stored permission grants.
- Record provider stream dispatch, Ready, and event progress in Response
  metadata. Warn once after five minutes without progress. Reset streaming idle
  budgets only for complete events and keep the existing 30-minute budgets.
  Record failures before Ready without renewing the generating lease.
- Keep each Provider call's error diagnostics and failure terminal in the Rust
  client. Deliver terminals in order under read credit, including hosted image
  failures. Elixir consumes them for public projection, credential health, and
  durable commits. Preserve retries before the first response event and keep
  delivered batches readable after the stream owner exits. Keep malformed
  Provider events non-retryable at both native failure edges. Deliver complete
  terminal output when it exceeds the mid-stream pending byte window.
- Bound Worker WebSocket connection attempts to ten seconds. Keep the existing
  reconnect backoff and record socket errors and close facts.
- Show the requested model profile and provider model for Conversation replies
  in Console. Keep the profile through configured fallbacks and credential retries.
- Document installation names, compaction threshold limits, single-replica
  PostgreSQL disruption, and database backup checks and recovery.
- Complete Agent replies after hosted Brain operations. The conversation Driver
  executes only client tools and does not dispatch completed gateway operations.
- Stop replies when a resolved message reference is withdrawn. Include that
  reference only in withdrawal checks. Keep retries and visible context checks
  limited to mirrored message sources.
- Let an Agent report an unavailable computer after repeated tool failures.
  Keep one unavailable acquisition state across tool rounds in the same run,
  including late workspace and transport replies. Request terminal diagnostics
  only when the computer is available.
- Give the Agent its current signal binding name with the channel ID. The
  `send_message` tool can use the real destination without guessing a binding.
- Let automatic compaction fit a safe boundary when fewer history rows remain
  than the preferred tail. Let manual compaction use a short, safe history
  without the automatic threshold. Keep retained history within its budget.
- Keep Lark connections stable when the first WebSocket frame arrives with the
  upgrade response. Handle rejected HTTP handshake bodies through the existing
  reconnect policy.
- Let file search index the Agent Home directory. Keep the existing path
  boundary and do not enable file system root scanning.
- Keep pending tool calls during temporary workspace route errors after a
  control-plane restart. Classify these errors when opening the workspace,
  mark disconnected routes stale, and recheck temporary failures within the
  same acquisition deadline. Probe adopted calls without repeating effects.
- Retry PostgreSQL image package installation after temporary repository
  timeouts.
- Export a fresh Worker image for Lambda builds to avoid FROM-only activation
  failures. Log Lambda bootstrap startup before Bun loads the hooks.
- Remove Lambda storage files before the helper reports ready. Request helper
  deletion before removing the Worker row, and use a new stable launch token
  after a failed helper terminates. Keep the existing hook deadline and retry.
- Require 4096 or 8192 MiB for official Lambda Worker images. Operators must
  correct saved lower values in Console before runtime or cleanup operations
  can proceed; saving queues reconciliation and clears rejected Worker errors.
- Check inbound attachment content and channel paths in adapter tests. Keep
  cancellation test streams open until cancellation completes.

## Version 2.0.0-alpha.1 (2026-10-09)

- Keep conversation files under stable `chats/<channel>/` drive directories.
  Accept only `drive_path` for `reply_attachment`, and reject attachment delivery
  to another channel at Outbox commit. Give main Agents and Background Jobs
  their workspace and drive rules. Move received files with known provenance
  out of shared `inbox/`; report files that need operator placement.
- Keep Worker credentials in root processes. Run model commands, Codex, MCP,
  browsers, and Automation as uid 1000 with no new privileges. Give Agent files
  and sockets to that user. Kubernetes Worker and storage helper Pods require
  baseline Pod Security and only six capabilities.
- Reject a new Worker incarnation while the current connection has a fresh
  heartbeat. Default idle release to 15 minutes for all providers; keep
  explicit `never` settings and memory-pause generation semantics.
- Show Agent computer acquisition phases and limit each wait to 60 seconds.
  Continue with safe tool errors, renew demand after temporary failures,
  prepare provider images in the background, and request a Worker when the
  model starts a Worker tool call.
- Let Lambda Agents start in parallel. Commit the first create timestamp,
  check possible orphan VMs only on retries, and resolve VM ownership across
  tenants while retaining the existing orphan cleanup delay.
- Close used workspaces in the background so the next input can start without
  a close receipt. Pure questions send no workspace messages. Log workspace
  preparation time for operator measurement.
- Use persisted Agent fixtures and seeded model metadata in Worker control
  tests. Give the Oban tenancy probe its own queue.
- Enforce tenant ownership on Oban-tagged business queries and struct/batch
  writes. Discover lost wakeups globally, then recover each item in its tenant.
  Track reviewed SQL and cross-tenant query entry points in the tenancy checks.
- Run the temporary tenant and binding data upgrade through Mix and Release.
  Re-encrypt old identity-provider configurations for their tenant, split shared
  Slack/Teams binding keys, and fill platform application metadata. Permit Ecto
  to record schema migration versions without a tenant context.
- Format Worker and Console sources to pass the workspace quality checks.
- Keep webhook and automation creation in Jobs. Resolve their durable recipient
  from the stored Job or Workflow owner for creation, queries, cancellation,
  and later delivery. Reject missing owners before creation and preserve legacy
  records whose owner cannot be proved.
- Renew a Workflow task's watchdog only when its current attempt commits a new
  round. Keep cancellation, reclaim, replay, and rollback checks. Let CardKit
  save the sent checkpoint and first source through the existing transaction;
  a source conflict still preserves recovery without sending again.
- Reuse successful Brain grades while the model and grading input stay the same.
  Store the input hash on the Claim, recheck input before commit, and retain
  failure retries, manual resolution, and calibration. Allow bare `DAN` text in
  Skill lessons while keeping the explicit phrase rules.
- Correct Turbo source inputs and Web asset cache outputs. Align CI Bun with
  the workspace, remove obsolete lint exclusions and hook documentation, and
  share the final-mirror test wait. Keep local file import and clarify its path
  placeholder.
- Restore missing Outbox dispatch jobs through the existing minute Reconciler.
  Preserve active-job backoff, delivery attempt limits, and operator recovery
  states when a job is discarded or pruned.
- Fix JSON type checks in the Codex protocol and durable resume tests.
- Explain a reply stop when referenced context is withdrawn. Keep source
  withdrawal checks and committed tool effects; send the notice through the
  existing terminal transaction and Outbox.
- Keep the Worker alive when turn acceptance is delayed or rejected. Confirm
  the same attempt before execution, and recover safe RPC reads within their
  original deadlines. Do not replay writes with unknown results.
- Preserve original Markdown code bytes in DingTalk, WeCom, and Teams text
  conversion. Use native source ranges and remove JSON transfer and duplicate
  code slices. Keep preview timing and the existing paging engine.
- Run Worker unit and portable integration tests on the host. Provide a
  Linux host suite for the supervisor and managed Codex runtime, and keep only
  image checks in Docker. Preserve complete UTF-8 CLI responses when socket
  writes are partial.
- Recover committed tool results before current validation, and resume waits
  from their original start times. Driver takeover keeps the stored Job
  message instead of sending it again.
- Reject direct tenant joins from site or subquery roots unless all tenants
  are selected explicitly. Tenant-scoped subqueries remain supported.
- Require one folder revision across list pages and check downloaded bytes,
  sizes, and modes against that manifest before execution. Copy each Automation
  run's installed Skills into its run directory so later cache updates cannot
  change the running script's dependencies. Apply file mode changes when
  contents are unchanged.
- Bound the shared HTTP client cache to 64 entries.
- Bound password retry keys per tenant and login hashing per node. Keep the
  five-failure limit and fair admission through caller exits and Guard restarts.
  Use cookie sessions and CSRF for Console requests, shared mutation errors,
  typed Actor references, and one HTTP completion log. Keep public API bearer
  credentials and site Library settings.
- Use Protox and protobuf-es with a frozen context in the first Job TurnStart.
  Remove duplicate document hashes and the native Worker codec. Use typed RPC
  data and compile-time broker checks. Share HTTP/1.1 clients and aws-lc-rs;
  remove HTTP/3 and alternate encodings. Give provider failures one diagnostic
  owner, reuse tool descriptors, and settle exhausted Agent quotas in the
  control plane. Let ChatGPTAuth record refresh-failure health once before
  credential selection continues. Keep current failure codes, cooldowns,
  affinity, and retry budgets.
- Deliver environment tool messages directly to the current Driver. Share
  Worker atomic writes and Job/Workspace slots; validate WorkerEnv in the
  control plane. Let images own Skill roots and provider kinds own credentials.
  Delete Codex logs_2 at a locked cold start, use the browser socket client for
  cancellable fetch, and generate webhook tokens in the control plane.
- Keep automatic cron wakeups on their rules and update checkbacks in place.
  Remove unused database fields, indexes, and helpers. Calculate salience from
  active Takes and persisted Tags without stored salience caches. Retain Tags,
  vocabulary promotion decisions, and Library page forking.
  Reuse binding reads and group projections. Supervise SDK connections directly,
  recover their start arguments after a reconciler restart, and render each
  CardKit page once. Skip identity admission for unaddressed ignored group
  messages and retain their data for later reply references. Preserve attachment
  download rules. Stop running native Workflow replay after cancellation commits.
- Store channel extraction watermarks on the Source row. Commit memory writes
  and watermark changes under the same Source lock. Move existing watermarks
  before removing internal terminal Claims. Before a rollback to an earlier
  version, restore the pre-upgrade database backup; the earlier code cannot read
  the new watermark location and would learn channel history again.
- Check platform application binding limits in SignalsGateway. Keep existing
  rejection when an enabled binding's configuration is missing, unreadable, or
  invalid. Duplicate applications use one rejection reason. Preserve WhatsApp's
  credential checks and their per-binding error order.
- Keep usage and rate-limit fields in the Console API when a ChatGPT account
  needs sign-in again. Use the credential pool's complete status projection so
  the existing account page and sign-in dialog can render.
- Deliver card actions, message removal, Job notifications and successor work,
  Workflow dispatch and attention, ambient handoffs, and Skill reflections
  after commit. Keep rollback from waking a Driver.
- Brain read paths preserve stored text after access and disclosure checks.
  Remove the recall sanitization count. Keep the Skill lesson write gate.
- Update website docs and the architecture diagram in four languages for
  Worker pools, per-Agent computers, on-demand lifecycle, Phoenix Channels,
  and tenant capability defaults.
- Replace completed Brain body implementation plans with the current syntax
  and editor contract. Align related docs with tenant settings and identity,
  control-plane scheduling, Worker MCP execution, and the Docker test workflow.
- Agents can read the current channel's observed history with
  `read_channel_history`, and a cron turn can pause its own schedule when its
  task's stop condition is met. A fact remembered without a holder reaches
  later conversations, and steering carried into a successor Job is reported
  as forwarded to it.
- `read_file` shows PNG, JPEG, GIF, WebP, and BMP files of up to 8 MiB to the
  model. The control plane converts each tool image like a received chat
  image, and a text-only model gets the vision fallback description of it, or
  a notice when no fallback is available.
- Count main-loop and ambient model use against the Agent token quota, and
  keep one prompt cache key and credential per conversation. Retry tool calls
  cut off by the output limit; a Workflow task that ends without a result
  reports a failure instead of staying running. `send_message` posts its text
  and each attachment, `/stop` marks the reply card stopped, an early batch
  wakeup waits for its due time, and URL learning rejects script-only pages.
- The control plane renders a Job's Skill index, recovery reads recorded tool
  result fields, and Worker failures carry only the error's own retryable flag,
  so a lost control-plane connection retries. Remove the Worker LLM error
  classifier, the unused Job silent-success path, plugin owner configuration
  handshakes, and duplicate secret sealing and settings flows. A configuration
  read error now fails instead of using a hard-coded default.
- `bun run test:integration` runs only the PostgreSQL integration files; Credo
  and the formatter also check plugin code; `tools/e2e/run --all` runs the
  real-LLM chaos scenarios when an OpenRouter key is set.

- Classify main conversation failures from AIGateway fields. Persist provider
  capacity retry counts and deadlines, honor credential-pool recovery times,
  and keep capacity retries outside the five-failure budget.
  Defer credential-pool shortages at admission and recover committed capacity
  failures after a Driver restart.
- Return an unavailable-computer result after Worker startup failure or timeout.
  Workspace preparation synchronizes the four Agent documents before tools run.
  Continued Jobs read their source report through complete UTF-8 result windows.
- Admit Workers at Channel join. Use connection identity, one heartbeat with
  capacity, and the existing context projection for Workspace preparation.
  Remove unused protocol fields, global inbound dispatch, and unused native
  ObjectStore stat calls.
- Show inbound file provenance in the Console. Provider APIs return only the
  fields that the Console uses. Remove unpublished intermediate migrations,
  obsolete Worker model adapters and parity fixtures, and the prototype workspace.
- Use the matching Worker image embedded in the control-plane image unless Helm
  values explicitly override it. Keep image-label checks in CI and set the
  Worker slot default to 12.

- Import installed Skills, legacy Automation Job scripts, and pending Outbox
  attachment bytes into each Agent's tenant from the Release and Mix upgrade
  commands. Retain attachment metadata, attempts, and recovery state. Legacy
  sends wait for conversion; missing files remain pending and are reported.
  Repeated imports keep existing drive files and clear copied legacy Job paths.
- Keep pending Outbox attachments alive after their last drive path is removed.
  Lock their content references when the intent commits, and release those
  references only after successful delivery or deletion of the intent.
- Preserve Agent setting rows and encrypted values during tenant migration.
  Resolve tenant settings through Agent, tenant, site, and default values, and
  reject Agent overrides from another tenant.
- Close Workflow inputs whose sleep or result submission committed before a
  Driver exit. Recovery preserves the waiting state, attention and free task
  capacity, including in suspended tenants. It does not start another attempt
  or model request, and repeated recovery keeps the original completion time.
- Document live Skill instruction reads, script and MCP updates at the next
  Turn, and Worker-owned environment Workspace capacity checks.
- Make `@ankole/block-editor` an internal workspace library in
  `libs/ankole-editor`, with React, Markdown/XML, and page-session entry
  points. Hosts compile the source package; the playground has a separate
  build.
- Add operator-managed tenants with isolated people, Agents, Brain and work,
  explicit data selection in the site Console, and site/tenant setting
  inheritance. WorkerEnv also accepts Agent overrides. New Principal UIDs are opaque; Agent handles remain editable.
  Suspending a tenant blocks new work while admitted attempts can finish.
  Deleting a tenant uses Human offboarding across tenants and keeps other
  tenants' stopped work and original authorizer for manual reauthorization.
  Credential-bearing platform applications, including Slack, cannot be shared
  across tenants. Credential identity checks run before database transactions;
  one tenant's configuration failures do not stop another tenant's maintenance
  or connection cleanup. Preserve Brain writer scopes and rewrite audience tags
  in live bodies and snapshots during the administrator-group migration. Back
  up and stop every old control-plane replica before the migration; existing
  data enters the default tenant. The Console moves from
  `/console` to `/site-admin-console`, configurable through
  `ANKOLE_SITE_ADMIN_CONSOLE_PATH`; the old path returns 404.
- Start configuration services before release data migrations, and keep
  retryable SDK delivery errors on the existing Outbox retry schedule.
- Exercise live DeepSeek over FakeFeishu and real Worker containers through
  Driver death, tenant suspension, Worker replacement, tenant file isolation,
  and file delivery after lost send confirmation. A Compose scenario stops
  every control-plane process and restarts PostgreSQL, then checks automatic
  recovery, one file effect, and the platform-visible reply and file bytes.
- Keep pending clarification choices and reply instructions visible when a
  rich reply degrades to text. Ordinary Lark replies continue the conversation;
  resolved interactions do not show stale choices again.
- Use hashcrew 0.3.0 for XXH3-128 fingerprints. Existing fingerprint values
  and the Bun and Elixir APIs stay the same.
- Fix kernel builds with Argon2 0.6 and CEL 0.15. Password hashing uses a
  random salt, and stored CEL conditions keep list and map `contains`, `max`,
  and `min`.
- Keep steering input, pending stops, and committed tool effects through
  conversation recovery. Worker workspaces follow the current run and wait
  for capacity. Unapplied input after a successful Job creates one successor;
  stale admission cannot revive the finished Job. Reject newly unauthorized
  commands without ending work that was already admitted.
- Restore scheduled and ambient reply instructions, custom `/llm` validation,
  and Workflow tool limits. Normalize incoming images to bounded WebP inputs
  and return paged `web_fetch` results from the control plane.
- Enforce production unused-code checks and selected Credo checks, with
  cross-language protocol goldens.
- Run the main Agent loop in the Elixir control plane. Pure questions and
  control-plane tools need no Worker; environment tools and Codex request the
  Agent's computer when required. Creating an Agent saves its provider and an
  absent Worker row, then requests background storage preparation and prewarm.
  Conversation epochs fence driver writes, and PostgreSQL
  retains inputs, model history, and tool receipts for recovery. The Reconciler
  also wakes admitted input after a crash with no new message and restores
  Workflow runs whose process disappeared. Repeated wakeups during admission
  still start one run for a `/new` request. Wakeups during finalization wait
  until the terminal transaction completes.
- Preserve committed tool records when a user withdraws part of a request or
  retries a run that has called tools, with or without a reply target. Targeted
  retries delete the old platform reply and request another answer on the same
  tape. Failed tool fragments outside visible history require manual recovery.
  Internal revisions retain the original reply owner. Invalid targeted retries
  leave the current run active. Repeated
  failures and crashes end in a dead letter; an invalid final result after
  repair is terminal. Rejected tool calls still reach the next model turn.
- Running Jobs and environment commands continue during a short control-plane
  disconnect. A new driver adopts the same execution without repeating it or
  using a failure attempt. Each Worker generation saves its selected instance
  settings; retries and runtime connection addresses keep those values until
  idle replacement. Worker replacement retains Codex thread files and Agent
  Home. Job claims and execution failures have separate bounds. Once an old
  instance is gone, its wait message is cleared so the next environment tool
  can request a new Worker.
- Use RuntimeFabric protocol 8 with conversation and Job operation identities.
  Remove Worker main-loop execution, activation and delivery tables, and the
  Worker tool-result WebSocket command. The first migration needs a maintenance
  window: stop the old control plane before migration and replace old Workers.
  Old in-flight turns can be interrupted once. The migration keeps input and
  outbox state.
- Use `pg_search` 0.25.11 to fix invalid CTIDs in Brain BM25 queries. For an
  existing database, back up the data and stop the control plane, start the new
  PostgreSQL image, then run `ALTER EXTENSION pg_search UPDATE TO '0.25.11'`
  before Ankole migrations and a Brain text recall. The image no longer
  includes the optional LLVM JIT package. PostgreSQL does not use JIT without
  its provider; no configuration change is required.
- Control-plane replicas start under high file-descriptor limits with an ERTS
  port limit of 65,536. Operators can override it through `ERL_FLAGS`.
- Worker lifecycle handling retains the generation and process identity through
  pause and resume. It closes the old connection after a confirmed pause,
  retries a failed resume, and replaces idle instances near their platform
  lifetime limit. Workers reconnect after an event-loop gap of more than
  30 seconds and restart the disconnection timer. A Worker that the control
  plane never admits exits after five minutes, as after a lost connection; a
  join refused for a stale generation and a stop signal before admission end
  it at once. The entry supervisor also
  removes old Agent processes when a platform starts it through a command
  service and tini is not PID 1. A command entry records its first start so
  delayed retries cannot start a second Worker after the supervisor exits.
- Operators configure Worker providers in the Console with YAML and separate
  encrypted credentials. Each provider defines a Docker, Kubernetes,
  Cloudflare, Vercel, Lambda MicroVM, or Function Compute pool and its instance size. An Agent
  selects one provider at creation and keeps it. Compose, Helm, and local development seed providers
  on the first start. The
  control plane saves a generation before it creates an instance and retries
  uncertain requests with that same generation. It calls the platform outside
  database transactions and records a result only if the Worker row did not
  change, so a slow provider cannot delay admission, heartbeats, or other
  Agents. In the Console API, an explicit `null` removes an optional provider
  credential, and the Console can remove a stored one, for example to return a
  Lambda provider to the default AWS credential chain. Provider checks name the
  platform, HTTP status, and error code; YAML errors name the path of a missing
  key. It waits for old instances to
  disappear before it replaces them, including during Agent deletion. The
  Console shows platform errors while it waits. Idle release pauses or deletes the instance, as the provider supports;
  its persistent storage and cache remain. Docker and Kubernetes default to
  no idle release. `idleReleaseAfter` belongs to the provider; the installation
  setting `agent_computer.worker.ready_timeout` limits observed unready instances.
  Vercel uses a persistent Drive per Agent and requires a target image digest
  in VCR. Its launch command receives credentials only after the selected
  session ID commits; extra sessions from repeated creates are removed. A
  selected session that disappears before its first observation ends its
  generation. The
  root entry starts the Worker as uid 1000 without installing sudo. Session
  stop and Drive lookup use the request headers and ordering required by Vercel.
- Lambda MicroVM providers build an arm64 image with AWS runtime hooks and
  mount each Agent's EFS directory through NFS 4.1 before dropping to uid 1000.
  Run retries keep their token, payload, and image settings; a terminated
  instance, or an observed instance that is no longer found, releases its
  reference. Orphan cleanup spares instances that started less than five
  minutes ago, so a create whose reference is not saved yet keeps its
  instance. Tagged images isolate providers.
  Storage deletion uses a stable provider request token and commits after
  the Agent directory is renamed. Real AWS checks cover image builds, EFS
  retention through termination and image changes, short memory pause, and
  storage deletion. The account must reserve memory for deletion helpers;
  long suspension and platform time limits still need deployment checks.
  ACS remains unregistered until its default hibernation
  proves process and memory retention.
- Function Compute providers use a stable AgenticSpace at the filesystem root
  with explicit capacity and file-count quotas, or an Agent prefix in OSS.
  A second-generation template waits for a contract. Only the committed
  sandbox reference receives it, and the entry consumes it once before it
  removes sudo and starts the Worker as uid 1000. Every Worker entry first
  exports the environment that the image recorded at build time, so the sudo
  start command does not drop tool paths; provider `env` adds variables and
  cannot change one that the image sets. Storage deletion removes
  NAS mount records and the AgenticSpace, or uses one selected OSS helper.
  OSS mount paths retain their leading slash. The entry changes Home ownership
  only when uid 1000 cannot write to it; writable OSS mounts reject `chown`.
  Real base-sandbox checks cover envd uploads and OSS retention across sandbox
  deletion. Worker image capture, AgenticFS, memory pause, and the full cloud
  lifecycle still need validation.
- Replace the FOSS design and operator documentation for Worker providers,
  persistent Home, native Codex resume, and storage backup. Helm mounts
  bootstrap Secrets as files for provider
  seed credentials and removes the Cloudflare-specific environment setting.
- Each Agent has persistent Home storage at `/workspace`, with Codex Home at
  `/workspace/.codex`. Codex SQLite uses `/var/cache/ankole`; a rebuild removes
  this cache, and other replacements keep a configured cache volume. A changed
  Kubernetes cache template replaces the cache PVC before the next instance.
  Docker uses two local volumes per Agent. Kubernetes uses a PVC per Agent or a
  directory in a shared PVC, with an optional cache PVC. Compose migrates the
  Homes of existing Agents from the old `agents_data` volume before the control
  plane starts; Homes that the old release kept for deleted Agents stay behind.
  Helm can keep the existing shared Home claim after the documented preparation
  for its storage type, including NFS with root squash; the import names the
  Homes of deleted Agents so operators can remove them. `/agents/<agent_uid>`
  links to `/workspace`, so stored absolute paths still work. Agent deletion waits
  for all instances to disappear, then deletes storage and the Worker row.
  Shared-PVC cleanup also waits for its helper Pod to disappear.
  Compose requires `ANKOLE_DOCKER_GID` for Docker socket access (`0` on Docker
  Desktop for macOS). Workers use their own network with Internet access.
  The Helm value `worker.localPods` (default `true`), not the provider seed,
  controls the Worker owner ConfigMap, ServiceAccount, Role, RoleBinding,
  NetworkPolicy, and shared Home claim; `false` requires `worker.providers`.
  The installation label must not change after the first install. Shell
  scripts check out with LF line endings, also on Windows.
  The system prompt, Job instructions, `ankole-files --help`, and the Jupyter
  Skill say that the Agent Home and its workspaces stay across Worker restarts,
  replacement, and upgrades.
- The website Quick start tells operators to set `ANKOLE_DOCKER_GID` to the
  output of `stat -c %g /var/run/docker.sock` on Linux and to `0` with Docker
  Desktop on macOS, as the Compose guide does.
- Workers can run on Cloudflare Containers: deploy the adapter Worker in
  `tools/deploy/cloudflare/agent-workers` with the `linux/amd64` Worker image
  and an R2 backup bucket, then configure a Cloudflare provider. The adapter
  backs up `/workspace` before a planned stop and restores it before Worker
  startup. A container restart that replaces the instance disk restores the
  latest backup again, and a disk that was not restored never requests a
  backup. A stop signal before the Worker starts ends the restore and starts no
  Worker. The adapter's image name must equal the control plane's Worker image
  reference. PostgreSQL keeps the committed backup reference. A forced platform
  stop can lose changes since the last backup. This replaces container disk
  snapshots. The adapter retains finished generation IDs to reject delayed
  creates, including after Agent deletion; these records contain no credentials
  or backup data. The control plane, file relay, and AIGateway must be reachable
  from Cloudflare; this deployment uses one control-plane replica. The image
  entrypoint prepares the browser socket directory when the platform mounts
  an empty `/run`, before it changes to uid 1000. Creation requests allow five
  minutes for a cold image to start; a timeout keeps the same generation.
- A Worker is its Agent's own computer: commands, Codex, Automation scripts,
  and the browser run without bubblewrap. Docker Workers need no `SYS_ADMIN`
  or unconfined seccomp. Processes run as uid 1000 without sudo. Each Worker
  generation has its own random credential, so a Worker cannot connect as
  another Agent or after it was replaced. The shared
  `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` setting,
  `secrets.workerAuthKey`, and the `bootstrap-worker-auth-key` step are
  removed; the control plane names Lark profiles, with the same names. A
  supervisor in the image restarts a crashed Worker process in place, a Worker
  reconnects at once after a control-plane restart, and a drained Worker
  always exits. Channel joins also check the generation authenticated by the
  socket. Workers can read only the rendered-fetch timeout and SSRF setting
  through AppConfigure; installation credentials remain in the control plane.
- Each Agent has a drive in the control plane for the files that other people
  see or receive: received
  attachments, generated images, sent attachments, installed Skills,
  Automation Job scripts, and files that it saves with the new `ankole-files`
  command. A folder path may end with a slash, and `put <file> <folder>/` puts
  the file into that folder, as `cp` does. The Console Agent page browses,
  uploads (also whole folders), moves, renames, and deletes drive files without
  a running Worker; the Workers page no longer browses files. The file service
  keeps one copy of an attachment for every Agent that receives it; Lark,
  Slack, Discord, Telegram, WhatsApp, LINE, and email also download it only
  once. `reply_attachment` pins the file when it runs, so a later change to the
  local file does not change what is sent, and a reply whose file is missing
  waits for an operator instead of retrying. The drive rejects a file whose
  path conflicts with a parent or child file. Valid file-to-folder changes
  also work in an existing Worker cache. `ankole-files list --after` reads
  later pages.
- Operators must set `ANKOLE_FILES_STORE` (`fs` or `s3`) and its settings:
  Docker Compose adds the `files_data` volume, and the Helm chart adds the
  `files.*` values. Give an `s3` bucket a lifecycle rule that aborts incomplete
  multipart uploads. After the upgrade, run the one-time import
  (`Ankole.Release.import_agent_home/1`, see the deployment guides). It copies
  installed Skills and Automation Job scripts to the drive and reports every
  directory or file that it cannot read. Agent Homes from root Workers are
  readable only by root, so make the old volume readable first; the Compose
  and Helm guides give the command. Attachments received before the upgrade
  show as not available.
- An Automation Job runs a fresh copy of its drive folder on every trigger. To
  change a script, put the edited directory to the same folder; files that a
  script writes into its working directory no longer remain between runs.
  It downloads installed Skills before it reads MCP dependencies, and retries
  a failed download as an infrastructure failure. An unknown registration
  result keeps the uploaded scripts and tells the caller to list jobs before
  retrying. Worker file grants move to the Agent resource `agent:<uid>:files`.
- The control plane builds the installed Skill catalog directly from the
  Agent's drive. Manifest updates preserve operator enablement overrides; a
  failed read leaves the catalog unchanged. Worker cache scans and the
  `skills.installed.replace` RPC are removed. Concurrent Turns and Automation
  Jobs now prepare the Worker Skill cache one at a time. A failed preparation
  does not block the next one. Skill paths use the Worker's saved startup
  settings, including native Kubernetes container environment values, so the
  control-plane tool returns the directory that the Worker uses.
- A Background Agent Job keeps its workspace and native Codex thread files in
  the Agent's persistent Home. A new Worker resumes the same thread and files;
  Codex can rebuild SQLite from those files when the cache is lost.
  Stored turn-item replay remains only for Jobs that had a runtime thread
  before this migration; a successful runtime-anchor update ends that fallback.
  Job creation accepts `/workspace` paths.
- RuntimeFabric has no ZeroMQ transport any more. Workers connect only over
  the Worker Channel, so `ANKOLE_RUNTIME_FABRIC_ENDPOINT` must be a `ws://` or
  `wss://` URL. `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT`, the Helm
  `runtimeFabric.port` and `runtimeFabric.bindEndpoint` values, port 6010, the
  `kit dev` flags `--fabric-port` and `--worker-transport`,
  `agent_computer.background_agent_job.max_turns_per_worker`,
  `worker.replicaCount`, and `ANKOLE_WORKER_ID` are removed. The kernel drops
  the `zmq` crate and the unused AnyAscii transliteration and adds an OpenDAL
  object store. The images no longer install libzmq, and the control-plane
  image runs as uid and gid 10001. A rollback to an earlier release is not
  supported.
- Docker Compose needs `RELEASE_COOKIE` in `.env`: generate it with
  `openssl rand -hex 32` before the upgrade. Compose used the distributed
  Erlang cookie built into the published image, while EPMD and the
  distribution port listened on the network that the Workers share; the
  control plane now binds both to the loopback interface when its node answers
  at the loopback address. The Helm chart already generates a cookie for each
  install. Compose upgrades and file-store backups use `docker compose stop`,
  which keeps the network of the running Workers.
- The Helm chart's bundled PostgreSQL keeps its database in the directory that
  `postgresql.pgdata` names, by default `pgdata` on its volume, so it starts on
  block volumes such as EBS, whose root holds `lost+found`. When you upgrade an
  installation that kept the database at the volume root, set
  `postgresql.pgdata=/var/lib/pgsql/18/data`. The migration init container
  gets the same environment as the control plane.
- Brain learns a URL source only through the `web_fetch` model profile;
  without one, the source reports `web_fetch_model_not_configured`. The
  fallback to a Worker's local browser and its Brain health item are removed.
- Failure records name the Provider's error code from the Provider body, not
  the kernel's code for the failure. AIGateway no longer retries a failure that
  the kernel finds in a provider stream as a provider capacity failure, for
  example an event that is not valid JSON or a Gemini safety stop. A chat turn
  then ends with the failure notice after one model call, not after up to 15
  calls over more than a minute.
- The kernel keeps the AWS exception type of a Bedrock ConverseStream exception
  that arrives mid-stream and reports the HTTP status that AWS declares for it.
  AIGateway then marks a throttling, service-unavailable, or internal-server
  exception as a retryable provider failure and reports a `validationException`
  as `invalid_prompt`. The AWS eventstream parser also reads every header value
  type, including byte arrays, correctly. A ConverseStream response now
  completes with its stop reason and token usage instead of ending as
  incomplete: the kernel names each event by its `:event-type` header, as the
  AWS SDK does.
- A Claude response that fails after its stream starts now ends as a provider
  failure with Anthropic's error type and message, and with the HTTP status
  that Anthropic documents for that type. Before, the kernel dropped the
  `error` event, so the Worker saw a closed stream and retried at once as a
  timeout, also after an `invalid_request_error`. Now an `overloaded_error`,
  `rate_limit_error`, or `api_error` is retried on the provider-capacity
  schedule, and a `rate_limit_error` puts the credential on cooldown as an HTTP
  429 does. An `invalid_request_error` ends the turn as `invalid_prompt`.
- A failed AppConfigure cache refresh can no longer leave the value from before
  a write in the cache. Before, a cache miss that read the key just before the
  write could store its older result after the refresh failed, and reads then
  returned the old value or the default until the next write to the key or a
  restart.
- `bin/ankole rpc`, `remote`, `stop`, `restart`, and `pid` work in a running
  control-plane container or Pod. Before, the client node that these commands
  start also listened on the fixed distribution port, which the running node
  already used, so it stopped with `eaddrinuse`. Now only the node that
  `start`, `start_iex`, `daemon`, or `daemon_iex` starts uses
  `ANKOLE_DIST_PORT`; clustering is unchanged.
- Local Worker images build on the Agent OS base with Codex 0.158.0. The new
  `kit pin-base-image` command pins the base that CI published for the current
  `Dockerfile.base`, local builds warn while the pinned base has a different
  `Dockerfile.base`, and `kit agent-computer-test` runs the Worker image
  directly without compiling the control plane. The development control plane
  listens on every interface, so Workers on Linux and in the dev container
  reach it.
- E2E tests fail when a Worker restarts or is replaced during a test that does
  not do this on purpose.
- Control-plane tests no longer call Feishu, the Lark binding and Plugin
  registry restart tests no longer fail at random, and the AIGateway trace test
  expects the boolean attributes that OTLP exporter 1.11 sends.
- The Plugin registry tests reset the global AppConfigure plugin declarations
  after each test. Test modules that run later, such as the LINE adapter
  tests, no longer fail with unknown plugin keys.
- The real-LLM Workflow e2e suite compiles again. Its Brain embedding and
  rerank test sets the Brain maintainer Agent and sends the rerank request as
  that Agent, as Recall does.
- AI provider modules no longer declare `upstream(...)`. The capability kind
  sets the upstream wire shape: Server-Sent Events for a language model and
  JSON for every other kind. A Control Plane Plugin that still calls
  `upstream(...)` must remove the call. The Gemini GenerateContent and OpenAI
  embeddings resolvers, which no provider used, are removed.
- A Background Agent Job that was created before 0.59 now resumes with text
  input only. Ankole no longer fills a missing image-input capability of such a
  Job from the current model profile.
- Lark, Slack, DingTalk, WeCom, Discord, Telegram, and Email connections share
  one reconcile and supervision implementation. A restart now replaces a
  connection owner that already stopped instead of reporting an error, and the
  reconciliation warning keeps its event name. Lark reply cards use one update,
  finalize, and page-seal path for both card transports. The Lark, Slack, and
  Teams startup channel syncs log `plugins.channel_sync.startup_enqueue_failed`
  when they cannot enqueue.
- The repository no longer contains the unused `tools/eval` evaluation
  framework.
- The Console and setup pages use the tianbai (甜白) neutral palette: paper and
  gray layers lean very slightly warm, text leans slightly cool, and contrast
  stays the same. Every overlay in `@ankole/uikit` uses the alumina ceramic
  material: menus, select and combobox lists, popovers, hover cards, tooltips,
  dialogs, sheets, drawers, and toasts. The ceramic lets the color behind it
  through but flattens its light and shade, so text on it keeps its contrast
  over any background, at least as well as on Fluent acrylic, while the
  ceramic is a little less transparent than Fluent acrylic. It has an edge
  light and a faint grain. Dropdown menus use the slightly more transparent
  `ceramic-primary` tier. Sheets and drawers float 8px from the window edge,
  tooltips are light and have no arrow, and the modal scrim is lighter so that
  the ceramic stays white. The mobile navigation panel now has its intended
  width of 320px. The material is also available as `--ceramic-*` and
  `--fog-*` tokens and the `ceramic`, `ceramic-primary`, `ceramic-attention`,
  and `fog` utilities.
- Berry in the Console and `@ankole/uikit` marks only the brand and the
  primary action; it no longer marks a state, because next to red it reads as
  an error. Interaction states use ink and shape: keyboard focus is a 2px ink
  ring with a gap, a focused field gets a 2px ink baseline on a paper fill,
  and checked boxes, radios, switches, active tabs, the current page, the
  current navigation item, and progress bars are ink. An invalid field gets a
  2px red baseline. Links are ink with an underline. A table row whose name
  opens an object now opens it on a click anywhere in the row; the name is
  underlined while the pointer is over the row. Selected text and selected
  rows take a pale qingbai glaze instead of solid berry. Status colors keep the
  common convention, and each status has its own icon: failure is red with a
  cross, a warning is amber with a triangle, a Background Agent Job that waits
  for a person is amber with a question mark, success is green, and work in
  progress is blue. A firing checkback now shows as in progress instead of as
  a warning. Badges are neutral by default, and the berry badge style and the
  `--link` token are removed; `--selection` and the `link` utility are new.
  The ceramic glaze for a decision that waits for a person is amber.
- The `@ankole/uikit` tokens follow the same color rules everywhere. A card is
  paper like the page, so a field keeps its gray fill on a card. Placeholder
  text reaches 4.5:1 against its field in both themes. Every status color has
  the same three roles: `--destructive`, `--warning`, `--success`, and `--info`
  color icons, dots, bars, borders, and rings; `--*-foreground` colors status
  text; and `--*-subtle` is the quiet background of alerts and notice panels.
  Marks keep 3:1 on paper and on the ceramic. Text keeps 4.5:1 on paper and,
  on the ceramic, reads at least as well as the same role on Fluent acrylic.
  Light marks use palette step 60 and light text step 70; dark marks use step
  50 and dark text step 40, except warning text at step 30. So dark red text
  is lighter, success marks are darker green, warning bars are darker amber,
  and `--destructive-foreground` is red text instead of white. A focused
  destructive menu item is red-60 with white text in both themes, like the
  destructive button. The Console home page shows failures with a cross and
  warnings with a triangle. The avatar badge is ink instead of berry. The
  unused `--error`, `--interactive*`, `--divider*`, `--chart-*`, and
  `--sidebar-primary*` tokens are removed.
- The `@ankole/uikit` controls share one grammar. Buttons, fields, selects,
  input groups, comboboxes, OTP slots, toggles, and tabs are 32px high by
  default, 28px in toolbars and rows, and 24px inside another control, with a
  4px radius (3px for keys and for options inside a control). A field is a
  gray slot with a 3:1 baseline and uses the placeholder color for its
  placeholder. A normal button is a paper object whose bottom edge is one step
  darker, and it sinks into a slot when pressed. The only solid buttons are the
  berry primary action and the red confirmation of an action that cannot be
  undone. A segmented toggle is a slot that holds the chosen option, menu and
  list rows are 32px and sit inset in their panel, and labels and titles are
  no longer uppercase. The `secondary`, `lg`, and `icon-lg` button styles and
  the `--radius` scale are removed; `--radius-control`, `--radius-mini`, and
  the `--field-*` and `--control-*` tokens are new. The close button of a
  dialog footer and the selected prefix filter on the Brain objects page are
  now outline buttons, and the buttons on the website landing page are 32px
  high instead of 44px.
- The Console page is a sheet of paper on a gray ground, as in the design
  language: the header and the navigation sit on the ground without divider
  lines, and the page content sits on a sheet with a 10px radius and a hairline
  edge. Panels on the sheet stay square. Table rows and header rows are 32px
  high instead of 48px, and header cells use small gray text over a darker
  line instead of a filled band. `--ground` and `--radius-panel` are new.
- The Automation Job and Background Agent Job detail panels in the Console
  fill the window up to their maximum width. Before, they used 75% of the
  window width, also on narrow screens. The `@ankole/uikit` `Command`
  component highlights only the selected item; before, every item had the
  selection background.
- The README in English, Chinese, Japanese, and Korean opens with a poster
  that plays the two-minute introduction film on X, then says what Ankole
  does and gives a group-chat example. It lists the supported chat, sign-in, model,
  and Worker platforms, gives a Docker Compose quick start, and links the
  documentation site, the known limits, and GitHub Discussions. The repository
  map and the development commands are in `CONTRIBUTING.md`.
- The website homepage uses the wording of the README in all four languages.
  Six everyday requests replace the decision-work examples and follow the
  title directly. The Harness section starts with the problem (a model with a
  prompt starts every task from zero). The Chinese, Japanese, and Korean
  titles no longer say "enterprise" and break into two lines. The page
  description and `llms.txt` use the same wording.

## Version 1.6.19-rc.1 (2026-10-09)

- Fix the website build by escaping apostrophes in the English quickstart.

## Version 1.6.18-rc.1 (2026-10-08)

- Enterprise IM signal bindings (Lark, Slack, DingTalk, WeCom, Teams) now
  reference an identity provider instead of a free-form
  `platformSubjectNamespace`. A binding adopts the single configured provider
  of its adapter by default, must choose one when several exist, and can
  choose a standalone namespace; an unknown reference is rejected. Chat
  senders and directory users of one organization now resolve to one
  Principal. Before, a binding kept a default namespace such as `lark-main`
  while directory sync wrote the provider id, so one person could get two
  Principals and an addressed message from a synced user was held as an
  unmapped sender. Enabling a binding keeps its reference, and a binding
  without any provider keeps the adapter default namespace.
- A required select without a default value in the Console now starts empty
  instead of its first option.
- Sender hydration failures and profiles without email or mobile are now logged
  as warnings during identity admission.

## Version 1.6.17-rc.1 (2026-10-07)

- When a Background Agent Job asks a question, the main Agent now answers it
  from the conversation, a loaded Skill, or its tools when it can, and corrects
  or stops a Job that cannot do its task as written. It relays to the user only
  a question that needs the user's decision, approval, or information. Before, the Agent relayed each
  Job question to the user, including a request for access that no setting
  gives.
- The `create_background_job` tool tells the Agent that a Background Agent Job
  cannot create Jobs or load a Skill that runs only in the main Agent.
- `skill_view` states the `ankole-runtime` value with the Skill content.

## Version 1.6.16-rc.1 (2026-10-06)

- A Background Agent Job that tries to load a selected Skill declared
  `ankole-runtime: main` now gets "skill is not available in the
  background_job runtime". Before, the Job reported "skill is not enabled for
  this turn", and Agents asked users to enable a Skill that a Job cannot load.

## Version 1.6.15-rc.1 (2026-10-02)

- The `grep` and `find` tools continue a paged search only for the Agent whose
  search made the cursor. Before, an Agent on a shared Worker could send a
  cursor from the search of a different Agent and get the next page of matches
  from that Agent Home. Now that cursor gets the same "Cursor expired" result as
  an unknown cursor.
- The Codex resume contract test checks that the pinned Codex resumes a thread
  from its rollout file alone, reassembled from segments in an empty Codex Home.
- Control-plane dependencies and the Turbo build runner are updated.

## Version 1.6.14-rc.1 (2026-10-02)

- Tool-result recording uses the existing idempotency index. Large message
  histories no longer cause metadata scans for each tool-result lookup.
- Agent Computer uses pi 1.0.0, OpenAI SDK 7.27.0, and Protobuf-ES 2.16.0.
  The generated RuntimeFabric codecs match the new generator version.

## Version 1.6.13-rc.1 (2026-10-01)

- Model responses over the AIGateway Responses WebSocket are no longer cut
  after 5 minutes. The socket idle timeout counted only client frames, and
  Codex sends none while it waits for a response, so every response that took
  longer than 5 minutes failed and was retried. The socket now allows the
  30-minute upstream model budget.

## Version 1.6.12-rc.1 (2026-10-01)

- A Background Agent Job now fails with the path of the Plugin marketplace
  that a Worker before 1.6.8-rc.1 left in the Agent Home, instead of a
  "Codex Agent Plugin state mismatch" with no cause. The Plugin install check
  selects the Worker marketplace by its path. Required operator action: remove
  `.agents/plugins/marketplace.json` and `runtime-materials/agent-plugins` from
  each Agent Home. Until then, Background Agent Jobs fail for every Agent that
  still has these files, including Agents whose Jobs passed the old check.

## Version 1.6.11-rc.1 (2026-09-29)

- Conversations can continue after image generation through OpenAI-compatible
  Responses endpoints. AIGateway restores saved image data before it sends
  history upstream, including images from existing conversations.

## Version 1.6.10-rc.1 (2026-09-29)

- OpenAI-compatible Responses requests explicitly disable upstream response
  storage, so Codex endpoints no longer reject them with "Store must be set to
  false". Ankole continues to store stateful conversations locally.

## Version 1.6.9-rc.1 (2026-09-29)

- Background Job details and attempt history show stored model failures even
  when no tool ran and the Job is queued for retry or has been stopped.
- The Feishu approvals Skill stays in the requesting user's main conversation.
  Receipt analysis and expense preparation can still run in background Jobs.

## Version 1.6.8-rc.1 (2026-09-29)

- Background Agent Jobs on different Workers no longer share mutable Plugin
  packages or marketplace files. Each Worker builds and installs them in its
  local Codex Home, and a cleanup failure preserves the original setup error.
- Brain accepts integer confidence and weight endpoints. Memory prompts
  preserve audience scope on retries, verify writes before reporting success,
  and check historical claims when current status matters. Memory analysis
  receives claim dates, attribution, and provenance, including the separate
  Fact validity dates and Take prediction periods.
- AIGateway traces retain classified failure codes, provider status, and retry
  facts. Brain model calls identify their phase in Langfuse. Automatic learning
  still requires an active maintainer Agent and its model profiles.
- The local Worker fallback now uses the OS base published with 1.6.6-rc.1.
  The published Worker image for the current commit remains the first choice.

## Version 1.6.7-rc.1 (2026-09-29)

- The Worker image now runs Codex CLI 0.158.0. Its generated app-server protocol matches the binary, and Job web search, MCP tools, Plugins, and durable resume work with this release.
- The Worker image updates Bun to 1.4.2, MCPorter to 0.14.1, OfficeCLI to 1.0.152, and PDF Inspector to 1.25.2. Agent turns and tool declarations work with pi-agent-core and pi-ai 0.87.1.
- The control plane, kernel, provider clients, web apps, and website use updated locked dependencies. Console's JSON editor works with json-edit-react 2.0 and React 19.3, and the devkit commands work with Crust 0.5.
- Tests no longer fix the wording of first-party Skill bodies, model-facing descriptions, prompts, or setup help text. Skill loading, data projection, and tool execution checks remain. The Worker transport modules no longer form a runtime import cycle.

## Version 1.6.6-rc.1 (2026-09-28)

- Feishu rich posts now include files from the message's `files` list as
  downloadable attachments. A Word template sent with text reaches the Agent's
  inbox through the same path as a standalone file. Files and inline images
  in the same post are retained, and repeated file references are deduplicated.

## Version 1.6.5-rc.1 (2026-09-28)

- The website now publishes a Markdown version of each documentation page at `/<locale>/docs/<page>/index.md`, and an `llms.txt` index and an `llms-full.txt` file for each language at `/<locale>/llms.txt` and `/<locale>/llms-full.txt`. `/llms.txt` and `/llms-full.txt` serve English. The Markdown of Quick start and FAQ contains every deployment method, identity provider, and chat channel, not only the selected tab.
- The Quick start agent prompt now sends the Agent to the Markdown version of Quick start. Each documentation page has a Copy page button that copies its Markdown, and a menu that opens the Markdown or opens the page in ChatGPT, Claude, or Cursor. Each page also links its Markdown version and its language's `llms.txt` for agents.
- The website build fails when a documentation MDX component has no Markdown form, and its link check now also covers the Markdown and `llms.txt` files.
- The website now builds with Astro 7.3.5, `@astrojs/react` 7, `@astrojs/mdx` 8.0.2, `intl-messageformat` 12, Motion 13.4.4, sharp 0.35.5, and Vite 8.3.1. The repository no longer tracks the generated `app/website/.astro/` directory; Astro recreates it on each dev, build, and check run.

## Version 1.6.4-rc.1 (2026-09-25)

- A Background Agent Job on a Google AI Studio (Gemini) model no longer fails with "Function call is missing a thought_signature" after a round that used a hosted tool such as Brain `recall`, or when the model writes text before its tool call. AIGateway now returns each Gemini tool-call signature by call ID, independent of item order.

## Version 1.6.3-rc.1 (2026-09-25)

- Google AI Studio (Gemini) models now work for Agent turns, Workflow tasks, and Background Agent Jobs. AIGateway no longer sends caller `metadata`, which Google refused with HTTP 400 before the first model call. It also sends back the thought signature of each Gemini tool call, which Google requires for the request after a tool call.
- A Google AI Studio request failure now shows Google's error message instead of "The upstream provider request failed.".

## Version 1.6.2-rc.1 (2026-09-21)

- Research into market, competitor, channel, cost, compliance, and resource
  constraints for a controllable operating or market-entry choice now has a
  focused `research-for-planning` Skill. Its routing entry separates that
  work from external-world research and forecasts, while mixed requests can
  split the subquestions and return to the requested action. Asset-price and
  buy/hold judgments remain with Deep Research.

## Version 1.6.1-rc.1 (2026-09-20)

- Brain `remember` now treats an empty or blank `until_date` as no date for every claim kind. A model that fills every declared property sent `""` for fact kinds and was refused with `until_date_only_for_takes`; the declared `until_date` schema now also requires a full ISO date.

## Version 1.6.0-rc.1 (2026-09-20)

- RuntimeFabric now carries Worker traffic over one Phoenix Channel per Worker. A Worker whose `ANKOLE_RUNTIME_FABRIC_ENDPOINT` is a `ws://` or `wss://` URL such as `ws://control-plane:4000/runtime-fabric/worker` connects through the channel and sends the shared key as the socket auth token; a `tcp://` endpoint keeps the ZeroMQ transport, and the control plane accepts both until every Worker has switched. Each stream carries a sequence number, the control plane acknowledges cumulatively with message and byte credits, and a Worker reconnect keeps its running turns. The protocol version stays 5. The Helm charts, Docker Compose, and the devkit default new Workers to the channel.
- The control-plane release runs as a named Erlang node and the Helm charts add a headless Service, a generated release cookie, a fixed distribution port, a rolling update above one replica, a `preStop` drain pause, and an optional NetworkPolicy, so several control-plane Pods can route Worker commands to each other. Keep one replica until the control-plane singleton processes are verified on more than one node.
- Worker files now move over HTTP instead of the RuntimeFabric connection. The control plane sends a one-time signed relay URL to the Worker through the new `worker_files.pull` and `worker_files.push` RPC methods, streams Console uploads and downloads without buffering a whole file, and lists, moves, and deletes through Worker-owned RPC methods. Operators must let Workers reach each control-plane Pod's internal HTTP origin; set `ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN` or inject `POD_IP`, and the Helm charts, Docker Compose, and devkit now do so. The raw multipart file frames, the zstd block codec, and the control-plane file transfer lane are removed.

## Version 1.5.3-rc.1 (2026-09-19)

- Internal runtime and SDK state now use declared struct fields and explicit provider hooks, and unused failure, trajectory, and actor-runtime paths are removed without changing the external response or storage contract.
- Console writes keep the cast request's internal atom-key shape through Agent, AuthZ, schedule, and AIGateway provider owners; Teams mirror scans filter the owning app in PostgreSQL before loading metadata.
- Elixir runtime paths now keep FIFO waiters in OTP queues, build ordered accumulators without repeated tail copies, trust LLMDB's normalized model shape, and keep GenServer callback tuples at callback sites while preserving response ordering, retry timing, and failure behavior.

## Version 1.5.2-rc.1 (2026-09-18)

- A completed Background Agent Job can finish silently after its result is already delivered, and its internal `silent_success` result no longer appears as raw JSON in a provider chat or live preview.
- Silent completion now requires a persisted provider-delivery verification record; missing or incomplete delivery evidence produces a visible parent result instead.

## Version 1.5.1-rc.1 (2026-09-17)

- Cron fires created before the Human authorization upgrade recover the authorization already held by their schedule, so pending tasks no longer fail because that migration omitted their authority. Revoked access remains blocked, and failed tasks retain their history; run a missed task manually after the upgrade if it is still needed.
- The website quick start and adapter guide now cover the Telegram, Discord, LINE, WhatsApp, and Email channels: the external app or mailbox each one needs, its platform settings, the Console fields, how a sender becomes a known account, and the platform limits.
- The website documents the per-Agent token quota on the Agents and Cost management pages, and the disablement and restoration of a departed person, including the administrator recovery command, on the Principals page. The agent-loop page describes the current retry classes and the provider capacity wait ladder.
- The README and the documentation index list every current chat and identity adapter, and the index links the Automation Jobs, Workflow, Local Password Identity Provider, and Brain Markdoc design documents.

## Version 1.5.0-rc.1 (2026-09-16)

- WhatsApp is now available as a chat provider. Give a binding the Meta App ID, App secret, verify token, phone number ID, and a permanent System User access token, then set the App's callback URL to `https://<host>/webhooks/v1/whatsapp/<appId>/events` with the same verify token and subscribe the App to the `messages` field. Several phone numbers of one App can each serve their own agent.
- In a one-to-one WhatsApp chat the agent reads text, quotes, locations, shared contacts, and received files, answers with quoted replies and files of its own, and offers clarification choices as numbered reply buttons or a numbered list. A sender whose phone number already belongs to a known person is mapped to that account without any administrator action.
- WhatsApp replies stop with a clear failure more than 24 hours after the user's last message or choice, because Meta closes the customer service window; an operator can retry the stopped reply from the Signal Routing page after the user writes again. Group chats, template messages, message edits, message deletions, and a live progress preview are not available on WhatsApp.
- The provider webhook route now also answers GET requests, so a provider can verify that it owns the callback URL.

## Version 1.4.0-rc.1 (2026-09-16)

- An operator can now connect a dedicated mailbox to an Agent with the new Email adapter: Ankole receives mail over IMAP, keeps each email thread as one conversation, and sends the Agent's replies over SMTP with the thread headers that mail clients use. The mailbox belongs to the Agent; a message that another mail client marks as read never reaches it.
- An email sender is identified only by an explicit `email` identity binding: an administrator maps the address from the mapping request list, a synced directory binds each user's address automatically, or the binding creates a standalone account. A profile email or a local sign-in email never links a sender by itself. By default the adapter requires a DMARC pass from the receiving mail server and ignores automatic and bulk mail. Password and app-password login are supported; OAuth mailboxes are not.
- A channel whose adapter cannot edit a sent message no longer receives a streaming preview, so an email thread gets the Agent's complete answer as one message instead of its first fragment. The Console signal routing page names a delivery that the channel does not support instead of showing a missing translation.
- A provider user that matches no binding and no contact is always a new account. Ankole no longer joins it to an existing Principal only because the UIDs are equal, and it refuses the write when that UID is taken; an operator maps the two explicitly when they are one person.

## Version 1.3.1-rc.1 (2026-09-14)

- A LINE file download that cannot start no longer runs inside the webhook answer. The webhook fails instead, and LINE delivers the message again.

## Version 1.3.0-rc.1 (2026-09-14)

- LINE is now available as a chat provider. Give a binding the channel ID, channel secret, and long-lived channel access token from the LINE Developers Console, set the channel's webhook URL to `https://<host>/webhooks/v1/line/<channelId>/events`, and the agent reads one-to-one, group, and multi-person chat messages, downloads received files, answers with push messages that quote the asker in groups, offers clarification choices as buttons, and forgets a message the user unsends. An unknown sender's mapping request shows the LINE display name.
- Every LINE reply is a push message and counts against the Official Account's monthly message plan; the account's plan must cover the expected traffic. A LINE bot cannot edit or unsend a message, cannot send files, and shows no live progress before the final answer.
- Provider webhook handlers now receive the exact request bytes next to the parsed body, so a provider signature can be verified.
- A provider that delivers the same message again can no longer replace an attachment the agent already downloaded with a failed observation. Internal: Telegram and Discord share one UTF-16 text helper.

## Version 1.2.0-rc.1 (2026-09-11)

- Administrators can disable Human access, review restrictions and permissions before restoration, and inspect access history in Console. Feishu departure, freeze, reviewed directory-scope removal, and DingTalk departure disable the same account. Repeated departure events are processed once, and provider restriction clearance requires current complete directory evidence. An audited operator command can recover administrator access after the last administrator departs.
- Disablement stops future Human work across messages, schedules, background jobs, workflows, and automations while admitted attempts can finish. Operators must classify unresolved older work before it can run. Restoration requires fresh login and personal Feishu authorization; old credentials and work stay revoked.
- Browser login now retains one durable identity across Console and OAuth, enforces requested authentication freshness and Client login-source policy, and rejects stale callbacks. The upgrade requires fresh browser login. OIDC Clients can use Introspection, Back-Channel Logout, and RP-Initiated Logout, including repeated logout after cookie removal. Console provides Client session settings and manual notification retry that makes waiting jobs available immediately.
- The existing OIDC cleanup job removes expired browser and logout state after credential, recent-session, and delivery retention ends; unfinished deliveries remain available for recovery. Expiry indexes support cleanup. Update the owning designs, the known-limits page, and operator recovery guidance, and add database, protocol, browser, and Worker regression coverage. Provider pagination rejects incomplete results instead of treating them as complete directory evidence.

## Version 1.1.2-rc.1 (2026-09-10)

- Word, Excel, and PowerPoint jobs use the OfficeCLI installed in the Worker image. An older version reference in a Skill no longer stops file work when the installed CLI and its format help run successfully.

## Version 1.1.1-rc.1 (2026-09-10)

- A message whose model call an upstream sheds for capacity now waits 30 seconds and then 2, 5, and 12.5 minutes before the Agent gives up, so a short provider overload no longer stops the message with "自动重试已停止". The Worker also stops repeating that model call three times before the first wait, and the automatic retry strategy never schedules more than 20 minutes of backoff.
- A credential pool with no usable recovery time counts as an ordinary capacity failure: the Background Agent Job returns to the queue on the fixed Job ladder and the attempt charges the execution-failure budget.

## Version 1.1.0-rc.1 (2026-09-09)

- An operator can now give each Agent a token quota in the Ankole Console: a period in days, a period start time, and a token limit. The Agent page shows the used tokens as a bar with the share of the limit, and the start and end time of the current period.
- An Agent that reaches its limit receives a reply with the used tokens, the limit, and the time the period ends, instead of an answer. AIGateway rejects its model requests with `agent_token_quota_exceeded` until the period ends.
- A Background Agent Job of an Agent at its limit fails with `agent_token_quota_exceeded`. It does not retry and does not wait for the next period.
- `Reset` starts a new period at that instant, so the Agent can work again before the period would end. The usage records stay for audit.
- The generic Agent update route no longer writes `options.ai_agent.models`, `provider_hosted`, or `token_quota` and answers 422 when a request contains them, and Agent creation rejects `options.ai_agent.token_quota`; use the model profile and token quota routes for those settings.

## Version 1.0.4-rc.1 (2026-09-09)

- Scheduled tasks validate visible replies and quiet success before delivery, so malformed completion markers do not become chat messages. If result correction fails, the task stops with a failure notice instead of repeating completed actions. Update the control plane and Worker together.

## Version 1.0.3-rc.2 (2026-09-07)

- A provider capacity failure that arrives only as a `service_unavailable_error`, `server_error`, or `overloaded_error` type without an HTTP status is now retried like the other overload aliases, so a user message, scheduled task, or research completion notice recovers instead of entering the dead-letter queue.
- Reading a finished background job's result now returns the job's real Workspace and absolute artifact paths with every chunk, including the inherited Workspace of a continued job, so a report can be delivered from another session without guessing a directory or redoing the research. The delivery policy names the copy-to-user-files step and forbids invented download links.
- Agent traces record each model generation's own output instead of an empty envelope that echoed the request, and keep JSON booleans and nulls in exported content.
- Deep Research asks only the clarifying questions that change the outcome, states the expected wait per task, delivers from the job's verified result, checks event timing before reading a market reaction, and keeps the reader's chosen objective when it corrects a fact.

## Version 1.0.3-rc.1 (2026-09-07)

- A turn that a provider ends with a `server_error` code, such as a Codex gateway relaying an OpenAI capacity overload, is now retried automatically instead of stopping with "自动重试已停止".

## Version 1.0.1-rc.7 (2026-09-06)

- Text fields show the full lower strokes of letters such as g, j, p, q, and y with the bundled font.
- The Console home page shows job counts for the full instance. Chinese list counts describe the displayed rows, and conversation pages move focus to the start of the new message page.
- Agent document drafts require confirmation before leaving the page, including after a separate basic-information save. The document editor fits narrow screens.
- Brain audits include disabled Principals. Claim text stays readable beside compact action menus, and missing Brain configuration links to its settings.

## Version 1.0.0-rc.7 (2026-09-05)

- Workers can reject new turns without blocking terminal acknowledgements, and idle Sessions release their controller processes after live deliveries finish. File transfers stop when a read fails or the file shrinks, file searches keep the requested directory scope, directory listings avoid redundant reads, and cached web pages share the same output budget as newly fetched pages.
- Slack, DingTalk, WeCom, and Teams report uncertain delivery when a later message chunk fails. Slack connections retain their resolved bot identity, WeCom disconnects after an acknowledgement timeout and preserves separators in button values, and Feishu preserves reply chunks during fallback and leaves image examples inside code untouched.
- Concurrent worker placement leaves other workers available, OIDC Client edits preserve rotated secrets, and Automation Job cancellation uses the same lock order as execution. Brain rebuilds and embedding results cannot restore stale content, repeated relations return persisted results, configured rerank options apply, and providers used by Brain cannot be disabled. Each AI Gateway Provider retains its 10,000 most recently used credential affinities; an older session whose mapping was removed can select a different credential on its next request.
- Console array fields retain line breaks during editing, each model profile tracks its own save, and new Brain approvals start with a fresh draft. Internal runtime and Brain paths remove unused state and repeated conversions and queries; Skills use the existing YAML parser and one catalog snapshot per operation, while lesson lifecycle and compaction model calls keep separate implementations behind their existing entrypoints. The Codex compaction check waits for the complete Turn before continuing.

- Agent traces now identify Agent runs and tool calls with their correct observation types. Worker and Codex tools record sanitized arguments and available results once per call, including the selected `skill_view` Skill and raw collaboration calls. Private fields and inline media bytes stay out of exported content. Silent turns record their outcome, and content above 1 MiB is marked as omitted. Worker telemetry stays provider-neutral; the control plane maps it once so Langfuse, LangSmith, and generic OTLP each receive one content projection.
- Model generations in an Agent turn are now direct siblings of tool calls under the Agent root. The duplicate `ai_gateway.response` wrapper is removed from this path, while standalone AI Gateway requests keep the response root.
- Brain no longer treats fuzzy titles as entity identity or merge evidence. Agent pages are reserved for real instance Principals, and memory instructions explain that boundary before writes; upgrades narrow the installed Agent schema to `internal`. Existing misclassified pages and old merge suggestions remain for separate operator cleanup.
- Dreaming patterns now update semantic topics within each audience instead of creating daily summaries. Each pattern cites at least three evidence pages, page updates and evidence links commit together, and no useful pattern produces no page. Signals learning and pattern model calls identify their caller in traces; existing daily pages are not rewritten.
- Library updates preserve pages that an operator forks during sync, and archiving a Library Source withdraws its pages without an in-flight sync restoring them.
- Concurrent Job completion and user steering no longer take database locks in opposite orders. Unaccepted instructions still create one successor Job, while turn completion, abort, and command paths keep the same lock order.
- Concurrent identity-provider saves retain both connections. Configuration and activation now commit together, and a second local account provider is rejected even when the first is disabled, without leaving unused configuration. A dedicated control-plane integration command checks these database races.

## Version 1.0.0-rc.6 (2026-09-04)

- Bundled tools and dependencies are updated, including Codex 0.153.2, pi-agent-core 0.84.4, and Bun 1.4.1 across local builds and release workflows; Agent turns still record terminal tool results, keep native plan updates enabled, and apply iteration, response-repair, and steering controls under the new completed-turn order. Worker image builds no longer pin or validate content hashes for downloaded artifacts or replay Lark Skill examples against one frozen CLI version.
- Administrators can register public and confidential OIDC Clients in Console, restrict their scopes and redirect URIs, select allowed Human groups through a searchable multi-select, configure Client-specific custom AI Gateway aliases with model-profile settings, and rotate confidential secrets. Ankole now serves discovery, JWKS, Authorization Code with PKCE S256, rotating Refresh Tokens, ID Tokens, and UserInfo from the existing Human identity system, and it removes expired codes and refresh tokens automatically.
- Agent, Console, and OIDC Human tokens now use one installation RS256 key without serializing JWT operations through one process, and AI Gateway verifies each presented access token once before applying its domain claims. OIDC Humans can call only their Client's allowed custom model aliases and use stored Responses over WebSocket under their own Principal identity. Existing HS256 bearer tokens stop working after upgrade; Console exchanges its active browser session at `/oauth/token`, and Workers obtain a new Agent token through RuntimeFabric after a 401.
- Brain memory is now an AI Gateway hosted tool: any Responses request can declare `{"type": "brain"}` to let the model recall, read, and write memory as the request's own Principal inside the same Response, with optional automatic memory injection for stored conversations. Agent Turns, Background Agent Jobs, and workflow tasks use this path instead of Worker RPC tools, so memory activity still shows in chat progress and each hosted operation emits a bounded telemetry event; the `brain.*` RuntimeFabric RPC methods are removed.
- Discord and Telegram attachments now settle the inbound batch window from the moment the message was observed rather than when the download finished, and a file download that fails for one Agent is reported as failed even when another Agent on the same channel already holds the file.
- The Console API declares the shapes of recurring schedules, checkback events, and their write requests, so an invalid recurrence, delivery route, or payload answers a field-level validation error, and the Console schedule pages use the generated types.
- AI Gateway now has one stateful response start path: the test-only twin that skipped the conversation lock, the single generating-run rule, and the visible-leaf check is removed, so the test suites exercise the same admission as production.
- A turn that ends without a reply, such as a silent scheduled run, now records how it ended and which model Response ended it, so a completed event is no longer indistinguishable from one that never ran.
- A dead-lettered event now stores a bounded, redacted copy of the failure that caused it; the dead-letter notice text is unchanged. The Worker no longer reports the unused provider-fallback hint on turn failures, and the retry budget of three local attempts per model call times five deliveries is named at both ends.
- Console API bearer tokens are managed by one testable session factory, and Console request parameters are read through one shared reader, so a `false` or blank value is never mistaken for an absent one; refresh, retry, logout, and every rendered error stay as before.
- A Background Job Turn is recorded as `compaction` only when the Worker explicitly compacts the thread; an automatic compaction stays an item of the agent Turn it happened in. Rows stored before this release keep their old `compaction` label, which may have covered ordinary agent work.
- The rendered `web_fetch` fallback has one adapter path, text turns, Workflow tasks, and Jobs apply the provider-hosted web search rule in one place, and Background Jobs derive their loadable Skill set in one step; the tool catalogs and Skill sets the model sees are unchanged.
- AI Gateway reports every request failure the same way over HTTP and WebSocket: an upstream 4xx keeps its status, an upstream timeout is 504, and every other upstream or transport failure is 502, with one code and message per failure on both edges; the WebSocket previously passed upstream 5xx statuses through, HTTP error bodies now carry `type`, `param`, and safe `details_json` fields, and an exhausted credential pool reports one message on every path.
- A streaming response whose stream owner exits before its terminal event now ends with one `error` event, so an SSE request no longer waits forever and a WebSocket connection no longer refuses every later request as in progress.
- Every Worker reply is checked against the turn fence by one owner, so a late reply from a replaced Worker is rejected the same way on every path; stop and retry controls are sent once per Worker turn instead of once per steer revision, and a Worker that can no longer receive a stop, retry, or Skill-disable control is marked unusable on every path, including Skill changes, so the next turn is placed on a live Worker.
- The Console Job detail shows the runtime Turn trajectory in bounded pages, newest Turns first, with a pager for older history instead of loading every recorded item at once. Job summary pages, message results, attempt history, and thread replay read the trajectory through one bounded reader with one cursor format; a page or replay cursor issued before the upgrade is rejected as invalid and the caller starts again from the first page.
- Channel reply previews now use one SignalsGateway route for finalization and one presentation contract for callbacks, retries, and deletion. Slack, Discord, and Telegram share the same chunk ledger; version 1 preview checkpoints remain readable and convert to the host-and-adapter version 2 shape on their next write.
- Codex Background Jobs now prepare one declared execution handoff before the app-server session starts, and foreground Turns, Codex Jobs, and Automation Jobs use one execution-material lifecycle for WorkerEnv, Lark, MCPorter, and browser state. Recovery keeps the same bounded resume and fork ladder, while cleanup cannot hide an earlier execution failure.
- Skill lesson reflection now reads terminal Job signals and evidence through the Background Jobs projection instead of decoding Worker items inside Brain. The obsolete Library built-in-sync cursor table is removed automatically; Library keeps Skill registration, Agent documents, and lesson delivery.
- AI Gateway now completes a provider's short or missing terminal output from the contiguous streamed items it already recorded. A conflicting terminal item remains authoritative, while a recorded tail is no longer lost.
- Console draft editors now use one typed resource identity and one loading-versus-absence rule. A fresh cache no longer produces a premature not-found page, a confirmed missing record gets the not-found branch, and a background refetch cannot replace the operator's draft; Setup forms keep their separate non-draft initialization, the selected sign-in method card now follows the form when the operator changes methods, and the sign-in page reliably enters and leaves the required password-change view.
- Internal: the Workflow Worker-kill chaos fixture now finds its registered marker across a multi-message request, so it exercises recovery instead of accepting a generic model reply; the Codex app-server notification opt-out contract is tested separately from the durable Turn recorder; release helper CLI tests isolate subprocess input and output under the declared Bun runtime.

## Version 1.0.0-rc.5 (2026-09-03)

- Concurrent scheduled sessions now keep separate model WebSocket identities even when they share one Agent, channel, and prompt prefix, so one session no longer cancels another. Retries keep the same identity, prompt cache routing remains unchanged, and terminal failures retain their specific transport error code for recovery and diagnosis.

## Version 1.0.0-rc.4 (2026-09-02)

- Console editors protect drafts: leaving an editor page, reloading the tab, or dismissing a dialog that holds typed input asks for confirmation first, the footer marks unsaved changes, and a rejected save scrolls its error into view. The guard stands down for the editor's own save and delete exits and for in-page scope changes such as picking another Agent in the schedule editor.
- Fresh-instance dead ends now guide the operator: Signal Routing, Schedules, and Worker files explain a missing or disabled Agent and link to Agent creation, the schedule editor links to routing-rule creation, the model-profile section links to provider creation once, Brain lists link to Brain health, the readiness checklist names the missing model profiles in the app language, and the Brain maintainer-agent, observability, and tokenizer selects show their placeholders instead of the literal "null" or a raw i18n key.
- Destructive actions confirm consistently (disabling a routing rule, dismissing an identity-mapping request, cancelling a checkback with a button that names it, rolling back a Brain version in the destructive style), and Register Source is a real form that rejects blank names before the request.
- Lists keep the previous rows on screen while a search, filter, or page change loads, never across an Agent or conversation change; Brain queries commit on a debounce with an immediate clear; an empty first page hides its pagination bar; an Agent scope on the passive job, webhook, and checkback lists counts as a clearable filter; the identity-mapping queue and the home conversations panel refresh themselves, with the home panel's per-conversation message count bounded server-side.
- Provider forms and validation messages now take every setting label from the locale catalog (API key, headers, Azure and search-provider fields included), the job-trajectory labels, turn statuses, workflow setting descriptions, built-in group names, download and request-failure fallbacks, combobox trigger labels, and the sign-in and setup page titles are localized, Chinese unifies on the Agent term with an Agent shown as 已启用 and a Brain claim or source as 活跃, and built-in group names translate only while they still carry the seeded text.
- Editors title by display name, Agent pickers show display names, the principal picker's label reaches its input and stops repeating an id that equals the name, the capability-library scope selector and the identity-mapping row buttons match their neighbours' height (uikit small selects are now 36px like small buttons), a missing worker variable shows a not-found page, the providers list surfaces a provider-kinds fetch error, saving a credential confirms with a toast, and the Agent environment-variable table hides Cancel until a row is being edited.
- Setup can record the administrator's display name, so the operator's name replaces the email in principal lists and pickers.
- Release candidates are releases: a `-rc` changelog version now publishes as a full GitHub Release and moves the `main-latest` image tag; only `-alpha` and `-beta` versions publish as pre-releases on the `canary` tag.

## Version 1.0.0-rc.3 (2026-08-31)

- Brain now uses one active maintainer Agent as the execution identity and usage owner for every model call. Its `light`, `heavy`, and `web_fetch` profiles replace the former Brain extraction, Dreaming, and web-fetch settings, while embedding and rerank stay in Brain. Operators upgrading must select an active Agent and configure the needed profiles; disabling it stops all Brain model calls and local URL fetching until it is enabled or replaced, while stored knowledge and pure-text recall remain available.
- URL Source learning now uses the Worker's local `ankole-browser` when the maintainer Agent has no `web_fetch` profile or the Provider request fails, with that Agent's environment and web security policy.
- Release candidates now advance the `main-latest` image tag without moving `canary`; only alpha and beta releases move `canary`, and release candidates remain GitHub pre-releases.

## Version 1.0.0-rc.2 (2026-08-30)

- Console editors now stop an incomplete save in place: the page focuses the first missing or invalid field and shows a message in the app language next to that field, instead of a generic English "request failed" banner. Leaving a required field empty flags it as soon as you move on, with the same timing in every editor. Draft problems and real request failures now use separate banners.
- A save the server rejects now names the exact problem in the app language: missing or invalid connection fields on routing rules, identity providers, and structured settings values. The Brain object editor picks the type from the installed list and shows the slug format rule, and duplicate, reserved, or malformed slugs and types get clear messages. The Brain settings drawer marks its required model fields, blocks an incomplete save at the field, picks the provider from the configured provider list, and suggests catalog models per slot — embedding, rerank, or conversational — while still accepting a typed model id; empty dropdowns now show a select prompt.
- Agent chat replies no longer leak internal markers into a channel. Provider server-side web-search citation tokens and the silent-success sentinel are stripped from every channel-visible reply, so a message shows clean text instead of stray citation glyphs or a raw `<silent_success/>`. On an ordinary turn, a reply that held only the sentinel now asks the model once for real content instead of delivering the marker.
- The release-candidate review adds a few repairs: upgrading from a stored blank Agent display name now uses the Agent uid for its Brain object title instead of failing the migration; recalled-memory neutralization also covers the agent-environment-info envelope and escapes every bracket occurrence in a matched tag; a soft-deleted Brain object no longer surfaces to the model through a page read; and the Discord, Telegram, and WeCom connection reconcilers keep a working connection when another binding's configuration is incomplete, matching the Lark, DingTalk, and Slack behavior. The test suite also drops unused aliases, imports, variables, and a stray helper carried since the release candidate.
## Version 1.0.0-rc.1 (2026-08-30)

- When `remember` omits its scope in an IM conversation, it now uses the asker's Principal or the channel's member Group; an explicit writable scope still follows the Agent's confidentiality judgment. Malformed or fully rejected learning output remains retryable instead of being marked learned, and Source revision, archive, and long-content fences have stronger regression coverage. Archiving a Library Source now withdraws its managed pages from every entrypoint, Brain searches treat wildcard characters literally, internal control claims stay out of Console results, and `remember` supports a validated resolution date for takes. Recall, context, page reads, and synthesis now use the same conversation reader set, synthesis links only its real evidence pages, and self-healing applies the normal semantic deduplication rules when it rebuilds embeddings after an outage.
- Provider failures before output can be retried safely, PostgreSQL notification listeners reconnect after a database restart, terminal replies no longer show stale running activities, and repeated web fetches reuse clean results through one bounded Worker cache keyed by conversation or Codex Job. A control-plane restart now renews leases for live Workers before stale-turn recovery, so their in-flight turns can finish without dead-lettering or duplicate effects, and retryable internal failures while saving an idempotent Job turn checkpoint retry the identical request. Lark and Slack binding saves request an immediate connection reconcile, while an invalid replacement Lark identity no longer removes the working connection.
- Setup industry and plugin selections now update immediately under React Compiler by exempting only their Set-backed selectors from compiler memoization. Exact custom model IDs remain selectable, an external Principal without a local credential can be edited without inventing an email, and valid ambient replies survive irrelevant work authority while unrelated group conversation remains silent. A disabled Agent's delete action is available immediately after the disable confirmation closes, and Brain Health replaces unexpected provider, projection, and stored-setting details with plain localized messages while retaining the full cause in server logs. Provider subject IDs again match the installation-wide Principal namespace after email and mobile matching, so equal normalized subject IDs across providers deliberately share one Principal when contact matching misses; an existing explicit provider binding still wins. Lark now uses the normalized email itself as `external_id`, then falls back through `user_id`, `union_id`, and `open_id`, while binding every available fallback ID to the same Principal.
- The real-model and fault-injection suites now use the release DeepSeek and Qwen model matrix, current trajectory and tool-offset contracts, deterministic retry targets, race-free reconnects and Workflow wakeups, and collision-free disclosure fixtures; the release-candidate manual E2E pass also adds regression tests for every product repair found during the run. Internal write-scope, Library withdrawal, adapter polling, connection blocking, reply terminalization, and editor and Brain validation decisions now each have one explicit owner. Brain page grammar now runs in the native kernel as CommonMark through comrak plus one root `audience` tag and `[[slug]]` links; it rejects ambiguous tag positions and treats tag text in code as code. Source-learned media bodies are now read-only Source projections, and Console operators can create or edit instance Objects through a raw-source editor with scoped preview, line diagnostics, and conflict-safe saves. Contributor guidance now makes changelog entries historical records only, removes the unapproved alpha.6 provider-scoped identity claim, and forbids using changelog text as a product contract or design decision.

## Version 1.0.0-alpha.10 (2026-08-27)

- Agents can now learn external web material in conversation: the new `learn_source` memory tool registers a public URL and runs the learning pipeline in the background. A newly registered URL Source defaults to the registering conversation's audience — a DM registers it for its asker, a group chat for its member group, and `world` is an explicit choice; later calls for the same URL reuse that Source and report its existing audience. The Brain Agent Plugin's `brain-learning` Skill routes material kinds and scope judgment; the `brain-memory` Skill is removed, with its filing rules moved into the `remember` tool and its vocabulary lookup replaced by the rejection error itself, which now names the closest vocabulary terms (this also fixes the vocabulary file being unreadable in packaged releases).
- The system prompt now explains the Agent's own memory model — the shared Brain, automatic conversation learning, Dreaming maintenance, and the duty to repair memory when corrected — and `ConfidentialityPolicy.md` now materializes into Agent Home like `DESIGN.md`, so the scope guidance the memory tools reference is readable and stays read-only inside the shell sandbox.
- Product and Agent Plugin knowledge directories can now project world-visible, recallable pages into Brain and update them with the installed files. These managed pages are read-only — fork an ordinary knowledge page in the Console (`POST /brain/objects/fork`) to take it over — and an instance page at the same slug always wins. Removing a set soft-deletes its pages without purging attached claims and links, and restores them if the set returns; archiving its Library Source permanently withdraws the whole set.
- The Brain Agent Plugin now ships Skills that Brain discovers from their names, descriptions, and tags without listing them in every prompt (`idea-lineage` and `applied-reading`). Current Plugin and Skill settings gate discovery and loading without deleting the shared projection; Recall points the model to `skill_view`, `get_page` delegates to the same loader, and Background Agent Jobs now use Ankole `skill_view` instead of Codex native Skill discovery.
- The Brain Agent Plugin grows an applied method set adapted from GBrain (MIT, recorded in the Plugin's third-party notices): `brain-learning` now also routes recordings, files, and meeting transcripts, captures a person's own ideas verbatim, and owns the memory write and repair discipline; the new `resolve-before-asking` Skill exhausts memory before the Agent asks who someone is; `idea-lineage` traces how one idea evolved through memory; `applied-reading` turns a book into a whole-life mirror or a problem-lens playbook. A pre-upgrade Job migrates its stale native Skill roots once, preserves its Workspace instructions, and replaces its frozen Codex thread, so a disabled or updated Skill follows the current loader after resume.
- The Console shows library pages as such: the Object list and detail carry a Library badge, and ordinary library pages hide forget, restore, and rollback actions behind an explanation and offer Fork with a confirmation that states the trade (editable, but no longer updated with the product). Lazy Skill discovery pages instead explain that Agent Library owns their availability and link there without offering Fork or Object lifecycle actions. Library sources get a readable kind label, and their archive confirmation states that archiving permanently withdraws the whole page set and cannot be undone — in all four Console languages.
- Conversation learning no longer files one named entity under two memory pages: before extraction runs, the pages the conversation already names (by exact alias) are listed in the extraction prompt with the rule to reuse their slugs instead of declaring new pages.
- The Console gains a Brain merge queue: a daily mechanical scan pairs look-alike pages of one type (shared alias or near-identical title) for review, and approving a pair merges it — every claim, timeline entry, tag, alias, and link moves to the surviving page and the old slug becomes a redirect. Nothing merges automatically, a rejected pair is never suggested again, canonical Principal pages never merge away, and reviewed or Principal-only prefixes cannot starve later candidates from the queue.
- Brain recall now fails closed when an IM recipient set cannot be resolved, and a scheduled reply checks every delivery target. Recall and background maintenance exclude claims on forgotten Objects, vector comparisons use the signature of the runtime model that produced them, and learning from a group or direct message cannot widen its audience to the whole instance. Recalled memory and runtime environment values cannot close their model-data envelopes.
- Foreground ambient replies now receive only read-only local tools and hosted web search. Console claim search runs before the 100-row display limit and treats SQL wildcard characters as text, Unicode and percent signs in Object paths no longer crash the page, and irreversible source archive and suggestion rejection actions require confirmation.
- Delayed or retried Brain maintenance keeps its original cron minute and retries enqueue failures, and one invalid Library inventory no longer prevents the same self-healing sweep from repairing other Brain projections. Manual identity mapping cannot reassign an existing provider subject. Known and missing email sign-ins now receive the same retry limit; the in-memory key set is hard-bounded and fails every email closed when saturated. Telegram sends images correctly and advances past permanently invalid updates; Telegram and Discord split Unicode-heavy replies within provider limits. Lark, DingTalk, and Slack keep live connections when desired configuration is incomplete.
- RuntimeFabric now has one protocol-version owner in the kernel and only the current version 5 contract and fixtures. Operators must stop existing Workers and deploy the control-plane and Worker images from the same release. Direct upgrades to this release are supported from v0.62.2 or a later stable release; fresh installs start from one v0.62.2 schema baseline, published stable migrations stay intact, and unpublished alpha schemas are not migration states. Stored values from supported stable releases are still normalized or read where needed. Agent-installed Skills now have one model-catalog rule: every enabled Skill enters the catalog; no shipped Skill uses `disable-model-invocation`, so that frontmatter field and its runtime plumbing are removed. Unconsumed Skill summary fields are also removed.
- Replying to a failed Agent message with `/retry` now retries that exact ActorEvent, including scheduled work in its own Session and replies whose confirmed provider send could not be mirrored locally. A bare `/retry` controls only live work and otherwise asks for an exact reply or ActorEvent reference, so unrelated channel completions are never selected. A failed retry attempt no longer blocks a later exact retry, and an unavailable target now tells the user to send the original request again.
- Main Agents can now start a durable Workflow that runs a fixed JavaScript program, fans bounded work out to independent subagent turns, combines structured results across stages without another parent-model turn, and wakes the owner Session when it completes or fails. Operators can cap calls and concurrency with the new `workflow.*` settings; Workflow tasks cannot create nested Workflows. Retrying one create tool call returns the same run. Queued tasks start when a capacity slot opens, up to four kernel replays run at once and retry after 30 seconds when busy, large fanouts enforce the 6 MiB memo limit without re-encoding prior task history on every result, and read-only Brain access remains usable when a page is a lazy Skill discovery record.
- Workflow tasks can now hibernate and wake: a task delegates one or more Background Agent Jobs, sleeps without holding a worker slot, and wakes in the same conversation when a delegated job finishes, when the main Agent messages it with the new `send_message_to_workflow_task` tool, or at its sleep deadline. A task blocked on a decision escalates with an attention note that wakes the main Agent at most once per hour per run, and `show_workflow` now lists live tasks with their status and waiting notes. When a run ends, no task can create or continue a delegated Job across the terminal transition; stop cleanup retries after a process restart until every task and Job is stopped. A dead-lettered Workflow completion notice now delivers the run outcome directly, like job notices.
- The default Workflow fanout ceiling drops from 256 to 32 Agent calls per run; raise `workflow.max_agent_calls_per_run` to keep larger runs.
- A real-LLM end-to-end suite now drives the whole Workflow lifecycle over fake Feishu — fanout, sleep and wake, attention escalation with an owner answer, Job delegation, failed-run channel replies, the failed-task null contract, cancel that stops a delegated job, a free-form run whose script and task prompts the model writes itself, and Brain embedding/rerank against the configured qwen models — and it caught that Workflow completion replies never reached the channel, which is fixed. A chaos scenario now kills the Worker mid task turn and proves the watchdog requeue and a replacement Worker finish the run, and new tests pin the task mailbox timing and the dead-lettered Workflow completion notice.
- The Skill lesson reflection log now counts rejected field notes by the gate that blocked each one, so operators can tell harmless duplicates from a reflection that keeps proposing the same blocked note.
- Internal: external identity binding, Workflow persistence and terminal cleanup, asynchronous work failure policy, Brain Source state and Console reads, local-password credentials, Turn request projections, RuntimeFabric RPC response types, the pi stream cursor, and UTF-8 byte trimming each have one owner. RuntimeFabric now checks each Control Plane RPC response against its generated type, representative request and response bytes decode identically in Rust, Elixir, and TypeScript, and Skill lesson overlays carry typed text instead of JSON-wrapped text. Workflow boundary maps use one key shape. Agent Plugin and Skill runtime catalogs now resolve together in the conversation context, connection teardown accepts only explicit complete or incomplete snapshots, and Workflow task helpers stay private. Product behavior is unchanged.

## Version 1.0.0-alpha.9 (2026-08-27)

- The ChatGPT account dialog now reports the real sign-in failure — the upstream HTTP status and error code, a denied or expired login, an unreachable sign-in service, or an unreadable stored credential — instead of "provider configuration is invalid". ChatGPT sign-in and token refresh follow the HTTPS_PROXY/ALL_PROXY/HTTP_PROXY/NO_PROXY environment like model traffic, send Proxy-Authorization when the proxy URL carries credentials, log a warning instead of silently connecting directly when the proxy value is unsupported, and each credential-refresh failure writes a warning log with its upstream cause.
- Console API errors stop leaking raw internal terms: a known configuration or sign-in mistake names the violated rule, and an unexpected failure answers with a plain message and a server log entry.
- An IM sender observation no longer renames a user who already has a display name; only directory sync updates names. Conversation lists and details now advance their update time with new messages, so ordering follows last activity.
- Disabled agents stay visible: the agent list shows every agent with its status, a disabled agent can be re-enabled or opened in the editor, and deleting follows the provider pattern — disabling first, then a second delete permanently removes the agent and its records with a matching confirmation and toast. Pickers that target new work — signal routing rules, schedules, and the worker file browser — offer only agents that can run. The Website agent guide and Console API reference describe the new lifecycle in all four languages.
- Console polish: computed groups show "—" instead of a 0 member count, the signal-source group type is translated and missing settings descriptions are filled in across the four languages, Brain health shows a plain reason instead of a raw error and formats queue age as a duration, conversation details carry a page title, principal and membership pickers match UID searches, and the Chinese disabled-status label is "已停用" everywhere.

## Version 1.0.0-alpha.8 (2026-08-27)

- Telegram and Discord connections survive hostile and busy conditions: a forged Telegram callback token no longer wedges the poll loop on one update, a Discord event backlog at the queue bound now sheds what a resume can replay instead of reconnecting forever, reconnect backoff resets on durable progress rather than on every resume handshake, and two Agents that name their bindings identically no longer overwrite each other's bot token. Reaction lookups no longer leak into another chat whose numeric id extends the reacted chat's, and mention removal follows the message's entity offsets, so a username that extends the bot's stays intact.
- A half-delivered multi-message reply now reaches an operator as a delivery problem on both Telegram and Discord instead of failing silently, and a Telegram reply reposted after a human deleted it keeps its reply anchor.
- The Worker agent loop regains three guarantees the pi runtime swap had dropped: per-tool trace spans, a repeated-failure warning that counts blocked and unknown-tool calls and keys on the exact failing call rather than the tool name, and the one-nudge-then-repair recovery ladder. Declaring a tool's execution mode is now mandatory, and a parallel tool must be read-only and not destructive.
- Memory recall now ranks with the kernel's real fused scores, so a result that both search routes found keeps its full margin through confidence and recency weighting. A source-learning run whose extracted items all fail validation now rolls back whole and retries later instead of erasing the previous revision's knowledge and recording the source as done. A failed signal-source group write now refuses the message for retry instead of admitting the sender with a narrower permission surface, and a decided memory contradiction can no longer be flipped again.
- The Console brain settings gain the two skill-learning keys (enabled and reflection threshold), the cron editor no longer keeps a stale mode after a restored setting, and the identity-mapping pages use the single-principal picker that shows the current selection.
- Trajectories recorded before 2026-08-13 no longer render: the item stream is the only readable form, old Turn pages show empty, and the retired trajectory-group storage is dropped. The retired ambient two-valued decision column and the unused quantitative claim fields are also removed.
- The BrainV3 and Skill Lessons design documents now exist in English at the referenced paths, and the READMEs describe Brain again, including the PostgreSQL `pg_search`/`vector`/`pg_trgm` requirements.
- Internal: local sign-in credentials, take calibration, and the hosted-response size budget move into their own modules; email normalization, reflection-job filtering, current-fact queries, and budgeted image walks each collapse into one owner. Behavior is unchanged.
- One Background Agent Job that fails while finishing no longer takes the whole Worker down with it, so the Jobs and conversations sharing that Worker keep running. A Codex runtime that floods its output without a line break now ends alone instead of exhausting Worker memory, and preparing a task cannot leave a listening socket behind when it fails part way.
- Queuing a file for reply delivery now reads only the file's size, so a very large file no longer risks the Worker's memory, and a path outside the Agent's user files is refused before the file is touched at all. A file read reports failure when its path became a different file during the read, even when the replacement has the same size and timestamp.
- A provider that answers a rate limit with a malformed `Retry-After` no longer parks a turn on a value read out of the junk, and a legitimate but very long wait is now bounded.
- The `todo` tool rejects a malformed task list with a clear message instead of storing repaired placeholder items, and the memory tools now reject an off-grid confidence or weight and an unparseable date bound where the agent can see it, rather than after a round trip to the control plane.
- Shutdown no longer waits out a timeout for its final trace export, so a Worker stops faster and keeps the last spans of its run.
- The main agent gains three workspace tools: `find` searches file paths fuzzily over a warm in-process index ranked by relevance and recency, `grep` searches file contents with smart-case and auto-detected regex grouped by file, and `ls` lists one directory deterministically. All three stay inside the Agent Home, so every result is a path the other tools can open.
- A shell command whose output was truncated now saves the pre-truncation text under `~/.ankole/command-logs/` and reports the path, so the agent can read the dropped middle back. An oversized `read_file` page now returns the lines that fit the budget with the exact offset to continue from instead of rejecting the read.
- Console menus, dialogs, and side panels now start immediately and stay interruptible: sheets slide from the screen edge, expanders reverse mid-motion, and the readiness bar grows without reflow. Table and nav hover paint no longer stick after a tap, Brain and Access tabs fade their rule instead of jumping it, and the theme control replays its mark.
- Browser session loading and durable Worker turn replay now distinguish absent data from malformed or unreadable data, so corruption fails clearly instead of silently starting from empty state. Brain context lookup failures also reach the Worker log.
- The Website now describes Brain directly as a world model that learns from experience. Internally, Signal Adapter OpenAPI types match the runtime field contract; redundant AI Gateway mapping and telemetry layers, unsafe Console casts, and a Console import cycle are gone; and direct control flow replaces avoidable nesting across production code.

## Version 1.0.0-alpha.7 (2026-08-25)

- Upgrading deletes the previous Brain memory storage permanently: entries, bodies, relations, episodes, audit history, and retained source material do not survive, and no migration into BrainV3 exists. Conversation knowledge relearns automatically from the retained channel message history once the `brain.*` models are configured; manually curated memory and uploaded source files do not come back, so export anything you need before you upgrade.
- Agents gain BrainV3 long-term memory: one instance-shared knowledge space with scope-based knowledge and disclosure boundaries, `remember`/`recall`/`get_page`/`forget`/`entity`/`whoknows`/`synthesize`/`delta` tools, automatic batch learning from IM channel conversations, file and url source learning, and zero-model context packs plus volunteer pointers injected into turns. A `synthesize` page inherits the audience of the evidence it reasons over, so a conclusion never reaches more people than the facts behind it, and evidence that the page cannot carry stays out of it. A context pack also carries what each participant told the agent in that chat when the claim named no page, while a volunteer pointer names only a live page the message itself names, instead of repeating recently touched pages on every turn. Url sources fetch through the web-fetch provider configured in `brain.web_fetch_model`, so pages become readable text instead of raw HTML; source learning runs as a background job, covers the whole content of large sources, and relearning a changed source expires the claims of its previous revision. The BrainV3 design document and the shared vocabulary seed ship with it.
- Setup adds an industry schema-pack selection step (the general pack always installs; six industry packs are optional), and existing completed instances gain the general pack on upgrade. A daily Dreaming task maintains memory (consolidation, cross-page synthesis, link extraction, salience, take grading, calibration scorecards, contradiction probes, promotion suggestions, purge) and a Self-healing task rebuilds stale chunk, embedding, and search-index projections; both schedules and all memory models live under new `brain.*` settings with a dedicated Console editor.
- The Console adds a Brain area: object browser with version history, rollback, and restore of soft-deleted objects inside their purge window, claim management with supersede/forget, take resolution, contradiction triage, promotion review, learning-source management, any-principal search preview, per-principal knowledge audit, and a health page that also reports invalid stored `brain.*` settings, unavailable model providers, and context-pack injection counters.
- Every Agent now requires a human owner Principal (existing Agents backfill to the earliest administrator) and carries a group-memory disclosure mode (strict or relaxed). A scheduled turn — a cron fire or a check-back wakeup — has no asking sender, so it takes its memory disclosure recipients from the channel it delivers into and checks every one of them. `ConfidentialityPolicy.md` joins the editable Agent documents; IM group member Groups now mirror joined Agents as members. The per-Agent `embedding` and `rerank` model profiles are retired: operators must configure `brain.embedding_model` and `brain.rerank_model` instead, and API callers can no longer use the `embedding.default` or `rerank.default` selectors.
- Agents now learn per-skill field notes from their own job history. Once an agent accumulates enough jobs that carry mid-run human corrections or failed tool calls (`brain.skill_learning_reflection_threshold`, default 10), a reflection background job distills that evidence into short leased checklist notes; accepted notes appear under the skill's `Agent-specific additions` block, every note is re-checked when its 7-day lease ends or when the platform release or the skill body changes, and a note whose condition died is retired automatically. Mechanical gates bound the loop: a note needs two independent evidence jobs (or one with human input), at most 2 land per skill per reflection and 10 stay active per skill, and note text can never contain a URL. `brain.skill_learning_enabled` turns the whole loop off. The design lives in `docs/design-docs/SkillLessons.md`.
- Operators manage skill notes on the Agent Library page: list active and retired notes with their evidence jobs, add permanent notes by hand, and retire any note — an operator-retired note is never learned again. The skill-overlay editor and its Console endpoints are gone, and the worker loses the `skill_append` and `skill_replace` tools: an agent no longer edits its own skill guidance mid-task. Existing overlay texts migrate automatically into operator notes, and the Brain health page reports note counts and drift signals.
- The Website explains Brain and Agent-specific Skill lessons in English, Simplified Chinese, Japanese, and Korean. Its Agent, architecture, Signal routing, model, cost, AppConfigure, and Console API guides now use the same memory, disclosure, lesson, and instance-wide model contracts.
- In **May intervene** group chats, Agents now route each new message batch to silence, a bounded foreground reply, new work, or one matching live background Job. Substantial work without a direct request or standing-order authorization asks for confirmation before it can start, foreground replies cannot create Jobs, and a silent Job handoff commits with the channel judgment so retries cannot change its target.
- Background jobs gain read-only Brain `recall` and `get_page` tools, and the deep-research plugin now consults instance memory before external search. A job cannot write memory, so the agent that delegated it files the durable conclusions when the job returns. `remember` accepts an `until_date` on take-kind claims, and deep research registers report predictions that carry a resolution date as gradable Brain takes, feeding the existing calibration scorecards.
- Deep-research jobs tighten their evidence loop: collector threads now also report counter-evidence they ran into, follow-up collection aims at the weakest points instead of re-collecting what already has independent support, and the verifier re-derives the measurements a conclusion rests on by a different method, reports where the conclusion would flip, and flags a conclusion that is safe but adds no information as a defect of the same rank as overclaiming. A new `scientific-research` Playbook adds derive-with-code, primary-literature, and identifier-exactness practice for science and mathematics tasks.
- web_fetch answers a URL repeated within one session from its earlier result instead of downloading the page again, and labels a script-shell or zero-text page with what to try instead of re-fetching it.
- A tool call that the model's output token limit cuts off now enters the conversation as the call together with a standard error result, and the model retries once from that record. The job trajectory shows the failed attempt instead of a synthetic message that described where the arguments stopped.
- Feishu and Lark requests work again: the previous release combined two Req transport options that Req 0.7 rejects, so every OpenAPI call failed before it reached the network. Both default timeouts now travel in the one accepted option.
- Internal: the fake Feishu test server accepts an explicit chat id from its CLI and regenerates its chat-id token on every server start, including a restart inside one OS process, so no run can reuse a chat that an earlier incarnation already mirrored. Every generated id — messages, events, reactions, file and image keys, cards — now carries that per-boot token too, so a restarted platform can no longer mint a message id that a connected control plane already mirrored from an earlier incarnation and have the new message silently treated as an edit of the old one.
- Internal: parallel control-plane tests no longer fail at random. An AppConfigure cache miss now reads the database in the requesting process and the after-commit refresh reads as the writer, so a concurrent test that clears the cache cannot make outbound delivery in other tests lose the worker auth key, and the advisory-lock timing test uses its own lock key instead of the shared fixture identifiers.
- Internal: the end-to-end suites create their agents with the human owner that Agents now require, so the gate suites run again instead of failing at setup.
- Internal: Background Agent Job creation now pins the Job's owner conversation itself on every creation path, so no creator supplies it. This also gives the successor Job that open steers seed after a run ends a conversation, which it had none of and without which it could not start.
- Internal: the fake Feishu server now serves the reaction list endpoint the Lark adapter uses to find its own reaction before it removes one, and the transport end-to-end test sends the emoji key the adapter accepts, so the reaction gate test exercises the real removal contract.
- Internal: the Agent Computer integration suite no longer expects the retired standalone compaction endpoint, so the suite runs without a false failure.
- Internal: Worker command-activity labels now come from one vocabulary table instead of branching code, the sandbox command environment builds its documented layering directly, and the Codex job runner names its repeated diff-accounting step. Behavior is unchanged.
- Internal: the Codex notification projection now parses every runtime notification the job session observes, so the session dispatches on typed variants only. A background Job's progress summary can now also report item starts, MCP server startup failures, credential-pool exhaustion, and compaction completion.
- Internal: Worker images now pin Codex 0.150.1; AIGateway model cards and app-server protocol bindings match that runtime.

## Version 1.0.0-alpha.6 (2026-08-22)

- Direct upgrades to this release are supported only from v0.70.0 or later. RuntimeFabric no longer accepts the terminal envelopes retired before that support window, so an installation older than v0.70.0 must not upgrade directly.
- Cron schedule creation and route updates now accept only `delivery.targets`. The v0.68.3 upgrade already migrated stored schedules; API or Worker callers that still send scalar `signal_channel_id` and `provider_thread_id` fields must send a target list instead.
- AIGateway message rows and the Console API no longer expose one row-level `role`, because one Response run can contain items with different roles. Callers must read roles from the items in `content`; the upgrade drops the obsolete database column automatically.
- Moving a signal binding now keeps its group-message mode when the request omits it, instead of resetting it to the default. The retired `confidential_memory` setting is removed from binding storage, the Console, and the Console API; API callers must stop sending this field, and the upgrade drops the unused column automatically.
- Feishu and Lark OpenAPI requests keep the five-second connection-pool wait without emitting Req's deprecated `pool_timeout` warning.
- Setup now records the administrator's role and the completion flag in one transaction, so a failure part way through can no longer leave an installation that is claimed but unfinished. A wrong activation code no longer changes the installation language, the first forced password change checks administrator rights before it writes the new password and cannot be repeated with a copied link, and simultaneous group-membership changes no longer fail with a database deadlock.
- A reply that the chat provider acknowledges late can no longer overwrite the outcome that recovery already recorded, which removes a source of duplicate and lost replies. `/stop` during an active steer now cancels the reply that is really generating, an attachment that replies to an older message starts the next turn instead of joining the running one, an attachment from the same sender is still found in busy group channels, and deleting one message no longer blocks unrelated conversations in the same channel.
- Discord is now available as a chat provider. Give a binding the bot token from the Discord Developer Portal and the agent reads direct messages and guild channel messages, replies in the same channel or thread without triggering Discord mentions, keeps editing one running reply instead of posting a second answer, adds and removes reactions, sends attachments, and answers button clicks. Gateway reconnects keep received events in order, and each thread is a separate agent session.
- A Discord application must have MESSAGE CONTENT INTENT enabled in the Developer Portal before the "observe all" and "may intervene" group modes can work, because Discord otherwise delivers guild messages that do not mention the bot with no text at all. Without it the connection still serves direct messages and messages that mention the bot. An application that has an Interactions Endpoint URL set receives its button clicks at that endpoint instead of through Ankole.
- Removing a reaction on Lark now works instead of sending an invalid request. Lark, Slack, WeCom, and DingTalk connections stop when their binding is disabled, deleted, or given new credentials, so an old connection can no longer keep running or block its replacement. Five stream adapters now share one periodic reconcile lifecycle while keeping their provider-specific connection and message logic. Microsoft Teams channel synchronization stays inside the Microsoft app that owns each channel, one unreachable team no longer stops the whole synchronization, and a partly failed Microsoft Graph subscription setup no longer leaves subscriptions that Ankole cannot track.
- A reply that stops at the model's token limit is now reported as incomplete on non-streaming calls, as it already was on streaming calls. AWS Bedrock non-streaming replies return their text and token usage instead of an empty completed response, a hosted image request stops with a clear error after 16 internal rounds, and a change to a provider's configuration applies to its model catalog at once instead of up to an hour later.
- Native image models can now read files and generated images that you already sent to Ankole, including when you use one as an edit mask. An image they produce is stored under an Ankole artifact id and stays available for later requests, and a failed image in a multi-image request points at the correct output.
- A stateful response that cannot record its failure no longer reports that failure to the client while the stored response stays in the generating state. The client now receives a terminal response only after the durable record has that terminal result.
- Job trajectories now come from the recorded item stream and load one page at a time, so opening the details of a long job no longer reads its whole history first. Jobs recorded before the item stream keep their current content, order, and paging.
- Worker command output and file reads are now bounded while they are produced, so a command that writes without limit can no longer grow the Worker's memory. Browser page snapshots stop processing more accessibility nodes when their text budget is full; what the model receives is unchanged. A command that ignores the stop signal after its timeout is now forced to exit.
- One-shot model requests no longer hold a scheduler thread for the whole request, so several slow requests can no longer delay other native work, such as delivery to Workers. An unusually large `Alt-Svc` cache hint from a server can no longer stop a request, and one oversized provider event batch now fails with a clear error instead of passing the pending-event limit.
- Console fixes: a schedule can use a conversation id that is not in the suggestion list, the setup page shows the selected language at once and a slower earlier catalog load cannot switch it back, a double click on Save sends one request, a provider whose kind is no longer available is marked as unavailable with its edit actions disabled, and a malformed identifier in a Console API address returns a normal not-found result. The Console API description also no longer offers a model-profile `compaction` capability that the runtime does not accept.
- Documentation links in the architecture diagram and in the Japanese and Korean pages now reach pages and sections that exist, and the Korean architecture page shows the diagram in Korean. The Jupyter live-kernel Skill writes the kernel's original output to the notebook, so images and other rich output display again, and a clean run clears every code cell first, so a run that stops early leaves no stale results.
- Internal: reading a Skill no longer rewrites its registry row when nothing changed, and new job turns no longer store a second copy of their content.
- Internal: the website build now rejects links to missing internal files or page anchors, including links in serialized Astro island properties, and lists each source page and target. The repository no longer retains Astro's obsolete data-store cache.
- Internal: the Agent Computer type check now also rejects a missing `override` keyword, a switch case that falls through, and an import that is used only as a type. A write-only model-call field, an unread session flag, and an unused path parameter are removed, and the Worker logger selects its pino level through a declared level type instead of an untyped lookup.
- Internal: control-plane tests remove implementation-only duplication, avoid live provider access, and run more cases in parallel.
- Creating an Agent now writes its whole builtin Skill library in one statement instead of one per Skill, which takes the operation from 31 database round trips to 11 and about halves its time. Every Skill row still goes through the same validation before the write.
- Internal: starting a Turn now resolves the two BackgroundAgentJob placement limits before it opens its database transaction instead of inside it, so the transaction no longer waits on the settings owner for a value that has nothing to do with it. A terminal status commit stops resolving a limit it then discards. The capacity counts still run inside the transaction, so admission keeps its guarantee, and the control-plane suite drops from about 200 to 119 seconds.
- Internal: the Agent Computer now gives the Worker process lifecycle, active Turn state, execution materials, sandbox, Text Turn tool assembly, and Codex Job/runtime code separate module owners. SignalsGateway names channel-reply eligibility without treating all Signals as IM, and the Codex Job update poll names every Worker-local update queue that it drains. Comments preserve the non-local ownership, durability, and shutdown constraints; Worker behavior and external contracts do not change.
- Console timestamps now use the browser's standard date and time format for English, Chinese, Japanese, and Korean. Blank timestamps still show an em dash, and invalid values remain visible.
- Internal: the single-control-plane release no longer starts or configures DNS clustering, and its boot-order guides no longer list it. Dependency manifests remove an unused direct HTTP/2 declaration, an unused direct MessageFormat package, and the date library replaced by the browser formatter, and declare the websocket client that the Discord gateway connection uses. Devkit now uses the TypeScript version required by Crust.
- Long provider streams no longer rescan the whole pending SSE event for each network chunk or merge an earlier LF-delimited event with a later CRLF-delimited event. Streamed tool arguments and reasoning grow without copying their full accumulated text, hosted image limits no longer allocate a decoded image only to count its bytes, and an output event that cannot fit its downstream budget now returns a size error instead of ending as if the client cancelled.
- Internal: hosted responses count their growing public shape without copying earlier images or request history for each output item; AuthZ and Signal filters share compiled rules by source text without allocating lookup keys; RuntimeFabric NIF sends avoid an envelope copy, command waits wake without a fixed poll delay, and Dealer receives keep one total timeout; program replay moves its validated memo and tool map instead of cloning or validating them twice.

## Version 1.0.0-alpha.5 (2026-08-22)

- Worker tool failures reach the model with the failure marker and recovery hint again; a tool call with unparseable arguments fails alone and recoverably instead of failing the whole reply; and a reply-ending tool call (such as a clarify question) now ends the reply even when the model called another tool in the same round, holds queued user follow-ups for the next turn, and delivers several queued follow-ups in one model round instead of one round each.
- Worker sandbox `read_file` failures other than a missing file report the real operating-system error again; a namespaced tool call now runs the tool of its own namespace when two connected tool sources share one tool name, instead of whichever registered first; and a call to a tool that does not exist again returns the marked `Unknown tool` failure instead of an unmarked engine message.
- Moving a signal binding to another agent now keeps its "When account auto-mapping fails" setting when the move request omits it, instead of resetting it to "Hold for manual review".
- An unmatched sender whose admission group name collides with an operator-created group of the same name now records a clear failure instead of crashing the inbound message, including when the sender already belongs to that colliding group. Internal cleanups remove dead memory-source residue in reply rendering, a stale Brain metadata key in the real-LLM e2e suite, and the retired `--brain-real-llm` documentation, and align the chaos delivery-failure suite with the 1.0.0-alpha.4 provider-error classification.

## Version 1.0.0-alpha.4 (2026-08-22)

- Plain-message delivery failures on DingTalk, Lark, and Microsoft 365 now retry, wait for an operator, or stop according to the provider error, and honor the provider's requested retry delay, instead of repeating until the attempt budget runs out.
- A DingTalk or WeCom reply preview that hits a permanent or operator-level provider error now records its blocked state and stops repeating the failed recovery attempt.
- The console email field now stays editable for accounts with a linked external identity, which completes the email-edit change from 1.0.0-alpha.3.
- Empty, failed, stopped, and awaiting-input final replies now use the installation language instead of fixed Chinese text.
- Console, sign-in, and setup pages load much less JavaScript up front: the name-transliteration table, the Markdown renderer, the JSON tree editor, and the language catalogs now load on demand, and the shell preloads the active language. The sign-in page ships roughly half its previous script weight.
- Dark-theme operators no longer see a light flash on every full page load, and each Console page now names its own browser tab and history entry.
- A batch of Console interaction fixes: fast typing in a list search box can no longer lose trailing keystrokes to the debounced URL commit, a background refresh no longer clears form validation or decryption errors, a revealed secret always re-masks when its reveal is revoked, oversized tool payloads no longer pay for a JSON parse that cannot succeed, and the ChatGPT device-login countdown no longer restarts on unrelated re-renders.
- Large webhook lists stay responsive while searching, long conversation threads render faster, and the time-zone picker builds its option list in half the work.
- Internal: shared Console components narrow their contracts — a read-only editor page cannot receive submit props, capability toggles split into explicit global and per-agent controls, and one unused prop is gone. Users do not see this.

## Version 1.0.0-alpha.3 (2026-08-21)

- Ankole now has built-in local accounts. The setup wizard step becomes "Configure user sign-in" and can create the administrator with an email and password, and the sign-in page accepts email and password next to SSO. No external SSO provider is needed to start.
- Console principal management can add local users with generated one-time initial passwords, force a password change at first sign-in, reset passwords, and edit a user's display name and email. These controls appear when the local identity provider is enabled.
- Password retry protection allows at most 5 failed sign-in attempts per account inside a 30-minute window; further attempts must wait, and a password reset ends the wait at once. It is on by default, and the local provider configuration can turn it off.
- A new rescue command resets a local account password by email: `mix ankole.local_password.reset` in development, `bun kit local-password reset` from the devkit, or `Ankole.Release.reset_local_password/1` on a production release.
- Telegram is now available as the first consumer IM Signal adapter. One encrypted Bot token connects one enabled binding through supervised long polling with durable ingress; the adapter receives direct, group, forum-topic, reaction, and card-action input and sends mutable replies, attachments, reactions, dividers, and cards. Telegram cloud downloads above 20 MB remain as explicit unavailable attachment records, and rate limits follow Telegram's requested delay.
- The Signal Routing adapter selector now groups enterprise IM and consumer IM adapters. This category is display-only and does not change identity admission, routing, permissions, capabilities, or binding policy.
- Telegram and Slack replies that reduce to no visible text now show the empty-reply placeholder in the installation's configured language instead of a fixed Chinese string.
- DingTalk reply-delivery failures (for example an expired token or a deleted group) now stop or wait for an operator as appropriate, instead of retrying forever with the wrong failure reason recorded.
- An administrator can now edit a local account's email from the console even when that account also has a linked external identity, such as a manually mapped Telegram handle.
- A final AI reply on Slack, Telegram, Lark, DingTalk, or WeCom now goes through the same secret-redaction step as an in-progress reply before it reaches the provider.
- Internal: consolidated the setup-completion sequence and duplicated local-account and reply-delivery validation logic into single implementations, with no change in behavior.

## Version 1.0.0-alpha.2 (2026-08-21)

- Concurrent identity observations, Slack directory deltas, and signal channel updates now keep all accepted facts. A mapped account no longer returns to Pending mappings, a failed directory delta leaves the group unchanged, and concurrent channel metadata keys no longer overwrite each other.
- AppConfigure and Plugin process crashes now rebuild one consistent declaration and activation snapshot. Long-connection owners reconnect after their Registry fails, and Feishu, DingTalk, and WeCom token requests no longer wait until timeout when a fetch task dies.
- Feishu webhook verification tokens now use constant-time comparison, and an AIGateway Response process crash report no longer contains request content or credentials.
- The Background Agent Job detail page loads all Turn trajectories in one query. Internal AIGateway token ownership and fixed request-key handling are simpler, with no API or operator change.
- Chat attachment filenames now pass one shared sanitizer on all five platforms. A name that reduces to empty, `.`, or `..` is stored as `attachment`; DingTalk, WeCom, Slack, and Teams no longer keep raw dot names or fall back to `unnamed`.
- Internal: the Worker and the control plane remove dead scaffolding left over from the agent-loop replacement and this version's own refactors. Users do not see this.
- Internal: the Worker gives its Background Agent Job document shapes, turn-local CLI socket bridges, and tool-authoring exports one owner each, and the Console route loaders reuse the pages' own query builders. Users do not see this.
- Model-visible catalogs that sort names (skills, agent plugins, changed file paths) now order by Unicode code point on every runtime. A name with characters outside the Basic Multilingual Plane can change position once.
- Internal: duplicated inline helpers move to single owners — shared attribute-map and result helpers on `Ankole.Attrs`, canonical Principal UID normalization on `PrincipalKey.canonicalize`, Worker error/ordering/number helpers under `common/`, and shared Console test auth helpers on `ConnCase`. Same-named map helpers with different semantics received distinct names. Users do not see this.
- Internal: Worker duration constants use `ms('5m')`-style declarations, Console refresh cadences share one owner module with unchanged values, the kernel AI client uses one JSON codec (sonic-rs) throughout, closed-union dispatch uses exhaustive `match`, and audited pass-through layers (AIGateway request-key and stateful-conversation forwarders, dead execution-scope plumbing, identity casts) collapse onto their owners. Users do not see this.
- The Worker now runs Playwright, its browser daemon, and browser scripts on Bun. The Worker image no longer carries a separate Node.js runtime for browser automation.

## Version 1.0.0-alpha.1 (2026-08-20)

- Operators can now bind chat senders to accounts by hand. A sender that auto-mapping cannot identify appears under Identity → Pending mappings in the Console; binding the entry maps that platform account to the chosen user, and the same page can map an account before the person ever writes. Until then, an addressed message gets one fixed reply that asks the sender to contact an administrator, and the message is not processed.
- Each signal routing rule gains one switch, "When account auto-mapping fails": hold the sender for manual review (default) or create a standalone account and serve them at once. Deployments that relied on automatic account creation for unknown senders must switch existing rules to "Create a standalone account" to keep that behavior.
- Account auto-mapping now also matches by platform-reported email and mobile number, and Lark/Feishu senders without an employee id (external-group members) can now be identified by their open or union id instead of being dropped silently.
- Two permission groups now maintain themselves: one per signal routing rule with everyone admitted through it, and one per identity provider with everyone it imported, so policy can address "users of this source" or "everyone outside this provider".
- The login page lists only providers that can sign an admin in: the adapter must support OIDC login, and the provider's login toggle must be on. A provider configured only for directory sync no longer shows a login button that fails.
- Internal: sender identity resolution moved from the five chat adapters into one SignalsGateway owner, identity-provider login and directory sync are separate modules over one shared provider connection, and the unused reserved identity shapes (channel actor, login subject, outbound actor) are removed.
- A changelog version may now carry an `-alpha`, `-beta`, or `-rc` pre-release suffix. The runtime-image workflow publishes such a version as a GitHub pre-release and moves the `canary` image tag instead of `main-latest`, leaving the current stable release and `main-latest` tag untouched.
- Long-term memory (Brain) is removed ahead of a rewrite: an Agent can no longer recall past conversations or curated knowledge, write or update memory, or automatically learn from an attached source. Upgrading to this version permanently deletes all stored memory data — knowledge entries, chat-recall indexes, retained sources, and audit history — with no migration path; export anything needed first.
- The Console's Knowledge section (Brain) is gone: the nav item; the entry, audit, dreaming, skill-experience, source, and status pages; and the Dreaming and Embedding settings editors are all removed ahead of the Brain rewrite.
- The developer and user documentation site drops its Brain and long-term-memory pages, and every other page's mention of them, ahead of the Brain rewrite.
- Internal: the `tools/e2e` suite drops its dedicated Brain real-LLM mode and suite ahead of the Brain rewrite, and its skill-tool-call tests use the still-available `brainstorming` skill in place of the removed `brain-review` example skill.
- Internal: SignalsGateway drops its channel-visibility and confidential-channel queries and their tests. Brain was their only caller, and Brain is gone ahead of its rewrite.
- Internal: the control plane's `/api/v1/brain/*` API and its five daily background sync, embedding, and dreaming jobs are removed ahead of the Brain rewrite, along with the `pgvector` dependency and the underlying `brain_*` database tables, enum types, and search indexes.
- Internal: an AIGateway conversation no longer carries a Brain memory-store scope. The channel or DM label the Console shows now comes from a simpler "origin" fact recorded once when the conversation starts; existing conversations migrate automatically, and a channel's confidentiality no longer starts a fresh conversation when it changes.
- Internal: the Worker's main agent loop now runs on pi-agent-core's `Agent` class instead of a hand-rolled OpenAI Responses client. AIGateway stays the sole owner of durable conversation state and the wire protocol is unchanged; tool-call validation, activity reporting, structured logging, and parallel-tool concurrency bounds keep their existing behavior.

## Version 0.76.2 (2026-08-20)

- The Console can run a recurring schedule immediately again. A valid `Idempotency-Key` no longer crashes request validation, and a repeated request still returns the same scheduled event.

## Version 0.76.1 (2026-08-19)

- No product behavior changes. Agent Computer integration no longer expects the retired standalone compaction endpoint, and Schedule end-to-end coverage no longer declares an unused context, so the current compaction and scheduling contracts run without false failures or warnings.

## Version 0.76.0 (2026-08-19)

- Background Agent Jobs and conversations now run on OpenAI-compatible Responses endpoints that accept only plain function tools, such as DeepSeek. AIGateway sends the Codex custom tools to such an endpoint as function tools and restores the answers to their official shape, so the first request no longer fails with an unsupported-tool error.
- An OpenAI-compatible Provider connection gains one visible switch, "Supports official OpenAI tools", off by default. Existing OpenAI-compatible Responses connections move to the emulated function-tool wire on upgrade; turn the switch on for an endpoint that faithfully implements the official OpenAI Responses tool surface to keep verbatim custom tools and Provider-native compaction.
- Provider-native compaction no longer sends probe requests to an OpenAI-compatible endpoint that does not declare official OpenAI tool support; those connections compact locally without the wasted round trip.

## Version 0.75.1 (2026-08-19)

- Fix DingTalk AI cards to use the platform's native `isFinalize` and `isError` state transitions instead of the unsupported `flowStatus` template variable. A completed interactive card now finishes through the same native protocol. Operators who followed the earlier setup guide must remove `flowStatus` and `flowStatusVar`, bind the `answer` Markdown component in each active state layout, and republish the template.

## Version 0.75.0 (2026-08-19)

- One Agent can now keep several Lark or Feishu signal bindings enabled, each with its own application. Each enabled binding still owns one distinct `domain` and `appID` pair across the instance, and disabling it releases that application.
- A Turn or Automation Job now gets Lark CLI credentials from its current signal route. A disabled or unavailable explicit route does not fall back to another Lark application, and an execution with several Lark bindings and no matching route gets no arbitrary credentials. Existing bindings need no migration and move to an independently namespaced, binding-owned encrypted configuration when they are next saved.

## Version 0.74.5 (2026-08-17)

- A Deep Research collector now takes what it needs out of a source in the call that fetches it, takes everything it still needs in one pass when it goes back, and spends a call on a fact it has not written down rather than on one it has. A long collection run stops paging the same downloaded page or data file through the model again and again, which is where most of a Job's tokens went.
- Compaction now runs late instead of early. The trigger defaults to 0.90 of the model input context with a 400000-token cap, in place of 0.5 capped at 100000, and a Background Agent Job no longer tells Codex to compact at 100000 either, so Codex applies its own nine tenths of the window. Compaction also hands back twice as many recent rows. A long conversation or Job loses its working memory less than half as often, and stops repeating the work that each loss caused. An instance that stored `ai_gateway.compaction` explicitly keeps its old values: raise `threshold`, `max_threshold_tokens`, and `tail_rows` there to get the new behavior.
- Record why Provider-owned compaction stays off by default, so the reason survives the next person who reads the setting. Users do not see this.

## Version 0.74.4 (2026-08-17)

- Deep Research no longer spends a Job checking the material you supplied as settled. The task now names what the research must establish and what your own specification, rules, or parameters contribute as given, and the Job builds on anything marked given instead of collecting evidence against it, saying so in the report when it looks wrong. It still checks the outside facts your design depends on: whether what it assumes to exist, to cost that much, or to be large enough really is so.
- Before it starts a Deep Research Job, the Agent shows you the requirements it is about to send and what the Job will treat as given, and it asks the costly question — what the research must establish — before the cheap ones such as the output format. A requirement that first occurred to the Agent while writing the task now reaches you as a choice it leaves to the Job, not as an obligation you never saw.
- A Deep Research Job drops a question from its collection plan when neither answer would change the deliverable.

## Version 0.74.3 (2026-08-16)

- A Background Agent Job no longer fails at its first compaction. AIGateway now resolves a WebSocket caller's `previous_response_id` into the history it names before it decides what kind of request this is, so a compaction trigger summarizes the whole conversation instead of the few items the caller sent with it. The same request previously ended the Job with `invalid_previous_response_id`.
- A continuation anchor is now answered by looking it up rather than by reading its characters, because the characters can be a value the Provider chose. Two error codes change: a WebSocket anchor this connection never issued reports `previous_response_not_found`, and an HTTP compaction request that names stored history reports `stateful_responses_require_websocket`, which is what every other HTTP Responses request already reported. The retired `compact_store_required` code is gone.
- AIGateway does not send a Provider an identifier that AIGateway made. Users do not see this.
- A stored conversation keeps working after its Provider changes. An operator who repoints a model profile, or a vision fallback that sends one Turn elsewhere, no longer replays state that only the previous Provider can read and that the new one rejects. AIGateway drops the hidden reasoning and turns the sealed parameters of an earlier tool call into plain text, while every message, call, and result stays. The Agent derives that reasoning again, so the Turn can cost more.
- Record which side owns the identifiers on each AIGateway link, so a later change does not send an Ankole identifier to a Provider or replay one Provider's sealed state to another.

## Version 0.74.2 (2026-08-16)

- Provider-forwarded compaction now streams its request like every other Responses request and collects the whole reply before the caller sees any of it. Upstreams that accept only streaming requests, such as the ChatGPT subscription backend, can now answer native compaction instead of always forcing the local fallback.
- Compaction over history that already holds Provider-owned compaction state no longer fails when the Provider path is off or unavailable. The local checkpoint preserves the Provider items verbatim, summarizes only the items after them, replays the preserved state on later turns, and logs a warning. The reply still carries exactly one compaction item, and the retired `opaque_compaction_fallback_unavailable` error is removed.

## Version 0.74.1 (2026-08-16)

- Remove the retired standalone-compaction wire from the kernel and the last documentation references to the removed `/responses/compact` endpoint. No behavior changes; the unified `compaction_trigger` protocol already serves every caller.

## Version 0.74.0 (2026-08-16)

- Compaction now has one protocol and one owner. AIGateway answers the `compaction_trigger` item for every caller, so a Background Agent Job and a stored conversation compact the same way. The separate `/responses/compact` endpoint is gone, together with the per-Job switch that chose between the two protocols and the per-Provider request constructors that only that endpoint used; a Job frozen under the old switch keeps running.
- Provider-native compaction moved from a per-Agent capability to the `upstream` field of the gateway compaction settings, next to the other compaction fields. An instance that had turned it on for an Agent enables it once there; the retired per-Agent switch is removed from stored Agent settings and from the Console.
- An Agent that leaves compaction to its Provider now has that request forwarded through the same protocol instead of a retired endpoint. AIGateway reads the whole reply and checks it before the caller sees anything, and falls back to its own summary when the Provider answers with something else, unless that history already holds Provider-owned compaction state that only the Provider can read.
- Keep a caller's `encrypted` tool-parameter declaration on any Responses provider instead of only on providers Ankole recognizes. The declaration is the caller's, the wire can carry it, and a provider that validates against a known tool schema rejects the request when it is removed. A protocol that cannot express the marker still has it emulated.
- Forward the calling client's identity headers to every OpenAI-family provider, the way ChatGPT Subscription requests already did. A Background Agent Job reaching an upstream through an OpenAI, OpenAI-compatible, or Azure OpenAI provider now presents its real Codex originator, user agent, session, thread, and turn headers instead of arriving anonymous, which is what some upstreams read to decide service level. Headers the caller did not send are still not invented.
- Retry a compaction summary that comes back empty or without the required headings, using the same larger output budget that a truncated summary already gets. One barren summarizer round no longer ends a Background Job at the compaction step. A summary that is still unusable after the retry reports an upstream failure instead of an invalid-request failure, and records the summarizer's response status, stop reason, and token usage so the cause is visible.
- Decide the changelog version increment with two explicit tests in the contributor and agent guidelines: `MINOR` needs a capability that nobody had before, or a break that a person must act on; every other change is a `PATCH`, including a bug fix that users see at once.

## Version 0.73.0 (2026-08-15)

- Group new observability traces by the trusted human for direct-message Turns and by the source channel for group or event Turns instead of by the Agent. Keep the Agent as separate Principal metadata, preserve session identities, and omit the user when no trusted trigger exists. Existing Observability settings remain valid, and historical traces do not change.
- Preserve the same user attribution across Worker tools, AIGateway HTTP and WebSocket generations, Codex Jobs, and image-input fallback calls. The internal cross-runtime carrier now preserves Unicode platform identifiers without breaking model transports, while Worker export authorization continues to use the Agent Principal.
- Keep the Signal Routing list in its original Agent scope after an operator saves or leaves an editor. Opening a routing rule from All Agents no longer adds the rule's owner as a filter and changes the list layout.
- Search the Background Agent Jobs board by an exact Job ID or a name fragment across stored Jobs. The search shares one toolbar with the Agent filter, keeps its value through refresh and browser history, waits for typing to pause before it requests results, and announces the matching count.

## Version 0.72.3 (2026-08-15)

- Preserve the official Codex tool schema, including encrypted collaboration parameters, through Responses-compatible Provider proxies. A permanent Provider request rejection now stops the Background Job instead of consuming Codex retries and returning it to the queue, and reaches every caller under one error code, while transport, authorization, rate-limit, and server failures keep bounded recovery.

## Version 0.72.2 (2026-08-15)

- Preserve `namespace` and tool `name` as separate, validated identities across Provider requests, Tool Search, program execution, trajectories, progress, Background Job history, and deployment recovery. Keep valid Chat Completions and Anthropic wire names unchanged, reject alias collisions, and use only structured V2 fingerprints.
- Keep tools loaded by client Tool Search callable across later turns and local compaction until the caller removes them from the surviving Tool Search output. Compaction budgets every complete retained pair and returns a structured context overflow instead of crashing or storing an oversized checkpoint.
- Apply one `max_tool_calls` budget across provider-owned built-ins and locally implemented Tool Search or program calls instead of rejecting requests that use both owners.
- Recover a retryable model attempt when a Responses-compatible Provider sends an error event before its terminal failure. AIGateway exposes only the canonical terminal, retains bounded Provider diagnostics, and Agent Computer uses explicit retryability or compatible fallback signals for its retry decision.

## Version 0.72.1 (2026-08-14)

- Preserve a streamed Chat Completions tool call's non-empty ID and name when later argument fragments repeat either field as an empty string, so OpenAI-compatible Providers cannot turn an otherwise valid client tool call into a partial completion.

## Version 0.72.0 (2026-08-14)

- Always write compaction summaries with the Agent's light model profile. A conversation that asked for high or extra-high reasoning effort skipped that profile and summarized with the primary model instead, so an Agent whose primary Provider was unreachable could not compact at all and lost the turn. An Agent that configures no light profile now resolves it to its primary profile, the way the coding profile already resolves to heavy.
- Let each Agent decide whether its Provider compacts history, with the new "Use the primary model's native capability, where applicable" switch on the light model profile. This replaces the former instance-wide `ai_gateway.compaction.prefer_upstream` setting. The switch is off by default, and a Provider that has no native compact operation falls back to the light profile, which stays editable because it still writes those summaries. Operator action: an instance that had turned the former global setting on enables the switch for each Agent that needs it; the stored global value is removed on upgrade.
- Recover a stateful conversation when an OpenAI Responses Provider rejects replayed provider-native history before any output. Ankole writes a provider-neutral local checkpoint and retries the current input once. If that retry fails, the next turn still starts from the repaired checkpoint, and dead-letter notices point to `/compress` as the manual recovery path.
- Let the bundled OCR Skill handle an image with no file-name suffix on its first attempt by detecting its media type and passing a temporary copy with the matching supported suffix to the recognizer.
- Let an Agent list, inspect, stop, message, and respawn its Background Jobs from any of its sessions or channels. The Agent owns the Job; its original session and reply route continue to control notification and delivery only.
- Deliver Lark files above the 30 MiB IM limit as cloud-space links instead of exhausting the durable outbox retry budget. Ankole uploads each file in sequential parts, tells the user that the file was uploaded because it is too large, grants the whole chat read access for a group reply or the sender read access for a direct reply, and records structured upload logs and telemetry. Missing cloud-space scope now blocks the first failed delivery instead of uploading the file again. Operator action: grant the Lark application `drive:drive.metadata:readonly`, `drive:file:upload`, `docs:permission.member:create`, and `space:document:delete`, ensure enough cloud-space capacity, then retry any stopped `234006` delivery.

## Version 0.71.2 (2026-08-14)

- Let Skill-backed HTTP MCP declarations pin protocol negotiation, so modern
  POST-only servers do not fall back to the legacy SSE receive channel.

## Version 0.71.1 (2026-08-14)

- Keep the Background Agent Job board within the desktop viewport with independently scrolling columns. Its five health cards now keep their space while loading, show request failures, and use one wide-screen row. Assistive technology can identify each Job column and the health loading state.

## Version 0.71.0 (2026-08-14)

- Re-enable a disabled model provider without rebuilding its credential pool. Re-enabling validates the stored configuration and retries credentials that failed before disablement, while enabling an active provider preserves current health. Credential replacement and disabled-provider re-enable use new internal health revisions, so a late response from an earlier secret cannot mark the current credential dead or rate-limited. Metadata changes and automatic OAuth token refresh preserve current health. Encrypted settings are limited to credential scope, and the endpoint uses the existing provider update permission.
- Make Console readiness continuously check five deployment-instance requirements: a provider, an active Agent, all required model profiles, a ready Worker, and a usable Signal Routing Rule owned by an active Agent. Header and home polling continue after setup, so removing or disabling a requirement restores its setup step.
- Make Console state match visible resources. Agent and Brain owner changes remove prior-scope rows from schedule, Signal Routing Rule, webhook, conversation, Automation Job, Background Agent Job, and Brain lists. Background Agent Job details use compact, right-aligned action footers, and their dialogs close with their Agent filter. Automation Job deep links accept every positive integer ID, retain owning-Agent authorization, and show explicit errors for invalid filters, invalid IDs, and missing details. Encrypted settings keep scalar input as a string and parse only valid JSON objects or arrays as structured data. Dirty drafts require confirmation; pending writes cannot be dismissed as discarded; Skill Experience drafts reset per Agent and retain their conflict hash; schedule limits survive edits; terminal schedules are read-only; and IME input cannot submit forms. Provider-hosted capability switches can be turned off again. Setup validates activation codes in the selected language and shows submission progress. Searches, settings, and operational states now use localized visible labels and explicit errors.
- Keep startup Signal connection reconciliation in tests, but disable its periodic timer so supervised plugin work does not race SQL Sandbox tests.

## Version 0.70.0 (2026-08-13)

- Continue a Background Job even after its Worker is replaced. When the Worker-local Codex thread is gone, a respawned or retried Job now replays its stored turn history into a fresh thread and continues where it left off. When nothing is stored, it continues in the same Workspace, seeded with the source Job's task and final report, and the Job metadata states which recovery ran. Previously a Worker replacement made every earlier Job impossible to continue, and a Worker whose thread index survived without its thread file failed the Job outright.
- The Worker now reports each Job Turn's content once, as sanitized semantic items. The control plane stores that stream for thread replay and derives the existing trajectory views from it, so the Console, message results, and attempt summaries keep their current shape.
- Let operators enable `ai_gateway.compaction.prefer_upstream` to make Main Agents and Background Jobs prefer a Responses Provider's native compaction. The switch is off by default. New ChatGPT Subscription Jobs use Codex v2 through AIGateway's normal Responses path; all other Jobs and every Main Agent use the standalone compact operation, fall back to Ankole's local summary when readable, and remember a 404 or 405 for one hour per Provider revision and model. Main Agent history binds opaque output to its Provider and model and rebuilds a local checkpoint before a switch. A later standalone fallback from opaque Provider state returns `opaque_compaction_fallback_unavailable`. When a real compact request fails and the local summary runs instead, the control-plane log records the Provider, model, and cause, so an operator can tell a working switch from one that degrades on every compaction.
- Keep Codex thread resume on its own 120-second request budget and preserve the existing app-server liveness check: a timed-out resume fails only its Background Job when the shared process still answers, while a process that cannot answer either request is replaced.
- Remove the separate `hosted_web_search` switch from OpenAI-compatible Providers: an endpoint configured for the Responses wire already states that capability, and whether to use it is the Agent's own web-search switch. Operator action: none, the stored option is removed on upgrade.
- Rework the Deep Research instructions around findings from a production trace audit. A spawned support thread now executes only its own brief instead of adopting the whole research workflow after an interruption, collectors report facts without pre-empting the judgment, and the verifier must report findings in both directions — a conclusion made softer than the evidence warrants counts the same as one made stronger. Reports state each limitation once and stop repeating already-green checks; build and writing tasks skip the research scaffolding entirely. The ACH playbook now rejects undecidable questions up front, gives every hypothesis the same burden of proof, and refuses matrices built only for compliance.
- Tell operators when the Job queue is held by the per-Agent concurrency cap rather than by Worker capacity. The Background Agent Jobs health panel now shows how many Agents sit at that cap and how many Jobs wait behind it, and states that the cap counts across all Workers, so adding a Worker will not start them. Raise `agent_computer.background_agent_job.max_running_per_agent` for that case, after confirming Provider quota.
- Stop dropping every message on a channel that changes kind. A channel first recorded as a group and later seen as a direct message kept its stored group, which storage rejects, so each later message on it failed silently and the sender never got a reply. The group is now cleared when the channel is no longer a group.
- Keep saved custom model profiles editable in the Console. Their description, Provider, model, context length, and Provider options now stay in sync while an operator types or selects values instead of freezing after the first change.
- Let an operator enable `signals_gateway.show_dead_letter_error_details` to append the current Actor turn error to Signal-channel dead-letter notices. The setting is off by default, and enabled notices limit and redact the details before delivery.
- Let image and scanned-document OCR run inside the Agent sandbox. The sandbox now exposes the Worker's `/sys` tree as read-only, so OpenVINO can inspect CPU topology instead of crashing during startup.
- Retry a dropped upstream provider connection inside the same model call. An AIGateway upstream WebSocket connect, send, or read failure — for example a connection reset mid-stream — was classified as an unknown, non-retryable error, so the whole Turn failed and waited for control-plane redelivery. The Worker now classifies these as retryable transport errors and retries the call from the stored anchor.
- Stop counting an AIGateway credential-pool cooldown, such as a 429 storm, against a Background Job's five execution failures. The Job now waits for the pool's declared recovery time with its budget intact, so a storm no longer fails a whole batch of parallel Jobs as `attempts_exhausted` task failures; a storm that outlasts all twenty-five claims fails with the existing infrastructure verdict instead.
- Let operators send optional OpenTelemetry traces through OTLP/HTTP. Export is off by default and is configured in one AppConfigure form with encrypted authentication headers. Each dispatched Agent Turn becomes one trace that names the Agent Principal and its conversation; Main Agent and Codex tool spans and each AIGateway model generation attach below it with bounded, redacted input and output, token usage with cache and reasoning buckets, and timing. The `langfuse`, `langsmith`, and generic `opentelemetry` Providers add vendor semantics, so a receiver such as Langfuse groups cost and quality per Agent, per session, and per release. The website documents Langfuse and LangSmith setup plus common OTLP alternatives.
- Count Claude prompt-cache reads and writes in AIGateway response usage the way OpenAI counts them: `usage.input_tokens` now includes both cache portions and `input_tokens_details` itemizes them, and Gemini cached prompt tokens now appear in the same detail field. Context accounting, traces, and cost views see real cache traffic instead of zero.
- Upgrade the bundled OfficeCLI to 1.0.144, which fixes XLSX `SUBTOTAL` handling for filtered and hidden rows, empty-cell comparisons, and date/time text arithmetic. The Office Agent Plugin now requires that matching runtime, sends top-level commands to their correct help entry, makes CSV and TSV imports durable through a verified non-resident batch, and aligns DOCX page-break and TOC guidance and XLSX print-layout guidance with the 1.0.144 source.
- Fix first-use Lark approval setup for each human profile. App-registration and user-login device codes now remain in locked profile state instead of crossing model Turns, so browser setup can finish without a signed code being altered. Registration errors retain the provider code and HTTP status, and the Worker bundles `lark-cli` 1.0.86.
- Let an Agent address the current Lark sender without asking them to copy an ID. Inbound Turns preserve a Contact-synchronized display name when the message webhook omits it, render group speakers as `name(uid)`, and expose the current chat ID. The Lark Skill uses a human `uid` as the usual Lark `user_id`, so the Agent can resolve that user through the bot Contact API and start a direct message.
- Shorten the Agent system prompt and tell a new Agent how to write. Duplicate sentences, self-evident tool instructions, and self-check directions are gone from the system prompt, which lowers the fixed token cost of every Agent turn; the approval boundaries, security limits, and schedule rules stay the same. The default SOUL template now asks for the voice of the colleague who did the work and is briefing the person whose call it is: lead with the judgment, keep replies short by default, calibrate what to explain to the reader at hand, commit to a position instead of surveying options, and write in everyday words instead of invented jargon. An Agent created before this release keeps its stored SOUL until an operator edits that document.
- Reject a Worker Turn checkpoint that reuses a revision but changes header fields such as status, progress, usage, or error. The header comparison always passed before, so such a resend was silently accepted and the drift was ignored.
- No product behavior changes from added delivery edge-case test coverage, corrected end-to-end expectations, test-fixture cleanup, an internal cleanup pass that gives the Responses-wire check, trace attribute encoding, and other duplicated internal logic a single owner each, and a compaction-planner cleanup that replaces its long internal argument lists with one context bundle per path.

## Version 0.69.0 (2026-08-13)

- Keep a Claude model's extended thinking across a tool-calling conversation. AIGateway carries the signed thinking blocks between rounds and rebuilds each assistant turn from the stored history, so Claude tool calls now replay correctly even with thinking off. Reasoning from one model is never replayed to another, and a conversation whose stored reasoning is missing or unreadable continues without it instead of failing.
- Deliver every configured target of a recurring task, and stop losing the ones that cannot be reached. A target whose channel or binding was deleted no longer leaves an undeliverable row waiting forever: it is recorded as unsupported, appears in the stopped-delivery view, and the remaining targets still deliver.
- Keep a Background Job on the Worker that holds its Codex thread. A retry, and a Job continued from steering messages, both stay put instead of moving to the emptiest Worker and rebuilding or failing to resume that thread. A continuation that truly lost its Worker now reports that cause.
- Stop rewriting what the pinned Codex runtime declares: model-visible tool descriptions keep their official `exec` declarations, and native OpenAI Responses keeps the encrypted tool-parameter marker it owns instead of an AIGateway emulation. A malformed marker is still rejected on every route.
- Give each Agent one switch per capability for web search and image generation: leave it to the Agent's language-model Provider, or use the Agent's own capability Provider. Turning it on disables that capability's model profile, because the Provider then runs the work inside its own turn and owns its results. A model that cannot run the capability means the Agent has none, rather than silently switching executor mid-conversation. Both switches default on for new Agents; an Agent that already configured a search or image Provider keeps it. This replaces the previous behavior where a provider-hosted search was declared alongside a competing local `web_search` tool, which let the model pick either one.
- Repair the operator endpoint that commits an externally verified Job completion: it read the result summary from the wrong place and rejected every valid request. Agents can also now state how many targets a recurring schedule delivers to instead of guessing.
- Maintenance with no user-visible behavior: declared Provider setting types are validated on write, daily Codex log maintenance no longer stops at the first unreachable Worker, the Rust lint gate passes again, the end-to-end steering check now looks for the final reply where a steer actually owns it, and the repository-only `audit-ankole-trajectories` Skill and the unit tests that only inventoried catalogs, restated source or locale copy, or snapshotted CSS class names are removed.

## Version 0.68.4 (2026-08-13)

- No product behavior changes. A `bun test` started outside the Worker image now stops with the correct Agent Computer test commands instead of reporting host environment failures, and the contributor guidelines state that a package's declared test or build script is the only correct entrypoint.

## Version 0.68.3 (2026-08-13)

- Let an Agent Plugin workspace template hold a Background Job to single-Agent execution: `features.multi_agent_v2.enabled` in the template `.codex/config.toml` now keeps the value the operator wrote, and Ankole supplies its default only when the template leaves the switch unset.

## Version 0.68.2 (2026-08-12)

- Apply the valid PR review-bot findings: restored Brain drafts rebaseline only from a fetched response, overlapping model-profile saves each keep their pending state, a refetch that restates current values no longer fakes "unsaved changes", the checkbacks list documents 401/403, schedule toolbars gain a real accessible label, the conversations search placeholder names every input, an invalid worker file timestamp renders as absent instead of crashing the table, and an abandoned invalid fitness horizon snaps back to the applied value.

## Version 0.68.1 (2026-08-12)

- Correct the automation-blueprints and Console API guides in all four locales to the real schedule API: `POST /api/v1/agents/:agent_uid/cron-schedules` with `owner_session_id`, `idempotency_key`, and `delivery` in the request body, the `{ "kind": "cron", "expression": ... }` schedule shape, and the checkback surface (`GET /api/v1/checkbacks?agent=`, `DELETE /api/v1/agents/:agent_uid/checkbacks/:scheduled_event_id`).

## Version 0.68.0 (2026-08-12)

- Give the Console lists for Schedules, Signal Routing, Automation Jobs, Webhooks, and Background Agent Jobs one "All Agents" default scope with a one-row search-and-filter toolbar, served by installation-wide `GET` endpoints with an optional `agent` query filter in place of the per-agent list routes. Operator action: these list endpoints now check the installation-wide read permission (`schedules`, `signal_gateway_bindings`, `webhooks`, `automation_jobs`); give custom roles that hold only per-agent grants the matching installation-wide read grant, and update API clients to the new list paths. Checkback lists now cap at 100 rows by default (500 maximum).
- Let the Console conversations list search by name: the `q` filter matches an exact subject UID (any letter case), a session-key fragment, or a fragment of a group channel or DM peer name, with literal `%` and `_` handling and a debounced search box.
- Fix the Console defects found in this release's full review: a rejected token refresh recovers through the browser session and survives network blips; legacy single-target schedules, deep-linked Automation Jobs, Brain audit restores, and settings-group restores no longer dead-end or silently revert; secret, encrypted, and model-profile editors validate and display stored values honestly; destructive actions confirm first and name their target; switching the Agent filter keeps an open job detail; ja-JP and ko-KR timestamps and English plural forms render correctly.
- Rebuild the Schedules area and the shared Console chrome: Cron and Checkbacks are routed tabs of the shared list frame, editors use the shared editor frame, `every` schedules require their anchor and drop hidden timezones, ChatGPT credential labels and priorities become editable, and the review's duplication findings collapse into shared owners.
- Make the ChatGPT device-login test clock-independent so unpinned credential resolution stays on the no-refresh path regardless of the run date.

## Version 0.67.2 (2026-08-13)

- Remove the obsolete per-Job Agent Plugin selection column from upgraded databases. Pause legacy direct-Agent cron schedules without a complete task, cancel their pending fires, and block resume or manual fire until repair; schedule coverage now uses explicit clocks and payload or delivery updates preserve run history.
- Move Codex runtime state to Worker-local shards, bind each shard into its Job sandbox, and retire only an unlocked, real legacy config directory. Pin local Worker builds to Codex 0.147, keep app-server timeouts retryable, redact bounded startup diagnostics, and roll back a successful terminal Job commit if its steer successor cannot be stored.
- Keep provider-hosted web search on standard Responses without a competing local tool, and persist and publish through the Console API whether each search was provider-hosted or local. Preserve frozen provider options across model and tool-result rounds, keep generic caller metadata local, retain configured WebSockets through hosted image fallback, and restore omitted terminal output from completed stream items.
- Keep OIDC login buttons usable after browser back navigation, and stop stale Feishu CardKit recovery from replacing a durable terminal presentation or retrying a provider binding-limit fallback forever.

## Version 0.67.1 (2026-08-13)

- No product behavior changes. Add the `tools/fake-feishu` developer tool: a standalone fake Feishu platform plus CLI for local end-to-end work without the Feishu web client, simulating CardKit streaming with the real conflict codes, the chat directory, images, and reaction/member/card-action events; the e2e suites share the same simulation core with unchanged behavior.
- Add the dev-only `ANKOLE_LARK_BASE_URL_OVERRIDE` environment variable that points a `:dev` control plane's Lark clients at such a local platform; production endpoint rules stay unchanged.
- Clarify the changelog rules in `AGENTS.md`: entries are written for end users, and `MINOR` is only for main-product capabilities that end users experience — everything else is `PATCH`.

## Version 0.67.0 (2026-08-12)

- Make BackgroundAgentJob retries honest and bounded: a retryable attempt failure returns the Job to `queued` and frees its Agent slot and Worker assignment, the new `execution_failures` budget (5) counts only real execution failures while total claims cap at 25, and infrastructure interruptions retry within minutes while provider-class failures keep the hours-spanning ladder. Operators see `execution_failures` beside `attempts`, and the per-Agent running cap becomes the `agent_computer.background_agent_job.max_running_per_agent` setting (default 3; confirm provider quota before raising it).
- Never block a Job's terminal commit on unconsumed steering: a succeeded commit converts open steers into one successor Job and names it in the wakeup, failed and stopped commits answer steers with the terminal notice, and the new `request_complete` operator action commits an externally verified completion with a result summary. A dead-lettered lifecycle wakeup now delivers the real outcome — title, status, result or error, artifacts, successor — without a model turn, and a Codex app-server internal death stays retryable instead of dead-lettering the notification.
- Move Codex SQLite state to Worker-local per-Agent shards (`ANKOLE_CODEX_STATE_ROOT`, default `/var/lib/ankole/codex`); SQLite WAL cannot run on the shared network filesystem, which was the root cause of production `thread/resume` stalls. Place Jobs per Job instead of per Agent so one Agent's Jobs spread across Workers by free capacity; a lost Worker shard falls into the existing runtime-chain recreation, and daily `logs_2` maintenance reaches every ready Worker.
- Keep one slow app-server request from killing every Job of the Agent: a timed-out request health-probes the process and fails alone when the process still answers; only an unresponsive process, a failed `initialize`, or a `turn/start` timeout closes the transport.
- Add the Console Job reliability panel: oldest queued wait, execution failures against claims, successor seeding, and dead-letter notices over 24 hours through `/background-agent-jobs/health`.
- Run each cron fire in the schedule's own derived execution session (`cron:<schedule_id>`) so long autonomous runs no longer block addressed messages in the owner conversation; a direct-Agent schedule stores its complete standing instruction in `payload.task`, and payload or delivery edits restart the schedule conversation from current facts. Console schedule forms pick the owner conversation from real sessions and edit the Task directly; the migration renames `session_id` to `owner_session_id` and moves pending fires to derived sessions.
- Store messages sent to a queued BackgroundAgentJob and replay them in strict order at admission instead of forcing a stop-and-recreate; admin OIDC sign-in redirects in one navigation; OpenAI-compatible and OpenAI providers declare endpoint kind and upstream WebSocket transport as Console selects with an editable `serviceTier`; a streamed OpenAI-compatible output item keeps its identity across a lossy terminal snapshot so Codex never executes one tool call twice; `audit-ankole-trajectories` loads only when a user invokes it by name.

## Version 0.66.0 (2026-08-12)

- Let an OpenAI-compatible Responses connection declare provider-hosted `web_search`, and project that capability end to end: Main Turns declare the hosted tool to the provider, and Background Agent Jobs enable Codex live web search from the same frozen declaration.
- Reject `hosted_web_search` on a connection whose `endpoint_kind` is not `responses`.

## Version 0.65.0 (2026-08-12)

- Run each recurring Agent or BackgroundAgentJob task once and deliver the same final reply and attachments through one independently retryable outbox row for each configured Signal target.
- Normalize existing single-target schedules and live event snapshots without rewriting terminal history or replaying old outbox effects; downgrade stops before it can lose a multi-target route.
- Let operators manage canonical `delivery.targets` in Console while target edits preserve worker-owned `quiet_success` and Agent tools preserve operator targets; schedule reads use the canonical list and legacy scalar writes still normalize to one target.
- Cover one-turn multi-target delivery and isolated retry with a real Worker and Lark adapter E2E case.

## Version 0.64.2 (2026-08-12)

- Update the public Console guides for reversible Signal Routing, safe credential replacement, Provider-dependent model options, and the editable boundaries of Principals, permission groups, and grants.
- Preserve whether a Background Agent Job tool ran through a Provider-hosted tool or an Ankole dynamic tool, even when both tools use the same display name.
- Let an authorized parent Agent read a succeeded Background Agent Job's exact persisted response through bounded offset reads when the completion notification is truncated.
- Stream Mix diagnostics while devkit renders the Worker bootstrap contract, so a held `_build` lock shows its holder immediately, and stop the wait after 10 minutes instead of hanging without output.

## Version 0.64.1 (2026-08-12)

- Compress every historical release into concise outcomes for release readers. Preserve all version headings, dates, ordering, and material user, operator, compatibility, migration, security, and architectural facts.
- Require future versions to use 1–4 outcome and operator-action bullets in normal cases. Do not use file or test inventories or implementation narratives. Continue to cover every material retained change.

## Version 0.64.0 (2026-08-12)

- Complete Turns for unreachable channels without endless model retries, and prevent removed or listen-only adapters from blocking Worker takeover.
- Enforce a hard outbox attempt limit, require explicit operator requeue, and add Console controls for stopped deliveries.
- Classify WeCom delivery failures and mark replies that may have been duplicated.

## Version 0.63.0 (2026-08-11)

- Move AgentBull Cloud web search to `/web-search/v1/search`; operators must provide an API key, which AIGateway sends with Bearer authentication.

## Version 0.62.2 (2026-08-09)

- Flatten namespaced function and custom-tool history even when the current request declares no tools.

## Version 0.62.1 (2026-08-09)

- Flatten namespaced custom-tool replay for strict OpenAI-compatible providers while preserving public Codex tool names.

## Version 0.62.0 (2026-08-09)

- Make `/steer` queue input for the next model boundary instead of aborting the active provider call.
- Add complete Japanese and Korean localization for the Website, Console, and server, and normalize Korean documentation style.
- Route the trajectory-audit Skill only for its intended audit work.

## Version 0.61.6 (2026-08-09)

- Proofread the Chinese documentation and Chinese READMEs without changing product behavior.

## Version 0.61.5 (2026-08-08)

- Upgrade dependencies, show Worker-image pull progress, and fail WebSocket connection attempts after one minute.
- Add immediate steer preemption; Version 0.62.0 later replaced this behavior with queued boundary admission.

## Version 0.61.4 (2026-08-07)

- Count credential-pool exhaustion against the bounded five-attempt Background Agent Job budget.

## Version 0.61.3 (2026-08-07)

- Retry HTTP 402 failures within the Background Agent Job budget, but keep HTTP 403 terminal.
- Respawn terminal Jobs from the same Codex thread and workspace.
- Return bounded provider error details through public AIGateway errors without exposing response bodies or log data.

## Version 0.61.2 (2026-08-07)

- Upgrade dependencies and Codex to 0.147.
- Hide the readiness control after setup is complete.

## Version 0.61.1 (2026-08-07)

- Preserve native OpenAI `encrypted_content` while rejecting foreign or corrupt adapter state.
- Limit web-search queries to 500 trimmed characters.

## Version 0.61.0 (2026-08-07)

- Recover stalled Background Agent Jobs and Brain work with clearer operator alerts and bounded recurring-reply escalation.
- Correct speaker, timezone, attachment, and deliverable handling across conversation and research workflows.
- Repair Codex tool, prewarm, MultiAgent, compaction, model-routing, and vision behavior; add Unicode Agent UIDs and sticky OpenRouter routing.
- Overhaul the PPTX Skill, make Deep Research confirmation safer, and move durable conduct rules into pinned memory.

## Version 0.60.0 (2026-08-06)

- Improve Console layout, accessibility, forms, and operator feedback.
- Redact secrets safely and preserve blank secret fields when editing Signal Routing and Identity Provider settings.
- Add a secure Signal Routing detail API and a soft-disable lifecycle, and validate provider option mappings.

## Version 0.59.0 (2026-08-06)

- Improve Agent and Job reliability with finite schedules, empty-reply reminders, truncated-call recovery, durable steering, richer collaboration history, and clearer stall and failure handling.
- Sanitize Skill catalogs and tool results, and cap `web_fetch` at 40,000 characters with workspace overflow. Add direct AIGateway web providers, refresh Lark credentials, and add read-only Mail through `lark-cli` 1.0.84.
- Strengthen provider and runtime correctness with sealed RuntimeFabric headers and typed stream events. Repair Brain curation, model-switch, vision, and cache behavior, and limit Codex tool output to 10,000 tokens.
- Add the disabled-by-default `context-dev` Skill, which requires `CONTEXT_DEV_API_KEY`, plus repository evaluation, BP fidelity, and trajectory-audit tooling.

## Version 0.58.0 (2026-08-05)

- Add recoverable Slack Block Kit replies, threads, attachments, and direct mentions; deterministic binding failures now wait for operator repair.
- Honor standard HTTP and WebSocket proxy variables, including `NO_PROXY`.
- Overhaul Console setup, readiness, forms, and accessibility; Agent display name and role are required when saving, while legacy unnamed Agents remain usable until edited.

## Version 0.57.2 (2026-08-04)

- Simplify the Background Agent Job board and distinguish synchronous from asynchronous Job messages.
- Add acknowledged Turn completion, no-op, and abort operations with rolling-upgrade compatibility; deployment must stop old Workers before applying the control-plane phase.
- Preserve `/steer` continuation presentation and durable compaction checkpoints across retries and restarts.

## Version 0.57.1 (2026-08-04)

- Restore Bearer authentication for Skill-backed HTTP MCP while keeping raw tokens only in WorkerEnv.

## Version 0.57.0 (2026-08-03)

- Scope Schedules, Automation Jobs, and Webhooks to an Agent across all its sessions, and label automatic Feishu cron replies.
- Run an Agent's active Background Jobs through one shared Codex app-server. Add official Plugin installation, per-Job Skill projection, physical Home locking, bounded recovery, and live Skill-disable or content-change hints.
- Persist a frozen Job runtime and model projection, add Agent-owned custom model profiles and `/llm`, and return HTTP 422 for unconfigured profiles.
- Add aggregated global financial data through Twelve Data, Massive US options, and Polymarket. Route Hong Kong daily bars through BullX, upgrade mcporter to 0.13.0, and prevent silent MCP result truncation.

## Version 0.56.3 (2026-08-03)

- Run Codex diagnostic cleanup only at the daily session-reset boundary.

## Version 0.56.2 (2026-08-03)

- Serialize Codex Home initialization and clean only disposable diagnostic databases when the Home is idle.
- Restore `tini` as the Kubernetes Worker supervisor and replace `RUNTIME_FABRIC_URL` with separate RuntimeFabric endpoint and authentication-key settings.
- Use immutable or content-addressed Worker images instead of the fixed local image.
- Require repository repairs to update all affected ownership boundaries and remove superseded paths.

## Version 0.56.1 (2026-08-03)

- Keep settled Tool Search history replayable after its declaration is removed, without making the removed tool callable again.

## Version 0.56.0 (2026-08-02)

- Improve Deep Research planning, add Academic Verification, and add a source-faithful playbook-porting Skill.
- Fix Brain retrieval for entries with many matching blocks and return clear canonical-name and alias-ambiguity results.
- Remove Flint Chart and general Direct MCP while preserving invocation-scoped Skill-backed MCP and compatible historical replay.
- Refine `clarify` and add explicit-request-only `brainstorming` and confirmation-first `proposal-review` Skills.

## Version 0.55.0 (2026-08-02)

- Keep Lark CardKit replies within table and page limits, block permanent recovery failures, and let operators requeue them after binding repair.
- Prevent duplicate replies during deployment with acknowledged terminal completion and safe Worker draining.
- Move to AgentBull active-support packages and Bun canary, with immutable runtime ownership and updated architecture documentation.
- Add local PDF triage, text extraction, and CPU OCR, and refresh bilingual channel and Automation Job guidance.

## Version 0.54.0 (2026-08-02)

- Add durable per-channel ambient judgments, reply attribution, and member-managed standing orders.
- Give Sessions and inbound attachments stable numeric IDs; legacy Session directories migrate on first access and fail on conflicting old and new state.
- Make MCP-backed capabilities Skill-first across main turns, Background Jobs, and Automation Jobs, with only a narrow release-defined Direct MCP exception.
- Disable Codex creator and installer Skills, improve localized conversation context, and strengthen RuntimeFabric, credential-retry, and file-I/O ownership.

## Version 0.53.1 (2026-08-01)

- Keep complete-response ChatGPT Subscription calls on the required upstream SSE protocol and omit its unsupported `truncation` field.
- Recover local Tool Search and program continuations when a provider omits the terminal `output` array.

## Version 0.53.0 (2026-08-01)

- Unify AIGateway Tool Search and programmatic tool calling under one public, multi-round Response lifecycle with stable replay and cancellation.
- Enforce frozen tool contracts, caller permissions, output schemas, `max_tool_calls`, and bounded program resources before execution.
- Preserve OpenRouter reasoning state, provider-native OpenAI tool behavior, ChatGPT Codex compatibility, and native-first image generation.
- Align Agent Computer execution and stateful replay with the Responses contract, and return invalid declarations as OpenAI-compatible HTTP 400 errors.

## Version 0.52.2 (2026-08-01)

- Omit `max_output_tokens` from ChatGPT Subscription requests so long-conversation compaction can run.
- Document the canonical WeCom WebSocket Upgrade header requirement fixed in Version 0.52.1.

## Version 0.52.1 (2026-07-31)

- Preserve conventional RFC 6455 header casing so WeCom AI-bot WebSocket handshakes succeed.

## Version 0.52.0 (2026-07-31)

- Restore mcporter 0.12.3 to the Agent Computer image; Automation scripts can use `~/.mcporter/mcporter.json` through Bun Shell.

## Version 0.51.0 (2026-07-31)

- Validate Identity Provider settings in the first-run form before submission, with localized and accessible field errors.
- Simplify Feishu setup, keep setup drafts across navigation and restarts, and preserve plugin-selection behavior until setup completes.
- Standardize setup copy and boolean controls across all supported Identity Providers without changing stored keys or defaults.
- Keep WeCom handlers available during unfinished setup and reduce AIGateway native error size without changing its serialized contract.

## Version 0.50.2 (2026-07-31)

- Compact large program calls as complete call-output pairs and reject checkpoints that would still exceed the provider budget.

## Version 0.50.1 (2026-07-31)

- Prevent Programmatic Tool Calling from aborting the control plane when V8 schedules delayed work under heap pressure.

## Version 0.50.0 (2026-07-31)

- Add WeCom chat and identity support with long-lived bot connections, streaming replies, media handling, directory sync, and documented platform limits.
- Fix blank DingTalk AI cards, preserve their lifecycle state, and add operator setup and troubleshooting guidance.
- Retry transient AIGateway transport and 502–504 failures once before provider output without disabling healthy credentials; keep 401 and 429 ownership distinct.
- Fix ChatGPT Subscription compaction for both automatic and manual summarization.

## Version 0.49.1 (2026-07-31)

- Preserve the complete AIGateway WebSocket connection state after upgrade.

## Version 0.49.0 (2026-07-30)

- Add durable webhook delegations with redacted raw-body admission and callback URLs under `/webhooks/v1/event-callbacks/*`.
- Add Agent-owned Automation Jobs for checkbacks, cron events, and webhook deliveries.
- Isolate main-Agent MCP catalog failures by server so one failure does not remove other catalogs.
- Clarify that one pending changelog version covers all retained work in one commit.

## Version 0.48.2 (2026-07-29)

- Fix release conflict detection in the `runtime-images` workflow.

## Version 0.48.1 (2026-07-30)

- Position Ankole as the open-source AI Workforce OS across localized READMEs and the Website.
- Publish a versioned RuntimeFabric image pair and GitHub Release only after both immutable images pass verification.
- Upgrade control-plane, kernel, and Worker dependencies while preserving CEL list and map functions.
- Align main-Agent file editing with Codex 0.146.

## Version 0.48.0 (2026-07-29)

- Adopt Semantic Versioning from the fixed `0.42.0` baseline.
- Add official Tool Search, deferred loading, and Programmatic Tool Calling across AIGateway, main turns, and Codex 0.146 Background Jobs.
- Replace the separate ChatGPT Subscription runtime with AIGateway v2 credential pools, and reject stateful providers that cannot replay stored history.
- Add pinned database and cloud CLIs to Agent Computer images, move font builds to `AgentBull/ankole-fonts`, localize credential strategies, and enforce Feishu's five-table card limit.

## Version 0.47.0 (2026-07-28)

- Keep Background Agent Jobs alive through upstream outages and resolve their model profiles when each Job is created.
- Preserve OpenRouter prompt caching and decode opaque tool state by its own version.
- Improve Brain Stage A output and show accepted clarification answers in frozen Feishu cards.
- Limit Codex Job threads to 100,000 tokens and reject truncated compaction summaries.

## Version 0.46.1 (2026-07-28)

- Serialize shared Codex Home setup for overlapping Background Agent Jobs owned by one Agent.

## Version 0.46.0 (2026-07-27)

- Complete Worker heartbeat recovery and keep the Worker registry non-durable across database restart.
- Give Deep Research durable state, delivery audit, first-party repository access, and a complete bilingual guide.
- Repair recurring Schedule state, idempotency, editing, replacement, and restart recovery; remove unused `stagger_ms`, `failure_policy`, and cron-level `failed`.
- Require callers to supply stable idempotency keys for manual cron runs, while automatic runs keep unique event identities.

## Version 0.45.1 (2026-07-26)

- Rebuild Quick start as the single path from deployment to an IM reply. Define one private enterprise instance as the product boundary, and remove or redirect duplicate setup and adapter pages.
- Reorganize Architecture, Agent Library, memory, schedules, web, files, images, and visual-design guidance around the real operator task and owner.
- Make AppConfigure the owner of runtime settings, replace the WorkerEnv essay with Console-led environment guidance, and document identity, permissions, and Background Job behavior in user terms.
- Improve troubleshooting, responsive navigation, and table-of-contents tracking. Docker Compose now supports Docker on Linux, macOS, and Windows. The persisted `coding` key remains compatible behind the Background Agent Jobs label.

## Version 0.45.0 (2026-07-26)

- Add a Console start page, consistent resource navigation and paging, Principal access, and clearer provider and Job views. Improve responsive layouts, labels, errors, motion, contrast, and keyboard navigation.
- Remove an Agent's visible reply when its source message is recalled, and repair Agent Library defects and misleading success states.
- Rebuild the Website around current product outcomes with consistent English and Chinese copy, a dark default, responsive composition, and a restrained motion system.
- Keep Website-only changes from rebuilding runtime images and pass requested report length to Deep Research as an approximate target.

## Version 0.44.0 (2026-07-26)

- Bound and persist the first Brain Stage A window for channels without a cursor.
- Add one Console editor for the five `brain.*` settings and separate installation-owned settings from operator-editable values.

## Version 0.43.0 (2026-07-25)

- Add compare-and-set Console editing for per-Agent Skill experience so stale edits cannot overwrite newer curation.
- Improve the ACH playbook and correct the repository changelog rule.
- Show Identity Provider callback URLs and current DingTalk credential names with targeted failure guidance.
- Let adapters validate credentials before the setup flow redirects to the provider.

## Version 0.42.0 (2026-07-24)

- Fix AIGateway compaction accounting and keep valid function call-output boundaries during overflow truncation.
- Add Turn-scoped runtime facts and redact Worker authentication and declared Agent secrets before provider-bound previews and outboxes.
- Add human-operated Lark approvals and Console editors for Brain embedding and retryable Stage B curation.
- Use forwarded HTTPS for OIDC callbacks and stop enabling the GitHub Agent Plugin for every Agent by default.

## Version 0.41.0 (2026-07-24)

- Remove generic Agent Home path policy from Computer tools while preserving domain-owned paths for attachments, Skills, learning, Job artifacts, and transfers.

## Version 0.40.0 (2026-07-23)

- Remove the CodexRunner `codex_no_progress` termination policy.

## Version 0.39.0 (2026-07-23)

- Repair Feishu CardKit crash recovery and prevent abandoned previews from blocking durable terminal replies.
- Show each clarification choice on its own button.

## Version 0.38.0 (2026-07-23)

- Resume group replies after the Brain visibility migration.
- Repair Feishu CardKit recovery when the provider omits an expected interactive element.
- Allow Brain Stage B to edit or delete the first block at position `0`.

## Version 0.37.0 (2026-07-23)

- Return readable rendered-browser content even when a page never emits `DOMContentLoaded`.
- Rate-limit Feishu CardKit writes without blocking durable replies, and delete old visible replies when `/retry` retracts them.
- Add a two-step AIGateway provider-removal lifecycle and align the Console file browser with Agent-scoped roots.
- Restore JavaScript-safe Schedule IDs, localize Background Job activity in Chinese, and update Turbo to 2.10.6.

## Version 0.36.0 (2026-07-23)

- Publish verified control-plane and Agent Computer manifests through the `main-latest` channel.

## Version 0.35.0 (2026-07-23)

- Restore RuntimeFabric image builds after workspace and Playwright packaging changes.

## Version 0.34.0 (2026-07-18)

- Replace model-visible `/workspace` paths with direct `/agents/<agent-key>` Agent Home paths.
- Share Home and Codex state at Agent scope, and project current Agent documents. Pin each Agent's live Sessions and Jobs to one Worker and Codex account.
- Change Control Plane Plugins to an explicit global allowlist. Existing shipped integrations migrate. New or invalid plugins stay disabled until an operator enables them and restarts Ankole.
- Complete RuntimeFabric ownership cleanup and pin both Agent Computer images to Codex 0.144.6.

## Version 0.33.0 (2026-07-18)

- Reject Background Agent Jobs that still use caller-local `/workspace/user-files` or `/workspace/temp` paths.
- Make `bun dev` shut down cleanly on Unix hosts that reject process-group signals.

## Version 0.32.0 (2026-07-18)

- Allow upgrade from unreleased destructive Job migrations only when PostgreSQL proves that no legacy Job was accepted; otherwise require backup recovery.
- Stop treating admission-only AIGateway frames as stalled output, while retaining stale detection after real output.
- Prevent cold-cache Skill edits from exhausting database connections and add default CJK Matplotlib fonts.
- Bound repeated no-progress Job calls and force stuck Vite watcher shutdown after its graceful window.

## Version 0.31.0 (2026-07-18)

- Publish control-plane and Agent Computer images as one verified, immutable RuntimeFabric pair and reject incompatible mixed runtimes before work starts.
- Make Background Agent Jobs the durable owner of long-running Codex work, with guarded migration of older Job history.
- Repair signal ordering, Schedule recovery, Brain source withdrawal, AppConfigure consistency, Console editing, and BullX native MCP access.
- Patch provider dependencies and restore repository, protocol-generation, lifecycle, and recovery gates after the TypeScript transition.

## Version 0.30.0 (2026-07-18)

- Restore control-plane image dependency installation for the `@ankole/browser` workspace.

## Version 0.29.0 (2026-07-18)

- Migrate RuntimeFabric RPC business payloads from hand-maintained JSON to generated Protobuf messages.
- Align real-LLM Job checks with the persisted Agent Plugin selection.

## Version 0.27.0 (2026-07-18)

- Make queued ambient group intervention use the latest valid channel scene and complete stale, expired, or disabled events without dead-lettering.

## Version 0.26.0 (2026-07-18)

- Keep Feishu WebSocket reconnection in its direct Mint-based owner instead of a shared adapter abstraction.

## Version 0.25.0 (2026-07-18)

- Remove wording-pinned tests while preserving the Skill activity test that prevents file paths and content from leaking into user-visible progress.

## Version 0.24.0 (2026-07-18)

- Add a repository subtraction discipline that removes superseded concepts unless a real dependency or staged migration requires them.
- Set the design priority to simplicity, correctness, consistency, then completeness.

## Version 0.23.0 (2026-07-18)

- Remove low-yield OpenAPI, Schedule, and wording tests while keeping contract and real end-to-end owners.
- Make Brain Stage B source revalidation non-locking so provider edits and deletes do not wait on Brain.

## Version 0.21.0 (2026-07-18)

- Replace per-method Worker RPC wrappers with one required typed requester while preserving rejection and transport-retry behavior.
- Make always-present Turn capabilities required and move strict Background Job response decoding into the RuntimeFabric contract.
- Use one rendered `web_fetch` construction for main turns and Codex Jobs.

## Version 0.20.0 (2026-07-18)

- Define and validate the complete 33-command browser wire protocol once, and derive both CLI parsing and execution from that typed declaration.

## Version 0.19.0 (2026-07-18)

- Resolve completed and current AIGateway Responses through public completion anchors and metadata APIs instead of probing storage layout.

## Version 0.18.0 (2026-07-17)

- Move Identity Provider directory writes into one control-plane owner for groups, bindings, memberships, and subject synchronization.

## Version 0.17.0 (2026-07-17)

- Freeze Background Agent Job Session IDs as the public `"job:" <> job_id` format with one owner.
- Harden Agent Computer path containment against lexical and symlink escapes while preserving intended Session file access and atomic moves.

## Version 0.15.0 (2026-07-17)

- Make each model tool own its user-visible activity text, with a generic fallback only when description generation fails.

## Version 0.14.0 (2026-07-17)

- Derive Background Agent Job RPC, summary, and Console projections from one field owner and validate Console responses against closed OpenAPI schemas.

## Version 0.13.0 (2026-07-17)

- Consolidate common adapter map decoding in one host-owned helper while keeping provider-specific formatting separate.

## Version 0.12.0 (2026-07-17)

- Execute function calls only after a successful tool-use terminal. Reconcile durable results to explicit calls, and quarantine malformed historical pairs without rewriting their audit rows.
- Repair bounded malformed arguments against schemas and split file editing into strict `replace` and V4A `patch` tools.
- Make Protobuf the sole RuntimeFabric envelope definition across Rust, Elixir, and TypeScript, restore the output-token ceiling, and preserve rolling-deploy decoding with golden fixtures.
- Let recoverable Job wakes use the Job attempt budget, remove obsolete delegation retention code, and unify rendered `web_fetch` fallback settings.

## Version 0.11.0 (2026-07-17)

- Add DingTalk as both a chat adapter and an Identity Provider with Stream connections, OAuth login, directory sync, robot messaging, and card support.
- Limit DingTalk groups to addressed-only messages and document unsupported reply, edit, reaction, and reconciliation features.
- Deliver streaming AI replies through operator-configured DingTalk card templates, with continuation cards for long answers.
- Fall back once to durable plain Markdown when card configuration or permanent provider rejection prevents card delivery, and disable departed users from contact events.

## Version 0.10.0 (2026-07-17)

- Add a Console Schedules page for recurring cron work and pending checkbacks, including edit, pause, resume, run-now, delete, cancel, and history actions.
- Add Agent Session listing for the Console, with manual Session ID entry when no durable activity exists.

## Version 0.9.0 (2026-07-16)

- Replace Subagent Delegation with durable Background Agent Jobs; the migration requires no non-terminal old Jobs and does not add compatibility aliases.
- Add resumable Codex Job execution, Agent Plugins, Skill inheritance, Console Agent Library management, and ordinary Plugin-based Deep Research.
- Narrow main turns to foreground work, move durable work and browser automation into Jobs, and replace mcporter with native MCP for allowlisted capabilities.
- Add a persistent browser data plane and pin Codex 0.144.5. Define the Worker container as the security boundary, and make development shutdown cleanly own all child processes.

## Version 0.8.0 (2026-07-15)

- Improve localized Console providers, IM batching and reply context, Checkback controls, CardKit activity, onboarding, Agent documents, visual identity, and CJK artifact fonts.
- Rebuild Deep Research, delegation recovery, Brain evidence curation, source learning, clarification, and retained context around durable, operator-visible contracts.
- Add the long-running Browser Skill, provider-only web profiles, bot-operated Lark Skills, OpenRouter image generation, and read-only Conversation inspection.
- Harden Worker recovery, RPC isolation, file transfers, generated-image persistence, Job output schemas, research retention, and channel-less internal Turns.

## Version 0.7.0 (2026-07-15)

- Query only the selected BullX MCP tool schema so large catalogs cannot truncate into invalid JSON.
- Route cutoff-based latest-bar requests separately from explicit historical ranges.

## Version 0.6.0 (2026-07-15)

- Make `/retry` retract the visible completed suffix and regenerate from its predecessor.
- End valid clarification turns immediately, preserve degraded Brain-search status, and keep one stable prompt and deterministic tool order per conversation.
- Route BullX and web-search profiles correctly, support providers without optional credentials, and keep Skill catalogs bounded.
- Prevent CardKit preview races and use the Agent owner's embedding profile when Brain has no global model owner.

## Version 0.5.0 (2026-07-14)

- Align Auth, Setup, and Console around one responsive Carbon-inspired shell and editor hierarchy.
- Split Brain into Entries, Audit, and Dreaming surfaces with clear filters and run ownership.
- Add typed settings, explicit save boundaries, accessible empty and error states, sensitive-value handling, and a persisted light or dark theme.

## Version 0.4.0 (2026-07-14)

- Prevent `/new` and `/stop` from reviving retryable Turns after cancellation.
- Keep stopped CardKit replies truthful when no partial answer exists.
- Degrade a failed remote Markdown image to its link without delaying durable delivery.

## Version 0.3.0 (2026-07-14)

- Reframe the root architecture maps around product entry points, AIGateway, Brain, durable delegation, and artifact ownership.
- Move migrations and Worker authentication bootstrap into release-owned commands.
- Add streaming Lark CardKit replies with progress, clarification, attachments, and long-answer continuation.
- Recover CardKit delivery after process loss and fall back without dropping terminal results.

## Version 0.2.0 (2026-07-14)

- Make Feishu and Lark CardKit replies durable across preview races, restarts, long Unicode or code answers, and provider limits. Preserve replies during image failures, clarification actions, cancellation, and binding repair.
- Strengthen AIGateway replay, `/retry`, function-tool validation, Brain curation, resident context, scheduled silent output, and renderer-safe progress.
- Improve Console provider setup with clear labels, typed options, advanced fields, masked secrets, custom models, and stable navigation.
- Harden Worker deadlines, process fencing, cross-mount file transfer, local Skill execution, SignalsGateway message storage, and the local end-to-end setup path.

## Version 0.1.0 (2027-07-13)

- First preview release of Ankole.

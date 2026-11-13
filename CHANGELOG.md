# Changelog

## Version 2.0.0-alpha.153 (2026-11-13)

- Keep Zoom in, Zoom out, Fit view, and Focus node working when you use them
  right after the Brain graph opens or after a search changes it. The node
  links appear before the graph finishes drawing, and a click in that moment
  used to be ignored; the graph now applies it as soon as drawing finishes.

## Version 2.0.0-alpha.152 (2026-11-13)

- Center the node when you choose **Focus node** in the Meta Brain object list.
  The graph canvas used to keep its initial width when the graph area started
  narrower, and the redraw for the new selection cancelled the focus
  animation, so the node stayed off center.

## Version 2.0.0-alpha.151 (2026-11-13)

- Open the Brain graph at its settled layout instead of animating every node
  into place. Pod used to redraw the whole network on every step of the force
  layout, which froze the page for seconds on a large Brain; it now computes
  the layout first and draws the graph once, and hovering or selecting a node
  restyles the graph in place. Dragging a node in the network layout moves
  that node alone.
- Open Pages that contain several tables without a pause. The editor used to
  recompute the whole document's layout once for every table it showed; it
  now measures all tables in one pass.

## Version 2.0.0-alpha.150 (2026-11-13)

- Return to Chat after you leave a room from its header. Pod sometimes stayed
  on the room's address and showed a "conversation not found" notice.
- Let the block menu of a heading open with the pointer at common desktop
  widths. At 1280px the sidebar's resize edge covered the heading's
  **Current block menu** button; document and knowledge pages now leave more
  room before the text.
- Open the Agent Library of a new space without the first long wait. Ankole
  now installs the shipped Skills when the space is created instead of during
  its first Agent Library read, which took about nine seconds.
- Notes for fixes that shipped in 2.0.0-alpha.149: a failed database catalog
  refresh now reports whether the address is blocked (`422`), the database is
  unreachable (`503`), or a statement timed out (`504`) instead of a generic
  validation error; **Focus node** in the Meta Brain object list now centers
  the node instead of re-arranging the graph; and a background job that reads
  a Skill available only to the main Agent now says the Skill cannot run in a
  background job instead of calling it not enabled.

## Version 2.0.0-alpha.149 (2026-11-13)

- Stop model profile cards from showing raw model IDs such as
  `claude-sonnet-5-5` for a moment before switching to model names. The Site
  and Pod defaults, system Principals, and Agent model profiles now wait for
  the model catalog before they show the cards.
- Stop selectors and labels from showing a raw ID while the list that names it
  loads. The Console tenant selector right after picking a tenant, the chat
  selector beside a Pod page, the Agent filter on Console lists, and the Agent
  and adapter fields of schedules, signal routes, and identity providers now
  show a placeholder until the name arrives. The home page's background
  activity waits for the agent list instead of asking you to choose an agent.

## Version 2.0.0-alpha.148 (2026-11-13)

- Return to the Private content list after moving a top-level Private page to
  the trash. Pod sometimes opened the hidden system page named Private instead.
- Keep a presentation playing full screen while you change slides or
  collaborators edit the deck. Any update to the page used to leave full
  screen and end the slideshow.
- Turn selected text into a link when you paste a web address from the
  context menu after selecting the text with Shift and the arrow keys or Home.
  The editor used to replace the selected text with the address.
- Limit **Check access** on a page you cannot manage to yourself and your own
  personal assistant. A viewer without manage access could check any other
  person or AI colleague on the page, which only page managers may do.
- Show Base chart labels in the interface language. Axis titles, data table
  headers, and KPI labels name the metric as, for example, "Sum · Revenue" in
  the viewer's language instead of `SUM(Revenue)` or `Count`; the merged
  scatter color group reads "Other" in that language; and screen readers
  announce the metric controls without English words.
- Open the matching records of a Base chart category from the keyboard. In the
  chart's data table, the first cell of each row is now a button that opens the
  same record list as clicking that bar, point, or slice.

## Version 2.0.0-alpha.147 (2026-11-13)

- Fix commands such as `cat`, `bun`, `curl`, and `git` hanging until timeout
  in Codex Jobs. When Codex put its own directories ahead of the Worker's
  output-shaping shims in `PATH`, a shim that should pass the command straight
  through ran itself again in an endless loop, so the Job could not read Drive
  files or run scripts.
- Fix HTTP Responses requests with `store: false` failing on Google AI Studio
  and other Chat Completions providers that reject unknown fields. AIGateway
  now removes `store` before it calls the provider, as the WebSocket path
  already did, so OIDC Clients, Codex, and internal callers such as OCR and
  web search work with these providers again.
- Keep the card of a Workflow or background job on the reply after a person
  interjects in the turn that started it. The card used to vanish from the
  timeline once the reply was saved, so the run could only be opened or stopped
  from the conversation's background work list.
- Let Agents create Infographics and set diagram display options in document
  pages through `ankole-pod`. A ` ```infographic ` fence used to be saved as a
  plain code block, and a `<mermaid>` or `<infographic>` tag with `view` or
  `theme` around its fence was rejected. `pages.read` now also shows existing
  Infographics as editable source instead of locked anchors.
- Show "This view has no records" on a Base kanban view whose grouping field
  has no columns. The view used to show the raw text `pod.content.no_records`.
- Label the per-slot action on the Site defaults tab **Clear** instead of
  **Restore inheritance**, because Site values are the base layer and have
  nothing to inherit. Its confirmation warns that every Pod and Agent without
  its own override of the slot is affected, and the Site's Provider-hosted
  switches offer **Restore default**.

## Version 2.0.0-alpha.146 (2026-11-13)

- Show where each model profile slot gets its value. Every slot header on the
  Pod defaults tab, an Agent, and a system Principal now says whether the value
  is that layer's own override, which layer it inherits from, or which slot it
  falls back to, so an inherited value no longer looks like one the layer
  stores. Before saving a slot that inherits, the header warns that saving
  stops the slot from inheriting.
- Add **Restore all inheritance** to the Pod defaults tab, each Agent, and each
  system Principal. It removes every override of that layer at once, so the
  slots follow the Site defaults again.
- Send the readiness step for model profiles to the Site defaults, which every
  Pod and Agent inherits. It used to open the Pod defaults tab or the first
  Agent's profiles, which saved the first models as overrides and left later
  Site changes without effect. A Pod configured that way keeps its overrides
  until an operator restores inheritance.

## Version 2.0.0-alpha.145 (2026-11-13)

- Let a Claude provider answer conversations. When a site, Pod, or Agent
  pointed a conversation profile such as `primary` or `heavy` at a Claude
  provider, every message used to fail at the start of its turn with
  `stateful_wire_unsupported`. Claude now continues each conversation from its
  stored history, including earlier tool calls and turns that another model
  answered.

## Version 2.0.0-alpha.144 (2026-11-13)

- When the Agent computer cannot start in time, the Agent now stops calling
  computer tools for the rest of the turn and tells the user what is blocked.
  It used to retry calls that could not succeed until that turn ended.
- Trace each Worker acquisition as a `session.worker.acquire` span with its
  outcome, wait time, and phases, so an operator can see where a slow computer
  start spends its time.
- Tell the Agent which tool or id to use next when a background job, Pod Page,
  related context, or schedule call is refused. Reading the result of an
  unfinished background job now returns its progress instead of an error.
- Keep the matches that Drive `grep` and `find` found when some files cannot be
  read or the 15-second limit is reached.
- Hand Applet development to a background job from the main Agent. Codex jobs
  keep tool output small, use `bun` because the computer has no `node`, and
  read `ankole:page` links with `ankole-pod pages.read`.

## Version 2.0.0-alpha.143 (2026-11-13)

- Line up a reply with its author's name in Pod Chat. An Agent's reply and
  another person's message now start beside the avatar, under the name, and so
  do their action rows. The work summary's caret sits on the name's edge, the
  open steps hang from a rail under the caret, and a step's hover background
  stays inside the message. In a chat column wider than 480 px the composer
  lines up with the messages too. The background-work inspector uses the same
  layout, and its composer lines up with its content.
- Redesign the rooms and colleagues in the Chat sidebar's Messages and
  colleagues section as two-line rows with 32 px avatars: the name and time
  above the latest message, shown without Markdown symbols, and its state. A
  group now shows a group avatar in the same rounded square as an Agent's, in
  every list that shows conversations.

## Version 2.0.0-alpha.142 (2026-11-13)

- Support OAuth 2.0 public PKCE clients (`token_endpoint_auth_method` `"none"`,
  `S256`, and custom-scheme redirect URIs) and the `pod` scope in OIDC. On a Pod
  host, `GET /.well-known/ankole-desktop` provisions the tenant's `Ankole
  Desktop` public Client (`ankole://oauth/callback`) and publishes its OAuth
  endpoints, returning `403` when an administrator disables that Client in
  Console. Access tokens granted `pod` carry the `ankole.pod` audience and
  authenticate `/api/v2/pod/*`, `GET /api/v2/pod/bootstrap`, `POST
  /api/v2/pod/realtime-token`, `GET /api/v2/browser/session`,
  `/pod/applet-frame/oauth/*`, and `PodSocket` alongside browser cookie
  sessions.
- Serve a Web App Manifest with 192px and 512px icons at `GET
  /pod/manifest.webmanifest` so browsers can install a Pod as a standalone app.

## Version 2.0.0-alpha.141 (2026-11-12)

- Add a model provider in one step. The new-provider form asks for the API key
  together with the connection and saves it as the provider's first credential,
  so the provider serves requests as soon as it is saved. The credential dialog
  fills in a label and keeps priority and authentication mode under Advanced
  settings.
- Show only the settings that an operator must fill in. Optional settings that
  already work by default move under Advanced settings, including Azure OpenAI's
  endpoint kind and deployment, Vertex AI's location, project, and safety
  threshold, Cloudflare's gateway, Bright Data's search defaults, the AgentBull
  Cloud base URL, and the model profile options of Alibaba Cloud, Jina,
  Parallel, Z.AI, and Xiaomi MiMo. Select fields show readable option names, and
  a provider kind without a default endpoint, such as Azure OpenAI, marks the
  base URL as required and shows an example address.
- Stop saving default values into a new provider's settings. A blank field keeps
  following the provider's current default, so later improvements to a default
  reach the provider too.
- Stop asking for an Anthropic API version on Claude and Xiaomi MiMo
  connections. Ankole now sends `2026-10-21` for Claude 4.5 and later models and
  `2023-06-01` for other models, so Claude 4.5 and later traffic moves to the
  newer version, which leaves out a caller's `temperature`, `top_p`, and
  `top_k`. Upgrading removes the stored version from existing connections, and
  an endpoint that needs a specific version receives it through the
  connection's custom headers.
- Let Xiaomi MiMo connections choose a Token Plan in Singapore or Europe as well
  as China, and authenticate with the `api-key` header that Xiaomi documents.
  Upgrading removes the unused Messages path and beta header settings from
  existing Xiaomi MiMo connections.

## Version 2.0.0-alpha.140 (2026-11-12)

- Fix Page references in Chat drawing a Page's icon over its title when an
  Agent had set the icon to a word instead of one emoji. Pod now shows the
  Page's type mark for such an icon in Chat, the sidebar, and page pickers, and
  the title line offers to add an icon.
- Reject a Page icon that is not exactly one emoji or a custom emoji from the
  Pod library. When a Page is created or updated with any other icon, from the
  browser or through `ankole-pod pages.create` and `pages.update`, the request
  fails with `invalid_icon` and a message that asks for one emoji and suggests
  putting labels such as "Demo data" in the title or content. `null` or an
  empty string removes the icon, an update that sends the stored icon back
  unchanged still succeeds, and the `ankole-pod` help states the one-emoji
  rule.

## Version 2.0.0-alpha.139 (2026-11-12)

- Keep an Agent's prompt cache across every turn of one conversation. Check
  back and cron wakeups, the turn after them, a colleague's returned result,
  and a turn whose Worker has not mounted Drive used to change the model
  instructions or tool list and resend the whole conversation uncached; those
  turns now reuse the cache and answer sooner at lower token cost.
- Stop telling the Agent that Drive is unavailable when a turn starts before
  its Worker is ready. The Agent now uses `/drive` unless the ready Worker
  reports no mount.
- Apply the chat reply length to Pod conversations as well as IM: about 150
  Chinese characters or 100 English words, with longer content saved as a Pod
  Page and linked from the reply. Agent peer exchanges keep their own reply
  rule.
- Remove contradictory file delivery instructions: `reply_attachment` takes a
  `/drive` path or a `node_id`, and the instructions no longer mention a
  scheduled response format that no longer exists.

## Version 2.0.0-alpha.138 (2026-11-12)

- Send Azure OpenAI requests to the Responses endpoint by default. This fixes
  the `Function tools with reasoning_effort are not supported` error that
  GPT-6.1 Sol and other reasoning models returned on every Agent request.
  Upgrading moves every existing Azure OpenAI connection that still uses the
  former Chat Completions default to Responses, and a connection that names a
  deployment sends that deployment as the request's model. An operator who
  serves a deployment that speaks only Chat Completions selects
  `chat_completions` again in the connection settings.
- Offer only the reasoning-effort levels that the selected model accepts in each
  model profile, including Azure OpenAI deployments of OpenAI models and
  ChatGPT subscription models, and hide the setting for a model that does not
  reason. The `ultra` level is removed because no upstream accepts it, and saved
  profiles that chose it now use `max`.
- Send Claude's `xhigh` and `max` efforts under their own names, where `xhigh`
  used to run as `max`. Claude Opus 4.6 and Sonnet 4.6 have no `xhigh`, so
  profiles that chose it for those models must switch to `high` or `max`. A
  Claude profile with fast `speed` also sends the beta flag that fast mode on
  Claude Opus 5 and Opus 4.8 requires.
- Request OpenAI's `priority` tier for the `fast` service tier. The upstream
  used to receive `fast`, which Azure OpenAI silently served at the default
  tier. `truncation` and `promptCacheRetention` now offer only the values that
  OpenAI accepts.
- Offer each model profile only the options that its capability reads.
  Embedding, rerank, image, and web search profiles on OpenRouter and AgentBull
  Cloud no longer show language-model options such as reasoning effort or
  verbosity, which those requests copied into the upstream body unchanged, and
  Google AI Studio language profiles no longer show embedding options. Saving
  such a profile again removes an option it held from before.
- Fix Background Jobs that failed after one minute with `The operation was
  aborted` while another Job of the same Agent was running. A long-running Job
  kept a copy of other conversations' Drive mounts, so reclaiming one of them
  held the Worker's Drive mount lock until that Job ended and new Jobs could not
  mount Drive. Each execution now keeps only its own Drive mounts, an unmount no
  longer blocks other mounts, and a Drive call that misses its deadline fails
  as a retryable `drive_control_timeout` that names the call.

## Version 2.0.0-alpha.137 (2026-11-12)

- Show the signed-in person's own avatar in the Pod sidebar's account row
  instead of the organization's mark, and show a bot mark for an AI colleague
  without an uploaded avatar in Chat instead of initials that repeated its
  owner's name.
- Open a Background Job or Workflow beside the chat as a narrow 440 px panel
  while the chat keeps the rest of the room. Drag the panel's edge, or use the
  arrow keys, Home, and End on it, to resize the panel and the chat; the browser
  remembers the width. The panel's composer now matches the chat composer, with
  Stop and Send pills, Enter to send, and Shift+Enter for a new line, and it
  takes focus when the panel opens.

## Version 2.0.0-alpha.136 (2026-11-12)

- Let Agents render `stat` metric cards (one value with an optional unit,
  comparison, and trend) and `quantile_band` charts (a median line inside a
  shaded range such as p5–p95) with `ankole-viz chart` and `AnkoleChart`.
- Correct product copy in English, Simplified Chinese, Japanese, and Korean,
  and refresh the guidance in the bundled Library Skills and Playbooks.
- Fix Azure OpenAI Chat Completions rejecting every Agent request with
  `invalid_function_parameters`, including conversations without attachments.
  Ankole sends function tool parameters without a top-level `oneOf`, `anyOf`,
  `allOf`, `enum`, `const`, or `not`, and still enforces those constraints
  before running the tool. Azure serves GPT-6.1 Sol function tools only on the
  Responses endpoint, so set the provider's `endpoint_kind` to `responses` for
  that model.

## Version 2.0.0-alpha.135 (2026-11-12)

- Let a Pod member bind owned AI colleagues to paired devices and see each
  binding's live connection status (`connected`, `draining`, or `offline`) in
  **Account → My devices**. Reconnecting on the same route or after an expired
  drain re-admits the binding cleanly, and disconnecting a device fails its
  queued and waiting Jobs alongside running ones.
- Harden Work, Issues, and principal renames: enforce monotonic `Ankole.LockOrder`
  across Issue updates, scheduled triggers, and background dispatch, update
  `issues.squad_uids` and `ai_gateway_media_jobs.request_context["human_uid"]`
  when renaming a Principal, validate cron rules before creating rooms, pass
  Squad colleagues to repeating Issue runs, index active `cron_schedules` by
  owner session, and keep explicit group-listener selections and optimistic Work
  board status updates deterministic.
- Isolate `AIGateway.MediaJobs` onto its own Oban queue with atomic single-charge
  claim transitions and an `(tenant_id, expires_at)` cleanup index, unify Applet
  AI/Web calls through `Ankole.Pod.Applets.Gateway` (preserving `400`, `413`,
  and `422` errors and `:knowledge` Page attachments), enforce `Strict` request
  validation and `provider_options` separation across `universal_ai_client`, and
  bound outbound HTTP redirects, SQL AST stack depth, `.ods`/`.pdf` decompression,
  and OCR response normalization. Run `mix ecto.migrate`.
- Split `@ankole/applet-sdk/toolkits/<toolkit>` into per-platform pure TypeScript
  declarations, consolidate Pele SVG materialization and financial chart time-series
  normalization in `@ankole/uikit/viz`, and restore lazy chunk boundaries for G6
  and PDF.js in `@ankole/webapps`.

## Version 2.0.0-alpha.134 (2026-11-12)

- Realign the shared design tokens with the Ankole Base Styles library. The hue
  colour steps (`--color-red-*` through `--color-magenta-*`) take the library's
  values, and nine hue families join them: `deeppurple`, `rose`, `amber`,
  `orchid`, `royalblue`, `manatee`, `navy`, `lime`, and `pampas`. A step number
  orders one hue from light to dark and no longer promises the same contrast
  in every hue, so an Applet that colours text with a hue step must pick the
  step by its contrast. `--background-tertiary` is gray-40, and
  `--background-quaternary` is removed. In the light theme, hovered, pressed,
  and selected rows, tabs, and toggles take the library's deeppurple-20 wash and
  fill, and a selected item draws no edge. The theme adds
  `--border-quaternary`, a blue-to-brand gradient in the light theme that
  works as an image rather than a border colour, and `--ground` is an image in
  both themes. Dark dialogs, menus, and the modal overlay take the library's
  deep purple surfaces. The theme adds the library's type scale as `text-25`
  to `text-800` utilities and tokens for the drag, overlay, divider, and
  skeleton roles.
- Rebuild the Pod shell on the Ankole layout design. The window rests on a
  ground under a 44 px top bar, and in the light theme that ground washes from
  a cool gray to a warm white. The open route is a white card beside a 258 px
  sidebar. The top bar carries back and forward buttons, the open
  Page's path with its favorite star and source conversation, a search button
  that opens the same `⌘K` / `Ctrl+K` menu, and the Page's actions as icon
  buttons with tooltips. The sidebar toggle sits at the end of the sidebar's
  header row. `Trash` and `Pod settings` move from the foot of the sidebar
  into the account menu. On a phone, a Page's path takes a row of its own
  below the bar, and the Page's more-actions menu adds or removes the
  favorite. The Console's sidebar takes the same row height and toggle size.
- Redraw the Pod sidebar's rows. Every row starts with a 20 px icon in one
  slot. A Page with children shows its expand arrow in that slot while the row
  is hovered or holds keyboard focus, so its icon and title line up with its
  siblings. A section title shows its caret only while the title is hovered or
  holds keyboard focus. Docking and hiding the sidebar move the column and the
  content card together, and sections and a Page's children open and close
  with a height motion.
- Open the Chat tab's Personal assistant group on its five latest tasks each
  time the tab opens.
- Fix an Agent's avatar, which drew a round edge inside its rounded square. An
  avatar's picture, initials, and edge take the avatar's own corners.
- Draw every icon with Fluent System Icons in place of Remix Icon. The UI kit
  re-exports the icons that the product uses as `@ankole/uikit/icons`, under
  Fluent's own component names.
- Set documents and conversations in one 892 px content column with 12 px
  between blocks and more room above headings. A document's text is 16 px on a
  24 px line, and its title is 36 px under its icon. A conversation's text is
  14 px on a 26 px line in the regular weight, a bold phrase in it takes the
  Medium weight, and a reply's headings step down with the text: 24 px, then
  20, 18, 16, and 14 px. Quotes, to-dos, callouts, code blocks, bookmark
  cards, and tables take the design's sizes and colours in documents and in
  chat replies alike.
- Keep a dollar amount such as `$300` as plain text in a chat message. Math
  renders between double dollar signs.
- Parse bold, italic, and strikethrough that touch Chinese, Japanese, or
  Korean punctuation. A phrase such as `**验收：**选择` used to keep its
  asterisks, because CommonMark closes emphasis after punctuation only before
  a space; chat messages and the Console's Markdown now follow the
  CJK-friendly rules, and text in other scripts reads as before.
- Redraw Pod Chat on the content design. A message opens with a 32 px round
  avatar and its author's name, and an Agent's work summary opens from a
  caret. The objects inside a message are one family of outlined cards with a
  20 px mark, a 14 px title, and 12 px meta, so that no card outweighs the
  text around it. A Page reference is a chip on the line of the text that
  names it, with the Page's mark, its title, and a chevron. Files, sent or
  still in the composer, are one-row cards with a type mark, the name, the
  type and size, and a download or remove button. Run cards, delegations,
  Clarify and Action Cards, and next-step cards share the same card; a card
  keeps its warning edge only while its decision waits. A delegation card
  stands under the reply of the turn that sent it, after the reply's work
  steps and text; it shows the start of the colleague's answer as source text
  and opens its exchange when clicked. A table's copy button shows inside the
  table's corner while the pointer is over the table, and each column keeps
  room for four characters. The timeline scrolls only up and down: in a narrow
  chat column, such as the one beside the inspector, a card's text wraps or
  truncates inside the card. Tool steps are rows with one set of status marks, and
  tool output, terminals, and diffs stand in the same block as code. The
  execution inspector, the conversation summary, and the file preview share
  one header.
- Remove model usage from a reply's work summary in Pod Chat. The summary no
  longer names the model and its tokens after "Work steps" or lists each
  model's rounds and token counts under the steps, and a reply that used no
  tool and summarized no thinking no longer shows a "Model usage" line. The
  execution record still carries the usage, and the Console's model usage
  pages still report it.
- Redraw the Pod Chat composer as a translucent panel above a 36 px toolbar
  that holds the attach, mention, and command buttons, the recipient and model
  selectors, and a send pill that turns brand-coloured once the draft can be
  sent. In the light theme the panel's edge runs from blue to the brand
  colour, and the panel rests 17 px above the bottom of the card. While an Agent works, a Stop pill stands before Send, and a narrow
  composer truncates or leaves out the selectors so that nothing overlaps.
  The mention and command list and the composer's menus open on the
  composer's own surface.
- Redraw the editor's slash menu with 60 px rows and 44 px tiles, and give the
  mention menu, the link menu, and the Pod's command menu the same group
  titles, hover wash, and thin scrollbar.
- Fix dividers that never showed, such as the two dividers in the spreadsheet
  toolbar. When renaming a Page meets a title conflict, the question opens as
  a popover under the rename field.
- Show what an action is doing on the control itself. A running button turns
  its icon into a spinner, keeps keyboard focus, and ignores further clicks.
  Copy buttons draw a check in place, loading placeholders share one sweep of
  light, and a chosen radio button's dot arrives with a short motion.
- Make the email code form answer each attempt. The form moves between its
  email step and its code step in place. A rejected code empties the field,
  marks it, and returns focus to it; an accepted code keeps the form busy until
  the browser leaves.
- Show more of an Agent's work in Pod Chat. A finished work step states how
  long it took once that reaches a second. A pressed Stop button shows that
  the request is on its way. On an Action Card, the pressed decision button
  shows the wait and the outcome fades in.
- Move the time of a Pod Chat message into the message's action row, which
  sits directly under the message and 12 px above the next one. A reply's row
  offers select, quote, and copy before its other actions and states its time
  last; your own message states its time first. The latest reply always shows
  its actions and time; an earlier message shows them on hover or keyboard
  focus without moving the timeline. A message from the last 24 hours shows
  only its hour and minute.
- In the Console, Save keeps keyboard focus while it saves, Load more shows
  that it is fetching, the figures on the home page roll when they change, and
  the webhook URL and OIDC client secret copy buttons confirm in place.
- All of these motions respect the device's reduced motion preference.
- Move the Pod's Work board out of the sidebar's tabs. While any work item
  is in To do or In progress, the Home tab shows a Background Agent
  tasks row directly above Shared with me, and the row opens the board under
  the same title. The board is the page's only layout, and the page no longer
  offers New issue, so Issues come from the conversations in which a
  Background Agent Job or Workflow starts and from `POST /api/v2/pod/issues`.
  When the page is too narrow for all five columns, such as beside an open
  Issue, the columns wrap onto another row instead of scrolling sideways.
- Remove from Pod's interface the Work controls that 2.0.0-alpha.123 added:
  the Issue panel, the label filter on the board, the schedule buttons, the
  sub-issue and Squad fields, and the Work tab's badge. The Work board does
  not show an Issue's labels, parent, sub-issues, Squad, or repeating rule.
  Ankole keeps all of them: set them with `POST /api/v2/pod/issues`, replace
  an Issue's labels with `PATCH /api/v2/pod/issues/:id`, and pause, resume,
  run, or remove a schedule with `PATCH /api/v2/pod/issues/scheduled/:id`.
- Open a work item on the Work board in the same side panel that a
  conversation uses for a task. The board narrows to a column while the panel
  slides in, and the panel shows the run's plan, steps, and result with its
  Stop, steering, and answer controls, beside the Issue's Start, Mark done, or
  Reopen step and a link to the conversation. A scheduled task opens its
  conversation.
- Redraw the Work board. Each column sits on a quiet surface under the
  status's icon, its name, and its card count. A card shows what its latest
  live run has done and how it stands, then the title, then the Agent and
  when the work last moved; its Stop button appears while you point at the
  card or move focus into it. The header names the Agents that are working
  now, and a Filter button shows only the cards of the Agents that you choose.
  UIKit adds the `Board` components that draw this layout.
- Turn the gradient edge of the Pod Chat composer slowly, once every eight
  seconds, while its text field has focus. The edge rests at the angle it
  reached when focus leaves, and it keeps still when the device asks for
  reduced motion. The edge's colours are the `--composer-edge-stops` token,
  which takes the stops of the new `--border-quaternary-stops` token on light.

## Version 2.0.0-alpha.133 (2026-11-12)

- Read and edit Word documents (`.docx`, `.docm`) and presentations (`.pptx`)
  directly in Pod alongside spreadsheets (`.xlsx`, `.xlsm`). Create blank
  Office files from the Page creation menu or upload existing files; edits save
  automatically into the Office file with version history, PDF export for Word
  and Presentation Pages, full-screen slide show playback, and Presence soft
  locks on active top-level blocks and slides so collaborators can work on
  different sections or slides concurrently.
- Preview `.docx`, `.docm`, `.pptx`, `.xlsx`, and `.xlsm` Chat attachments and
  read-only file Pages with the same WebAssembly engines, including text
  selection, clipboard copy, and in-file search.
- Convert any Word Page into a native Pod document Page in one click
  (`POST /api/v2/pod/pages/:id/convert-to-document`), preserving headings,
  formatted runs, nested lists, merged and shaded tables, extracted media
  assets, equations, and footnotes while keeping the original Word file intact.
- Add `ankole-pod office` (`inspect`, `render --to`, `commands`, `apply`, and
  `to-document`) so Agents can inspect, visually render, edit, and convert Pod
  Office Pages through the shared operation log without resetting human
  collaborators, while keeping `OfficeCLI` for local `/workspace` files.
- Generalize Pod's spreadsheet configuration and HTTP/channel endpoints to
  Office Pages (`pod.office.limits`, `POST /api/v2/pod/office-pages`, and
  `/api/v2/pod/pages/:id/office*`), migrating existing `pod.spreadsheet.limits`
  tenant settings automatically. Run `mix ecto.migrate`: the migration renames
  `pod_spreadsheet_ops` to `pod_office_ops` and creates
  `pod_office_checkpoints`.

## Version 2.0.0-alpha.132 (2026-11-12)

- Cut repeated access checks on live conversation streams, and let shutdown
  finish its cleanup.
  - A conversation's live event stream reuses a successful access check for
    5 seconds instead of querying the database before every 40 ms text flush.
    A Page-permission change still rechecks at once. Ankole detects a sign-out
    or a disabled Human on the first frame or 15-second heartbeat after that
    5-second window.
  - Supervisor shutdown now runs the cleanup that AI Gateway response streams
    already define, cancelling open upstream streams and program tasks.
  - The Docker Compose control plane waits up to 60 seconds for a graceful
    stop, matching the Helm chart, instead of Docker's 10-second default. For
    the first upgrade to this release, run `docker compose stop --timeout 60`,
    because the running container still carries the old 10-second timeout.
  - When a channel reply preview exits or times out while a new turn takes it
    over, the turn continues without the preview instead of failing.
  - One Applet invocation runs at most 64 capability calls at a time; further
    calls wait and start as earlier ones finish. Feishu, Slack, and DingTalk
    connections dispatch at most 64 events at a time and leave further events
    unacknowledged, so the platform redelivers them.

## Version 2.0.0-alpha.131 (2026-11-11)

- Internal changes only.

## Version 2.0.0-alpha.130 (2026-11-11)

- Internal changes only.

## Version 2.0.0-alpha.129 (2026-11-11)

- Fix Squads after an AI colleague is renamed. Renaming an Agent left its old
  name in the Squads of existing Issues, so those Issues stopped showing it as
  a Squad member. A rename now updates the Agent's name in every Squad.

## Version 2.0.0-alpha.128 (2026-11-12)

- Add Personal Skills, `/learn` workflow extraction, and `/<slug>` Skill
  invocation in Pod. Any workspace member can create, edit, import, and delete
  Personal Skills attached exclusively to their own Personal Assistant
  (`skills.agent_uid`), and members with `tenant_console:custom_skills` can
  promote a Personal Skill to a Workspace Skill. Leading `/learn` turns (and the
  message-level `Save as Skill (/learn)` action) draft `library.skill.save`
  Action Cards validated by `SkillLinter` with revision preconditions and
  personal-draft redaction for other group-room viewers, while leading `/<slug>`
  turns and the `/` command picker invoke runtime-enabled Skills directly.
- Add live Connector Auth Cards, Page Access Cards, and a 4-stage Page access
  diagnostic waterfall. When a native room turn stops on `consent_required` or
  `access_denied` (`node_view`), Pod renders an inline `ConnectorAuthCardView`
  or `PageAccessCardView`, groups pending conversations under `Needs your input`
  (alongside inline Clarify controls on `waiting_on_user` Background Agent Jobs
  and Workflows), and automatically resumes the blocked Agent once the owner
  completes authorization in the popup window or a Page manager clicks `Grant
  view & continue` (preserving any higher existing role). The Page Share
  popover gains a `Check access` view (`GET /api/v2/pod/pages/:id/sharing/explain`)
  showing the 4-stage authorization waterfall, and `pod.page.set_sharing` Action
  Cards summarize affected principals' current access.
- Add the `My Memories & Context` lens (`?lens=mine`), `Focus on me` graph
  highlight, and object claims inspector in `/meta/brain`. Viewers can inspect
  active Facts and Takes on any selected Brain object, filter the graph to the
  1-hop neighborhood around themselves and their Personal Assistant, and add,
  edit (`supersede`), or retract (`forget`) personal memories and workspace
  claims from `/meta/brain?lens=mine` (including private memories captured in
  Personal Assistant DM conversations).
- Enable `programmatic_tool_calling` (`program`) across read-only Session tools
  and `tool_search` (`defer_loading`) for setup tools, preserve prompt-cache
  prefixes across OpenAI Responses, Claude, OpenRouter Claude, and Workflow wake
  turns, project preflight context growth with unproductive-compaction
  hysteresis (while keeping `8 MiB / 1,024-item` provider-history checkpoints
  active), and shape repetitive test, build, package-manager, `git log`, JSON,
  and `cat` CLI outputs in Agent Computer (retaining full raw bytes in
  `outputLogPath` and bypassing downstream pipes and redirections). Run
  `mix ecto.migrate`: the migrations create `connector_auth_waits`, add
  `skills.agent_uid`, and add `library.skill.save` to `action_cards`.

## Version 2.0.0-alpha.127 (2026-11-11)

- Let a scanned PDF be read again, and recover sooner when an OCR run dies.
  A file in the trash no longer lends what OCR read from it, so moving every
  copy of a file to the trash and uploading it again sends it to OCR afresh.
  The job that reads a file's scans now refreshes its claim every 20 seconds.
  When its node dies, another job of the same file takes over after about a
  minute instead of 30 minutes.

## Version 2.0.0-alpha.126 (2026-11-11)

- Give every copy of a scanned PDF its text as soon as OCR has read one of
  them. A copy that was uploaded before the OCR model existed now takes the
  pages that OCR reads from a later upload of the same file. It no longer
  waits for an administrator to accept the charges for earlier scans, because
  taking those pages costs nothing, and Console no longer counts it among the
  unread scans.

## Version 2.0.0-alpha.125 (2026-11-11)

- Send the same scanned PDF to OCR once in a Pod. A file uploaded to another
  place takes the pages that OCR already read from the same bytes, including
  a page in which OCR found no text, instead of being sent again. When two
  extraction jobs hold the same bytes at the same time, one sends them, and
  the other waits and then takes the stored pages. Run `mix ecto.migrate`:
  the migration adds an index on `file_objects (tenant_id, sha256)`.

## Version 2.0.0-alpha.124 (2026-11-11)

- Fix OCR for scanned PDFs in a trashed folder. Pod marks only the folder
  when someone moves it to the trash, so the scans inside were still counted
  when Console asked about the scans uploaded earlier, and they were still
  sent to the OCR provider once an administrator accepted the charges. Pod
  now leaves every file under a trashed folder out of the count and sends
  none of its pages; restoring the folder brings its scans back.

## Version 2.0.0-alpha.123 (2026-11-11)

- Extend Work. An Issue can repeat on a cron schedule: each run sends its
  request to the Agent, reports in the Issue's conversation, and returns the
  Issue to In review, and the person who made it repeat can pause, resume, run,
  or remove the schedule from the Issue's panel or from Scheduled. Issues carry
  labels, and the board filters by one label. A person can break an Issue into
  sub-issues; accepting a sub-issue posts its result in the parent's
  conversation, where the parent's Agent continues. An Issue for a personal
  assistant can name a Squad of AI colleagues among whom the assistant shares
  the work. A direct conversation with an AI colleague or a group now enters
  Work when its first Background Agent Job or Workflow starts, as a
  conversation with a personal assistant already did, and stays there until
  someone accepts it. The Work tab shows a badge for the Issues that need an
  answer or wait for review, and lists them first. Run `mix ecto.migrate`: the
  migration adds labels, the parent link, and the Squad to Issues.

## Version 2.0.0-alpha.122 (2026-11-11)

- Add video and music generation to AIGateway as media jobs. `POST /videos`
  and `POST /audio/music` answer `202` with a job, `GET /videos/:id` and
  `GET /audio/music/:id` read it, and `GET /videos/:id/content` and
  `GET /audio/music/:id/content` send the generated file once the job is
  `completed`. A background job sends the request, waits for the Provider,
  and saves the file in the tenant's object storage, where it stays for seven
  days. The new Pod and Site `video` and `music` profiles select the model:
  OpenRouter serves video, and Cloudflare serves music through the Workers AI
  partner models `minimax/music-2.6` and `elevenlabs/music-v2`. The usage
  ledger records each completed job. The migration creates
  `ai_gateway_media_jobs` and replaces the capability check on
  `ai_gateway_usage_records`, which holds that table's exclusive lock while
  PostgreSQL validates its rows; on a large database plan the upgrade for a
  quiet period.

## Version 2.0.0-alpha.121 (2026-11-11)

- Add the optional `amazon-ai-providers` Plugin, whose `amazon` provider kind
  serves Amazon Polly on the `speech` slot and Amazon Textract on the `ocr`
  slot. Polly takes its engine, such as `neural`, as the model and the
  profile's `voice` when a request names none; Textract reads a PNG or JPEG
  image or a one-page PDF. AIGateway signs each request with AWS Signature
  Version 4 from the pool member's access key and the provider row's region.

## Version 2.0.0-alpha.120 (2026-11-11)

- Close gaps in OCR for scanned PDF pages. Two Pages that hold the same file
  no longer both send its scans when their jobs run at the same time: a
  reconciliation pass enqueues one Page for each object. OCR pages that a run
  kept after it could not store its extraction now join the file's text on the
  next pass, at no charge. A file whose search text went missing is extracted
  again after a rebuild. A result for bytes that were committed again while
  the run was reading is stored for the new object. Committing unchanged bytes
  keeps the cache's time, so a scan whose OCR run failed is still retried. A
  learning run that finds its content version outdated asks for the page's
  current version, which covers the runs that were executing during the
  upgrade to 2.0.0-alpha.119. That upgrade's migration replaces the origin
  check on `ai_gateway_usage_records` first and holds the table's exclusive
  lock until the migration commits, across the view rebuild and two data
  updates; on a large database plan the upgrade for a quiet period.

## Version 2.0.0-alpha.119 (2026-11-11)

- Read scanned PDF pages with OCR. When the Pod or the Site has an OCR model,
  file extraction sends the pages of a newly uploaded PDF that have no text
  layer to that model and adds what it reads to the file's text under the same
  `[Page N]` lines, so Pod search and Brain cover those pages, and Brain
  relearns a file once OCR text arrives. The OCR provider charges for every
  page, so each page is sent once: the file's cache keeps what OCR read
  (`pod_file_caches.ocr`), and later extractions reuse it, as does a commit of
  the same bytes and another Page that holds the same file. Scanned PDFs that
  were not read at upload stay unread until an administrator accepts the
  charges. Console asks when the OCR profile is saved, shows how many files
  and pages are waiting (and says so while it is still counting after an
  upgrade), and stores the answer in the new tenant setting
  `pod.ocr_existing_scans` (default `false`). A Site-level consent covers
  every Pod without a value of its own, and a Pod that declined keeps its
  refusal. AIGateway records the pages under the new `pod_files` usage origin.
  Without an OCR model, scanned pages stay unsearchable. A File Page's content
  version in Brain now follows the SHA-256 of its bytes, so committing an
  unchanged file again, as an Agent's `drive put` does, no longer makes Brain
  learn it again; the upgrade renames the versions that learned files and
  waiting learning jobs carry.
  `Ankole.Kernel.file_extract_text/4` takes the page texts, a PDF's cache
  metadata lists the pages OCR read in `ocr_pages`, and
  `GET /api/v2/unread-scans` and `GET /api/v2/site/unread-scans` return the
  waiting files and pages.
- Let the `ocr` Skill call the AIGateway OCR API. The Skill gains
  `scripts/ocr_api.py`, which sends an image or a PDF to `/ocr` and prints
  Markdown per page, next to the local engine; the Agent decides which one to
  use. The shell of a Codex Job receives `ANKOLE_RUNTIME_AI_GATEWAY_URL` and
  `ANKOLE_RUNTIME_AI_GATEWAY_TOKEN_FILE`, so a Skill script can call a gateway
  endpoint with the Agent's own key.

## Version 2.0.0-alpha.118 (2026-11-11)

- Add `POST /audio/speech` and `POST /audio/transcriptions` to AIGateway, with
  Pod and Site `speech` and `transcription` model slots in Console. OpenRouter
  serves its text-to-speech and speech-to-text models, and Cloudflare serves
  the Deepgram Aura models and the Workers AI models that take base64 audio,
  such as Whisper large v3 turbo. A speech response is the audio itself, as
  `mp3` or `pcm`, and a client can ask for it with `Accept: audio/*`; a
  transcription returns the text, plus the language, the duration, and timed
  segments with `verbose_json`. Both requests fail with
  `model_profile_not_configured` until an operator binds the slot. Run
  `mix ecto.migrate`: the migration lets the usage ledger record a speech call
  by its characters and a transcription call by its seconds of audio. It
  rechecks every usage row under a table lock, so gateway calls wait while it
  runs on a large ledger.
- Add `POST /ocr` to AIGateway. It returns the text of one PNG, JPEG, or WebP
  document image as Markdown, read by the caller's `vision_fallback` language
  model, or by `primary` when that profile is not configured.
- Add `AnkoleRuntime.ai.generateSpeech`, `ai.transcribe`, and `ai.ocr` to
  Applets. `generateSpeech` saves the audio as a Pod file the way
  `generateImage` saves an image, and `transcribe` and `ocr` read a Pod file.
- Let `POST /ocr` read PDFs through a dedicated OCR model. Add the `mistral`
  provider kind and the Pod and Site `ocr` model slot in Console. With the slot
  bound, `/ocr` accepts a PDF of up to 50 MiB and an optional `pages` list of
  up to 100 page indexes, starting at 0, and returns Markdown per page. Without
  the slot, a language model that accepts images still reads one image, and a
  PDF fails with `unsupported_value`. Run `mix ecto.migrate`: the migration
  lets the usage ledger record an OCR call by its pages, and it rechecks every
  usage row under a table lock as well.
- Show a provider's request options in Console only on the model profiles that
  use them. A provider kind can limit a request setting to some of its
  capabilities, so a speech, transcription, or decision profile on a Cloudflare
  provider shows neither the search engine nor the image options, and a speech
  or transcription profile on OpenRouter shows no language-model options.
- Show the usage of capabilities that count no tokens on the Console Model
  usage page. A table lists OCR, transcription, speech, image generation, and
  decision-model calls with their number, the quantity in pages, seconds,
  characters, or images, and the cost in US dollars when the Provider reports
  one.
- Bring File Pages into Brain. `recall` searches a public file whose text
  Ankole can extract (PDF, Office and OpenDocument files, spreadsheets,
  CSV/TSV, and text) by page, slide, sheet, or section. A file in the Brain
  tree, or one whose own page or an ancestor enables `extract_facts`, also
  yields facts and timeline events that cite it, and the Brain graph shows it
  as their evidence source; a File Page has its own Learn business facts
  control for that. A spreadsheet contributes one summary of its sheets and
  columns instead of row-level facts. Replacing a file relearns it, and a file
  replaced by a format that Ankole cannot read drops its passages, facts, and
  timelines. The `brain` tool reads a file's extracted text with a note of
  what the extraction covered. Extracted search text now carries the numbers,
  dates, and formula results of spreadsheet cells, marks each page, slide, and
  sheet (`[Page N]`, `[Slide N]`, `[Sheet: name]`), turns Word and
  OpenDocument headings into `[Section: outer > heading]` lines, and labels
  table rows `R<row>`; after the upgrade, Ankole re-extracts existing files in
  the background. The migration adds File Pages to `brain_page_nodes` and
  renames `upstream_state.facts_revision` and `timeline_revision` to
  `facts_version` and `timeline_version`.
- Keep addressing an Issue's Agent after a teammate joins the Issue's
  conversation. The conversation becomes a group, and its composer selects the
  Issue's Agent as the recipient until the member picks another one.

## Version 2.0.0-alpha.117 (2026-11-11)

- Internal changes only.

## Version 2.0.0-alpha.116 (2026-11-11)

- Fix long conversations that stopped answering with
  `provider_history_byte_limit_exceeded`. When a model streamed its reasoning
  through a Chat Completions provider such as OpenRouter, AIGateway stored
  every streamed fragment as a separate `reasoning_details` entry, so the stored
  reasoning took many times the bytes of the reasoning itself. A conversation
  could then reach the `8 MiB` history limit of one Response long before the
  token trigger for compaction. Every later message in it ended with the
  "This message could not be finished" notice, and `/retry` failed the same
  way. AIGateway now joins the fragments of one reasoning text into one entry,
  both when it stores a response and when it replays a stored one.
- Compact a conversation when its stored history reaches three quarters of the
  item limit (1,024) or byte limit (`8 MiB`) of one Response, even when it is
  below the token trigger. A conversation that already fails with
  `provider_history_byte_limit_exceeded` or `provider_history_item_limit_exceeded`
  is compacted on its next message and continues; `/compress` remains
  available. When that compaction cannot write its summary, the message runs on
  the full history as before.

## Version 2.0.0-alpha.115 (2026-11-11)

- Sync the block editor engine with Wordgard through `7008e6a`. The engine
  lifts a wrapped paragraph on Backspace before joining it, splits a continued
  list item when Enter lifts an empty paragraph, and removes an empty block
  before deleting a neighboring leaf. A double-click that is not on a word
  places a normal caret. Paste follows the DOM selection, and `Wordgard.paste`
  inserts HTML and plain text through the same paste handlers. `Wordgard.label`
  puts `aria-label` on the editable element, and a focused editor is marked
  with `wg-focused`. Page block-boundary keys keep their own Backspace, Delete,
  and Enter rules.
- Webapp production bundles target Chrome 132, Firefox 160, and Safari 18.
- Guard IME composition `Enter` in creatable comboboxes, number inputs, cron
  editors, and icon upload dialogs, add 2D keyboard grid navigation to the date
  range picker, default OTP inputs to a numeric mobile keyboard and one-time
  code autofill, preserve focus outlines in Forced Colors mode, expand compact
  touch targets on coarse pointers, style combobox, command, and sidebar lists
  with high-contrast thin scrollbars, and keep color and opacity feedback under
  `prefers-reduced-motion` while slowing spinners and turning off spatial motion.
- Add TypeSafe SystemOne and compatible endpoints, Microsoft Foundry through
  `azure_openai`, OpenRouter SystemOne models, and OpenAI `gpt-6-luna` as
  decision-model providers, and map `promptCacheOptions` and `safetyIdentifier`
  across OpenAI language and decision requests. Decision requests retain one
  public contract across native state, image, instruction, and answer
  encodings, record provider cost and cache writes, and reject the whole
  request with `upstream_decision_refusal` when OpenAI declines any question.

## Version 2.0.0-alpha.114 (2026-11-11)

- Add Issues and the Pod's Work tab. An Issue hands background work to an
  Agent: it has a title, a description, and the personal assistant or AI
  colleague that does the work. Starting an Issue posts the request as the
  first message of the Issue's conversation, where the Agent's replies and its
  Background Agent Jobs and Workflows appear as they do in Chat; an Issue
  created with Start later waits. The Work tab shows Issues as a board or a
  list whose columns follow the Agent's real work (To do, In progress, Needs
  you, In review, Done), shows each live run on its card with a Stop action,
  and lists the scheduled tasks of the conversations in a member's Chat list.
  A conversation with a personal assistant becomes an Issue when the assistant
  starts its first Background Agent Job or Workflow there. Run
  `mix ecto.migrate`: the migration creates the `issues` table.
- Fix permanent deletion of a Page that an Agent discussion or a shared chat
  was anchored to. The purge failed; Ankole now keeps such a conversation for
  the people who joined it.
- Fix tenant deletion when a discussion among people was anchored to a Page.
  The deletion failed at that Page and retried without end; Ankole now releases
  such conversations from their Pages before it deletes the Pages.
- Add the `google_vertex_ai` provider kind for Gemini and partner models on
  Google Vertex AI. Each credential is the JSON key file of a Google Cloud
  service account; AIGateway exchanges it for access tokens and renews them
  without operator action. The row selects a location (`global` by default),
  can override the project, and can set one safety filter threshold. Model
  profiles name models as Google does, for example `gemini-2.5-pro`.
- Fail an AgentBull Cloud request when its hosted token cannot be minted or is
  rejected. The provider fell back to the row's static `api_key`, so a revoked
  hosted token kept working. It now uses the static key only when no hosted
  credential is present, and a row without any credential fails instead of
  sending an unauthenticated request.

## Version 2.0.0-alpha.113 (2026-11-11)

- Keep an Agent computer's Drive working when a control-plane Pod is replaced.
  A Worker mounted Drive at the address of the Pod that configured the mount,
  so after a rollout or a node replacement every command on that Worker waited
  up to seven minutes and then failed with `mount: /drive/Skills: ... Connection
  refused` until the Worker itself was replaced. A Worker whose provider sets no
  `endpoints.relayOrigin` now mounts Drive at the HTTP origin of its
  RuntimeFabric endpoint, which the Helm chart points at the control-plane
  Service. If a proxy fronts `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` or a
  provider's `endpoints.runtimeFabricUrl`, it must also forward `/api/v1/vfs/`,
  including WebDAV methods such as `PROPFIND`, to the control plane. Workers
  started by an earlier release keep their old mounts until they are replaced.

## Version 2.0.0-alpha.112 (2026-11-11)

- Internal changes only.

## Version 2.0.0-alpha.111 (2026-11-11)

- Change the response of `POST /api/v1/ai-gateway/web_search`. AIGateway
  returns `items` and `metadata` in place of `success`, `query`, and `results`.
  Each item carries `url`, `title`, and `description` (formerly `snippet`),
  plus `published_at` and `score` when the provider reports them; the order of
  `items` replaces `position`. `metadata` carries `query`, `latency_ms`, and
  the HTTP `request_id`. A query can now have 1,024 characters instead of 500.
  Callers of the HTTP endpoint must read the new fields; the `web_search` tool
  and `AnkoleRuntime.web.search` return what they returned before.
- Add `POST /api/v1/ai-gateway/decisions`, which answers `noul`, `choice`, and
  `score` questions about a state and returns a probability with every answer.
  The new Pod and Site `decision` model profile selects a decision model. When
  the profile is not configured, the caller's `light` language model answers;
  its probabilities are its own estimates and are not calibrated. Applet
  backends ask the same questions through `AnkoleRuntime.ai.decide`.
- Add the `cloudflare` provider kind. One provider row, configured with an API
  token, an Account ID, and a Gateway ID, serves `web_search` through
  Cloudflare Web Search, the `decision` profile through decision models such
  as `@cf/cloudflare/clef` and `typesafe/jev`, and the `image_generate` profile
  through FLUX.1 [schnell] and the Black Forest Labs models such as
  `black-forest-labs/flux-2-pro-preview`, which also edit up to eight
  reference images.
- Add `POST /api/v1/ai-gateway/images`, which generates or edits one image
  through the image provider that the request's `model` selects and returns it
  as `data[0].b64_json` with its `media_type`.
- Let a provider kind that has no image catalog serve the `image_generate`
  profile. OpenRouter and AgentBull Cloud keep reading their catalogs; any
  other provider module names the endpoint for each image model through the
  `image_endpoint/3` callback. AIGateway downloads the image that a Black
  Forest Labs model on Cloudflare returns as a link.
- Record generated images and decision-model calls in the usage ledger. Each
  `ai_gateway_usage_records` row gains `capability`, and a row for generated
  images also carries `unit`, `quantity`, and the `provider_cost` that the
  provider reports. Agent token quotas, per-turn usage, and the Console Model
  usage page keep counting language-model rounds only. Rows written before the
  upgrade are language-model rows.
- Fix Console forms losing text that arrives without a key press. When a field
  showed a validation error, the first paste from the context menu, autofill,
  or drag-and-drop left the field empty; the field now keeps the text and
  clears the error.
- Keep what a member did in an Agent's reply when the reply finishes
  streaming. The open work summary, a code block's line wrapping, a Mermaid
  view, and the state of a `ui` block stay as they were, and the reply no
  longer shifts when it is saved. A `ui` block also shows the state its reader
  left when the reader returns to the room.

## Version 2.0.0-alpha.110 (2026-11-11)

- Connect your own devices in Pod account settings and choose one when
  starting a background Job. The Job resumes on the same device and
  workspace after a connection interruption. Agents continue to use their
  managed Workers for ordinary work.

## Version 2.0.0-alpha.109 (2026-11-11)

- Filter Base views, Applet record queries, and Base aggregates with `not_is`
  ("is not") and `in` ("is any of", up to 500 items), matching PostgreSQL null
  semantics across server and local small-table execution, and search Base
  records from the CLI with `pod base list-records --search <text>`.
- Build interactive Applets with `Slider`, `NumberInput`, `DatePicker`,
  `DateRangePicker`, `FileDropzone`, and `PrincipalBadge` from `@ankole/uikit`,
  resolve workspace Human and AI colleague profiles via `usePrincipals` and
  `usePrincipal`, navigate between Pod Pages with `pod.navigateToPage`, and hand
  off context quotes or prompts to the Page Chat sidebar with `pod.openChat`.
- Read active source-scoped Brain Facts from Applet backends with
  `AnkoleRuntime.brain.listFacts`, and include resolved `holderUid` fields on
  Applet Fact and Take payloads for Principal badges and Brier calibration
  views.
- Preserve queued user inputs when editing the last message of an idle Pod
  conversation, open conversation-summary files directly in the Chat preview
  pane, keep portrait and landscape PDF first-page thumbnails at their true
  aspect ratio, and unfurl `application/xhtml+xml` links while unwrapping empty
  list items when converting pasted URLs into cards or previews.

## Version 2.0.0-alpha.108 (2026-11-11)

- Let an Agent show a small interactive UI inside a reply in Pod Chat. A fenced
  `ui` block renders as tabs, collapsible sections, sortable tables, inline
  charts, headline numbers, and segmented switches, and a button in the block
  leaves a follow-up question in the composer for the member to send. The
  visualization Skill teaches Agents the block. Only native Pod rooms offer it,
  and external chat channels receive replies as before.

## Version 2.0.0-alpha.107 (2026-11-11)

- Give shared controls immediate visual feedback. Switch thumbs stretch on
  press, checkboxes draw their marks, and one highlight follows the selection
  in tabs and menus. Form errors and verification code fields animate as
  their state changes.
- Show new words and execution steps as they arrive in Pod chat, and display
  elapsed time for live turns. Composer menus unfold from their buttons.
  Dragging files into the composer reveals a drop target, and each card shows
  actual upload progress and offers a retry on failure.
- Move one highlight between quick navigation results and resize the list as
  results change. Escape clears the search before closing the menu, and
  Command/Control+1–5 opens the available shortcuts. All these motion cues
  respect the device's reduced motion preference.

## Version 2.0.0-alpha.106 (2026-11-11)

- Build Applet tables with sticky headers and columns, keyboard navigation,
  controlled sorting, and virtual scrolling for loaded rows.
- Ask a designated reviewer for a decision in an Applet and display it with
  `ApprovalCard`. Applet Actions can also post unread notices to authorized
  native conversations without starting an Agent turn. The control-plane
  migration creates `pod_applet_approvals` to store requests and decisions.
- Record and read Brain Takes from Applets and show source-scoped calibration
  scores by researcher.
- Read Applet evidence files by expected SHA-256 and report a conflict when
  the contents change. Applets can also tell whether a Signal reached a
  matching Binding.

## Version 2.0.0-alpha.105 (2026-11-10)

- Speed up repository checks. The control-plane checks run as two parallel
  jobs: static checks compile `Ankole.Kernel` without its crate
  (`ANKOLE_KERNEL_SKIP_NIF=1`) and need no Rust toolchain, and the
  generated-contract checks restore the kernel NIF from a cache keyed on the
  kernel's inputs. `mix ankole.toolkits` formats the generated contracts in one
  `oxfmt` run instead of one per file, and its check compares JSON contracts by
  value without formatting them. Torque uses its precompiled NIF in these
  checks.
- Skip the repository checks for documentation-only changes. The
  `Repository checks passed` job always reports a result, so branch protection
  can require it. Pull requests restore the caches that `main` saves and no
  longer save their own copies.
- Build the runtime images while the repository checks run on `main`; the
  immutable control-plane, Worker, and Function Runtime tags still wait for the
  checks. The control-plane and Worker images declare the per-release build
  arguments after their package layers, so a release no longer rebuilds those
  layers.

## Version 2.0.0-alpha.104 (2026-11-10)

- Fix the arm64 control-plane image build, which failed with `revision ... not
  found` for the `gridcraft` git dependency. The kernel WebAssembly stage and
  the Elixir build stage ran in parallel and cloned the dependency into the
  same Cargo git cache at once; the WebAssembly stage now keeps its own Cargo
  caches.

## Version 2.0.0-alpha.103 (2026-11-10)

- Record prompt-cache reads and writes in the model usage ledger. Each
  `ai_gateway_usage_records` row gains `cache_creation_input_tokens` for cache
  writes beside `cached_input_tokens` for cache reads, and the Console Model
  usage page adds a Cache writes column beside the column that it now labels
  Cache reads. AIGateway now reads the cache reads that DeepSeek reports as
  `prompt_cache_hit_tokens` and Kimi as a flat `cached_tokens`, and the cache
  writes that OpenRouter and Kimi report as `cache_write_tokens` and DashScope
  as `cache_creation_input_tokens`. Rows written before the upgrade keep `NULL`
  cache writes.

## Version 2.0.0-alpha.102 (2026-11-10)

- Show upload progress on chat attachments. While a file uploads, its card
  shows the bytes sent against the total and a progress ring on the remove
  control; a finished or sent attachment shows its size.
- Show the first page of a PDF as its thumbnail on Grid cards of the subpages
  directory. Chat attachment cards show an image as its thumbnail and mark any
  other file with its extension.
- Read PDFs in an Ankole viewer on File Pages and in the chat attachment
  preview. The viewer follows the light and dark themes and has page, zoom,
  and whole-document find controls, selectable text, and working links; it
  also renders PDFs that do not embed their CJK fonts.

## Version 2.0.0-alpha.101 (2026-11-10)

- Leave the caret on the line after the block when you switch a page mention
  to the embed view, a link to the card or preview view, or a web embed or
  media block between views, instead of selecting the block. Typing and IME
  input continue below it, and when no text follows the block the switch adds
  an empty paragraph there in the same undo step.
- Show a selected Applet, Base, or other Pod page embed with a ring around the
  whole block. The selection fill used to tint only the embed's title row once
  the page content loaded. Mermaid diagrams, tables, and dividers use the same
  ring, and web previews, web cards, and media show their highlighted border in
  every block selection, not only when they are selected alone.
- Align the Brain knowledge graph toolbar: the search field, category select,
  layout switcher, view toggles, and zoom buttons share one 32 px height, so
  their edges and labels line up.

## Version 2.0.0-alpha.100 (2026-11-10)

- Internal changes only.

## Version 2.0.0-alpha.99 (2026-11-10)

- Open a Pod chat file in its preview when you select its card, in Agent
  replies, your own sent messages, the composer, queued messages, and the
  conversation summary. The preview carries **Download original** and **Open in
  new tab**, and files that Pod cannot render open it with their type, size, and
  those actions instead of downloading straight away. **Save to Pod** stays a
  separate button on reply cards.
- Preview Pod chat files in the formats that the Pod file page renders. CSV and
  TSV files open as the file page's UTF-8 table, so Chinese text in a CSV saved
  without a byte-order mark no longer turns into garbled characters; Markdown
  files open rendered, with tables, formulas, and Mermaid diagrams; `.xlsm` and
  `.xlsb` workbooks open in the read-only workbook preview; and SVG images open
  in the image viewer. A chat file that arrives without a media type, as some
  uploads and channel files do, previews by its extension, and Ankole serves
  such files with the media type that their name implies, so a PDF or image
  without a recorded type opens inline instead of downloading.
- Restyle Pod, Console, the website, and system emails to the Ankole colour
  schema in light and dark themes. Primary actions, keyboard focus, hovered and
  selected rows, and text selection use the brand colour `#ff4669`; the
  neutral `--color-gray-*` ramp becomes pure grey from `#fbfbfb` to `#1c1c1e`;
  the dark theme sits on a black ground with a `#0b0b0b` page; status marks,
  backgrounds, and badges take the schema's state colours; and a disabled
  primary button keeps a faint brand fill. Every selected item (the current
  sidebar row, the chosen tab, a selected table row, a pressed toggle) shares
  one selected fill with a hairline edge, and the Pod and Console sidebars sit
  on white beside a faint divider. Applets that read `--color-gray-*` steps
  directly see lighter greys at the same step numbers.
- Let a SaaS build replace shared webapp assets such as the UIKit fonts through
  an `assets` map in `internals/webapps/entries.json`, so the build emits them
  under the SaaS file names.
- Slide the selected fill between object tabs (the Pod sidebar's **Home** and
  **Chat** tabs, Pod settings, and Applet settings) instead of switching it at
  once; in the sidebar the old tab's label closes and blurs away while the new
  label opens.
- Remove the create button from the top of the Pod sidebar's Home tab. Create
  Pages from the **Space** and **Private** section headings, a Page row, or a
  content list.
- Move the Console's setup readiness, theme toggle, and sign-out buttons to the
  right end of the full-width top bar, in both the open-source and SaaS
  Consoles. The navigation toggle moves from the top bar to the start of the
  page sheet's header, left of the current section's name, as on a Pod sheet.
  In both the Console and Pod, the top bar and the shell around the page sheets
  sit on the page background (`--background`) instead of the grey ground.
- Lay out the Pod and Console shells on the Ankole layout grid: a 56 px top bar,
  a 236 px sidebar (Pod's resizable sidebar starts there), and a page that fills
  the rest of the window edge to edge with small rounded top corners. A Pod
  document's column is 832 px wide with at least 68 px on either side and starts
  68 px below the page's top edge, and the comments and Page assistant drawers
  are 296 px wide and sit flush against the page and the window's edge.
- Give Pod the same full-width top bar above the sidebar and the page sheets.
  **Search or jump** moves from the sidebar into its centre, and the open
  route's actions sit at its right: a Page's actions, from its save state and
  presence through **Share** and the more-actions menu, and a Conversation's
  participants, invite, and summary buttons. **Copy link** leaves the
  Conversation's more-actions menu and becomes a share icon among those top bar
  buttons. The sidebar toggle moves to the left of each sheet's title, while the
  Page's sheet header keeps the path and the favorite star and a Conversation's
  header keeps its title, with no hover wash, followed by the more-actions
  menu. Find in the conversation moves into that menu, and every item in it
  carries an icon. The Pod's mark and name start the Pod top bar, and the search entry in its
  centre is a quiet, borderless field up to 240 px wide that becomes an icon
  button on a narrow top bar. A Conversation's
  title and its rename field take the width of the title text, and a long
  title truncates with its full text in a tooltip.
- Keep a chat message's hover actions from covering the next message when the
  same author posts again. Consecutive messages from one author now sit 28 px
  apart, which leaves room for the copy, quote, and select bar and for the next
  message's time.
- Line up every Page row in the Pod sidebar's Space and Private trees on its
  icon. A Page with children shows its icon in the same slot as its siblings
  and turns it into the expand chevron on hover or focus, instead of placing a
  chevron to the left of the icon.
- Stop icon buttons from looking selected after a click. **Trash** and **Pod
  settings** in the sidebar footer keep their resting look while their page is
  open, the conversation summary button keeps its resting look while the
  summary is open, and the participant avatars in the top bar show no hover
  fill.
- Show a Base kanban board's **Ungrouped** column only when some records have
  no value in the grouping field, instead of always showing an empty one.
- Give each Pod chat room one right sidebar for its summary, a linked
  execution, or a file. The summary is a 296 px drawer; on desktop an execution
  or a file slides in from the right and takes everything beside a 300 px chat
  column, which narrows over the same motion, and selecting a file card now
  previews the file in that sidebar instead of a dialog. The execution inspector no longer has its own resize
  handle, because the sidebar's width follows the room. Phones and the Page
  assistant panel keep the slide-over sheet and the preview dialog.

## Version 2.0.0-alpha.98 (2026-11-09)

- Switch external links in Pod documents across four views—inline `Link`,
  inline `Title`, `Card`, and `Preview`—and unfurl webpage titles, descriptions,
  favicons, and preview images through SSRF-guarded metadata fetching
  (`POST /api/v2/pod/links/unfurl`). External `<embed href="..." />` blocks
  replace separate `<bookmark>` blocks (existing Document and Knowledge
  bookmarks migrate on upgrade), embeddable `@Page` mentions and inline Pod
  Page embeds switch between inline mention and embedded views, pasted Pod Page
  links become `<mention>` or `<embed>` references automatically, and image,
  video, audio, file, and embed blocks share compact single-line creation bars,
  floating actions, and resizable frames.
- Paste structured Markdown, IDE code selections, and `<iframe>` snippets
  cleanly into Pod documents. Multi-block GitHub Flavored Markdown (headings,
  nested task lists, tables, callouts, math, Mermaid and Infographic diagrams,
  and YAML frontmatter) pasted as plain text or `<pre>` wrappers converts into
  document blocks while `Shift+Paste` keeps plain text, VS Code and Cursor
  selections keep their language-tagged code, Mermaid, or Infographic blocks,
  standalone `<iframe src="...">` snippets become `<embed>` previews, and
  multi-line Markdown pasted when replacing a Document Page title places the
  first heading into the title and the remaining blocks into the document body.
- Allow any Base field type to serve as a table's primary display column, lift
  forced primary-column locking in Grid views and column deletion when at least
  one other column remains, and add server-side `search` filtering to
  `POST /api/v2/pod/tables/:table_id/query`. Members and Agents can convert a
  table's initial column in one step while empty, promote another column with
  `is_primary: true` on `PATCH /api/v2/pod/fields/:field_id`, format non-text
  display fields consistently across linked-record pills, cards, charts, VFS
  exports, and table copies, and search linked-record pickers across all pages
  on the server.

## Version 2.0.0-alpha.97 (2026-11-09)

- Fix the Pod Connectors page asking for the same authorization again on every
  reload after a member connected an account from a consent link.
- Log `lark_adapter.inbound.message_without_chat_binding` when a Feishu or Lark
  long connection that serves no chat binding receives a chat message. Feishu
  delivers each event to only one long connection of an application, so this
  warning shows that a connection opened for real-time directory sync is taking
  messages from another deployment that uses the same application. The
  `Sync directory changes` setting now explains when to turn it off.

## Version 2.0.0-alpha.96 (2026-11-08)

- Tidy the environment variable editor shared by Space settings and Applet
  settings. The save button now reads "Save variable" instead of a raw message
  key, the name and value fields drop their long hints, the encryption switch
  explains the plaintext choice when it is off, the stored-secret hint sits
  under the value it describes, and the inherited-variable table lines up its
  columns. "Paste .env" is now "Bulk import", because the button opens the
  import form rather than reading the clipboard.
- Put the heading first on the Applet Automation, Webhooks, and Run logs tabs.
  When an Applet publishes no Action, these tabs no longer offer "New Job" and
  instead tell a Page editor to ask the Agent to add one, or tell a contributor
  to ask an editor.
- Make the Space settings sections consistent: Members, Agents, Invitations,
  and Enterprise SSO now each open with a heading and a description, SSO shows
  an empty state when no identity provider is connected, and the save bar
  appears only while there are unsaved changes. On member cards, "Offboard" is
  an outline button that opens the confirmation, and each member's sign-in
  methods carry a label.
- Name a personal assistant that keeps its default name after its owner alone,
  such as "Alex's assistant" instead of "Assistant (Alex's assistant)".
- Polish page details across Pod and Console: headings balance their lines and
  paragraphs avoid a lone last word (text being edited keeps normal wrapping),
  Base number cells align right with even
  digits, Base creates tables, views, and fields from buttons with an add icon,
  the Child pages button collapses to an icon on narrow screens like its
  neighbours, Share and the document status button show a tooltip, chat
  participant avatars overlap less, and the account menu shows a placeholder
  instead of a stray initial while it loads.
- In Console, each page now opens at its top instead of keeping the previous
  page's scroll position, the all-tenants view uses outline create buttons so
  each screen keeps one primary action, Files has its own navigation icon, and
  the Chinese interface calls Worker providers "Worker 提供商".
- Fix layout on phones and narrow pages: a continued chat message no longer
  draws its time over the previous message's actions, an embedded Page title
  truncates instead of overflowing both sides, and the Base header shows adding
  a field as an icon button so a narrow table keeps its label readable.
- Base boards leave the grouping field off their cards, galleries keep space
  below the toolbar, personal settings show the save button only while the name
  has changed, and the Space guest option wraps its hint evenly.
- In Console, header actions stay on the right when they wrap, the Workers
  empty state names Workers, Schedules translates its Cron and Checkbacks tabs,
  and the Chinese Worker provider and Automation Job pages use consistent terms.

## Version 2.0.0-alpha.95 (2026-11-08)

- Redesign Pod personal and space settings with responsive section navigation,
  clearer grouped forms, and consistent save states, add persistent PNG, JPEG,
  GIF, and WebP avatar uploads for both member and space profiles, and resolve
  multi-space account switcher avatars against each space's own Pod origin and
  authentication reference.
- Add `AnkoleRuntime.web.search`, `AnkoleRuntime.web.fetch`, and
  `AnkoleRuntime.ai.generateImage` (plus `AnkoleRuntime.admin.{web, ai}`
  equivalents and tab-authenticated `pod.fileURL` / browser-bound `result.url`
  display URLs) to Pod Applets, introduce Applet-scoped environment variables
  with four-layer inheritance (`Site -> Space -> applet.env.json -> Applet`),
  structured `applet.env.json` contracts, single-refresh `.env` batch import
  that retains failed entries for retry, and Space Settings management, and
  unify Applet Page settings (`Variables`, `Automation`, `Webhooks`, `Run logs`,
  and `Functions` backed by `GET /api/v2/pod/pages/:page_id/functions`) into a
  single Applet settings modal with shared Job creation state.
- Edit earlier sent messages directly in Pod Chat (`edit_last`) and navigate
  editable messages from the keyboard with double-`Escape` backtrack (including
  inside mobile `PageChat` sheets without dismissing the sheet). Submitting an
  inline edit stops active turns, delegated peer exchanges, Workflows, and
  Background Agent Jobs (including continuation successors) spawned from the
  reverted turns, rewinds model context to that point while preserving earlier
  Action Cards and already committed Pod Page, Base, and Applet writes, and
  regenerates from the updated message.

## Version 2.0.0-alpha.94 (2026-11-08)

- Keep an Agent's live work steps open while it thinks between steps. The step
  list used to fold away each time one step finished and the next had not yet
  started, then reopen with everything the reader had expanded closed again. It
  now stays where the reader left it, and the reasoning between steps sits in a
  collapsed Thinking row inside it.
- Stop the Chat sidebar from jumping when it opens. Switching from Home to Chat
  showed loading bars above the first rows and then pulled the whole list up
  once it loaded. Chat now shows only the loading bars until the list is ready,
  and keeps the list for the rest of the page session, so later switches show
  it at once.
- Switch tabs without a one-frame jump. A closing tab panel stayed in the layout
  for one frame and pushed the opening panel down, which made the Chat list
  twitch upward on every switch. The closing panel now leaves at once.

## Version 2.0.0-alpha.93 (2026-11-08)

- Internal changes only.

## Version 2.0.0-alpha.92 (2026-11-08)

- Fit an Applet embedded in a document to its content. The embed no longer
  takes a whole screen with blank space under a short Applet, and no longer
  scrolls on its own inside the document: it takes the Applet's height, up to
  one screen, and scrolls with the document. An Applet laid out to fill the
  screen keeps one screen, and a dialog, drawer, or sheet opened in the embed
  gets a whole screen while it is open.
- Let an Applet show its Page title. `usePod()` now gives the Page's current
  title and whether a document embeds the Applet, so an Applet can head its
  Page with the title, follow renames, and leave the title to the document when
  embedded. The Applet guidance and the starter project describe this layout.

## Version 2.0.0-alpha.91 (2026-11-08)

- Let an Applet fill its Page. An Applet Page no longer shows a large title and
  a source line above the Applet, and the Page no longer scrolls on top of the
  Applet's own scrolling, which used to cut the Applet's first lines off under
  the title. The Applet now starts right below the Page header, whose path
  shows the title, keeps the same margins as a document, and is the only thing
  that scrolls: scrolling anywhere in the Page body, including the margins
  beside it, moves the Applet, and its scrollbar sits at the edge of the Page.
  The link to the conversation that produced the Applet sits beside the title in
  the header, and the Page's ⋯ menu renames the Applet right in the header.

## Version 2.0.0-alpha.90 (2026-11-08)

- Explain Pod errors in plain language in English, Chinese, Japanese, and
  Korean. About 40 errors that used to appear as raw codes, such as
  `route_not_found`, `webhook_terminal`, `field_referenced`, and
  `applet_owner_unavailable`, now say what happened and what to do next. The
  connector, account, and Pod settings screens translate errors like the rest of
  the Pod, the account page explains a wrong or expired email verification
  code, and a busy Applet runtime reports that it is busy instead of "The
  request is invalid".
- Show only the error when a list fails to load. The Applet automation dialog
  and its run history, the chart record list, the Console principal audit, and
  the tenant's Transfer site administration form no longer show an empty-state
  hint under the error. An Applet published without a backend lists no Actions
  instead of failing with `route_not_found`.
- Follow a renamed member or Agent on the Brain metric revisions they approved.
  Renaming a Principal now updates each revision's approver, so it no longer
  names the old identity.

## Version 2.0.0-alpha.89 (2026-11-08)

- Fix Background Agent Jobs that failed within seconds of starting with
  `431 Request Header Fields Too Large`. A Job's Drive credential carried the
  Job's whole Skill selection, so a Job whose Agent had many Skills enabled
  could not mount `/drive`. The credential now names the Job, and its size no
  longer depends on how many Skills the Job uses.

## Version 2.0.0-alpha.88 (2026-11-08)

- Keep an Agent's work steps steady when it runs several steps at once. While
  the Agent works, its steps stay in one folded list instead of spreading out
  and folding back each time parallel steps start and finish, and the work
  header names every running step, such as "Searching code: “a” · Reading file:
  b.ts". A folded row of reads and searches shows a spinner while one of them
  runs and marks a failed read, instead of looking finished.

## Version 2.0.0-alpha.87 (2026-11-08)

- Show a page skeleton in the Console while a page's code or data takes longer
  than 300 ms to load, including pages that Plugins add. Opening or refreshing a
  slow Console page now shows the Console shell with the skeleton instead of a
  blank window, and a slow navigation no longer keeps the previous page on
  screen as if the click did nothing. A Plugin's Console route now declares a
  `load` function that imports its page, in place of a lazy `Component`.
- Find an Applet Page's full-screen command in the Page's ⋯ menu instead of as
  an unlabeled icon in the header. The comments button in a Page header now
  reads "Comments" next to its icon, like the assistant, learning, and
  automation buttons; a narrow header still shows only the icons.
- Keep an Agent's work steps open while the Agent is still working. Expanding
  them in chat no longer folds them back each time a new step arrives, and the
  working spinner sits on the same line as its status text again.
- Show what an Agent reads and searches without a wall of identical rows. In
  an Agent's work steps, consecutive file reads, code searches, and directory
  listings now fold into one row such as "Read 4 files · Searched 9 times",
  while edits, tests, and commits keep their own rows. A code or file search
  names what it looks for, such as `Searching code: “useActivityLabel”`, and
  shell commands like `cat`, `sed -n`, and `ls` read as file reads and listings
  instead of "Running command · cat". While the Agent works, each step shows
  the icon of its tool, such as a file, a search, or a terminal, instead of the
  same generic icon on every row.

## Version 2.0.0-alpha.86 (2026-11-08)

- Keep the chat composer's tools and send button on one row. The send button no
  longer drops to a line of its own in the Page chat panel or on a phone; when
  the row is too narrow, the recipient and model menus shorten their names with
  an ellipsis. The recipient name and the model menu use the same text size as
  the other composer controls.
- Open the Meta Ankole Skills page faster. The Skill list now checks the
  caller's edit, delete, and binding permissions once per Skill source instead
  of once per Skill, and the page shows a loading skeleton until the list
  arrives.
- Read the shipped Agent Plugins and Skill packages from disk once per
  control-plane process instead of every 30 seconds, so opening the Meta Ankole
  Skills page or starting a Turn no longer waits for the library to be reread.
  Operators who edit the directories under `ANKOLE_LIBRARY_ROOT` or
  `ANKOLE_INTERNAL_SKILLS_ROOT` in a running deployment must restart the control
  plane to apply the edits.

## Version 2.0.0-alpha.85 (2026-11-08)

- Tell Applet authors in the `pod-content` Skill that a GET route can call only
  MCP tools whose server declares `readOnlyHint: true`, and that any other tool
  belongs in a POST route or an Action. Agents previously learned this rule only
  from the `read_only_route` error after publishing.

## Version 2.0.0-alpha.84 (2026-11-08)

- Connect PostgreSQL, MySQL, MariaDB, and ClickHouse databases as read-only
  Pod connections. Agents and Applets can search the cached catalog, describe a
  table, probe values, explain and run one read-only `SELECT` or `WITH` query,
  and run published metrics. Ankole keeps the database password in the
  connection, rejects writes, multi-statement batches, and built-in functions
  with side effects such as `pg_notify`, runs every query in a read-only
  session with the timeout, row, byte, and scan limits in
  `connectors.database.limits`, checks the resolved address against the SSRF
  policy, and saves large results as Pod files. When the database fails
  partway through an export, the query returns the database's error and saves
  no file. Every engine, ClickHouse included, accepts an administrator's CA
  certificate in the verify TLS mode, checks the configured host name or IP
  address, and names the failed check when verification fails. Large integers
  and decimals stay exact, ClickHouse results return NULLs, arrays, and maps as
  JSON values, and ClickHouse sorting keys keep whole expressions such as
  `toDate(ts)`. Sample values stay hidden for
  sensitive columns, including columns an administrator excludes later, and
  value probes require a cached catalog. When a database has more tables than
  the catalog table limit, the connection card and the `search_catalog`
  result say that only the first tables are cached. Administrators choose
  whether all members and AI colleagues or only selected groups and Agents
  can query a connection.
- Write a description on Base tables and fields. Agents, the Worker CLI,
  `base.schema`, the Drive `.info/schema.json` file, and the Pod API return it,
  and Agents now record units, currency, and tax handling when they create a
  table or field.
- Group, filter, and measure Base aggregates through link fields in the same
  Base: group by a field of a linked record, keep records that have or lack
  matching linked records, and total a child table per parent without
  counting the parent once per child. Aggregate results list the data version
  of every table they read, and Applet aggregates refresh when any of those
  tables changes.
- Define datasets and metrics in Brain. Every workspace has `datasets/` and
  `metrics/` categories; saving a metric validates its definition and
  publishes a numbered revision that dashboards and Agents can pin. Agents run
  a metric with the `brain` tool's `metric_query` operation, also inside codex
  Background Jobs, Applets with
  `AnkoleRuntime.metrics.query`, and database connections with their own
  `metric_query` tool. A metric whose field, link, column, or table disappears
  is marked for review instead of returning a number from a different column;
  a catalog refresh that stops at the table limit does not count unlisted
  tables as removed. Brain objects can declare `identifiers` that link an
  entity to its rows in a Base or database.
- Agents answer business-number questions with the new `business-metrics`
  Skill: they use a published metric when one matches, state the temporary
  basis for a simple count, ask one choice question before they define an
  ambiguous financial metric, and say which data is missing instead of
  substituting a similar column.
- Upgrade a site from a release older than 2026-11-03 without the migration
  stopping on a missing table or column: the upgrade now creates the Brain
  root, categories, and Agent pages after the last schema migration.
- Clicking a chat's participant avatars opens a list of everyone in the
  conversation. In an assistant task or colleague DM they no longer open the
  summary panel, so only the summary button shows it as open.
- An Applet Page header has a full-screen button, shown in browsers that allow
  full screen. It fills the screen with the Applet alone, keeping what the user
  had open in it, and Esc returns to the Pod.
- Keep Pod Page search fast after someone saves a very long Chinese, Japanese,
  Thai, Lao, Khmer, or Myanmar text with no punctuation. Such a Page could make
  every search on the site run for minutes at full CPU, and canceling the
  search did not stop it. Ankole now tokenizes each Page once when it is saved,
  and searches no longer slow down as recently saved Pages grow.

## Version 2.0.0-alpha.83 (2026-11-08)

- Use one spinner across the Pod, the console, setup, and Applets: an arc
  that turns while it grows and shrinks, in the progress color where content
  loads and in the button's own color inside a busy button. Applets get it
  through the UIKit `Spinner` without republishing, and the Applet guidance
  now asks for skeletons shaped like the coming view instead of plain loading
  text.

## Version 2.0.0-alpha.82 (2026-11-08)

- Read Office and spreadsheet files with version 9.4.2 of the `zip` library,
  which fixes GHSA-m665-v7pm-7grj, GHSA-q7v9-x93c-xqv3, and
  GHSA-8hxf-qr8p-62x4. Ankole reads these archives in memory and does not
  use the affected extraction or AES paths.

## Version 2.0.0-alpha.81 (2026-11-08)

- Show every Pod loading state in the shape of what is loading. Pages, lists,
  tables, spreadsheets, version history, comments, and connections show gray
  placeholders of their content; applets, file and slide previews, and chat
  history show a centered spinner; pickers, menus, and fields show a small
  spinner beside their text. Every state waits a moment before it appears, so
  quick loads no longer flash plain "Loading…" text.

## Version 2.0.0-alpha.80 (2026-11-08)

- Keep the sidebar on Home when you start a New Chat from there, with the
  button or Command/Control+Shift+O, so your Page tree stays in view after you
  send the first message.

## Version 2.0.0-alpha.79 (2026-11-08)

- Send an open Pod straight to the sign-in page when its session expires, and
  return to the same page afterwards, instead of filling the sidebar with a
  "session expired" error and a Retry button in every section.

## Version 2.0.0-alpha.78 (2026-11-08)

- Name the sign-in method in the account menu, the sign-in account chooser,
  and the sign-out screen after the platform the identity provider uses, such
  as 飞书 / Feishu or Lark, instead of a label derived from the provider ID
  such as "Lark main". Accounts keep that name after an administrator
  disables their provider.
- Show one loading indicator while switching Pod pages: a centered spinner
  with a pulsing label, matching the Assistant's thinking indicator, replaces
  the plain loading text. It appears only when a load takes longer than a
  moment, so quick switches no longer flash, and opening a table or an applet
  no longer shows a second loading message for its code.
- Slide the Page chat, Comments, and conversation summary panels in and out
  like a drawer: the Page or conversation widens and narrows with the panel
  instead of jumping by the panel's width on the click. Opening a panel also
  no longer shifts the whole Pod, sidebar included, to the left.
- Keep every sidebar section heading the same height, so Spaces and Private
  pages line up with Recent and the Chat sections, and style the Chat sidebar
  correctly when you switch to it before opening any conversation.

## Version 2.0.0-alpha.77 (2026-11-08)

- Start new Applets from `ankole-pod applet init` flush with the Pod Page: the
  starter shows a toolbar and an empty state instead of wrapping the whole
  Applet in a card.

## Version 2.0.0-alpha.76 (2026-11-08)

- Show a spinning progress indicator centered in an applet while it loads,
  matching the Assistant's thinking indicator, instead of a single line of
  gray text in the top-left corner.
- Keep the knowledge graph steady when you move the pointer from one node to
  another: the spotlight moves straight to the next node instead of flashing
  the whole graph back to full brightness while the pointer crosses the gap or
  passes from a node to its label.
- Close the Page chat, Comments, and conversation summary panels smoothly: the
  Page or conversation widens as soon as you click, and the panel fades out on
  top instead of holding its space and then snapping away.
- Expand or collapse Chat sidebar sections such as Personal assistant by
  clicking anywhere on the section heading, not only its chevron.
- Name Feishu and Lark by the platform each configuration uses: login buttons,
  identity-provider lists, and connector cards show 飞书 or Feishu for a
  mainland China app and Lark for a global app, while the plugin and adapter
  read 飞书 / Lark (Feishu / Lark in other languages). Every platform select
  offers Feishu (Mainland China) and Lark (Global), the connector catalog shows
  localized names, and event sources and large-file notices no longer name the
  wrong platform.

## Version 2.0.0-alpha.75 (2026-11-08)

- Include explicit `WITH (key_field=...)` clauses when creating or rebuilding
  `pg_search` BM25 indexes in `AddPodPageFullTextSearch` and
  `Ankole.SearchIndexes` so migrations and index self-healing succeed on
  PostgreSQL servers running `pg_search` `0.25.x`.

## Version 2.0.0-alpha.74 (2026-11-08)

- Preserve live remote adapter connection owners in
  `Ankole.Plugins.ConnectionLifecycle` when peer reconciliation hits transient
  RPC timeouts on a still-connected BEAM node, keeping `:global` ownership
  intact instead of starting duplicate connections.
- Fix `"directory already mounted"` Drive FUSE failures on reused Agent Computer
  Workers: serialize mount adoption, idle retirement, and orphan reclamation per
  mount slot in `DriveMounts`, reconcile uncertain `rclone rc` mount and unmount
  outcomes against `mount/listmounts` before leasing or remounting, sweep stale
  `/run/ankole-drives` FUSE mounts and `/run/ankole/rclone.sock` on daemon
  startup and shutdown, and clean up residual `root` `unshare`/`ankole-rclone`
  helpers and FUSE mounts in `ankole-worker-supervisor` after abnormal Worker
  exits.

## Version 2.0.0-alpha.73 (2026-11-07)

- Support zero-downtime multi-replica control-plane deployments across
  Distributed Erlang: add `AnkoleWeb.EndpointDrain` HTTP readiness
  (`/_internal/health`, flipping to `503` and draining for
  `ANKOLE_SHUTDOWN_DRAIN_MS` on `SIGTERM` before Bandit stops) and liveness
  (`/_internal/live`) endpoints, start `DNSCluster` before Oban and Plugin
  supervisors, coordinate cluster-wide single-owner adapter connections with
  immediate drain handover and crash failover in
  `Ankole.Plugins.ConnectionLifecycle`, resolve live WeCom bot WebSockets across
  replicas for outbound delivery, and render `RollingUpdate`, HTTP health
  probes, hostname anti-affinity, and `PodDisruptionBudget` resources in the
  `ankole-agent` Helm chart when running shared remote file storage.
- Upgrade Pod Page search (`⌘K`, `/content/search`, and `ankole-pod pages.search`)
  to unified BM25 + substring full-text search across Pages, Brain knowledge,
  Base schemas, Spreadsheets, and extracted File Pages (`.docx`, `.pptx`,
  `.odt`, `.ods`, `.pdf`, Markdown, CSV/TSV, and text/code files), with
  activity- and recency-weighted ranking, recent search history, subtree and
  title-only filters, desktop command-menu Page previews, highlighted result
  snippets, target locators (headings, Base tables/fields, spreadsheet cells,
  PDF pages, and slide decks), and an in-page Find bar across Pod workspaces.
- Rejoin `RuntimeFabric` Worker channels immediately on `stale_transport_route`
  replies and re-run queued `start` and `observe` passes in `Ankole.Sessions.JobDriver`
  when a Codex Job Worker transiently disconnects or changes incarnation.

## Version 2.0.0-alpha.72 (2026-11-06)

- Introduce the Mineral Ink and Ceramic Glaze visualization palette and
  channel-encoding rules across `@ankole/uikit`, Base chart views, Document
  chart blocks, Knowledge Mermaid diagrams, and `ankole-viz`: pair warm matte
  mineral pigments in light mode with luminous ceramic glazes in dark mode,
  keep single-series bar and column charts in uniform Cobalt while reserving
  neutral grays for `"Other"` and `"Empty"` buckets, separate continuous
  sequential and zero-anchored diverging heatmap ramps, anchor waterfall totals
  with `--chart-total`, choose readable light or dark ink for inside data
  labels, and clear prior G2 view state before switching chart types on a live
  canvas.

## Version 2.0.0-alpha.71 (2026-11-06)

- Preserve G2's built-in category legend, axis, label, and tooltip theme defaults
  when applying Ankole visualization tokens, serialize async chart mount, resize,
  and spec updates behind a single container lifecycle, pass explicit axis titles
  instead of internal field keys, and pass root-array hierarchy nodes to sunburst
  partitions so pie, donut, funnel, multi-series, and sunburst charts render
  reliably across light and dark themes.

## Version 2.0.0-alpha.70 (2026-11-06)

- Keep standalone Applet `@ankole/uikit` stylesheets out of host browser pages,
  load entry stylesheets after their imported base styles, and avoid circular
  vendor chunk splits in production frontend builds, restoring the multi-column
  SaaS landing layout and preventing startup module-order errors.
- Complete keyboard focus loops across document resource blocks, whole-block
  selections, and Page titles: inserting or editing an external `embed`,
  `media`, or `bookmark` block focuses its address field, ignores IME
  composition `Enter`/`Escape` events, cancels cleanly on `Escape`, reopens via
  `Space` or `⌘Enter` on a selected block, selects the card when clicking its
  frame, and returns focus to the editor after saving; `Shift+Enter` inserts a
  paragraph above a whole-block selection; and pressing `Enter` or last-line
  `ArrowDown` in a Spreadsheet or Base Page title moves focus into the active
  cell or Base grid.

## Version 2.0.0-alpha.69 (2026-11-06)

- Add unified data visualization across Bases, Documents, Knowledge pages,
  Applets, Pod Chat, and Agents: create native `chart` views on Base tables
  (column, bar, line, area, pie, donut, scatter, combo, funnel, and KPI stat
  cards with Top-N + `"Other"` folding, cumulative and percentage modes, target
  reference lines, period-over-period KPI deltas, record drill-down, auto-save,
  and PNG/SVG export), embed linked or inline Base charts in Documents via
  `/chart`, author collaborative `<infographic>` blocks in Documents and
  `<mermaid>` diagrams in Knowledge pages, build financial charts (`candlestick`,
  `area`, `histogram`, `yield-curve`) and graphs with `@ankole/uikit` in
  Applets, and generate print-safe SVG or PNG visuals from Agents via
  `ankole-viz` and the built-in `visualization` Skill.
- Rank chart categories without counting multi-value memberships twice, keep
  cumulative amounts and donut totals exact, and show KPI loading and errors
  until the total is available. Infographics recover when authors correct
  invalid source.
- Keep browser sign-ins alive while they are in use: each sign-in stays valid
  for 30 days after the browser last used it, up to 180 days after login,
  instead of expiring 24 hours after login. Browsers signed in before this
  release sign in once more to receive the longer lifetime.

## Version 2.0.0-alpha.68 (2026-11-05)

- Show a Page mention's location with its root only once: the path starts with
  the Space name or Private and no longer repeats the root's internal `Space` or
  `Private` title.
- Close only the attachment preview when `Escape` arrives right after it opens;
  the conversation summary and the execution inspector stay open.
- Label the Page header's **Learn business facts** button **Learn** while
  learning is off, beside the other labelled header buttons; a narrow header
  still shows only its icon, and **Learning** marks an enabled Page as before.
- Show who is in an assistant task or colleague DM when its participant avatars
  are clicked: they open the summary panel's member list instead of the
  **Start a group** dialog, which stays on its own button.
- Open the Console's Signals, new Signal, Signal detail, and Webhooks pages
  directly on the dedicated SaaS Console host. Only inbound CloudEvents under
  `/signals/v1/` and provider webhooks below `/webhooks/<segment>` stay with
  their endpoints, so these pages no longer return 404 on a direct link or
  reload.

## Version 2.0.0-alpha.67 (2026-11-05)

- Label Pages in a Private space as Private again. Page responses and mention
  candidates report the owner of each Page's Private root, so Recent and
  Favorites show the Private badge, mention paths start at Private instead of
  the Space name, and trashing a top-level Private Page returns to the Private
  list.
- Keep a file Page's extension when its title changes, so renaming
  `Budget.xlsx` to `Budget 2027` still opens a spreadsheet and downloads
  `Budget 2027.xlsx`.
- Bring three Pod browser stories back in line with the current contracts: a
  replaced file Page takes the uploaded file's name as its title, an empty
  Document shows the subpages directory while a Document with text and no
  children hides it, and unpositioned siblings sort by name.

## Version 2.0.0-alpha.66 (2026-11-05)

- Center text from the bundled IBM Plex Sans CN font on the same line as the
  icons and avatars beside it. Button labels such as **Saved**, **Assistant**,
  and **Share**, and the online count next to collaborator avatars, previously
  sat about 2px above the icon center because the font's raised descent was not
  matched by its ascent.

## Version 2.0.0-alpha.65 (2026-11-05)

- Move **Learn business facts** from the Page more-actions menu to the Page
  header for Page managers. The header shows a brain icon while learning is off
  and a **Learning** label once the Page or an ancestor enables it; its popover
  holds the switch and explains that extracted facts stay visible only to
  members and Agents who can read the Page. Pod hides the control while Brain is
  disabled.
- Move an Applet's **Automation** button into the Page header, so the Applet
  starts right below its title instead of under a row holding only that button.

## Version 2.0.0-alpha.64 (2026-11-05)

- Stop a room's Background Agent Job or Workflow only when the Human may command
  its Agent, as the room execution API documents; room members without `chat` on
  that Agent are refused.
- Give Pod chat reply suggestions and generated room titles enough output budget
  for a reasoning `light` model to answer after it reasons, so both keep
  appearing after the first turn.
- Load the next page of the Pod chat execution inspector when **Load more** is
  clicked during a room update, and show steer messages with only the text the
  Human sent, without the Background Agent Job's hidden instructions or original
  request.
- Label each Page picker target, including the move-page dialog, as Space,
  Private, or Shared with me from its readable root; Page search returns the
  readable root among each result's ancestors.
- Keep other Base embeds on a Page visible after an embed that cannot be
  displayed is removed.
- Reach every painted spreadsheet control from the keyboard: Shift+F10 or the
  context-menu key opens the cell, row, column, and picture menus;
  Shift+Space and Ctrl+Space select rows and columns; Alt+Down opens filter and
  validation lists; the cell menu adds a **Fill** submenu; Enter applies a held
  format painter; and Ctrl+Alt+P selects floating pictures, which arrow keys move
  and Delete removes.
- Show the active spreadsheet cell's value, formula, and formatting as soon as a
  spreadsheet opens, replace the previous fill when the fill option changes so
  **Formatting only** keeps the original values, name colour swatches with
  translated colour names, and announce presence avatars by full name.
- Make the Meta Ankole Brain graph's node links follow the nodes after search
  filtering, zoom, fit view, and layout changes, keep the hidden graph canvas out
  of the Tab order, and keep toolbar button names on narrow screens.
- Announce navigation entries styled as buttons as links, name each Agent card in
  Pod Settings and its Disable, Enable, and Rename UID buttons after the Agent,
  name each Console model usage table after its heading, and translate the
  accessible names of file preview line numbers.
- Label the Feishu connection dialog's service-network select **Domain**, so it
  no longer shares the **Platform** name with the platform picker.
- Keep a Pod chat message's Copy, Quote, and Edit buttons clickable when the
  same author's next message follows directly below it.
- Open an Agent's private root when the Console Drive is opened from that
  Agent's files link, so uploading and creating folders work right away; the
  Drive listing API resolves `owner_uid` without `relative_path` to that root.
- Validate Console Drive file and folder names in the browser again; the name
  fields' slash rule is now a valid pattern for current browsers.
- Move **Learn business facts** into the Page header's more-actions menu for
  Page managers, so a document title continues straight into its body.
- Number a file that collides with an existing name before its extension, so a
  second `report.xlsx` becomes `report (1).xlsx` and still opens and previews as
  a spreadsheet.
- Show **Private page** as the access scope, and the Space instead of
  **Inherit from parent page**, for a Page directly under its Private or Space
  root in the share dialog; Page sharing reads return `has_parent`.
- Expand only the active Page's own sidebar section on reload, so opening a
  Private Page leaves a folded Space folded.

## Version 2.0.0-alpha.63 (2026-11-05)

- Remove the **Save as page** action on Pod chat messages and multi-message
  excerpts so chat transcripts are not saved directly as Pages; Agents create and
  edit Pages through Pod tools, while file attachments still offer **Save file to
  Pod**.
- Replace the elapsed-time stopwatch on Pod chat turn work summaries with an
  indeterminate loading spinner while an Agent is working and untimed step/status
  labels once settled.
- Generate concise sidebar titles for personal-assistant and group chat rooms
  asynchronously with the Agent's `light` model profile when the opening turn
  starts, replacing the 40-character first-line fallback once ready unless the
  room was manually renamed.
- Render Pod chat reply suggestions inline inside the empty composer as ghost
  placeholder text with a trailing `⇥ Tab` keycap (pressed via `Tab` or clicked
  to fill the draft) instead of a floating button above the composer, and
  suppress suggestions while any Agent turn, queued input, pending question,
  confirmation card, Background Agent Job, Workflow, or delegated colleague task
  is still active in the room.
- Grant active Pod members (`all_humans`) default `chat` permission on newly
  created AI colleagues, backfill existing ungranted AI colleagues on upgrade,
  and refresh the Pod Chat colleague directory when administrators enable,
  disable, or rename an Agent in Pod Settings, so configured AI colleagues appear
  in the Chat sidebar and remain callable via DMs, `@` mentions, and Personal
  Assistant delegation out of the box.
- Visualize Brain Pages, Bases, Applets, Skills, and Agents in an interactive
  knowledge graph under **Meta Ankole → Brain** with force, hierarchy, cluster,
  and radial layouts, ontology layer and category filters, search, a node
  relationship inspector, and accessible object links.
- Inspect room-linked Background Agent Jobs, Workflows, and delegated AI
  colleague exchanges in a Pod chat side panel (or mobile sheet) with paginated
  execution logs, final outcomes, live stop actions, and follow-up messages that
  steer running Background Agent Jobs or continue settled jobs in the same
  workspace.
- Gate per-field secret reveals on Site Console AI Gateway providers behind the
  `decrypt` permission on `site_console:ai_gateway_provider:{provider_id}`, so
  authorized administrators can reveal masked API keys, OAuth client secrets,
  and credential-pool tokens on demand.
- Synchronize the active Pod light or dark theme into Applet iframes and expose
  reactive `usePod().theme` (`'light' | 'dark'`) in `@ankole/applet-sdk`, while
  preloading Applet vendor ESM modules and serving `304 Not Modified` for
  unchanged Applet `index.html` shells without re-reading stored object bytes.

## Version 2.0.0-alpha.62 (2026-11-05)

- Accept an Agent's tool call that fills an optional setting with an empty
  value, such as a background job without a workspace template, instead of
  rejecting it and making the Agent try again.
- Mark a reply's work as failed only when its turn failed. When an Agent
  recovers from a failed step, the work summary shows how long it worked and
  how many steps failed, so people can still report the error, and it no
  longer counts tool calls.
- Name each step of a reply's work in the reader's language, with the same
  label that people saw while the step ran, and leave out the retry hint that
  a failed step returns to the Agent.

## Version 2.0.0-alpha.61 (2026-11-05)

- Show which model served each Agent reply and how many tokens it used in the
  reply's work history. Usage that a provider did not report appears as not
  reported instead of zero, and a turn that only some rounds reported shows
  how many rounds are missing.
- Record each AI call's token usage together with the Human it served, and
  give site administrators a Console usage page with totals by Agent, Human,
  and origin and the share of rounds that reported usage. Rounds without
  reported usage do not count toward an Agent's token quota.
- Keep an Agent's model usage after the Agent is deleted, so the Console still
  shows it. A new Agent that reuses the name starts its token quota without
  that usage.
- Let Agents ask a structured question with up to five typed fields: text,
  number, date, single or multiple choice, and yes or no. Ankole checks every
  answer before it reaches the Agent and keeps the question open after an
  invalid answer. Feishu/Lark and Teams show the form in the card, and other
  chat channels link to the same form in Pod.
- Replace an Agent's older unanswered question when it asks a new one in the
  same conversation.
- Update Microsoft Teams cards in place: an answered question or a decided
  approval card shows its outcome instead of keeping its form or buttons, and a
  reply shows its status until its first words arrive.
- Start an Agent's Turns sooner. Turns that start together in a tenant whose
  shipped Skills are not yet installed install them once instead of each
  repeating the work, the installation uploads files in parallel, and each Turn
  reads its Skill catalog with about one-eighth of the earlier database queries.

## Version 2.0.0-alpha.60 (2026-11-05)

- Open Console `/model-profiles` on Site defaults across Pods with a dedicated Pod
  defaults tab for tenant overrides and system Principal profiles, and link the
  readiness model step to `/model-profiles?defaults_scope=tenant` when a Pod has
  no Agent yet.

## Version 2.0.0-alpha.59 (2026-11-05)

- Seed built-in Global and Personal Assistant contracts from compiled control-plane
  templates and serve `/drive/Skills` directly from PostgreSQL, so Personal
  Assistant creation and messaging work on packaged control-plane images without a
  source checkout on disk.
- Query authorized Feishu Contact scopes before enumerating departments and accept
  omitted empty list fields in Feishu Contact v3 responses, so directory sync
  succeeds when a Feishu app is granted specific departments instead of the root
  department.
- Validate `/pod/socket` WebSocket `Origin` headers against configured site and
  tenant origins so browser Pod channels connect cleanly behind TLS-terminating
  reverse proxies.

## Version 2.0.0-alpha.58 (2026-11-05)

- Connect Pod workspaces, Agents, and Applets to managed cloud OAuth accounts and
  custom credentials across eleven new built-in connector plugins (`calendly`,
  `figma`, `gitlab`, `google_analytics`, `googlecalendar`, `salesforce`,
  `sentry`, `stripe`, `trello`, `typeform`, and `zendesk`), with native webhook
  and Composio trigger reconciliation.
- Serve the Site Admin Console from a dedicated `site-admin-console` origin when
  the active host policy defines one, and route Worker Drive DAV requests before
  browser host classification on SaaS control-plane pods.
- Allow fresh-install database migrations to run under a non-superuser role when
  `pg_search` and `vector` are pre-installed by the database administrator.
- Reuse an index for cached Page lookups and preserve unchanged Base record
  arrays, reducing repeated work in navigation and long tables.
- Match Base grid row estimates to ordinary cell heights, reducing offset
  recalculations as users scroll long tables.
- Rebuild the cached page index on its first read after cache writes, so a
  batch of Page updates shares one rebuild and observer changes do not rescan it.
- Resolve heading fold sections in one pass, so opening or editing a long
  document does not rescan earlier blocks for every heading.
- Build editor documents directly from source parsed inside the editor, while
  normalizing caller-supplied page trees on every import.
- Leave a record card's details dialog unmounted until it is opened, so a long
  gallery or board does not build a dialog for every loaded record.

## Version 2.0.0-alpha.57 (2026-11-04)

- Show file edits in a turn's work history as per-file changes with added and
  removed line counts, and keep the end of long tool output, where failing tests
  and command summaries appear. Expanding a command shows the end of its output
  first.
- Wait for loading `@` suggestions when Enter is pressed instead of sending the
  half-typed mention, and play audio and video chat attachments inside their
  preview dialog.
- Open tooltips after a short hover delay so that moving the pointer across a
  toolbar no longer flashes every hint; keyboard focus still shows them at once.
- Show why a chat matched in global search with an excerpt of the matching
  message, and open the room at that message with in-room search filled in.
- Open a room at the first unread message from others under a New messages
  divider, so returning to a busy group shows where to start reading.
- Take the page-tree lock before storing chat attachments and generated images
  as conversation or private files, so these writes follow the same lock order
  as other page-tree changes.
- Offer 4 to 7 concrete next steps from your personal assistant on the chat
  home, including at most one ambitious 10x step, drawn from your recent
  conversations, pages, and Brain knowledge. Choosing a step fills the composer
  for you to edit and send; Show others writes a new menu, and steps you pass
  over in two menus are not offered again.
- Suggest one next message above the composer after an Agent replies in a
  conversation where you are the only person. Choosing it only fills your
  draft, and the suggestion stops for the visit after you pass over three in a
  row.
- Close a Page's discussion room as soon as the Page moves to Trash, so people
  who could see the Page can no longer read or post in its room.
- Release the Worker workspace when a recovered turn finishes after Ankole
  replaced its Session Driver, instead of holding the slot until idle expiry.
- Finish aborted and stalled background job attempts without an error after
  they commit, and wake the owning conversation with the resulting failure.
- Keep the AI reply to an edited, supplemented, or retried external chat
  message attached to the original request.
- Reread the Pod pages and files a resumed conversation worked with when Ankole
  builds its wake briefing.
- Remove the retired RuntimeFabric worker key from site configuration during
  upgrade, so configuration reads and E2E cleanup no longer fail on it.
- Stop Lark, Slack, DingTalk, Discord, Email, and Telegram long connections
  together with their connection registry, so a plugin restart cannot leave
  duplicate connections.
- Count Applet Worker startup, including top-level await, toward call admission,
  so an Action whose deadline expires during startup is retried instead of
  failing with an unknown outcome.
- Stop the bundled PostgreSQL image with a fast shutdown, so stopping or
  recreating it no longer waits for connected clients until the server is
  killed and must recover on its next start.

## Version 2.0.0-alpha.56 (2026-11-04)

- Create and edit spreadsheets in Pod. The page create menus offer a new
  **Spreadsheet**, which starts as a blank `Untitled.xlsx`, and every `.xlsx` or
  `.xlsm` file page opens in an online editor: type values and formulas,
  format cells (fonts, colors, alignment, wrapping, number formats, borders,
  merges, and notes), insert, delete, hide, and resize rows and columns, freeze
  panes, sort, and add, rename, reorder, color, or delete sheets. Several
  people can edit the same workbook at once and see each other's selections;
  Ankole moves an edit that crosses another person's row or column change to
  the right cells and formulas, and asks you to redo an edit it cannot place.
  Undo and redo cover your own values, formats, and merges. Editors can restore earlier
  versions from the page history, downloads always return the latest edits,
  Agents see them in their Drive shortly after editing pauses, and search finds
  text inside spreadsheet cells.
  Workbooks larger than the editing limit (20 MiB by default) offer the
  download only, and `.xls`, `.xlsb`, `.ods`, `.csv`, and `.tsv` files keep
  their read-only previews. Operators can tune the editable file size and
  compaction with `pod.spreadsheet.limits`.
- Spreadsheets gain the data tools. The **Data** menu filters the selection or
  the block of data around the active cell, and the header buttons list each
  column's values to show or hide; data validation restricts what cells accept,
  cells with a list rule offer a dropdown, and input that breaks a rule is
  rejected or flagged with the rule's message; a range can be formatted as a
  table and converted back; and find and replace (Ctrl+F, Ctrl+H) search the
  sheet or the workbook. The grid now paints the charts of a sheet from the
  values they refer to, table styles, conditional formatting (fills, fonts,
  data bars, colour scales, and icon sets) from the file, and a mark on cells
  with notes, and the note popover shows the current note.
- Spreadsheets gain the everyday editing tools of desktop spreadsheet apps.
  Typing `=` suggests functions and shows their arguments, the **Formulas**
  menu inserts a sum, average, count, maximum, or minimum of the numbers above
  or picks from a searchable list of every function, clicking or dragging over
  cells while typing a formula inserts their reference (other sheets included),
  F4 switches a reference between relative and absolute, and the status bar
  sums, averages, and counts the selection. The freeze menu freezes the first
  row or column, or everything up to the selected row, column, or cell. The fill
  handle continues numbers, dates, numbered text, and weekday or month names,
  double-clicking it fills down beside the neighbouring data, and Ctrl+D and
  Ctrl+R copy down and right. Copied cells keep their formulas and formats
  between Ankole spreadsheets, cut and paste moves them, and paste special
  pastes values, formulas, or formats only. The context menu inserts and
  deletes rows, columns, or cells in a chosen direction and clears contents,
  formats, or both, and the toolbar adds the format painter, strikethrough, and
  clear formats. Pictures float over the cells or sit inside one; you can
  insert, paste, or drop them, move and resize them, switch them between the two
  kinds, view them full size, and download them, and they stay in the
  downloaded `.xlsx`. Rows without a height set by hand grow with larger fonts
  and wrapped text, and shrink back when they go.

## Version 2.0.0-alpha.55 (2026-11-04)

- Let AI colleagues read and manage their own business pages, files, Bases and
  Applets across tools and Drive; Brain knowledge still follows the conversation
  audience's shared permissions.
- Keep Action logs across continuation slices and failures, publish background
  job wakeups when their changes commit, and retry dispatch preparation when its
  schedule or target changes concurrently.
- Keep ordinary text conversations responsive during unrelated page-tree writes.
  Restore clarification and Action Cards from their recorded interaction data.
- Find writable move destinations beyond read-only search matches, and show
  private and shared page locations correctly in destination pickers.
- Publish Applet builds directly from Worker files, preserve document rich blocks
  and comment anchors in CLI Markdown edits, and reuse mounted Skills for
  background jobs.

## Version 2.0.0-alpha.54 (2026-11-04)

- Preserve Chinese IME confirmation in comment mentions, compare knowledge-page
  metadata by value, and keep formula arrays and dates consistent across Base
  queries and grouping controls.
- Keep browser material identity independent of JSON object key order, accept
  valid Skill filenames beginning with two dots, and use the shared path rules
  for Worker tools and MCP configuration.
- Keep XML attribute whitespace intact when importing Markdown links, and
  preserve newly typed search text while an earlier query updates the URL.
- Validate Connector OAuth return paths through the browser session contract,
  and keep file previews, downloads, copy feedback, and automation controls
  consistent across Pod and Console.
- Preserve seconds in automation run timestamps and Base date-time cells.

## Version 2.0.0-alpha.53 (2026-11-04)

- Use the supported read-only Brain operations in Workflow tasks, and terminate
  foreground command process groups when a conversation turn is stopped.
- Export current knowledge without an optional snapshot ID, return permission
  and missing-page errors from knowledge panels, and encode dated recall
  evidence before generating persistent synthesis pages.
- Preserve sidebar tab selection and focus while Agent availability loads.

- Preserve the native input node when IME composition replaces selected blocks
  without a preceding key event or receives compatible remote text edits, and
  clean up empty nested columns when composition ends. Keep that cleanup in the
  same undo step while earlier edits await confirmation or the first preedit
  arrives after structural preparation.
- Complete empty-list composition cleanup across remote edits, and preserve
  original list paragraphs when a later composition ends without input or
  editing resumes after a read-only completion. Moving the caret finishes cleanup
  at the original paragraph without changing another list, and ending a reverted
  preedit keeps its own undo step across remote edits.
- Keep the insertion caret and block attributes when cross-column composition
  starts in a heading or code block. Apply asynchronous embedded Base
  configuration updates after composition cleanup so undo preserves the
  committed candidate. Finish synchronous composition-end events outside
  drawing when switching an editor to read-only.
- Finish pending composition cleanup and resume drawing when an editor
  reconnects, preserving accepted text, remote edits, the insertion caret,
  and collaboration submissions.
- Save, synchronize, and generate Drive projections for documents at the
  supported nesting-depth limit.
- Return stable event subscription IDs and let Agent CLI callers read Jobs,
  Runs, and source subscriptions through their declared access checks.
  Apply Page disclosure checks to Job-scoped subscription lists and their sources.
- Reject model Provider removal while an enabled OIDC Client still uses it.
- Give Codex Jobs bounded web-page excerpts and complete workspace files, with
  working file reads, complete Unicode read windows and continuation hints,
  and repeated-fetch caching. Write page files as the Agent user and transfer
  rendered page bodies once so foreground results fit the Worker frame. Keep
  completed pages and continue the remaining URLs when another browser page
  cannot be created.

## Version 2.0.0-alpha.52 (2026-11-04)

- Recover rejected Connector tokens through the shared credential owner and
  retry safe operations once. Preserve Git authentication and require explicit
  retry for writes whose effects cannot safely be repeated.
- Keep remote MCP and event-subscription error details available for diagnosis.
  Let members repair a subscription and return to the same Applet Job, preserving
  their authorization and source-selection context.
- Add platform setup guidance to connection forms and load a Job's event
  subscriptions in one request.

## Version 2.0.0-alpha.51 (2026-11-04)

- Keep OfficeCLI on the release tested with the Worker image by disabling its
  background self-updates by default, preserving document screenshots when an
  upstream release omits required assemblies.
- Restore scheduled Applet replies to the originating messaging conversation.
- Add tenant-owned external connections with shared encrypted credentials for
  identity providers, messaging channels, Applets, and Agents. Members authorize
  personal accounts in Pod; administrators manage application credentials there.
  Expose Lark approvals, tasks, calendars and messaging, GitHub collaboration,
  and Linear through explicit MCP Toolkits and generated Skills and SDK types.
- Run Applet MCP calls through the Function Runtime host and shared control-plane
  gateway. Proxy remote Skill servers, keep external credentials on the control
  plane, and authenticate local Git through the active Turn.
- Let Applet Jobs own schedules and webhook endpoints, with pause, resume,
  delivery history, Page lifecycle, and personal-access revocation. Manage Jobs,
  native triggers, connector events and Run results from the Automation panel.
  Deterministic triggers run Actions without waking an Agent.
- **Breaking:** replace Agent-script Automation Jobs with published Applet Actions.
  Migration removes stored `agent_script` Jobs, their Runs, state and related
  event bindings and receipts. Export required scripts and configuration before
  upgrading, then recreate those automations as Applet Actions. Remove the Automation Job script CLI, `emitEvent()`, the
  Worker `lark-cli` and `gh` executables, and
  `automation_jobs.max_running_per_agent`; use Pod Job APIs and Connector Toolkits.
- Keep authorization locks compatible with concurrent chat and background Job
  writes, and handle database exceptions through the Session retry path.

## Version 2.0.0-alpha.50 (2026-11-03)

- Internal changes only.

## Version 2.0.0-alpha.49 (2026-11-03)

- Centralize 1.x Worker provider adoption and pending Automation script imports
  in dedicated upgrade modules; keep legacy fields out of runtime Job resources.
  Recover imported Jobs with the bounded Workspace rebuild when native thread
  files are missing, preserving queryable history and removing transcript replay.

- Recover knowledge bodies and property edits together after reloads, including
  invalid YAML, and preserve new input when an earlier save finishes. Display
  Page references inside business properties as links, report malformed knowledge
  panels, and keep graph and backlink titles in sync with confirmed Page updates.
- Fix nested transactions in Console promotion and merge reviews so review decisions commit and publish their changes.
- Remove unused Brain panel types and retired internal read/serialization helpers; use one Drive path contract for reads and writes.
- Read immutable Applet packages outside Page-lock transactions, batch Worker
  provider counts, and use deterministic tool-result journal keys. Remove unused
  VFS message handlers and coalesce the Worker's initial Drive refresh.
- Repair Skill lesson review and UUID-based memory retrieval, preserve forgetting
  provenance, and accept document search results without an entity subject.
  Publish scheduled, webhook, background Job and Workflow inputs immediately
  after commit. Recover Worker RPC credit on failed responses and report replay
  owner failures instead of leaving callers waiting.
- Correct Plugin restart dependencies, credential cache identities, binary
  attachment downloads, IMAP IDLE handling and fragmented HTTP body limits.
  Preserve reasoning spaces and completion labels, isolate WhatsApp webhook
  verification by matching credentials, reduce repeated cache and database work,
  and enforce tenant foreign keys on the Meta tables.

- Add published Applet Actions with caller and owner execution identities,
  persistent cursors, serial queues, coalescing and resumable slices. Route
  schedules, webhooks and Base changes through shared Signal Bindings and
  receipts, preserving historical deliveries. Add Base business-key upserts and
  suppress unchanged writes; provide streaming HTTP file transfers and isolate
  foreground and background Function Runtime capacity within the 2 GiB deployment budget.
  Let Applet frontends follow durable Run progress and recover the latest result
  after reconnecting through `useActionRun`. Retry Base deliveries independently
  by tenant and table, retain the event size limit on the production Run path,
  and reserve foreground capacity for PTC while honoring the total concurrency limit.
  Keep filtered Base deliveries in their correct concurrency groups and drain
  large change backlogs promptly. Wake queued Actions when a publication enables
  parallel execution, wait for busy runtimes, and distinguish completed function
  errors from interrupted attempts when deciding whether to retry.
  Allow tenant deletion to finish when an Agent owns published Applets.
  Fix Agent Applet publication lock order while keeping Action policies and
  files atomic and rejecting writes from completed runs.
  Preserve failed cron history when the final delivery attempt is rejected at admission.
  Hand off slices only after the current handler finishes, preserve event IDs and
  Human authorization on Applet emissions, and keep the original caller through
  owner-authorized child calls. Batch historical delivery migration and receipt
  cleanup, and reuse MCP tool discovery within each function invocation.

- Add Meta Ankole with a collapsed navigation tree, a Brain graph, editable Skill
  packages and per-Agent/global AGENTS and DESIGN contracts. Separate knowledge
  from collaboration roots and move Skills and contracts to independent tables
  with revision checks. Preserve positive Skill bindings under global enablement.
  Project Brain read-only by conversation disclosure and cache each Agent's
  read-only Skills and contracts across conversations; retain admitted Skill
  selection for background Jobs. Migrate existing packages, contracts and grants.
  Let members configure their assistant before starting a conversation, search
  Skills, import package metadata and edit attachments directly from the file
  list. Show effective Agent instructions and save feedback, with scrollable
  workspaces on desktop and narrow screens. Keep Worker
  connections alive during Page tree changes and use the internal Worker origin
  for Drive mounts.
  Persist Markdown supplied by Agent document creation so delivered links open
  the requested content.
  Isolate Skill drafts across package navigation and keep literal Agent UIDs
  separate from assistant and global settings routes. Read package directories
  without repeatedly scanning the capability catalog. Reject conflicting package
  file paths and preserve distinct legacy knowledge bodies and attachments during
  migration. Give each Agent list entry a separate, full-width click target.
  Correct Skill ZIP import tests to distinguish backend file limits from Drive VFS policy.
  Keep individual Skill bindings independent of package revisions and let editors
  reconcile conflicts without discarding drafts. Show separate global, colleague
  and assistant controls without creating an assistant during reads. Complete
  Brain favorites, moves, trash and semantic links, and derive object types from
  ontology categories. Handle archived legacy content, orphan contracts and slug
  collisions during migration. Refresh live contract files in long-running FUSE
  mounts and enforce admitted Job Skills across every runtime read path.
  Support interactive Workers without FUSE by materializing enabled Skill packages.
  Preserve installed package directories, manifest attachments, explicit enablement
  and inherited Agent defaults during direct upgrades. Remove the legacy Skill
  defaults setting, manage runnable packages in Meta Ankole, and grant members
  custom-Skill editing and deletion. Keep generated pattern pages inside Brain
  with their source's visibility, and load graph summaries without document bodies.
  Retire active lessons when deleting a Skill and complete Skill renames without
  reopening the discarded draft or requesting the old address.

- Restore Page as the source of truth for identity, content, subpages and access,
  and remove the folder Page type. Drive projects empty Pages as directories
  and populated Pages as body files with optional child directories. Preserve
  Page IDs, permissions, history and attachments during migration; clearing a
  body keeps its children. Require parent edit permission to create subpages.
  Use the Ankole logo for AnkoleBrain and a distinct book icon for knowledge Pages.
  Preserve empty Page subtrees during structured moves, allow editors to remove
  empty directories, and keep ordinary ChatDrive filenames writable. Delete
  Page-owned Actions in lock order when removing conversations or Agents.

- Hide unavailable Page actions across the canvas, sidebar, and child lists.
  System knowledge Pages display fixed titles and omit rename, move, reorder,
  and trash controls while keeping authorized content editing and child creation.

- Improve Brain memory selection so routine task completion, delivery and
  validation messages do not become facts or empty entity pages. Preserve
  substantive research conclusions, business outcomes and reusable knowledge
  when they appear alongside execution messages.

- Update the kernel's Rust dependencies to the latest releases that still build
  on Rust 1.91, including crc32fast 1.5.4. Update control-plane Elixir
  dependencies to llm_db 2026.11.0, Localize 1.6.1, attesto 2.10.0,
  attesto_client 2.13.0, and codepagex 0.3.0. The opaque Principal subject
  patch now applies to attesto 2.10.0.

- Fix native kernel stream completion and input boundaries: completed or failed
  AI streams no longer emit a later abort event, token truncation avoids excessive
  shortening across BPE merges, and OpenAI Chat records actual completion
  times. Provider numeric fields saturate instead of overflowing, JWT configs
  reject incorrectly typed fields, batch AuthZ rejects empty resources or actions,
  HTTP specs require HTTP(S), zero-capacity caches stay empty, and WebDAV requests
  are capped at 1 MiB and 128 XML levels.

## Version 2.0.0-alpha.48 (2026-11-03)

- Automation Job runs whose request never reached the Agent's Worker, because
  the Worker connection closed or was replaced just as the run was dispatched,
  now retry on the next attempt instead of being marked failed with an unknown
  outcome.

## Version 2.0.0-alpha.47 (2026-11-03)

- Use readable `<title-slug>-<short-id>` Pod Page URLs (transliterating
  non-ASCII titles to ASCII words and falling back to `/pages/<short-id>` when a
  Page has no title) alongside 26-character lowercase Crockford Base32 short IDs
  for Pages and Conversations. Bare short-ID links and links carrying an older
  title slug resolve to the Page and update the address bar to its current
  canonical path.

- Improve Brain extraction by reusing pages through titles and aliases and
  separating useful facts from entities worth creating. File new entities by
  their selected type. Reports keep their own content and permissions while
  their facts appear on related company pages for authorized readers.

- Mount authorized Drive content into Linux Workers so shell tools and Codex can
  read and write files, knowledge pages, documents, and Base records through
  normal paths. Share hot caches across matching conversations, isolate ChatDrive
  views, preserve rejected drafts, and flush explicit deliveries before sending.
  Merge separate knowledge edits, copy whole files within a mount without
  retransferring bytes, skip unchanged saves, and stream large uploads under a
  configurable site limit. Editor saves keep temporary files out of Trash; one
  restore recovers a deleted directory and its authorized contents.
  Let conversation members edit, rename, and delete shared ChatDrive files while
  sent attachments keep their captured contents.
  Cancel pending metadata refreshes with their caller and preserve local drafts
  when recovery metadata cannot be encoded. Report malformed upload metadata
  without replacing the cached file size with zero.
  Keep edits made during an upload pending across lost responses, and wait for
  their remote commit before reporting a successful delivery flush.
  Check the source revision during server-side copies so a growing source does
  not exceed the caller's requested byte count or replace the wrong contents.
  Add bounded Base exports and replay-safe imports, plus the Kubernetes FUSE
  device and admission configuration. Keep the file CLI fallback while the
  six-provider live acceptance gate remains open. Recognize Lambda managed-base
  minor revisions so ready Worker images do not enter a rebuild loop.
  Give cold FUSE client launches the mount manager's startup budget and report
  the failing probe stage when a Worker cannot mount Drive.
  Refresh Drive credentials after renewed Worker admission on thaw, so a stale
  socket cannot race the control plane's paused state.

- Show knowledge pages in a content-sized reader, with images, tables, code,
  Callouts, and live references. Empty bodies leave room for child pages and
  related knowledge. The editor loads when an author chooses Edit; saving or
  cancelling returns to the reading view.
- Unify business knowledge, Agent instructions, visual standards, and shared Skills
  in Pod's `/AnkoleBrain` tree. Knowledge pages support explicit atomic saves,
  editable properties, long-lived version history, and permission-filtered graph
  panels. Shared defaults and official Skill packages update when unmodified;
  local edits and team supplements stay intact. Agent reads follow the current
  requester and room permissions, and native approval cards let authorized owners
  confirm proposed knowledge edits without overwriting concurrent changes.
  Folder managers can enable fact learning directly in Pod, including existing
  material in subfolders, and stop queued extraction when they disable it.
  Entering or cancelling a knowledge edit preserves titles that are still saving.
  Main conversations can create and revise knowledge pages directly, with saved
  tool results that preserve later human edits when a call resumes.
  Repeated entity learning preserves existing documents. Brain lookups distinguish
  the shared namespace from matching paths in other spaces. Draft date properties
  save without database errors, leading dividers survive Markdown round trips,
  and execution cleanup removes temporary Skill packages.
- Keep knowledge summaries and introductions compact while preserving full-page
  reads and visible outlines. Brain budgets the complete recall response,
  including evidence sources. Editing page properties preserves unchanged
  retrieval vectors instead of making them wait for another embedding pass.
  Brain converts tool-result enums to JSON strings so Ankole can save the
  conversation history and the Agent can finish its reply.
- Separate personal-assistant tasks from stable colleague DMs. Home and Chat
  combine recent work, pending decisions, relevant comment activity, and the
  colleague directory. New Chat preserves unfinished drafts, DM invitations
  create a separate group with editable Page references, and DM headers identify
  the colleague throughout the relationship. Global search also finds colleagues
  by UID, name, or role, and inactive sidebar tabs keep their attention badges
  visible. Pages open a private Assistant panel. Queued
  attachments remain available for preview and download. Removing a top-level
  private Page returns to its private directory.
- Keep characters in order when a user types immediately after selecting a
  colleague mention in a Page comment.
- Let personal assistants delegate asynchronously to AI colleagues through
  isolated peer conversations. Show compact progress cards and live details;
  return clarification and approval requests to the originating conversation.
  Human answers resume the colleague directly, completed exchanges clear pending
  controls without opening their details, and stopping or deleting work stops
  the associated exchange. Clarify ownership and Page-role guidance keep the
  assistant from duplicating a colleague's questions or limiting document reviews
  to read-only access.
- Make personal-assistant and colleague work easier to follow in Pod. Each
  delegation is one row that names the colleague, states where the work stands,
  and shows the start of the answer when it arrives; a colleague's question names
  who is asking. Sidebar rows tell tasks, colleague DMs, and groups apart, show
  time and the latest message for conversations, and mark work that needs you
  with a labelled badge. The New chat row no longer overlaps the list below it,
  DMs no longer show an empty bar above their header, and browser tabs show the
  colleague's name. Starting a group from a task or a DM asks for a name,
  members, and a first message, and says what is missing before it can create
  the group.
- Expose incremental Page sharing to Agent tools and preserve each colleague's
  own resource permissions. Add audience-filtered context recall across peer
  exchanges, DMs, and Page comments, with short IM conclusions and Page-based
  deliverables. Colleagues retain each requester's recent context even when
  serving many other projects. Worker directory reads use the browser's compact
  projection so unloaded Page fields cannot break RPC encoding.
- Keep historical private conversations reachable under their own titles, and
  give a new Human instruction its own delegation budget and a visible response
  when it joins an assistant's running turn.
- Open a colleague's stable DM directly from a delegation card. Delegation cards
  distinguish queued, running, and retrying work, and stopping a queued
  delegation cancels it before execution starts. Related-context indexes keep
  recall references intact within their token budget when recent delegations
  attach many Pages, so colleagues can still recall the prior exchange from a
  follow-up DM. Combine already
  queued colleague results for the same request into one assistant turn, while
  keeping later results and other tasks separate.

## Version 2.0.0-alpha.46 (2026-11-02)

- Keep the shared email verification form’s resend countdown in the public auth catalogs.
- Disable Agent, model-provider, Signal Binding, tenant, group, permission-grant,
  Worker environment-variable, and SaaS invitation-code fields until their initial
  drafts load, so arriving data cannot overwrite operator input. Apply the same
  initialization gate to the setup company profile and business selection.
- Keep temporary Response IDs consistent across HTTP, streamed events, and
  WebSocket continuation without storing those Responses.
- Wait for initial editor data before accepting identity-provider, scheduled-rule,
  and Worker-provider input; preserve drafts during background refreshes.
- Select browser options by label first, then by value when no label matches,
  including when a page replaces the control while options load. Preserve exact
  label spacing and fire one change event when selection opens a dialog. Report
  expired browser actions as retryable timeouts.
- Let operators choose an active Agent when a new schedule link names an unavailable
  one. Keep switches disabled while forms load and return focus to Clear filters
  when the last matching Webhook disappears.
- Accept an omitted Agent UID when creating a shared personal-assistant Bot.
- Match the Pod account button's accessible name to its visible identity order
  in every supported language.
- Refresh root directory queries when committed Page changes use a concrete
  root ID, so new Pages appear in the Space tree.
- Return focus to the Brain source and Webhook create buttons when list updates
  move those buttons during or after the creation dialog closes, without taking
  focus from another control the user has selected.

## Version 2.0.0-alpha.45 (2026-11-01)

- Replaying a recorded tool result or workflow round returns the existing record
  instead of failing an identity lookup. Replay lookups stay within their tenant.

## Version 2.0.0-alpha.44 (2026-11-01)

- Keep tenant identity in Session processes, delivery scheduling, and Kubernetes
  shared-volume paths. Upgrade legacy System identities and preserve Delivery
  attachments through Principal renames. Typed mentions and attribution follow
  the renamed Principal. Compose copies pooled Agent Homes to tenant-qualified
  volumes after schema migration, with matching ownership labels.
- Cold wake briefings read real file prefixes, preserve UTF-8 at the read boundary,
  and omit withdrawn quoted messages. Codex resumes evaluate the last context
  size before clearing their pause marker.
- File comments bind selections to the previewed object version, support
  file-specific comment grants, and recognize CommonMark headings. Page-chat
  readers can download attachments through current host-page access.
- Shared personal-assistant Bots enforce direct messages. Initial chat mentions
  acquire locks together, owner status changes reconcile assistant Workers, and
  generic clarification replies reject approval-card identifiers.
- Canonical titles settle autosave without discarding newer edits. Principal
  renames refresh browser identity, and approval cards show grant and participant
  details. Chat drafts remain editable while a send awaits confirmation.
- Scope legacy per-Agent Console file grants to that Agent's private Drive.
  Preserve read and nested-file creation, merge replacement and deletion under
  `node_edit`, and reject ambiguous Agent targets before migration. Global file
  grants remain global; equivalent rules are deduplicated. Initialize owner
  permissions for private roots without a legacy Pod Page so upgraded Agents
  can read their Skill catalog.

- Upgrade bundled Codex to 0.166.0 and match its app-server protocol
  declarations. ChatGPT subscription requests send that client version.

- Brain and Pod Applets have independent system model overrides and usage
  attribution. Configure `ankole_brain` and `system` in Default model profiles.
  Embedding signature changes ask for confirmation before saving and trigger
  background re-embedding. Upgrades stop if an existing Principal already uses
  `ankole_brain`; rename that Principal before retrying the migration.
- Model-profile migration keeps same-named Agents in different tenants separate.
  Editors refresh inherited models without discarding unsaved edits, and
  Provider-reference errors identify the tenant that owns each override.
- Upgrade the PostgreSQL image to pg_search 0.26.4 to fix scored searches with
  prepared scope filters. Container deployments allocate 1 GiB of shared memory
  for parallel queries.
- Tenant deletion advances past slow empty tables before yielding its batch
  time slice, so repeated cleanup attempts continue making progress under load.

- Hosted image-generation requests no longer crash the control plane when nested
  request data exceeds the native scheduler stack.
- Delete confirmation cards become stale when a concurrent document or Base
  change commits before the target write lock is acquired.
- Agent Markdown repair preserves reference links and definitions, and chat
  excerpts preserve blank lines inside code. Mermaid PNG exports preserve
  aspect ratio and reject diagrams beyond the canvas pixel budget.
- CLI guidance appears again after automatic Codex compaction. Truncated output
  pipes return a nonzero status without printing a stack trace.
- Page title sanitization preserves combining characters while removing Bidi
  controls, keeping the client and server's code-point limits consistent.
- Principal names are unique within each tenant. Human accounts use their email
  or external identity ID, AI colleagues use the name chosen at creation, and
  administrators can explicitly rename either. Existing browser sessions remain
  signed in; failed Base shard reference updates can be retried separately.
- Principal renames preserve private Brain page access and links through version
  restores, and update document mentions containing XML-escaped characters or
  additional attributes.
- Members can start a New Chat with a personal assistant, created on first use.
  It uses the owner's collaboration permissions and private documents while
  keeping its own execution, files, tasks, and usage records. AI colleagues
  remain available in the shared directory.
- A tenant can route a shared Feishu or Slack Bot's private messages to each
  sender's personal assistant. Channel configuration uses binding IDs; API
  callers must use `uid` when creating AI colleagues and the binding ID routes
  when reading, changing, or disabling channel bindings.
- Numbered lists pasted from Microsoft Word keep their starting number.

- Page titles hold at most 255 Unicode code points. Typing or pasting past the
  limit drops only the excess new text, and existing longer titles stay until
  they are edited.
- Setting `drive.trash_retention_days` to `0` keeps deleted Drive nodes in Trash
  until the setting changes; the Console offers it as a switch.
- Let authorized administrators restore accounts with a reason, clearing eligible
  restrictions in the same operation. Restoration uses current permissions and
  requires a fresh sign-in; old credentials and work remain revoked.
- Allow administrators to disable Worker Plugins with existing Agent references.
  The choice takes effect on restart; re-enable the Plugin to resume operations
  that need its provider kinds.
- Let tasks finish their answers when a background message is withdrawn.
  Withdrawing the task's triggering message still cancels the task.
- Unify files, folders, and Pod pages in Drive. Moving or renaming keeps node
  links intact, sent attachments keep their original bytes, and the Site Console
  can manage every space even while Workers are offline. File overwrites replace
  the current content without file history or hash-based deduplication; document
  history remains available.
- Keep open file previews current when Agents replace their bytes. Browser
  replacements compare object IDs, including changes made through runtime paths.
  Preserve user text and provider payloads during attachment migration, and
  include folder names in nested Site Console breadcrumbs.
- Execute delegated resource access with the Agent's own permissions. Humans
  still need authority to issue the instruction, but their resource grants and
  authentication conditions do not constrain the Agent. Guests have no private
  root; demotion preserves an existing private root while denying access.
- Stop old writers and Workers and back up PostgreSQL with the object store
  before the [unified Drive migration](docs/upgrades/unified-drive.md). Deploy
  matching control-plane and Worker builds for RuntimeFabric protocol 11. FUSE
  remains deferred until all built-in Worker providers meet its mount prerequisite;
  Agents continue to use `ankole-files`.
- Configure model profiles through Site defaults, Pod overrides, and sparse
  Agent overrides in the Console. Brain, Pod Applets, and local compaction no
  longer require a maintainer or creator Agent; their LLM usage is recorded
  separately without consuming Agent quotas. A single primary model covers
  basic LLM work, while embedding, rerank, and web fetching remain independently
  configurable. Existing Agents inherit the seeded Pod defaults for every slot
  without an override, including web fetching. Matching overrides are removed;
  distinct overrides and custom models are preserved. Back up PostgreSQL before
  this migration: downgrading requires restoring that backup.
- Render fenced `mermaid` blocks in Pod Chat inside sandboxed SVG viewers with
  Diagram/Source switching, PNG export, and double-buffered zoom, repair
  malformed Agent-generated Markdown fences, GFM tables, and list/bold spacing
  without altering code or math blocks, guard interactive chat islands against
  browser translation crashes, and let users select multiple chat messages to
  export Markdown excerpts, save a Pod document, or generate PNG share cards.
- Open Pod comments to File nodes with version-bound multimodal anchors (code
  lines, CSV row ranges, Markdown sections, and media timestamps), wake
  `@`-mentioned Agents from Document and File comments when both Human and Agent
  permissions allow, and expose `ankole-pod comments` (`list`, `show`, `reply`,
  `resolve`) to Agent runtimes.
- Add `propose_action_card` approval cards so Agents can draft permission
  changes, page trash/restore operations, Base table deletions, and conversation
  participant invitations for one-click Human confirmation across Pod Chat,
  interactive IM channels, and WebUI confirmation links for text-only channels,
  enforcing optimistic target preconditions and live Human authorization on
  execution.
- Replace the daily `04:30` scheduled Session reset with prompt-cache-aware
  cold-wake conversation rotation (`sessions.wake_recycle` and 10-minute cold
  `waiting_on_user` Codex Job thread recycling) backed by bounded `<wake-briefing>`
  context and live `/workspace` re-reads, emit once-per-context CLI subcommand
  guidance on `stderr` while keeping `stdout` pure JSON (`EPIPE`-safe), and
  reject Unicode bidirectional override and control characters in Drive and
  attachment filenames while isolating untrusted external names in `<bdi>`.

## Version 2.0.0-alpha.43 (2026-10-30)

- Discarding unsaved changes when leaving a Pod document removes the local
  draft, so reopening the page no longer saves the discarded title.
- Turning several selected blocks into another type from the selection toolbar
  keeps the text selected and the toolbar open.
- Plain-text copy of a Pod document links uploaded files with the reader's file
  address, and editing stats count only written text.
- Version comparison marks only the changed lines when text follows the last
  line of an older version.
- Full-width tables in Pod documents extend into the page margins.
- Markdown export and copy omit empty paragraphs instead of writing `<p />`.
- Pasting bullet and numbered lists from Microsoft Word, including `(1)` and
  `一、` numbering, keeps them as nested lists.
- The code language picker lists exact name and alias matches first, so `ts`
  selects TypeScript.
- Losing edit permission while editing says so instead of reporting a changed
  document, and a page that cannot load mentions a kept draft only when one
  exists.
- Network failures show a translated message instead of the browser's
  `Failed to fetch`.
- Starting an IME composition on selected blocks writes only the committed
  text in their place, both on an empty paragraph, such as the one that Escape
  and Down create below a code block, and on blocks with text.
- Confirming an IME candidate with Enter or Escape in the code language search
  or the callout icon field no longer picks a language or closes the menu, and
  the callout icon changes only when the composition ends.
- Pasting a GitHub task list whose items hold paragraphs keeps it as a task
  list.
- Enter in the only, empty paragraph of a callout adds a paragraph inside the
  callout instead of removing it.
- Typing, IME composition, pasting, and inserting an image over several
  selected table cells put the input in the first selected cell and clear the
  others, instead of deleting cells or merging rows.
- Shift+Down and Shift+Up extend a cell selection down its column also beside
  empty cells, instead of selecting the neighbouring column too.
- A collaborator's deletion that leaves a column row with one column unwraps
  that row, as a local deletion does.
- Typing in a large table is fast again: a 500-row table took seconds for each
  key because every closed table menu checked row and column moves.
- Cutting a whole document that starts with a table no longer crashes the
  editor.
- Deleting, typing over, cutting, or pressing Enter on a text selection that
  crosses columns, nested list items in a table cell or callout, or a sublist
  inside a callout keeps the columns, table, callout, and unselected items in
  place, and undo restores the columns.
- Pasting over two selected list items no longer nests the next item.
- Command+Backspace at the first item of a list inside a callout or quote joins
  it to the text before the container.
- Pasting plain text with thousands of lines no longer takes seconds.
- Page text styles keep only `color`, `background-color`, and `text-transform`.
  Other declarations, such as a `position: fixed` overlay that covered the page
  for every reader, are dropped when a page is read, written, or pasted into;
  pages with such styles still open.
- Pod search, scoped lists, favorites, recents, and Trash match every word of
  a query in the title or body, in any order, using the first 16 distinct
  words.
- The selection toolbar stays closed after Ask Agent or Comment instead of
  briefly reopening on the same selection.
- With text selected in a Pod document, Command+K on Apple platforms and
  Control+K elsewhere open the link form; otherwise they still open search.
- Page titles hold at most 255 characters. Existing longer titles stay until
  they are edited.
- Moving a Page to Trash names how many subpages moved with it, and Trash rows
  show the days left before permanent deletion.
- Setting `pod.trash_retention_days` to `0` keeps deleted Pages in Trash until
  the setting changes; the Console offers it as a switch.

## Version 2.0.0-alpha.42 (2026-10-30)

- Reset pre-release browser and OIDC sessions when migrating to unified
  `site` and `tenant` authentication scopes. Users sign in again while
  identities and OIDC client registrations remain intact; existing refresh
  tokens stop working, and pending back-channel logout deliveries are discarded
  with the retired sessions. Signing into the privileged Pod as a `siteadmin`
  opens the Site Console and `/api/v2/site/*` endpoints directly without a
  second login, with multi-account browser pinning on the Console shell, sealed
  `console_return` redirects filtered to `siteadmin` identities, unified
  authentication evidence on OIDC tokens, and `403` responses for authenticated
  non-admin sessions on `/api/v2/site/*` and unauthorized native Agent file
  downloads and uploads.

- Scope single-space sign-out in Pods and the Site Console to the target Pod
  (revoking only that Pod's access and RP sessions while other live Pod
  identities remain on the site authentication, and returning Console sign-out
  to privileged Pod sign-in via `?switch=1`), show browser-wide sign-out only
  when more than one account is signed in, clear local Pod document and comment
  drafts on sign-out, and require a resolved Pod host on `/api/v2/pod/*`
  endpoints.

- Sharpen Brain hybrid retrieval and close the Agent page-curation loop. `recall`
  returns qualifying claim `context`, caps fused chunk candidates at two per page
  before cross-encoder reranking, gates recency and salience boosts onto hits
  backed by lexical BM25 evidence, and packs up to three exact-alias entity cards
  with relationships and backlinks inside the token budget. Agents can read raw
  caller-visible Markdoc prose and its `revision` via `get_page(include_content:
  true)`, create or replace structured pages via `put_page`, and apply surgical
  multi-span replacements via `edit_page` under `expected_revision` optimistic
  concurrency while preserving audience boundaries and calibration scorecards.
  `synthesize` incorporates claim `context`, decayed confidence, and
  scope-bounded open contradictions to surface contested points and open gaps,
  and refuses to replace analysis sections the caller cannot see or edit.
  Console duplicate-page merge approvals consolidate non-blank duplicate bodies
  with `ObjectVersion` snapshots, and Background Agent Jobs gain `entity`,
  `whoknows`, and `delta` through `tools.read`.

- Replace block-level Document Page embeds in Pod Documents with inline `@` /
  `＠` mentions for Pages (`doc`, `base`, `file`, `applet`) and Principals
  (tenant members, shared Guests, and AI colleagues), migrating historical
  Document `<embed ref="…" />` blocks to `<p><mention page="…" /></p>`
  paragraphs in PostgreSQL while keeping **Embed Base or app** (`embeddable=true`)
  for interactive Bases, File Pages, and Applets. Typing `@` filters **All**,
  **Pages**, and **Principals** without leaving the document, converts pasted
  Pod Page URLs and newly created child Documents into inline mentions, previews
  Page excerpts on hover, opens Principal identity cards on click, highlights
  self-mentions, redacts restricted targets, and resolves Guest Principal
  mentions within each Page's collaborator context while showing external Guests
  only collaborator display names and avatars.

- Redesign Pod Page sharing as a two-level popover with an overview, multi-select
  collaborator invite flow, inherited and direct collaborator breakdown (`This
  page and subpages` / `This page only`), consistent comment-role selection,
  access-scope controls, and permission settings. Viewers without `manage`
  access can open a read-only sharing overview to inspect effective
  collaborators and copy the Page link. Interactive sharing changes apply
  immediately via `PATCH /api/v2/pod/pages/:id/sharing`, block new Guest grants
  on Private Pages while allowing existing inactive grants to round-trip without
  granting access, and publish access updates when trashing or restoring a
  Userset source Page.

- Add durable document history, selected-text and whole-page comments, portable
  Markdown exports, an editing statistics footer, and Document Insights:
  - **Version history**: Capture five-minute checkpoints plus pre- and
    post-restore snapshots (retained for 30 days, up to 200 per Page), show
    content-edit timestamps and version diffs, preview snapshots read-only while
    references load, refresh before confirmation, and commit metadata-aware
    restores as new OT revisions. Full history requires edit access.
  - **Comments**: Support anchored and whole-page threads, replies, resolution,
    relocation, direct thread links, unread activity indicators, and mobile
    navigation between discussions and quoted text. Native comment marks follow
    in-editor moves and cut/paste across blocks, code, and Mermaid source while
    omitting marks from copies and exports. Contributors can comment without
    document edit access; canonical stored role grants gain comment access during
    migration while custom action subsets keep their declared permissions.
    Anchored comment submission and relocation unlock once the document body is
    confirmed, even when a title change or recovery draft is pending.
  - **Markdown export, statistics, and Insights**: Copy Documents as Markdown or
    plain text, and export Markdown or ZIP archives bundling document-local
    uploaded assets, custom icons, and embedded File Pages while keeping inline
    Page mentions and links as Web URLs. Count CJK words via Unicode
    segmentation in a toggleable footer, and surface creation/update times,
    durable Human and Agent contributor attribution, 30-day activity trends, and
    optional per-document reader privacy in Insights.

- Open deleted Pages from Trash in a read-only detail view with restore and
  confirmed permanent-delete actions, keep trashed Applets inactive while
  preserving Page previews, keep external embedded Pages in their original
  directory when an embed block is removed, and commit block-menu deletion of
  multiple child Pages atomically in one transaction.

- Upgrade collaborative Document editing, rich blocks, and table workflows:
  - **Collaborative sync and drafts**: Preserve concurrent edits across lists,
    tables, local undo, formatting marks, and Agent writes; retain local drafts
    across tab reloads, rejected sessions, and whole-block replacement or sort
    conflicts; require title baselines on Human and Agent renames to surface
    conflicting title drafts instead of overwriting them; and place live
    synchronization status and online participants in the Page header.
  - **Blocks, media, and icons**: Add H1–H6 section folding, multilingual slash
    aliases, configurable callouts, syntax-highlighted code blocks with
    searchable language pickers and line wrapping, inline-editable `$$` LaTeX
    formula blocks, split-view Mermaid diagram blocks with templates and
    full-window preview, image and video uploads with link/card/preview modes,
    webpage bookmark cards, external iframe embeds, multi-column layouts with
    resizable widths and cross-column selection/navigation, and Document File
    uploads saved as child File Pages in a collapsible List/Grid subpages
    directory below the document body. Document Page icons sit in the title line
    with localized Emoji search and shared Custom icons (`metadata/custom-emoji/`
    up to 1 MB, named with bare names such as `my_icon` stored as `:my_icon:`).
  - **Tables**: Add selection-aware row and column operations, cell merge and
    split, drag and keyboard reordering, column widths, cell colours, sorting
    (skipping no-op sorts), full-width layout, sticky headers, independent
    scrolling, single-cell content paste, and formula-safe CSV export.
  - **Keyboard, CJK IME, and gutter interaction**: Preserve list structure and
    active preedit sessions during Chinese and CJK IME composition; align
    whole-block, column, code, formula, and heading shortcuts (`Escape`,
    `Shift+Enter`, `⌘Enter`, `Tab`/`ArrowDown` from title into body); unify
    slash, `+`, and block-type menus; click below the last block to focus or
    append a paragraph; and drag from blank gutters for marquee block selection.
  - **Selection `Ask Agent`**: Quote selected document text directly into Page
    chat from the selection toolbar (available in read-only documents and code
    blocks as well), preserving selected-text quotes when the draft already
    references the same Page.

- Improve Pod and Console navigation, startup speed, and fault isolation:
  - Bootstrap sidebar roots and the active Page's authorized `ancestors` path in
    one pass, keep directory caches and cursors across tab switches and metadata
    patches, prefetch linked Pages on pointer approach, remove the 500 ms route
    loading floor, load Console routes on demand, and load emoji data, syntax
    highlighting, and formula rendering lazily.
  - Resize the desktop Pod sidebar between 248 and 480 px with left-edge hover
    preview when collapsed, highlight only the sidebar row a user followed, keep
    Page titles and icons synchronized across trees, breadcrumbs, lists, and
    pickers, and keep permitted Page creation actions available while sections
    load or recover.
  - Isolate frontend render exceptions into inline, panel, and shell fault
    boundaries across Pod, Console, Auth, and Setup with localized retry,
    one-click diagnostic copy, and unsaved Document draft export.

- Refine the interface design language, typography, and Pod Chat presentation:
  - Align Page headers, side panels, and Console headers onto shared 16px paper
    sheets over a cool light ground (`#F9FAFB`), move Console setup, theme, and
    sign-out controls into the content sheet header, place Console list search,
    filters, and counts in the top row of the list frame, and round transient
    ceramic menus, popovers, dialogs, and sheets at 8px with unified control
    borders, disabled outlines, and error borders.
  - Regularize Okhsl colour ramps around the `#E10059` primary action across web
    surfaces and transactional emails, style destructive buttons in deep red, and
    highlight focused destructive menu items with a translucent red wash.
  - Align Document typography and spacing with a 38px semibold title, 28/22/18px
    headings, and a 32px body and list rhythm.
  - Put Pod Chat on a single 760px column with 15/24 message text, unified code
    and table blocks, inline conversation renaming, distinct sidebar indicators
    for unread, waiting, and working turns, labelled Stop/Retry/Steer controls,
    and real-world multilingual layout fixes for CJK/Arabic avatar initials,
    Vietnamese diacritics, automatic `dir="auto"` text direction, formatted run
    durations, and narrow-screen headers.

## Version 2.0.0-alpha.41 (2026-10-30)

- Fix enterprise SSO buttons on the Site Admin Console and Pod sign-in pages.
  Ankole sent these buttons an empty sign-in link, so the browser opened
  `/null` and showed a "no route found" error instead of the provider's sign-in
  page.

## Version 2.0.0-alpha.40 (2026-10-29)

- Internal changes only.

## Version 2.0.0-alpha.39 (2026-10-28)

- Internal changes only.

## Version 2.0.0-alpha.38 (2026-10-28)

- Stop declaring native image generation and web search to an OpenAI provider
  that uses Chat Completions. Chat Completions rejected those tools, so every
  Agent turn on such a provider failed.
- Send model profile request options under the field names that each upstream
  accepts, such as `prompt_cache_key`, `verbosity`, and `inference_geo`. Reject
  Responses-only options on Chat Completions.
- Remove request options that had no upstream field: `strictJSONSchema`, the
  OpenAI `systemMessageMode`, `forceReasoning`, and `allowedTools`, the Google AI
  Studio `textVerbosity`, and the Claude `structuredOutputMode`,
  `toolStreaming`, `taskBudget`, `anthropicBeta`, and `contextManagement`. A
  model profile that stores one of them now fails validation. Before, the
  upstream rejected the request. Remove the option from the profile.
- Remove the Claude `none` and `minimal` reasoning effort values, which
  Anthropic does not accept.
- Send a reasoning effort only to models that accept one. A model without a
  configured effort gets `high` only when the packaged model metadata marks it
  as reasoning, so OpenAI models such as `gpt-4o` and `gpt-4.1` and Claude
  models without effort levels, such as Claude Haiku 4.5, work again. A
  configured effort that the model does not list fails before the request, for
  example `xhigh` on Claude Opus 4.5. Models that the metadata does not describe
  get only a configured effort.

## Version 2.0.0-alpha.37 (2026-10-28)

- Show the Pod page picker scope labels from the locale catalogs.
- Make the full Pod mobile sidebar section link 40 px tall so the whole row
  opens the section.
- Offer the realtime reconnect action on a Pod page when its live connection
  does not open in 10 seconds. Loaded file previews stay visible.

## Version 2.0.0-alpha.36 (2026-10-28)

- Show tenant-owned Site Console collections across all tenants and let operators
  filter by tenant. Bind record forms, row actions, links, searches, and page
  cursors to the selected tenant. Share site infrastructure queries and preserve
  the tenant filter when operators open site settings.
- Show Agent Library read errors for the selected capability scope.
- Keep padded Base64 page cursors intact when operators reload a Console list or
  return to its previous page. Show unknown Console routes without asking for a
  tenant first.

## Version 2.0.0-alpha.35 (2026-10-28)

- Complete targeted site-credential sign-in through the existing UID-ordered Principal admission flow, preserving site access for non-members and explicit errors for disabled or policy-rejected members. Centralize browser login targets and build-selected login URLs.
- Organize AppConfigure into one editing scope, task forms, and a read-only searchable registry. Commit grouped edits atomically, preserve site and workspace ownership, show real reset fallbacks and persistent restart/index status, inspect consumed Agent overrides, and test SMTP drafts without changing the saved transport. Migrate Worker namespaces, combine OTP limit policies, and separate Brain deletion retention from memory decay.
- Preserve custom tool identities and text inputs through Anthropic request schemas, tool choices, streamed responses, and history replay. Add production-code bounded checks for PTC replay, Worker message ordering, and provider tool aliases, plus a Lean proof that cumulative ACKs stop at a sequence gap.
- Verify production Base field-version checks, tool call/result identity, formula-copy metadata, and aggregate reference byte budgets with Lean; expand bounded counterexample searches and exercise failed-batch rollback against both inline and physical Base storage.
- Render the site Console and Console sign-in in the privileged Pod's `i18n.default_locale` (falling back to `en-US`), and immediately switch the Console UI language when updating or resetting the privileged Pod's `i18n.default_locale` in Console Settings.
- Render the Ankole brand icon and favicon across the Console, Setup, sign-in, session, and invitation screens as well as verification and invitation emails, drop the redundant "Control plane" subtitle from the Console header, and separate `@ankole/uikit` primary action ink fills from the `#FF4669` brand accent palette so primary buttons stay distinct from destructive actions.
- Skip SMTP delivery on ineligible email OTP login challenges while keeping the standard code-sent response: Console logins deliver only to `siteadmin` members, Pod and OAuth logins without an invitation deliver only to existing members (including disabled or SSO-gated members so verification surfaces `account_disabled` or `login_policy_rejected`), directed invitations deliver only to the invited email, and `/me` reauthentications deliver only to the pinned member. Restrict `purpose="site"` sign-in and registration to editions with a site sign-in host (disabling public site registration in FOSS), and clear site resend cooldowns once a site challenge is verified.

- Install the official OfficeCLI 1.0.159 Linux binaries with SHA-256 checks.
  Remove the local OfficeCLI patches and the .NET build from the Worker image.

- Run Site Console cron schedules with the selected Agent's service authority
  and keep the administrator as the recorded creator. Active and paused Console
  rules that still use their verified creator as the Human authorizer become
  service work, together with matching pending fires. Paused rules stay paused.

## Version 2.0.0-alpha.34 (2026-10-28)

- Scope `i18n.default_locale` strictly to each Pod workspace (`:pod` AppConfigure scope), migrating any existing site-level default locale to Pods without an override and rejecting site-level or per-Agent writes.
- Let Pod administrators view and update their workspace's `defaultLocale` in Pod Settings (`/api/v2/pod/admin/settings`), render Pod and Pod sign-in HTML shells in each Pod's configured locale, and negotiate `Accept-Language` (falling back to `en-US`) on tenant-independent HTML shells and site-wide email OTP deliveries.
- Layer the Pod and Console workspaces as rounded paper sheets above a ground-level collapsible sidebar, move compact Home/Chat tabs and quick actions into the Pod sidebar header, interleave visited Pages (`visited_at`) and active Conversations in Recently Visited, and surface Favorites inline above the Space tree.
- Download a Feishu file or image that a group member sends without a mention
  when the binding ignores unaddressed group messages. A later reply that
  mentions the Agent and quotes the file now gives the Agent the stored file.
  Before, the attachment stayed `pending` and the Agent saw only the file name.
  A redelivered event keeps the stored file, also when its new download fails.

## Version 2.0.0-alpha.33 (2026-10-28)

- Fail an Automation Job run that stays `running` after its attempt deadline
  when no Oban job owns it. Such runs used the Agent's running slots, and when
  `automation_jobs.max_running_per_agent` runs leaked, every new run of the
  Agent stayed queued with no error. Runs that leaked before this version fail
  within five minutes after the upgrade and send their failure notice when
  `wake_on_failure` is set.

## Version 2.0.0-alpha.32 (2026-10-27)

- Record the verified authentication time for each OIDC authorization code and use it in ID Tokens and refresh context, including email reauthentication.
- Keep unchanged PPTX chart data linked to its original workbook cells when series are added or removed. Preserve other workbook cells and correct scatter and bubble values.
- Keep image Python packages available when the per-Agent Python bootstrap runs from an active Agent environment.

## Version 2.0.0-alpha.30 (2026-10-28)

- Collect the company name, editable tenant slug, and business packs during Setup, and explain how business selections shape the Company Brain ontology.
- Simplify the Setup step navigator with compact single-line rows and a subtle current-step treatment.
- Support source-build Console extension slots (`ConsoleAppSlots`) and site-administrator extension JSON:API routers (`/api/v2/saas-site` OpenAPI and client generation).
- Migrate `1.x` `signals.lark.bindings.*` Lark binding settings onto `signals.lark.binding_configs.<digest>` during `Ankole.Upgrade202610`.
- Forward `ANKOLE_VERSION` and `ANKOLE_ENV` from the control plane to launched Workers, and fall back to `ANKOLE_RELEASE_REVISION` for Worker log and trace version labels when `ANKOLE_VERSION` is unset.
- Compare JSON object settings structurally in Console editors so reordered keys keep clean forms clean, reject non-object JSON command frames in the browser daemon and Job emit bridge, and ignore malformed SSE payloads in Pod chat streams.

## Version 2.0.0-alpha.29 (2026-10-27)

- Start the setup activation-code command in a cold process.
- Honor model profile sampling settings during ambient triage and preserve optional arguments in hosted Brain calls.
- Apply tenant query timeouts to physical Base reads and aggregates. Establish owner access when a page first moves into Private.
- Let Console operators inspect system groups by name or ID. Hide saved Skill lessons while learning is disabled, and describe JSON API results with the fields they return.
- Keep pulled Applet projects writable by the Agent, including nested folders, and install their packages as that user. Let custom Python environments use the image's Python packages.
- Reject Worker requests that exceed the transport frame budget before transmission.
- Create standard PPTX charts with editable workbooks. Correct spreadsheet pivot results, chart references and axes, and PDF table headers.
- Keep Pod and Console actions working on HTTP origins. Clear stale Chat activity during disconnection, wait for requested browser snapshot elements, and correct missing language labels, page titles, and navigation state.

- Bound HTTP/1 data queued during an Applet invocation to 1 MiB. Overflow closes the connection and cancels the invocation while preserving committed writes.
- Save Messaging Binding filters on creation, edits, and moves. Omitted filters keep their saved value for the same adapter and reset when the adapter changes. Invalid filters reject the complete write.
- Let an Agent read the current native conversation readers' private Brain content. Other participants continue to restrict disclosure.
- Preserve native Conversation routes when Workflow tasks delegate Background Jobs, so Job results wake the owning task.

## Version 2.0.0-alpha.28 (2026-10-27)

- Serve `/sessions/new` directly without expiring `flow` query URLs or upfront
  login-transaction writes. Keep outbound enterprise SSO state in
  `browser_oidc_states`, keep email OTP ceremony state in `authn_challenges`,
  and isolate relying-party OIDC authorization requests in `Ankole.OIDC`.
- Use the SaaS `accounts` host for sign-in and registration. The root host opens
  the most recently used tenant account when signed in.
- Combine SaaS sign-in and registration through email verification. Use a
  separate space selection step for enterprise SSO, and remove invitation-code
  forms from the sign-in and account pages.
- Keep an existing email verification code usable when a replacement email
  fails to send; activate the replacement before invalidating the old code.
- Keep verification codes for different email accounts independent. Allow a
  valid unused ordinary code to start a new sign-in after logout.
- Accept valid Bot Framework tokens with the standard `serviceurl` claim for
  Teams and Azure Web Chat message ingress.
- Send localized HTML and plain-text verification code and workspace invitation
  emails in the recipient's preferred language.
- Create Applets through Agent conversations. Use the creator Agent's model
  profiles and token quota for Applet AI calls.
- Create file Pages with their selected file in one transaction. Save chat
  content and attachments together with their destination Page.
- Save sharing changes directly, show authorized search breadcrumbs, and expose
  child listing and search through the Pod CLI. Add table and view rename controls.
- Copy only the selected Base table. Convert links to ordered title text,
  validate copied formulas, and remove view filters tied to source record IDs.
- Preserve numeric precision during Base field conversion and let trash purge
  continue past parents whose children still need removal.
- Reject incomplete tool-call JSON. Keep function-runtime health independent of
  invocation capacity and preserve resource URLs in Applet Worker bundles.
- Keep Human email and sign-in credentials consistent. Store OIDC refresh
  identity once, and preserve adapter recovery context keys.
- Keep Brain contradiction and grading evidence within their audience scope.
  Preserve retrieval boosts through reranking and overlap unspaced CJK text.
- Report unexpected Console failures as HTTP 500 and retain useful domain,
  provider, CEL, SMTP, and Worker failure diagnostics.
- Let people discard failed Page drafts directly. Use the same delete and Undo
  flow from the Page header and sidebar, and show paths beside Page search results.
- Apply field visibility to kanban and gallery cards. Start new kanban views with
  an available category, use single-choice controls for single-value references,
  and prompt for unfinished calculation input without reporting it as an error.
- Upload Agent files from the file or folder picker, rename them in place, and
  download them from their names. Move files by destination folder.
- Open member details after creation. Resend Setup verification codes directly,
  keep callback customization optional, and normalize group names consistently.
- Separate identity-provider creation from editing. Reject duplicate creation
  instead of overwriting an existing sign-in configuration.
- Open Console preparation guidance on request. Check runtime prerequisites
  without requiring an external messaging channel.
- Give each single-value Base relation its own database constraint name, so
  multiple tables can use single-value relations in one tenant. Remove a deleted
  field's cardinality constraint while preserving the surviving reverse relation.
- Ignore late workspace status replies when a Session is not opening a Worker.
  Remove duplicate current-generation Worker instances and keep unlabelled
  platform instances out of absent Workers.
- Simplify Pod, Console, Auth, and Setup interactions: rename Pages, Chats,
  Base tables, and Base views in place; confirm destructive deletes and sign-in
  method removals; derive slugs from names; replace raw UIDs, slugs, crontab
  text, millisecond counters, CEL expressions, and JSON payloads with searchable
  selectors, visual schedule editors, and readable labels; clean deleted Base
  fields from saved views; and filter Base author fields by member.

## Version 2.0.0-alpha.27 (2026-10-26)

- Translate Applets as 小应用 in Simplified Chinese interfaces and starter templates.

## Version 2.0.0-alpha.26 (2026-10-26)

- Internal changes only.

## Version 2.0.0-alpha.25 (2026-10-26)

- Rename Database pages and APIs to Base (多维表). Update callers to `/bases`, `pod_base_operation`, and `AnkoleRuntime.base`.
- Keep small independent Base tables inline and automatically move large or linked tables to typed PostgreSQL shard tables. Primary fields have a fixed text type and accept up to 2 KiB of UTF-8 text.
- Keep the original copy destination visible when it is read-only, and require a new selection before copying a Base table.
- Keep a record form's identity across failed submissions. Repeated creates return a clear conflict in both Base storage modes without changing saved records or counters.
- Save Base views without changing physical table schemas or link constraints. Notify connected clients and refresh saved views when clients reconnect.
- Apply the same field conversion rules in both Base storage modes. Preserve unaffected cell versions when select options change, and derive formula and system fields without stored cell values.
- Support browser snapshots for small physical Base tables and include formula results in the 4 MiB snapshot limit.
- Process Base copies and physical field conversions in bounded batches while preserving copy options, record sizes, and atomic rollback.
- Keep healthy Base shards available when another shard cannot connect. Reconnecting pools initialize and verify their shard identity.
- Require PostgreSQL 18. FOSS uses its existing database by default; `BASE_DB_URLS` supports multiple shards, closed allocation, and dedicated tenant placement. Independent shard backups must recover to at least the control-plane recovery time.

- Source builds can add site Plugin hooks, Pod settings tabs, account navigation, and email sign-in challenges. The HTML shell supplies Plugin and feature snapshots before the first render. All SPAs load extension labels. Fixed build Plugins stay enabled in setup and the Console.
- Support direct OpenFeature SDK evaluation without wrapper-specific context. Preserve the SDK evaluation details and flag key.
- Show Control Plane Plugin names and descriptions with the declared locale fallback. Use the same request context for HTML feature snapshots and backend evaluation.
- Check Binding admission when a route is created or reactivated. Keep enabled routes editable and movable when a Plugin limits new routes.
- Read Tenant IDs during the application-identity data upgrade so it can run before the Base storage migration.
- Let Agents learn Skill lessons from completed Pod work without an external chat Binding.

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

## Pre-2.0 releases

See [`CHANGELOG-pre2.md`](CHANGELOG-pre2.md) for `1.x` and `0.x` release history.

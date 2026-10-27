# Pod Content Model

A Conversation holds the work process. A Page keeps the result. Pod content is
shared by Humans and Agents through the same domain contracts. PostgreSQL owns
pages, documents, Base records, revisions, permissions, and file references.
Worker files, browser caches, and channel presence are not durable truth.

Humans and Agents collaborate on the same stored documents and business tables.
An Agent creates and publishes an Applet as another interface to a Base. Its
business operations use the current Human's permissions.

## Browser interactions

Use Notion as the default reference for page, sharing, trash, property, and view
interactions, including loading, empty, pending, failed, and concurrent edit
states. Keep Ankole's components, visual identity, and domain contracts.
This reference does not add features outside the first-version scope. See
[views and filters](https://www.notion.com/help/views-filters-and-sorts),
[properties](https://www.notion.com/help/database-properties), and
[trash](https://www.notion.com/help/duplicate-delete-and-restore-content).
Calendar, timeline, form, and chart presentations are Applets, not built-in
Base views.

Page creation opens a non-modal menu with document, Base, and file choices.
A document or Base opens at the selected Space, Private, or parent destination.
File creation first selects a file, then submits its bytes and Page attributes
through `POST /api/v2/pod/file-pages`. One tree transaction creates the Page
and its file reference. An empty title uses the selected filename.
Document insertion creates a child at the current document. Titles are edited
at the top of the Page canvas. Creation failures keep the entry available for retry.
Applets are created and published by an Agent through its conversation workflow.

Page titles and document bodies share one recoverable draft and navigation
guard. Failed saves retain input. Before leaving with unsaved changes, the
person can continue editing, download the draft, or discard it and leave.
Pending dialogs keep their submitted inputs
and cannot close. Document titles save after a 500 ms pause in typing and on
blur. IME composition delays the automatic save until composition ends. Enter
moves from the title to the start of the body. Up at the start of the body
returns to the end of the title. Normal save status is available to assistive
technology; save failures show a retry control. The document insertion menu
appears beside the body without taking space between the title and body.
Page details and lists include the effective actions from
the same permission snapshot. Operation controls use these actions; role names
summarize access for display. Page moves list writable Page destinations and
exclude the page and its descendants. Root creation, move, and copy choices use
the directory's `can_create_space` and `can_create_private` facts from the same
destination check as the write. Root capabilities load while the navigation
section is collapsed. Trash search matches titles and document bodies
before the server applies the result limit.
The Page header and sidebar use the same trash action. Deleting a Page discards
its local draft, returns to its visible parent or content root, and offers Undo.
Every Page header offers child-page navigation. It lists visible children,
loads further children with the directory cursor, and offers creation when the
Page permits `page_edit`. This entry also serves shared projects whose parent
is outside the current person's view.
Pod links use the tenant's slug subdomain and Kernel's short UUID codec:
`https://<slug>.<site>/pages/<short-id>` and `/conversations/<short-id>`.
The Kernel owns the codec. The browser bundle cannot load the native kernel, so
`app/webapps/common/uuid-url.ts` mirrors it. `app/kernel/test/vectors/uuid_url.json`
pins the codec, and `app/kernel/test/vectors/pod_url.json` pins the Pod browser
path and query grammar that the control plane and the browser share.
Local development uses `<slug>.ankole.localhost:<port>`. Normal links have no `/pod`
prefix or tenant query. Logged-in accounts are shared across Pod subdomains;
switching uses the BrowserSessions authentication and activation owners.
Each open document keeps its selected identity, and every tenant request
checks that identity's admission. The content context supplies the same links to
document embeds and full pages.

Dialogs use compact forms, explicit cancellation, searchable page selection,
and focus restoration. Enter submits ordinary forms; destructive confirmation
starts with Cancel focused. Long forms scroll their bodies while retaining
their title and actions. Property pickers stay anchored to their field.

The sidebar search button and Command/Control+K open the same navigation menu.
The menu links to Pages, Chats, and content locations. Page search owns title
and body matching for both the menu and the search list. The search list keeps
its query in the `q` URL parameter across result navigation, Back, and reload.
Search results, quick navigation, and Chat Page references show visible ancestor
paths so that people can distinguish Pages with the same title.
The menu does not send a request
or replace an unfinished Chat draft. J/K moves focus within content lists;
fields keep their normal typing and composition keys. Desktop rows use compact
spacing, with larger targets on touch layouts. Page references use the same type
icon in navigation, pickers, embedded content, and Chat outputs.

Ordinary Pod actions use paper controls. State color does not mark a selected
view. High-frequency menus and keyboard navigation open immediately. Mobile Chat
panels retain their content during exit; reduced motion removes movement and
uses a short fade. Chat scrolling also follows the reduced-motion preference.

Standalone Chats follow Notion AI's conversation layout. Native follow-up input
can steer at the Main loop's next boundary or wait for a separate reply. The
durable queue supports editing, removal, ordering, and releasing one input;
stale edits fail without overwriting newer changes. Stop cancels current work
and pauses all pending inputs across refresh. Only Continue resumes the queue.
Last-turn editing and regeneration use the retry and model-history
owners, keep completed content changes, and reject changes to running or
superseded turns. Earlier messages load in bounded windows into the same remote
cache while keeping the current reading position.

A first send keeps its local draft and request IDs until the server confirms it.
Opening a new standalone Chat while that request is unfinished uses a separate
draft. An unconfirmed first send remains available for recovery, with its original
attachments and retry IDs.
Late request results apply only to the captured draft and message. The
Chat draft owner keeps this work in memory for the current document.

Returning to a Chat restores the visible message and its offset. The
Chat draft model keeps this position in memory for the current document. Page
panels and Conversation views keep separate positions because their widths can
differ. A Chat at the bottom follows new content. The latest-message
action resumes that behavior. Reloading starts at the latest message.

Model choices belong to the Chat, with null following the Agent default. Each
accepted input captures its logical profile; later preference changes affect
future replies. An input with a different profile from the active run must queue.

Base cells keep the value and field versions from the start of an edit.
Enter or Tab submits; Escape cancels; composition keys do not submit. A conflict
keeps the draft for an explicit retry or discard. View changes preview locally;
an editor can save them for everyone with the starting view version. A failed
save retains the draft. Inline configuration belongs to its document embed.
Single-value relation and user pickers close when a value is selected.
Multiple-value pickers keep the selection open until Done. A calculation that
needs a field prompts for that field. Invalid saved filter and calculation
fields show a repair action.

Ankole's settled differences are: records are not pages and have no separate
page trash; permanent record and field deletion requires confirmation. Moving
a page keeps direct shares, including a move into Private. The move and share
interfaces state this difference. Agents require explicit admission, and
applets run as their current Human.

File uploads capture the selected file and loaded revision. Pending uploads
freeze the picker; failures keep the selection for an explicit retry. A
temporary realtime failure keeps loaded file content and offers reconnection.
Only an authoritative access denial hides content. Applet loading and connection
failures have separate retry actions; retrying a connection does not remount
the applet.

## Pages and access

`Ankole.Pod.Pages` owns the page tree and lifecycle. A page is a `doc`,
`base`, `applet`, or `file`. Every page type can have child pages. A new
Base page has a `Table 1` table, a primary `Name` field, and a `Grid` view. Tables
and records belong to a Base; they are not pages. Sibling positions use
PostgreSQL `C` collation. Page moves lock the tenant tree before they check for
cycles, so concurrent opposite moves cannot create a cycle. A move names one
sibling with `after_id` or `before_id`, and the server makes the key under the
same lock. A sibling outside the destination returns `position_conflict`.
Without a sibling, the page goes last.
The move response includes `undo`, with the original parent, Private owner,
and adjacent sibling read under that lock. The browser uses this result for
Undo, including when directory pagination has not loaded that sibling. An
original location with no siblings needs only its parent and Private owner.

`Ankole.Pod.Access` uses Principal and AuthZ. Each action has one bit:
`page_view = 1`, `page_write_records = 2`, `page_edit = 4`, and
`page_manage = 8`. Roles include all lower actions: `view = 1`,
`contribute = 3`, `edit = 7`, and `manage = 15`. Contributors can change
records and upload record attachments. Editors can change documents, page
metadata, table schemas, and Applet source. Managers can share, delete tables,
move across permission boundaries, and manage Trash. Space-root page creation
requires `page_edit`. Human-driven Agent work uses the intersection of the
Human and Agent bits.
Page grants are rows in `permission_grants`. The general Console grant API
cannot create, change, or delete page authority. Tenant creation initializes
the space policy once. Reads and scaffold repair do not restore removed grants.
Tenant initialization seeds default Pod pages only when the tenant has no Pod
pages and no page grants.

- Active Human members receive the space's default role. Guests receive
  explicit shares and have no default space role.
- A Private root belongs to its Human member. Guests cannot enter Private
  space. Console grants do not authorize Private access.
- Agents need explicit space admission or a Page share. Human-derived Agent
  work also requires the Human's current Page permission, including Workflow,
  scheduled, and Background Agent Job work. Service autonomous work uses the
  Agent's Page permissions.
- A Page with inheritance disabled stops its parent's container grants.
  Local grants still apply. A deleted ancestor hides all descendants.
- Editors can move a Page when its subtree keeps the same permissions.
  Conditional grants or cross-subtree Userset cycles require `page_manage`
  when the move crosses an ACL boundary. A change between Space and Private,
  or between Private owners, also requires `page_manage`.
- Guest collaborator search returns direct-share candidates only when both
  Principals have effective `page_view` on a common Page in the request
  snapshot. Conditions and Guest Private restrictions apply to this check.
- Lists, search, favorites, recents, embeds, and file reads check current
  access. Inaccessible Userset sources expose an ID and `accessible: false`,
  with null title and icon.

Each Page stores `acl_anchor_id`. Roots, Pages with local grants, Pages with
inheritance disabled, and trashed Pages are ACL anchors. An anchor points to
its nearest parent anchor. A pass-through Page points to its nearest anchor.
A `container` grant applies to the Page and inheriting children. A `self`
grant applies to the Page only. A Userset adds the audience that has a named
action on its source Page. These rules combine by positive union.

The Kernel evaluates Principal, group, and request conditions. PostgreSQL
computes reachable anchor permissions with recursive `UNION`. The result is
local to one request. Point checks load the target anchor's ancestor and
reverse Userset dependency graph. Each authorized read uses the same reachable
permissions for result selection and metadata. A cycle
without a seed grants no permission. Topology
writes update pass-through descendants only when their anchor identity changes.
The recursive update stops at the next anchor and locates target rows by ID.
Indexes on `tenant_id` with `acl_anchor_id` or `parent_anchor_id` support
foreign-key checks for live and trashed Pages.

Navigation uses the Page resource's Ash keyset pagination over position and ID. Root
queries use `parent_id IS NULL`; child queries use equality. Covering indexes
support both forms and include `private_owner_uid` for the root scope filter.
Page timestamps use `Ankole.Ash.Types.Timestamptz`, which maps microsecond
`DateTime` values to the stored `timestamptz` type. Native Ash filters use the
same type as the live-page index predicate.
Search matches page titles and document plain text within the visible page
set, ranks title similarity first, and returns at most 30 Pages. Trigram
indexes support selective title and body matches. Shared
Pages can be visible while their parent is hidden.
Move destination search supplies `exclude_subtree_of`. The server excludes
that Page and all its descendants before the result limit, including descendants
whose ancestors do not match the search text.
Move, copy, and saved-artifact destinations also supply `required_action=page_edit`.
Base copies start with the source parent as the destination. If that parent is
not editable, the caller must select an editable destination before submission.
The search checks both view and edit access before the result limit. Ordinary
search uses `page_view`.
List text queries match titles and document bodies within the requested
scope before the 200-result limit.
Favorites and recents select visible live Pages before the limit and sort by
the person's favorite or visit time, with the Page ID as a tie-breaker.
The Trash list selects top-level deleted Pages in deletion-time order. It
checks candidate batches before it applies the 200-result limit. Each candidate
ignores only its own tombstone during the permission check; other deleted
ancestors remain hidden.

Agent writes check and lock the actual RunRef or Job attempt in the transaction
that commits the content. The RPC broker passes this authority from the
authenticated turn. A delayed file relay cannot commit after that turn closes
or its attempt is replaced.

### Persistence and transactions

The root module `Ankole.Pod` is the Ash domain. Its durable resources are `Page`,
`PageContent`, `PageChange`, `PageUserState`, `BaseTable`, `BaseField`, and
`BaseView`, and its `*.Browser` resources serve `/api/v2/pod` JSON:API routes.
The browser actions validate query operators as finite enums, then convert
them to the JSON strings consumed by the shared Base query contract.
Each Pod operation that writes, or reads under a row lock, runs in
`Repo.transact_top_level/2` in its owning module (`Ankole.Pod.Pages`, `Pages.Sharing`,
`Documents`, `Files`, `Applets`, `Bases`, and `Jobs.PurgePage`). Its first
step takes the Pod tree lock for topology and sharing writes, then checks and
locks the Agent's turn. Content and record writes do not take the tree lock.
The `*_in_tx` functions run the write steps; another Pod operation can call one
of them in its own transaction, as a Base copy calls `Pages.create_in_tx/1`.
Broadcasts to the page, access, and table topics run after commit
(`after_commit`), and only when the transaction succeeds.

`Ankole.Pod.Access` owns ancestor paths, reachable anchors, and access
provenance. Its native SQL read model loads paths and reachable anchors.
`Ankole.Pod.Pages.Queries` owns directory cursors, title and body search, list scopes,
and version snapshots. The `all` list includes visible child Pages. Search
results include authorized ancestor breadcrumbs. `pages.children` and
`pages.search` expose these directory contracts to Agents. Each SQL branch
binds the tenant.
`Ankole.Pod.Pages.Sharing` owns sharing changes, collaborator selection, and
Space access settings. `Pages` owns tree writes, page details, and personal state.
AuthZ owns Grant persistence and calls anchor maintenance for affected targets.
Base sharing offers view, contribute, edit, and manage roles. Other Page types
offer view, edit, and manage. A non-Base Page rejects a contribute-only grant
that applies only to itself; a container grant can pass record-write access to
Base children. Adding a collaborator, changing a role, or removing a grant
saves that change immediately. Conditional rules,
Usersets, and partial action sets show their exact actions as read-only entries
with a revoke action. An unchanged entry preserves its action set. An explicit
role change expands that role into its actions. A write supplies a role or an
exact action set. If both are supplied, they must describe the same action set.
Agents read `pages.sharing` and write `pages.set_sharing` through the same
`page_manage` and version checks as the browser. Sharing saves use the current
sharing version and one transaction. The Space default role comes from the
unconditional `all_humans` rule; conditional rules keep their own scope.

Pure multi-page reads use `Repo.transact_repeatable_read_only/1`. Its first
statement sets `REPEATABLE READ, READ ONLY`. SQL Sandbox savepoint tests use
the outer test transaction. Committed concurrency tests use the full isolation
contract. Reads that need row locks use `READ COMMITTED`. They acquire the
Page or table lock before authorization and before loading protected data.
`Bases.query` locks inline metadata for share and physical metadata for key share.
The inline share lock keeps records and their version in one consistent read.
`Copy.table` locks source tables in ID order for update before it checks source
access.
Page state reads use the same repeatable-read snapshot for authorization and
state. Favorite and visit writes lock the Page for share before authorization
and commit the state in that transaction.

Each content table carries `tenant_id`. Composite foreign keys prevent a
reference to another tenant. `Ankole.Repo` requires an explicit tenant context.
Tenant deletion removes records and other children in batches before pages.

Deletion marks a page as trash and hides its subtree. A scheduled purge starts
after `pod.trash_retention_days` (a positive integer number of days, default 30,
or `"unlimited"` to retain trashed pages without automatic purge). The purge
marks its start in the same transaction that checks eligibility. Restore is
rejected after that mark.
The purge job marks and cleans each Base table through the Base cleanup contract.
It then removes page resources, file references, grants, and child pages in
bounded batches. The root stays present until cleanup completes, so an
interrupted job can resume from the remaining resources.

## Documents and collaboration

`Ankole.Pod.Documents` owns revisions and writes. Ash resources own the persisted
Page, PageContent, PageChange, and PageUserState facts. Their create, update,
and destroy actions run in the caller's transaction. Page
revision increments run as database expressions. PageChange entries are
immutable; the write transaction appends and prunes them with the content
update. Favorite and visit upserts change only the
fields that the caller supplies. The tree lock and AuthZ proof belong to
the aggregate transaction.

`page_contents` stores
canonical page-tree XML and derived plain text. The Rust kernel validates the
same XML vocabulary and normalization as `@ankole/block-editor`. The complete
path is XML to document, normalization, ChangeSet application, normalization,
and document to XML. A write is rejected if reading its XML back changes the
submitted document. Limits are 8,388,608 UTF-16 units, 100,000 nodes, and depth
128. Browser transactions enforce the same bounds before replacing the current
document or undo history. Rejected input leaves the last legal draft editable
and surfaces an error. A merged remote/local document that exceeds a bound
keeps that draft and uses explicit reset/reload recovery.

An Agent reads Markdown and its page revision with `ankole-pod pages.read`.
Page reads hold a shared page lock through the content read. Revision replay
uses the same lock and ends at the revision read under that lock.
The Worker uses the editor parser and printer for `pages.write`. The control
plane validates the XML before the write transaction. The transaction checks
write authority. Under the page lock, it checks page access, type, and
`base_revision` before it returns an XML validation error or commits the parsed
document.
XML bytes cross the signed WorkerFiles relay. They do not consume the
RuntimeFabric RPC payload budget. `Documents.write` computes a ChangeSet under
the page row lock. Rust aligns unchanged blocks, then changed child nodes and
text with Myers diff. Text offsets count UTF-16 units and cannot split a
surrogate pair. The kernel checks that applying the changes reproduces the
target document. The transaction writes a `change` entry with
`client_id = "server:" <> principal_uid` and `client_seq = new_revision`.
The browser cannot use the reserved `server:` client prefix. A write with no
content change keeps the current revision.

`pages.append` appends the supplied Markdown blocks under the same revision
check and diff path. `pages.patch` reads Markdown at `base_revision`, applies
exact text replacements, and submits the resulting XML with the original
revision. A missing match or an ambiguous match without `replace_all` rejects
the patch. A concurrent commit returns a revision conflict.

A browser tab owns one authenticated Phoenix socket at `/pod/socket`. Its
frame and fragmented-message limits are 32 MiB, so valid Unicode documents can
cross the transport. The tab's `content` topic uses the existing tenant
content-access notifications to refresh its active content queries. It checks
admission and refreshes after join, reconnect, and the periodic access check.
A temporary token-service failure retries the subscription; access denial ends it.
Ancestor and Space policy changes refresh effective actions even when the
Page's content revision stays the same. Query refresh preserves the current
document editor and its local draft. Document editors use `page:<id>`. Each client has one
immutable batch in flight, identified
by `client_id` and `client_seq`. Before submission it applies `preparePageUpdate`
to its own document and includes the normalization correction in the batch.
The server accepts a batch once. Reusing its client sequence with different
changes returns a conflict. An unknown result retries the same request.
When a broadcast confirms a batch before its request completes, later edits
wait for that request to release its slot, including after a transport failure.
An explicit stale result supplies missing changes without committing the batch;
the client rebases, prepares the pending edits again, and uses a new sequence.

`page_changes` retains the last `pod.ot_replay_window` batches (default 1,000).
Pruning occurs in the write transaction. A client outside the window reloads.
Replay also respects the 32 MiB transport budget; an oversized replay
requires a reload instead of constructing a response that cannot cross the socket.
A reset or unavailable replay keeps unconfirmed edits as a recoverable draft.
The PageDraft model accepts only the current recovery read. A later read, a
source change, or editor disposal revokes an earlier read. A response cannot
replace edits made during its request or reduce the acknowledged revision.
The component rebuilds the editor only for an accepted response. Failed reads
keep the draft available for export and retry; recovery copies remain until
the user discards them.
The log is an OT transport window, not a user-visible version history.

ACL, tree, Pod login policy, and Guest access changes recheck topic membership
immediately. A reconnect, return to a visible tab, or the 60-second version check
repairs missed broadcasts.
Acknowledged state is already committed before a broadcast.

The editor keeps a composing text node when a remote text edit uses the same
marks. It maps both ends of that node through the pending changes and updates
only the changed UTF-16 range in the DOM. This preserves the browser's native
composition markers and the caret when a prefix changes. Structural changes or
incompatible marks use the editor's composition cancellation path.

The editor host resolves `embed` and `ankole:asset/<full-sha256>/<name>`.
Creating an inline page first creates its child in the tree. Deleting its direct
child embed through the block menu trashes that child. Removing a reference with
a selection or an Agent document rewrite leaves the page in the tree.

## Base

Base page navigation starts the table list and first table schema reads while
the editor modules load. Navigation and the editor use the same query cache;
the editor displays read failures and provides retry controls. A page visit
updates its recent-page entry once, including when development effects replay.

`Ankole.Pod.Bases` owns table schemas, record writes, and queries. Tables,
fields, and views are Ash resources. They share their Base page's access and
lifecycle. Each table has one primary text field, at most 200 active fields,
and at most 100,000 records. A primary value uses at most 2,048 UTF-8 bytes.
The primary field permits name and position changes; its type is fixed as text.

An independent table with at most 2,000 records and 4,194,304 stored data bytes
uses `inline` storage. Its records live in `base_records` in the control-plane
database. The generated `data_bytes` column measures `octet_length(data::text)`;
the write transaction sums those integers into `base_tables.record_bytes`.
These thresholds are fixed system constants. Each inline write locks only its
own metadata row `FOR NO KEY UPDATE`, and commits records, field versions,
auto numbers, counters, and its data version in that database.

Crossing either threshold, or creating any link, promotes a table to `physical`
storage. A link promotes both endpoint tables. Promotion is one-way. The
operation takes metadata locks `FOR UPDATE`, imports the records with one JSON
parameter and `jsonb_to_recordset`, and creates the indexes in a single shard
transaction. It then removes the inline rows and marks the metadata physical.
A retry drops incomplete physical tables and their referencing edge tables, then
imports the authoritative inline records. Reads and writes
use the same typed API in both modes.

`Ankole.Pod.BaseRepo` routes physical operations to the tenant's fixed
`base_db_id`. The active `Ankole.Repo` tenant context supplies the schema name
`t_<tenant_hex>`. Physical tables use `tbl_<table_hex>` and columns use
`f_<field_hex>`. Text, number, checkbox, datetime, and auto-number fields use
`text`, `numeric`, `boolean`, `timestamptz`, and `bigint`; structured cells use
`jsonb`. The table's system columns hold its ID, field versions, timestamps,
and authors. Indexes cover the primary key, primary field with `COLLATE "C"`,
auto numbers, and link edges. Text comparisons and sorting use the same `C`
collation as the primary index. Case conversion and `ILIKE` use the database
locale. The tenant's `_table_states` row owns each physical table's schema
version, data version, count, and next auto number.

Physical record writes hold the Agent commit authority and sorted active page
metadata rows `FOR KEY SHARE` in the control plane. They lock the relevant shard
state rows and commit all business changes in one shard transaction. They do not
write control-plane counters. The key-share locks permit inline writes on the
same page. All control-plane locks precede the shard transaction (lock rank 12).
The shard transaction cannot acquire another control-plane lock or connection.
It can read through the control-plane transaction's existing connection.

A record batch has at most 200 operations. A cell update supplies the baseline
versions of the changed fields; deletion supplies the complete version map.
Different-cell edits can both succeed. Each affected table advances once per
batch. Explicit clearing advances a cell version even if the value is absent.
The browser and function SDK assign UUIDv7 IDs to creates in a `RecordWrite`
before sending it. Retrying the same write reuses those IDs; a new `create` call
starts a new operation. The record form keeps its create ID until it succeeds or
the user closes it, including when the user edits a failed submission. A repeated
create ID fails the storage primary-key constraint and rejects the batch with
`record_exists` (HTTP 409). It cannot create a second record or overwrite the
saved values. The user can close the form and review the saved record if the
first response was lost.

Links use ordered `lnk_<forward_field_hex>` edge tables with native cascading
foreign keys. Field configuration records the edge name and `src` or `dst`
role. Both directions enforce their single-value cardinality or a maximum of
2,000 IDs per cell. Each single-value constraint uses its field UUID in its
name, so fields in the same tenant have independent indexes.
Reads return the complete ordered array. A one-way child
link can point to a parent with more than 2,000 children. Deleting one direction
removes that field's cardinality constraint and keeps the counterpart's edge
and values. Disabling bidirectional writes gives
each field an independent edge.

Deleting a linked record updates surviving peer cell versions and timestamps
for at most 2,000 affected records per field. Above that limit, foreign keys
remove the edges, the affected table version advances, and `resync: true`
requests a full client refresh. It does not send a partial cell value.

Field and view changes lock page tables in ID order `FOR UPDATE`. For field
changes, the control plane writes definitions before a single shard DDL
transaction validates the old schema versions, changes physical objects, and
advances state versions. `Bases.Schema` writes definitions through Ash;
`Bases.DDL` owns stored value changes in both storage modes. Physical conversions
read the affected column in batches and stage converted cells in a temporary
PostgreSQL table until the column and edge changes can be applied. The transaction
validates complete record sizes before commit. Type conversion
stops at the first invalid cell unless `clear_invalid` is explicit. Unchanged
select values keep their cell versions when the available options change.
Conversion to a formula or system field removes the stored cell value and
version; reads use the formula or the record's system columns. A physical
field type change refreshes statistics with best-effort `ANALYZE` after commit.
PostgreSQL's 1,600 historical column limit returns an error that asks the caller
to copy the table. Field deletion removes the deleted field from saved view
filters, sorts, grouping, field order, field visibility, and summaries in the
same transaction.

View changes write their definitions in the control plane and advance the
table's data version in its storage database. They publish `schema_changed`
after commit. The data version lets clients detect a missed event when they
reconnect. The physical schema version and relations stay unchanged.

Ordinary shard writes use the control-plane request's 15-second budget; schema
changes and promotion use 60 seconds. A shard deadline is two seconds earlier.
Transaction-local statement and transaction timeouts enforce the remaining
budget; lock timeouts are five seconds for records and two seconds for DDL.
A shard write probes the original control-plane connection immediately before
its commit. A schema-version mismatch rejects access and logs an operator error.

`table_access/3` maps `:read`, `:write_records`, `:manage_schema`, and
`:delete_table` to `page_view`, `page_write_records`, `page_edit`, and
`page_manage` on the host page. A table with incoming links cannot be deleted.
Deletion first commits `deleting_at` and a cleanup job. Ordinary access excludes
marked tables. Cleanup drops shard objects, then removes metadata; `PurgePage`
resumes an interrupted cleanup and also handles deleted page subtrees.

`Ankole.Pod.Formula` parses same-record expressions and generates typed SQL.
Formula values and system fields are read-only. References use field identity,
so a rename does not change the formula. Renames refresh editable source from
the same AST. Field names escape `]` and `\` as `\]` and `\\` in source. Cycles and removal of referenced fields
are rejected. Division by zero returns null. Formula values are calculated at
query time and included in mutation responses; there is no browser formula
engine or stored-value backfill. Each requested formula uses its dependency
graph. SQL evaluates a shared dependency at most once for that result and record;
it does not expand the dependency again at each reference. Dependencies in an
unselected conditional branch are not evaluated.

One transaction journal records the tables and records actually changed by a
batch, including both sides of a link. Each touched table advances once at
commit. Repeated operations in a batch compare against the preceding operation's
actual field versions; an old baseline rolls the whole batch back. Explicitly
clearing a field advances its version even when its value is already absent.
Field conversions validate final record bytes through the same owner as
ordinary writes and commit atomically in their storage database.

`Ankole.Pod.Query` owns typed filtering, sorting, keyset pagination, grouping,
and aggregate SQL. It adds the record ID after explicit sort keys and handles
nulls and mixed directions. Numeric and JSONB cursor keys keep PostgreSQL text
representations; they do not pass through JavaScript numeric rounding. Aggregate
groups return `value_json` alongside display values, and grouped record queries
use that exact JSON value. The group condition is ANDed outside any user filter.
Large kanban views fetch full-table group counts and page each group separately.
A change to grouping, filtering, or sorting starts the board at its first page.
Physical reads hold metadata key-share locks and use one repeatable-read,
read-only shard snapshot for records and `_table_states`. They verify the schema
version before serving data. The statement timeout includes lock waiting.

The shared query compiler uses JSONB expressions for inline records and native
columns and edge subqueries for physical records. Array equality checks JSONB
equality as well as containment. Author system fields accept a single Principal
UID or a UID list in equality and membership filters. Statistics support
up to two group fields and date buckets in `system.timezone`. A count without
a field counts rows; a count with a field counts its non-null values.

A small table can be fetched in full for browser evaluation. The browser uses
local operations only where they reproduce PostgreSQL semantics. It sends
numeric comparisons, numeric formula operations, sum, average, and operations
that depend on an unsupported database locale through the server query
or aggregate path. PostgreSQL `numeric` precision is not replaced by JavaScript
Number arithmetic. The server reports locale capabilities with the schema;
shared fixtures cover both results and the route selection.
Local evaluation requires the schema and complete record snapshot to have the
same data version. A mismatch invalidates both cached reads and uses the server
path for the current request.

The built-in views are grid, kanban, and gallery. They are records browsers:
they share the table query, record writes, permissions, and realtime updates,
and differ only in presentation. A built-in view type must be a way to browse
the same records. Calendar, timeline, form, and chart presentations are Applets;
they introduce time-axis, public submission, or encoding semantics that do not
belong to the Base contract. An Applet that presents a table reads and
writes through the same Base API.
New kanban views use the first single-choice field when one exists. The grouping
control lets the person change it. Kanban and gallery cards show the primary
field as their title and the fields selected for that view. Record details
include every field.

View changes use their own versions. Dragging in kanban writes the related field
through the ordinary record contract. Inline views keep their configuration in
the document embed. The host validates this configuration before rendering a
view; invalid input remains available for repair. An embed with an unsupported
view type offers the same repair to grid.
New fields, reverse fields, and views append after the last position by default.
An explicit position is authoritative. These writes use the table
locks; a new self-link also reserves its uninserted forward field's position.

`base.copy` creates an independent `base` Page and table at a Space or Private
root or under a target parent Page. It applies
the source filter, assigns new IDs, and adds references to existing attachment
bytes. Source metadata locks keep the copy stable. Records move in batches
through a temporary control-plane table, then into their destination storage.
The temporary table belongs to the copy transaction. Only the selected table
is copied. Each link becomes a text field with the referenced records' primary
field titles, joined with a comma and space in link order. An empty link becomes
null. The copy reads only the referenced titles in each selected record batch.
Copied formulas refer to the copy's own fields and are checked against their
new types. A formula that cannot use the new types becomes an ordinary field
with its current result. Array results become JSON text; scalar results keep
their value type. Other formulas continue to calculate from the copied fields.
View configuration remaps field references and keeps business values. When a
field's value type changes, its filter conditions keep only `is_empty` and
`is_not_empty`. Later source edits do not change the copy. Copies that fit the
fixed inline thresholds use inline storage; larger copies are created directly
in the tenant shard.

`pod.base.limits` has these configurable defaults:

| Key | Default |
| --- | --- |
| `query_rows` | 1,000 |
| `record_bytes` | 1,000,000 |
| `group_count` | 1,000 |
| `statement_timeout_ms` | 5,000 |

`query_rows` bounds ordinary query pages. Both storage modes support local
snapshots with at most 2,000 records and 4 MiB of serialized records, including
formula results and record metadata. PostgreSQL checks the projected size
before sending records to the browser. The schema reports this eligibility
separately from the storage mode. The browser refreshes schema before merging
a record delta and invalidates its snapshot on promotion or `resync`. Limits reject excess input
or results explicitly.

## Files and Conversation origins

`Ankole.Files` owns one site-wide blob store and `drive_files` references.
An Agent drive uses its UID; the Pod drive uses a null `agent_uid` in the same
table. A unique index treats nulls as equal. Pod references live under
`pages/<page-id>/`. `Ankole.Pod.Files` authorizes their page before access.

A file-page replacement commits its bytes and revision together. Document assets
and Base attachments use the full digest in their path. Removing a document
reference leaves its asset available until page purge. See [Files](Files.md).

File pages preview PDF, images, audio, video, workbooks, and presentations.
Workbook and presentation previews load their libraries on demand and read bytes
through the authorized file URL. They do not send files to an external viewer.
Workbooks support sheet selection; presentations support slide selection. The
download keeps the original file. Preview fidelity depends on the supported
format features and installed fonts; online Office editing is outside this
version.

A native Conversation message carries page links and verified attachments.
Humans can upload, paste, and drop files without creating a Page. The
Files owner stores bytes; accepted Messages keep canonical attachment facts.
Each message gets its own incoming file paths so later Agent edits cannot change
the bytes received by a subsequent message. Download checks current Chat
membership and reads frozen bytes. Losing Page access prevents new Page-context
input but does not revoke a participant's personal Chat attachments.
Unsent local Files survive panel and route changes; refreshing before acceptance
requires choosing those local files again. The unload guard protects that draft.
Images and text can open in a read-only dialog in the same Chat. The dialog uses
the authorized attachment URL, restores focus when it closes, and
keeps the download and new-tab actions. Text previews read a bounded
prefix and identify incomplete content. Closing the dialog cancels its request
and releases preview data. Previewing a file does not create a Page.
Saving an attachment to a file page uses the visible message's blob reference;
it does not grant access to the Agent's whole drive or copy blob bytes. Replacing
the source drive path cannot change the saved message attachment. A page keeps
`saved_from_message_id`. A deleted source is shown as deleted; an inaccessible
source exposes no Conversation metadata. Deleting a Conversation leaves pages
and their Pod file references intact.

For an Agent-created Page, the RPC broker defaults this source to the current
input's message. A Job completion wakeup follows its persisted Job to that
message. Continued Jobs keep this source across further wakeups unless a new
Human message starts the continuation. Source lookup stays within the Agent
and tenant and stops when a Job repeats or no message can be found.

## Applets

`ankole-pod applet init`, `build`, `publish`, and `pull` use one React ESM
project contract. Bun builds the browser entry at `dist/main.js`, shared chunks,
CSS, and `dist/index.html`. Seven host modules use an import map: `react`,
`react/jsx-runtime`, `react/jsx-dev-runtime`, `react-dom`, `react-dom/client`,
`@ankole/uikit`, and `@ankole/applet-sdk`. Other NPM packages are bundled with
the Applet. Dynamic imports and WASM use browser module rules. Source files named
`*.worker.ts` or `*.worker.js` build to matching `*.worker.js` entries under
`dist/`. Import a Worker URL with
`import workerURL from './calculation.worker.ts?url'`, then start it with
`new Worker(new URL(workerURL, import.meta.url), { type: 'module' })`.
JavaScript media imports emit standalone assets and resolve their URLs against
the importing module. A Worker URL import emits an entry that loads the compiled
Worker at its original output path, so nested resource URLs keep the same base.
CSS asset processing follows Bun. The project scaffold supplies the URL import types.

An Applet runs in a same-origin iframe at
`/pod/applet-frame/:authentication_ref/:id/:revision/*path`. The path selects
one sealed browser authentication proof for the document and its subresources.
Changing the browser's default account does not change that selection. The
frame has its own DOM, CSS, viewport, and module map. The workspace scroll
panel sets its viewport height; long Applet content scrolls inside the frame.
The frame follows panel size changes. It shares the host origin and trust
boundary. The host injects the runtime before the entry loads and scopes storage
keys by the selected Principal UID and page ID. The shell supplies this UID
from the same verified authentication result as its proof. The storage adapter
preserves the frame's Storage prototype, methods, named properties, and key
enumeration. One generation owns the frame's subscriptions,
channels, and observers. A new page revision or unmount closes that generation.
A change to effective actions updates runtime props in the same iframe and
React root. Form input and local component state stay available while controls
follow the new permissions. A denied business operation keeps the frame and its
local state available. Page reads and realtime access checks own the decision
to close a generation when view access is lost.
A publication conflict refreshes the page snapshot; it does not repeat a write.

The frame shell receives the hashed vendor modules and shared styles from the
Vite manifest. Frame responses use precise content types, `nosniff`,
`SAMEORIGIN`, private revalidation, and a content ETag. A shared page lock covers
page authorization, the requested revision, and the immutable file digest.
Blob reads run outside that transaction. A stale revision returns 409.
The host presents Applet failures and one reload action above the frame. The
SDK error boundary reports a render failure to this owner. Reload starts a
fresh generation and clears the host's failure state.

A project can include `src/server/main.ts`. Bun bundles its NPM dependencies
into `server/main.js` and keeps Node built-ins as `node:` imports.
`applet.env.json` is an optional flat string map with a 64 KiB limit. Its values
are supplied as `process.env` in that publication's function worker.
The manifest contains `src/`, `dist/`, optional `server/main.js`, and optional
`package.json`, `bun.lock`, `tsconfig.json`, and `applet.env.json`. Publication
replaces these paths atomically and advances one revision. Content digests must
belong to the publishing Agent's drive or the same page. Route inspection runs
before the page write lock and rejects invalid handlers or top-level host calls.
The inspector receives the published environment for module initialization.

Applet files under `dist/` and `assets/` require `page_view`. Source, backend,
and root project files require `page_edit`; other Applet paths are rejected.
The manifest applies the same filter. File downloads and Worker transfers use
this same owner. Record attachments require `page_write_records`; document
assets and file-page uploads require `page_edit`.

`applet pull` requires an empty or absent destination. It downloads source and
root project files to a temporary directory, checks each digest, and moves the
complete project to its destination. A project with `package.json` runs
`bun install --ignore-scripts`.

The SDK uses the current Human's Pod APIs and a shared QueryClient. One
connection per table coordinates schema and snapshot events and refreshes record
and aggregate queries. The ContentProvider owns the read-denial cache observer
across Applet generations and disposes it when the Pod unmounts.

`useRecords` and `useAggregate` keep live subscriptions. An HTTP 401, 403, or
404 hides cached data on the first denial, including during a Query retry.
Remounts, temporary failures, and pending writes preserve that denial until a
successful read. Subscribers share the denied state and stop joining the
table's channel while it applies. Temporary failures before a denial keep
previous data.

Record updates and deletes use the field versions captured when editing began.
A failed save keeps the attempted value and versions for explicit retry. An
attachment upload ends its cell edit when it settles; the next edit takes the
latest versions. Pending updates preview values separately from the confirmed
cache. Creates and deletes enter results after server confirmation, which owns
auto-numbers, formulas, and membership in filtered or paged results. Failed
creates retain input, and failed deletes retain their confirmation dialog.

`useChannel` uses `applet:<page-id>:<room>` for temporary messages and presence.
The server checks each recipient's authentication, Pod policy, and Page access
before delivery. A failed check ends that subscription. Presence and messages
are ephemeral. Applets can use network fetch; the server owns Page and Base
authorization.

### Backend routes

An Applet backend exports a table of `METHOD /path/:parameter` functions.
Supported methods are GET, POST, PUT, PATCH, and DELETE. Literal path segments
take precedence over parameter segments. Parameters are URL decoded; repeated
query parameters are arrays and bracketed keys stay literal. The handler receives
the method, path, parameters, query, optional JSON body, current principal,
Applet page ID and revision, and tenant timezone. It receives no credentials.
JSON results use status 200; `undefined` uses 204. A handler can throw
`AnkoleRuntime.HttpError` with a 4xx status. Unexpected exceptions use a fixed
browser error; Agent calls also receive bounded diagnostics and console logs.

The HTTP path is `/api/v2/pod/pages/:id/routes/*path`. It uses the
ordinary Pod login and CSRF checks and requires `x-ankole-applet-revision`.
Admission reads the authorized Applet revision and immutable backend package
under the same page lock. A stale revision gets 409 `applet_revision_changed`.
The host rereads the Page and replaces its loaded publication. It does not
replay a failed mutation. Agent RPC `applets.call`, exposed by `ankole-pod applet
call`, uses the same invocation owner with the Agent's current write authority.

`ankole-function-runtime` is a stateless service built from Supabase Edge Runtime
`v1.77.4`, commit `d4a4f606a90e8c66864219c9b1d31ef0e3e3f626`, with the native
patches in `app/function_runtime/native/patches`. Its main worker authenticates control-plane
requests with an internal Bearer token. Applet user workers receive only their
published environment. Workers are pooled by tenant, page, and revision for at most
five minutes. `AsyncLocalStorage` binds each request's capabilities,
logs, and cancellation to its own WebSocket.

Code and environment form one immutable SHA-256 cache identity: UTF-8 source,
a newline, and compact JSON of the environment key/value pairs sorted by
UTF-16 key code units.
A plain HTTP invoke preflight on the selected replica returns 204 and reserves
one invocation, 428 for missing code, or 503 at capacity. The client supplies
missing code to that replica and opens its WebSocket. The client settles the
reservation with an authenticated DELETE when the connection ends; the call's
wall-time limit bounds an abandoned reservation. Health reports process
availability independently of occupied invocation capacity.

The client resolves all Ready replica addresses and chooses the least occupied
endpoint from its active process leases. An explicit release or caller exit removes
that lease. Only a connection failure before admission or a preflight 503 permits
one switch to another replica. Executed code and capability writes are never
replayed. `Ankole.Pod.Applets.Invocation` owns the call and all capability tasks.
Caller exit, cancellation, timeout, and connection loss settle that owner once
and stop its pending tasks.

While an Applet response is pending, the HTTP/1 connection buffers at most
1,048,576 bytes of pipelined request data. The total includes the initial
transport buffer and all data received before the response. An overflow closes
the connection and cancels the invocation. Already committed capability writes
remain. Pipelined requests within this limit keep their bytes and order.
An HTTP/2 stream reset cancels the invocation through its transport reset message.

`pod.applet.limits` sets the wall-time and heap bounds. The function service
also enforces per-worker CPU limits. Applets can use Node crypto, a private
temporary `/tmp` filesystem per worker, environment values, and public network fetch. The function service
has no database credentials or persistent business volumes. Its deployment
network uses the Helm NetworkPolicy to block the configured private and metadata
CIDRs when the cluster enforces that policy. Single-host Compose puts the
service and control plane on `ankole_functions`; PostgreSQL uses the separate
internal `ankole_backend` network. The function service can reach the control
plane on that shared bridge. The host firewall and cloud instance metadata
settings control its other network access. The Elixir control plane owns every
durable business write.

Each user worker owns a native execution thread and can create a Tokio blocking
helper. A CPU loop cannot occupy another worker's execution thread. The native
supervisor deducts cumulative CPU use at each poll and enforces the absolute hard
limit, including when the soft and hard limits are equal. Resident worker count
and admitted request count are separate resource costs.

Inspection and PTC use exclusive one-shot workers with immediate retirement.
PTC reports execution failure as a JSON outcome over HTTP 200. Memory limits
report `program_heap_limit_exceeded`; CPU and wall limits report `program_timeout`.
A worker shutdown ends its child request and preserves the main worker's response.
An HTTP caller disconnect settles the native request once and terminates an
unowned one-shot worker, including synchronous JavaScript. Applet cancellation
settles its control-plane invocation and capability tasks. An aborted invocation
removes its worker from pool selection before the control plane reports completion.
Existing calls on that worker can finish, and subsequent calls use a fresh worker.
Synchronous Applet code can continue on its own thread until the CPU limit.
A call that reaches its deadline returns `504 handler_timeout`, including when the native socket closes
at the same time. The call deadline includes replica admission and worker startup.
An expired call cannot start a handler.

`AnkoleRuntime` capabilities call domain owners with the caller's
identity and tenant: `base.schema`, `base.query`, `base.aggregate`, `base.write`,
`file.list`, `file.read`, and `file.write`. Each call repeats authorization;
all calls require `page_view` on the Applet. Writes require the action on the
target resource: `page_write_records` for records and record attachments, or
`page_edit` for file content. They also enforce current RunRef or Job authority.
The frontend SDK exposes the Applet Page's effective `actions`; the target
Base API owns record-write authorization. GET handlers cannot write. Base writes keep
field-version conflicts and normal broadcasts.
There is no transaction across capability calls. A guarded inventory update
reads the record, writes with its field versions, and rereads after a conflict.
Files use the page-type and revision rules. Both reads and writes enforce the
Worker transfer byte limit before loading or storing file content. Byte values
in the handler are `Uint8Array`, including empty files.

`ai.generateText` resolves an LLM profile of the Agent recorded in the Applet
Page's `created_by`. It accepts `model`, `effort`, optional `system`, and
`prompt`, and returns `text`, `finishReason`, and token `usage`. It rejects raw
provider/model identifiers. Missing `light` falls back to the primary profile.
The creator Agent's token quota applies and usage belongs to that Agent.
An unavailable creator Agent yields `ai_not_configured`. Model and effort errors
use 422, an exhausted quota uses 429, and unavailable providers use 502.

`useRoute` and `useRouteMutation` are thin TanStack Query hooks. They expand
declared route parameters, preserve Query options and result objects, and use
the loaded publication's revision and identity in the route cache prefix.
Queries abort on unmount and hide cached data after an authoritative 401, 403,
or 404. Temporary failures keep prior data. Route writes have no optimistic
update or automatic invalidation. The Applet chooses which queries to refresh
with its shared QueryClient and `routes.key()`.

Backend routes do not create Pages or schema, schedule work, receive events,
access host connectors or host secrets, stream responses, or return binary HTTP
bodies. Source, backend code, and publication environment values require
`page_edit` permission to read.

An Agent's Worker browser has its own profile and uses the browser runtime
contract for rendered checks. The Agent returns the saved Page link and reports
which interactions it verified.

## Verification

The domain, endpoint, channel, SDK, query, and editor suites check their owning
contracts. Integration suites use independent PostgreSQL transactions for
concurrency, purge, tenant teardown, and large-table measurements. The shared
Rust/editor corpus compares XML and editor documents after each edit batch.
The function-runtime protocol suite checks real workers and cancellation.

`test:pod` follows browser user flows through the production Pod, SDK, Phoenix
endpoints, and PostgreSQL. The `pod_content_real_llm` suite starts with a Human
request, lets the Agent create and deliver content through the Worker CLI,
and checks the delivered result in an authenticated Human browser. See
[Pod content checks](../../CONTRIBUTING.md#pod-content-checks) for commands and
fixture requirements.

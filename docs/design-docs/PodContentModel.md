# Pod Content Model

In a Pod, a Conversation captures the collaborative work process while a Page
stores the durable result. Humans and Agents read and edit the same underlying
pages, documents, and business tables through shared domain contracts.
PostgreSQL is the single source of truth for pages, documents, Base records,
revisions, permissions, and file references; Worker files, browser caches, and
channel presence are ephemeral projections rather than durable state. Agents can
also build and publish Applets as custom interfaces over a Base, where every
business operation runs under the signed-in Human's permissions.

## Browser interactions

Use Notion as the default interaction reference for pages, trash,
properties, and views—and Feishu Wiki as the reference for the two-level Page
sharing popover—covering loading, empty, pending, failed, and concurrent
editing states while preserving Ankole's UI components, visual identity, and
first-version domain scope. See Notion's guides on
[views and filters](https://www.notion.com/help/views-filters-and-sorts),
[properties](https://www.notion.com/help/database-properties), and
[trash](https://www.notion.com/help/duplicate-delete-and-restore-content).
Presentations such as calendars, timelines, forms, and charts belong in Applets
rather than built-in Base views.

### Page creation, editing, and navigation

Creating a Page opens a non-modal menu offering document, Base, and file
options:

- **Documents and Bases** open immediately at the chosen Space root, Private
  root, or parent Page. Inserting a child document from inside a document body
  inserts an inline `<mention page="…" />` reference at the caret and opens the
  child document once saved; inserting a child Base inserts an interactive
  `<embed ref="…" />` block, and Agents create and publish Applets
  through their conversation workflow.
- **File pages** prompt for a local file first, then submit its bytes and Page
  attributes to `POST /api/v2/pod/file-pages`, which creates the Page and file
  reference in a single tree transaction (defaulting an empty title to the
  selected filename). If creation fails, the UI keeps the form entry open for
  retry.

Users edit Page titles at the top of the canvas. Document titles and bodies form
a continuous writing area, with synchronization status and online participants
in the Page header.

Page titles and document bodies share one recoverable draft and unsaved-changes
navigation guard: failed saves keep the user's input, and attempting to navigate
away with unsaved edits lets the user continue editing, download the draft, or
discard changes and leave.
While any dialog submission is in flight, the dialog preserves its inputs and
blocks dismissal. Document titles auto-save after 500 ms of idle typing and on
blur (deferring auto-save until any active IME composition finishes). Pressing
Enter or Tab in a document title, or pressing Down on its last visual line,
moves the caret to the start of the body, and pressing Up at the start of the
body moves it back to the end of the title. Assistive technology receives normal
save-status announcements, save failures expose an explicit retry control, and
the block controls occupy the left gutter outside sequential Tab navigation.
The gutter remains reachable as the pointer crosses from text to the controls,
and the caret uses the same rendered coordinates as the text.

Clicking the blank canvas below the last document block, including the side
gutters, creates and focuses a root paragraph. If the last root block is already
an empty paragraph, the editor focuses it without adding another block or undo
step. Other block types receive a separate paragraph. The empty paragraph at the
caret displays the typing hint. Clicking beside an existing line positions the
caret on that line, and dragging from the blank canvas selects blocks. Creating
the paragraph and typing into it are separate undo steps.

An empty paragraph exposes a left `+` that opens the insertion menu for that
paragraph. Blocks with content or an assigned type expose their type icon instead;
list items show their bullet, numbered, or task type. Clicking the type icon or
the adjacent grip opens the same block menu without changing the document. Its
conversion submenu marks the current type. The Add below action creates a writable
paragraph below the target (above with Alt/Option-click) and switches the same popup
to insertion choices, keeping its original anchor. The menu offers editor block
types (including inline `@` mentions and file uploads) followed by child Document or Base creation and **Embed Base or app**. Dismissing
insertion keeps the prepared paragraph ready for typing. The grip also drags the
block, including its nested children, to a visible insertion boundary. Multiple selected blocks move
as one group, including selections that cross list boundaries. Dragging preserves
each block's type: a paragraph dropped between list items splits the list, while
a list item keeps its marker. Moving right below a parent block nests the dragged
blocks; moving left lifts the drop boundary through parent levels. Dragging near
the scroll container's edge reveals further drop targets, and Escape cancels.

Document menus use the shared UIKit alumina ceramic material: a translucent
surface that diffuses background colours, with soft directional lighting, fine
edges, and a restrained shadow. The dark theme balances translucency with a
denser tint to keep labels legible. Slash, insertion, conversion, and block actions
share a 272 px surface and 36 px rows. The block catalogue has one owner for its
options, search, grouping, and 22 px icon slots. Only the slash state adds raised
icon tiles with a coloured light for each block type; other states use plain 16 px
glyphs. Single-line rows and muted group labels separate basic blocks, layouts, and additional content. Search
fields, action menus, and the emoji picker share the surface and focus treatment.
Menu search and link fields select the UIKit
`overlay` input variant explicitly. Input and InputGroup own their size, focus,
and validation appearance; placing a regular field inside a popover keeps its
regular appearance and caller-provided sizing.

Escape selects the current block. Shift+Up/Down and Shift-click extend that
selection across paragraphs and list items without including unselected siblings.
Dragging from page whitespace selects the blocks the rectangle intersects. Each
parent and child has its own hit area: selecting a parent includes its children,
while selecting a child alone leaves its parent unselected. Across columns, only
intersecting blocks are selected; unselected blocks between them stay untouched
when the user deletes, replaces, copies, or moves the selection. The selection keeps
its document origin during wheel and edge scrolling, and Escape cancels the gesture. Dragging
inside text selects characters.
Command/Control+A selects the whole document, and Enter edits the first
selected block at its end. Duplicate, move, delete, and block-menu commands act
on the selected group. Command/Control+Enter toggles selected tasks together,
using the inverse of the first selected task's state. List-type changes affect only the selected items, while
Undo restores each structural action in one step. The editor specification in
`libs/ankole-editor/SPEC.md` owns the remaining keyboard and block contracts.

Ordinary paragraphs and headings can own child blocks. Tab creates a structural
parent-child relationship, represented by `<block>` in Page XML: its first block
is the parent's own content and subsequent blocks are its children. Shift+Tab
lifts a child; following siblings become its children. Enter in a parent's text
transfers its children to the new sibling. Duplicating, deleting, or moving a
parent includes its descendants, and conversion between ordinary blocks and
list items preserves that relationship. The browser and Kernel share this
representation, so saving and reloading restores editable nested blocks.
The first list item can also nest under the ordinary block before its list.
Tab moves only the selected leading items, and Shift+Tab lifts them with their
markers while making subsequent child blocks children of the last lifted item.
Enter in an empty list child lifts that item one level with its marker.
When a selection spans columns or separate runs, Tab moves the selected blocks
together below the first selected block's preceding sibling. Existing children
stay before the moved blocks. Shift+Tab lifts each run within its own parent;
root blocks stay in place. Unselected blocks and column boundaries remain intact,
and the selection follows blocks that acquire children during the operation.

The heading catalogue covers H1 through H6, with H1 smaller than the Page title.
Readers can fold each heading's section up to the next sibling heading of equal
or lower level. Fold state belongs to that editor instance and never modifies
the document. The slash menu searches translated labels and multilingual aliases,
so Chinese and English names can select the same block in either interface.

Media blocks store image and video addresses in `<media>`, and webpage cards
use `<bookmark>`. Each block persists its display metadata and view in Page XML.
Media blocks offer link, card, and preview views; webpage cards add a title view
and let editors enter the title, description, and cover image. Ankole uploads
image and video bytes through the Page's existing asset contract before storing
`ankole:asset/<full-sha256>/<name>` in the block.

Every other file belongs to its own File Page. The **File** entry in the `/` and
`+` menus opens an upload panel at the caret; each chosen or dropped file becomes
a File Page child of the current Document, and the document body stays unchanged.
Pasting or dropping files into the document routes each file by type: images and
videos become media blocks at the drop point, while other files become File Page
children through the same path as the upload panel. The new children appear in
the subpages directory below the body. Files upload one at a time, and a failure
stops at that file while the children created before it remain.

External embeds use `<embed href="…" title="…" />` and render an iframe,
deriving provider URLs for Figma, YouTube, and Vimeo while preserving the original
link. The external site controls whether its content permits framing. Internal
live embeds use `<embed ref="…" />` (with optional `table` and `view` on Base
embeds) for interactive non-document Pages (`base`, `file`, and `applet`):
editors insert them either by creating a child Base or by choosing **Embed Base
or app** from the document `+` menu, which queries `GET
/api/v2/pod/pages/search?embeddable=true` so Document Pages never appear as
canvas embeds.

Resource forms submit only edited fields, preserving concurrent updates to the
other fields. Replacing a source removes its old MIME type, size, and explicit
media kind; uploads supply fresh metadata. Preview and portable export choose
the explicit media kind first, then the MIME type, then the URL. Copying resources
provides images or links to other applications and a title with an address in
plain text, while internal paste preserves the full resource metadata.

Authors reference existing Pages (`doc`, `base`, `file`, `applet`) and tenant
Principals inline by typing `@` or `＠` (when not preceded by `[A-Za-z0-9_]`),
selecting **Mention or reference** from the `/` or `+` menu, or pasting a bare
same-origin Pod Page URL. While the author types after `@`, focus stays inside
the document text and an alumina ceramic overlay filters **All**, **Pages**, and
**Principals** (`GET /api/v2/pod/mentions/candidates`). `Ankole.Pod.Pages.Mentions`
ranks Pages and Principals independently within their own domains; the **All**
tab caps its first screen at six grouped candidates (up to three **Pages** and
three **Principals**, backfilling from the other group when one group has fewer
than three matches) so both categories remain visible without scrolling while
individual category tabs list up to twenty matches. Selecting a candidate
commits an atomic self-closing `<mention page="<uuid>" />` or
`<mention principal="<uid>" />` leaf with zero side effects: Ankole sends no
notifications, grants no permissions, and wakes no Agents. Readers resolve visible mention targets in microtask-coalesced batches through
`POST /api/v2/pod/mentions/resolve`, which enforces `page_view` per Page
(evaluating trashed Page targets in a single batched ACL graph query) and
`Access.collaborator_scope/1` for Guest directory isolation. When a caller has
Guest collaborator scope, `Mentions` restricts Principal search and resolution
to collaborators who share effective `page_view` on at least one live Page
(whether through direct or inherited ancestor grants) or contributed to the
context Page, and omits `email` and `job_title` from both search matching and
returned Principal records so external Guests see only display names and
avatars for human peers. Because a Guest's visible collaborators depend on the
context Page, the browser caches Principal resolutions by both Principal UID
and context Page ID, and inline pills, identity cards, and clipboard text share
that context. All authorized Page
mention consumers—inline chips, picker labels, clipboard plain-text
serialization, and portable Markdown or text exports—project `{ title, icon }`
from the shared `pageMetadata` TanStack DB collection after verifying
`access !== 'restricted'`, whereas restricted targets bypass `pageMetadata` and
render as a non-clickable restricted label without exposing any title or icon.
Accessible Page mentions render inline with `PageIcon`, wrap naturally across
lines, preview location and body excerpts on hover, and open the target Page on
click. Accessible Principal mentions render as unbreakable inline pills
(highlighting mentions of the signed-in Principal with a subtle Berry tint) and
open an identity card popover on click, preserving display names for disabled
historical Principals.

Markdown tables can be pasted or inserted from the slash menu or `|--` shortcut.
Cell, row, column, and table menus expose the selected operation scope. Row and
column handles support selection, dragging, insertion, deletion, and keyboard
move commands. Editors can merge and split cells, toggle header rows and columns,
set alignment and background colors, sort rows, distribute or resize columns,
expand a table to full width, and export CSV. Sorting keeps the first header row;
tables with row spans require splitting those spans before sorting. An already
sorted range produces no edit, and sorting retains unchanged leading and
trailing rows so concurrent edits there continue to merge. Moves that
would break a merged cell are disabled.

Tab at the last cell and Mod+Enter add a row and continue editing. Commands and
completed resize gestures each form one undo step. Tables scroll independently
with overflow hints. Complete header rows stay fixed vertically, and complete
header columns stay fixed horizontally. Their scroll regions remain accessible
in read-only documents. Copying one selected cell copies its content, while
multiple cells retain a table. XML stores column pixel widths in `widths`, full
width in `layout="full"`, and cell colors in `background`. Markdown uses GFM for
plain tables and block tags for richer tables. The browser and Rust codecs
preserve these values through collaborative updates and reopening.

Callouts offer an editable emoji and five background tones, stored as `icon` and
`tone` on `<callout>`.

In code blocks, Tab indents each line touched by the selection with a leading
tab. Shift+Tab removes one leading tab or up to two spaces. These commands keep
the selected text and its direction, and each command is one undo step.
Each code block shows a toolbar with a searchable language picker, a wrap
toggle, and copy. Kirari tokenizes the source for highlighting, while Page XML
keeps the language in `lang`, the info string remainder in `meta`, and wrapping
in `wrap="true"`; the Markdown codec writes a plain fence unless wrapping or
extra attributes require a `<pre>` tag. Formula blocks store their LaTeX source
in a `<math>` element and render it through Temml. The editor opens a formula
panel from the block, reports invalid formulas there, and writes each edit to
the page immediately. Markdown uses `$$` fences for formula blocks.
Mermaid blocks store their source in a `<mermaid>` element and render it with
Pele. The block splits source and diagram, remembers whether to show both,
code only, or the diagram only, and stores the diagram palette (`auto`, `light`,
or `dark`) on the element. Markdown writes a `mermaid` fence for the default
view; non-default view or theme values use a `<mermaid>` tag around the fence.

Documents support column rows. The insert menu and slash queries such as
`/2 columns` create two to five columns. Dropping blocks beside another block
creates columns; dropping beside an existing column adds a sibling. A vertical
insertion line previews the destination. Moving the last block out removes that
column, and a row with one remaining column becomes ordinary page content.
Users drag the divider to resize adjacent columns, press Escape to cancel a
preview, or focus the divider and use Left/Right and undo/redo shortcuts.
Up/Down and Shift+Up/Down follow the document's reading order across columns:
the last line of one column leads to the first line of the next, and upward
motion reverses that order. Wrapped lines stay within their paragraph.
Backspace at a column's first block joins it to the preceding text block;
Delete at a column's last block joins the next text block. These operations
remove an emptied column, and undo restores the original layout.
Page XML stores the layout as `<columns>` containing `<column>` elements with
relative `width` weights. Browser and Kernel normalization preserve the same
layout through save, reload, and undo. On screens at most 600 px wide, columns
stack vertically in document order.

Document editors can set the icon in the title line from two tabs. **Emoji**
searches or browses categories and renders Fluent Emoji Color, including
skin-tone and joined sequences. **Custom icon** shows the Pod's shared
custom-picture library and uploads a square raster image (`PNG`, `JPEG`, `GIF`,
or `WebP`, verified by magic-byte signature) up to 1 MB, resized to 128 px and
named with a unique ASCII shortcode such as `:my_icon:` using lowercase letters,
digits, and underscores; re-uploading identical bytes under the same shortcode
succeeds idempotently, whereas assigning an existing shortcode to a different
asset fails with `shortcode_taken`.
The existing Page `icon` metadata is the durable owner: it holds either the
emoji or a `metadata/custom-emoji/...` path. Navigation, references, and page
pickers render that same value; the Page header path is text only. Listing the
picker catalog requires Space view access, uploading to the library requires
Space edit access, reading an individual `metadata/custom-emoji/...` asset
requires an active Pod Principal so Guests and Page-scoped Agents can render
icons on shared Pages, and saving the Page `icon` requires `page_edit`. A save
ignores another choice while the request is pending and offers retry after a
failure. Viewers see the saved icon without editing controls.

Page detail responses and directory lists attach each caller's effective actions
from the same permission snapshot. A Page detail response also carries
`ancestors`: the Pages from the root down to the parent that the caller can read,
stopping at the nearest unreadable ancestor, read in the same transaction as the
Page itself. The Page header path renders that list as returned; UI controls gate actions on those bits while
displaying role names as human summaries. Move pickers list writable Page
destinations while excluding the moving Page and its descendants, and root
create, move, and copy options read `can_create_space` and `can_create_private`
from the directory using the exact destination check enforced on write (loading
those root capabilities even while the sidebar section is collapsed). Base,
file, and Applet Pages provide child-page navigation in their header—listing
visible children, paging additional children via the directory cursor, and
offering child creation when the Page grants `page_edit`—which lets
collaborators navigate shared subtrees whose parent Page is hidden from them.
Document Pages instead append a collapsible subpages directory below the
document body whenever the caller can view at least one live direct child
(`child_count > 0`), and render nothing when zero live children are visible.
When a Document Page has visible children, its editor drops its standalone canvas
minimum height so an empty parent keeps a single-line body placeholder for
editors while read-only viewers hide the empty body and top divider entirely.
When collapsed, the subpages directory shows a dimmed single-line toggle bar
with a visible-child count badge and defers child-list requests until expanded.
When expanded, the heading omits the count badge and offers List and Grid views, a field-visibility and
column-order popover (`Creator`, `Modified`, and `Created` alongside the locked
`Name` column), three-state column sorting (`asc`, `desc`, and tree sibling
order), inline multi-file uploads that remain on the parent document, and child
Document or Base creation. `Page.children_view` (`collapsed`, `view`,
`field_order`, `visible_fields`) persists these presentation settings on the
Page: editors save changes through `PATCH /api/v2/pod/pages/:id` without
advancing `updated_at` or recording a content contributor edit, whereas
read-only viewers adjust presentation locally in session memory. Both the Page
header and sidebar invoke
the same Trash action: trashing a Page discards its local draft, navigates to
its visible parent or content root, and offers Undo, while Trash search matches
both titles and document bodies before applying the server result limit. Trash
rows open the standard Page detail view. A top-level deleted Page remains
readable with its document, Base, and file content, but the UI and API reject
edits and personal-state writes; descendants of a deleted ancestor stay hidden.
Managers can restore the Page or confirm permanent deletion from either the
list or the detail notice. Permanent deletion starts the same bounded purge job
as retention expiry and returns the manager to Trash.

### Pod URLs, dialogs, search, and motion

Pod URLs combine the tenant's subdomain slug with the Kernel's short UUID codec:
`https://<slug>.<site>/pages/<short-id>` and `/conversations/<short-id>` (or
`<slug>.ankole.localhost:<port>` in local development, with no `/pod` prefix or
tenant query parameter). Because the browser bundle cannot load the native Rust
kernel, `app/webapps/common/uuid-url.ts` mirrors the codec;
`app/kernel/test/vectors/uuid_url.json` pins the UUID encoding, and
`app/kernel/test/vectors/pod_url.json` pins the shared Pod path and query
grammar. Signed-in accounts span Pod subdomains via the BrowserSessions
authentication and activation owners, while each open browser tab retains its
selected identity and verifies that identity's tenant admission on every
request. Both full-page views and document embeds consume links from the same
content context.

Dialogs use compact layouts, explicit Cancel buttons, searchable Page pickers,
and focus restoration on close. Pressing Enter submits ordinary forms, whereas
destructive confirmations focus Cancel initially; tall dialogs scroll their body
while pinning the header and action bar, and property pickers stay anchored to
their trigger field.

Clicking the sidebar search icon button or pressing Command/Control+K opens a
single quick-navigation menu linking to Pages, Chats, and content roots without
mutating or discarding an unfinished Chat draft. Both the menu and the dedicated
search view share title-and-body Page search, and the search view persists its
query in the `q` URL parameter across result clicks, Back navigation, and
reloads. Search hits, quick-navigation items, and Page references in Chat render
visible ancestor breadcrumbs so users can tell identically named Pages apart,
alongside consistent per-type Page icons across sidebars, pickers, embeds, and
Chat messages. Within content lists, `J` and `K` move focus while text inputs
preserve normal typing and IME keys; desktop lists use compact row density and
touch layouts expand hit targets. Mobile sidebar section links have a minimum
height of 40 px across the full link target.

The Pod shell layers a rounded paper sheet (`main`) above the ground-level
sidebar (`Home` and `Chat` tabs at top-left, paired with search,
quick-create, and sidebar-collapse icon buttons at top-right; when the desktop
sidebar collapses, the expand trigger flows into the 44 px sheet header without
shifting content vertically). On a Page, that header starts with the Page path
in text only: every path begins at `Pages`, which links to all Pages, then names
the direct parent and ends with the open Page in full ink beside its favorite
star. Any ancestors between `Pages` and the direct parent fold into a menu. On a
phone, `Pages` gives way to the title and every ancestor folds into that menu.
The path is the Page read's `ancestors`, so an unreadable parent starts the path
below it. A hairline under the header
separates it from the scrolling content. The header's actions follow the path:
`Page chat` and `Comments` are toggles that stay pressed while their panel is
open, with `Comments` showing the unread count, and `Share` is the one bordered
button (displaying a scope icon on live Pages and opening a two-level sharing
popover across overview, multi-select invite, collaborator management, and
permission settings subviews; viewers without `page_manage` open a read-only
collaborator overview with link copy, while trashed Pages render a standalone
Copy link icon button). When the header runs short, action labels give way before the title
does. On desktop, an open chat or comments panel is a second paper sheet beside
the Page, with the same radius, edge, and clearance. Each sheet keeps the
shell's 6 px clearance, so the two sheets sit 12 px apart. The panel's 44 px
header carries no hairline, and its title starts on the same 18 px edge as the
Page path. Selects in either header are borderless text with a chevron. The
chat composer docks at the bottom of the panel before the first message as
well as after it. In `Home`, `Recently visited` interleaves visited
Pages (ordered by `page_user_states.visited_at`) with recent Conversations
(ordered by `lastActivityAt`) both inline in the sidebar and in `/content/recent`;
opening a Conversation from `Recently visited` keeps the sidebar on `Home` so
the user's navigation context stays stable. `Favorites` renders inline above the
`Space` and `Private` trees whenever the user has favorited Pages, while the
account switcher, `Trash`, and `Pod settings` sit in the sidebar footer.
The Pod and Console share sidebar controls. Command/Control+B toggles the
sidebar while leaving shortcuts inside editable controls to those controls.
On desktop, the Pod sidebar starts at its 248 px minimum width and its edge
separator widens it up to 480 px. Dragging updates the layout immediately and
stores the final width in origin-scoped `localStorage`; Left and Right adjust a
focused separator by 16 px, while Home and End select the minimum and maximum.
Every Pod on the same origin restores that device preference. When the desktop
sidebar is collapsed, hovering the left screen edge opens it as a temporary
ceramic overlay without changing the collapse preference or moving the page.
Leaving the overlay closes it, while `Show sidebar` expands it persistently.
The open sidebar tab shows its icon and label; the other tab shows only its
icon and names itself in a tooltip. The open tab and the current row in the Pod
and Console sidebars share one mark: an ink wash one step denser than the hover
wash, with ink text at the same weight. Only the Sidebar row the user followed
marks the open Page, so a Page listed under both Recently visited and a tree
highlights once; a Page opened without a Sidebar row marks its Space or Private
row instead. The browser history entry records the followed section, so reloads
and Back/Forward restore the same mark. A link opened in a new tab uses its tree
row. The section determines both the visible wash and `aria-current`; URL
matching alone cannot distinguish repeated links. Document row and section
actions fade in over 140 ms under a fine pointer. Leaving the row hides them
immediately; keyboard focus and an open menu keep them visible immediately.
Touch and mobile sidebars show these actions persistently. Chat status and menu
icons exchange places immediately. When the system forces its own colors, the
current row takes an outline instead of the wash.

Pointer clicks rotate the Recently visited, Favorites, Space, and Private
chevrons over 140 ms. Nested tree changes, keyboard activation, preference
restoration, and drop-driven expansion are immediate. Reduced motion replaces
the root chevron's rotation with a short opacity recovery on pointer release.

On desktop, pointer activation brings Comments, Page chat, and the conversation
summary into view with an 8 px translation and opacity over 200 ms. Closing
immediately returns focus and makes the departing panel inert while its visual
exit completes. Reopening reverses that transition in place. Keyboard actions,
URL restoration, automatic opening, and switching between Comments and Page
chat are immediate. A close while a popup is still mounted also unmounts the
panel immediately, so its portals leave with it. Navigation, lost access, and
trashing a Page remove the corresponding panel without an exit delay. Async
conversation completion and revocation callbacks consult the logical open
state before navigating; a visually departing Page chat cannot reopen itself.

On mobile, closing a Chat sheet keeps its content mounted through the sheet's
exit transition. With `prefers-reduced-motion`, desktop panels use a 140 ms fade
without translation, root chevrons change direction immediately, and Chat
scrolling disables smooth animation. Keyboard and programmatic paths stay
immediate under either preference.

Chat timestamps appear immediately when a message is hovered or contains focus.
Turn-rail markers resize immediately as the pointer or keyboard focus moves
between turns, so browsing a long conversation never waits for visual feedback.

### Standalone Chats, Base cells, and file/Applet states

Standalone Chats follow Notion AI's conversation layout:

- **Queueing and turn control**: Native follow-up messages can either steer the
  main loop at its next boundary or wait in the durable queue for a separate
  turn. Users can edit, reorder, delete, or immediately release queued items,
  and stale edits fail cleanly without clobbering newer state. Clicking Stop
  cancels the active run and pauses all queued inputs across page reloads until
  the user clicks Continue. Editing or regenerating the last turn goes through
  the retry and model-history owners, preserving completed Pod content edits and
  rejecting mutations to running or superseded turns. Scrolling upward loads
  older messages in bounded windows into the same remote cache without jumping
  the reading position.
- **Unconfirmed first sends and scroll memory**: On a Chat's initial send, the
  client retains the local draft, attachments, and retry request IDs in memory
  for the current document until the server confirms receipt; opening a fresh
  standalone Chat in the meantime starts a separate draft, and any late response
  settles only against the draft and message that initiated it. Returning to a
  Chat restores its last visible message and pixel offset in memory (tracked
  separately for narrow Page panels versus full Conversation views), auto-follows
  incoming output when anchored at the bottom or after clicking latest-message,
  and starts at the newest message on full page reload.
- **Model selection**: Model preferences live on the Chat (`null` inherits the
  Agent default). Each accepted input snapshots its resolved logical profile so
  subsequent preference changes affect only future turns; if a follow-up message
  uses a different profile than the active run, the server queues it.

In Base tables, editing a cell snapshots the starting value and field versions:
Enter or Tab submits, Escape cancels, IME composition keys never submit, and
version conflicts preserve the draft for explicit retry or discard. View filter,
sort, and layout edits preview locally until an editor saves them against the
starting view version (keeping the draft on save failure), while inline view
settings live inside their host document embed. Single-select relation and user
pickers close on selection, whereas multi-select pickers stay open until Done;
calculations that require a target field prompt for one, and saved filters or
summaries referencing invalid fields surface a repair action.

Four deliberate product differences separate Ankole from Notion: Base records
are not Pages and have no per-record trash (deleting records or fields requires
confirmation); moving a Page—even into Private—retains its direct shares (as
noted in the move and share dialogs); Agents require explicit Space or Page
admission; and Applets execute with the signed-in Human's permissions.

For file uploads, selecting a file captures both the file and the loaded Page
revision, freezing the picker while the upload is in flight and keeping the
selection for retry on failure. Transient realtime disconnects leave loaded file
previews visible with a reconnect action, hiding content only upon an
authoritative access denial. If the realtime token request, the socket, and the
page topic join do not all complete in 10 seconds, the page shows the same
reconnect action. Likewise, Applet bundle-load errors and live connection
drops expose separate retry actions so reconnecting never unmounts the running
Applet.

## Pages and access

`Ankole.Pod.Pages` owns the page tree and lifecycle. Every Page has one of four
types—`doc`, `base`, `applet`, or `file`—and any Page can have child Pages.
Creating a `base` Page seeds a default `Table 1` table with a primary `Name`
text field and a `Grid` view; tables and records belong to their Base rather
than acting as standalone Pages.

Sibling ordering uses keys compared under PostgreSQL `C` collation. Moving a
Page locks the tenant's Pod tree before checking for cycles so concurrent
opposite moves cannot form a loop. Callers position a moved Page relative to
`after_id` or `before_id` (falling back to the end of the parent's children when
omitted, or returning `position_conflict` if the named sibling lives under a
different parent), and the server generates the new position key under that same
tree lock. Move responses return an `undo` payload containing the prior parent,
Private owner, and adjacent sibling captured under the lock so the browser can
undo a move even when directory pagination had not loaded that sibling (when the
Page had no siblings, `undo` carries only the parent and Private owner).

### Permissions and ACL anchors

`Ankole.Pod.Access` layers Pod permissions on Principal and AuthZ using a 5-bit
action mask: `page_view = 1`, `page_write_records = 2`, `page_edit = 4`, and
`page_manage = 8`, plus `page_comment = 16`. Named roles bundle these actions:

- **`view` (`1`)**: Read the Page and its records.
- **`contribute` (`19`)**: Comment on documents, edit Base records, and upload
  record attachments.
- **`edit` (`23`)**: Edit documents, Page metadata, Base schemas, and Applet
  source, and create Space-root Pages.
- **`manage` (`31`)**: Manage sharing, delete Base tables, move Pages across
  permission boundaries, and manage Trash.

Page grants live in `permission_grants`, but the general Console grant API
cannot create, modify, or delete Pod page grants. Tenant creation seeds the
Space policy once (and creates starter Pod pages only when the tenant has zero
Pages and zero page grants); reads and scaffold repair never resurrect grants
that an operator or manager removed.

Access evaluation follows seven core rules:

- Active Human members receive the Space's default role, whereas Guests have no
  default Space role and see only explicitly shared Pages.
- Each Private root belongs to a single Human member; Guests cannot access
  Private space, Console grants confer no Private access, and creating or moving
  a Page into a Private root establishes the owner's grant only after verifying
  move permissions.
- Agents need explicit Space admission or a Page share. When an Agent acts on
  behalf of a Human—including Workflows, scheduled checkbacks/crons, and
  Background Agent Jobs—effective access is the bitwise intersection of the
  Human's and Agent's current Page permissions; autonomous service work uses the
  Agent's own Page permissions.
- Disabling inheritance on a Page blocks `container` grants from ancestors while
  keeping local grants on that Page; trashing any ancestor hides its entire
  descendant subtree.
- Editors (`page_edit`) may move a Page within the same effective permission
  envelope, whereas `page_manage` is required whenever a move crosses an ACL
  boundary (including conditional grants or Userset cycles across subtrees),
  switches between Space and Private, or changes Private owners.
- Collaborator search for Guests returns direct-share candidates only when both
  Principals hold effective `page_view` on at least one common Page in the
  current request snapshot (honoring grant conditions and Guest Private rules).
- Directory lists, search, favorites, recents, embeds, and file downloads all
  recheck current access; Userset grants pointing to an inaccessible source Page
  expose only the source ID and `accessible: false` with `null` title and icon.

To evaluate tree permissions efficiently, every Page stores `acl_anchor_id`.
Root Pages, Pages with local grants, Pages with inheritance disabled, and
trashed Pages act as ACL anchors pointing to their nearest ancestor anchor,
while ordinary pass-through Pages point directly to their enclosing anchor.
`container` grants propagate to the Page and inheriting descendants, `self`
grants apply only to the target Page, and Userset grants import Principals who
hold a specified action on another Page; effective bits combine by bitwise
union. The Rust Kernel evaluates Principal, group, and request conditions, and
PostgreSQL resolves reachable anchor permissions per request via recursive
`UNION` (where unseeded Userset cycles grant zero bits). Single-page checks walk
the target anchor's ancestors and reverse Userset dependencies, while list/read
queries reuse one reachable-anchor set for both filtering and action metadata.
When tree moves or grant edits change anchor topology, Ankole recursively
updates pass-through descendants by ID—stopping at child anchors—only when their
`acl_anchor_id` actually changes, backed by composite indexes on `(tenant_id,
acl_anchor_id)` and `(tenant_id, parent_anchor_id)` across live and trashed
rows.

### Directory pagination, search, and Agent write authority

Tree navigation uses Ash keyset pagination over `(position, id)`—filtering roots
with `parent_id IS NULL` and children with `parent_id = ...`—supported by
covering indexes that include `private_owner_uid`. Page timestamps use
`Ankole.Ash.Types.Timestamptz` (mapping microsecond `DateTime` structs to
`timestamptz`) so native Ash filters match the partial index predicate for live
Pages.

Each directory entry includes `has_children`, indicating whether the caller can
view at least one live direct child, while Page detail responses and Phoenix
channel `tree_changed` parent summaries also include `child_count` for the
caller's visible live direct children. The directory query calculates existence
with the same authorization filter as the returned entries, and passing
`details=true` to `GET /api/v2/pod/pages/children` enriches the returned batch
with creator display names, timestamps, plain-text document excerpts, and
primary file descriptors while keeping default sidebar navigation on its
index-only scan. Hidden descendants
and deleted children do not make a Page expandable. The sidebar renders an
expand button for branches and an equally wide spacer for leaves; users with
edit permission can create a child through the row's add button in either case.
When the directory identifies a leaf, the browser closes it without fetching a
child list. Branch choices stay in the current browser document. On reload,
`pages.navigation` returns Space and Private roots, the visible active Page path,
and the first child-list page for each ancestor in one response. These reads share
one evaluated authorization context per subject, including the interactive Human
when an Agent acts on their behalf. The browser expands only that path; section
folding preferences remain scoped to the Pod and authentication. A path node beyond
the first 200 siblings appears alongside the loaded directory rows, with duplicates
removed as pagination reaches it. Dragging can target these path nodes; step-up and
step-down commands require the node to be among the continuously loaded siblings.
Shared Pages whose ancestors are hidden or whose
Private root belongs to another person remain accessible through Shared and search.

Pod routes show loading feedback while their data or component is pending and
render the destination as soon as both are ready. Loading feedback has no minimum
visible duration. A Page route renders cached details immediately while TanStack
Query revalidates stale data in the background. A cold route waits for its first
read alongside the component download.

The shared shell loads an emoji search dataset only when a picker opens,
selecting the current locale and using English for other locales.

Remote search inputs update their text immediately and wait for 180 ms of quiet
before changing the query. Command search, Page pickers, mention and participant
search, and Base reference pickers share this behavior. While the text differs
from the submitted query, pickers hide remote results for the previous text so
users cannot select a stale match. Locally available commands and Agents filter
immediately. TanStack Query continues to own request cancellation and cached
results.

Each paginated TanStack Query owns its directory data in memory. The bootstrap
fills directories that have no cached data and keeps only the active path in its
own query. Revalidating the path preserves loaded directory pages and cursors.
Creation controls subscribe to an enabled directory query whenever they need
the caller's root capabilities. The default creation menu and Recent select
those capabilities from the Space root query; favorites, Shared, and search
also load that directory. These consumers share its cache and in-flight request,
and fetch independently of sidebar bootstrap success. Access changes invalidate
the same query so active consumers reread the caller's permissions.
Lists expose a retry when this read fails and prevent creation from cached
permissions until the query succeeds.

The browser shares Page titles and icons through one in-memory TanStack DB
collection per QueryClient, authentication, and Pod. Successful directory, list,
search, Page-detail, and mention reads populate this collection; confirmed edits
and authorized content events update it by Page ID. Row components subscribe to
their Page, while paths and pickers subscribe to their displayed IDs. Query
snapshots continue to own membership, pagination, permissions, and freshness.
An in-flight read cannot overwrite a metadata edit confirmed after that read
started. A later read can refresh that Page normally. The collection lasts for
the browser session and does not persist data or queue offline writes. Signals
continue to own editable document drafts, including pending title changes.

After a successful create, move, delete, or restore, the browser applies the
committed change to cached directories and continues the user action while
mounted queries refresh in the background. The browser immediately removes a
restored Page from each cached Trash filter. When a Page is renamed, the browser
updates the shared metadata and refreshes search membership, Page details, history,
and insights while preserving unrelated comments and Base table queries.
Conversation list events invalidate the shared recent-query prefix used by
Home and the sidebar.
Page, directory, Agent, conversation, teammate-search, and Base snapshot queries
pass their abort signal to the HTTP client so cancellation also stops the
associated request.
When the content subscription becomes ready or reconnects, the browser invalidates
content queries through TanStack Query. Initial reads continue, and observed cached
queries revalidate according to their normal lifecycle.
Hovering or focusing an expansion control for 100 ms prefetches its child list.
Pod links use TanStack Router's intent preloading after 250 ms: the router loads
the destination component and runs its loader together. Page loaders prefetch
details through TanStack Query, which owns freshness and deduplicates the read
when the user follows the link. A cold expansion rotates the arrow immediately
and shows an inline spinner after 250 ms, keeping the row height stable. Cached
children remain visible during background validation. Opening Home uses the
existing cache, and the Space settings dialog loads its details when opened.

The sidebar retains Home inside a React Activity boundary. While Chat is selected,
React preserves Home's local branch choices and DOM but releases its query and
effect subscriptions. Home rereads stored section preferences when its effects
resume, including choices made in another tab while Home was hidden.
`ContentProvider` keeps receiving content events and invalidating the cache;
visible consumers refresh immediately, and Home refreshes its stale queries
when selected. The navigation model separates root preferences
from each row's computed expansion state, so toggling a branch updates that row
and its children. Persistent navigation components select the pathname and
navigation state they use instead of subscribing to every URL change.

Search and directory lists enforce access before applying result caps:

- **Full-text search**: Matches titles and plain-text bodies across visible
  Pages (including shared child Pages whose parent is hidden), ranks title
  similarity ahead of body matches via trigram indexes, and returns up to 30
  Pages. Move pickers pass `exclude_subtree_of` to strip the moving Page and all
  its descendants—even when intermediate ancestors do not match the query—before
  the 30-row cap. Move, copy, and saved-artifact destination searches pass
  `required_action=page_edit` (checking both view and edit bits before the cap,
  whereas ordinary search checks `page_view`), and Base copies default to the
  source Page's parent when editable or require picking an editable destination
  first.
- **Scoped lists, favorites, recents, and Trash**: Scoped text queries filter
  titles and bodies before the 200-row cap. Favorites and recents filter to
  visible live Pages first and sort by favorite or visit timestamp with Page ID
  as tie-breaker. Trash lists scan top-level deleted Pages in deletion-time
  order in batches before the 200-row cap; during that check, each candidate
  ignores its own deletion tombstone while still hiding Pages under a deleted
  ancestor. The list response contains the authorized Page rows; the browser
  reads creation permissions and the current Principal from the root-directory
  cache. Favorites, recents, and Shared reuse their reachable-anchor result when
  Ash filters and projects the returned rows, evaluating each subject once in the
  read transaction.

Every Agent write locks and verifies the active `RunRef` or Job attempt inside
the same PostgreSQL transaction that commits the Pod change, using the authority
passed by the RPC broker from the authenticated turn. Consequently, an in-flight
file relay cannot commit once its turn closes or its Job attempt is superseded.

### Persistence and transactions

`Ankole.Pod` is the root Ash domain, owning the durable `Page`, `PageContent`,
`PageChange`, `PageUserState`, `BaseTable`, `BaseField`, and `BaseView`
resources alongside stateless `*.Browser` resources serving `/api/v2/pod`
JSON:API routes (where browser actions validate query operators as closed enums
before serializing them to the JSON strings expected by the shared Base query
compiler).

Every Pod write—or read requiring a row lock—opens `Repo.transact_top_level/2`
in its owning module (`Ankole.Pod.Pages`, `Pages.Sharing`, `Documents`, `Files`,
`Applets`, `Bases`, or `Jobs.PurgePage`). Topology and sharing writes acquire
the tenant Pod tree lock first and then lock the Agent's turn, whereas document
content and Base record writes skip the tree lock. Intra-domain callers compose
`*_in_tx` helpers inside an existing transaction (for example, Base copy calling
`Pages.create_in_tx/1`), and Phoenix channel broadcasts to page, access, and
table topics fire strictly in `after_commit` hooks after the top-level
transaction commits.

Within the domain:

- `Ankole.Pod.Pages` owns tree writes, page details, and personal state.
- `Ankole.Pod.Access` computes ancestor paths, reachable anchors, and access
  provenance through its native SQL read model.
- `Ankole.Pod.Pages.Queries` implements directory cursors, title/body search
  (attaching authorized ancestor breadcrumbs), list scopes (where `all` includes
  visible child Pages), and version snapshots, backing the `pages.children` and
  `pages.search` Agent tools with explicit tenant binding on every SQL branch.
- `Ankole.Pod.Pages.Sharing` manages collaborator pickers, Space access policy
  (where the unconditional `all_humans` rule sets the Space default role while
  conditional rules keep their own scope), and Page sharing reads and writes.
  `GET /api/v2/pod/pages/:id/sharing` (`Sharing.sharing/2`, also backing
  `pages.sharing`) authorizes callers who hold `page_view` or `page_manage` on a
  live Page, returning `can_manage`, `scope_kind` (`space` or `private`),
  `space_name`, `space_role`, inherited collaborator provenance (`space_admin`,
  `space_default`, `space_agent`, `private_owner`, and `ancestor`), and local
  `grants`. Each local grant carries an authoritative `rule_kind` (`role` for
  unconditional Principal or group grants matching a canonical action bundle in
  `Ankole.Pod.Access`, or `advanced` for Usersets, CEL conditions, and custom
  action subsets). When a caller lacks `page_manage`, `Sharing` omits
  collaborator picker `subjects`, omits disabled Principals, inactive Private
  Guest grants, conditional CEL expressions, Userset definitions, and grants
  without `page_view`, and returns active unconditional Principal and group
  grants that confer `page_view` (including both canonical `role` grants and
  `advanced` action subsets). For callers with Guest collaborator scope,
  `Collaborators` and `Sharing` restrict visible peers to collaborators who
  share effective `page_view` on at least one live Page or contributed to the
  Page and set `subtitle` to `nil` so external Guests see only display names and
  avatars; Guest grants carried on Pages inside a Private subtree include
  `inactive_in_private: true` because Guests hold zero effective access in
  Private space. Both `PATCH /api/v2/pod/pages/:id/sharing`
  (`Sharing.update_sharing/4`) and `PUT /api/v2/pod/pages/:id/sharing`
  (`Sharing.set_sharing/4`, also backing `pages.set_sharing`) enforce the same
  collaborator, peer-visibility, and scope validation contract under the tenant
  Pod tree lock—rejecting new or escalated Guest grants on Private subtrees with
  `guest_forbidden_in_private` (`422`), restricting Guest managers to visible
  shared-Page peers, and ensuring that the acting manager (and any interactive
  Human Principal on an Agent session) holds `page_manage` when
  `inherit_permissions` is `false` by adding a container `manage` grant only if
  that Principal lacks `page_manage`. `PATCH` applies atomic granular mutations
  (`inherit_permissions`, `upserts`, and `removes`), replacing any unconditional
  grant at the opposite `target_scope` for an upserted owner while merging
  concurrent non-conflicting updates and preserving untouched custom action
  bitmasks, whereas `PUT` diffs the submitted grant set against existing rows
  when `expected_sharing_version` matches so unchanged rows stay in place and
  managers can preserve or narrow historical grants for disabled Principals,
  legacy Guests when external guest access is turned off, or inactive Private
  Guests without escalating them. Documents and Base Pages offer `view`,
  `contribute`, `edit`, and `manage` roles (labeling `contribute` as comment
  access on Documents and record submission on Bases), while Files and Applets
  offer `view`, `edit`, and `manage`; `container` grants can confer comment and
  record-write access on descendant Pages, and `Sharing` rejects `self`-scoped
  rules granting only `page_write_records` on Documents or granting
  `page_write_records` or `page_comment` without `page_edit` or `page_manage` on
  Files and Applets. Conditional grants, Usersets, and custom bitmasks appear as
  read-only advanced rules in permission settings with explicit removal, role
  edits expand to full role bitmasks, payloads supplying both a role and an
  action set must match, and `AuthZ` persists the underlying `permission_grants`
  rows and triggers anchor maintenance.

Read isolation matches each operation's locking needs:

- Lock-free multi-page reads use `Repo.transact_repeatable_read_only/1`, whose
  opening statement sets `REPEATABLE READ, READ ONLY` (reusing the outer
  savepoint in SQL Sandbox unit tests while exercising full snapshot isolation
  in committed concurrency tests). Personal page-state reads authorize and read
  state inside that same snapshot.
- Locking reads run at `READ COMMITTED` and lock the Page or table row *before*
  running authorization or loading protected data: `Bases.query` takes `FOR SHARE`
  on inline table metadata (keeping records and table version consistent) and
  `FOR KEY SHARE` on physical table metadata; `Copy.table` locks source tables
  `FOR UPDATE` in ascending ID order before checking access; and favorite/visit
  writes lock the Page `FOR SHARE` before authorizing and committing.

Every Pod table includes `tenant_id` enforced by composite foreign keys and
mandatory `Ankole.Repo` tenant context; tenant teardown deletes Base records and
child rows in batches before deleting Pages. Trashing a Page marks it deleted
and hides its subtree until `pod.trash_retention_days` elapses (a positive
integer defaulting to `30`, or `"unlimited"` to disable automatic purge). When
purge begins, it stamps a purge-started marker in the same transaction that
rechecks eligibility—blocking any subsequent restore—cleans Base tables via the
Base cleanup contract, and deletes page content, file references, grants, and
child Pages in bounded batches while keeping the root Page row last so an
interrupted job can safely resume.

## Documents and collaboration

### Document tools

The document menu offers **Insights**, **Show editing stats**, **Export →
Markdown**, and **Copy → Markdown / Plain text**. Export and copy read the
current editor draft, including edits awaiting OT acknowledgement. Markdown
includes the title and icon when present; plain text contains only the body.
Both projections use the canonical document tree. The portable Markdown
projection flattens layout containers, renders callouts as blockquotes, and
renders accessible Page references and `<mention page="…" />` nodes as readable
titles and links while redacting restricted targets to plain text and rendering
`<mention principal="…" />` nodes as `@Name` (plain-text copy outputs Page
mention titles without trailing URLs). Media images become
Markdown images; videos, attachments, webpage cards, and external embeds become
readable links. Plain-text tables use
tabs between cells and newlines between rows. Copy uses the reader's Page and
file links without the author's browser authentication reference.

Export downloads a `.md` file when the document has no local attachments.
Documents with uploaded media or attachments, referenced File Pages, or a custom icon download
as a ZIP containing Markdown and the actual files at relative paths. Ankole
reads each file through its owning authenticated endpoint before producing the
archive; a failed file read leaves an error instead of a partial download.
Referenced documents, Bases, and Applets remain links to their independent
Pages, and remote image URLs remain remote URLs.

The desktop statistics footer stays visible while enabled, including during
typing. Unicode word segmentation counts word-like segments, including Chinese
and Japanese text without spaces. UTF-16 code units count as characters,
nonempty text lines count as paragraphs, and estimated reading time rounds up
at 200 segmented words per minute.
Selecting text in the document replaces the whole-body totals with selected
word and character counts. The browser remembers footer visibility per Pod and
Principal. Command/Control+Shift+G toggles the footer, and Command/Control+Shift+I
opens Insights.

`Ankole.Pod.Documents.Insights` shows creation and update times, contributors,
recent readers, and daily activity for the last 30 UTC dates. `PageContent` owns
the durable contributor set and records body and title/icon edits inside the
Page write transaction. No-op edits and comment annotation changes do not add
contributors or editing sessions. OT replay pruning leaves attribution and
activity intact. Author profiles are loaded in one batch for each result page.

Readers need `page_view` to inspect Insights and set their own `hide_visits`
preference for that document. Only `page_edit` callers can list readers. The
list is paginated by most recent visit and excludes Principals who hide their
visits; hiding a name does not subtract anonymous activity counts. The browser
records a visit when the actual Page route opens, separately from prefetches,
reference resolution, and API content reads. `PageUserState.visited_at` stores
the latest visit and `edited_at` stores the latest meaningful edit for that
Principal. A gap of at least five minutes starts a new viewing or editing
session. A title or icon edit joins the same editing session as body changes.

`PageDailyActivity` stores viewing sessions, editing sessions, and new comments
(including replies) per Page and UTC date. The owning operation increments its
counter inside the same Page transaction. Edits to an existing comment and
resolution changes do not count as new comments. Data accumulates from when
recording is enabled; the interface explains the counting rules and exposes a
daily table alongside the chart. Page purge removes both these counters and
reader states.

### Persistence

`Ankole.Pod.Documents` manages document revisions and collaborative writes,
while Ash resources persist `Page`, `PageContent`, `PageChange`, and
`PageUserState` rows inside the caller's transaction:

- Page revision increments execute as atomic SQL expressions.
- `PageChange` rows are immutable; each write transaction appends new batches
  and prunes expired ones alongside the `PageContent` update.
- Favorite and visit upserts modify only the columns supplied by the caller.
- The enclosing aggregate transaction holds the tree lock (when applicable) and
  AuthZ proof.

### Live editing

Each browser keeps its confirmed document, one submitted batch, and subsequent
local edits. The control plane assigns revisions under the Page row lock and
deduplicates retried batches by client ID and sequence. A stale submission receives
the missing changes so the client can transform and resubmit it. The client marks
received transactions as remote and includes structural corrections in its pending
changes. Lists and table operations preserve the identity of retained text so a
concurrent edit follows its cell or paragraph. Undo changes the author's own work
while preserving received edits.

Agents use the same authorized document commit owner through the Pod tool RPC.
Whole-document writes and appends require the revision that the Agent read. On a
revision conflict, the Agent reads the current document before submitting revised
work. The server publishes an accepted write as an incremental ChangeSet for open
editors, which transform pending Human edits over it.

Document participants and selections are ephemeral Phoenix Presence data. The
server derives participant identity from the authenticated Principal and checks
Page access before delivering updates. The browser maps selections through its
pending edits and hides selections from an incompatible revision. The participant
strip distinguishes viewers and editors. The Page header's participant picker
shows connection and save status, keeping both visible while the document
scrolls. In a narrow header, a status icon and participant count replace
the text and avatar strip; the participant popover shows the full status and
member list. `PodRealtime` owns connection status and reports it from the channel
lifecycle. A failed synchronization request displays a retryable error while
the channel continues to report its actual connection
status. Reconnecting clients request missing revisions.
When the replay window is unavailable, the browser retains an unconfirmed draft
for export and reads the current document.
The browser uses the same recovery flow when one author replaces a complete
container, such as reordered table rows, while another edits its contents.
Positional OT cannot identify the edited content inside that replacement, so
the browser keeps the unconfirmed draft for manual reconciliation and opens
the committed document.

When the server rejects an editing batch, the browser terminates that editing
session and closes its channel. It keeps the local draft available for export
and offers a fresh document read. A reader who loses editing permission can
reopen the current document with viewing permission; losing all Page access
removes the editor. The retry action is available only for request failures in
an active editing session.

The browser stores unconfirmed content and title drafts in tab-local
`sessionStorage`, scoped to the Pod, Principal, and Page. On a browser reload,
the editor opens the server document and offers retained content drafts for
export and manual reconciliation. A restored title keeps its original base and
requires review when the server title differs. Confirmed content and explicitly
discarded drafts are removed from browser storage. If storage is unavailable,
the browser asks the author to export the draft before reloading or closing the
tab. This recovery copy never commits a document by itself.

Human and Agent title edits must carry the title the author began editing as
`expected_title`. `Ankole.Pod.Pages` compares it with the current title under the
Page row lock and returns `title_conflict` with the current title when the base
is missing, null, or different. The browser retains the
draft and lets its author choose the current title or explicitly submit the draft
against the reviewed title. Background refreshes never advance an unsaved draft's
base. Updates to other metadata need no title base. Body revision checks remain
independent of title changes.

### Version history

`Ankole.Pod.Documents.History` owns immutable `PageSnapshot` checkpoints.
Readers need `page_edit` to list, preview, export, or restore them: sharing the
current document with a viewer or contributor does not expose deleted historical
content. Each snapshot stores canonical body XML without comment marks, title,
icon, author, document revision, and timestamps. History exposes checkpoints from
the last 30 days and keeps at most 200 per Page, including checkpoints made before
and after a restore. Every append trims the Page's excess snapshots in the same
transaction. An hourly job removes expired snapshots from idle Pages in bounded
batches. Snapshots use the Page's existing attachment retention.

Creating a document establishes its first checkpoint. Before a meaningful body,
title, or icon edit, the owning Page transaction records the current confirmed
state if the last checkpoint is at least five minutes old. Identical states and
comment-only OT batches do not add checkpoints. The history viewer presents the
current document separately from saved checkpoints. No timer or background job
is needed to make this decision. Ordinary checkpoints show the content's last
modification time; restore entries show the restore operation time. The preview
also identifies when the snapshot was saved. Readers can compare a selected
version with the current document using Markdown additions and deletions,
including title and icon changes. The comparison renders from the two saved
contents independently of reference-name requests. Historical references show readable names and
open the referenced Page's current content. Exporting a version uses the same
attachment bundling contract as exporting the current document.

Restoring a checkpoint requires both the current content revision and Page
update timestamp, serialized as an ISO 8601 date-time string. The browser fetches
both values together when opening the restore confirmation. The server rejects
a stale restore so the caller can inspect concurrent content or metadata changes.
In one Page transaction, it saves a
checkpoint before restoring, computes the current-to-target ChangeSet, commits
that ChangeSet as a new revision, and saves the restored checkpoint. Revision
numbers always advance. The operation restores body, title, and icon; it does
not restore sharing, tree location, discussions, or their resolution status.
Current comment marks survive only where the diff preserves a complete marked
fragment as a contiguous range. Old snapshots cannot resurrect deleted anchors.
Other editors keep using the normal
OT protocol, including rebasing edits that were awaiting acknowledgement.

### Comments and anchored discussions

`Ankole.Pod.Comments` owns Page-scoped root threads and one level of replies.
`page_view` permits reading, while `page_comment` permits posting. Authors can
edit or delete their own comments; `page_manage` can manage other authors'
comments. The root author or a caller with `page_edit` can resolve, reopen, or
explicitly relocate a thread. Deleting a root with replies preserves a tombstone
and the remaining discussion. Posting a reply does not resolve or reopen it.
Every author is an existing Principal represented by `ActorRef`, including
Human and Agent authors; comments do not introduce an Agent execution path.
Asking an Agent about selected text goes through Page Chat (see
[Conversations](Conversations.md)), which carries the selection as a quoted
Page reference. Selecting text from a Page already referenced in the chat draft
adds the quote to that reference. Mentioning the same Page again preserves the
quote; choosing a new selection replaces the draft's previous quote.

A root may refer to the whole Page or to selected text. Inline
`<comment ids="…">` marks carry a set of root thread UUIDs through canonical XML
and OT. The set preserves overlapping discussions during concurrent annotation.
The server emits mark additions and removals for annotation changes, preserving
the underlying text identity, active selections, and concurrent text edits.
Text in ordinary blocks and code blocks can carry the same mark. The comment
record also retains its original quoted text and anchor revision. The server
computes the quote from the confirmed document, checks the caller's `base_revision`, and
commits the new thread and annotation in one Page transaction. It rejects marks
that refer to a missing thread or a thread on another Page.

The browser captures a selection from the actual editor tree and maps its
retained source tokens through local and remote OT transactions. Edits elsewhere
in the document do not invalidate the pending comment. Before creating or
relocating an anchor, the browser waits until the collaboration session has no
pending body changes, the local XML matches the confirmed XML, and no document
conflict requires recovery. It uses that confirmed body's revision for the
request. An unsaved title or a retained recovery draft does not block a confirmed
body's anchor; both still require attention before leaving the Page. An in-flight
body batch also protects navigation, even if later edits restore the confirmed
XML. If an edit deletes or replaces any of the
selected source text, the browser keeps the draft and asks for a new selection;
identical replacement text is not evidence that the source survived. Insertions
within a surviving selection update its displayed quote. Authors can continue
writing the comment while the document saves or the selection needs replacing;
submission becomes available when the selection is valid and saved. Native block
moves and one-time cut/paste within the same editor carry comment marks. Copying
or duplicating content, pasting it into another editor, and Markdown export omit
those marks so another document cannot inherit the thread. If all annotated text
is deleted, the thread remains readable with its saved quote and an explicit
missing-text state. Relocation requires a new selection; the system does not
guess a matching passage.

Comment text uses Markdown. Mutation versions protect edits and resolution
changes from stale writes. An edit draft keeps the version the author began
editing; an incoming update requires the author to review the latest comment
before continuing. The browser keeps unfinished drafts per Pod, Principal,
Page, and thread. A successful request consumes only its submitted text and
selection. The editor handle subscription refreshes the pending selection directly
from its native state field. Page notifications and reconnect reads refresh the Query cache.
Comment annotations advance the OT revision without changing document edit
attribution or creating a history checkpoint. Resolution state belongs to the
thread rather than the document mark. Resolved threads keep their anchors but
do not show a passive highlight or intercept normal document clicks. Clicking
overlapping open anchors shows the discussions at that location. On mobile,
following a quote closes the comment sheet and selects its text; a return action
reopens the discussion. Relocating a missing quote similarly returns the reader
to the document to select replacement text. The open discussion list refreshes
when its document revision falls behind, so deleting quoted text updates its
missing-text state.

Root threads record their latest activity time and actor. Activity updates do
not advance the root's mutation version, so replies leave an in-progress root
edit valid. Editing, resolving, relocating, or deleting the root still advances
its version. Threads are paginated by latest activity, so a new reply in an old
thread appears at the top. `PageUserState.comments_read_at` stores each
Principal's acknowledgment. The document header and comments panel show threads
whose latest activity came from another Principal after that acknowledgment,
provide an unread filter, and expose an explicit
mark-all-read action. That action acknowledges only the activity watermark the
reader received as an ISO 8601 date-time string; later activity stays unread.
Each discussion has a copyable `commentId` Page link that opens and locates the
thread, including a resolved
thread or one beyond the first page of results. Known thread IDs use a direct
thread read; the browser does not walk list cursors to locate them. The summary
uses database aggregates for counts and returns resolution state only for native
anchors in the current document. Each listed thread carries its own unread
state. Acknowledging activity notifies only connections for the same Principal.

`page_contents` stores canonical page-tree XML together with derived plain text.
The Rust kernel enforces the exact same XML vocabulary and normalization rules
as `@ankole/block-editor`, running the full pipeline—XML parse, normalize,
ChangeSet application, normalize, and XML serialize—and rejecting any write
whose serialized XML does not round-trip back to the identical document. Hard
bounds cap each document at `8,388,608` UTF-16 code units, `100,000` nodes, and
tree depth `128`. In the browser, editor transactions check these bounds before
replacing the live document or undo stack: rejected local edits leave the last
valid draft editable and show an error, while a remote/local merge that crosses
a bound preserves the local draft and prompts for explicit reset or reload.

### Agent document reads and writes

Agents read a document's Markdown, revision, and resolved `references` metadata
for any `<mention />` targets visible to the caller via `ankole-pod pages.read`,
which holds a shared page lock across the content read (and across any revision
replay up to the revision captured under that lock).

For `pages.write`, the Worker parses Markdown and prints XML using the shared
editor parser/printer, and streams the XML bytes over the signed WorkerFiles
relay rather than consuming the RuntimeFabric RPC frame budget. On the control
plane, `Documents.write` pre-validates the XML before opening the write
transaction, verifies Agent write authority, acquires the page row lock, and
checks page access, page type, and `base_revision` before either returning an
XML validation error or committing the parsed document. Under that page lock,
the Rust kernel computes a minimal ChangeSet—aligning unchanged blocks first,
then diffing changed child nodes and UTF-16 text spans with Myers diff without
ever splitting surrogate pairs—and verifies that applying the ChangeSet
reproduces the target document. Paragraph and heading conversions, heading-level
changes, data-cell and header-cell conversions, and bullet-list and ordered-list
conversions replace only the opening token while diffing their content in place.
This keeps pending human text inside the converted block and preserves comment
anchors on retained content. If the content changed, the transaction writes a
`PageChange` row with `client_id = "server:" <> principal_uid` and
`client_seq = new_revision` (browsers cannot claim the reserved `server:`
prefix); no-op writes leave the current revision unchanged.

Two higher-level Agent commands build on the same revision check and diff path:
`pages.append` appends Markdown blocks at `base_revision`, and `pages.patch`
reads Markdown at `base_revision`, applies exact string replacements, and
submits the resulting XML against that revision—rejecting the patch if a target
string is missing or matches multiple locations without `replace_all`, and
returning a revision conflict on any concurrent commit.

### Realtime socket, OT batches, and IME composition

Each browser tab opens one authenticated Phoenix socket at `/pod/socket` with
32 MiB frame and fragmented-message limits so maximum-size Unicode documents fit
on the wire. The browser starts HTTP reads and the `content` subscription in
parallel, so the page and directory render while the socket connects. A successful
join reconciles cached content in the background, replacing reads that started
before subscription with fresh reads. Authorized `tree_changed` events refresh
affected child lists and update their parents' `has_children` flags;
`page_updated` events patch titles and icons in the shared metadata collection.
Reconnecting reconciles cached content. Every 60 seconds,
the server checks admission and reevaluates the authorization context, notifying
the browser when evaluated subjects, grants, or groups change. `Pod.Access`
publishes committed permission changes from sharing, grant writes, moves across
ACL anchors, and Page trash or restore operations. Trash and restore can change
access to other Pages through Userset dependencies even when grants stay the same.
Related access notifications from one commit coalesce before delivery. The client retries
transient token-service errors and ends the subscription on access denial.
Changes to ancestor or Space policies, including moves across ACL anchors, refresh effective action
bits even when a Page's content revision has not changed, without unmounting the
open document editor or losing its local draft.

Open document editors join `page:<id>` and keep at most one immutable batch in
flight, keyed by `(client_id, client_seq)`. Before sending a batch, the client
runs `preparePageUpdate` locally and folds any normalization fixups into the
outgoing batch. The server accepts each `(client_id, client_seq)` once: reusing
a sequence number with different changes returns a conflict, while an ambiguous
transport failure retries the identical batch. If a channel broadcast confirms a
batch before its HTTP/socket reply returns, subsequent edits still wait for that
in-flight request to release its slot (including after a transport error). When
the server returns an explicit stale status, it attaches the missing commits
without applying the batch so the client can rebase, re-run `preparePageUpdate`,
and submit under a new `client_seq`.

`page_changes` retains the latest `pod.ot_replay_window` batches (default
`1,000`), pruned inside each write transaction; `page_changes` is strictly an OT
catch-up window rather than a user-facing version history. Clients that fall
behind the window—or whose catch-up payload would exceed the 32 MiB socket
budget—perform a full document reload while keeping unconfirmed local edits as a
recoverable draft. `PageDraft` accepts only the latest recovery read (invalidating
older in-flight reads when a newer read starts, the source changes, or the
editor disposes), never overwrites edits typed while the read was in flight,
never regresses the acknowledged revision, and rebuilds the editor instance only
when a read is accepted. If a reload fails, the draft remains available for
export and retry until the user explicitly discards it.

ACL edits, tree moves, Pod login-policy updates, and Guest access changes
re-verify topic membership immediately, while reconnects, tab-visibility
restores, and a 60-second version poll heal any missed broadcasts. Every
broadcast reflects state that has already committed in PostgreSQL.

During active IME composition, if a remote text edit shares the composing text
node's marks, the editor maps both endpoints through pending changes and
mutates only the affected UTF-16 range in the DOM, preserving native browser
composition underlines and caret position when earlier text shifts; structural
edits or mark mismatches cancel composition through the editor's standard path.
Finally, the editor host resolves Page `embed` blocks carrying `ref` and
`ankole:asset/<full-sha256>/<name>` URLs: inserting an inline subpage creates
the child Page in the tree first, deleting a direct child embed from the block
menu trashes that child Page. For a multi-block menu deletion, the editor sends
all selected embed references to `POST /api/v2/pod/pages/:id/embeds/delete`.
`Pages` checks the parent and each direct child's permissions in one tree
transaction and commits all child deletions together. A rejected child leaves
all children and their purge jobs unchanged. After success, the editor removes
the captured block selection if the document is still unchanged. Deleting a
block that refers to a Page outside this document's direct children leaves the
target and its directory entry intact. The browser refreshes the document's
child listing, while Page events update cached entries for children actually
deleted by the server. Deleting a reference via text selection or an Agent
rewrite leaves the target Page intact in the tree.

## Base

Navigating to a Base Page kicks off the table-list and initial table-schema
queries in parallel while editor code chunks load, sharing one query cache
between navigation and the editor (which renders read errors with retry buttons)
and recording at most one recent-page visit even if development-mode effects
replay.

`Ankole.Pod.Bases` owns table schemas, record writes, and queries. Tables,
fields, and views are Ash resources that inherit their host Base Page's access
and lifecycle. Each table has one primary text field (whose name and position
can change, though its type stays `text` and values cap at `2,048` UTF-8 bytes),
at most `200` active fields, and at most `100,000` records.

### Inline and physical storage modes

Bases transparently tier tables across two storage modes behind a single typed
read/write API:

- **Inline storage (`inline`)**: Holds standalone tables with no link fields, at
  most `2,000` records, and at most `4,194,304` stored data bytes (fixed system
  constants). Rows live in `base_records` in the control-plane database, where
  the generated `data_bytes` column computes `octet_length(data::text)` and each
  write sums those sizes into `base_tables.record_bytes`. Inline writes lock
  only their own `base_tables` row `FOR NO KEY UPDATE` and commit records, field
  versions, auto-numbers, counters, and the table's data version in one
  control-plane transaction.
- **Physical storage (`physical`)**: Crossing either size threshold—or adding a
  link field (which promotes both endpoint tables)—irreversibly promotes a table
  to `physical` storage on the tenant's assigned `base_db_id` shard via
  `Ankole.Pod.BaseRepo` under schema `t_<tenant_hex>`. Promotion locks table
  metadata `FOR UPDATE`, bulk-imports rows via a single JSON parameter and
  `jsonb_to_recordset` alongside index creation in one shard transaction, and
  then deletes the inline rows and flips metadata to `physical` (on retry,
  promotion drops any partial physical and referencing edge tables before
  re-importing from the authoritative inline rows).

In physical storage, tables are named `tbl_<table_hex>` and columns
`f_<field_hex>`. Text, number, checkbox, datetime, and auto-number fields map to
native `text`, `numeric`, `boolean`, `timestamptz`, and `bigint` columns, while
structured cells use `jsonb`; system columns store record ID, field versions,
timestamps, and authors. Indexes cover the primary key, primary text field
(`COLLATE "C"`), auto-numbers, and link edges. Text sorting and equality use `C`
collation to match the primary index, whereas case conversion and `ILIKE` use
the database locale. Per-table schema version, data version, row count, and next
auto-number live in the shard's `t_<tenant_hex>._table_states` table.

Physical record writes first acquire the Agent commit fence and `FOR KEY SHARE`
on sorted active page metadata rows in the control plane (allowing concurrent
inline writes on the same Page), then lock the target `_table_states` rows and
commit all business mutations in a single shard transaction without touching
control-plane counters. Under Ankole's lock order, every control-plane lock must
be acquired before opening the shard transaction (lock rank 12); once inside the
shard transaction, code may read over the existing control-plane connection but
must never open a new control-plane connection or take another control-plane
lock.

### Record batches, links, and schema changes

A `RecordWrite` batch contains up to `200` operations:

- **Optimistic concurrency**: Cell updates pass baseline versions only for edited
  fields, while record deletes pass the full field-version map, allowing edits
  to disjoint cells on the same row to succeed concurrently. Within one batch,
  later operations validate against the field versions produced by earlier
  operations in that batch, and any stale baseline rolls back the entire batch.
  Explicitly clearing a cell increments its field version even when the cell was
  already empty, and each modified table's version advances once per committed
  batch (tracked across both endpoints of any modified link via a single
  transaction journal).
- **Idempotent record creation**: Both the browser and the function SDK mint
  UUIDv7 IDs for creates before sending a `RecordWrite`. Retrying an ambiguous
  write reuses those UUIDs, whereas starting a fresh `create` mints a new UUID;
  the browser's create form keeps its UUID across validation/network retries
  until the write succeeds or the user closes the form. Submitting an already
  committed UUID hits the primary-key constraint and returns `record_exists`
  (HTTP 409) without duplicating or overwriting the saved row, letting the user
  close the form and view the existing record.

Link fields store ordered relationships in `lnk_<forward_field_hex>` edge tables
with cascading foreign keys, recording the edge table name and `src`/`dst` role
in field config. Single-value links enforce uniqueness via per-field UUID
constraint names (keeping indexes independent across fields in a tenant), while
multi-value links cap each cell at `2,000` ordered target IDs—though a one-way
child link may reference a parent that has more than `2,000` incoming children.
Deleting one direction of a paired link drops its cardinality constraint while
preserving the surviving field's edge table and values; turning off
two-way syncing splits the two fields onto independent edge tables. When
deleting a linked record affects up to `2,000` peer rows per field, Ankole
increments those peers' cell versions and timestamps directly; above `2,000`
peers, cascading foreign keys delete the edges, the peer table's version
advances, and the broadcast sets `resync: true` so clients refresh in full
rather than applying a partial delta.

Field and view DDL operations lock the Page's tables `FOR UPDATE` in ascending
ID order:

- **Field changes**: `Bases.Schema` writes control-plane Ash definitions first,
  and `Bases.DDL` owns stored value conversions across both `inline` and
  `physical` modes—validating final record byte sizes through the same owner as
  ordinary writes and committing atomically in each table's storage database. In
  physical mode, `Bases.DDL` executes a single shard DDL transaction that
  verifies prior schema versions, streams batches of existing values into a
  temporary PostgreSQL table before altering columns and edges, aborts on the
  first unconvertible cell unless `clear_invalid` is set, preserves cell
  versions on unchanged select values when option lists change, bumps
  `_table_states` versions, and runs best-effort `ANALYZE` after commit. Converting a field to a formula or system field drops its stored
  values and versions so reads compute from the formula or system columns;
  hitting PostgreSQL's 1,600 historical-column ceiling returns an actionable
  error asking the caller to copy the table; and deleting a field strips it from
  all saved view filters, sorts, groupings, field orders, visibility lists, and
  summaries in the same transaction.
- **View changes**: Persist view definitions in the control plane, bump the
  table's data version in its storage database so reconnecting clients spot
  missed updates, and broadcast `schema_changed` after commit without altering
  physical relations or the physical schema version.

Timeouts bound shard work tightly: ordinary shard writes inherit the 15-second
request budget while schema changes and promotions use a 60-second budget, with
the shard deadline set 2 seconds inside the control-plane deadline, enforced via
transaction-local statement/transaction timeouts and lock timeouts of 5 seconds
(records) or 2 seconds (DDL). Immediately before committing a shard write,
Ankole probes the parent control-plane connection, and any schema-version
mismatch aborts access and logs an operator error.

`table_access/3` maps `:read`, `:write_records`, `:manage_schema`, and
`:delete_table` to `page_view`, `page_write_records`, `page_edit`, and
`page_manage` on the host Base Page. Tables with incoming links from other
tables cannot be deleted; deleting an unreferenced table stamps `deleting_at`
(hiding it from ordinary reads) and enqueues a cleanup job that drops shard
objects before deleting control-plane metadata, with `PurgePage` resuming
interrupted cleanups and handling trashed Page subtrees.

### Formulas, queries, views, copies, and limits

`Ankole.Pod.Formula` parses single-record expressions into typed SQL. Formula
and system fields are read-only, evaluated at query time and returned inline in
mutation responses with no client-side formula engine or stored backfill. AST
references bind to stable field IDs—so renaming a field regenerates the human
formula string (`\]` and `\\` escaped) without changing semantics—while cyclic
references or deleting a referenced field are rejected, and division by zero
evaluates to `null`. Within a query, SQL evaluates each shared sub-dependency at
most once per row and short-circuits unselected conditional branches.

`Ankole.Pod.Query` compiles typed filters, multi-column sorts (appending record
ID as tie-breaker across mixed directions and nulls), keyset cursors (keeping
exact PostgreSQL text representations for `numeric` and `jsonb` keys to avoid
JavaScript float rounding), groupings, and aggregates—emitting JSONB expressions
for `inline` tables and native column/edge SQL for `physical` tables:

- Array equality checks both JSONB equality and containment, and author system
  fields accept either a single Principal UID or a UID list.
- Aggregate queries support up to two group fields plus date bucketing in
  `system.timezone` (`count` without a field counts rows; `count` with a field
  counts non-null values) and return `value_json` alongside formatted labels so
  per-group record queries `AND` that exact JSON value outside user filters.
- Large kanban boards fetch full-table group counts and paginate each column
  independently, resetting to page 1 whenever grouping, filters, or sorts
  change.
- Physical reads hold `FOR KEY SHARE` on control-plane metadata, open one
  `REPEATABLE READ, READ ONLY` shard transaction across records and
  `_table_states`, verify the schema version before returning rows, and count
  lock waits toward the statement timeout.

For small tables (up to `2,000` rows and `4 MiB` of serialized records,
formulas, and metadata—checked in PostgreSQL and flagged on the schema
independently of `inline`/`physical` mode), the browser may load a full snapshot
and run local filters/sorts only when they match PostgreSQL semantics exactly.
Numeric comparisons, numeric formulas, `sum`, `average`, and locale-dependent
operations when the database locale is unsupported always route to the server so
JavaScript `Number` arithmetic never approximates PostgreSQL `numeric`
precision (verified by shared cross-runtime fixtures). Local evaluation requires
matching schema and snapshot data versions—falling back to the server and
invalidating both caches on any mismatch, promotion, or `resync`—and refreshes
the schema before applying incoming record deltas.

Built-in Base views are strictly `grid`, `kanban`, and `gallery`—pure record
browsers sharing one query, mutation, permission, and realtime contract (whereas
calendars, timelines, forms, and charts belong in Applets calling the Base API).
New kanban views default to grouping by the first single-select field when
present, kanban and gallery cards show the primary field title plus configured
card fields while the detail drawer shows all fields, dragging a kanban card
updates its grouping field via a normal `RecordWrite`, and invalid inline embed
configs (or unsupported view types) stay editable with a one-click repair to
`grid`. Newly created fields, reverse link fields, and views append at the end
unless given an explicit position under the table lock (self-links also reserve
the forward field's position up front).

`base.copy` copies a single table—applying its source filter—into a new
standalone `base` Page at a Space root, Private root, or parent Page while
holding source metadata locks:

- Records stream in batches through a transaction-scoped temporary control-plane
  table into destination storage (`inline` when within the inline thresholds, or
  directly into the tenant shard otherwise), assigning fresh UUIDs and adding
  new references to existing attachment blobs without copying bytes, so later
  edits to the source table never affect the copy.
- Link fields flatten into `text` fields containing the linked records' primary
  titles joined by `", "` in link order (`null` when empty, fetching titles per
  batch).
- Copied formulas rebind to the copied fields and re-typecheck: formulas whose
  inputs changed to incompatible types freeze into ordinary fields populated
  with their current values (arrays serialized as JSON text, scalars keeping
  their value type), while compatible formulas stay live.
- Copied views remap field IDs and preserve filter/sort values, narrowing
  filters on type-changed fields to `is_empty` and `is_not_empty`.

`pod.base.limits` defines four configurable per-tenant defaults, and queries or
writes exceeding these bounds fail explicitly:

| Key | Default |
| --- | --- |
| `query_rows` | 1,000 |
| `record_bytes` | 1,000,000 |
| `group_count` | 1,000 |
| `statement_timeout_ms` | 5,000 |

`query_rows` caps standard paginated reads, while `statement_timeout_ms` bounds
both record and aggregate queries across `inline` and `physical` modes (on a
shard connection, physical queries apply the lesser of the tenant timeout and
the remaining request deadline).

## Files and Conversation origins

`Ankole.Files` manages one site-wide blob store and the `drive_files` reference
table, where Agent drives set `agent_uid` and the shared Pod drive sets
`agent_uid` to `NULL` (enforced by a unique index that treats nulls as equal).
Pod file references live under `pages/<page-id>/`, and `Ankole.Pod.Files`
authorizes the owning Page before serving any file. Replacing a file Page
commits the new bytes and revision atomically, while document assets and Base
attachments embed the full SHA-256 digest in their path and remain available
after document edits until the Page itself is purged; see [Files](Files.md).

File Pages render in-browser previews for PDFs, images, audio, video, workbooks,
and presentations. Workbook and presentation viewers lazy-load their rendering
libraries and stream bytes from the authorized Pod file URL without sending
files to any external service—supporting sheet switching for workbooks, slide
switching for presentations, and original-file downloads (preview fidelity
follows supported format features and installed fonts; online Office editing is
outside v1 scope).

Native Conversation messages carry Page links and verified attachments:

- **Uploading and viewing in Chat**: Humans can upload, paste, or drop files in
  Chat without creating a Page. `Ankole.Files` stores the underlying blobs while
  accepted Messages record canonical attachment metadata under per-message
  incoming paths so subsequent Agent drive edits cannot alter bytes attached to
  earlier messages. Downloads verify current Chat membership and read those
  frozen blobs; losing access to a Page blocks new Page-context prompts without
  revoking a participant's personal Chat attachments. Unsent local attachments
  survive panel toggles and route changes (protected by the page-unload guard,
  though a full browser reload before message acceptance requires re-selecting
  local files). Clicking an image or text attachment opens a read-only modal in
  Chat backed by the authorized attachment URL—restoring focus and canceling
  in-flight fetches on close, keeping download and open-in-new-tab controls, and
  streaming a bounded prefix for text files with a truncation indicator—without
  creating a Page.
- **Saving to a Page and message provenance**: Saving a Chat attachment to a
  file Page references the visible Message's blob directly without granting
  access to the Agent's drive or duplicating blob bytes, so later overwrites to
  the source drive path never mutate the saved attachment. Created Pages record
  `saved_from_message_id` (rendering a deleted badge if the source Message is
  deleted, exposing zero Conversation metadata if the Conversation is
  inaccessible, and keeping Pages and Pod file references intact if the
  Conversation itself is deleted). When an Agent creates a Page, the RPC broker
  defaults `saved_from_message_id` to the current input's Message—or traces a
  Job completion wakeup back through its persisted Job to the originating Human
  Message across continuations until a new Human message starts a continuation,
  staying strictly within the same Agent and tenant and halting on cycles or
  missing messages.

## Applets

`ankole-pod applet init`, `build`, `publish`, and `pull` share a single React
ESM project layout. Bun compiles the browser entrypoint to `dist/main.js`
alongside shared chunks, CSS, and `dist/index.html`:

- **Imports and bundling**: Seven host packages resolve via the frame's import
  map (`react`, `react/jsx-runtime`, `react/jsx-dev-runtime`, `react-dom`,
  `react-dom/client`, `@ankole/uikit`, and `@ankole/applet-sdk`), while all
  other NPM dependencies bundle into the Applet. Dynamic `import()`, WASM, CSS
  assets, and media imports (which emit standalone assets resolved relative to
  the importing module) follow standard browser ESM and Bun rules. Files
  matching `*.worker.ts` or `*.worker.js` compile to matching `dist/*.worker.js`
  entries; importing `import workerURL from './calculation.worker.ts?url'` (typed
  by the project scaffold) and calling
  `new Worker(new URL(workerURL, import.meta.url), { type: 'module' })` loads a
  wrapper entry at the compiled Worker's output path so nested relative URLs
  keep the same base.
- **Publishing and pulling**: A project may also include `src/server/main.ts`
  (bundled by Bun into `server/main.js` with Node built-ins kept as `node:`
  imports) and an optional flat string map `applet.env.json` (up to `64 KiB`,
  injected as `process.env` into that publication's function worker). A
  publication manifest covers `src/`, `dist/`, optional `server/main.js`, and
  optional `package.json`, `bun.lock`, `tsconfig.json`, and `applet.env.json`.
  Publishing swaps all paths atomically and increments the Page revision by one,
  requiring every content digest to exist in the publishing Agent's drive or on
  the target Page, and running route inspection (with the published environment)
  before acquiring the Page write lock to reject invalid handlers or top-level
  host calls. `dist/` and `assets/` require `page_view`, whereas `src/`,
  backend, and root project files require `page_edit` (all other Applet paths
  are rejected across the manifest, HTTP downloads, and Worker transfers; Base
  record attachments require `page_write_records`, and document assets or
  file-page uploads require `page_edit`). Conversely, `applet pull` requires an
  absent or empty target directory, downloads source and root files into a
  temporary directory owned by the Agent user, verifies digests, runs
  `bun install --ignore-scripts` as the Agent user when `package.json` is
  present, and moves the verified tree into place.

### Same-origin iframe, storage, and frontend SDK

Each Applet mounts inside a same-origin iframe at
`/pod/applet-frame/:authentication_ref/:id/:revision/*path`, where
`:authentication_ref` pins a sealed browser authentication proof for the
document and all subresources—unaffected if the user switches the browser's
default account elsewhere. The iframe isolates its own DOM, CSS, viewport
(sized to the workspace scroll panel, scrolling tall content internally), and
import map while sharing the host origin and trust boundary. Frame responses
serve hashed vendor bundles and styles from the Vite manifest with exact MIME
types, `nosniff`, `SAMEORIGIN`, private revalidation, and content ETags: a
shared Page lock authorizes access and captures the revision and immutable blob
digest (returning HTTP 409 on a stale revision), while blob streaming runs
outside the transaction.

Before the Applet entry executes, the host injects the runtime and scopes Web
Storage keys by `(principal_uid, page_id)` using the Principal UID from the
verified authentication proof while preserving the native `Storage` prototype,
methods, named properties, and key enumeration. Each mounted revision forms one
generation owning the frame's subscriptions, channels, and observers:

- Publishing a new revision or unmounting closes the generation (a publication
  conflict refreshes the Page snapshot without replaying a write).
- Permission changes push updated `actions` props into the live iframe and React
  root without losing form inputs or component state; individual denied business
  writes likewise leave the frame intact, whereas losing `page_view` (via Page
  reads or realtime checks) closes the generation.
- Render crashes caught by the SDK error boundary—and frame load failures—render
  above the iframe alongside a Reload button that clears the error state and
  starts a fresh generation.

`@ankole/applet-sdk` calls Pod APIs as the signed-in Human through a shared
`QueryClient`, multiplexing schema and snapshot events over one socket
subscription per Base table and keeping a `ContentProvider`-owned read-denial
observer across Applet generations until the Pod unmounts:

- **`useRecords` and `useAggregate`**: Maintain live subscriptions. On the first
  authoritative HTTP `401`, `403`, or `404` (including during a Query retry),
  all subscribers share a sticky denied state, hide cached rows, and stop
  joining the table channel until a fresh read succeeds; transient network
  errors before a denial keep prior data.
- **Record mutations**: Updates and deletes pass the field versions captured
  when editing started (keeping attempted values and versions on failure;
  settling an attachment upload closes that cell edit so the next edit reads
  fresh versions). Pending updates preview optimistically outside the confirmed
  cache, whereas creates and deletes appear once confirmed by the server (which
  owns auto-numbers, formulas, and filter/page membership; failed creates keep
  form input and failed deletes keep the confirmation dialog).
- **`useChannel`**: Joins `applet:<page-id>:<room>` for ephemeral messages and
  presence, rechecking each recipient's authentication, Pod login policy, and
  Page access before every delivery and closing the subscription on denial.
  Applets may also call `fetch`, while the server enforces all Page and Base
  authorization.

### Backend routes

An Applet's `src/server/main.ts` exports a map of `METHOD /path/:parameter`
handlers supporting `GET`, `POST`, `PUT`, `PATCH`, and `DELETE` (matching
literal segments before `:parameter` segments, URL-decoding path parameters,
grouping repeated query keys into arrays, and keeping bracketed query keys
literal). Handlers receive `{ method, path, params, query, body, principal,
pageId, revision, timezone }` with zero credentials: returning a JSON value
sends HTTP `200`, returning `undefined` sends `204`, throwing
`AnkoleRuntime.HttpError` returns the specified `4xx` status, and uncaught
errors return a generic browser message (while Agent calls via `applets.call` /
`ankole-pod applet call` also receive bounded diagnostics and console output).

Browser requests hit `/api/v2/pod/pages/:id/routes/*path` under standard Pod
session + CSRF checks and must send `x-ankole-applet-revision` (Agent RPC
`applets.call` enters the same `Ankole.Pod.Applets.Invocation` owner under the
Agent's active write fence). Admission locks the Page to verify access and the
loaded revision/package. Applet execution and each host capability call require
a live Applet Page, so moving it to Trash closes those entry points. A stale
revision returns HTTP `409`
(`applet_revision_changed`), prompting the host to reload the Page and swap in
the latest publication without replaying a failed mutation.

Backend handlers run on `ankole-function-runtime`—a stateless service built on
Supabase Edge Runtime `v1.77.4` (`d4a4f606a90e8c66864219c9b1d31ef0e3e3f626`)
with native patches under `app/function_runtime/native/patches`:

- **Worker pooling and cache identity**: The runtime's main worker authenticates
  control-plane calls via an internal Bearer token, while user workers receive
  only the Applet's published `applet.env.json`, pooled by `(tenant, page,
  revision)` for up to five minutes with `AsyncLocalStorage` isolating each
  request's capabilities, console logs, and cancellation to its own WebSocket.
  Code and environment hash together into one SHA-256 cache key (UTF-8 source +
  `\n` + compact JSON of environment pairs sorted by UTF-16 key code units).
- **Replica admission and failover**: The control plane tracks active process
  leases across `Ready` replicas, picks the least-occupied replica, and sends an
  HTTP preflight returning `204` (reserving one slot), `428` (upload missing
  code first, then open the WebSocket), or `503` (at capacity; only a
  pre-admission connect error or preflight `503` allows one retry on another
  replica—executed code and capability writes never replay). Closing the
  WebSocket settles the slot with an authenticated `DELETE` (bounded by the
  call's wall-time limit if abandoned), while caller exit, cancellation,
  timeout, or disconnect settles `Ankole.Pod.Applets.Invocation` once and stops
  pending capability tasks. Replica health checks report process liveness
  independently of busy invocation slots.
- **Transport, isolation, and limits**: Pending HTTP/1 Applet requests buffer at
  most `1,048,576` bytes of pipelined client data (including initial read
  buffers)—closing the socket and canceling the invocation on overflow while
  keeping already committed capability writes, or preserving queued requests
  within budget; HTTP/2 stream resets cancel via the transport reset frame.
  `pod.applet.limits` sets wall-time and heap ceilings alongside per-worker CPU
  quotas enforced by the native supervisor on each poll (including when soft and
  hard CPU limits match; each user worker runs on its own native thread plus an
  optional Tokio blocking helper so a tight JS loop cannot starve sibling
  workers, and resident worker count is tracked separately from active
  invocations). Workers may use `node:crypto`, an isolated `/tmp`, published env
  vars, and outbound `fetch`, with zero DB credentials or persistent volumes;
  Kubernetes Helm `NetworkPolicy` blocks private/metadata CIDRs when enforced,
  and single-host Compose places the runtime and control plane on
  `ankole_functions` while isolating PostgreSQL on `ankole_backend` (with host
  firewall and cloud metadata rules governing external egress).
- **One-shot workers, cancellation, and deadlines**: Route inspection and PTC
  run in dedicated one-shot workers retired immediately afterward (PTC returns
  execution failures as structured JSON over HTTP `200`, mapping heap exhaustion
  to `program_heap_limit_exceeded` and CPU/wall timeouts to `program_timeout`).
  Shutting down a user worker terminates its child request while preserving the
  main worker's response; HTTP client disconnects settle the native request once
  and kill unowned one-shot workers (even inside synchronous JS). Aborting a
  pooled Applet invocation evicts that worker from future pool selection before
  reporting completion—letting other in-flight calls on it finish while routing
  new calls to a fresh worker and capping runaway synchronous JS at the CPU
  limit. Hitting the end-to-end call deadline (which includes replica admission
  and worker boot; expired calls never start a handler) returns `504
  handler_timeout` even if the native socket closes simultaneously.

Inside a handler, `AnkoleRuntime` exposes domain capabilities bound to the
caller's Principal and tenant, while the Elixir control plane owns every durable
business write:

- **Base and File capabilities**: `base.schema`, `base.query`, `base.aggregate`,
  `base.write`, `file.list`, `file.read`, and `file.write` re-verify
  authorization on every call, requiring `page_view` on the Applet plus target
  permissions (`page_write_records` for Base records/attachments, `page_edit`
  for files) and active `RunRef`/Job authority when called by an Agent (while
  the frontend SDK surfaces the Applet Page's `actions` and the target Base API
  authorizes record writes). `GET` routes cannot invoke write capabilities. Base
  writes enforce normal field-version conflicts and broadcasts, and capability
  calls do not span a multi-call transaction—guarded updates read field
  versions, write against them, and reread on conflict. File capabilities follow
  the standard page-type and revision rules and enforce the Worker transfer byte
  cap up front, passing bytes as `Uint8Array` (including empty files).
- **`ai.generateText`**: Resolves a logical model profile (`model`, `effort`,
  optional `system`, and `prompt`, falling back from missing `light` to primary
  and rejecting raw provider/model strings) belonging to the Agent recorded in
  the Applet Page's `created_by`, charging that Agent's token quota and
  returning `{ text, finishReason, usage }`. Missing/disabled creator Agents
  fail with `ai_not_configured`, invalid model/effort parameters return `422`,
  exhausted quotas return `429`, and upstream provider failures return `502`.

On the frontend, `useRoute` and `useRouteMutation` wrap TanStack Query—interpolating
route params, forwarding Query options/results, keying caches by loaded
publication revision and Principal identity, aborting in-flight queries on
unmount, hiding cached data on authoritative `401`/`403`/`404` while keeping
prior data on transient errors, and performing no optimistic updates or
automatic cache invalidation so Applets explicitly invalidate keys via their
shared `QueryClient` and `routes.key()`. Backend routes cannot create Pages or
Base schemas, schedule jobs, subscribe to events, access host connectors or
secrets, stream responses, or return binary HTTP bodies, and reading Applet
source, backend bundles, or `applet.env.json` requires `page_edit`. When an
Agent verifies an Applet visually, its Worker browser runs under a dedicated
profile via the browser runtime contract, returning the saved Page link and a
summary of verified interactions.

## Verification

Unit and integration suites across the domain, endpoints, Phoenix channels, SDK,
query compiler, and block editor verify their respective contracts: PostgreSQL
integration suites use independent transactions to test concurrency, trash
purge, tenant teardown, and large-table thresholds; the shared Rust/editor
corpus checks XML/document equivalence after every edit batch; and the
function-runtime suite exercises real workers and cancellation.

End-to-end, `test:pod` drives real browser user flows through the production Pod
bundle, SDK, Phoenix endpoints, and PostgreSQL, while `pod_content_real_llm`
starts from a Human prompt, lets an Agent author and publish Pod content through
the Worker CLI, and verifies the rendered result in an authenticated Human
browser. See [Pod content checks](../../CONTRIBUTING.md#pod-content-checks) for
commands and fixture setup.

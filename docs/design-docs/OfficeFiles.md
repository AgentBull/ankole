# Office Files

An Office Page is a file Page that people open, read, and edit in the browser
while the stored object stays a standard Office file. Pod supports three kinds:

| Kind | File names | Engine | Kernel crate | Editing unit |
| --- | --- | --- | --- | --- |
| Spreadsheet Page | `.xlsx`, `.xlsm` | [GridCraft](https://github.com/storytold/gridcraft) | `ankole_spreadsheet` | Cell or range on a sheet |
| Word Page | `.docx`, `.docm` | [WordCraft](https://github.com/storytold/wordcraft) | `ankole_word` | Top-level block (paragraph or table) |
| Presentation Page | `.pptx` | [DeckCraft](https://github.com/storytold/deckcraft) | `ankole_presentation` | Slide |

`Ankole.Pod.OfficeFiles` owns all three formats: the operation log, compaction,
version history, and the Agent RPC contract. Each kernel crate owns what
differs between formats: the document model, canonical wire operations, and
unit-level conflict and rebase rules. Each browser editor runs its kernel crate
as WebAssembly inside a dedicated Web Worker and renders the interface with
Pod's own UIKit components.

## User flows

- **Create.** The Page creation menu offers a blank spreadsheet, Word
  document, or presentation alongside documents and Bases. Uploading or saving
  an Office file to a file Page makes that Page an Office Page as well.
- **Read.** Opening an Office Page lays out the file as its native application
  does: a workbook on a grid, a Word document across pages, or a presentation as
  slides with a thumbnail rail. A viewer without `node_edit` receives the same
  view with text selection, clipboard copy, in-document find, and live updates.
  Chat attachment previews and Pod file previews share the same Worker
  renderers.
- **Edit.** An editor with `node_edit` types, formats, and rearranges content
  in place on desktop and narrow viewports alike (narrow viewports collapse the
  side rail and secondary toolbars into compact menus while keeping full edit
  access). Each completed editing step saves automatically without a manual Save
  button or a whole-file checkout lock. When someone leaves a Word or Presentation
  Page within Pod, the editor waits for outstanding changes to be acknowledged.
  If it cannot save them, Pod keeps the editor open and offers an explicit choice
  to stay or discard the changes.
- **Collaborate at unit granularity.** Collaborators and Agents edit the same
  Page concurrently through unit-level isolation rather than character-level
  OT. Presence highlights the cell, top-level block, or slide that each
  collaborator is actively editing and soft-locks that unit in the interface so
  peers do not type over an uncommitted draft. Edits to disjoint cells,
  top-level blocks, or slides both commit; when two concurrent requests touch
  the same unit or shared document-wide state, the first request commits and
  the second editor replays the missed change and reports which unit to edit
  again.
- **Present.** A presentation plays full screen, slide by slide, with keyboard
  and pointer navigation.
- **Restore versions.** Version history lists retained states of the file and
  restores any version.
- **Download and export.** Downloading an Office Page returns the Office file
  with every committed edit included. Word and Presentation Pages also export
  to PDF in the browser Worker.
- **Search.** Pod search and Brain index the text of every Office file,
  including browser and Agent edits, and opening a search result jumps to the
  matching sheet, page, or slide.
- **Convert a Word Page to a document Page.** One action creates a native
  document Page from a Word Page so teams can switch to Pod's block editor,
  mentions, embeds, and character-level collaborative editing inside a
  paragraph while keeping the original `.docx` Page intact.
- **Collaborate with an Agent.** Agents inspect, render, and edit Office Pages
  through the same operation log, so collaborators watch Agent edits arrive in
  real time and can step back through version history.

## Shared pipeline

The file node's current object holds the authoritative Office bytes, and the
logical document equals that object plus the operations in `pod_office_ops`
whose `compacted` flag is `false`. The Page row's `revision` keys every log
entry, and `pod_file_caches` stores extracted search text and metadata per
Page.

| Step | Contract |
| --- | --- |
| Bootstrap | `GET /api/v2/pod/pages/:id/office` returns the Page `revision`, the `format` (`spreadsheet`, `word`, or `presentation`), the current file (`path`, `object_id`, `sha256`, `size`), the optional `checkpoint` from `pod_office_checkpoints` when present for that `object_id`, the uncompacted operations in revision order, and, for a spreadsheet with `subtype == :spreadsheet` and `extract_status == :ok`, the cached workbook metadata. The browser downloads the file pinned to that `sha256` and opens it with any accompanying `checkpoint` before replaying the operations in its Web Worker; if compaction replaced the object in between, the pinned read returns `manifest_changed` and the editor bootstraps again up to three times before offering manual retry. |
| Commit | The editor sends one canonical operation at a time on the page channel (`office:apply`) with `base_revision`, `client_id`, and `client_seq` (after a 30 ms send delay while queuing subsequent local edits behind the in-flight request). `OfficeFiles` opens the cached or stored document outside any database transaction, then under the Page row lock asks the kernel to rebase the operation over entries committed after `base_revision`, stamps the authenticated actor's display name onto any comment or tracked-change author fields, advances `page.revision`, and inserts the committed `pod_office_ops` entry. Retrying the same `(client_id, client_seq)` acknowledges the original commit; submitting a different payload under an existing `(client_id, client_seq)` returns `client_sequence_conflict`. |
| Conflict | Whenever rebasing would have to guess—two edits touch the same unit, a structural edit overlaps, an allocated identifier collides, or cross-block markers become unbalanced—the kernel rejects the operation with `office_conflict`, carrying the kernel `reason`, current `revision`, and missed `changes`. The editor applies those missed entries to its confirmed document, drops the conflicting local edit, and reports which unit changed. |
| Broadcast & Presence | Every committed change pushes `office:changes` with entries after the channel's last revision; `office:sync` replays entries after a caller-supplied revision (setting `reset_required` when the replay exceeds the 32 MiB message budget or reaches past pruned entries); `office:presence` updates the sender's `selection` (at most 4 KiB or `null`, throttled to 250 ms) and sets `mode` to `"editing"` only while an authorized `node_edit` caller holds an active uncommitted draft on a unit (mere navigation sends `"viewing"`). Closing the tab or disconnecting clears Presence automatically without durable lock rows. |
| Compaction | Every commit schedules the Page's single `Ankole.Pod.Jobs.CompactOfficeFile` job `compaction_idle_seconds` in the future; reaching `compaction_op_threshold` uncompacted operations, reaching `compaction_structural_threshold` structural spreadsheet operations, committing an operation that carries embedded media bytes, or having the last editor leave the channel moves that wakeup to now. `CompactOfficeFile` exports a pure ECMA-376 archive via `office_export_with_checkpoint/1` outside any transaction and writes a new Drive object, then under the Page row lock updates the node via `Ankole.Pod.Files.Content.rewrite_in_tx/2`, upserts any Word or Presentation `checkpoint` sidecar in `pod_office_checkpoints` (`(tenant_id, page_id)` guarded by `object_id`), marks the exported operations `compacted`, updates search state, records a history `checkpoint` when due, and prunes compacted entries older than `pod.ot_replay_window` revisions without advancing `page.revision`. |
| Reads | A file manifest, any Pod file read or download without a pinned `sha256`, and the Agent `files.get` RPC call `OfficeFiles.flush_if_dirty/1` first (which costs a single index probe when no uncompacted rows exist). Worker Drive mounts read the object from the latest compaction and refresh when its commit event arrives. |
| Outside writes | A Pod upload, an Agent Drive write, or a version restore commits through `Ankole.Pod.Files.Content.commit_in_tx/4`, which calls `OfficeFiles.object_committed_in_tx/3` in the same transaction to mark prior operations `compacted`, delete any `pod_office_checkpoints` row for the Page, advance `page.revision`, and append a `reset` entry. Pod uploads and restores flush pending operations into the current object and check under the Page lock that the object includes every committed edit. If another editor commits in between, the upload reports `manifest_changed` and a restore retries the flush. Raw Drive writes replace the object directly. |
| Versions | `GET /api/v2/pod/pages/:id/office/versions` lists retained snapshots newest first and `POST /api/v2/pod/pages/:id/office/versions/:version_id/restore` records the current state as `before_restore`, restores the chosen version's object and filename, and appends a `restored` snapshot. Both require `node_edit`. Office snapshots store `object_id` instead of XML in `page_snapshots` and share document history's five-minute checkpoint interval, 30-day retention, and 200-snapshot cap (`created`, `checkpoint`, `uploaded`, `before_restore`, `restored`). |
| Comments | File-level `page_comments` remain unanchored whole-Page threads on Office Pages so compaction updating `object_id` leaves comment threads active; cell notes, Word passage comments, and slide comments live inside the Office file itself. |
| Limits | `pod.office.limits` configures per-tenant bounds: `max_file_bytes` (default 20 MiB), `compaction_idle_seconds` (30), `compaction_op_threshold` (100), and `compaction_structural_threshold` (10). |

`OfficeFiles.kind/1` derives the format from the file name—returning
`:spreadsheet`, `:word`, `:presentation`, or `nil` while ignoring letter case
and Drive's duplicate ` (n)` suffix—so the Page `type` remains `file`.
`POST /api/v2/pod/office-pages` accepts `format` (`spreadsheet`, `word`, or
`presentation`) and creates a blank Office file named after the optional title
(`Untitled.xlsx`, `Untitled.docx`, or `Untitled.pptx` by default). Uploading a
file with a different extension switches the channel Presence and browser view
to match the new file's format.

The control plane calls the kernel through `DirtyCpu` NIFs—`office_create_blank/2`,
`office_open/3`, `office_open/4`, `office_apply/4`, `office_export/1`,
`office_export_with_checkpoint/1`, `office_inspect/2`, `office_commands/2`,
`office_apply_commands/3`, `office_render_png/3`, and
`office_word_to_document/1`. `OfficeFiles.NodeCache` keeps at most 64 opened
documents across all formats on each control-plane node and evicts idle entries
after ten minutes; a cache miss reopens the Page's current object with any
matching `pod_office_checkpoints` row and replays uncompacted operations from
PostgreSQL.

### Kernel contract and wire compatibility

Each kernel crate acts as the stateless anti-corruption layer over its upstream
engine, loaded both by the control-plane NIF and by its browser Web Worker
(starting cross-origin development Workers through a same-origin Blob module
under CORS rules and revoking the Blob URL on teardown). Each Worker maintains
a confirmed document matching the server's acknowledged `revision` plus a local
session holding in-flight operations and any active unit draft.

When `CompactOfficeFile` exports a Word or Presentation Page,
`office_export_with_checkpoint/1` writes a pure ECMA-376 package with zero
custom XML parts or proprietary namespaces alongside a deterministic
`checkpoint` JSON payload capturing runtime editor identifiers (`PartId`s,
comment keys, `SlideId`s, `ShapeId`s, `LayoutId`s, `MediaId`s, and `next_id`).
`OfficeFiles` stores that payload in `pod_office_checkpoints` keyed by
`(tenant_id, page_id)` and guarded by `object_id`, and both the NIF and browser
Worker pass it to `open_with_checkpoint` so collaborators submit operations
against the same revision across compaction without reloading. WordCraft and
DeckCraft allocate fresh identifiers whenever a file opens without a checkpoint
or after an outside write deletes the sidecar row.

- **Spreadsheet operations** serialize as single typed edits addressing sheets
  by stable `sheet_id` and cells by A1 coordinates.
- **Word and presentation operations** serialize as atomic `ChangeSet` values
  (`{"model_version": 1, "edits": [...]}`) so commands that mutate both a
  content unit and a supporting map entry (such as inserting a picture or a
  footnote) commit or reject together. Each kernel crate validates payloads
  against its wire schema, wraps binary payloads in standard base64, and
  rejects any serialized operation exceeding 4 MiB (accommodating a 2 MiB
  picture encoded as base64).
- **Stateless identifier allocation.** Neither `ankole_word` nor
  `ankole_presentation` rewrites engine-allocated identifiers across operations.
  Because editors commit at unit boundaries rather than per keystroke, two
  collaborators allocate colliding part, comment, media, revision, slide, or
  shape identifiers only when both insert new objects within the same network
  round trip; `apply` rejects the second request with `office_conflict`
  (`identifier_taken` or `concurrent_revision`).
- **Rolling-upgrade safety.** Each kernel crate replays operations written by
  earlier pinned revisions, and stamps `model_version` on every Word and
  presentation `ChangeSet`. If a node or browser Worker encounters a higher
  `model_version` than it supports, the control plane returns `office_busy` (so
  the browser retries up to five times at 200 ms intervals) and an older
  browser Worker prompts the user to reload.

`app/kernel/Cargo.toml` pins `rust-version = "1.95"`, aligns `ankole_word` and
`ankole_presentation` on one shared `storytold/craft-libs` revision alongside
the upstream `krilla` and `storytold/egui` patches, and `scripts/build-wasm.ts`
sets `CRAFT_I18N_DIR=""` and `CRAFT_FONTS_DIR=""` so host files never leak into
WASM or NIF builds. Real-world corpora under `test/fixtures/<kind>/corpus` verify
that every file opens, exports, and reopens cleanly across engine upgrades.

### Search indexing

`Ankole.Pod.FileExtraction` owns `PageSearchDocument` indexing across file
Pages. When `CompactOfficeFile` writes a `.docx`, `.docm`, or `.pptx` object, it
calls `FileExtraction.enqueue_sync_in_tx/2` without purging the existing
`PageSearchDocument` row, keeping the Page searchable while `SyncFileCache`
extracts text from the new OOXML archive in the background (which also indexes
files larger than `max_file_bytes`). Spreadsheet compaction writes kernel-derived
plain text directly inside the compaction transaction because displayed cell
text depends on formula evaluation and number formatting.

### Errors

| Code | Meaning |
| --- | --- |
| `office_conflict` | The kernel rejected a rebase that would require guessing (`block_changed`, `slide_changed`, `slide_deleted`, `slides_reordered`, `container_deleted`, `container_changed`, `field_changed`, `identifier_taken`, `concurrent_revision`, `unbalanced_markers`, `target_deleted`, `sheet_deleted`, `overlapping_structural_edit`, or `concurrent_sort_or_merge`). |
| `office_busy` | The node cannot serve the Page right now; the editor retries after 200 ms, up to five attempts. |
| `office_full` | Applying the operation would push the file plus uncompacted log bytes past `max_file_bytes`. |
| `invalid_office_file` | The kernel cannot parse the file; the Page offers the original-file download. |
| `file_too_large` | The file exceeds `max_file_bytes`; the Page skips Worker startup and offers the original-file download. |
| `document_too_large` | Converting a Word Page exceeds `page_document` limits (`8 MiB` UTF-16, `100,000` nodes, or `128` depth). |
| `client_sequence_conflict` | A client reused `(client_id, client_seq)` with a different operation payload. |

## Spreadsheet Pages

`ankole_spreadsheet` wraps GridCraft over `.xlsx` and `.xlsm` workbooks. Each
operation targets a sheet by stable `sheet_id` and cells by absolute A1
references. Under the Page row lock, the kernel rebases incoming operations over
intervening commits: row and column inserts or deletes shift target coordinates
and rewrite formula references, and sheet renames rewrite cross-sheet formula
references. When target cells or sheets were deleted, structural edits overlap,
or a concurrent sort or merge intersects the target range, `apply` returns
`office_conflict`. Auto-sized rows recompute their height from cell font sizes
and wrapped line counts using GridCraft's glyph-width estimator so the control
plane and browser Workers agree on row heights until an author sets an explicit
pixel size with `line.resize`. Volatile functions such as `NOW()` recalculate on
each compaction export.

- **Operations and range tools.** Operations cover typed values (`cell.set`,
  `range.set_values`), formats, merges, row/column inserts and resizes, cell
  shifts, moves (`range.move`), sheets, notes (`comment.set`, stamped with the
  authenticated actor's display name), sorting, filters (`filter.set`), data
  validation (`validation.set`), and tables (`table.toggle`). `range.fill`
  extends numbers, numbered text, or weekday/month/quarter lists in `series`,
  `copy`, `values`, or `formats` mode while shifting relative formula
  references; `range.paste` writes copied cells with relocated formulas and
  formats in one rebasable operation; and `range.restore_formats` restores a
  relative format snapshot and clears blank format-only cells.
- **Pictures.** PNG and JPEG images up to 2 MiB travel as base64 in
  `image.insert`, `image.update`, `image.delete`, `cell.picture`,
  `image.to_cell`, and `image.from_cell` (larger or non-PNG/JPEG images are
  downscaled in the browser up to 2048 px on their longest edge to fit). The
  editor assigns a fresh `image_id` so follow-up moves or resizes can address a
  floating picture before its insert acknowledgement returns.
- **Grid viewport, formulas, and data tools.** `ankole_spreadsheet_wasm` returns
  high-DPI canvas viewports carrying cell values, table styles, conditional
  formatting, data bars, icon sets, notes, filters, validation dropdowns, and
  live GridCraft chart drawing primitives anchored over the grid (charts and
  conditional formats render live from workbook values; slicers, timelines,
  Power Pivot models, and named sheet views trigger a dismissible unsupported-object
  banner when present). A native textarea over the active cell and synchronized
  formula bar handle typing, IME composition, function autocomplete from the
  localized catalog, point-and-drag range insertion across sheets, `F4`
  reference cycling, `Alt+=` auto-formulas, and multi-cell status-bar aggregates.
  Keyboard shortcuts (`Shift+F10`, `Shift+Space`, `Ctrl+Space`, `Alt+Down`,
  `Ctrl+Alt+P` / `Cmd+Option+P`) expose context menus, filter/validation lists,
  freeze panes, format painter, and floating-picture navigation without a
  pointer.
- **Personal Undo.** Before mutating cell inputs, formats, or merges, the
  editor snapshots affected inputs and `format_snapshot` patches inside its
  edit queue so Undo restores values (`range.set_values`), formats
  (`range.restore_formats`), and merge bounds accurately. Structural edits
  (sorts, row/column inserts or deletes, cell shifts, moves, sheet operations,
  filters, validation, tables, floating pictures, or format/merge changes above
  100,000 stored / 1,000,000 total cells) and remote structural commits clear
  the tab's Undo history.

## Word Pages

### Document model

`ankole_word` builds on WordCraft's `engine`, `doc`, `docx`, `layout`,
`render`, `pdf`, and `fonts` crates without its UI crates. WordCraft's
`Document` organizes content into these containers:

| Container | Content | Addressing |
| --- | --- | --- |
| `body` | Main document story: flat `Vec<Arc<Block>>` of top-level `Paragraph` and `Table` blocks | `StoryRef::Body` (`"body"`) and zero-based top-level block index `usize` |
| `parts` | Headers, footers, footnotes, endnotes, comment bodies, and text boxes, each holding its own top-level `Vec<Arc<Block>>` | `StoryRef::Part(id)` (`{"part": id}`) and top-level block index `usize` |
| `comments` | Comment records keyed by `u32` id | `entry.put` / `entry.delete` (`map: "comments"`) |
| `media` | Embedded image bytes keyed by media name (base64 on the wire) | `entry.put` / `entry.delete` (`map: "media"`) |
| `passthrough` | Unmodelled OOXML parts preserved verbatim: charts, SmartArt, OLE objects (`wordcraft:embedded.parts`), `.docm` macros (`word/vbaProject.bin`), embedded font parts, glossary parts, and custom XML (base64 on the wire) | `entry.put` / `entry.delete` (`map: "passthrough"`) |
| `revisions` | Tracked-change records referenced by array index | `revisions.append` (or full `field.set` on `revisions` for accept/reject all) |
| `styles`, `numbering`, `settings`, `core`, `last_section`, `sources`, `custom_props`, `glossary`, `footnote_separators`, `endnote_separators` | Document-wide settings and definitions | `field.set` |

Each top-level `Paragraph` or `Table` block is the atomic unit of collaboration;
editing a table cell replaces its enclosing top-level `Table` block so grid
columns, merges, and borders stay consistent.

### Edits and conflict rules

| Edit | Effect | Rebase & conflict rule |
| --- | --- | --- |
| `blocks.splice {story, at, delete, insert}` | Removes `delete` top-level blocks starting at `at` in `story` and inserts `insert` | Shifts `at` across earlier non-overlapping splices in the same story; overlapping spans return `block_changed`; splices targeting a deleted or replaced part return `container_deleted` or `container_changed` |
| `entry.put {map, key, value}`, `entry.delete {map, key}` | Inserts, updates, or deletes an entry in `parts`, `comments`, `media`, or `passthrough` | Distinct keys commute; concurrent edits to the same key return `identifier_taken`; replacing or deleting a `parts` entry conflicts with a concurrent `blocks.splice` inside that part |
| `revisions.append {from, items}` | Appends tracked-change records at expected length `from` | Commits when `doc.revisions.len() == from` and stamps the authenticated actor's display name on each record; returns `concurrent_revision` if another commit changed `revisions` |
| `field.set {field, value}` | Replaces a document-wide field | Concurrent edits to the same field return `field_changed`; concurrent `numbering` edits with colliding list definitions also conflict |

After rebasing a `blocks.splice`, `ankole_word` validates inline paired markers
across the story (`FieldStart`/`FieldEnd` and `ControlStart`/`ControlEnd`
paired sequentially, plus `CommentStart`/`CommentEnd` and
`BookmarkStart`/`BookmarkEnd` paired by id). If concurrent edits across
different paragraphs leave unbalanced or mis-ordered markers, `apply` rejects
the incoming change set with `unbalanced_markers`. New `comments` entries take
the authenticated actor's display name on commit.

### Deriving operations and running the editor

`ankole_word_wasm` runs WordCraft's `Session` inside a dedicated Web Worker.
While an author types inside a top-level block, keystrokes stay in the local
Worker session and `office:presence` advertises `{story, block, editing: true}`
(`mode: "editing"`) so collaborators see the block outlined and soft-locked in
real time. The Worker runs `derive(before, after)`—comparing `Arc` pointers
first, trimming unchanged leading and trailing blocks per story into minimal
`blocks.splice` edits, and diffing keyed maps, revisions, and document-wide
fields—and queues a `ChangeSet` when:

- the caret leaves the edited top-level block (including pressing `Enter` to
  advance into a new paragraph);
- the author invokes a discrete formatting, table, review, or insert command from
  the toolbar, menu, or command palette, or presses `Ctrl+S` / `Cmd+S`;
- typing pauses for 2 seconds outside an active IME composition, or `pagehide`
  fires (never during an active IME composition).

The page view rasterizes visible and nearby pages via `Session::layout` and
`render_page` at device pixel ratio, translates pointer gestures through
`DocLayout::hit` (single/double/triple click, drag selection, link activation,
table cell selection and column resize, image/textbox manipulation), positions a
hidden native textarea at the caret for keyboard and IME input (`Session::run_ime`),
supports `Ctrl+C` / `Cmd+C` plain-text and HTML copy plus `Ctrl+F` / `Cmd+F`
and `searchTarget` page jumps via `find`, and exports PDFs in the Worker.
Personal Undo captures the prior `Arc<Block>` slice before a block edit and
submits a restoring `blocks.splice`, clearing the stack on document-wide or
conflicting remote commits. When a file contains unsupported image formats that
WordCraft could not decode on open, the editor displays a dismissible notice
noting that version history retains the original upload; reading a file never
rewrites it.

## Presentation Pages

### Document model, edits, and conflict rules

`ankole_presentation` wraps DeckCraft's `engine`, `model`, `text`, `render`,
`pptx`, `pdf`, and `fonts` crates. DeckCraft's `Presentation` stores
`slides: Vec<Arc<Slide>>`, masters and layouts, media items, deck-wide fields,
and a monotonic `next_id` counter across slides, shapes, layouts, and media.

An entire **Slide (`SlideId`)** is the atomic unit of collaboration: text edits
in shapes or tables, pointer moves and resizes, z-order changes, grouping,
connectors, animations, speaker notes, and slide comments all commit as a
`slide.put` replacement of that `Slide`. Because DeckCraft skips `MediaItem.data`
in default `serde`, `ankole_presentation` carries media bytes explicitly in
base64 inside `media.put`.

| Edit | Effect | Rebase & conflict rule |
| --- | --- | --- |
| `slide.put {slide, value}` | Replaces the `Slide` whose `SlideId == slide` | Edits to distinct `SlideId`s commute; concurrent edits to the same `SlideId` return `slide_changed`; editing a slide removed by `slides.order` returns `slide_deleted` |
| `slides.order {order, insert}` | Sets the deck's `SlideId` sequence, carrying `{id, value}` in `insert` only for newly created slides and deleting omitted existing `SlideId`s | Commutes with `slide.put` on any surviving `SlideId`; two concurrent `slides.order` edits return `slides_reordered` |
| `media.put {id, filename, mime, data}`, `media.delete {id}` | Inserts/replaces or removes a binary `MediaItem` (`data` base64-encoded) | Distinct `MediaId`s commute; colliding `id`s return `identifier_taken` |
| `deck.set {field, value}` | Replaces a deck-wide field (`slide_size`, `notes_size`, `masters`, `notes_master`, `handout_master`, `sections`, `custom_shows`, `show_settings`, `header_footer`, `props`, `default_text_style`, `first_slide_number`, `embedded_fonts`, `table_styles`, `tags`, `kept_parts`, `guides`, `raw_ext`) | Concurrent edits to the same field return `field_changed` |

If an incoming `ChangeSet` introduces a new slide, shape, layout, or media id at
or below the server's committed maximum id, `apply` rejects it with
`identifier_taken`; on commit, `apply` advances `doc.next_id` past every id in
use and stamps the authenticated actor's display name onto new slide comments.

### Editor and presentation mode

`ankole_presentation_wasm` runs in a dedicated Web Worker backing the slide
canvas, collapsible thumbnail rail, and speaker notes panel:

- **Commit boundaries and soft slide lock.** Pointer gestures commit on pointer
  release; toolbar and palette commands commit immediately; typing inside a
  shape or speaker notes stays local while active (`mode: "editing"` with
  `{slide, editing, shapes, text}` in `office:presence`) and commits when focus
  leaves the text box or notes, on `Ctrl+S` / `Cmd+S` / `pagehide`, or after 2
  seconds of idle time outside IME composition. Collaborators see the active
  author's badge on the thumbnail and canvas and cannot edit that slide until
  the draft commits, while every other slide remains editable.
- **Rendering, copy, find, Undo, and present mode.** The Worker processes
  pointer and key events, rasterizes slides and thumbnails via `render_slide`,
  supports `find` across slide text and speaker notes plus `selected_text` copy,
  exports PDFs, plays slides full screen with keyboard and pointer navigation,
  and restores captured `Arc<Slide>` snapshots for personal Undo (clearing Undo
  on `slides.order`, `deck.set`, or remote commits to the same slide). Pictures
  follow the 2 MiB PNG/JPEG rule, while existing embedded audio, video, and
  unmodelled parts stay intact in `media` and `kept_parts`.

## Fonts

Ankole ships one open-licensed site-wide font bundle for deterministic Office
layout and rendering:

| Faces | Coverage |
| --- | --- |
| Source Sans 3, Source Serif 4, Inter, JetBrains Mono | Engine default UI, body, serif, and monospace faces |
| Carlito, Caladea | Metric-compatible substitutes for Calibri and Cambria |
| Liberation Sans, Serif, and Mono | Metric-compatible substitutes for Arial, Times New Roman, and Courier New |
| Noto Sans CJK and Noto Serif CJK (SC, TC, JP, KR) | Simplified Chinese, Traditional Chinese, Japanese, and Korean faces |

`app/control_plane/scripts/fetch-office-fonts.mjs` downloads each `.ttf` file
and license notice at a pinned SHA-256 digest during the container image build
into `/usr/share/ankole/fonts` (`ANKOLE_OFFICE_FONTS_DIR`), writes a
content-addressed `manifest.json`, and lists every license in
`THIRD-PARTY-NOTICES.txt`; `AnkoleWeb.Endpoint` serves those immutable font
files under `/fonts/office`.

Because both `wordcraft-fonts` and `deckcraft-fonts` memoize loaded `FontFace`
data in a process-global table via `Box::leak`, Ankole separates font loading
by runtime:

- **Control plane (BEAM NIF).** `office_create_blank`, `office_open`,
  `office_apply`, `office_export`, `office_export_with_checkpoint`,
  `office_inspect`, and `office_word_to_document` operate purely on OOXML
  document models without touching `FontDb`. Headless Agent command batches
  (`office.apply`) and page/slide PNG rendering (`office.render`) lazily
  initialize each engine's site-wide `FontDb` once on first call from
  `ANKOLE_OFFICE_FONTS_DIR` (falling back to `/usr/share/ankole/fonts` or
  `priv/static/fonts/office`) with host system fallback disabled, and never load
  per-document embedded fonts into BEAM memory.
- **Browser Web Worker.** Each open Office Page or preview runs in an isolated
  Web Worker that inspects both `substituted_fonts` (requested font families
  absent from the bundle) and `missing_glyph_fonts()` (characters mapped to the
  `.notdef` glyph under a loaded Latin face such as Source Sans 3 or Carlito),
  selectively fetches only the matching families or regional Noto CJK faces from
  `/fonts/office/manifest.json` (plus any fonts embedded in that file) into its
  own WASM linear memory without raising false font-substitution warnings, and
  releases all memory when the Worker terminates.

## Read-only previews

Chat attachment modals and file Pages opened without `node_edit` run the same
WebAssembly Workers in read-only mode without opening an operation log or
subscribing to write events:

- `.docx` and `.docm` files render in `ankole_word_wasm`;
- `.pptx` files render in `ankole_presentation_wasm`;
- `.xlsx` and `.xlsm` files render in `ankole_spreadsheet_wasm`;
- `.xls`, `.xlsb`, and `.ods` workbooks use the SheetJS table preview
  (`file-spreadsheet.tsx`), while `.doc`, `.odt`, `.rtf`, `.ppt`, and `.odp`
  files offer direct download;
- any Office file exceeding `max_file_bytes` or failing with
  `invalid_office_file` falls back cleanly to original-file download.

## Converting a Word Page to a document Page

`POST /api/v2/pod/pages/:id/convert-to-document` converts a Word Page into a
native Pod document Page while leaving the source Word Page, its links, and its
version history intact. When an editor starts conversion from the toolbar, the
browser waits for its outstanding edits to be acknowledged before sending the
conversion request.

- **Authorization and placement.** Any caller with `node_view` on the Word Page
  may convert it. When `parent_id` is omitted and the caller may create Pages
  under the Word Page's parent, Ankole places the new document Page immediately
  after the Word Page (`after_id`); when the caller holds read-only access to a
  shared Word Page without write permission on its parent (or converts a
  Conversation file), Ankole creates the document Page in the caller's Private
  root (or an explicit writable `parent_id`). The new Page takes the Word file's
  stem as its title.
- **Kernel conversion.** Outside any database transaction, `OfficeFiles` loads
  the logical Word document (including uncompacted operations) and invokes
  `office_word_to_document/1` on `DirtyCpu` to produce canonical `page_document`
  XML validated by `app/kernel/src/page_document/`, extracted media blobs stored
  under `assets/<sha256>/<filename>`, and a map of `omitted` and `downgraded`
  feature counts shown once on the newly created Page. Trees exceeding
  `page_document` bounds (`8 MiB` UTF-16, `100,000` nodes, or `128` depth)
  return `document_too_large` (`413`).

| Word content | Document Page (`page_document`) |
| --- | --- |
| Headings by outline level, paragraphs, alignment, indents | `Heading` and `Paragraph` with `align` and `indent` |
| Bold, italic, underline, strike, inline code, superscript, subscript, links | `Bold`, `Italic`, `Underline`, `Strikethrough`, `Code`, `Superscript`, `Subscript`, and `Link` |
| Text color and highlight / shading | `TextStyle` with `#RRGGBB` `color` and `background-color` (uncolored highlight maps to `Highlight` `<mark>`) |
| Bulleted and numbered lists with nesting | `BulletList`, `OrderedList`, `ListItem` |
| Tables with header rows, merged cells, column widths, and cell shading | `Table` with `HeaderCell` (`<th>`) and `TableCell` (`<td>`), `colspan` and `rowspan` (omitting covered shadow cells), integer pixel `widths` clamped to `1..=9999`, and `#RRGGBB` `background` |
| Standalone paragraph pictures and small inline images | Block `Media` (`<media src="ankole:asset/<sha256>/<name>" kind="image" view="preview" mime="…" size="…" />`) for standalone pictures; inline `Image` (`<img>`) for small inline icons (custom display dimensions count under `downgraded`) |
| Display equations vs inline equations | Standalone paragraph equations convert to block `Math` (`<math>`) via WordCraft's LaTeX converter; inline equations inside text paragraphs convert to `Code` spans holding LaTeX source (counted under `downgraded`) |
| Footnotes and endnotes | Appended numbered list at the end of the document with `[n]` inline references |
| Tracked changes | Accepted text |

Headers, footers, page setup, page and section breaks, floating text boxes and
shapes, charts, SmartArt, and Word comments count under `omitted`.

## Agents

Agents inspect, render, edit, and convert Pod Office Pages through
`Ankole.Pod.RPCBroker` (`ankole-pod office.*`):

| Operation | Purpose |
| --- | --- |
| `office.inspect {id, …}` | Returns the structure and text of the logical document: stories and top-level blocks with indexes, slides and shapes with ids, or sheets and cell ranges. |
| `office.render {id, page \| slide, scale?} --to <worker-path>` | Renders a Word page or presentation slide to PNG on `DirtyCpu` outside any database transaction using the site-wide `FontDb` and streams the PNG to `<worker-path>` via `WorkerFiles` so the Agent can visually verify layout. |
| `office.commands {id, query?}` | Lists available headless engine commands and parameter schemas for Word and Presentation Pages. |
| `office.apply {id, base_revision?, commands \| ops}` | Applies headless engine commands (Word/Presentation) or canonical operations (Spreadsheet) and returns the committed `revision`. |
| `office.to_document {id, parent_id?}` | Converts a Word Page into a native document Page and returns the new Page metadata plus `omitted` and `downgraded` counts. |

For Word and Presentation Pages, `office.apply` runs engine commands outside
PostgreSQL locks before committing:

1. **Unlocked execution.** Outside any transaction, `OfficeFiles` opens the
   logical document at `read_revision`, clones it into a headless `Session`
   confined with `file_access::confine` over an empty directory (blocking
   `file.*` commands and setting `Session::author` to the actor's display name),
   executes the command batch on `DirtyCpu`, and calls `derive` to produce a
   single `ChangeSet`. Any command error aborts without writing to PostgreSQL.
2. **Locked commit.** Under `Pages.lock`, if `base_revision` was supplied and
   `page.revision != base_revision`, the call rejects with `revision_conflict`;
   otherwise `OfficeFiles` rebases and commits the derived `ChangeSet` through
   `office_apply`, broadcasting `office:changes` to open browser tabs without
   resetting them.

### Routing between `ankole-pod office.*` and Worker `OfficeCLI`

Ankole routes Office work by where the file lives:

| Target | Tool | Contract |
| --- | --- | --- |
| Existing or shared Office Page in Pod | `ankole-pod office.*` | Commits unit-level operations through the control plane, merges cleanly with open browser collaborators, and preserves `PageSnapshot` history. |
| Scratch or newly generated Office files in `/workspace` | `OfficeCLI` and the Office Skills | Builds and transforms Worker-local files alongside local scripts before publishing final deliverables (`ankole-files put` to a file Page replaces the object and appends a `reset` entry). |

Because the Office Plugin's `docx`, `pptx`, and `xlsx` Skills run with
`ankole-runtime: background_job`, both `priv/sessions/prompts/tools.eex` (plus
`ankole-pod --help` for the interactive main Agent) and the three `SKILL.md`
files (for Background Agent Jobs) carry this routing rule.

## Architectural decisions

| Decision | Alternative | Rationale |
| --- | --- | --- |
| Native Pod UIKit editors over headless WASM Workers | Embed upstream `egui` apps in iframes | Native UIKit editors integrate Pod Presence, Page comments, Chat context, 60-second access rechecks, narrow-viewport toolbars, and accessible ARIA controls without full-file reloads on remote commits. |
| Unit-level concurrency + Presence soft unit locks (cell, top-level block, slide) | Intra-paragraph / intra-slide OT and cross-operation identifier rewriting | Sub-slide `shapes.splice` + `shape.set` diverges on z-order and group edits, nested block OT risks corrupting cross-paragraph markers, and teams needing character-level co-writing convert a Word Page to a document Page in one click. |
| Commit on unit exit, discrete command, or 2 s idle pause outside IME | Stream snapshots every 300 ms while typing | Unit-boundary commits keep `pod_office_ops` compact, preserve clean personal Undo steps, never interrupt IME composition, and avoid mid-sentence revision conflicts. |
| Snapshot-restore personal Undo (`Arc<Block>` slice, `Arc<Slide>`, cell/format snapshots) | Multi-step algebraic inverse operations across rebases | Document-wide fields and `revisions.append` have no clean algebraic inverse; restoring prior unit snapshots and clearing Undo on structural/conflicting commits keeps Undo deterministic. |
| Isolate per-document fonts to disposable browser Web Workers; use one immutable site `FontDb` in BEAM NIFs | Load embedded document fonts inside BEAM NIFs | Upstream `FontDb` caches leak loaded faces via `Box::leak` for process lifetime, which would grow BEAM memory unboundedly and mix fonts across tenants; terminating a browser Worker reclaims its WASM heap immediately. |
| Direct kernel conversion from `wordcraft_doc::Document` to `page_document` XML | Convert through Markdown | Direct XML conversion preserves merged cells, column widths, cell shading, text colors, alignment, indents, extracted assets, and LaTeX math. |
| `ankole-pod office.*` via `RPCBroker` + Worker `OfficeCLI` for `/workspace` | Control-plane MCP server replacing `OfficeCLI` | `RPCBroker` already owns Pod authorization and replay for main and background Agents, while `/workspace` generation pipelines still operate on local files that have no Pod Page row. |
| Non-purging `SyncFileCache` enqueue on Word/Presentation compaction | Synchronous search purge before background extraction | Updating `PageSearchDocument` in place when extraction finishes avoids a search visibility gap every 30 seconds during active editing. |
| Sibling document Page creation with Private-root fallback | Mutating `Page.type` in place or requiring parent write access | Keeping the Word Page intact preserves links, `.docx` downloads, and history, while Private-root fallback lets read-only viewers convert shared Word files. |

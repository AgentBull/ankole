# Brain Body Syntax and Object Editing

Brain Object bodies use CommonMark, block-level `audience` tags, and `[[slug]]`
links. The native `brain_markdoc` module owns the grammar. comrak parses Markdown
structure; `brain_markdoc` uses those boundaries to identify audience tags.
The control plane calls this parser through a NIF, validates scopes, and filters
read results. The Console uses local parsing for previews.

## Body contract

`brain_objects.body` stores body text. Structured fields own `slug`, `type`,
`subtype`, `title`, `meta`, and `effective_date`.

### Audience tags

The supported tag is block-level `audience`:

```markdoc
{% audience scope="principal:alice" %}
Only Alice can read this.
{% /audience %}
```

- The opening tag is `{% audience scope="..." %}`. The closing tag is
  `{% /audience %}`. Each tag starts at column one and occupies its own line.
  Trailing whitespace is allowed. Adjacent blank lines are optional.
- Tags form pairs and cannot nest. Text outside tags has the `world` scope.
  Each segment has one scope, stored as `brain_chunks.audience_scope` after
  chunking.
- Tag text inside fenced code, indented code, or inline code is literal code.
- Scope values are `world`, `group:<name>`, or `principal:<uid>`.
  `Ankole.Brain.Scope` validates their shape. The control plane checks scope
  existence and the writer's access in the write transaction. `world` covers
  the current tenant. See [BrainV3](BrainV3.md).
- An `{% audience` or `{% /audience` candidate outside a tag line or code range
  produces `misplaced_audience_tag`. This includes candidates inside a heading,
  blockquote, list, HTML block, or ordinary text line.

In this input, the closing tag is code:

````markdoc
{% audience scope="principal:alice" %}
private
~~~markdoc
{% /audience %}
~~~
tail that must stay private
````

The parser returns `unclosed_audience_tag`, and the write fails. `GetPage`
returns an empty body when stored body syntax is invalid.

### Internal links

`[[companies/minghu-ai]]` links to an internal page. In `[[target|title]]`, the
text before `|` identifies the target. comrak's `wikilinks_title_after_pipe`
extension identifies links. Dreaming stores them as link edges. Wikilink text
inside code is literal code.

## Canonical parser

The implementation and syntax tests are in
`app/kernel/src/brain_markdoc/mod.rs` and its adjacent `tests.rs`.
The Cargo feature `brain_markdoc = ["dep:comrak"]` uses comrak with its default
features disabled and is included in `nif`.

### NIF contract

`brain_markdoc_analyze_nif` accepts UTF-8 body text and returns JSON.
`Ankole.Kernel.brain_markdoc_analyze/1` decodes it with `Torque.decode!`.
The NIF runs on a DirtyCpu scheduler in the current process.

A successful result has this shape:

```json
{"segments": [{"scope": "world", "text": "..."},
              {"scope": "principal:alice", "text": "..."}],
 "wikilinks": ["companies/minghu-ai"]}
```

Syntax errors are returned as data:

```json
{"error": {"code": "unclosed_audience_tag", "line": 12}}
```

The error codes are `nested_audience_tag`, `unopened_audience_tag`,
`unclosed_audience_tag`, and `misplaced_audience_tag`. Line numbers start at one.
A native analysis or encoding failure fails the NIF call.

### Analysis

1. comrak parses the complete body with wikilinks enabled. The parser collects
   source positions for `CodeBlock`, `Code`, and `HtmlBlock`, and targets for
   `WikiLink`.
2. The parser identifies column-one tag lines outside code and HTML blocks.
3. It checks every audience candidate. A candidate outside a tag line or code
   range produces `misplaced_audience_tag`.
4. It pairs tags in document order. Segments preserve the original bytes and
   whitespace between tags. Text outside a pair forms a `world` segment.
5. It trims link targets, removes empty values, and removes duplicates in
   document order.

comrak supplies structural ranges and link facts. `brain_markdoc` supplies the
audience grammar. Reads call the parser directly; syntax trees, segments, and
diagnostics are temporary results.

### Control-plane interface

`Ankole.Brain.Markdoc` calls the canonical parser:

| Interface | Behavior |
| --- | --- |
| `segments/1` | Validates scopes, maps syntax errors to atoms, and omits whitespace-only segments |
| `scopes/1` | Returns the distinct scopes in the body |
| `prune/2` | Keeps segments selected by `keep?` and restores tags around scoped text |
| `wrap/2` | Adds canonical tags around scoped text; returns `world` text directly |
| `wikilinks/1` | Returns internal link targets, or an empty list for invalid bodies |
| `diagnostic/1` | Returns native syntax error codes and line numbers for the editor |

Objects validates write scopes and chunks each segment. GetPage filters the
body by read and disclosure access. SourceLearning, Synthesis, and other derived
body writers use `wrap/2` to preserve source scopes.

## Console creation and editing

### Body ownership

`managed_by_source_id` identifies a Brain Source that owns the body.
SourceLearning uses an internal upsert bound to that Source identity. Ordinary
Object updates reject changes to managed bodies. The server returns `editable`
and `edit_block_reason` for the Console's controls.

| State | Body actions | Owner |
| --- | --- | --- |
| Tenant-owned, active | Create, edit, save | `Ankole.Brain.create_object/2`, `Ankole.Brain.update_object/3` |
| Deleted | Read, then restore before editing | Object restoration |
| SourceLearning media projection | Read; relearn or archive through the Source | SourceLearning |
| `agent-skills` projection | Read; edit through Agent Library | Agent Library |

### Console API

Slugs can contain `/`, so the Console sends them in query parameters or request
bodies. The API uses `/api/v2/brain` and `application/vnd.api+json`. Generic
actions receive arguments under `data` and return their declared typed results.

| Method and path | Purpose | Main inputs or outputs |
| --- | --- | --- |
| `GET /api/v2/brain/objects/show?slug=...` | Read detail and save baseline | Raw `body`, `content_hash`, `editable`, `edit_block_reason` |
| `POST /api/v2/brain/objects` | Create a tenant-owned Object with `:console_create` | slug, type, subtype, title, body, meta, effective_date |
| `PATCH /api/v2/brain/objects` | Update a tenant-owned Object with `:console_update` | slug, mutable fields, `expected_content_hash` |
| `GET /api/v2/brain/object-versions?slug=...` | Read version history | author, body, meta, tags, snapshot_at |

Writes return an Object summary. After a successful save, the editor reloads
detail to obtain the current `content_hash` and normalized tags. If that read
fails, it keeps the draft and shows the error. A successful read updates the
save baseline.

Create and update require `site_console:brain` `update` permission. They accept
an optional `tags` array. Omitting `tags` preserves the current set; an empty
array clears it. Each tag has its own editor input and can contain newlines.
Tags participate in the compare-and-swap baseline and the author-attributed
version snapshot. Version rollback restores `body` and `meta`.

Raw body reads require `site_console:brain` `read` permission. Domain rejections
return 422 with the domain error code. The local preview supplies syntax error
line numbers. `content_hash_conflict`, `object_deleted`, and `slug_taken` return
409.

### Editor behavior

The Console uses full-page routes `/brain/objects/new` and
`/brain/objects/:slug/edit`. A textarea edits source text.
`previewBrainObjectBody` uses CommonMark source ranges for fenced, indented, and
multiline inline code, then identifies tag lines outside those ranges.
`MarkdownBody` renders the segments with scope badges. Wikilinks appear as
literal text in the preview.

The preview reports misplaced, nested, unopened, and unclosed audience tags
with line numbers. Invalid bodies show diagnostics without scope badges.
Native and Console tests share `app/kernel/test/fixtures/brain_markdoc.json`.
Valid segments preserve original text and newlines; the preview hides
whitespace-only segments. On save, the server parses the body and checks syntax,
scope validity, and write access. Server diagnostics appear in Problems.

Saves carry the loaded `expected_content_hash`. A conflict preserves the local
draft. The operator can load the current version, compare it, and update the
baseline. Leaving an unsaved draft prompts for confirmation. The baseline covers
title, body, meta, tags, subtype, and effective_date. Derived retrieval and
embedding state does not change it. Ordinary saves and rollbacks check the
Object lock and reject deleted Objects with `object_deleted`; restore them
before editing.

Save and comparison results belong to the editor instance that started them.
A request can finish its server write and global query refresh after navigation,
but its result does not change a later draft, error, or destination. Creation
accepts slug, type, subtype, title, effective_date, and meta. Editing keeps slug
and type read-only. Administrators can repair invalid stored syntax through the
raw-body editor.

## Implementation boundaries

The syntax consists of the audience tags and wikilinks above. The in-process
NIF owns parsing and access enforcement remains in the control plane. The
editor saves source as entered and previews it with the shared test corpus.
`GetPage.rendered` joins the segments that pass disclosure checks. Per-Principal
disclosure uses that Principal's actual read path; recall administration is a
separate function.

## References

- [comrak](https://docs.rs/comrak)
- [Markdoc tag syntax](https://markdoc.dev/docs/tags)

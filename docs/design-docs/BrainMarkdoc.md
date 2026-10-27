# Brain Body Syntax and Object Editing

Brain Object bodies combine CommonMark, block-level `audience` tags, and
`[[slug]]` wikilinks. The native Rust `brain_markdoc` module defines this
grammar: it runs `comrak` to parse Markdown structure and uses those structural
boundaries to locate `audience` tags. On the server, the Elixir control plane
calls this parser through a NIF, validates each scope, and filters segments on
read. In the browser, the Console parses drafts locally to render live previews.

## Body contract

`brain_objects.body` stores the Markdown body text, while dedicated structured
fields store `slug`, `type`, `subtype`, `title`, `meta`, and `effective_date`.

### Audience tags

The only supported Markdoc tag is the block-level `audience` tag:

```markdoc
{% audience scope="principal:alice" %}
Only Alice can read this.
{% /audience %}
```

- An audience block opens with `{% audience scope="..." %}` and closes with
  `{% /audience %}`. Each tag must start at column one on its own line; trailing
  whitespace is allowed, and adjacent blank lines are optional.
- Tags must form matching pairs and cannot nest. Text outside any `audience`
  block belongs to the `world` scope. Every parsed segment carries a single
  scope, which chunking stores in `brain_chunks.audience_scope`.
- Tag syntax inside fenced code blocks, indented code blocks, or inline code
  spans is treated as literal code.
- Valid scope strings are `world`, `group:<name>`, and `principal:<uid>`.
  `Ankole.Brain.Scope` validates the string format, and the control plane checks
  that the target exists and that the writer may address it inside the write
  transaction. The `world` scope covers eligible Principals in the current
  tenant; see [BrainV3](BrainV3.md).
- If `{% audience` or `{% /audience` appears outside a standalone column-one tag
  line or a code range (including inside a heading, blockquote, list, HTML
  block, or ordinary text line), the parser rejects the body with
  `misplaced_audience_tag`.

For example, in the following input, the fenced code block captures the closing
tag as literal code:

````markdoc
{% audience scope="principal:alice" %}
private
~~~markdoc
{% /audience %}
~~~
tail that must stay private
````

Because the opening tag is never closed outside code, the parser returns
`unclosed_audience_tag` and the control plane rejects the write. Likewise, if a
stored Object body contains invalid syntax, `GetPage` returns an empty body
rather than exposing unfiltered text.

### Internal links

Authors link to internal pages using `[[companies/minghu-ai]]` or
`[[target|title]]`, where the text before `|` identifies the target slug. The
parser detects these links through `comrak`'s `wikilinks_title_after_pipe`
extension while treating wikilink syntax inside code ranges as literal code.
Dreaming and link reconciliation store resolved targets as link edges.

## Canonical parser

The parser implementation and syntax test suite live in
`app/kernel/src/brain_markdoc/mod.rs` and its adjacent `tests.rs`. The Cargo
feature `brain_markdoc = ["dep:comrak"]` builds `comrak` with default features
disabled and is enabled by the `nif` feature.

### NIF contract

`brain_markdoc_analyze_nif` accepts UTF-8 body text and returns a JSON string,
which `Ankole.Kernel.brain_markdoc_analyze/1` decodes with `Torque.decode!`. The
NIF executes on a `DirtyCpu` scheduler in the calling BEAM process.

When the body is valid, the NIF returns segments and deduplicated wikilinks:

```json
{"segments": [{"scope": "world", "text": "..."},
              {"scope": "principal:alice", "text": "..."}],
 "wikilinks": ["companies/minghu-ai"]}
```

When the body has a syntax error, the NIF returns the error as structured data:

```json
{"error": {"code": "unclosed_audience_tag", "line": 12}}
```

The syntax error codes are `nested_audience_tag`, `unopened_audience_tag`,
`unclosed_audience_tag`, and `misplaced_audience_tag`, with 1-based line
numbers. If an internal failure occurs during native analysis or JSON encoding,
the NIF call itself fails.

### Analysis

`brain_markdoc` analyzes a body in five steps:

1. `comrak` parses the full Markdown document with wikilinks enabled and
   collects byte ranges for `CodeBlock`, `Code`, and `HtmlBlock` nodes together
   with `WikiLink` targets.
2. `brain_markdoc` locates valid column-one tag lines that lie outside code and
   HTML blocks.
3. It scans the remaining body for any `{% audience` or `{% /audience`
   occurrence; if one appears outside a recognized tag line or code range,
   analysis stops with `misplaced_audience_tag`.
4. It pairs opening and closing tags in document order. Each segment preserves
   the exact bytes and whitespace between tags, and text outside a tag pair
   forms a `world` segment.
5. It trims wikilink targets, drops empty targets, and removes duplicates while
   preserving first-seen document order.

In this division of work, `comrak` provides Markdown structural ranges and link
targets, while `brain_markdoc` enforces the `audience` tag grammar. Read paths
invoke the parser directly on demand; syntax trees, segments, and diagnostics
are temporary values that are never persisted.

### Control-plane interface

`Ankole.Brain.Markdoc` wraps the canonical parser for control-plane callers:

| Interface | Behavior |
| --- | --- |
| `segments/1` | Validates scopes, maps syntax errors to atoms, and omits whitespace-only segments |
| `scopes/1` | Returns the distinct scopes present in the body |
| `prune/2` | Keeps segments selected by `keep?` and restores canonical tags around scoped text |
| `wrap/2` | Wraps scoped text in canonical `audience` tags, or returns `world` text unchanged |
| `wikilinks/1` | Returns internal link targets, or `[]` when the body is invalid |
| `diagnostic/1` | Returns native syntax error codes and line numbers for editor feedback |

On writes, `Objects` validates write scopes and chunks each segment. On reads,
`GetPage` filters the body according to the caller's read and disclosure
boundaries. Derived-body writers such as `SourceLearning` and `Synthesis` call
`wrap/2` so generated text retains its source scopes.

## Console creation and editing

### Body ownership

When `managed_by_source_id` is set on an Object, that Brain Source owns the
body. `SourceLearning` updates managed bodies through an internal upsert bound
to that Source identity, whereas ordinary Object update actions reject edits to
managed bodies. When the Console fetches an Object, the server returns
`editable` and `edit_block_reason` to drive the editor controls.

| State | Body actions | Owner |
| --- | --- | --- |
| Tenant-owned, active | Create, edit, save | `Ankole.Brain.create_object/2`, `Ankole.Brain.update_object/3` |
| Deleted | Read, then restore before editing | Object restoration |
| SourceLearning media projection | Read; relearn or archive through the Source | SourceLearning |
| `agent-skills` projection | Read; edit through Agent Library | Agent Library |

### Console API

Because Object slugs can contain `/`, the Console passes slugs in query
parameters or JSON request bodies rather than path segments. All endpoints live
under `/api/v2/brain` and speak `application/vnd.api+json`; generic actions
accept arguments under `data` and return typed results.

| Method and path | Purpose | Main inputs or outputs |
| --- | --- | --- |
| `GET /api/v2/brain/objects/show?slug=...` | Read detail and save baseline | Raw `body`, `content_hash`, `editable`, `edit_block_reason` |
| `POST /api/v2/brain/objects` | Create a tenant-owned Object with `:console_create` | slug, type, subtype, title, body, meta, effective_date |
| `PATCH /api/v2/brain/objects` | Update a tenant-owned Object with `:console_update` | slug, mutable fields, `expected_content_hash` |
| `GET /api/v2/brain/object-versions?slug=...` | Read version history | author, body, meta, tags, snapshot_at |

Write endpoints return an Object summary. After a save succeeds, the Console
editor reloads the Object detail to refresh `content_hash` and normalized tags,
updating its save baseline once that read succeeds; if the follow-up read fails,
the editor keeps the local draft and displays the error.

Creating or updating an Object requires the `site_console:brain` `update`
permission and accepts an optional `tags` array. If the caller omits `tags`, the
server preserves the existing tag set; passing `[]` clears all tags. In the
editor, each tag has its own input field and may contain newlines. Tags are
covered by both the compare-and-swap hash baseline and the version snapshot
recorded with the author, whereas rolling back a version restores only `body`
and `meta`.

Reading raw Object bodies requires the `site_console:brain` `read` permission.
When domain validation rejects a write, the server returns HTTP 422 with the
domain error code (while the local preview supplies line numbers for syntax
errors). State conflicts (`content_hash_conflict`, `object_deleted`, and
`slug_taken`) return HTTP 409.

### Editor behavior

The Console mounts full-page editors at `/brain/objects/new` and
`/brain/objects/:slug/edit`, using a plain `textarea` for source editing. On
each edit, `previewBrainObjectBody` computes CommonMark byte ranges for fenced,
indented, and multiline inline code and identifies column-one `audience` tag
lines outside those ranges. `MarkdownBody` then renders valid segments with
scope badges while leaving `[[wikilinks]]` as literal text and hiding
whitespace-only segments. Valid segments preserve their original text and
newlines.

When a draft has misplaced, nested, unopened, or unclosed `audience` tags, the
preview reports the diagnostic with its line number and omits scope badges. Both
the Rust NIF tests and the Console preview tests run against the shared fixture
corpus in `app/kernel/test/fixtures/brain_markdoc.json`. On save, the server
re-parses the body, validates every scope, checks write permissions, and
surfaces any server-side rejections in the editor's Problems panel.

Every save request carries the loaded `expected_content_hash`, which covers
`title`, `body`, `meta`, `tags`, `subtype`, and `effective_date` (derived
retrieval chunks and embeddings do not affect this hash). If the server returns
`content_hash_conflict`, the editor preserves the operator's local draft so the
operator can load the latest server version, compare the two, and adopt the new
baseline. If the operator navigates away from an unsaved draft, the browser asks
for confirmation. Ordinary saves and rollbacks acquire the Object row lock and
reject soft-deleted Objects with `object_deleted`, so operators must restore a
deleted Object before editing it.

In-flight save and comparison callbacks are bound to the specific editor
instance that started them: if the operator navigates away before a request
completes, the server write and global query cache refresh still finish, but the
callback will not overwrite a newer draft, error state, or route. Creating an
Object accepts `slug`, `type`, `subtype`, `title`, `effective_date`, and `meta`;
editing an existing Object keeps `slug` and `type` read-only. If a stored Object
contains invalid body syntax, an administrator can repair it directly in this
raw-body editor.

## Implementation boundaries

The Brain body grammar consists solely of CommonMark, block-level `audience`
tags, and `[[slug]]` wikilinks. The in-process Rust NIF owns syntax parsing,
while the Elixir control plane owns scope validation and access enforcement. The
Console editor saves the exact source text entered by the operator and validates
preview parity through the shared test corpus. On read, `GetPage.rendered`
concatenates only the segments that pass knowledge and disclosure checks.
Evaluating disclosure for a specific Principal always runs through that
Principal's read path; recall administration is a separate operation.

## References

- [comrak](https://docs.rs/comrak)
- [Markdoc tag syntax](https://markdoc.dev/docs/tags)

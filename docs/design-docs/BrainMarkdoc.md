# Brain Body Syntax and Runtime Object Editing

Status: implemented.

## Decision

The normative syntax of a Brain Object body is CommonMark plus one block-level
`audience` tag and `[[slug]]` internal links. The `audience` tag borrows the
shape of Markdoc tag syntax. The `brain_markdoc` module of the native kernel is
the only owner of this syntax. It parses block structure with comrak, a Rust
implementation of the CommonMark specification, and adds a thin tag
recognition layer on top. The control plane calls it through one NIF function.
The system has no second parser.

Before the replacement, `Ankole.Brain.Markdoc` scanned a flat string for tags
with three regular expressions. It had no concept of block structure. It could
not tell a tag line from code text in a code block, and it accepted ambiguous
input without an error. This caused a confirmed P0 that disclosed content to
Principals without access. The replacement is atomic. It is not a patch, and
the old scanner does not remain as a fallback.

This design adds no `@markdoc/markdoc`, no JavaScript runtime, and no separate
process. One parse is one in-process NIF call, with the same failure semantics
as the other kernel functions.

Delivery has two commits, and each commit has its own changelog version:

1. Phase 1 replaces the server-side syntax atomically. It is a security fix.
2. Phase 2 adds Object creation and editing in the Console. It is a new
   capability.

## The Confirmed P0 Leak Path

In the body below, the `audience` closing tag is inside a fenced code block.
By block structure, that line is code text and not a tag:

````markdoc
{% audience scope="principal:alice" %}
private
~~~markdoc
{% /audience %}
~~~
tail that must stay private
````

A correct parse treats the line inside the fence as code. The document then
has only one unclosed opening tag, and the write must be rejected. The replaced
regular expression scanner treated that line as a real closing tag, so the text
after it became a `world` segment. The write passed validation. Retrieval
chunking and page pruning then exposed the tail, which belongs to
`principal:alice`, to Principals without access.

The same class of error also occurs in inline code, indented code, and other
block structures. More regular expressions cannot establish a reliable
boundary.

## Root Causes

1. **The syntax implementation had no block structure.** `audience` is a
   block-level construct, but the implementation matched flat strings. Whether
   a string is a tag depends on its block context, and only a CommonMark parser
   can answer that question.
2. **It accepted ambiguity without an error.** Where the parser cannot
   determine the meaning, the correct behavior is to reject the write.
   `audience` sets the confidentiality boundary, so a wrong guess changes who
   can read the content.
3. **One body had more than one interpretation.** The control plane read scopes
   with regular expressions, and the Console rendered the body as Markdown.
   After the replacement, both use one normative syntax, and the server is the
   only authority.

## Body Contract (Normative Syntax)

The `brain_objects.body` column stores only the body. Structured fields own
`slug`, `type`, `subtype`, `title`, `meta`, and `effective_date`, and the body
must not declare them again. A body has no frontmatter. The `.okf` file
importer strips frontmatter before it calls the parser. This behavior is
unchanged.

### The `audience` Tag

The only tag is the block-level `audience` tag:

```markdoc
{% audience scope="principal:alice" %}
Only Alice can read this.
{% /audience %}
```

These rules apply:

- The opening tag is `{% audience scope="..." %}`, and the closing tag is
  `{% /audience %}`. The shape matches Markdoc block tags, so the syntax can
  move to full Markdoc when more tags are necessary.
- A tag line starts at column 0 and holds only the tag. Trailing whitespace is
  allowed. A tag line needs no blank line before or after it.
- Tag text inside a code block, fenced or indented, is code and not a tag.
- Tags must pair, must not nest, and must sit at the document root. Text
  outside tags is `world`. Each segment has exactly one scope, which maps to
  one `brain_chunks.audience_scope`.
- A scope has the shape `world`, `group:<name>`, or `principal:<uid>`.
  `Ankole.Brain.Scope` validates the shape, as before. Inside the database
  transaction, the control plane still checks that the scope exists and that
  the writer can use it, as before.
- Any `{% audience` or `{% /audience` substring outside those positions is a
  `misplaced_audience_tag` validation error, and the write fails. These
  positions include the middle of a line, a heading, a blockquote, a list, an
  HTML block, and a paragraph with more than one line. Where the syntax cannot
  determine the meaning, the parser rejects the input. It does not guess.

### `[[slug]]` Internal Links

`[[companies/minghu-ai]]` is an internal page link. In the `[[target|title]]`
form, the part before `|` is the target. This is an existing contract. Dreaming
materializes these links as link edges, and stored bodies in deployed
instances contain them, so the syntax must stay.

The comrak wikilink extension (`wikilinks_title_after_pipe`) now parses these
links, and the target comes from the AST `WikiLink` node. `[[...]]` in a code
block or in inline code no longer produces a link. Link extraction has no
confidentiality meaning, because an error affects only relation edges and not
disclosure. The same parser makes link extraction correct at no extra cost.

## Kernel `brain_markdoc` Owns the Syntax

The implementation copies the location and the pattern of `program_runner`:

- `app/kernel/Cargo.toml` adds the optional dependency `comrak`
  (`default-features = false`) and the new feature
  `brain_markdoc = ["dep:comrak"]`. The `nif_dev` and `nif_prod` feature lists
  include the new feature.
- `app/kernel/src/brain_markdoc/mod.rs` and `tests.rs` in the same directory
  hold the module. `lib.rs` feature-gates the module the same way as
  `program_runner`, and `nif_exports` registers it.
- Before you edit the NIF boundary, read
  `.agents/skills/elixir-rust-nif-coding/SKILL.md`.

### NIF Contract

The kernel exposes one function:

```elixir
@spec brain_markdoc_analyze_nif(binary()) :: result(String.t())
```

The input is the body as a UTF-8 binary, and the output is a JSON string. The
public Elixir wrapper `Ankole.Kernel.brain_markdoc_analyze/1` calls
`Torque.decode` and copies the pattern of `authz_authorize/1`. Parsing is CPU
work, so the function runs on the DirtyCpu scheduler.

The output on success:

```json
{"segments": [{"scope": "world", "text": "..."},
              {"scope": "principal:alice", "text": "..."}],
 "wikilinks": ["companies/minghu-ai"]}
```

A syntax error returns a normal value, not a NIF error:

```json
{"error": {"code": "unclosed_audience_tag", "line": 12}}
```

`code` is one of `nested_audience_tag`, `unopened_audience_tag`,
`unclosed_audience_tag`, or `misplaced_audience_tag`. `line` is a 1-based line
number, and the Phase 2 editor diagnostics use it directly. A NIF-level
`{:error, String.t()}` means only an implementation defect, such as invalid
UTF-8. The existing `result()` convention handles it.

### Analysis Algorithm (Normative)

1. Parse the full text with comrak. Turn on `wikilinks_title_after_pipe` and
   no other extension. Each AST node carries its sourcepos.
2. Collect the code ranges. These are the line range of each `CodeBlock` node
   and the sourcepos span of each inline `Code` node.
3. Find the tag lines. A tag line matches
   `^\{%\s*audience\s+scope="([^"]*)"\s*%\}[ \t\r]*$` or
   `^\{%\s*/audience\s*%\}[ \t\r]*$` as a whole line, and it is outside every
   `CodeBlock` line range.
4. Check for misplaced tags. Each position in the source that matches
   `\{%[ \t]*/?[ \t]*audience` must be on a tag line or inside a code range.
   If a position is in neither, return `misplaced_audience_tag`.
5. Run the pairing state machine over the tag lines in document order. The
   error codes are the same as above. Segment text is the raw byte slice
   between tag lines, cut at line boundaries and kept verbatim. Root text
   before an opening tag line and after a closing tag line is a `world`
   segment.
6. Collect the wikilinks. Take the `url` of each AST `WikiLink` node in
   document order, trim it, drop empty targets, and remove duplicates.

Here comrak supplies only two facts. It reports which ranges are code, and it
reports where the wikilinks are. The algorithm does not use paragraphs, lists,
headings, or other structure. The normative syntax is these six steps, no more
and no fewer.

### Elixir Side

`Ankole.Brain.Markdoc` keeps all its public functions and signatures:
`segments/1`, `scopes/1`, `prune/2`, `wrap/2`, and `wikilinks/1`. Internally,
the module calls `Ankole.Kernel.brain_markdoc_analyze/1` once:

- `segments/1` maps each error code to its existing atom, such as
  `{:error, :nested_audience_tag}`. It runs `Ankole.Brain.Scope.parse/1` on
  each scope other than `world` and keeps the
  `{:error, {:invalid_audience_scope, scope}}` result. Last, it drops the
  segments that are empty after trim, as before.
- `prune/2` uses the raw segment list, before the empty segments are dropped.
  It keeps the segments that pass `keep?` and wraps each scoped segment in the
  normative tags again. This keeps the existing property that a pruned body
  keeps its scopes when it is written again.
- `wrap/2` stays plain string concatenation. Its output already follows the
  new syntax, because each tag starts at column 0 on its own line.
- `wikilinks/1` returns the wikilinks from the analysis result directly.
- The replacement deletes the three regular expressions `@open_tag`,
  `@close_tag`, and `@wikilink`, and the functions `tokenize/1` and
  `build_segments/2`.

The callers `Objects`, `GetPage`, `Dreaming`, `Forget`, `SourceLearning`, and
`Synthesis` do not change. `GetPage` keeps its fail-closed behavior and
projects an empty body for a body that does not parse. Whitespace in segment
slices can differ from the old implementation. Test fixtures can change for
that reason, but the scope of each piece of text must stay the same.

## Existing Data

- Every system writer goes through `wrap/2`, and its output follows the new
  syntax. Existing data from the main write paths is not affected.
- Some bodies passed the old scanner but break the new syntax, for example
  with tag text in the middle of a line. A read projects such a body as empty
  through the existing fail-closed path, and an update is rejected. An
  operator repairs the body with the Phase 2 raw body editor. Before Phase 2,
  the repair used a direct database connection. There is no migration for
  these bodies.
- An inventory of the shipped library files found no `audience` tag text and
  no `[[slug]]` links. They need no migration.

## Phase 1: Atomic Server-Side Replacement

One commit contains the kernel module and its tests, the internal replacement
in `Ankole.Brain.Markdoc`, the caller test updates, and the status and
reference updates in this document and in `BrainV3.md`.

| Guarantee | Evidence |
| --- | --- |
| P0 closed | The sample in this document is rejected or projected as empty on all four paths: create, update, chunk, and get_page. The kernel corpus test includes the sample. |
| Code is text | Tag text and `[[...]]` produce no tag and no link in fenced code (``` and ~~~, including a fence with an info string), indented code, an indented fence inside a list, or inline code. |
| A misplaced tag is rejected | Tag text in the middle of a line, a heading, a blockquote, a paragraph with more than one line, or an HTML block returns `misplaced_audience_tag`. |
| Pairing semantics | Nested tags, unopened tags, unclosed tags, and invalid scopes return the same error codes as the previous implementation. |
| Behavior preserved | The markdoc, objects, get_page, forget, and dreaming tests in `app/control_plane` pass. Fixtures can differ in whitespace. |

To verify Phase 1, run `cargo test` and `mix test` in `app/kernel`. Set the
`cargo test` features the same way as the `program_runner` tests. In
`app/control_plane`, run `mix test test/ankole/brain/markdoc_test.exs` and the
other affected test files.

## Phase 2: Create and Edit Objects in the Console

One commit contains this phase. Before you start, read
`app/webapps/AGENTS.md`.

### Projection Ownership

`managed_by_source_id` now means that one Brain Source owns the body.
SourceLearning must set it when it writes a media Object, and it must use the
internal upsert path that the Source identity constrains. Ordinary Object
updates still reject every managed Object. There is no second owner field.

### Editable State

The server returns the editable state. The Console does not guess it from a
badge or a type:

| State | Body operations | Guidance |
| --- | --- | --- |
| Instance-owned and not deleted | Create, edit, and save | `Objects.create_object/3` or `Objects.update_object/4` |
| Deleted | Read-only | Restore the Object first, then edit it |
| Ordinary Library projection | Read-only | Fork is available. After a fork, the body belongs to the instance and receives no more projection updates. This behavior is unchanged. |
| SourceLearning media projection | Read-only | Open the Source to learn it again or to archive it. Fork is not available. |
| `agent-skills` projection | Read-only | Open the Agent Library. Fork is not available. |

### Console API

An Object slug contains `/`, so create and update use the collection path and
carry the slug in the request body:

| Method and path | Purpose | Key input or output |
| --- | --- | --- |
| `GET /brain/objects/show?slug=...` | Load the details and the edit baseline | Adds raw `body`, `content_hash`, `editable`, and `edit_block_reason` |
| `POST /brain/objects` | Create an instance Object | slug, type, subtype, title, body, meta, and effective_date |
| `PUT /brain/objects` | Update an instance Object | slug, the mutable fields, and `expected_content_hash` |

Create and update require `brain:update`. The API returns the raw body only
inside the `brain:read` management boundary. A 422 response carries a
structured diagnostic with `code` and `line`. A 409 response is only for a
content hash conflict. After the control-plane schema is complete, regenerate
the OpenAPI document and the Web client as the repository rules require. Do not
edit generated files by hand.

There is no "preview as Principal" endpoint. The scope badges in the full
preview already show the confidentiality boundary. To verify real disclosure,
read the page once as the target Principal.

### Editor

The editor has the dedicated full-page routes `/brain/objects/new` and
`/brain/objects/:slug/edit`. The first version is minimal by design:

- The source uses a plain textarea. There is no CodeMirror.
- The preview column uses a local, preview-only segment function in the
  console state layer. The function is a fence state machine plus a tag-line
  regular expression, about 60 lines long. Each segment renders with the
  existing `MarkdownBody` and gets a scope badge. The preview shows `[[slug]]`
  as literal text. This is acceptable.
- Local segmentation serves only the preview. On save, the server always
  analyzes the body again, and the Problems area shows the 422 diagnostics.
  For unusual input, the local preview and the server can disagree. The server
  result is authoritative.
- A save sends the `expected_content_hash` from page load. On a 409 response,
  the editor keeps the local draft and lets the operator reload and compare.
  It does not overwrite anything automatically. Before the operator leaves a
  page with unsaved changes, the editor asks for confirmation.
- On create, the operator can set slug, type, subtype, title, effective_date,
  and meta. On edit, slug and type are read-only. The domain update contract
  does not support a rename or a type change, and the editor does not invent a
  second path for them.

The acceptance E2E test creates and edits an Object with `audience` from the
Console. It reads the Object as a Principal with access and as a Principal
without access, and it checks the versions and the chunk scopes. An
administrator can open the edit page of an existing broken body, see the
diagnostics, and save a repair.

## Rejected Options

Each item below was considered and rejected. Do not add it back:

- No `@markdoc/markdoc`, shared JS package, Bun build output, separate process,
  Port, process pool, or deno_core isolate. Parsing is one NIF function.
- No full Markdoc. There is no `if`/`else`, variable, function, partial,
  annotation, inline tag, or nested tag. When a second tag becomes necessary,
  evaluate a complete move to full Markdoc again. Do not add features to the
  thin layer.
- No markdown-it-rs, no tree-sitter, and no hand-written CommonMark parser.
  Facts about block structure come only from comrak.
- No stored AST, segments, or diagnostics, and no cache of parse results.
  Native parsing takes microseconds, so the read path calls it directly.
- The kernel exposes only this one NIF. It has no format, transform, or render
  function.
- No formatting feature. The source is stored verbatim, and there is no
  formatter.
- No WYSIWYG, CodeMirror, or syntax highlighting in the first version.
- No "preview as Principal" endpoint.
- The `rendered` field name of `GetPage` and its concatenated projection stay
  as they are. Do not rename or refactor them.
- No migration and no runtime compatibility branch for existing bodies that
  break the new syntax.

## References

- [comrak documentation](https://docs.rs/comrak). The parser uses
  `Options.extension.wikilinks_title_after_pipe`, `NodeValue::CodeBlock`,
  `NodeValue::Code`, `NodeValue::WikiLink`, and node sourcepos.
- [Markdoc tags](https://markdoc.dev/docs/tags), the tag syntax shape for a
  future move to full Markdoc.

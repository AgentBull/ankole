# Ankole Block Editor Specification

This specification defines the behavior of the `@ankole/block-editor` package in `libs/ankole-editor` (version `0.1.0` in `package.json`). It covers the page tree, the Markdown and XML source formats, the editing engine, the React component, the host interface, the example host, and browser compatibility checks.

## 0. Authority and conventions

- This specification is the sole authority for package behavior. Any disagreement between the implementation and this document is a defect; whenever you change behavior, update this specification in the same change.
- Every statement in this specification is a normative requirement, except paragraphs explicitly labeled "Note".
- `upstream/fixtures/commonmark-dialect.json` records every case where this Markdown dialect differs from the CommonMark reference implementation and forms part of this specification.
- `upstream/NOTICE.md` lists the sources and licenses of third-party test fixtures.
- In keyboard shortcuts, `⌘` denotes the Command key on Apple platforms (macOS, iOS, and iPadOS) and the `Ctrl` key on other platforms, whereas `Ctrl` denotes the Control key on every platform. On Apple platforms, editor shortcuts never combine `Ctrl` with a letter because macOS reserves those bindings for native text editing.
- Document errors and warnings are emitted in Chinese. Interface labels also default to Chinese and can be localized via `BlockEditor.labels` (section 7.6); parsing and serialization never depend on interface labels.

| Term | Meaning |
| --- | --- |
| Page | One complete document body. Every read, write, and revision check applies to a whole page. |
| Page tree | The structured content of a page: elements, attributes, text, and ordered child nodes |
| Element | A node with a name, attributes, and ordered child nodes |
| Block element, inline element | The two element categories defined in the vocabulary (section 2) |
| Shorthand | CommonMark and GitHub Flavored Markdown (GFM) syntax, such as `**bold**` and `- list` |
| Tag | Explicit angle-bracket syntax for an element, such as `<u>underline</u>` |
| Vocabulary | The catalog of known elements, defining each element's kind, allowed content, attributes, and attribute values |
| Unknown element | Any element whose name is not in the vocabulary |
| Normalization | The transformation that puts a page tree into canonical normal form (section 3), written `N` in this specification |
| Read-only element | An element rendered in the editor that can be modified only in source mode (section 7.4) |

## 1. Page tree

### 1.1 Nodes

A page tree contains only two node types:

- Text node: `{ type: 'text', value: string }`.
- Element node: `{ type: 'element', name: string, attrs: Record<string, string>, children: Node[] }`.

Child node order is significant; attribute order is not. Every attribute value is a string, and an attribute whose value is `""` is distinct from an omitted attribute except for the optional attributes listed in section 3.1. The tree contains no node IDs, XML comments, processing instructions, CDATA sections, or DTDs. Discussion anchors are ordinary `comment` elements tied to host-owned threads.

### 1.2 Names

- Element name: starts with a Unicode letter, followed by zero or more letters, digits, `-`, or `_`.
- Attribute name: starts with a Unicode letter or `_`, followed by zero or more letters, digits, `-`, or `_`. `xmlns` is forbidden as an attribute name.
- Every name must also be a valid XML name. Names are case-sensitive, and names containing `:` or `.` are invalid.

### 1.3 Characters

Text and attribute values may contain only valid XML 1.0 characters: U+0009, U+000A, U+000D, U+0020–U+D7FF, U+E000–U+FFFD, and U+10000–U+10FFFF. Lone surrogates are invalid. Neither reading nor writing applies Unicode normalization (NFC or NFD).

### 1.4 Root element

The root element is `page`, which takes no attributes and may appear only as the root. Markdown source omits the `<page>` wrapper, whereas XML source wraps the document in `<page>…</page>`. Page metadata—title, identity, and revision number—lives outside the page tree.

### 1.5 Size limits

- Source input has a maximum length of 8,388,608 UTF-16 code units.
- A page has a maximum of 100,000 element and text nodes combined (excluding layout whitespace) and a maximum nesting depth of 128 levels below `page`.

When input exceeds any of these limits, the package raises an error instead of truncating content.

## 2. Vocabulary

| Element | Kind | Content | Attributes and values | Other requirements |
| --- | --- | --- | --- | --- |
| `p`, `h1`…`h6` | Block | Inline | `align`: `left`, `center`, `right`, or `justify`. `indent`: an integer from 1 to 999. `style`: `color`, `background-color`, and `text-transform` declarations. | — |
| `block` | Block | Block | — | The first block is the parent's content; subsequent blocks are its children. |
| `columns` | Block | Only `column` | — | A horizontal row of columns. |
| `column` | Block | Block | `width`: an integer from 1 to 9999, default 1000 | Only in `columns`; widths are relative weights within the row. |
| `blockquote` | Block | Block | — | — |
| `ul` | Block | Only `li` | — | — |
| `ol` | Block | Only `li` | `start`: 0, or a positive integer with a maximum of 9 digits | — |
| `li` | Block | Block | `task`: `todo` or `done` | Only in `ul` or `ol` |
| `pre` | Block | Text and `comment` wrappers | `lang`, `meta`: any value. `wrap`: `true`. | Comment wrappers preserve literal code whitespace; other inline elements are invalid. |
| `math` | Block | Text | — | The text is the LaTeX source of a display formula. |
| `mermaid` | Block | Text and `comment` wrappers | `view`: `both`, `code`, or `diagram`, default `both`. `theme`: `auto`, `light`, or `dark`, default `auto`. | The text is Mermaid source rendered as a diagram. |
| `hr` | Block | Empty | — | — |
| `table` | Block | Only `tr` | `widths`: comma-separated pixel widths from 1 to 9999. `layout`: `full`. | Widths follow logical column order. |
| `tr` | Block | Only `th` and `td` | — | Only in `table` |
| `th`, `td` | Block | Block | `align`: the same values as for `p`. `colspan`, `rowspan`: an integer from 1 to 9999. `background`: a six-digit hex color. | Only in `tr` |
| `callout` | Block | Block | `tone`: `info`, `warning`, `success`, `danger`, or `neutral`. `icon`: any value. | — |
| `embed` | Block | Empty | `href`, `title`, `ref`, `table`, `view`: any value | `href` selects an external iframe; `ref` identifies a host-owned Page. |
| `media`, `bookmark` | Block | Empty | `src`, `title`, `description`, `image`, `mime`, `size`: any value. `kind`: `image` or `video`. `view`: `link`, `title`, `card`, or `preview`. | Uploaded bytes belong to the host asset store. |
| `a` | Inline | Inline | `href`: any value, required. `title`: any value. | — |
| `img` | Inline | Empty | `src`: any value, required. `alt`, `title`: any value. | — |
| `mention` | Inline | Empty | Exactly one of `page` (canonical lowercase UUID) or `principal` (non-empty ASCII UID without whitespace) | Host-resolved inline reference; `N` strips any enclosing `a`. |
| `br` | Inline | Empty | — | — |
| `span` | Inline | Inline | `style`: `color`, `background-color`, and `text-transform` declarations | — |
| `comment` | Inline | Inline | `ids`: space-separated lowercase UUIDv7 thread IDs, required | IDs normalize to a sorted unique set; no other attributes. Inside `pre` and `mermaid`, descendants contain only text and comment wrappers. |
| `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`, `code` | Inline | Inline | — | — |

If a known element carries attributes outside the vocabulary, the package preserves them unchanged and reports each one as a warning (section 6.4). Likewise, the package preserves unknown elements and all of their attributes unchanged and reports each unknown element as a warning.

An external `embed` stores the original HTTP(S) URL in `href` and a display title. The renderer derives iframe URLs for Figma, YouTube, and Vimeo while preserving the original address for editing and opening. Other HTTP(S) addresses render directly in an iframe; the destination controls whether browsers may frame it. The block always offers its original link.

A Page `embed` stores `ref`, with optional `table` and `view` for a Base. The host resolves that reference and owns the target's existence, permissions, and lifecycle. The document contains no copy of the target's fields, records, views, or settings.

Ankole uses two internal URI forms in attributes: `ankole:page/<page ID>` in `href` for page links, and `ankole:asset/<digest>/<file name>` in `src` for page-owned files and media. The codecs preserve both forms verbatim; the editor host resolves them for display.

## 3. Normalization

Normalization (`N`) strips only differences that are invisible to a reader: if two trees are equal after `N`, they represent the same page. The package applies `N` whenever it parses Markdown or XML, prints output, imports a tree into the editor, or reads a tree from the editor.

### 3.1 Attributes

- `N` sorts attributes by name in Unicode code-point order.
- If a known attribute has a value outside those permitted in section 2, `N` reports an error.
- In a `style` value, `N` keeps only the `color`, `background-color`, and `text-transform` declarations. `N` drops every other declaration instead of reporting an error, so a stored page with other styles still opens. A value with only kept declarations stays as written; otherwise `N` joins the kept declarations with `; `, and a value with none of them is empty.
- When the vocabulary declares `alt`, `title`, `lang`, `meta`, or `style` on an element and its value is `""`, `N` drops the attribute. `N` also drops `start="1"` on `ol`, `width="1000"` on `column`, `colspan="1"` and `rowspan="1"` on `th` and `td`, and `view="both"` and `theme="auto"` on `mermaid`.
- Missing a required attribute on an element is an error.

### 3.2 Block content

The content categories below correspond to the **Content** column in section 2. An "Only …" rule (such as "Only `li`") restricts children to that exact set of elements.

- Inside an element with "Block" or "Only …" content, text consisting solely of spaces, tabs, CR, and LF is layout whitespace and `N` removes it; any other direct text is an error.
- Inside an element with "Only …" content, any child element outside that allowed set is an error.
- Inside an element with "Block" content, a direct child that is a known inline element is an error.
- An element with "Text" content (`pre`) may contain only text, and an element with "Empty" content may have no child nodes.
- `N` removes any `ul` or `ol` that has zero list items.
- A `block` without attributes and with fewer than two children becomes its sole child, or an empty paragraph when it has no children. A wrapper with unknown attributes stays so those attributes survive a round trip.
- A `columns` row without attributes drops columns with no blocks or unknown attributes. A column containing an empty paragraph remains editable. If one column remains, its blocks replace the row unless the column has unknown attributes; if none remain, the row is removed. Unknown wrapper attributes are preserved.
- `N` merges adjacent lists of the same element name (two `ul`s or two `ol`s) into a single list. The merged list keeps `start` from the first list and combines all other attributes; if the two lists disagree on any attribute other than `start`, `N` reports an error.

### 3.3 Content of unknown elements

- Mixing a known block element with inline content (non-whitespace text or a known inline element) among the children of an unknown element is an error.
- If the children include a known block element, `N` normalizes them as block content (section 3.2).
- If all three conditions below hold, every text child—including leading and trailing text—is treated as layout whitespace and removed by `N`:
  - At least one child is an element.
  - No child is a known inline element.
  - Every text child contains only spaces, tabs, CR, and LF, and includes at least one line break.
- Otherwise, `N` normalizes the children as inline content (section 3.4).

### 3.4 Inline content

To normalize inline content, `N` first flattens it into a sequence of segments and then rebuilds the element hierarchy using the rules below. Each segment is either a contiguous run of text or a single atomic element, annotated with a set of active formats, an inline `style`, and an optional enclosing `a` link.

Expansion rules:

- Attribute-free `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`, and `code` elements add their format to enclosed segments; nested occurrences of the same format collapse into one.
- A `span` with no attributes or with only a `style` attribute contributes to the `style` of its enclosed segments. When nested styles combine, `N` places the outer style first, appends `;` if the outer style does not already end with one, and separates the inner style with a single space.
- Segments inside an `a` inherit that link. Nested links are invalid, and an empty `a` is treated as an atomic element.
- `br` and `img` are atomic elements: they carry neither formats nor `style`, though they retain an enclosing link.
- `mention` is an atomic empty inline element: it inherits surrounding formats, `style`, and `comment` marks while dropping any enclosing `a` link.
- Every other inline element—unknown inline elements, format elements that carry attributes, and `span` elements with attributes other than `style`—is also atomic. It inherits the formats, `style`, and link of its ancestors, while `N` normalizes its own children according to that element's content rules.

Soft line-break rules:

- Outside `code`, `N` replaces each line break (CRLF, CR, or LF)—together with any spaces or tabs immediately before it and all whitespace immediately after it—with a single space, except in three cases where `N` deletes the break and surrounding whitespace altogether:
  - The nearest visible characters on both sides of the line break are Chinese or Japanese characters.
  - The line break lies at the very start or end of the inline content.
  - The line break immediately follows a `br`.
- A Chinese or Japanese character is any Han, Hiragana, or Katakana character, or any code point in U+3000–U+303F, U+30FC, U+FE30–U+FE4F, or U+FF00–U+FFEF.
- When scanning for the nearest visible character, `N` skips plain whitespace, whereas whitespace formatted as `code`, underline, strikethrough, or highlight counts as visible. A `br` acts as a content boundary, and every other atomic element counts as a visible character that is neither Chinese nor Japanese.
- Inside `code` text, `N` replaces each line break with a single space.

Additional cleanup rules:

- Outside `code` text, `N` hoists leading and trailing whitespace out of bold (`strong`) and italic (`em`) formatting while keeping all other formats on that whitespace intact.
- `N` merges adjacent text segments that share identical formats, `style`, and link, and drops empty text segments.

Rebuild rules:

- `N` wraps maximal runs of adjacent segments that share the same non-empty `style` in a single outer `span`.
- Within each constant-style run, adjacent segments that share the same link form a link unit and are wrapped in one `a`. If a link spans segments with different `style` values, each styled run produces its own `a`.
- Let a *unit* be either a link unit or an unlinked segment. Scanning left to right, `N` picks the format that covers the longest run of consecutive units, wraps that run, and recurses inside it. Ties break in the priority order `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`. For `strong` and `em`, a whitespace-only unit does not interrupt a run.
- `code` is always the innermost format, wrapping text or an atomic element directly.
- `N` rebuilds the interior of each link by the same rules; if a format covers the entire link, `N` places that format outside `a`.

## 4. Markdown

### 4.1 Input syntax

- The base grammar is CommonMark 0.31.2 with four GFM extensions: tables, task list items, strikethrough, and bare URLs (GFM autolink literals). Footnotes are not supported.
- Three CommonMark constructs are omitted: indented code blocks, raw HTML, and angle-bracket autolinks. Leading indentation never creates a code block and never prevents block markers, so headings, thematic breaks, code fences, and list markers indented by four or more spaces remain valid.
- Every `<…>` construct is parsed as a tag (section 4.3) using MDX's expression-free JSX tag syntax.
- HTML named and numeric character references are decoded in text, link destinations and titles, code fence info strings, and attribute values.

### 4.2 Elements from shorthand

| Markdown | Element |
| --- | --- |
| Paragraph | `p` |
| ATX heading, Setext heading | `h1`…`h6` |
| Thematic break | `hr` |
| `>` block quote | `blockquote` |
| Bullet list, ordered list | `ul` or `ol`. An ordered list's starting number is stored in `start`. |
| List item, `[ ]` or `[x]` task item | `li`, with `task="todo"` or `task="done"` on task items. |
| Fenced code block | `pre`. The first word of the info string becomes `lang`, and the remainder becomes `meta`. |
| `$$` formula block | `math`. The formula must occupy its own paragraph, and the text between the delimiters becomes the LaTeX source. Single-line `$$…$$` stays inline math and is rejected. |
| Mermaid fence | `mermaid`. The info string is exactly `mermaid` with no meta, and the fence body becomes the Mermaid source. |
| GFM table | `table` > `tr` > `th` (header row) or `td`. Column alignment sets `align` on every cell in that column, and each cell wraps its inline content in a single `p`. |
| `*x*`, `_x_` | `em` |
| `**x**`, `__x__` | `strong` |
| `~~x~~`, `~x~` | `s` |
| `` `x` `` | `code` |
| Hard line break (two trailing spaces or a trailing backslash) | `br` |
| Link | `a`, with `href` and `title` |
| Image | `img`, with `src`, `alt`, and `title` |
| Link reference, image reference | `a` or `img` resolved from its definition; when duplicate labels exist, the first definition wins. |
| Link reference definition | Omitted from the page tree |
| GFM bare URL | `a`. Addresses starting with `www.` receive an `http://` prefix, and email addresses receive a `mailto:` prefix. |

### 4.3 Tags

Syntax:

- Start tags use `<name attributes…>`, end tags use `</name>`, and self-closing empty elements use `<name />`.
- Attributes take the form `name="value"` or `name='value'`; a bare attribute `name` receives `"name"` as its value.
- JSX value expressions (`{…}`), spread attributes (`{...x}`), fragments (`<>`), and duplicate attribute names are syntax errors.
- `{…}` in body text is literal text, and `<` inside inline code or code blocks is literal text.

Where a tag appears determines whether the parser treats it as block or inline:

1. A line containing only tags and whitespace forms block tags. Content between block tags may be indented and—except under rules 5–9—is parsed as Markdown blocks separated by blank lines.
2. A tag embedded within paragraph text is an inline element whose content is parsed as inline Markdown. An inline tag may span soft line breaks inside a paragraph, provided no blank line or tag-only line appears between its start and end tags.
3. If a paragraph consists solely of a single known block element or a single unknown element, the parser treats that element as a block; if it is a known block element whose content model is "Block", its inline content is wrapped in a `p`.
4. If a paragraph consists solely of known block elements separated only by whitespace (such as one `<td>a</td>` per line), each element is parsed as a block.
5. A known element with inline or empty content (such as `p`, `h2`, or `u`) may be written with block tags, provided its body is at most a single paragraph (which may contain inline tags); multiple paragraphs or nested blocks are an error. A block element parses directly as that element, whereas an inline element is wrapped in a `p`.
6. When an unknown element is written with block tags, the parser treats its body as inline content if all three conditions hold:
   - Every line inside the body contains only tags (no plain-text paragraph).
   - At least one tag is a known inline element.
   - None of the tags is a known block element.

   Otherwise, the parser reads its body as block content.
7. When `pre` is written with block tags, its body must be either empty or a single fenced code block. The parser merges the `<pre>` tag's attributes with the fence's `lang` and `meta`, raising an error if either attribute is specified in both places.
8. When `math` is written with block tags, its body must be empty or a single `$$` formula block. The tag may carry attributes that the `$$` syntax cannot express.
9. When `mermaid` is written with block tags, its body must be empty or a single `mermaid` fence. The tag may carry `view` and `theme` that the fence cannot express.

### 4.4 Lenient forms

If strict parsing fails, the parser rewrites unescaped `<` characters according to the table below and retries once. It leaves `<` untouched in three positions:

- inside code spans or fenced code blocks
- immediately after a backslash escape
- at the start of a link destination (immediately after `](` and optional whitespace)

| After the `<` | Action |
| --- | --- |
| `!--`, `![CDATA[`, `?`, or `!` | Raise an error for a comment, CDATA section, processing instruction, or `<!…>` declaration |
| An angle-bracket autolink such as `<https://…>` or `<a@b.c>` | Raise an error |
| A complete tag | Wrap unquoted attribute values in double quotes, and self-close HTML void start tags (`area`, `base`, `br`, `col`, `embed`, `hr`, `img`, `input`, `link`, `meta`, `param`, `source`, `track`, `wbr`) by inserting ` /` before `>` |
| Other text | Escape `<` so it parses as literal text |

Any error positions reported on retry are mapped back to offsets in the original source.

### 4.5 Canonical output

The Markdown printer emits canonical output, choosing the first applicable representation for each element in the order: shorthand, GFM, tag.

Block elements:

| Element | Condition for shorthand | Form if the condition is false |
| --- | --- | --- |
| `p` | Has no attributes, is non-empty, is not a single line of tags with no whitespace, and is not a single unknown element. | `<p …>…</p>`, or `<p />` when empty. |
| `h1`…`h6` | Has no attributes. | Single-line tag |
| `blockquote` | Has no attributes. | Block tags |
| `ul`, `ol` | The list has no attributes other than `start` on `ol`; items have no attributes other than `task`; and every task item begins with an attribute-free, non-empty `p`. | Block tags for both the list and every list item |
| `pre` | Carries only `lang` and `meta` (no `wrap`); `lang` contains no whitespace, `` ` ``, `&`, or `\`; `meta` is present only when `lang` is also present; and `meta` has no line breaks, `` ` ``, `&`, `\`, or leading/trailing whitespace. | Block `<pre …>` tags carrying all attributes, wrapping an info-free code fence. |
| `math` | Has no attributes. | Block `<math …>` tags wrapping a `$$` formula block. |
| `mermaid` | Has no attributes. | Block `<mermaid …>` tags wrapping a `mermaid` fence. |
| `hr` | Has no attributes. | `<hr … />` |
| `table` | Neither the table nor its rows have attributes; the first row has only `th` cells and subsequent rows have only `td` cells; every row has the same cell count; every cell in a column shares the same `align` (excluding `justify`) and has no other attributes; every cell contains a single attribute-free `p` whose text has no leading or trailing whitespace; and no attribute value inside a cell contains `\|`. | Block tags. Rows in which every cell contains a single shorthand-eligible paragraph print one cell per line; other rows print cells as block tags as well. |
| Other block elements | — | Block tags when all children are non-inline elements, `<name … />` when empty, or a single-line tag otherwise. |

Inline elements:

| Element | Condition for shorthand | Shorthand |
| --- | --- | --- |
| `strong`, `em`, `s` | No attributes | `**…**`, `*…*`, `~~…~~` |
| `code` | No attributes, and a single text child | `` `…` `` |
| `a` | Only `href` and `title` | `[text](url "title")`, or a bare URL when all conditions below hold |
| `img` | Only `src`, `alt`, and `title` | `![alt](url "title")` |

All other inline elements—and any element in the table above whose shorthand condition fails—are printed as tags.

Output formatting rules:

- Unordered lists use `-`, switching to `*` whenever `-` would parse as a thematic break or an empty sublist. Ordered lists start at `start` and increment by 1. List item content begins one space after the marker.
- A list item containing a single block, or a single paragraph followed by a single sublist, is printed tight (no internal blank lines); all other list items separate child blocks with a blank line.
- Headings use ATX `#` markers. Code fences use backticks, lengthening the fence whenever the code body contains backticks. Thematic breaks print as `---`, and hard line breaks print as `<br />`.
- Top-level and nested blocks are separated by a single blank line, and block-tag bodies are indented by two spaces.
- In plain text, characters that would otherwise trigger Markdown or tag syntax are escaped with a backslash (or a character reference where a backslash is insufficient); `<` is always written as `\<`.
- Tag attributes use double quotes in code-point name order, escaping `&` as `&amp;`, `<` as `&lt;`, `"` as `&quot;`, tab as `&#9;`, LF as `&#10;`, and CR as `&#13;`.
- If a paragraph line would consist solely of inline tags and whitespace, the printer encodes that whitespace as numeric character references so the parser still reads the line as a paragraph; if the line consists solely of inline tags with no whitespace, the printer wraps the paragraph in `<p>…</p>`.
- A link prints as a bare URL when all five conditions hold:
  - It has a single text child and no `title`.
  - `href` equals `text`, `http://${text}`, or `mailto:${text}`.
  - Parsing `text` alone under GFM produces the exact same link.
  - The link sits at the start of inline content or immediately after whitespace.
  - The link sits at the end of inline content, or is followed by zero or more characters from `.,:!?)` and then whitespace or end of content.
- Printed Markdown has no trailing newline.

Markdown is portable content: the printer unwraps `comment` elements and preserves their content, excluding live thread IDs. Before returning, the printer reparses its own output and compares the resulting tree against `N(stripComments(tree))`. If reparsing fails, the printer throws `Error` prefixed with `规范 Markdown 无法读回：` ("Canonical Markdown cannot be read back: ") followed by the underlying cause; if the reparsed tree differs, it throws `Error` with `规范 Markdown 读回后得到不同的页面` ("Canonical Markdown gives a different page when it is read back"). In either case, no output is returned. XML retains the complete canonical page, including discussion anchors.

### 4.6 Differences from CommonMark

The test suite opens all official CommonMark 0.31.2 examples in the editor and compares the rendered structure against the CommonMark reference implementation, ignoring four expected presentation equivalences:

- Soft line breaks normalize to spaces.
- Leading or trailing whitespace hoisted out of bold or italic formatting matches plain whitespace.
- List-item comparisons check paragraph breaks rather than tight-versus-loose `<p>` wrappers.
- Percent-encoded characters in link and image URLs are compared after decoding.

Every remaining divergence is recorded in `upstream/fixtures/commonmark-dialect.json` with its cause and exact expected XML or error message. All dialect differences stem from six design choices:

- Leading indentation never forms a code block and never blocks other block markers.
- `<…>` tags represent page elements: known elements map to vocabulary nodes, unknown elements remain preserved as unknown elements, and tag interiors are parsed as Markdown.
- A `<` that does not begin a complete tag falls back to literal text.
- Bare URLs and email addresses become links under GFM autolink rules.
- Adjacent lists of the same kind merge into one list.
- Angle-bracket autolinks, comments, CDATA sections, processing instructions, `<!…>` declarations, incomplete or unclosed tags, and vocabulary violations raise errors.

## 5. XML

Reading XML:

- Only XML 1.0 is accepted. An XML declaration is optional; when present, `version` must be `1.0` and `encoding` (if specified) must be `UTF-8`.
- `DOCTYPE` declarations, comments, and processing instructions raise errors. CDATA sections are read as plain text, and only the five predefined XML entities plus numeric character references are recognized.
- The root element must be `page`, and the parser applies `N` before returning the tree.

Printing XML:

- The XML printer omits the XML declaration, inserts no layout whitespace, and writes childless elements as `<name />`.
- Attributes are double-quoted and sorted by name.
- Text escapes `&` as `&amp;`, `<` as `&lt;`, `>` as `&gt;`, and CR as `&#13;`; attribute values additionally escape `"` as `&quot;`, tab as `&#9;`, and LF as `&#10;`.

## 6. Errors and warnings

### 6.1 Error object

When source input is invalid, parsing throws `DocumentError` with these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `format` | `'markdown' \| 'xml'` | The source format |
| `reason` | `string` | What failed |
| `fix` | `string` | How to fix the problem |
| `start`, `end` | `number` | UTF-16 offsets in the original source |
| `line`, `column` | `number` | 1-based line and column numbers (column counts UTF-16 code units) |

`message` uses the format `{Markdown|XML} 第 {line} 行第 {column} 列：{reason}。{fix}` ("Markdown or XML, line {line}, column {column}: {reason}. {fix}").

When an error is not tied to a specific node position, it points to the start of the source (`line = 1`, `column = 1`, `start = 0`).

### 6.2 Error reasons

The templates below use these placeholders:

- `x` and `y`: element or attribute names from the source
- `a`: an attribute name
- `v`: an attribute value
- `c`: a character
- `U+XXXX`: a Unicode code point
- `…`: context-specific detail

| Category | `reason` | Meaning |
| --- | --- | --- |
| Source | `源码超过 8388608 个 UTF-16 单元` | The source is longer than 8,388,608 UTF-16 code units. |
| Source | `含有 XML 1.0 不允许的字符 U+XXXX` | The source contains U+XXXX, which is not an XML 1.0 character. |
| Tag syntax | `标签 <x> 没有闭合` | The tag `<x>` is not closed. |
| Tag syntax | `结束标签 </x> 与开始标签 <y> 不匹配` | The end tag `</x>` does not match the start tag `<y>`. |
| Tag syntax | `结束标签前没有对应的开始标签` | An end tag has no start tag before it. |
| Tag syntax | `结束标签 </x> 和开始标签不在同一层` | The end tag `</x>` is not at the same level as its start tag. |
| Tag syntax | `标签中不能有字符 c` | A tag cannot contain the character c. |
| Tag syntax | `标签没有写完` | The tag is not complete. |
| Tag syntax | `标签语法错误（…）` | Tag syntax error (…). |
| Tag attributes and names | `属性不能写成 {…} 表达式` | An attribute cannot be a `{…}` expression. |
| Tag attributes and names | `属性 x 的值不能写成 {…} 表达式` | The value of the attribute x cannot be a `{…}` expression. |
| Tag attributes and names | `重复属性 x` | The attribute x occurs more than one time. |
| Tag attributes and names | `页面不支持片段 <>…</>` | A page cannot contain a fragment `<>…</>`. |
| Tag attributes and names | `元素名 "x" 不合法` | The element name "x" is not valid. |
| Tag attributes and names | `属性名 "x" 不合法` | The attribute name "x" is not valid. |
| Input that pages do not accept | `页面没有注释节点` | A page has no comment nodes. |
| Input that pages do not accept | `页面不支持 CDATA` | A page cannot contain CDATA. |
| Input that pages do not accept | `页面不支持处理指令` | A page cannot contain processing instructions. |
| Input that pages do not accept | `页面不支持 <!…> 声明` | A page cannot contain `<!…>` declarations. |
| Input that pages do not accept | `页面不支持尖括号自动链接` | A page cannot contain angle-bracket autolinks. |
| Input that pages do not accept | `页面不支持 DOCTYPE` | A page cannot contain a DOCTYPE. |
| Input that pages do not accept | `只支持 XML 1.0` | Only XML 1.0 is accepted. |
| Input that pages do not accept | `源码编码必须是 UTF-8` | The source encoding must be UTF-8. |
| Input that pages do not accept | `缺少 page 根元素` | There is no `page` root element. |
| Position and content | `<pre> 只能包含一个代码围栏` | `<pre>` can contain only one code fence. |
| Position and content | `<pre> 的 x 写了两次` | The x of `<pre>` is written two times. |
| Position and content | `<x> 只能包含一段行内内容` | `<x>` can contain only one paragraph of inline content. |
| Position and content | `<x> 只能包含行内内容` | `<x>` can contain only inline content. |
| Position and content | `<x> 只能放在 <y> 里` | `<x>` can be only in `<y>`. |
| Position and content | `<x> 只能包含文字` | `<x>` can contain only text. |
| Position and content | `<x> 是空元素` | `<x>` is an empty element. |
| Position and content | `<x> 中的文字必须放在块元素里` | Text in `<x>` must be in a block element. |
| Position and content | `<x> 只能包含 <y>` | `<x>` can contain only `<y>`. |
| Position and content | `<x> 是行内元素，不能直接放在 <y> 里` | `<x>` is an inline element. It cannot be directly in `<y>`. |
| Position and content | `<x> 不能同时包含块元素和行内内容` | `<x>` cannot contain both block elements and inline content. |
| Position and content | `<x> 是块元素，不能放在行内内容里` | `<x>` is a block element. It cannot be in inline content. |
| Position and content | `链接不能嵌套` | Links cannot be nested. |
| Vocabulary and tree | `根元素必须是 page` | The root element must be `page`. |
| Vocabulary and tree | `page 只能作为根元素` | `page` can be only the root element. |
| Vocabulary and tree | `page 没有属性` | `page` has no attributes. |
| Vocabulary and tree | `comment 只支持 ids 属性` | A comment anchor requires `ids` and accepts no other attributes. |
| Vocabulary and tree | `comment 的 ids 必须是以空格分隔的 UUIDv7` | Thread IDs must be lowercase UUIDv7 values separated by single spaces. |
| Vocabulary and tree | `<x> 的 a="v" 不合法` | `a="v"` on `<x>` is not valid. |
| Vocabulary and tree | `<x> 缺少 a 属性` | `<x>` does not have the attribute a. |
| Vocabulary and tree | `页面超过 100000 个节点或 128 层嵌套` | The page has more than 100,000 nodes or 128 levels of nesting. |
| Vocabulary and tree | `含有 XML 1.0 不允许的字符或孤立代理项` | The content contains a character that is not an XML 1.0 character, or a lone surrogate. |

Every error includes an actionable `fix`. In particular:

- **Unclosed tag**: if the tag opened inside a paragraph, `fix` instructs the author to close it in the same paragraph without a blank line or tag-only line in between; otherwise, `fix` instructs the author to place the closing tag after the content. In both cases, `fix` also notes that a literal `<` in text should be written as `&lt;`.
- **Invalid value on a known attribute**: `fix` lists the allowed values—for example, `align 的值应为 left、center、right 或 justify。` ("The value of align must be left, center, right, or justify.").
- **Wrapper element inside an "Only …" parent** (such as `thead` inside `table`, wrapping children that the parent itself accepts): `fix` instructs the author to remove the wrapper tags.

For low-level XML syntax errors, `reason` carries the message from the XML parser and `fix` is `请修正这处 XML 语法。` ("Correct this XML syntax.").

### 6.3 Errors from the editor and from writes

| Condition | Thrown error |
| --- | --- |
| The revision number is stale. | `Error('文档已变化，源码草稿已保留。请导出草稿并重新读取文档后合并修改。')` ("The document changed. The source draft is kept. Export the draft, read the document again, and then merge your changes.") |
| An input method editor (IME) composition is still active. | `Error('输入法组合尚未结束，请完成输入后再应用')` ("The IME composition is not complete. Complete the input, and then apply it.") |
| The source is invalid. | `DocumentError` |
| The printer cannot serialize the new page. | The print error from section 4.5; the page remains unchanged. |
| Editor content violates a page tree limit (for example, pasted content that exceeds maximum nesting depth). | `readTree` and `read()` throw `TreeError`. |
| The editor encounters an unexpected internal node. | `Error('Unexpected block …')`, `Error('Unexpected block leaf …')`, or `Error('Unexpected inline node …')`, indicating an editor defect. |

### 6.4 Warnings

`unknownNames(tree)` returns warning strings in document order without duplicates. For an unknown element, it emits `未知元素 <x>` ("unknown element <x>"); for an unknown attribute on a known element, it emits `<x> 的未知属性 a` ("unknown attribute a on <x>"). Attributes on unknown elements do not produce additional warnings.

## 7. Editor

### 7.1 Assembly

The editing engine lives in `src/core` as a maintained fork of Wordgard within this package. Changes to `src/core` follow this package's rules rather than tracking upstream automatically; see `src/core/README.md` for provenance, licensing, and divergences from upstream.

`editorExtension()` builds the single canonical editor assembly shared by both the visible editor and headless instances. That assembly comprises:

- the page schema (section 7.2)
- normal-form transaction filters (section 7.5, Normal form)
- undo/redo history
- `PageSession` revision tracking
- block-boundary key handling (`blockKeys`)
- list editing (`listEditing`)
- keyboard and typing shortcuts (`shortcuts`)
- link handling (`links`)
- clipboard handling (`clipboard`)
- DOM input event handling (`nativeInput`)
- table editing (`tableEditing`)
- page-end click handling (`pageEnd`)
- code block highlighting, the language picker, and the toolbar (`codeBlockExtension`)
- the extension contributed by each registered block definition (including Mermaid line-number, scroll, and preview synchronization)

`initialState(initial, config)` creates an editor state from `initial` (either a Markdown string or a page tree) and assembly `config`, throwing `DocumentError` if the Markdown is invalid. The caret starts at the end of the page, so focusing the editor or inserting a block before clicking acts at the end of the page. `headlessState(initial)` creates a headless state configured with `editorExtension()`.

### 7.2 Import: page tree to editor document

`pageDocument(tree)` normalizes `tree` with `N` and converts it into an editor document according to the table below. `replaceTree(state, tree)` builds an editor update that replaces the entire page.

| Element | Editor node |
| --- | --- |
| `p`, `h1`…`h6` | Paragraph or heading, with `align`, `indent`, and `style` stored as node marks. |
| `blockquote` | Quote container; each child block is imported recursively. |
| `ul`, `ol` | Bullet list or numbered list (`start` becomes a parameter on the numbered list). |
| `li` | List-item container; each child block is imported recursively, and `task` becomes a mark on the list item. |
| `pre` | Code block, with `lang`, `meta`, and `wrap` as marks and line breaks represented as line-break nodes. |
| `math` | Formula block whose parameter is the LaTeX source. |
| `mermaid` | Mermaid source block with `view` and `theme` marks; line breaks are line-break nodes. |
| `hr` | Divider |
| `table`, `tr`, `th`, `td` | Table, row, header cell, and cell. Cells are containers, with `colspan`, `rowspan`, `align`, and `background` stored as marks on the cell. The table carries `widths` and `layout` marks. |
| `callout` | Callout container; each child block is imported recursively. |
| `block` | `BlockGroup`: the first block renders at the parent's level and subsequent blocks render one level deeper. |
| `columns`, `column` | Horizontal row and isolated block containers. `width` becomes a relative-width mark on each column. |
| `embed` | Embed |
| `media`, `bookmark` | Atomic resource block with document-owned metadata and view mode. |
| Format elements, `span` with `style` | Text marks: bold, italic, strikethrough, underline, highlight, subscript, superscript, code, and style |
| `comment` | A set-valued `Comment` mark on text and inline leaves; overlapping wrappers union thread IDs. Code and Mermaid blocks retain the same mark on text and line breaks. |
| `a` with content | Link mark on text, preserving all attributes of `a` |
| `br` | Line-break node |
| `img` | Image node, with `alt` and `title` stored as marks |
| Unknown elements, empty `a`, format elements with attributes, `span` with attributes other than `style` | Read-only element (section 7.4). Inline read-only elements inherit the formats, `style`, and link of their ancestors. |

Any attribute not listed above—including unknown attributes—is preserved in an extra-attributes mark on the node across copy, undo, and block-type conversions.

Bullet lists may mix task items and plain items. Table rows may vary in length or be empty, and cells may be empty. Merged cells (`colspan` / `rowspan`) participate in the logical table grid. Selection expands to cover touched merged cells; merge and split commands preserve their content.

An empty page imports as a single empty paragraph carrying a placeholder mark so that it can hold the caret.

### 7.3 Read: editor document to page tree

`readTree(doc)` converts an editor document back into a page tree by reversing the mapping in section 7.2 and applying `N`:

- An empty paragraph carrying the placeholder mark is omitted.
- Characters in text or attribute values that are invalid in XML 1.0 (such as pasted control characters or an unpaired surrogate during input) are stripped from the output without mutating the editor state.

For every valid page tree `T`, importing `T` and reading it back yields `N(T)`.

#### Prepare a submission

`preparePageUpdate(transaction)` prepares the final local transaction of an edit batch for XML storage; run input appenders first and call it only after IME composition has ended. It round-trips the resulting document through the XML codec, computes a diff for any normalization adjustments, and folds that correction into the transaction without shifting text positions on mark-only changes. The returned transaction preserves the mapped selection, effects, annotations, and history boundary.

The client must apply the returned transaction instead of the original one, compose its changes onto earlier changes in the batch, and transmit the combined change set. Normalizing only the outgoing payload while leaving the unnormalized document in memory would desynchronize the next batch. A committed remote change is already prepared. If rebasing that change against pending local edits requires another correction, the client records the correction as local pending work, as described in section 8.1.

When a native document diff changes only marks on unchanged content, it emits mark modifications on retained tokens. Text, inline leaves, and container opening tokens keep their identities and positions. The OT client transforms these modifications against concurrent text insertion without replacing the existing text or collapsing its selection. A `Comment` modification adds or removes only the changed thread IDs, so concurrent annotations preserve each other's set members. Source restoration treats adjacent retains and mark modifications as one retained source interval when deciding which complete comment runs survive.

Compatible block conversions replace the opening token and retain or diff the content inside it. These conversions include paragraphs and headings, heading levels, data and header cells, and bullet and ordered lists. Pending human text remains inside the converted block, and retained comment ranges keep their anchors when an Agent changes the block type.

### 7.4 Read-only elements

A read-only node wraps a single page-tree element and returns it verbatim on read while rendering its contents in the editor:

- Known vocabulary elements render in the editor's standard typography.
- `img` renders the image.
- Links render their text and reveal the target URL on pointer hover.
- Task items render a non-interactive checkbox.
- Callouts and embeds render in their respective block styles.
- Block-level unknown elements render their children alongside a badge naming the element.
- Inline unknown elements render their children and show the element name on pointer hover.

The plain-text value of a read-only element is the concatenation of all text inside it in document order. Authors edit read-only elements—and image attributes—through the source view.

#### Standard typography

The package stylesheet owns the document typography, and a host sets only the width and padding of the page around the editor. Every colour comes from a uikit token, so the light and dark themes use the same rules.

| Element | Size and line | Weight | Space above / below |
| --- | --- | --- | --- |
| Body text (`p`) | 16px, 28px line | 400 | 4px / 4px |
| `h1` | 28px, 1.3 | 600 | 32px / 4px |
| `h2` | 22px, 1.35 | 600 | 24px / 4px |
| `h3` | 18px, 1.4 | 600 | 20px / 4px |
| `h4`, `h5`, `h6` | 16px, 15px, 14px, 1.5 | 600 | 16px / 4px |
| List (`ul`, `ol`) | body text, 26px indent | 400 | 4px / 4px; items 2px apart |
| Task item | body text with a 16px box | 400 | as a list item |
| `blockquote` | body text, 3px ink rule, 14px inset | 400 | 8px / 8px |
| Callout | body text on a light fill, 4px radius | 400 | 8px / 8px |
| Code block | Toolbar 32px; source 13px monospace, 1.65, light fill, 4px radius | 400 | 8px / 8px |
| Formula block | Temml MathML at 1.12em on the paper | 400 | 10px / 10px, 44px minimum height |
| Mermaid block | 36px toolbar; split source and diagram; 13px monospace source | 400 | 8px / 8px, 220px minimum body height |
| Inline `code` | 0.85em monospace on a light fill | 400 | — |
| `hr` | 1px border colour | — | 16px / 16px |
| Table cell | 14px, 1.5 | 400 (header 600) | — |

Body text keeps a 28px line because CJK text needs more leading than Latin text; blocks sit 4px apart, so paragraphs, list items, and task items share one vertical rhythm. A completed task item has an ink box with a paper check and tertiary struck-through text. A link is ink text with a light underline that darkens under the pointer.

### 7.5 Edit behavior

- **Normal form**: Before applying any document-changing update, the editor normalizes it under the rules of sections 2 and 3:
  - Adjacent lists of the same kind merge, keeping the first list's attributes plus any attributes present only on the second list.
  - Formats, styles, and links inside code blocks and Mermaid source are stripped. Both keep comment anchors on text and line breaks.
  - `colspan="1"` and `rowspan="1"` are removed.
  - Invalid attribute values, cell spans above 9999, and empty optional attributes are removed.
- **Typing shortcuts**: Markdown shorthand from section 4.1 (excluding `<…>` tags) acts as live typing shortcuts:
  - Typing a space after a block marker converts the current paragraph when it sits directly inside the page root, a quote, a callout, or a table cell.
  - Pressing Enter after a code-fence marker converts the paragraph into a code block, and typing the closing delimiter of an inline marker applies that inline format.
  - Additional shortcuts trigger when their final character leaves the paragraph containing nothing else: `[] ` converts to a task item, `" ` or `| ` converts to a quote, `---` converts to a divider followed by a new empty paragraph, and `|--` inserts a three-column table outside existing tables.
  - Typing `[ ] ` or `[x] ` at the start of a bullet list item converts only that item into a task item.
  - Shortcuts trigger only on typed input—never on paste or delete—and run once when an IME composition commits.
  - Every shortcut conversion forms its own undo step, so undoing immediately afterward restores the literal characters typed.
- **Typed URLs**: Outside code and existing links, pressing Space or Enter immediately after a URL turns it into a link when all four conditions hold:
  - The URL sits immediately before the caret.
  - It starts at the beginning of the text block or right after whitespace.
  - It begins with `http://`, `https://`, or `www.` (addresses starting with `www.` receive an `http://` prefix).
  - Its final character is not in `.,;:!?'")]`.

  Importing text never auto-links URLs beyond normal Markdown parsing.
- **Lists**: Every list item is a block container whose first text block holds the item's label text, followed by any nested sublists or child blocks:
  - Pressing Enter inside a list item splits it at the caret, moving trailing text and subsequent child blocks into a new sibling item. Splitting after a checked task item creates an unchecked task item.
  - Newly created or outdented empty list items contain no child blocks and print as `-`. While an IME composition is active inside an empty list item, the editor keeps the paragraph that hosts the preedit text and collapses it back to an empty list item only if composition ends without text; elsewhere, if editing leaves a list item with a single empty, attribute-free paragraph, the item collapses to an empty list item.
  - Attaching a sublist to an empty list item inserts an empty paragraph above the sublist.
  - Converting a list item to a paragraph keeps its child blocks under an ordinary parent block.
  - Outdenting a sublist item with Shift+Tab adopts both its existing children and any following sibling items as its children, while any blocks that followed the sublist in the former parent item move into a new list item after the outdented item.
  - When a list follows an ordinary block at the same level, Tab nests its selected leading items under that block, retaining their markers and leaving unselected items in place. Without a preceding sibling to nest under, Tab on the first item is a no-op; a multi-item selection then leaves the first item in place and nests the remaining selected items beneath it.
  - Shift+Tab on list children of an ordinary parent lifts the selected items with their markers. The following list items and ordinary child blocks become children of the last lifted item. Enter in an empty list child uses the same lift.
  - When a list item's text merges into a preceding block, its remaining child blocks append to the previous list item—or move before the list if it was the first item.
  - Pressing Enter in an empty list item outdents it by one level when nested, or converts it into a paragraph (splitting the list) at the top level.
  - Pressing Enter at the very start of a non-empty list item inserts an empty list item above it.
- **Headings**: The insertion and conversion menus expose H1 through H6. Every heading with following content has a folding button; it hides following sibling blocks until the next heading of equal or lower level. Nested headings retain their independent fold state. Folding is local presentation state, maps through edits, and does not change saved content or undo history. Moving the selection into a folded section opens it. The host Page title is larger than H1.
- **Tables**: Slash insertion and `|--` create three columns and three rows with a header row. Cell, row, column, and table menus show their operation scope, active formats, and destructive actions. Row and column handles select their logical ranges, support dragging, and offer keyboard-accessible move commands. Boundary buttons append a row or column. Insertions inherit column alignment; deletions apply to every selected row or column and adjust crossing spans while retaining surviving content. Structural commands fill missing cells in uneven imported tables. Each command is one undo step, and closing an editing menu returns focus to the document.
  - Tab and Shift+Tab navigate cells; Tab at the last cell appends a row, and Mod+Enter inserts a row below the selected row. Both continue editing in the new row. Copying one selected cell copies its content; copying multiple cells retains a table.
  - Adjacent selected cells can merge, retaining their block content and the first cell's attributes. Empty cells contribute no extra blank paragraphs. Splitting keeps content in the first cell and creates the remaining empty cells. Row or column moves are disabled when the resulting order would break a merged cell. Sorting is numeric-aware, keeps the first header row, and is disabled for tables with row spans. An already sorted range produces no transaction; a changed order replaces only the range between the first and last displaced rows.
  - Cell, row, and column menus set alignment and preset or custom background colors, retaining the selection for successive formatting. Header rows and columns use `th`. Foreground contrast follows the selected background. Column widths support pointer resizing, arrow-key adjustment, cancellation with Escape, and equal distribution that preserves the combined width of the selected columns. The drag preview changes no durable state; releasing commits one undo step.
  - Tables scroll independently with overflow hints. A complete header row stays fixed vertically, and a complete header column stays fixed horizontally. Full-width layout expands top-level tables into the document gutters. The scroll region remains keyboard accessible in read-only documents. CSV export quotes every value and prefixes formula-like values with an apostrophe.
  - Markdown uses GFM when the table meets section 4.5; richer attributes and merged cells use lossless block tags. XML, the browser document codec, and the Rust codec share these attributes.
- **Callouts**: The icon opens a style menu with an editable emoji and five background tones. The emoji field writes an IME candidate to the block only when the composition ends. Icon and tone persist on the block. Deleting or cutting a selection whose endpoints lie inside the same callout removes only the selected content and keeps the callout wrapper; if all blocks inside a callout are deleted, one empty paragraph remains.
- **Resources**: Media blocks accept images and videos, including YouTube and Vimeo links. Media blocks offer link, card, and preview views; webpage cards also offer a title view. Webpage title, description, and cover are editable document metadata. The host's `uploadAsset` stores uploaded images and videos before the editor writes their durable addresses. Read-only blocks keep previews and navigation while hiding edit/upload/view controls. Slash search matches the block's translated title, description, canonical name, and multilingual aliases independently of the current interface language. Forms submit only edited fields, preserving concurrent changes to other fields. Replacing a source clears its previous MIME type, size, and explicit media kind; an upload supplies fresh metadata. Preview and portable export choose the explicit media kind first, then the MIME type, then the URL.
- **Parent blocks**: Tab nests an ordinary block under its preceding sibling, using `block` to retain the relationship in the document. The first child has no preceding sibling to nest under. Shift+Tab or Backspace at the child's start lifts it one level, and following siblings become its children. Enter in the parent's own text creates a sibling and transfers its children to that sibling; at the parent's start, Enter inserts an empty paragraph before it. Backspace at a parent's start joins its text to the preceding text block and lifts its children. Block selection, duplication, deletion, clipboard operations, and dragging include descendants. Converting between an ordinary parent and a list item preserves its children. Nesting through Tab is limited to 49 child levels, including the moved subtree.
  - A plain child paragraph inside a list item is edited independently: Enter creates another plain paragraph at the same level, and Enter on an empty child lifts that paragraph out of the list.
- **Embeds**: Backspace and Delete at an adjacent block boundary skip over an embed rather than deleting it (see Delete below), and Up/Down Arrow move the caret past it. Users can delete an embed from the block menu or by deleting a selection that spans or selects the embed node (such as clicking the embed to create a node selection). Deleting an embed block removes only the reference; the target page itself is untouched.
- **Code blocks**: Each editable code block carries a toolbar above its source with the block title, the language picker, the wrap toggle, and copy. The language picker searches labels, canonical names, and common aliases, and lists exact name or alias matches first, then languages with a word that starts with the query; choosing a language stores its canonical name as `lang`, choosing `Plain Text` removes the mark, and either choice is one undo step. A stored language Kirari does not recognize keeps its label in the toolbar and leaves every option unmarked; `Plain Text` is marked only when no language is set or the stored language is `plaintext`. Kirari tokenizes the source per block and paints token classes without changing the document; a block without a language, or with one Kirari does not know, stays plain. The wrap toggle adds or removes `wrap="true"` and lets long lines scroll horizontally when it is absent. Copy writes the literal source, including line breaks but no markup. In read-only documents the language and wrap controls are hidden and copy remains available.
- **Formula blocks**: A formula block is a leaf whose LaTeX source is its parameter. It renders through Temml as display MathML; clicking it, or selecting it and pressing Enter, Space, or `⌘Enter`, opens a formula editor below the block. The editor accepts LaTeX and writes each change to the document immediately, preserving every mark (including unknown attributes), groups consecutive typing into one undo step, marks an invalid formula in its header, and closes on Enter, Escape, or a click outside. The slash menu inserts an empty formula block and opens its editor. Formula blocks follow the ordinary leaf-block deletion and selection rules, and their source round-trips through Markdown `$$` fences and the `math` element.
- **Mermaid blocks**: A Mermaid block is a code-like text block whose source is its content. It renders through Pele into the right-hand pane of a split layout, with a line-number gutter beside the source. The `模板` (Templates) menu replaces the source with a starter diagram, `视图` (View) chooses both panes, code only, or diagram only, `主题` (Theme) chooses the host theme, light, or dark, `展开` (Expand) opens a full-window diagram, and `帮助` (Help) opens the Mermaid syntax reference. View and theme persist on the block (`view`, `theme`). Each source edit re-renders the diagram; an invalid diagram shows Pele's error in place. Typing inside the block is ordinary code editing: Tab indents lines, `/` stays literal, formatting does not apply, comment anchors are preserved, and Markdown fences named `mermaid` round-trip to the block.
- **Delete**: Backspace deletes backward and Delete deletes forward:
  - Backspace removes one grapheme/code-point unit before the caret: an emoji, a zero-width joiner (ZWJ) sequence, or a supplementary-plane character deletes as a single unit, whereas for BMP base characters with combining marks each Backspace strips only the last combining mark. Forward Delete removes the entire character cluster after the caret.
  - On Apple platforms, Ctrl+H deletes one character backward, Ctrl+D deletes one character forward, Ctrl+K deletes to the end of the line (without writing to the kill ring, so Ctrl+Y does not yank it back), Option+Backspace and Option+Delete delete by word, Command+Backspace deletes to the start of the line, and Command+Delete deletes to the end of the line.
  - On non-Apple platforms, Ctrl+Backspace and Ctrl+Delete delete by word.
  - At the start or end of a block, both key presses and browser delete input events (including on-screen keyboards) follow the boundary tables below.
  - If a key or input event arrives before the editor has read an updated DOM selection, the command acts at the caret position currently shown on screen.
- **Input events**: The editor handles `beforeinput` events for text insertion, text replacement, line breaks, paragraph breaks, character transposition, kill-ring yank, drag-and-drop, cut deletion, all delete input types, undo, redo, bold, italic, underline, and strikethrough:
  - During IME composition the browser inserts composition text natively, and clipboard pastes are handled on the `paste` event.
  - The editor cancels these `beforeinput` types without changing the page: `deleteEntireSoftLine`, `formatSuperscript`, `formatSubscript`, `formatJustifyLeft`, `formatJustifyCenter`, `formatJustifyRight`, `formatJustifyFull`, `formatIndent`, `formatOutdent`, `formatRemove`, `formatSetBlockTextDirection`, `formatSetInlineTextDirection`, `formatBackColor`, `formatFontColor`, `formatFontName`, `insertOrderedList`, `insertUnorderedList`, `insertHorizontalRule`, and `insertLink`.
  - Some `insertReplacementText` events (such as OS spellcheck replacements) are non-cancelable, so the browser mutates the DOM directly. If the mutation stays within a pre-existing text node, the editor reads the updated text and applies it once; if the browser alters DOM structure, the editor re-renders from the document state and discards the browser mutation.
  - For browser-applied edits—plain typing, composition updates, and inline deletes—the editor defers DOM re-rendering between `beforeinput` and `input`; any layout measurement during that window observes the previous render.
- **Paste and copy**:
  - Pasting HTML preserves headings, flat and nested lists, quotes, tables, task items (`aria-checked` or GitHub task-list markup), code blocks (`data-language`), links (`href`, `title`), and images (`src`, `alt`, `title`).
  - Microsoft Word list paragraphs (`mso-list` styles) become nested lists: the `mso-list` level sets the nesting, a new list id starts a new list, a numbered or lettered marker makes the list numbered, a first number other than 1 becomes the list's `start`, and the typed marker text is removed.
  - Inline formatting recognizes vocabulary format tags plus `<b>`, `<i>`, `<del>`, and `<strike>`; CSS `font-weight` maps to bold only for `bold` and `700`.
  - Inline styles retain only `text-transform` and alignment (`data-align` or `text-align`, ignoring `start` and mapping `end` to `right`); all other inline styles and all block styles are stripped.
  - Callouts and embeds are recognized from HTML only in the exact markup written by the editor.
  - Copying from an editor embeds the exact serialized slice in the clipboard HTML; on paste, the editor prefers that slice whenever it is present and valid for the schema, falling back to HTML parsing otherwise.
  - When the clipboard contains only plain text, the editor parses it as Markdown and inserts structured page content if parsing succeeds without unknown elements and yields non-paragraph blocks, inline formats, links, or hard breaks; otherwise, it inserts the literal plain text.
  - Inside a code block, paste always inserts literal text with line breaks converted to line-break nodes (extracting one text line per block if the clipboard carries only HTML).
  - When inserting multi-block content, only leading and trailing text blocks stay open: a leading text block merges into the block at the caret, a trailing text block absorbs the text after the caret, and lists, tables, quotes, and callouts insert as closed blocks.
  - Copying a fully selected quote, callout, list item, list, or table copies the whole block structure, except that a table containing just one cell contributes that cell’s content. A single selected cell copies only its content; a list item includes its enclosing list, and a multi-cell selection produces a table of the selected cells, whereas a partial selection inside one list item copies inline content without the list wrapper.
  - Plain-text copy writes one line per text block and formats tables as one line per row with tab-separated cells. Resource blocks contribute their title and address. Clipboard HTML represents media images as images and videos, webpage cards, and external embeds as links; host asset resolution supplies usable addresses. The serialized internal slice keeps every resource attribute.
- **Page-end click**: Clicking the page whitespace below the final block, including the side gutters, appends a root paragraph and places the caret inside it. An empty final root paragraph is reused without changing the document or history. Headings, code, lists, nested blocks, and columns receive a separate paragraph even when their final text block is empty. A click beside a block on the same line positions the caret there; dragging from the whitespace selects blocks without inserting a paragraph. Appending the paragraph is one undo step, separate from subsequent typing.
- **Column boundaries**: Backspace at the start of a column's first text block joins it to the preceding text block in document order. Delete at the end of its last text block joins the following text block. Removing the final block of a column removes that column, and a single remaining column unwraps. The join and layout change share one undo step.
- **Range edits**: Backspace, Delete, typing, Enter, cut, and paste over a text range delete the range in the same way. The text at both ends of the range joins. A list item, quote, callout, table cell, or column that the range enters keeps its unselected blocks, and the blocks after the range keep their container and level. A column goes only when the range removes its last block. Undo restores the earlier layout exactly, columns included.
- **History**: Each of the following actions records a single undo step:
  - toggling a format from the toolbar
  - running a block-menu action
  - inserting a block from the insert menu or slash menu
  - invoking a block shortcut (duplicate, move, or turn into)
  - dragging a block handle to reorder blocks
  - triggering a typing-shortcut conversion
  - applying a whole-page write

A *text block* is a block that holds text directly: a paragraph, a heading, or a code block. When the caret is at the start of a block, backward delete behaves as follows:

| Block at the caret | Backspace, Ctrl+H, delete by word | Command+Backspace |
| --- | --- | --- |
| A list item, or the first block of a list item | Converts the list item into a paragraph. At the top level, the list splits around the new paragraph. In a sublist, the first item becomes a paragraph inside the parent list item, while any other item becomes a paragraph in place; any nested sublist of the converted item follows the paragraph. | Outdents a sublist item (along with its children) by one level, or merges a top-level item into the nearest preceding text block, also across the edge of an enclosing quote or callout. |
| A block after the first paragraph of a list item | Moves this block and any following blocks in the same item out of the list immediately after the item, splitting the list there. | Same as Backspace |
| An indented paragraph or heading | Decreases `indent` by one level. | Same as Backspace |
| The first paragraph of a quote | Unwraps all paragraphs in the quote into plain paragraphs. | Merges this paragraph into the nearest text block before the quote, or does nothing if none exists. |
| The first paragraph of a callout | Merges this paragraph into the nearest text block before the callout (deleting the callout if it becomes empty), or does nothing if no text block precedes it. | Same as Backspace |
| The first paragraph of a table cell | Does nothing. | Same as Backspace |
| A code block or Mermaid block | Does nothing. | Same as Backspace |
| A block immediately after a divider, embed, formula block, diagram-only Mermaid block, or block-level read-only element | Merges into the nearest text block before those non-editable blocks while leaving them in place, or does nothing if none exists. | Same as Backspace |
| A block immediately after a quote, callout, or table | Merges into the last text block inside that container (for a table, inside its last cell). | Same as Backspace |
| The first block of the page | If the block is empty and followed by other blocks, deletes it and moves the caret to the next block; otherwise does nothing. | Same as Backspace |
| Any other block | Merges into the previous block while keeping the previous block's type. | Same as Backspace |

When the caret is at the end of a block, forward delete (Delete, Ctrl+D, Ctrl+K, delete by word, or Command+Delete) behaves as follows:

| Condition | Result |
| --- | --- |
| The next block is a divider, embed, formula block, diagram-only Mermaid block, or block-level read-only element. | Pulls the nearest text block after those non-editable blocks into the block at the caret while leaving them in place, or does nothing if none exists. |
| The block at the caret is the last paragraph of a quote or callout. | Pulls the nearest text block after the container into the block at the caret. |
| The next block is a quote or callout. | Pulls the first text block inside that container into the block at the caret, deleting the container if it becomes empty. |
| The next block is a table, or the block at the caret is the last paragraph of a table cell. | Does nothing. |
| Any other condition | Merges the text of the next block, next list item, or first child item into the block at the caret without changing the current block's type. If the caret sits in an empty list item, quote, callout, or cell, the merged text populates a new paragraph inside it. |

Enter key behavior:

- **In a heading**: pressing Enter in the middle splits trailing text into a new paragraph below; pressing Enter at the start inserts an empty paragraph above; pressing Enter at the end inserts an empty paragraph below.
- **In a paragraph inside a quote**: pressing Enter splits trailing text into a plain paragraph after the quote, and any remaining paragraphs of the quote form a second quote below it—except at the very start of the quote's first non-empty paragraph, where Enter inserts an empty paragraph above the quote without moving the caret.
- **In a callout**: pressing Enter inserts a new paragraph inside the callout, unless the callout has multiple blocks and the caret is in a trailing empty paragraph, in which case that empty paragraph moves below the callout.
- **In a list**: see **Lists** above.
- **Shift+Enter in a code or Mermaid block**: inserts an empty paragraph below the block and places the caret inside it without splitting the source.

`applyBlockType(editor, type, replace?)` converts block types in a single undo step; when `replace` is supplied (such as the `/query` range from the slash menu), that range is deleted first in the same step:

| `type` | Behavior |
| --- | --- |
| `paragraph`, `h1`…`h6` | Converts selected blocks to paragraphs or headings while preserving `align`, `indent`, `style`, and non-vocabulary attributes. |
| `bullet`, `number`, `check` | Converts selected paragraphs, headings, and code blocks into list items, keeping `align`, `style`, and non-vocabulary attributes on each item's paragraph (an empty, attribute-free block becomes an empty list item). Block `indent` maps to list nesting depth, clamped so the first item stays at depth 0 and each subsequent item nests at most one level deeper than its predecessor. If a matching list sits immediately above, the new items append to it. Within a list, conversion affects only the selected items and splits the surrounding list when its kind differs; a following numbered segment starts at 1. Nested items keep their types unless selected too. |
| `quote`, `callout` | Copies the text of the paragraph, heading, or code block at the caret into a new paragraph wrapped in a quote or callout (preserving `align`, `indent`, `style`, and non-vocabulary attributes) and places the caret at the end. In any other block type, splits the block at the caret, inserts an empty quote or callout between the halves, and moves the caret inside; lists split at the current item (leaving a trailing empty item if split at the end of the last item). |
| `code` | Converts selected blocks into code blocks, keeping text, line breaks, comment anchors, and non-vocabulary attributes (plus existing `lang` and `meta` if already a code block); `align`, `indent`, and `style` are dropped. |
| `divider`, `embed` | Inserts a divider or empty embed at the caret. If the current paragraph is empty and has no non-vocabulary attributes, it is replaced by the new block followed by an empty paragraph; otherwise the current block splits around the new block (lists split as for `quote`), and the caret moves after it. |
| `media`, `bookmark` | Inserts an atomic resource block using the same insertion rules, with a form for its URL and metadata and, for media, an upload button when the host supports it. |
| `file` | Inserts no block and opens the file upload panel at the caret, focusing the file chooser once the panel is visible; the slash menu removes its query, and the block menu keeps the empty paragraph it prepared. The menus offer `file` only when the host provides `acceptFiles`. |
| `table` | Inserts a three-by-three table with a header row and places the caret in its first cell. |
| `columns2`…`columns5` | Places the current block in the first column of a new row, creates an empty paragraph in each remaining column, and focuses the first column. List items retain their markers. |

Converting a code block to another type drops `meta`; converting a heading to another type discards its heading level; splitting a code block preserves both `lang` and `meta` on both halves.

Block-menu actions operate on the targeted block or list item, or on the whole block selection when its target belongs to that selection:

- **Duplicate**: creates deep copies preserving all attributes (including task-item check state). Duplicating from a text caret, a block menu, or a block selection selects the complete copies. Backspace deletes that selection, and Enter starts editing it.
- **Delete**: removes the block and moves the caret to the next block (or the previous block if none follows, inserting an empty paragraph if the page becomes empty).
- **Move up / Move down**: swaps the selected blocks with their adjacent sibling, preserving their order and selection.

In the block menu, `转换为` (Turn into) supports paragraphs, headings, code blocks, list items, lists, quotes, and callouts. Converting a list item changes its own label text and preserves its nested children. Paragraph, heading, code, quote, and callout targets move that item out of the list; list targets change only the selected items. When a text selection spans several blocks, the converted blocks keep that text selected, so the selection toolbar stays open.

### 7.6 React component

`BlockEditor` accepts these props:

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `initial` | `string \| DocumentElement` | `''` | Read once when mounting the editor instance. |
| `onReady` | `(editor) => void \| (() => void)` | — | Called after the editor mounts; if it returns a cleanup function, that function runs on unmount. |
| `onChange` | `() => void` | — | Called synchronously (with no arguments) whenever an accepted update changes the page. |
| `onError` | `(error: unknown) => void` | — | Called when an edit is rejected while keeping the current document intact; if omitted, the component renders an inline error banner. |
| `readOnly` | `boolean` | `false` | Disables editing; see details below. |
| `labels` | `Partial<EditorLabels>` | Chinese defaults | Host translations for visible and accessible UI strings; omitted keys keep their Chinese defaults. |
| `ariaLabel` | `string` | `文档编辑器` ("document editor") | Accessible name of the editing surface |
| `placeholder` | `string` | `输入 / 添加 Block，或直接开始写作…` ("Type / to add a Block, or start to write…") | Empty-page prompt; see details below. |
| `className` | `string` | `''` | Extra CSS class added to the outer wrapper |
| `header`, `footer` | `ReactNode` | — | Custom content rendered before and after the page body |
| `insertMenu` | `(prepareInsertion: () => void) => ReactNode` | — | Host actions in the left insert menu. Call `prepareInsertion` before inserting host content to restore the insertion caret. |
| `toolbar` | `ReactNode` | The default toolbar | Pass `null` to hide the toolbar; custom nodes render inside the editor context. |
| `children` | `ReactNode` | — | Additional nodes rendered inside the editor context with access to `useEditor` and `useEditorState`. |

Host re-renders, updated callbacks, and `labels` changes update the mounted view in place without recreating the editor instance, and changing `labels` never alters document text, selection, or undo history. Internally, `labels` uses `PhraseSet` while hosts own locale selection and translation catalogs; explicit `ariaLabel` and `placeholder` props take precedence over matching keys in `labels`. Slash-menu search matches translated block titles and descriptions alongside fixed English keyword aliases. The UI descriptions below cite the default Chinese labels.

When `readOnly` is `true`:

- Document editing is disabled.
- The toolbar is wrapped in a disabled `<fieldset>`, and the default toolbar renders only the hint text plus disabled Undo and Redo buttons.
- The empty-page placeholder, slash menu, formatting actions, block menu, block handles, and column resizers are hidden. When the host supplies `askAgent` or `requestComment`, the selection toolbar offers only those actions.
- Users and assistive technologies can still read and select body text.

When the page is editable, the empty page and an empty paragraph at the caret display the host's placeholder without inserting document text or shifting the caret. The editor exposes the same string through `aria-placeholder`.

Because `onChange` can fire before the DOM reflects the update, reading layout inside `onChange` measures the previous render. Inside the editor React context, `useEditor()` returns the editor instance, and `useEditorState(select?)` returns the rendered editor state (or `select(state)`), re-rendering after the editor flushes its DOM so components can safely measure layout. When the state has not changed, `select` must return a referentially or structurally equal value.

User interface controls:

- **Default toolbar**: contains `插入` (Insert), `当前 Block 菜单` (Current Block menu), the hint `选中文字设置格式 · / 添加内容` ("Select text to format it · Type / to add content"), `撤销` (Undo), and `重做` (Redo).
- **Selection toolbar**: appears whenever a non-whitespace selection lies outside code blocks. Its controls are 28px and fall into groups separated by dividers, in this order: `问 Agent` (Ask Agent, when the host supplies `askAgent`); the block type, a labelled menu that names the type every selected block shares (or `转换为` when they differ) and turns all of them into the chosen type in one undo step, shown only when every selected block can convert; bold, italic, underline, strikethrough, inline code, and highlight, with `aria-pressed` states reflecting the selection; and link followed by comment (when the host supplies `requestComment`). Code selections and read-only documents offer only Ask Agent and comment. The toolbar keeps its place while the block type menu is open, and on screens narrower than 480px Ask Agent shows only its icon. It hides during IME composition, when focus moves into an input field, when the selection scrolls out of view, or when the user presses Escape. After Ask Agent or comment hands off the selection, it stays hidden until the next editor update, so selecting the same text again reopens it.
- **Link form**: opens from the selection toolbar or via `⌘K`. URLs starting with `http://`, `https://`, `mailto:`, `tel:`, `ankole:page/`, `ankole:asset/`, `/`, or `#` are saved verbatim, and bare domain names with a TLD (such as `example.com`) receive an `https://` prefix; all other inputs display a validation error and leave the document unchanged. When editing an existing link, the form also offers `移除链接` (Remove link).
- **Slash menu**: opens when typing `/` at the start of a text run (for instance at block start or immediately after bold text or a link), after whitespace, or after `(`, except inside code blocks where `/` is literal text. Queries after `/` are capped at 75 characters, allow spaces (for example `/2 columns`), break on line breaks, tabs or any character in `.,+*?$@|#{}()^-[]\/!%'"~=<>_:;`, and filter options case-insensitively by title, description, and keyword aliases. Picking an option deletes `/query` and applies the block type in a single undo step.
- **Insert menu**: `插入` (Insert) in the toolbar runs the chosen block-type command at the caret. The left `+` appears on an empty paragraph and opens insertion choices for that paragraph. Existing blocks expose Add below in their block menu; it prepares a paragraph below the target (above with Alt/Option-click) and switches the popup to insertion choices while keeping its anchor. The menu filters translated titles, descriptions, and English aliases. Enter in the search field chooses its first result, arrows navigate the options, and Escape closes the menu and returns to the insertion caret. Closing without choosing keeps the paragraph.
- **Block menu**: provides `转换为` (Turn into, disabled when the block cannot convert), `创建副本` (Duplicate), `上移` (Move up), `下移` (Move down), `在下方添加 Block` (Add below, or above with Alt/Option-click), and `删除 Block` (Delete Block). Invoking `当前 Block 菜单` in the toolbar or pressing `⌘/` targets the current block or list item; clicking its type icon or grip targets the hovered block. When that block belongs to a whole-block selection, the menu acts on the selection. All entry points show the same actions.
- **Block handle**: the left gutter shows `+` for an empty paragraph and the current type icon for a typed or nonempty block, followed by the grip. The type icon and grip share one menu state and target. Only the grip starts dragging. The gutter remains a continuous pointer target, and controls stay on their block while its menu is open or a drag is active. A visible insertion line identifies a valid drop boundary. Preview and release use the same measured-target decision, which returns a valid block edit together with its insertion line. The React view measures block faces and ancestor bounds; `blockDrop` in `react/block-geometry.ts` selects the boundary and asks `relocation` or `columnDrop` for the edit. Dragging a selected block moves the selected group with its children, preserving order and block types in one undo step. A paragraph dropped between list items splits the list; a list item keeps its marker even when dropped into a list of another type. Moving right below an item nests the dragged blocks, and moving left lifts the boundary through list levels. Dragging near the scroll container's edge reveals further drop targets; Escape cancels. Read-only views hide the controls.
- **Code toolbar**: each code block renders a 32px toolbar with `代码块` (Code block), the current language label, `自动换行` (Wrap text), and `复制` (Copy). The language label opens a picker whose search field takes focus; results filter as the reader types, ArrowUp/ArrowDown move the active option, Enter chooses it, and Escape closes the picker. Choosing a language updates the block's highlight immediately and returns focus to the editor. Copy reports `已复制` (Copied) for a moment and never writes markup to the clipboard. The toolbar's buttons are focusable and respond to Enter and Space.
- **Mermaid block toolbar**: each Mermaid block shows `模板` (Templates), `视图` (View), `展开` (Expand), `主题` (Theme), and `帮助` (Help) on the right side of its header. The menus are ceramic surfaces anchored to their button; view and theme choices are single-step block changes, and a template replaces the source in one undo step. The full-window view is a native modal dialog: it takes focus on its close button, traps focus, and closes with Escape or the close button. Read-only views keep expand and help, and hide editing actions.
- **Formula editor**: clicking a formula block or activating it from the keyboard opens a ceramic panel below the block with the `LaTeX 公式` (LaTeX formula) title, an input, the hint `按 ESC 完成输入` ("Press ESC to finish"), and a `查看帮助文档` (View help) link. The header reads `无效公式` (Invalid formula) and the field uses the destructive colour while Temml cannot parse the draft. Each draft update replaces the block's source immediately, so the page preview follows the input. Enter or Escape closes the panel, selects the formula block, and returns focus to the editor; a click outside also closes it.
- **File upload panel**: choosing `文件` (File) opens a ceramic panel below the caret with a drop zone labelled `选择或拖入文件` (Choose or drop files) and the hint `可以一次选择多个文件` (You can choose several files at once); the host decides what each file becomes and may supply its own wording. The drop zone takes focus; activating it opens the system file picker with multiple selection, and dropping files on it hands them over directly. The panel passes every file to the host's `acceptFiles` at once and reads `正在上传…` (Uploading…) until the host settles. Success closes the panel and returns focus to the editor; a rejection keeps the panel open with the host's message so the reader can try again. Escape or a click outside closes the panel while no upload is in flight.
- **Whole-block selection**: Escape selects the current block, and pressing Escape while blocks are selected clears the block selection and places a collapsed caret at the end of the last selected editable block (or immediately after a non-editable block). Inside a table cell, the first Escape selects that cell and a second Escape selects the whole table; arrow keys move a cell selection across the table grid and Enter edits the selected cell at its end. Shift+Up/Down and Shift-click extend or shrink the selection across paragraphs and list items. Dragging from the surrounding page whitespace draws a marquee and selects intersecting block faces. A parent's face includes its descendants in the selection; intersecting only a child's face selects that child. Across columns, the selection contains only intersecting blocks, even when unselected blocks lie between them in document order. The marquee scrolls at viewport edges, and Escape restores the preceding selection. A drag starting in text keeps text-selection behavior. Partially selected lists retain their unselected items. Up/Down select the adjacent block, and pressing Down on the final block of the page appends an empty root paragraph in one undo step and selects it (reusing an existing trailing empty root paragraph). Command/Control+A selects the whole document. Enter edits the first selected editable block at its end, opens the formula editor for a single selected formula block (as Space also does), or inserts an empty paragraph below a single non-editable block (`divider`, `embed`, diagram-only `mermaid`, or block-level read-only element). Left/Right enter an editable block at its start or end, or place the caret before or after a non-editable block. Duplicate, move, delete, and menu actions use the selected blocks. Copy and cut preserve their structure and list wrappers. Typing, starting an IME composition, pasting, or inserting an image replaces the first selected range and removes the other selected ranges, preserving unselected blocks. The selected blocks use a background highlight without a duplicate native text highlight.
- **Columns**: dropping blocks beside the left or right edge of another block creates a row. Dropping beside an existing column adds a sibling column. A vertical insertion line previews the target; dropping above or below the row moves blocks back to the surrounding page. Moving the last block out of a column removes that column; a remaining single column becomes ordinary page content. Dragging a divider previews both adjacent widths and commits them in one undo step; Escape cancels. A focused divider also supports Left/Right and undo/redo shortcuts. Widths are saved in the document. Text navigation and Shift+Up/Down extension follow document order across columns, moving from the last line of a column to the first line of the next, and reversing that order when moving up. Within a paragraph, they move through its rendered lines. At viewport widths of 600 px or less, columns stack in document order and resizers are hidden.

The slash, insert, and type-conversion menus use 272 px translucent ceramic
surfaces and one shared catalogue view with 36 px single-line rows, 22 px icon
slots, grouping, and search matching. Slash keeps keyboard focus in the editor;
the insert and conversion menus use menu-item focus. The slash state adds 22 px
raised icon tiles. Each tile carries a small coloured light in its upper-right
corner: Heading 1 uses blue, Heading 2 grey-violet, and Heading 3 and bullet lists
purple. Insert and type-conversion menus use plain 16 px glyphs. Both themes
diffuse the background colours beneath a softly lit surface and fine edges;
the dark theme preserves legibility with a denser tint. Block descriptions remain
available to assistive technology and in title tooltips, and are included in search matching.
Slash and insert menus group the options into basic blocks, column layouts, and
additional content without changing keyboard navigation order.

Insert and slash menu options appear in this order:

1. `正文` (Text)
2. `一级标题`…`六级标题` (Heading 1 through Heading 6)
3. `表格` (Table)
4. `项目列表` (Bullet list)
5. `编号列表` (Numbered list)
6. `待办列表` (Task list)
7. `引用` (Quote)
8. `代码块` (Code block)
9. `分割线` (Divider)
10. `两栏`…`五栏` (Two to five columns)
11. `提及或引用` (Mention or reference)
12. `文件` (File)
13. `高亮块` (Callout)
14. `嵌入` (Embed)
15. `媒体` (Media)
16. `网页卡片` (Webpage card)
17. `公式` (Equation)
18. `Mermaid流程图` (Mermaid flowchart)

`公式` and `Mermaid流程图` are inserted only from the menus; neither converts an existing text block (`turnInto` is false).

| Action | Shortcut |
| --- | --- |
| Edit the link on the selection or at the caret | ⌘K |
| Open the block menu for the current block or whole-block selection | ⌘/ |
| Duplicate selected blocks below the selection | ⌘D |
| Move selected blocks above the previous block or below the next block, including across list boundaries | ⌘Shift+↑, ⌘Shift+↓ |
| Toggle selected tasks together, open a referenced page on a single page `embed`, open the formula editor on a single formula block, or toggle a foldable heading | ⌘Enter |
| Convert selected blocks to another block type, or back to a paragraph when every selected block already has that type | Apple platforms: Command+Option+digit; other platforms: Ctrl+Shift+digit (`0` paragraph; `1`–`3` heading 1–3; `4` task list; `5` bullet list; `6` numbered list; `8` code block) |
| Select the current block's text, then all cells of an enclosing table, and then the entire page | ⌘A |
| Move focus from an active selection to the selection toolbar | Alt+F10 |
| Navigate buttons inside the selection toolbar | Left Arrow, Right Arrow, Home, End |
| Close an open menu, cancel link editing, or toggle whole-block selection | Escape |
| Bold, italic, underline | ⌘B, ⌘I, ⌘U |
| Inline code | ⌘E |
| Strikethrough | ⌘Shift+S or ⌘Shift+X |
| Highlight | ⌘Shift+H |
| Undo, redo | ⌘Z, ⌘Shift+Z (plus Ctrl+Y for redo on non-Apple platforms) |
| Hard line break, or exit a code or Mermaid block into a new paragraph below | Shift+Enter |
| Indent or outdent (changes parent-child structure in lists and ordinary blocks; existing `indent` attributes remain editable; indents selected code lines; keeps focus in editable documents when a block is already at its limit) | Tab, Shift+Tab anywhere in the block |
| Move to the next or previous table cell (places caret at end of cell text, skips empty rows, and exits the table from the first/last cell) | Tab, Shift+Tab |

Inside a code block, Tab inserts one leading tab on every line touched by the selection, or the current line when the caret is collapsed. A selection ending at the next line's start includes that line. Shift+Tab removes one leading tab or up to two leading spaces on those lines. Both ends of the selection stay beside their text, including a backward selection, and each command is one undo step.

For selections spanning columns or separate sibling runs, Tab nests the selected blocks together below the first block's preceding sibling, after that sibling's existing children. Shift+Tab lifts each run within its own parent while root blocks stay put. Unselected blocks and the columns that contain them remain intact. Whole-block Up/Down and Shift+Up/Down cross column boundaries in reading order, and the selection follows a block when it acquires children.

Selecting across multiple table cells creates a cell selection. Deleting empties every selected cell. Typing, starting an IME composition, or pasting puts the input in the first selected cell and empties the other selected cells. The table keeps its rows, columns, and cell alignment. Pasted cells go into the first selected cell as paragraphs.

Block shortcuts (duplicate, move, and turn into) resolve their target blocks as follows:

- Selecting a list item includes its nested child items.
- Inside a quote, callout, or table cell, shortcuts target the inner blocks of that container.
- Multi-block selections act on every spanned sibling block; single-block or collapsed selections act on the block where the selection starts.

While an IME composition is active, Enter, Escape, and `keyCode=229` events never submit or dismiss menus or the link form.

### 7.7 PageSession

`PageSession` manages whole-page reads and revision-checked writes, shared by both the source panel and language-model edits:

| Member | Behavior |
| --- | --- |
| `new PageSession(editor)` | Initializes revision tracking on `editor`, replacing any earlier `PageSession` attached to the same editor. |
| `revision` | Current revision counter, incremented by 1 each time a dispatched update changes the document. |
| `read()` | Returns `{ revision, markdown, xml }`. |
| `readXml()` | Returns `{ revision, xml }`, reusing the validated XML cached for the accepted document. |
| `apply({ format, source, revision })` | Replaces the page after checking preconditions (see steps below). |
| `dispose()` | Detaches the session so subsequent `apply` calls throw, while `read()` and `readXml()` remain available. |

`apply({ format, source, revision })` executes these steps in order:

1. Throw if this `PageSession` has been replaced or disposed.
2. Throw if an IME composition is currently active.
3. Throw if `revision` does not match `this.revision`.
4. Parse `source` according to `format` (`'markdown'` or `'xml'`).
5. Run canonical printing on the new tree, throwing if printing fails.
6. Apply the page in a single undoable update. XML replaces the complete tree. Markdown computes changes between content with comment marks removed and applies those changes to the current marked document. An anchor survives only when its complete contiguous marked run is retained; rewritten or fragmented runs lose their anchor rather than attaching a discussion to coincident matching letters. Other intact runs of the same thread survive.
7. Return `{ revision, markdown, xml, warnings }`.

Whenever `apply` throws, the current document remains untouched. Revision numbers are meaningful only within the editor instance that produced them.

## 8. Package and host

### 8.1 Entry points

| Entry point | Exports |
| --- | --- |
| `@ankole/block-editor` | `BlockEditor`, `useEditor`, and type `EditorHandle` |
| `@ankole/block-editor/document` | `parseMarkdown`, `printMarkdown`, `parseXml`, `printXml`, `resourceContent`, `resourceText` |
| `@ankole/block-editor/editor` | `editorPhrases`, `PageSession`, `PageCollaboration`, `remoteSelections`, `insertEmbed`, `commitMention`, `insertMention`, `mentionField`, `insertImage`, `insertResource`, `toggleFormat`, `undo`, `commentSelection`, `trackCommentSelection`, `commentRanges`, `revealComment`, `EditorSelection`, and types `EditorLabels`, `Editor`, `EditorHost`, `EmbedAttributes`, `MentionTarget`, `MentionCategory`, `MentionSession`, `MentionItem`, `MentionQueryResult`, `MountMentionOptions`, `ResourceAttributes`, `ResourceKind`, `PageChanges`, `RemoteSelection`, `CommentSelection`, `CommentRange` |
| `@ankole/block-editor/styles.css` | Styles scoped to the editor and its overlays |

Host applications—including the Pod web app, Worker tools, and the embedding playground—import exclusively from these four entry points (for example, the embedding playground builds its custom toolbar with `useEditor`, `toggleFormat`, and `undo`), whereas internal package modules and tests use relative imports. Hosts read snapshots with `PageSession.read()` and perform revision-checked whole-page replacements with `PageSession.apply()`.

Passing the optional `host` prop to `BlockEditor` wires `EditorHost` integration hooks:

| Hook | Contract |
| --- | --- |
| `uploadAsset(file)` | Stores bytes in the host's real asset store and returns a durable `src` with optional title, MIME type, and size. Rejection leaves the resource form open with an error. |
| `acceptFiles(files)` | Receives the files chosen or dropped in the file upload panel and stores them as host resources; the document stays unchanged. Resolution closes the panel and returns focus to the editor, while a rejection keeps the panel open and shows its message. |
| `mountEmbed(attributes, container, update)` | Mounts the referenced resource into `container` and returns a teardown callback; calling `update` mutates only the embed's reference attributes via an editor transaction. |
| `mountMention(target, container, options)` | Mounts an inline `mention` leaf (`{ page }` or `{ principal }`) into `container` and returns an optional teardown callback. |
| `queryMentions(request)` | Returns ranked `MentionItem` candidates for the inline `@` / `＠` picker across `all`, `page`, and `principal` tabs without moving focus out of the document. |
| `mentionText(target)` | Supplies the plain-text label for clipboard `text/plain` serialization of an inline `mention`. |
| `matchPageUrl(url)` | Matches a bare pasted internal page URL and returns its canonical page UUID so the paste handler inserts an inline `<mention page="…" />`. |
| `resolveAsset(address)` | Resolves an uploaded asset URI to a display URL while the document keeps its durable address and metadata. |
| `openPage(id)` | Navigates to an internal page link in the host application. |
| `openComment(ids)` | Opens the persisted threads attached to a clicked anchor, including in read-only documents. |
| `requestComment(selection)` | Opens the host's comment composer for `{ from, to, quote }`; the selection toolbar offers this action independently of content-editing permission, including code selections. |
| `askAgent(selection)` | Hands `{ from, to, quote }` to the host, which owns the conversation that receives it; the selection toolbar offers this action independently of content-editing permission, including code selections, and leaves the document unchanged. |
| `deleteEmbeds(ids)` | Atomically handles the selected references in one block-menu deletion; ordinary selection deletes remove only the embed references. |

`insertEmbed` and `insertImage` insert at the current selection in a single undoable transaction.

Discussion threads belong to the host. `commentSelection(editor)` captures a single nonblank selection with structural-token and UTF-16 text positions; `commentRanges(editor, id?)` reads every live interval; `revealComment(editor, id)` selects and scrolls to the first interval. Hosts create or reanchor threads through their authorized server commit, then receive the native `Comment` mark through ordinary collaboration changes. The mark stores a sorted set of thread IDs, so overlapping threads compose independently. Code blocks use the same mark and preserve literal whitespace.

`trackCommentSelection(editor, selection)` returns a pure reader that accepts an editor state and returns the pending comment's current `{ from, to, quote }`. Hosts subscribe to the `EditorHandle` supplied by `BlockEditor.onReady`, then pass its drawn state to the reader. Submission reads the current editor state. The editor maps selected source tokens through local transactions and rebased remote changes. Pure insertions, unrelated edits, and formatting preserve the selection. Deleting or replacing any selected source makes the original quote uncertain, so the reader returns `null` and the host asks the author to select its source again. Replacing source with identical text does not revive it. Capturing another selection invalidates the previous reader. A reader returns `null` for a different editor session. Hosts wait for pending document changes to save before submitting the range with its confirmed revision. The editor never searches text to guess a draft's new anchor.

The `resolvedCommentIDs` prop controls presentation independently of document content. Resolved anchors keep their native marks and can still be revealed from the discussion, but have no passive highlight or ordinary click target. At an overlap, `openComment` receives every unresolved thread ID so the host can let the reader choose a discussion.

Moving blocks or dragging selected content within one editor preserves its marks. Duplicate and clipboard copies strip comment IDs. A cut within the same live editor retains its marked slice in memory and places only a one-use opaque nonce on the clipboard: the matching paste moves that slice once. Another copy or undo/redo invalidates it; a later paste or a paste in another editor carries unmarked content. Portable Markdown and plain text never expose thread IDs. A thread whose entire range disappears has no live document anchor; its persisted discussion and original quote remain the host's responsibility.

For real-time editing, `PageCollaboration` tracks pending local changes and keeps at most one batch in flight at a time: the host supplies `send`, `changed`, `reset`, and `sync` callbacks and manages transport reconnection, while the server assigns authoritative revisions. If preparing an outgoing batch fails, `PageCollaboration` leaves the local document intact and emits an error. Calling `dispose()` terminates that collaboration session.

Incoming transactions carry the editor's remote annotation and stay outside local undo history. Local input rules, including cleanup of a paragraph emptied inside a list item, skip these transactions so undo restores the same content on every client. When rebasing concurrent edits triggers a page correction, such as joining adjacent lists, `PageCollaboration` composes the correction into the local pending batch and applies the complete incoming change once to the visible document, selection, and undo mapping. Retries preserve their original request identity and payload until the server confirms or rejects that batch. Table row, column, header, and alignment commands retain the source tokens of surviving cell content so concurrent typing and comment anchors follow those changes. Uneven rows from imports or concurrent structure edits remain editable. An explicit row or column command fills missing trailing cells to the table's maximum width before applying the requested operation; merged-cell tables retain their imported structure.

When one concurrent change replaces a complete container with nonempty content and the other edits inside that container, `PageCollaboration` keeps the local draft and calls the host's `reset` callback before rebasing. Positional OT cannot track the original content through a wholesale replacement, including reordered table rows, whereas pure mark updates and identical whole-container deletions rebase directly. If an incoming change cannot be decoded or applied, `PageCollaboration` publishes the error and triggers the same `reset` recovery flow. The host opens the committed document and offers the local draft for manual reconciliation.

Hosts publish live selections in confirmed document coordinates using `selectionToConfirmed` and render them through `selectionFromConfirmed`, which maps through both in-flight and pending local changes. Peer selections from a different revision or outside the confirmed document are not rendered; the host republishes the selection when its confirmed revision changes. `remoteSelections(editor)` returns an updater for authorized peer selections in visible document coordinates; it renders colored carets, name labels, and selected ranges outside document content, undo history, and exports. Presence is ephemeral and belongs to the host transport rather than document persistence.

Before committing any document transaction to editor state, revision counters, or undo history, the editor checks the source, node-count, and nesting-depth bounds from section 1.5; if a transaction exceeds a bound, the editor rejects it and keeps the previous valid draft. Likewise, if combining an incoming remote change with pending local edits exceeds a bound, `PageCollaboration` preserves the current valid local draft and asks the host to recover via reset/reload.

### 8.2 Dependencies and build

- `@ankole/block-editor` is a private workspace package (`"private": true`), consumed by internal hosts via `"@ankole/block-editor": "workspace:*"`.
- Because hosts compile its TypeScript source directly, `bun run build` type-checks the library, playground, and tests rather than emitting a bundle; `bun run build:playground` builds the standalone example host.
- Dependencies are locked at the Ankole repository root (`package.json` and `bun.lock`, with `"@ankole/uikit": "workspace:*"`), so `libs/ankole-editor` maintains no lockfile of its own.
- The root workspace pins `mdast-util-gfm-strikethrough` to `2.0.1` so strikethrough parses reliably across punctuation and tag boundaries when followed by text; external consumers must use `2.0.1` or a newer release carrying that fix.
- `react` and `react-dom` `19.3.1` are peer dependencies that the host and editor must share as singletons, whereas `style-mod` and `@marijn/find-cluster-break` are direct dependencies used by the editing engine. Any host rendering `BlockEditor` with UI Kit styles must also depend directly on `"@ankole/uikit": "workspace:*"` and the React peer dependencies.
- Host stylesheets must import `@ankole/uikit/styles.css` before `@ankole/block-editor/styles.css`. Editor rules are scoped strictly under `.ankole-editor` and `.ankole-editor-overlay` and never style `html`, `body`, or `#root`.
- `mdast-util-to-markdown` `2.2.1` prevents a literal preceding backslash from escaping a character reference emitted at a formatting boundary; the property tests in `test/generated.test.ts` cover the boundary.

### 8.3 Block definitions

Custom block types with dedicated editor nodes implement `BlockDefinition`:

| Field | Meaning |
| --- | --- |
| `name` | Vocabulary element name |
| `type` | Editor node type representing the element |
| `schema` | Node types, marks, and schema overrides added to the page schema |
| `extension` | Editing behavior and DOM rendering for the block |
| `import(element, { blocks })` | Converts a page-tree element into an editor node (`blocks` imports child blocks) |
| `read(node, { children })` | Converts an editor node back into a page-tree element (`children` reads child blocks) |
| `insert` | Menu descriptor: `title`, `detail`, `glyph`, optional `turnInto` flag (when the block can convert the text block at the caret), and `insert(editor)` |

To register a block type, add its `BlockDefinition` to `blocks` in `src/blocks/index.ts` and declare its element kind, content model, and attributes in `src/document/vocabulary.ts`; the Markdown and XML codecs require no changes. `callout`, `embed`, `media`, `bookmark`, `math`, and `mermaid` use `BlockDefinition`.

## 9. Example host

Start the example playground from the Ankole root:

```sh
bun install --frozen-lockfile
bun run --filter @ankole/block-editor dev
```

- <http://127.0.0.1:3046>: full playground with side-by-side source inspector.
- <http://127.0.0.1:3046/playground/embedded.html>: two independent editor instances mounted on one page.

In the full playground:

- The source inspector toggles between Markdown and XML. While unapplied edits exist in the source pane, visual editing on the left is locked until you click `应用修改` (Apply changes) or `放弃修改` (Discard changes). Applying calls `PageSession.apply`: on failure, both the source draft and the visual page remain unchanged; on success, any unknown-element or unknown-attribute warnings appear in the status notice.
- `往返验证` (Round-trip check) exports the current page to Markdown, mounts a fresh editor from that Markdown, verifies that both editors produce identical XML, and clears undo history.
- `导出` (Export) downloads a `.md` or `.xml` file matching the active source tab, and `打开文件` (Open file) infers the format from the uploaded file extension.
- Changes autosave to `localStorage` under `ankole.block-lab.markdown.v2` 250 ms after each edit and immediately on `pagehide`. If stored data fails to parse on load, the raw text is preserved in the source draft for manual repair and autosave will not overwrite it until repaired. `恢复示例` (Restore example) resets the page to the built-in sample document.

## 10. Compatibility and verification

### 10.1 Browsers

JavaScript and CSS build targets are `chrome126`, `firefox153`, and `safari17`.

| Scope | Requirement | Automated check |
| --- | --- | --- |
| Chromium 126 and later | Required | Playwright Chromium, plus the same scenarios against built output on Chrome for Testing `126.0.6478.182`. |
| Latest Firefox ESR | Required | Playwright Firefox, plus WebDriver scenarios on native Firefox `153.4.0esr`. |
| Safari 17 and later | Required | Not covered in CI (Playwright WebKit is not Safari). |
| Mobile browsers | Best effort | Manual verification only |

Pinned compatibility browser versions live in `compat/browsers.json` and install into the Git-ignored `output/browsers` directory.

### 10.2 Test commands

- `bun run test` runs the fast unit and property suite covering:
  - page-tree validation and normalization
  - Markdown and XML parsing, printing, and canonical output
  - source error offsets, lines, and columns
  - real repository documents
  - the `src/core` editing engine (`test/core`)
  - editor import and read round trips
  - list and block-boundary key bindings
  - block menu actions and shortcuts
  - whole-page `PageSession` writes

  Using `fast-check` (default seed `20261005`, overridable via `FC_SEED`), the suite generates arbitrary pages across all vocabulary elements—including irregular tables and merged cells—and verifies that both import-then-read and `apply`-then-read yield `N(T)`. Headless tests run the full `editorExtension()` assembly against a fake view; DOM-dependent behavior is verified in `test:e2e`.
- `bun run test:upstream` runs all 652 CommonMark 0.31.2 examples (section 4.6) plus 52 Tiptap fixtures, requiring every Tiptap page tree to round-trip losslessly through the editor.
- `bun run test:e2e` runs Playwright across Chromium, Firefox, and WebKit on port `3146`, covering:
  - `src/core` browser tests (`test/core/browser` via `e2e/core.spec.ts`; one pixel-hit upstream case in WebKit is a known failure)
  - interactive typing and formatting edits
  - Backspace, Delete, Enter, and Tab at block boundaries
  - keyboard and typing shortcuts
  - platform delete bindings
  - `beforeinput` event handling
  - arrow-key navigation and caret placement in empty blocks
  - page-end clicks
  - toolbar, slash, insert, and block menus
  - text, node, and table-cell selections
  - clipboard copy/paste and Markdown plain-text paste
  - the playground source inspector
  - multi-editor embedding
  - upstream rendering cases

  Engine- or OS-specific cases are skipped where unsupported:
  - CDP-driven IME tests run only in Chromium.
  - Apple-specific shortcut tests run only on Apple platforms.
  - Character-transposition tests skip Firefox, which lacks native transpose input events.
  - Native drag-selection tests run only in Firefox.

  Any uncaught page exception or console error fails the test. Setting `E2E_PREVIEW=1` runs against the prebuilt `dist/` output.
- `E2E_PREVIEW=1 bun run test:chromium126` runs the Playwright suite against Chrome for Testing 126.
- `bun run test:native` runs WebDriver scenarios against native Firefox ESR on port `3147` (or Safari when `NATIVE_BROWSER=safari`).
- `bun run generate:corpus` regenerates the shared golden file in `corpus/rust`, and `bun run test:corpus` verifies the committed golden file without modifying it. The corpus stores valid pages, rejected inputs, exact limit-boundary cases, and multi-step local edit batches produced by the production transaction pipeline, checking that an in-memory client stays identical to an XML-persisting server after every batch (any divergence fails preflight). `FC_SEED` overrides the generation or property-test seed; see `corpus/rust/README.md` for format v2 details.
- `bun run test:package` packs `@ankole/block-editor` and `@ankole/uikit` into tarballs, installs them into a clean consumer project, verifies public TypeScript types and headless reads/writes, builds the consumer bundle, and runs the three-browser embedding suite covering `PageSession`, `PageCollaboration`, `EditorHost` hooks, caret-position image insertion, and undo.
- `bun run type-check`, `bun run fmt:check`, and `bun run build` verify TypeScript types, formatting, and workspace build checks.
- `bun run test:e2e:install` and `bun run test:compat:install chromium126 firefox-esr` download Playwright and pinned compatibility browsers.

When `E2E_PREVIEW=1` is set (and always for `test:native`), tests serve the existing `dist/` directory without rebuilding, so run `bun run build:playground` beforehand. No test suite retries failed cases automatically.

### 10.3 Manual checks

Because automated drivers cannot exercise native OS input methods or system clipboards end to end, record the following evidence whenever running manual acceptance checks:

- operating system and version
- full browser version string
- IME name and version
- exact reproduction steps
- DOM input event trace
- screenshots
- exported Markdown

| Scope | Environment | Pass condition |
| --- | --- | --- |
| Desktop | Windows with Chromium 126 or Firefox ESR; Microsoft Pinyin, Japanese, and Korean IMEs | Pick candidates, page through candidate lists, commit with Enter, and cancel with Escape inside an empty paragraph, at a bold boundary, and inside a list, callout, and table: no duplicated text, premature block splits, or lost formatting. |
| Desktop | macOS with Chromium 126, Firefox ESR, or Safari 17; macOS Pinyin, Japanese, and Korean IMEs | Trigger focus changes, mouse selections, Tab, undo, and redo mid-composition; reloading the page afterward shows identical persisted content. |
| Desktop | Browsers in section 10.1 with Latin dead keys, accents, emoji/ZWJ sequences, and bidirectional text | Backspace and Delete remove the exact units specified in section 7.5 (Delete), selection boundaries stay logically sound, and screenshots confirm caret placement in bidi text and at line wraps. |
| Desktop | System clipboard pastes from Word, web browsers, and Office apps | Inline formatting, nested lists, tables, links, and paragraph breaks survive both pasting from the external app and re-exporting to Markdown. |
| Mobile | Safari on iOS/iPadOS 17; Chromium 126 on Android with Gboard or the system IME | Candidate selection, autocorrect, dictation, continuous composition, touch selection handles, virtual keyboard viewport resizing, pinch-zoom, and scrolling all work without corrupting content or losing the caret. |

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

Child node order is significant; attribute order is not. Every attribute value is a string, and an attribute whose value is `""` is distinct from an omitted attribute except for the optional attributes listed in section 3.1. The tree contains no node IDs, comments, processing instructions, CDATA sections, or DTDs.

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
| `p`, `h1`…`h6` | Block | Inline | `align`: `left`, `center`, `right`, or `justify`. `indent`: an integer from 1 to 999. `style`: any value. | — |
| `blockquote` | Block | Block | — | — |
| `ul` | Block | Only `li` | — | — |
| `ol` | Block | Only `li` | `start`: 0, or a positive integer with a maximum of 9 digits | — |
| `li` | Block | Block | `task`: `todo` or `done` | Only in `ul` or `ol` |
| `pre` | Block | Text | `lang`, `meta`: any value | — |
| `hr` | Block | Empty | — | — |
| `table` | Block | Only `tr` | — | — |
| `tr` | Block | Only `th` and `td` | — | Only in `table` |
| `th`, `td` | Block | Block | `align`: the same values as for `p`. `colspan`, `rowspan`: an integer from 1 to 9999. | Only in `tr` |
| `callout` | Block | Block | `tone`: `info` or `warning` | — |
| `embed` | Block | Empty | `ref`, `table`, `view`: any value | — |
| `a` | Inline | Inline | `href`: any value, required. `title`: any value. | — |
| `img` | Inline | Empty | `src`: any value, required. `alt`, `title`: any value. | — |
| `br` | Inline | Empty | — | — |
| `span` | Inline | Inline | `style`: any value | — |
| `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`, `code` | Inline | Inline | — | — |

If a known element carries attributes outside the vocabulary, the package preserves them unchanged and reports each one as a warning (section 6.4). Likewise, the package preserves unknown elements and all of their attributes unchanged and reports each unknown element as a warning.

`embed` stores only a reference: `ref` identifies the target page, and a Base embed may also specify `table` and `view`. Because the target page owns the format, existence, and lifecycle of those values, the host page never embeds the target's fields, records, views, or settings. The editor itself never loads an embedded page, fetches its assets, or deletes it; those operations belong to the host product.

Ankole uses two internal URI forms in attributes: `ankole:page/<page ID>` in `href` for page links, and `ankole:asset/<digest>/<file name>` in `src` for page-owned images. The package treats both like any other attribute string—reading, printing, and copying them verbatim without resolving them.

## 3. Normalization

Normalization (`N`) strips only differences that are invisible to a reader: if two trees are equal after `N`, they represent the same page. The package applies `N` whenever it parses Markdown or XML, prints output, imports a tree into the editor, or reads a tree from the editor.

### 3.1 Attributes

- `N` sorts attributes by name in Unicode code-point order.
- If a known attribute has a value outside those permitted in section 2, `N` reports an error.
- When the vocabulary declares `alt`, `title`, `lang`, `meta`, or `style` on an element and its value is `""`, `N` drops the attribute. `N` also drops `start="1"` on `ol` and `colspan="1"` and `rowspan="1"` on `th` and `td`.
- Missing a required attribute on an element is an error.

### 3.2 Block content

The content categories below correspond to the **Content** column in section 2. An "Only …" rule (such as "Only `li`") restricts children to that exact set of elements.

- Inside an element with "Block" or "Only …" content, text consisting solely of spaces, tabs, CR, and LF is layout whitespace and `N` removes it; any other direct text is an error.
- Inside an element with "Only …" content, any child element outside that allowed set is an error.
- Inside an element with "Block" content, a direct child that is a known inline element is an error.
- An element with "Text" content (`pre`) may contain only text, and an element with "Empty" content may have no child nodes.
- `N` removes any `ul` or `ol` that has zero list items.
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

1. A line containing only tags and whitespace forms block tags. Content between block tags may be indented and—except under rules 5–7—is parsed as Markdown blocks separated by blank lines.
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
| `pre` | Carries only `lang` and `meta`; `lang` contains no whitespace, `` ` ``, `&`, or `\`; `meta` is present only when `lang` is also present; and `meta` has no line breaks, `` ` ``, `&`, `\`, or leading/trailing whitespace. | Block `<pre …>` tags carrying all attributes, wrapping an info-free code fence. |
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

Before returning, the printer reparses its own output and compares the resulting tree against `N(tree)`. If reparsing fails, the printer throws `Error` prefixed with `规范 Markdown 无法读回：` ("Canonical Markdown cannot be read back: ") followed by the underlying cause; if the reparsed tree differs from `N(tree)`, it throws `Error` with `规范 Markdown 读回后得到不同的页面` ("Canonical Markdown gives a different page when it is read back"). In either case, no output is returned.

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
- the extension contributed by each registered block definition

`initialState(initial, config)` creates an editor state from `initial` (either a Markdown string or a page tree) and assembly `config`, throwing `DocumentError` if the Markdown is invalid. The caret starts at the end of the page, so focusing the editor or inserting a block before clicking acts at the end of the page. `headlessState(initial)` creates a headless state configured with `editorExtension()`.

### 7.2 Import: page tree to editor document

`pageDocument(tree)` normalizes `tree` with `N` and converts it into an editor document according to the table below. `replaceTree(state, tree)` builds an editor update that replaces the entire page.

| Element | Editor node |
| --- | --- |
| `p`, `h1`…`h6` | Paragraph or heading, with `align`, `indent`, and `style` stored as node marks. |
| `blockquote` | Quote container; each child block is imported recursively. |
| `ul`, `ol` | Bullet list or numbered list (`start` becomes a parameter on the numbered list). |
| `li` | List-item container; each child block is imported recursively, and `task` becomes a mark on the list item. |
| `pre` | Code block, with `lang` and `meta` as marks and line breaks represented as line-break nodes. |
| `hr` | Divider |
| `table`, `tr`, `th`, `td` | Table, row, header cell, and cell. Cells are containers, with `colspan`, `rowspan`, and `align` stored as marks on the cell. |
| `callout` | Callout container; each child block is imported recursively. |
| `embed` | Embed |
| Format elements, `span` with `style` | Text marks: bold, italic, strikethrough, underline, highlight, subscript, superscript, code, and style |
| `a` with content | Link mark on text, preserving all attributes of `a` |
| `br` | Line-break node |
| `img` | Image node, with `alt` and `title` stored as marks |
| Unknown elements, empty `a`, format elements with attributes, `span` with attributes other than `style` | Read-only element (section 7.4). Inline read-only elements inherit the formats, `style`, and link of their ancestors. |

Any attribute not listed above—including unknown attributes—is preserved in an extra-attributes mark on the node across copy, undo, and block-type conversions.

Bullet lists may mix task items and plain items. Table rows may vary in length or be empty, and cells may be empty. Merged cells (`colspan` / `rowspan`) are preserved as document data, although the editor provides no interactive commands to merge or split cells.

An empty page imports as a single empty paragraph carrying a placeholder mark so that it can hold the caret.

### 7.3 Read: editor document to page tree

`readTree(doc)` converts an editor document back into a page tree by reversing the mapping in section 7.2 and applying `N`:

- An empty paragraph carrying the placeholder mark is omitted.
- Characters in text or attribute values that are invalid in XML 1.0 (such as pasted control characters or an unpaired surrogate during input) are stripped from the output without mutating the editor state.

For every valid page tree `T`, importing `T` and reading it back yields `N(T)`.

#### Prepare a submission

`preparePageUpdate(transaction)` prepares the final local transaction of an edit batch for XML storage; run input appenders first and call it only after IME composition has ended. It round-trips the resulting document through the XML codec, computes a diff for any normalization adjustments, and folds that correction into the transaction without shifting text positions on mark-only changes. The returned transaction preserves the mapped selection, effects, annotations, and history boundary.

The client must apply the returned transaction instead of the original one, compose its changes onto earlier changes in the batch, and transmit the combined change set. Normalizing only the outgoing payload while leaving the unnormalized document in memory would desynchronize the next batch. When replaying remote changes, the client applies the already-prepared change set directly without running `preparePageUpdate` again.

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

### 7.5 Edit behavior

- **Normal form**: Before applying any document-changing update, the editor normalizes it under the rules of sections 2 and 3:
  - Adjacent lists of the same kind merge, keeping the first list's attributes plus any attributes present only on the second list.
  - Formats, styles, and links inside code blocks are stripped.
  - `colspan="1"` and `rowspan="1"` are removed.
  - Invalid attribute values, cell spans above 9999, and empty optional attributes are removed.
- **Typing shortcuts**: Markdown shorthand from section 4.1 (excluding `<…>` tags) acts as live typing shortcuts:
  - Typing a space after a block marker converts the current paragraph when it sits directly inside the page root, a quote, a callout, or a table cell.
  - Pressing Enter after a code-fence marker converts the paragraph into a code block, and typing the closing delimiter of an inline marker applies that inline format.
  - Three additional shortcuts trigger when their final character leaves the paragraph containing nothing else: `[] ` converts to a task item, `" ` or `| ` converts to a quote, and `---` converts to a divider followed by a new empty paragraph.
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
  - Newly created or outdented empty list items contain no child blocks and print as `-`. If editing leaves a list item with a single empty, attribute-free paragraph, the item collapses to an empty list item.
  - Attaching a sublist to an empty list item inserts an empty paragraph above the sublist.
  - Converting a list item to a paragraph promotes its child blocks directly to the surrounding container.
  - Outdenting a sublist item with Shift+Tab adopts both its existing children and any following sibling items as its children, while any blocks that followed the sublist in the former parent item move into a new list item after the outdented item.
  - The first item of a list cannot indent deeper: pressing Tab on it is a no-op, and indenting a multi-item selection that starts on the first item leaves the first item in place while nesting the remaining selected items beneath it.
  - When a list item's text merges into a preceding block, its remaining child blocks append to the previous list item—or move before the list if it was the first item.
  - Pressing Enter in an empty list item outdents it by one level when nested, or converts it into a paragraph (splitting the list) at the top level.
  - Pressing Enter at the very start of a non-empty list item inserts an empty list item above it.
- **Callouts**: Deleting or cutting a selection whose endpoints lie inside the same callout removes only the selected content and keeps the callout wrapper; if all blocks inside a callout are deleted, one empty paragraph remains.
- **Embeds**: Backspace and Delete at an adjacent block boundary skip over an embed rather than deleting it (see Delete below), and Up/Down Arrow move the caret past it. Users can delete an embed from the block menu or by deleting a selection that spans or selects the embed node (such as clicking the embed to create a node selection). Deleting an embed block removes only the reference; the target page itself is untouched.
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
  - Inline formatting recognizes vocabulary format tags plus `<b>`, `<i>`, `<del>`, and `<strike>`; CSS `font-weight` maps to bold only for `bold` and `700`.
  - Inline styles retain only `text-transform` and alignment (`data-align` or `text-align`, ignoring `start` and mapping `end` to `right`); all other inline styles and all block styles are stripped.
  - Callouts and embeds are recognized from HTML only in the exact markup written by the editor.
  - Copying from an editor embeds the exact serialized slice in the clipboard HTML; on paste, the editor prefers that slice whenever it is present and valid for the schema, falling back to HTML parsing otherwise.
  - When the clipboard contains only plain text, the editor parses it as Markdown and inserts structured page content if parsing succeeds without unknown elements and yields non-paragraph blocks, inline formats, links, or hard breaks; otherwise, it inserts the literal plain text.
  - Inside a code block, paste always inserts literal text with line breaks converted to line-break nodes (extracting one text line per block if the clipboard carries only HTML).
  - When inserting multi-block content, only leading and trailing text blocks stay open: a leading text block merges into the block at the caret, a trailing text block absorbs the text after the caret, and lists, tables, quotes, and callouts insert as closed blocks.
  - Copying a fully selected quote, callout, list item, cell, list, or table copies the whole block structure: a single cell includes its row and table, a list item includes its enclosing list, and a multi-cell selection produces a table of the selected cells, whereas a partial selection inside one list item copies inline content without the list wrapper.
  - Plain-text copy writes one line per text block and formats tables as one line per row with tab-separated cells.
- **Page-end click**: When the final block on the page is a leaf block (embed, divider, or block-level read-only element) or a container (table, quote, or callout), clicking in the blank area below it appends a new empty paragraph and places the caret inside it.
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
| A list item, or the first block of a list item | Converts the list item into a paragraph. At the top level, the list splits around the new paragraph. In a sublist, the first item becomes a paragraph inside the parent list item, while any other item becomes a paragraph in place; any nested sublist of the converted item follows the paragraph. | Outdents a sublist item (along with its children) by one level, or merges a top-level item into the nearest preceding text block. |
| A block after the first paragraph of a list item | Moves this block and any following blocks in the same item out of the list immediately after the item, splitting the list there. | Same as Backspace |
| An indented paragraph or heading | Decreases `indent` by one level. | Same as Backspace |
| The first paragraph of a quote | Unwraps all paragraphs in the quote into plain paragraphs. | Merges this paragraph into the nearest text block before the quote, or does nothing if none exists. |
| The first paragraph of a callout | Merges this paragraph into the nearest text block before the callout (deleting the callout if it becomes empty), or does nothing if no text block precedes it. | Same as Backspace |
| The first paragraph of a table cell | Does nothing. | Same as Backspace |
| A block immediately after a divider, embed, or block-level read-only element | Merges into the nearest text block before those leaf blocks while leaving them in place, or does nothing if none exists. | Same as Backspace |
| A block immediately after a quote, callout, or table | Merges into the last text block inside that container (for a table, inside its last cell). | Same as Backspace |
| The first block of the page | If the block is empty and followed by other blocks, deletes it and moves the caret to the next block; otherwise does nothing. | Same as Backspace |
| Any other block | Merges into the previous block while keeping the previous block's type. | Same as Backspace |

When the caret is at the end of a block, forward delete (Delete, Ctrl+D, Ctrl+K, delete by word, or Command+Delete) behaves as follows:

| Condition | Result |
| --- | --- |
| The next block is a divider, embed, or block-level read-only element. | Pulls the nearest text block after those leaf blocks into the block at the caret while leaving the leaf blocks in place, or does nothing if none exists. |
| The block at the caret is the last paragraph of a quote or callout. | Pulls the nearest text block after the container into the block at the caret. |
| The next block is a quote or callout. | Pulls the first text block inside that container into the block at the caret, deleting the container if it becomes empty. |
| The next block is a table, or the block at the caret is the last paragraph of a table cell. | Does nothing. |
| Any other condition | Merges the text of the next block, next list item, or first child item into the block at the caret without changing the current block's type. If the caret sits in an empty list item, quote, callout, or cell, the merged text populates a new paragraph inside it. |

Enter key behavior:

- **In a heading**: pressing Enter in the middle splits trailing text into a new paragraph below; pressing Enter at the start inserts an empty paragraph above; pressing Enter at the end inserts an empty paragraph below.
- **In a paragraph inside a quote**: pressing Enter splits trailing text into a plain paragraph after the quote, and any remaining paragraphs of the quote form a second quote below it—except at the very start of the quote's first non-empty paragraph, where Enter inserts an empty paragraph above the quote without moving the caret.
- **In a callout**: pressing Enter inserts a new paragraph inside the callout, unless the callout has multiple blocks and the caret is in a trailing empty paragraph, in which case that empty paragraph moves below the callout.
- **In a list**: see **Lists** above.

`applyBlockType(editor, type, replace?)` converts block types in a single undo step; when `replace` is supplied (such as the `/query` range from the slash menu), that range is deleted first in the same step:

| `type` | Behavior |
| --- | --- |
| `paragraph`, `h1`, `h2`, `h3` | Converts selected blocks to paragraphs or headings while preserving `align`, `indent`, `style`, and non-vocabulary attributes. |
| `bullet`, `number`, `check` | Converts selected paragraphs, headings, and code blocks into list items, keeping `align`, `style`, and non-vocabulary attributes on each item's paragraph (an empty, attribute-free block becomes an empty list item). Block `indent` maps to list nesting depth, clamped so the first item stays at depth 0 and each subsequent item nests at most one level deeper than its predecessor. If a matching list sits immediately above, the new items append to it. Within a bullet list, contiguous runs of task items and plain items count as distinct logical lists, and conversion retargets the run containing the selection. |
| `quote`, `callout` | Copies the text of the paragraph, heading, or code block at the caret into a new paragraph wrapped in a quote or callout (preserving `align`, `indent`, `style`, and non-vocabulary attributes) and places the caret at the end. In any other block type, splits the block at the caret, inserts an empty quote or callout between the halves, and moves the caret inside; lists split at the current item (leaving a trailing empty item if split at the end of the last item). |
| `code` | Converts selected blocks into code blocks, keeping only text, line breaks, and non-vocabulary attributes (plus existing `lang` and `meta` if already a code block); `align`, `indent`, and `style` are dropped. |
| `divider`, `embed` | Inserts a divider or empty embed at the caret. If the current paragraph is empty and has no non-vocabulary attributes, it is replaced by the new block followed by an empty paragraph; otherwise the current block splits around the new block (lists split as for `quote`), and the caret moves after it. |

Converting a code block to another type drops `meta`; converting a heading to another type discards its heading level; splitting a code block preserves both `lang` and `meta` on both halves.

Block-menu actions operate on top-level blocks:

- **Duplicate**: creates a deep copy preserving all attributes (including task-item check state) and moves the caret into the copy.
- **Delete**: removes the block and moves the caret to the next block (or the previous block if none follows, inserting an empty paragraph if the page becomes empty).
- **Move up / Move down**: swaps the block with its adjacent top-level sibling.

In the block menu, `转换为` (Turn into) is enabled only on paragraphs, headings, and code blocks. Inside a list item, invoking a block-type command from the slash menu or insert menu moves the item out of the list for `paragraph`, `h1`–`h3`, and `code`, or switches the list kind for `bullet`, `number`, and `check`.

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
| `toolbar` | `ReactNode` | The default toolbar | Pass `null` to hide the toolbar; custom nodes render inside the editor context. |
| `children` | `ReactNode` | — | Additional nodes rendered inside the editor context with access to `useEditor` and `useEditorState`. |

Host re-renders, updated callbacks, and `labels` changes update the mounted view in place without recreating the editor instance, and changing `labels` never alters document text, selection, or undo history. Internally, `labels` uses `PhraseSet` while hosts own locale selection and translation catalogs; explicit `ariaLabel` and `placeholder` props take precedence over matching keys in `labels`. Slash-menu search matches translated block titles and descriptions alongside fixed English keyword aliases. The UI descriptions below cite the default Chinese labels.

When `readOnly` is `true`:

- Document editing is disabled.
- The toolbar is wrapped in a disabled `<fieldset>`, and the default toolbar renders only the hint text plus disabled Undo and Redo buttons.
- The empty-page placeholder, slash menu, selection toolbar, block menu, and block handles are hidden.
- Users and assistive technologies can still read and select body text.

When the page is editable and consists of a single empty paragraph, that paragraph displays the empty-page placeholder visually and sets the same string on `aria-placeholder` without inserting document text or shifting the caret.

Because `onChange` can fire before the DOM reflects the update, reading layout inside `onChange` measures the previous render. Inside the editor React context, `useEditor()` returns the editor instance, and `useEditorState(select?)` returns the rendered editor state (or `select(state)`), re-rendering after the editor flushes its DOM so components can safely measure layout. When the state has not changed, `select` must return a referentially or structurally equal value.

User interface controls:

- **Default toolbar**: contains `插入` (Insert), `当前 Block 菜单` (Current Block menu), the hint `选中文字设置格式 · / 添加内容` ("Select text to format it · Type / to add content"), `撤销` (Undo), and `重做` (Redo).
- **Selection toolbar**: appears whenever a non-whitespace selection lies outside code blocks, offering bold, italic, underline, strikethrough, inline code, link, and highlight buttons in that order with `aria-pressed` states reflecting the selection. It hides during IME composition, when focus moves into an input field, when the selection scrolls out of view, or when the user presses Escape.
- **Link form**: opens from the selection toolbar or via `⌘K`. URLs starting with `http://`, `https://`, `mailto:`, `tel:`, `/`, or `#` are saved verbatim, and bare domain names with a TLD (such as `example.com`) receive an `https://` prefix; all other inputs display a validation error and leave the document unchanged. When editing an existing link, the form also offers `移除链接` (Remove link).
- **Slash menu**: opens when typing `/` at the start of a text run (for instance at block start or immediately after bold text or a link), after whitespace, or after `(`, except inside code blocks where `/` is literal text. Queries after `/` are capped at 75 characters, break on whitespace or any character in `.,+*?$@|#{}()^-[]\/!%'"~=<>_:;`, and filter options case-insensitively by title, description, and keyword aliases. Picking an option deletes `/query` and applies the block type in a single undo step.
- **Insert menu**: `插入` (Insert) in the top toolbar runs the chosen block-type command at the caret, whereas clicking `+` on a block handle inserts a new paragraph below the hovered top-level block and runs the command there.
- **Block menu**: provides `转换为` (Turn into, disabled when the block cannot convert), `创建副本` (Duplicate), `上移` (Move up), `下移` (Move down), and `删除 Block` (Delete Block). Invoking `当前 Block 菜单` in the toolbar or pressing `⌘/` targets the top-level block at the caret, whereas clicking a block handle targets the hovered top-level block; all three entry points show the same items.
- **Block handle**: appears when hovering over a top-level block and can be dragged to reorder blocks in a single undo step.

Insert and slash menu options appear in this order:

1. `正文` (Text)
2. `一级标题` (Heading 1)
3. `二级标题` (Heading 2)
4. `三级标题` (Heading 3)
5. `项目列表` (Bullet list)
6. `编号列表` (Numbered list)
7. `待办列表` (Task list)
8. `引用` (Quote)
9. `代码块` (Code block)
10. `分割线` (Divider)
11. `提示块` (Callout)
12. `嵌入` (Embed)

| Action | Shortcut |
| --- | --- |
| Edit the link on the selection or at the caret | ⌘K |
| Open the block menu for the block at the caret (no-op if the selection spans multiple top-level blocks) | ⌘/ |
| Duplicate selected blocks below the selection | ⌘D |
| Move selected blocks above the previous sibling or below the next sibling | ⌘Shift+↑, ⌘Shift+↓ |
| Convert selected blocks to another block type | Apple platforms: Command+Option+digit; other platforms: Ctrl+Shift+digit (`0` paragraph; `1`–`3` heading 1–3; `4` task list; `5` bullet list; `6` numbered list; `8` code block) |
| Select the current block's text, then the entire page on a second press | ⌘A (twice) |
| Move focus from an active selection to the selection toolbar | Alt+F10 |
| Navigate buttons inside the selection toolbar | Left Arrow, Right Arrow, Home, End |
| Close an open menu or cancel link editing | Escape |
| Bold, italic, underline | ⌘B, ⌘I, ⌘U |
| Inline code | ⌘E |
| Strikethrough | ⌘Shift+S or ⌘Shift+X |
| Highlight | ⌘Shift+H |
| Undo, redo | ⌘Z, ⌘Shift+Z (plus Ctrl+Y for redo on non-Apple platforms) |
| Hard line break | Shift+Enter |
| Indent or outdent (adjusts nesting depth in lists, or `indent` up to 49 on paragraphs and headings; inserts a literal tab inside code blocks) | Tab, Shift+Tab anywhere in the block |
| Move to the next or previous table cell (places caret at end of cell text, skips empty rows, and exits the table from the first/last cell) | Tab, Shift+Tab |

Selecting across multiple table cells creates a cell selection, in which typing or deleting modifies cell contents while preserving table structure and cell alignment.

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
6. Replace the entire page in a single undoable update.
7. Return `{ revision, markdown, xml, warnings }`.

Whenever `apply` throws, the current document remains untouched. Revision numbers are meaningful only within the editor instance that produced them.

## 8. Package and host

### 8.1 Entry points

| Entry point | Exports |
| --- | --- |
| `@ankole/block-editor` | `BlockEditor`, `useEditor` |
| `@ankole/block-editor/document` | `parseMarkdown`, `printMarkdown`, `parseXml`, `printXml` |
| `@ankole/block-editor/editor` | `editorPhrases`, `PageSession`, `PageCollaboration`, `insertEmbed`, `insertImage`, `toggleFormat`, `undo`, and types `EditorLabels`, `Editor`, `EditorHost`, `EmbedAttributes`, `PageChanges` |
| `@ankole/block-editor/styles.css` | Styles scoped to the editor and its overlays |

Host applications—including the Pod web app, Worker tools, and the embedding playground—import exclusively from these four entry points (for example, the embedding playground builds its custom toolbar with `useEditor`, `toggleFormat`, and `undo`), whereas internal package modules and tests use relative imports. Hosts read snapshots with `PageSession.read()` and perform revision-checked whole-page replacements with `PageSession.apply()`.

Passing the optional `host` prop to `BlockEditor` wires `EditorHost` integration hooks:

| Hook | Contract |
| --- | --- |
| `mountEmbed(attributes, container, update)` | Mounts the referenced resource into `container` and returns a teardown callback; calling `update` mutates only the embed's reference attributes via an editor transaction. |
| `resolveAsset(address)` | Resolves an image asset URI to a display URL while the editor preserves `alt` and `title`. |
| `openPage(id)` | Navigates to an internal page link in the host application. |
| `deleteEmbed(id)` | Handles explicit deletion from the block menu; ordinary selection deletes remove only the embed reference. |

`insertEmbed` and `insertImage` insert at the current selection in a single undoable transaction.

For real-time editing, `PageCollaboration` tracks pending local changes and keeps at most one batch in flight at a time: the host supplies `send`, `change`, `reset`, and `sync` callbacks and manages transport reconnection, while the server assigns authoritative revisions. If preparing an outgoing batch fails, `PageCollaboration` leaves the local document intact and emits an error. Calling `dispose()` terminates that collaboration session.

Before committing any document transaction to editor state, revision counters, or undo history, the editor checks the source, node-count, and nesting-depth bounds from section 1.5; if a transaction exceeds a bound, the editor rejects it and keeps the previous valid draft. Likewise, if combining an incoming remote change with pending local edits exceeds a bound, `PageCollaboration` preserves the current valid local draft and asks the host to recover via reset/reload.

### 8.2 Dependencies and build

- `@ankole/block-editor` is a private workspace package (`"private": true`), consumed by internal hosts via `"@ankole/block-editor": "workspace:*"`.
- Because hosts compile its TypeScript source directly, `bun run build` type-checks the library, playground, and tests rather than emitting a bundle; `bun run build:playground` builds the standalone example host.
- Dependencies are locked at the Ankole repository root (`package.json` and `bun.lock`, with `"@ankole/uikit": "workspace:*"`), so `libs/ankole-editor` maintains no lockfile of its own.
- The root workspace pins `mdast-util-gfm-strikethrough` to `2.0.1` so strikethrough parses reliably across punctuation and tag boundaries when followed by text; external consumers must use `2.0.1` or a newer release carrying that fix.
- `react` and `react-dom` `19.3.0` are peer dependencies that the host and editor must share as singletons, whereas `style-mod` and `@marijn/find-cluster-break` are direct dependencies used by the editing engine. Any host rendering `BlockEditor` with UI Kit styles must also depend directly on `"@ankole/uikit": "workspace:*"` and the React peer dependencies.
- Host stylesheets must import `@ankole/uikit/styles.css` before `@ankole/block-editor/styles.css`. Editor rules are scoped strictly under `.ankole-editor` and `.ankole-editor-overlay` and never style `html`, `body`, or `#root`.
- Every installation must apply the patches under `patches/`. In the Ankole monorepo, the root `patchedDependencies` field applies them automatically during `bun install`; external tarball consumers must declare the same `patchedDependencies` entry in their own root manifest:
  - `mdast-util-to-markdown@2.2.0`: prevents a literal preceding backslash from escaping a character reference emitted at a formatting boundary (covered by `test/generated.test.ts`).
- Remove a patch and its `patchedDependencies` entry only when upstream ships the fix and both the regression test and the three-browser end-to-end suite pass without it.

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

To register a block type, add its `BlockDefinition` to `blocks` in `src/blocks/index.ts` and declare its element kind, content model, and attributes in `src/document/vocabulary.ts`; the Markdown and XML codecs require no changes. Currently, `callout` and `embed` are implemented via `BlockDefinition`.

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

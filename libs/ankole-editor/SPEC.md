# Ankole Block Editor Specification

This specification gives the behavior of the `@ankole/block-editor` package in `libs/ankole-editor`, version 0.1.0 in `package.json`. It covers the page tree, the Markdown and XML source formats, the editor, the React component, the host interface, the example host, and compatibility checks.

## 0. Authority and conventions

- This specification is the only authority for the behavior of the package. If the code and this specification do not agree, that is a defect. When you change a behavior, change this specification in the same change.
- Each statement in this specification is a requirement, except a paragraph with the label "Note".
- `upstream/fixtures/commonmark-dialect.json` records each example where this format is different from the CommonMark reference implementation. This file is part of this specification.
- `upstream/NOTICE.md` gives the sources and licenses of the third-party test data.
- In shortcuts, ⌘ is the Command key on Apple platforms (macOS, iOS, and iPadOS) and the Ctrl key on other platforms. In this specification, Ctrl is the Control key on all platforms. On Apple platforms, editor shortcuts do not use Ctrl with a letter, because the system uses these keys to edit text.
- Document errors and warnings are in Chinese. Interface labels default to Chinese and can be translated through `BlockEditor.labels` (section 7.6). Parsing and serialization do not depend on interface labels.

| Term | Meaning |
| --- | --- |
| Page | One complete document body. Each read, write, and revision check applies to one full page. |
| Page tree | The content of a page: elements, attributes, text, and ordered child nodes |
| Element | A node with a name, attributes, and ordered child nodes |
| Block element, inline element | The two kinds of element that the vocabulary gives (section 2) |
| Shorthand | CommonMark and GitHub Flavored Markdown (GFM) syntax, for example `**bold**` and `- list` |
| Tag | Syntax that writes an element directly, for example `<u>underline</u>` |
| Vocabulary | The list of known elements. It gives the kind, content, attributes, and attribute values of each element. |
| Unknown element | An element with a name that is not in the vocabulary |
| Normalization | The operation that changes a page tree into its normal form (section 3). This specification writes it as `N`. |
| Read-only element | An element that the editor shows, but that you can change only in the source (section 7.4) |

## 1. Page tree

### 1.1 Nodes

A page tree has only two types of node:

- Text node: `{ type: 'text', value: string }`.
- Element node: `{ type: 'element', name: string, attrs: Record<string, string>, children: Node[] }`.

The order of child nodes is part of the content. The order of attributes is not. All attribute values are strings. An attribute with an empty string value is not the same as no attribute, except for the optional attributes in section 3.1. The tree has no node IDs, comments, processing instructions, CDATA sections, or DTDs.

### 1.2 Names

- Element name: the first character is a Unicode letter. Each other character is a letter, a digit, `-`, or `_`.
- Attribute name: the first character is a Unicode letter or `_`. Each other character is a letter, a digit, `-`, or `_`. You cannot use `xmlns` as an attribute name.
- Each name must also be a valid XML name. Names are case-sensitive. A name that contains `:` or `.` is not valid.

### 1.3 Characters

Text and attribute values can contain only these XML 1.0 characters: U+0009, U+000A, U+000D, U+0020–U+D7FF, U+E000–U+FFFD, and U+10000–U+10FFFF. A lone surrogate is not valid. No read or write applies Unicode normalization (NFC or NFD).

### 1.4 Root element

The root element is `page`. `page` has no attributes and can occur only as the root. Markdown source does not contain the root element. XML source contains it as `<page>…</page>`. The title, identity, and revision number of a page are not in the page tree.

### 1.5 Size limits

- A source has a maximum of 8,388,608 UTF-16 code units.
- A page has a maximum of 100,000 element and text nodes in total. This count does not include layout whitespace. A page has a maximum of 128 levels below the root.

If content goes past a limit, the package reports an error. It does not truncate the content.

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

A known element (an element in the vocabulary) can have attributes that are not in the vocabulary. The package keeps these attributes without change and reports them as warnings (section 6.4). The package also keeps an unknown element and all its attributes without change, and reports the element as a warning.

`embed` holds only a reference. `ref` names the page that the embed shows. A database embed can also have `table` and `view`. The embedded page controls the format, existence, and lifecycle of these values. A page does not hold fields, records, views, or settings of the embedded page. The editor does not load the embedded page, read its assets, or delete it; those operations belong to the product that stores pages.

The product gives two address forms. A page link uses `ankole:page/<page ID>` in `href`, and an image that a page owns uses `ankole:asset/<digest>/<file name>` in `src`. The package treats both as any other attribute value. It reads, prints, and copies them without change, and it does not resolve them.

## 3. Normalization

Normalization (`N`) removes only differences that a reader cannot see. If two trees are equal after `N`, they show the same page. Each Markdown or XML parse, each print, each import into the editor, and each read from the editor applies `N`.

### 3.1 Attributes

- `N` sorts attributes by name, in the order of Unicode code points.
- If a known attribute has a value that section 2 does not give, that is an error.
- If the vocabulary declares `alt`, `title`, `lang`, `meta`, or `style` for an element, `N` removes that attribute when its value is an empty string. `N` also removes `start="1"` from `ol`, and `colspan="1"` and `rowspan="1"` from `th` and `td`.
- An element without one of its required attributes is an error.

### 3.2 Block content

The content types in this section are the values in the Content column of section 2. "Only …" content, for example "Only `li`", is a fixed set of child elements.

- In an element with "Block" or "Only …" content, text that contains only spaces, tabs, CR, and LF is layout whitespace. `N` removes it. Other text is an error.
- In an element with "Only …" content, any other child element is an error.
- If an element with "Block" content directly contains a known inline element, that is an error.
- An element with "Text" content (`pre`) can contain only text. An element with "Empty" content cannot have child nodes.
- `N` removes a `ul` or `ol` that has no list items.
- `N` merges two adjacent lists with the same name (both `ul` or both `ol`) into one list. The merged list has all attributes of the two lists, and its `start` comes from the first list. For an attribute other than `start`, two different values are an error.

### 3.3 Content of unknown elements

- If the child nodes include both a known block element and inline content, that is an error. Inline content is text that is not whitespace, or a known inline element.
- If the child nodes include a known block element, `N` processes them as block content (section 3.2).
- If all of these conditions are true, each text child is layout whitespace, also at the start and the end. `N` removes it.
  - The child nodes include an element.
  - The child nodes include no known inline element.
  - Each text child contains only spaces, tabs, CR, and LF, and contains a line break.
- In all other cases, `N` processes the child nodes as inline content (section 3.4).

### 3.4 Inline content

`N` first expands inline content into a sequence of segments. Then it rebuilds the content with the rules below. A segment is a run of text or one atomic element. Each segment has a set of formats, a style, and a link. The link is the `a` that contains the segment, or no link.

Expansion rules:

- A `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`, or `code` element without attributes becomes a format of its segments. Nested copies of one format are equal to one copy.
- A `span` with no attributes, or with only a `style` attribute, becomes the style of its segments. To join nested styles, `N` puts the outer style first. If the outer style does not end with a semicolon, `N` adds `;`. Then `N` adds a space before the inner style.
- Segments in an `a` get that link. Links cannot be nested. An `a` with no content is an atomic element.
- `br` and `img` are atomic elements. They have no formats and no style, but they keep their link.
- All other elements are atomic elements: unknown inline elements, format elements with attributes, and `span` elements with attributes other than `style`. They get the formats, style, and link of their outer elements. `N` normalizes the inside of each of these elements by the rules for that element.

`N` changes line breaks from the source (soft line breaks) with these rules:

- In text that is not code, `N` replaces each line break (CRLF, CR, or LF) with one space. The replacement also includes the spaces and tabs before the line break and all whitespace after it. In these cases, `N` replaces this text with an empty string:
  - The nearest visible characters on the two sides of the line break are both Chinese or Japanese characters.
  - The line break is at the start or end of the content.
  - The line break comes directly after a `br`.
- A Chinese or Japanese character is a Han character, a Hiragana or Katakana character, or a character in U+3000–U+303F, U+30FC, U+FE30–U+FE4F, or U+FF00–U+FFEF.
- To find the nearest visible character, `N` goes past whitespace. But whitespace in code, underline, strikethrough, or highlight text is visible. A `br` is a boundary of the content. Each other atomic element is a visible character that is not Chinese or Japanese.
- In code text, `N` replaces each line break with one space.

Other rules:

- `N` moves whitespace at the two ends of bold or italic text out of the bold or italic format. The other formats of that whitespace do not change. This rule does not apply to code text.
- `N` merges adjacent text that has the same formats, style, and link. It removes empty text.

Rebuild rules:

- `N` wraps adjacent segments with the same style in one `span` with that `style`. The `span` is the outermost element.
- In a range with the same style, adjacent segments with the same link make one link unit. `N` writes each link unit as one `a`. If parts of one link have different styles, each part becomes a separate `a`.
- A unit is a link unit or a segment outside a link. From left to right, `N` selects the format that covers the most consecutive units. It wraps those units in that format, and then processes the inside. The comparison order is `strong`, `em`, `s`, `u`, `mark`, `sub`, `sup`. If two formats cover the same number of units, `N` uses the first format in this order. For bold and italic ranges, a unit that contains only whitespace does not break the range.
- `code` is always the innermost format. It directly wraps text or an atomic element.
- `N` rebuilds the inside of a link with the same rules. If a format covers a full link, `N` writes the format outside the link.

## 4. Markdown

### 4.1 Input syntax

- The base is CommonMark 0.31.2 with these GFM extensions: tables, task list items, strikethrough, and bare URLs (GFM autolink literals). Footnotes are not part of the syntax.
- The syntax does not include three CommonMark constructs: indented code blocks, raw HTML, and angle-bracket autolinks. Indentation does not make a code block, and it does not stop other blocks. A heading, thematic break, fence, or list marker with four or more spaces of indentation is still valid.
- The parser reads each `<…>` as a tag (section 4.3). The tag syntax is the JSX tag syntax of MDX, without expressions.
- The parser decodes character references (HTML named character references and numeric character references) in text, links, code info strings, and attribute values.

### 4.2 Elements from shorthand

| Markdown | Element |
| --- | --- |
| Paragraph | `p` |
| ATX heading, Setext heading | `h1`…`h6` |
| Thematic break | `hr` |
| `>` block quote | `blockquote` |
| Bullet list, ordered list | `ul` or `ol`. The start number of an ordered list goes into `start`. |
| List item, `[ ]` or `[x]` task item | `li`. A task item has `task="todo"` or `task="done"`. |
| Fenced code block | `pre`. The first word of the info string goes into `lang`. The text after it goes into `meta`. |
| GFM table | `table` > `tr` > `th` (first row) or `td`. The alignment of a column goes into the `align` of each cell in that column. The content of each cell is one `p`. |
| `*x*`, `_x_` | `em` |
| `**x**`, `__x__` | `strong` |
| `~~x~~`, `~x~` | `s` |
| `` `x` `` | `code` |
| Hard line break (two spaces or a backslash at the end of a line) | `br` |
| Link | `a`, with `href` and `title` |
| Image | `img`, with `src`, `alt`, and `title` |
| Link reference, image reference | `a` or `img`, from its definition. If two definitions have the same label, the first definition applies. |
| Link reference definition | Not in the page tree |
| GFM bare URL | `a`. An address that starts with `www.` gets the prefix `http://`. An email address gets the prefix `mailto:`. |

### 4.3 Tags

Syntax:

- A start tag is `<name attributes…>`, an end tag is `</name>`, and an empty element is `<name />`.
- An attribute is `name="value"` or `name='value'`. An attribute `name` without a value has a value equal to its name.
- These are errors: an attribute value written as `{…}`, an attribute written as `{...x}`, a fragment `<>`, and a repeated attribute name.
- `{…}` in body text is plain text. A `<` in code is text.

The position of a tag sets its kind, block or inline:

1. If a line contains only tags and whitespace, those tags are block tags. The content between block tags can have an indent. Except in rules 5–7, the parser reads that content as Markdown blocks, and blank lines separate the blocks.
2. A tag in the middle of text is an inline element. The parser reads its content as inline Markdown. An inline element can continue across line breaks in the same paragraph. But between its start and its end, there cannot be a blank line or a line that contains only a tag.
3. If a paragraph contains only one known block element or one unknown element, the parser reads that element as a block. If that known block element has "Block" content, the parser wraps its inline content in a `p`.
4. If a paragraph contains only known block elements, with only whitespace between them, the parser reads each element as a block. An example is `<td>a</td>` cells with one cell on each line.
5. You can write a known element with inline or empty content (for example `p`, `h2`, or `u`) as block tags. Then its content is a maximum of one paragraph, and that paragraph can contain inline tags. More paragraphs or other blocks are an error. The parser reads a block element as that element. It reads an inline element as a `p` that contains only that element.
6. You can write an unknown element as block tags. The parser reads its content as inline content if all of these conditions are true:
   - Each line of the content contains only tags. There is no text paragraph.
   - The tags include a known inline element.
   - The tags include no known block element.

   In all other cases, the parser reads the content as blocks.
7. You can write `pre` as block tags. Then its content can only be one code fence, or it can be empty. The parser merges the attributes of the tag with the `lang` and `meta` of the fence. An attribute in both places is an error.

### 4.4 Lenient forms

If the strict read fails, the parser changes the source at each `<` as the table below shows. Then it reads the source again. The parser does not change the source at these `<` characters:

- a `<` in code
- a `<` that a backslash escapes
- a `<` at a link destination, which comes directly after `](` and optional whitespace

| After the `<` | Action |
| --- | --- |
| `!--`, `![CDATA[`, `?`, or `!` | Error: comment, CDATA, processing instruction, or `<!…>` declaration |
| An angle-bracket autolink, for example `<https://…>` or `<a@b.c>` | Error |
| A complete tag | Add double quotes around each attribute value that has no quotes. The HTML void elements are `area`, `base`, `br`, `col`, `embed`, `hr`, `img`, `input`, `link`, `meta`, `param`, `source`, `track`, and `wbr`. Add ` /` to the start tag of each of these elements. |
| Other text | The `<` is text. |

The parser maps error positions back to the original source.

### 4.5 Canonical output

The printer writes canonical Markdown. For each element, it uses the first form that is possible, in this order: shorthand, GFM, tag.

Block elements:

| Element | Condition for shorthand | Form if the condition is false |
| --- | --- | --- |
| `p` | It has no attributes, and it has content. It is not one line of only tags with no whitespace. It is not only one unknown element. | `<p …>…</p>`. An empty paragraph is `<p />`. |
| `h1`…`h6` | It has no attributes. | A single-line tag |
| `blockquote` | It has no attributes. | Block tags |
| `ul`, `ol` | The list has no attributes, except `start` on `ol`. The list items have no attributes, except `task`. In each task item, the first child is a `p` with content and no attributes. | Block tags for the list and for each list item |
| `pre` | It has only `lang` and `meta`. `lang` contains no whitespace, `` ` ``, `&`, or `\`. If there is `meta`, there is also `lang`. `meta` contains no line break, `` ` ``, `&`, or `\`, and has no whitespace at its two ends. | Block tags with all attributes on the tag. The content is a fence without an info string. |
| `hr` | It has no attributes. | `<hr … />` |
| `table` | The table and its rows have no attributes. The first row has only `th` cells, and the other rows have only `td` cells. All rows have the same number of cells. In each column, all cells have the same `align`, and that value is not `justify`. Cells have no attribute other than `align`. Each cell contains exactly one `p` without attributes. The text in a cell has no whitespace at its two ends. Attribute values in cells do not contain `\|`. | Block tags. If each cell in a row contains only one paragraph that can be shorthand, each cell of that row is on one line. In other rows, the cells are also block tags. |
| Other block elements | — | Block tags if all child nodes are elements that are not inline. An empty element if there are no child nodes. A single-line tag in all other cases. |

Inline elements:

| Element | Condition for shorthand | Shorthand |
| --- | --- | --- |
| `strong`, `em`, `s` | No attributes | `**…**`, `*…*`, `~~…~~` |
| `code` | No attributes, and only one text child node | `` `…` `` |
| `a` | Only `href` and `title` | `[text](url "title")`. A bare URL if the conditions below are true. |
| `img` | Only `src`, `alt`, and `title` | `![alt](url "title")` |

The printer writes all other inline elements as tags. It also writes an element in this table as a tag if its condition is false.

Output rules:

- The list marker is `-`. If `-` makes the parser read a list item as a thematic break or an empty sublist, the printer uses `*`. The numbers of an ordered list start at `start` and increase by one. The content of a list item starts one space after the marker.
- If a list item contains only one block, or only one paragraph and one sublist, the printer puts no blank lines in the item. In all other cases, it puts a blank line between the blocks in the item.
- Headings are ATX headings. Fences use backticks. If the content contains backticks, the printer makes the fence longer. A thematic break is `---`. A hard line break is `<br />`.
- One blank line separates blocks. The content of block tags has an indent of two spaces.
- In text, the printer escapes each character that the parser can read as syntax. It uses a backslash, or a character reference when necessary. It always writes `<` as `\<`.
- Tag attributes use double quotes and are in name order. In attribute values, the printer writes `&` as `&amp;`, `<` as `&lt;`, `"` as `&quot;`, tab as `&#9;`, LF as `&#10;`, and CR as `&#13;`.
- If a line of text contains only tags and whitespace, the printer writes the whitespace as numeric character references. The parser then reads the line as a paragraph. The printer writes a line that contains only tags, with no whitespace, in a `<p>` tag.
- The printer writes a link as a bare URL if all of these conditions are true:
  - The link contains only one text segment and has no title.
  - `href` is equal to the text, to `http://` and the text, or to `mailto:` and the text.
  - When GFM reads the text alone, it gets exactly the same link.
  - Before the link, there is the start of the content or whitespace.
  - After the link, there is the end of the content, or zero or more of `.,:!?)` and then whitespace or the end of the text.
- The output does not end with a line break.

The printer reads the full output back and compares the result with `N(tree)`. If the parser cannot read the output, the printer throws an `Error` with `规范 Markdown 无法读回：` ("Canonical Markdown cannot be read back: ") and then the cause. If the result is different, the printer throws an `Error` with `规范 Markdown 读回后得到不同的页面` ("Canonical Markdown gives a different page when it is read back"). In both cases, the printer does not return the output.

### 4.6 Differences from CommonMark

The tests open the official CommonMark 0.31.2 examples in the editor. They compare the content that the editor shows with the content of the reference implementation. These differences do not count:

- A soft line break shows as a space.
- Whitespace in bold or italic text is equal to plain whitespace.
- In a list item, the comparison uses only the breaks between paragraphs. It does not compare `<p>` wrappers.
- The comparison decodes percent-encoded characters in link and image addresses.

`upstream/fixtures/commonmark-dialect.json` records each other difference. Each entry gives the cause and the exact result, which is the page XML or the error message. All differences come only from these causes:

- Indentation does not make a code block, and it does not stop other blocks.
- Tags are page elements. The parser reads a vocabulary element as that element, keeps an unknown element as an unknown element, and reads the Markdown in tags.
- A `<` that does not start a complete tag is text.
- GFM reads bare URLs and email addresses as links.
- Adjacent lists of the same type merge.
- Angle-bracket autolinks, comments, CDATA, processing instructions, declarations, tags that are not complete or not closed, and elements that break the vocabulary rules are errors.

## 5. XML

Read:

- The parser accepts only XML 1.0. An XML declaration is optional. In the declaration, `version` must be `1.0`. If the declaration has `encoding`, it must be UTF-8.
- DOCTYPE, comments, and processing instructions are errors. The parser reads CDATA as text. It reads only the five predefined XML entities and numeric character references.
- The root element must be `page`. The parser applies `N` to the result.

Print:

- The printer writes no XML declaration and adds no layout whitespace. It writes an element with no child nodes as `<name />`.
- Attributes use double quotes and are in name order.
- In text, the printer writes `&` as `&amp;`, `<` as `&lt;`, `>` as `&gt;`, and CR as `&#13;`. In attribute values, it also writes `"` as `&quot;`, tab as `&#9;`, and LF as `&#10;`.

## 6. Errors and warnings

### 6.1 Error object

If a source is not valid, the parse function throws `DocumentError`. `DocumentError` has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `format` | `'markdown' \| 'xml'` | The source format |
| `reason` | `string` | What is wrong |
| `fix` | `string` | How to correct it |
| `start`, `end` | `number` | UTF-16 offsets in the original source |
| `line`, `column` | `number` | The line number and the column number. Both start at 1. The column counts UTF-16 code units. |

`message` has the format `{Markdown|XML} 第 {line} 行第 {column} 列：{reason}。{fix}` ("Markdown or XML, line {line}, column {column}: {reason}. {fix}").

If an error has no position of a specific node, it points to the start of the source.

### 6.2 Error reasons

These texts contain placeholders:

- `x` and `y` are names from the source.
- `a` is an attribute name.
- `v` is an attribute value.
- `c` is a character.
- `U+XXXX` is a code point.
- `…` is more detail.

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

Each error has a `fix`. These fixes must give specific advice:

- Tag that is not closed: if the tag opens in a paragraph, the fix tells you to write the end tag in the same paragraph. It also tells you that a blank line, or a line with only a tag, cannot be between the start and the end. In other cases, the fix tells you to write the end tag after the content. Both fixes also tell you to write a `<` in text as `&lt;`.
- Value of a known attribute that is not valid: the fix lists the valid values. An example is `align 的值应为 left、center、right 或 justify。` ("The value of align must be left, center, right, or justify.").
- Wrapper element in an element with "Only …" content: the fix tells you to remove the wrapper tags. A wrapper element contains child elements that the outer element accepts, for example `thead` in `table`.

For an XML syntax error, `reason` is the message from the XML parser, and `fix` is `请修正这处 XML 语法。` ("Correct this XML syntax.").

### 6.3 Errors from the editor and from writes

| Condition | Thrown error |
| --- | --- |
| The revision number is stale. | `Error('文档已变化，源码草稿已保留。请导出草稿并重新读取文档后合并修改。')` ("The document changed. The source draft is kept. Export the draft, read the document again, and then merge your changes.") |
| An input method editor (IME) composition is not complete. | `Error('输入法组合尚未结束，请完成输入后再应用')` ("The IME composition is not complete. Complete the input, and then apply it.") |
| The source is not valid. | `DocumentError` |
| The printer cannot print the new page. | The print error from section 4.5. The page does not change. |
| The editor content breaks a page rule, for example pasted content with too many levels of nesting. | `readTree` and `read()` throw `TreeError`. |
| The editor cannot read a node. | `Error('Unexpected block …')`, `Error('Unexpected block leaf …')`, or `Error('Unexpected inline node …')`. This error shows a defect in the editor. |

### 6.4 Warnings

`unknownNames(tree)` returns the warning texts in document order, with no duplicates. An unknown element gives `未知元素 <x>` ("unknown element <x>"). An unknown attribute on a known element gives `<x> 的未知属性 a` ("unknown attribute a on <x>"). The attributes of an unknown element do not get separate warnings.

## 7. Editor

### 7.1 Assembly

The editing engine is in `src/core`. It is a fork of Wordgard and is part of the source of this package. Changes to it follow the rules of this package. The package does not copy upstream changes into it automatically. `src/core/README.md` gives its origin, its license, and its differences from upstream.

`editorExtension()` returns the only editor assembly. The visible editor and the headless editor use the same assembly. The assembly contains these parts:

- the page schema (section 7.2)
- the corrections that keep the page in normal form (section 7.5, Normal form)
- history
- the revision count of `PageSession`
- block-boundary keys (`blockKeys`)
- lists (`listEditing`)
- keyboard shortcuts and typing shortcuts (`shortcuts`)
- links (`links`)
- the clipboard (`clipboard`)
- input events (`nativeInput`)
- tables (`tableEditing`)
- page-end clicks (`pageEnd`)
- the extension of each block definition

`initialState(initial, config)` makes an editor state with the assembly `config`. `initial` is a Markdown string or a page tree. If the Markdown is not valid, the function throws `DocumentError`. The caret starts at the end of the page. If you focus the editor or insert a block before a click, the action occurs at the end of the page. `headlessState(initial)` returns a headless state with `editorExtension()`.

### 7.2 Import: page tree to editor document

`pageDocument(tree)` applies `N` to `tree`. Then it makes the editor document as this table shows. `replaceTree(state, tree)` returns an update that replaces the full page.

| Element | Editor node |
| --- | --- |
| `p`, `h1`…`h6` | Paragraph, heading. `align`, `indent`, and `style` are marks on the node. |
| `blockquote` | Quote, which is a container. The editor imports each child block. |
| `ul`, `ol` | Bullet list, numbered list. `start` is a parameter of the numbered list. |
| `li` | List item, which is a container. The editor imports each child block. `task` is a mark on the list item. |
| `pre` | Code block. `lang` and `meta` are marks. A line break in the text is a line-break node. |
| `hr` | Divider |
| `table`, `tr`, `th`, `td` | Table, row, header cell, cell. Cells are containers. `colspan`, `rowspan`, and `align` are marks on the cell. |
| `callout` | Callout, which is a container. The editor imports each child block. |
| `embed` | Embed |
| Format elements, `span` with `style` | Marks on text: bold, italic, strikethrough, underline, highlight, subscript, superscript, code, and style |
| `a` with content | A link mark on text. The mark keeps all attributes of the link. |
| `br` | Line-break node |
| `img` | Image node. `alt` and `title` are marks. |
| Unknown elements, `a` without content, format elements with attributes, `span` with attributes other than `style` | Read-only element (section 7.4). An inline read-only element gets the formats, style, and link of its outer elements. |

The editor keeps each attribute that the table does not name, and each unknown attribute, in one mark on the node. Copy, undo, and block type changes keep this mark.

A bullet list can mix task items and plain items. Table rows can have different lengths, and a row can be empty. A cell can be empty. The editor keeps merged cells as document data, but it has no commands to merge or split cells.

An empty page imports as one empty paragraph with a placeholder mark. This paragraph holds the caret.

### 7.3 Read: editor document to page tree

`readTree(doc)` reads the document with the table in section 7.2, in the reverse direction. Then it applies `N`:

- It does not read an empty paragraph with a placeholder mark.
- It does not read characters in text and attribute values that are not XML 1.0 characters. Examples are control characters from a paste, and one half of a surrogate pair during input. The text in the editor does not change.

For each valid page tree `T`, an import and then a read give `N(T)`.

#### Prepare a submission

`preparePageUpdate(transaction)` prepares the final local transaction of a batch for XML storage. Run input appenders first, and call it after IME composition ends. The function reads and writes the document through the XML conversion chain, makes a correction for the parts that differ, and merges that correction into the transaction. Mark changes keep text positions. The returned transaction keeps the mapped selection and effects, annotations, and history boundary.

The client applies the returned transaction in place of the original. It composes that transaction's changes with the earlier changes in the batch, then sends the result. Normalizing only the wire data while keeping the old client document breaks the next batch. Remote replay applies the prepared changes without a new local preparation.

### 7.4 Read-only elements

A read-only element holds one element, and a read gives that element without change. The editor shows the content of the element:

- A vocabulary element shows in the editor style.
- `img` shows the image.
- A link shows its text. When the pointer hovers over the link, the editor shows the address.
- A task item shows a checkbox that you cannot operate.
- A callout and an embed show in their own styles.
- A block-level unknown element shows its content and a label with the element name.
- An inline unknown element shows its content. When the pointer hovers over it, the editor shows the element name.

The text content of a read-only element is all the text in the element, joined in order. You change a read-only element in the source. An image node shows the image, and you also change its attributes in the source.

### 7.5 Edit behavior

- **Normal form**: Before the editor applies an update that changes the document, it corrects the update with the rules of sections 2 and 3:
  - It merges adjacent lists of the same type. The merged list keeps the attributes of the first list. It also gets the attributes that only the second list has.
  - It removes formats, styles, and links in code blocks.
  - It removes `colspan` and `rowspan` with the value 1.
  - It removes attribute values that are not valid, spans larger than 9999, and optional attributes with an empty value.
- **Typing shortcuts**: The editor uses the Markdown syntax of the page (section 4.1, without tags) as typing shortcuts.
  - A block marker converts its paragraph when you type the space after the marker. This applies only to a paragraph that is directly in the page, a quote, a callout, or a table cell.
  - A fence converts when you press Enter. An inline format converts when you type its end marker.
  - Three more shortcuts apply when you type the last character of one of these texts, and the paragraph then contains only that text. `[] ` changes the paragraph into a task item. `" ` or `| ` changes the paragraph into a quote. `---` changes the paragraph into a divider and adds an empty paragraph after it.
  - If you type `[ ] ` or `[x] ` at the start of a bullet list item, only that item becomes a task item.
  - Only typed text converts. A paste or a delete does not convert. When an IME composition ends, the editor checks for a shortcut one time.
  - Each conversion is one undo step. An undo directly after a conversion restores the typed characters.
- **Typed URLs**: In text that is not code and not a link, an address becomes a link when you press Space or Enter after it. All of these conditions must be true:
  - The address is directly before the caret.
  - The address starts at the start of the text or after whitespace.
  - The address starts with `http://`, `https://`, or `www.`.
  - The last character of the address is not one of `.,;:!?'")]`.

  An address that starts with `www.` gets the prefix `http://`. Imported text does not become a link automatically.
- **Lists**: A list item is a container. Its first text block is the text of the list item. Its sublists are blocks after that text block.
  - If you press Enter in a list item, the editor splits the item at the caret. The text after the caret and the blocks after it in the item move to a new list item. A new item after a checked task item is an unchecked task item.
  - A new or outdented empty list item has no blocks. The printer writes it as `-`. If an edit makes the only paragraph of a list item empty, and the paragraph has no attributes, the item becomes an empty list item.
  - If an empty list item gets a sublist, the editor adds an empty paragraph above the sublist.
  - When a list item becomes a paragraph, its blocks become blocks of the page directly.
  - If you use Shift+Tab to outdent a list item in a sublist, its child items and the sibling items after it become its child items. The blocks that were after the sublist in the old parent item go into a new list item after the outdented item.
  - The first item of a list cannot nest one level deeper. Tab does not indent the first item of a list. If the selection starts at the first item of a list, the first item stays in its position, and the other items nest under it.
  - When the text of a list item merges into another block, the other blocks of that item go into the previous list item. The first item of a list has no previous list item. For that item, the other blocks go before the list.
  - If you press Enter in an empty list item, an item in a sublist outdents one level. A top-level item becomes a paragraph, and the list splits at that position.
  - If you press Enter at the start of a list item that is not empty, the editor adds an empty list item before it.
- **Callouts**: If both ends of the selection are in the same callout, a delete or a cut removes only content and keeps the callout. If you delete all blocks in a callout, one empty paragraph stays in it.
- **Embeds**: The delete keys do not delete an embed (refer to Delete). The Up Arrow and Down Arrow keys move the caret past it. The block menu can delete it. A selection that contains it can also delete it. For example, a click on it makes a node selection that contains it. Deleting the block removes only the embed. The page that it names stays.
- **Delete**: Backspace deletes backward, and Delete deletes forward.
  - Backspace deletes one character before the caret. It deletes an emoji, a zero-width joiner (ZWJ) sequence, or a character outside the Basic Multilingual Plane as one unit. For other characters with combining marks, each Backspace removes the last combining mark. Delete removes the full character after the caret.
  - On Apple platforms, Ctrl+H deletes the character before the caret, and Ctrl+D deletes the character after the caret. Ctrl+K deletes to the end of the line. Option+Backspace and Option+Delete delete by word. Command+Backspace deletes to the start of the line, and Command+Delete deletes to the end of the line.
  - On other platforms, Ctrl+Backspace and Ctrl+Delete delete by word.
  - When the caret is at the start or end of a block, the two tables below apply. These rules also apply to delete input events from the browser, for example a delete from an on-screen keyboard.
  - On Apple platforms, the text that Ctrl+K deletes does not go into the kill ring, and Ctrl+Y cannot paste it back.
  - If a key or an input event comes before the editor reads the new DOM selection, it acts at the caret position on the screen.
- **Input events**: The editor processes these `beforeinput` types: insert text, replace text, line break, paragraph break, transpose, and yank from the kill ring. It also processes drag and drop, delete by cut, all delete types, undo, redo, bold, italic, underline, and strikethrough.
  - The browser inserts IME composition text. The editor processes a paste in the `paste` event.
  - The editor cancels these types, and the page does not change: `deleteEntireSoftLine`, `formatSuperscript`, `formatSubscript`, `formatJustifyLeft`, `formatJustifyCenter`, `formatJustifyRight`, `formatJustifyFull`, `formatIndent`, `formatOutdent`, `formatRemove`, `formatSetBlockTextDirection`, `formatSetInlineTextDirection`, `formatBackColor`, `formatFontColor`, `formatFontName`, `insertOrderedList`, `insertUnorderedList`, `insertHorizontalRule`, `insertLink`.
  - The editor cannot cancel some `insertReplacementText` events, for example a spelling correction. For these events, the browser changes the page. If the change stays in a text node that was there before the event, the editor reads the result and inserts it one time. If the browser changes the page structure, the editor renders the page again from the document, and the change is lost.
  - The browser applies some changes itself: typed text, composition text, and inline deletes. Between the `beforeinput` and `input` events of such a change, the editor does not render the page again. During this time, a layout read gets the page from the last render.
- **Paste and copy**:
  - From pasted HTML, the editor keeps headings, lists and nested lists, quotes, and tables. It also keeps task items (`aria-checked`, or GitHub task list items), code blocks with `data-language`, links (`href`, `title`), and images (`src`, `alt`, `title`).
  - For formats, the editor reads the format elements and `<b>`, `<i>`, `<del>`, and `<strike>`. Bold comes only from the font weights `bold` and 700.
  - For styles, the editor keeps only text case changes (`text-transform`) and alignment (`data-align` or `text-align`). It disregards `text-align: start` and reads `end` as `right`. It removes all other styles and all block styles.
  - The editor reads callouts and embeds only in the form that the editor writes.
  - When you copy between editors, the clipboard HTML carries the exact data of the copied content. If that data is not there, or does not agree with the page schema, the editor reads the HTML.
  - If the clipboard has only plain text, the editor reads it as Markdown. If the result has blocks other than paragraphs, or formats, links, or line breaks, the editor inserts it as page content. If the result has only plain paragraphs, contains unknown elements, or cannot be read, the editor inserts the plain text.
  - In a code block, the editor always inserts plain text, and line breaks become line-break nodes. If the clipboard has only HTML, the editor uses the text of the HTML, with one line for each block.
  - When the editor inserts page content, only the text blocks at the two edges are open. If the first block is a text block, it merges into the block at the caret. If the last block is a text block, the text after the caret merges into it. Lists, tables, quotes, and callouts go in as full blocks.
  - A fully selected quote, callout, list item, cell, list, or table copies as a full block. A cell copies with its row and its table. A list item copies with its list. A cell selection copies a table of the selected cells. A partial selection in a list item copies without the list.
  - In copied plain text, each text block is one line. A copied table has one line for each row, with a tab between cells.
- **Page-end click**: This rule applies when the last block is a leaf block or a container. A leaf block is an embed, a divider, or a block-level read-only element. A container is a table, a quote, or a callout. A click in the empty area below the last block adds an empty paragraph at the end of the page. The caret goes into that paragraph.
- **History**: Each of these is one undo step:
  - a format change from the toolbar
  - a block menu action
  - an insert from the insert menu or the slash menu
  - a block shortcut (duplicate, move, or change type)
  - a drag of a block handle to change the order of blocks
  - a typing shortcut conversion
  - a whole-page write

A text block is a block that contains text directly: a paragraph, a heading, or a code block. When the caret is at the start of a block, a backward delete does this:

| Block at the caret | Backspace, Ctrl+H, delete by word | Command+Backspace |
| --- | --- | --- |
| A list item, or the block at the start of a list item | The list item becomes a paragraph. A top-level list splits at this position, and the paragraph goes between the two parts. The first item of a sublist becomes a paragraph in the parent list item. The other items of a sublist become paragraphs in their positions. The sublist of the item comes after the paragraph. | An item in a sublist outdents one level, together with its child items. A top-level item merges into the nearest text block before it. |
| A paragraph or block after the first paragraph of a list item | This block, and the content after it in the list item, move out of the list to a position after this list item. The list splits at this position. | Same as Backspace |
| A paragraph or heading with an indent | The indent decreases by one level. | Same as Backspace |
| The first paragraph of a quote | All paragraphs of the quote become plain paragraphs. | This paragraph merges into the nearest text block before the quote. If there is no text block before it, nothing changes. |
| The first paragraph of a callout | This paragraph merges into the nearest text block before the callout. If the callout becomes empty, the editor deletes it. If there is no text block before the callout, nothing changes. | Same as Backspace |
| The first paragraph of a table cell | Nothing changes. | Same as Backspace |
| A block after a divider, an embed, or a block-level read-only element | The block merges into the nearest text block before them. These blocks stay in their positions. If there is no text block before them, nothing changes. | Same as Backspace |
| A block after a quote, a callout, or a table | The block merges into the last text block in it. For a table, this text block is in the last cell. | Same as Backspace |
| The first block of the page | If the block is empty and other blocks come after it, the editor deletes it and moves the caret to the next block. In other cases, nothing changes. | Same as Backspace |
| Any other block | The block merges into the previous block. The type of the previous block does not change. | Same as Backspace |

When the caret is at the end of a block, a forward delete (Delete, Ctrl+D, Ctrl+K, delete by word, or Command+Delete) does this:

| Condition | Result |
| --- | --- |
| The next block is a divider, an embed, or a block-level read-only element. | The nearest text block after them merges into the block at the caret. These blocks stay in their positions. If there is no text block after them, nothing changes. |
| The block at the caret is the last paragraph of a quote or a callout. | The nearest text block after the container merges into the block at the caret. |
| The next block is a quote or a callout. | The first text block in it merges into the block at the caret. If the container becomes empty, the editor deletes it. |
| The next block is a table, or the block at the caret is the last paragraph of a table cell. | Nothing changes. |
| Any other condition | The text of the next block, of the next list item, or of the first child item merges into the block at the caret. The type of the block at the caret does not change. If the caret is in an empty list item, quote, callout, or cell, this text goes into a new paragraph in it. |

Enter:

- In a heading: in the middle, the text after the caret becomes a paragraph after the heading. At the start, the editor adds an empty paragraph before the heading. At the end, the editor adds an empty paragraph after the heading.
- In a paragraph of a quote: the text after the caret becomes a paragraph after the quote. The paragraphs after it in the quote make a new quote after this paragraph. At the start of the first paragraph of the quote, Enter does a different thing. If that paragraph is not empty, Enter adds an empty paragraph before the quote. The caret does not move.
- In a callout: the editor adds a paragraph in the callout. If the callout has other blocks, and its last paragraph is empty, Enter in that paragraph moves it to a position after the callout.
- In a list: refer to Lists.

The block type operation `applyBlockType(editor, type, replace?)` is one undo step. `replace` is a range that the operation deletes first, in the same step. An example is the query text of the slash menu.

| `type` | Behavior |
| --- | --- |
| `paragraph`, `h1`, `h2`, `h3` | Changes the selected blocks into paragraphs or headings. Keeps the alignment, the indent, the style, and the attributes that are not in the vocabulary. |
| `bullet`, `number`, `check` | Changes the selected paragraphs, headings, and code blocks into list items. Each block becomes the paragraph of a list item and keeps its alignment, style, and attributes that are not in the vocabulary. A block with no content and no attributes becomes an empty list item. The indent of a block becomes its nesting level in the list. Each item can be a maximum of one level deeper than the previous item. The first item of a new list does not nest. If a list of the same type is directly before the blocks, the new list items go into that list. In a bullet list, each run of consecutive task items or plain items counts as one list. The operation changes the type of the run that contains the selected items. |
| `quote`, `callout` | Puts the text of the paragraph, heading, or code block at the caret into a new paragraph. Wraps that paragraph in a quote or a callout. The new paragraph keeps the alignment, indent, style, and attributes outside the vocabulary from the old block. The caret moves to the end of the new paragraph. If the caret is in a different type of block, the operation splits that block at the caret. It puts an empty quote or callout between the two parts and moves the caret into it. A list splits at the list item with the caret. If the caret is at the end of the last list item, the second part is an empty list item. |
| `code` | Changes the selected blocks into code blocks. Keeps only the text, the line breaks, and the attributes that are not in the vocabulary. If the old block is a code block, keeps its language and `meta`. A code block has no alignment, indent, or style. |
| `divider`, `embed` | Inserts a divider, or an empty embed at the caret. If the paragraph at the caret is empty and has no attributes outside the vocabulary, that paragraph becomes the new block. An empty paragraph comes after it. In other cases, the operation splits the block at the caret and puts the new block between the two parts. A list splits as for `quote`. The caret moves to a position after the new block. |

When a code block changes into another type, the editor removes `meta`. When a heading changes into another type, the editor does not keep the heading level. When a code block splits in the middle, the two parts both keep the language and `meta`.

Block menu actions apply to top-level blocks:

- Duplicate: makes a deep copy that keeps all attributes. The check state of a task item also stays. The caret moves to the copy.
- Delete: the caret moves to the next block. If there is no next block, the caret moves to the previous block. If the page becomes empty, the editor adds an empty paragraph.
- Move up, Move down: the block changes position with the adjacent block.

The `转换为` (Turn into) item of the block menu applies only to paragraphs, headings, and code blocks. In a list item, the slash menu and the insert menu also run block type operations. `paragraph`, `h1`–`h3`, and `code` move the list item out of the list. `bullet`, `number`, and `check` change the type of the list.

### 7.6 React component

Props of `BlockEditor`:

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `initial` | `string \| DocumentElement` | `''` | The component reads it only one time, when it makes the editor. |
| `onReady` | `(editor) => void \| (() => void)` | — | The component calls it after it makes the editor. The component calls the returned function when it unmounts. |
| `onChange` | `() => void` | — | The component calls it synchronously each time an accepted update changes the page. It gets no content. |
| `onError` | `(error: unknown) => void` | — | Reports a rejected edit without replacing the current document. Without a callback, the component displays the error. |
| `readOnly` | `boolean` | `false` | Refer to the text below. |
| `labels` | `Partial<EditorLabels>` | Chinese defaults | Host translations for visible and accessible editor text. Unspecified labels keep their defaults. |
| `ariaLabel` | `string` | `文档编辑器` ("document editor") | The accessible name of the edit area |
| `placeholder` | `string` | `输入 / 添加 Block，或直接开始写作…` ("Type / to add a Block, or start to write…") | The prompt for an empty page. Refer to the text below. |
| `className` | `string` | `''` | The component adds it to the outer element. |
| `header`, `footer` | `ReactNode` | — | Content before and after the body |
| `toolbar` | `ReactNode` | The default toolbar | `null` hides the toolbar. Custom content runs in the editor context. |
| `children` | `ReactNode` | — | Content in the editor context. It can use `useEditor` and `useEditorState`. |

A host re-render, new callback, or label change does not make a new editor.
Labels use `PhraseSet`; hosts own locale selection and translation catalogs.
`ariaLabel` and `placeholder` override the corresponding labels when supplied.
Slash search matches the translated block title and detail, plus its fixed
keyword aliases. Labels do not change document text, selection, or undo history.
The interface descriptions below use the default Chinese labels.
When `readOnly` is `true`:

- You cannot edit the page.
- The toolbar is in a disabled `fieldset`. The default toolbar shows only the hint text and the disabled undo and redo buttons.
- The editor does not show the empty-page prompt, the slash menu, the selection toolbar, the block menu, or the block handles.
- You can still read and select the body text, and assistive technology can still access it.

When the page has only one empty paragraph and you can edit the page, that paragraph shows the empty-page prompt. The prompt is not page text. It is not part of the paragraph text, and it does not change the caret. The `aria-placeholder` of the edit area has the same prompt.

`onChange` can run before the editor renders the update. Then a layout read in `onChange` gets the page from the previous render. In the editor context, `useEditor()` returns the editor. `useEditorState(select?)` returns the state that the editor rendered, or the value that `select` reads from that state. The component renders again after the editor renders. This lets the component measure the page. For a state with no change, `select` must return an equal value.

User interface:

- **Default toolbar**: has these items:
  - the `插入` (Insert) menu
  - the `当前 Block 菜单` (Current Block menu) button
  - the hint text `选中文字设置格式 · / 添加内容` ("Select text to format it · Type / to add content")
  - `撤销` (Undo)
  - `重做` (Redo)
- **Selection toolbar**: shows when the selection contains text that is not whitespace and is not in a code block. The buttons, in order, are bold, italic, underline, strikethrough, inline code, link, and highlight. The pressed state of each button shows the format of the selection. The toolbar hides during an IME composition and when the focus is in an input box. It also hides when the selection goes out of the visible area, and after you press Escape.
- **Link form**: opens from the toolbar or with ⌘K. The form uses an address without change if it starts with `http://`, `https://`, `mailto:`, `tel:`, `/`, or `#`. An address that is a domain name with a suffix, for example `example.com`, gets the prefix `https://`. For all other input, the form shows an error and does not change the body text. If the text has a link, the form also shows `移除链接` (Remove link).
- **Slash menu**: opens when you type `/` at the start of the text run at the caret, or after whitespace or `(`. An example of the start of a text run is the position directly after bold text or a link. The menu does not open in a code block, where `/` is code text. The query after `/` has a maximum of 75 characters. It cannot contain whitespace or any of `.,+*?$@|#{}()^-[]\/!%'"~=<>_:;`. The menu filters options by title and description, and the filter is not case-sensitive. When you select an option, the editor deletes the query text and runs the block type operation in one undo step.
- **Insert menu**: `插入` (Insert) on the toolbar runs the block type operation at the caret. The `+` of a block handle inserts a paragraph below the block under the pointer, and then runs the operation there.
- **Block menu**: has these items:
  - `转换为` (Turn into) lists the types that the block can change into. It is disabled when the block cannot change its type.
  - `创建副本` (Duplicate)
  - `上移` (Move up)
  - `下移` (Move down)
  - `删除 Block` (Delete Block)

  The `当前 Block 菜单` (Current Block menu) button on the toolbar and ⌘/ act on the top-level block at the caret. A block handle acts on the top-level block under the pointer. The menu has the same items in the three places.
- **Block handle**: shows when the pointer is on a top-level block. You can drag it to change the order of blocks. A drag is one undo step.

The insert options are in this order:

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
| Edit the link of the selected text, or the link at the caret | ⌘K |
| Open the block menu of the block at the caret. This has no effect if the selection goes across more than one top-level block. | ⌘/ |
| Duplicate the selected blocks, and put the copies after them | ⌘D |
| Move the selected blocks before the previous sibling block or after the next sibling block | ⌘Shift+↑, ⌘Shift+↓ |
| Change the type of the selected blocks | On Apple platforms, Command+Option with a digit. On other platforms, Ctrl+Shift with the same digit. 0: paragraph. 1, 2, 3: heading of that level. 4: task list. 5: bullet list. 6: numbered list. 8: code block. |
| Select the text of the block at the caret, and then all of the page | ⌘A, two times |
| Move from the selection to the selection toolbar | Alt+F10 |
| Move the focus in the selection toolbar | Left Arrow, Right Arrow, Home, End |
| Close a menu, or cancel a link change | Escape |
| Bold, italic, underline | ⌘B, ⌘I, ⌘U |
| Inline code | ⌘E |
| Strikethrough | ⌘Shift+S or ⌘Shift+X |
| Highlight | ⌘Shift+H |
| Undo, redo | ⌘Z, ⌘Shift+Z. On other platforms, Ctrl+Y also does a redo. |
| Hard line break | Shift+Enter |
| Increase or decrease the indent. A list item changes its nesting level. A paragraph or a heading changes its `indent`, to a maximum of 49 levels. | Tab, Shift+Tab, with the caret at any position in the block. In a code block, Tab inserts a tab character. |
| Move to the next or previous cell in a table | Tab, Shift+Tab. The caret moves to the end of the text in the cell and goes past empty rows. Tab in the last cell, or Shift+Tab in the first cell, moves out of the table. |

A selection across more than one cell is a cell selection. In a cell selection, typed text and deletes change only the content of the cells. The table and the cell alignment stay the same.

The shortcuts that duplicate, move, and change the type of blocks act on the selected blocks:

- A list item includes its child items.
- In a quote, a callout, or a table cell, the shortcuts act on the blocks in it.
- If the selection goes across more than one sibling block, the shortcuts act on all of these blocks. If not, they act on the block where the selection starts.

During an IME composition, Enter, Escape, and keys with `keyCode=229` do not submit or cancel a menu or the link form.

### 7.7 PageSession

`PageSession` is the entry point for whole-page reads and writes. The source panel and writes from a language model use the same instance.

| Member | Behavior |
| --- | --- |
| `new PageSession(editor)` | Starts the revision count. A new instance on the same editor replaces the old instance. |
| `revision` | The revision number. It increases by 1 each time a dispatched update changes the page. |
| `read()` | Returns `{ revision, markdown, xml }`. |
| `readXml()` | Returns `{ revision, xml }`, reusing the accepted document's validated XML source. |
| `apply({ format, source, revision })` | Refer to the steps below. |
| `dispose()` | Stops the count and rejects later writes through this instance. Reads remain available. |

`apply` does these steps in this order:

1. If this instance was replaced or disposed, it throws an error.
2. If an IME composition is not complete, it throws an error.
3. If `revision` is not equal to the `revision` of the session, it throws an error.
4. It parses `source` as `format` (`'markdown'` or `'xml'`).
5. It prints the new page. If the print is not possible, it throws an error.
6. It replaces the full page in one update that you can undo.
7. It returns `{ revision, markdown, xml, warnings }`.

When `apply` throws an error, the page does not change.

A revision number is valid only in one editor instance.

## 8. Package and host

### 8.1 Entry points

| Entry point | Exports |
| --- | --- |
| `@ankole/block-editor` | `BlockEditor`, `useEditor` |
| `@ankole/block-editor/document` | `parseMarkdown`, `printMarkdown`, `parseXml`, `printXml` |
| `@ankole/block-editor/editor` | `editorPhrases`, `PageSession`, `PageCollaboration`, `insertEmbed`, `insertImage`, `toggleFormat`, `undo`, and the types `EditorLabels`, `Editor`, `EditorHost`, `EmbedAttributes`, `PageChanges` |
| `@ankole/block-editor/styles.css` | The styles of the editor and its overlays |

A host imports only these entry points. They serve the Pod, Worker, and
embedding example. The example uses `useEditor`, `toggleFormat`, and `undo` for
its custom toolbar. Internal editor helpers and test types use relative imports.
`PageSession.read()` reads a page snapshot. `PageSession.apply()` replaces the
page from Markdown or XML and checks its revision.

The optional `host` in `BlockEditor` supplies `EditorHost`:

| Hook | Contract |
| --- | --- |
| `mountEmbed(attributes, container, update)` | Mount the referenced resource and return its cleanup function. `update` changes only the reference attributes through an editor transaction. |
| `resolveAsset(address)` | Resolve the image address; the editor preserves its alt text and title. |
| `openPage(id)` | Open a page link in the host's navigation. |
| `deleteEmbed(id)` | Handle the explicit block-menu deletion action. Ordinary selection edits remove the reference only. |

`insertEmbed` and `insertImage` insert at the current selection in one undoable
editor transaction. `PageCollaboration` owns the local pending change set and
one in-flight batch. The host supplies send, change, reset, and sync callbacks;
the server assigns revisions. Preparation failures preserve the local document
and publish an error. The host owns reconnecting the transport. Calling
`dispose()` ends that collaboration instance.

Document transactions validate the source, node, and depth bounds (section 1.5)
before updating editor state, revision, or undo history. A rejected transaction
keeps the preceding legal draft. When a remote change combined with pending
local edits exceeds a bound, collaboration preserves the current legal draft and
requests reset/reload recovery from the host.

### 8.2 Dependencies and build

- This package is an internal Ankole workspace library and keeps `private: true`. Its public package name is `@ankole/block-editor`. An internal host declares `"@ankole/block-editor": "workspace:*"` in its own `package.json`.
- This package is a TypeScript source package, and the host builds it. `bun run build` checks the types of the library, the example host, and the tests. `bun run build:playground` builds the example host separately.
- The `package.json` and `bun.lock` in the Ankole root control the dependencies. The package directory has no lockfile of its own. `@ankole/uikit` uses `workspace:*`.
- The root pins `mdast-util-gfm-strikethrough` to `2.0.1`. This version keeps strikethrough at punctuation and tag boundaries when text follows it. A separate host must also use this version or a later version with the same fix.
- `react` and `react-dom` 19.3.0 are peer dependencies. The host and the editor use the same instance of each. `style-mod` and `@marijn/find-cluster-break` are dependencies of this package, because the editing engine uses them.
- A host that uses the React component and the UI Kit styles must also declare `"@ankole/uikit": "workspace:*"`. It must also have direct dependencies on the React peer dependencies above.
- The host CSS loads `@ankole/uikit/styles.css` first, and then `@ankole/block-editor/styles.css`. The editor styles apply only in `.ankole-editor` and `.ankole-editor-overlay`. They do not change `html`, `body`, or `#root`.
- Each install must apply the patches in `patches/`. The `patchedDependencies` field in the Ankole root declares them, and `bun install` in the root applies them. A separate host that installs the package from a tarball must declare them in its own `patchedDependencies`:
  - `mdast-util-to-markdown@2.2.0`: When a format boundary writes a letter as a character reference, a literal backslash before it must not escape the reference. The regression test is in `test/generated.test.ts`.
- Remove a patch and its `patchedDependencies` entry when all of these conditions are true:
  - Upstream fixes the problem of the patch.
  - The regression test passes.
  - The tests in the three browsers pass.

### 8.3 Block definitions

A block with its own editor node has a `BlockDefinition` with these fields:

| Field | Meaning |
| --- | --- |
| `name` | The element name |
| `type` | The node type that holds the element |
| `schema` | The node types, marks, and overrides that the block adds to the page schema |
| `extension` | The edit behavior and the display of the block |
| `import(element, { blocks })` | Makes a node from an element. `blocks` imports the child blocks. |
| `read(node, { children })` | Reads an element from a node. `children` reads the child blocks. |
| `insert` | The menu item: `title`, `detail`, `glyph`, `turnInto` (if the block can replace the text block at the caret), and `insert(editor)` |

To install a block type, add its definition to the `blocks` list in `src/blocks/index.ts`. Then add the kind, content, and attributes of its element to `src/document/vocabulary.ts`. You do not change the Markdown and XML readers and writers. This package has two block definitions: `callout` and `embed`.

## 9. Example host

Run these commands from the Ankole root:

```sh
bun install --frozen-lockfile
bun run --filter @ankole/block-editor dev
```

- <http://127.0.0.1:3046>: the full example page.
- <http://127.0.0.1:3046/playground/embedded.html>: two independent editors on one page.

Behavior of the full example page:

- The source panel switches between Markdown and XML. After you change the source, you cannot edit the page on the left until you select `应用修改` (Apply changes) or `放弃修改` (Discard changes). `PageSession.apply` applies the changes. If the apply fails, the draft and the page do not change. The success notice lists the warnings.
- `往返验证` (Round-trip check) exports the page as Markdown and makes a new editor from that Markdown. Then it compares the XML that it reads from the two editors, and clears the undo history.
- `导出` (Export) saves a `.md` or `.xml` file in the format that the source panel shows. `打开文件` (Open file) selects the format from the file extension.
- The page saves to the browser `localStorage` under the key `ankole.block-lab.markdown.v2`. A save occurs 250 milliseconds after a content change, and immediately when the page unloads (the `pagehide` event). If the saved data cannot be read, the original text stays as a draft for repair. Nothing overwrites it before the repair. `恢复示例` (Restore example) replaces the page with the example page.

## 10. Compatibility and verification

### 10.1 Browsers

The build targets for JS and CSS are `chrome126`, `firefox153`, and `safari17`.

| Scope | Requirement | Automated check |
| --- | --- | --- |
| Chromium 126 and later | Required | Playwright Chromium. The built output runs the same scenarios on Chrome for Testing 126.0.6478.182. |
| The latest Firefox ESR | Required | Playwright Firefox. Native Firefox 153.4.0esr runs some scenarios through WebDriver. |
| Safari 17 and later | Required | Not verified. Playwright WebKit is not Safari. |
| Mobile browsers | Best effort | Not verified |

`compat/browsers.json` pins the versions of the compatibility browsers. They install into `output/browsers`, which Git ignores.

### 10.2 Test commands

- `bun run test` checks these parts:
  - the page tree and normalization
  - Markdown and XML reads, writes, and canonical output
  - error positions
  - real documents from the repository
  - the editing engine (`test/core`)
  - editor import and read
  - list keys and block-boundary keys
  - block actions and shortcuts
  - whole-page writes

  fast-check makes pages with all vocabulary elements. These pages also contain tables of any shape and merged cells. For each page `T`, an import and then a read must give `N(T)`. A whole-page write and then a read must also give `N(T)`. The default seed is `20261005`. `FC_SEED` sets a different seed. The headless editor tests run the same assembly on a view that is marked as fake. `test:e2e` checks the behavior that uses a DOM.
- `bun run test:upstream` checks the 652 examples of CommonMark 0.31.2 (section 4.6) and 52 Tiptap fixtures. The page tree of each Tiptap fixture must make an exact round trip through the editor.
- `bun run test:e2e` runs in Chromium, Firefox, and WebKit on port 3146. It checks these parts:
  - the browser tests of the editing engine (`test/core/browser`), which `e2e/core.spec.ts` runs. In WebKit, one upstream case that hits a pixel position is a known failure.
  - edits
  - deletes, Enter, and Tab at block boundaries
  - shortcuts
  - delete keys
  - input event types
  - arrow keys, and the caret in empty blocks
  - page-end clicks
  - menus
  - selections
  - the clipboard and Markdown paste
  - the source panel
  - embedding
  - upstream cases

  Some cases do not run in all browsers or on all platforms:
  - IME cases that only the Chrome DevTools Protocol (CDP) of Chromium can drive do not run in the other two engines.
  - Cases for keys that only Apple platforms have do not run on other platforms.
  - Transpose cases do not run in Firefox, because Firefox does not transpose characters.
  - Cases for a native drag that selects text run only in Firefox.

  A browser exception or a console error makes the test fail. `E2E_PREVIEW=1` uses the built output.
- `E2E_PREVIEW=1 bun run test:chromium126` runs the same scenarios on Chrome for Testing 126.
- `bun run test:native` runs WebDriver tests in native Firefox ESR on port 3147. `NATIVE_BROWSER=safari` uses Safari.
- `bun run generate:corpus` writes the shared golden file in `corpus/rust`. `bun run test:corpus` checks it without rewriting it. It holds pages, rejected sources, exact document-limit boundaries, and local edit batches from the production transaction pipeline. Each batch has the expected client XML and document. Replay compares the in-memory client with a server that stores and reads XML after every batch. A mismatch fails the preflight. `FC_SEED` selects the generated samples or the independent property-test seed. `corpus/rust/README.md` describes format version 2 and its limits.
- `bun run test:package` installs the editor and UI Kit from tarballs and checks the public types. Then it checks reads and writes on a headless editor state and builds a host. Last, it runs the embedding tests in the three browsers, exercising `PageSession`, `PageCollaboration`, the host hooks, cursor-position image insertion, and undo.
- `bun run type-check`, `bun run fmt:check`, and `bun run build` check the types, the format, and the build.
- `bun run test:e2e:install` and `bun run test:compat:install chromium126 firefox-esr` install the test browsers.

With `E2E_PREVIEW=1`, `test:e2e` and `test:chromium126` use the built output that `dist/` contains. They do not make a new build. `test:native` always uses the built output. Before you use the built output, run `bun run build:playground`. The tests do not retry automatically.

### 10.3 Manual checks

Automated tests cannot prove the items below. For acceptance, record these data for each item:

- the operating system
- the full browser version
- the IME name and version
- the steps
- the event trace
- screenshots
- the exported Markdown

| Scope | Environment | Pass condition |
| --- | --- | --- |
| Desktop | Windows with Chromium 126 or Firefox ESR. Microsoft Pinyin, Japanese, and Korean IMEs. | Select candidates, go to the next page of candidates, commit with Enter, and cancel with Escape. Do this in an empty paragraph, at a bold boundary, and in a list, a callout, and a table. No text is inserted two times, no block splits too early, and no format is lost. |
| Desktop | macOS with Chromium 126, Firefox ESR, or Safari 17. The system Pinyin, Japanese, and Korean IMEs. | During a composition: focus changes, mouse selections, Tab, undo, and redo. After the page opens again, the content is the same. |
| Desktop | The browsers in section 10.1. Latin dead keys, accents, emoji and ZWJ sequences, and bidirectional text. | Each delete removes the character unit that section 7.5 (Delete) gives. The logical boundaries of selections are correct. Screenshots confirm the caret position in bidirectional text and at line breaks. |
| Desktop | The system clipboard with content from Word, browsers, and Office | Formats, nested lists, tables, links, and blank lines stay after a real paste from another application and an export. |
| Mobile | Safari on iOS or iPadOS 17. Chromium 126 on Android with Gboard or the system IME. | Candidates, autocorrect, voice input, continuous composition, touch selection, the on-screen keyboard over the content, zoom, and scroll. |

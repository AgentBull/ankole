/*
 * The editor schema: one node type or mark type for each element and attribute of the page tree
 * (SPEC §1–§3), so that every normalized page has exactly one editor document.
 *
 *  - An element becomes a node type. h1–h6 are one type with the level as parameter.
 *  - Vocabulary attributes become typed marks on the node. Attributes outside the vocabulary go
 *    into one `Attrs` mark whose value is sorted [name, value] pairs (see `checkPairs`).
 *  - Unknown elements, and inline elements that N keeps as atoms, become read-only leaves whose
 *    parameter is a frozen copy of the element.
 */
import { Elt, Leaf, Mark, Node, parse, Plot, Schema, ValidationError } from '../core/doc'
import * as T from '../core/types'
import { blocks } from '../blocks'
import { embedCard } from '../blocks/embed'
import { Attrs, checkPairs, type Pairs } from './attributes'

const G = Node.Group

/** A frozen element: the parameter of a read-only leaf. Text children are plain strings. */
export type Frozen = { readonly name: string; readonly attrs: Pairs; readonly children: readonly (string | Frozen)[] }

function checkFrozen(value: unknown): void {
  const frozen = value as Frozen
  if (!frozen || typeof frozen !== 'object' || typeof frozen.name !== 'string' || !Array.isArray(frozen.children)) {
    throw new ValidationError('Expected a frozen element')
  }
  if (!Array.isArray(frozen.attrs)) throw new ValidationError('Expected attribute pairs')
  if (frozen.attrs.length) checkPairs(frozen.attrs)
  for (const child of frozen.children) if (typeof child !== 'string') checkFrozen(child)
}

/** §7.4: the text of a read-only element is all the text in the element. */
const frozenText = (frozen: Frozen): string =>
  frozen.children.map(child => (typeof child === 'string' ? child : frozenText(child))).join('')

const oneOf =
  <V extends string>(...values: V[]) =>
  (value: V) => {
    if (!values.includes(value)) throw new ValidationError(`Expected one of ${values.join(', ')}, got ${value}`)
  }

const integer = (min: number, max: number) => (value: number) => {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ValidationError(`Expected an integer from ${min} to ${max}, got ${value}`)
  }
}

// ---------------------------------------------------------------------------
// Read-only display. Only element names and display attributes reach the editor DOM; document
// attributes such as `onclick` never do.

const shown = new Set([
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'ul',
  'ol',
  'li',
  'pre',
  'table',
  'tr',
  'th',
  'td',
  'strong',
  'em',
  's',
  'u',
  'mark',
  'sub',
  'sup',
  'code',
  'span',
  'br',
  'hr'
])

function view(frozen: Frozen, inline: boolean): Elt<string> {
  const children = frozen.children.map(child => (typeof child === 'string' ? child : view(child, inline)))
  const attr = (name: string) => frozen.attrs.find(pair => pair[0] === name)?.[1]
  if (frozen.name === 'img') return Elt.mk('img', { src: attr('src') ?? '', alt: attr('alt') ?? '' })
  if (frozen.name === 'a') return Elt.mk('span', { class: 'read-only-link', title: attr('href') ?? '' }, children)
  if (frozen.name === 'li' && attr('task')) {
    return Elt.mk('li', { class: 'read-only-task', 'data-task': attr('task') ?? '' }, children)
  }
  const tone = attr('tone')
  if (frozen.name === 'callout') {
    return Elt.mk('aside', { class: 'callout', ...(tone ? { 'data-tone': tone } : {}) }, children)
  }
  if (frozen.name === 'embed') {
    return embedCard(
      Object.fromEntries(
        ['ref', 'table', 'view'].flatMap(name => {
          const value = attr(name)
          return value === undefined ? [] : [[name, value] as const]
        })
      )
    )
  }
  if (shown.has(frozen.name)) return Elt.create(frozen.name, [], children)
  return Elt.mk(
    inline ? 'span' : 'div',
    { class: 'unknown-element', 'data-name': frozen.name, title: frozen.name },
    children
  )
}

// ---------------------------------------------------------------------------
// Node types

/** `page`. The editor shows an empty page as one empty paragraph with `PagePlaceholder` (SPEC §7.2). */
export const Page = Plot.defineDoc({ blockContent: G.Content })

/** `blockquote`. The core's Blockquote cannot be empty and joins its neighbours. */
export const Blockquote = Plot.define('Blockquote', {
  blockContent: G.Content,
  group: G.Content,
  canBeEmpty: true,
  cursorBarrier: 'empty',
  shape: { element: 'blockquote' }
})

/** `li`. The core's ListItem cannot be empty; `- ` gives `<li />`. */
export const ListItem = Plot.define('ListItem', {
  blockContent: G.Content,
  canBeEmpty: true,
  cursorBarrier: 'empty',
  defining: true,
  shape: { element: 'li' },
  // Pasted HTML: a GitHub task item starts with a checkbox. The tag is read when the parser
  // collects the rules, after Task is defined.
  parseRules: (['done', 'todo'] as const).map(task => ({
    selector: `li.task-list-item:has(> input[type=checkbox]${task === 'done' ? '[checked]' : ''})`,
    precedence: 1,
    get tag(): Plot.Tag<null> {
      return ListItem.withMarks([Task.of(task)])
    }
  }))
})

/** `td`. Data cells come before header cells, so content wrapped in a row becomes a data cell. */
export const DataCell = Plot.define('Cell', {
  blockContent: G.Content,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: 'empty',
  canBeEmpty: true,
  shape: { element: 'td' }
})

/** `th`. */
export const HeaderCell = Plot.define('HeaderCell', {
  blockContent: G.Content,
  group: G.TableCell,
  isolating: true,
  cursorBarrier: 'empty',
  canBeEmpty: true,
  shape: { element: 'th' }
})

/** `tr`. A row may hold no cells, and rows may differ in length. */
export const TableRow = Plot.define('TableRow', {
  blockContent: G.TableCell,
  canBeEmpty: true,
  cursorBarrier: 'empty',
  orientation: 'row',
  role: Node.Role.TableRow,
  shape: { element: 'tr' }
})

/** `table`. May hold no rows. */
export const Table = Plot.define('Table', {
  blockContent: TableRow,
  group: G.Content,
  isolating: true,
  cursorBarrier: 'empty',
  canBeEmpty: true,
  role: Node.Role.Table,
  shape: { structure: Elt.mk('table', [Elt.mk('tbody', [0])]) }
})

/** An unknown element at block level. Read-only; its parameter is the element. */
export const UnknownBlock = Leaf.Type.define<Frozen>('UnknownBlock', {
  group: G.Content,
  selectable: true,
  validate: checkFrozen,
  toText: leaf => frozenText(leaf.param as Frozen),
  shape: { structure: frozen => Elt.mk('div', { class: 'read-only-block' }, [view(frozen, false)]) }
})

/**
 * An inline element that N keeps as an atom: an unknown inline element, a format element with
 * attributes, a `span` with attributes other than `style`, or a link without content. Read-only; it
 * carries the formats, style and link around it as marks.
 */
export const InlineElement = Leaf.Type.define<Frozen>('InlineElement', {
  inline: true,
  selectable: true,
  validate: checkFrozen,
  toText: leaf => frozenText(leaf.param as Frozen),
  shape: { structure: frozen => Elt.mk('span', { class: 'read-only-inline' }, [view(frozen, true)]) }
})

// ---------------------------------------------------------------------------
// Marks

/** `mark` (highlight). */
export const Highlight = Mark.define('Highlight', { rank: 44, shape: { element: 'mark' } })

/** `span style`. One style string per node, as N joins nested styles. */
export const TextStyle = Mark.Type.define<string>('TextStyle', {
  rank: 10,
  validate: 'string',
  shape: { element: 'span', attributes: style => ({ style }) },
  // Pasted HTML keeps no styles, except a change of letter case, which has no text format.
  parseRules: [
    {
      attribute: 'style/text-transform',
      readAttribute: value =>
        /^(lowercase|uppercase|capitalize)$/.test(value) ? `text-transform: ${value};` : parse.Reject
    }
  ]
})

/** `a`. The value holds every attribute of the link, including unknown ones. Only href and title are rendered. */
export const Link = Mark.Type.define<Pairs>('Link', {
  rank: 20,
  inclusive: false,
  validate: value => checkPairs(value, 'href'),
  target: [Leaf.Text, InlineElement, T.Image, T.LineBreak],
  shape: {
    element: 'a',
    attributes: pairs => Object.fromEntries(pairs.filter(([name]) => name === 'href' || name === 'title'))
  },
  // Pasted HTML keeps the link target as written and its title.
  parseRules: [
    {
      selector: 'a[href]',
      readElement: element => {
        const title = element.getAttribute('title')
        return [['href', element.getAttribute('href')!] as const, ...(title ? [['title', title] as const] : [])]
      }
    }
  ]
})

const textBlocks = [T.Paragraph, T.Heading]

const alignments = ['left', 'center', 'right', 'justify'] as const
type Alignment = (typeof alignments)[number]
const alignment = (value: string) => (alignments.includes(value as Alignment) ? (value as Alignment) : parse.Reject)

/** `align` of p, h1–h6, th, td. */
export const Align = Mark.Type.define<Alignment>('Align', {
  target: [...textBlocks, DataCell, HeaderCell],
  keepOnSplit: true,
  keepOnTypeChange: true,
  validate: oneOf(...alignments),
  shape: { attribute: 'data-align', value: 0, readAttribute: alignment },
  // Pasted HTML: `start` is the default alignment, `end` is right.
  parseRules: [{ attribute: 'style/text-align', readAttribute: value => alignment(value === 'end' ? 'right' : value) }]
})

/** `indent` of p, h1–h6. */
export const Indent = Mark.Type.define<number>('Indent', {
  target: textBlocks,
  keepOnSplit: true,
  keepOnTypeChange: true,
  validate: integer(1, 999),
  shape: { attribute: 'data-indent', value: indent => String(indent) }
})

/** `style` of p, h1–h6. Pasted HTML keeps no block styles, so the shape has no parse rule. */
export const BlockStyle = Mark.Type.define<string>('BlockStyle', {
  target: textBlocks,
  keepOnSplit: true,
  keepOnTypeChange: true,
  validate: 'string',
  shape: { attributes: style => ({ style }) }
})

/** `task` of li. A mark, so checking a box changes a mark instead of replacing the item. */
export const Task = Mark.Type.define<'todo' | 'done'>('Task', {
  target: ListItem,
  keepOnSplit: true,
  validate: oneOf('todo', 'done'),
  shape: {
    attributes: task => ({ role: 'checkbox', 'aria-checked': String(task === 'done'), 'data-task': task })
  },
  // The editor's own task items and Google Docs task items carry aria-checked.
  parseRules: [
    {
      attribute: 'aria-checked',
      readAttribute: value => (value === 'true' ? 'done' : value === 'false' ? 'todo' : parse.Reject)
    }
  ]
})

/** `meta` of pre. The language uses the core's CodeBlockLanguage. */
export const CodeMeta = Mark.Type.define<string>('CodeMeta', {
  target: T.CodeBlock,
  keepOnSplit: true,
  validate: 'string',
  shape: { attribute: 'data-meta', value: 0 }
})

/** `title` of img. The alt text uses the core's ImageAlt. */
export const ImageTitle = Mark.Type.define<string>('ImageTitle', {
  target: T.Image,
  validate: 'string',
  shape: { attribute: 'title', value: 0, preferTarget: 'img' }
})

/**
 * The paragraph that an empty page shows, so that the page has a place for the caret (SPEC §7.2).
 * While it is empty, the page reads as empty (§7.3). It has no DOM form, so pasted HTML cannot
 * make it, and a split or a type change does not keep it.
 */
export const PagePlaceholder = Mark.define('PagePlaceholder', { target: T.Paragraph, shape: { attributes: {} } })

/** Text formats in vocabulary order. */
export const formats = {
  strong: T.Strong,
  em: T.Emphasis,
  s: T.Strikethrough,
  u: T.Underline,
  mark: Highlight,
  sub: T.Subscript,
  sup: T.Superscript,
  code: T.Code
} as const

const formatMarks = Object.values(formats)

export const schemaElements: readonly Schema.Element[] = [
  Page,
  T.Paragraph,
  T.Heading,
  Blockquote,
  T.BulletList,
  T.OrderedList,
  ListItem,
  T.CodeBlock,
  T.HorizontalRule,
  Table,
  TableRow,
  DataCell,
  HeaderCell,
  UnknownBlock,
  T.LineBreak,
  T.Image,
  InlineElement,
  ...formatMarks,
  TextStyle,
  Link,
  Align,
  Indent,
  BlockStyle,
  Task,
  T.CodeBlockLanguage,
  CodeMeta,
  T.ColSpan,
  T.RowSpan,
  T.ImageAlt,
  ImageTitle,
  PagePlaceholder,
  Attrs,
  Schema.Override.markTarget(Attrs, target => [target, Blockquote, ListItem, Table, TableRow, DataCell, HeaderCell]),
  ...blocks.flatMap(block => block.schema),
  // The core's lists hold the core's list items; ours hold our list item.
  Schema.Override.plotContent(T.BulletList, ListItem),
  Schema.Override.plotContent(T.OrderedList, ListItem),
  // N gives `br` and `img` only a link, never a format or style.
  ...formatMarks.map(mark => Schema.Override.markTarget(mark, [Leaf.Text, InlineElement])),
  Schema.Override.markTarget(TextStyle, [Leaf.Text, InlineElement])
]

export const schema = Schema.define(schemaElements)

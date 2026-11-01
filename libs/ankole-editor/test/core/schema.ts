import { Plot, Leaf, Node, Mark, Schema } from '../../src/core/doc'
import { Doc, Blockquote, Link, Table, Cell, HeaderCell, BlockCell, BlockHeaderCell } from './types'
import {
  Paragraph,
  Heading,
  CodeBlock,
  CodeBlockLanguage,
  LineBreak,
  OrderedList,
  BulletList,
  ListItem,
  HorizontalRule,
  Image,
  ImageAlt,
  Figure,
  CaptionedFigure,
  Emphasis,
  Strong,
  Code,
  Underline,
  Superscript,
  Subscript,
  Alignment,
  ColSpan,
  RowSpan
} from '../../src/core/types/schema'
import { TableRow } from './types'

export type ContentSpec = Node | string | number | null | readonly ContentSpec[]

export function builder<Param>(from: Leaf<Param>): Leaf<Param>
export function builder<Param>(from: Leaf.Type<Param>): (param: Param) => Leaf
export function builder(from: Plot.Tag): (...children: ContentSpec[]) => Plot
export function builder<Param>(from: Plot.Type<Param>): (param: Param, ...children: ContentSpec[]) => Plot
export function builder<Param>(from: Mark<Param>): (...children: ContentSpec[]) => Plot
export function builder<Param>(from: Mark.Type<Param>): (param: Param, ...children: ContentSpec[]) => Plot
export function builder(from: Schema): (...children: ContentSpec[]) => Plot.Doc
export function builder(from: Mark | Mark.Type | Node.Type | Leaf | Plot.Tag | Schema): any {
  return from instanceof Plot.Tag
    ? (...children: ContentSpec[]) => from.create(collectChildren(children))
    : from instanceof Mark
      ? (...children: ContentSpec[]) => fragment(children, from)
      : from instanceof Plot.Type
        ? (param: any, ...children: ContentSpec[]) => from.of(param).create(collectChildren(children))
        : from instanceof Leaf.Type
          ? (param: any) => from.of(param)
          : from instanceof Leaf
            ? from
            : from instanceof Schema
              ? (...children: ContentSpec[]) => from.doc(collectChildren(children))
              : (value: any, ...children: ContentSpec[]) => fragment(children, (from as any as Mark.Type).of(value))
}

const InlineFragment = Plot.define('Fragment', {
  inline: true,
  shape: { element: 'span' },
  inlineContent: true
})
const BlockFragment = Plot.define('Fragment', {
  shape: { element: 'div' },
  blockContent: Node.Group.All
})

function fragment(children: ContentSpec[], mark: Mark) {
  const chs = collectChildren(children, mark)
  return (chs.length && chs[0]!.isBlock ? BlockFragment : InlineFragment).create(chs)
}

const tagMap = new WeakMap<readonly Node[], { [label: number]: number }>()

function addMark(node: Node, mark?: Mark) {
  return mark ? node.withMarks(mark.addToSet(node.marks)) : node
}

function collectChildren(spec: ContentSpec, mark?: Mark, list: Node[] = []) {
  if (Array.isArray(spec)) {
    for (const elt of spec) collectChildren(elt, mark, list)
  } else if (typeof spec == 'string') {
    if (spec) addMark(Leaf.text(spec), mark).pushTo(list)
  } else if (spec instanceof Plot) {
    if (spec.tag == InlineFragment || spec.tag == BlockFragment) {
      copyTags(spec.content, list, 0)
      for (const ch of spec.content) collectChildren(ch, mark, list)
    } else {
      copyTags(spec.content, list, 1)
      addMark(spec, mark).pushTo(list)
    }
  } else if (spec instanceof Leaf) {
    addMark(spec, mark).pushTo(list)
  } else if (typeof spec == 'number') {
    let tags = tagMap.get(list)
    if (!tags) tagMap.set(list, (tags = Object.create(null)))
    tags![spec] = contentLength(list)
  }
  return list
}

function copyTags(source: readonly Node[], dest: readonly Node[], extraOffset: number) {
  const srcTags = tagMap.get(source)
  if (srcTags) {
    let destTags = tagMap.get(dest)
    if (!destTags) tagMap.set(dest, (destTags = Object.create(null)))
    const off = contentLength(dest) + extraOffset
    for (const id in srcTags) destTags![id] = srcTags[id]! + off
  }
}

function contentLength(nodes: readonly Node[]) {
  return nodes.reduce((l, n) => l + n.length, 0)
}

export function maybeTag(node: Plot, id: number): number | undefined {
  const tags = tagMap.get(node.content)
  return tags && tags[id]
}

export function tag(node: Plot, id: number): number {
  const value = maybeTag(node, id)
  if (value == null) throw new Error(`Undefined tag ${id}`)
  return value
}

export const basicSchema = Schema.define([
  Doc,
  Paragraph,
  Heading,
  CodeBlock,
  CodeBlockLanguage,
  Blockquote,
  Image,
  ImageAlt,
  LineBreak,
  HorizontalRule,
  BulletList,
  OrderedList,
  ListItem,
  Emphasis,
  Strong,
  Link,
  Code,
  Underline,
  Superscript,
  Subscript,
  Alignment
])

export const tableSchema = Schema.define(
  basicSchema.elements.concat([Table, TableRow, Cell, HeaderCell, ColSpan, RowSpan])
)

export const basicBuilders = {
  doc: builder(basicSchema),
  p: builder(Paragraph),
  h1: builder(Heading.of(1)),
  h2: builder(Heading.of(2)),
  h3: builder(Heading.of(3)),
  h4: builder(Heading.of(4)),
  pre: builder(CodeBlock),
  preLang: builder(CodeBlockLanguage),
  img: builder(Image),
  fig: builder(Figure),
  capFig: builder(CaptionedFigure),
  $img: builder(Image.of('test.png')),
  imgAlt: builder(ImageAlt),
  table: builder(Table),
  tr: builder(TableRow),
  td: builder(Cell),
  th: builder(HeaderCell),
  tdB: builder(BlockCell),
  thB: builder(BlockHeaderCell),
  rowspan: builder(RowSpan),
  colspan: builder(ColSpan),
  br: builder(LineBreak),
  blockquote: builder(Blockquote),
  ol: builder(OrderedList.default!),
  olStart: builder(OrderedList),
  ul: builder(BulletList),
  li: builder(ListItem),
  hr: builder(HorizontalRule),
  em: builder(Emphasis),
  strong: builder(Strong),
  code: builder(Code),
  a: builder(Link),
  $a: builder(Link.of('/'))
}

export function eq<T extends { eq: (b: T) => boolean }>(a: T, b: T) {
  return a.eq(b)
}

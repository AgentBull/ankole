import { describe, it } from 'bun:test'
import {
  Command,
  liftEmptyBlock,
  insertLineBreak,
  enter,
  splitTextblock,
  deleteSelection,
  joinBackward,
  joinForward,
  joinListItems,
  deleteBackward,
  deleteForward,
  setTextblockType,
  wrapBlock,
  unwrapBlock,
  toggleList,
  toggleMark
} from '../../src/core/command'
import { Plot, Mark, Leaf, Node, Schema, ChangeSet } from '../../src/core/doc'
import { Paragraph, Heading, Blockquote, BulletList, OrderedList, Emphasis, Strong, Link } from '../../src/core/types'
import { GardState, GardSelection, Transaction } from '../../src/core/state'
import ist from 'ist'
import { basicSchema, basicBuilders, maybeTag, builder, eq } from './schema'

const { p, blockquote, ul, ol, li, pre, br, h1, $img, hr, em, strong } = basicBuilders

function selectionFrom(cx: GardSelection.Context) {
  const { doc } = cx,
    a = maybeTag(doc, 0)
  if (a == null) return GardSelection.atStart(cx)
  if (maybeTag(doc, 2) == null) return GardSelection.range(a, maybeTag(doc, 1))
  const ranges: { from: number; to: number }[] = []
  for (let i = 0; ;) {
    const from = maybeTag(doc, i++)
    if (from == null) return new MultiSel(ranges)
    ranges.push({ from, to: maybeTag(doc, i++) ?? from })
  }
}

function selRange(sel: GardSelection) {
  return `${sel.from}-${sel.to}`
}

class MultiSel extends GardSelection {
  rngs: { from: number; to: number }[]
  constructor(rngs: { from: number; to: number }[]) {
    super(rngs[0]!.from, rngs[0]!.to)
    this.rngs = rngs
  }
  get ranges() {
    return this.rngs
  }
  eq(other: GardSelection) {
    return (
      other instanceof MultiSel &&
      this.ranges.length == other.ranges.length &&
      this.ranges.every((r, i) => r.from == other.ranges[i]!.from && r.to == other.ranges[i]!.to)
    )
  }
  map(changes: ChangeSet) {
    return new MultiSel(
      this.ranges.map(r => {
        const from = changes.mapPos(r.from, 1)
        return { from, to: Math.max(from, changes.mapPos(r.to, -1)) }
      })
    )
  }
}
const multiSel = GardSelection.define<MultiSel, {}>(
  'multi',
  MultiSel,
  () => ({}),
  () => 1 as any
)

function test(doc: Plot.Doc, f: (state: GardState) => Transaction.Spec | false, expect?: Plot.Doc) {
  let state = GardState.create({
    doc,
    selection: cx => selectionFrom(cx),
    config: multiSel
  })
  const result = f(state)
  if (expect) {
    ist(result)
    const tr = state.update(result as Transaction.Spec)
    state = tr.state
    ist(state.doc, expect, eq)
    if (maybeTag(expect, 0) != null) {
      const expectedSel = selectionFrom({ doc: expect, config: state.config })
      ist(selRange(state.selection), selRange(expectedSel))
    }
  } else {
    ist(!result)
  }
}

function fromCmd<T>(command: Command.Pure<T>, param: T): (state: GardState) => Transaction.Spec | false
function fromCmd(command: Command.Pure<null>): (state: GardState) => Transaction.Spec | false
function fromCmd<T>(command: Command.Pure<T>, param?: T) {
  return (state: GardState) => command({ state }, param!)
}

function testSelMarks(
  before: Mark.Set | undefined,
  f: (state: GardState) => Transaction.Spec | false,
  expect: Mark.Set
) {
  let state = GardState.create({
    doc: doc(p()),
    selection: GardSelection.Text.create({ anchor: 1, marks: before })
  })
  const tr = f(state)
  if (tr) state = state.update(tr).state
  ist((state.selection as GardSelection.Text).marks, expect, (a, b) => a == b || (a && b && Mark.sameSet(a, b)))
}

const TextOnly = Plot.define('TextOnly', {
    inlineContent: Leaf.Text,
    shape: { element: 'div' },
    group: Node.Group.Content,
    preserveWhitespace: true
  }),
  to = builder(TextOnly)

const BlockMark = Mark.define('BlockMark', {
    keepOnSplit: false,
    keepOnTypeChange: false,
    target: Node.Group.Content,
    shape: { element: 'mark1' }
  }),
  bp = builder(BlockMark)

const PreservedMark = Mark.define('PreservedMark', {
    keepOnSplit: true,
    keepOnTypeChange: true,
    target: Node.Group.Content,
    shape: { element: 'mark2' }
  }),
  pp = builder(PreservedMark)

const InlineSpan = Plot.define('InlineSpan', {
    inline: true,
    inlineContent: true,
    shape: { element: 'span' }
  }),
  sp = builder(InlineSpan)

const InlineAtom = Plot.define('InlineAtom', {
    inline: true,
    inlineContent: true,
    shape: { element: 'var', atom: true }
  }),
  at = builder(InlineAtom)

const AtomMark = Mark.define('AtomMark', {
    target: [{ and: [Node.Group.Inline, Node.Group.Leaf] }, InlineAtom],
    shape: { element: 'atom-mark' }
  }),
  ap = builder(AtomMark)

const schema = Schema.define([
  ...basicSchema.nodes,
  ...basicSchema.marks,
  TextOnly,
  BlockMark,
  PreservedMark,
  InlineSpan,
  InlineAtom,
  AtomMark
])
const doc = builder(schema)

describe('liftEmptyBlock', () => {
  it('can lift a paragraph out of a quote', () => {
    test(doc(blockquote(p(0))), liftEmptyBlock, doc(p(0)))
  })

  it('can leave sibling nodes in parent', () => {
    test(doc(blockquote(p('a'), p(0), p('b'))), liftEmptyBlock, doc(blockquote(p('a')), p(0), blockquote(p('b'))))
  })

  it('can lift out of multiple parents', () => {
    test(doc(ul(li(p(0)))), liftEmptyBlock, doc(p(0)))
  })

  it('can lift out of multiple parents and leave siblings', () => {
    test(doc(ul(li(p('a')), li(p(0)), li(p('b')))), liftEmptyBlock, doc(ul(li(p('a'))), p(0), ul(li(p('b')))))
  })

  it('can close asymmetric parents', () => {
    test(doc(ul(li(p('a')), li(p(0), p('b')))), liftEmptyBlock, doc(ul(li(p('a'))), p(0), ul(li(p('b')))))
  })

  it('returns false when unable to lift', () => {
    test(doc(p(0)), liftEmptyBlock)
  })

  it('only goes up to the next parent that fits', () => {
    test(doc(blockquote(blockquote(p(0), p('a')))), liftEmptyBlock, doc(blockquote(p(0), blockquote(p('a')))))
  })

  it('preserves marks on nodes it splits', () => {
    test(
      doc(pp(blockquote(p('a'), p(0), p('b')))),
      liftEmptyBlock,
      doc(pp(blockquote(p('a'))), p(0), pp(blockquote(p('b'))))
    )
  })

  it('can drop marks on nodes it splits', () => {
    test(
      doc(bp(blockquote(p('a'), p(0), p('b')))),
      liftEmptyBlock,
      doc(bp(blockquote(p('a'))), p(0), blockquote(p('b')))
    )
  })

  it('can lift blocks with an inline node', () => {
    test(doc(blockquote(p(sp(0)))), liftEmptyBlock, doc(p(sp(0))))
  })
})

describe('insertLineBreak', () => {
  const insert = fromCmd(insertLineBreak, null)

  it('inserts a line break node in a regular paragraph', () => {
    test(doc(p('hi', 0)), insert, doc(p('hi', br, 0)))
  })

  it('adds a line break when in a code block', () => {
    test(doc(pre('hi', 0)), insert, doc(pre('hi', br, 0)))
  })

  it('can overwrite text', () => {
    test(doc(pre('a', 0, 'b', 1, 'c')), insert, doc(pre('a', br, 0, 'c')))
  })

  it('applies marks', () => {
    test(doc(p(strong('a', 0, 'b'))), insert, doc(p(strong('a', br, 0, 'b'))))
  })

  it('uses a newline when no line break characters allowed', () => {
    test(doc(to('a', 0, 'b')), insert, doc(to('a\n', 0, 'b')))
  })

  it("doesn't create a newline when the selection crosses out of the block", () => {
    test(doc(to(0), p('a'), to(1)), insert)
  })
})

describe('splitTextblock', () => {
  it('can split a paragraph', () => {
    test(doc(p('a', 0, 'b')), splitTextblock, doc(p('a'), p(0, 'b')))
  })

  it('can split when selection spans paragraphs', () => {
    test(doc(p('a', 0, 'b'), p('c', 1, 'd')), splitTextblock, doc(p('a'), p(0, 'd')))
  })

  it('can split when selection ends at a higher depth', () => {
    test(
      doc(p('a', 0, 'b'), blockquote(p('c', 1, 'd'), p('e'))),
      splitTextblock,
      doc(p('a'), p(0, 'd'), blockquote(p('e')))
    )
  })

  it('can split when selection ends at a lower depth', () => {
    test(doc(blockquote(p(0)), p(1, 'a'), p('b')), splitTextblock, doc(blockquote(p(), p(0, 'a')), p('b')))
  })

  it('keeps tag when splitting in the middle', () => {
    test(doc(h1('a', 0, 'b')), splitTextblock, doc(h1('a'), h1(0, 'b')))
  })

  it('picks the default block when splitting at the end', () => {
    test(doc(h1('a', 0)), splitTextblock, doc(h1('a'), p(0)))
  })

  it('resets the origin block when splitting at the start', () => {
    test(doc(h1(0, 'a')), splitTextblock, doc(p(), h1(0, 'a')))
  })

  it('preserves marks', () => {
    test(doc(pp(p('a', 0, 'b'))), splitTextblock, doc(pp(p('a')), pp(p(0, 'b'))))
  })

  it('drops marks when appropriate', () => {
    test(doc(bp(p('a', 0, 'b'))), splitTextblock, doc(bp(p('a')), p(0, 'b')))
  })

  it('can split inline nodes around the cursor', () => {
    test(doc(p('a', sp('b', 0, 'c'), 'd')), splitTextblock, doc(p('a', sp('b')), p(sp(0, 'c'), 'd')))
  })
})

describe('enter', () => {
  const runEnter = fromCmd(enter, null)

  it('inserts a paragraph node', () => {
    test(doc(p('a'), 0, p('b')), runEnter, doc(p('a'), p(0), p('b')))
  })

  it('can create wrapper nodes', () => {
    test(doc(ul(li(p('a')), 0, li(p('b')))), runEnter, doc(ul(li(p('a')), li(p(0)), li(p('b')))))
  })

  it('can overwrite a selection', () => {
    test(doc(0, pre('a'), p('b'), 1), runEnter, doc(p(0)))
  })
})

describe('deleteSelection', () => {
  it('can delete an inline selection', () => {
    test(doc(p('one', 0, 'two', 1, 'three')), deleteSelection, doc(p('one', 0, 'three')))
  })

  it('can join two paragraphs', () => {
    test(doc(p('a', 0, 'b'), p('c', 1, 'd')), deleteSelection, doc(p('a', 0, 'd')))
  })

  it('can delete across blocks', () => {
    test(doc(p('a', 0), blockquote(p(1, 'b'), p('c'))), deleteSelection, doc(p('a', 0, 'b'), blockquote(p('c'))))
  })

  it('can delete leaving a block', () => {
    test(
      doc(blockquote(p('a'), p(0)), p('b', 1, 'c'), p('d')),
      deleteSelection,
      doc(blockquote(p('a'), p(0, 'c')), p('d'))
    )
  })

  it('keeps the start block type', () => {
    test(doc(h1('a', 0), pre(1, 'b')), deleteSelection, doc(h1('a', 0, 'b')))
  })

  it('expands the deleted range', () => {
    test(doc(blockquote(p(0, 'a'), p('b', 1)), p('b')), deleteSelection, doc(p(0, 'b')))
  })

  it('can join two lists', () => {
    test(doc(ul(li(p('a'))), 0, p('-'), 1, ul(li(p('b')))), deleteSelection, doc(ul(li(p('a')), li(p('b')))))
  })
})

describe('joinBackward', () => {
  it('can join two paragraphs', () => {
    test(doc(p('a'), p(0, 'b')), joinBackward, doc(p('a', 0, 'b')))
  })

  it('can join when the start is deeper than the end', () => {
    test(doc(blockquote(p('a')), p(0, 'b')), joinBackward, doc(blockquote(p('a', 0, 'b'))))
  })

  it('can join when the start is much deeper than the end', () => {
    test(doc(ul(li(blockquote(p('a')))), p(0, 'b')), joinBackward, doc(ul(li(blockquote(p('a', 0, 'b'))))))
  })

  it('can drop extra tokens after the end', () => {
    test(doc(ul(li(p('a'))), blockquote(p(0, 'b'))), joinBackward, doc(ul(li(p('a', 0, 'b')))))
  })

  it('can join when the end is deeper than the start', () => {
    test(doc(p('a'), blockquote(p(0, 'b'))), joinBackward, doc(p('a', 0, 'b')))
  })

  it('can join when the end is much deeper than the start', () => {
    test(doc(p('a'), ul(li(blockquote(p(0, 'b'))))), joinBackward, doc(p('a', 0, 'b')))
  })

  it('does nothing when not at the start of a textblock', () => {
    test(doc(p('a'), p('b', 0)), joinBackward)
  })

  it("drops the type of the first block if it's empty", () => {
    test(doc(h1(), p(0, 'a')), joinBackward, doc(p(0, 'a')))
  })

  it('joins parent nodes after', () => {
    test(doc(ul(li(p('a'))), p(0, 'b'), ul(li(p('c')))), joinBackward, doc(ul(li(p('a', 0, 'b')), li(p('c')))))
  })

  it('drops nodes not supported by the new parent', () => {
    test(doc(to('a'), p(0, $img)), joinBackward, doc(to('a', 0)))
  })

  it('can join from inside an inline node', () => {
    test(doc(p('a'), p(sp(0, 'b'))), joinBackward, doc(p('a', sp(0, 'b'))))
  })
})

describe('joinListItems', () => {
  it('joins list items', () => {
    test(doc(ul(li(p('a')), li(p(0, 'b')))), joinListItems, doc(ul(li(p('a'), p(0, 'b')))))
  })

  it("doesn't join when not at the start of the item", () => {
    test(doc(ul(li(p('a')), li(p('b', 0, 'c')))), joinListItems)
    test(doc(ul(li(p('a')), li(p('b'), p(0, 'c')))), joinListItems)
  })

  it("doesn't try to join the first item", () => {
    test(doc(ul(li(p('a'))), ul(li(p(0, 'b')))), joinListItems)
  })

  it("doesn't join non-list items", () => {
    test(doc(blockquote(blockquote(p('a')), blockquote(p(0, 'b')))), joinListItems)
  })
})

describe('joinForward', () => {
  it('can join two paragraphs', () => {
    test(doc(p('a', 0), p('b')), joinForward, doc(p('a', 0, 'b')))
  })

  it('can join when the start is deeper than the end', () => {
    test(doc(blockquote(p('a', 0)), p('b')), joinForward, doc(blockquote(p('a', 0, 'b'))))
  })

  it('can join when the start is much deeper than the end', () => {
    test(doc(ul(li(blockquote(p('a', 0)))), p('b')), joinForward, doc(ul(li(blockquote(p('a', 0, 'b'))))))
  })

  it('can drop extra tokens after the end', () => {
    test(doc(ul(li(p('a', 0))), blockquote(p('b'))), joinForward, doc(ul(li(p('a', 0, 'b')))))
  })

  it('can join when the end is deeper than the start', () => {
    test(doc(p('a', 0), blockquote(p('b'))), joinForward, doc(p('a', 0, 'b')))
  })

  it('can join when the end is much deeper than the start', () => {
    test(doc(p('a', 0), ul(li(blockquote(p('b'))))), joinForward, doc(p('a', 0, 'b')))
  })

  it('does nothing when not at the end of a textblock', () => {
    test(doc(p(0, 'a'), p('b')), joinForward)
  })

  it("drops the type of the first block if it's empty", () => {
    test(doc(h1(0), p('a')), joinForward, doc(p(0, 'a')))
  })

  it('joins parent nodes after', () => {
    test(doc(ul(li(p('a', 0))), p('b'), ul(li(p('c')))), joinForward, doc(ul(li(p('a', 0, 'b')), li(p('c')))))
  })

  it('drops nodes not supported by the new parent', () => {
    test(doc(to('a', 0), p($img)), joinForward, doc(to('a', 0)))
  })

  it('can join from the end of an inline node', () => {
    test(doc(p(sp('a', 0)), p('b')), joinForward, doc(p(sp('a', 0), 'b')))
  })

  it('can pull a block out of a multi-block list item', () => {
    test(
      doc(p('a', 0), ul(li(p('b'), p('c')), li(p('d')))),
      joinForward,
      doc(p('a', 0, 'b'), ul(li(p('c')), li(p('d'))))
    )
  })
})

describe('deleteBackward', () => {
  it('can delete a letter', () => {
    test(doc(p('abc', 0)), deleteBackward, doc(p('ab', 0)))
  })

  it('can delete a composite letter', () => {
    test(doc(p('👨‍🎤👨‍🎤', 0, '!')), deleteBackward, doc(p('👨‍🎤', 0, '!')))
  })

  it('deletes the last mark of a letter with combining marks', () => {
    test(doc(p('พี่', 0)), deleteBackward, doc(p('พี', 0)))
    test(doc(p('xe\u0301', 0)), deleteBackward, doc(p('xe', 0)))
  })

  it('deletes an emoji with a variation selector as a whole', () => {
    test(doc(p('a❤️', 0)), deleteBackward, doc(p('a', 0)))
  })

  it('can delete an image', () => {
    test(doc(p('a', $img, 0, 'b')), deleteBackward, doc(p('a', 0, 'b')))
  })

  it('can delete a horizontal rule', () => {
    test(doc(hr, 0, p('x')), deleteBackward, doc(0, p('x')))
  })

  it('can delete a horizontal rule from inside the next node', () => {
    test(doc(hr, p(0, 'x')), deleteBackward, doc(p(0, 'x')))
  })

  it('can delete a horizontal rule inside a wrapping node', () => {
    test(doc(ul(li(hr)), p(0, 'x')), deleteBackward, doc(p(0, 'x')))
  })

  it("won't clear wrappers with extra content", () => {
    test(doc(ul(li(p('a')), li(hr)), p(0, 'x')), deleteBackward, doc(ul(li(p('a'))), p(0, 'x')))
  })

  it('will not clear the document', () => {
    test(doc(hr, 0), deleteBackward)
  })

  it('can delete an empty inline plot', () => {
    test(doc(p(sp(), 0, 'x')), deleteBackward, doc(p(0, 'x')))
  })

  const delWord = (state: GardState) => deleteBackward(state, true)

  it('can delete a word', () => {
    test(doc(p('one two', 0)), delWord, doc(p('one ', 0)))
  })

  it('includes whitespace after a word', () => {
    test(doc(p('one two  ', 0)), delWord, doc(p('one ', 0)))
  })

  it('can delete single-character words', () => {
    test(doc(p('one t', 0)), delWord, doc(p('one ', 0)))
  })

  it('can delete groups of punctuation', () => {
    test(doc(p(' /// ', 0)), delWord, doc(p(' ', 0)))
  })

  it('stops on punctuation in a word', () => {
    test(doc(p('space-ship', 0, ' fuel')), delWord, doc(p('space-', 0, ' fuel')))
  })
})

describe('deleteForward', () => {
  it('can delete a letter', () => {
    test(doc(p(0, 'abc')), deleteForward, doc(p(0, 'bc')))
  })

  it('can delete a letter in the middle of a text node', () => {
    test(doc(p('a', 0, 'bc')), deleteForward, doc(p('a', 0, 'c')))
  })

  it('can delete a composite letter', () => {
    test(doc(p('..', 0, '👨‍🎤👨‍🎤')), deleteForward, doc(p('..', 0, '👨‍🎤')))
  })

  it('can delete an image', () => {
    test(doc(p('a', 0, $img, 'b')), deleteForward, doc(p('a', 0, 'b')))
  })

  it('can delete a horizontal rule', () => {
    test(doc(p('x'), 0, hr), deleteForward, doc(p('x'), 0))
  })

  it('can delete a horizontal rule from inside the next node', () => {
    test(doc(p('x', 0), hr), deleteForward, doc(p('x', 0)))
  })

  it('can delete a horizontal rule inside a wrapping node', () => {
    test(doc(p(0), ul(li(hr))), deleteForward, doc(p(0)))
  })

  it("won't clear wrappers with extra content", () => {
    test(doc(p('x', 0), ul(li(hr), li(p('a')))), deleteForward, doc(p('x', 0), ul(li(p('a')))))
  })

  it('will not clear the document', () => {
    test(doc(0, hr), deleteForward)
  })

  it('can delete an empty inline plot', () => {
    test(doc(p(0, sp())), deleteForward, doc(p(0)))
  })

  const delWord = (state: GardState) => deleteForward(state, true)

  it('can delete a word', () => {
    test(doc(p('one ', 0, 'two')), delWord, doc(p('one ', 0)))
  })

  it('includes whitespace before a word', () => {
    test(doc(p('one', 0, ' two.')), delWord, doc(p('one', 0, '.')))
  })

  it('can delete single-character words', () => {
    test(doc(p(0, 'o k')), delWord, doc(p(0, ' k')))
  })

  it('can delete groups of punctuation', () => {
    test(doc(p(0, ' /// ')), delWord, doc(p(0, ' ')))
  })

  it('stops on punctuation in a word', () => {
    test(doc(p(0, 'space-ship')), delWord, doc(p(0, '-ship')))
  })
})

describe('setTextblockType', () => {
  it('can change the type of a paragraph', () => {
    test(doc(p('a', 0), p('b')), fromCmd(setTextblockType, Heading.of(1)), doc(h1('a', 0), p('b')))
  })

  it('can change the type of two paragraphs', () => {
    test(doc(p(0, 'a'), p('b', 1)), fromCmd(setTextblockType, Heading.of(1)), doc(h1(0, 'a'), h1('b', 1)))
  })

  it('can change the type of two paragraphs at different depth', () => {
    test(
      doc(p(0, 'a'), blockquote(p('b', 1))),
      fromCmd(setTextblockType, Heading.of(1)),
      doc(h1(0, 'a'), blockquote(h1('b', 1)))
    )
  })

  it('returns false at the top level', () => {
    const s = Schema.define([Plot.defineDoc({ inlineContent: true }), Paragraph])
    test(s.doc([]), fromCmd(setTextblockType, Paragraph))
  })

  it('returns false when the node is already of that type', () => {
    test(doc(p(0)), fromCmd(setTextblockType, Paragraph))
  })

  it('works on multiple selections', () => {
    test(
      doc(h1(0, 'h'), p('a', 1), blockquote(p('b'), pre('c', 2)), pre('d', 4)),
      fromCmd(setTextblockType, Paragraph),
      doc(p(0, 'h'), p('a', 1), blockquote(p('b'), p('c', 2)), p('d', 4))
    )
  })

  it('clears disallowed content', () => {
    test(doc(p('a', 0, $img)), fromCmd(setTextblockType, TextOnly), doc(to('a', 0)))
  })

  it('preserves marks when appropriate', () => {
    test(doc(pp(p(0, 'a')), p('b', 1)), fromCmd(setTextblockType, Heading.of(1)), doc(pp(h1(0, 'a')), h1('b', 1)))
  })

  it('drops marks when appropriate', () => {
    test(doc(bp(p(0, 'a'))), fromCmd(setTextblockType, Heading.of(1)), doc(h1(0, 'a')))
  })
})

describe('wrapBlock', () => {
  it('can wrap a paragraph in a blockquote', () => {
    test(doc(p(0)), fromCmd(wrapBlock, Blockquote), doc(blockquote(p(0))))
  })

  it('can wrap two paragraphs in a blockquote', () => {
    test(doc(p(0), p(1)), fromCmd(wrapBlock, Blockquote), doc(blockquote(p(0), p(1))))
  })

  it('can wrap three paragraphs in a blockquote', () => {
    test(doc(p(0), p('wow'), p(1)), fromCmd(wrapBlock, Blockquote), doc(blockquote(p(0), p('wow'), p(1))))
  })

  it('can content inside a blockquote', () => {
    test(
      doc(blockquote(p('a'), p(0), p('b'))),
      fromCmd(wrapBlock, Blockquote),
      doc(blockquote(p('a'), blockquote(p(0)), p('b')))
    )
  })

  it('will expand to cover a partially selected node', () => {
    test(
      doc(p(0), blockquote(p(1), p('a'))),
      fromCmd(wrapBlock, Blockquote),
      doc(blockquote(p(0), blockquote(p(1), p('a'))))
    )
  })

  it('will create required wrapper nodes', () => {
    test(
      doc(p('a', 0), p('b'), p('c', 1), p('d')),
      fromCmd(wrapBlock, BulletList),
      doc(ul(li(p('a', 0)), li(p('b')), li(p('c', 1))), p('d'))
    )
  })

  it('will pick the innermost valid depth', () => {
    test(doc(blockquote(p('a', 0))), fromCmd(wrapBlock, BulletList), doc(blockquote(ul(li(p('a', 0))))))
  })

  it('will join to adjacent auto-join node', () => {
    test(
      doc(blockquote(p('a')), p('b', 0), blockquote(p('c'))),
      fromCmd(wrapBlock, Blockquote),
      doc(blockquote(p('a'), p('b'), p('c')))
    )
  })
})

describe('unwrapBlock', () => {
  it('can unwrap a quote', () => {
    test(doc(blockquote(p('a', 0))), fromCmd(unwrapBlock), doc(p('a', 0)))
  })

  it('can unwrap multiple children from a quote', () => {
    test(doc(blockquote(p('a', 0), p('b', 1))), fromCmd(unwrapBlock), doc(p('a', 0), p('b', 1)))
  })

  it('can partially unwrap quote with content left at end', () => {
    test(doc(blockquote(p('a', 0), p('b'))), fromCmd(unwrapBlock), doc(p('a', 0), blockquote(p('b'))))
  })

  it('can partially unwrap quote with content left at start', () => {
    test(doc(blockquote(p('a'), p('b', 0))), fromCmd(unwrapBlock), doc(blockquote(p('a')), p('b', 0)))
  })

  it('can partially unwrap quote with content left at both sides', () => {
    test(
      doc(blockquote(p('a'), p('b', 0), p('c'))),
      fromCmd(unwrapBlock),
      doc(blockquote(p('a')), p('b', 0), blockquote(p('c')))
    )
  })

  it('can unwrap a list', () => {
    test(doc(ul(li(p('a', 0)), li(p('b', 1)))), fromCmd(unwrapBlock), doc(p('a', 0), p('b', 1)))
  })

  it('can partially unwrap a list', () => {
    test(
      doc(ul(li(p('a')), li(p('b', 0)), li(p('c')))),
      fromCmd(unwrapBlock),
      doc(ul(li(p('a'))), p('b', 0), ul(li(p('c'))))
    )
  })

  it('can partially unwrap nested content at start', () => {
    test(
      doc(ul(li(p('a')), li(blockquote(p('b', 0))))),
      fromCmd(unwrapBlock, BulletList),
      doc(ul(li(p('a'))), blockquote(p('b', 0)))
    )
  })

  it('can partially unwrap nested content at end', () => {
    test(
      doc(ul(li(blockquote(p('a', 0))), li(p('b')))),
      fromCmd(unwrapBlock, BulletList),
      doc(blockquote(p('a', 0)), ul(li(p('b'))))
    )
  })

  it('can unwrap children from multiple parents', () => {
    test(
      doc(ul(li(p('a'), p('b', 0))), ul(li(p('c', 1), p('d')))),
      fromCmd(unwrapBlock),
      doc(ul(li(p('a'))), p('b', 0), p('c', 1), ul(li(p('d'))))
    )
  })

  it('returns null at the top level', () => {
    test(doc(p('a', 0)), fromCmd(unwrapBlock))
  })

  it('can unwrap textblock list items', () => {
    const item = Plot.define('Item', { shape: { element: 'li' }, inlineContent: true })
    const list = Plot.define('List', { shape: { element: 'ul' }, group: Node.Group.Content, blockContent: item })
    const s = Schema.define([...basicSchema.nodes, list, item])
    const state = GardState.create({
      doc: s.doc([list.create([item.create([Leaf.text('a')]), item.create([Leaf.text('b')])])]),
      selection: { anchor: 0, head: 8 }
    })
    const tr = unwrapBlock({ state }, list)
    ist(tr)
    if (tr) ist(state.update(tr).state.doc, s.doc([p('a'), p('b')]), eq)
  })

  it('will auto-join unwrapped nodes', () => {
    test(doc(ul(li(p('a'))), blockquote(ul(li(p(0, 'b'))))), fromCmd(unwrapBlock), doc(ul(li(p('a')), li(p(0, 'b')))))
  })
})

describe('toggleList', () => {
  const toggleUL = fromCmd(toggleList, BulletList),
    toggleOL = fromCmd(toggleList, OrderedList.default!)

  it('can add a list to a single block', () => {
    test(doc(p('a', 0)), toggleUL, doc(ul(li(p('a', 0)))))
  })

  it('can add a list to two blocks', () => {
    test(doc(p('a', 0), p('b', 1)), toggleOL, doc(ol(li(p('a', 0)), li(p('b', 1)))))
  })

  it('can remove a list', () => {
    test(doc(ol(li(p(0)))), toggleOL, doc(p(0)))
  })

  it('can remove only some items from a list', () => {
    test(
      doc(ul(li(p('a')), li(p(0, 'b')), li(p('c', 1)), li(p('d')))),
      toggleUL,
      doc(ul(li(p('a'))), p(0, 'b'), p('c', 1), ul(li(p('d'))))
    )
  })

  it('adds lists when it can', () => {
    test(doc(ol(li(p(0))), p(1)), toggleOL, doc(ol(li(p(0)), li(p(1)))))
  })

  it('joins newly created lists to those above and below', () => {
    test(doc(ul(li(p('a'))), p('b', 0), ul(li(p('c')))), toggleUL, doc(ul(li(p('a')), li(p('b', 0)), li(p('c')))))
  })

  it('joins changed lists to those above and below', () => {
    test(
      doc(ul(li(p('a'))), ol(li(p('b', 0))), ul(li(p('c')))),
      toggleUL,
      doc(ul(li(p('a')), li(p('b', 0)), li(p('c'))))
    )
  })

  it("can change a list's type", () => {
    test(doc(ul(li(p(0)))), toggleOL, doc(ol(li(p(0)))))
  })

  it('can change the type of two adjacent lists', () => {
    test(doc(ul(li(p(0))), ul(li(p(1)))), toggleOL, doc(ol(li(p(0)), li(p(1)))))
  })

  it("can change a list's type and wrap items before and after", () => {
    test(doc(p(0), ul(li(p())), p(1)), toggleOL, doc(ol(li(p(0)), li(p()), li(p(1)))))
  })

  it('can handle multiple cursors in a single block', () => {
    test(doc(p(0, 'a', 2, 'b', 4)), toggleOL, doc(ol(li(p(0, 'a', 2, 'b', 4)))))
  })

  it('can unwrap a wrapper block', () => {
    test(doc(ul(li(blockquote(p(0, 'a'), p('b', 1))))), toggleUL, doc(blockquote(p(0, 'a'), p('b', 1))))
  })

  it('can unwrap a nested item', () => {
    test(doc(ul(li(p('a'), ul(li(p('b', 0)))))), toggleUL, doc(ul(li(p('a'), p('b', 0)))))
  })

  it('can wrap a nested item', () => {
    test(doc(ul(li(p('a'), p('b', 0)))), toggleUL, doc(ul(li(p('a'), ul(li(p('b', 0)))))))
  })

  it('can unwrap an item with multiple children', () => {
    test(doc(ul(li(p('a', 0), p('b')))), toggleUL, doc(p('a', 0), p('b')))
  })

  describe('with textblock items', () => {
    const InlineListItem = Plot.define('ListItem', {
      inlineContent: true,
      shape: { element: 'li' }
    })
    const InlineOrderedList = Plot.define('OrderedList', {
      blockContent: InlineListItem,
      shape: { element: 'ol' },
      role: Node.Role.List
    })
    const InlineBulletList = Plot.define('BulletList', {
      blockContent: InlineListItem,
      shape: { element: 'ul' },
      role: Node.Role.List
    })
    const InlineListSchema = Schema.define([
      Plot.defineDoc({ blockContent: [Paragraph, InlineOrderedList, InlineBulletList] }),
      Paragraph,
      InlineListItem,
      InlineOrderedList,
      InlineBulletList
    ])
    const toggleUL = fromCmd(toggleList, InlineBulletList),
      toggleOL = fromCmd(toggleList, InlineOrderedList)
    const doc = builder(InlineListSchema)
    const ul = builder(InlineBulletList),
      ol = builder(InlineOrderedList),
      li = builder(InlineListItem)

    it('can wrap lists', () => {
      test(doc(p('a', 0)), toggleUL, doc(ul(li('a', 0))))
    })

    it('can unwrap lists', () => {
      test(doc(ol(li('a', 0))), toggleOL, doc(p('a', 0)))
    })

    it('can add a list to two blocks', () => {
      test(doc(p('a', 0), p('b', 1)), toggleOL, doc(ol(li('a', 0), li('b', 1))))
    })

    it('can remove only some items from a list', () => {
      test(
        doc(ul(li('a'), li(0, 'b'), li('c', 1), li('d'))),
        toggleUL,
        doc(ul(li('a')), p(0, 'b'), p('c', 1), ul(li('d')))
      )
    })

    it('adds lists when it can', () => {
      test(doc(ol(li(0)), p(1)), toggleOL, doc(ol(li(0), li(1))))
    })

    it('joins newly created lists to those above and below', () => {
      test(doc(ul(li('a')), p('b', 0), ul(li('c'))), toggleUL, doc(ul(li('a'), li('b', 0), li('c'))))
    })

    it('joins changed lists to those above and below', () => {
      test(doc(ul(li('a')), ol(li('b', 0)), ul(li('c'))), toggleUL, doc(ul(li('a'), li('b', 0), li('c'))))
    })

    it("can change a list's type", () => {
      test(doc(ul(li(0))), toggleOL, doc(ol(li(0))))
    })

    it('can change the type of two adjacent lists', () => {
      test(doc(ul(li(0)), ul(li(1))), toggleOL, doc(ol(li(0), li(1))))
    })

    it("can change a list's type and wrap items before and after", () => {
      test(doc(p(0), ul(li()), p(1)), toggleOL, doc(ol(li(0), li(), li(1))))
    })

    it('can handle multiple cursors in a single block', () => {
      test(doc(p(0, 'a', 2, 'b', 4)), toggleOL, doc(ol(li(0, 'a', 2, 'b', 4))))
    })
  })
})

describe('toggleMark', () => {
  const emp = fromCmd(toggleMark, Emphasis)

  it('can add emphasis to a selection', () => {
    test(doc(p('a', 0, 'bc', 1, 'd')), emp, doc(p('a', 0, em('bc'), 1, 'd')))
  })

  it('can remove emphasis from a selection', () => {
    test(doc(p('a', 0, em('bc'), 1, 'd')), emp, doc(p('a', 0, 'bc', 1, 'd')))
  })

  it('adds emphasis to a mixed-mark selection', () => {
    test(doc(p('a', 0, em('bc'), 'd', 1)), emp, doc(p('a', 0, em('bcd'), 1)))
  })

  it('stacks added marks with others', () => {
    test(doc(p('a', 0, strong(em('bc')), 'd', 1)), emp, doc(p('a', 0, em(strong('bc'), 'd'), 1)))
  })

  it('adds selection marks', () => {
    testSelMarks(undefined, emp, [Emphasis])
  })

  it('adds selection marks to existing set', () => {
    testSelMarks([Strong], emp, [Emphasis, Strong])
  })

  it('removes selection marks', () => {
    testSelMarks([Emphasis], emp, [])
  })

  it('replaces marks of the same type', () => {
    testSelMarks([Link.of('/')], fromCmd(toggleMark, Link.of('#')), [Link.of('#')])
  })

  it("doesn't add the same mark on multiple levels", () => {
    test(doc(p(0, sp('abc'), 'd', 1)), emp, doc(p(0, sp(em('abc')), em('d'), 1)))
  })

  it('can add a mark inside an inline node', () => {
    test(doc(p(sp('a', 0, 'b', 1, 'c'))), emp, doc(p(sp('a', 0, em('b'), 1, 'c'))))
  })

  it('can add a mark to an inline node that partially has it', () => {
    test(doc(p(0, sp('a', em('b'), 'c'), 1)), emp, doc(p(0, sp(em('abc')), 1)))
  })

  const atom = fromCmd(toggleMark, AtomMark)

  it('will not add to both a parent and a child', () => {
    test(doc(p(0, 'a', at('b'), 1)), atom, doc(p(0, ap('a', at('b')), 1)))
  })

  it('will not remove a mark from inside an inline element that supports it', () => {
    test(doc(p(0, at(ap('b')), 1)), atom, doc(p(0, ap(at(ap('b'))), 1)))
  })
})

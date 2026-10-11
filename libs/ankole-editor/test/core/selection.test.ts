import { describe, it } from 'bun:test'
import ist from 'ist'
import { Schema, Plot, Node, Leaf } from '../../src/core/doc'
import { Table, TableRow, Cell, HeaderCell } from '../../src/core/types'
import { GardSelection, GardState } from '../../src/core/state'
import { basicSchema, basicBuilders, builder, maybeTag } from './schema'
const { p, hr, blockquote, pre, ul, li, $img, table, tr, td, th } = basicBuilders

const Iso = Plot.define('Iso', {
    blockContent: Node.Group.Content,
    group: Node.Group.Content,
    isolating: true,
    shape: { element: 'div' }
  }),
  iso = builder(Iso)
const Inline = Plot.define('Inline', {
    inline: true,
    inlineContent: true,
    shape: { element: 'span' }
  }),
  inl = builder(Inline)

const schema = Schema.define([
  ...basicSchema.nodes,
  ...basicSchema.marks,
  Iso,
  Inline,
  Table,
  TableRow,
  Cell,
  HeaderCell
])
const doc = builder(schema)

function normalPositions(state: GardState) {
  const result: number[] = []
  let ii = 0
  for (let cur = GardSelection.atStart(state); ;) {
    result.push(cur.head)
    const next = cur.nextNormalCursor(state)
    if (next == null) return result
    cur = next
    if (++ii > state.doc.length * 2) throw new Error(`STUCK ${result}`)
  }
}

describe('GardSelection', () => {
  describe('nextNormalCursor', () => {
    function testNormal(doc: Plot.Doc) {
      const state = GardState.create({ doc }),
        forward = normalPositions(state),
        back = []
      const expect = []
      for (let i = 0; ; i++) {
        const next = maybeTag(doc, i)
        if (next == null) break
        expect.push(next)
      }
      for (let cur = GardSelection.atEnd(state); ;) {
        back.push(cur.head)
        const next = cur.nextNormalCursor(state, false)
        if (next == null) break
        cur = next
      }
      ist(forward.join(), expect.join())
      ist(back.join(), expect.slice().reverse().join())

      // Check whether GardSelection.near properly normalizes
      for (let i = 0, j = 0; i < doc.length; i++) {
        const forw = GardSelection.near(state, i, -1).head
        const back = GardSelection.near(state, i, 1).head
        if (j < expect.length && expect[j] == i) {
          // This is a normal pos
          ist(forw, i)
          ist(back, i)
          j++
        } else {
          const prev = expect[Math.max(0, j - 1)],
            next = expect[Math.min(expect.length - 1, j)]
          ist(forw == prev || forw == next)
          ist(back == prev || back == next)
        }
      }
    }

    it('finds inline positions', () => testNormal(doc(p(0, 'o', 1, 'n', 2, 'e', 3))))

    it('allows positions between block leaves', () => testNormal(doc(0, hr, 1, hr, 2)))

    it("doesn't include positions next to textblocks", () => testNormal(doc(0, hr, p(1, 'a', 2), hr, 3)))

    it('returns the bottom-most position between blocks', () =>
      testNormal(doc(0, blockquote(hr), 1, blockquote(hr), 2)))

    it('stops at isolating nodes', () => testNormal(doc(0, iso(1, hr, 2), 3, iso(p(4)), 5)))

    it('allows positions between block atoms', () => testNormal(doc(p(0, '-', 1), hr, 2, hr, 3)))

    it('creates positions around whitespace-preserving nodes', () =>
      testNormal(doc(0, pre(1, 'a', 2), p(3), pre(4), 5)))

    it('handles inline nodes', () => testNormal(doc(p(0, 'a', 1, $img, 2, 'b', 3), p(4, $img, 5))))

    it('skips whole glyphs', () => testNormal(doc(p(0, 'ő', 1, '👨‍🎤', 2, '🇪🇸', 3))))

    it('creates positions inside inline plots', () => testNormal(doc(p(0, 'a', 1, inl(2, 'b', 3, 'c', 4), 5, 'd', 6))))

    it('exits text nodes', () => {
      testNormal(doc(p(0, 'a', 1, 'b', 2, $img, 3, 'c', 4, 'd', 5)))
    })

    it('enters tables', () => {
      testNormal(doc(p(0, 'a', 1), table(tr(td(2, 'b', 3), td(4)), tr(td(5, 'c', 6), th(7, 'd', 8))), 9))
    })

    describe('bidi', () => {
      function test(text: string, ltr: number[], rtl: number[]) {
        it(`moves LTR through ${JSON.stringify(text)}`, () => {
          ist(
            JSON.stringify(normalPositions(GardState.create({ doc: doc(p(text)) })).map(n => n - 1)),
            JSON.stringify(ltr)
          )
        })
        it(`moves RTL through ${JSON.stringify(text)}`, () => {
          const state = GardState.create({ doc: doc(p(text)), config: GardState.textLTR.of(false) })
          ist(JSON.stringify(normalPositions(state).map(n => n - 1)), JSON.stringify(rtl))
        })
      }

      test('الصفصاف', [7, 6, 5, 4, 3, 2, 1, 0], [0, 1, 2, 3, 4, 5, 6, 7])
      test('treeشجرة', [0, 1, 2, 3, 4, 7, 6, 5, 4], [4, 3, 2, 1, 4, 5, 6, 7, 8])
      test('شجرةtree', [4, 3, 2, 1, 4, 5, 6, 7, 8], [0, 1, 2, 3, 4, 7, 6, 5, 4])
      test('aشجرةtree', [0, 1, 4, 3, 2, 5, 6, 7, 8, 9], [1, 1, 2, 3, 4, 5, 8, 7, 6, 5])
      test('رقم415خمسة', [10, 9, 8, 7, 6, 4, 5, 3, 2, 1, 0], [0, 1, 2, 3, 5, 4, 6, 7, 8, 9, 10])
      test('كو,', [2, 1, 2, 3], [0, 1, 2, 3])
      test('  foo  ', [0, 1, 2, 3, 4, 5, 6, 7], [0, 1, 2, 4, 3, 5, 6, 7])
      test('  مرآة  ', [0, 1, 2, 5, 4, 3, 6, 7, 8], [0, 1, 2, 3, 4, 5, 6, 7, 8])
      test('ab12-34%م', [0, 1, 2, 3, 4, 5, 6, 7, 8, 8], [8, 7, 6, 5, 4, 3, 2, 1, 8, 9])
      test('ر12:34ر', [7, 6, 2, 3, 4, 5, 1, 0], [0, 1, 5, 4, 3, 2, 6, 7])
      test(
        'ab مرآة10 cde 20مرآة!',
        [0, 1, 2, 3, 8, 7, 6, 5, 4, 9, 10, 11, 12, 13, 14, 15, 16, 19, 18, 17, 20, 21],
        [2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 14, 13, 12, 11, 16, 17, 18, 19, 20, 21]
      )
      test('(ء)و)', [0, 1, 2, 3, 4, 5], [0, 1, 2, 3, 4, 5])
      test(
        '(([^ء-ي]|^)و)',
        [0, 1, 2, 3, 4, 6, 5, 7, 8, 9, 10, 11, 12, 13],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
      )
      test('ء(و)', [4, 3, 2, 1, 0], [0, 1, 2, 3, 4])
      test('[foo(barء)]', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], [0, 1, 3, 2, 4, 5, 7, 6, 8, 9, 10, 11])
    })
  })

  describe('near', () => {
    it('will skip out of a surrogate pair', () => {
      const s = GardState.create({ doc: doc(p('🐜')) })
      ist(GardSelection.near(s, 2, -1).head, 1)
      ist(GardSelection.near(s, 2, 1).head, 3)
    })

    it('will move to the bottom of a block separation', () => {
      const s = GardState.create({ doc: doc(ul(li(blockquote(hr)), li(blockquote(hr)))) })
      ist(GardSelection.near(s, 4).head, 6)
      ist(GardSelection.near(s, 8).head, 6)
    })

    it('will not exit a cursor-inside inline plot', () => {
      Plot.Doc.noValidate(() => {
        const s = GardState.create({ doc: doc(p('a', inl('b'), 'c')) })
        ist(GardSelection.near(s, 3).head, 3)
        ist(GardSelection.near(s, 4).head, 4)
      })
    })
  })

  describe('map', () => {
    it('keeps the direction of a backward text selection', () => {
      const s = GardState.create({ doc: doc(p('abc'), p('def')), selection: { anchor: 7, head: 2 } })
      const mapped = s.update({}).newSelection
      ist(mapped.anchor, 7)
      ist(mapped.head, 2)
      const changed = s.update({ changes: { from: 1, insert: [Leaf.text('x')] } }).newSelection
      ist(changed.anchor, 8)
      ist(changed.head, 3)
    })
  })

  describe('skipWord', () => {
    function test(name: string, lines: string | string[], positions: number[]) {
      it(name, () => {
        const state = GardState.create({ doc: doc((Array.isArray(lines) ? lines : [lines]).map(line => p(line))) })
        let cur = GardSelection.atStart(state)
        const found = []
        for (;;) {
          const next = cur.skipWord(state, true)
          if (!next) break
          found.push(next.head)
          cur = next
        }
        ist(JSON.stringify(found), JSON.stringify(positions))
      })
    }

    test('can skip words', 'a bbb c', [2, 6, 8])

    test('skips whitespace', '  a      bbb', [4, 13])

    test('skips punctuation', 'a. b??? / c', [2, 5, 12])

    test('can move across blocks', ['abc def', ' efg'], [4, 8, 14])

    test('includes extra positions at end', 'a b ', [2, 4, 5])

    test('is direction-aware', 'a واحد اثنين ثلاثة b', [2, 14, 8, 19, 21])

    test('uses a segmenter', '两只兔子', [2, 3, 5])
  })

  describe('skipWord back', () => {
    function test(name: string, lines: string | string[], positions: number[]) {
      it(name, () => {
        const state = GardState.create({ doc: doc((Array.isArray(lines) ? lines : [lines]).map(line => p(line))) })
        let cur = GardSelection.atEnd(state)
        const found = []
        for (;;) {
          const prev = cur.skipWord(state, false)
          if (!prev) break
          found.push(prev.head)
          cur = prev
        }
        ist(JSON.stringify(found), JSON.stringify(positions))
      })
    }

    test('can skip words', 'a bbb c', [7, 3, 1])

    test('skips whitespace', 'a  bbb ', [4, 1])

    test('skips punctuation', 'a. b??? / c', [11, 4, 1])

    test('can move across blocks', ['abc def ', ' efg'], [12, 5, 1])

    test('includes extra positions at start', ' a b', [4, 2, 1])

    test('is direction-aware', 'a واحد اثنين ثلاثة b', [20, 7, 13, 19, 1])

    test('uses a segmenter', '两只兔子', [3, 2, 1])
  })
})

import { expect, test } from 'bun:test'
import { Leaf } from '../src/core/doc'
import { Decoration, type Wordgard } from '../src/core/editor'
import type { Transaction } from '../src/core/state'
import { printXml } from '../src/document/xml'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { remoteSelections } from '../src/editor/remote-selections'

test.each([
  {
    name: 'remote sessions arrive in reverse document order',
    selections: [
      { anchor: 8, head: 6 },
      { anchor: 1, head: 3 }
    ],
    points: [3, 6],
    ranges: [
      [1, 3],
      [6, 8]
    ]
  },
  {
    name: 'overlapping backward selections have a different order from their carets',
    selections: [
      { anchor: 8, head: 4 },
      { anchor: 1, head: 6 }
    ],
    points: [4, 6],
    ranges: [
      [1, 6],
      [4, 8]
    ]
  },
  {
    name: 'two remote sessions can share a caret position',
    selections: [
      { anchor: 4, head: 4 },
      { anchor: 1, head: 4 }
    ],
    points: [4, 4],
    ranges: [[1, 4]]
  }
])('$name', ({ selections, points, ranges }) => {
  const view = {
    state: headlessState('abcdefghij'),
    dispatch(spec: Transaction.Spec) {
      this.state = this.state.update(spec).state
    }
  }
  const update = remoteSelections(view as unknown as Wordgard)
  const original = view.state.doc
  update(
    selections.map((selection, index) => ({
      id: `peer-${index}`,
      name: `Peer ${index}`,
      color: '#2469a2',
      ...selection
    }))
  )

  const inspect = (): { points: readonly number[]; ranges: readonly (readonly number[])[] } => {
    const actualPoints: number[] = []
    const actualRanges: number[][] = []
    for (const source of view.state.facet(Decoration.Point.source)) {
      for (const cursor = source(view.state).cursor(); cursor.value; cursor.next()) actualPoints.push(cursor.from)
    }
    for (const source of view.state.facet(Decoration.Range.source)) {
      for (const cursor = source(view.state).cursor(); cursor.value; cursor.next()) {
        actualRanges.push([cursor.from, cursor.to])
      }
    }
    return { points: actualPoints, ranges: actualRanges }
  }
  expect(inspect()).toEqual({ points, ranges })
  expect(view.state.doc).toBe(original)
  expect(printXml(readTree(view.state.doc))).toBe('<page><p>abcdefghij</p></page>')

  view.dispatch({ changes: { from: 1, insert: [Leaf.text('X')] } })
  expect(inspect()).toEqual({
    points: points.map(pos => pos + 1),
    ranges: ranges.map(range => range.map(pos => pos + 1))
  })
  update([])
  expect(inspect()).toEqual({ points: [], ranges: [] })
})

test('remoteSelections rejects unsafe peer.color values while accepting standard CSS colors', () => {
  const view = {
    state: headlessState('abcdefghij'),
    dispatch(spec: Transaction.Spec) {
      this.state = this.state.update(spec).state
    }
  }
  const update = remoteSelections(view as unknown as Wordgard)
  update([
    { id: 'bad-1', name: 'Injected', color: '#2469a2;background:url(https://evil.test)', anchor: 1, head: 3 },
    { id: 'bad-2', name: 'URL', color: 'url(https://evil.test)', anchor: 2, head: 4 },
    { id: 'bad-3', name: 'FuncInject', color: 'rgb(0,0,0);position:fixed', anchor: 3, head: 5 },
    { id: 'bad-4', name: 'NestedParen', color: 'rgb(var(--a))', anchor: 4, head: 6 },
    { id: 'bad-5', name: 'Empty', color: '   ', anchor: 1, head: 2 },
    { id: 'ok-hex', name: 'Hex', color: ' #2469a2 ', anchor: 1, head: 3 },
    { id: 'ok-rgb', name: 'RGB', color: 'rgb(36 105 162 / 80%)', anchor: 4, head: 6 },
    { id: 'ok-var', name: 'Var', color: 'var(--chart-2)', anchor: 7, head: 7 }
  ])

  const points: number[] = []
  const ranges: Array<{ from: number; to: number }> = []
  for (const source of view.state.facet(Decoration.Point.source)) {
    for (const cursor = source(view.state).cursor(); cursor.value; cursor.next()) points.push(cursor.from)
  }
  for (const source of view.state.facet(Decoration.Range.source)) {
    for (const cursor = source(view.state).cursor(); cursor.value; cursor.next()) {
      ranges.push({ from: cursor.from, to: cursor.to })
    }
  }
  expect(points).toEqual([3, 6, 7])
  expect(ranges).toEqual([
    { from: 1, to: 3 },
    { from: 4, to: 6 }
  ])
})

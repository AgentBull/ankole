import { describe, it } from 'bun:test'
import ist from 'ist'
import { Leaf } from '../../src/core/doc'
import { GardState, Transaction } from '../../src/core/state'
import { basicBuilders, eq } from './schema'
const { doc, p } = basicBuilders

describe('EditorState', () => {
  it('can be initialized', () => {
    const state = GardState.create({
      doc: doc(p('!')),
      selection: { anchor: 2 }
    })
    ist(state.doc.length, 3)
    ist(state.selection.from, 2)
  })

  describe('update', () => {
    it('can update a state', () => {
      const { state } = GardState.create({
        doc: doc(p('!'))
      }).update({ changes: { from: 1, insert: [Leaf.text('-')] } })
      ist(state.doc, doc(p('-!')), eq)
    })

    function updateMerged(start: GardState.Spec, trs: Transaction.Spec[]) {
      const state = GardState.create(start)
      return state.update(trs.reduce((a, b) => Transaction.merge(state, a, b)))
    }

    it('merges changes from multiple specs', () => {
      const { state } = updateMerged({ doc: doc(p('-')) }, [
        { changes: { from: 2, insert: [Leaf.text('a')] } },
        { changes: { from: 2, insert: [Leaf.text('b')] } }
      ])
      ist(state.doc, doc(p('-ab')), eq)
    })

    it('can combine more than two changes', () => {
      const { state } = updateMerged({ doc: doc(p('abc')) }, [
        { changes: { from: 4, insert: [Leaf.text('d')] } },
        { changes: { from: 2, insert: [Leaf.text('.')] } },
        { changes: { from: 1, to: 3 } }
      ])
      ist(state.doc, doc(p('.cd')), eq)
    })

    it('can combine sequential changes', () => {
      const { state } = updateMerged({ doc: doc(p()) }, [
        { changes: { from: 1, insert: [Leaf.text('ab')] } },
        { changes: { from: 2, insert: [Leaf.text('.')] }, sequential: true }
      ])
      ist(state.doc, doc(p('a.b')), eq)
    })

    it('can have multiple sequential changes', () => {
      const { state } = updateMerged({ doc: doc(p()) }, [
        { changes: { from: 1, insert: [Leaf.text('a')] } },
        { changes: { from: 2, insert: [Leaf.text('b')] }, sequential: true },
        { changes: { from: 3, insert: [Leaf.text('c')] }, sequential: true }
      ])
      ist(state.doc, doc(p('abc')), eq)
    })

    it('can handle regular changes after sequential changes', () => {
      const { state } = updateMerged({ doc: doc(p()) }, [
        { changes: { from: 1, insert: [Leaf.text('a')] } },
        { changes: { from: 2, insert: [Leaf.text('b')] }, sequential: true },
        { changes: { from: 1, insert: [Leaf.text('-')] } }
      ])
      ist(state.doc, doc(p('ab-')), eq)
    })

    it('maps selection forward for sibling changes', () => {
      const { state } = updateMerged({ doc: doc(p('ab')) }, [
        { selection: { anchor: 2 } },
        { changes: { from: 1, insert: [Leaf.text('.')] } }
      ])
      ist(state.selection.head, 3)
    })

    it('maps selection forward in sibling changes', () => {
      const { state } = updateMerged({ doc: doc(p('ab')) }, [
        { changes: { from: 1, insert: [Leaf.text('.')] } },
        { selection: { anchor: 2 } }
      ])
      ist(state.selection.head, 3)
    })

    it('maps selection across sequential change', () => {
      const { state } = updateMerged({ doc: doc(p('ab')) }, [
        { changes: { from: 3, insert: [Leaf.text('c')] }, selection: { anchor: 4 } },
        { changes: { from: 1, to: 2 }, sequential: true }
      ])
      ist(state.doc, doc(p('bc')), eq)
      ist(state.selection.head, 3)
    })

    it("doesn't map selection from a sequential change", () => {
      const { state } = updateMerged({ doc: doc(p('bc')) }, [
        { changes: { from: 1, insert: [Leaf.text('a')] } },
        { changes: { from: 2, to: 3 }, selection: { anchor: 2 }, sequential: true }
      ])
      ist(state.doc, doc(p('ac')), eq)
      ist(state.selection.head, 2)
    })

    const posEffect = Transaction.Effect.define<number>({ map: (val, mapping) => mapping.mapPos(val) })

    it('maps effects for sibling changes', () => {
      const tr = updateMerged({ doc: doc(p('abc')) }, [
        { changes: { from: 1, to: 2 }, effects: posEffect.of(3) },
        { changes: { from: 3, insert: [Leaf.text('-')] }, effects: posEffect.of(5) }
      ])
      ist(tr.effects.map(e => e.value).join(), '4,4')
    })

    it('maps effects for sequential changes', () => {
      const tr = updateMerged({ doc: doc(p('abc')) }, [
        { changes: { from: 1, to: 2 }, effects: posEffect.of(3) },
        { changes: { from: 2, insert: [Leaf.text('-')] }, effects: posEffect.of(4), sequential: true }
      ])
      ist(tr.effects.map(e => e.value).join(), '4,4')
    })
  })
})

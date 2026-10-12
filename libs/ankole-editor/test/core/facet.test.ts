import { describe, it } from 'bun:test'
import ist from 'ist'
import { GardState, Transaction } from '../../src/core/state'
import { Leaf } from '../../src/core/doc'
import { Cell } from './types'
import { basicBuilders, basicSchema } from './schema'

const { doc, p } = basicBuilders

function mk(...extensions: GardState.Extension[]) {
  return GardState.create({ doc: doc(p()), config: extensions })
}

const num = GardState.Facet.define<number>(),
  str = GardState.Facet.define<string>(),
  bool = GardState.Facet.define<boolean>()

describe('EditorState facets', () => {
  it('allows querying of facets', () => {
    const st = mk(num.of(10), num.of(20), str.of('x'), str.of('y'))
    ist(st.facet(num).join(), '10,20')
    ist(st.facet(str).join(), 'x,y')
  })

  it('includes sub-extenders', () => {
    const e = (s: string) => [num.of(s.length), num.of(+s)]
    const st = mk(num.of(5), e('20'), num.of(40), e('100'))
    ist(st.facet(num).join(), '5,2,20,40,3,100')
  })

  it('only includes duplicated extensions once', () => {
    const e = num.of(50)
    const st = mk(num.of(1), e, num.of(4), e)
    ist(st.facet(num).join(), '1,50,4')
  })

  it('returns an empty array for absent facet', () => {
    const st = mk()
    ist(JSON.stringify(st.facet(num)), '[]')
  })

  it('sorts extensions by priority', () => {
    const st = mk(
      str.of('a'),
      str.of('b'),
      GardState.prec.high(str.of('c')),
      GardState.prec.highest(str.of('d')),
      GardState.prec.low(str.of('e')),
      GardState.prec.high(str.of('f')),
      str.of('g')
    )
    ist(st.facet(str).join(), 'd,c,f,a,b,g,e')
  })

  it("lets sub-extensions inherit their parent's priority", () => {
    const e = (n: number) => num.of(n)
    const st = mk(num.of(1), GardState.prec.highest(e(2)), e(4))
    ist(st.facet(num).join(), '2,1,4')
  })

  it('supports dynamic facet inputs', () => {
    const st = mk(
      num.of(1),
      num.compute(() => 88)
    )
    ist(st.facet(num).join(), '1,88')
  })

  it('only recomputes a facet value when necessary', () => {
    const st = mk(
      num.of(1),
      num.compute(s => s.facet(str).join().length),
      str.of('hello')
    )
    const array = st.facet(num)
    ist(array.join(), '1,5')
    ist(st.update({}).state.facet(num), array)
  })

  it("can handle dependencies on facets that aren't present in the state", () => {
    const st = mk(
      num.compute(s => s.facet(str).join().length),
      str.compute(s => s.facet(bool).toString())
    )
    ist(st.update({}).state.facet(num).join(), '0')
  })

  it('can specify a dependency on the document', () => {
    let count = 0
    let st = mk(num.compute(state => (state.doc, count++)))
    ist(st.facet(num).join(), '0')
    st = st.update({ changes: { insert: [Leaf.text('hello')], from: 1 } }).state
    ist(st.facet(num).join(), '1')
    st = st.update({}).state
    ist(st.facet(num).join(), '1')
  })

  it('can specify a dependency on the selection', () => {
    let count = 0
    let st = mk(num.compute(state => (state.selection, count++)))
    ist(st.facet(num).join(), '0')
    st = st.update({ changes: { insert: [Leaf.text('hello')], from: 1 } }).state
    ist(st.facet(num).join(), '1')
    st = st.update({ selection: { anchor: 2 } }).state
    ist(st.facet(num).join(), '2')
    st = st.update({}).state
    ist(st.facet(num).join(), '2')
  })

  it('can specify a dependency on the schema', () => {
    let count = 0
    let st = mk(
      num.compute(state => (state.schema, count++)),
      basicSchema.elements.map(e => GardState.schemaElement.of(e))
    )
    ist(st.facet(num).join(), '0')
    st = st.update({ changes: { insert: [Leaf.text('hello')], from: 1 } }).state
    ist(st.facet(num).join(), '0')
    st = st.update({ effects: GardState.appendConfig.of(GardState.schemaElement.of(Cell)) }).state
    ist(st.facet(num).join(), '1')
  })

  it('derives dependencies of computed facets', () => {
    let ran = 0
    let st = mk(
      num.compute(state => {
        ran++
        return state.doc.length + state.facet(str).length
      })
    )
    st = st.update({ changes: { from: 1, insert: [Leaf.text('---')] } }).state
    ist(st.facet(num)[0], 5)
    ist(ran, 2)
    st = st.update({ selection: { anchor: 2 } }).state
    ist(ran, 2)
    st = st.update({ effects: GardState.appendConfig.of(str.of('1')) }).state
    ist(st.facet(num)[0], 6)
    ist(ran, 3)
  })

  it('only tracks direct, not transitive dependencies', () => {
    let ran = 0
    let st = mk(
      bool.compute(st => st.doc.length > 2),
      str.compute(st => (st.facet(bool)[0] ? 'ok' : 'o')),
      num.compute(st => {
        ran++
        return st.facet(str)[0]!.length
      })
    )
    ist(ran, 1)
    ist(st.facet(num)[0], 1)
    st = st.update({ changes: { from: 1, insert: [Leaf.text('a')] } }).state
    ist(ran, 2)
    ist(st.facet(num)[0], 2)
    st = st.update({ changes: { from: 2, insert: [Leaf.text('b')] } }).state
    ist(ran, 2)
  })

  it('can provide multiple values at once', () => {
    let st = mk(
      num.computeN(s => (s.doc.length % 2 ? [100, 10] : [])),
      num.of(1)
    )
    ist(st.facet(num).join(), '1')
    st = st.update({ changes: { insert: [Leaf.text('hello')], from: 1 } }).state
    ist(st.facet(num).join(), '100,10,1')
  })

  it('works with a static combined facet', () => {
    const f = GardState.Facet.define<number, number>({ combine: ns => ns.reduce((a, b) => a + b, 0) })
    const st = mk(f.of(1), f.of(2), f.of(3))
    ist(st.facet(f), 6)
  })

  it('works with a dynamic combined facet', () => {
    const f = GardState.Facet.define<number, number>({ combine: ns => ns.reduce((a, b) => a + b, 0) })
    let st = mk(
      f.of(1),
      f.compute(s => s.doc.length),
      f.of(3)
    )
    ist(st.facet(f), 6)
    st = st.update({ changes: { insert: [Leaf.text('hello')], from: 1 } }).state
    ist(st.facet(f), 11)
  })

  it('survives reconfiguration', () => {
    const st = mk(
      num.compute(s => s.doc.length),
      num.of(2),
      str.of('3')
    )
    const st2 = st.update({ effects: GardState.reconfigure.of([num.compute(s => s.doc.length), num.of(2)]) }).state
    ist(st.facet(num), st2.facet(num))
    ist(st2.facet(str).length, 0)
  })

  it('survives unrelated reconfiguration even without deep-compare', () => {
    const f = GardState.Facet.define<number, { count: number }>({
      combine: v => ({ count: v.length })
    })
    const st = mk(
      f.compute(s => s.doc.length),
      f.of(2)
    )
    const st2 = st.update({ effects: GardState.appendConfig.of(str.of('hi')) }).state
    ist(st.facet(f), st2.facet(f))
  })

  it('preserves static facets across reconfiguration', () => {
    const st = mk(num.of(1), num.of(2), str.of('3'))
    const st2 = st.update({ effects: GardState.reconfigure.of([num.of(1), num.of(2)]) }).state
    ist(st.facet(num), st2.facet(num))
  })

  it('creates newly added fields when reconfiguring', () => {
    let st = mk(num.of(2))
    const events: string[] = []
    const field = GardState.Field.define({
      create() {
        events.push('create')
        return 0
      },
      update(val: number) {
        events.push(`update ${val}`)
        return val + 1
      }
    })
    st = st.update({ effects: GardState.appendConfig.of(field) }).state
    ist(events.join(', '), 'create, update 0')
    ist(st.field(field), 1)
  })

  it('applies effects from reconfiguring transaction to new fields', () => {
    let st = mk()
    const effect = Transaction.Effect.define<number>()
    const field = GardState.Field.define<number>({
      create(state) {
        return state.facet(num)[0] ?? 0
      },
      update(val, tr) {
        return tr.effects.reduce((val, e) => (e.is(effect) ? val + e.value : val), val)
      }
    })
    st = st.update({ effects: [GardState.appendConfig.of([field, num.of(10)]), effect.of(5)] }).state
    ist(st.field(field), 15)
  })

  it('errors on cyclic dependencies', () => {
    ist.throws(
      () =>
        mk(
          num.compute(s => s.facet(str).length),
          str.compute(s => s.facet(num).join())
        ),
      /cyclic/i
    )
  })

  it('updates facets computed from static values on reconfigure', () => {
    let st = mk(
      num.compute(state => state.facet(str).length),
      str.of('A')
    )
    st = st.update({ effects: GardState.appendConfig.of(str.of('B')) }).state
    ist(st.facet(num).join(','), '2')
    ist(st.facet(num), st.update({ effects: GardState.appendConfig.of(bool.of(false)) }).state.facet(num))
  })

  it('preserves dynamic facet values when dependencies stay the same', () => {
    const f = GardState.Facet.define<{ a: number }>()
    const st1 = mk(
      f.compute(_state => ({ a: 1 })),
      str.of('A')
    )
    const st2 = st1.update({ effects: GardState.appendConfig.of(bool.of(true)) }).state
    ist(st1.facet(f), st2.facet(f))
  })
})

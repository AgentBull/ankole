import { describe, it } from 'bun:test'
import { history, undo, redo, undoDepth, redoDepth } from '../../src/core/history'
import { Plot, Leaf, ChangeSet } from '../../src/core/doc'
import { GardState, GardSelection, Transaction } from '../../src/core/state'
import { Command } from '../../src/core/command/command'
import ist from 'ist'

import { basicBuilders, maybeTag, basicSchema, eq } from './schema'
const { doc, p } = basicBuilders

function mkState(d: Plot.Doc = doc(p(0)), cfg?: Parameters<typeof history>[0]) {
  const from = maybeTag(d, 0),
    to = maybeTag(d, 1) ?? from
  return GardState.create({
    config: [history(cfg)],
    doc: d,
    selection: from != null ? { anchor: from!, head: to! } : undefined
  })
}

function type(state: GardState, text: string, at = state.selection.head) {
  return state.update({ changes: { from: at, insert: [Leaf.text(text)] }, selection: { anchor: at + text.length } })
    .state
}
function timedType(state: GardState, text: string, atTime: number) {
  return state.update({
    changes: { from: state.selection.head, insert: [Leaf.text(text)] },
    selection: { anchor: state.selection.head + text.length },
    annotations: Transaction.time.of(atTime)
  }).state
}
function isolate(state: GardState) {
  return state.update({ annotations: history.isolate.of('before') }).state
}
function receive(state: GardState, text: string, from: number, to = from) {
  return state.update({
    changes: { from, to, insert: [Leaf.text(text)] },
    annotations: Transaction.addToHistory.of(false)
  }).state
}
function command(state: GardState, f: Command.Pure, success: boolean | null = true) {
  const tr = f({ state }, null)
  if (success != null) ist(!!tr, success)
  return tr ? state.update(tr).state : state
}

describe('history', () => {
  it('allows to undo a change', () => {
    let state = mkState()
    state = type(state, 'newtext')
    state = command(state, undo)
    ist(state.doc, doc(p()), eq)
  })

  it('allows to undo nearby changes in one change', () => {
    let state = mkState()
    state = type(state, 'new')
    state = type(state, 'text')
    ist(state.doc, doc(p('newtext')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p()), eq)
  })

  it('allows to redo a change', () => {
    let state = mkState()
    state = type(state, 'newtext')
    state = command(state, undo)
    state = command(state, redo)
    ist(state.doc, doc(p('newtext')), eq)
  })

  it('allows to redo nearby changes in one change', () => {
    let state = mkState()
    state = type(state, 'new')
    state = type(state, 'text')
    state = command(state, undo)
    state = command(state, redo)
    ist(state.doc, doc(p('newtext')), eq)
  })

  it('tracks multiple levels of history', () => {
    let state = mkState(doc(p('one', 0)))
    state = type(state, 'new')
    state = type(state, 'text')
    state = type(state, 'some', 1)
    ist(state.doc, doc(p('someonenewtext')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('onenewtext')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('one')), eq)
    state = command(state, redo)
    ist(state.doc, doc(p('onenewtext')), eq)
    state = command(state, redo)
    ist(state.doc, doc(p('someonenewtext')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('onenewtext')), eq)
  })

  it('starts a new event when newGroupDelay elapses', () => {
    let state = mkState(doc(p()), { newGroupDelay: 1000 })
    state = timedType(state, 'a', 1000)
    state = timedType(state, 'b', 1600)
    ist(undoDepth(state), 1)
    state = timedType(state, 'c', 2700)
    ist(undoDepth(state), 2)
    state = command(state, undo)
    state = timedType(state, 'd', 2800)
    ist(undoDepth(state), 2)
  })

  it('supports a custom join predicate', () => {
    let state = mkState(doc(p()), {
      joinToEvent: (tr: Transaction, adj: boolean) => {
        if (!adj) return false
        let space = false
        if (adj) {
          tr.changes.iterChanges((fA, tA, fB, tB, tokens) => {
            if (tokens.some(t => t instanceof Leaf && t.is(Leaf.Text) && t.param.slice(0, 1) == ' ')) {
              space = true
            }
          })
        }
        return !space
      }
    })
    for (const ch of 'ab cd') state = type(state, ch)
    ist(state.doc, doc(p('ab cd')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('ab')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p()), eq)
  })

  it("allows changes that aren't part of the history", () => {
    let state = mkState()
    state = type(state, 'hello')
    state = receive(state, 'oops', 1)
    state = receive(state, '!', 10)
    state = command(state, undo)
    ist(state.doc, doc(p('oops!')), eq)
  })

  it("can handle multiple levels with changes that aren't part of history", () => {
    let state = mkState()
    state = type(state, 'A')
    state = receive(state, 'b', 1)
    state = isolate(state)
    state = type(state, 'C', 1)
    state = receive(state, 'd', 1)
    state = isolate(state)
    state = type(state, 'E', 1)
    state = receive(state, 'f', 1)
    ist(undoDepth(state), 3)
    state = command(state, undo)
    ist(state.doc, doc(p('fdCbA')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('fdbA')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('fdb')), eq)
  })

  it('allows adding multiple non-history changes to one level', () => {
    let state = mkState()
    state = isolate(type(state, 'A'))
    state = type(state, 'B')
    state = receive(state, 'c', 1)
    state = receive(state, 'd', 1)
    state = command(state, undo)
    ist(state.doc, doc(p('dcA')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('dc')), eq)
  })

  it('allows adding new changes to an event that was mapped', () => {
    let state = type(mkState(), 'A')
    state = receive(state, 'x', 2)
    state = type(state, 'B')
    state = command(state, undo)
    ist(state.doc, doc(p('x')), eq)
  })

  it("doesn't get confused by an undo not adding any redo item", () => {
    let state = mkState(doc(p('ab')))
    state = type(state, 'cd', 2)
    state = receive(state, '123', 1, 5)
    state = command(state, undo, false)
    command(state, redo, false)
  })

  it('can handle complex editing sequences', () => {
    let state = mkState()
    state = type(state, 'hello')
    state = isolate(state)
    state = type(state, '!')
    state = receive(state, '....', 1)
    state = type(state, '--', 3)
    ist(state.doc, doc(p('..--..hello!')), eq)
    state = receive(state, '//', 2)
    state = command(state, undo)
    state = command(state, undo)
    ist(state.doc, doc(p('.//...hello')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('.//...')), eq)
  })

  it('supports overlapping edits', () => {
    let state = mkState()
    state = isolate(type(state, 'hello'))
    state = state.update({ changes: { from: 1, to: 6 } }).state
    ist(state.doc, doc(p()), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('hello')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p()), eq)
  })

  it("supports overlapping edits that aren't collapsed", () => {
    let state = mkState()
    state = receive(state, 'h', 1)
    state = isolate(type(state, 'ello', 2))
    state = state.update({ changes: { from: 1, to: 6 } }).state
    ist(state.doc, doc(p()), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('hello')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('h')), eq)
  })

  it('supports overlapping unsynced deletes', () => {
    let state = mkState()
    state = isolate(type(state, 'hi'))
    state = type(state, 'hello')
    state = state.update({ changes: { from: 1, to: 8 }, annotations: Transaction.addToHistory.of(false) }).state
    ist(state.doc, doc(p()), eq)
    state = command(state, undo, false)
    ist(state.doc, doc(p()), eq)
  })

  it('can go back and forth through history multiple times', () => {
    let state = mkState()
    state = type(state, 'one')
    state = isolate(type(state, ' two'))
    state = type(state, ' three')
    state = isolate(type(state, 'zero ', 1))
    state = type(state, '//', 1)
    state = type(state, 'top', 1)
    for (let i = 0; i < 6; i++) {
      const re = i % 2
      for (let j = 0; j < 4; j++) state = command(state, re ? redo : undo)
      ist(state.doc, re ? doc(p('top//zero one two three')) : doc(p()), eq)
    }
  })

  it('supports non-tracked changes next to tracked changes', () => {
    let state = mkState()
    state = type(state, 'o')
    state = type(state, 'XX', 1)
    state = receive(state, 'zzz', 4)
    state = command(state, undo)
    ist(state.doc, doc(p('zzz')), eq)
  })

  it('can go back and forth through history when preserving items', () => {
    let state = mkState()
    state = type(state, 'one')
    state = isolate(type(state, ' two'))
    state = receive(state, 'xxx', state.doc.length - 1)
    state = type(state, ' three', state.doc.length - 1)
    state = isolate(type(state, 'zero ', 1))
    state = type(state, '~~', 1)
    state = type(state, 'top', 1)
    state = receive(state, 'yyy', 1)
    for (let i = 0; i < 3; i++) {
      for (let j = 0; j < 4; j++) state = command(state, undo)
      ist(state.doc, doc(p('yyyxxx')), eq)
      for (let j = 0; j < 4; j++) state = command(state, redo)
      ist(state.doc, doc(p('yyytop~~zero one twoxxx three')), eq)
    }
  })

  it('restores selection on undo', () => {
    let state = mkState()
    state = isolate(type(state, 'hi'))
    state = state.update({ selection: { anchor: 1, head: 3 } }).state
    const selection = state.selection
    state = state.update({
      changes: { from: selection.from, to: selection.to, insert: [Leaf.text('hello')] },
      selection: { anchor: selection.from + 5 }
    }).state
    const selection2 = state.selection
    state = command(state, undo)
    ist(state.selection, selection, eq)
    state = command(state, redo)
    ist(state.selection, selection2, eq)
  })

  it('restores the selection before the first change in an item', () => {
    let state = mkState()
    state = type(state, 'a')
    state = type(state, 'b')
    state = command(state, undo)
    ist(state.doc, doc(p()), eq)
    ist(state.selection.anchor, 1)
  })

  it('rebases selection on undo', () => {
    let state = mkState()
    state = isolate(type(state, 'hi'))
    state = state.update({ selection: { anchor: 1, head: 3 } }).state
    state = type(state, 'hello', 1)
    state = receive(state, '---', 1)
    state = command(state, undo)
    ist(state.selection.head, 6)
  })

  it('can handle random events without crashing', () => {
    let state = mkState(doc(p('123456789')))
    const r = (n: number) => Math.floor(Math.random() * n)
    const rPos = () => 1 + r(state.doc.length - 2)
    const rRange = () => {
      const from = 1 + r(state.doc.length - 3)
      return { from, to: from + r(state.doc.length - 1 - from) }
    }
    for (let i = 0; i < 500; i++) {
      const c = r(5)
      state =
        c == 0
          ? command(state, undo, null)
          : c == 1
            ? command(state, redo, null)
            : c == 2
              ? type(state, 'ABCDEFGHIJKL'[r(12)]!, rPos())
              : c == 3
                ? receive(state, 'abcdefghijkl'[r(12)]!, rPos())
                : state.update({ changes: rRange() }).state
    }
  })

  it('supports querying for the undo and redo depth', () => {
    let state = mkState()
    state = type(state, 'a')
    ist(undoDepth(state), 1)
    ist(redoDepth(state), 0)
    state = receive(state, 'b', 1)
    ist(undoDepth(state), 1)
    ist(redoDepth(state), 0)
    state = command(state, undo)
    ist(undoDepth(state), 0)
    ist(redoDepth(state), 1)
    state = command(state, redo)
    ist(undoDepth(state), 1)
    ist(redoDepth(state), 0)
  })

  it('all functions gracefully handle EditorStates without history', () => {
    const state = GardState.create({ doc: doc(p()) })
    ist(undoDepth(state), 0)
    ist(redoDepth(state), 0)
    command(state, undo, false)
    command(state, redo, false)
  })

  it('truncates history', () => {
    let state = mkState(doc(p()), { minDepth: 10 })
    for (let i = 0; i < 40; ++i) state = isolate(type(state, 'a'))
    ist(undoDepth(state) < 40)
  })

  it('isolates transactions when asked to', () => {
    let state = mkState()
    state = state.update({
      changes: { from: 1, insert: [Leaf.text('a')] },
      annotations: history.isolate.of('after')
    }).state
    state = state.update({ changes: { from: 2, insert: [Leaf.text('b')] } }).state
    state = state.update({
      changes: { from: 3, insert: [Leaf.text('c')] },
      annotations: history.isolate.of('after')
    }).state
    state = state.update({ changes: { from: 4, insert: [Leaf.text('d')] } }).state
    state = state.update({
      changes: { from: 5, insert: [Leaf.text('e')] },
      annotations: history.isolate.of(true)
    }).state
    state = state.update({ changes: { from: 6, insert: [Leaf.text('f')] } }).state
    ist(undoDepth(state), 5)
  })

  it('can group events around a non-history transaction', () => {
    let state = mkState()
    state = state.update({ changes: { from: 1, insert: [Leaf.text('a')] } }).state
    state = state.update({
      changes: { from: 2, insert: [Leaf.text('b')] },
      annotations: Transaction.addToHistory.of(false)
    }).state
    state = state.update({ changes: { from: 2, insert: [Leaf.text('c')] } }).state
    state = command(state, undo)
    ist(state.doc, doc(p('b')), eq)
  })

  it('properly maps selections through non-history changes', () => {
    let state = mkState(doc(p('abc')))
    state = state.update({ selection: GardSelection.range(1, 2) }).state
    state = state.update({ changes: { from: 1, to: 4, insert: [Leaf.text('d')] } }).state
    state = state.update({
      changes: [
        { from: 1, insert: [Leaf.text('x')] },
        { from: 2, insert: [Leaf.text('y')] }
      ],
      annotations: Transaction.addToHistory.of(false)
    }).state
    state = command(state, undo)
    ist(state.doc, doc(p('xabcy')), eq)
    ist(state.selection.from, 2)
    ist(state.selection.to, 3)
  })

  it('properly maps selections in deeper events', () => {
    let state = mkState(doc(p('123', 0)))
    state = isolate(type(state, '4'))
    state = state.update({ changes: { from: 1, to: 3 } }).state
    state = receive(state, '!!!!', 1)
    state = command(command(state, undo), undo)
    ist(state.selection.head, 8)
  })

  it('restores selection on redo', () => {
    let state = mkState(doc(p('a'), p('b'), p('c')))
    state = state.update({ selection: GardSelection.range(1, 8) }).state
    state = state.update({ changes: [1, 4, 7].map(n => ({ from: n, insert: [Leaf.text('-')] })) }).state
    state = command(state, undo)
    state = state.update({ selection: { anchor: 1 } }).state
    state = command(state, redo)
    ist(state.selection.from, 2)
    ist(state.selection.to, 11)
  })

  it('can handle extenders adding changes', () => {
    let state = GardState.create({
      doc: doc(p('ab')),
      config: [
        history(),
        Transaction.extender.of(tr => {
          return !tr.startState.doc.eq(doc(p('abcd'))) ? null : { changes: { from: 4, insert: [Leaf.text('...')] } }
        })
      ]
    })
    state = state.update({
      changes: { from: 3, insert: [Leaf.text('c')] },
      annotations: history.isolate.of('after')
    }).state
    state = state.update({ changes: { from: 4, insert: [Leaf.text('d')] } }).state
    state = command(state, undo)
    ist(state.doc, doc(p('abc...')), eq)
    state = command(state, undo)
    ist(state.doc, doc(p('ab...')), eq)
    state = command(state, redo)
    ist(state.doc, doc(p('abc...')), eq)
    state = command(state, redo)
    ist(state.doc, doc(p('abcd')), eq)
  })

  describe('effects', () => {
    it('includes inverted effects in the history', () => {
      const set = Transaction.Effect.define<number>()
      const field = GardState.Field.define({
        create: () => 0,
        update(val, tr) {
          for (const effect of tr.effects) if (effect.is(set)) val = effect.value
          return val
        }
      })
      const invert = history.invertedEffects.of(tr => {
        for (const e of tr.effects) if (e.is(set)) return [set.of(tr.startState.field(field))]
        return []
      })
      let state = GardState.create({ doc: doc(p()), config: [history(), field, invert] })
      state = state.update({ effects: set.of(10), annotations: history.isolate.of('before') }).state
      state = state.update({ effects: set.of(20), annotations: history.isolate.of('before') }).state
      ist(state.field(field), 20)
      state = command(state, undo)
      ist(state.field(field), 10)
      state = command(state, undo)
      ist(state.field(field), 0)
      state = command(state, redo)
      ist(state.field(field), 10)
      state = command(state, redo)
      ist(state.field(field), 20)
      state = command(state, undo)
      ist(state.field(field), 10)
      state = command(state, redo)
      ist(state.field(field), 20)
    })

    class Comment {
      readonly from: number
      readonly to: number
      readonly text: string

      constructor(from: number, to: number, text: string) {
        this.from = from
        this.to = to
        this.text = text
      }

      eq(other: Comment) {
        return this.from == other.from && this.to == other.to && this.text == other.text
      }
    }
    function mapComment(comment: Comment, mapping: ChangeSet) {
      const from = mapping.mapPos(comment.from, 1),
        to = mapping.mapPos(comment.to, -1)
      return from >= to ? undefined : new Comment(from, to, comment.text)
    }
    const addComment = Transaction.Effect.define<Comment>({ map: mapComment })
    const rmComment = Transaction.Effect.define<Comment>({ map: mapComment })
    const comments = GardState.Field.define<Comment[]>({
      create: () => [],
      update(value, tr) {
        value = value.map(c => mapComment(c, tr.changes)).filter(x => x) as any
        for (const effect of tr.effects) {
          if (effect.is(addComment)) value = value.concat(effect.value)
          else if (effect.is(rmComment)) value = value.filter(c => !c.eq(effect.value))
        }
        return value.sort((a, b) => a.from - b.from)
      }
    })
    const invertComments = history.invertedEffects.of(tr => {
      const effects = []
      for (const effect of tr.effects) {
        if (effect.is(addComment) || effect.is(rmComment)) {
          const src = mapComment(effect.value, tr.changes.invert(tr.startState.doc))
          if (src) effects.push((effect.is(addComment) ? rmComment : addComment).of(src))
        }
      }
      for (const comment of tr.startState.field(comments)) {
        if (!mapComment(comment, tr.changes)) effects.push(addComment.of(comment))
      }
      return effects
    })

    function commentStr(state: GardState) {
      return state
        .field(comments)
        .map(c => `${c.text}@${c.from}`)
        .join(',')
    }

    it('can map effects', () => {
      let state = GardState.create({ config: [history(), comments, invertComments], doc: doc(p('one two foo')) })
      state = state.update({
        effects: addComment.of(new Comment(1, 4, 'c1')),
        annotations: history.isolate.of(true)
      }).state
      ist(commentStr(state), 'c1@1')
      state = state.update({
        changes: { from: 4, to: 5, insert: [Leaf.text('---')] },
        annotations: history.isolate.of(true),
        effects: addComment.of(new Comment(7, 10, 'c2'))
      }).state
      ist(commentStr(state), 'c1@1,c2@7')
      state = state.update({
        changes: { from: 1, insert: [Leaf.text('---')] },
        annotations: Transaction.addToHistory.of(false)
      }).state
      ist(commentStr(state), 'c1@4,c2@10')
      state = command(state, undo)
      ist(state.doc, doc(p('---one two foo')), eq)
      ist(commentStr(state), 'c1@4')
      state = command(state, undo)
      ist(commentStr(state), '')
      state = command(state, redo)
      ist(commentStr(state), 'c1@4')
      state = command(state, redo)
      ist(commentStr(state), 'c1@4,c2@10')
      ist(state.doc, doc(p('---one---two foo')), eq)
      state = command(state, undo).update({
        changes: { from: 11, to: 12, insert: [Leaf.text('---')] },
        annotations: Transaction.addToHistory.of(false)
      }).state
      state = state.update({
        effects: addComment.of(new Comment(14, 17, 'c3')),
        annotations: history.isolate.of(true)
      }).state
      ist(commentStr(state), 'c1@4,c3@14')
      state = command(state, undo)
      ist(state.doc, doc(p('---one two---foo')), eq)
      ist(commentStr(state), 'c1@4')
      state = command(state, redo)
      ist(commentStr(state), 'c1@4,c3@14')
    })

    it('can restore comments lost through deletion', () => {
      let state = GardState.create({ config: [history(), comments, invertComments], doc: doc(p('123456')) })
      state = state.update({
        effects: addComment.of(new Comment(4, 6, 'c1')),
        annotations: history.isolate.of(true)
      }).state
      state = state.update({ changes: { from: 3, to: 7 } }).state
      ist(commentStr(state), '')
      state = command(state, undo)
      ist(commentStr(state), 'c1@4')
    })
  })

  describe('JSON', () => {
    it('survives serialization', () => {
      let state = mkState(doc(p('abcd')))
      state = state.update({ changes: { from: 4, to: 5 } }).state
      state = state.update({ changes: { from: 1, insert: [Leaf.text('d')] } }).state
      state = command(state, undo)
      const jsonConf = { history: history.field }
      const json = JSON.stringify(state.toJSON(jsonConf))
      state = GardState.fromJSON(
        JSON.parse(json),
        [history(), basicSchema.elements.map(e => GardState.schemaElement.of(e))],
        jsonConf
      )
      ist(state.doc, doc(p('abc')), eq)
      state = command(state, redo)
      ist(state.doc, doc(p('dabc')), eq)
      state = command(command(state, undo), undo)
      ist(state.doc, doc(p('abcd')), eq)
    })

    it('resolves before serializing', () => {
      let state = mkState(doc(p()))
      state = isolate(type(state, 'a'))
      state = isolate(type(state, 'b'))
      state = type(state, 'c')
      state = receive(state, 'd', 4)
      const jsonConf = { history: history.field }
      const json = JSON.stringify(state.toJSON(jsonConf))
      state = GardState.fromJSON(
        JSON.parse(json),
        [history(), basicSchema.elements.map(e => GardState.schemaElement.of(e))],
        jsonConf
      )
      ist(state.doc, doc(p('abcd')), eq)
      state = command(command(state, undo), undo)
      ist(state.doc, doc(p('ad')), eq)
      state = command(state, undo)
      ist(state.doc, doc(p('d')), eq)
    })
  })
})

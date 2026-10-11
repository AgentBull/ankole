import { describe, it } from './runner'
import { Wordgard } from '../../../src/core/editor'
import { Command, deleteLine, killToLineEnd, yankKilled } from '../../../src/core/command'
import { GardState } from '../../../src/core/state'
import { Plot } from '../../../src/core/doc'
import ist from 'ist'
import { tempEditor } from './tempview'
import { basicBuilders, maybeTag, eq } from '../schema'
const { doc, p, br, strong } = basicBuilders

function test1<T>(doc: Plot.Doc, cmd: Command<T>, arg: T, expect: Plot.Doc | null, config: GardState.Extension = []) {
  const wg = tempEditor(doc, config)
  const result = Command.dispatch(wg, cmd, arg)
  ist(result, expect != null)
  if (expect) {
    ist(wg.state.doc, expect, eq)
    if (maybeTag(expect, 0) != null) ist(wg.state.selection.head, maybeTag(expect, 0))
  }
}

function test(doc: Plot.Doc, cmd: Command<null>, expect: Plot.Doc | null, config: GardState.Extension = []) {
  test1(doc, cmd, null, expect, config)
}

const narrow = Wordgard.theme({ '&': { width: '20ex' } })

describe('deleteLine', () => {
  it('clears an entire paragraph', () => {
    test(doc(p('foo', 0), p('bar')), deleteLine, doc(p(0), p('bar')))
  })

  it("doesn't clear past wrap points", () => {
    test(
      doc(p('bigwordone bigword', 0, 'two bigwordthree')),
      deleteLine,
      doc(p('bigwordone ', 0, 'bigwordthree')),
      narrow
    )
  })
})

describe('killToLineEnd', () => {
  it('deletes content after the cursor', () => {
    test(doc(p('one ', 0, 'two')), killToLineEnd, doc(p('one ', 0)))
  })

  it('joins textblocks when at the end of one', () => {
    test(doc(p('one', 0), p('two')), killToLineEnd, doc(p('one', 0, 'two')))
  })

  it('deletes line breaks', () => {
    test(doc(p('one', 0, br, 'two')), killToLineEnd, doc(p('one', 0, 'two')))
  })

  it('does nothing at end of doc', () => {
    test(doc(p('one', 0)), killToLineEnd, null)
  })

  it('stores content in the kill buffer', () => {
    const wg = tempEditor(doc(p('a', 0, 'b')))
    Command.dispatch(wg, killToLineEnd)
    Command.dispatch(wg, yankKilled)
    Command.dispatch(wg, yankKilled)
    ist(wg.state.doc, doc(p('abb')), eq)
    ist(wg.state.selection.head, 4)
  })

  it('accumulates killed content', () => {
    const wg = tempEditor(doc(p('a', 0, 'b', strong('c')), p('d')))
    Command.dispatch(wg, killToLineEnd)
    Command.dispatch(wg, killToLineEnd)
    Command.dispatch(wg, killToLineEnd)
    ist(wg.state.doc, doc(p('a')), eq)
    Command.dispatch(wg, yankKilled)
    ist(wg.state.doc, doc(p('a', 0, 'b', strong('c')), p('d')), eq)
  })

  it('stops accumulating on cursor motion', () => {
    const wg = tempEditor(doc(p('a', 0, 'b'), p('cd')))
    Command.dispatch(wg, killToLineEnd)
    wg.dispatch({ selection: { anchor: 5 } })
    Command.dispatch(wg, killToLineEnd)
    ist(wg.state.doc, doc(p('a'), p('c')), eq)
    Command.dispatch(wg, yankKilled)
    ist(wg.state.doc, doc(p('a'), p('cd')), eq)
  })

  it('stops accumulating on document changes', () => {
    const wg = tempEditor(doc(p('a', 0, 'b'), p('cd')))
    Command.dispatch(wg, killToLineEnd)
    wg.dispatch({ changes: { from: 5, to: 6 } })
    Command.dispatch(wg, killToLineEnd)
    Command.dispatch(wg, yankKilled)
    ist(wg.state.doc, doc(p('a'), p('c')), eq)
  })
})

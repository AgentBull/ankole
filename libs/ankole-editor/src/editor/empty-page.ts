/*
 * The empty-page hint (SPEC §7.6 `placeholder`). While the page is one empty paragraph, the
 * paragraph has a `data-placeholder` attribute, and the style sheet shows the hint from it. The hint
 * is not page text: the paragraph stays empty for the caret and for reading. Assistive technology
 * reads `aria-placeholder` on the content element.
 */
import { Decoration } from '../core/editor'
import { GardState } from '../core/state'
import * as T from '../core/types'
import { PhraseSet } from '../core/phrases'

function hint(state: GardState, text: string | PhraseSet.Ref): Decoration.Point.Set {
  const { doc } = state
  const only = doc.content.length == 1 ? doc.firstChild : null
  if (!only?.isPlot || only.type != T.Paragraph.type || only.content.length) return Decoration.Point.none
  return Decoration.Point.set([
    [Decoration.Point.attributes({ 'data-placeholder': typeof text === 'string' ? text : text(state) }), 0]
  ])
}

export function emptyPageHint(text: string | PhraseSet.Ref): GardState.Extension {
  return GardState.Field.define<Decoration.Point.Set>({
    create: state => hint(state, text),
    update: (deco, tr) => (tr.docChanged || PhraseSet.didChange(tr.startState, tr.state) ? hint(tr.state, text) : deco),
    provide: field => Decoration.Point.source.of(state => state.field(field))
  })
}

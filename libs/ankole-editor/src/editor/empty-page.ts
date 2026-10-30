/*
 * The empty-paragraph hint (SPEC §7.6 `placeholder`). The empty page or paragraph at the caret
 * has a `data-placeholder` attribute, and the style sheet shows the hint from it. The hint
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
  const caret = state.selection.isCursor ? state.sel.head.textblockParent : null
  const paragraph = only?.type === T.Paragraph.type ? only : caret?.node
  if (!paragraph?.isPlot || paragraph.type !== T.Paragraph.type || paragraph.content.length) {
    return Decoration.Point.none
  }
  return Decoration.Point.set([
    [
      Decoration.Point.attributes({ 'data-placeholder': typeof text === 'string' ? text : text(state) }),
      paragraph === only ? 0 : caret!.before
    ]
  ])
}

export function emptyPageHint(text: string | PhraseSet.Ref): GardState.Extension {
  return GardState.Field.define<Decoration.Point.Set>({
    create: state => hint(state, text),
    update: (deco, tr) =>
      tr.docChanged || tr.selection || PhraseSet.didChange(tr.startState, tr.state) ? hint(tr.state, text) : deco,
    provide: field => Decoration.Point.source.of(state => state.field(field))
  })
}

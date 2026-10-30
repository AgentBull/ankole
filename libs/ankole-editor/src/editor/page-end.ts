/*
 * Click at the page end (SPEC §7.5 Page-end click). The content surface and surrounding-page
 * gestures share this operation, so a click adds one root paragraph or focuses the empty last one.
 */
import { Wordgard } from '../core/editor'
import { GardSelection } from '../core/state'
import * as T from '../core/types'
import { dispatchStep } from './block-insert'

export function focusPageEnd(wg: Wordgard, y: number): boolean {
  const { doc, readOnly } = wg.state
  const last = doc.lastChild
  if (readOnly || !wg.editable || !last) return false
  const dom = wg.nodeDOM(doc.length - last.length)
  if (!dom || y <= dom.getBoundingClientRect().bottom) return false
  if (last.isPlot && last.type === T.Paragraph.type && !last.content.length) {
    wg.dispatch({
      selection: GardSelection.cursor(doc.length - last.length + 1),
      scrollIntoView: true,
      userEvent: 'select.pointer'
    })
  } else {
    dispatchStep(wg, {
      changes: { from: doc.length, insert: [T.Paragraph.create([])] },
      selection: GardSelection.cursor(doc.length + 1),
      userEvent: 'block.insert'
    })
  }
  wg.focus()
  return true
}

export const pageEnd = Wordgard.domEventHandler('mousedown', (event, wg) => {
  if (event.button || event.ctrlKey || event.metaKey || event.altKey || event.target !== wg.contentDOM) return false
  return focusPageEnd(wg, event.clientY)
})

/*
 * Click at the page end (SPEC §7.5 Page-end click). When the last block is a leaf (a database
 * reference, a divider, a read-only block) or a container (a table, a quote, a callout), a click in
 * the empty space below it adds an empty paragraph at the page end and puts the caret there. Below
 * a text block or a list, the click puts the caret in that block as usual.
 */
import { Node } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection } from '../core/state'
import * as T from '../core/types'

export const pageEnd = Wordgard.domEventHandler('mousedown', (event, wg) => {
  const { doc, readOnly } = wg.state
  const last = doc.lastChild
  if (event.button !== 0 || event.target !== wg.contentDOM || readOnly || !wg.editable || !last) return false
  if (last.isPlot && (last.isTextblock || last.type.hasRole(Node.Role.List))) return false
  const dom = wg.nodeDOM(doc.length - last.length)
  if (!dom || event.clientY <= dom.getBoundingClientRect().bottom) return false
  wg.dispatch({
    changes: { from: doc.length, insert: [T.Paragraph.create([])] },
    selection: GardSelection.cursor(doc.length + 1),
    scrollIntoView: true,
    userEvent: 'input'
  })
  wg.focus()
  return true
})

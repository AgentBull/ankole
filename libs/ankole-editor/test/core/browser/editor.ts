import { describe, it } from './runner'
import { Wordgard, Decoration } from '../../../src/core/editor'
import { Widget } from '../../../src/core/editor/decoration'
import { Transaction } from '../../../src/core/state'
import { Leaf } from '../../../src/core/doc'
import { Image } from '../../../src/core/types/schema'
import { basicBuilders, eq } from '../schema'
import ist from 'ist'
import { requireFocus, tempEditor } from './tempview'

const { doc, p, img, hr } = basicBuilders

describe('Wordgard', () => {
  it('calls update on plugins', () => {
    let updates = 0
    const plugin = Wordgard.Plugin.define(wg => {
      let prevDoc = wg.state.doc
      return {
        update(update: Wordgard.Update) {
          ist(update.startState.doc, prevDoc)
          ist(update.state.doc, wg.state.doc)
          prevDoc = update.state.doc
          updates++
        }
      }
    })
    const wg = tempEditor(doc(p('xyz')), [plugin])
    ist(updates, 0)
    wg.dispatch({ changes: { from: 2, to: 3, insert: [Leaf.text('u')] } })
    wg.flush()
    ist(updates, 1)
    wg.dispatch({ selection: { anchor: 3 } })
    wg.flush()
    ist(updates, 2)
  })

  it('allows content attributes to be changed through extensions', () => {
    const wg = tempEditor(doc(p()), [Wordgard.contentAttributes.of({ 'aria-label': 'test' })])
    ist(wg.contentDOM.getAttribute('aria-label'), 'test')
  })

  it('allows editor attributes to be changed through extensions', () => {
    const wg = tempEditor(doc(p()), [Wordgard.editorAttributes.of({ class: 'something' })])
    ist(wg.dom.classList.contains('something'))
  })

  it('repairs changes to text nodes', () => {
    const wg = tempEditor(doc(p('abc')))
    wg.contentDOM.firstChild!.firstChild!.nodeValue = 'a'
    wg.flush()
    ist(wg.contentDOM.innerHTML, '<p>abc</p>')
  })

  it('repairs modified attributes', () => {
    const wg = tempEditor(doc(p('abc')))
    ;(wg.contentDOM.firstChild as HTMLElement).setAttribute('test', 'test')
    wg.flush()
    ist(wg.contentDOM.innerHTML, '<p>abc</p>')
  })

  it('disallows dispatches from plugin update', () => {
    const wg = tempEditor(
      doc(p('x')),
      Wordgard.Plugin.fromClass(
        class {
          update(u: Wordgard.Update) {
            if (u.state.doc.length == 4) {
              ist.throws(() => {
                wg.dispatch({ changes: { from: 1, to: 2 } })
              }, /Cannot dispatch new updates/)
            }
          }
        }
      )
    )
    wg.dispatch({ changes: { from: 2, insert: [Leaf.text('y')] } })
    wg.flush()
  })

  it('automatically flushes on DOM access', () => {
    const wg = tempEditor(doc(p('abc')))
    const c1 = wg.coordsAtPos(4)
    wg.dispatch({ changes: { from: 0, insert: [p()] } })
    const c2 = wg.coordsAtPos(4)
    ist(c2.top, c1.top, '>')
  })

  it('applies transaction appenders', () => {
    const wg = tempEditor(
      doc(p()),
      Transaction.appender.of((trs, state) => {
        return state.doc.length >= 5 ? { changes: { from: 5, to: state.doc.length, fit: true } } : null
      })
    )
    wg.dispatch({ changes: { from: 1, insert: [Leaf.text('more content')] } })
    ist(wg.state.doc, doc(p('more')), eq)
  })

  it('calls connect/disconnect on widgets', () => {
    const log: string[] = []
    const trackedWidget = Widget.define<string>({
      render(v) {
        const s = document.createElement('span')
        s.textContent = v
        return s
      },
      connect(v) {
        log.push(`connect ${v}`)
      },
      disconnect(v) {
        log.push(`disconnect ${v}`)
      }
    })
    const imgWidget = Decoration.Tag.shape(Image, t => trackedWidget.of(t.param))

    const wg = tempEditor(doc(p('ab', img('a'), 'cd')), imgWidget)
    ist(log.join('/'), 'connect a')
    const parent = wg.dom.parentNode!
    parent.removeChild(wg.dom)
    parent.appendChild(wg.dom)
    ist(log.join('/'), 'connect a/disconnect a/connect a')
    log.length = 0
    wg.dispatch({ changes: { from: 3, to: 4, insert: [img('b')] } })
    wg.flush()
    ist(log.join('/'), 'disconnect a/connect b')
    wg.dispatch({ changes: { from: wg.state.doc.length, insert: [p('!', img('c'))] } })
    wg.flush()
    ist(log.join('/'), 'disconnect a/connect b/connect c')
    wg.dispatch({ changes: { from: 0, to: wg.state.doc.length, insert: [hr] } })
    wg.flush()
    ist(log.join('/'), 'disconnect a/connect b/connect c/disconnect b/disconnect c')
  })

  it('reads a DOM selection change before a key binding runs', () => {
    const wg = requireFocus(tempEditor(doc(p('abc'))))
    // Move the DOM caret after "b" without a flush, as when a key arrives before the flush.
    getSelection()!.collapse(wg.contentDOM.firstChild!.firstChild!, 2)
    const key = { key: 'Backspace', code: 'Backspace', keyCode: 8, bubbles: true, cancelable: true }
    wg.contentDOM.dispatchEvent(new KeyboardEvent('keydown', key))
    ist(wg.state.doc, doc(p('ac')), eq)
  })
})

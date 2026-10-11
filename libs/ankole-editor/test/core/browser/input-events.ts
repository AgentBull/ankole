import { describe, it } from './runner'
import { Wordgard } from '../../../src/core/editor'
import { GardSelection } from '../../../src/core/state'
import ist from 'ist'
import { tempEditor, requireFocus } from './tempview'
import { basicBuilders, eq } from '../schema'
const { doc, p, strong, hr } = basicBuilders

// Fire an input event. Chrome reports input types that it does not
// know as "" on synthetic events, and Safari ignores `targetRanges`.
function fire(wg: Wordgard, type: string, init: InputEventInit) {
  const event = new InputEvent(type, { bubbles: true, cancelable: true, ...init })
  if (event.inputType != init.inputType) Object.defineProperty(event, 'inputType', { value: init.inputType })
  if (init.targetRanges && !event.getTargetRanges().length) event.getTargetRanges = () => init.targetRanges!
  wg.contentDOM.dispatchEvent(event)
  return event
}

function findText(wg: Wordgard, text: string): Text {
  const walker = document.createTreeWalker(wg.contentDOM, NodeFilter.SHOW_TEXT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.nodeValue == text) return node as Text
  throw new Error(`Failed to find text node ${JSON.stringify(text)}`)
}

function range(node: Node, from: number, to = from) {
  return new StaticRange({ startContainer: node, startOffset: from, endContainer: node, endOffset: to })
}

describe('input events', () => {
  it('act on a DOM selection that the editor has not read yet', () => {
    const wg = requireFocus(tempEditor(doc(p('hello world'))))
    wg.flush()
    const text = findText(wg, 'hello world')
    // No selectionchange event reaches the editor before the input event.
    document.getSelection()!.setBaseAndExtent(text, 0, text, 5)
    ist(fire(wg, 'beforeinput', { inputType: 'formatBold' }).defaultPrevented)
    ist(wg.state.doc, doc(p(strong('hello'), ' world')), eq)
  })

  it('let a key act on a DOM selection that the editor has not read yet', () => {
    const wg = requireFocus(tempEditor(doc(p('abc'))))
    wg.flush()
    document.getSelection()!.collapse(findText(wg, 'abc'), 3)
    wg.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Backspace', keyCode: 8, bubbles: true, cancelable: true })
    )
    ist(wg.state.doc, doc(p('ab')), eq)
  })

  it('read a DOM selection that changed after an earlier read', () => {
    const wg = requireFocus(tempEditor(doc(p('abcdef'))))
    wg.flush()
    const text = findText(wg, 'abcdef')
    document.getSelection()!.collapse(text, 2)
    // An input event that changes nothing reads the selection.
    fire(wg, 'beforeinput', { inputType: 'insertFromPasteAsQuotation' })
    document.getSelection()!.collapse(text, 5)
    wg.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Backspace', keyCode: 8, bubbles: true, cancelable: true })
    )
    ist(wg.state.doc, doc(p('abcdf')), eq)
  })

  it('replace the selection with replacement text that has no target range', () => {
    const wg = requireFocus(tempEditor(doc(p('a ', strong('Espana'), ' b'))))
    wg.dispatch({ selection: GardSelection.range(3, 9) })
    ist(fire(wg, 'beforeinput', { inputType: 'insertReplacementText', data: 'España' }).defaultPrevented)
    ist(wg.state.doc, doc(p('a ', strong('España'), ' b')), eq)
  })

  it('read a replacement that cannot be canceled from the DOM once', () => {
    const wg = requireFocus(tempEditor(doc(p('a ', strong('Espana'), ' b'))))
    wg.flush()
    const text = findText(wg, 'Espana')
    fire(wg, 'beforeinput', {
      inputType: 'insertReplacementText',
      data: 'España',
      cancelable: false,
      targetRanges: [range(text, 0, 6)]
    })
    // The browser changes the DOM.
    text.replaceData(0, 6, 'Españaa')
    document.getSelection()!.collapse(text, 7)
    fire(wg, 'input', { inputType: 'insertReplacementText', data: 'España' })
    ist(wg.state.doc, doc(p('a ', strong('Españaa'), ' b')), eq)
    // Before the next flush, the next input event refers to the changed DOM text.
    document.getSelection()!.collapse(text, 6)
    fire(wg, 'beforeinput', { inputType: 'insertText', data: '!', targetRanges: [range(text, 6)] })
    text.insertData(6, '!')
    fire(wg, 'input', { inputType: 'insertText', data: '!' })
    ist(wg.state.doc, doc(p('a ', strong('España!a'), ' b')), eq)
    wg.flush()
    ist(wg.contentDOM.innerHTML, '<p>a <strong>España!a</strong> b</p>')
  })

  it('read a text change without beforeinput', () => {
    const wg = requireFocus(tempEditor(doc(p('one'), p('two'))))
    wg.flush()
    const one = findText(wg, 'one'),
      two = findText(wg, 'two')
    one.data = 'on'
    two.data = 'twelve'
    document.getSelection()!.collapse(two, 6)
    fire(wg, 'input', { inputType: 'insertReplacementText' })
    ist(wg.state.doc, doc(p('on'), p('twelve')), eq)
    wg.flush()
    ist(wg.state.selection.head, 11)
  })

  it('draw other DOM changes without beforeinput from the document again', () => {
    const wg = requireFocus(tempEditor(doc(p('hello'))))
    wg.flush()
    const text = findText(wg, 'hello')
    const bold = document.createElement('b')
    text.parentNode!.insertBefore(bold, text)
    bold.appendChild(text.splitText(3))
    fire(wg, 'input', { inputType: 'formatBold' })
    wg.flush()
    ist(wg.state.doc, doc(p('hello')), eq)
    ist(wg.contentDOM.innerHTML, '<p>hello</p>')
  })

  it('put a composition that starts between blocks into a new textblock', () => {
    const wg = requireFocus(tempEditor(doc(p('a'), hr)))
    wg.dispatch({ selection: GardSelection.cursor(4) })
    wg.flush()
    wg.contentDOM.dispatchEvent(new CompositionEvent('compositionstart'))
    ist(wg.state.doc, doc(p('a'), hr, p()), eq)
    const text = wg.contentDOM.querySelectorAll('p')[1]!.appendChild(document.createTextNode(''))
    wg.contentDOM.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'x' }))
    fire(wg, 'beforeinput', {
      inputType: 'insertCompositionText',
      data: 'x',
      isComposing: true,
      cancelable: false,
      targetRanges: [range(text, 0)]
    })
    text.nodeValue = 'x'
    document.getSelection()!.collapse(text, 1)
    fire(wg, 'input', { inputType: 'insertCompositionText', data: 'x', isComposing: true })
    wg.flush()
    wg.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { data: 'x' }))
    wg.flush()
    ist(wg.state.doc, doc(p('a'), hr, p('x')), eq)
  })
})

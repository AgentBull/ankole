import { describe, it } from './runner'
import { Wordgard } from '../../../src/core/editor'
import { Command, insertText } from '../../../src/core/command'
import { Leaf, Node } from '../../../src/core/doc'
import ist from 'ist'
import { requireFocus, tempEditor } from './tempview'
import { r, rWord, rLetter } from '../generate'
import { basicBuilders, eq } from '../schema'
const { doc, p, em } = basicBuilders

function inputEvent(wg: Wordgard, type: string, init: InputEventInit) {
  const event = new InputEvent(type, init)
  // Safari doesn't support the targetRanges option
  if (init.targetRanges && !event.getTargetRanges().length) {
    event.getTargetRanges = () => init.targetRanges!
  }
  wg.contentDOM.dispatchEvent(event)
}

function domDel(wg: Wordgard, node: Text, from: number, to: number) {
  inputEvent(wg, 'beforeinput', {
    inputType: 'deleteContentBackward',
    data: '',
    targetRanges: [new StaticRange({ startContainer: node, startOffset: from, endContainer: node, endOffset: to })]
  })
  node.nodeValue = node.nodeValue!.slice(0, from) + node.nodeValue!.slice(to)
  inputEvent(wg, 'input', {
    inputType: 'deleteContentBackward',
    data: ''
  })
}

function domIns(wg: Wordgard, node: Text, text: string, from: number, to = from) {
  inputEvent(wg, 'beforeinput', {
    inputType: 'insertText',
    data: text,
    targetRanges: [new StaticRange({ startContainer: node, startOffset: from, endContainer: node, endOffset: to })]
  })
  node.nodeValue = node.nodeValue!.slice(0, from) + text + node.nodeValue!.slice(to)
  inputEvent(wg, 'input', {
    inputType: 'insertText',
    data: text
  })
}

function findText(wg: Wordgard, text: string): Text {
  const t = document.createTreeWalker(wg.contentDOM, NodeFilter.SHOW_TEXT)
  for (let node = t.nextNode(); node; node = t.nextNode()) if (node.nodeValue == text) return node as Text
  throw new Error(`Failed to find text node ${JSON.stringify(text)}`)
}

describe('DOM change tracking', () => {
  it('can combine stacked changes', () => {
    const wg = tempEditor(doc(p('123456')))
    const txt = findText(wg, '123456')
    domDel(wg, txt, 1, 2)
    domIns(wg, txt, '--', 4)
    ist(wg.state.doc, doc(p('1345--6')), eq)
    ist(wg.posAtDOM(txt, 0), 1)
    ist(wg.posAtDOM(txt, 2), 3)
    ist(wg.posAtDOM(txt, 7), 8)
    const para = txt.parentNode!
    ist(wg.posAtDOM(para, 0), 1)
    ist(wg.posAtDOM(para, 1), 8)
  })

  it('properly corrects for changes in earlier nodes', () => {
    const wg = tempEditor(doc(p('abc'), p('def')))
    const abc = findText(wg, 'abc'),
      def = findText(wg, 'def')
    domDel(wg, abc, 1, 2)
    domIns(wg, def, 'xyz', 0)
    ist(wg.state.doc, doc(p('ac'), p('xyzdef')), eq)
    ist(wg.posAtDOM(def, 0), 5)
    ist(wg.posAtDOM(def, 6), 11)
  })

  it('properly corrects for changes in adjacent nodes', () => {
    const wg = tempEditor(doc(p('abc', em('def'))))
    const abc = findText(wg, 'abc'),
      def = findText(wg, 'def')
    domIns(wg, abc, 'jk', 3)
    domIns(wg, def, 'xyz', 3)
    ist(wg.posAtDOM(def, 0), 6)
    ist(wg.posAtDOM(def, 6), 12)
  })

  it('integrates non-DOM changes', () => {
    const wg = tempEditor(doc(p('abc'), p('def')))
    const def = findText(wg, 'def')
    wg.dispatch({ changes: { from: 2, to: 4 } })
    domIns(wg, def, 'xyz', 0)
    ist(wg.state.doc, doc(p('a'), p('xyzdef')), eq)
    ist(wg.posAtDOM(def, 0), 4)
    ist(wg.posAtDOM(def, 6), 10)
  })

  it('can handle DOM changes being interpreted differently', () => {
    const wg = tempEditor(
      doc(p('abc'), p('def')),
      Command.handler(insertText, (wg, { from, insert }) => {
        return { changes: { from, insert: [Leaf.text(`${insert}?`)] } }
      })
    )
    const abc = findText(wg, 'abc'),
      def = findText(wg, 'def')
    domIns(wg, abc, 'x', 1)
    domDel(wg, def, 1, 2)
    ist(wg.state.doc, doc(p('ax?bc'), p('df')), eq)
    ist(wg.posAtDOM(def, 0), 8)
    ist(wg.posAtDOM(def, 2), 10)
  })

  it('works for newly created text nodes', () => {
    const wg = tempEditor(doc(p('abc')))
    const nw = wg.contentDOM.firstChild!.appendChild(document.createTextNode(''))
    domIns(wg, nw, 'x', 0)
    domDel(wg, findText(wg, 'abc'), 0, 1)
    ist(wg.state.doc, doc(p('bcx')), eq)
    ist(wg.posAtDOM(nw, 0), 3)
    ist(wg.posAtDOM(nw, 1), 4)
  })

  it('survives random input', () => {
    for (let i = 0; i < 20; i++) {
      const content: (Node | string)[] = []
      for (let i = 0; i < 10; i++) content.push(i % 2 ? em(rWord()) : rWord())
      const d = doc(p(...content)),
        wg = tempEditor(d)
      const walk = document.createTreeWalker(wg.contentDOM, NodeFilter.SHOW_TEXT)
      const textNodes: Text[] = []
      for (let node = walk.nextNode(); node; node = walk.nextNode()) textNodes.push(node as Text)
      for (let j = 0; j < 10; j++) {
        const sel = r(5)
        if (sel == 0) {
          const from = r(wg.state.doc.length - 3) + 1
          wg.dispatch({ changes: { from, to: from + 1 } })
        } else if (sel == 1) {
          const from = r(wg.state.doc.length - 2) + 1
          wg.dispatch({ changes: { from, insert: [Leaf.text(rWord())] } })
        } else if (sel == 2) {
          const txt = textNodes[r(textNodes.length)]!
          if (txt.nodeValue && wg.contentDOM.contains(txt)) {
            const from = r(txt.nodeValue.length - 1),
              to = from + 1
            domDel(wg, txt, from, to)
          }
        } else if (sel == 3) {
          const txt = textNodes[r(textNodes.length)]!
          if (wg.contentDOM.contains(txt)) domIns(wg, txt, rLetter(), r(txt.nodeValue!.length))
        } else if (!r(3)) {
          wg.flush()
        }
      }
    }
  })
})

describe('layout reads during native input', () => {
  // The browser applies an allowed insertion after the beforeinput handlers return, at the
  // position that the event saw. A listener that reads layout in between must not redraw the
  // DOM: a redraw shows the typed character, the browser adds it again, and the next
  // character goes between the two.
  it('do not redraw between beforeinput and input', () => {
    const wg = requireFocus(
      tempEditor(doc(p('12', 0, '34')), [
        Wordgard.transactionListener.of((_trs, editor) => {
          editor.coordsAtPos(1)
        })
      ])
    )
    wg.flush()
    for (const char of ['x', 'y', 'z']) {
      const sel = document.getSelection()!
      const node = sel.focusNode as Text,
        offset = sel.focusOffset
      inputEvent(wg, 'beforeinput', {
        inputType: 'insertText',
        data: char,
        targetRanges: [
          new StaticRange({ startContainer: node, startOffset: offset, endContainer: node, endOffset: offset })
        ]
      })
      node.insertData(offset, char)
      document.getSelection()!.collapse(node, offset + 1)
      inputEvent(wg, 'input', { inputType: 'insertText', data: char })
    }
    wg.flush()
    ist(wg.state.doc, doc(p('12xyz34')), eq)
    ist(wg.contentDOM.textContent, '12xyz34')
  })
})

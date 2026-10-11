import { describe, it } from './runner'
import { Wordgard } from '../../../src/core/editor'
import { Leaf } from '../../../src/core/doc'
import { Strong } from '../../../src/core/types'
import { GardSelection } from '../../../src/core/state'
import browser from '../../../src/core/editor/browser'
import ist from 'ist'
import { tempEditor, requireFocus } from './tempview'
import { basicBuilders, eq } from '../schema'
const { doc, p, strong, em } = basicBuilders

function compositionEvent(wg: Wordgard, type: string) {
  wg.contentDOM.dispatchEvent(new CompositionEvent(type))
}

function inputEvent(wg: Wordgard, type: string, init: InputEventInit) {
  const event = new InputEvent(type, init)
  // Safari doesn't support the targetRanges option
  if (init.targetRanges && !event.getTargetRanges().length) {
    event.getTargetRanges = () => init.targetRanges!
  }
  wg.contentDOM.dispatchEvent(event)
}

type CompositionUpdate = [number, number, string, () => Text] | [number, number, string]

type UpdateArg = CompositionUpdate | { run: () => void }

function selEnd(node: Node) {
  document.getSelection()!.collapse(node, node.nodeValue!.length)
  return node as Text
}

// Replay the events that WebKit fires when it ends a composition (see
// WebKit's LayoutTests/fast/events/input-events-ime-composition.html):
// a deleteCompositionText event that cannot be canceled, then, when
// text is committed, an insertFromComposition event that can be
// canceled, followed (in `compose`) by compositionend. `from` and `to`
// are offsets of the composed text in `node`. When `removeNode` is
// true, the deletion removes the text node and leaves a placeholder
// <br>, as WebKit does when a textblock becomes empty.
function webkitEnd(wg: Wordgard, node: Text, from: number, to: number, commit: string | null, removeNode = false) {
  const sel = document.getSelection()!
  // Chrome reports unknown input types (including these) as "" on
  // synthetic events, so set the type explicitly.
  const fire = (type: string, init: InputEventInit) => {
    const event = new InputEvent(type, init)
    if (event.inputType != init.inputType) Object.defineProperty(event, 'inputType', { value: init.inputType })
    if (init.targetRanges && !event.getTargetRanges().length) event.getTargetRanges = () => init.targetRanges!
    wg.contentDOM.dispatchEvent(event)
    return event
  }
  fire('beforeinput', {
    inputType: 'deleteCompositionText',
    isComposing: true,
    cancelable: false,
    targetRanges: [new StaticRange({ startContainer: node, startOffset: from, endContainer: node, endOffset: to })]
  })
  const parent = node.parentNode!
  let at: StaticRange
  if (removeNode) {
    const index = Array.prototype.indexOf.call(parent.childNodes, node)
    node.remove()
    parent.insertBefore(document.createElement('br'), parent.childNodes[index] || null)
    sel.collapse(parent, index)
    at = new StaticRange({ startContainer: parent, startOffset: index, endContainer: parent, endOffset: index })
  } else {
    node.nodeValue = node.nodeValue!.slice(0, from) + node.nodeValue!.slice(to)
    sel.collapse(node, from)
    at = new StaticRange({ startContainer: node, startOffset: from, endContainer: node, endOffset: from })
  }
  fire('input', { inputType: 'deleteCompositionText', isComposing: true })
  if (commit == null) return
  const event = fire('beforeinput', {
    inputType: 'insertFromComposition',
    data: commit,
    isComposing: true,
    cancelable: true,
    targetRanges: [at]
  })
  // The editor inserts the committed text itself
  ist(event.defaultPrevented)
}

function compose(
  wg: Wordgard,
  start: UpdateArg | (() => Text),
  ...args: (UpdateArg | { end?: (node: Text) => void; beforeEnd?: (node: Text) => void; cancel?: boolean })[]
) {
  const last = args[args.length - 1]!
  const [updates, options] =
    Array.isArray(last) || 'run' in last
      ? [args as UpdateArg[], {}]
      : [args.slice(0, args.length - 1) as UpdateArg[], last as any]

  ist(!wg.composing)
  compositionEvent(wg, 'compositionstart')
  ist(wg.composing)
  let node!: Text
  const sel = document.getSelection()!
  for (let i = -1; i < updates.length; i++) {
    let update: UpdateArg | undefined
    if (i < 0) {
      if (typeof start == 'function') node = start()
      else update = start
    } else {
      update = updates[i]
    }
    if (!update) {
    } else if ('run' in update) {
      update.run()
    } else {
      compositionEvent(wg, 'compositionupdate')
      const [from, to, text] = update
      let fromDOM = wg.domAtPos(from, -1)
      if (fromDOM.node.nodeType != 3 || (node && node != fromDOM.node)) fromDOM = wg.domAtPos(from, 1)
      const toDOM = from == to ? fromDOM : wg.domAtPos(to, -1)
      inputEvent(wg, 'beforeinput', {
        inputType: 'insertCompositionText',
        data: text,
        isComposing: true,
        targetRanges: [
          new StaticRange({
            startContainer: fromDOM.node,
            startOffset: fromDOM.offset,
            endContainer: toDOM.node,
            endOffset: toDOM.offset
          })
        ]
      })
      if (update.length == 4) {
        node = update[3]()
      } else {
        node = fromDOM.node as Text
        if (node.nodeType != 3) throw new Error("Didn't find a composition text node")
        node.nodeValue =
          node.nodeValue!.slice(0, fromDOM.offset) + text + node.nodeValue!.slice(fromDOM.offset + (to - from))
        sel.collapse(node, fromDOM.offset + text.length)
      }
      inputEvent(wg, 'input', { inputType: 'insertCompositionText', data: text, isComposing: true })
    }

    const { focusNode, focusOffset } = sel
    const stack = []
    for (let p = node.parentNode; p && p != wg.contentDOM; p = p.parentNode) stack.push(p)

    wg.flush()

    if (options.cancel && i == updates.length - 1) {
      ist(!wg.composing)
    } else {
      for (let p = node.parentNode, i = 0; p && p != wg.contentDOM && i < stack.length; p = p.parentNode, i++) {
        ist(p, stack[i])
      }
      ist(node.parentNode && wg.contentDOM.contains(node.parentNode))
      ist(sel.focusNode, focusNode)
      ist(sel.focusOffset, focusOffset)
      if (update) ist(wg.compositionStarted)
    }
  }
  if (options.beforeEnd) options.beforeEnd(node)
  compositionEvent(wg, 'compositionend')
  if (options.end) options.end(node)
  wg.flush()
  ist(!wg.composing)
}

describe('composition', () => {
  it('starts at a selection that the editor set and has not drawn yet', () => {
    const wg = requireFocus(tempEditor(doc(p('one'), p('two'))))
    wg.flush()
    wg.dispatch({ selection: GardSelection.cursor(9) })
    compositionEvent(wg, 'compositionstart')
    const sel = document.getSelection()!
    ist(wg.posAtDOM(sel.focusNode!, sel.focusOffset), 9)
    compositionEvent(wg, 'compositionend')
  })

  it('supports composition inside existing text', () => {
    const wg = requireFocus(tempEditor(doc(p('a', 0, 'b'))))
    compose(wg, [2, 2, '-'], [2, 3, '/'], [2, 3, '*'])
    ist(wg.state.doc, doc(p('a*b')), eq)
  })

  it('supports composition on an empty line', () => {
    const wg = requireFocus(tempEditor(doc(p('.'), p(0))))
    compose(
      wg,
      [4, 4, 'a', () => selEnd(wg.contentDOM.querySelectorAll('p')[1]!.appendChild(document.createTextNode('a')))],
      [5, 5, 'b'],
      [6, 6, 'c']
    )
    ist(wg.state.doc, doc(p('.'), p('abc')), eq)
  })

  it('supports composition at end of block in existing node', () => {
    const wg = requireFocus(tempEditor(doc(p('foo', 0))))
    compose(wg, [4, 4, '!'], [5, 5, '?'])
    ist(wg.state.doc, doc(p('foo!?')), eq)
  })

  it('supports composition at end of block in a new node', () => {
    const wg = requireFocus(tempEditor(doc(p('foo', 0))))
    compose(
      wg,
      [4, 4, '!', () => selEnd(wg.contentDOM.firstChild!.appendChild(document.createTextNode('!')))],
      [5, 5, '?']
    )
    ist(wg.state.doc, doc(p('foo!?')), eq)
  })

  it('supports composition at start of block in a new node', () => {
    const wg = requireFocus(tempEditor(doc(p('foo'))))
    compose(
      wg,
      [
        1,
        1,
        '!',
        () => {
          const p = wg.contentDOM.firstChild!
          return selEnd(p.insertBefore(document.createTextNode('!'), p.firstChild))
        }
      ],
      [2, 2, '?']
    )
    ist(wg.state.doc, doc(p('!?foo')), eq)
  })

  it('supports composition at start of line', () => {
    const wg = requireFocus(tempEditor(doc(p('c'))))
    compose(wg, [1, 1, 'b'], [1, 1, 'a'])
    ist(wg.state.doc, doc(p('abc')), eq)
  })

  it('handles replacement of existing words', () => {
    const wg = requireFocus(tempEditor(doc(p('one two three'))))
    compose(wg, [5, 8, 'five'], [5, 9, 'seven'], [5, 10, 'zero'])
    ist(wg.state.doc, doc(p('one zero three')), eq)
  })

  it('can compose inside a wrapping mark', () => {
    const wg = requireFocus(tempEditor(doc(p('a', strong('b', 0, 'c')))))
    compose(wg, [3, 3, '-'], [4, 4, '$'])
    ist(wg.contentDOM.innerHTML, '<p>a<strong>b-$c</strong></p>')
    ist(wg.state.doc, doc(p('a', strong('b-$c'))), eq)
  })

  it('can compose at the end of a wrapping mark', () => {
    const wg = requireFocus(tempEditor(doc(p('a', strong('bc'), 0, 'd'))))
    compose(wg, () => selEnd(wg.domAtPos(3).node), [4, 4, '-'], [5, 5, '$'])
    ist(wg.contentDOM.innerHTML, '<p>a<strong>bc-$</strong>d</p>')
    ist(wg.state.doc, doc(p('a', strong('bc-$'), 'd')), eq)
  })

  it('can compose at the start of a wrapping mark', () => {
    const wg = requireFocus(tempEditor(doc(p('a', 0, strong('bc'), 'd'))))
    compose(wg, () => selEnd(wg.domAtPos(3).node), [2, 2, '-'], [3, 3, '$'])
    ist(wg.contentDOM.innerHTML, '<p>a-$<strong>bc</strong>d</p>')
    ist(wg.state.doc, doc(p('a-$', strong('bc'), 'd')), eq)
  })

  it('handles composition in a wrapper that has multiple children', () => {
    const wg = requireFocus(tempEditor(doc(p('one ', em('two', 0, strong(' three'))))))
    compose(wg, [8, 8, 'o'], [9, 9, 'o'], [10, 10, 'w'])
    ist(wg.state.doc, doc(p('one ', em('twooow', strong(' three')))), eq)
  })

  it('supports composition in a cursor wrapper', () => {
    const wg = requireFocus(tempEditor(doc(p(0))))
    wg.dispatch({ selection: GardSelection.Text.create({ anchor: 1, marks: [Strong] }) })
    compose(
      wg,
      [
        1,
        1,
        'a',
        () => {
          ist(wg.contentDOM.innerHTML, `<p><strong><img class="wg-buffer"></strong></p>`)
          const sel = window.getSelection()!
          ist(sel.getRangeAt(0).comparePoint(wg.contentDOM.firstChild!.firstChild!, 1), -1)
          return selEnd(wg.contentDOM.firstChild!.appendChild(document.createTextNode('a')))
        }
      ],
      [2, 2, 'b'],
      [3, 3, 'c']
    )
    ist(wg.contentDOM.innerHTML, '<p><strong>abc</strong></p>')
    ist(wg.state.doc, doc(p(strong('abc'))), eq)
  })

  it('can handle API-driven insertions around the composition', () => {
    const wg = requireFocus(tempEditor(doc(p('a', 0, 'b'))))
    compose(
      wg,
      [2, 2, '-'],
      { run: () => wg.dispatch({ changes: { from: 1, insert: [Leaf.text('!')] } }) },
      [3, 4, '×'],
      { run: () => wg.dispatch({ changes: { from: 5, insert: [Leaf.text('?')] } }) },
      [3, 4, '⇒']
    )
    ist(wg.state.doc, doc(p('!a⇒b?')), eq)
    ist(wg.contentDOM.innerHTML, '<p>!a⇒b?</p>')
  })

  it('gracefully handles API-produced changes inside the composition', () => {
    const wg = requireFocus(tempEditor(doc(p('ab', 0, 'c'))))
    compose(
      wg,
      [3, 3, '-'],
      {
        run: () => {
          wg.dispatch({ changes: { from: 2, insert: [Leaf.text('!')] } })
          wg.flush()
          ist(wg.contentDOM.innerHTML, '<p>a!b-c</p>')
        }
      },
      { cancel: true }
    )
    ist(wg.state.doc, doc(p('a!b-c')), eq)
  })

  it('gracefully handles starting a composition in a modified text node', () => {
    const wg = requireFocus(tempEditor(doc(p('ab', 0, 'c'))))
    wg.dispatch({ changes: { from: 2, insert: [Leaf.text('/')] } })
    compose(wg, [4, 4, '-'], [4, 5, '×'])
    ist(wg.state.doc, doc(p('a/b×c')), eq)
  })

  it("handles WebKit's commit events when the committed text differs from the composition", () => {
    const wg = requireFocus(tempEditor(doc(p('a', 0, 'b'))))
    compose(wg, [2, 2, 'n'], [2, 3, 'ni'], [2, 4, 'ni h'], [2, 6, 'ni hao'], {
      beforeEnd: node => webkitEnd(wg, node, 1, 7, '你好')
    })
    ist(wg.state.doc, doc(p('a你好b')), eq)
    ist(wg.contentDOM.innerHTML, '<p>a你好b</p>')
  })

  it("handles WebKit's events for a canceled composition", () => {
    const wg = requireFocus(tempEditor(doc(p('a', 0, 'b'))))
    compose(wg, [2, 2, 'n'], [2, 3, 'ni'], { beforeEnd: node => webkitEnd(wg, node, 1, 3, null) })
    ist(wg.state.doc, doc(p('ab')), eq)
    ist(wg.contentDOM.innerHTML, '<p>ab</p>')
  })

  it("handles WebKit's commit events when the composed text node is removed", () => {
    const wg = requireFocus(tempEditor(doc(p('.'), p(0))))
    compose(
      wg,
      [4, 4, 'z', () => selEnd(wg.contentDOM.querySelectorAll('p')[1]!.appendChild(document.createTextNode('z')))],
      [4, 5, 'zh'],
      { beforeEnd: node => webkitEnd(wg, node, 0, 2, '中', true) }
    )
    ist(wg.state.doc, doc(p('.'), p('中')), eq)
    ist(wg.contentDOM.innerHTML, '<p>.</p><p>中</p>')
  })

  it('keeps marks when WebKit commits at the end of a mark', () => {
    const wg = requireFocus(tempEditor(doc(p(strong('bold'), 0, ' rest'))))
    compose(wg, () => selEnd(wg.domAtPos(3).node), [5, 5, 'j'], [5, 6, 'ji'], {
      beforeEnd: node => webkitEnd(wg, node, 4, 6, '机')
    })
    ist(wg.state.doc, doc(p(strong('bold机'), ' rest')), eq)
  })

  // Desktop Safari fires the keydown of the Enter that commits a
  // composition after compositionend.
  if (browser.safari && !browser.ios) {
    it('ignores the Enter keydown that follows a commit on Safari', () => {
      const wg = requireFocus(tempEditor(doc(p('a', 0, 'b'))))
      compose(wg, [2, 2, 'n'], [2, 3, 'ni'], { beforeEnd: node => webkitEnd(wg, node, 1, 3, 'ni') })
      const enter = new KeyboardEvent('keydown', {
        key: 'Enter',
        code: 'Enter',
        keyCode: 13,
        bubbles: true,
        cancelable: true
      })
      wg.contentDOM.dispatchEvent(enter)
      ist(wg.state.doc, doc(p('anib')), eq)
      wg.contentDOM.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true })
      )
      ist(wg.state.doc, doc(p('ani'), p('b')), eq)
    })
  }

  // FIXME text composition next to widgets

  // FIXME test enter-at-end-of-selection situation (especially on Android)
})

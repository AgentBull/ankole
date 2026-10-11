import { describe, it } from './runner'
import ist from 'ist'
import { Command, deleteCut } from '../../../src/core/command'
import { Wordgard } from '../../../src/core/editor'
import { readClipboard, writeClipboard } from '../../../src/core/editor/clipboard'
import { Leaf, Plot, Slice } from '../../../src/core/doc'
import { GardState } from '../../../src/core/state'
import { basicBuilders, eq, tag } from '../schema'
import { requireFocus, tempEditor } from './tempview'

const { doc, p, pre, br, strong } = basicBuilders

function paste(wg: Wordgard, values: Record<string, string>) {
  const event = new ClipboardEvent('paste', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
  for (const [type, value] of Object.entries(values)) event.clipboardData!.setData(type, value)
  wg.contentDOM.dispatchEvent(event)
  return event
}

function copy(state: GardState, from: number, to: number) {
  const data = new DataTransfer()
  writeClipboard(state, state.doc.slice(from, to), state.doc.contextAt(from), data)
  return data
}

describe('clipboard', () => {
  it('pastes on a paste event without an input event', () => {
    const start = doc(p('a', 0, 'b'))
    const wg = tempEditor(start)
    const event = paste(wg, { 'text/html': '<strong>x</strong>' })
    ist(event.defaultPrevented)
    ist(wg.state.doc, doc(p('a', strong('x'), 'b')), eq)
  })

  it('copies a DOM selection that the editor has not read yet', () => {
    const wg = requireFocus(tempEditor(doc(p('one two'))))
    const text = wg.contentDOM.querySelector('p')!.firstChild!
    getSelection()!.setBaseAndExtent(text, 4, text, 7)
    const event = new ClipboardEvent('copy', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
    wg.contentDOM.dispatchEvent(event)
    ist(event.clipboardData!.getData('text/plain'), 'two')
  })

  it('pastes plain text lines into code as line breaks', () => {
    const start = doc(pre('a', 0, 'b'))
    const wg = tempEditor(start)
    paste(wg, { 'text/plain': 'one\r\ntwo\nthree' })
    ist(wg.state.doc, doc(pre('aone', br, 'two', br, 'threeb')), eq)
  })

  it('deletes a cut through deleteCut, which extensions can handle', () => {
    const wg = requireFocus(
      tempEditor(doc(p('one two')), [
        Command.handler(deleteCut, ({ state }) => ({
          changes: { from: state.selection.from, insert: [Leaf.text('x')] }
        }))
      ])
    )
    const text = wg.contentDOM.querySelector('p')!.firstChild!
    getSelection()!.setBaseAndExtent(text, 4, text, 7)
    const event = new ClipboardEvent('cut', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
    wg.contentDOM.dispatchEvent(event)
    ist(event.clipboardData!.getData('text/plain'), 'two')
    ist(wg.state.doc, doc(p('one xtwo')), eq)
  })

  it('pastes HTML without a text form into code as its text', () => {
    const wg = tempEditor(doc(pre('a', 0, 'b')))
    paste(wg, { 'text/html': '<p>one <strong>two</strong></p><p>three</p>' })
    ist(wg.state.doc, doc(pre('aone two', br, 'threeb')), eq)
  })

  it('does not ask text parsers in code', () => {
    const state = GardState.create({
      doc: doc(pre('x'), p('y')),
      config: Wordgard.clipboardTextParser.of(() => Slice.of([Leaf.text('parsed')]))
    })
    const data = new DataTransfer()
    data.setData('text/plain', 'text')
    ist(readClipboard(state, data, state.doc.resolve(2), false)!.slice, Slice.of([Leaf.text('text')]), eq)
    ist(readClipboard(state, data, state.doc.resolve(5), false)!.slice, Slice.of([Leaf.text('parsed')]), eq)
  })

  it('reads back the exact slice that it writes', () => {
    const d = doc(p('a', 1, '  b'), p('c ', 2, 'd'))
    const state = GardState.create({ doc: d })
    const data = copy(state, tag(d, 1), tag(d, 2))
    ist(/wg-slice=/.test(data.getData('text/html')))
    const read = readClipboard(state, data, state.doc.resolve(1), false)!
    ist(read.slice, d.slice(tag(d, 1), tag(d, 2)), eq)
    ist(read.context.join(), 'Paragraph')
  })

  it('marks inline content that starts with text', () => {
    const d = doc(p('a', 1, 'b  c', 2, 'd'))
    const state = GardState.create({ doc: d })
    const html = copy(state, tag(d, 1), tag(d, 2)).getData('text/html')
    ist(/^<span wg-content="true" wg-slice="[^"]*">b {2}c<\/span>$/.test(html))
  })

  it('parses the HTML when the exact slice does not fit the schema', () => {
    const state = GardState.create({ doc: doc(p('x')) })
    const data = new DataTransfer()
    data.setData('text/html', `<p wg-content="true" wg-slice='[{"type":"Unknown"}]'>a  b</p>`)
    const read = readClipboard(state, data, state.doc.resolve(1), false)!
    ist(read.slice, Slice.of([Leaf.text('a  b')]), eq)
  })

  it('gives clipboard filters the slice context', () => {
    const seen: string[] = []
    const state = GardState.create({
      doc: doc(p('x')),
      config: [
        Wordgard.clipboardInputFilter.of(content => {
          seen.push(content.context.join())
          return { slice: content.slice, context: [] }
        })
      ]
    })
    const data = new DataTransfer()
    data.setData('text/html', '<p>a</p><p>b</p>')
    const read = readClipboard(state, data, state.doc.resolve(1), false)!
    ist(seen.join(), 'Paragraph')
    ist(read.context.length, 0)
    ist(read.slice, Slice.of([Leaf.text('a'), Plot.End, p('b').tag, Leaf.text('b')]), eq)
  })
})

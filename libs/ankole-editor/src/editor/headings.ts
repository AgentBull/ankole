import type { Plot } from '../core/doc'
import { Decoration, Wordgard } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import { GardSelection, GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { editorPhrases } from './phrases'

/** Folding is a reader's view of a section, never a deletion or a collaborative document edit. */
export const toggleHeading = Transaction.Effect.define<number>()
export const foldedHeadings = GardState.Field.define<ReadonlySet<number>>({
  create: () => new Set(),
  update(value, tr) {
    const next = new Set<number>()
    for (const pos of value) {
      const mapped = tr.docChanged ? tr.changes.mapPos(pos, 1) : pos
      if (tr.state.doc.nodeAt(mapped)?.type === T.Heading) next.add(mapped)
    }
    for (const effect of tr.effects) {
      if (effect.is(toggleHeading)) {
        if (next.has(effect.value)) next.delete(effect.value)
        else next.add(effect.value)
      }
    }
    // Search, comments and keyboard navigation can move the selection into hidden content.
    if (tr.selection) {
      for (const section of headingSections(tr.state.doc)) {
        if (tr.selection.head >= section.from && tr.selection.head < section.to) next.delete(section.pos)
      }
    }
    return next
  }
})

export function headingSections(doc: Plot.Doc) {
  const result: { pos: number; from: number; to: number }[] = []
  doc.iterate((node, pos) => {
    if (!node.isPlot || !node.tag.is(T.Heading)) return
    const found = doc.resolveNode(pos)!
    const siblings = found.parent!.node.content
    let to = found.after
    for (const sibling of siblings.slice(found.index + 1)) {
      if (sibling.isPlot && sibling.tag.is(T.Heading) && sibling.tag.param <= node.tag.param) break
      to += sibling.length
    }
    if (to > found.after) result.push({ pos, from: found.after, to })
  })
  return result
}

const foldButton = Widget.define<{ pos: number; folded: boolean; label: string }>({
  render: ({ pos, folded, label }, editor) => {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'heading-fold'
    button.title = label
    button.setAttribute('aria-label', label)
    button.setAttribute('aria-expanded', String(!folded))
    button.onmousedown = event => event.preventDefault()
    button.onclick = () => {
      const node = editor.state.doc.nodeAt(pos)
      if (!node?.isPlot || !node.tag.is(T.Heading)) return
      editor.dispatch({
        effects: toggleHeading.of(pos),
        selection: GardSelection.cursor(pos + node.length - 1)
      })
    }
    return button
  },
  eq: (a, b) => a.pos === b.pos && a.folded === b.folded && a.label === b.label,
  propagateEvent: false,
  inFlow: false
})

export const headingFolding: GardState.Extension = [
  foldedHeadings,
  Decoration.Point.source.of(state => {
    const folded = state.field(foldedHeadings)
    const sections = headingSections(state.doc)
    const hidden = sections.filter(section => folded.has(section.pos))
    const points: [Decoration.Point, number][] = []
    for (const section of sections) {
      if (hidden.some(range => section.pos >= range.from && section.pos < range.to)) continue
      points.push([
        Decoration.Point.widget(
          foldButton.of({
            pos: section.pos,
            folded: folded.has(section.pos),
            label: editorPhrases.get(state, folded.has(section.pos) ? 'heading_expand' : 'heading_collapse')
          }),
          { side: -1 }
        ),
        section.pos + 1
      ])
      points.push([
        Decoration.Point.attributes({
          class: 'foldable-heading',
          'aria-label': (state.doc.nodeAt(section.pos) as Plot).textContent()
        }),
        section.pos
      ])
    }
    state.doc.iterate((node, pos) => {
      if (hidden.some(range => pos >= range.from && pos < range.to)) {
        if (node.isBlock) {
          points.push([Decoration.Point.attributes({ class: 'heading-hidden', 'aria-hidden': 'true' }), pos])
        }
        return false
      }
    })
    return Decoration.Point.set(points.sort((a, b) => a[1] - b[1] || a[0].side - b[0].side))
  }),
  Wordgard.styles({
    '.foldable-heading': { position: 'relative' },
    '.heading-hidden': { display: 'none !important' },
    '.heading-fold': {
      zIndex: '3',
      position: 'absolute',
      insetInlineStart: '-23px',
      top: '0',
      width: '22px',
      height: '100%',
      border: '0',
      padding: '0',
      background: 'transparent',
      color: 'var(--fg-tertiary)',
      cursor: 'pointer',
      fontSize: '16px',
      lineHeight: 'inherit'
    },
    '.heading-fold::before': {
      content: '""',
      display: 'inline-block',
      width: '0',
      height: '0',
      borderTop: '4px solid transparent',
      borderBottom: '4px solid transparent',
      borderLeft: '6px solid currentColor'
    },
    '.heading-fold[aria-expanded="true"]::before': { transform: 'rotate(90deg)' }
  })
]

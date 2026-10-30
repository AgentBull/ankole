import { Decoration, type Wordgard } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import { GardState, Transaction } from '../core/state'

/** A host-authorized peer selection in the current visible document's coordinates. */
export type RemoteSelection = { id: string; name: string; color: string; anchor: number; head: number }

const SAFE_PEER_COLOR =
  /^(?:#[0-9a-fA-F]{3,8}|(?:rgb|rgba|hsl|hsla|oklch|oklab|lch|lab)\([0-9a-zA-Z.,%\s/+-]+\)|var\(--[a-zA-Z0-9_-]+\)|[a-zA-Z]{3,20})$/

function safePeerColor(color: string): string | null {
  const trimmed = color.trim()
  if (!SAFE_PEER_COLOR.test(trimmed) || /\burl\b/i.test(trimmed)) return null
  return trimmed
}

const replace = Transaction.Effect.define<readonly RemoteSelection[]>()
const selections = GardState.Field.define<readonly RemoteSelection[]>({
  create: () => [],
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(replace)) return effect.value
    return transaction.docChanged
      ? value.map(peer => ({
          ...peer,
          anchor: transaction.changes.mapPos(peer.anchor, 1),
          head: transaction.changes.mapPos(peer.head, 1)
        }))
      : value
  }
})
const cursor = Widget.define<RemoteSelection>({
  eq: (a, b) => a.id === b.id && a.name === b.name && a.color === b.color,
  inFlow: false,
  render(peer) {
    const caret = document.createElement('span')
    caret.className = 'editor-remote-caret'
    const color = safePeerColor(peer.color)
    if (color) caret.style.setProperty('--peer-color', color)
    caret.setAttribute('aria-hidden', 'true')
    caret.dataset.peer = peer.id
    const label = caret.appendChild(document.createElement('span'))
    label.className = 'editor-remote-caret-label'
    label.dataset.name = peer.name
    return caret
  }
})
const extension: GardState.Extension = [
  selections,
  Decoration.Point.source.of(state =>
    Decoration.Point.set(
      state
        .field(selections)
        .slice()
        .sort((a, b) => a.head - b.head)
        .map(peer => [Decoration.Point.widget(cursor.of(peer)), peer.head])
    )
  ),
  Decoration.Range.source.of(state =>
    Decoration.Range.set(
      state
        .field(selections)
        .slice()
        .sort((a, b) => Math.min(a.anchor, a.head) - Math.min(b.anchor, b.head))
        .flatMap(peer => {
          const color = safePeerColor(peer.color)
          return peer.anchor === peer.head || !color
            ? []
            : [
                [
                  Decoration.Range.wrapper('span', {
                    attributes: { class: 'editor-remote-selection', style: `--peer-color:${color}` },
                    rank: 95
                  }),
                  Math.min(peer.anchor, peer.head),
                  Math.max(peer.anchor, peer.head)
                ]
              ]
        })
    )
  )
]

/** Decorations stay outside document content, undo history, export, and persistence. */
export function remoteSelections(editor: Wordgard) {
  editor.dispatch({ effects: GardState.appendConfig.of(extension) })
  return (peers: readonly RemoteSelection[]) => {
    const length = editor.state.doc.length
    const valid = peers.flatMap(peer => {
      const color = typeof peer.color === 'string' ? safePeerColor(peer.color) : null
      return color &&
        Number.isInteger(peer.anchor) &&
        Number.isInteger(peer.head) &&
        peer.anchor >= 0 &&
        peer.head >= 0 &&
        peer.anchor <= length &&
        peer.head <= length
        ? [{ ...peer, color }]
        : []
    })
    editor.dispatch({ effects: replace.of(valid) })
  }
}

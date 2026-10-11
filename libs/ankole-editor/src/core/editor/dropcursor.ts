import { GardState, Transaction } from '../state'
import { Wordgard } from './editor'
import { getScale } from './dom'

const setDropCursorPos = Transaction.Effect.define<{ pos: number; side: -1 | 1 } | null>({
  map(pos, mapping) {
    return pos == null ? null : { pos: mapping.mapPos(pos.pos), side: pos.side }
  }
})

const dropCursorPos = GardState.Field.define<{ pos: number; side: -1 | 1 } | null>({
  create() {
    return null
  },
  update(pos, tr) {
    if (pos != null) pos = { pos: tr.changes.mapPos(pos.pos), side: pos.side }
    return tr.effects.reduce((pos, e) => (e.is(setDropCursorPos) ? e.value : pos), pos)
  }
})

const drawDropCursor = Wordgard.Plugin.fromClass(
  class {
    cursor: HTMLElement | null = null

    constructor() {
      this.measure = this.measure.bind(this)
    }

    update(update: Wordgard.Update) {
      const cursorPos = update.state.field(dropCursorPos)
      if (cursorPos) {
        if (!this.cursor) this.cursor = update.editor.scrollDOM.appendChild(document.createElement('wg-dropcursor'))
        if (update.startState.field(dropCursorPos) != cursorPos || update.docChanged || update.geometryChanged) {
          update.editor.scheduleDOMRead(this.measure)
        }
      } else if (this.cursor) {
        this.cursor?.remove()
        this.cursor = null
      }
    }

    measure(wg: Wordgard) {
      const pos = wg.state.field(dropCursorPos)
      const rect = pos != null && wg.coordsAtPos(pos.pos, pos.side)
      if (!rect) {
        wg.scheduleDOMWrite(() => {
          if (this.cursor) this.cursor.style.left = '-100000px'
        })
        return
      }
      const outer = wg.scrollDOM.getBoundingClientRect()
      const { scaleX, scaleY } = getScale(wg.scrollDOM, outer)
      wg.scheduleDOMWrite(() => {
        if (this.cursor) {
          this.cursor.style.left = `${(rect.left - outer.left) / scaleX + wg.scrollDOM.scrollLeft}px`
          this.cursor.style.top = `${(rect.top - outer.top) / scaleY + wg.scrollDOM.scrollTop}px`
          if (rect.left == rect.right) {
            this.cursor.style.height = `${rect.height / scaleY}px`
            this.cursor.style.width = '0'
            this.cursor.className = 'wg-vertical'
          } else {
            this.cursor.style.height = '0'
            this.cursor.style.width = `${Math.min(rect.width, 40) / scaleX}px`
            this.cursor.className = 'wg-horizontal'
          }
        }
      })
    }

    remove() {
      if (this.cursor) this.cursor.remove()
    }
  },
  () => [
    Wordgard.domEventObserver('dragover', (event, wg) => {
      setDropPos(wg, wg.posAtCoords({ x: event.clientX, y: event.clientY }))
    }),
    Wordgard.domEventObserver('dragleave', (event, wg) => {
      if (event.target == wg.contentDOM || !wg.contentDOM.contains(event.relatedTarget as HTMLElement)) {
        setDropPos(wg, null)
      }
    }),
    Wordgard.domEventObserver('dragend', (_event, wg) => {
      setDropPos(wg, null)
    }),
    Wordgard.domEventObserver('drop', (_event, wg) => {
      setDropPos(wg, null)
    })
  ]
)

function setDropPos(wg: Wordgard, pos: { pos: number; side: -1 | 1 } | null) {
  const cur = wg.state.field(dropCursorPos)
  if (pos ? !cur || cur.pos != pos.pos || cur.side != pos.side : cur) wg.dispatch({ effects: setDropCursorPos.of(pos) })
}

/**
 * Draws a cursor at the current drop position when something is
 * being dragged over the editor.
 */
export function dropCursor(): GardState.Extension {
  return [dropCursorPos, drawDropCursor]
}

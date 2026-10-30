import { useEffect, useRef } from 'react'
import { scrollableParents } from '../core/editor/dom'
import { GardSelection } from '../core/state'
import { BlockSelection } from '../editor/block-selection'
import { focusPageEnd } from '../editor/page-end'
import { blockBoxes } from './block-geometry'
import { useEditor } from './context'

function isAtOrBelowFollowingSection(anchor: HTMLElement, container: Element, win: Window, clientY: number): boolean {
  for (let branch: Element | null = anchor; branch && branch !== container; branch = branch.parentElement) {
    for (let next = branch.nextElementSibling; next; next = next.nextElementSibling) {
      if (
        next.getClientRects().length > 0 &&
        win.getComputedStyle(next).pointerEvents !== 'none' &&
        clientY >= next.getBoundingClientRect().top
      ) {
        return true
      }
    }
  }
  return false
}

/** Dragging from page whitespace selects blocks; drags that start in their content edit text. */
export function BlockMarquee({ anchor }: { anchor: HTMLElement }) {
  const editor = useEditor()
  const rectangle = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const document = anchor.ownerDocument
    const win = document.defaultView!
    let stop = () => {}
    const start = (event: MouseEvent) => {
      const target = event.target
      if (event.button || event.ctrlKey || event.metaKey || event.altKey || !(target instanceof Element)) return
      // Only an empty editor surface or its surrounding page can begin a marquee. Controls,
      // text, embedded applications and other editors keep their own pointer behavior.
      if (target !== editor.contentDOM && target !== editor.dom && !target.contains(anchor)) return
      if (
        target !== editor.contentDOM &&
        target !== editor.dom &&
        isAtOrBelowFollowingSection(anchor, target, win, event.clientY)
      ) {
        return
      }
      const origin = anchor.getBoundingClientRect()
      if (event.clientY < origin.top) return
      stop()
      event.preventDefault()
      const doc = editor.state.doc
      const previous = editor.state.selection
      const x = event.clientX - origin.left
      const y = event.clientY - origin.top
      const scroller = scrollableParents(editor.contentDOM).y
      let pointer = event
      let active = false
      const draw = () => {
        if (editor.state.doc !== doc || editor.state.readOnly) return stop()
        const bounds = anchor.getBoundingClientRect()
        const left = Math.min(x + bounds.left, pointer.clientX)
        const right = Math.max(x + bounds.left, pointer.clientX)
        const top = Math.min(y + bounds.top, pointer.clientY)
        const bottom = Math.max(y + bounds.top, pointer.clientY)
        if (!active && Math.max(right - left, bottom - top) < 5) return
        active = true
        const overlay = rectangle.current!
        Object.assign(overlay.style, {
          display: 'block',
          left: `${left - bounds.left}px`,
          top: `${top - bounds.top}px`,
          width: `${right - left}px`,
          height: `${bottom - top}px`
        })
        const hits = [...blockBoxes(editor)].filter(
          ({ rect }) => rect.left < right && rect.right > left && rect.top < bottom && rect.bottom > top
        )
        const selection = hits.length
          ? BlockSelection.of(
              doc,
              hits.map(hit => hit.pos)
            )!
          : GardSelection.near(editor.state, previous.head)
        if (!selection.eq(editor.state.selection)) editor.dispatch({ selection, userEvent: 'select.block' })
        editor.focus()
      }
      const move = (next: MouseEvent) => {
        if (!next.buttons) return stop()
        pointer = next
        draw()
      }
      const up = () => {
        if (active) draw()
        else if (!focusPageEnd(editor, pointer.clientY)) {
          const pos = editor.posAtCoords({ x: pointer.clientX, y: pointer.clientY })
          editor.dispatch({ selection: GardSelection.near(editor.state, pos.pos, pos.side) })
          editor.focus()
        }
        stop()
      }
      const cancel = (key: KeyboardEvent) => {
        if (key.key !== 'Escape') return
        key.preventDefault()
        key.stopPropagation()
        if (editor.state.doc === doc) editor.dispatch({ selection: previous })
        stop()
      }
      stop = () => {
        clearInterval(timer)
        document.removeEventListener('mousemove', move)
        document.removeEventListener('mouseup', up)
        document.removeEventListener('scroll', draw, true)
        document.removeEventListener('keydown', cancel, true)
        win.removeEventListener('blur', stop)
        if (rectangle.current) rectangle.current.style.display = 'none'
      }
      document.addEventListener('mousemove', move)
      document.addEventListener('mouseup', up)
      document.addEventListener('scroll', draw, true)
      document.addEventListener('keydown', cancel, true)
      win.addEventListener('blur', stop)
      const timer = setInterval(() => {
        if (!active) return
        const bounds = scroller?.getBoundingClientRect()
        const top = Math.max(0, bounds?.top ?? 0)
        const bottom = Math.min(win.innerHeight, bounds?.bottom ?? win.innerHeight)
        const speed = pointer.clientY < top + 32 ? -12 : pointer.clientY > bottom - 32 ? 12 : 0
        if (!speed) return
        if (scroller) scroller.scrollTop += speed
        else win.scrollBy(0, speed)
        draw()
      }, 50)
    }
    document.addEventListener('mousedown', start, true)
    return () => {
      stop()
      document.removeEventListener('mousedown', start, true)
    }
  }, [editor, anchor])
  return <div ref={rectangle} className="block-marquee" aria-hidden="true" />
}

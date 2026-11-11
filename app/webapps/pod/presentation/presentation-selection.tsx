import { useRef, type MouseEvent, type PointerEvent } from 'react'
import type { PresentationEngine, PresentationSelection } from './presentation-engine'
import type { PresentationSession } from './presentation-toolbar'

export const PRESENTATION_TEXT_NAVIGATION_KEYS = new Set([
  'ArrowLeft',
  'ArrowRight',
  'ArrowUp',
  'ArrowDown',
  'Home',
  'End'
])

export function useReadOnlyPresentationPointer(
  model: PresentationSession,
  size: { width: number; height: number },
  focus: () => void
) {
  type SlidePointerEvent = Parameters<PresentationEngine['viewPointerEvent']>[0]
  const press = useRef<{ id: number; clientX: number; clientY: number; dragging: boolean } | null>(null)
  const moving = useRef(false)

  const payload = (event: MouseEvent<HTMLCanvasElement>, kind: SlidePointerEvent['kind']): SlidePointerEvent => {
    const rect = event.currentTarget.getBoundingClientRect()
    const scaleX = rect.width > 0 ? size.width / rect.width : 1
    const scaleY = rect.height > 0 ? size.height / rect.height : 1
    return {
      kind,
      x: (event.clientX - rect.left) * scaleX,
      y: (event.clientY - rect.top) * scaleY,
      tol: Math.max(2, 6 * scaleX)
    }
  }

  const dispatch = (...events: SlidePointerEvent[]) =>
    model
      .updateSelection(async engine => {
        const pointer = engine as PresentationEngine
        for (const event of events.slice(0, -1)) await pointer.viewPointerEvent(event)
        return { snapshot: await pointer.viewPointerEvent(events.at(-1)!) }
      })
      .catch(() => undefined)

  const finish = (event: PointerEvent<HTMLCanvasElement>) => {
    const current = press.current
    if (current?.id !== event.pointerId) return
    press.current = null
    const up = payload(event, 'up')
    if (
      event.type === 'pointerup' &&
      (current.dragging || Math.hypot(event.clientX - current.clientX, event.clientY - current.clientY) >= 3)
    ) {
      void dispatch({ ...up, kind: 'drag' }, up)
    } else {
      void dispatch(up)
    }
  }

  return {
    onPointerDown(event: PointerEvent<HTMLCanvasElement>) {
      if (event.button !== 0 || press.current) return
      focus()
      event.currentTarget.setPointerCapture(event.pointerId)
      press.current = { id: event.pointerId, clientX: event.clientX, clientY: event.clientY, dragging: false }
      void dispatch(payload(event, 'down'))
    },
    onPointerMove(event: PointerEvent<HTMLCanvasElement>) {
      const current = press.current
      if (current?.id !== event.pointerId || moving.current) return
      if (!current.dragging && Math.hypot(event.clientX - current.clientX, event.clientY - current.clientY) < 3) return
      current.dragging = true
      moving.current = true
      void dispatch(payload(event, 'drag')).finally(() => {
        moving.current = false
      })
    },
    onPointerUp: finish,
    onPointerCancel: finish,
    onDoubleClick(event: MouseEvent<HTMLCanvasElement>) {
      void dispatch(payload(event, 'doubleclick'))
    }
  }
}

export function PresentationTextHighlight({
  selection,
  size
}: {
  selection?: PresentationSelection
  size: { width: number; height: number }
}) {
  if (!selection?.text_quads?.length) return null
  return (
    <svg
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 size-full"
      viewBox={`0 0 ${size.width} ${size.height}`}
      preserveAspectRatio="none">
      {selection.text_quads.map(quad => {
        const points = quad.map(([x, y]) => `${x},${y}`).join(' ')
        return <polygon key={points} points={points} className="fill-blue-60/30" />
      })}
    </svg>
  )
}

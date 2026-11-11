'use client'

import { useLayoutEffect, useRef, useState, type ComponentProps, type CSSProperties } from 'react'

import { cn } from '../lib/utils'

const HEIGHT_MS = 320
const HEIGHT_EASING = 'cubic-bezier(0.22, 1, 0.36, 1)'

/**
 * The entrance of a step inside a `StepTransition`. The frame applies it to the step it renders; a caller that
 * keeps several steps mounted puts it on each of them. It plays only after the flow has moved once, so the first
 * step of a page renders still.
 */
const stepEnter = 'group-data-moved/step-transition:motion-safe:animate-step-in'

/**
 * The frame of a flow that shows one step at a time, such as a sign-in or a setup form. When `step` changes, the
 * frame glides from the height of the old step to the height of the new one, and the new step comes in out of a
 * soft blur from the side it is heading to.
 *
 * By default the frame renders its children as the current step and replaces them when `step` changes. A flow
 * that must keep a step's state while another step shows sets `keyed={false}`, renders every step itself, and
 * marks each one with `stepEnter`.
 *
 * The frame owns only the motion. The caller moves focus into the new step and chooses `direction`.
 */
function StepTransition({
  step,
  direction = 'forward',
  keyed = true,
  className,
  style,
  children,
  ...props
}: ComponentProps<'div'> & { step: string | number; direction?: 'forward' | 'back'; keyed?: boolean }) {
  const frame = useRef<HTMLDivElement>(null)
  const height = useRef<number | undefined>(undefined)
  const [seen, setSeen] = useState({ step, moved: false })
  if (seen.step !== step) setSeen({ step, moved: true })

  useLayoutEffect(() => {
    const element = frame.current
    if (!element) return
    const from = height.current
    const to = element.offsetHeight
    height.current = to
    if (from === undefined || from === to || typeof element.animate !== 'function') return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const animation = element.animate([{ height: `${from}px` }, { height: `${to}px` }], {
      duration: HEIGHT_MS,
      easing: HEIGHT_EASING
    })
    // Only the height is clipped, so a focus ring at the side of a field stays whole while the frame moves.
    element.style.overflowY = 'clip'
    const release = () => {
      element.style.overflowY = ''
    }
    animation.addEventListener('finish', release)
    animation.addEventListener('cancel', release)
    return () => animation.cancel()
  }, [step])

  // A step can grow or shrink while it is shown, so the frame records its height after every render.
  useLayoutEffect(() => {
    if (frame.current) height.current = frame.current.offsetHeight
  })

  return (
    <div
      ref={frame}
      data-slot="step-transition"
      data-moved={seen.moved || undefined}
      className={cn('group/step-transition', className)}
      style={{ '--step-from': direction === 'back' ? '-8px' : '8px', ...style } as CSSProperties}
      {...props}>
      {keyed ? (
        <div key={step} data-slot="step-transition-step" className={stepEnter}>
          {children}
        </div>
      ) : (
        children
      )}
    </div>
  )
}

export { StepTransition, stepEnter }

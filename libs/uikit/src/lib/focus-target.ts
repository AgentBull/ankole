import type { RefObject } from 'react'

/**
 * ui-sdk takes an element, a selector, a keyword or a function as the place where a popup moves focus, and callers
 * in Ankole usually hold that element in a React ref. The kit therefore also accepts a ref and reads its element only
 * when the popup moves focus, because the element mounts after the render that passes the ref.
 */
type FocusTarget<Target> = Target | RefObject<HTMLElement | null>

function focusTarget<Target>(target: FocusTarget<Target> | undefined) {
  return target && typeof target === 'object' && 'current' in target
    ? () => (target as RefObject<HTMLElement | null>).current
    : (target as Target | undefined)
}

export { focusTarget, type FocusTarget }

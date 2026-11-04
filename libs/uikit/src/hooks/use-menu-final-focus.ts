import { useRef } from 'react'

/** Keep focus in an inline editor opened by a menu; otherwise restore its trigger. */
export function useMenuFinalFocus() {
  const keepFocus = useRef(false)
  const finalFocus = () => {
    const restore = !keepFocus.current
    keepFocus.current = false
    return restore
  }
  return [keepFocus, finalFocus] as const
}

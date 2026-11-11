import { useLayoutEffect, useRef, useState } from 'react'

export type ActionHandlers = Record<string, (params: Record<string, unknown>) => unknown>

/**
 * json-render keeps the action handlers it received on mount. Each returned handler forwards to the handler of
 * the latest render, so an action sees the current props of the component that owns it.
 */
export function useLatestHandlers(handlers: ActionHandlers): ActionHandlers {
  const latest = useRef(handlers)
  useLayoutEffect(() => {
    latest.current = handlers
  })
  const [stable] = useState(() =>
    Object.fromEntries(
      Object.keys(handlers).map(name => [name, (params: Record<string, unknown>) => latest.current[name]?.(params)])
    )
  )
  return stable
}

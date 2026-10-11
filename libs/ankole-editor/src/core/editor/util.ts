import { GardState } from '../state'

export function eqArray<T extends { eq(b: T): boolean }>(a?: readonly T[] | null, b?: readonly T[] | null) {
  if (!a || !b) return a == b
  if (a == b) return true
  if (a.length != b.length) return false
  for (let i = 0; i < a.length; i++) if (!a[i]!.eq(b[i]!)) return false
  return true
}

export const exceptionSink = GardState.Facet.define<(exception: any) => void>()

export function logException(state: GardState, exception: any, context?: string) {
  const handler = state.facet(exceptionSink)
  if (handler.length) handler[0]!(exception)
  else if (window.onerror) window.onerror(String(exception), context, undefined, undefined, exception)
  else if (context) console.error(`${context}:`, exception)
  else console.error(exception)
}

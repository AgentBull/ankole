import { createStateStore, type StateModel, type StateStore } from '@json-render/core'
import { flattenToPointers } from '@json-render/core/store-utils'
import { useEffect, useRef, useState } from 'react'

const NO_STATE: StateModel = {}
const MAX_REMEMBERED = 48
/** The state that readers left in recently shown blocks, by block source. */
const remembered = new Map<string, StateModel>()

const same = (left: unknown, right: unknown) => left === right || JSON.stringify(left) === JSON.stringify(right)

/** Keeps what the reader left in a settled block, so that the same block shows it again when it mounts again. */
export function rememberViewState(code: string, state: StateModel) {
  remembered.delete(code)
  remembered.set(code, state)
  while (remembered.size > MAX_REMEMBERED) remembered.delete(remembered.keys().next().value!)
}

/**
 * Holds the state of one mounted `ui` block. A settled block starts from the state that its reader left when the
 * same block was last on screen, for example before the reader opened another room. While a block streams, state
 * that later lines add or change joins the store, and the values that the reader set elsewhere stay.
 *
 * Two blocks with the same source share what is remembered.
 */
export function useViewState(code: string, streaming: boolean, initial: StateModel = NO_STATE): StateStore {
  const [store] = useState(() => createStateStore((!streaming && remembered.get(code)) || initial))
  const seeded = useRef(flattenToPointers(initial))
  useEffect(() => {
    const next = flattenToPointers(initial)
    const changed = Object.entries(next).filter(([path, value]) => !same(seeded.current[path], value))
    seeded.current = next
    if (changed.length) store.update(Object.fromEntries(changed))
  }, [initial, store])
  useEffect(() => {
    if (streaming) return
    rememberViewState(code, store.getSnapshot())
    return store.subscribe(() => rememberViewState(code, store.getSnapshot()))
  }, [code, streaming, store])
  return store
}

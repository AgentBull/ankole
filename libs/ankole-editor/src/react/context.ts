import { createContext, useContext, useSyncExternalStore } from 'react'
import type { Wordgard } from '../core/editor'
import type { GardState } from '../core/state'
import { editorPhrases, type EditorLabels } from '../editor/phrases'

/** The editor of a `BlockEditor`, the state that its DOM shows, and a subscription to its updates. */
export type EditorHandle = {
  editor: Wordgard
  /**
   * The state that the editor DOM shows. `editor.state` changes as soon as a transaction is
   * dispatched; the DOM, and so this state, follows when the editor draws.
   */
  drawn(): GardState
  /** Called after each editor update, once the DOM shows it. */
  subscribe(listener: () => void): () => void
}

export const EditorContext = createContext<EditorHandle | null>(null)

function useHandle(): EditorHandle {
  const handle = useContext(EditorContext)
  if (!handle) throw new Error('useEditor must be used inside a BlockEditor')
  return handle
}

/** The editor of the enclosing `BlockEditor`. */
export function useEditor(): Wordgard {
  return useHandle().editor
}

/**
 * The editor state that the DOM shows, or a value that `select` reads from it. The component
 * renders again when the value changes after the editor draws, so that it can measure the DOM.
 * `select` must return an equal value for an unchanged state, for example a primitive or a state
 * field value.
 */
export function useEditorState(): GardState
export function useEditorState<T>(select: (state: GardState) => T): T
export function useEditorState<T>(select?: (state: GardState) => T): GardState | T {
  const { drawn, subscribe } = useHandle()
  return useSyncExternalStore(subscribe, () => (select ? select(drawn()) : drawn()))
}

/** Reads interface labels from the same state as the editor menus. */
export function useEditorLabel() {
  const state = useEditorState()
  return (key: keyof EditorLabels) => editorPhrases.get(state, key)
}

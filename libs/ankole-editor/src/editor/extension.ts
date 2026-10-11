import { history } from '../core/history'
import { GardSelection, GardState } from '../core/state'
import { blocks } from '../blocks'
import { parseMarkdown } from '../document/markdown'
import type { Element } from '../document/tree'
import { pageDocument } from './convert'
import { blockKeys } from './block-keys'
import { clipboard } from './clipboard'
import { pageCorrections } from './corrections'
import { links } from './links'
import { listEditing } from './lists'
import { nativeInput } from './native-input'
import { pageEnd } from './page-end'
import { shortcuts } from './shortcuts'
import { tableEditing } from './tables'
import { pageSessions } from './page-session'
import { schemaElements } from './schema'

/** All editing capabilities. The visible editor and headless states use the same assembly. */
export function editorExtension(): GardState.Extension {
  return [
    GardState.schemaElement.of(schemaElements),
    pageCorrections.map(correction => correction.extension),
    history(),
    pageSessions,
    blockKeys,
    listEditing,
    shortcuts,
    links,
    clipboard,
    nativeInput,
    tableEditing,
    pageEnd,
    blocks.map(block => block.extension)
  ]
}

/**
 * The editor state for initial content: Markdown source or a page tree. Invalid Markdown throws
 * `DocumentError`. The caret starts at the end of the page, so that focusing the editor, or
 * inserting before a click, acts there.
 */
export function initialState(initial: string | Element, config: GardState.Extension): GardState {
  const doc = pageDocument(typeof initial === 'string' ? parseMarkdown(initial) : initial)
  const state = GardState.create({ doc, config })
  return state.update({ selection: GardSelection.near(state, doc.length, -1) }).state
}

/** An editor state without a view, with the same assembly as the visible editor. */
export function headlessState(initial: string | Element): GardState {
  return initialState(initial, editorExtension())
}

import { headingFolding } from './headings'
import { history } from '../core/history'
import { GardSelection, GardState } from '../core/state'
import { blocks } from '../blocks'
import { parseMarkdown } from '../document/markdown'
import type { Element } from '../document/tree'
import { normalizedPageDocument, pageDocument } from './convert'
import { blockKeys } from './block-keys'
import { blockSelection, clearCompositionHost, isDiagramOnlyBlock } from './block-selection'
import { clipboard } from './clipboard'
import { codeBlockExtension } from './code-block'
import { commentDraftSelection } from './comments'
import { pageCorrections } from './corrections'
import { isKnowledge } from './knowledge-context'
import { linkViews } from './link-views'
import { links } from './links'
import { listEditing } from './lists'
import { mentions } from './mention'
import { nativeInput } from './native-input'
import { pageEnd } from './page-end'
import { fileUploadField } from './file-upload'
import { shortcuts } from './shortcuts'
import { tableEditing } from './tables'
import { pageSessions } from './page-session'
import { schemaElements } from './schema'
import { compositionComplete } from '../core/editor/input'
import { preparePageUpdate } from './page-update'

/** All editing capabilities. The visible editor and headless states use the same assembly. */
export function editorExtension(): GardState.Extension {
  return [
    GardState.schemaElement.of(schemaElements),
    pageCorrections.map(correction => correction.extension),
    history(),
    pageSessions,
    blockKeys,
    blockSelection,
    listEditing,
    shortcuts,
    links,
    linkViews,
    mentions,
    clipboard,
    commentDraftSelection,
    nativeInput,
    tableEditing,
    headingFolding,
    pageEnd,
    codeBlockExtension,
    fileUploadField,
    blocks.map(block => block.extension),
    compositionComplete.of(editor => {
      if (editor.state.readOnly) return
      const correction = preparePageUpdate(
        editor.state.update({ annotations: clearCompositionHost.of(true), userEvent: 'input.type.compose' })
      )
      if (correction.docChanged) editor.dispatch(correction)
    })
  ]
}

/**
 * The editor state for initial content: Markdown source or a page tree. Invalid Markdown throws
 * `DocumentError`. The caret starts at the end of the page, so that focusing the editor, or
 * inserting before a click, acts there.
 */
export function initialState(initial: string | Element, config: GardState.Extension): GardState {
  const doc = typeof initial === 'string' ? normalizedPageDocument(parseMarkdown(initial)) : pageDocument(initial)
  const state = GardState.create({ doc, config })
  const near = GardSelection.near(state, doc.length, -1)
  const inDiagramOnly =
    near instanceof GardSelection.Text && !isKnowledge(state) && isDiagramOnlyBlock(doc.resolve(near.from).parent.node)
  return state.update({ selection: inDiagramOnly ? GardSelection.cursor(doc.length, -1) : near }).state
}

/** An editor state without a view, with the same assembly as the visible editor. */
export function headlessState(initial: string | Element): GardState {
  return initialState(initial, editorExtension())
}

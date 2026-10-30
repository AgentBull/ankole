import { GardState, Transaction } from '../core/state'
import { hostFacet } from './host-context'

/** Open the file upload panel at a document position. */
export const openFileUpload = Transaction.Effect.define<number>()
/** Close the file upload panel. */
export const closeFileUpload = Transaction.Effect.define<null>()

/**
 * The position that anchors the file upload panel, or null while the panel is closed. The `file`
 * menu entry inserts nothing into the document: the host turns the chosen files into its own
 * resources, so only the panel's anchor lives in editor state.
 */
export const fileUploadField = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    let pos = value !== null && tr.docChanged ? tr.changes.mapPos(value, -1) : value
    for (const effect of tr.effects) {
      if (effect.is(openFileUpload)) pos = effect.value
      else if (effect.is(closeFileUpload)) pos = null
    }
    return tr.state.readOnly ? null : pos
  }
})

/** Whether the host accepts files, which decides whether the menus offer `file`. */
export const acceptsFiles = (state: GardState) => !!state.facet(hostFacet)?.acceptFiles

/** The change that opens the panel at the selection head. */
export function fileUploadSpec(state: GardState): Transaction.Spec | null {
  if (state.readOnly || !acceptsFiles(state)) return null
  return { effects: openFileUpload.of(state.selection.head) }
}

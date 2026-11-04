import { t } from 'i18next'
import { toast } from '@ankole/uikit'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { decodeClipboard, encodeClipboard, type ClipboardPayload } from '../state/spreadsheet-clipboard'
import { decodeTSV, rangeName, selectionRect, type PasteMode } from '../state/spreadsheet-grid'
import { displaySize, preparePicture } from './spreadsheet-pictures'

/** The last copy of each session, for pastes that cannot read the system clipboard. */
const lastCopies = new WeakMap<SpreadsheetSession, { text: string; payload: ClipboardPayload }>()

/**
 * Copies or cuts the selection to the system clipboard as text and as an HTML table that carries
 * the kernel's block. A cut moves the cells when this tab pastes them.
 */
export async function copySelection(model: SpreadsheetSession, pageID: string, cut: boolean) {
  const copied = model.copy(cut)
  const encoded = copied.then(result => {
    if (!result) return undefined
    const source = { pageID, sheetID: result.sheetID, range: rangeName(result.rect), cut: result.cut }
    const clip = encodeClipboard(result.block, source)
    lastCopies.set(model, { text: clip.text, payload: { version: 1, source, block: result.block } })
    return clip
  })
  try {
    // The clipboard item resolves later, so the browser keeps the user's activation for the write.
    await navigator.clipboard.write([
      new ClipboardItem({
        'text/plain': encoded.then(clip => new Blob([clip?.text ?? ''], { type: 'text/plain' })),
        'text/html': encoded.then(clip => new Blob([clip?.html ?? ''], { type: 'text/html' }))
      })
    ])
  } catch {
    const clip = await encoded
    try {
      if (clip) await navigator.clipboard.writeText(clip.text)
    } catch {
      toast.error(t('pod.spreadsheet.copy_failed'))
    }
  }
}

/** Pastes clipboard contents into the selection: an Ankole block, an HTML table, text, or an image. */
export async function pasteContents(
  model: SpreadsheetSession,
  pageID: string,
  contents: { html?: string; text?: string; image?: Blob },
  mode: PasteMode = 'all'
) {
  const decoded = contents.html ? decodeClipboard(contents.html) : {}
  if (decoded.payload) {
    const { source, block } = decoded.payload
    return model.paste(block, mode, source.pageID === pageID ? source.cut : undefined)
  }
  // Text pasted with Ctrl+Shift+V loses its HTML; this tab's own copy still knows its block.
  const own = lastCopies.get(model)
  if (own && !decoded.rows && contents.text !== undefined && contents.text === own.text) {
    return model.paste(own.payload.block, mode, mode === 'all' ? own.payload.source.cut : undefined)
  }
  const rows = decoded.rows ?? (contents.text ? decodeTSV(contents.text) : undefined)
  if (rows?.length && mode !== 'formats') {
    const { r0, c0 } = selectionRect(model.selection.peek())
    return model.setValues({ row: r0, col: c0 }, rows)
  }
  if (contents.image) return insertPicture(model, contents.image, 'floating')
  return undefined
}

/**
 * Reads the system clipboard for the context menu and the paste shortcuts the browser does not
 * turn into a paste event. Without permission, this tab's last copy serves instead.
 */
export async function pasteFromClipboard(model: SpreadsheetSession, pageID: string, mode: PasteMode) {
  try {
    const items = await navigator.clipboard.read()
    const contents: { html?: string; text?: string; image?: Blob } = {}
    for (const item of items) {
      if (item.types.includes('text/html')) contents.html = await (await item.getType('text/html')).text()
      if (item.types.includes('text/plain')) contents.text = await (await item.getType('text/plain')).text()
      const image = item.types.find(type => type.startsWith('image/'))
      if (image) contents.image = await item.getType(image)
    }
    return await pasteContents(model, pageID, contents, mode)
  } catch {
    const own = lastCopies.get(model)
    if (own) return model.paste(own.payload.block, mode, own.payload.source.cut)
    toast.info(t('pod.spreadsheet.paste_with_keyboard'))
    return undefined
  }
}

/**
 * Inserts an image file at the active cell, floating over the grid or placed in the cell. Images
 * the browser cannot read, or that stay too large after shrinking, are refused with a message.
 */
export async function insertPicture(model: SpreadsheetSession, file: Blob, kind: 'floating' | 'cell') {
  let prepared: Awaited<ReturnType<typeof preparePicture>>
  try {
    prepared = await preparePicture(file, file instanceof File ? file.name.replace(/\.[^.]+$/, '') : '')
  } catch {
    toast.error(t('pod.spreadsheet.picture_unreadable'))
    return undefined
  }
  const cell = model.selection.peek().anchor
  if (kind === 'cell') return model.setCellPicture(cell, prepared.picture)
  const size = displaySize(prepared.width, prepared.height)
  return model.insertImage(
    { cell: rangeName({ r0: cell.row, c0: cell.col, r1: cell.row, c1: cell.col }), dx: 0, dy: 0, ...size },
    prepared.picture
  )
}

import { t } from 'i18next'
import {
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger
} from '@ankole/uikit'
import { rangeName, selectedLines, selectionRect, type PasteMode } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { chooseLocalFile } from '../native-transfers'
import { copySelection, insertPicture, pasteFromClipboard } from './spreadsheet-clipboard-actions'

/** What the press that opened the context menu hit. */
export type MenuKind = 'cells' | 'picture' | 'rows' | 'cols' | 'image'

/** Actions on the picture under the menu, which the grid owns. */
export type PictureActions = {
  convert(): void
  view(): void
  download(): void
  remove(): void
}

const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform)
const key = (shortcut: string) =>
  isMac ? shortcut.replace('Ctrl+', '⌘').replace('Alt+', '⌥').replace('Shift+', '⇧') : shortcut

/**
 * The grid's context menu: clipboard and paste special, inserting and deleting rows, columns, and
 * cells, clearing, freezing from a header, and the actions of a picture.
 */
export function SpreadsheetCellMenu({
  kind,
  model,
  pageID,
  onLines,
  onResize,
  picture
}: {
  kind: MenuKind
  model: SpreadsheetSession
  pageID: string
  onLines(axis: 'rows' | 'cols', type: 'line.insert' | 'line.delete', after?: boolean): void
  onResize(axis: 'rows' | 'cols', size: 'hidden' | 'unhide' | 'auto'): void
  picture?: PictureActions
}) {
  const perform = (op: Record<string, unknown>) =>
    void model.perform({ type: String(op.type), ...op, sheet_id: model.activeSheetID.peek() })
  const range = () => rangeName(selectionRect(model.selection.peek()))
  const freeze = (axis: 'rows' | 'cols') => {
    const sheet = model.activeSheet.peek()
    const [rows, cols] = sheet?.freeze ?? [0, 0]
    const lines = selectedLines(selectionRect(model.selection.peek()), axis, model.selection.peek().anchor)
    perform({
      type: 'sheet.freeze',
      rows: axis === 'rows' ? lines.end + 1 : rows,
      cols: axis === 'cols' ? lines.end + 1 : cols
    })
  }
  const paste = (mode: PasteMode) => void pasteFromClipboard(model, pageID, mode)
  const insertImage = async (where: 'floating' | 'cell') => {
    const file = await chooseLocalFile('image/png,image/jpeg,image/gif,image/webp,image/bmp')
    if (file) await insertPicture(model, file, where)
  }

  const pictureItems = picture && (
    <>
      <DropdownMenuItem onClick={picture.convert}>
        {kind === 'image' ? t('pod.spreadsheet.picture_to_cell') : t('pod.spreadsheet.picture_to_floating')}
      </DropdownMenuItem>
      <DropdownMenuItem onClick={picture.view}>{t('pod.spreadsheet.picture_view')}</DropdownMenuItem>
      <DropdownMenuItem onClick={picture.download}>{t('pod.spreadsheet.picture_download')}</DropdownMenuItem>
      <DropdownMenuItem variant="destructive" onClick={picture.remove}>
        {t('pod.spreadsheet.picture_delete')}
      </DropdownMenuItem>
    </>
  )

  if (kind === 'image') return pictureItems

  if (kind === 'rows' || kind === 'cols') {
    const rows = kind === 'rows'
    return (
      <>
        <DropdownMenuItem onClick={() => onLines(kind, 'line.insert')}>
          {rows ? t('pod.spreadsheet.insert_row_above') : t('pod.spreadsheet.insert_column_left')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => onLines(kind, 'line.insert', true)}>
          {rows ? t('pod.spreadsheet.insert_row_below') : t('pod.spreadsheet.insert_column_right')}
        </DropdownMenuItem>
        <DropdownMenuItem variant="destructive" onClick={() => onLines(kind, 'line.delete')}>
          {rows ? t('pod.spreadsheet.delete_rows') : t('pod.spreadsheet.delete_columns')}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={() => onResize(kind, 'hidden')}>
          {rows ? t('pod.spreadsheet.hide_rows') : t('pod.spreadsheet.hide_columns')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => onResize(kind, 'unhide')}>
          {rows ? t('pod.spreadsheet.unhide_rows') : t('pod.spreadsheet.unhide_columns')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => onResize(kind, 'auto')}>
          {rows ? t('pod.spreadsheet.reset_row_height') : t('pod.spreadsheet.reset_column_width')}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={() => freeze(kind)}>
          {rows ? t('pod.spreadsheet.freeze_to_this_row') : t('pod.spreadsheet.freeze_to_this_column')}
        </DropdownMenuItem>
      </>
    )
  }

  return (
    <>
      <DropdownMenuItem onClick={() => void copySelection(model, pageID, true)}>
        {t('pod.spreadsheet.cut')}
        <DropdownMenuShortcut>{key('Ctrl+X')}</DropdownMenuShortcut>
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => void copySelection(model, pageID, false)}>
        {t('pod.spreadsheet.copy')}
        <DropdownMenuShortcut>{key('Ctrl+C')}</DropdownMenuShortcut>
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => paste('all')}>
        {t('pod.spreadsheet.paste')}
        <DropdownMenuShortcut>{key('Ctrl+V')}</DropdownMenuShortcut>
      </DropdownMenuItem>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.paste_special')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={() => paste('values')}>
            {t('pod.spreadsheet.paste_values')}
            <DropdownMenuShortcut>{key('Ctrl+Shift+V')}</DropdownMenuShortcut>
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => paste('formulas')}>{t('pod.spreadsheet.paste_formulas')}</DropdownMenuItem>
          <DropdownMenuItem onClick={() => paste('formats')}>
            {t('pod.spreadsheet.paste_formats')}
            <DropdownMenuShortcut>{key('Ctrl+Alt+V')}</DropdownMenuShortcut>
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuSeparator />
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.insert')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={() => onLines('rows', 'line.insert')}>
            {t('pod.spreadsheet.insert_row_above')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => onLines('rows', 'line.insert', true)}>
            {t('pod.spreadsheet.insert_row_below')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => onLines('cols', 'line.insert')}>
            {t('pod.spreadsheet.insert_column_left')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => onLines('cols', 'line.insert', true)}>
            {t('pod.spreadsheet.insert_column_right')}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => perform({ type: 'cells.insert', range: range(), shift: 'right' })}>
            {t('pod.spreadsheet.insert_cells_right')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => perform({ type: 'cells.insert', range: range(), shift: 'down' })}>
            {t('pod.spreadsheet.insert_cells_down')}
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.delete')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem variant="destructive" onClick={() => onLines('rows', 'line.delete')}>
            {t('pod.spreadsheet.delete_rows')}
          </DropdownMenuItem>
          <DropdownMenuItem variant="destructive" onClick={() => onLines('cols', 'line.delete')}>
            {t('pod.spreadsheet.delete_columns')}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            variant="destructive"
            onClick={() => perform({ type: 'cells.delete', range: range(), shift: 'left' })}>
            {t('pod.spreadsheet.delete_cells_left')}
          </DropdownMenuItem>
          <DropdownMenuItem
            variant="destructive"
            onClick={() => perform({ type: 'cells.delete', range: range(), shift: 'up' })}>
            {t('pod.spreadsheet.delete_cells_up')}
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.clear')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={() => void model.clearContents()}>
            {t('pod.spreadsheet.clear_contents')}
            <DropdownMenuShortcut>Delete</DropdownMenuShortcut>
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => void model.clear('formats')}>
            {t('pod.spreadsheet.clear_formats')}
            <DropdownMenuShortcut>{key('Ctrl+\\')}</DropdownMenuShortcut>
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => void model.clear('all')}>{t('pod.spreadsheet.clear_all')}</DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuSeparator />
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.insert_picture')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={() => void insertImage('floating')}>
            {t('pod.spreadsheet.floating_picture')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => void insertImage('cell')}>
            {t('pod.spreadsheet.cell_picture')}
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      {pictureItems && (
        <>
          <DropdownMenuSeparator />
          {pictureItems}
        </>
      )}
    </>
  )
}

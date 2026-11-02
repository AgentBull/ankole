import { t } from 'i18next'
import {
  Button,
  cn,
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
  Input
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { RiAddLine, RiArrowDownSLine } from '@remixicon/react'
import { useState, type ReactNode } from 'react'
import type { SheetInfo } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { ColorSwatches } from './spreadsheet-toolbar'

const TAB_COLORS = [
  '--color-red-60',
  '--color-orange-50',
  '--color-yellow-30',
  '--color-green-60',
  '--color-teal-60',
  '--color-cyan-60',
  '--color-blue-60',
  '--color-purple-60',
  '--color-magenta-60',
  '--color-gray-60'
]

/** The tabs of the visible sheets in workbook order, with sheet actions for editors. */
export function SpreadsheetSheetTabs({ model }: { model: SpreadsheetSession }) {
  useSignals()
  const sheets = model.sheets.value
  const activeID = model.activeSheetID.value
  const editable = model.editable.value
  const [renaming, setRenaming] = useState<{ id: number; name: string }>()
  const [deleting, setDeleting] = useState<SheetInfo>()
  const visible = sheets.filter(sheet => !sheet.hidden)

  const rename = (id: number, name: string) => {
    setRenaming(undefined)
    const current = sheets.find(sheet => sheet.sheet_id === id)
    if (current && name.trim() && name.trim() !== current.name) {
      void model.perform({ type: 'sheet.rename', sheet_id: id, name: name.trim() })
    }
  }
  /** Moves a sheet past its visible neighbour; hidden sheets keep their places between them. */
  const move = (sheet: SheetInfo, step: -1 | 1) => {
    const position = visible.indexOf(sheet)
    const neighbour = visible[position + step]
    if (neighbour) {
      void model.perform({ type: 'sheet.reorder', sheet_id: sheet.sheet_id, index: sheets.indexOf(neighbour) })
    }
  }
  const actions = (sheet: SheetInfo): ReactNode => (
    <>
      <DropdownMenuItem onClick={() => setRenaming({ id: sheet.sheet_id, name: sheet.name })}>
        {t('pod.spreadsheet.rename_sheet')}
      </DropdownMenuItem>
      <DropdownMenuItem disabled={visible[0] === sheet} onClick={() => move(sheet, -1)}>
        {t('pod.spreadsheet.move_sheet_left')}
      </DropdownMenuItem>
      <DropdownMenuItem disabled={visible.at(-1) === sheet} onClick={() => move(sheet, 1)}>
        {t('pod.spreadsheet.move_sheet_right')}
      </DropdownMenuItem>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>{t('pod.spreadsheet.tab_color')}</DropdownMenuSubTrigger>
        <DropdownMenuSubContent className="w-auto p-3">
          <ColorSwatches
            tokens={TAB_COLORS}
            onPick={color => void model.perform({ type: 'sheet.tab_color', sheet_id: sheet.sheet_id, color })}
          />
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuItem variant="destructive" disabled={visible.length <= 1} onClick={() => setDeleting(sheet)}>
        {t('pod.spreadsheet.delete_sheet')}
      </DropdownMenuItem>
    </>
  )

  return (
    <nav
      aria-label={t('pod.spreadsheet.sheets')}
      className="flex min-h-9 items-center gap-1 overflow-x-auto border-t border-border bg-background-secondary px-2 py-1">
      {editable && (
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={t('pod.spreadsheet.add_sheet')}
          title={t('pod.spreadsheet.add_sheet')}
          onClick={() =>
            void model.perform({ type: 'sheet.insert' }).then(op => {
              if (typeof op?.sheet_id === 'number') model.showSheet(op.sheet_id)
            })
          }>
          <RiAddLine />
        </Button>
      )}
      {visible.map(sheet => {
        const active = sheet.sheet_id === activeID
        if (renaming?.id === sheet.sheet_id) {
          return (
            <Input
              key={sheet.sheet_id}
              autoFocus
              aria-label={t('pod.spreadsheet.sheet_name')}
              className="h-7 w-36"
              value={renaming.name}
              onChange={event => setRenaming({ id: sheet.sheet_id, name: event.target.value })}
              onBlur={() => rename(sheet.sheet_id, renaming.name)}
              onKeyDown={event => {
                if (event.nativeEvent.isComposing) return
                if (event.key === 'Enter') rename(sheet.sheet_id, renaming.name)
                if (event.key === 'Escape') setRenaming(undefined)
              }}
            />
          )
        }
        const tab = (
          <Button
            size="xs"
            variant={active ? 'outline' : 'ghost'}
            aria-pressed={active}
            className={cn('max-w-48 shrink-0 border-b-2', !active && 'border-b-transparent')}
            style={sheet.tab_color ? { borderBottomColor: sheet.tab_color } : undefined}
            onClick={() => model.showSheet(sheet.sheet_id)}
            onDoubleClick={() => editable && setRenaming({ id: sheet.sheet_id, name: sheet.name })}>
            <span className="truncate">{sheet.name}</span>
          </Button>
        )
        if (!editable) return <span key={sheet.sheet_id}>{tab}</span>
        return (
          <span key={sheet.sheet_id} className="flex shrink-0 items-center">
            <ContextMenu>
              <ContextMenuTrigger render={tab} />
              <ContextMenuContent aria-label={t('pod.spreadsheet.sheet_actions', { sheet: sheet.name })}>
                {actions(sheet)}
              </ContextMenuContent>
            </ContextMenu>
            {active && (
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      aria-label={t('pod.spreadsheet.sheet_actions', { sheet: sheet.name })}
                      title={t('pod.spreadsheet.sheet_actions', { sheet: sheet.name })}
                    />
                  }>
                  <RiArrowDownSLine />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="w-52">
                  {actions(sheet)}
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </span>
        )
      })}
      <Dialog open={!!deleting} onOpenChange={open => !open && setDeleting(undefined)}>
        <DialogContent className="pod-dialog" closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.spreadsheet.delete_sheet')}</DialogTitle>
          <p>{t('pod.spreadsheet.delete_sheet_confirmation', { sheet: deleting?.name ?? '' })}</p>
          <DialogFooter>
            <Button variant="ghost" onClick={() => setDeleting(undefined)}>
              {t('pod.content.cancel')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                if (deleting) void model.perform({ type: 'sheet.delete', sheet_id: deleting.sheet_id })
                setDeleting(undefined)
              }}>
              {t('pod.spreadsheet.delete_sheet')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </nav>
  )
}

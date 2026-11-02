import { t } from 'i18next'
import {
  Avatar,
  AvatarFallback,
  AvatarGroup,
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Separator,
  Textarea,
  Toggle,
  ToggleGroup,
  ToggleGroupItem
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiAlignCenter,
  RiAlignLeft,
  RiAlignRight,
  RiArrowGoBackLine,
  RiArrowGoForwardLine,
  RiBold,
  RiBrushLine,
  RiFontColor,
  RiFormatClear,
  RiFunctions,
  RiGridLine,
  RiImageAddLine,
  RiItalic,
  RiLayoutTop2Line,
  RiMergeCellsHorizontal,
  RiNumbersLine,
  RiPaintFill,
  RiSortAsc,
  RiSortDesc,
  RiSplitCellsHorizontal,
  RiStickyNoteLine,
  RiStrikethrough,
  RiTableLine,
  RiTextWrap,
  RiUnderline
} from '@remixicon/react'
import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { isFormula } from '../state/spreadsheet-formula'
import {
  cellName,
  columnName,
  MAX_COLS,
  MAX_ROWS,
  rangeName,
  selectedLines,
  selectionRect,
  type RenderStyle,
  type SpreadsheetOp
} from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { chooseLocalFile } from '../native-transfers'
import { FORMULA_BAR_ATTRIBUTE, SHEET_TAB_ATTRIBUTE, useDraftCaret, useFunctions } from './spreadsheet-cell-editor'
import { insertPicture } from './spreadsheet-clipboard-actions'
import { SpreadsheetFormulaAssist } from './spreadsheet-formula-assist'
import { SpreadsheetFunctionsDialog } from './spreadsheet-functions-dialog'
import { SpreadsheetVersions } from './spreadsheet-versions'

const FONT_SIZES = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36]
const NUMBER_FORMATS = {
  general: 'General',
  number: '#,##0.00',
  percent: '0.00%',
  currency: '¥#,##0.00',
  date: 'yyyy-mm-dd',
  text: '@'
} as const
const TEXT_COLORS = [
  '--color-gray-100',
  '--color-gray-60',
  '--color-red-60',
  '--color-orange-50',
  '--color-yellow-50',
  '--color-green-60',
  '--color-teal-60',
  '--color-blue-60',
  '--color-purple-60',
  '--color-magenta-60'
]
const FILL_COLORS = [
  '--color-gray-20',
  '--color-red-20',
  '--color-orange-20',
  '--color-yellow-20',
  '--color-green-20',
  '--color-teal-20',
  '--color-blue-20',
  '--color-purple-20',
  '--color-magenta-20',
  '--color-yellow-30'
]
const THIN = { style: 'thin' }
/** The functions the formula menu offers before the full list. */
const QUICK_FUNCTIONS = ['SUM', 'AVERAGE', 'COUNT', 'MAX', 'MIN'] as const
const PICTURE_TYPES = 'image/png,image/jpeg,image/gif,image/webp,image/bmp'

/** The `#RRGGBB` value of an Ankole colour token, which a format patch stores. */
export function tokenColor(token: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(token).trim().toUpperCase()
}

export function ColorSwatches({ tokens, onPick }: { tokens: readonly string[]; onPick(color: string | null): void }) {
  return (
    <div className="grid gap-2">
      <div className="grid grid-cols-5 gap-1.5">
        {tokens.map(token => (
          <button
            key={token}
            type="button"
            aria-label={token.replace('--color-', '')}
            className="size-7 rounded-control border border-border focus-visible:outline-offset-1"
            style={{ background: `var(${token})` }}
            onClick={() => onPick(tokenColor(token))}
          />
        ))}
      </div>
      <Button size="sm" variant="outline" onClick={() => onPick(null)}>
        {t('pod.spreadsheet.no_color')}
      </Button>
    </div>
  )
}

function ToolButton({
  label,
  disabled,
  onClick,
  children
}: {
  label: string
  disabled?: boolean
  onClick(): void
  children: ReactNode
}) {
  return (
    <Button size="icon-sm" variant="ghost" aria-label={label} title={label} disabled={disabled} onClick={onClick}>
      {children}
    </Button>
  )
}

/**
 * The format bar, the formula bar, collaborators, and the save state. Every format action patches
 * the selected range with `range.format`; the formula bar edits the same draft as the cell editor.
 */
export function SpreadsheetToolbar({
  model,
  pageID,
  canEdit,
  gridInput
}: {
  model: SpreadsheetSession
  pageID: string
  canEdit: boolean
  gridInput: RefObject<HTMLTextAreaElement | null>
}) {
  useSignals()
  const editable = model.editable.value
  const selection = model.selection.value
  const sheetID = model.activeSheetID.value
  const version = model.version.value
  const draft = model.draft.value
  const members = model.members.value
  const pending = model.pending.value
  const error = model.error.value
  const active = selection.anchor
  const [current, setCurrent] = useState<{ input: string; text: string; style?: RenderStyle; merged: boolean }>({
    input: '',
    text: '',
    merged: false
  })
  const [note, setNote] = useState('')
  const [functionsOpen, setFunctionsOpen] = useState(false)
  const formulaBar = useRef<HTMLInputElement>(null)
  const functions = useFunctions(model)
  const painter = model.painter.value
  useDraftCaret(formulaBar, draft?.caret)

  useEffect(() => {
    let stale = false
    const rect = { r0: active.row, c0: active.col, r1: active.row, c1: active.col }
    void Promise.all([model.cellInputs(sheetID, rect), model.viewport(sheetID, rect)]).then(([inputs, view]) => {
      if (stale) return
      setCurrent({
        input: inputs?.[0]?.[0] ?? '',
        text: view?.cells[0]?.text ?? '',
        style: view?.cells[0] ? view.styles[view.cells[0].style] : undefined,
        merged: Boolean(view?.merges.length)
      })
    })
    return () => {
      stale = true
    }
  }, [model, sheetID, active.row, active.col, version])

  const rect = selectionRect(selection)
  const range = rangeName(rect)
  const perform = (op: SpreadsheetOp) => {
    void model.perform({ ...op, sheet_id: sheetID })
    gridInput.current?.focus({ preventScroll: true })
  }
  const format = (patch: Record<string, unknown>) => perform({ type: 'range.format', range, patch })
  const lines = (axis: 'rows' | 'cols') => selectedLines(rect, axis, active)
  const insert = (axis: 'rows' | 'cols', after: boolean) =>
    perform({ type: 'line.insert', axis, at: after ? lines(axis).end + 1 : lines(axis).start, count: 1 })
  const remove = (axis: 'rows' | 'cols') =>
    perform({ type: 'line.delete', axis, at: lines(axis).start, count: lines(axis).end - lines(axis).start + 1 })
  const sort = (descending: boolean) =>
    perform({ type: 'range.sort', range, keys: [{ col: columnName(rect.c0), ...(descending ? { descending } : {}) }] })
  const borders = (kind: 'all' | 'outside' | 'none') => {
    if (kind !== 'outside') {
      const side = kind === 'all' ? THIN : null
      format({ borders: { left: side, right: side, top: side, bottom: side } })
      return
    }
    const edge = (r0: number, c0: number, r1: number, c1: number, side: string) =>
      perform({ type: 'range.format', range: rangeName({ r0, c0, r1, c1 }), patch: { borders: { [side]: THIN } } })
    edge(rect.r0, rect.c0, rect.r0, rect.c1, 'top')
    edge(rect.r1, rect.c0, rect.r1, rect.c1, 'bottom')
    edge(rect.r0, rect.c0, rect.r1, rect.c0, 'left')
    edge(rect.r0, rect.c1, rect.r1, rect.c1, 'right')
  }
  const style = current.style
  const align =
    style?.h_align === 'left' || style?.h_align === 'center' || style?.h_align === 'right' ? [style.h_align] : []
  const multiRow = rect.r1 > rect.r0 && rect.r1 < MAX_ROWS - 1
  // A formula that points at another sheet keeps showing its text here.
  const formula = draft ? draft.text : current.input
  const [frozenRows, frozenCols] = model.activeSheet.value?.freeze ?? [0, 0]
  const freezeRows = rect.c0 === 0 && rect.c1 === MAX_COLS - 1 ? rect.r1 + 1 : active.row + 1
  const freezeCols = rect.r0 === 0 && rect.r1 === MAX_ROWS - 1 ? rect.c1 + 1 : active.col + 1
  const freeze = (rows: number, cols: number) => perform({ type: 'sheet.freeze', rows, cols })
  const autoSum = async (fn: string) => {
    if (model.draft.peek()) await model.commitEdit()
    await model.autoSum(fn)
    gridInput.current?.focus({ preventScroll: true })
  }
  /** Inserts a function into the formula being typed, or starts one in the active cell. */
  const insertFunction = (name: string) => {
    const editing = model.draft.peek()
    if (editing && isFormula(editing.text)) {
      const text = `${editing.text}${name}(`
      model.type(text, text.length)
    } else {
      const text = `=${name}(`
      model.edit(active, text, text.length)
    }
    gridInput.current?.focus({ preventScroll: true })
  }
  const insertImage = async (kind: 'floating' | 'cell') => {
    const file = await chooseLocalFile(PICTURE_TYPES)
    if (file) await insertPicture(model, file, kind)
    gridInput.current?.focus({ preventScroll: true })
  }
  const status = error
    ? t('pod.spreadsheet.sync_retrying')
    : pending
      ? t('pod.spreadsheet.saving')
      : t('pod.spreadsheet.saved')

  return (
    <div className="flex flex-col border-b border-border">
      <div className="flex min-h-10 flex-wrap items-center gap-0.5 px-2 py-1">
        {canEdit && (
          <>
            <ToolButton
              label={t('pod.spreadsheet.undo')}
              disabled={!editable || !model.canUndo.value}
              onClick={() => void model.undo()}>
              <RiArrowGoBackLine />
            </ToolButton>
            <ToolButton
              label={t('pod.spreadsheet.redo')}
              disabled={!editable || !model.canRedo.value}
              onClick={() => void model.redo()}>
              <RiArrowGoForwardLine />
            </ToolButton>
            {/* One click paints once; a double click keeps painting until Escape. */}
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.format_painter')}
              title={t('pod.spreadsheet.format_painter_hint')}
              disabled={!editable}
              pressed={Boolean(painter)}
              onClick={event => {
                if (event.detail > 1) void model.pickFormats(true)
                else if (painter) model.clearCopied()
                else void model.pickFormats(false)
                gridInput.current?.focus({ preventScroll: true })
              }}>
              <RiBrushLine />
            </Toggle>
            <ToolButton
              label={t('pod.spreadsheet.clear_formats')}
              disabled={!editable}
              onClick={() => perform({ type: 'range.clear', range, mode: 'formats' })}>
              <RiFormatClear />
            </ToolButton>
            <Separator orientation="vertical" className="mx-1 h-5" />
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.bold')}
              title={t('pod.spreadsheet.bold')}
              disabled={!editable}
              pressed={Boolean(style?.bold)}
              onPressedChange={pressed => format({ bold: pressed })}>
              <RiBold />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.italic')}
              title={t('pod.spreadsheet.italic')}
              disabled={!editable}
              pressed={Boolean(style?.italic)}
              onPressedChange={pressed => format({ italic: pressed })}>
              <RiItalic />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.underline')}
              title={t('pod.spreadsheet.underline')}
              disabled={!editable}
              pressed={Boolean(style?.underline)}
              onPressedChange={pressed => format({ underline: pressed })}>
              <RiUnderline />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.strikethrough')}
              title={t('pod.spreadsheet.strikethrough')}
              disabled={!editable}
              pressed={Boolean(style?.strike)}
              onPressedChange={pressed => format({ strike: pressed })}>
              <RiStrikethrough />
            </Toggle>
            <Select
              value={String(style?.font_size ?? 11)}
              disabled={!editable}
              onValueChange={value => {
                if (value) format({ font_size: Number(value) })
              }}>
              <SelectTrigger size="sm" className="w-18" aria-label={t('pod.spreadsheet.font_size')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {[...new Set([...FONT_SIZES, style?.font_size ?? 11])]
                  .sort((a, b) => a - b)
                  .map(size => (
                    <SelectItem key={size} value={String(size)}>
                      {size}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
            <ColorPicker
              label={t('pod.spreadsheet.font_color')}
              disabled={!editable}
              tokens={TEXT_COLORS}
              onPick={color => format({ font_color: color })}>
              <RiFontColor />
            </ColorPicker>
            <ColorPicker
              label={t('pod.spreadsheet.fill_color')}
              disabled={!editable}
              tokens={FILL_COLORS}
              onPick={color => format({ fill_color: color })}>
              <RiPaintFill />
            </ColorPicker>
            <ToggleGroup
              size="sm"
              spacing={0}
              aria-label={t('pod.spreadsheet.horizontal_alignment')}
              disabled={!editable}
              value={align}
              onValueChange={value => {
                const next = value.at(-1)
                format({ h_align: next ?? 'general' })
              }}>
              <ToggleGroupItem
                value="left"
                aria-label={t('pod.spreadsheet.align_left')}
                title={t('pod.spreadsheet.align_left')}>
                <RiAlignLeft />
              </ToggleGroupItem>
              <ToggleGroupItem
                value="center"
                aria-label={t('pod.spreadsheet.align_center')}
                title={t('pod.spreadsheet.align_center')}>
                <RiAlignCenter />
              </ToggleGroupItem>
              <ToggleGroupItem
                value="right"
                aria-label={t('pod.spreadsheet.align_right')}
                title={t('pod.spreadsheet.align_right')}>
                <RiAlignRight />
              </ToggleGroupItem>
            </ToggleGroup>
            <Toggle
              size="sm"
              aria-label={t('pod.spreadsheet.wrap_text')}
              title={t('pod.spreadsheet.wrap_text')}
              disabled={!editable}
              pressed={Boolean(style?.wrap)}
              onPressedChange={pressed => format({ wrap: pressed })}>
              <RiTextWrap />
            </Toggle>
            <ToolMenu label={t('pod.spreadsheet.number_format')} disabled={!editable} icon={<RiNumbersLine />}>
              {(Object.keys(NUMBER_FORMATS) as (keyof typeof NUMBER_FORMATS)[]).map(kind => (
                <DropdownMenuItem key={kind} onClick={() => format({ num_fmt: NUMBER_FORMATS[kind] })}>
                  {t(`pod.spreadsheet.number_formats.${kind}`)}
                </DropdownMenuItem>
              ))}
            </ToolMenu>
            <ToolMenu label={t('pod.spreadsheet.borders')} disabled={!editable} icon={<RiGridLine />}>
              <DropdownMenuItem onClick={() => borders('all')}>{t('pod.spreadsheet.all_borders')}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => borders('outside')}>
                {t('pod.spreadsheet.outside_borders')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => borders('none')}>{t('pod.spreadsheet.no_borders')}</DropdownMenuItem>
            </ToolMenu>
            {current.merged ? (
              <ToolButton
                label={t('pod.spreadsheet.unmerge_cells')}
                disabled={!editable}
                onClick={() => perform({ type: 'range.unmerge', range })}>
                <RiSplitCellsHorizontal />
              </ToolButton>
            ) : (
              <ToolButton
                label={t('pod.spreadsheet.merge_cells')}
                disabled={!editable || (rect.r0 === rect.r1 && rect.c0 === rect.c1)}
                onClick={() => perform({ type: 'range.merge', range })}>
                <RiMergeCellsHorizontal />
              </ToolButton>
            )}
            <Separator orientation="vertical" className="mx-1 h-5" />
            <ToolMenu label={t('pod.spreadsheet.rows_and_columns')} disabled={!editable} icon={<RiTableLine />}>
              <DropdownMenuItem onClick={() => insert('rows', false)}>
                {t('pod.spreadsheet.insert_row_above')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => insert('rows', true)}>
                {t('pod.spreadsheet.insert_row_below')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => insert('cols', false)}>
                {t('pod.spreadsheet.insert_column_left')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => insert('cols', true)}>
                {t('pod.spreadsheet.insert_column_right')}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem variant="destructive" onClick={() => remove('rows')}>
                {t('pod.spreadsheet.delete_rows')}
              </DropdownMenuItem>
              <DropdownMenuItem variant="destructive" onClick={() => remove('cols')}>
                {t('pod.spreadsheet.delete_columns')}
              </DropdownMenuItem>
            </ToolMenu>
            <ToolMenu label={t('pod.spreadsheet.freeze')} disabled={!editable} icon={<RiLayoutTop2Line />}>
              <DropdownMenuItem onClick={() => freeze(1, frozenCols)}>
                {t('pod.spreadsheet.freeze_first_row')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => freeze(frozenRows, 1)}>
                {t('pod.spreadsheet.freeze_first_column')}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => freeze(freezeRows, frozenCols)}>
                {t('pod.spreadsheet.freeze_to_row', { row: freezeRows })}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => freeze(frozenRows, freezeCols)}>
                {t('pod.spreadsheet.freeze_to_column', { column: columnName(freezeCols - 1) })}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => freeze(active.row + 1, active.col + 1)}>
                {t('pod.spreadsheet.freeze_to_cell', { row: active.row + 1, column: columnName(active.col) })}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem disabled={!frozenRows && !frozenCols} onClick={() => freeze(0, 0)}>
                {t('pod.spreadsheet.unfreeze')}
              </DropdownMenuItem>
            </ToolMenu>
            <ToolMenu label={t('pod.spreadsheet.formulas')} disabled={!editable} icon={<RiFunctions />}>
              {QUICK_FUNCTIONS.map(fn => (
                <DropdownMenuItem key={fn} onClick={() => void autoSum(fn)}>
                  {t(`pod.spreadsheet.quick_functions.${fn}`)}
                  <span className="ml-auto font-mono text-xs text-fg-tertiary">{fn}</span>
                </DropdownMenuItem>
              ))}
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => setFunctionsOpen(true)}>
                {t('pod.spreadsheet.all_functions')}
              </DropdownMenuItem>
            </ToolMenu>
            <ToolMenu label={t('pod.spreadsheet.insert_picture')} disabled={!editable} icon={<RiImageAddLine />}>
              <DropdownMenuItem onClick={() => void insertImage('floating')}>
                {t('pod.spreadsheet.floating_picture')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => void insertImage('cell')}>
                {t('pod.spreadsheet.cell_picture')}
              </DropdownMenuItem>
            </ToolMenu>
            <ToolButton
              label={t('pod.spreadsheet.sort_ascending')}
              disabled={!editable || !multiRow}
              onClick={() => sort(false)}>
              <RiSortAsc />
            </ToolButton>
            <ToolButton
              label={t('pod.spreadsheet.sort_descending')}
              disabled={!editable || !multiRow}
              onClick={() => sort(true)}>
              <RiSortDesc />
            </ToolButton>
            <Popover onOpenChange={open => open && setNote('')}>
              <PopoverTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('pod.spreadsheet.note')}
                    title={t('pod.spreadsheet.note')}
                    disabled={!editable}
                  />
                }>
                <RiStickyNoteLine />
              </PopoverTrigger>
              <PopoverContent align="start" className="w-72 gap-3">
                <PopoverTitle>{t('pod.spreadsheet.note_for', { cell: cellName(active) })}</PopoverTitle>
                <Textarea
                  aria-label={t('pod.spreadsheet.note')}
                  value={note}
                  onChange={event => setNote(event.target.value)}
                  rows={3}
                />
                <div className="flex justify-end gap-2">
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() => perform({ type: 'comment.set', cell: cellName(active), text: null })}>
                    {t('pod.spreadsheet.remove_note')}
                  </Button>
                  <Button
                    size="sm"
                    disabled={!note.trim()}
                    onClick={() => perform({ type: 'comment.set', cell: cellName(active), text: note })}>
                    {t('pod.spreadsheet.save_note')}
                  </Button>
                </div>
              </PopoverContent>
            </Popover>
          </>
        )}
        <div className="ml-auto flex items-center gap-2">
          <span role="status" className="text-xs text-fg-tertiary">
            {canEdit ? status : t('pod.spreadsheet.view_only')}
          </span>
          {members.length > 0 && (
            <AvatarGroup aria-label={t('pod.spreadsheet.collaborators')}>
              {members.map(member => (
                <Avatar key={member.uid} size="sm" title={member.name}>
                  <AvatarFallback className="text-white" style={{ background: `var(${member.color})` }}>
                    {member.name.slice(0, 1).toUpperCase()}
                  </AvatarFallback>
                </Avatar>
              ))}
            </AvatarGroup>
          )}
          {canEdit && <SpreadsheetVersions pageID={pageID} />}
        </div>
      </div>
      <div className="flex items-center gap-2 border-t border-border px-2 py-1">
        <span
          className="w-20 shrink-0 truncate font-mono text-xs text-fg-secondary"
          title={t('pod.spreadsheet.name_box')}>
          {cellName(active)}
        </span>
        {/* The canvas has no text to read, so assistive technology hears the active cell's value here. */}
        <p role="status" aria-label={t('pod.spreadsheet.active_cell')} className="sr-only">
          {t('pod.spreadsheet.active_cell_value', { cell: cellName(active), value: current.text })}
        </p>
        <input
          ref={formulaBar}
          {...{ [FORMULA_BAR_ATTRIBUTE]: '' }}
          aria-label={t('pod.spreadsheet.formula_bar')}
          className="h-7 min-w-0 flex-1 rounded-control border border-field-edge bg-field px-2 font-mono text-sm outline-none focus-visible:border-input"
          readOnly={!editable}
          value={formula}
          onFocus={() => {
            if (editable && !model.draft.peek()) model.edit(active, current.input)
          }}
          onChange={event => model.type(event.target.value)}
          onKeyDown={event => {
            if (event.nativeEvent.isComposing) return
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault()
              void model.commitToSelection()
              gridInput.current?.focus({ preventScroll: true })
            } else if (event.key === 'Enter') {
              event.preventDefault()
              void model.commitEdit('down')
              gridInput.current?.focus({ preventScroll: true })
            } else if (event.key === 'Escape') {
              event.preventDefault()
              model.cancelEdit()
              gridInput.current?.focus({ preventScroll: true })
            }
          }}
          onBlur={event => {
            const next = event.relatedTarget
            if (next === gridInput.current || !model.draft.peek()) return
            // The formula keeps waiting while its author picks another sheet to point at.
            if (next instanceof HTMLElement && next.hasAttribute(SHEET_TAB_ATTRIBUTE)) return
            void model.commitEdit()
          }}
        />
        {draft && isFormula(draft.text) && (
          <SpreadsheetFormulaAssist
            input={formulaBar.current}
            text={draft.text}
            functions={functions}
            onChange={(text, caret) => model.type(text, caret)}
          />
        )}
      </div>
      <SpreadsheetFunctionsDialog
        open={functionsOpen}
        onOpenChange={setFunctionsOpen}
        functions={functions}
        onInsert={insertFunction}
      />
    </div>
  )
}

function ToolMenu({
  label,
  disabled,
  icon,
  children
}: {
  label: string
  disabled: boolean
  icon: ReactNode
  children: ReactNode
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={<Button size="icon-sm" variant="ghost" aria-label={label} title={label} disabled={disabled} />}>
        {icon}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56" aria-label={label}>
        {children}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function ColorPicker({
  label,
  disabled,
  tokens,
  onPick,
  children
}: {
  label: string
  disabled: boolean
  tokens: readonly string[]
  onPick(color: string | null): void
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        render={<Button size="icon-sm" variant="ghost" aria-label={label} title={label} disabled={disabled} />}>
        {children}
      </PopoverTrigger>
      <PopoverContent align="start" className="w-auto gap-2 p-3">
        <PopoverTitle>{label}</PopoverTitle>
        <ColorSwatches
          tokens={tokens}
          onPick={color => {
            setOpen(false)
            onPick(color)
          }}
        />
      </PopoverContent>
    </Popover>
  )
}

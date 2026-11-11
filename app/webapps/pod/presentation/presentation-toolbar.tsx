import {
  Avatar,
  AvatarFallback,
  AvatarGroup,
  Button,
  Command,
  CommandDialog,
  CommandEmpty,
  CommandInput,
  CommandItem,
  CommandList,
  CommandShortcut,
  Input,
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
  Spinner,
  Toggle,
  toast
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiAddLine,
  RiAlignCenter,
  RiAlignLeft,
  RiAlignRight,
  RiArrowDownLine,
  RiArrowDownSLine,
  RiArrowGoBackLine,
  RiArrowGoForwardLine,
  RiArrowRightLine,
  RiArrowUpLine,
  RiArrowUpSLine,
  RiBold,
  RiBringForward,
  RiCheckboxBlankCircleLine,
  RiCloseLine,
  RiCommandLine,
  RiDeleteBinLine,
  RiFileCopy2Line,
  RiFileCopyLine,
  RiFilePdf2Line,
  RiFontColor,
  RiImageAddLine,
  RiItalic,
  RiLayoutLeftLine,
  RiPaintFill,
  RiPencilLine,
  RiRectangleLine,
  RiSearchLine,
  RiSendBackward,
  RiSlideshowLine,
  RiStickyNoteLine,
  RiStrikethrough,
  RiTableLine,
  RiText,
  RiUnderline,
  RiZoomInLine,
  RiZoomOutLine
} from '@remixicon/react'
import { t } from 'i18next'
import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { chooseLocalFile } from '../native-transfers'
import { OfficeCollaborationModel, type OfficeCollaborationOptions } from '../office/office-collaboration'
import { OfficeVersions } from '../office/office-versions'
import type { PresentationCommandInfo, PresentationEngine, PresentationSnapshot } from './presentation-engine'

export const MAX_PICTURE_BYTES = 2 * 1024 * 1024

const PICTURE_ACCEPT = 'image/png,image/jpeg,image/gif,image/webp'
const FONT_SIZES = [10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 44, 54, 64, 72]

const TEXT_COLOR_SWATCHES = [
  '#111827',
  '#4B5563',
  '#DC2626',
  '#EA580C',
  '#CA8A04',
  '#16A34A',
  '#0D9488',
  '#2563EB',
  '#7C3AED',
  '#DB2777'
] as const

const SHAPE_FILL_SWATCHES = [
  '#FFFFFF',
  '#E5E7EB',
  '#FEE2E2',
  '#FFEDD5',
  '#FEF9C3',
  '#DCFCE7',
  '#CCFBF1',
  '#DBEAFE',
  '#EDE9FE',
  '#FCE7F3'
] as const

const SHAPE_STROKE_SWATCHES = [
  '#111827',
  '#6B7280',
  '#DC2626',
  '#EA580C',
  '#CA8A04',
  '#16A34A',
  '#0D9488',
  '#2563EB',
  '#7C3AED',
  '#DB2777'
] as const

export function createPresentationSession(options: OfficeCollaborationOptions<PresentationSnapshot>) {
  return new OfficeCollaborationModel<PresentationSnapshot>(options)
}

export type PresentationSession = ReturnType<typeof createPresentationSession>

export function encodeBase64Bytes(bytes: Uint8Array): string {
  const chunkSize = 0x2000
  const chunks: string[] = []
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const slice = bytes.subarray(offset, offset + chunkSize)
    chunks.push(String.fromCharCode(...slice))
  }
  return btoa(chunks.join(''))
}

function centeredRect(
  slideSizePt: { width: number; height: number },
  width: number,
  height: number
): [number, number, number, number] {
  const safeW = Math.min(width, Math.max(48, slideSizePt.width * 0.75))
  const safeH = Math.min(height, Math.max(36, slideSizePt.height * 0.75))
  const x = Math.max(12, Math.round((slideSizePt.width - safeW) / 2))
  const y = Math.max(12, Math.round((slideSizePt.height - safeH) / 2))
  return [x, y, Math.round(safeW), Math.round(safeH)]
}

function normalizeAlignment(align: string | null | undefined): 'left' | 'center' | 'right' | null {
  switch (align) {
    case 'l':
    case 'left':
      return 'left'
    case 'ctr':
    case 'center':
      return 'center'
    case 'r':
    case 'right':
      return 'right'
    default:
      return null
  }
}

function defaultCommandParams(
  commandId: string,
  slideSizePt: { width: number; height: number },
  activeSlideIndex: number,
  selectedShapeIds: readonly number[]
): Record<string, unknown> {
  switch (commandId) {
    case 'slide.duplicate':
    case 'slide.delete':
      return { index: activeSlideIndex }
    case 'slide.move':
      return {
        from: activeSlideIndex,
        to: Math.max(0, activeSlideIndex - 1)
      }
    case 'shape.insert':
      return {
        preset: 'rect',
        rect: centeredRect(slideSizePt, 240, 140)
      }
    case 'insert.table':
      return { rows: 3, cols: 3 }
    case 'edit.delete':
      return selectedShapeIds.length > 0 ? { ids: [...selectedShapeIds] } : {}
    case 'format.size':
      return { size: 18 }
    case 'format.align':
      return { align: 'left' }
    case 'format.color':
      return { color: '#111827' }
    case 'shape.fill':
      return { color: '#DBEAFE' }
    case 'shape.line':
      return { color: '#2563EB' }
    default:
      return {}
  }
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

function PresentationColorPicker({
  label,
  disabled,
  swatches,
  allowClear = false,
  onPick,
  children
}: {
  label: string
  disabled: boolean
  swatches: readonly string[]
  allowClear?: boolean
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
        <div className="grid grid-cols-5 gap-1.5">
          {swatches.map(hex => {
            const swatchName = `${label} ${hex}`
            return (
              <button
                key={hex}
                type="button"
                aria-label={swatchName}
                title={swatchName}
                className="size-7 rounded-control border border-border focus-visible:outline-offset-1"
                style={{ backgroundColor: hex }}
                onClick={() => {
                  setOpen(false)
                  onPick(hex)
                }}
              />
            )
          })}
          {allowClear && (
            <button
              type="button"
              aria-label={`${label} —`}
              title={`${label} —`}
              className="flex size-7 items-center justify-center rounded-control border border-dashed border-border text-xs text-fg-secondary hover:bg-accent"
              onClick={() => {
                setOpen(false)
                onPick(null)
              }}>
              <RiCloseLine className="size-4" />
            </button>
          )}
        </div>
      </PopoverContent>
    </Popover>
  )
}

function PresentationCommandPaletteDialog({
  open,
  onOpenChange,
  model,
  onExecute
}: {
  open: boolean
  onOpenChange(open: boolean): void
  model: PresentationSession
  onExecute(command: PresentationCommandInfo): void
}) {
  const [query, setQuery] = useState('')
  const [commands, setCommands] = useState<PresentationCommandInfo[]>([])

  useEffect(() => {
    if (!open) {
      setQuery('')
      return
    }
    let cancelled = false
    void model
      .read(eng => (eng as PresentationEngine).commands(query))
      .then(list => {
        if (cancelled) return
        setCommands(list ?? [])
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [open, query, model])

  const runSelected = (item: PresentationCommandInfo) => {
    onOpenChange(false)
    onExecute(item)
  }

  return (
    <CommandDialog
      open={open}
      onOpenChange={onOpenChange}
      title={t('pod.office.command_palette')}
      description={t('pod.office.search_commands')}
      className="max-w-lg">
      <Command shouldFilter={false}>
        <CommandInput
          autoFocus
          aria-label={t('pod.office.search_commands')}
          placeholder={t('pod.office.search_commands')}
          value={query}
          onValueChange={setQuery}
        />
        <CommandList aria-label={t('pod.office.command_palette')}>
          <CommandEmpty>{t('pod.office.no_commands')}</CommandEmpty>
          {commands.map(item => (
            <CommandItem key={item.id} value={item.id} onSelect={() => runSelected(item)}>
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{item.label || item.id}</p>
                <p className="truncate font-mono text-xs text-fg-tertiary">{item.id}</p>
              </div>
              {item.shortcut && <CommandShortcut className="font-mono">{item.shortcut}</CommandShortcut>}
            </CommandItem>
          ))}
        </CommandList>
      </Command>
    </CommandDialog>
  )
}

export type PresentationFindBarProps = {
  query: string
  matchCase: boolean
  matchCount: number
  activeMatchIndex: number
  onQueryChange(query: string): void
  onMatchCaseChange(matchCase: boolean): void
  onNext(): void
  onPrevious(): void
  onClose(): void
}

/**
 * Accessible inline search bar shared by collaborative Presentation Pages and read-only `.pptx`
 * attachment previews.
 */
export function PresentationFindBar({
  query,
  matchCase,
  matchCount,
  activeMatchIndex,
  onQueryChange,
  onMatchCaseChange,
  onNext,
  onPrevious,
  onClose
}: PresentationFindBarProps) {
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.focus({ preventScroll: true })
    inputRef.current?.select()
  }, [])

  const trimmed = query.trim()

  return (
    <div
      role="search"
      aria-label={t('pod.office.find_what')}
      className="flex flex-wrap items-center gap-1.5 border-b border-border bg-muted/30 px-2.5 py-1.5">
      <RiSearchLine className="size-4 shrink-0 text-fg-tertiary" aria-hidden />
      <Input
        ref={inputRef}
        aria-label={t('pod.office.find_what')}
        placeholder={t('pod.office.find_what')}
        value={query}
        onChange={event => onQueryChange(event.target.value)}
        onKeyDown={event => {
          if (event.key === 'Escape') {
            event.preventDefault()
            onClose()
          } else if (event.key === 'Enter') {
            event.preventDefault()
            if (event.shiftKey) onPrevious()
            else onNext()
          }
        }}
        className="h-7 w-48 sm:w-64"
      />
      <Toggle
        size="sm"
        aria-label={t('pod.office.find_match_case')}
        title={t('pod.office.find_match_case')}
        pressed={matchCase}
        onPressedChange={pressed => onMatchCaseChange(pressed)}>
        <span className="font-mono text-xs font-semibold">Aa</span>
      </Toggle>
      <span role="status" aria-live="polite" className="min-w-24 px-1 text-xs text-fg-secondary">
        {trimmed.length === 0
          ? ''
          : matchCount > 0
            ? t('pod.office.find_position', {
                index: activeMatchIndex + 1,
                count: matchCount
              })
            : t('pod.office.find_none')}
      </span>
      <ToolButton label={t('pod.office.find_previous')} disabled={matchCount === 0} onClick={onPrevious}>
        <RiArrowUpSLine />
      </ToolButton>
      <ToolButton label={t('pod.office.find_next')} disabled={matchCount === 0} onClick={onNext}>
        <RiArrowDownSLine />
      </ToolButton>
      <ToolButton label={t('pod.office.close_find')} onClick={onClose}>
        <RiCloseLine />
      </ToolButton>
    </div>
  )
}

export type PresentationToolbarProps = {
  model: PresentationSession
  pageID: string
  canEdit: boolean
  railOpen: boolean
  onToggleRail(): void
  notesOpen: boolean
  onToggleNotes(): void
  zoomMode: 'fit' | number
  effectiveZoom: number
  onZoomIn(): void
  onZoomOut(): void
  onZoomFit(): void
  exportingPdf: boolean
  onDownloadPdf(): void
  onPresent(): void
  onOpenFind(): void
  onCopy(): void
  onRunCommand(
    commandId: string,
    params: Record<string, unknown>,
    options?: { allowWhenSlideLocked?: boolean }
  ): Promise<void>
  editorInputRef: RefObject<HTMLTextAreaElement | null>
}

/**
 * Formatting, slide structure, object insertion, view, export, Present, and collaborator toolbar
 * for Presentation Pages.
 */
export function PresentationToolbar({
  model,
  pageID,
  canEdit,
  railOpen,
  onToggleRail,
  notesOpen,
  onToggleNotes,
  zoomMode,
  effectiveZoom,
  onZoomIn,
  onZoomOut,
  onZoomFit,
  exportingPdf,
  onDownloadPdf,
  onPresent,
  onOpenFind,
  onCopy,
  onRunCommand,
  editorInputRef
}: PresentationToolbarProps) {
  useSignals()
  const [paletteOpen, setPaletteOpen] = useState(false)

  const editable = model.editable.value
  const snapshot = model.snapshot.value
  const members = model.members.value
  const pending = model.pending.value
  const error = model.error.value

  const slides = snapshot?.slides ?? []
  const slideCount = slides.length
  const selection = snapshot?.selection
  const activeSlideIndex = selection?.slide_index ?? 0
  const selectedShapeIds = selection?.shapes ?? []
  const hasShapeOrText = selectedShapeIds.length > 0 || Boolean(selection?.text_sel)
  const slideSizePt = snapshot?.slideSizePt ?? { width: 960, height: 540 }
  const formatState = snapshot?.formatState ?? null
  const activeAlign = normalizeAlignment(formatState?.align)
  const currentFontSize = formatState?.size && Number.isFinite(formatState.size) ? Math.round(formatState.size) : 18

  const focusEditor = () => {
    editorInputRef.current?.focus({ preventScroll: true })
  }

  const runAndFocus = (
    commandId: string,
    params: Record<string, unknown>,
    options?: { allowWhenSlideLocked?: boolean }
  ) => {
    void onRunCommand(commandId, params, options).finally(focusEditor)
  }

  const handleInsertPicture = async () => {
    const file = await chooseLocalFile(PICTURE_ACCEPT)
    if (!file) {
      focusEditor()
      return
    }
    if (file.size <= 0 || file.size > MAX_PICTURE_BYTES) {
      toast.error(t('pod.presentation.picture_too_large'))
      focusEditor()
      return
    }
    if (typeof createImageBitmap === 'function') {
      try {
        const bitmap = await createImageBitmap(file)
        bitmap.close()
      } catch {
        toast.error(t('pod.presentation.picture_too_large'))
        focusEditor()
        return
      }
    }
    try {
      const bytes = new Uint8Array(await file.arrayBuffer())
      if (bytes.byteLength <= 0 || bytes.byteLength > MAX_PICTURE_BYTES) {
        toast.error(t('pod.presentation.picture_too_large'))
        return
      }
      const data = encodeBase64Bytes(bytes)
      await onRunCommand('insert.picture', {
        data,
        name: file.name || 'picture.png'
      })
    } catch {
      toast.error(t('pod.presentation.picture_too_large'))
    } finally {
      focusEditor()
    }
  }

  const statusText = error
    ? t('pod.office.sync_retrying')
    : pending > 0
      ? t('pod.office.saving')
      : t('pod.office.saved')

  return (
    <div className="flex flex-col border-b border-border bg-background">
      <div className="flex min-h-10 flex-wrap items-center gap-0.5 px-2 py-1">
        <Toggle
          size="sm"
          aria-label={t('pod.presentation.toggle_slides_rail')}
          title={t('pod.presentation.toggle_slides_rail')}
          pressed={railOpen}
          onPressedChange={() => onToggleRail()}>
          <RiLayoutLeftLine />
        </Toggle>

        {canEdit && (
          <>
            <Separator orientation="vertical" className="mx-1 h-5" />

            <ToolButton
              label={t('pod.presentation.undo')}
              disabled={!editable || !model.canUndo.value}
              onClick={() => {
                void model.undo().finally(focusEditor)
              }}>
              <RiArrowGoBackLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.redo')}
              disabled={!editable || !model.canRedo.value}
              onClick={() => {
                void model.redo().finally(focusEditor)
              }}>
              <RiArrowGoForwardLine />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5" />

            <ToolButton
              label={t('pod.presentation.add_slide')}
              disabled={!editable}
              onClick={() => runAndFocus('slide.new', {}, { allowWhenSlideLocked: true })}>
              <RiAddLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.duplicate_slide')}
              disabled={!editable || slideCount === 0}
              onClick={() => runAndFocus('slide.duplicate', { index: activeSlideIndex })}>
              <RiFileCopy2Line />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.move_slide_up')}
              disabled={!editable || activeSlideIndex <= 0}
              onClick={() =>
                runAndFocus('slide.move', {
                  from: activeSlideIndex,
                  to: activeSlideIndex - 1
                })
              }>
              <RiArrowUpLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.move_slide_down')}
              disabled={!editable || activeSlideIndex >= slideCount - 1}
              onClick={() =>
                runAndFocus('slide.move', {
                  from: activeSlideIndex,
                  to: activeSlideIndex + 1
                })
              }>
              <RiArrowDownLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.delete_slide')}
              disabled={!editable || slideCount <= 1}
              onClick={() => runAndFocus('slide.delete', { index: activeSlideIndex })}>
              <RiDeleteBinLine />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5" />

            <ToolButton
              label={t('pod.presentation.insert_textbox')}
              disabled={!editable || slideCount === 0}
              onClick={() => runAndFocus('insert.textBox', {})}>
              <RiText />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.insert_rectangle')}
              disabled={!editable || slideCount === 0}
              onClick={() =>
                runAndFocus('shape.insert', {
                  preset: 'rect',
                  rect: centeredRect(slideSizePt, 240, 140)
                })
              }>
              <RiRectangleLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.insert_ellipse')}
              disabled={!editable || slideCount === 0}
              onClick={() =>
                runAndFocus('shape.insert', {
                  preset: 'ellipse',
                  rect: centeredRect(slideSizePt, 180, 180)
                })
              }>
              <RiCheckboxBlankCircleLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.insert_arrow')}
              disabled={!editable || slideCount === 0}
              onClick={() =>
                runAndFocus('shape.insert', {
                  preset: 'rightArrow',
                  rect: centeredRect(slideSizePt, 220, 80)
                })
              }>
              <RiArrowRightLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.insert_table')}
              disabled={!editable || slideCount === 0}
              onClick={() => runAndFocus('insert.table', { rows: 3, cols: 3 })}>
              <RiTableLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.insert_picture')}
              disabled={!editable || slideCount === 0}
              onClick={() => void handleInsertPicture()}>
              <RiImageAddLine />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.bring_forward')}
              disabled={!editable || selectedShapeIds.length === 0}
              onClick={() => runAndFocus('arrange.bringForward', {})}>
              <RiBringForward />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.send_backward')}
              disabled={!editable || selectedShapeIds.length === 0}
              onClick={() => runAndFocus('arrange.sendBackward', {})}>
              <RiSendBackward />
            </ToolButton>
            <ToolButton
              label={t('pod.presentation.delete_shape')}
              disabled={!editable || selectedShapeIds.length === 0}
              onClick={() => runAndFocus('edit.delete', { ids: [...selectedShapeIds] })}>
              <RiCloseLine />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5" />

            <Toggle
              size="sm"
              aria-label={t('pod.presentation.bold')}
              title={t('pod.presentation.bold')}
              disabled={!editable || !hasShapeOrText}
              pressed={Boolean(formatState?.bold)}
              onPressedChange={pressed => runAndFocus('format.bold', { on: pressed })}>
              <RiBold />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.presentation.italic')}
              title={t('pod.presentation.italic')}
              disabled={!editable || !hasShapeOrText}
              pressed={Boolean(formatState?.italic)}
              onPressedChange={pressed => runAndFocus('format.italic', { on: pressed })}>
              <RiItalic />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.presentation.underline')}
              title={t('pod.presentation.underline')}
              disabled={!editable || !hasShapeOrText}
              pressed={Boolean(formatState?.underline)}
              onPressedChange={pressed => runAndFocus('format.underline', { on: pressed })}>
              <RiUnderline />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.presentation.strikethrough')}
              title={t('pod.presentation.strikethrough')}
              disabled={!editable || !hasShapeOrText}
              pressed={Boolean(formatState?.strike)}
              onPressedChange={pressed => runAndFocus('format.strikethrough', { on: pressed })}>
              <RiStrikethrough />
            </Toggle>

            <Select
              value={String(currentFontSize)}
              disabled={!editable || !hasShapeOrText}
              onValueChange={value => {
                if (value) {
                  runAndFocus('format.size', { size: Number(value) })
                }
              }}>
              <SelectTrigger size="sm" className="w-18" aria-label={t('pod.presentation.font_size')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {[...new Set([...FONT_SIZES, currentFontSize])]
                  .sort((a, b) => a - b)
                  .map(size => (
                    <SelectItem key={size} value={String(size)}>
                      {size}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>

            <PresentationColorPicker
              label={t('pod.presentation.font_color')}
              disabled={!editable || !hasShapeOrText}
              swatches={TEXT_COLOR_SWATCHES}
              onPick={color => {
                if (color) runAndFocus('format.color', { color })
              }}>
              <RiFontColor />
            </PresentationColorPicker>

            <PresentationColorPicker
              label={t('pod.presentation.fill_color')}
              disabled={!editable || selectedShapeIds.length === 0}
              swatches={SHAPE_FILL_SWATCHES}
              allowClear
              onPick={color => runAndFocus('shape.fill', color ? { color } : { none: true })}>
              <RiPaintFill />
            </PresentationColorPicker>

            <PresentationColorPicker
              label={t('pod.presentation.stroke_color')}
              disabled={!editable || selectedShapeIds.length === 0}
              swatches={SHAPE_STROKE_SWATCHES}
              allowClear
              onPick={color => runAndFocus('shape.line', color ? { color } : { none: true })}>
              <RiPencilLine />
            </PresentationColorPicker>

            <Toggle
              size="sm"
              aria-label={t('pod.presentation.align_left')}
              title={t('pod.presentation.align_left')}
              disabled={!editable || !hasShapeOrText}
              pressed={activeAlign === 'left'}
              onPressedChange={() => runAndFocus('format.align', { align: 'left' })}>
              <RiAlignLeft />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.presentation.align_center')}
              title={t('pod.presentation.align_center')}
              disabled={!editable || !hasShapeOrText}
              pressed={activeAlign === 'center'}
              onPressedChange={() => runAndFocus('format.align', { align: 'center' })}>
              <RiAlignCenter />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.presentation.align_right')}
              title={t('pod.presentation.align_right')}
              disabled={!editable || !hasShapeOrText}
              pressed={activeAlign === 'right'}
              onPressedChange={() => runAndFocus('format.align', { align: 'right' })}>
              <RiAlignRight />
            </Toggle>

            <ToolButton
              label={t('pod.office.command_palette')}
              disabled={!editable}
              onClick={() => setPaletteOpen(true)}>
              <RiCommandLine />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5" />
          </>
        )}

        <Toggle
          size="sm"
          aria-label={t('pod.presentation.toggle_notes')}
          title={t('pod.presentation.toggle_notes')}
          pressed={notesOpen}
          onPressedChange={() => onToggleNotes()}>
          <RiStickyNoteLine />
        </Toggle>

        <ToolButton label={t('pod.office.find')} onClick={onOpenFind}>
          <RiSearchLine />
        </ToolButton>

        <ToolButton label={t('pod.office.copy')} disabled={!hasShapeOrText} onClick={onCopy}>
          <RiFileCopyLine />
        </ToolButton>

        <ToolButton label={t('pod.office.zoom_out')} onClick={onZoomOut}>
          <RiZoomOutLine />
        </ToolButton>
        <Button
          size="xs"
          variant="ghost"
          aria-label={zoomMode === 'fit' ? t('pod.office.fit_width') : t('pod.office.zoom_reset')}
          title={zoomMode === 'fit' ? t('pod.office.fit_width') : t('pod.office.zoom_reset')}
          className="px-1.5 font-mono text-xs tabular-nums"
          onClick={onZoomFit}>
          {zoomMode === 'fit' ? t('pod.office.fit_width') : `${Math.round(effectiveZoom * 100)}%`}
        </Button>
        <ToolButton label={t('pod.office.zoom_in')} onClick={onZoomIn}>
          <RiZoomInLine />
        </ToolButton>

        <ToolButton
          label={exportingPdf ? t('pod.office.exporting_pdf') : t('pod.office.download_pdf')}
          disabled={exportingPdf || slideCount === 0}
          onClick={onDownloadPdf}>
          {exportingPdf ? <Spinner className="size-4" /> : <RiFilePdf2Line />}
        </ToolButton>

        <Button
          size="xs"
          variant="outline"
          aria-label={t('pod.presentation.present')}
          title={t('pod.presentation.present')}
          disabled={slideCount === 0}
          onClick={onPresent}>
          <RiSlideshowLine />
          <span className="hidden sm:inline">{t('pod.presentation.present')}</span>
        </Button>

        <div className="ml-auto flex items-center gap-2 pl-1">
          <span role="status" className="text-xs text-fg-tertiary">
            {canEdit ? statusText : t('pod.office.view_only')}
          </span>
          {members.length > 0 && (
            <AvatarGroup role="group" aria-label={t('pod.office.collaborators')}>
              {members.map(member => (
                <Avatar key={member.uid} size="sm" role="img" aria-label={member.name} title={member.name}>
                  <AvatarFallback className="text-white" style={{ background: `var(${member.color})` }}>
                    {member.name.slice(0, 1).toUpperCase()}
                  </AvatarFallback>
                </Avatar>
              ))}
            </AvatarGroup>
          )}
          {canEdit && <OfficeVersions pageID={pageID} />}
        </div>
      </div>

      {canEdit && (
        <PresentationCommandPaletteDialog
          open={paletteOpen}
          onOpenChange={setPaletteOpen}
          model={model}
          onExecute={command => {
            const params = defaultCommandParams(command.id, slideSizePt, activeSlideIndex, selectedShapeIds)
            runAndFocus(command.id, params, {
              allowWhenSlideLocked: command.id === 'slide.new'
            })
          }}
        />
      )}
    </div>
  )
}

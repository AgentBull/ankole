import { t } from 'i18next'
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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
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
  Textarea,
  Toggle,
  ToggleGroup,
  ToggleGroupItem,
  toast
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiAlignCenter,
  RiAlignJustify,
  RiAlignLeft,
  RiAlignRight,
  RiArrowGoBackLine,
  RiArrowGoForwardLine,
  RiArticleLine,
  RiBold,
  RiChatNewLine,
  RiCheckDoubleLine,
  RiCodeLine,
  RiCommandLine,
  RiEditCircleLine,
  RiExpandWidthLine,
  RiFilePdf2Line,
  RiFontColor,
  RiFormatClear,
  RiImageAddLine,
  RiIndentDecrease,
  RiIndentIncrease,
  RiItalic,
  RiLink,
  RiListOrdered,
  RiListUnordered,
  RiMarkPenLine,
  RiPageSeparator,
  RiSearchLine,
  RiSeparator,
  RiStrikethrough,
  RiSubscript,
  RiSuperscript,
  RiTableLine,
  RiUnderline,
  RiZoomInLine,
  RiZoomOutLine
} from '@remixicon/react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useEffect, useState, type ReactNode, type RefObject } from 'react'
import { downloadBlob } from '../../common/browser-files'
import { podPagePath } from '../../common/pod-url'
import { requestErrorMessage } from '../../common/request-errors'
import { podWordConvertToDocument } from '../api/generated/sdk.gen'
import { contentError } from '../content-errors'
import { chooseLocalFile } from '../native-transfers'
import { OfficeVersions } from '../office/office-versions'
import { pageCreated } from '../state/navigation-cache'
import {
  bytesToBase64,
  MAX_WORD_PICTURE_BYTES,
  type WordCommandInfo,
  type WordEngine,
  type WordSession
} from './word-engine'

const PICTURE_ACCEPT = 'image/png,image/jpeg,image/gif,image/webp'

const PARAGRAPH_STYLES = [
  { id: 'Normal', labelKey: 'pod.word.style_normal' },
  { id: 'Heading1', labelKey: 'pod.word.style_heading_1' },
  { id: 'Heading2', labelKey: 'pod.word.style_heading_2' },
  { id: 'Heading3', labelKey: 'pod.word.style_heading_3' },
  { id: 'Title', labelKey: 'pod.word.style_title' },
  { id: 'Subtitle', labelKey: 'pod.word.style_subtitle' },
  { id: 'Quote', labelKey: 'pod.word.style_quote' }
] as const

const FONT_COLORS = [
  '000000',
  '4B5563',
  'DC2626',
  'EA580C',
  'CA8A04',
  '16A34A',
  '0D9488',
  '2563EB',
  '7C3AED',
  'DB2777'
] as const

const HIGHLIGHT_COLORS = [
  { id: 'yellow', hex: '#FEF08A' },
  { id: 'brightGreen', hex: '#BBF7D0' },
  { id: 'turquoise', hex: '#99F6E4' },
  { id: 'pink', hex: '#FBCFE8' },
  { id: 'blue', hex: '#BFDBFE' },
  { id: 'red', hex: '#FECACA' }
] as const

const FONT_SIZES = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48] as const

function pdfDownloadName(rawTitle?: string): string {
  const cleaned = (rawTitle ?? '')
    .trim()
    .replace(/\.(docx|docm)$/i, '')
    .trim()
  return `${cleaned || 'document'}.pdf`
}

function normalizeStyleId(styleName: string | undefined): string {
  if (!styleName) return 'Normal'
  const compact = styleName.replace(/\s+/g, '')
  const matched = PARAGRAPH_STYLES.find(entry => entry.id.toLowerCase() === compact.toLowerCase())
  return matched ? matched.id : styleName
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

function ToolMenu({
  label,
  disabled,
  icon,
  children
}: {
  label: string
  disabled?: boolean
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

export type WordToolbarProps = {
  model: WordSession
  pageID?: string
  title?: string
  canEdit: boolean
  editorInput: RefObject<HTMLTextAreaElement | null>
  zoom: number
  fitWidth: boolean
  onZoomIn(): void
  onZoomOut(): void
  onZoomReset(): void
  onToggleFitWidth(): void
  onOpenFind(): void
  onRunCommand?(commandId: string, params?: Record<string, unknown>, mutates?: boolean): Promise<void> | void
}

/**
 * Toolbar for collaborative Word Pages and read-only Word attachment previews.
 */
export function WordToolbar({
  model,
  pageID,
  title,
  canEdit,
  editorInput,
  zoom,
  fitWidth,
  onZoomIn,
  onZoomOut,
  onZoomReset,
  onToggleFitWidth,
  onOpenFind,
  onRunCommand
}: WordToolbarProps) {
  useSignals()

  const editable = model.editable.value
  const snapshot = model.snapshot.value
  const caretState = snapshot?.caretState
  const substitutedFonts = snapshot?.substitutedFonts ?? []
  const members = model.members.value
  const pending = model.pending.value
  const error = model.error.value

  const [linkPopoverOpen, setLinkPopoverOpen] = useState(false)
  const [linkUrl, setLinkUrl] = useState('')
  const [commentPopoverOpen, setCommentPopoverOpen] = useState(false)
  const [commentText, setCommentText] = useState('')
  const [fontColorOpen, setFontColorOpen] = useState(false)
  const [highlightOpen, setHighlightOpen] = useState(false)
  const [paletteOpen, setPaletteOpen] = useState(false)
  const [exportingPdf, setExportingPdf] = useState(false)

  const focusEditor = () => {
    editorInput.current?.focus({ preventScroll: true })
  }

  const run = (commandId: string, params: Record<string, unknown> = {}, mutates = true) => {
    void onRunCommand?.(commandId, params, mutates)
    focusEditor()
  }

  const inTable = (caretState?.focus.path.length ?? 0) > 1
  const currentStyle = normalizeStyleId(caretState?.style)
  const styleItems = PARAGRAPH_STYLES.some(item => item.id === currentStyle)
    ? PARAGRAPH_STYLES
    : [...PARAGRAPH_STYLES, { id: currentStyle, labelKey: '' } as { id: string; labelKey: string }]

  const alignValue = caretState?.align ? [caretState.align] : ['left']

  const handleInsertPicture = async () => {
    const file = await chooseLocalFile(PICTURE_ACCEPT)
    if (!file) {
      focusEditor()
      return
    }
    if (file.size === 0 || file.size > MAX_WORD_PICTURE_BYTES) {
      toast.error(t('pod.word.picture_too_large'))
      focusEditor()
      return
    }
    try {
      const bytes = new Uint8Array(await file.arrayBuffer())
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_WORD_PICTURE_BYTES) {
        toast.error(t('pod.word.picture_too_large'))
        focusEditor()
        return
      }
      const data = bytesToBase64(bytes)
      const alt = file.name.replace(/\.[^.]+$/, '')
      await onRunCommand?.('insert.picture', { data, ...(alt ? { alt } : {}) }, true)
    } catch {
      toast.error(t('pod.word.picture_too_large'))
    }
    focusEditor()
  }

  const handleExportPdf = async () => {
    if (exportingPdf) return
    setExportingPdf(true)
    try {
      const bytes = await model.read(eng => (eng as WordEngine).exportPdf())
      if (bytes && bytes.byteLength > 0) {
        downloadBlob(new Blob([bytes.slice()], { type: 'application/pdf' }), pdfDownloadName(title))
      }
    } catch (failure) {
      toast.error(requestErrorMessage(contentError(failure)))
    } finally {
      setExportingPdf(false)
    }
  }

  const saveStatusText = error
    ? t('pod.office.sync_retrying')
    : pending > 0
      ? t('pod.office.saving')
      : t('pod.office.saved')

  return (
    <div className="flex flex-col border-b border-border bg-background">
      <div className="flex min-h-10 flex-wrap items-center gap-0.5 px-2 py-1 max-md:px-1.5">
        {canEdit && (
          <>
            <ToolButton
              label={t('pod.word.undo')}
              disabled={!editable || !model.canUndo.value}
              onClick={() => {
                void model.undo()
                focusEditor()
              }}>
              <RiArrowGoBackLine />
            </ToolButton>
            <ToolButton
              label={t('pod.word.redo')}
              disabled={!editable || !model.canRedo.value}
              onClick={() => {
                void model.redo()
                focusEditor()
              }}>
              <RiArrowGoForwardLine />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

            <Select
              value={currentStyle}
              disabled={!editable}
              onValueChange={value => {
                if (value) run('para.style', { style: value })
              }}>
              <SelectTrigger
                size="sm"
                className="w-30 max-md:w-26"
                aria-label={t('pod.word.style')}
                title={t('pod.word.style')}>
                <SelectValue>
                  {(() => {
                    const matched = PARAGRAPH_STYLES.find(item => item.id === currentStyle)
                    return matched ? t(matched.labelKey) : currentStyle
                  })()}
                </SelectValue>
              </SelectTrigger>
              <SelectContent>
                {styleItems.map(item => (
                  <SelectItem key={item.id} value={item.id}>
                    {item.labelKey ? t(item.labelKey) : item.id}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <Select
              value=""
              disabled={!editable}
              onValueChange={value => {
                if (value) run('format.size', { size: Number(value) })
              }}>
              <SelectTrigger
                size="sm"
                className="w-16 max-md:hidden"
                aria-label={t('pod.word.font_size')}
                title={t('pod.word.font_size')}>
                <SelectValue placeholder="11" />
              </SelectTrigger>
              <SelectContent>
                {FONT_SIZES.map(size => (
                  <SelectItem key={size} value={String(size)}>
                    {size}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

            <Toggle
              size="sm"
              aria-label={t('pod.word.bold')}
              title={t('pod.word.bold')}
              disabled={!editable}
              pressed={Boolean(caretState?.bold)}
              onPressedChange={() => run('format.bold')}>
              <RiBold />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.word.italic')}
              title={t('pod.word.italic')}
              disabled={!editable}
              pressed={Boolean(caretState?.italic)}
              onPressedChange={() => run('format.italic')}>
              <RiItalic />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.word.underline')}
              title={t('pod.word.underline')}
              disabled={!editable}
              pressed={Boolean(caretState?.underline)}
              onPressedChange={() => run('format.underline')}>
              <RiUnderline />
            </Toggle>
            <Toggle
              size="sm"
              aria-label={t('pod.word.strikethrough')}
              title={t('pod.word.strikethrough')}
              disabled={!editable}
              pressed={Boolean(caretState?.strike)}
              onPressedChange={() => run('format.strikethrough')}>
              <RiStrikethrough />
            </Toggle>
            <Toggle
              size="sm"
              className="max-md:hidden"
              aria-label={t('pod.word.inline_code')}
              title={t('pod.word.inline_code')}
              disabled={!editable}
              pressed={Boolean(caretState?.code)}
              onPressedChange={() => {
                if (caretState?.code) run('format.resetChar')
                else run('format.font', { name: 'Consolas' })
              }}>
              <RiCodeLine />
            </Toggle>
            <ToolButton label={t('pod.word.subscript')} disabled={!editable} onClick={() => run('format.subscript')}>
              <RiSubscript />
            </ToolButton>
            <ToolButton
              label={t('pod.word.superscript')}
              disabled={!editable}
              onClick={() => run('format.superscript')}>
              <RiSuperscript />
            </ToolButton>

            <Popover open={fontColorOpen} onOpenChange={setFontColorOpen}>
              <PopoverTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('pod.word.font_color')}
                    title={t('pod.word.font_color')}
                    disabled={!editable}
                  />
                }>
                <RiFontColor />
              </PopoverTrigger>
              <PopoverContent align="start" className="w-auto gap-2 p-3">
                <PopoverTitle>{t('pod.word.font_color')}</PopoverTitle>
                <div className="grid grid-cols-5 gap-1.5">
                  {FONT_COLORS.map(hex => {
                    const label = `${t('pod.word.font_color')} #${hex}`
                    return (
                      <button
                        key={hex}
                        type="button"
                        aria-label={label}
                        title={label}
                        className="size-6 rounded-control border border-border focus-visible:outline-offset-1"
                        style={{ backgroundColor: `#${hex}` }}
                        onClick={() => {
                          setFontColorOpen(false)
                          run('format.color', { color: hex })
                        }}
                      />
                    )
                  })}
                </div>
                <Button
                  size="xs"
                  variant="outline"
                  aria-label={t('pod.word.clear_formatting')}
                  title={t('pod.word.clear_formatting')}
                  onClick={() => {
                    setFontColorOpen(false)
                    run('format.color', { color: 'auto' })
                  }}>
                  {t('pod.word.clear_formatting')}
                </Button>
              </PopoverContent>
            </Popover>

            <Popover open={highlightOpen} onOpenChange={setHighlightOpen}>
              <PopoverTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('pod.word.highlight_color')}
                    title={t('pod.word.highlight_color')}
                    disabled={!editable}
                  />
                }>
                <RiMarkPenLine />
              </PopoverTrigger>
              <PopoverContent align="start" className="w-auto gap-2 p-3">
                <PopoverTitle>{t('pod.word.highlight_color')}</PopoverTitle>
                <div className="grid grid-cols-3 gap-1.5">
                  {HIGHLIGHT_COLORS.map(entry => {
                    const label = `${t('pod.word.highlight_color')} (${entry.id})`
                    return (
                      <button
                        key={entry.id}
                        type="button"
                        aria-label={label}
                        title={label}
                        className="size-6 rounded-control border border-border focus-visible:outline-offset-1"
                        style={{ backgroundColor: entry.hex }}
                        onClick={() => {
                          setHighlightOpen(false)
                          run('format.highlight', { color: entry.id })
                        }}
                      />
                    )
                  })}
                </div>
                <Button
                  size="xs"
                  variant="outline"
                  aria-label={t('pod.word.clear_formatting')}
                  title={t('pod.word.clear_formatting')}
                  onClick={() => {
                    setHighlightOpen(false)
                    run('format.highlight', { color: 'none' })
                  }}>
                  {t('pod.word.clear_formatting')}
                </Button>
              </PopoverContent>
            </Popover>

            <ToolButton label={t('pod.word.clear_formatting')} disabled={!editable} onClick={() => run('format.clear')}>
              <RiFormatClear />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

            <ToggleGroup
              size="sm"
              spacing={0}
              aria-label={t('pod.word.align_left')}
              disabled={!editable}
              value={alignValue}
              onValueChange={values => {
                const chosen = values.at(-1)
                if (chosen) run('para.align', { value: chosen })
              }}>
              <ToggleGroupItem value="left" aria-label={t('pod.word.align_left')} title={t('pod.word.align_left')}>
                <RiAlignLeft />
              </ToggleGroupItem>
              <ToggleGroupItem
                value="center"
                aria-label={t('pod.word.align_center')}
                title={t('pod.word.align_center')}>
                <RiAlignCenter />
              </ToggleGroupItem>
              <ToggleGroupItem value="right" aria-label={t('pod.word.align_right')} title={t('pod.word.align_right')}>
                <RiAlignRight />
              </ToggleGroupItem>
              <ToggleGroupItem
                value="justify"
                aria-label={t('pod.word.align_justify')}
                title={t('pod.word.align_justify')}>
                <RiAlignJustify />
              </ToggleGroupItem>
            </ToggleGroup>

            <ToolButton label={t('pod.word.bullet_list')} disabled={!editable} onClick={() => run('para.bullets')}>
              <RiListUnordered />
            </ToolButton>
            <ToolButton label={t('pod.word.numbered_list')} disabled={!editable} onClick={() => run('para.numbering')}>
              <RiListOrdered />
            </ToolButton>
            <ToolButton label={t('pod.word.outdent')} disabled={!editable} onClick={() => run('para.outdent')}>
              <RiIndentDecrease />
            </ToolButton>
            <ToolButton label={t('pod.word.indent')} disabled={!editable} onClick={() => run('para.indent')}>
              <RiIndentIncrease />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

            <ToolMenu label={t('pod.word.table_actions')} disabled={!editable} icon={<RiTableLine />}>
              <DropdownMenuItem onClick={() => run('insert.table', { rows: 3, cols: 3 })}>
                {t('pod.word.insert_table')}
              </DropdownMenuItem>
              {inTable && (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onClick={() => run('table.insertRowAbove')}>
                    {t('pod.word.insert_row_above')}
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => run('table.insertRowBelow')}>
                    {t('pod.word.insert_row_below')}
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => run('table.insertColumnLeft')}>
                    {t('pod.word.insert_column_left')}
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={() => run('table.insertColumnRight')}>
                    {t('pod.word.insert_column_right')}
                  </DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem variant="destructive" onClick={() => run('table.deleteRow')}>
                    {t('pod.word.delete_row')}
                  </DropdownMenuItem>
                  <DropdownMenuItem variant="destructive" onClick={() => run('table.deleteColumn')}>
                    {t('pod.word.delete_column')}
                  </DropdownMenuItem>
                  <DropdownMenuItem variant="destructive" onClick={() => run('table.deleteTable')}>
                    {t('pod.word.delete_table')}
                  </DropdownMenuItem>
                </>
              )}
            </ToolMenu>

            <ToolButton
              label={t('pod.word.insert_picture')}
              disabled={!editable}
              onClick={() => void handleInsertPicture()}>
              <RiImageAddLine />
            </ToolButton>

            <Popover
              open={linkPopoverOpen}
              onOpenChange={open => {
                setLinkPopoverOpen(open)
                if (open) setLinkUrl(caretState?.link ?? '')
              }}>
              <PopoverTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('pod.word.insert_link')}
                    title={t('pod.word.insert_link')}
                    disabled={!editable}
                  />
                }>
                <RiLink />
              </PopoverTrigger>
              <PopoverContent align="start" className="w-72 gap-3 p-3">
                <PopoverTitle>{t('pod.word.insert_link')}</PopoverTitle>
                <Input
                  autoFocus
                  aria-label={t('pod.word.link_url')}
                  placeholder="https://"
                  value={linkUrl}
                  onChange={event => setLinkUrl(event.target.value)}
                  onKeyDown={event => {
                    if (event.key === 'Enter' && linkUrl.trim()) {
                      event.preventDefault()
                      setLinkPopoverOpen(false)
                      run('insert.link', { url: linkUrl.trim() })
                    }
                  }}
                />
                <div className="flex justify-end gap-2">
                  <Button
                    size="sm"
                    variant="ghost"
                    aria-label={t('pod.word.clear_formatting')}
                    title={t('pod.word.clear_formatting')}
                    onClick={() => {
                      setLinkPopoverOpen(false)
                      run('insert.removeLink')
                    }}>
                    {t('pod.word.clear_formatting')}
                  </Button>
                  <Button
                    size="sm"
                    aria-label={t('pod.word.insert_link')}
                    title={t('pod.word.insert_link')}
                    disabled={!linkUrl.trim()}
                    onClick={() => {
                      setLinkPopoverOpen(false)
                      run('insert.link', { url: linkUrl.trim() })
                    }}>
                    {t('pod.word.insert_link')}
                  </Button>
                </div>
              </PopoverContent>
            </Popover>

            <Popover
              open={commentPopoverOpen}
              onOpenChange={open => {
                setCommentPopoverOpen(open)
                if (open) setCommentText('')
              }}>
              <PopoverTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('pod.word.comments')}
                    title={t('pod.word.comments')}
                    disabled={!editable}
                  />
                }>
                <RiChatNewLine />
              </PopoverTrigger>
              <PopoverContent align="start" className="w-72 gap-3 p-3">
                <PopoverTitle>{t('pod.word.comments')}</PopoverTitle>
                <Textarea
                  aria-label={t('pod.word.comment_text')}
                  placeholder={t('pod.word.comment_text')}
                  rows={3}
                  value={commentText}
                  onChange={event => setCommentText(event.target.value)}
                />
                <div className="flex justify-end gap-2">
                  <Button
                    size="sm"
                    variant="ghost"
                    aria-label={t('pod.word.delete_comment')}
                    title={t('pod.word.delete_comment')}
                    onClick={() => {
                      setCommentPopoverOpen(false)
                      run('review.deleteComment')
                    }}>
                    {t('pod.word.delete_comment')}
                  </Button>
                  <Button
                    size="sm"
                    aria-label={t('pod.word.add_comment')}
                    title={t('pod.word.add_comment')}
                    disabled={!commentText.trim()}
                    onClick={() => {
                      setCommentPopoverOpen(false)
                      run('review.newComment', { text: commentText.trim() })
                    }}>
                    {t('pod.word.add_comment')}
                  </Button>
                </div>
              </PopoverContent>
            </Popover>

            <ToolButton
              label={t('pod.word.insert_page_break')}
              disabled={!editable}
              onClick={() => run('insert.pageBreak')}>
              <RiPageSeparator />
            </ToolButton>
            <ToolButton
              label={t('pod.word.insert_horizontal_rule')}
              disabled={!editable}
              onClick={() => run('insert.horizontalLine')}>
              <RiSeparator />
            </ToolButton>

            <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

            <Toggle
              size="sm"
              aria-label={t('pod.word.track_changes')}
              title={t('pod.word.track_changes')}
              disabled={!editable}
              pressed={Boolean(caretState?.track_changes)}
              onPressedChange={() => run('review.trackChanges')}>
              <RiEditCircleLine />
            </Toggle>

            <ToolMenu label={t('pod.office.more_actions')} disabled={!editable} icon={<RiCheckDoubleLine />}>
              <DropdownMenuItem onClick={() => run('review.accept')}>{t('pod.word.accept_change')}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => run('review.reject')}>{t('pod.word.reject_change')}</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => run('review.acceptAll')}>
                {t('pod.word.accept_all_changes')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => run('review.rejectAll')}>
                {t('pod.word.reject_all_changes')}
              </DropdownMenuItem>
            </ToolMenu>

            <ToolButton
              label={t('pod.office.command_palette')}
              disabled={!editable}
              onClick={() => setPaletteOpen(true)}>
              <RiCommandLine />
            </ToolButton>
          </>
        )}

        <Separator orientation="vertical" className="mx-1 h-5 max-md:hidden" />

        <ToolButton label={t('pod.office.find')} onClick={onOpenFind}>
          <RiSearchLine />
        </ToolButton>

        <div className="flex items-center gap-0.5" role="group" aria-label={t('pod.office.zoom')}>
          <ToolButton label={t('pod.office.zoom_out')} onClick={onZoomOut}>
            <RiZoomOutLine />
          </ToolButton>
          <Button
            size="xs"
            variant="ghost"
            className="min-w-12 px-1.5 font-mono text-xs"
            aria-label={t('pod.office.zoom_reset')}
            title={t('pod.office.zoom_reset')}
            onClick={onZoomReset}>
            {`${Math.round(zoom * 100)}%`}
          </Button>
          <ToolButton label={t('pod.office.zoom_in')} onClick={onZoomIn}>
            <RiZoomInLine />
          </ToolButton>
          <Toggle
            size="sm"
            aria-label={t('pod.office.fit_width')}
            title={t('pod.office.fit_width')}
            pressed={fitWidth}
            onPressedChange={() => onToggleFitWidth()}>
            <RiExpandWidthLine />
          </Toggle>
        </div>

        <ToolButton
          label={exportingPdf ? t('pod.office.exporting_pdf') : t('pod.office.download_pdf')}
          disabled={exportingPdf}
          onClick={() => void handleExportPdf()}>
          <RiFilePdf2Line />
        </ToolButton>

        {pageID && <ConvertToDocumentButton model={model} pageID={pageID} />}

        <div className="ml-auto flex items-center gap-2">
          {substitutedFonts.length > 0 && (
            <span
              className="max-w-44 truncate text-xs text-fg-tertiary max-xl:hidden"
              title={t('pod.word.substituted_fonts_hint', {
                fonts: substitutedFonts.join(', ')
              })}>
              {t('pod.word.substituted_fonts_hint', {
                fonts: substitutedFonts.join(', ')
              })}
            </span>
          )}
          <span role="status" className="text-xs text-fg-tertiary">
            {canEdit ? saveStatusText : t('pod.office.view_only')}
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
          {canEdit && pageID && <OfficeVersions pageID={pageID} />}
        </div>
      </div>

      {canEdit && (
        <WordCommandPaletteDialog
          open={paletteOpen}
          onOpenChange={setPaletteOpen}
          model={model}
          onExecute={(commandId, params, mutates) => {
            setPaletteOpen(false)
            run(commandId, params, mutates)
          }}
        />
      )}
    </div>
  )
}

function ConvertToDocumentButton({ model, pageID }: { model: WordSession; pageID: string }) {
  useSignals()
  const status = model.status.value
  const client = useQueryClient()
  const navigate = useNavigate()

  const convertMutation = useMutation({
    mutationFn: async () => {
      if (!(await model.savePending())) {
        throw new Error(t('pod.content.unsaved_changes'))
      }
      return podWordConvertToDocument({ path: { id: pageID } })
    },
    onSuccess: res => {
      pageCreated(client, res.page)
      const combined = { ...res.omitted, ...res.downgraded }
      const noteEntries = Object.entries(combined).filter(([, value]) =>
        typeof value === 'number' ? value > 0 : Boolean(value)
      )
      if (noteEntries.length > 0) {
        const details = noteEntries.map(([key, value]) => `${key.replaceAll('_', ' ')} (${String(value)})`).join(', ')
        toast.success(
          t('pod.word.converted_with_notes', {
            title: res.page.title,
            details
          })
        )
      } else {
        toast.success(t('pod.word.converted_open_document', { title: res.page.title }))
      }
      void navigate({ to: podPagePath(res.page.id, res.page.title) })
    },
    onError: failure => {
      toast.error(requestErrorMessage(contentError(failure)))
    }
  })

  const label = convertMutation.isPending ? t('pod.word.converting_to_document') : t('pod.word.convert_to_document')

  return (
    <Button
      size="xs"
      variant="outline"
      className="ml-1 gap-1"
      aria-label={label}
      title={label}
      disabled={(status !== 'ready' && status !== 'read_only') || convertMutation.isPending}
      onClick={() => convertMutation.mutate()}>
      <RiArticleLine />
      <span className="max-lg:hidden">{label}</span>
    </Button>
  )
}

function WordCommandPaletteDialog({
  open,
  onOpenChange,
  model,
  onExecute
}: {
  open: boolean
  onOpenChange(open: boolean): void
  model: WordSession
  onExecute(commandId: string, params: Record<string, unknown>, mutates: boolean): void
}) {
  const [query, setQuery] = useState('')
  const [commands, setCommands] = useState<WordCommandInfo[]>([])

  useEffect(() => {
    if (!open) {
      setQuery('')
      return
    }
    let stale = false
    void model
      .read(eng => (eng as WordEngine).commands(query.trim()))
      .then(list => {
        if (!stale && list) {
          setCommands(list)
        }
      })
      .catch(() => undefined)
    return () => {
      stale = true
    }
  }, [open, query, model])

  return (
    <CommandDialog
      open={open}
      onOpenChange={onOpenChange}
      title={t('pod.office.command_palette')}
      description={t('pod.office.search_commands')}
      className="max-w-xl">
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
            <CommandItem key={item.id} value={item.id} onSelect={() => onExecute(item.id, {}, item.mutates)}>
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{item.label}</p>
                <p className="truncate text-xs text-fg-tertiary">
                  {[item.location, item.id].filter(Boolean).join(' · ')}
                </p>
              </div>
              {item.shortcut && <CommandShortcut className="font-mono">{item.shortcut}</CommandShortcut>}
            </CommandItem>
          ))}
        </CommandList>
      </Command>
    </CommandDialog>
  )
}

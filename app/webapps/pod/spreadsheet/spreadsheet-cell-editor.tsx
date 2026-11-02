import { t } from 'i18next'
import { cn, toast } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { useEffect, useRef, type KeyboardEvent, type RefObject } from 'react'
import { cellName, decodeTSV, encodeTSV, selectionRect } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'

/** The formula bar marks its input with this attribute, so moving focus there keeps the draft open. */
export const FORMULA_BAR_ATTRIBUTE = 'data-spreadsheet-formula'

/**
 * A native textarea over the active cell. It keeps keyboard focus for the whole grid: while no cell
 * is edited it is transparent and turns navigation keys into selection moves, and the first typed
 * character or IME composition opens the editor with that input. The DOM value is written only
 * outside a composition, so the system IME keeps its candidate window and Enter never commits
 * half-composed text.
 */
export function SpreadsheetCellEditor({
  model,
  inputRef,
  navigate
}: {
  model: SpreadsheetSession
  inputRef: RefObject<HTMLTextAreaElement | null>
  navigate(event: KeyboardEvent<HTMLTextAreaElement>): boolean
}) {
  useSignals()
  const composing = useRef(false)
  const draft = model.draft.value
  const editable = model.editable.value
  const cell = draft?.cell ?? model.selection.value.anchor

  useEffect(() => {
    const element = inputRef.current
    const text = draft?.text ?? ''
    if (element && !composing.current && element.value !== text) element.value = text
  }, [draft, inputRef])

  const open = (text: string) => {
    if (model.draft.peek()) model.type(text)
    else if (model.editable.peek()) model.edit(model.selection.peek().anchor, text)
  }

  const copy = async (clear: boolean) => {
    try {
      await navigator.clipboard.writeText(encodeTSV(await model.copyText()))
      if (clear && model.editable.peek()) await model.clearContents()
    } catch {
      toast.error(t('pod.spreadsheet.copy_failed'))
    }
  }

  return (
    <textarea
      ref={inputRef}
      aria-label={t('pod.spreadsheet.cell_editor', { cell: cellName(cell) })}
      data-editing={draft ? '' : undefined}
      readOnly={!editable}
      spellCheck={false}
      rows={1}
      className={cn(
        'absolute z-10 m-0 resize-none overflow-hidden border-2 border-blue-60 px-[3px] py-px leading-tight whitespace-pre-wrap outline-none [field-sizing:content]',
        !draft && 'pointer-events-none opacity-0'
      )}
      onInput={event => open(event.currentTarget.value)}
      onCompositionStart={() => {
        composing.current = true
        if (!model.draft.peek() && model.editable.peek()) model.edit(model.selection.peek().anchor, '')
      }}
      onCompositionEnd={event => {
        composing.current = false
        open(event.currentTarget.value)
      }}
      onKeyDown={event => {
        if (event.nativeEvent.isComposing || composing.current) return
        if (!model.draft.peek()) {
          if (navigate(event)) event.preventDefault()
          return
        }
        if (event.key === 'Enter' && event.altKey) {
          event.preventDefault()
          event.currentTarget.setRangeText(
            '\n',
            event.currentTarget.selectionStart,
            event.currentTarget.selectionEnd,
            'end'
          )
          open(event.currentTarget.value)
        } else if (event.key === 'Enter') {
          event.preventDefault()
          void model.commitEdit(event.shiftKey ? 'up' : 'down')
        } else if (event.key === 'Tab') {
          event.preventDefault()
          void model.commitEdit(event.shiftKey ? 'left' : 'right')
        } else if (event.key === 'Escape') {
          event.preventDefault()
          model.cancelEdit()
        }
      }}
      onFocus={() => model.focus()}
      onBlur={event => {
        const next = event.relatedTarget
        if (next instanceof HTMLElement && next.hasAttribute(FORMULA_BAR_ATTRIBUTE)) return
        if (model.draft.peek()) void model.commitEdit()
        model.blur()
      }}
      onCopy={event => {
        if (model.draft.peek()) return
        event.preventDefault()
        void copy(false)
      }}
      onCut={event => {
        if (model.draft.peek()) return
        event.preventDefault()
        void copy(true)
      }}
      onPaste={event => {
        if (model.draft.peek() || !model.editable.peek()) return
        event.preventDefault()
        const values = decodeTSV(event.clipboardData.getData('text/plain'))
        const { r0, c0 } = selectionRect(model.selection.peek())
        if (values.length) void model.setValues({ row: r0, col: c0 }, values)
      }}
    />
  )
}

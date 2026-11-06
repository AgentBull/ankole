import { t } from 'i18next'
import { cn } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { useEffect, useRef, useState, type KeyboardEvent, type RefObject } from 'react'
import { acceptsReference, isFormula } from '../state/spreadsheet-formula'
import { cellName, type FunctionInfo, type PasteMode } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { copySelection, pasteContents } from './spreadsheet-clipboard-actions'
import { SpreadsheetFormulaAssist } from './spreadsheet-formula-assist'

/** The formula bar marks its input with this attribute, so moving focus there keeps the draft open. */
export const FORMULA_BAR_ATTRIBUTE = 'data-spreadsheet-formula'
/** Sheet tabs carry this attribute, so a formula draft stays open while its author picks another sheet. */
export const SHEET_TAB_ATTRIBUTE = 'data-spreadsheet-sheet-tab'

/** Loads the function list once per session for suggestions and hints. */
export function useFunctions(model: SpreadsheetSession): FunctionInfo[] {
  const [functions, setFunctions] = useState<FunctionInfo[]>([])
  useEffect(() => {
    let stale = false
    void model
      .functions()
      .then(list => {
        if (!stale) setFunctions(list)
      })
      .catch(() => undefined)
    return () => {
      stale = true
    }
  }, [model, model.status.value])
  return functions
}

/** Moves the caret where the draft asks, once the input shows the draft's text. */
export function useDraftCaret(input: RefObject<HTMLTextAreaElement | HTMLInputElement | null>, caret?: number) {
  useEffect(() => {
    const element = input.current
    if (caret === undefined || !element || document.activeElement !== element) return
    element.setSelectionRange(caret, caret)
  })
}

/**
 * A native textarea over the active cell. It keeps keyboard focus for the whole grid: while no cell
 * is edited it is transparent and turns navigation keys into selection moves, and the first typed
 * character or IME composition opens the editor with that input. The DOM value is written only
 * outside a composition, so the system IME keeps its candidate window and Enter never commits
 * half-composed text. While a formula is typed, function suggestions and the argument hint follow
 * the caret.
 */
export function SpreadsheetCellEditor({
  model,
  pageID,
  inputRef,
  navigate
}: {
  model: SpreadsheetSession
  pageID: string
  inputRef: RefObject<HTMLTextAreaElement | null>
  navigate(event: KeyboardEvent<HTMLTextAreaElement>): boolean
}) {
  useSignals()
  const composing = useRef(false)
  const pasteMode = useRef<PasteMode>('all')
  const functions = useFunctions(model)
  const draft = model.draft.value
  const editable = model.editable.value
  const here = !draft || draft.sheetID === model.activeSheetID.value
  const cell = draft?.cell ?? model.selection.value.anchor

  useEffect(() => {
    const element = inputRef.current
    const text = here ? (draft?.text ?? '') : ''
    if (element && !composing.current && element.value !== text) element.value = text
  }, [draft, here, inputRef])
  useDraftCaret(inputRef, here ? draft?.caret : undefined)

  const open = (text: string) => {
    if (model.draft.peek()) model.type(text)
    else if (model.editable.peek()) model.edit(model.selection.peek().anchor, text)
  }

  return (
    <>
      <textarea
        ref={inputRef}
        aria-label={t('pod.spreadsheet.cell_editor', { cell: cellName(cell) })}
        data-spreadsheet-cell-editor=""
        data-editing={draft && here ? '' : undefined}
        readOnly={!editable}
        spellCheck={false}
        rows={1}
        className={cn(
          'absolute z-10 m-0 resize-none overflow-hidden border-2 border-blue-60 px-[3px] py-px leading-tight whitespace-pre-wrap outline-none [field-sizing:content]',
          !(draft && here) && 'pointer-events-none opacity-0'
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
          const command = event.metaKey || event.ctrlKey
          if (command && event.shiftKey && event.key.toLowerCase() === 'v') pasteMode.current = 'values'
          if (event.altKey && (event.key === '=' || event.code === 'Equal') && model.editable.peek()) {
            event.preventDefault()
            if (model.draft.peek()) void model.commitEdit()
            void model.autoSum('SUM')
            return
          }
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
          } else if (event.key === 'Enter' && command) {
            event.preventDefault()
            void model.commitToSelection()
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
          const current = model.draft.peek()
          const pointing =
            current && acceptsReference(current.text, event.currentTarget.selectionStart ?? current.text.length)
          if (next instanceof HTMLElement && next.hasAttribute(SHEET_TAB_ATTRIBUTE) && pointing) return
          if (current) void model.commitEdit()
          model.blur()
        }}
        onCopy={event => {
          if (model.draft.peek()) return
          event.preventDefault()
          void copySelection(model, pageID, false)
        }}
        onCut={event => {
          if (model.draft.peek()) return
          event.preventDefault()
          void copySelection(model, pageID, true)
        }}
        onPaste={event => {
          const mode = pasteMode.current
          pasteMode.current = 'all'
          if (model.draft.peek() || !model.editable.peek()) return
          event.preventDefault()
          const data = event.clipboardData
          const image = [...data.files].find(file => file.type.startsWith('image/'))
          void pasteContents(
            model,
            pageID,
            { html: data.getData('text/html') || undefined, text: data.getData('text/plain'), image },
            mode
          )
        }}
      />
      {draft && here && isFormula(draft.text) && (
        <SpreadsheetFormulaAssist
          input={inputRef.current}
          text={draft.text}
          functions={functions}
          onChange={(text, caret) => model.type(text, caret)}
        />
      )}
    </>
  )
}

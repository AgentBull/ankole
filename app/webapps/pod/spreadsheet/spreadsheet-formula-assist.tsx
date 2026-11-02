import { t } from 'i18next'
import { cn } from '@ankole/uikit'
import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { functionContext, namePrefix, splice, suggestFunctions, toggleAbsolute } from '../state/spreadsheet-formula'
import type { FunctionInfo } from '../state/spreadsheet-grid'

type FormulaInput = HTMLTextAreaElement | HTMLInputElement

/** A function's description in the reader's language when the catalogs carry one, else GridCraft's. */
export function functionDescription(fn: FunctionInfo): string {
  return t(`pod.spreadsheet.function_descriptions.${fn.name}`, { defaultValue: fn.description })
}

/** The parameter list of a signature split around the argument at `index`, for bold display. */
function signatureParts(signature: string, index: number): [string, string, string] {
  const open = signature.indexOf('(')
  const close = signature.lastIndexOf(')')
  if (open < 0 || close < open) return [signature, '', '']
  const params = signature.slice(open + 1, close).split(',')
  const variadic = params.findIndex(param => param.trim() === '...')
  const at = variadic > 0 && index >= variadic - 1 ? variadic - 1 : Math.min(index, params.length - 1)
  const before =
    signature.slice(0, open + 1) +
    params
      .slice(0, at)
      .map(param => `${param},`)
      .join('')
  const current = params[at] ?? ''
  const after = (at + 1 < params.length ? ',' : '') + params.slice(at + 1).join(',') + signature.slice(close)
  return [before, current, after]
}

/**
 * Function suggestions and the argument hint for a formula input. While suggestions show, the
 * arrow keys move through them and Tab or Enter inserts the function with its opening parenthesis;
 * F4 cycles the reference at the caret between relative and absolute forms. `onChange` receives
 * the edited text and the caret after it.
 */
export function SpreadsheetFormulaAssist({
  input,
  text,
  functions,
  onChange
}: {
  input: FormulaInput | null
  text: string
  functions: FunctionInfo[]
  onChange(text: string, caret: number): void
}) {
  const [caret, setCaret] = useState(text.length)
  const [highlight, setHighlight] = useState(0)
  const [dismissed, setDismissed] = useState<string | undefined>()
  const [box, setBox] = useState<DOMRect | undefined>()
  const prefix = namePrefix(text, caret)
  const suggestions = useMemo(
    () => (prefix && dismissed !== text ? suggestFunctions(functions, prefix.prefix) : []),
    [functions, prefix?.prefix, dismissed, text]
  )
  const call = functionContext(text, caret)
  const called = call ? functions.find(fn => fn.name === call.name) : undefined

  useEffect(() => setHighlight(0), [prefix?.prefix])

  useEffect(() => {
    if (!input) return
    const track = () => {
      setCaret(input.selectionStart ?? input.value.length)
      setBox(input.getBoundingClientRect())
    }
    track()
    const events = ['input', 'keyup', 'click', 'select', 'focus'] as const
    for (const event of events) input.addEventListener(event, track)
    return () => {
      for (const event of events) input.removeEventListener(event, track)
    }
  }, [input, text])

  useEffect(() => {
    if (!input) return
    const accept = (fn: FunctionInfo) => {
      if (!prefix) return
      const end = prefix.start + prefix.prefix.length
      const opened = text[end] === '(' ? fn.name : `${fn.name}(`
      const next = splice(text, prefix.start, end, opened)
      onChange(next.text, next.caret + (text[end] === '(' ? 1 : 0))
    }
    // Capture runs before the editor's own handler, so Enter picks a suggestion instead of committing.
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.isComposing) return
      if (event.key === 'F4') {
        const toggled = toggleAbsolute(text, input.selectionStart ?? text.length)
        if (toggled) {
          event.preventDefault()
          event.stopImmediatePropagation()
          onChange(toggled.text, toggled.caret)
        }
        return
      }
      if (!suggestions.length) return
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault()
        event.stopImmediatePropagation()
        const step = event.key === 'ArrowDown' ? 1 : -1
        setHighlight(index => (index + step + suggestions.length) % suggestions.length)
      } else if (event.key === 'Tab' || event.key === 'Enter') {
        event.preventDefault()
        event.stopImmediatePropagation()
        accept(suggestions[highlight] ?? suggestions[0]!)
      } else if (event.key === 'Escape') {
        event.preventDefault()
        event.stopImmediatePropagation()
        setDismissed(text)
      }
    }
    const element: HTMLElement = input
    element.addEventListener('keydown', onKeyDown, true)
    return () => element.removeEventListener('keydown', onKeyDown, true)
  }, [input, text, suggestions, highlight, prefix, onChange])

  if (!input || !box || document.activeElement !== input) return null
  if (!suggestions.length && !called) return null
  const style = { left: box.left, top: box.bottom + 4, maxWidth: Math.max(320, box.width) }
  const [before, current, after] = called && call ? signatureParts(called.signature, call.argument) : ['', '', '']
  return createPortal(
    <div
      className="fixed z-50 w-80 overflow-hidden rounded-control border border-border bg-popover text-sm text-popover-foreground shadow-md"
      style={style}
      role={suggestions.length ? 'listbox' : 'tooltip'}
      aria-label={suggestions.length ? t('pod.spreadsheet.function_suggestions') : t('pod.spreadsheet.function_hint')}
      onPointerDown={event => event.preventDefault()}>
      {suggestions.length > 0 ? (
        <ul className="max-h-72 overflow-y-auto py-1">
          {suggestions.map((fn, index) => (
            <li
              key={fn.name}
              role="option"
              aria-selected={index === highlight}
              className={cn('cursor-pointer px-3 py-1.5', index === highlight && 'bg-accent')}
              onPointerEnter={() => setHighlight(index)}
              onClick={() => {
                if (!prefix) return
                const end = prefix.start + prefix.prefix.length
                const next = splice(text, prefix.start, end, `${fn.name}(`)
                onChange(next.text, next.caret)
              }}>
              <div className="font-mono font-medium">{fn.name}</div>
              <div className="truncate text-xs text-fg-secondary">{functionDescription(fn)}</div>
            </li>
          ))}
        </ul>
      ) : (
        called && (
          <div className="grid gap-1 px-3 py-2">
            <div className="font-mono text-xs">
              {before}
              <strong className="font-semibold text-fg-primary">{current}</strong>
              {after}
            </div>
            <div className="text-xs text-fg-secondary">{functionDescription(called)}</div>
          </div>
        )
      )}
    </div>,
    document.body
  )
}

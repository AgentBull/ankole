import { RiErrorWarningLine, RiFormula, RiQuestionLine } from '@remixicon/react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { Leaf } from '../core/doc'
import { MathBlock, closeMathEditor, mathEditorField, mathEditorOpenKey, mathSourceChange } from '../blocks/math'
import { BlockSelection } from '../editor/block-selection'
import { unitAt } from '../editor/block-target'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

const helpURL = 'https://temml.org/docs/en/supported.html'

/**
 * The formula editor (SPEC §7.6). It follows Notion and Feishu: the formula block shows the
 * rendered result, and a small panel below it accepts LaTeX, previews the error state, and closes
 * on Enter or Escape.
 */
export function MathEditor() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const pos = state.field(mathEditorField, false) ?? null
  const openKey = state.field(mathEditorOpenKey, false) ?? 0
  const panel = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const node = pos === null ? null : state.doc.nodeAt(pos)
  const editing = pos !== null && node?.type === MathBlock
  const source = editing ? ((node as Leaf<string>).param as string) : ''
  const [validation, setValidation] = useState<{ source: string; invalid: boolean }>()
  const invalid = validation?.source === source && validation.invalid
  useEffect(() => {
    if (!editing || !source.trim()) return
    let active = true
    void import('temml')
      .then(({ default: Temml }) => {
        if (!active) return
        try {
          Temml.renderToString(source, { displayMode: true, throwOnError: true })
          setValidation({ source, invalid: false })
        } catch {
          setValidation({ source, invalid: true })
        }
      })
      .catch(() => {
        if (active) setValidation({ source, invalid: true })
      })
    return () => {
      active = false
    }
  }, [editing, source])

  useLayoutEffect(() => {
    if (!openKey) return
    const frame = requestAnimationFrame(() => {
      input.current?.focus()
      input.current?.select()
    })
    return () => cancelAnimationFrame(frame)
  }, [openKey])

  const position = useAnchoredOverlay({
    open: editing && pos !== null,
    panelRef: panel,
    anchor: () => (pos === null ? null : (editor.nodeDOM(pos)?.getBoundingClientRect() ?? null)),
    observe: () => (pos === null ? null : editor.nodeDOM(pos)),
    onClose: () => editor.dispatch({ effects: closeMathEditor.of(null) }),
    shouldIgnore: target => !!target.closest('.math-block'),
    sideOffset: 6,
    dependencies: [pos]
  })

  if (!editing || pos === null) return null
  const close = () => {
    const unit = unitAt(editor.state.doc, pos, 1)
    const selected = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
    editor.dispatch({
      effects: closeMathEditor.of(null),
      ...(selected ? { selection: selected, userEvent: 'select.block' } : {})
    })
    editor.focus()
  }
  const change = (value: string) => {
    const spec = mathSourceChange(editor.state, pos, value)
    if (!spec) return
    editor.dispatch(spec)
    if (editor.connected) editor.flush()
  }
  return createPortal(
    <div
      ref={panel}
      className="ankole-editor-overlay math-editor ceramic ceramic-primary"
      data-invalid={invalid ? 'true' : undefined}
      style={position ?? { visibility: 'hidden' }}
      role="dialog"
      aria-label={label(invalid ? 'math_invalid' : 'math_editor_title')}>
      <div className="math-editor-header">
        {invalid ? <RiErrorWarningLine aria-hidden /> : <RiFormula aria-hidden />}
        <span>{label(invalid ? 'math_invalid' : 'math_editor_title')}</span>
      </div>
      <label className="math-editor-field">
        <input
          ref={input}
          value={source}
          placeholder={label('math_placeholder')}
          aria-label={label('math_placeholder')}
          aria-invalid={invalid ? 'true' : 'false'}
          spellCheck={false}
          autoComplete="off"
          onChange={event => change(event.target.value)}
          onKeyDown={event => {
            if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
            if (event.key === 'Escape' || event.key === 'Enter') {
              event.preventDefault()
              close()
            }
          }}
        />
      </label>
      <div className="math-editor-footer">
        <span>{label('math_hint')}</span>
        <a href={helpURL} target="_blank" rel="noopener noreferrer">
          <RiQuestionLine aria-hidden />
          {label('math_help')}
        </a>
      </div>
    </div>,
    document.body
  )
}

import { ErrorCircleRegular, MathFormulaRegular, QuestionCircleRegular } from '@ankole/uikit/icons'
import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { Leaf } from '../core/doc'
import { GardSelection } from '../core/state'
import {
  InlineMath,
  MathBlock,
  closeMathEditor,
  mathEditorField,
  mathEditorOpenKey,
  mathSourceChange,
  validateFormulaSyntax
} from '../blocks/math'
import { BlockSelection } from '../editor/block-selection'
import { unitAt } from '../editor/block-target'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

const helpURL = 'https://temml.org/docs/en/supported.html'

/**
 * The formula editor (SPEC §7.6). A display or inline formula shows
 * the rendered result, and a small panel below it accepts LaTeX, ignores redundant outer math-mode
 * delimiters (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`), previews the error state, and closes on Enter,
 * Escape, or the Done submit button.
 */
export function MathEditor() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const inputId = useId()
  const pos = state.field(mathEditorField, false) ?? null
  const openKey = state.field(mathEditorOpenKey, false) ?? 0
  const panel = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const node = pos === null ? null : state.doc.nodeAt(pos)
  const isBlock = node?.type === MathBlock
  const isInline = node?.type === InlineMath
  const editing = pos !== null && (isBlock || isInline)
  const source = editing ? ((node as Leaf<string>).param as string) : ''
  const validationKey = `${isBlock ? 'block' : 'inline'}:${source}`
  const syncValid = editing ? validateFormulaSyntax(source, isBlock) : true
  const [asyncValidation, setAsyncValidation] = useState<{ key: string; valid: boolean }>()

  useEffect(() => {
    if (!editing || typeof syncValid === 'boolean') return
    let active = true
    void syncValid.then(valid => {
      if (active) setAsyncValidation({ key: validationKey, valid })
    })
    return () => {
      active = false
    }
  }, [editing, syncValid, validationKey])

  const invalid =
    editing &&
    (typeof syncValid === 'boolean' ? !syncValid : asyncValidation?.key === validationKey && !asyncValidation.valid)

  useLayoutEffect(() => {
    if (!editing || pos === null) return
    const dom = editor.nodeDOM(pos)
    const target = dom?.matches('.math-block, .math-inline')
      ? dom
      : (dom?.querySelector('.math-block, .math-inline') ?? null)
    if (!target) return
    target.setAttribute('data-editing', 'true')
    return () => target.removeAttribute('data-editing')
  }, [editor, editing, pos, source])

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
    shouldIgnore: target => !!target.closest('.math-block, .math-inline'),
    sideOffset: 6,
    dependencies: [pos]
  })

  if (!editing || pos === null) return null
  const close = () => {
    if (isInline) {
      editor.dispatch({
        effects: closeMathEditor.of(null),
        selection: GardSelection.cursor(pos + 1)
      })
      if (editor.connected) editor.flush()
      editor.focus()
      return
    }
    const unit = unitAt(editor.state.doc, pos, 1)
    const selected = unit && BlockSelection.between(editor.state.doc, unit.before, unit.before)
    editor.dispatch({
      effects: closeMathEditor.of(null),
      ...(selected ? { selection: selected, userEvent: 'select.block' } : {})
    })
    if (editor.connected) editor.flush()
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
      <label className="math-editor-header" htmlFor={inputId}>
        {invalid ? <ErrorCircleRegular aria-hidden /> : <MathFormulaRegular aria-hidden />}
        <span>{label(invalid ? 'math_invalid' : 'math_editor_title')}</span>
      </label>
      <form
        className="math-editor-field"
        onSubmit={event => {
          event.preventDefault()
          close()
        }}>
        <input
          id={inputId}
          ref={input}
          value={source}
          placeholder={label('math_placeholder')}
          aria-label={label('math_placeholder')}
          aria-invalid={invalid ? 'true' : 'false'}
          spellCheck={false}
          autoComplete="off"
          onChange={event => change(event.target.value)}
          onKeyDown={event => {
            if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) {
              if (event.key === 'Enter') event.preventDefault()
              return
            }
            if (event.key === 'Escape' || event.key === 'Enter') {
              event.preventDefault()
              close()
            }
          }}
        />
        <button type="submit" className="math-editor-submit">
          {label('math_done')}
        </button>
      </form>
      <div className="math-editor-footer">
        <span>{label('math_hint')}</span>
        <a href={helpURL} target="_blank" rel="noopener noreferrer">
          <span>{label('math_help')}</span>
          <QuestionCircleRegular aria-hidden />
        </a>
      </div>
    </div>,
    document.body
  )
}

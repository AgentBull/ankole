import { RiCheckLine, RiSearchLine } from '@remixicon/react'
import { useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { Plot } from '../core/doc'
import * as T from '../core/types'
import {
  chooseCodeLanguage,
  closeCodeLanguage,
  codeLanguageField,
  codeLanguageState,
  filterCodeLanguages
} from '../editor/code-block'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

/**
 * The code language picker (SPEC §7.6). It opens from the language button of a code block, filters
 * Kirari's languages as the reader types, and writes the chosen language to the block's mark.
 */
export function CodeLanguageMenu() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const pos = state.field(codeLanguageField, false) ?? null
  const [query, setQuery] = useState('')
  const [index, setIndex] = useState(0)
  const list = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const options = useMemo(() => filterCodeLanguages(query), [query])
  const block = pos === null ? null : editor.nodeDOM(pos)
  const node = pos === null ? null : state.doc.nodeAt(pos)
  const language = node?.isPlot ? codeLanguageState((node as Plot).mark(T.CodeBlockLanguage)) : null
  const active = options.length ? Math.min(index, options.length - 1) : -1

  useLayoutEffect(() => {
    if (pos === null) return
    setQuery('')
    setIndex(0)
    // Let the click that opened the picker finish before taking focus from the editor.
    requestAnimationFrame(() => input.current?.focus())
  }, [pos])

  const position = useAnchoredOverlay({
    open: pos !== null,
    panelRef: list,
    anchor: () => {
      if (pos === null) return null
      const block = editor.nodeDOM(pos)
      const trigger = block?.querySelector<HTMLElement>('.editor-code-language')
      return (trigger ?? block)?.getBoundingClientRect() ?? null
    },
    observe: () => (pos === null ? null : editor.nodeDOM(pos)),
    onClose: () => editor.dispatch({ effects: closeCodeLanguage.of(null) }),
    shouldIgnore: target => !!target.closest('.editor-code-language'),
    align: 'end',
    dependencies: [pos, options.length]
  })

  useLayoutEffect(() => {
    list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [active])

  if (pos === null || !block) return null
  const choose = (id: string) => {
    chooseCodeLanguage(editor, pos, id)
    input.current?.blur()
    editor.focus()
  }
  return createPortal(
    <div
      ref={list}
      className="ankole-editor-overlay code-language-menu ceramic ceramic-primary"
      role="dialog"
      aria-label={label('code_search_language')}
      style={position ?? { visibility: 'hidden' }}>
      <div className="code-language-search">
        <RiSearchLine aria-hidden />
        <input
          ref={input}
          value={query}
          placeholder={label('code_search_language')}
          aria-label={label('code_search_language')}
          role="combobox"
          aria-autocomplete="list"
          aria-expanded="true"
          aria-controls={`${editor.contentDOM.id}-code-languages`}
          aria-activedescendant={active >= 0 ? `${editor.contentDOM.id}-code-language-${active}` : undefined}
          onChange={event => {
            setQuery(event.target.value)
            setIndex(0)
          }}
          onKeyDown={event => {
            if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
              event.preventDefault()
              if (!options.length) return
              const step = event.key === 'ArrowDown' ? 1 : -1
              setIndex((active + step + options.length) % options.length)
            } else if (event.key === 'Enter') {
              event.preventDefault()
              if (active >= 0) choose(options[active]!.id)
            } else if (event.key === 'Escape') {
              event.preventDefault()
              editor.dispatch({ effects: closeCodeLanguage.of(null) })
              editor.focus()
            }
          }}
        />
      </div>
      <div
        id={`${editor.contentDOM.id}-code-languages`}
        className="code-language-options"
        role="listbox"
        aria-label={label('code_search_language')}>
        {options.map((option, optionIndex) => (
          <button
            key={option.id}
            id={`${editor.contentDOM.id}-code-language-${optionIndex}`}
            type="button"
            role="option"
            className="code-language-option"
            aria-selected={optionIndex === active}
            onMouseDown={event => event.preventDefault()}
            onMouseEnter={() => setIndex(optionIndex)}
            onClick={() => choose(option.id)}>
            <span>{option.label}</span>
            {language?.canonical === option.id && <RiCheckLine className="code-language-check" aria-hidden />}
          </button>
        ))}
        {!options.length && <p className="code-language-empty">—</p>}
      </div>
    </div>,
    document.body
  )
}

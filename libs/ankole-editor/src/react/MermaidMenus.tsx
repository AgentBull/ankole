import { RiCheckLine } from '@remixicon/react'
import { useEffect, useLayoutEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { Plot } from '../core/doc'
import {
  MermaidTheme,
  MermaidView,
  applyMermaidTemplate,
  closeMermaidMenu,
  mermaidMenuField,
  mermaidTemplates,
  setMermaidTheme,
  setMermaidView,
  type MermaidMenuKind
} from '../blocks/mermaid'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

const kindLabels = {
  view: 'mermaid_view',
  theme: 'mermaid_theme',
  template: 'mermaid_template'
} as const

/**
 * The Mermaid toolbar menus (SPEC §7.6): templates, view modes, and palettes. They share one
 * anchored ceramic surface like the other editor menus.
 */
export function MermaidMenus() {
  const editor = useEditor()
  const label = useEditorLabel()
  const menu = useEditorState(state => state.field(mermaidMenuField, false) ?? null)
  const list = useRef<HTMLDivElement>(null)
  const node = menu === null ? null : editor.state.doc.nodeAt(menu.pos)
  const plot = node?.isPlot ? (node as Plot) : null
  const view = plot?.mark(MermaidView) ?? 'both'
  const theme = plot?.mark(MermaidTheme) ?? 'auto'

  const position = useAnchoredOverlay({
    open: menu !== null,
    panelRef: list,
    anchor: () => {
      if (!menu) return null
      const target = editor.nodeDOM(menu.pos)?.querySelector<HTMLElement>(`[data-mermaid-action="${menu.kind}"]`)
      return target?.getBoundingClientRect() ?? null
    },
    observe: () => (menu === null ? null : editor.nodeDOM(menu.pos)),
    onClose: () => editor.dispatch({ effects: closeMermaidMenu.of(null) }),
    shouldIgnore: target => !!target.closest(`[data-mermaid-action="${menu?.kind}"]`),
    align: 'end',
    dependencies: [menu?.pos, menu?.kind]
  })

  useLayoutEffect(() => {
    if (menu) list.current?.querySelector<HTMLButtonElement>('button')?.focus()
  }, [menu])

  useEffect(() => {
    if (!menu) return
    const key = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      editor.dispatch({ effects: closeMermaidMenu.of(null) })
      editor.focus()
    }
    document.addEventListener('keydown', key, true)
    return () => document.removeEventListener('keydown', key, true)
  }, [editor, menu])

  if (!menu || !plot) return null
  const choose = (kind: MermaidMenuKind, value: string) => {
    if (kind === 'view') setMermaidView(editor, menu.pos, value as 'both' | 'code' | 'diagram')
    else if (kind === 'theme') setMermaidTheme(editor, menu.pos, value as 'auto' | 'light' | 'dark')
    else {
      const template = mermaidTemplates.find(item => item.id === value)
      if (template) applyMermaidTemplate(editor, menu.pos, template.source)
    }
    editor.focus()
  }
  const option = (
    id: string,
    text: string,
    selected: boolean,
    role: 'menuitemradio' | 'menuitem' = 'menuitemradio'
  ) => (
    <button
      key={id}
      type="button"
      role={role}
      className="mermaid-menu-option"
      aria-checked={role === 'menuitemradio' ? selected : undefined}
      onMouseDown={event => event.preventDefault()}
      onClick={() => choose(menu.kind, id)}>
      <span>{text}</span>
      {selected && <RiCheckLine className="mermaid-menu-check" aria-hidden />}
    </button>
  )
  return createPortal(
    <div
      ref={list}
      className="ankole-editor-overlay mermaid-menu ceramic ceramic-primary"
      role="menu"
      aria-label={label(kindLabels[menu.kind])}
      style={position ?? { visibility: 'hidden' }}>
      {menu.kind === 'view' && (
        <>
          {option('both', label('mermaid_view_both'), view === 'both')}
          {option('code', label('mermaid_view_code'), view === 'code')}
          {option('diagram', label('mermaid_view_diagram'), view === 'diagram')}
        </>
      )}
      {menu.kind === 'theme' && (
        <>
          {option('auto', label('mermaid_theme_auto'), theme === 'auto')}
          {option('light', label('mermaid_theme_light'), theme === 'light')}
          {option('dark', label('mermaid_theme_dark'), theme === 'dark')}
        </>
      )}
      {menu.kind === 'template' &&
        mermaidTemplates.map(template => option(template.id, template.title(editor.state), false, 'menuitem'))}
    </div>,
    document.body
  )
}

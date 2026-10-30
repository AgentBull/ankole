import { RiCloseLine } from '@remixicon/react'
import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { Plot } from '../core/doc'
import { MermaidTheme, closeExpandedMermaid, expandedMermaidField } from '../blocks/mermaid'
import { MermaidPreview } from '../blocks/mermaid/preview'
import { useEditor, useEditorLabel, useEditorState } from './context'

/** A full-window preview of one Mermaid block, opened from its toolbar. */
export function MermaidExpanded() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const pos = state.field(expandedMermaidField, false) ?? null
  const node = pos === null ? null : state.doc.nodeAt(pos)
  const plot = node?.isPlot ? (node as Plot) : null
  const source = plot ? plot.textContent() : ''
  const theme = plot?.mark(MermaidTheme) ?? 'auto'
  const placeholder = label('mermaid_placeholder')
  const dialog = useRef<HTMLDialogElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  const preview = useRef<HTMLDivElement>(null)
  const controller = useRef<MermaidPreview | null>(null)
  const open = plot !== null && pos !== null

  useEffect(() => {
    if (!open) return
    const element = preview.current
    if (!element) return
    const current = new MermaidPreview(element, true)
    controller.current = current
    return () => {
      current.destroy()
      controller.current = null
    }
  }, [open])

  useEffect(() => {
    if (!open) return
    controller.current?.setSource(source, placeholder)
  }, [open, source, placeholder])

  useEffect(() => {
    const element = dialog.current
    if (!open || !element) return
    if (!element.open) element.showModal()
    closeButton.current?.focus()
    return () => {
      if (element.open) element.close()
    }
  }, [open])

  if (!open) return null
  const close = () => {
    dialog.current?.close()
    editor.dispatch({ effects: closeExpandedMermaid.of(null) })
    editor.focus()
  }
  return createPortal(
    <dialog
      ref={dialog}
      className="ankole-editor-overlay mermaid-expanded ceramic ceramic-primary"
      aria-label={label('mermaid_title')}
      onCancel={event => {
        event.preventDefault()
        close()
      }}>
      <div className="mermaid-expanded-header">
        <strong>{label('mermaid_title')}</strong>
        <span>
          {theme === 'auto'
            ? label('mermaid_theme_auto')
            : theme === 'light'
              ? label('mermaid_theme_light')
              : label('mermaid_theme_dark')}
        </span>
        <button
          ref={closeButton}
          type="button"
          className="mermaid-expanded-close"
          aria-label={label('mermaid_close')}
          onClick={close}>
          <RiCloseLine />
        </button>
      </div>
      <div ref={preview} className="mermaid-expanded-preview" data-theme={theme} />
    </dialog>,
    document.body
  )
}

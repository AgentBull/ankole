import { RiUpload2Line } from '@remixicon/react'
import { useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { closeFileUpload, fileUploadField } from '../editor/file-upload'
import { editorHost } from '../editor/host-context'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

/**
 * The file upload panel (SPEC §7.6). The `file` menu entry opens it at the caret. Choosing or
 * dropping files hands them to the host, which stores them outside the document; the panel stays
 * open with the error when the host rejects them, so the reader can try again.
 */
export function FileUpload() {
  const editor = useEditor()
  const label = useEditorLabel()
  const pos = useEditorState(state => state.field(fileUploadField, false) ?? null)
  const panel = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const zone = useRef<HTMLButtonElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [dragging, setDragging] = useState(false)
  const open = pos !== null

  const close = () => {
    if (busy) return
    editor.dispatch({ effects: closeFileUpload.of(null) })
    editor.focus()
  }
  const position = useAnchoredOverlay({
    open,
    panelRef: panel,
    anchor: () => (pos === null ? null : editor.coordsAtPos(Math.min(pos, editor.state.doc.length), 1)),
    onClose: close,
    sideOffset: 6,
    dependencies: [pos]
  })

  const visible = open && position !== null
  useLayoutEffect(() => {
    if (!visible) return
    setError('')
    zone.current?.focus()
  }, [visible])

  if (pos === null) return null
  const accept = async (files: File[]) => {
    const host = editorHost(editor)
    if (!files.length || busy || !host?.acceptFiles) return
    setBusy(true)
    setError('')
    try {
      await host.acceptFiles(files)
      editor.dispatch({ effects: closeFileUpload.of(null) })
      editor.focus()
    } catch (reason) {
      setError(reason instanceof Error && reason.message ? reason.message : label('resource_upload_failed'))
    } finally {
      setBusy(false)
    }
  }
  return createPortal(
    <div
      ref={panel}
      className="ankole-editor-overlay file-upload ceramic ceramic-primary"
      style={position ?? { visibility: 'hidden' }}
      role="dialog"
      aria-label={label('file_title')}
      aria-busy={busy}
      onKeyDown={event => {
        if (event.key !== 'Escape') return
        event.preventDefault()
        close()
      }}>
      <input
        ref={input}
        className="sr-only"
        type="file"
        multiple
        tabIndex={-1}
        aria-hidden
        onChange={event => {
          const files = Array.from(event.target.files ?? [])
          event.target.value = ''
          void accept(files)
        }}
      />
      <button
        ref={zone}
        type="button"
        className="file-upload-zone"
        data-dragging={dragging ? 'true' : undefined}
        disabled={busy}
        onClick={() => input.current?.click()}
        onDragOver={event => {
          if (!event.dataTransfer.types.includes('Files')) return
          event.preventDefault()
          event.stopPropagation()
          event.dataTransfer.dropEffect = 'copy'
          setDragging(true)
        }}
        onDragLeave={event => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragging(false)
        }}
        onDrop={event => {
          event.preventDefault()
          event.stopPropagation()
          setDragging(false)
          void accept(Array.from(event.dataTransfer.files))
        }}>
        <RiUpload2Line aria-hidden />
        <span>{label(busy ? 'resource_uploading' : 'file_upload_choose')}</span>
      </button>
      <p className="file-upload-hint">{label('file_upload_hint')}</p>
      {error && (
        <p className="file-upload-error" role="alert">
          {error}
        </p>
      )}
    </div>,
    document.body
  )
}

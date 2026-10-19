import { useCallback, useEffect, useEffectEvent, useState, type ReactNode } from 'react'
import { Wordgard } from '../core/editor'
import { GardState } from '../core/state'
import type { Element } from '../document/tree'
import { emptyPageHint } from '../editor/empty-page'
import { editorExtension, initialState } from '../editor/extension'
import { BlockHandles, blockMenus, KeyboardBlockMenu } from './BlockMenus'
import { EditorContext, type EditorHandle } from './context'
import { attachHost, hostExtension, type EditorHost } from '../editor/host'
import { EditorToolbar } from './EditorToolbar'
import { SelectionToolbar } from './SelectionToolbar'
import { SlashMenu, slashMenu } from './SlashMenu'

export type BlockEditorProps = {
  /** Initial content is read once. Use PageSession for edits, or a new key for a new document. */
  initial?: string | Element
  onReady?: (editor: Wordgard) => void | (() => void)
  /** Content changed. Read a snapshot through PageSession when the host needs it. */
  onChange?: () => void
  /** A rejected edit keeps the previous document, selection and undo history. */
  onError?: (error: unknown) => void
  readOnly?: boolean
  ariaLabel?: string
  placeholder?: string
  className?: string
  header?: ReactNode
  footer?: ReactNode
  /** A custom toolbar runs inside the editor context. Set null to hide it. */
  toolbar?: ReactNode
  children?: ReactNode
  /** Stable for this editor instance. A new host requires a new editor key. */
  host?: EditorHost
}

type Options = { readOnly: boolean; ariaLabel: string; placeholder: string }

const editable = GardState.Compartment.define()

const editableExtension = (readOnly: boolean) => [Wordgard.editable.of(!readOnly), GardState.readOnly.of(readOnly)]

// `indent` levels 1 to 49 (SPEC §7.6) move a block 40px each. Imported pages may have more levels.
const indentLevels = 49
const indentStyles = Wordgard.styles({
  '[data-indent]': { paddingInlineStart: `${indentLevels * 40}px` },
  ...Object.fromEntries(
    Array.from({ length: indentLevels }, (_, index) => [
      `[data-indent="${index + 1}"]`,
      { paddingInlineStart: `${(index + 1) * 40}px` }
    ])
  )
})

function createHandle(
  initial: string | Element,
  options: Options,
  changed: () => void,
  failed: (error: unknown) => void,
  host?: EditorHost
): EditorHandle {
  const listeners = new Set<() => void>()
  let drawn: GardState
  const editor = Wordgard.create({
    state: initialState(initial, [
      // An open slash menu takes its keys before any editing key binding.
      slashMenu,
      Wordgard.exceptionSink.of(failed),
      host ? hostExtension(host) : [],
      editorExtension(),
      editable.of(editableExtension(options.readOnly)),
      Wordgard.editorAttributes.of({ class: 'editor-view' }),
      Wordgard.contentAttributes.of({
        class: 'editor-content',
        'aria-label': options.ariaLabel,
        'aria-placeholder': options.placeholder
      }),
      emptyPageHint(options.placeholder),
      indentStyles,
      blockMenus,
      // Hosts hear of a change when it is dispatched. React components read the DOM, so they
      // update after the editor draws.
      Wordgard.transactionListener.of(trs => {
        if (trs.some(tr => tr.docChanged)) changed()
      }),
      Wordgard.updateListener.of(update => {
        drawn = update.state
        for (const listener of listeners) listener()
      })
    ])
  })
  drawn = editor.state
  return {
    editor,
    drawn: () => drawn,
    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}

export function BlockEditor({
  initial = '',
  onReady,
  onChange,
  onError,
  readOnly = false,
  ariaLabel = '文档编辑器',
  placeholder = '输入 / 添加 Block，或直接开始写作…',
  className = '',
  header,
  footer,
  toolbar,
  children,
  host
}: BlockEditorProps) {
  const [failure, setFailure] = useState<unknown>()
  const changed = useEffectEvent(() => {
    setFailure(undefined)
    onChange?.()
  })
  const failed = useEffectEvent((error: unknown) => {
    if (onError) onError(error)
    else setFailure(error)
  })
  const [handle] = useState(() =>
    createHandle(
      initial,
      { readOnly, ariaLabel, placeholder },
      () => changed(),
      error => failed(error),
      host
    )
  )
  const { editor } = handle
  const [anchor, setAnchor] = useState<HTMLDivElement | null>(null)
  const ready = useEffectEvent(() => onReady?.(editor))

  const mountEditor = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node) return
      node.appendChild(editor.dom)
      setAnchor(node)
      return () => {
        editor.dom.remove()
        setAnchor(null)
      }
    },
    [editor]
  )
  useEffect(() => ready(), [editor])
  useEffect(() => attachHost(editor, host), [editor, host])
  useEffect(() => {
    editor.dispatch({ effects: editable.reconfigure(editableExtension(readOnly)) })
  }, [editor, readOnly])

  return (
    <EditorContext.Provider value={handle}>
      <div className={`ankole-editor ${className}`}>
        {failure !== undefined && <p role="alert">{failure instanceof Error ? failure.message : String(failure)}</p>}
        <fieldset disabled={readOnly} style={{ display: 'contents' }}>
          {toolbar === undefined ? <EditorToolbar /> : toolbar}
        </fieldset>
        <div className="document-scroll">
          {header}
          <div className="editor-anchor" ref={mountEditor}>
            {!readOnly && anchor && (
              <>
                <SlashMenu />
                <SelectionToolbar />
                <KeyboardBlockMenu />
                <BlockHandles anchor={anchor} />
              </>
            )}
          </div>
          {footer}
        </div>
      </div>
      {children}
    </EditorContext.Provider>
  )
}

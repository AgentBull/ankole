import { useEffect, useEffectEvent, useLayoutEffect, useState, type ReactNode } from 'react'
import { Wordgard } from '../core/editor'
import { GardState } from '../core/state'
import type { Element } from '../document/tree'
import { emptyPageHint } from '../editor/empty-page'
import { editorExtension, initialState } from '../editor/extension'
import { BlockHandles, blockMenus, KeyboardBlockMenu } from './BlockMenus'
import { EditorContext, type EditorHandle } from './context'
import { EditorToolbar } from './EditorToolbar'
import { SelectionToolbar } from './SelectionToolbar'
import { SlashMenu, slashMenu } from './SlashMenu'

export type BlockEditorProps = {
  /** Initial content is read once. Use PageSession for edits, or a new key for a new document. */
  initial?: string | Element
  onReady?: (editor: Wordgard) => void | (() => void)
  /** Content changed. Read a snapshot through PageSession when the host needs it. */
  onChange?: () => void
  readOnly?: boolean
  ariaLabel?: string
  placeholder?: string
  className?: string
  header?: ReactNode
  footer?: ReactNode
  /** A custom toolbar runs inside the editor context. Set null to hide it. */
  toolbar?: ReactNode
  children?: ReactNode
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

function createHandle(initial: string | Element, options: Options, changed: () => void): EditorHandle {
  const listeners = new Set<() => void>()
  let drawn: GardState
  const editor = Wordgard.create({
    state: initialState(initial, [
      // An open slash menu takes its keys before any editing key binding.
      slashMenu,
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
  readOnly = false,
  ariaLabel = '文档编辑器',
  placeholder = '输入 / 添加 Block，或直接开始写作…',
  className = '',
  header,
  footer,
  toolbar,
  children
}: BlockEditorProps) {
  const changed = useEffectEvent(() => onChange?.())
  const [handle] = useState(() => createHandle(initial, { readOnly, ariaLabel, placeholder }, () => changed()))
  const { editor } = handle
  const [anchor, setAnchor] = useState<HTMLDivElement | null>(null)
  const ready = useEffectEvent(() => onReady?.(editor))

  useLayoutEffect(() => {
    if (!anchor) return
    anchor.appendChild(editor.dom)
    return () => editor.dom.remove()
  }, [editor, anchor])
  useEffect(() => ready(), [editor])
  useEffect(() => {
    editor.dispatch({ effects: editable.reconfigure(editableExtension(readOnly)) })
  }, [editor, readOnly])

  return (
    <EditorContext.Provider value={handle}>
      <div className={`ankole-editor ${className}`}>
        <fieldset disabled={readOnly} style={{ display: 'contents' }}>
          {toolbar === undefined ? <EditorToolbar /> : toolbar}
        </fieldset>
        <div className="document-scroll">
          {header}
          <div className="editor-anchor" ref={setAnchor}>
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

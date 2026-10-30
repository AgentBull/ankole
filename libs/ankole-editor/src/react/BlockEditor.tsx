import { useCallback, useEffect, useEffectEvent, useState, type ReactNode } from 'react'
import { Decoration, Wordgard } from '../core/editor'
import { GardState } from '../core/state'
import type { Element } from '../document/tree'
import { emptyPageHint } from '../editor/empty-page'
import { editorExtension, initialState } from '../editor/extension'
import { BlockHandles, blockMenus, KeyboardBlockMenu } from './BlockMenus'
import { BlockMarquee } from './BlockMarquee'
import { CodeLanguageMenu } from './CodeLanguageMenu'
import { ColumnResizers, columnResizing } from './ColumnResizers'
import { EditorContext, type EditorHandle } from './context'
import { hostExtension } from '../editor/host'
import { attachHost, type EditorHost } from '../editor/host-context'
import { EditorToolbar } from './EditorToolbar'
import { ResourceBlocks } from './ResourceBlocks'
import { CalloutMenu } from './CalloutMenu'
import { TableTools } from './TableTools'
import { TableScroll } from './TableScroll'
import { MathEditor } from './MathEditor'
import { MermaidExpanded } from './MermaidExpanded'
import { MermaidMenus } from './MermaidMenus'
import { MentionMenu, mentionMenu } from './MentionMenu'
import { SelectionToolbar } from './SelectionToolbar'
import { SlashMenu, slashMenu } from './SlashMenu'
import { FileUpload } from './FileUpload'
import { editorPhrases, type EditorLabels } from '../editor/phrases'
import { Comment } from '../editor/schema'

export type BlockEditorProps = {
  /** Initial content is read once. Use PageSession for edits, or a new key for a new document. */
  initial?: string | Element
  onReady?: (editor: Wordgard, handle: EditorHandle) => void | (() => void)
  /** Content changed. Read a snapshot through PageSession when the host needs it. */
  onChange?: () => void
  /** A rejected edit keeps the previous document, selection and undo history. */
  onError?: (error: unknown) => void
  readOnly?: boolean
  ariaLabel?: string
  placeholder?: string
  /** Host translations for the editor interface; document parsing is unchanged. */
  labels?: Partial<EditorLabels>
  className?: string
  header?: ReactNode
  footer?: ReactNode
  /** A custom toolbar runs inside the editor context. Set null to hide it. */
  toolbar?: ReactNode
  /** Host-owned insert actions share the block's left-hand menu and insertion position. */
  insertMenu?: (prepareInsertion: () => void) => ReactNode
  children?: ReactNode
  /** Stable for this editor instance. A new host requires a new editor key. */
  host?: EditorHost
  /** Resolved threads retain document anchors without passive highlights or click targets. */
  resolvedCommentIDs?: readonly string[]
}

type Options = { readOnly: boolean; ariaLabel?: string; placeholder?: string; labels?: Partial<EditorLabels> }

const editable = GardState.Compartment.define()
const interfaceLabels = GardState.Compartment.define()
const commentPresentation = GardState.Compartment.define()
const noResolvedComments: readonly string[] = []

function commentAppearance(resolved: readonly string[]) {
  const hidden = new Set(resolved)
  return Decoration.Mark.shape(Comment, {
    element: 'span',
    attributes: (ids): Record<string, string> => {
      const open = ids.filter(id => !hidden.has(id))
      return open.length ? { class: 'editor-comment-anchor', 'data-comment-ids': open.join(' ') } : {}
    }
  })
}

function labelExtension({ labels, ariaLabel, placeholder }: Omit<Options, 'readOnly'>) {
  return [
    editorPhrases.translatePartial(labels ?? {}),
    Wordgard.contentAttributes.of(editor => ({
      'aria-label': ariaLabel ?? editorPhrases.get(editor.state, 'document'),
      'aria-placeholder': placeholder ?? editorPhrases.get(editor.state, 'placeholder'),
      tabindex: '0'
    })),
    emptyPageHint(state => placeholder ?? editorPhrases.get(state, 'placeholder'))
  ]
}

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
      // An open slash or mention menu takes its keys before any editing key binding.
      slashMenu,
      mentionMenu,
      Wordgard.exceptionSink.of(failed),
      host ? hostExtension(host) : [],
      editorExtension(),
      editable.of(editableExtension(options.readOnly)),
      interfaceLabels.of(labelExtension(options)),
      commentPresentation.of(commentAppearance(noResolvedComments)),
      Wordgard.editorAttributes.of({ class: 'editor-view' }),
      Wordgard.contentAttributes.of({ class: 'editor-content' }),
      indentStyles,
      blockMenus,
      columnResizing,
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
  ariaLabel,
  placeholder,
  labels,
  className = '',
  header,
  footer,
  toolbar,
  insertMenu,
  children,
  host,
  resolvedCommentIDs = noResolvedComments
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
      { readOnly, ariaLabel, placeholder, labels },
      () => changed(),
      error => failed(error),
      host
    )
  )
  const { editor } = handle
  const [anchor, setAnchor] = useState<HTMLDivElement | null>(null)
  const ready = useEffectEvent(() => onReady?.(editor, handle))

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
  useEffect(() => {
    editor.dispatch({ effects: interfaceLabels.reconfigure(labelExtension({ labels, ariaLabel, placeholder })) })
  }, [editor, labels, ariaLabel, placeholder])
  useEffect(() => {
    editor.dispatch({ effects: commentPresentation.reconfigure(commentAppearance(resolvedCommentIDs)) })
  }, [editor, resolvedCommentIDs])

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
            {anchor && <SelectionToolbar />}
            {anchor && <TableScroll />}
            {anchor && <ResourceBlocks host={host} />}
            {anchor && <MermaidExpanded />}
            {!readOnly && anchor && (
              <>
                <SlashMenu />
                <MentionMenu />
                <CodeLanguageMenu />
                <MathEditor />
                <FileUpload />
                <TableTools />
                <CalloutMenu />
                <MermaidMenus />
                <KeyboardBlockMenu insertMenu={insertMenu} />
                <BlockHandles anchor={anchor} insertMenu={insertMenu} />
                <BlockMarquee anchor={anchor} />
                <ColumnResizers anchor={anchor} />
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

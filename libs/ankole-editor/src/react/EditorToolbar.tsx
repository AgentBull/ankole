import { Button } from '@ankole/uikit/components/button'
import { RiArrowGoBackLine, RiArrowGoForwardLine } from '@remixicon/react'
import { redoDepth, undoDepth } from '../core/history'
import { redo, undo } from '../editor/commands'
import { BlockMenu, InsertMenu } from './BlockMenus'
import { useEditor, useEditorLabel, useEditorState } from './context'

/** The default toolbar. A read-only editor shows only the hint and disabled undo and redo. */
export function EditorToolbar() {
  const label = useEditorLabel()
  const editor = useEditor()
  const locked = useEditorState(state => state.readOnly)
  const canUndo = useEditorState(state => undoDepth(state) > 0)
  const canRedo = useEditorState(state => redoDepth(state) > 0)
  return (
    <div className="editor-toolbar" role="toolbar" aria-label={label('toolbar')}>
      {!locked && (
        <>
          <InsertMenu />
          <BlockMenu />
        </>
      )}
      <span className="editing-hint">{label('hint')}</span>
      <div className="toolbar-spacer" />
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={label('undo')}
        title={label('undo')}
        disabled={locked || !canUndo}
        onClick={() => undo(editor)}>
        <RiArrowGoBackLine />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={label('redo')}
        title={label('redo')}
        disabled={locked || !canRedo}
        onClick={() => redo(editor)}>
        <RiArrowGoForwardLine />
      </Button>
    </div>
  )
}

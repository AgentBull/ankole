import { Button } from '@ankole/uikit/components/button'
import { RiArrowGoBackLine, RiArrowGoForwardLine } from '@remixicon/react'
import { redoDepth, undoDepth } from '../core/history'
import { redo, undo } from '../editor/commands'
import { BlockMenu, InsertMenu } from './BlockMenus'
import { useEditor, useEditorState } from './context'

/** The default toolbar. A read-only editor shows only the hint and disabled undo and redo. */
export function EditorToolbar() {
  const editor = useEditor()
  const locked = useEditorState(state => state.readOnly)
  const canUndo = useEditorState(state => undoDepth(state) > 0)
  const canRedo = useEditorState(state => redoDepth(state) > 0)
  return (
    <div className="editor-toolbar" role="toolbar" aria-label="编辑器工具栏">
      {!locked && (
        <>
          <InsertMenu />
          <BlockMenu />
        </>
      )}
      <span className="editing-hint">选中文字设置格式 · / 添加内容</span>
      <div className="toolbar-spacer" />
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label="撤销"
        title="撤销"
        disabled={locked || !canUndo}
        onClick={() => undo(editor)}>
        <RiArrowGoBackLine />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label="重做"
        title="重做"
        disabled={locked || !canRedo}
        onClick={() => redo(editor)}>
        <RiArrowGoForwardLine />
      </Button>
    </div>
  )
}

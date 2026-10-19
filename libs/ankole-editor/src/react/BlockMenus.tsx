import { Button } from '@ankole/uikit/components/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger
} from '@ankole/uikit/components/dropdown-menu'
import { RiAddLine, RiDraggable, RiMoreLine } from '@remixicon/react'
import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactElement } from 'react'
import type { Command } from '../core/command'
import { Embed, embedAttributes } from '../blocks/embed'
import { editorHost } from '../editor/host'
import type { Node, Pos } from '../core/doc'
import { Decoration, KeyBinding, type Wordgard } from '../core/editor'
import { history } from '../core/history'
import { GardSelection, GardState, Transaction } from '../core/state'
import {
  applyBlockType,
  blockOptions,
  canTurnInto,
  currentBlock,
  deleteBlock,
  duplicateBlocks,
  insertAfterBlock,
  moveBlocks,
  type BlockType
} from '../editor/block-actions'
import { useEditor, useEditorState } from './context'

/*
 * Menus for blocks (SPEC §7.6): the insert menu of the toolbar and of the block handle, and the
 * block menu of the toolbar, of ⌘/ and of the block handle. One state field records the open menu
 * and its top-level block, so that the target follows document changes and the block shows as the
 * target while its menu is open.
 */

type MenuKind = 'insert' | 'block' | 'keyboard' | 'handle-insert' | 'handle'
/**
 * The open menu. `pos` is the position before its top-level block, or null for the insert menu of
 * the toolbar. Each ⌘/ press has its own `request` number.
 */
type OpenMenu = { kind: MenuKind; pos: number | null; request?: number }

let keyboardRequests = 0

const setMenu = Transaction.Effect.define<OpenMenu | null>()

const targetMark = Decoration.Point.attributes({ class: 'block-menu-target' })

const menuField = GardState.Field.define<OpenMenu | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setMenu)) value = effect.value
    if (tr.state.readOnly) return null
    if (!value || value.pos === null || !tr.docChanged) return value
    // A change that deletes the block leaves the menu without a target.
    const pos = tr.changes.mapPos(value.pos, 1, 'after')
    return pos === value.pos ? value : { ...value, pos }
  },
  provide: field =>
    Decoration.Point.source.of(state => {
      const menu = state.field(field)
      return menu && menu.pos !== null && !menu.kind.endsWith('insert')
        ? Decoration.Point.set([[targetMark, menu.pos]])
        : Decoration.Point.none
    })
})

/** The top-level block at `pos`. */
function topBlock(state: GardState, pos: number | null): Pos.Node | null {
  if (pos === null || pos < 0 || pos > state.doc.length) return null
  const found = state.doc.resolveNode(pos)
  return found && !found.parent?.parent ? found : null
}

/** ⌘/ opens the block menu of the current top-level block, unless the selection spans several. */
const openFromKeyboard: Command = wg => {
  const { state } = wg
  const block = topBlock(state, state.readOnly ? null : currentBlock(state))
  if (!block || state.selection.from < block.before || state.selection.to > block.after) return false
  return { effects: setMenu.of({ kind: 'keyboard', pos: block.before, request: ++keyboardRequests }) }
}

/** The state of the block menus and the ⌘/ shortcut. */
export const blockMenus: GardState.Extension = [
  menuField,
  KeyBinding.of({ key: 'Mod-/', run: openFromKeyboard, shift: openFromKeyboard })
]

/**
 * The open state of one menu. The menu opens and closes at once; the editor state records its
 * target, which the editor shows after it draws.
 */
function useMenu(kind: MenuKind) {
  const editor = useEditor()
  const [open, setOpen] = useState(false)
  const change = (next: boolean, pos: number | null = null, reason?: string) => {
    setOpen(next)
    if (next) editor.dispatch({ effects: setMenu.of({ kind, pos }) })
    else {
      if (editor.state.field(menuField)?.kind === kind) editor.dispatch({ effects: setMenu.of(null) })
      // Focus returns to the editor unless the user moved it elsewhere. It returns at once: the menu
      // removes its focused item later, and keys typed before that would go to the item.
      if (reason !== 'outside-press' && reason !== 'focus-out') editor.focus()
    }
  }
  // The menu itself does not move focus when it closes.
  const finalFocus = () => false
  return { editor, open, setOpen, change, finalFocus }
}

const targetOf = (editor: Wordgard) => editor.state.field(menuField, false)?.pos ?? null

export function InsertMenu({ hovered, trigger }: { hovered?: () => number | null; trigger?: ReactElement }) {
  const kind = hovered ? 'handle-insert' : 'insert'
  const { editor, open, change, finalFocus } = useMenu(kind)
  const triggerId = useId()
  return (
    <DropdownMenu
      modal={false}
      open={open}
      triggerId={triggerId}
      onOpenChange={(next, details) => change(next, hovered?.() ?? null, details.reason)}>
      <DropdownMenuTrigger
        id={triggerId}
        {...(hovered ? handleTriggerEvents(() => change(!open, hovered())) : {})}
        render={
          trigger ?? (
            <Button variant="ghost" size="xs">
              <RiAddLine />
              插入
            </Button>
          )
        }
      />
      <DropdownMenuContent className="block-menu ankole-editor-overlay" aria-label="添加 Block" finalFocus={finalFocus}>
        <DropdownMenuLabel>添加内容</DropdownMenuLabel>
        {blockOptions.map(option => (
          <DropdownMenuItem
            key={option.type}
            onClick={() => {
              const pos = targetOf(editor)
              if (!hovered) applyBlockType(editor, option.type)
              else if (topBlock(editor.state, pos)) insertAfterBlock(editor, pos!, option.type)
            }}>
            <span className="menu-icon">{option.glyph}</span>
            <span>
              {option.title}
              <small>{option.detail}</small>
            </span>
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** The block menu. Without `hovered`, it acts on the top-level block that holds the caret. */
export function BlockMenu({ hovered, trigger }: { hovered?: () => number | null; trigger?: ReactElement }) {
  const kind = hovered ? 'handle' : 'block'
  const { editor, open, change, finalFocus } = useMenu(kind)
  const triggerId = useId()
  return (
    <DropdownMenu
      modal={false}
      open={open}
      triggerId={triggerId}
      onOpenChange={(next, details) => change(next, hovered ? hovered() : currentBlock(editor.state), details.reason)}>
      <DropdownMenuTrigger
        id={triggerId}
        {...(hovered ? handleTriggerEvents(() => change(!open, hovered())) : {})}
        render={
          trigger ?? (
            <Button variant="ghost" size="xs" aria-label="当前 Block 菜单" title="当前 Block 菜单 ⌘/Ctrl+/">
              <RiMoreLine />
              Block
            </Button>
          )
        }
      />
      <DropdownMenuContent
        className="block-menu block-actions ankole-editor-overlay"
        aria-label="Block 操作"
        finalFocus={finalFocus}>
        <BlockActions />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** The block menu of ⌘/, anchored at the top of its block. */
export function KeyboardBlockMenu() {
  const { editor, open, setOpen, change, finalFocus } = useMenu('keyboard')
  const request = useEditorState(state => {
    const menu = state.field(menuField, false)
    return menu?.kind === 'keyboard' ? menu : null
  })
  const [top, setTop] = useState(0)
  const triggerId = useId()
  const anchor = useRef<HTMLButtonElement>(null)
  const handled = useRef<number | undefined>(undefined)
  // ⌘/ records a request in the editor state. The menu opens once the editor has drawn it, and
  // only once for each request: a change that moves the block does not open it again.
  useLayoutEffect(() => {
    if (!request) return
    const block = request.pos === null ? null : editor.nodeDOM(request.pos)
    const parent = anchor.current?.offsetParent
    if (block && parent) setTop(block.getBoundingClientRect().top - parent.getBoundingClientRect().top)
    if (handled.current === request.request) return
    handled.current = request.request
    setOpen(true)
  }, [editor, request, setOpen])
  return (
    <DropdownMenu
      modal={false}
      open={open}
      triggerId={triggerId}
      onOpenChange={(next, details) => {
        if (!next) change(false, null, details.reason)
      }}>
      <DropdownMenuTrigger
        id={triggerId}
        render={
          <button ref={anchor} tabIndex={-1} aria-hidden="true" className="keyboard-block-anchor" style={{ top }} />
        }
      />
      <DropdownMenuContent
        className="block-menu block-actions ankole-editor-overlay"
        aria-label="Block 操作"
        finalFocus={finalFocus}>
        <BlockActions />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/**
 * Handle buttons open their menu on click, so that a press that moves starts a drag of the block
 * instead.
 */
function handleTriggerEvents(toggle: () => void) {
  return {
    onMouseDown: (event: { preventBaseUIHandler(): void }) => event.preventBaseUIHandler(),
    onClick: (event: { preventBaseUIHandler(): void }) => {
      event.preventBaseUIHandler()
      toggle()
    }
  }
}

function BlockActions() {
  const editor = useEditor()
  const state = useEditorState()
  const block = topBlock(state, state.field(menuField, false)?.pos ?? null)
  const act = (action: (pos: number) => void) => () => {
    const pos = targetOf(editor)
    if (topBlock(editor.state, pos)) action(pos!)
  }
  const turnInto = (type: BlockType) =>
    act(pos => {
      const { state } = editor
      const target = topBlock(state, pos)
      if (!target?.node.isPlot || !canTurnInto(state, pos)) return
      // The operation acts on the selected block. Keep a caret that is already inside it.
      if (state.selection.from <= target.before || state.selection.to >= target.after) {
        editor.dispatch({ selection: GardSelection.atEnd(state, target as Pos.Plot) })
      }
      applyBlockType(editor, type)
    })
  const remove = async () => {
    const pos = targetOf(editor)
    const target = topBlock(editor.state, pos)
    if (!target || editor.state.readOnly) return
    const ref = target.node.type === Embed.type ? embedAttributes(target.node).ref : undefined
    if (ref && editorHost(editor)?.deleteEmbed) {
      if (!(await editorHost(editor)!.deleteEmbed!(ref))) return
      // A pending network request must not remove another block after a local edit.
      if (topBlock(editor.state, pos)?.node !== target.node) return
    }
    deleteBlock(editor, pos!)
  }
  return (
    <>
      <DropdownMenuLabel>{block ? '当前 Block' : '先将光标放入文档'}</DropdownMenuLabel>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger disabled={!block || !canTurnInto(state, block.before)}>转换为</DropdownMenuSubTrigger>
        <DropdownMenuSubContent className="block-menu ankole-editor-overlay" aria-label="转换 Block 类型">
          {blockOptions
            .filter(option => option.turnInto)
            .map(option => (
              <DropdownMenuItem key={option.type} onClick={turnInto(option.type)}>
                <span className="menu-icon">{option.glyph}</span>
                {option.title}
              </DropdownMenuItem>
            ))}
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuItem disabled={!block} onClick={act(pos => duplicateBlocks(editor, pos))}>
        创建副本
      </DropdownMenuItem>
      <DropdownMenuItem disabled={!block?.index} onClick={act(pos => moveBlocks(editor, -1, pos))}>
        上移
      </DropdownMenuItem>
      <DropdownMenuItem
        disabled={!block || block.index === state.doc.content.length - 1}
        onClick={act(pos => moveBlocks(editor, 1, pos))}>
        下移
      </DropdownMenuItem>
      <DropdownMenuSeparator />
      <DropdownMenuItem disabled={!block} variant="destructive" onClick={() => void remove()}>
        删除 Block
      </DropdownMenuItem>
    </>
  )
}

type Hit = { pos: number; node: Node; dom: HTMLElement; rect: DOMRect }

/**
 * The top-level block at the vertical position `y`, counting the margins around a block as part of
 * it. With `clamp`, a position above or below all blocks gives the first or the last block.
 */
function blockAt(editor: Wordgard, y: number, clamp: boolean): Hit | null {
  let pos = 0,
    first: Hit | null = null,
    last: Hit | null = null
  for (const node of editor.state.doc.content) {
    const dom = editor.nodeDOM(pos)
    if (dom instanceof HTMLElement) {
      const rect = dom.getBoundingClientRect()
      const style = getComputedStyle(dom)
      last = { pos, node, dom, rect }
      first ??= last
      // Blocks follow each other down the page, so no later block holds a position above this one.
      if (y < rect.top - parseFloat(style.marginTop)) break
      if (y <= rect.bottom + parseFloat(style.marginBottom)) return last
    }
    pos += node.length
  }
  if (!clamp || !first || !last) return null
  return y < first.rect.top ? first : y > last.rect.bottom ? last : null
}

/** Move the top-level block at `from` to the position `to` between top-level blocks, as one undo step. */
function moveBlock(editor: Wordgard, from: number, to: number) {
  const node = topBlock(editor.state, from)?.node
  if (!node || to === from || to === from + node.length) return
  editor.dispatch({
    changes: [
      { from, to: from + node.length },
      { from: to, insert: [node] }
    ],
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(to, -1) + 1),
    annotations: history.isolate.of(true),
    userEvent: 'move.block',
    scrollIntoView: true
  })
}

const handleMenuOpen = (state: GardState) => !!state.field(menuField, false)?.kind.startsWith('handle')

/** Handles beside the hovered top-level block: insert below, open the block menu, drag to reorder. */
export function BlockHandles({ anchor }: { anchor: HTMLElement }) {
  const editor = useEditor()
  const [hover, setHover] = useState<{ pos: number; top: number } | null>(null)
  const menuOpen = useEditorState(handleMenuOpen)
  const handle = useRef<HTMLDivElement>(null)
  const line = useRef<HTMLDivElement>(null)
  const dragged = useRef<{ pos: number; doc: GardState['doc'] } | null>(null)
  const hoveredPos = useRef<number | null>(null)
  hoveredPos.current = hover?.pos ?? null
  // The handle stays on its block while one of its menus is open or the block is dragged.
  const keep = () => handleMenuOpen(editor.state) || !!dragged.current

  useEffect(() => {
    const scroller = anchor.parentElement ?? anchor
    const move = (event: MouseEvent) => {
      if (keep()) return
      // Moving onto the handle keeps the current block.
      if ((event.target as Element).closest?.('.drag-handle')) return
      const hit = blockAt(editor, event.clientY, false)
      if (!hit) return setHover(null)
      const handleHeight = handle.current?.offsetHeight ?? 0
      const lineHeight = parseFloat(getComputedStyle(hit.dom).lineHeight)
      const lineBox = Number.isNaN(lineHeight) ? hit.rect.height : Math.min(lineHeight, hit.rect.height)
      const top = hit.rect.top - anchor.getBoundingClientRect().top + (lineBox - handleHeight) / 2
      setHover(previous => (previous?.pos === hit.pos && previous.top === top ? previous : { pos: hit.pos, top }))
    }
    const leave = (event: PointerEvent) => {
      if (event.pointerType === 'mouse' && !keep()) setHover(null)
    }
    const pointerUp = (event: PointerEvent) => {
      if (event.pointerType !== 'mouse') move(event)
    }
    scroller.addEventListener('mousemove', move)
    scroller.addEventListener('pointerup', pointerUp)
    scroller.addEventListener('pointerleave', leave)
    return () => {
      scroller.removeEventListener('mousemove', move)
      scroller.removeEventListener('pointerup', pointerUp)
      scroller.removeEventListener('pointerleave', leave)
    }
  }, [editor, anchor])

  // The positions are stale after a document change. The next pointer move shows the handle again.
  const doc = useEditorState(state => state.doc)
  useEffect(() => {
    if (!keep()) setHover(null)
  }, [doc])

  useEffect(() => {
    const target = (event: DragEvent) => {
      const drag = dragged.current
      if (!drag) return null
      event.preventDefault()
      event.stopPropagation()
      if (editor.state.doc !== drag.doc) return null
      const hit = blockAt(editor, event.clientY, true)
      if (!hit) return null
      const before = event.clientY < hit.rect.top + hit.rect.height / 2
      return { hit, before, to: before ? hit.pos : hit.pos + hit.node.length }
    }
    const over = (event: DragEvent) => {
      const found = target(event)
      const element = line.current
      if (event.dataTransfer && dragged.current) event.dataTransfer.dropEffect = 'move'
      if (!element) return
      if (!found) {
        element.style.opacity = '0'
        return
      }
      const box = anchor.getBoundingClientRect()
      const edge = found.before ? found.hit.rect.top - 4 : found.hit.rect.bottom + 4
      element.style.width = `${box.width}px`
      element.style.transform = `translateY(${edge - box.top - 1}px)`
      element.style.opacity = '1'
    }
    const drop = (event: DragEvent) => {
      const found = target(event)
      const drag = dragged.current
      if (found && drag) moveBlock(editor, drag.pos, found.to)
    }
    anchor.addEventListener('dragover', over, true)
    anchor.addEventListener('drop', drop, true)
    return () => {
      anchor.removeEventListener('dragover', over, true)
      anchor.removeEventListener('drop', drop, true)
    }
  }, [editor, anchor])

  const shown = hover !== null
  return (
    <>
      <div
        draggable
        onDragStart={event => {
          const pos = hoveredPos.current
          const block = pos === null ? null : editor.nodeDOM(pos)
          if (pos === null || !block) return event.preventDefault()
          dragged.current = { pos, doc: editor.state.doc }
          event.dataTransfer.effectAllowed = 'move'
          event.dataTransfer.setData('application/x-ankole-block', String(pos))
          event.dataTransfer.setDragImage(block, 0, 0)
        }}
        onDragEnd={() => {
          dragged.current = null
          if (line.current) line.current.style.opacity = '0'
          setHover(null)
          editor.focus()
        }}>
        <div
          ref={handle}
          className="drag-handle"
          data-menu-open={menuOpen}
          style={shown ? { top: hover.top } : { visibility: 'hidden' }}>
          <InsertMenu
            hovered={() => hoveredPos.current}
            trigger={
              <Button variant="ghost" size="icon-xs" aria-label="在下方添加 Block" title="在下方添加 Block">
                <RiAddLine />
              </Button>
            }
          />
          <BlockMenu
            hovered={() => hoveredPos.current}
            trigger={
              <Button variant="ghost" size="icon-xs" aria-label="Block 菜单" title="点击打开菜单，拖动调整顺序">
                <RiDraggable />
              </Button>
            }
          />
        </div>
      </div>
      <div className="drag-line" ref={line} />
    </>
  )
}

import { Button } from '@ankole/uikit/components/button'
import { Input } from '@ankole/uikit/components/input'
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
import {
  RiAddLine,
  RiArrowDownLine,
  RiArrowUpLine,
  RiDeleteBinLine,
  RiDraggable,
  RiFileCopyLine,
  RiMoreLine,
  RiText
} from '@remixicon/react'
import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactElement, type ReactNode } from 'react'
import type { Command } from '../core/command'
import { Embed, embedAttributes } from '../blocks/embed'
import { editorHost } from '../editor/host-context'
import { type Pos } from '../core/doc'
import { Decoration, KeyBinding, type Wordgard } from '../core/editor'
import { scrollableParents } from '../core/editor/dom'
import { GardSelection, GardState, Transaction } from '../core/state'
import {
  applyBlockType,
  blockTypeAt,
  canTurnInto,
  currentBlock,
  actionUnits,
  removal,
  duplicateBlocks,
  insertBesideBlock,
  moveBlocks,
  turnBlockInto
} from '../editor/block-actions'
import { blockOptions, filterBlockOptions, type BlockType } from '../editor/block-catalog'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { adjacentUnit, targetAt } from '../editor/block-target'
import { dispatchStep, isList } from '../editor/block-insert'
import { BlockSelection } from '../editor/block-selection'
import { blockAt, blockDrop } from './block-geometry'
import * as T from '../core/types'
import { BlockTypeIcon } from './block-type-icon'
import { BlockTypeItems } from './BlockTypeItems'

/*
 * Menus for blocks (SPEC §7.6): the insert menu of the toolbar and of the block handle, and the
 * block menu of the toolbar, of ⌘/ and of the block handle. One state field records the open menu
 * and its block, so that the target follows document changes and the block shows as the
 * target while its menu is open.
 */

type MenuKind = 'insert' | 'block' | 'keyboard' | 'handle-insert' | 'handle'
/**
 * The open menu. `pos` is the position before its block, or null for the insert menu of
 * the toolbar. Each ⌘/ press has its own `request` number.
 */
type OpenMenu = { kind: MenuKind; pos: number | null; request?: number; inserting?: boolean }

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
      return menu && menu.pos !== null && !menu.inserting && !menu.kind.endsWith('insert')
        ? Decoration.Point.set([[targetMark, menu.pos]])
        : Decoration.Point.none
    })
})

/** The block or list item at `pos`. */
function menuTarget(state: GardState, pos: number | null): Pos.Node | null {
  if (pos === null || pos < 0 || pos > state.doc.length) return null
  return targetAt(state.doc, pos)
}

/** ⌘/ opens the menu for the current block or whole block selection. */
const openFromKeyboard: Command = wg => {
  const { state } = wg
  const block = menuTarget(state, state.readOnly ? null : currentBlock(state))
  if (
    !block ||
    (!(state.selection instanceof BlockSelection) &&
      (state.selection.from < block.before || state.selection.to > block.after))
  ) {
    return false
  }
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

export function InsertMenu({
  hovered,
  trigger,
  children
}: {
  hovered?: () => number | null
  trigger?: ReactElement
  children?: (prepareInsertion: () => void) => ReactNode
}) {
  const label = useEditorLabel()
  const kind = hovered ? 'handle-insert' : 'insert'
  const { editor, open, change, finalFocus } = useMenu(kind)
  const triggerId = useId()
  const toggle = (next: boolean, reason?: string, before = false) => {
    if (next && !open) {
      const pos = hovered?.()
      if (pos !== undefined && pos !== null) insertBesideBlock(editor, pos, 'paragraph', before)
    }
    change(next, hovered ? currentBlock(editor.state) : null, reason)
  }
  return (
    <DropdownMenu
      modal={false}
      open={open}
      triggerId={triggerId}
      onOpenChange={(next, details) => toggle(next, details.reason)}>
      <DropdownMenuTrigger
        id={triggerId}
        {...(hovered ? handleTriggerEvents(event => toggle(!open, undefined, event.altKey)) : {})}
        render={
          trigger ?? (
            <Button variant="ghost" size="xs">
              <RiAddLine />
              {label('insert')}
            </Button>
          )
        }
      />
      <DropdownMenuContent
        className="block-menu ankole-editor-overlay"
        aria-label={label('insert_block')}
        finalFocus={finalFocus}>
        {open && <InsertChoices close={() => toggle(false)}>{children}</InsertChoices>}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** The target has already been chosen when the menu opens, including host insertions. */
function prepareInsertion(editor: Wordgard) {
  const block = menuTarget(editor.state, targetOf(editor))
  if (block) editor.dispatch({ selection: GardSelection.near(editor.state, block.before + 1, 1) })
}

type InsertExtras = (prepareInsertion: () => void) => ReactNode

function InsertChoices({ close, children }: { close(): void; children?: InsertExtras }) {
  const editor = useEditor()
  const label = useEditorLabel()
  const [filter, setFilter] = useState('')
  const options = filterBlockOptions(editor.state, filter)
  const choose = (type: BlockType) => {
    prepareInsertion(editor)
    applyBlockType(editor, type)
    editor.focus()
  }
  return (
    <>
      <Input
        variant="overlay"
        autoFocus
        value={filter}
        aria-label={label('filter_blocks')}
        placeholder={label('filter_blocks')}
        onChange={event => setFilter(event.target.value)}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) {
            event.stopPropagation()
            return
          }
          if (event.key === 'Enter' && options[0]) {
            event.preventDefault()
            event.stopPropagation()
            choose(options[0].type)
            close()
          } else if (!['ArrowDown', 'ArrowUp', 'Escape', 'Tab'].includes(event.key)) {
            event.stopPropagation()
          }
        }}
      />
      <BlockTypeItems options={options} onChoose={choose} />
      {children && <DropdownMenuSeparator />}
      {children?.(() => {
        prepareInsertion(editor)
        editor.focus()
      })}
    </>
  )
}

function BlockMenuBody({ close, insertMenu }: { close(): void; insertMenu?: InsertExtras }) {
  const inserting = useEditorState(state => state.field(menuField, false)?.inserting)
  return inserting ? <InsertChoices close={close}>{insertMenu}</InsertChoices> : <BlockActions />
}

/** The block menu. Without `hovered`, it acts on the top-level block that holds the caret. */
export function BlockMenu({
  hovered,
  trigger,
  typeTrigger,
  insertMenu
}: {
  hovered?: () => number | null
  trigger?: ReactElement
  typeTrigger?: ReactElement
  insertMenu?: InsertExtras
}) {
  const label = useEditorLabel()
  const kind = hovered ? 'handle' : 'block'
  const { editor, open, change, finalFocus } = useMenu(kind)
  const gripId = useId()
  const typeId = useId()
  const [triggerId, setTriggerId] = useState(gripId)
  const inserting = useEditorState(state => state.field(menuField, false)?.inserting)
  const toggle = (id: string) => {
    setTriggerId(id)
    change(!open, hovered ? hovered() : currentBlock(editor.state))
  }
  return (
    <DropdownMenu
      modal={false}
      open={open}
      triggerId={triggerId}
      onOpenChange={(next, details) => change(next, hovered ? hovered() : currentBlock(editor.state), details.reason)}>
      {typeTrigger && (
        <DropdownMenuTrigger id={typeId} {...handleTriggerEvents(() => toggle(typeId))} render={typeTrigger} />
      )}
      <DropdownMenuTrigger
        id={gripId}
        {...(hovered ? handleTriggerEvents(() => toggle(gripId)) : {})}
        render={
          trigger ?? (
            <Button
              variant="ghost"
              size="xs"
              aria-label={label('current_block_menu')}
              title={`${label('current_block_menu')} ⌘/Ctrl+/`}>
              <RiMoreLine />
              {label('block')}
            </Button>
          )
        }
      />
      <DropdownMenuContent
        className="block-menu block-actions ankole-editor-overlay"
        aria-label={label(inserting ? 'insert_block' : 'block_actions')}
        finalFocus={finalFocus}>
        <BlockMenuBody close={() => change(false)} insertMenu={insertMenu} />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** The block menu of ⌘/, anchored at the top of its block. */
export function KeyboardBlockMenu({ insertMenu }: { insertMenu?: InsertExtras }) {
  const label = useEditorLabel()
  const { editor, open, setOpen, change, finalFocus } = useMenu('keyboard')
  const request = useEditorState(state => {
    const menu = state.field(menuField, false)
    return menu?.kind === 'keyboard' ? menu : null
  })
  const inserting = useEditorState(state => state.field(menuField, false)?.inserting)
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
        aria-label={label(inserting ? 'insert_block' : 'block_actions')}
        finalFocus={finalFocus}>
        <BlockMenuBody close={() => change(false)} insertMenu={insertMenu} />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/**
 * Handle buttons open their menu on click, so that a press that moves starts a drag of the block
 * instead.
 */
function handleTriggerEvents(toggle: (event: { altKey?: boolean }) => void) {
  return {
    onMouseDown: (event: { preventBaseUIHandler(): void }) => event.preventBaseUIHandler(),
    onClick: (event: { altKey?: boolean; preventBaseUIHandler(): void }) => {
      event.preventBaseUIHandler()
      toggle(event)
    }
  }
}

function BlockActions() {
  const label = useEditorLabel()
  const editor = useEditor()
  const state = useEditorState()
  const block = menuTarget(state, state.field(menuField, false)?.pos ?? null)
  const selected = block ? (actionUnits(state, block.before) ?? []) : []
  const act = (action: (pos: number) => void) => () => {
    const pos = targetOf(editor)
    if (menuTarget(editor.state, pos)) action(pos!)
  }
  const turnInto = (type: BlockType) =>
    act(pos => {
      turnBlockInto(editor, pos, type)
    })
  const remove = async () => {
    const pos = targetOf(editor)
    const target = menuTarget(editor.state, pos)
    if (!target || editor.state.readOnly) return
    const state = editor.state
    const change = removal(state, pos!)
    if (!change) return
    const refs = [
      ...new Set(
        (actionUnits(state, pos!) ?? []).flatMap(unit => {
          const ref = unit.node.type === Embed.type ? embedAttributes(unit.node).ref : undefined
          return ref ? [ref] : []
        })
      )
    ]
    const host = editorHost(editor)
    if (refs.length && host?.deleteEmbeds) {
      if (!(await host.deleteEmbeds(refs))) return
      // Keep the captured selection, but do not apply old positions to an edited document.
      if (editor.state.doc !== state.doc || editor.state.readOnly) return
    }
    dispatchStep(editor, change)
  }
  return (
    <>
      <DropdownMenuLabel>{label(block ? 'current_block' : 'focus_document')}</DropdownMenuLabel>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger disabled={!selected.length || selected.some(unit => !canTurnInto(state, unit.before))}>
          <RiText aria-hidden />
          {label('turn_into')}
        </DropdownMenuSubTrigger>
        <DropdownMenuSubContent className="block-menu ankole-editor-overlay" aria-label={label('turn_into_type')}>
          <BlockTypeItems
            options={blockOptions.filter(option => option.turnInto)}
            current={selected.length === 1 ? blockTypeAt(state, selected[0]!.before) : null}
            onChoose={type => turnInto(type)()}
          />
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuItem
        disabled={!block}
        closeOnClick={false}
        onClick={event => {
          const menu = editor.state.field(menuField, false)
          if (!menu || menu.pos === null || !insertBesideBlock(editor, menu.pos, 'paragraph', event.altKey)) return
          editor.dispatch({ effects: setMenu.of({ ...menu, pos: currentBlock(editor.state), inserting: true }) })
        }}>
        <RiAddLine aria-hidden />
        {label('insert_below')}
      </DropdownMenuItem>
      <DropdownMenuItem disabled={!block} onClick={act(pos => duplicateBlocks(editor, pos))}>
        <RiFileCopyLine aria-hidden />
        {label('duplicate')}
      </DropdownMenuItem>
      <DropdownMenuItem
        disabled={!selected.length || !adjacentUnit(selected[0]!, -1)}
        onClick={act(pos => moveBlocks(editor, -1, pos))}>
        <RiArrowUpLine aria-hidden />
        {label('move_up')}
      </DropdownMenuItem>
      <DropdownMenuItem
        disabled={!selected.length || !adjacentUnit(selected.at(-1)!, 1)}
        onClick={act(pos => moveBlocks(editor, 1, pos))}>
        <RiArrowDownLine aria-hidden />
        {label('move_down')}
      </DropdownMenuItem>
      <DropdownMenuSeparator />
      <DropdownMenuItem disabled={!block} variant="destructive" onClick={() => void remove()}>
        <RiDeleteBinLine aria-hidden />
        {label('delete_block')}
      </DropdownMenuItem>
    </>
  )
}

const handleMenuOpen = (state: GardState) => !!state.field(menuField, false)?.kind.startsWith('handle')

/** Handles beside the hovered block: insert beside it, open its menu, or drag to reorder. */
export function BlockHandles({
  anchor,
  insertMenu
}: {
  anchor: HTMLElement
  insertMenu?: (prepareInsertion: () => void) => ReactNode
}) {
  const label = useEditorLabel()
  const editor = useEditor()
  const [hover, setHover] = useState<{ pos: number; top: number; left: number } | null>(null)
  const menuOpen = useEditorState(handleMenuOpen)
  const handle = useRef<HTMLDivElement>(null)
  const line = useRef<HTMLDivElement>(null)
  const dragged = useRef<{ positions: number[]; doc: GardState['doc'] } | null>(null)
  const hoveredPos = useRef<number | null>(null)
  const pointer = useRef<MouseEvent | null>(null)
  const refreshHover = useRef<() => void>(() => {})
  hoveredPos.current = hover?.pos ?? null
  // The handle stays on its block while one of its menus is open or the block is dragged.
  const keep = () => handleMenuOpen(editor.state) || !!dragged.current

  useEffect(() => {
    const scroller = anchor.parentElement ?? anchor
    const move = (event: MouseEvent, refresh = false) => {
      pointer.current = event
      if (keep()) return
      // Moving onto the handle keeps the current block.
      if (!refresh && (event.target as Element).closest?.('.drag-handle')) return
      const hit = blockAt(editor, event.clientX, event.clientY, false)
      if (!hit) return setHover(null)
      const handleHeight = handle.current?.offsetHeight ?? 0
      const lineHeight = parseFloat(getComputedStyle(hit.dom).lineHeight)
      const lineBox = Number.isNaN(lineHeight) ? hit.rect.height : Math.min(lineHeight, hit.rect.height)
      const box = anchor.getBoundingClientRect()
      const top = hit.rect.top - box.top + (lineBox - handleHeight) / 2
      const parent = editor.state.doc.resolve(hit.pos).parent
      const list = isList(parent.node) ? editor.nodeDOM(parent.before) : null
      // List markers and task checkboxes occupy the space before the paragraph's text.
      const left =
        (list instanceof HTMLElement ? list.getBoundingClientRect().left : hit.rect.left) -
        box.left -
        58 -
        (hit.dom.classList.contains('foldable-heading') ? 24 : 0)
      setHover(previous =>
        previous?.pos === hit.pos && previous.top === top && previous.left === left
          ? previous
          : { pos: hit.pos, top, left }
      )
    }
    const leave = (event: PointerEvent) => {
      if (event.pointerType === 'mouse') {
        pointer.current = null
        if (!keep()) setHover(null)
      }
    }
    const pointerUp = (event: PointerEvent) => {
      if (event.pointerType !== 'mouse') move(event)
    }
    scroller.addEventListener('mousemove', move)
    scroller.addEventListener('pointerup', pointerUp)
    scroller.addEventListener('pointerleave', leave)
    refreshHover.current = () => {
      if (pointer.current) move(pointer.current, true)
      else if (!keep()) setHover(null)
    }
    return () => {
      scroller.removeEventListener('mousemove', move)
      scroller.removeEventListener('pointerup', pointerUp)
      scroller.removeEventListener('pointerleave', leave)
    }
  }, [editor, anchor])

  // Recompute against the rendered document: local edits and remote echoes can arrive while the
  // pointer is stationary in the gutter.
  const doc = useEditorState(state => state.doc)
  useEffect(() => {
    refreshHover.current()
  }, [doc])

  useEffect(() => {
    let dragPointer: DragEvent | null = null
    let scrolling: ReturnType<typeof setInterval> | null = null
    const stopScrolling = () => {
      if (scrolling !== null) clearInterval(scrolling)
      scrolling = null
      dragPointer = null
    }
    const target = (event: DragEvent) => {
      const drag = dragged.current
      if (!drag) return null
      event.preventDefault()
      event.stopPropagation()
      if (editor.state.doc !== drag.doc) return null
      const hit = blockAt(editor, event.clientX, event.clientY, true)
      if (!hit) return null
      return blockDrop(
        editor.state,
        drag.positions,
        hit,
        { x: event.clientX, y: event.clientY, viewportWidth: window.innerWidth },
        pos => {
          const dom = editor.nodeDOM(pos)
          return dom instanceof HTMLElement ? dom.getBoundingClientRect() : null
        }
      )
    }
    const draw = (event: DragEvent) => {
      const found = target(event)
      const element = line.current
      if (event.dataTransfer && dragged.current) event.dataTransfer.dropEffect = 'move'
      if (!element) return
      if (!found) {
        element.style.opacity = '0'
        return
      }
      const box = anchor.getBoundingClientRect()
      const { marker } = found
      element.style.width = `${marker.width}px`
      element.style.height = `${marker.height}px`
      element.style.left = `${marker.left - box.left}px`
      element.style.transform = `translateY(${marker.top - box.top - 1}px)`
      element.style.opacity = '1'
    }
    const over = (event: DragEvent) => {
      draw(event)
      if (!dragged.current) return
      dragPointer = event
      if (scrolling !== null) return
      const scroller = scrollableParents(editor.contentDOM).y
      scrolling = setInterval(() => {
        if (!dragPointer || !dragged.current || editor.state.doc !== dragged.current.doc) return stopScrolling()
        const bounds = scroller?.getBoundingClientRect()
        const top = Math.max(0, bounds?.top ?? 0)
        const bottom = Math.min(window.innerHeight, bounds?.bottom ?? window.innerHeight)
        const y = dragPointer.clientY
        const speed = y < top + 32 ? -12 : y > bottom - 32 ? 12 : 0
        if (!speed) return
        if (scroller) scroller.scrollTop += speed
        else window.scrollBy(0, speed)
        draw(dragPointer)
      }, 50)
    }
    const drop = (event: DragEvent) => {
      const found = target(event)
      if (found) dispatchStep(editor, found.edit)
      stopScrolling()
    }
    const leave = (event: DragEvent) => {
      if (!anchor.contains(event.relatedTarget as globalThis.Node | null)) stopScrolling()
    }
    anchor.addEventListener('dragover', over, true)
    anchor.addEventListener('drop', drop, true)
    anchor.addEventListener('dragleave', leave)
    anchor.ownerDocument.addEventListener('dragend', stopScrolling)
    return () => {
      stopScrolling()
      anchor.removeEventListener('dragover', over, true)
      anchor.removeEventListener('drop', drop, true)
      anchor.removeEventListener('dragleave', leave)
      anchor.ownerDocument.removeEventListener('dragend', stopScrolling)
    }
  }, [editor, anchor])

  const target = hover ? menuTarget(editor.state, hover.pos) : null
  const empty = target?.node.type === T.Paragraph.type && target.node.isPlot && !target.node.content.length
  const type = target ? blockTypeAt(editor.state, target.before) : null
  const shown = hover !== null
  return (
    <>
      <div
        ref={handle}
        className="drag-handle"
        data-menu-open={menuOpen}
        style={shown ? { top: hover.top, left: hover.left } : { visibility: 'hidden' }}>
        {empty && (
          <InsertMenu
            hovered={() => hoveredPos.current}
            trigger={
              <Button
                variant="ghost"
                size="icon-xs"
                tabIndex={-1}
                aria-label={label('insert_block')}
                title={label('insert_block')}>
                <RiAddLine />
              </Button>
            }>
            {insertMenu}
          </InsertMenu>
        )}
        <BlockMenu
          hovered={() => hoveredPos.current}
          insertMenu={insertMenu}
          typeTrigger={
            !empty ? (
              <Button
                variant="ghost"
                size="icon-xs"
                tabIndex={-1}
                aria-label={label('current_block_menu')}
                title={
                  type
                    ? blockOptions.find(option => option.type === type)?.title(editor.state)
                    : label('current_block_menu')
                }>
                {type ? <BlockTypeIcon type={type} /> : <RiMoreLine />}
              </Button>
            ) : undefined
          }
          trigger={
            <Button
              variant="ghost"
              size="icon-xs"
              tabIndex={-1}
              aria-label={label('block_menu')}
              title={label('drag_hint')}
              draggable
              onDragStart={event => {
                const pos = hoveredPos.current
                const block = pos === null ? null : editor.nodeDOM(pos)
                if (pos === null || !block) return event.preventDefault()
                const selection = editor.state.selection
                const positions =
                  selection instanceof BlockSelection && selection.blocks.some(block => block.before === pos)
                    ? selection.blocks.map(block => block.before)
                    : [pos]
                dragged.current = { positions, doc: editor.state.doc }
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
              <RiDraggable />
            </Button>
          }
        />
      </div>
      <div className="drag-line" ref={line} />
    </>
  )
}

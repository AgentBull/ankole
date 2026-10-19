/*
 * Block operations for menus and shortcuts (SPEC §7.5 block type table and block menu, §7.6).
 * Positions name a block by the document position right before it.
 *
 * The functions that take an editor dispatch one undo step. The functions that take a state return
 * the transaction spec of the same operation, for composition and for tests.
 */
import { Leaf, Plot, type ChangeSet, type Node, type Pos, type Schema, type Token } from '../core/doc'
import type { Wordgard } from '../core/editor'
import { GardSelection, type GardState, type Transaction } from '../core/state'
import * as T from '../core/types'
import { blocks } from '../blocks'
import { compareNames } from '../document/tree'
import { Attrs, markSet, markValue, type Pairs } from './attributes'
import { blockInsertion, compose, dispatchStep, isContainer, isList, isListItem, withLeadingEdit } from './block-insert'
import * as S from './schema'

/** Block types of the core vocabulary. Block definitions add their own names. */
export const coreBlockTypes = [
  'paragraph',
  'h1',
  'h2',
  'h3',
  'bullet',
  'number',
  'check',
  'quote',
  'code',
  'divider'
] as const
export type CoreBlockType = (typeof coreBlockTypes)[number]
export type BlockType = CoreBlockType | (typeof blocks)[number]['name']

export type BlockOption = {
  type: BlockType
  title: string
  detail: string
  keywords?: string
  glyph: string
  turnInto: boolean
}

/** Menu entries in SPEC §7.6 order: the core block types, then the installed blocks. */
export const blockOptions: readonly BlockOption[] = [
  { type: 'paragraph', title: '正文', detail: '普通段落', keywords: 'text paragraph', glyph: 'T', turnInto: true },
  { type: 'h1', title: '一级标题', detail: '大标题', keywords: 'heading h1', glyph: 'H₁', turnInto: true },
  { type: 'h2', title: '二级标题', detail: '中标题', keywords: 'heading h2', glyph: 'H₂', turnInto: true },
  { type: 'h3', title: '三级标题', detail: '小标题', keywords: 'heading h3', glyph: 'H₃', turnInto: true },
  { type: 'bullet', title: '项目列表', detail: '组织要点', keywords: 'bullet list', glyph: '≡', turnInto: true },
  { type: 'number', title: '编号列表', detail: '有序步骤', keywords: 'numbered list', glyph: '1.', turnInto: true },
  {
    type: 'check',
    title: '待办列表',
    detail: '可以勾选的事项',
    keywords: 'todo checklist',
    glyph: '☑',
    turnInto: true
  },
  { type: 'quote', title: '引用', detail: '突出一段话', keywords: 'quote', glyph: '❞', turnInto: true },
  { type: 'code', title: '代码块', detail: '保留空格和换行', keywords: 'code', glyph: '<>', turnInto: true },
  { type: 'divider', title: '分割线', detail: '分隔内容', keywords: 'divider', glyph: '—', turnInto: false },
  ...blocks.map(block => ({
    type: block.name,
    title: block.insert.title,
    detail: block.insert.detail,
    keywords: block.insert.keywords,
    glyph: block.insert.glyph,
    turnInto: block.insert.turnInto
  }))
]

/** What the selected blocks become. A code target can give the language and `meta` of a fence. */
export type BlockTarget = { kind: 'text'; tag: Plot.Tag } | { kind: 'code'; lang?: string; meta?: string } | ListTarget
export type ListTarget = { kind: 'list'; list: 'bullet' | 'number' | 'check'; start?: number; done?: boolean }

// ---------------------------------------------------------------------------
// Editor operations

/**
 * Apply a block type at the selection as one undo step (SPEC §7.5 block type table). `replace` is a
 * range to delete first in the same step, such as the query of the slash menu. Returns whether the
 * block type applied.
 */
export function applyBlockType(editor: Wordgard, type: BlockType, replace?: { from: number; to: number }): boolean {
  if (editor.state.readOnly) return false
  const deletion = replace && replace.from < replace.to ? { changes: { from: replace.from, to: replace.to } } : null
  const definition = blocks.find(block => block.name === type)
  if (definition) {
    if (deletion) withLeadingEdit(editor, deletion, () => definition.insert.insert(editor))
    else definition.insert.insert(editor)
    return true
  }
  const core = type as CoreBlockType
  return step(
    editor,
    deletion ? compose(editor.state, deletion, state => blockChange(state, core)) : blockChange(editor.state, core)
  )
}

/** The top-level block that holds the selection head, as the position before it. */
export function currentBlock(state: GardState): number | null {
  const { head } = state.selection
  let pos = 0
  for (const node of state.doc.content) {
    if (head <= pos + node.length) return pos
    pos += node.length
  }
  return null
}

/** Whether the block menu can turn the top-level block at `pos` into another type. */
export function canTurnInto(state: GardState, pos: number): boolean {
  const node = state.doc.resolveNode(pos)?.node
  return !!node && (node.type === T.Paragraph.type || node.type === T.Heading || node.type === T.CodeBlock.type)
}

/**
 * Duplicate the top-level block at `pos`, or the selected blocks (see `selectedUnits`). The copies
 * follow the originals, and the caret moves into the first copy.
 */
export function duplicateBlocks(editor: Wordgard, pos?: number): boolean {
  return step(editor, duplication(editor.state, pos))
}

/** Swap the top-level block at `pos`, or the selected blocks, with the sibling before or after them. */
export function moveBlocks(editor: Wordgard, direction: -1 | 1, pos?: number): boolean {
  return step(editor, movement(editor.state, direction, pos))
}

/**
 * Delete the top-level block at `pos`. The caret moves to the next block, or to the previous one.
 * An empty page gets an empty paragraph.
 */
export function deleteBlock(editor: Wordgard, pos: number): boolean {
  return step(editor, removal(editor.state, pos))
}

/** Insert an empty paragraph after the top-level block at `pos` and apply `type` to it, as one undo step. */
export function insertAfterBlock(editor: Wordgard, pos: number, type: BlockType): boolean {
  const { state } = editor
  const block = topLevel(state, pos)?.[0]
  if (!block || state.readOnly) return false
  const paragraph = {
    changes: { from: block.after, insert: [T.Paragraph.create([])] },
    selection: GardSelection.cursor(block.after + 1)
  }
  const definition = blocks.find(definition => definition.name === type)
  if (definition) withLeadingEdit(editor, paragraph, () => definition.insert.insert(editor))
  else {
    step(
      editor,
      compose(state, paragraph, next => blockChange(next, type as CoreBlockType))
    )
  }
  editor.focus()
  return true
}

/** Dispatch a block edit as one undo step. Returns false when there is no edit. */
function step(editor: Wordgard, spec: Transaction.Spec | null): boolean {
  if (!spec || editor.state.readOnly) return false
  dispatchStep(editor, spec)
  return true
}

// ---------------------------------------------------------------------------
// Block types

/** The change that `applyBlockType` makes for a core block type, or null when nothing changes. */
export function blockChange(state: GardState, type: CoreBlockType): Transaction.Spec | null {
  switch (type) {
    case 'paragraph':
      return turnInto(state, { kind: 'text', tag: T.Paragraph })
    case 'h1':
    case 'h2':
    case 'h3':
      return turnInto(state, { kind: 'text', tag: T.Heading.of(Number(type[1])) })
    case 'bullet':
    case 'number':
    case 'check':
      return turnInto(state, { kind: 'list', list: type })
    case 'code':
      return turnInto(state, { kind: 'code' })
    case 'quote':
      return { ...blockInsertion(state, S.Blockquote.create([])), userEvent: 'block.insert' }
    case 'divider':
      return { ...blockInsertion(state, T.HorizontalRule), userEvent: 'block.insert' }
  }
}

/**
 * Turn the selected blocks into `target` (SPEC §7.5). Paragraphs, headings and code blocks change
 * their type and keep their alignment, indent, style and other attributes where the new type has
 * them. For a list item:
 *
 *  - a list target changes the type of its list;
 *  - another target moves the item out of the list and changes the type of its text. The blocks
 *    after the text in the item follow it.
 */
export function turnInto(state: GardState, target: BlockTarget): Transaction.Spec | null {
  if (state.readOnly) return null
  const selected = selectedBlocks(state)
  const { changes, end } =
    target.kind === 'list' ? listChanges(state, selected, target) : typeChanges(state, selected, target)
  if (!changes.length) return null
  return {
    changes: sorted(changes),
    // As before, the caret goes to the end of a new code block.
    selection:
      target.kind === 'code' && end !== null
        ? (cx, changeSet) => GardSelection.near(cx, changeSet.mapPos(end, 1), -1)
        : undefined,
    userEvent: 'block.type'
  }
}

/**
 * The blocks that hold the selection: textblocks, and empty list items, which have a caret
 * position of their own.
 */
function selectedBlocks(state: GardState): Pos.Plot[] {
  const result: Pos.Plot[] = []
  let last = -1
  for (const { from, to } of state.selection.ranges) {
    state.doc.iterate(from, to, (node, pos, parent) => {
      if (pos <= last || !node.isPlot) return
      if (node.isTextblock || (!node.content.length && !!parent && isList(parent))) {
        result.push(state.doc.resolvePlot(pos)!)
        last = pos
      }
    })
  }
  return result
}

/** The list item whose own text `block` is: an empty item, or an item that starts with the textblock. */
function itemOf(block: Pos.Plot): Pos.Plot | null {
  if (isListItem(block)) return block
  return block.index === 0 && block.parent && isListItem(block.parent) ? block.parent : null
}

/** The direct children of a plot, with their positions. */
function children(doc: Plot.Doc, plot: Pos.Plot): Pos.Node[] {
  const result: Pos.Node[] = []
  let pos = plot.start
  for (const child of plot.node.content) {
    result.push(doc.resolveNode(pos)!)
    pos += child.length
  }
  return result
}

/** Changes in position order. A mark change follows a replacement at the same position. */
function sorted(changes: ChangeSet.Change[]): ChangeSet.Change[] {
  const marks = (change: ChangeSet.Change) => (change.add || change.remove ? 1 : 0)
  return [...changes].sort((a, b) => a.from - b.from || marks(a) - marks(b))
}

type Changes = { changes: ChangeSet.Change[]; end: number | null }

/** Group items by their list, keeping document order. */
function byList(items: Pos.Plot[]): { list: Pos.Plot; items: Pos.Plot[] }[] {
  const groups = new Map<number, { list: Pos.Plot; items: Pos.Plot[] }>()
  for (const item of items) {
    const list = item.parent!
    const group = groups.get(list.before) ?? { list, items: [] }
    if (!group.items.some(other => other.before === item.before)) group.items.push(item)
    groups.set(list.before, group)
  }
  return [...groups.values()]
}

// ---------------------------------------------------------------------------
// Paragraphs, headings and code blocks

function typeChanges(state: GardState, selected: Pos.Plot[], target: Exclude<BlockTarget, ListTarget>): Changes {
  const changes: ChangeSet.Change[] = []
  const items: Pos.Plot[] = []
  let end: number | null = null
  for (const block of selected) {
    const item = itemOf(block)
    if (item) items.push(item)
    else if (block.node.isTextblock && retype(state, block, target, changes)) end = block.end
  }
  for (const { list, items: moved } of byList(items)) {
    const last = moveOut(state, list, moved, target, changes)
    if (end === null || last > end) end = last
  }
  return { changes, end }
}

/** Change the type of a textblock in place. Returns whether it changed. */
function retype(state: GardState, block: Pos.Plot, target: Exclude<BlockTarget, ListTarget>, out: ChangeSet.Change[]) {
  const { node } = block
  if (target.kind === 'text') {
    if (node.type === target.tag.type && node.tag.param === target.tag.param) return false
    out.push({ from: block.before, to: block.start, insert: [state.schema.withMarksFrom(node.tag, target.tag)] })
    return true
  }
  if (node.type === T.CodeBlock.type) return false
  out.push({ from: block.before, to: block.start, insert: [codeTag(state.schema, node.tag, target)] })
  if (node.content.length) out.push({ from: block.start, to: block.end, insert: codeContent(node) })
  return true
}

/**
 * Move the selected items out of their list and change the type of their text. The list splits
 * around each run of selected items. Returns the end of the last moved text.
 */
function moveOut(
  state: GardState,
  list: Pos.Plot,
  selected: Pos.Plot[],
  target: Exclude<BlockTarget, ListTarget>,
  out: ChangeSet.Change[]
): number {
  const items = children(state.doc, list) as Pos.Plot[]
  const chosen = new Set(selected.map(item => item.before))
  let end = list.start
  items.forEach((item, index) => {
    if (!chosen.has(item.before)) return
    const first = !chosen.has(items[index - 1]?.before ?? -1)
    const last = !chosen.has(items[index + 1]?.before ?? -1)
    const text =
      item.node.firstChild?.isPlot && item.node.firstChild.isTextblock ? state.doc.resolvePlot(item.start)! : null
    const tag = withAttrs(blockTag(state.schema, text?.node.tag ?? null, target), Attrs.isInSet(item.node.marks)?.value)
    const lead: Token[] = first && index > 0 ? [Plot.End] : []
    out.push({
      from: first && index === 0 ? list.before : item.before,
      to: text ? text.start : item.start,
      insert: [...lead, tag]
    })
    if (text && target.kind === 'code' && text.node.type !== T.CodeBlock.type && text.node.content.length) {
      out.push({ from: text.start, to: text.end, insert: codeContent(text.node) })
    }
    const trail: Token[] = text ? [] : [Plot.End]
    if (last && index < items.length - 1) trail.push(reopenList(list.node.tag))
    out.push({ from: item.end, to: last && index === items.length - 1 ? list.after : item.after, insert: trail })
    end = text ? text.end : item.end
  })
  return end
}

/** The tag of a block that takes the text of a list item, or that replaces an empty item. */
function blockTag(schema: Schema, from: Plot.Tag | null, target: Exclude<BlockTarget, ListTarget>): Plot.Tag {
  if (target.kind === 'text') return from ? schema.withMarksFrom(from, target.tag) : target.tag
  if (from?.type === T.CodeBlock.type) return from
  return codeTag(schema, from ?? T.Paragraph, target)
}

/** A list tag for the items after a split. A numbered list starts at 1 again. */
function reopenList(tag: Plot.Tag): Plot.Tag {
  const split = tag.split(false)
  return split.type === T.OrderedList ? T.OrderedList.of(1, split.marks) : split
}

/** A code block tag. A code block keeps only the attributes outside the vocabulary of `from`. */
function codeTag(schema: Schema, from: Plot.Tag, target: { lang?: string; meta?: string }): Plot.Tag {
  const tag = schema.withMarksFrom(from, T.CodeBlock)
  return tag.withMarks(
    markSet([
      ...tag.marks,
      target.lang !== undefined && T.CodeBlockLanguage.of(target.lang),
      target.meta !== undefined && S.CodeMeta.of(target.meta)
    ])
  )
}

/** The text and line breaks of a textblock as code block content. */
function codeContent(node: Plot): Node[] {
  const text = node.textContent({
    leafText: leaf =>
      leaf.type === T.LineBreak.type ? '\n' : leaf.type === S.InlineElement ? leaf.type.spec.toText!(leaf) : ''
  })
  const result: Node[] = []
  text.split('\n').forEach((line, index) => {
    if (index) result.push(T.LineBreak)
    if (line) result.push(Leaf.text(line))
  })
  return result
}

/** Add attributes outside the vocabulary to a tag. Attributes that the tag has win. */
function withAttrs(tag: Plot.Tag, extra: Pairs | undefined): Plot.Tag {
  if (!extra?.length) return tag
  const own = Attrs.isInSet(tag.marks)?.value ?? []
  const pairs = [...new Map([...extra, ...own])].sort(([a], [b]) => compareNames(a, b))
  return tag.withMarks(Attrs.of(pairs).addToSet(tag.marks))
}

// ---------------------------------------------------------------------------
// Lists

function listChanges(state: GardState, selected: Pos.Plot[], target: ListTarget): Changes {
  const changes: ChangeSet.Change[] = []
  const items: Pos.Plot[] = []
  const wrapped: Pos.Plot[] = []
  for (const block of selected) {
    const item = isListItem(block) ? block : block.parent && isListItem(block.parent) ? block.parent : null
    if (item) items.push(item)
    else if (block.parent && isContainer(block.parent)) wrapped.push(block)
  }
  for (const { list, items: chosen } of byList(items)) retypeList(state, list, chosen, target, changes)
  for (const run of siblingRuns(wrapped)) wrapInList(state, run, target, changes)
  return { changes, end: null }
}

/** Runs of blocks that follow each other directly. */
function siblingRuns(blocks: Pos.Plot[]): Pos.Plot[][] {
  const runs: Pos.Plot[][] = []
  for (const block of blocks) {
    const run = runs.at(-1)
    if (run && run.at(-1)!.after === block.before) run.push(block)
    else runs.push([block])
  }
  return runs
}

const hasTask = (node: Node) => !!S.Task.isInSet(node.marks)

/**
 * Change the type of a list. A bullet list holds runs of to-do items and of plain items, and each
 * run counts as a list of its own (SPEC §7.2), so only the runs with selected items change.
 */
function retypeList(
  state: GardState,
  list: Pos.Plot,
  selected: Pos.Plot[],
  target: ListTarget,
  out: ChangeSet.Change[]
) {
  const items = children(state.doc, list) as Pos.Plot[]
  const setTask = (item: Pos.Plot, on: boolean) => {
    const task = S.Task.isInSet(item.node.marks)
    if (on && !task) out.push({ from: item.before, add: S.Task.of('todo') })
    else if (!on && task) out.push({ from: item.before, remove: task })
  }
  if (list.node.type === T.OrderedList) {
    if (target.list === 'number') return
    out.push({ from: list.before, to: list.start, insert: [state.schema.withMarksFrom(list.node.tag, T.BulletList)] })
    for (const item of items) setTask(item, target.list === 'check')
    return
  }
  const chosen = new Set(selected.map(item => item.before))
  const runs: [number, number][] = []
  for (let first = 0; first < items.length;) {
    let last = first
    while (last + 1 < items.length && hasTask(items[last + 1]!.node) === hasTask(items[first]!.node)) last++
    if (items.slice(first, last + 1).some(item => chosen.has(item.before))) {
      // Adjacent runs that both change into a numbered list become one list.
      const previous = runs.at(-1)
      if (target.list === 'number' && previous && previous[1] === first - 1) previous[1] = last
      else runs.push([first, last])
    }
    first = last + 1
  }
  for (const [first, last] of runs) {
    const run = items.slice(first, last + 1)
    if (target.list !== 'number') {
      for (const item of run) setTask(item, target.list === 'check')
      continue
    }
    const whole = first === 0 && last === items.length - 1
    const ordered = whole ? state.schema.withMarksFrom(list.node.tag, T.OrderedList.of(1)) : T.OrderedList.of(1)
    if (first === 0) out.push({ from: list.before, to: list.start, insert: [ordered] })
    else out.push({ from: run[0]!.before, insert: [Plot.End, ordered] })
    if (last < items.length - 1) {
      out.push({
        from: run.at(-1)!.after,
        insert: [Plot.End, first === 0 ? list.node.tag : list.node.tag.split(false)]
      })
    }
    for (const item of run) setTask(item, false)
  }
}

const indentOf = (node: Node) => markValue(node, S.Indent) ?? 0

/** The paragraph that holds the text of a block in a list item. The indent becomes nesting. */
function itemParagraph(schema: Schema, tag: Plot.Tag): Plot.Tag {
  const paragraph = schema.withMarksFrom(tag, T.Paragraph)
  return paragraph.withMarks(S.Indent.removeFromSet(paragraph.marks))
}

/** The lists at the end of `list`: the list, the list in its last item, and so on, with their last items. */
function lastItems(doc: Plot.Doc, list: Pos.Plot) {
  const lists: Pos.Plot[] = []
  const items: Pos.Plot[] = []
  for (let current: Pos.Plot | null = list; current;) {
    lists.push(current)
    const item: Pos.Plot | null = current.node.lastChild
      ? doc.resolvePlot(current.end - current.node.lastChild.length)
      : null
    if (!item) break
    items.push(item)
    const child: Node | null = item.node.lastChild
    current = child && isList(child) ? doc.resolvePlot(item.end - child.length) : null
  }
  return { lists, items }
}

const ends = (count: number): Token[] => Array.from({ length: count }, () => Plot.End)

/**
 * Make a run of sibling blocks into list items. A block becomes a paragraph in its item, with its
 * alignment, style and other attributes; a block without content and attributes becomes an empty
 * item. The indent of a block becomes the nesting level of its item, at most one level deeper than
 * the item before it. The first item of a new list is not nested. A list of the same kind right
 * before the run takes the items, so they can nest under its last items.
 */
function wrapInList(state: GardState, run: Pos.Plot[], target: ListTarget, out: ChangeSet.Change[]) {
  const { doc, schema } = state
  const ordered = target.list === 'number'
  const outer = ordered ? T.OrderedList.of(target.start ?? 1) : T.BulletList
  const nested = ordered ? T.OrderedList.of(1) : T.BulletList
  const item = target.list === 'check' ? S.ListItem.withMarks([S.Task.of(target.done ? 'done' : 'todo')]) : S.ListItem
  const first = run[0]!
  const before = first.previousSibling
  let level = 0
  let from = first.before
  let prefix: Token[] = [outer]
  if (before && isList(before) && before.type === outer.type) {
    // Reopen the list before the run at the level of the first block.
    const chain = lastItems(doc, doc.resolvePlot(first.before - before.length)!)
    level = Math.min(indentOf(first.node), chain.items.length)
    if (level < chain.lists.length) {
      from = chain.lists[level]!.end
      prefix = []
    } else {
      from = chain.items[level - 1]!.end
      prefix = [nested]
    }
  }
  run.forEach((block, index) => {
    if (index) {
      const previous = level
      level = Math.min(indentOf(block.node), previous + 1)
      prefix = level > previous ? [nested] : ends(1 + 2 * (previous - level))
      from = block.before
    }
    const paragraph = itemParagraph(schema, block.node.tag)
    const empty = !block.node.content.length && !paragraph.marks.length
    out.push({ from, to: block.start, insert: [...prefix, item, ...(empty ? [] : [paragraph])] })
    // Close the paragraph; after the last block, close the item and every open list.
    const close = ends(empty ? 0 : 1).concat(index === run.length - 1 ? ends(2 * level + 2) : [])
    out.push({ from: block.end, to: block.after, insert: close })
  })
}

// ---------------------------------------------------------------------------
// Block menu and block shortcuts

/** The top-level block at `pos`, as a one-element list. */
function topLevel(state: GardState, pos: number): Pos.Node[] | null {
  if (pos < 0 || pos >= state.doc.length) return null
  const node = state.doc.resolveNode(pos)
  return node && node.parent && !node.parent.parent ? [node] : null
}

/**
 * The block that a block shortcut acts on at `pos` (SPEC §7.6): a list item with its children, or
 * a block in a container. `side` picks the block after or before a position between blocks.
 */
function unitAt(doc: Plot.Doc, pos: number, side: -1 | 1): Pos.Node | null {
  const at = doc.resolve(pos)
  let node: Pos.Node | null
  if (at.parent.node.inlineContent || !at.parent.node.content.length) node = at.parent.parent ? at.parent : null
  else {
    const after = at.nodeAfter ? pos : null
    const before = at.nodeBefore ? pos - at.nodeBefore.length : null
    const start = side > 0 ? (after ?? before) : (before ?? after)
    node = start === null ? null : doc.resolveNode(start)
  }
  for (; node?.parent; node = node.parent) if (isList(node.parent.node) || isContainer(node.parent)) return node
  return null
}

/**
 * The blocks that a block shortcut acts on: all blocks from the one at the selection start to the
 * one at its end when they are siblings, or else the block at the anchor.
 */
function selectedUnits(state: GardState): Pos.Node[] | null {
  const { doc, selection } = state
  const forward = selection.anchor <= selection.head
  const anchor = unitAt(doc, selection.anchor, forward ? 1 : -1)
  const head = unitAt(doc, selection.head, forward ? -1 : 1)
  if (!anchor) return null
  const parentOf = (node: Pos.Node) => (node.parent!.parent ? node.parent!.before : -1)
  if (!head || parentOf(head) !== parentOf(anchor)) return [anchor]
  const [first, last] = anchor.before <= head.before ? [anchor, head] : [head, anchor]
  const units: Pos.Node[] = []
  for (let pos = first.before; pos <= last.before; pos += units.at(-1)!.node.length) units.push(doc.resolveNode(pos)!)
  return units
}

/** A selection at the start of the block at `pos`: a node selection for a block leaf such as a divider. */
function selectStart(cx: GardSelection.Context, pos: number, node: Node): GardSelection {
  return node.isLeaf && node.type.isSelectable ? GardSelection.node(pos, node) : GardSelection.near(cx, pos + 1, 1)
}

/** The spec of `duplicateBlocks`. */
export function duplication(state: GardState, pos?: number): Transaction.Spec | null {
  const units = pos === undefined ? selectedUnits(state) : topLevel(state, pos)
  if (!units?.length || state.readOnly) return null
  const at = units.at(-1)!.after
  const first = units[0]!.node
  return {
    changes: { from: at, insert: units.map(unit => unit.node) },
    selection: cx => selectStart(cx, at, first),
    userEvent: 'block.duplicate'
  }
}

/** The spec of `moveBlocks`. Without `pos`, the selection moves with the blocks. */
export function movement(state: GardState, direction: -1 | 1, pos?: number): Transaction.Spec | null {
  const units = pos === undefined ? selectedUnits(state) : topLevel(state, pos)
  if (!units?.length || state.readOnly) return null
  const first = units[0]!
  const last = units.at(-1)!
  const sibling = direction < 0 ? first.previousSibling : last.nextSibling
  if (!sibling) return null
  const changes: ChangeSet.Change[] =
    direction < 0
      ? [
          { from: first.before - sibling.length, to: first.before },
          { from: last.after, insert: [sibling] }
        ]
      : [
          { from: first.before, insert: [sibling] },
          { from: last.after, to: last.after + sibling.length }
        ]
  const moved = first.before + direction * sibling.length
  return {
    changes,
    selection: pos === undefined ? undefined : cx => selectStart(cx, moved, first.node),
    userEvent: 'block.move'
  }
}

/** The spec of `deleteBlock`. */
export function removal(state: GardState, pos: number): Transaction.Spec | null {
  const block = topLevel(state, pos)?.[0]
  if (!block || state.readOnly) return null
  if (state.doc.content.length === 1) {
    return {
      changes: { from: block.before, to: block.after, insert: [T.Paragraph.create([])] },
      selection: GardSelection.cursor(block.before + 1),
      userEvent: 'block.delete'
    }
  }
  const next = block.nextSibling
  const previous = block.previousSibling
  return {
    changes: { from: block.before, to: block.after },
    selection: cx =>
      next ? selectStart(cx, block.before, next) : selectStart(cx, block.before - previous!.length, previous!),
    userEvent: 'block.delete'
  }
}

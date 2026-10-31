/*
 * Block operations for menus and shortcuts (SPEC §7.5 block type table and block menu, §7.6).
 * Positions name a block by the document position right before it.
 *
 * The functions that take an editor dispatch one undo step. The functions that take a state return
 * the transaction spec of the same operation, for composition and for tests.
 */
import { Leaf, Node, Plot, type ChangeSet, type Pos, type Schema, type Token } from '../core/doc'
import type { Wordgard } from '../core/editor'
import { GardSelection, type GardState, type Transaction } from '../core/state'
import * as T from '../core/types'
import { blocks } from '../blocks'
import { fileUploadSpec } from './file-upload'
import { blockOptions, type BlockType, type CoreBlockType } from './block-catalog'
import { Callout } from '../blocks/callout'
import { compareNames } from '../document/tree'
import { Attrs, markSet, markValue, type Pairs } from './attributes'
import {
  blockInsertion,
  compose,
  dispatchStep,
  isContainer,
  isList,
  isListItem,
  splitInsert,
  withLeadingEdit
} from './block-insert'
import * as S from './schema'
import { adjacentUnit, blockContent, blockRemovalRanges, targetAt, unitAt } from './block-target'
import { BlockSelection, selectedUnits } from './block-selection'
import { withoutCommentMarks } from './comments'
import { insertChildren, isBlockGroup } from './nesting'
import { columnInsertion } from './columns'
import { mentionTriggerSpec } from './mention'
import { tableInsertion } from './tables'

/** The semantic type shown by a block's handle and conversion menu. */
export function blockTypeAt(state: GardState, pos: number): BlockType | null {
  const target = targetAt(state.doc, pos)
  if (!target) return null
  if (isList(target.parent!.node)) {
    if (S.Task.isInSet(target.node.marks)) return 'check'
    return target.parent!.node.type === T.OrderedList ? 'number' : 'bullet'
  }
  const node = target.node.isPlot && isBlockGroup(target.node) ? target.node.firstChild : target.node
  if (!node) return null
  if (node.type === T.Paragraph.type) return 'paragraph'
  if (node.isPlot && node.tag.is(T.Heading)) return `h${node.tag.param}`
  if (node.type === T.CodeBlock.type) return 'code'
  if (node.type === T.HorizontalRule.type) return 'divider'
  if (node.type === S.Blockquote.type) return 'quote'
  if (node.type === S.Columns.type && node.isPlot) return `columns${node.content.length}`
  return blocks.find(block => block.type === node.type)?.name ?? null
}

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

/** The block that holds the selection head, as the position before it. */
export function currentBlock(state: GardState): number | null {
  if (state.selection instanceof BlockSelection) return state.selection.last.before
  const unit = unitAt(state.doc, state.selection.head, state.selection.headSide)
  if (unit && (isBlockGroup(unit.node) || isBlockGroup(unit.parent!.node))) return unit.before
  if (unit?.parent && isList(unit.parent.node)) return unit.before
  if (unit?.parent?.node.type === S.Column.type) return unit.before
  let pos = 0
  for (const node of state.doc.content) {
    if (state.selection.head <= pos + node.length) return pos
    pos += node.length
  }
  return null
}

/** Whether the block menu can turn the block at `pos` into another type. */
export function canTurnInto(state: GardState, pos: number): boolean {
  const target = conversionTarget(state, pos)?.node
  const node = target?.isPlot && isBlockGroup(target) ? target.firstChild : target
  return (
    !!node &&
    (node.type === T.Paragraph.type ||
      node.type === T.Heading ||
      node.type === T.CodeBlock.type ||
      node.type === S.Blockquote.type ||
      node.type === Callout.type ||
      node.type.hasRole(Node.Role.List) ||
      isList(state.doc.resolve(pos).parent.node))
  )
}

/** A parent's own content can change type without selecting its children. */
function conversionTarget(state: GardState, pos: number): Pos.Node | null {
  const target = targetAt(state.doc, pos)
  if (target) return target
  const head = pos >= 0 && pos < state.doc.length ? state.doc.resolveNode(pos) : null
  return head?.parent && head.index === 0 && isBlockGroup(head.parent.node) ? head : null
}

/** Turn the block at `pos`, or every block the selection touches, into `type` as one undo step. */
export function turnBlockInto(editor: Wordgard, pos: number | undefined, type: BlockType): boolean {
  const units = actionUnits(editor.state, pos)
  if (!units?.length) return false
  // Work from the end so earlier block positions stay valid through each conversion.
  let spec: Transaction.Spec | null = null
  for (const unit of [...units].reverse()) {
    spec = spec
      ? compose(editor.state, spec, state => turnBlock(state, unit.before, type))
      : turnBlock(editor.state, unit.before, type)
  }
  // A text selection across several blocks stays selected, so the selection toolbar stays open.
  const { selection } = editor.state
  if (spec && units.length > 1 && !selection.empty && selection instanceof GardSelection.Text) {
    const { changes } = editor.state.update(spec)
    const backward = selection.anchor > selection.head
    spec = compose(editor.state, spec, () => ({
      selection: GardSelection.range(
        changes.mapPos(selection.anchor, backward ? 1 : -1),
        changes.mapPos(selection.head, backward ? -1 : 1)
      )
    }))
  }
  return step(editor, spec)
}

/**
 * Duplicate the block at `pos`, or the selected blocks (see `selectedUnits`). The copies
 * follow the originals and become the whole-block selection.
 */
export function duplicateBlocks(editor: Wordgard, pos?: number): boolean {
  return step(editor, duplication(editor.state, pos))
}

/** Swap the block at `pos`, or the selected blocks, with the sibling before or after them. */
export function moveBlocks(editor: Wordgard, direction: -1 | 1, pos?: number): boolean {
  return step(editor, movement(editor.state, direction, pos))
}

/**
 * Delete the block at `pos`. The caret moves to the next block, or to the previous one.
 * An empty page gets an empty paragraph.
 */
export function deleteBlock(editor: Wordgard, pos: number): boolean {
  return step(editor, removal(editor.state, pos))
}

/** Insert an empty paragraph beside the block at `pos` and apply `type` in one undo step. */
export function insertBesideBlock(editor: Wordgard, pos: number, type: BlockType, before = false): boolean {
  const { state } = editor
  const block = specifiedUnits(state, pos)?.[0]
  if (!block || state.readOnly) return false
  if (!before && block.node.isPlot && block.node.type === T.Paragraph.type && !block.node.content.length) {
    editor.dispatch({ selection: GardSelection.cursor(block.before + 1) })
    applyBlockType(editor, type)
    editor.focus()
    return true
  }
  let at = before ? block.before : block.after
  const insert: Token[] = [T.Paragraph.create([])]
  const parent = block.parent!
  if (isList(parent.node)) {
    if (at === parent.start) at = parent.before
    else if (at === parent.end) at = parent.after
    else insert.splice(0, insert.length, Plot.End, ...insert, parent.node.tag)
  }
  const paragraph = {
    changes: { from: at, insert },
    selection: GardSelection.cursor(at + (insert[0] === Plot.End ? 2 : 1))
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

/** Select all inline or selectable positions inside `[from, to]` on a copy of `state`. */
function selectSpan(state: GardState, from: number, to: number): GardState | null {
  const start = GardSelection.near(state, from, 1).from
  const end = GardSelection.near(state, to, -1).to
  if (start < from || start > to || end < from || end > to) return null
  return state.update({ selection: GardSelection.range(start, end) }).state
}

/** The spec of `turnBlockInto` for a block at `pos`. */
export function turnBlock(state: GardState, pos: number, type: BlockType): Transaction.Spec | null {
  const target = conversionTarget(state, pos)
  if (!target?.node.isPlot || !canTurnInto(state, pos) || state.readOnly) return null
  if (!blockOptions.find(option => option.type === type)?.turnInto) return null
  const plot = target as Pos.Plot
  if (isBlockGroup(plot.node)) return turnBlock(state, plot.start, type)
  if (isListItem(plot)) {
    // Select only this item's own text. Its nested children keep their types.
    const text = plot.node.firstChild
    const inside = selectSpan(state, plot.start, text ? plot.start + text.length : plot.end)
    if (!inside) return null
    if (type !== 'quote' && type !== 'callout') {
      return compose(state, { selection: inside.selection }, next => blockChange(next, type as CoreBlockType))
    }
    const unlisted = turnInto(inside, { kind: 'text', tag: T.Paragraph })
    if (!unlisted) return null
    const tr = state.update(unlisted)
    const at = unitAt(tr.state.doc, tr.changes.mapPos(inside.selection.from, 1), 1)
    return at ? compose(state, unlisted, next => turnBlock(next, at.before, type)) : null
  }
  const inside = state.selection.from > plot.before && state.selection.to < plot.after

  if (plot.node.isTextblock) {
    const apply = (next: GardState): Transaction.Spec | null =>
      type === 'callout'
        ? { ...blockInsertion(next, Callout.create([])), userEvent: 'block.insert' }
        : blockChange(next, type as CoreBlockType)
    if (inside) return apply(state)
    const atEnd = GardSelection.atEnd(state, plot)
    const preview = apply(state.update({ selection: atEnd }).state)
    return preview ? compose(state, { selection: atEnd }, apply) : null
  }

  if (plot.node.type.hasRole(Node.Role.List)) {
    if (type === 'quote' || type === 'callout') {
      const container = state.schema.withMarksFrom(plot.node.tag, type === 'quote' ? S.Blockquote : Callout)
      const whole = selectSpan(state, plot.before, plot.after)
      const unlisted = whole ? turnInto(whole, { kind: 'text', tag: T.Paragraph }) : null
      if (!unlisted) return null
      const tailLength = state.doc.length - plot.after
      return compose(state, unlisted, next => {
        const end = next.doc.length - tailLength
        return {
          changes: [
            { from: plot.before, insert: [container] },
            { from: end, insert: [Plot.End] }
          ],
          selection: cx => GardSelection.near(cx, end + 1, -1),
          userEvent: 'block.type'
        }
      })
    }
    const keepPartial = !state.selection.empty && inside
    const base = keepPartial ? state : selectSpan(state, plot.before, plot.after)
    const spec = base ? blockChange(base, type as CoreBlockType) : null
    if (!spec) return null
    return inside
      ? spec
      : {
          ...spec,
          selection: spec.selection ?? ((cx, changes) => GardSelection.near(cx, changes.mapPos(plot.before, 1) + 1, 1))
        }
  }

  const isQuote = (plot.node as Node).type === S.Blockquote.type
  if ((isQuote && type === 'quote') || (!isQuote && type === 'callout')) return null
  if (type === 'quote' || type === 'callout') {
    const container = state.schema.withMarksFrom(plot.node.tag, type === 'quote' ? S.Blockquote : Callout)
    if (!plot.node.content.length) {
      return {
        changes: { from: plot.before, to: plot.after, insert: [container.create([T.Paragraph.create([])])] },
        selection: GardSelection.cursor(plot.before + 2),
        userEvent: 'block.type'
      }
    }
    return {
      changes: { from: plot.before, to: plot.start, insert: [container] },
      selection: inside ? undefined : cx => selectStart(cx, plot.start, plot.node.firstChild!),
      userEvent: 'block.type'
    }
  }

  if (!plot.node.content.length) {
    const unwrap: Transaction.Spec = {
      changes: { from: plot.before, to: plot.after, insert: [T.Paragraph.create([])] },
      selection: GardSelection.cursor(plot.before + 1),
      userEvent: 'block.type'
    }
    return compose(state, unwrap, next => blockChange(next, type as CoreBlockType))
  }

  const tailLength = state.doc.length - plot.after
  const firstChild = plot.node.firstChild!
  const unwrap: Transaction.Spec = {
    changes: [
      { from: plot.before, to: plot.start },
      { from: plot.end, to: plot.after }
    ],
    selection: inside ? undefined : cx => selectStart(cx, plot.before, firstChild),
    userEvent: 'block.type'
  }
  return compose(state, unwrap, next => {
    const selected = selectSpan(next, plot.before, next.doc.length - tailLength)
    return selected ? blockChange(selected, type as CoreBlockType) : null
  })
}

/** The change that `applyBlockType` makes for a core block type, or null when nothing changes. */
export function blockChange(state: GardState, type: CoreBlockType): Transaction.Spec | null {
  switch (type) {
    case 'paragraph':
      return turnInto(state, { kind: 'text', tag: T.Paragraph })
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return turnInto(state, { kind: 'text', tag: T.Heading.of(Number(type[1])) })
    case 'bullet':
    case 'number':
    case 'check':
      return turnInto(state, { kind: 'list', list: type })
    case 'code':
      return turnInto(state, { kind: 'code' })
    case 'quote':
      return { ...blockInsertion(state, S.Blockquote.create([])), userEvent: 'block.insert' }
    case 'table':
      return tableInsertion(state)
    case 'divider':
      return { ...blockInsertion(state, T.HorizontalRule), userEvent: 'block.insert' }
    case 'columns2':
    case 'columns3':
    case 'columns4':
    case 'columns5':
      return columnInsertion(state, Number(type.at(-1)))
    case 'mention':
      return mentionTriggerSpec(state)
    case 'file':
      return fileUploadSpec(state)
  }
}

/**
 * Turn the selected blocks into `target` (SPEC §7.5). Paragraphs, headings and code blocks change
 * their type and keep their alignment, indent, style and other attributes where the new type has
 * them. For a list item:
 *
 *  - a list target changes the selected items, splitting the list around them;
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
    const nested = item.node.content.length > (text ? 1 : 0)
    const lead: Token[] = first && index > 0 ? [Plot.End] : []
    out.push({
      from: first && index === 0 ? list.before : item.before,
      to: text ? text.start : item.start,
      insert: [...lead, ...(nested ? [S.BlockGroup] : []), tag]
    })
    if (text && target.kind === 'code' && text.node.type !== T.CodeBlock.type && text.node.content.length) {
      out.push({ from: text.start, to: text.end, insert: codeContent(text.node) })
    }
    const trail: Token[] = text ? [] : [Plot.End]
    if (nested) trail.push(Plot.End)
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
  const result: Node[] = []
  for (const leaf of node.content) {
    const text = leaf.isText
      ? (leaf.param as string)
      : leaf.type === T.LineBreak.type
        ? '\n'
        : leaf.type === S.InlineElement
          ? leaf.type.spec.toText!(leaf as Leaf)
          : ''
    const marks = leaf.marks.filter(mark => mark.type === S.Comment)
    text.split('\n').forEach((line, index) => {
      if (index) result.push(T.LineBreak.withMarks(marks))
      if (line) result.push(Leaf.text(line, marks))
    })
  }
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

/**
 * Change only the chosen list items. Numbered and bullet lists split around a changed run;
 * checklist markers live on the individual items.
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
  const chosen = new Set(selected.map(item => item.before))
  const runs: [number, number][] = []
  for (let first = 0; first < items.length;) {
    let last = first
    while (last + 1 < items.length && chosen.has(items[last + 1]!.before) === chosen.has(items[first]!.before)) last++
    if (chosen.has(items[first]!.before)) runs.push([first, last])
    first = last + 1
  }
  for (const [first, last] of runs) {
    const run = items.slice(first, last + 1)
    const tag = target.list === 'number' ? T.OrderedList.of(1) : T.BulletList
    if (list.node.type === tag.type) {
      for (const item of run) setTask(item, target.list === 'check')
      continue
    }
    const whole = first === 0 && last === items.length - 1
    const replacement = whole ? state.schema.withMarksFrom(list.node.tag, tag) : tag
    if (first === 0) out.push({ from: list.before, to: list.start, insert: [replacement] })
    else out.push({ from: run[0]!.before, insert: [Plot.End, replacement] })
    if (last < items.length - 1) {
      out.push({
        from: run.at(-1)!.after,
        insert: [Plot.End, reopenList(list.node.tag)]
      })
    }
    for (const item of run) setTask(item, target.list === 'check')
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
  const owner = first.parent!
  if (run.length === 1 && first.index === 0 && isBlockGroup(owner.node)) {
    out.push(
      {
        from: owner.before,
        to: first.start,
        insert: [outer, withAttrs(item, markValue(owner.node, Attrs)), itemParagraph(schema, first.node.tag)]
      },
      { from: owner.end, to: owner.after, insert: [Plot.End, Plot.End] }
    )
    return
  }
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

/** The block at `pos`, as a one-element list. */
function specifiedUnits(state: GardState, pos: number): Pos.Node[] | null {
  const node = targetAt(state.doc, pos)
  return node ? [node] : null
}

/** A menu on a selected block acts on the whole block selection. */
export function actionUnits(state: GardState, pos?: number): Pos.Node[] | null {
  const selected = state.selection
  if (
    selected instanceof BlockSelection &&
    (pos === undefined || selected.blocks.some(block => block.before === pos))
  ) {
    return selected.blocks
  }
  if (pos === undefined) return selectedUnits(state)
  return specifiedUnits(state, pos)
}

/** A selection at the start of the block at `pos`: a node selection for a block leaf such as a divider. */
function selectStart(cx: GardSelection.Context, pos: number, node: Node): GardSelection {
  return node.isLeaf && node.type.isSelectable ? GardSelection.node(pos, node) : GardSelection.near(cx, pos + 1, 1)
}

/** The spec of `duplicateBlocks`. */
export function duplication(state: GardState, pos?: number): Transaction.Spec | null {
  const units = actionUnits(state, pos)
  if (!units?.length || state.readOnly) return null
  const nodes = blockContent(units).map(withoutCommentMarks)
  const insertion = insertBlocks(state, units.at(-1)!.after, nodes)
  const { at } = insertion
  return {
    changes: insertion.changes,
    selection: cx =>
      BlockSelection.between(cx.doc, at, at + nodes.slice(0, -1).reduce((size, node) => size + node.length, 0))!,
    userEvent: 'block.duplicate'
  }
}

/** The spec of `moveBlocks`. Without `pos`, the selection moves with the blocks. */
export function movement(state: GardState, direction: -1 | 1, pos?: number): Transaction.Spec | null {
  const units = actionUnits(state, pos)
  if (!units?.length || state.readOnly) return null
  const first = units[0]!
  const last = units.at(-1)!
  if (
    units.some((unit, index) => index > 0 && unit.before !== units[index - 1]!.after) ||
    first.parent!.start !== last.parent!.start ||
    !(direction < 0 ? first.previousSibling : last.nextSibling)
  ) {
    const next = adjacentUnit(direction < 0 ? first : last, direction)
    return next
      ? relocation(
          state,
          units.map(unit => unit.before),
          direction < 0 ? next.before : next.after
        )
      : null
  }
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
    selection:
      pos === undefined || state.selection instanceof BlockSelection
        ? undefined
        : cx => selectStart(cx, moved, first.node),
    userEvent: 'block.move'
  }
}

/** Insert complete blocks at a boundary, splitting a surrounding list when their types differ. */
function insertBlocks(state: GardState, pos: number, nodes: readonly Node[]) {
  const parent = state.doc.resolve(pos).parent
  return nodes.every(node => state.schema.canContain(parent.node.type, node.type))
    ? { changes: { from: pos, insert: nodes }, at: pos }
    : splitInsert(state.doc, pos, nodes, false)
}

/** Move complete blocks to a boundary, preserving their types and nested children. */
export function relocation(
  state: GardState,
  positions: readonly number[],
  to: number,
  nestUnder?: number
): Transaction.Spec | null {
  if (state.readOnly || !positions.length) return null
  const units = positions.map(pos => targetAt(state.doc, pos))
  if (units.some(unit => !unit)) return null
  const first = units[0]!
  if (nestUnder === undefined && units.some(unit => to >= unit!.before && to <= unit!.after)) return null
  if (nestUnder !== undefined && units.some(unit => nestUnder >= unit!.before && nestUnder < unit!.after)) return null
  if (units.some((unit, index) => index > 0 && unit!.before < units[index - 1]!.after)) return null
  const destination = nestUnder === undefined ? state.doc.resolve(to).parent : state.doc.resolveNode(nestUnder)!
  const source = first.parent!
  let nodes = blockContent(units as Pos.Node[])
  if (
    isList(source.node) &&
    nodes.every(node => node.type === S.ListItem.type) &&
    !source.node.tag.eq(destination.node.tag)
  ) {
    nodes = [source.node.tag.create(nodes)]
  }
  const deletion = state.update({
    changes: { correct: blockRemovalRanges(units as Pos.Node[]).map(range => ({ ...range, fit: true })), local: true }
  })
  const parent = nestUnder === undefined ? null : deletion.state.doc.resolveNode(deletion.changes.mapPos(nestUnder, 1))
  const insertion = parent
    ? insertChildren(parent, nodes)
    : insertBlocks(deletion.state, deletion.changes.mapPos(to, to < first.before ? -1 : 1), nodes)
  const { at } = insertion
  return {
    ...compose(state, { changes: deletion.changes }, () => ({
      changes: insertion.changes,
      selection: cx =>
        BlockSelection.between(cx.doc, at, at + nodes.slice(0, -1).reduce((size, node) => size + node.length, 0))!
    })),
    userEvent: 'block.move'
  }
}

/** The spec of `deleteBlock`. */
export function removal(state: GardState, pos: number): Transaction.Spec | null {
  const units = actionUnits(state, pos)
  const block = units?.[0]
  if (!block || state.readOnly) return null
  const last = units!.at(-1)!
  const ranges = blockRemovalRanges(units!)
  if (ranges.length === 1 && block.parent!.node.isDoc && block.before === 0 && last.after === state.doc.length) {
    return {
      changes: { from: block.before, to: last.after, insert: [T.Paragraph.create([])] },
      selection: GardSelection.cursor(block.before + 1),
      userEvent: 'block.delete'
    }
  }
  const adjacent = adjacentUnit(last, 1) ?? adjacentUnit(block, -1)
  return {
    changes: { correct: ranges.map(range => ({ ...range, fit: true })), local: true },
    selection: (cx, changes) => {
      const at = adjacent && changes.mapPos(adjacent.before, 1, 'after')
      const node = at == null ? null : cx.doc.nodeAt(at)
      return node ? selectStart(cx, at!, node) : GardSelection.near(cx, changes.mapPos(block.before, -1), 1)
    },
    userEvent: 'block.delete'
  }
}

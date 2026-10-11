/*
 * Lists (SPEC §7.5 Lists). A list holds list items. An item holds blocks: its first text block is
 * the item's text, and nested lists are blocks after it. The operations here change the tokens
 * around items and keep their content in place, so the caret maps through them. `block-keys.ts`
 * decides which operation a key runs.
 */
import { Plot, Pos, type ChangeSet, type Node, type Token } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection, Transaction, type GardState } from '../core/state'
import * as T from '../core/types'
import { Attrs } from './attributes'
import * as S from './schema'

/** Lists nest at most this many levels below the top level (SPEC §7.6: at most 49 levels). */
export const maxLevel = 49

export const isItem = (node: Node) => node.type == S.ListItem.type

/** The child of `parent` at `index`. */
export function childAt(doc: Plot.Doc, parent: Pos.Plot, index: number): Pos.Node {
  let pos = parent.start
  for (let i = 0; i < index; i++) pos += parent.node.content[i]!.length
  return doc.resolveNode(pos)!
}

const plotAt = (doc: Plot.Doc, parent: Pos.Plot, index: number) => childAt(doc, parent, index) as Pos.Plot

/** An item without text: it has no blocks, or its first text block is empty. Nested lists do not count. */
export function isEmptyItem(item: Plot): boolean {
  const first = item.firstChild
  return !first || (first.isPlot && first.isTextblock && !first.content.length)
}

/** The number of list levels around `item`. A top-level item is at level 0. */
function levelOf(item: Pos.Plot): number {
  let level = 0
  for (let plot = item.parent!.parent; plot; plot = plot.parent) if (isItem(plot.node)) level++
  return level
}

/** The number of item levels in `node`, counting `node` when it is an item. */
function itemLevels(node: Node): number {
  if (node.isLeaf || node.inlineContent) return 0
  let levels = 0
  for (const child of node.content) levels = Math.max(levels, itemLevels(child))
  return isItem(node) ? levels + 1 : levels
}

/**
 * The tag of an item that Enter adds next to `item`. It has no attributes outside the vocabulary,
 * and an item next to a done task is an open task.
 */
function newItemTag(item: Plot.Tag): Plot.Tag {
  const tag = item.split(false)
  return tag.mark(S.Task) == 'done' ? tag.withMarks(S.Task.of('todo').addToSet(tag.marks)) : tag
}

/**
 * Backspace at the start of a list item (SPEC §7.5 Backspace table): the item's blocks take its
 * place outside its list, which splits there, and the item's own lists follow its text. In a nested
 * list, the item's blocks join the item that holds the list. An item without blocks becomes an
 * empty paragraph. The task state of the item goes.
 */
export function unwrapItem(item: Pos.Plot): Transaction.Spec {
  const list = item.parent!
  const fill = item.node.content.length ? [] : [T.Paragraph.create()]
  const changes: ChangeSet.Spec[] = [
    item.index == 0
      ? { from: list.before, to: item.start, insert: fill }
      : { from: item.before, to: item.start, insert: [Plot.End, ...fill] },
    item.isLast ? { from: item.end, to: list.after } : { from: item.end, to: item.after, insert: [list.node.tag] }
  ]
  return {
    changes,
    // The caret stays in the item's first block. An empty item gets a paragraph for the caret.
    ...(fill.length && {
      selection: (_cx, set) => GardSelection.cursor(set.findInserted(tag => tag.type == T.Paragraph.type)! + 1)
    }),
    scrollIntoView: true,
    userEvent: 'unwrap.list'
  }
}

/**
 * Backspace at the start of a block after the first block of a list item: that block and the
 * blocks after it in the item move out of the list, after the item. The list splits there.
 */
export function moveOutOfItem(item: Pos.Plot, index: number): Transaction.Spec {
  const list = item.parent!
  let from = item.start
  for (let i = 0; i < index; i++) from += item.node.content[i]!.length
  return {
    changes: [
      { from, insert: [Plot.End, Plot.End] },
      item.isLast ? { from: item.end, to: list.after } : { from: item.end, to: item.after, insert: [list.node.tag] }
    ],
    scrollIntoView: true,
    userEvent: 'unwrap.list'
  }
}

/**
 * Lift the items `first`–`last` of a nested list one level (Shift+Tab; SPEC §7.5 Lists). They
 * follow the item that holds the list. The items after them become children of the last one, and
 * the blocks after the list in the holding item move into a new item after them. With `clear`, a
 * last item whose only block is an empty paragraph, and that takes no children, becomes an empty
 * item.
 */
export function liftChanges(doc: Plot.Doc, list: Pos.Plot, first: number, last: number, clear = false) {
  const owner = list.parent!
  const firstItem = plotAt(doc, list, first),
    lastItem = plotAt(doc, list, last)
  const after = last < list.node.content.length - 1,
    ownerAfter = list.index < owner.node.content.length - 1
  const changes: ChangeSet.Spec[] = []
  // Close the list and the holding item before the first lifted item. A holding item with no other
  // blocks goes.
  if (first > 0) changes.push({ from: firstItem.before, insert: [Plot.End, Plot.End] })
  else if (list.index > 0) changes.push({ from: list.before, to: list.start, insert: [Plot.End] })
  else changes.push({ from: owner.before, to: list.start })
  if (clear && !after && lastItem.node.content.length == 1 && isEmptyItem(lastItem.node)) {
    changes.push({ from: lastItem.start, to: lastItem.end })
  }
  if (after) {
    // The items after the lifted ones nest in the last of them, below an empty paragraph when it has no blocks.
    const nest = lastItem.node.content.length ? [list.node.tag] : [T.Paragraph.create([]), list.node.tag]
    changes.push({ from: lastItem.end, to: lastItem.after, insert: nest })
    if (ownerAfter) changes.push({ from: list.after, insert: [Plot.End, S.ListItem] })
  } else if (ownerAfter) {
    changes.push({ from: list.end, to: list.after, insert: [S.ListItem] })
  } else {
    changes.push({ from: list.end, to: owner.after })
  }
  return changes
}

/**
 * Nest the items `first`–`last` under the item before them (Tab), with their own nested lists.
 * They join a list of the same kind that ends that item. The first item of a list has no item to
 * nest under and stays. Returns null when nothing can nest, or when an item would pass the deepest
 * level.
 */
export function sinkChanges(doc: Plot.Doc, list: Pos.Plot, first: number, last: number): ChangeSet.Spec[] | null {
  const start = Math.max(first, 1)
  if (start > last) return null
  let levels = 0
  for (let i = start; i <= last; i++) levels = Math.max(levels, itemLevels(list.node.content[i]!))
  if (levelOf(plotAt(doc, list, start)) + levels > maxLevel) return null
  const previous = plotAt(doc, list, start - 1),
    lastItem = plotAt(doc, list, last)
  const nested = previous.node.lastChild
  // An item without blocks gets an empty paragraph above its new list.
  const open = previous.node.content.length
    ? [list.node.type.default!]
    : [T.Paragraph.create([]), list.node.type.default!]
  return [
    nested?.type == list.node.type
      ? { from: previous.end - 1, to: previous.after }
      : { from: previous.end, to: previous.after, insert: open },
    { from: lastItem.after, insert: [Plot.End, Plot.End] }
  ]
}

/**
 * Changes that remove the first block of `item` after its text joined another block. The item's
 * other blocks stay at their level: the item before takes them, or, for the first item of a list,
 * they go before the list (a list never starts with a nested list). Returns null when the item has
 * no other blocks: then the whole item goes.
 */
export function removeItemHead(doc: Plot.Doc, item: Pos.Plot): ChangeSet.Spec[] | null {
  const rest = item.node.content.slice(1)
  if (!rest.length) return null
  const head = childAt(doc, item, 0)
  const list = item.parent!
  if (item.index > 0) return [{ from: childAt(doc, list, item.index - 1).after - 1, to: head.after }]
  return list.node.content.length == 1
    ? [{ from: list.before, to: list.after, insert: rest }]
    : [
        { from: list.before, insert: rest },
        { from: item.before, to: item.after }
      ]
}

/**
 * Enter in a list item (SPEC §7.5 Lists), with the caret in a paragraph of the item or in an
 * empty item. Enter in an empty item lifts a nested item one level and turns a top-level item into
 * a paragraph. At the start of an item it adds an empty item before it. Elsewhere the item splits:
 * the text after the caret and the blocks after it in the item go to a new item. A paragraph that
 * the split leaves empty goes, unless it has attributes outside the vocabulary.
 */
export function enterListItem(state: GardState): Transaction.Spec | false {
  const { doc } = state
  const head = state.sel.head
  const block = head.parent.node.inlineContent ? head.textblockParent : null
  if (block && block.node.type != T.Paragraph.type) return false
  const item = block ? block.parent! : head.parent
  if (!isItem(item.node)) return false
  const list = item.parent!
  if (isEmptyItem(item.node) && (!block || block.index == 0)) {
    if (isItem(list.parent!.node)) {
      return {
        changes: liftChanges(doc, list, item.index, item.index, true),
        scrollIntoView: true,
        userEvent: 'lift.list'
      }
    }
    return { ...unwrapItem(item), userEvent: 'split.list' }
  }
  if (!block) return false
  const tag = newItemTag(item.node.tag)
  if (block.index == 0 && head.pos == block.start) {
    return { changes: { from: item.before, insert: [tag.create()] }, scrollIntoView: true, userEvent: 'split.list' }
  }
  const keepsBefore = head.pos > block.start || block.index == 0 || block.node.marks.some(mark => mark.type == Attrs)
  const atEnd = head.pos == block.end
  // When nothing goes to the new item, it is empty.
  const empty = atEnd && block.isLast
  const open: Token[] = empty ? [tag] : [tag, block.node.tag.split(atEnd)]
  const change: ChangeSet.Change = keepsBefore
    ? { from: head.pos, to: empty ? block.after : head.pos, insert: [Plot.End, Plot.End, ...open] }
    : { from: block.before, to: empty ? block.after : block.start, insert: [Plot.End, ...open] }
  // The caret goes into the new item, past the tokens that open it.
  const caret = (keepsBefore ? head.pos + 2 : block.before + 1) + open.length
  return { changes: change, selection: GardSelection.cursor(caret), scrollIntoView: true, userEvent: 'split.list' }
}

/**
 * The task item whose check box is at the point of a pointer event: the box is in the item's left
 * padding, beside its first line.
 */
function taskAt(wg: Wordgard, event: MouseEvent): { pos: number; node: Node } | null {
  const target = event.target as HTMLElement
  if (target.localName != 'li' || !target.hasAttribute('data-task')) return null
  const box = target.getBoundingClientRect()
  const text = target.firstElementChild?.getBoundingClientRect()
  const left = box.left + parseFloat(getComputedStyle(target).paddingLeft)
  if (event.clientX >= left || (text && event.clientY > text.bottom)) return null
  const found = wg.nodeFromDOM(target)
  return found && isItem(found.node) ? found : null
}

/** List editing beside the keys: a click on the check box of a task item toggles the task. */
/**
 * An edit that empties the only paragraph of a list item leaves an empty item, which reads as `-`.
 * A paragraph with attributes stays. A page write keeps its source as written, history replays what
 * it recorded, and a composition keeps the paragraph that holds its text.
 */
const emptiedItems = Transaction.extender.of(tr => {
  if (!tr.docChanged || ['page.write', 'undo', 'redo', 'input.type.compose'].some(event => tr.isUserEvent(event))) {
    return null
  }
  const doc = tr.newDoc,
    changes: ChangeSet.Spec[] = [],
    seen = new Set<number>()
  tr.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    for (const pos of [fromB, toB]) {
      const paragraph = doc.resolve(pos).parent
      const item = paragraph.parent
      if (
        !item ||
        !isItem(item.node) ||
        item.node.content.length != 1 ||
        paragraph.node.type != T.Paragraph.type ||
        paragraph.node.content.length ||
        paragraph.node.marks.length ||
        seen.has(paragraph.before)
      ) {
        continue
      }
      seen.add(paragraph.before)
      changes.push({ from: paragraph.before, to: paragraph.after })
    }
  })
  return changes.length ? { changes, sequential: true } : null
})

export const listEditing: GardState.Extension = [
  emptiedItems,
  Wordgard.domEventHandler('mousedown', (event, wg) => {
    if (event.button != 0 || wg.state.readOnly) return false
    const task = taskAt(wg, event)
    if (!task) return false
    const value = task.node.mark(S.Task) == 'done' ? 'todo' : 'done'
    wg.dispatch({ changes: { from: task.pos, add: S.Task.of(value) }, userEvent: 'toggle.task' })
    return true
  })
]

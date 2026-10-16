import { Plot, Node, Mark, Pos, Leaf, Token, ChangeSet, Schema } from '../doc'
import { GardSelection, GardState, Transaction } from '../state'
import { findClusterBreak } from '@marijn/find-cluster-break'

/**
 * If the cursor is in an empty textblock that can be lifted out of a
 * parent, return a transaction that does this.
 */
export function liftEmptyBlock(state: GardState): Transaction.Spec | false {
  if (!state.selection.isCursor) return false
  const sel = state.sel,
    block = sel.head.textblockParent
  if (!block || !sel.head.isAtStart(block) || !sel.head.isAtEnd(block)) return false
  let start = block.before
  let end = block.after
  const before: Token[] = []
  const after: Token[] = []
  for (
    let level = block.parent, index = block.index, atStart = true, atEnd = true, first = true;
    level;
    first = false, index = level.index, level = level.parent
  ) {
    if (!first && state.schema.canContain(level.node.type, block.node.type)) {
      return {
        changes: [
          { from: start, to: block.before, insert: before },
          { from: block.after, to: end, insert: after }
        ],
        scrollIntoView: true,
        userEvent: 'unwrap.empty'
      }
    }
    if (level.node.isInline || level.node.type.isolating) break
    if (index) atStart = false
    if (atStart) start--
    else before.push(Plot.End)
    if (index < level.node.content.length - 1) atEnd = false
    if (atEnd) end++
    else after.unshift(level.node.tag.split(false))
  }
  return false
}

/**
 * If the selection is in a {@link Plot.Spec.preserveWhitespace
 * `preserveWhitespace`} textblock, replace the selected content with
 * a {@link Schema.lineBreak line break}.
 *
 * If the selection additionally is a cursor on an otherwise empty
 * line after a blank line, split or trunctate (if at end) the parent
 * textblock and create a blank default text block in place of the
 * empty line.
 */
export function enterInCode(state: GardState): Transaction.Spec | false {
  const { sel } = state,
    { head } = sel
  if (
    !head.parent.node.inlineContent ||
    !head.parent.node.type.preserveWhitespace ||
    head.parent.start != sel.anchor.parent.start ||
    !state.schema.lineBreak
  ) {
    return false
  }

  // If on empty line after two line breaks, split or truncate the block
  if (
    sel.selection.empty &&
    head.parent.parent &&
    !head.inText &&
    head.index > 1 &&
    head.nodeBefore!.type == state.schema.lineBreak.type &&
    (head.pos == head.parent.end || head.nodeAfter!.type == state.schema.lineBreak.type) &&
    head.parent.node.content[head.index - 2]!.type == state.schema.lineBreak.type
  ) {
    const textblock = state.schema.defaultContentPlot(head.parent.parent.node.type)
    if (textblock?.type.inlineContent) {
      return {
        changes: {
          from: head.pos - 2,
          to: head.pos + 1,
          insert:
            head.pos == head.parent.end
              ? [Plot.End, textblock, Plot.End]
              : [Plot.End, textblock, Plot.End, head.parent.node.tag]
        },
        selection: GardSelection.cursor(head.pos, -1),
        scrollIntoView: true,
        userEvent: 'split.textblock'
      }
    }
  }

  return {
    changes: { from: sel.from.pos, to: sel.to.pos, insert: [state.schema.lineBreak] },
    selection: GardSelection.cursor(sel.from.pos + 1, -1),
    scrollIntoView: true,
    userEvent: 'input'
  }
}

/**
 * Split the textblock at the cursor position, if any. If the
 * textblock is the first child of a list item, also split that item,
 * unless `splitListItem` is false.
 */
export function splitTextblock(state: GardState, splitListItem = true): Transaction.Spec | false {
  const { from, to } = state.sel.replacementRange,
    { schema } = state.doc
  const before = from.textblockParent
  if (!before || !before.parent || before.node.type.isolating) return false
  const tokens: Token[] = []
  for (let p = from.parent; ; p = p.parent!) {
    tokens.push(Plot.End)
    if (p == before) break
  }

  if (
    splitListItem &&
    !before.parent.node.type.hasRole(Node.Role.List) &&
    before.isFirst &&
    before.parent.parent?.node.type.hasRole(Node.Role.List)
  ) {
    tokens.push(Plot.End, before.parent.node.tag.split(false))
  }

  const after = to.textblockParent
  if (after) {
    let atEnd = true
    const insert = tokens.length
    for (let p = to.parent, index = to.index; ; index = p.index + 1, p = p.parent!) {
      if (index < p.node.content.length) atEnd = false
      let tag = p.node.tag.split(atEnd)
      const nextTag = atEnd && !p.node.type.spec.preserveOnSplitAtEnd ? null : tag
      if (!nextTag || !schema.canContain(p.parent!.node.type, tag.type)) {
        if (!atEnd) return false
        const defaultType = schema.defaultContentPlot(p.parent!.node.type)
        if (defaultType) tag = schema.withMarksFrom(tag, defaultType)
        else return false
      }
      tokens.splice(insert, 0, tag)
      if (p == after) break
    }
  }
  const changes: ChangeSet.Spec[] = [
    {
      from: from.pos,
      to: to.pos,
      insert: tokens
    }
  ]
  if (from.isAtStart(before)) {
    const deflt = schema.defaultContentPlot(before.parent.node.type)
    if (deflt && !deflt.eq(before.node.tag)) {
      changes.unshift({
        from: before.before,
        to: before.start,
        insert: [schema.withMarksFrom(before.node.tag, deflt)]
      })
    }
  }
  const changeSet = ChangeSet.create(state.doc, { correct: changes, local: true })
  return {
    changes: changeSet,
    selection: GardSelection.cursor(changeSet.mapPos(to.pos, 1)),
    scrollIntoView: true,
    userEvent: 'split.textblock'
  }
}

/**
 * Returns a transaction that deletes the selection, or false if the
 * selection is empty.
 */
export function deleteSelection(state: GardState): Transaction.Spec | false {
  const { ranges } = state.selection
  if (ranges.every(r => r.from == r.to)) return false
  return autoJoinBlocks(state, {
    changes: {
      correct: ranges.filter(r => r.from < r.to).map(r => ({ from: r.from, to: r.to, fit: true })),
      local: true
    },
    selection: (cx, changes) =>
      state.selection instanceof GardSelection.Text
        ? GardSelection.near(cx, changes.mapPos(state.selection.head, -1), 1)
        : state.selection.map(changes, cx),
    scrollIntoView: true,
    userEvent: 'delete.selection'
  })
}

/**
 * If the cursor is inside an empty plot, return a transaction that
 * deletes the entire plot. `dir` determines which way the cursor
 * moves after the deletion.
 */
export function deleteEmptyPlot(state: GardState, dir: -1 | 1 = -1): Transaction.Spec | false {
  if (!state.selection.isCursor) return false
  const plot = state.sel.head.parent
  if (!plot.parent || plot.start < plot.end) return false
  return {
    changes: { from: plot.before, to: plot.after, fit: true },
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(state.selection.head), dir),
    scrollIntoView: true,
    userEvent: dir < 0 ? 'delete.backward' : 'delete.forward'
  }
}

/**
 * If the cursor is at the start of a textblock that can be joined to
 * a textblock before it, return a transaction to performs this join.
 */
export function joinBackward(state: GardState): Transaction.Spec | false {
  if (!state.selection.isCursor) return false
  const { head } = state.sel
  const block = head.textblockParent
  if (!block || !head.isAtStart(block) || block.node.type.isolating) return false
  let scan = block
  const target = scan.node
  while (!scan.index) {
    if (!scan.parent) return false
    scan = scan.parent
    if (scan.node.type.isolating || !scan.node.isBlock) return false
  }
  let before = scan.previousSibling!,
    parent = scan.parent!.node,
    pos = scan.start - 1
  while (before.isLeaf || !before.isTextblock) {
    if (before.isLeaf || state.isAtom(before.type) || before.type.isolating || !before.isBlock) return false
    const last = before.content.length - 1
    if (last < 0) return false
    parent = before
    before = before.content[last]!
    pos--
  }
  const { schema } = state.doc
  const changes = [joinBlocks(state.doc.resolve(pos - 1).parent, block), clearNonFitting(schema, block, before.type)]
  if (!before.content.length && !before.tag.eq(target.tag) && schema.canContain(parent.type, target.type)) {
    changes.push({
      from: pos - before.length,
      to: pos - before.length + 1,
      insert: [schema.withMarksFrom(before.tag, target.tag)]
    })
  }
  const changeSet = ChangeSet.create(state.doc, changes)
  return {
    changes: changeSet,
    selection: GardSelection.cursor(changeSet.mapPos(head.pos), -1),
    scrollIntoView: true,
    userEvent: 'join.backward'
  }
}

/**
 * If the cursor is at the start of a list item that has another item
 * before it, return a transaction that joins those two items.
 */
export function joinListItems(state: GardState): Transaction.Spec | false {
  if (!state.selection.isCursor) return false
  const { head } = state.sel
  if (head.index || head.inText) return false
  for (let scan = head.parent; ;) {
    const next = scan.parent
    if (!next) return false
    if (scan.node.isBlock && next.node.type.hasRole(Node.Role.List)) {
      const prev = scan.previousSibling
      if (!prev || (!prev.isLeaf && scan.node.content.some(ch => !state.schema.canContain(prev.type, ch.type)))) {
        return false
      }
      return {
        changes: { from: scan.before - 1, to: scan.before + 1 },
        userEvent: 'join.backward.list',
        scrollIntoView: true
      }
    }
    if (scan.index) return false
    scan = next
  }
}

/**
 * If the cursor is at the end of a textblock that can be joined to
 * the textblock after it, return a transaction that performs this
 * join.
 */
export function joinForward(state: GardState): Transaction.Spec | false {
  if (!state.selection.isCursor) return false
  const { head } = state.sel
  const block = head.textblockParent
  if (!block || !head.isAtEnd(block) || block.node.type.isolating) return false
  let scan = block
  const target = scan.node
  for (;;) {
    if (!scan.parent) return false
    if (scan.index < scan.parent.node.content.length - 1) break
    scan = scan.parent
    if (scan.node.type.isolating || !scan.node.isBlock) return false
  }
  let after = scan.nextSibling!,
    parent = scan.parent.node,
    pos = scan.after
  while (after.isLeaf || !after.isTextblock) {
    if (after.isLeaf || after.type.isolating || state.isAtom(after.type) || !after.isBlock || !after.content.length) {
      return false
    }
    parent = after
    after = after.content[0]!
    pos++
  }
  const blockAfter = state.doc.resolveNode(pos) as Pos.Plot
  const { schema } = state.doc
  const changes = [joinBlocks(block, blockAfter), clearNonFitting(schema, blockAfter, target.type)]
  if (!target.content.length && !target.tag.eq(after.tag) && schema.canContain(parent.type, after.type)) {
    changes.push({
      from: block.before,
      to: block.start,
      insert: [schema.withMarksFrom(target.tag, after.tag)]
    })
  }
  return {
    changes,
    scrollIntoView: true,
    userEvent: 'join.forward'
  }
}

/**
 * Create a transaction that deletes the atomic node or text
 * cluster/word in front of the cursor, if possible.
 */
export function deleteBackward(state: GardState, word = false): Transaction.Spec | false {
  if (!state.selection.isCursor) return false

  const sel = state.sel
  let { parent: scan, index, pos } = sel.head
  if (!sel.head.inText) {
    while (!index) {
      if (scan.node.type.isolating || !scan.parent || (!scan.node.contentLength && scan.node.isInline)) return false
      index = scan.index
      scan = scan.parent
      pos--
    }
  }
  let next = sel.head.inText ? sel.head.nodeBefore! : scan.node.content[--index]
  for (;;) {
    if (next!.isPlot && next!.type.isolating) return false
    if (next!.isLeaf || state.isAtom(next!.type) || !next!.content.length) break
    next = next!.content[next!.content.length - 1]
    pos--
  }
  if (next!.is(Leaf.Text)) {
    let size = 0
    if (word) {
      for (let i = next.param.length, type: 'a' | 'p' | undefined; ;) {
        const ch = next.param[i - 1]!
        if (/\s/.test(ch)) {
          if (type) break
        } else {
          const next: 'a' | 'p' = /[\p{Alphabetic}\p{Number}]/u.test(ch) ? 'a' : 'p'
          if (!type) type = next
          else if (type != next) break
        }
        i--
        size++
        if (i == 0) {
          if (!index) break
          next = scan.node.content[--index]
          if (!next!.is(Leaf.Text)) break
          i = next.param.length
        }
      }
    } else {
      size = next.length - findClusterBreak(next.param, next.length, false)
      // As in browsers, this takes the last mark off a letter with
      // combining marks (for example in Thai). A cluster with emoji or
      // with characters outside the BMP goes as a whole.
      if (size > 1 && !/[\ud800-\udfff]|\p{Emoji}/u.test(next.param.slice(-size))) size = 1
    }
    return {
      changes: { from: pos - size, to: pos },
      scrollIntoView: true,
      userEvent: 'delete.backward'
    }
  }
  // Delete the next node, plus, if it's a block, all parents that contain only it.
  let from = pos - next!.length,
    to = pos
  let parent: Pos.Plot | null = state.doc.resolve(pos).parent
  if (next!.isBlock) {
    while (parent && parent.node.isBlock && parent.node.content.length == 1) {
      if (!parent.parent) return false
      parent = parent.parent
      from--
      to++
    }
  }
  return {
    changes: { from, to },
    scrollIntoView: true,
    userEvent: 'delete.backward'
  }
}

/**
 * Return a transaction that deletes the element (text cluster or
 * leaf node) after the cursor, if any.
 */
export function deleteForward(state: GardState, word = false): Transaction.Spec | false {
  if (!state.selection.isCursor) return false

  const sel = state.sel
  let { parent: scan, index, pos } = sel.head
  if (!sel.head.inText) {
    while (index == scan.node.content.length) {
      if (scan.node.type.isolating || !scan.parent || (!scan.node.contentLength && scan.node.isInline)) return false
      index = scan.index + 1
      scan = scan.parent
      pos++
    }
  }
  let next = sel.head.inText ? sel.head.nodeAfter! : scan.node.content[index]
  for (;;) {
    if (next!.isPlot && next!.type.isolating) return false
    if (next!.isLeaf || state.isAtom(next!.type) || !next!.content.length) break
    next = next!.content[0]
    pos++
  }
  if (next!.is(Leaf.Text)) {
    let size = 0
    if (word) {
      for (let i = 0, type: 'a' | 'p' | undefined; ;) {
        const ch = next.param[i]!
        if (/\s/.test(ch)) {
          if (type) break
        } else {
          const next: 'a' | 'p' = /[\p{Alphabetic}\p{Number}]/u.test(ch) ? 'a' : 'p'
          if (!type) type = next
          else if (type != next) break
        }
        i++
        size++
        if (i == next.param.length) {
          if (index == scan.node.content.length - 1) break
          next = scan.node.content[++index]
          if (!next!.is(Leaf.Text)) break
          i = 0
        }
      }
    } else {
      size = findClusterBreak(next.param, 0)
    }
    return {
      changes: { from: pos, to: pos + size },
      scrollIntoView: true,
      userEvent: 'delete.forward'
    }
  }
  // Delete the node ahead, plus all parents that it completely fills
  let from = pos,
    to = pos + next!.length
  let parent: Pos.Plot | null = state.doc.resolve(pos).parent
  if (next!.isBlock) {
    while (parent && parent.node.isBlock && parent.node.content.length == 1) {
      if (!parent.parent) return false
      parent = parent.parent
      from--
      to++
    }
  }
  return {
    changes: { from, to },
    scrollIntoView: true,
    userEvent: 'delete.forward'
  }
}

/** Get an array of all textblocks that contain part of the selection. */
export function selectedTextblocks(state: GardState) {
  const textblocks: Pos.Plot[] = []
  let lastBlock = -1
  for (const { from, to } of state.selection.ranges) {
    state.doc.iterate(from, to, (node, pos) => {
      if (node.isPlot && node.isTextblock && pos > lastBlock) {
        textblocks.push(state.doc.resolveNode(pos) as Pos.Plot)
        lastBlock = pos
      }
    })
  }
  return textblocks
}

/**
 * Remove all content in `node` that is not allowed to appear in
 * `type`.
 */
function clearNonFitting(schema: Schema, node: Pos.Plot, type: Plot.Type): ChangeSet.Spec {
  const changes: ChangeSet.Spec[] = []
  for (let i = 0, pos = node.start; i < node.node.content.length; i++) {
    const child = node.node.content[i]!,
      end = pos + child.length
    if (!schema.canContain(type, child.type)) changes.push({ from: pos, to: end })
    pos = end
  }
  return changes
}

/**
 * Join two adjacent (only separated by first a sequence of block end
 * tokens and then a sequence of block open tokens) block plots.
 */
export function joinBlocks(before: Pos.Plot, after: Pos.Plot): ChangeSet.Spec {
  const changes: ChangeSet.Spec[] = [{ from: before.end, to: after.start }]
  const dBefore = before.depth,
    dAfter = after.depth
  const tokensAfter: Token[] = []
  const posAfter = after.after
  let end = posAfter
  if (dBefore > dAfter) {
    const extraContext: Plot.Tag[] = []
    for (let i = dBefore - dAfter, level = before.parent!; i > 0; i--, level = level.parent!) {
      extraContext.push(level.node.tag)
    }
    const nodeAfter = after.nextSibling
    for (let i = dBefore - dAfter - 1, joining = true; i >= 0; i--) {
      const context = extraContext[i]!
      if (
        !joining ||
        !nodeAfter ||
        nodeAfter.isLeaf ||
        nodeAfter.type != context.type ||
        !context.type.spec.autoJoin ||
        (typeof context.type.spec.autoJoin == 'function' && !context.type.spec.autoJoin(context, nodeAfter.tag))
      ) {
        joining = false
      }
      if (joining) end++
      else tokensAfter.push(Plot.End)
    }
  } else if (dAfter > dBefore) {
    for (let i = dAfter - dBefore, level = after, atEnd = true; i > 0; i--, level = level.parent!) {
      if (level.nextSibling) atEnd = false
      if (atEnd) end++
      else tokensAfter.unshift(level.parent!.node.tag)
    }
  }
  if (tokensAfter.length || end > posAfter) changes.push({ from: posAfter, to: end, insert: tokensAfter })
  return changes
}

/**
 * Query whether the given range has any content to which the given
 * mark or mark type could be added.
 */
export function canAddMarkInRange(doc: Plot.Doc, from: number, to: number, mark: Mark | Mark.Type) {
  let found = false
  const type = mark instanceof Mark.Type ? mark : mark.type
  doc.iterate(from, to, node => {
    if (found || mark.isInSet(node.tag.marks)) return false
    if (doc.schema.markAllowed(type, node.type)) found = true
    return true
  })
  return found
}

/**
 * Post-process the given transaction spec to check for any block
 * boundaries touched by the changes in it that can be {@link
 * Plot.Spec.autoJoin auto-joined}. If any are found, the spec is
 * updated to perform those joins.
 */
function autoJoinBlocks(state: GardState, tr: Transaction.Spec): Transaction.Spec {
  if (!tr.changes) return tr
  const changes = ChangeSet.create(state.doc, tr.changes)
  const doc = changes.apply(state.doc)
  if (changes.empty) return tr
  const append: ChangeSet.Spec[] = []
  let cursor = doc.resolve(0)
  const check = (pos: number) => {
    cursor = cursor.advance(pos - cursor.pos)
    let before = cursor.nodeBefore,
      after = cursor.nodeAfter
    if (before && after && before.isPlot && before.isBlock && after.isPlot && after.type == before.type) {
      let { autoJoin } = after.type.spec
      if (autoJoin && (typeof autoJoin != 'function' || autoJoin(before.tag, after.tag))) {
        let from = pos - 1,
          to = pos + 1
        for (;;) {
          const last: Node | null = before!.lastChild,
            first: Node | null = after!.firstChild
          if (!first || !last || first.isLeaf || last.isLeaf || first.type != last.type || first.isInline) break
          autoJoin = last.type.spec.autoJoin
          if (!autoJoin || (typeof autoJoin == 'function' && !autoJoin(last.tag, first.tag))) {
            break
          }
          from--
          to++
          before = last
          after = first
        }
        append.push({ from, to })
      }
    }
  }

  changes.iterGaps(
    () => {},
    (_fromA, _toA, fromB, toB) => {
      check(fromB)
      if (toB > fromB) check(toB)
    }
  )
  if (!append.length) return { ...tr, changes }
  return Transaction.merge(state, tr, { changes: append, sequential: true })
}

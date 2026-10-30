import { Elt, Leaf, Node, type Mark, type Pos } from '../core/doc'
import { Decoration, Wordgard } from '../core/editor'
import { PhraseSet } from '../core/phrases'
import { GardSelection, GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { BlockSelection } from './block-selection'
import { dispatchStep, splitInsert } from './block-insert'
import { Attrs, markValue } from './attributes'
import { editorPhrases } from './phrases'
import { Align, checkMentionTarget, Link, Mention, type MentionTarget } from './schema'

export type MentionCategory = 'all' | 'page' | 'principal'

export type MentionSession = {
  /** Position of the triggering `@` or `＠` character. */
  from: number
  /** End position of the active `@query` span (`>= from + 1`). */
  to: number
  /** Query text after the trigger character (`0..50` chars, spaces allowed). */
  query: string
  /** Active category tab in the mention popover. */
  category: MentionCategory
  /** Query length where total matches across all categories first dropped to 0. */
  zeroMatchSinceLength: number | null
}

const MAX_QUERY_LENGTH = 50
const ZERO_MATCH_GRACE_CHARS = 12
const SUPPRESSED_PREV_CHAR = /[A-Za-z0-9_@/]/

export const openMentionEffect = Transaction.Effect.define<{ category?: MentionCategory }>()
export const dismissMentionEffect = Transaction.Effect.define<null>()
export const setMentionCategoryEffect = Transaction.Effect.define<MentionCategory>()
export const reportMentionMatchesEffect = Transaction.Effect.define<{ query: string; totalAllMatches: number }>()

const isTriggerChar = (ch: string | undefined) => ch === '@' || ch === '＠'

/** Read plain text across `[from, to]` in `block`, returning `null` if any non-text leaf or code/link mark appears. */
function readCleanTextRange(block: Pos.Plot, from: number, to: number): string | null {
  if (from < block.start || to > block.end || from > to) return null
  if (!block.node.isTextblock || block.node.type.hasRole(Node.Role.Code)) return null
  let offset = block.start
  let result = ''
  for (const child of block.node.content) {
    const next = offset + child.length
    if (next <= from) {
      offset = next
      continue
    }
    if (offset >= to) break
    if (!child.is(Leaf.Text) || T.Code.isInSet(child.marks) || Link.isInSet(child.marks)) return null
    const sliceStart = Math.max(0, from - offset)
    const sliceEnd = Math.min(child.length, to - offset)
    result += child.param.slice(sliceStart, sliceEnd)
    offset = next
  }
  return result
}

/** Character immediately before `pos` inside `block`, or `''` at block start or after a non-text leaf. */
function charBeforeInBlock(block: Pos.Plot, pos: number): string {
  if (pos <= block.start) return ''
  let offset = block.start
  for (const child of block.node.content) {
    const next = offset + child.length
    if (pos > offset && pos <= next) {
      return child.is(Leaf.Text) ? (child.param[pos - offset - 1] ?? '') : ''
    }
    offset = next
  }
  return ''
}

/** Inline format and discussion marks at `pos` in `block` that `Mention` can inherit. */
export function inheritedMentionMarks(state: GardState, pos: number): readonly Mark[] {
  if (
    state.selection instanceof GardSelection.Text &&
    state.selection.empty &&
    state.selection.head === pos &&
    state.selection.marks
  ) {
    return state.selection.marks.filter(mark => mark.type !== Attrs && state.schema.markAllowed(mark.type, Mention))
  }
  const resolved = state.doc.resolve(pos)
  const block = resolved.parent
  if (!block.node.inlineContent) return []
  let offset = block.start
  for (const child of block.node.content) {
    const next = offset + child.length
    if (pos >= offset && pos < next) {
      return child.marks.filter(mark => mark.type !== Attrs && state.schema.markAllowed(mark.type, Mention))
    }
    offset = next
  }
  const before = resolved.nodeBefore
  if (before) {
    return before.marks.filter(mark => mark.type !== Attrs && state.schema.markAllowed(mark.type, Mention))
  }
  return []
}

function validateSessionSpan(
  state: GardState,
  from: number,
  to: number,
  category: MentionCategory,
  zeroMatchSinceLength: number | null
): MentionSession | null {
  if (state.readOnly || to < from + 1 || to > state.doc.length || from < 0) return null
  const { selection } = state
  if (!(selection instanceof GardSelection.Text) || !selection.empty) return null
  if (selection.head < from + 1 || selection.head > to) return null
  const atFrom = state.doc.resolve(from)
  const atTo = state.doc.resolve(to)
  if (atFrom.parent.before !== atTo.parent.before) return null
  const raw = readCleanTextRange(atFrom.parent, from, to)
  if (!raw || !isTriggerChar(raw[0])) return null
  const query = raw.slice(1)
  if (isTriggerChar(query[0]) || query.length > MAX_QUERY_LENGTH || /[\r\n\t]/.test(query)) return null
  let nextZero = zeroMatchSinceLength
  if (nextZero !== null) {
    if (query.length < nextZero) nextZero = null
    else if (query.length - nextZero > ZERO_MATCH_GRACE_CHARS) return null
  }
  return { from, to, query, category, zeroMatchSinceLength: nextZero }
}

function isNonTypingTransaction(tr: Transaction): boolean {
  if (tr.annotation(Transaction.addToHistory) === false) return true
  for (const kind of ['input.paste', 'move.paste', 'input.drop', 'undo', 'redo', 'block.type', 'block.insert']) {
    if (tr.isUserEvent(kind)) return true
  }
  return false
}

function detectTypedTrigger(tr: Transaction): MentionSession | null {
  if (!tr.docChanged || tr.state.readOnly || isNonTypingTransaction(tr)) return null
  const { selection } = tr.state
  if (!(selection instanceof GardSelection.Text) || !selection.empty || selection.head < 1) return null
  const head = selection.head
  const from = head - 1
  let insertedAtCaret = false
  tr.changes.iterChanges((_fromA, _toA, fromB, toB) => {
    if (fromB <= from && head <= toB && toB > fromB) insertedAtCaret = true
  })
  if (!insertedAtCaret) return null
  const resolved = tr.state.doc.resolve(from)
  const block = resolved.parent
  const triggerText = readCleanTextRange(block, from, head)
  if (!triggerText || !isTriggerChar(triggerText)) return null
  const prevChar = charBeforeInBlock(block, from)
  if (prevChar && SUPPRESSED_PREV_CHAR.test(prevChar)) return null
  return { from, to: head, query: '', category: 'all', zeroMatchSinceLength: null }
}

function mentionPlaceholderDeco(state: GardState, session: MentionSession | null): Decoration.Point.Set {
  if (!session || session.query.length > 0 || state.readOnly) return Decoration.Point.none
  const block = state.doc.resolve(session.from).parent
  if (
    block.node.type !== T.Paragraph.type ||
    block.end - block.start !== 1 ||
    (markValue(block.node, Align) ?? 'left') !== 'left'
  ) {
    return Decoration.Point.none
  }
  return Decoration.Point.set([
    [
      Decoration.Point.attributes({
        'data-mention-placeholder': editorPhrases.get(state, 'mention_placeholder')
      }),
      block.before
    ]
  ])
}

export const mentionField = GardState.Field.define<MentionSession | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(dismissMentionEffect)) return null
      if (effect.is(openMentionEffect)) {
        const head = tr.state.selection.head
        return validateSessionSpan(tr.state, head - 1, head, effect.value.category ?? 'all', null)
      }
      if (effect.is(setMentionCategoryEffect) && value) {
        value = { ...value, category: effect.value }
      }
      if (effect.is(reportMentionMatchesEffect) && value && value.query === effect.value.query) {
        if (effect.value.totalAllMatches > 0) {
          value = { ...value, zeroMatchSinceLength: null }
        } else {
          const since = value.zeroMatchSinceLength ?? value.query.length
          if (value.query.length - since > ZERO_MATCH_GRACE_CHARS) return null
          value = { ...value, zeroMatchSinceLength: since }
        }
      }
    }
    if (tr.annotation(Wordgard.isFocusChange) === false) return null
    if (tr.state.readOnly) return null

    if (value === null) {
      return detectTypedTrigger(tr)
    }

    if (!tr.docChanged && !tr.selection) {
      return PhraseSet.didChange(tr.startState, tr.state) ? { ...value } : value
    }

    const mappedFrom = tr.docChanged ? tr.changes.mapPos(value.from, 1) : value.from
    const mappedTo = tr.docChanged ? tr.changes.mapPos(value.to, 1) : value.to
    return validateSessionSpan(tr.state, mappedFrom, mappedTo, value.category, value.zeroMatchSinceLength)
  },
  provide: field => Decoration.Point.source.of(state => mentionPlaceholderDeco(state, state.field(field)))
})

/** Transaction spec that inserts `@` at the caret and opens a mention session (used by `/` and `+` menus). */
export function mentionTriggerSpec(state: GardState, category: MentionCategory = 'all'): Transaction.Spec | null {
  if (state.readOnly) return null
  const head = state.sel.head
  if (
    !(state.selection instanceof BlockSelection) &&
    head.parent.node.isTextblock &&
    !head.parent.node.type.hasRole(Node.Role.Code)
  ) {
    const { from, to } = state.selection.replacementRange
    const block = state.doc.resolve(from).parent
    const prev = charBeforeInBlock(block, from)
    const text = prev && SUPPRESSED_PREV_CHAR.test(prev) ? ' @' : '@'
    const marks = inheritedMentionMarks(state, from)
    return {
      changes: { from, to, insert: [Leaf.text(text, marks)] },
      selection: GardSelection.cursor(from + text.length),
      effects: openMentionEffect.of({ category }),
      userEvent: 'mention.open'
    }
  }
  const { changes, at } = splitInsert(state.doc, head.pos, [T.Paragraph.create([Leaf.text('@')])], false)
  return {
    changes,
    selection: GardSelection.cursor(at + 2),
    effects: openMentionEffect.of({ category }),
    userEvent: 'mention.open'
  }
}

/** Transaction spec replacing the active `@query` session with an inline `<mention />` leaf. */
export function commitMentionSpec(state: GardState, target: MentionTarget): Transaction.Spec | null {
  if (state.readOnly) return null
  checkMentionTarget(target)
  const session = state.field(mentionField, false)
  if (!session) return null
  const marks = inheritedMentionMarks(state, session.from)
  const leaf = Mention.of(target, marks)
  return {
    changes: { from: session.from, to: session.to, insert: [leaf] },
    selection: GardSelection.cursor(session.from + leaf.length),
    effects: dismissMentionEffect.of(null),
    userEvent: 'mention.insert'
  }
}

/** Replace the active `@query` session with an inline `<mention />` leaf as one undo step. */
export function commitMention(editor: Wordgard, target: MentionTarget): boolean {
  if (editor.composing) return false
  const spec = commitMentionSpec(editor.state, target)
  if (!spec) return false
  dispatchStep(editor, spec)
  editor.focus()
  return true
}

/** Transaction spec inserting an inline `<mention />` leaf at the current selection. */
export function insertMentionSpec(state: GardState, target: MentionTarget): Transaction.Spec | null {
  if (state.readOnly) return null
  checkMentionTarget(target)
  const head = state.sel.head
  if (
    !(state.selection instanceof BlockSelection) &&
    head.parent.node.isTextblock &&
    !head.parent.node.type.hasRole(Node.Role.Code)
  ) {
    const { from, to } = state.selection.replacementRange
    const leaf = Mention.of(target, inheritedMentionMarks(state, from))
    return {
      changes: { from, to, insert: [leaf] },
      selection: GardSelection.cursor(from + leaf.length),
      effects: dismissMentionEffect.of(null),
      userEvent: 'mention.insert'
    }
  }
  const leaf = Mention.of(target)
  const { changes, at } = splitInsert(state.doc, head.pos, [T.Paragraph.create([leaf])], false)
  return {
    changes,
    selection: GardSelection.cursor(at + 2),
    effects: dismissMentionEffect.of(null),
    userEvent: 'mention.insert'
  }
}

/** Insert an inline `<mention />` leaf at the current selection as one undo step. */
export function insertMention(editor: Wordgard, target: MentionTarget): boolean {
  if (editor.composing) return false
  const spec = insertMentionSpec(editor.state, target)
  if (!spec) return false
  dispatchStep(editor, spec)
  editor.focus()
  return true
}

/** Default fallback shape when `host.mountMention` is absent, plus the `@` session state field. */
export const mentions: GardState.Extension = [
  mentionField,
  Decoration.Tag.shape(Mention, tag => {
    const target = tag.param
    return 'page' in target
      ? Elt.mk(
          'span',
          {
            class: 'editor-mention editor-mention-page',
            contenteditable: 'false',
            'data-mention-page': target.page
          },
          [`@${target.page}`]
        )
      : Elt.mk(
          'span',
          {
            class: 'editor-mention editor-mention-principal',
            contenteditable: 'false',
            'data-mention-principal': target.principal
          },
          [`@${target.principal}`]
        )
  })
]

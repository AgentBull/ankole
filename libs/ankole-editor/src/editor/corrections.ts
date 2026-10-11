/*
 * Normalization rules (SPEC §3) that the schema cannot express, as corrections: every transaction
 * that changes the document is corrected before it applies, so the editor document stays normalized.
 *
 * The schema covers the structural rules: lists hold only list items, tables only rows, rows only
 * cells, code blocks only text and line breaks, one link and one style per character, and no
 * format or style on `br` and `img`.
 */
import { type ChangeSet, Leaf, type Mark, Node } from '../core/doc'
import { Correction } from '../core/state'
import * as T from '../core/types'
import { compareNames } from '../document/tree'
import { Attrs, type Pairs } from './attributes'
import * as S from './schema'

const isList = (node: Node) => node.type === T.BulletList.type || node.type === T.OrderedList
const attrsOf = (node: Node) => (node.marks.find(mark => mark.type === Attrs)?.value as Pairs | undefined) ?? []

/**
 * §3.2: adjacent lists of the same kind form one list. The merged list keeps the first list's tag
 * (its `start` and attributes) and adds attributes that only a later list has. Where both lists
 * have an attribute, the first list's value wins: an edit cannot be refused as N refuses the source.
 */
export const mergeAdjacentLists = Correction.onChildList(Node.Group.All, container => {
  const changes: ChangeSet.Spec[] = []
  let pos = container.start
  let run: { pos: number; attrs: Map<string, string>; added: boolean } | null = null
  const flush = () => {
    if (run?.added) {
      const merged = [...run.attrs].sort(([a], [b]) => compareNames(a, b))
      changes.push({ from: run.pos, add: Attrs.of(merged) })
    }
  }
  let previous: Node | null = null
  for (const child of container.node.content) {
    if (previous && run && isList(child) && child.type === previous.type) {
      // Delete the closing token of the list before and the opening token of this one.
      changes.push({ from: pos - 1, to: pos + 1 })
      for (const [name, value] of attrsOf(child)) {
        if (!run.attrs.has(name)) {
          run.attrs.set(name, value)
          run.added = true
        }
      }
    } else {
      flush()
      run = isList(child) ? { pos, attrs: new Map(attrsOf(child)), added: false } : null
    }
    previous = child
    pos += child.length
  }
  flush()
  return changes.length ? changes : null
})

/** §3.1: colspan="1" and rowspan="1" are the default and are removed. */
export const dropDefaultSpans = Correction.onMarks(Node.Group.TableCell, cell => {
  const changes: ChangeSet.Spec[] = []
  for (const mark of cell.node.marks) {
    if ((mark.type === T.ColSpan || mark.type === T.RowSpan) && mark.value === 1) {
      changes.push({ from: cell.before, remove: mark })
    }
  }
  return changes.length ? changes : null
})

// §3.1: an empty value of these attributes equals a missing attribute.
const optionalText = new Set<unknown>([
  S.TextStyle,
  S.BlockStyle,
  T.ImageAlt,
  S.ImageTitle,
  T.CodeBlockLanguage,
  S.CodeMeta
])

/**
 * §3.1: known attribute values must match the vocabulary. Mark values created by commands are not
 * validated by the core, so they are checked here. An invalid or empty optional value is removed;
 * spans are limited to 1–9999.
 */
export const vocabularyValues = Correction.onMarks(Node.Group.All, node => {
  const changes: ChangeSet.Spec[] = []
  for (const mark of node.node.marks) {
    let valid = true
    const validate = mark.type.spec.validate
    if (typeof validate === 'function') {
      try {
        validate(mark.value)
      } catch {
        valid = false
      }
    }
    if ((mark.type === T.ColSpan || mark.type === T.RowSpan) && !((mark.value as number) <= 9999)) valid = false
    if (optionalText.has(mark.type) && mark.value === '') valid = false
    if (!valid) changes.push({ from: node.before, remove: mark as Mark })
  }
  return changes.length ? changes : null
})

// §2: a code block holds plain text. Formats, styles and links that edits put on its content are removed:
// on content that enters the code block, and on marks added to content already in it.
export const plainCode = Correction.onContent(T.CodeBlock, block => {
  const changes: ChangeSet.Spec[] = []
  let pos = block.start
  for (const child of block.node.content) {
    for (const mark of child.marks) changes.push({ from: pos, to: pos + child.length, remove: mark })
    pos += child.length
  }
  return changes.length ? changes : null
})

export const plainCodeMarks = Correction.onMarks([Leaf.Text, T.LineBreak], leaf => {
  if (leaf.parent?.node.type !== T.CodeBlock.type || !leaf.node.marks.length) return null
  return leaf.node.marks.map(mark => ({ from: leaf.before, to: leaf.after, remove: mark }))
})

export const pageCorrections = [mergeAdjacentLists, dropDefaultSpans, vocabularyValues, plainCode, plainCodeMarks]

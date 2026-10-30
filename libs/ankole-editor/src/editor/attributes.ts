/*
 * Attributes in the editor document. Vocabulary attributes are typed marks; attributes outside the
 * vocabulary go into one `Attrs` mark per node. Block definitions use these helpers to convert their
 * own elements.
 */
import { type ChangeSet, Leaf, Mark, type Node, type Plot, ValidationError } from '../core/doc'
import * as T from '../core/types'
import { compareNames } from '../document/tree'
import { vocabulary } from '../document/vocabulary'

/** Editor marks and XML use the same attribute value grammar. */
export function attributeValue(element: string, name: string, numeric = false) {
  const pattern = vocabulary[element]!.attributes[name]
  return (value: unknown) => {
    const validType = numeric ? typeof value === 'number' && Number.isInteger(value) : typeof value === 'string'
    if (!validType || (pattern && !pattern.test(String(value)))) {
      throw new ValidationError(`Invalid ${element} attribute ${name}`)
    }
  }
}

/** Attributes as [name, value] pairs, sorted by Unicode code point, names unique. */
export type Pairs = readonly (readonly [string, string])[]

/**
 * The core compares parameters and mark values key by key with `in`, so for a plain object an
 * inherited name such as `constructor` counts as present. Attribute names in a page are free-form,
 * so attributes are stored as pairs, which compare exactly.
 */
export function checkPairs(value: unknown, required?: string) {
  if (!Array.isArray(value) || !value.length) throw new ValidationError('Expected a non-empty array of attribute pairs')
  let previous: string | null = null
  for (const pair of value) {
    if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== 'string' || typeof pair[1] !== 'string') {
      throw new ValidationError('Expected [name, value] string pairs')
    }
    if (previous !== null && compareNames(previous, pair[0]) >= 0) {
      throw new ValidationError('Attribute pairs must be sorted and unique')
    }
    previous = pair[0]
  }
  if (required && !value.some(pair => pair[0] === required)) {
    throw new ValidationError(`Missing required attribute ${required}`)
  }
}

/**
 * Attributes outside the vocabulary on a known element. Kept on type change, dropped on split,
 * never rendered. Block definitions add their node types to the targets.
 */
export const Attrs = Mark.Type.define<Pairs>('Attrs', {
  target: [T.Paragraph, T.Heading, T.BulletList, T.OrderedList, T.CodeBlock, T.HorizontalRule, T.Image, T.LineBreak],
  keepOnTypeChange: true,
  validate: value => checkPairs(value),
  shape: { attributes: () => ({}) }
})

export function markSet(marks: (Mark | null | undefined | false | '')[]): Mark.Set {
  let set: Mark.Set = Mark.none
  for (const mark of marks) if (mark) set = mark.addToSet(set)
  return set
}

export function pairsOf(attrs: Record<string, string>, skip: readonly string[] = []): Pairs {
  return Object.entries(attrs)
    .filter(([name]) => !skip.includes(name))
    .sort(([a], [b]) => compareNames(a, b))
    .map(([name, value]) => [name, value] as const)
}

/** An `Attrs` mark for the attributes outside `known`, or null when there are none. */
export function extraAttrs(attrs: Record<string, string>, known: readonly string[] = []): Mark | null {
  const pairs = pairsOf(attrs, known)
  return pairs.length ? Attrs.of(pairs) : null
}

// Object.fromEntries keeps names such as __proto__ as own attributes.
export const recordOf = (pairs: Pairs | undefined): Record<string, string> => Object.fromEntries(pairs ?? [])

/** The attributes outside the vocabulary of a node. */
export function extraOf(node: Node | Plot.Tag): Record<string, string> {
  return recordOf(node.marks.find(mark => mark.type === Attrs)?.value as Pairs | undefined)
}

export const markValue = <V>(node: Node | Plot.Tag, type: Mark.Type<V>) =>
  node.marks.find(mark => mark.type === type)?.value as V | undefined

/** Changes that set `type` on the block at `pos` to `value`, or remove `type` when `value` is null. */
export function markChange<V>(
  node: Node | null | undefined,
  pos: number,
  type: Mark.Type<V>,
  value: V | null
): ChangeSet.Spec | undefined {
  if (!node) return undefined
  const current = node.mark(type)
  if (value === null) return current === undefined ? undefined : { from: pos, remove: type.of(current) }
  return current === value ? undefined : { from: pos, add: type.of(value) }
}

/**
 * Inline leaves for a code-role block: `\n` becomes a `LineBreak` leaf, while `\r` stays in the
 * text leaf so XML `&#13;` round-trips.
 */
export function codeNodes(value: string, marks: Mark.Set = Mark.none): Node[] {
  const result: Node[] = []
  value.split('\n').forEach((line, index) => {
    if (index) result.push(T.LineBreak.withMarks(marks))
    if (line) result.push(Leaf.text(line, marks))
  })
  return result
}

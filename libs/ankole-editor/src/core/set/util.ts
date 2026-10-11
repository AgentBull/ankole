import { ChangeSet } from '../doc'

/**
 * Perform a binary search on the given array (starting at start) and
 * return the index of the first element > n (or the length if no
 * such element exists) @hidden
 */
export function findAbove(array: readonly number[], start: number, n: number) {
  let from = start,
    to = array.length
  for (;;) {
    if (from == to) return from
    const mid = (from + to) >> 1
    if (array[mid]! > n) to = mid
    else from = mid + 1
  }
}

export function addReplacements(changes: ChangeSet, replace: readonly { from: number; to: number }[]) {
  const add: number[] = []
  let at = 0
  const len = changes.newLength
  for (const repl of replace) {
    if (repl.from < at) throw new Error('Replacing ranges must be ordered and non-overlapping')
    if (repl.to > len) throw new Error('Replacing range out of bounds')
    if (repl.from > at) add.push(repl.from - at, -1)
    add.push(repl.to - repl.from, repl.to - repl.from)
    at = repl.to
  }
  if (len > at) add.push(len - at, -1)
  return ChangeSet.composeSections(changes.sections, add)
}

/** Locale-independent lexical ordering by Unicode scalar value. */
export function compareCodePointStrings(left: string, right: string): number {
  const leftIterator = left[Symbol.iterator]()
  const rightIterator = right[Symbol.iterator]()

  while (true) {
    const leftValue = leftIterator.next()
    const rightValue = rightIterator.next()
    if (leftValue.done || rightValue.done) {
      if (leftValue.done && rightValue.done) return 0
      return leftValue.done ? -1 : 1
    }

    const difference = leftValue.value.codePointAt(0)! - rightValue.value.codePointAt(0)!
    if (difference !== 0) return difference
  }
}

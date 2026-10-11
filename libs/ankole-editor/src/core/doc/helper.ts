export type DOMElement = Element

export const none: readonly any[] = []

export function compareDeep(a: any, b: any) {
  if (a === b) return true
  if (!a || !b || typeof a != 'object' || typeof b != 'object') return false
  const array = Array.isArray(a)
  if (Array.isArray(b) != array) return false
  if (array) {
    if (a.length != b.length) return false
    for (let i = 0; i < a.length; i++) if (!compareDeep(a[i], b[i])) return false
  } else {
    for (const p in a) if (!(p in b) || !compareDeep(a[p], b[p])) return false
    for (const p in b) if (!(p in a)) return false
  }
  return true
}

export function eqArray<T extends { eq: (other: T) => boolean }>(a: readonly T[], b: readonly T[]) {
  if (a == b) return true
  if (a.length != b.length) return false
  for (let i = 0; i < a.length; i++) if (!a[i]!.eq(b[i]!)) return false
  return true
}

export function validate<T>(validator: string | ((value: T) => void) | undefined, value: T) {
  if (typeof validator == 'string') {
    const types = validator.split('|')
    const name = value === null ? 'null' : typeof value
    if (types.indexOf(name) < 0) throw new RangeError(`Expected value of type ${validator} got ${name}`)
  } else if (validator) {
    validator(value)
  }
  return value
}

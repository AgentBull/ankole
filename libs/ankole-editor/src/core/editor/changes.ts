import { findAbove } from '../set'

// To represent changed ranges for tile tree updates, we use a format
// similar to the sections arrays used by ChangeSet, except that:
//
// - Zero-length updated ranges are allowed (redraw the content at
//   precisely that position).
// - Adjacent replaced ranges are merged.
// - Adjacent updated ranges are merged.
export type Changes = readonly number[]

// Add a set of updated ranges to a set of sections. `sections` is in
// section format. `updated` contains pairs of start/end positions
// referring to positions in the start document.
export function addUpdated(sections: Changes, updated: readonly number[]) {
  const result: number[] = []
  let j = 0,
    [uFrom, uTo] = updated.length ? [updated[j++], updated[j++]] : [1e9, 1e9]
  for (let i = 0, pos = 0; i < sections.length;) {
    const len = sections[i++]!,
      ins = sections[i++]!
    if (ins == -1) {
      const end = pos + len
      while (uFrom! < end) {
        if (uTo! > pos) {
          if (uFrom! > pos) addSection(result, uFrom! - pos, -1)
          addSection(result, Math.min(uTo!, end) - Math.max(pos, uFrom!), -2)
          pos = uTo!
        }
        if (uTo! >= end) break
        if (j == updated.length) {
          uFrom = uTo = 1e9
          break
        }
        uFrom = updated[j++]
        uTo = updated[j++]
      }
      if (pos < end) addSection(result, end - pos, -1)
      pos = end
    } else {
      addSection(result, len, ins)
      pos += len
    }
  }
  return result
}

export function addSection(sections: number[], len: number, ins: number) {
  const last = sections.length - 1
  if (last >= 0) {
    const lastIns = sections[last]!
    if (lastIns >= 0 && ins >= 0) {
      sections[last - 1]! += len
      sections[last]! += ins
      return
    }
    if (lastIns < 0 && lastIns == ins) {
      sections[last - 1]! += len
      return
    }
  }
  sections.push(len, ins)
}

// Change the given sections to make sure that the given range gets
// its replacement section, so that the tile update loop can handle it
// separately from surrounding changes.
export function separateChange(changes: Changes, fromB: number, toB: number) {
  const result: number[] = []
  let lenI = 0,
    dLen = 0
  for (let posB = 0, done = false, i = 0; i < changes.length;) {
    const len = changes[i++]!,
      ins = changes[i++]!,
      endB = posB + (ins < 0 ? len : ins)!
    if (fromB >= endB || toB <= posB) {
      result.push(len, ins)
    } else {
      if (ins >= 0) {
        if (posB < fromB || endB > toB) return null
        dLen += len - ins
      }
      if (posB < fromB) result.push(fromB - posB, ins)
      if (!done) {
        lenI = result.length
        result.push(0, toB - fromB)
        done = true
      }
      if (endB > toB) result.push(endB - toB, ins)
    }
    posB = endB
  }
  result[lenI] = toB - fromB + dLen
  return result
}

export function isEmpty(changes: Changes) {
  return changes.length == 0 || (changes.length == 2 && changes[1] == -1)
}

// Add the given range to a set of ranges, represented as a flat array
// of number where each adjacent pair is a [from, to] range.
export function addRange(ranges: number[], from: number, to: number) {
  const last = ranges.at(-1)
  if (last === undefined || last < from) {
    ranges.push(from, to)
  } else if (last == from) {
    ranges[ranges.length - 1] = to
  } else {
    let i = findAbove(ranges, 0, from) & ~1,
      j = i
    if (j && ranges[j - 1] == from) {
      j -= 2
      from = ranges[j]!
    }
    while (i < ranges.length && ranges[i]! <= to) {
      from = Math.min(from, ranges[i++]!)
      to = Math.max(to, ranges[i++]!)
    }
    ranges.splice(j, i - j, from, to)
  }
}

// Join multiple sets of ordered ranges into a single set
export function joinRanges(ranges: number[][]) {
  if (ranges.length == 1) return ranges[0]
  const result: number[] = [],
    index = ranges.map(() => 0)
  for (;;) {
    let minI = -1,
      minFrom = -1
    for (let i = 0; i < ranges.length; i++) {
      const idx = index[i]!,
        set = ranges[i]!
      if (idx < set.length && (minI < 0 || set[idx!]! < minFrom)) {
        minI = i
        minFrom = set[idx!]!
      }
    }
    if (minI < 0) return result
    const idx = index[minI]!,
      set = ranges[minI]!
    addRange(result, set[idx!]!, set[idx + 1]!)
    index[minI]! += 2
  }
}

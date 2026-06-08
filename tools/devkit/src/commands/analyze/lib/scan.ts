// Source-reference extraction for the `smells` boundary checks.
// Ported (min-change) from the parts of openclaw's guard-inventory-utils.mjs
// that the architecture-smell scan needs: a regex import/export scanner with
// comment/string masking, plus relative-specifier resolution. File walking is
// handled by `collectSourceFiles` in ./import-cycle-graph.ts (no second walker).

import path from 'node:path'

export type ModuleReferenceKind = 'import' | 'export' | 'dynamic-import'

export interface ModuleReference {
  kind: ModuleReferenceKind
  line: number
  specifier: string
}

/**
 * Resolve a relative specifier ('./x', '../y') against the importer's
 * repo-root-relative POSIX path, returning a repo-root-relative POSIX path.
 * Returns null for bare/absolute specifiers — boundary rules match those as raw
 * specifier strings, not resolved paths.
 */
export function resolveRelativeSpecifier(importerRepoPath: string, specifier: string): string | null {
  if (!specifier.startsWith('.')) {
    return null
  }
  return path.posix.normalize(path.posix.join(path.posix.dirname(importerRepoPath), specifier))
}

export function collectModuleReferencesFromSource(source: string): ModuleReference[] {
  const lineStarts = computeLineStarts(source)
  const isCodePosition = createCodePositionChecker(source)
  const references: ModuleReference[] = []
  const push = (kind: ModuleReferenceKind, specifier: string, position: number, syntaxPosition: number) => {
    if (!isCodePosition(syntaxPosition)) {
      return
    }
    references.push({ kind, line: lineFromPosition(lineStarts, position), specifier })
  }

  for (const match of source.matchAll(/\bimport\s*\(\s*(["'])([^"']+)\1/g)) {
    push('dynamic-import', match[2]!, match.index + match[0].lastIndexOf(match[1]!), match.index)
  }
  for (const match of source.matchAll(/^\s*import\s*(["'])([^"']+)\1/gm)) {
    push('import', match[2]!, match.index + match[0].lastIndexOf(match[1]!), match.index + match[0].indexOf('import'))
  }
  for (const match of source.matchAll(/^\s*(import|export)\s+(?:type\s+)?[^;"']*?\bfrom\s*(["'])([^"']+)\2/gm)) {
    push(
      match[1] as ModuleReferenceKind,
      match[3]!,
      match.index + match[0].lastIndexOf(match[2]!),
      match.index + match[0].indexOf(match[1]!)
    )
  }

  return references.toSorted(
    (left, right) =>
      left.line - right.line || left.kind.localeCompare(right.kind) || left.specifier.localeCompare(right.specifier)
  )
}

/**
 * Build a predicate that reports whether a byte offset sits in real code (not
 * inside a line comment, block comment, or string/template literal). Lets the
 * regex scanner ignore `import`-looking text in comments and strings.
 */
function createCodePositionChecker(source: string): (position: number) => boolean {
  const codePositions = new Uint8Array(source.length)

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index]
    const next = source[index + 1]

    if (char === '/' && next === '/') {
      index += 2
      while (index < source.length && source.charCodeAt(index) !== 10) {
        index += 1
      }
      index -= 1
      continue
    }

    if (char === '/' && next === '*') {
      index += 2
      while (index < source.length && !(source[index] === '*' && source[index + 1] === '/')) {
        index += 1
      }
      index += 1
      continue
    }

    if (char === "'" || char === '"' || char === '`') {
      const quote = char
      index += 1
      while (index < source.length) {
        if (source[index] === '\\') {
          index += 2
          continue
        }
        if (source[index] === quote) {
          break
        }
        index += 1
      }
      continue
    }

    codePositions[index] = 1
  }

  return position => codePositions[position] === 1
}

function computeLineStarts(source: string): number[] {
  const lineStarts = [0]
  for (let index = 0; index < source.length; index += 1) {
    if (source.charCodeAt(index) === 10) {
      lineStarts.push(index + 1)
    }
  }
  return lineStarts
}

function lineFromPosition(lineStarts: readonly number[], position: number): number {
  let low = 0
  let high = lineStarts.length - 1
  while (low <= high) {
    const middle = Math.floor((low + high) / 2)
    if (lineStarts[middle]! <= position) {
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  return high + 1
}

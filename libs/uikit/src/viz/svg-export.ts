import { SaxesParser } from 'saxes'
import { buildPaletteTokenLookup, buildPeleTokenMap, type VizThemePalette } from './theme'

export interface ExportedSvgArtifact {
  svg: string
  width: number
  height: number
  isPrintSafe: boolean
}

export interface MaterializePeleSvgOptions {
  width?: number
  height?: number
  safetyPaddingPx?: number
  injectBackgroundRect?: boolean
  extraTokens?: Readonly<Record<string, string>>
}

export interface FinalizeExportedSvgOptions {
  safetyPaddingPx?: number
  cardFrame?: boolean
  fallbackWidth?: number
  fallbackHeight?: number
  width?: number
  height?: number
  synchronizeDimensions?: boolean
  injectBackgroundRect?: boolean
  promoteCssRx?: boolean
  stripCustomProperties?: boolean
  includePeleTokens?: boolean
  extraTokens?: Readonly<Record<string, string>>
}

interface SvgXmlText {
  type: 'text'
  value: string
}

interface SvgXmlElement {
  type: 'element'
  name: string
  attrs: Record<string, string>
  children: SvgXmlNode[]
}

type SvgXmlNode = SvgXmlText | SvgXmlElement

interface ParsedSvgDocument {
  root: SvgXmlElement | null
  wellFormed: boolean
  hasUnsafePreliminaries: boolean
  usesXlinkPrefix: boolean
}

interface PropScope {
  rawDecls: Record<string, string>
  resolvedCache: Map<string, string | null>
  parent: PropScope | null
}

const PELE_INTERNAL_SYMBOLIC_DEFAULTS: Readonly<Record<string, string>> = {
  '--_bg': 'var(--pele-bg)',
  '--_fg': 'var(--pele-fg)',
  '--_m': 'var(--pele-muted)',
  '--_l': 'var(--pele-line)',
  '--_s': 'var(--pele-surface)',
  '--_a': 'var(--pele-surface-alt)',
  '--_b': 'var(--pele-border)',
  '--_c': 'var(--pele-accent)',
  '--_r': 'var(--pele-radius)',
  '--_fm': 'var(--pele-font-mono)',
  '--_hw': 'var(--pele-header-weight, bold)',
  '--_tw': 'var(--pele-title-weight, bold)',
  '--_w': 'var(--pele-weight, bold)'
}

const NON_CSS_METADATA_ATTRS = new Set([
  'xmlns',
  'id',
  'class',
  'role',
  'tabindex',
  'lang',
  'xml:lang',
  'xml:space',
  'xml:id',
  'version',
  'baseprofile',
  'preserveaspectratio',
  'viewbox'
])

function localTagOrAttrName(qualifiedName: string): string {
  const colonIdx = qualifiedName.indexOf(':')
  return (colonIdx === -1 ? qualifiedName : qualifiedName.slice(colonIdx + 1)).toLowerCase()
}

function isNonCssMetadataAttr(attrName: string): boolean {
  const lower = attrName.toLowerCase()
  if (NON_CSS_METADATA_ATTRS.has(lower)) return true
  return lower.startsWith('xmlns:') || lower.startsWith('aria-') || lower.startsWith('data-')
}

function isResourceUriAttr(attrName: string): boolean {
  const local = localTagOrAttrName(attrName)
  return local === 'href' || local === 'src'
}

function isCssSpace(code: number): boolean {
  return code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d || code === 0x0c
}

function isIdentChar(code: number): boolean {
  return (
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    code === 0x2d ||
    code === 0x5f ||
    code > 0x7f
  )
}

function isValidCustomPropName(name: string): boolean {
  if (name.length < 3 || !name.startsWith('--')) return false
  for (let i = 2; i < name.length; i += 1) {
    if (!isIdentChar(name.charCodeAt(i))) return false
  }
  return true
}

function matchAsciiWordIgnoreCase(source: string, pos: number, lowerWord: string): boolean {
  if (pos + lowerWord.length > source.length) return false
  for (let i = 0; i < lowerWord.length; i += 1) {
    let code = source.charCodeAt(pos + i)
    if (code >= 0x41 && code <= 0x5a) code += 0x20
    if (code !== lowerWord.charCodeAt(i)) return false
  }
  return true
}

function skipSpacesAndComments(source: string, start: number, end = source.length): number {
  let pos = start
  while (pos < end) {
    if (isCssSpace(source.charCodeAt(pos))) {
      pos += 1
      continue
    }
    if (source.charCodeAt(pos) === 0x2f && source.charCodeAt(pos + 1) === 0x2a) {
      const closeIdx = source.indexOf('*/', pos + 2)
      pos = closeIdx === -1 || closeIdx + 2 > end ? end : closeIdx + 2
      continue
    }
    break
  }
  return pos
}

function skipQuotedString(source: string, quoteStart: number, end = source.length): number {
  const quote = source.charCodeAt(quoteStart)
  let pos = quoteStart + 1
  while (pos < end) {
    const code = source.charCodeAt(pos)
    if (code === 0x5c) {
      pos = Math.min(end, pos + 2)
      continue
    }
    pos += 1
    if (code === quote) break
  }
  return pos
}

function readQuotedStringContent(
  source: string,
  quoteStart: number,
  end = source.length
): { value: string; nextPos: number } {
  const quote = source.charCodeAt(quoteStart)
  let out = ''
  let pos = quoteStart + 1
  while (pos < end) {
    const code = source.charCodeAt(pos)
    if (code === 0x5c && pos + 1 < end) {
      out += source[pos + 1]!
      pos += 2
      continue
    }
    if (code === quote) {
      pos += 1
      break
    }
    out += source[pos]!
    pos += 1
  }
  return { value: out, nextPos: pos }
}

function isExternalUrlTarget(rawTarget: string): boolean {
  let start = 0
  let end = rawTarget.length
  while (start < end && rawTarget.charCodeAt(start) <= 0x20) start += 1
  while (end > start && rawTarget.charCodeAt(end - 1) <= 0x20) end -= 1
  if (start >= end) return false
  const trimmedLower = rawTarget.slice(start, Math.min(end, start + 10)).toLowerCase()
  return trimmedLower.startsWith('http://') || trimmedLower.startsWith('https://') || trimmedLower.startsWith('//')
}

interface CssDeclarationEntry {
  kind: 'pair' | 'raw'
  name: string
  value: string
  important: boolean
}

function stripOuterCssCommentsAndTrim(raw: string): string {
  const start = skipSpacesAndComments(raw, 0, raw.length)
  let end = raw.length
  while (end > start && isCssSpace(raw.charCodeAt(end - 1))) end -= 1
  return raw.slice(start, end)
}

function splitImportantSuffix(rawValue: string): { value: string; important: boolean } {
  let end = rawValue.length
  while (end > 0 && isCssSpace(rawValue.charCodeAt(end - 1))) end -= 1
  if (end < 10) return { value: rawValue, important: false }
  const wordStart = end - 9
  if (!matchAsciiWordIgnoreCase(rawValue, wordStart, 'important')) {
    return { value: rawValue, important: false }
  }
  let bangScan = wordStart
  while (bangScan > 0 && isCssSpace(rawValue.charCodeAt(bangScan - 1))) bangScan -= 1
  if (bangScan === 0 || rawValue.charCodeAt(bangScan - 1) !== 0x21) {
    return { value: rawValue, important: false }
  }
  return {
    value: stripOuterCssCommentsAndTrim(rawValue.slice(0, bangScan - 1)),
    important: true
  }
}

function splitCssDeclarations(styleText: string): CssDeclarationEntry[] {
  const entries: CssDeclarationEntry[] = []
  let pos = 0
  let declStart = 0
  let colonAt = -1
  let parenDepth = 0

  const flush = (declEnd: number) => {
    if (colonAt !== -1) {
      const name = stripOuterCssCommentsAndTrim(styleText.slice(declStart, colonAt))
      const rawValue = stripOuterCssCommentsAndTrim(styleText.slice(colonAt + 1, declEnd))
      if (name) {
        const { value, important } = splitImportantSuffix(rawValue)
        entries.push({ kind: 'pair', name, value, important })
      }
    } else {
      const raw = stripOuterCssCommentsAndTrim(styleText.slice(declStart, declEnd))
      if (raw) {
        entries.push({ kind: 'raw', name: '', value: raw, important: false })
      }
    }
  }

  while (pos < styleText.length) {
    const code = styleText.charCodeAt(pos)
    if (code === 0x2f && styleText.charCodeAt(pos + 1) === 0x2a) {
      const closeIdx = styleText.indexOf('*/', pos + 2)
      pos = closeIdx === -1 ? styleText.length : closeIdx + 2
      continue
    }
    if (code === 0x27 || code === 0x22) {
      pos = skipQuotedString(styleText, pos)
      continue
    }
    if (code === 0x28) {
      parenDepth += 1
      pos += 1
      continue
    }
    if (code === 0x29) {
      if (parenDepth > 0) parenDepth -= 1
      pos += 1
      continue
    }
    if (parenDepth === 0 && code === 0x3a && colonAt === -1) {
      colonAt = pos
      pos += 1
      continue
    }
    if (parenDepth === 0 && code === 0x3b) {
      flush(pos)
      pos += 1
      declStart = pos
      colonAt = -1
      continue
    }
    pos += 1
  }

  flush(styleText.length)
  return entries
}

/**
 * Collapses duplicate property declarations within one declaration block according to CSS
 * cascade order (`!important` beats normal; later declaration wins among equal importance;
 * custom property names stay case-sensitive while standard CSS properties fold to lowercase).
 */
function selectWinningStyleDeclarations(entries: readonly CssDeclarationEntry[]): {
  effectiveEntries: CssDeclarationEntry[]
  customDecls: Record<string, string> | null
} {
  const winningIndexByKey = new Map<string, { index: number; important: boolean }>()
  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i]!
    if (entry.kind !== 'pair') continue
    const key = isValidCustomPropName(entry.name) ? entry.name : entry.name.toLowerCase()
    const prev = winningIndexByKey.get(key)
    if (!prev || entry.important || !prev.important) {
      winningIndexByKey.set(key, { index: i, important: entry.important })
    }
  }

  const winningIndices = new Set<number>()
  for (const { index } of winningIndexByKey.values()) {
    winningIndices.add(index)
  }

  const effectiveEntries: CssDeclarationEntry[] = []
  let customDecls: Record<string, string> | null = null
  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i]!
    if (entry.kind === 'raw') {
      effectiveEntries.push(entry)
      continue
    }
    if (!winningIndices.has(i)) continue
    effectiveEntries.push(entry)
    if (isValidCustomPropName(entry.name)) {
      customDecls ??= {}
      customDecls[entry.name] = entry.value
    }
  }

  return { effectiveEntries, customDecls }
}

type CssResolveFrame =
  | { kind: 'root'; out: string; hasUnresolvedVar: boolean }
  | { kind: 'paren'; out: string; hasUnresolvedVar: boolean }
  | { kind: 'var-name'; rawPrefix: string; nameBuf: string; hasUnresolvedVar: boolean }
  | { kind: 'var-fallback'; rawPrefix: string; propName: string; fbOut: string; hasUnresolvedVar: boolean }

function appendToResolveFrame(frame: CssResolveFrame, chunk: string): void {
  if (!chunk) return
  if (frame.kind === 'var-name') {
    frame.nameBuf += chunk
  } else if (frame.kind === 'var-fallback') {
    frame.fbOut += chunk
  } else {
    frame.out += chunk
  }
}

function frameTrailingSpaceSafe(frame: CssResolveFrame): boolean {
  const buf = frame.kind === 'var-name' ? frame.nameBuf : frame.kind === 'var-fallback' ? frame.fbOut : frame.out
  if (buf.length === 0) return true
  const last = buf.charCodeAt(buf.length - 1)
  return isCssSpace(last) || last === 0x28 || last === 0x2c || last === 0x3a || last === 0x3b || last === 0x7b
}

/**
 * Single-pass explicit-stack `var(...)` resolver. Visits each character of `raw` at most once
 * in O(n) time and tracks unresolved `var(--...)` references directly on the stack frame.
 */
function resolveCssValue(
  raw: string,
  lookupProp: (name: string) => string | undefined
): { value: string; hasUnresolvedVar: boolean } {
  const stack: CssResolveFrame[] = [{ kind: 'root', out: '', hasUnresolvedVar: false }]
  let pos = 0

  while (pos < raw.length) {
    const top = stack[stack.length - 1]!
    const code = raw.charCodeAt(pos)

    if (code === 0x2f && raw.charCodeAt(pos + 1) === 0x2a) {
      const closeIdx = raw.indexOf('*/', pos + 2)
      pos = closeIdx === -1 ? raw.length : closeIdx + 2
      if (top.kind !== 'var-name' && !frameTrailingSpaceSafe(top)) {
        appendToResolveFrame(top, ' ')
      }
      continue
    }

    if (code === 0x27 || code === 0x22) {
      const nextPos = skipQuotedString(raw, pos)
      appendToResolveFrame(top, raw.slice(pos, nextPos))
      pos = nextPos
      continue
    }

    if (top.kind === 'var-name') {
      if (code === 0x2c) {
        const propName = top.nameBuf.trim()
        stack[stack.length - 1] = {
          kind: 'var-fallback',
          rawPrefix: `${top.rawPrefix}${top.nameBuf},`,
          propName,
          fbOut: '',
          hasUnresolvedVar: false
        }
        pos += 1
        continue
      }
      if (code === 0x29) {
        const propName = top.nameBuf.trim()
        stack.pop()
        pos += 1
        const parent = stack[stack.length - 1]!
        const resolved = isValidCustomPropName(propName) ? lookupProp(propName) : undefined
        if (resolved !== undefined) {
          appendToResolveFrame(parent, resolved)
        } else {
          appendToResolveFrame(parent, `${top.rawPrefix}${top.nameBuf})`)
          if (propName.startsWith('--') || top.hasUnresolvedVar) {
            parent.hasUnresolvedVar = true
          }
        }
        continue
      }
      if (code === 0x28) {
        stack.push({ kind: 'paren', out: '', hasUnresolvedVar: false })
        pos += 1
        continue
      }
      top.nameBuf += raw[pos]!
      pos += 1
      continue
    }

    if (code === 0x29 && top.kind !== 'root') {
      stack.pop()
      pos += 1
      const parent = stack[stack.length - 1]!
      if (top.kind === 'paren') {
        appendToResolveFrame(parent, `(${top.out})`)
        if (top.hasUnresolvedVar) parent.hasUnresolvedVar = true
      } else {
        const resolved = isValidCustomPropName(top.propName) ? lookupProp(top.propName) : undefined
        if (resolved !== undefined) {
          appendToResolveFrame(parent, resolved)
        } else if (!top.hasUnresolvedVar) {
          appendToResolveFrame(parent, top.fbOut.trim())
        } else {
          appendToResolveFrame(parent, `${top.rawPrefix}${top.fbOut})`)
          parent.hasUnresolvedVar = true
        }
      }
      continue
    }

    if (matchAsciiWordIgnoreCase(raw, pos, 'var(') && (pos === 0 || !isIdentChar(raw.charCodeAt(pos - 1)))) {
      stack.push({
        kind: 'var-name',
        rawPrefix: raw.slice(pos, pos + 4),
        nameBuf: '',
        hasUnresolvedVar: false
      })
      pos += 4
      continue
    }

    if (code === 0x28) {
      stack.push({ kind: 'paren', out: '', hasUnresolvedVar: false })
      pos += 1
      continue
    }

    appendToResolveFrame(top, raw[pos]!)
    pos += 1
  }

  while (stack.length > 1) {
    const unclosed = stack.pop()!
    const parent = stack[stack.length - 1]!
    if (unclosed.kind === 'paren') {
      appendToResolveFrame(parent, `(${unclosed.out}`)
      if (unclosed.hasUnresolvedVar) parent.hasUnresolvedVar = true
    } else if (unclosed.kind === 'var-name') {
      appendToResolveFrame(parent, `${unclosed.rawPrefix}${unclosed.nameBuf}`)
      if (unclosed.nameBuf.trimStart().startsWith('--') || unclosed.hasUnresolvedVar) {
        parent.hasUnresolvedVar = true
      }
    } else if (unclosed.kind === 'var-fallback') {
      appendToResolveFrame(parent, `${unclosed.rawPrefix}${unclosed.fbOut}`)
      if (unclosed.propName.startsWith('--') || unclosed.hasUnresolvedVar) {
        parent.hasUnresolvedVar = true
      }
    }
  }

  const rootFrame = stack[0] as { kind: 'root'; out: string; hasUnresolvedVar: boolean }
  return { value: rootFrame.out, hasUnresolvedVar: rootFrame.hasUnresolvedVar }
}

function lookupScopedProperty(scope: PropScope | null, propName: string, visiting: Set<string>): string | undefined {
  let cursor = scope
  while (cursor && !Object.hasOwn(cursor.rawDecls, propName)) {
    cursor = cursor.parent
  }
  if (!cursor) return undefined

  if (cursor.resolvedCache.has(propName)) {
    const cached = cursor.resolvedCache.get(propName)!
    return cached === null ? undefined : cached
  }

  if (visiting.has(propName)) {
    return undefined
  }

  visiting.add(propName)
  const ownerScope = cursor
  const { value, hasUnresolvedVar } = resolveCssValue(ownerScope.rawDecls[propName]!, refName =>
    lookupScopedProperty(ownerScope, refName, visiting)
  )
  visiting.delete(propName)

  const resolved = value.trim()
  if (hasUnresolvedVar) {
    if (visiting.size === 0) ownerScope.resolvedCache.set(propName, null)
    return undefined
  }

  if (visiting.size === 0) ownerScope.resolvedCache.set(propName, resolved)
  return resolved
}

function hasUnsafeCssConstruct(cssText: string): boolean {
  let pos = 0
  while (pos < cssText.length) {
    const code = cssText.charCodeAt(pos)

    if (code === 0x2f && cssText.charCodeAt(pos + 1) === 0x2a) {
      const closeIdx = cssText.indexOf('*/', pos + 2)
      pos = closeIdx === -1 ? cssText.length : closeIdx + 2
      continue
    }

    if (code === 0x27 || code === 0x22) {
      pos = skipQuotedString(cssText, pos)
      continue
    }

    if (code === 0x40 && matchAsciiWordIgnoreCase(cssText, pos, '@import')) {
      const nextAfterImport = pos + 7
      if (nextAfterImport >= cssText.length || !isIdentChar(cssText.charCodeAt(nextAfterImport))) {
        const targetPos = skipSpacesAndComments(cssText, nextAfterImport)
        const targetCode = cssText.charCodeAt(targetPos)
        if (targetCode === 0x27 || targetCode === 0x22) {
          const { value, nextPos } = readQuotedStringContent(cssText, targetPos)
          if (!value.trim().toLowerCase().startsWith('data:')) return true
          pos = nextPos
          continue
        }
        if (matchAsciiWordIgnoreCase(cssText, targetPos, 'url(')) {
          const innerPos = skipSpacesAndComments(cssText, targetPos + 4)
          const innerCode = cssText.charCodeAt(innerPos)
          if (innerCode === 0x27 || innerCode === 0x22) {
            const { value } = readQuotedStringContent(cssText, innerPos)
            if (!value.trim().toLowerCase().startsWith('data:')) return true
          } else {
            let endUnquoted = innerPos
            while (
              endUnquoted < cssText.length &&
              !isCssSpace(cssText.charCodeAt(endUnquoted)) &&
              cssText.charCodeAt(endUnquoted) !== 0x29
            ) {
              endUnquoted += 1
            }
            if (!cssText.slice(innerPos, endUnquoted).trim().toLowerCase().startsWith('data:')) return true
          }
        }
        pos = Math.max(nextAfterImport, targetPos)
        continue
      }
    }

    if (matchAsciiWordIgnoreCase(cssText, pos, 'var(') && (pos === 0 || !isIdentChar(cssText.charCodeAt(pos - 1)))) {
      const afterParen = skipSpacesAndComments(cssText, pos + 4)
      if (cssText.charCodeAt(afterParen) === 0x2d && cssText.charCodeAt(afterParen + 1) === 0x2d) {
        return true
      }
      pos = afterParen
      continue
    }

    if (matchAsciiWordIgnoreCase(cssText, pos, 'url(') && (pos === 0 || !isIdentChar(cssText.charCodeAt(pos - 1)))) {
      const targetPos = skipSpacesAndComments(cssText, pos + 4)
      const targetCode = cssText.charCodeAt(targetPos)
      if (targetCode === 0x27 || targetCode === 0x22) {
        const { value, nextPos } = readQuotedStringContent(cssText, targetPos)
        if (isExternalUrlTarget(value)) return true
        pos = nextPos
        continue
      }
      let endUnquoted = targetPos
      while (
        endUnquoted < cssText.length &&
        !isCssSpace(cssText.charCodeAt(endUnquoted)) &&
        cssText.charCodeAt(endUnquoted) !== 0x29 &&
        !(cssText.charCodeAt(endUnquoted) === 0x2f && cssText.charCodeAt(endUnquoted + 1) === 0x2a)
      ) {
        endUnquoted += 1
      }
      if (isExternalUrlTarget(cssText.slice(targetPos, endUnquoted))) return true
      pos = endUnquoted
      continue
    }

    pos += 1
  }
  return false
}

function isSvgTreePrintSafe(elem: SvgXmlElement): boolean {
  const localTag = localTagOrAttrName(elem.name)
  if (localTag === 'foreignobject' || localTag === 'script') return false

  for (const [attrName, attrVal] of Object.entries(elem.attrs)) {
    if (isNonCssMetadataAttr(attrName)) continue
    if (isResourceUriAttr(attrName)) {
      if (isExternalUrlTarget(attrVal)) return false
      continue
    }
    if (hasUnsafeCssConstruct(attrVal)) return false
  }

  if (localTag === 'style') {
    for (const child of elem.children) {
      if (child.type === 'text' && hasUnsafeCssConstruct(child.value)) return false
    }
    return true
  }

  for (const child of elem.children) {
    if (child.type === 'element' && !isSvgTreePrintSafe(child)) return false
  }
  return true
}

function selectorAppliesToSvgRoot(prelude: string): boolean {
  for (const rawPart of prelude.split(',')) {
    const sel = stripOuterCssCommentsAndTrim(rawPart).toLowerCase()
    if (sel === ':root' || sel === 'svg' || sel === '*' || sel === ':host') return true
  }
  return false
}

function extractStylesheetRootDecls(cssText: string, out: Record<string, string>): void {
  let pos = 0
  let preludeStart = 0
  let blockStart = -1
  let braceDepth = 0

  while (pos < cssText.length) {
    const code = cssText.charCodeAt(pos)
    if (code === 0x2f && cssText.charCodeAt(pos + 1) === 0x2a) {
      const closeIdx = cssText.indexOf('*/', pos + 2)
      pos = closeIdx === -1 ? cssText.length : closeIdx + 2
      continue
    }
    if (code === 0x27 || code === 0x22) {
      pos = skipQuotedString(cssText, pos)
      continue
    }
    if (code === 0x7b) {
      if (braceDepth === 0) blockStart = pos + 1
      braceDepth += 1
      pos += 1
      continue
    }
    if (code === 0x7d) {
      if (braceDepth === 1 && blockStart !== -1) {
        if (selectorAppliesToSvgRoot(cssText.slice(preludeStart, blockStart - 1))) {
          const { customDecls } = selectWinningStyleDeclarations(splitCssDeclarations(cssText.slice(blockStart, pos)))
          if (customDecls) Object.assign(out, customDecls)
        }
        blockStart = -1
        preludeStart = pos + 1
      }
      if (braceDepth > 0) braceDepth -= 1
      pos += 1
      continue
    }
    pos += 1
  }
}

function collectStyleElementsRootDecls(node: SvgXmlElement, out: Record<string, string>): void {
  if (localTagOrAttrName(node.name) === 'style') {
    const textContent = node.children.map(child => (child.type === 'text' ? child.value : '')).join('')
    if (textContent) extractStylesheetRootDecls(textContent, out)
    return
  }
  for (const child of node.children) {
    if (child.type === 'element') collectStyleElementsRootDecls(child, out)
  }
}

function parseNonNegativeLengthForSvgAttr(raw: string): string | null {
  let s = raw.trim()
  if (s.length >= 2 && s.slice(-2).toLowerCase() === 'px') {
    s = s.slice(0, -2).trim()
  }
  if (!s) return null
  let sawDigit = false
  let sawDot = false
  for (let i = 0; i < s.length; i += 1) {
    const code = s.charCodeAt(i)
    if (code >= 0x30 && code <= 0x39) {
      sawDigit = true
    } else if (code === 0x2e && !sawDot) {
      sawDot = true
    } else {
      return null
    }
  }
  return sawDigit ? s : null
}

function parseNumericSvgLength(raw: string | undefined): number | null {
  if (!raw) return null
  let s = raw.trim()
  if (s.length >= 2 && s.slice(-2).toLowerCase() === 'px') {
    s = s.slice(0, -2).trim()
  }
  if (!s) return null
  for (let i = 0; i < s.length; i += 1) {
    if (isCssSpace(s.charCodeAt(i))) return null
  }
  const num = Number(s)
  return Number.isFinite(num) ? num : null
}

function parseViewBoxNumbers(raw: string | undefined): [number, number, number, number] | null {
  if (!raw) return null
  const tokens: string[] = []
  let pos = 0
  while (pos < raw.length) {
    while (pos < raw.length && (isCssSpace(raw.charCodeAt(pos)) || raw.charCodeAt(pos) === 0x2c)) {
      pos += 1
    }
    if (pos >= raw.length) break
    const start = pos
    while (pos < raw.length && !isCssSpace(raw.charCodeAt(pos)) && raw.charCodeAt(pos) !== 0x2c) {
      pos += 1
    }
    tokens.push(raw.slice(start, pos))
    if (tokens.length > 4) return null
  }
  if (tokens.length !== 4) return null
  const x = Number(tokens[0]!)
  const y = Number(tokens[1]!)
  const w = Number(tokens[2]!)
  const h = Number(tokens[3]!)
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) return null
  return [x, y, w, h]
}

function parseSvgXmlDocument(source: string): ParsedSvgDocument {
  const trimmed = source.trim()
  if (!trimmed) {
    return { root: null, wellFormed: false, hasUnsafePreliminaries: false, usesXlinkPrefix: false }
  }

  const parser = new SaxesParser({ xmlns: false, defaultXMLVersion: '1.0', forceXMLVersion: true })
  const stack: SvgXmlElement[] = []
  let root: SvgXmlElement | null = null
  let rootCount = 0
  let wellFormed = true
  let hasUnsafePreliminaries = false
  let usesXlinkPrefix = false

  const addText = (value: string) => {
    const parent = stack[stack.length - 1]
    if (!parent || !value) return
    const last = parent.children[parent.children.length - 1]
    if (last && last.type === 'text') {
      last.value += value
    } else {
      parent.children.push({ type: 'text', value })
    }
  }

  parser.on('text', value => {
    if (stack.length === 0) {
      if (value.trim()) wellFormed = false
      return
    }
    addText(value)
  })
  parser.on('cdata', addText)
  parser.on('doctype', doctype => {
    const lower = doctype.toLowerCase()
    if (
      lower.includes('http://') ||
      lower.includes('https://') ||
      lower.includes('//') ||
      lower.includes('<!entity') ||
      lower.includes('system') ||
      lower.includes('public')
    ) {
      hasUnsafePreliminaries = true
    }
  })
  parser.on('processinginstruction', pi => {
    const lowerBody = pi.body.toLowerCase()
    if (
      lowerBody.includes('http://') ||
      lowerBody.includes('https://') ||
      (pi.target.toLowerCase() === 'xml-stylesheet' && lowerBody.includes('//'))
    ) {
      hasUnsafePreliminaries = true
    }
  })
  parser.on('opentag', tag => {
    const attrs: Record<string, string> = Object.create(null) as Record<string, string>
    if (tag.name.toLowerCase().startsWith('xlink:')) usesXlinkPrefix = true
    for (const [attrName, attrVal] of Object.entries(tag.attributes)) {
      attrs[attrName] = attrVal
      if (attrName.toLowerCase().startsWith('xlink:')) usesXlinkPrefix = true
    }
    const element: SvgXmlElement = { type: 'element', name: tag.name, attrs, children: [] }
    if (stack.length > 0) {
      stack[stack.length - 1]!.children.push(element)
    } else {
      rootCount += 1
      if (rootCount === 1) root = element
      else wellFormed = false
    }
    stack.push(element)
  })
  parser.on('closetag', () => {
    stack.pop()
  })
  parser.on('error', () => {
    wellFormed = false
  })

  try {
    parser.write(trimmed).close()
  } catch {
    wellFormed = false
  }

  if (stack.length !== 0 || rootCount !== 1 || !root) wellFormed = false

  return {
    root: wellFormed ? root : null,
    wellFormed,
    hasUnsafePreliminaries,
    usesXlinkPrefix
  }
}

const XML_TEXT_ESCAPES: Readonly<Record<string, string>> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '\r': '&#13;'
}

const XML_ATTR_ESCAPES: Readonly<Record<string, string>> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;'
}

function serializeSvgElement(root: SvgXmlElement): string {
  const chunks: string[] = []
  const visit = (node: SvgXmlNode) => {
    if (node.type === 'text') {
      chunks.push(node.value.replace(/[&<>\r]/g, ch => XML_TEXT_ESCAPES[ch]!))
      return
    }
    chunks.push('<', node.name)
    for (const [attrName, attrVal] of Object.entries(node.attrs)) {
      chunks.push(
        ' ',
        attrName,
        '="',
        attrVal.replace(/[&<>"]/g, ch => XML_ATTR_ESCAPES[ch]!),
        '"'
      )
    }
    if (node.children.length === 0) {
      chunks.push('/>')
      return
    }
    chunks.push('>')
    for (const child of node.children) visit(child)
    chunks.push('</', node.name, '>')
  }
  visit(root)
  return chunks.join('')
}

function getAttrCaseInsensitive(attrs: Readonly<Record<string, string>>, targetLower: string): [string, string] | null {
  if (Object.hasOwn(attrs, targetLower)) return [targetLower, attrs[targetLower]!]
  for (const [k, v] of Object.entries(attrs)) {
    if (k.toLowerCase() === targetLower) return [k, v]
  }
  return null
}

function deleteAttrCaseInsensitive(attrs: Record<string, string>, targetLower: string): void {
  for (const k of Object.keys(attrs)) {
    if (k.toLowerCase() === targetLower) delete attrs[k]
  }
}

/**
 * Parses an SVG document once, resolves CSS custom properties across `<style>`, `style`, and SVG
 * presentation attributes using CSS cascade rules, applies viewBox padding / background / card
 * frame, computes intrinsic dimensions, and verifies print-safety via `isSvgTreePrintSafe`.
 */
export function finalizeExportedSvg(
  rawSvg: string,
  palette: VizThemePalette,
  options?: FinalizeExportedSvgOptions
): ExportedSvgArtifact {
  const fallbackWidth = options?.fallbackWidth ?? options?.width ?? 680
  const fallbackHeight = options?.fallbackHeight ?? options?.height ?? 400

  if (!rawSvg.trim()) {
    return { svg: rawSvg, width: fallbackWidth, height: fallbackHeight, isPrintSafe: false }
  }

  const parsed = parseSvgXmlDocument(rawSvg)
  if (!parsed.wellFormed || !parsed.root || localTagOrAttrName(parsed.root.name) !== 'svg') {
    return { svg: rawSvg, width: fallbackWidth, height: fallbackHeight, isPrintSafe: false }
  }

  const root = parsed.root
  const stylesheetRootDecls: Record<string, string> = {}
  collectStyleElementsRootDecls(root, stylesheetRootDecls)

  const baseDecls: Record<string, string> = {
    ...buildPaletteTokenLookup(palette),
    ...(options?.includePeleTokens ? { ...PELE_INTERNAL_SYMBOLIC_DEFAULTS, ...buildPeleTokenMap(palette) } : {}),
    ...stylesheetRootDecls,
    ...options?.extraTokens
  }
  const baseScope: PropScope = { rawDecls: baseDecls, resolvedCache: new Map(), parent: null }

  const promoteCssRx = options?.promoteCssRx ?? false
  const stripCustomProperties = options?.stripCustomProperties ?? false
  const visiting = new Set<string>()
  let resolvedRootScope: PropScope = baseScope

  const walkElement = (elem: SvgXmlElement, parentScope: PropScope, isRoot: boolean): void => {
    const localTag = localTagOrAttrName(elem.name)
    let currentScope = parentScope
    const styleEntry = getAttrCaseInsensitive(elem.attrs, 'style')
    let effectiveStyleDecls: CssDeclarationEntry[] | null = null

    if (styleEntry) {
      const { effectiveEntries, customDecls } = selectWinningStyleDeclarations(splitCssDeclarations(styleEntry[1]))
      effectiveStyleDecls = effectiveEntries
      if (customDecls) {
        currentScope = { rawDecls: customDecls, resolvedCache: new Map(), parent: parentScope }
      }
    }

    if (isRoot) resolvedRootScope = currentScope
    const lookup = (propName: string) => lookupScopedProperty(currentScope, propName, visiting)

    if (styleEntry && effectiveStyleDecls) {
      const styleAttrKey = styleEntry[0]
      const keptParts: string[] = []
      for (const decl of effectiveStyleDecls) {
        if (decl.kind === 'raw') {
          keptParts.push(resolveCssValue(decl.value, lookup).value)
          continue
        }
        const suffix = decl.important ? ' !important' : ''
        if (isValidCustomPropName(decl.name)) {
          if (!stripCustomProperties) {
            keptParts.push(`${decl.name}:${resolveCssValue(decl.value, lookup).value.trim()}${suffix}`)
          }
          continue
        }
        const resolvedVal = resolveCssValue(decl.value, lookup).value.trim()
        const lowerProp = decl.name.toLowerCase()
        if (promoteCssRx && (lowerProp === 'rx' || lowerProp === 'ry')) {
          const promotedLength = parseNonNegativeLengthForSvgAttr(resolvedVal)
          if (promotedLength !== null) {
            const existingAttr = getAttrCaseInsensitive(elem.attrs, lowerProp)
            elem.attrs[existingAttr?.[0] ?? lowerProp] = promotedLength
            continue
          }
        }
        keptParts.push(`${decl.name}:${resolvedVal}${suffix}`)
      }
      if (keptParts.length === 0) delete elem.attrs[styleAttrKey]
      else elem.attrs[styleAttrKey] = keptParts.join(';')
    }

    for (const [attrName, attrVal] of Object.entries(elem.attrs)) {
      if (attrName.toLowerCase() === 'style' || isNonCssMetadataAttr(attrName) || isResourceUriAttr(attrName)) {
        continue
      }
      if (attrVal.includes('(')) {
        const nextVal = resolveCssValue(attrVal, lookup).value
        if (nextVal !== attrVal) elem.attrs[attrName] = nextVal
      }
    }

    if (localTag === 'style') {
      for (const child of elem.children) {
        if (child.type === 'text' && child.value) {
          child.value = resolveCssValue(child.value, lookup).value
        }
      }
      return
    }

    for (const child of elem.children) {
      if (child.type === 'element') walkElement(child, currentScope, false)
    }
  }

  walkElement(root, baseScope, true)

  if (!getAttrCaseInsensitive(root.attrs, 'xmlns')) {
    const reordered: Record<string, string> = Object.create(null) as Record<string, string>
    reordered.xmlns = 'http://www.w3.org/2000/svg'
    for (const [k, v] of Object.entries(root.attrs)) reordered[k] = v
    root.attrs = reordered
  }
  if (parsed.usesXlinkPrefix && !getAttrCaseInsensitive(root.attrs, 'xmlns:xlink')) {
    root.attrs['xmlns:xlink'] = 'http://www.w3.org/1999/xlink'
  }

  const vbAttr = getAttrCaseInsensitive(root.attrs, 'viewbox')
  let vb = parseViewBoxNumbers(vbAttr?.[1])
  const pad = options?.safetyPaddingPx ?? 0

  if (pad > 0) {
    if (vb) {
      vb = [vb[0] - pad, vb[1] - pad, vb[2] + pad * 2, vb[3] + pad * 2]
    } else {
      const wNum = parseNumericSvgLength(getAttrCaseInsensitive(root.attrs, 'width')?.[1])
      const hNum = parseNumericSvgLength(getAttrCaseInsensitive(root.attrs, 'height')?.[1])
      if (wNum !== null && wNum > 0 && hNum !== null && hNum > 0) {
        vb = [-pad, -pad, wNum + pad * 2, hNum + pad * 2]
      }
    }
  }

  let outputWidth: number | undefined
  let outputHeight: number | undefined

  if (options?.synchronizeDimensions) {
    let finalWidth = options.width ?? 480
    let finalHeight = options.height ?? 320
    const vbX = vb ? vb[0] : 0
    const vbY = vb ? vb[1] : 0
    const vbW = vb ? vb[2] : finalWidth
    const vbH = vb ? vb[3] : finalHeight

    if (vb) {
      if (options.width && options.height) {
        finalWidth = Math.round(options.width)
        finalHeight = Math.round(options.height)
      } else if (options.width && vbW > 0) {
        finalWidth = Math.round(options.width)
        finalHeight = Math.max(1, Math.round((options.width * vbH) / vbW))
      } else if (options.height && vbH > 0) {
        finalHeight = Math.round(options.height)
        finalWidth = Math.max(1, Math.round((options.height * vbW) / vbH))
      } else {
        finalWidth = Math.max(1, Math.ceil(vbW))
        finalHeight = Math.max(1, Math.ceil(vbH))
      }
    }

    deleteAttrCaseInsensitive(root.attrs, 'width')
    deleteAttrCaseInsensitive(root.attrs, 'height')
    root.attrs.width = String(finalWidth)
    root.attrs.height = String(finalHeight)
    outputWidth = finalWidth
    outputHeight = finalHeight

    if (options.injectBackgroundRect ?? false) {
      const bgFill =
        lookupScopedProperty(resolvedRootScope, '--pele-bg', visiting) ??
        options.extraTokens?.['--pele-bg'] ??
        palette.background
      const bgAttrs: Record<string, string> = Object.create(null) as Record<string, string>
      bgAttrs.x = String(vbX)
      bgAttrs.y = String(vbY)
      bgAttrs.width = String(vbW)
      bgAttrs.height = String(vbH)
      bgAttrs.fill = bgFill
      root.children.unshift({ type: 'element', name: 'rect', attrs: bgAttrs, children: [] })
    }
  }

  if (options?.cardFrame && vb) {
    const framePad = 12
    const nx = vb[0] - framePad
    const ny = vb[1] - framePad
    const nw = vb[2] + framePad * 2
    const nh = vb[3] + framePad * 2
    vb = [nx, ny, nw, nh]
    const frameAttrs: Record<string, string> = Object.create(null) as Record<string, string>
    frameAttrs.x = String(nx + 0.5)
    frameAttrs.y = String(ny + 0.5)
    frameAttrs.width = String(nw - 1)
    frameAttrs.height = String(nh - 1)
    frameAttrs.fill = palette.background
    frameAttrs.stroke = palette.border
    frameAttrs['stroke-width'] = '1'
    root.children.unshift({ type: 'element', name: 'rect', attrs: frameAttrs, children: [] })
    outputWidth = Math.max(1, Math.ceil(nw))
    outputHeight = Math.max(1, Math.ceil(nh))
  }

  if (vb) {
    root.attrs[vbAttr?.[0] ?? 'viewBox'] = `${vb[0]} ${vb[1]} ${vb[2]} ${vb[3]}`
  }

  if (outputWidth === undefined || outputHeight === undefined) {
    if (vb && vb[2] > 0 && vb[3] > 0) {
      outputWidth = Math.ceil(vb[2])
      outputHeight = Math.ceil(vb[3])
    } else {
      const wNum = parseNumericSvgLength(getAttrCaseInsensitive(root.attrs, 'width')?.[1])
      const hNum = parseNumericSvgLength(getAttrCaseInsensitive(root.attrs, 'height')?.[1])
      outputWidth = wNum !== null && wNum > 0 ? Math.ceil(wNum) : fallbackWidth
      outputHeight = hNum !== null && hNum > 0 ? Math.ceil(hNum) : fallbackHeight
    }
  }

  return {
    svg: serializeSvgElement(root),
    width: outputWidth,
    height: outputHeight,
    isPrintSafe: !parsed.hasUnsafePreliminaries && isSvgTreePrintSafe(root)
  }
}

/**
 * Resolves all Pele CSS custom properties (`--pele-*` and `--_*`) into concrete palette
 * values, strips inline custom property declarations, converts effective CSS `rx`/`ry` styles
 * to SVG attributes, and optionally inserts a solid background `<rect>` so standalone SVG
 * exports and offline PDF engines render faithfully.
 */
export function materializePeleSvg(
  rawSvg: string,
  palette: VizThemePalette,
  options?: MaterializePeleSvgOptions
): ExportedSvgArtifact {
  return finalizeExportedSvg(rawSvg, palette, {
    width: options?.width,
    height: options?.height,
    safetyPaddingPx: options?.safetyPaddingPx ?? 8,
    synchronizeDimensions: true,
    injectBackgroundRect: options?.injectBackgroundRect ?? true,
    promoteCssRx: true,
    stripCustomProperties: true,
    includePeleTokens: true,
    extraTokens: options?.extraTokens
  })
}

/**
 * Verifies whether an SVG string is self-contained and safe for offline vector PDF/print
 * pipelines: rejects invalid XML, `<foreignObject>`, `<script>`, unresolved `var(--...)`,
 * and external `http(s)://` or `//` resource references while ignoring prose text and
 * non-CSS metadata attributes.
 */
export function isPrintSafeSvg(svg: string): boolean {
  const parsed = parseSvgXmlDocument(svg)
  if (!parsed.wellFormed || !parsed.root || parsed.hasUnsafePreliminaries) return false
  if (localTagOrAttrName(parsed.root.name) !== 'svg') return false
  return isSvgTreePrintSafe(parsed.root)
}

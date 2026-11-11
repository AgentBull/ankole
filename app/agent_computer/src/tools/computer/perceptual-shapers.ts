import { extname } from 'node:path'

const CURL_JSON_MIN_BYTES = 4_096
const CURL_JSON_MAX_SCHEMA_RATIO = 0.65
const SHELL_CAT_MIN_CHARS = 2_000

export function normalizeCarriageReturns(text: string): string {
  if (!text.includes('\r')) return text
  return text
    .replace(/\r\n/g, '\n')
    .split('\n')
    .map(line => {
      const idx = line.lastIndexOf('\r')
      return idx >= 0 ? line.slice(idx + 1) : line
    })
    .join('\n')
}

const PASSING_NOISE_LINE_RE =
  /^(?:\s*(?:PASS|✓|✔|√|\(pass\))\s+.+|test\s+\S+\s+\.\.\.\s+ok\s*$|running\s+\d+\s+tests?\s*$|\.+|\s*Compiling\s+\S+\s+v\S+.*|\s*Downloading\s+crates\s*\.\.\..*|\s*Downloaded\s+\S+\s+v\S+.*|\s*Checking\s+\S+\s+v\S+.*|\s*Fresh\s+\S+\s+v\S+.*)$/

const SUMMARY_OR_WARNING_LINE_RE =
  /(?:={2,}\s*.*passed.*={2,}|^\s*Test Suites?:|^\s*Tests?:|^\s*Test Files\s+|^\s*Snapshots:|^\s*Duration\s+|^\s*Time:\s+|^\s*\d+\s+pass\b|^\s*\d+\s+fail\b|^Ran\s+\d+\s+tests?\b|^Finished\s+in\s+|^Finished\s+`?\w+`?\s+profile|^\d+\s+doctests?,\s+\d+\s+tests?,\s+0\s+failures|^test result:\s+ok\.|warning:|^\s*WARN\b|deprecated|\b\d+\s+warnings?\b|^Found\s+0\s+warnings\s+and\s+0\s+errors)/i

export function shapeTestOrBuildOutput(cleaned: string, exitCode: number): string {
  const lines = cleaned.split('\n')

  if (exitCode !== 0) {
    // On failure, preserve every failure block, traceback, compiler diagnostic, and summary;
    // only drop repetitive passing-item lines and compile-progress chatter when large.
    if (lines.length <= 40) return cleaned
    const filtered = lines.filter(line => !PASSING_NOISE_LINE_RE.test(line))
    return collapseBlankLines(filtered.join('\n')).trim()
  }

  // When exitCode === 0 and output is already compact, keep it verbatim unless it has passing noise.
  const hasPassingNoise = lines.some(line => PASSING_NOISE_LINE_RE.test(line))
  if (!hasPassingNoise && cleaned.length <= 600) {
    return cleaned.trim()
  }

  // Collect cargo test crate totals if multiple crates ran.
  let cargoPassed = 0
  let cargoIgnored = 0
  let cargoSuites = 0
  const kept: string[] = []

  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed) continue
    if (PASSING_NOISE_LINE_RE.test(line)) continue

    const cargoMatch = trimmed.match(/^test result:\s+ok\.\s+(\d+)\s+passed;\s+0\s+failed;\s+(\d+)\s+ignored/)
    if (cargoMatch) {
      cargoSuites++
      cargoPassed += Number(cargoMatch[1])
      cargoIgnored += Number(cargoMatch[2])
      continue
    }

    if (SUMMARY_OR_WARNING_LINE_RE.test(trimmed)) {
      kept.push(line)
    }
  }

  if (cargoSuites > 0) {
    kept.push(
      cargoSuites === 1
        ? `test result: ok. ${cargoPassed} passed; 0 failed; ${cargoIgnored} ignored`
        : `test result: ok across ${cargoSuites} suites (${cargoPassed} passed; 0 failed; ${cargoIgnored} ignored)`
    )
  }

  if (kept.length === 0) {
    // Unrecognized custom script or clean silent tool (like `tsc --noEmit` with 0 output):
    // preserve short output verbatim rather than erasing custom text.
    return cleaned.length <= 800 ? cleaned.trim() : lines.slice(-12).join('\n').trim()
  }

  return kept.join('\n').trim()
}

const PKG_NOISE_LINE_RE =
  /^(?:Progress:\s+resolved\b|Packages:\s+\+\d+|[-+]{3,}|[│└├─]+\s*(?:Running|Downloading|Resolving)|npm notice\b|.*packages? are looking for funding.*|.*run `npm fund` for details.*|Requirement already satisfied:|Downloading\s+\S+\s+\(|Using cached\s+\S+|Collecting\s+\S+|Installing collected packages:)/i

export function shapePackageManagerOutput(cleaned: string, exitCode: number): string {
  if (exitCode !== 0) {
    // Keep full error chain on non-zero exit; only strip progress bar lines.
    return collapseBlankLines(
      cleaned
        .split('\n')
        .filter(line => !/^Progress:\s+resolved\b/.test(line.trim()))
        .join('\n')
    ).trim()
  }

  const lines = cleaned.split('\n')
  const kept: string[] = []
  let addedPkgLines = 0

  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed) continue
    if (PKG_NOISE_LINE_RE.test(trimmed)) continue
    if (/^\+\s+@?[\w./-]+[ @][\dA-Za-z.+_-]+$/.test(trimmed)) {
      addedPkgLines++
      continue
    }
    kept.push(line)
  }

  if (addedPkgLines > 0 && !kept.some(line => /\bpackages?\s+installed\b|\badded\s+\d+\s+packages?\b/i.test(line))) {
    kept.unshift(`+${addedPkgLines} packages`)
  }

  return kept.length > 0 ? collapseBlankLines(kept.join('\n')).trim() : cleaned.trim()
}

export function shapeCurlJsonOutput(raw: string): string {
  if (Buffer.byteLength(raw, 'utf8') <= CURL_JSON_MIN_BYTES) return raw
  const trimmed = raw.trim()
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return raw

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch {
    return raw
  }

  if (looksLikeErrorPayload(parsed)) return raw

  const schemaSummary = renderUnifiedJsonDocument(parsed)
  if (Buffer.byteLength(schemaSummary, 'utf8') >= Buffer.byteLength(raw, 'utf8') * CURL_JSON_MAX_SCHEMA_RATIO) {
    return raw
  }
  return schemaSummary
}

function looksLikeErrorPayload(value: unknown): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  const hasCollection =
    Array.isArray(record.data) ||
    Array.isArray(record.items) ||
    Array.isArray(record.results) ||
    Array.isArray(record.records) ||
    Array.isArray(record.nodes)
  if (hasCollection) return false

  if (record.ok === false || record.success === false) return true
  if (record.error !== undefined && record.error !== null && record.error !== false) return true
  for (const key of ['status', 'statusCode', 'status_code', 'code']) {
    const code = record[key]
    if (typeof code === 'number' && code >= 400 && code <= 599) return true
  }
  return false
}

type SchemaNode = {
  primitives: Set<string>
  arrayInfo?: { minLen: number; maxLen: number; element: SchemaNode }
  objectInfo?: {
    count: number
    fields: Map<string, { presentCount: number; schema: SchemaNode }>
    dynamicValue?: SchemaNode
  }
}

function emptySchemaNode(): SchemaNode {
  return { primitives: new Set() }
}

function mergeValueIntoSchema(target: SchemaNode, value: unknown, depth: number): void {
  if (value === null) {
    target.primitives.add('null')
    return
  }
  const kind = typeof value
  if (kind === 'string' || kind === 'number' || kind === 'boolean') {
    target.primitives.add(kind === 'number' && Number.isInteger(value) ? 'integer' : kind)
    return
  }
  if (depth >= 8) {
    target.primitives.add(Array.isArray(value) ? 'Array<unknown>' : 'object')
    return
  }
  if (Array.isArray(value)) {
    if (!target.arrayInfo) {
      target.arrayInfo = { minLen: value.length, maxLen: value.length, element: emptySchemaNode() }
    } else {
      target.arrayInfo.minLen = Math.min(target.arrayInfo.minLen, value.length)
      target.arrayInfo.maxLen = Math.max(target.arrayInfo.maxLen, value.length)
    }
    for (const item of value) {
      mergeValueIntoSchema(target.arrayInfo.element, item, depth + 1)
    }
    return
  }
  if (kind === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (!target.objectInfo) {
      target.objectInfo = { count: 0, fields: new Map() }
    }
    target.objectInfo.count++
    // Treat wide dictionary maps (> 48 keys) as Record<string, V> so dynamic ID maps stay compact.
    if (entries.length > 48 || target.objectInfo.dynamicValue) {
      if (!target.objectInfo.dynamicValue) {
        target.objectInfo.dynamicValue = emptySchemaNode()
        for (const [, existing] of target.objectInfo.fields) {
          target.objectInfo.dynamicValue = mergeSchemaNodes(target.objectInfo.dynamicValue, existing.schema)
        }
        target.objectInfo.fields.clear()
      }
      for (const [, val] of entries) {
        mergeValueIntoSchema(target.objectInfo.dynamicValue, val, depth + 1)
      }
      return
    }
    for (const [key, val] of entries) {
      let entry = target.objectInfo.fields.get(key)
      if (!entry) {
        entry = { presentCount: 0, schema: emptySchemaNode() }
        target.objectInfo.fields.set(key, entry)
      }
      entry.presentCount++
      mergeValueIntoSchema(entry.schema, val, depth + 1)
    }
  }
}

function mergeSchemaNodes(left: SchemaNode, right: SchemaNode): SchemaNode {
  const out = emptySchemaNode()
  for (const p of left.primitives) out.primitives.add(p)
  for (const p of right.primitives) out.primitives.add(p)
  if (left.arrayInfo || right.arrayInfo) {
    const a = left.arrayInfo
    const b = right.arrayInfo
    out.arrayInfo = {
      minLen: Math.min(a?.minLen ?? Infinity, b?.minLen ?? Infinity),
      maxLen: Math.max(a?.maxLen ?? 0, b?.maxLen ?? 0),
      element: a && b ? mergeSchemaNodes(a.element, b.element) : (a?.element ?? b!.element)
    }
  }
  return out
}

function renderUnifiedJsonDocument(root: unknown): string {
  const node = emptySchemaNode()
  mergeValueIntoSchema(node, root, 0)

  const headerScalars: Record<string, unknown> = {}
  if (root && typeof root === 'object' && !Array.isArray(root)) {
    for (const [key, val] of Object.entries(root as Record<string, unknown>)) {
      if (
        val === null ||
        typeof val === 'boolean' ||
        typeof val === 'number' ||
        (typeof val === 'string' && val.length <= 120)
      ) {
        headerScalars[key] = val
      }
    }
  }

  const lines: string[] = []
  if (Array.isArray(root)) {
    lines.push(`JSON Array (length: ${root.length}) unified schema:`)
  } else {
    lines.push('JSON Object unified schema:')
    if (Object.keys(headerScalars).length > 0) {
      lines.push(`scalars: ${JSON.stringify(headerScalars)}`)
    }
  }
  lines.push(formatSchemaNode(node, 0, true))
  return lines.join('\n')
}

function formatSchemaNode(node: SchemaNode, indent: number, topLevel = false): string {
  const parts: string[] = []
  const pad = '  '.repeat(indent)

  if (node.objectInfo) {
    if (node.objectInfo.dynamicValue) {
      parts.push(`Record<string, ${formatSchemaNode(node.objectInfo.dynamicValue, indent)}>`)
    } else if (node.objectInfo.fields.size === 0) {
      parts.push('{}')
    } else {
      const total = node.objectInfo.count
      const fieldLines: string[] = []
      for (const [key, info] of node.objectInfo.fields) {
        const optional = info.presentCount < total ? '?' : ''
        const rendered = formatSchemaNode(info.schema, indent + 1)
        fieldLines.push(`${'  '.repeat(indent + 1)}${JSON.stringify(key)}${optional}: ${rendered}`)
      }
      parts.push(`{\n${fieldLines.join(',\n')}\n${pad}}`)
    }
  }

  if (node.arrayInfo) {
    const { minLen, maxLen, element } = node.arrayInfo
    const lenLabel =
      topLevel && minLen === maxLen
        ? ''
        : minLen === maxLen
          ? ` (length: ${minLen})`
          : ` (length: ${minLen}..${maxLen})`
    if (maxLen === 0) {
      parts.push(`Array<never>${lenLabel}`)
    } else {
      parts.push(`Array<${formatSchemaNode(element, indent)}>${lenLabel}`)
    }
  }

  const primitives = [...node.primitives]
  if (primitives.includes('integer') && primitives.includes('number')) {
    primitives.splice(primitives.indexOf('integer'), 1)
  }
  // Keep `null` at the end of union types for readability.
  const hasNull = primitives.includes('null')
  for (const prim of primitives) {
    if (prim !== 'null') parts.push(prim)
  }
  if (hasNull) parts.push('null')

  return parts.join(' | ') || 'unknown'
}

const LICENSE_KEYWORDS_RE =
  /Copyright\s+\(c\)|SPDX-License-Identifier:|Licensed under the Apache License|Permission is hereby granted, free of charge/i

export function shapeSourceCatOutput(raw: string, filePath: string): string {
  if (raw.length <= SHELL_CAT_MIN_CHARS) return raw
  const ext = extname(filePath).toLowerCase()
  const isHashLang = ext === '.py' || ext === '.ex' || ext === '.exs' || ext === '.rb' || ext === '.sh'

  let text = raw
  // Strip leading license header comment block when present at top of file.
  const leadingBlockMatch = text.match(/^(?:\/\*[\s\S]*?\*\/\s*\n|(?:(?:#|\/\/).*\n){3,})/)
  if (leadingBlockMatch && LICENSE_KEYWORDS_RE.test(leadingBlockMatch[0])) {
    // Preserve shebang on first line if present.
    const firstLine = leadingBlockMatch[0].split('\n')[0] ?? ''
    const rest = text.slice(leadingBlockMatch[0].length)
    text = firstLine.startsWith('#!') ? `${firstLine}\n${rest}` : rest
  }

  const lines = text.split('\n')
  const out: string[] = []
  let inDocBlock = false
  let inPythonTriple: '"""' | "'''" | null = null

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!
    const trimmed = line.trim()

    if (ext === '.py') {
      if (inPythonTriple) {
        out.push(line)
        if (trimmed.includes(inPythonTriple)) inPythonTriple = null
        continue
      }
      if (trimmed.startsWith('"""') || trimmed.startsWith("'''")) {
        const delim = trimmed.slice(0, 3) as '"""' | "'''"
        out.push(line)
        if (trimmed.slice(3).indexOf(delim) === -1) inPythonTriple = delim
        continue
      }
    }

    if (inDocBlock) {
      out.push(line)
      if (trimmed.includes('*/')) inDocBlock = false
      continue
    }

    if (trimmed.startsWith('/**') || trimmed.startsWith('/*!')) {
      out.push(line)
      if (!trimmed.includes('*/')) inDocBlock = true
      continue
    }

    if (isHashLang) {
      if (index === 0 && trimmed.startsWith('#!')) {
        out.push(line)
        continue
      }
      if (trimmed.startsWith('#')) {
        continue
      }
    } else {
      // Preserve Rust/C# `///` and `//!` doc comments; strip ordinary standalone `//` comments.
      if (trimmed.startsWith('//') && !trimmed.startsWith('///') && !trimmed.startsWith('//!')) {
        continue
      }
    }

    out.push(line)
  }

  return collapseBlankLines(out.join('\n'))
}

function collapseBlankLines(text: string): string {
  return text.replace(/\n{3,}/g, '\n\n')
}

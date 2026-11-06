import { validateInfographicSyntax } from '@ankole/uikit/viz/infographic'
import { createHash } from 'node:crypto'
import { validateMermaidSyntax } from '../viz/mermaid-svg'

export type PodDiagramKind = 'mermaid' | 'infographic'
export type PodDiagramSyntaxForm = 'fence' | 'xml'

export interface ExtractedDiagramBlock {
  kind: PodDiagramKind
  syntaxForm: PodDiagramSyntaxForm
  source: string
  startLine: number
  hash: string
}

export function hashDiagramBlock(kind: PodDiagramKind, source: string): string {
  return createHash('sha256').update(`${kind}:${source.trim()}`).digest('hex')
}

function decodeXmlEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function normalizeXmlDiagramInnerSource(rawInner: string, kind: PodDiagramKind): string {
  const lines = rawInner
    .replace(/^\r?\n/, '')
    .replace(/\r?\n[ \t]*$/, '')
    .split(/\r?\n/)
  if (lines.length >= 2) {
    const first = lines[0]!.trim()
    const last = lines[lines.length - 1]!.trim()
    const openMatch = /^(`{3}|~{3})(mermaid|infographic)?\s*$/i.exec(first)
    if (openMatch && last === openMatch[1]) {
      const innerLang = openMatch[2]?.toLowerCase()
      if (!innerLang || innerLang === kind) {
        return lines.slice(1, -1).join('\n')
      }
    }
  }
  return decodeXmlEntities(rawInner)
}

/**
 * Extracts rendered `<mermaid>` / ```` ```mermaid ```` and (unless `pageType === 'knowledge'`)
 * `<infographic>` / ```` ```infographic ```` blocks from Pod Markdown while ignoring:
 * - Outer 4+ backtick/tilde fences (e.g. ```` ````markdown ```` documentation examples)
 * - 3-backtick/tilde fences that carry a meta string (e.g. ```` ```mermaid title="raw" ````)
 * - Explicit `<pre ...>...</pre>` blocks (e.g. `<pre lang="mermaid">`)
 * - Inline code spans on prose lines (e.g. `` `<mermaid>` ``)
 */
export function extractDiagramBlocks(markdown: string, options?: { pageType?: string }): ExtractedDiagramBlock[] {
  if (!markdown) return []

  const isKnowledge = options?.pageType === 'knowledge'
  const lines = markdown.split(/\r?\n/)
  const blocks: ExtractedDiagramBlock[] = []

  type ScanState =
    | { mode: 'normal' }
    | { mode: 'pre' }
    | {
        mode: 'fence'
        fenceChar: '`' | '~'
        fenceLen: number
        diagramKind: PodDiagramKind | null
        startLine: number
        bodyLines: string[]
      }
    | {
        mode: 'xml'
        diagramKind: PodDiagramKind
        startLine: number
        bodyLines: string[]
      }

  let state: ScanState = { mode: 'normal' }

  for (let idx = 0; idx < lines.length; idx += 1) {
    const line = lines[idx]!
    const lineNum = idx + 1

    if (state.mode === 'pre') {
      if (/<\/pre\s*>/i.test(line)) {
        state = { mode: 'normal' }
      }
      continue
    }

    if (state.mode === 'fence') {
      const closeRe = new RegExp(`^ {0,3}${state.fenceChar}{${state.fenceLen},}\\s*$`)
      if (closeRe.test(line)) {
        if (state.diagramKind) {
          const source = state.bodyLines.join('\n')
          blocks.push({
            kind: state.diagramKind,
            syntaxForm: 'fence',
            source,
            startLine: state.startLine,
            hash: hashDiagramBlock(state.diagramKind, source)
          })
        }
        state = { mode: 'normal' }
      } else if (state.diagramKind) {
        state.bodyLines.push(line)
      }
      continue
    }

    if (state.mode === 'xml') {
      const closeXmlRe = new RegExp(`^(.*?)<\\/${state.diagramKind}\\s*>\\s*$`, 'i')
      const closeMatch = closeXmlRe.exec(line)
      if (closeMatch) {
        if (closeMatch[1]) {
          state.bodyLines.push(closeMatch[1])
        }
        const source = normalizeXmlDiagramInnerSource(state.bodyLines.join('\n'), state.diagramKind)
        blocks.push({
          kind: state.diagramKind,
          syntaxForm: 'xml',
          source,
          startLine: state.startLine,
          hash: hashDiagramBlock(state.diagramKind, source)
        })
        state = { mode: 'normal' }
      } else {
        state.bodyLines.push(line)
      }
      continue
    }

    // `state.mode === 'normal'`
    // 1. Check CommonMark code fence opener (` ``` ` or ` ~~~ ` or 4+ outer fences)
    const fenceMatch = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (fenceMatch) {
      const fenceRun = fenceMatch[1]!
      const fenceChar = fenceRun[0] as '`' | '~'
      const fenceLen = fenceRun.length
      const infoRaw = fenceMatch[2]!

      if (!(fenceChar === '`' && infoRaw.includes('`'))) {
        let diagramKind: PodDiagramKind | null = null
        if (fenceLen === 3) {
          const trimmedInfo = infoRaw.trim()
          if (trimmedInfo === 'mermaid') {
            diagramKind = 'mermaid'
          } else if (trimmedInfo === 'infographic' && !isKnowledge) {
            diagramKind = 'infographic'
          }
        }
        state = {
          mode: 'fence',
          fenceChar,
          fenceLen,
          diagramKind,
          startLine: lineNum,
          bodyLines: []
        }
        continue
      }
    }

    // 2. Check `<pre ...>` blocks (e.g. `<pre lang="mermaid">`)
    if (/^ {0,3}<pre\b[^>]*>/i.test(line)) {
      if (!/<\/pre\s*>/i.test(line)) {
        state = { mode: 'pre' }
      }
      continue
    }

    // 3. Check block-level `<mermaid ...>` / `<infographic ...>` JSX/XML tags
    const singleLineXml = /^ {0,3}<(mermaid|infographic)(?:\s[^>]*)?>(.*?)<\/\1\s*>\s*$/i.exec(line)
    if (singleLineXml) {
      const rawKind = singleLineXml[1]!.toLowerCase() as PodDiagramKind
      if (rawKind === 'infographic' && isKnowledge) {
        continue
      }
      const source = normalizeXmlDiagramInnerSource(singleLineXml[2]!, rawKind)
      blocks.push({
        kind: rawKind,
        syntaxForm: 'xml',
        source,
        startLine: lineNum,
        hash: hashDiagramBlock(rawKind, source)
      })
      continue
    }

    const openXml = /^ {0,3}<(mermaid|infographic)(\s[^>]*)?>(.*)$/i.exec(line)
    if (openXml) {
      const attrs = openXml[2] ?? ''
      if (!attrs.trimEnd().endsWith('/')) {
        const rawKind = openXml[1]!.toLowerCase() as PodDiagramKind
        if (rawKind === 'infographic' && isKnowledge) {
          continue
        }
        const trailing = openXml[3] ?? ''
        state = {
          mode: 'xml',
          diagramKind: rawKind,
          startLine: lineNum,
          bodyLines: trailing.trim() ? [trailing] : []
        }
        continue
      }
    }
  }

  return blocks
}

interface FailedDiagramBlock {
  block: ExtractedDiagramBlock
  errors: string[]
}

async function validateSingleDiagramBlock(block: ExtractedDiagramBlock): Promise<string[] | null> {
  if (block.kind === 'mermaid') {
    const res = await validateMermaidSyntax(block.source)
    return res.ok ? null : res.errors
  }
  const res = validateInfographicSyntax(block.source)
  return res.ok ? null : res.errors
}

function formatSnippet(source: string): string {
  const firstNonEmpty =
    source
      .split(/\r?\n/)
      .map(line => line.trim())
      .find(line => line.length > 0) ?? '<empty>'
  return firstNonEmpty.length > 80 ? `${firstNonEmpty.slice(0, 77)}...` : firstNonEmpty
}

function buildPreflightErrorMessage(failures: readonly FailedDiagramBlock[]): string {
  const details = failures.map(({ block, errors }) => {
    const snippet = formatSnippet(block.source)
    return `- ${block.kind} block at line ${block.startLine} ("${snippet}"): ${errors.join('; ')}`
  })
  return [
    `Diagram syntax preflight failed (${failures.length} invalid block${failures.length === 1 ? '' : 's'}):`,
    ...details,
    'Fix the diagram syntax (or run `ankole-viz validate <mermaid|infographic> --spec -`) before saving the page.'
  ].join('\n')
}

export interface ExistingPageSnapshot {
  pageType?: string
  markdown?: string
}

export interface PreflightPageMarkdownOptions {
  operation: 'pages.create' | 'pages.append' | 'pages.write' | 'pages.patch'
  markdown: string
  knownPageType?: string
  existingSnapshot?: ExistingPageSnapshot
  loadExistingPage?: () => Promise<ExistingPageSnapshot | undefined>
}

/**
 * Validates rendered Mermaid and Infographic blocks before mutating a Pod page:
 * - Zero extra RPCs when the incoming Markdown has zero diagram blocks OR all blocks pass syntax validation.
 * - Exempts fenced ```` ```infographic ```` blocks on `:knowledge` pages (where they render as `<pre lang="infographic">`).
 * - On `pages.write` and `pages.patch`, exempts any failing `(kind, sha256)` block that already existed
 *   identically on the page before this edit so legacy broken blocks never block unrelated edits.
 */
export async function preflightPageMarkdown(opts: PreflightPageMarkdownOptions): Promise<void> {
  if (!opts.markdown) return

  const candidates = extractDiagramBlocks(opts.markdown, { pageType: opts.knownPageType })
  if (candidates.length === 0) {
    return
  }

  let failures: FailedDiagramBlock[] = []
  for (const block of candidates) {
    const errors = await validateSingleDiagramBlock(block)
    if (errors && errors.length > 0) {
      failures.push({ block, errors })
    }
  }

  if (failures.length === 0) {
    return
  }

  let snapshot = opts.existingSnapshot
  if (!snapshot && opts.loadExistingPage && opts.operation !== 'pages.create') {
    try {
      snapshot = await opts.loadExistingPage()
    } catch {
      snapshot = undefined
    }
  }

  const effectivePageType = opts.knownPageType ?? snapshot?.pageType
  if (effectivePageType === 'knowledge') {
    failures = failures.filter(f => !(f.block.kind === 'infographic' && f.block.syntaxForm === 'fence'))
    if (failures.length === 0) {
      return
    }
  }

  if (
    (opts.operation === 'pages.write' || opts.operation === 'pages.patch') &&
    typeof snapshot?.markdown === 'string'
  ) {
    const existingBlocks = extractDiagramBlocks(snapshot.markdown, { pageType: effectivePageType })
    const existingHashes = new Set(existingBlocks.map(b => b.hash))
    failures = failures.filter(f => !existingHashes.has(f.block.hash))
    if (failures.length === 0) {
      return
    }
  }

  throw new Error(buildPreflightErrorMessage(failures))
}

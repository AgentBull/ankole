import type { GrepResult } from '@ff-labs/fff-bun'
import { realpathSync } from 'node:fs'
import { resolve } from 'node:path'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import type { ComputerToolContext } from './context'
import {
  AGENT_RUNTIME_DIRNAME,
  GREP_TIME_BUDGET_MS,
  buildSearchQuery,
  clipSearchLine,
  displayPath,
  fffSearchRuntime,
  fileAnnotation,
  normalizeExcludes,
  resolveSearchTarget,
  scanNotice,
  SEARCH_MAX_LINE_LENGTH,
  type FffSearchRuntime
} from './fff-search'
import { MAX_OUTPUT_CHARS, clipLinesToBudget } from './format'

const DEFAULT_LIMIT = 20
const MAX_CONTEXT = 20

const GrepParams = z
  .object({
    pattern: z
      .string()
      .optional()
      .describe(
        'Text to search for: a literal string or a regex (auto-detected). Prefer bare identifiers or literal phrases. Required unless cursor is set.'
      ),
    path: z
      .string()
      .optional()
      .describe(
        "Scope constraint: directory ('src/'), filename ('main.rs'), or glob ('*.ts'). Absolute and ~/ paths inside the agent home also work."
      ),
    exclude: z
      .union([z.string(), z.array(z.string())])
      .optional()
      .describe("Paths to skip, same syntax as path; comma/space separated or an array, e.g. 'test/,*.min.js'."),
    caseSensitive: z
      .boolean()
      .optional()
      .describe(
        'Force case-sensitive matching. Default is smart-case: case-insensitive when the pattern is all lowercase.'
      ),
    context: z
      .number()
      .int()
      .min(0)
      .max(MAX_CONTEXT)
      .optional()
      .describe(`Lines of context before and after each match (default 0, max ${MAX_CONTEXT}).`),
    limit: z.number().int().min(1).max(50).optional().describe(`Maximum matches per page (default ${DEFAULT_LIMIT}).`),
    cursor: z
      .string()
      .optional()
      .describe('Continuation cursor from a previous result; when set, other arguments are ignored.')
  })
  .strict()

interface GrepDetails {
  totalMatched: number
  totalFilesSearched: number
  cursor?: string
}

// Wildcard-only regex means "match everything" — the model is trying to read
// a file through grep. Refuse with a steer instead of burning retries.
const WILDCARD_ONLY_PATTERN = /^(?:[.^$]*(?:[.][*+?]|\*|\+)[.^$]*|[.^$\s]*|\.\*\??|\.\*[+?]?|\.\+\??|\.|\*|\?)$/

function detectMode(pattern: string): 'plain' | 'regex' {
  const hasRegexSyntax = pattern !== pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  if (!hasRegexSyntax) return 'plain'
  try {
    new RegExp(pattern)
    return 'regex'
  } catch {
    return 'plain'
  }
}

/** Groups matches by file in engine order; matches inside a file stay in source order. */
function formatGrepOutput(
  result: GrepResult,
  root: string,
  workspaceReal: string
): { text: string; linesClipped: boolean } {
  const lines: string[] = []
  let linesClipped = false
  let currentFile = ''
  const pushLine = (lineNumber: number, separator: ':' | '-', content: string) => {
    const clipped = clipSearchLine(content)
    if (clipped.wasClipped) linesClipped = true
    lines.push(` ${lineNumber}${separator} ${clipped.text}`)
  }

  for (const match of result.items) {
    if (match.relativePath !== currentFile) {
      if (lines.length > 0) lines.push('')
      currentFile = match.relativePath
      lines.push(`${displayPath(root, workspaceReal, match.relativePath)}${fileAnnotation(match)}`)
    }
    match.contextBefore?.forEach((line, index) => {
      pushLine(match.lineNumber - (match.contextBefore?.length ?? 0) + index, '-', line)
    })
    pushLine(match.lineNumber, ':', match.lineContent)
    match.contextAfter?.forEach((line, index) => {
      pushLine(match.lineNumber + 1 + index, '-', line)
    })
  }
  return { text: lines.join('\n'), linesClipped }
}

/**
 * The model's content-search tool over the warm fff index: smart-case,
 * auto-detected regex vs literal, results grouped by file with the most
 * relevant files first.
 */
export function createGrepTool(
  context: ComputerToolContext,
  runtime: FffSearchRuntime = fffSearchRuntime
): WorkerAgentTool<typeof GrepParams, GrepDetails> {
  return defineWorkerTool({
    name: 'grep',
    description:
      'Search file contents in the indexed workspace. Smart-case; regex vs literal is auto-detected; output is grouped by file with the most relevant files first, matches in source order with line numbers. Use path to scope and exclude to cut noise. After one or two greps, read the top file instead of grepping more. Long lines are clipped; use read_file for full lines.',
    schema: GrepParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({
      key: 'signals_gateway.reply.activity.command_search_code_family',
      bindings: { family: 'grep' }
    }),
    async execute(_toolCallId, params): Promise<AgentToolResult<GrepDetails>> {
      const workspaceReal = realpathSync(resolve(context.workspaceRoot))
      const emptyDetails: GrepDetails = { totalMatched: 0, totalFilesSearched: 0 }

      const resumed = params.cursor !== undefined ? runtime.getGrepCursor(params.cursor) : undefined
      if (params.cursor !== undefined && !resumed) {
        return {
          content: [{ type: 'text', text: 'Cursor expired; rerun the search from the first page.' }],
          details: emptyDetails
        }
      }

      let root: string
      let query: string
      let mode: 'plain' | 'regex' | 'fuzzy'
      let smartCase: boolean
      let contextLines: number
      let pageSize: number
      if (resumed) {
        root = resumed.root
        query = resumed.query
        mode = resumed.mode
        smartCase = resumed.smartCase
        contextLines = resumed.context
        pageSize = resumed.pageSize
      } else {
        const pattern = params.pattern?.trim() ?? ''
        if (!pattern) {
          return {
            content: [{ type: 'text', text: 'pattern is required unless cursor is set.' }],
            details: emptyDetails
          }
        }
        mode = detectMode(pattern)
        if (mode === 'regex' && WILDCARD_ONLY_PATTERN.test(pattern)) {
          return {
            content: [
              {
                type: 'text',
                text: `Pattern '${pattern}' matches everything — grep needs a concrete substring or identifier. To read a file, use read_file.`
              }
            ],
            details: emptyDetails
          }
        }
        const target = resolveSearchTarget(
          { agentHome: context.agentHome, workspaceRoot: context.workspaceRoot },
          params.path
        )
        if (!target.ok) {
          return { content: [{ type: 'text', text: target.message }], details: emptyDetails }
        }
        root = target.root
        smartCase = params.caseSensitive !== true
        contextLines = params.context ?? 0
        pageSize = params.limit ?? DEFAULT_LIMIT
        const excludes = normalizeExcludes(params.exclude)
        if (root !== workspaceReal) excludes.push(`!${AGENT_RUNTIME_DIRNAME}/`)
        query = buildSearchQuery({ constraint: target.constraint, excludes, pattern })
      }

      const acquired = await runtime.acquire(root, { covering: root !== workspaceReal })
      const grepOptions = {
        mode,
        smartCase,
        maxMatchesPerFile: pageSize,
        pageSize,
        cursor: resumed?.cursor ?? null,
        beforeContext: contextLines,
        afterContext: contextLines,
        timeBudgetMs: GREP_TIME_BUDGET_MS
      }
      const searched = acquired.finder.grep(query, grepOptions)
      if (!searched.ok) throw new Error(`grep failed: ${searched.error}`)
      let result = searched.value

      // Zero exact hits on a fresh literal search: retry fuzzy once so a
      // near-miss identifier still surfaces something actionable.
      let fuzzyNotice: string | undefined
      if (result.items.length === 0 && !result.nextCursor && !resumed && mode !== 'regex') {
        const fuzzy = acquired.finder.grep(query, { ...grepOptions, mode: 'fuzzy', beforeContext: 0, afterContext: 0 })
        if (fuzzy.ok && fuzzy.value.items.length > 0) {
          fuzzyNotice = '0 exact matches. Maybe you meant this?'
          result = fuzzy.value
        }
      }

      const notices: string[] = []
      const scanning = scanNotice(acquired.finder)
      if (scanning) notices.push(scanning)
      if (result.regexFallbackError) notices.push(`Invalid regex (${result.regexFallbackError}); used literal match`)

      const details: GrepDetails = {
        totalMatched: result.totalMatched,
        totalFilesSearched: result.totalFilesSearched
      }

      if (result.items.length === 0) {
        const tail = notices.length > 0 ? `\n\n[${notices.join('. ')}]` : ''
        return { content: [{ type: 'text', text: `No matches found${tail}` }], details }
      }

      const formatted = formatGrepOutput(result, acquired.root, workspaceReal)
      let output = formatted.text
      if (formatted.linesClipped) {
        notices.push(`Some lines clipped to ${SEARCH_MAX_LINE_LENGTH} chars. Use read_file for full lines`)
      }
      if (result.nextCursor && !fuzzyNotice) {
        const cursor = runtime.storeGrepCursor({
          cursor: result.nextCursor,
          root: acquired.root,
          query,
          mode,
          smartCase,
          context: contextLines,
          pageSize
        })
        details.cursor = cursor
        notices.push(`More matches available. Continue with cursor="${cursor}"`)
      }

      const clipped = clipLinesToBudget(output, MAX_OUTPUT_CHARS)
      if (clipped.clipped) {
        output = clipped.text
        notices.push(`Output clipped to ${clipped.keptLines} of ${clipped.totalLines} lines; narrow the search`)
      }
      if (notices.length > 0) output += `\n\n[${notices.join('. ')}]`
      if (fuzzyNotice) output = `[${fuzzyNotice}]\n${output}`
      return { content: [{ type: 'text', text: output }], details }
    }
  })
}

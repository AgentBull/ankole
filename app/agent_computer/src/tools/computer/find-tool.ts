import { realpathSync } from 'node:fs'
import { resolve } from 'node:path'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import type { ComputerToolContext } from './context'
import {
  AGENT_RUNTIME_DIRNAME,
  buildSearchQuery,
  displayPath,
  fffSearchRuntime,
  fileAnnotation,
  normalizeExcludes,
  resolveSearchTarget,
  scanNotice,
  type FffSearchRuntime
} from './fff-search'
import { MAX_OUTPUT_CHARS, clipLinesToBudget } from './format'

const DEFAULT_LIMIT = 30

const FindParams = z
  .object({
    pattern: z
      .string()
      .optional()
      .describe(
        "Fuzzy query matched against whole relative paths, not just filenames; also accepts globs. Multi-word narrows (AND). May be omitted when path provides the filter, e.g. path 'dir/**' lists a directory."
      ),
    path: z
      .string()
      .optional()
      .describe(
        "Scope constraint: directory ('src/'), filename ('main.rs'), or glob ('src/**/*.ts'). Absolute and ~/ paths inside the agent home also work."
      ),
    exclude: z
      .union([z.string(), z.array(z.string())])
      .optional()
      .describe("Paths to skip, same syntax as path; comma/space separated or an array, e.g. 'test/,*.min.js'."),
    limit: z.number().int().min(1).max(100).optional().describe(`Maximum results per page (default ${DEFAULT_LIMIT}).`),
    cursor: z
      .string()
      .optional()
      .describe('Continuation cursor from a previous result; when set, other arguments are ignored.')
  })
  .strict()

interface FindDetails {
  totalMatched: number
  totalFiles: number
  cursor?: string
}

// Below half of a perfect fuzzy score, results are scattered noise: show a
// small sample instead of a full page. Mirrors the fff scoring formula.
const WEAK_SAMPLE_SIZE = 5

function weakScoreThreshold(pattern: string): number {
  return Math.floor(pattern.length * 12 * 0.5)
}

/**
 * The model's file-discovery tool: fuzzy whole-path search over the warm fff
 * index of the workspace, ranked by relevance and recency. Ranking makes a
 * small first page enough, which is why the default limit stays low.
 */
export function createFindTool(
  context: ComputerToolContext,
  runtime: FffSearchRuntime = fffSearchRuntime
): WorkerAgentTool<typeof FindParams, FindDetails> {
  return defineWorkerTool({
    name: 'find',
    description:
      'Find files by fuzzy path search over the indexed workspace. The pattern matches whole relative paths (not just filenames) and accepts globs; results are ranked by relevance and recency, so the first page is usually enough. Keep patterns to 1-2 terms; extra words narrow. Use path to scope and exclude to cut noise. For file contents use grep; for one directory listing use ls.',
    schema: FindParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({
      key: 'signals_gateway.reply.activity.command_find_files_family',
      bindings: { family: 'find' }
    }),
    async execute(_toolCallId, params): Promise<AgentToolResult<FindDetails>> {
      const workspaceReal = realpathSync(resolve(context.workspaceRoot))

      let root: string
      let query: string
      let pattern: string
      let pageSize: number
      let offset: number
      if (params.cursor !== undefined) {
        const state = runtime.getFindCursor(params.cursor)
        if (!state) {
          return {
            content: [{ type: 'text', text: 'Cursor expired; rerun the search from the first page.' }],
            details: { totalMatched: 0, totalFiles: 0 }
          }
        }
        root = state.root
        query = state.query
        pattern = state.pattern
        pageSize = state.pageSize
        offset = state.nextOffset
      } else {
        const target = resolveSearchTarget(
          { agentHome: context.agentHome, workspaceRoot: context.workspaceRoot },
          params.path
        )
        if (!target.ok) {
          return { content: [{ type: 'text', text: target.message }], details: { totalMatched: 0, totalFiles: 0 } }
        }
        root = target.root
        pattern = params.pattern ?? ''
        pageSize = params.limit ?? DEFAULT_LIMIT
        offset = 0
        const excludes = normalizeExcludes(params.exclude)
        if (root !== workspaceReal) excludes.push(`!${AGENT_RUNTIME_DIRNAME}/`)
        query = buildSearchQuery({ constraint: target.constraint, excludes, pattern })
      }

      const acquired = await runtime.acquire(root, { covering: root !== workspaceReal })
      // fff's `pageIndex` counts items, not pages (verified against 0.10.5).
      const searched = acquired.finder.fileSearch(query, { pageIndex: offset, pageSize })
      if (!searched.ok) throw new Error(`find failed: ${searched.error}`)
      const result = searched.value

      const notices: string[] = []
      const scanning = scanNotice(acquired.finder)
      if (scanning) notices.push(scanning)

      if (result.items.length === 0) {
        if (notices.length > 0) {
          return {
            content: [{ type: 'text', text: `No files found matching pattern\n\n[${notices.join('. ')}]` }],
            details: { totalMatched: 0, totalFiles: result.totalFiles }
          }
        }
        return {
          content: [{ type: 'text', text: 'No files found matching pattern' }],
          details: { totalMatched: 0, totalFiles: result.totalFiles }
        }
      }

      // Trust native ranking: never re-sort engine output. When even the top
      // score is weak the whole page is fuzzy noise — show a sample instead.
      const topScore = result.scores[0]?.total ?? 0
      const weak = topScore < weakScoreThreshold(pattern)
      const shown = weak ? result.items.slice(0, Math.min(WEAK_SAMPLE_SIZE, pageSize)) : result.items
      let output = shown
        .map(item => `${displayPath(acquired.root, workspaceReal, item.relativePath)}${fileAnnotation(item)}`)
        .join('\n')

      const details: FindDetails = { totalMatched: result.totalMatched, totalFiles: result.totalFiles }
      if (weak && shown.length > 0) {
        notices.push(
          `Query "${pattern}" produced only weak scattered fuzzy matches. Output capped at ${shown.length}/${result.totalMatched}; refine the pattern`
        )
      }

      const shownSoFar = offset + result.items.length
      const hasMore = !weak && result.items.length >= pageSize && result.totalMatched > shownSoFar
      if (hasMore) {
        const cursor = runtime.storeFindCursor({
          root: acquired.root,
          query,
          pattern,
          pageSize,
          nextOffset: shownSoFar
        })
        details.cursor = cursor
        notices.push(`${result.totalMatched - shownSoFar} more matches. Continue with cursor="${cursor}"`)
      }

      const clipped = clipLinesToBudget(output, MAX_OUTPUT_CHARS)
      if (clipped.clipped) {
        output = clipped.text
        notices.push(`Output clipped to ${clipped.keptLines} of ${clipped.totalLines} lines`)
      }
      if (notices.length > 0) output += `\n\n[${notices.join('. ')}]`
      return { content: [{ type: 'text', text: output }], details }
    }
  })
}

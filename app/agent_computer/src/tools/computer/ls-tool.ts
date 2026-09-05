import { readdir, realpath, stat } from 'node:fs/promises'
import type { Dirent } from 'node:fs'
import { join, resolve } from 'node:path'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { pathIsWithin } from '../../core/path-boundary'
import { compactActivityPath } from '../activity-summary'
import type { ComputerToolContext } from './context'
import { MAX_OUTPUT_CHARS, clipLinesToBudget } from './format'

const DEFAULT_LIMIT = 500

const LsParams = z
  .object({
    path: z
      .string()
      .optional()
      .describe('Directory to list (absolute, relative, or ~/path). Defaults to the current workspace.'),
    limit: z
      .number()
      .int()
      .min(1)
      .max(2000)
      .optional()
      .describe(`Maximum entries to return (default ${DEFAULT_LIMIT}).`)
  })
  .strict()

interface LsDetails {
  path: string
  entries: number
  truncated: boolean
}

/**
 * The model's directory-listing tool: one directory's complete entries in
 * deterministic alphabetical order. Discovery across the tree belongs to
 * find; this tool answers "what exactly is in this directory".
 */
export function createLsTool(context: ComputerToolContext): WorkerAgentTool<typeof LsParams, LsDetails> {
  return defineWorkerTool({
    name: 'ls',
    description:
      "List one directory's entries sorted alphabetically, with a trailing '/' on directories; dotfiles included. Defaults to the current workspace. Use find to locate files by name across the tree; use ls when you need the complete layout of one directory.",
    schema: LsParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => {
      const path = compactActivityPath(params.path)
      return path
        ? { key: 'signals_gateway.reply.activity.file_list_target', bindings: { path } }
        : { key: 'signals_gateway.reply.activity.file_list' }
    },
    async execute(_toolCallId, params): Promise<AgentToolResult<LsDetails>> {
      const requested = params.path?.trim() || '.'
      const expanded =
        requested === '~'
          ? context.agentHome
          : requested.startsWith('~/')
            ? resolve(context.agentHome, requested.slice(2))
            : resolve(context.workspaceRoot, requested)

      const miss = (text: string): AgentToolResult<LsDetails> => ({
        content: [{ type: 'text', text }],
        details: { path: requested, entries: 0, truncated: false }
      })

      let target: string
      try {
        target = await realpath(expanded)
      } catch {
        return miss(`Path not found: ${requested}`)
      }
      const homeReal = await realpath(resolve(context.agentHome))
      if (!pathIsWithin(homeReal, target)) {
        return miss(
          `Path is outside the agent home: ${requested}. find/grep/ls cover ~ only; use the command tool for other locations.`
        )
      }
      if (!(await stat(target)).isDirectory()) {
        return miss(`Not a directory: ${requested}`)
      }

      let entries: Dirent[]
      try {
        entries = await readdir(target, { withFileTypes: true })
      } catch (error) {
        return miss(`Cannot read directory: ${error instanceof Error ? error.message : String(error)}`)
      }
      entries.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))

      const limit = params.limit ?? DEFAULT_LIMIT
      const rendered: string[] = []
      let limitReached = false
      for (const entry of entries) {
        if (rendered.length >= limit) {
          limitReached = true
          break
        }
        try {
          const entryStat = entry.isSymbolicLink() ? await stat(join(target, entry.name)) : entry
          rendered.push(entryStat.isDirectory() ? `${entry.name}/` : entry.name)
        } catch {
          // A dangling symlink or a file deleted mid-listing is not worth failing the call.
          continue
        }
      }

      if (rendered.length === 0) {
        return {
          content: [{ type: 'text', text: '(empty directory)' }],
          details: { path: requested, entries: 0, truncated: false }
        }
      }

      let output = rendered.join('\n')
      const notices: string[] = []
      if (limitReached) notices.push(`${limit} entries limit reached. Use limit=${Math.min(limit * 2, 2000)} for more`)
      const clipped = clipLinesToBudget(output, MAX_OUTPUT_CHARS)
      if (clipped.clipped) {
        output = clipped.text
        notices.push(`Output clipped to ${clipped.keptLines} of ${clipped.totalLines} entries`)
      }
      if (notices.length > 0) output += `\n\n[${notices.join('. ')}]`
      return {
        content: [{ type: 'text', text: output }],
        details: { path: requested, entries: rendered.length, truncated: limitReached || clipped.clipped }
      }
    }
  })
}

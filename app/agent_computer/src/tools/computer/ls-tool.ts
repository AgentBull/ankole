import { errorMessage, nodeErrorCode } from '../../common/errors'
import { workspacePath } from './commands'
import { scopedPath, driveDeadline } from '../../drive/paths'
import { readdir, stat } from 'node:fs/promises'
import type { Dirent } from 'node:fs'
import { join } from 'node:path'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
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

export function createLsTool(context: ComputerToolContext): WorkerAgentTool<typeof LsParams, LsDetails> {
  return defineWorkerTool({
    name: 'ls',
    description:
      "List one directory's entries sorted alphabetically, with a trailing '/' on directories; dotfiles included. Defaults to the current workspace. Use find to locate files by name across the tree; use ls when you need the complete layout of one directory.",
    schema: LsParams,
    executionMode: 'parallel',
    isReadOnly: true,
    retrySafe: true,
    isDestructive: false,
    describeActivity: params => {
      const path = compactActivityPath(params.path)
      return path
        ? { key: 'conversations.delivery.reply.activity.file_list_target', bindings: { path } }
        : { key: 'conversations.delivery.reply.activity.file_list' }
    },
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<LsDetails>> {
      const requested = params.path?.trim() || '.'
      const expanded = workspacePath(context.agentHome, context.workspaceRoot, requested)

      const miss = (text: string): AgentToolResult<LsDetails> => ({
        content: [{ type: 'text', text }],
        details: { path: requested, entries: 0, truncated: false }
      })

      let target: string
      try {
        target = await scopedPath(
          context.driveView,
          context.agentHome,
          expanded,
          signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : undefined
        )
        if (!(await driveDeadline(stat(target), signal)).isDirectory()) {
          return miss(`Not a directory: ${requested}`)
        }
      } catch (error) {
        return miss(
          nodeErrorCode(error) === 'ENOENT'
            ? `Path not found: ${requested}`
            : `Cannot access ${requested}: ${errorMessage(error)}`
        )
      }

      let entries: Pick<Dirent, 'name' | 'isDirectory' | 'isSymbolicLink'>[]
      try {
        entries = await driveDeadline(readdir(target, { withFileTypes: true }), signal)
        if (context.driveView && target === context.driveView.scope.path) {
          entries = entries.filter(entry => ['Public', 'AgentDrive', 'MyDrive', 'Brain'].includes(entry.name))
          entries.push(
            ...(await driveDeadline(readdir(context.driveView.library.path, { withFileTypes: true }), signal))
          )
          if (context.driveView.chat) {
            entries.push({ name: 'ChatDrive', isDirectory: () => true, isSymbolicLink: () => false })
          }
        }
      } catch (error) {
        return miss(`Cannot read directory: ${errorMessage(error)}`)
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
          const entryStat = entry.isSymbolicLink()
            ? await driveDeadline(
                scopedPath(context.driveView, context.agentHome, join(target, entry.name), signal).then(path =>
                  stat(path)
                ),
                signal
              )
            : entry
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

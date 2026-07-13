import { mkdirSync, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { resolveWorkspacePath } from '../../core/workspace-paths'
import {
  defaultBackgroundCommandRegistry,
  type BackgroundCommandRegistry,
  type BackgroundCommandSnapshot
} from './background-commands'
import { runWorkspaceCommand, type CommandFinished, type CommandInput } from './commands'
import { createContainerTerminals, type ContainerTerminals } from './terminals'

export type { BackgroundCommandSnapshot, BackgroundCommandStatus } from './background-commands'
export type { CommandFinished, CommandInput, CommandOutputMode } from './commands'

export interface ContainerComputer {
  runCommand(input: CommandInput): Promise<CommandFinished>
  backgroundCommands: {
    start(input: CommandInput): Promise<BackgroundCommandSnapshot>
    status(id: string, opts?: { signal?: AbortSignal }): Promise<BackgroundCommandSnapshot | null>
    kill(id: string, opts?: { signal?: AbortSignal }): Promise<BackgroundCommandSnapshot | null>
    list(opts?: { signal?: AbortSignal }): Promise<BackgroundCommandSnapshot[]>
  }
  readFileToBuffer(input: { path: string; cwd?: string }, opts?: { signal?: AbortSignal }): Promise<Buffer | null>
  fs: {
    writeFiles(
      files: Array<{ path: string; content: string | Buffer }>,
      opts?: { cwd?: string; signal?: AbortSignal }
    ): Promise<void>
  }
  terminals: ContainerTerminals
}

interface ContainerComputerOptions {
  backgroundCommandRegistry?: BackgroundCommandRegistry
  /** Operator-managed variables applied to every command and terminal session. */
  workerEnv?: Record<string, string>
}

/**
 * Builds the container Computer facade over the mounted Ankole workspace.
 *
 * The migrated tools were written for a remote `Computer` session. In Ankole
 * the model loop already runs inside Agent Computer, so the same tool contract is satisfied by
 * container filesystem/process/tmux operations rooted at `workspaceRoot`.
 */
export function createContainerComputer(
  workspaceRoot: string,
  executionScopeID: string,
  options: ContainerComputerOptions = {}
): ContainerComputer {
  const root = resolve(workspaceRoot)
  const backgroundCommandRegistry = options.backgroundCommandRegistry ?? defaultBackgroundCommandRegistry
  const backgroundScope = { workspaceRoot: root, executionScopeID }
  const workerEnv = options.workerEnv

  const safePath = (path: string, cwd?: string): string => resolveWorkspacePath(root, path, { cwd })

  return {
    runCommand(input) {
      return runWorkspaceCommand({ workerEnv, ...input }, root)
    },
    backgroundCommands: {
      start(input) {
        return backgroundCommandRegistry.start({ workerEnv, ...input }, backgroundScope)
      },
      status(id) {
        return Promise.resolve(backgroundCommandRegistry.status(id, backgroundScope))
      },
      kill(id) {
        return Promise.resolve(backgroundCommandRegistry.kill(id, backgroundScope))
      },
      list() {
        return Promise.resolve(backgroundCommandRegistry.list(backgroundScope))
      }
    },
    async readFileToBuffer(input) {
      try {
        return await readFile(safePath(input.path, input.cwd))
      } catch (error) {
        if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return null
        throw error
      }
    },
    fs: {
      async writeFiles(files, opts) {
        for (const file of files) {
          const target = safePath(file.path, opts?.cwd)
          mkdirSync(dirname(target), { recursive: true })
          writeFileSync(target, file.content)
        }
      }
    },
    terminals: createContainerTerminals(root, workerEnv)
  }
}

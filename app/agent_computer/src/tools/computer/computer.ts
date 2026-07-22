import { mkdirSync, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import {
  assertCreatablePathWithin,
  assertExistingPathWithin,
  workspacePhysicalRoots
} from '../../core/real-path-boundary'
import { resolveAgentHomePath } from '../../core/agent-home-paths'
import { runWorkspaceCommand, type CommandFinished, type CommandInput } from './commands'

export type { CommandFinished, CommandInput, CommandOutputMode } from './commands'

export interface ContainerComputer {
  runCommand(input: CommandInput): Promise<CommandFinished>
  readFileToBuffer(input: { path: string; cwd?: string }, opts?: { signal?: AbortSignal }): Promise<Buffer | null>
  fs: {
    writeFiles(
      files: Array<{ path: string; content: string | Buffer }>,
      opts?: { cwd?: string; signal?: AbortSignal }
    ): Promise<void>
  }
}

interface ContainerComputerOptions {
  /** Operator-managed variables applied to every command. */
  workerEnv?: Record<string, string>
}

/**
 * Builds the container Computer facade over the mounted Ankole workspace.
 *
 * The migrated tools were written for a remote `Computer` session. In Ankole
 * the model loop already runs inside Agent Computer, so the same tool contract is satisfied by
 * container filesystem and foreground process operations rooted at `workspaceRoot`.
 */
export function createContainerComputer(
  agentHome: string,
  workspaceRoot: string,
  options: ContainerComputerOptions = {}
): ContainerComputer {
  const root = resolve(agentHome)
  const cwd = resolve(workspaceRoot)
  const physicalRoots = workspacePhysicalRoots(root)
  const workerEnv = options.workerEnv

  const safePath = (path: string, inputCwd?: string): string =>
    resolveAgentHomePath(root, path, { cwd: inputCwd ?? cwd })

  return {
    runCommand(input) {
      return runWorkspaceCommand({ workerEnv, ...input }, root, cwd)
    },
    async readFileToBuffer(input) {
      try {
        const path = safePath(input.path, input.cwd)
        return await readFile(assertExistingPathWithin(physicalRoots, path, 'path resolves outside workspace roots'))
      } catch (error) {
        if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return null
        throw error
      }
    },
    fs: {
      async writeFiles(files, opts) {
        for (const file of files) {
          const target = assertCreatablePathWithin(
            physicalRoots,
            safePath(file.path, opts?.cwd),
            'path resolves outside workspace roots'
          )
          mkdirSync(dirname(target), { recursive: true })
          writeFileSync(target, file.content)
        }
      }
    }
  }
}

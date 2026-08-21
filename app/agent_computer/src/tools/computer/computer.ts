import { isAbsolute, join, normalize, resolve } from 'node:path'
import { runWorkspaceCommand, runWorkspaceProcess, type CommandFinished, type CommandInput } from './commands'

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
  /** Trusted turn variables applied to every command. */
  runtimeEnv?: Record<string, string>
}

const ReadFileScript = `
import { readFile } from 'node:fs/promises'
try {
  process.stdout.write(await readFile(process.argv[1]))
} catch (error) {
  if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') process.exit(44)
  console.error(errorMessage(error))
  process.exit(1)
}
`

const WriteFileScript = `
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { errorMessage } from '../../common/errors'
const target = process.argv[1]
await mkdir(dirname(target), { recursive: true })
await writeFile(target, await Bun.stdin.bytes())
`

/**
 * Builds the container Computer facade over the mounted Ankole workspace.
 *
 * The migrated tools were written for a remote `Computer` session. In Ankole
 * the model loop already runs inside Agent Computer, so the same tool contract is satisfied by
 * foreground operations inside the existing bubblewrap filesystem view.
 */
export function createContainerComputer(
  agentHome: string,
  workspaceRoot: string,
  options: ContainerComputerOptions = {}
): ContainerComputer {
  const root = resolve(agentHome)
  const cwd = resolve(workspaceRoot)
  const workerEnv = options.workerEnv
  const runtimeEnv = options.runtimeEnv

  return {
    runCommand(input) {
      return runWorkspaceCommand({ ...input, workerEnv, runtimeEnv }, root, cwd)
    },
    async readFileToBuffer(input, opts) {
      const target = computerPath(root, cwd, input.path, input.cwd)
      const result = await runWorkspaceProcess(
        {
          commandArgv: [process.execPath, '-e', ReadFileScript, target],
          workerEnv,
          runtimeEnv,
          signal: opts?.signal
        },
        root,
        cwd
      )
      if (result.exitCode === 44) return null
      if (result.exitCode !== 0) throw processError('read file', target, result)
      return result.stdout
    },
    fs: {
      async writeFiles(files, opts) {
        for (const file of files) {
          const target = computerPath(root, cwd, file.path, opts?.cwd)
          const result = await runWorkspaceProcess(
            {
              commandArgv: [process.execPath, '-e', WriteFileScript, target],
              workerEnv,
              runtimeEnv,
              stdin: file.content,
              signal: opts?.signal
            },
            root,
            cwd
          )
          if (result.exitCode !== 0) throw processError('write file', target, result)
        }
      }
    }
  }
}

/**
 * Resolves tool path syntax without deciding which paths the sandbox permits.
 */
function computerPath(agentHome: string, workspaceRoot: string, path: string, cwd?: string): string {
  const base = cwd ? expandComputerPath(agentHome, workspaceRoot, cwd) : workspaceRoot
  return expandComputerPath(agentHome, base, path)
}

function expandComputerPath(agentHome: string, cwd: string, path: string): string {
  const expanded = path === '~' ? agentHome : path.startsWith('~/') ? join(agentHome, path.slice(2)) : path
  return isAbsolute(expanded) ? resolve(normalize(expanded)) : resolve(cwd, normalize(expanded))
}

function processError(operation: string, path: string, result: { exitCode: number; stderr: Buffer }): Error {
  const detail = result.stderr.toString('utf8').trim()
  return new Error(`${operation} failed for ${path}: ${detail || `exit code ${result.exitCode}`}`)
}

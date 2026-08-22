import { isAbsolute, join, normalize, resolve } from 'node:path'
import { runWorkspaceCommand, runWorkspaceProcess, type CommandFinished, type CommandInput } from './commands'

export type { CommandFinished, CommandInput, CommandOutputMode } from './commands'

/** One paginated slice of a text file, read without materializing the file. */
export interface ReadFileWindow {
  /** First bytes of the file (up to 8 KB), for the binary sniff. */
  sniff: Buffer
  totalLines: number
  /** Decoded lines `[offset, offset + limit)`, each clipped to its first 8 KB. */
  lines: string[]
}

export interface ContainerComputer {
  runCommand(input: CommandInput): Promise<CommandFinished>
  readFileToBuffer(input: { path: string; cwd?: string }, opts?: { signal?: AbortSignal }): Promise<Buffer | null>
  readFileWindow(
    input: { path: string; cwd?: string; offset: number; limit: number },
    opts?: { signal?: AbortSignal }
  ): Promise<ReadFileWindow | null>
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

// These template strings are standalone `bun -e` programs, not part of this
// module — they run inside the sandbox with no access to our imports, so
// they must stay self-contained.
const ReadFileScript = `
import { readFile } from 'node:fs/promises'
try {
  process.stdout.write(await readFile(process.argv[1]))
} catch (error) {
  if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') process.exit(44)
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}
`

// Streams the file instead of materializing it: only the requested line window
// (each line clipped to its first 8 KB, more than the 2000-char render clip can
// use), the 8 KB binary-sniff prefix, and the total line count come back as JSON.
// Line boundaries are LF bytes; 0x0A never occurs inside a UTF-8 sequence, so
// byte scanning matches decoding the whole file and splitting on newlines.
const ReadFileWindowScript = `
import { createReadStream } from 'node:fs'
const target = process.argv[1]
const firstLine = Number(process.argv[2])
const lastLine = firstLine + Number(process.argv[3]) - 1
const maxLineBytes = 8192
const sniffBytes = 8192
try {
  const sniff = []
  let sniffLength = 0
  const lines = []
  let current = []
  let currentLength = 0
  let line = 1
  let sawBytes = false
  let endedWithNewline = false
  for await (const part of createReadStream(target)) {
    const data = Buffer.isBuffer(part) ? part : Buffer.from(part)
    if (data.length === 0) continue
    sawBytes = true
    endedWithNewline = data[data.length - 1] === 10
    if (sniffLength < sniffBytes) {
      const take = Math.min(data.length, sniffBytes - sniffLength)
      sniff.push(data.subarray(0, take))
      sniffLength += take
    }
    let position = 0
    while (position < data.length) {
      const newline = data.indexOf(10, position)
      const end = newline === -1 ? data.length : newline
      if (line >= firstLine && line <= lastLine && currentLength < maxLineBytes) {
        const take = Math.min(end - position, maxLineBytes - currentLength)
        current.push(data.subarray(position, position + take))
        currentLength += take
      }
      if (newline === -1) break
      if (line >= firstLine && line <= lastLine) {
        lines.push(Buffer.concat(current).toString('utf8'))
        current = []
        currentLength = 0
      }
      line += 1
      position = newline + 1
    }
  }
  if (sawBytes && !endedWithNewline && line >= firstLine && line <= lastLine) {
    lines.push(Buffer.concat(current).toString('utf8'))
  }
  const totalLines = sawBytes ? (endedWithNewline ? line - 1 : line) : 0
  process.stdout.write(JSON.stringify({ totalLines, lines, sniff: Buffer.concat(sniff).toString('base64') }))
} catch (error) {
  if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') process.exit(44)
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}
`

const WriteFileScript = `
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
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
    async readFileWindow(input, opts) {
      const target = computerPath(root, cwd, input.path, input.cwd)
      const result = await runWorkspaceProcess(
        {
          commandArgv: [
            process.execPath,
            '-e',
            ReadFileWindowScript,
            target,
            String(input.offset),
            String(input.limit)
          ],
          workerEnv,
          runtimeEnv,
          signal: opts?.signal
        },
        root,
        cwd
      )
      if (result.exitCode === 44) return null
      if (result.exitCode !== 0) throw processError('read file', target, result)
      const payload = JSON.parse(result.stdout.toString('utf8')) as {
        totalLines: number
        lines: string[]
        sniff: string
      }
      return { sniff: Buffer.from(payload.sniff, 'base64'), totalLines: payload.totalLines, lines: payload.lines }
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

import { resolve } from 'node:path'
import { bubblewrapArgv } from './bubblewrap'
import { commandArgvWithOptionalTimeout, workspacePath, type CommandInput, type CommandOutputMode } from './commands'
import { commandEnv } from './env'

export type BackgroundCommandStatus = 'running' | 'exited' | 'killed'

export interface BackgroundCommandSnapshot {
  id: string
  command: string
  cwd: string
  status: BackgroundCommandStatus
  exitCode?: number
  startedAtUnixMs: number
  endedAtUnixMs?: number
  output(mode?: CommandOutputMode, opts?: { incremental?: boolean; signal?: AbortSignal }): Promise<string>
}

export interface BackgroundCommandScope {
  workspaceRoot: string
  executionScopeID: string
}

type MutableBackgroundCommand = {
  scopeKey: string
  id: string
  command: string
  cwd: string
  status: BackgroundCommandStatus
  exitCode?: number
  startedAtUnixMs: number
  endedAtUnixMs?: number
  stdout: string
  stderr: string
  observedStdoutChars: number
  observedStderrChars: number
  process: ReturnType<typeof Bun.spawn>
}

const BACKGROUND_OUTPUT_MAX_CHARS = 200_000
// Cap on tracked background commands. Once exceeded, finished (non-running) entries are evicted
// oldest-first so a long-lived worker that starts many background commands does not grow the
// registry without bound. Running commands are never evicted.
const BACKGROUND_COMMANDS_MAX = 64

export class BackgroundCommandRegistry {
  private readonly commands = new Map<string, MutableBackgroundCommand>()

  async start(input: CommandInput, scope: BackgroundCommandScope): Promise<BackgroundCommandSnapshot> {
    if (input.signal?.aborted) throw new Error('command aborted')

    const workspaceRoot = resolve(scope.workspaceRoot)
    const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
    const env = commandEnv(input.env, { workerEnv: input.workerEnv })
    const argv = bubblewrapArgv({
      workspaceRoot,
      cwd,
      env,
      commandArgv: commandArgvWithOptionalTimeout(input)
    })
    const id = `bg-${crypto.randomUUID()}`
    const commandText = [input.cmd, ...(input.args ?? [])].join(' ')

    const proc = Bun.spawn(argv, {
      cwd: workspaceRoot,
      env,
      stdout: 'pipe',
      stderr: 'pipe'
    })

    const command: MutableBackgroundCommand = {
      scopeKey: this.scopeKey({ ...scope, workspaceRoot }),
      id,
      command: commandText,
      cwd,
      status: 'running',
      startedAtUnixMs: Date.now(),
      stdout: '',
      stderr: '',
      observedStdoutChars: 0,
      observedStderrChars: 0,
      process: proc
    }

    this.commands.set(id, command)
    this.evictFinished()
    void collectBackgroundStream(proc.stdout, chunk => {
      const next = appendBounded(command.stdout, chunk)
      command.stdout = next.text
      command.observedStdoutChars = Math.max(0, command.observedStdoutChars - next.droppedChars)
    })
    void collectBackgroundStream(proc.stderr, chunk => {
      const next = appendBounded(command.stderr, chunk)
      command.stderr = next.text
      command.observedStderrChars = Math.max(0, command.observedStderrChars - next.droppedChars)
    })
    proc.exited.then(exitCode => {
      if (command.status === 'running') {
        command.status = 'exited'
        command.endedAtUnixMs = Date.now()
      }
      command.exitCode = exitCode ?? 124
    })

    return commandSnapshot(command)
  }

  status(id: string, scope: BackgroundCommandScope): BackgroundCommandSnapshot | null {
    const command = this.scopedCommand(id, scope)
    return command ? commandSnapshot(command) : null
  }

  kill(id: string, scope: BackgroundCommandScope): BackgroundCommandSnapshot | null {
    const command = this.scopedCommand(id, scope)
    if (!command) return null
    if (command.status === 'running') {
      command.status = 'killed'
      command.endedAtUnixMs = Date.now()
      command.process.kill()
    }
    return commandSnapshot(command)
  }

  list(scope: BackgroundCommandScope): BackgroundCommandSnapshot[] {
    const scopeKey = this.scopeKey(scope)
    return Array.from(this.commands.values())
      .filter(command => command.scopeKey === scopeKey)
      .map(commandSnapshot)
  }

  private evictFinished(): void {
    if (this.commands.size <= BACKGROUND_COMMANDS_MAX) return
    const finished = Array.from(this.commands.values())
      .filter(command => command.status !== 'running')
      .sort((a, b) => (a.endedAtUnixMs ?? 0) - (b.endedAtUnixMs ?? 0))
    for (const command of finished) {
      if (this.commands.size <= BACKGROUND_COMMANDS_MAX) break
      this.commands.delete(command.id)
    }
  }

  private scopedCommand(id: string, scope: BackgroundCommandScope): MutableBackgroundCommand | null {
    const command = this.commands.get(id)
    if (!command || command.scopeKey !== this.scopeKey(scope)) return null
    return command
  }

  private scopeKey(scope: BackgroundCommandScope): string {
    return `${resolve(scope.workspaceRoot)}\u0000${scope.executionScopeID}`
  }
}

export const defaultBackgroundCommandRegistry = new BackgroundCommandRegistry()

/**
 * Returns an immutable snapshot facade over a mutable background command.
 */
function commandSnapshot(command: MutableBackgroundCommand): BackgroundCommandSnapshot {
  return {
    id: command.id,
    command: command.command,
    cwd: command.cwd,
    status: command.status,
    ...(command.exitCode === undefined ? {} : { exitCode: command.exitCode }),
    startedAtUnixMs: command.startedAtUnixMs,
    ...(command.endedAtUnixMs === undefined ? {} : { endedAtUnixMs: command.endedAtUnixMs }),
    async output(mode = 'both', opts) {
      if (opts?.incremental) return incrementalBackgroundOutput(command, mode)
      if (mode === 'stdout') return command.stdout
      if (mode === 'stderr') return command.stderr
      return [command.stdout, command.stderr].filter(Boolean).join(command.stderr && command.stdout ? '\n' : '')
    }
  }
}

/**
 * Returns only the new output since the last incremental read.
 */
function incrementalBackgroundOutput(command: MutableBackgroundCommand, mode: CommandOutputMode): string {
  if (mode === 'stdout') {
    const output = command.stdout.slice(command.observedStdoutChars)
    command.observedStdoutChars = command.stdout.length
    return output
  }
  if (mode === 'stderr') {
    const output = command.stderr.slice(command.observedStderrChars)
    command.observedStderrChars = command.stderr.length
    return output
  }

  const stdout = command.stdout.slice(command.observedStdoutChars)
  const stderr = command.stderr.slice(command.observedStderrChars)
  command.observedStdoutChars = command.stdout.length
  command.observedStderrChars = command.stderr.length
  return [stdout, stderr].filter(Boolean).join(stdout && stderr ? '\n' : '')
}

/**
 * Continuously appends a background process stream to its bounded buffer.
 */
async function collectBackgroundStream(
  stream: ReadableStream<Uint8Array> | null,
  append: (chunk: string) => void
): Promise<void> {
  if (!stream) return

  const reader = stream.getReader()
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) return
      if (value) append(Buffer.from(value).toString('utf8'))
    }
  } catch {
    return
  } finally {
    reader.releaseLock()
  }
}

/**
 * Appends output while keeping only the newest bounded tail.
 */
function appendBounded(current: string, chunk: string): { droppedChars: number; text: string } {
  const next = current + chunk
  if (next.length <= BACKGROUND_OUTPUT_MAX_CHARS) return { droppedChars: 0, text: next }
  const droppedChars = next.length - BACKGROUND_OUTPUT_MAX_CHARS
  return { droppedChars, text: next.slice(droppedChars) }
}

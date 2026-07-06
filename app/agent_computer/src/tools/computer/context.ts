import { mkdirSync, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { createHash } from 'node:crypto'
import type { JsonObject } from '@pleisto/active-support'
import { resolveWorkspacePath, WORKSPACE_MODEL_ROOT } from '../../core/workspace-paths'
import { bubblewrapArgv } from './bubblewrap'

export type CommandOutputMode = 'stdout' | 'stderr' | 'both'

export interface CommandFinished {
  exitCode: number
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
}

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

export interface ContainerComputer {
  runCommand(input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  }): Promise<CommandFinished>
  backgroundCommands: {
    start(input: {
      cmd: string
      args?: string[]
      cwd?: string
      env?: Record<string, string>
      timeoutMs?: number
      signal?: AbortSignal
    }): Promise<BackgroundCommandSnapshot>
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
  terminals: {
    list(opts?: { signal?: AbortSignal }): Promise<Array<{ name: string; windows: number; attached: boolean }>>
    start(
      name: string,
      opts: { command: string; cwd?: string; cols?: number; rows?: number },
      runOpts?: { signal?: AbortSignal }
    ): Promise<{ name: string; status: string }>
    send(
      name: string,
      opts: { input?: string; keys?: string[]; enter?: boolean },
      runOpts?: { signal?: AbortSignal }
    ): Promise<{ name: string; status: string }>
    capture(
      name: string,
      opts?: { lines?: number },
      runOpts?: { signal?: AbortSignal }
    ): Promise<{ name: string; screen: string }>
    kill(name: string, opts?: { signal?: AbortSignal }): Promise<{ name: string; status: string }>
  }
}

/** Shared per-run state for the computer tools (workspace root + execution scope). */
export interface ComputerToolContext {
  /** Current Ankole Agent UID; used to namespace browser/session artifacts. */
  agentUid: string
  /** Session-local /workspace root for the active turn. */
  workspaceRoot: string
  /**
   * Conversation-level execution scope. Persistent shells, tmux names, browser
   * execution sessions/captures/artifacts are namespaced by this so concurrent
   * conversations of one agent do not share execution state.
   */
  executionScopeId: string
  /** Decrypted remote browser CDP config for this turn, resolved by control-plane RPC. */
  browserRemoteCdpConfig?: JsonObject | null
  /** Local browser idle release TTL in milliseconds, resolved by AppConfigure. */
  localBrowserIdleTtlMs?: number
  /** Resolve-or-create the agent's container computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<ContainerComputer>
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
const backgroundCommands = new Map<string, MutableBackgroundCommand>()

/**
 * Evicts old finished background commands while never dropping running ones.
 */
function evictFinishedBackgroundCommands(): void {
  if (backgroundCommands.size <= BACKGROUND_COMMANDS_MAX) return
  const finished = Array.from(backgroundCommands.values())
    .filter(command => command.status !== 'running')
    .sort((a, b) => (a.endedAtUnixMs ?? 0) - (b.endedAtUnixMs ?? 0))
  for (const command of finished) {
    if (backgroundCommands.size <= BACKGROUND_COMMANDS_MAX) break
    backgroundCommands.delete(command.id)
  }
}

/**
 * Builds the container Computer facade over the mounted Ankole workspace.
 *
 * The migrated tools were written for a remote `Computer` session. In Ankole
 * the model loop already runs inside Agent Computer, so the same tool contract is satisfied by
 * container filesystem/process/tmux operations rooted at `workspaceRoot`.
 */
export function createContainerComputer(workspaceRoot: string, executionScopeId: string): ContainerComputer {
  const root = resolve(workspaceRoot)
  const backgroundScopeKey = scopedBackgroundCommandKey(root, executionScopeId)

  const safePath = (path: string, cwd?: string): string => resolveWorkspacePath(root, path, { cwd })

  const runTmux = async (args: string[], opts?: { signal?: AbortSignal }): Promise<CommandFinished> =>
    runContainerControlCommand({ cmd: 'tmux', args, signal: opts?.signal }, root)

  return {
    runCommand(input) {
      return runBubblewrappedCommand(input, root)
    },
    backgroundCommands: {
      start(input) {
        return startBackgroundCommand(input, root, backgroundScopeKey)
      },
      status(id) {
        return Promise.resolve(backgroundSnapshot(id, backgroundScopeKey))
      },
      kill(id) {
        const command = scopedBackgroundCommand(id, backgroundScopeKey)
        if (!command) return Promise.resolve(null)
        if (command.status === 'running') {
          command.status = 'killed'
          command.endedAtUnixMs = Date.now()
          command.process.kill()
        }
        return Promise.resolve(commandSnapshot(command))
      },
      list() {
        return Promise.resolve(
          Array.from(backgroundCommands.values())
            .filter(command => command.scopeKey === backgroundScopeKey)
            .map(commandSnapshot)
        )
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
    terminals: {
      async list(opts) {
        const result = await runTmux(
          ['list-sessions', '-F', '#{session_name}\t#{session_windows}\t#{session_attached}'],
          opts
        )
        const output = await result.output('stdout', opts)
        if (result.exitCode !== 0 && output.trim().length === 0) return []
        return output
          .split(/\r?\n/)
          .filter(Boolean)
          .map(line => {
            const [name = '', windows = '0', attached = '0'] = line.split('\t')
            return {
              name,
              windows: Number.parseInt(windows, 10) || 0,
              attached: attached === '1'
            }
          })
      },
      async start(name, opts, runOpts) {
        const cwd = workspacePath(root, opts.cwd ?? '/workspace')
        mkdirSync(cwd, { recursive: true })
        const size = ['-x', String(opts.cols ?? 140), '-y', String(opts.rows ?? 40)]
        const result = await runTmux(['new-session', '-d', '-s', name, '-c', cwd, ...size, opts.command], runOpts)
        if (result.exitCode !== 0) throw new Error(await result.output('both', runOpts))
        return { name, status: 'started' }
      },
      async send(name, opts, runOpts) {
        const keys = [...(opts.keys ?? [])]
        const shouldPressEnter = opts.enter ?? opts.input !== undefined
        if (shouldPressEnter) keys.push('Enter')
        if (opts.input !== undefined && opts.input.length > 0) {
          const result = await runTmux(['send-keys', '-t', name, '-l', '--', opts.input], runOpts)
          if (result.exitCode !== 0) throw new Error(await result.output('both', runOpts))
        }
        if (keys.length > 0) {
          const result = await runTmux(['send-keys', '-t', name, ...keys], runOpts)
          if (result.exitCode !== 0) throw new Error(await result.output('both', runOpts))
        }
        return { name, status: 'sent' }
      },
      async capture(name, opts, runOpts) {
        const lines = Math.max(1, Math.min(opts?.lines ?? 80, 2000))
        const result = await runTmux(['capture-pane', '-pt', name, '-S', `-${lines}`], runOpts)
        if (result.exitCode !== 0) throw new Error(await result.output('both', runOpts))
        return { name, screen: await result.output('stdout', runOpts) }
      },
      async kill(name, opts) {
        const result = await runTmux(['kill-session', '-t', name], opts)
        if (result.exitCode !== 0) throw new Error(await result.output('both', opts))
        return { name, status: 'killed' }
      }
    }
  }
}

/**
 * Derives a short, stable tag used to namespace worker-side names (shell names,
 * tmux sessions, artifact dirs) by execution scope.
 *
 * The raw `executionScopeId` is an arbitrary conversation id, too long and not
 * guaranteed safe for shell/tmux identifiers. Hashing makes it deterministic
 * across turns and process restarts; 8 chars is sufficient because this is only
 * a namespace, not a security boundary.
 */
export function executionScopeTag(context: Pick<ComputerToolContext, 'executionScopeId'>): string {
  return createHash('sha256').update(context.executionScopeId).digest('hex').slice(0, 8)
}

/**
 * Resolves a path against the workspace root.
 */
function workspacePath(root: string, path: string): string {
  return resolveWorkspacePath(root, path)
}

/**
 * Runs one foreground command inside bubblewrap.
 */
async function runBubblewrappedCommand(
  input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  },
  workspaceRoot: string
): Promise<CommandFinished> {
  if (input.signal?.aborted) {
    return finishedCommand(130, '', 'command aborted')
  }

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const env = commandEnv(input.env)
  const commandArgv =
    input.timeoutMs === undefined
      ? [input.cmd, ...(input.args ?? [])]
      : ['timeout', `${Math.max(1, Math.ceil(input.timeoutMs / 1000))}s`, input.cmd, ...(input.args ?? [])]
  const argv = bubblewrapArgv({ workspaceRoot, cwd, env, commandArgv })

  const proc = Bun.spawn(argv, {
    cwd: workspaceRoot,
    env,
    stdout: 'pipe',
    stderr: 'pipe'
  })

  let aborted = false
  const abort = () => {
    aborted = true
    proc.kill()
  }

  input.signal?.addEventListener('abort', abort, { once: true })

  try {
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      readableToUtf8(proc.stdout),
      readableToUtf8(proc.stderr)
    ])

    return finishedCommand(exitCode ?? 124, stdout, aborted && stderr.length === 0 ? 'command aborted' : stderr)
  } finally {
    input.signal?.removeEventListener('abort', abort)
  }
}

/**
 * Runs Agent Computer control processes that must share container runtime state.
 *
 * This is intentionally not exposed through the model-facing `command` tool.
 * `interactive_terminal` is backed by a tmux server, and wrapping every tmux
 * control command in a fresh bubblewrap `/tmp` would make the session socket
 * disappear between `start`, `send`, `capture`, and `kill`.
 */
async function runContainerControlCommand(
  input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  },
  workspaceRoot: string
): Promise<CommandFinished> {
  if (input.signal?.aborted) {
    return finishedCommand(130, '', 'command aborted')
  }

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const timeoutSeconds = Math.max(1, Math.ceil((input.timeoutMs ?? 60_000) / 1000))
  const env = commandEnv(input.env)
  const argv = ['timeout', `${timeoutSeconds}s`, input.cmd, ...(input.args ?? [])]

  const proc = Bun.spawn(argv, {
    cwd,
    env,
    stdout: 'pipe',
    stderr: 'pipe'
  })

  let aborted = false
  const abort = () => {
    aborted = true
    proc.kill()
  }

  input.signal?.addEventListener('abort', abort, { once: true })

  try {
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      readableToUtf8(proc.stdout),
      readableToUtf8(proc.stderr)
    ])

    return finishedCommand(exitCode ?? 124, stdout, aborted && stderr.length === 0 ? 'command aborted' : stderr)
  } finally {
    input.signal?.removeEventListener('abort', abort)
  }
}

/**
 * Starts a long-running background command inside bubblewrap and registers it
 * under the current execution scope.
 */
async function startBackgroundCommand(
  input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  },
  workspaceRoot: string,
  scopeKey: string
): Promise<BackgroundCommandSnapshot> {
  if (input.signal?.aborted) {
    throw new Error('command aborted')
  }

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const env = commandEnv(input.env)
  const commandArgv =
    input.timeoutMs === undefined
      ? [input.cmd, ...(input.args ?? [])]
      : ['timeout', `${Math.max(1, Math.ceil(input.timeoutMs / 1000))}s`, input.cmd, ...(input.args ?? [])]
  const argv = bubblewrapArgv({ workspaceRoot, cwd, env, commandArgv })
  const id = `bg-${crypto.randomUUID()}`
  const commandText = [input.cmd, ...(input.args ?? [])].join(' ')

  const proc = Bun.spawn(argv, {
    cwd: workspaceRoot,
    env,
    stdout: 'pipe',
    stderr: 'pipe'
  })

  const command: MutableBackgroundCommand = {
    scopeKey,
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

  backgroundCommands.set(id, command)
  evictFinishedBackgroundCommands()
  collectBackgroundStream(proc.stdout, chunk => {
    const next = appendBounded(command.stdout, chunk)
    command.stdout = next.text
    command.observedStdoutChars = Math.max(0, command.observedStdoutChars - next.droppedChars)
  })
  collectBackgroundStream(proc.stderr, chunk => {
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

/**
 * Looks up a background command only inside the current execution scope.
 */
function scopedBackgroundCommand(id: string, scopeKey: string): MutableBackgroundCommand | null {
  const command = backgroundCommands.get(id)
  if (!command || command.scopeKey !== scopeKey) return null
  return command
}

/**
 * Returns a snapshot for a scoped background command.
 */
function backgroundSnapshot(id: string, scopeKey: string): BackgroundCommandSnapshot | null {
  const command = scopedBackgroundCommand(id, scopeKey)
  return command ? commandSnapshot(command) : null
}

/**
 * Builds the in-memory namespace key for background command ownership.
 */
function scopedBackgroundCommandKey(workspaceRoot: string, executionScopeId: string): string {
  return `${workspaceRoot}\u0000${executionScopeId}`
}

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

/**
 * Builds the allowlisted command environment passed into bwrap.
 */
function commandEnv(inputEnv: Record<string, string> | undefined): Record<string, string> {
  const shellBootstrap = process.env.BASH_ENV ?? '/etc/profile.d/ankole-agent-computer.sh'
  const env: Record<string, string> = {
    PATH: commandPath(process.env.PATH),
    HOME: process.env.HOME ?? WORKSPACE_MODEL_ROOT,
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    SHELL: process.env.SHELL ?? '/bin/bash',
    BASH_ENV: shellBootstrap,
    ENV: process.env.ENV ?? shellBootstrap,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: process.env.CODEX_UNSAFE_ALLOW_NO_SANDBOX ?? '1',
    ANKOLE_WORKSPACE_ROOT: process.env.ANKOLE_WORKSPACE_ROOT ?? WORKSPACE_MODEL_ROOT
  }

  for (const [key, value] of Object.entries(inputEnv ?? {})) {
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) env[key] = value
  }

  return env
}

/**
 * Ensures core command directories appear at the front of PATH.
 */
function commandPath(path: string | undefined): string {
  const required = ['/usr/local/bin', '/usr/bin', '/bin']
  const current = path?.split(':').filter(Boolean) ?? []
  return [...required, ...current.filter(entry => !required.includes(entry))].join(':')
}

/**
 * Reads a stream fully as UTF-8 text.
 */
async function readableToUtf8(stream: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!stream) return ''
  return Buffer.from(await new Response(stream).arrayBuffer()).toString('utf8')
}

/**
 * Builds the completed-command facade returned by command execution.
 */
function finishedCommand(exitCode: number, stdout: string, stderr: string): CommandFinished {
  return {
    exitCode,
    async output(mode = 'both') {
      if (mode === 'stdout') return stdout
      if (mode === 'stderr') return stderr
      return [stdout, stderr].filter(Boolean).join(stderr && stdout ? '\n' : '')
    }
  }
}

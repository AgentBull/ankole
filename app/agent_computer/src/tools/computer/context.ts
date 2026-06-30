import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, normalize, resolve } from 'node:path'
import { createHash } from 'node:crypto'
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
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
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
  /** Resolve-or-create the agent's container computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<ContainerComputer>
}

type MutableBackgroundCommand = {
  id: string
  command: string
  cwd: string
  status: BackgroundCommandStatus
  exitCode?: number
  startedAtUnixMs: number
  endedAtUnixMs?: number
  stdout: string
  stderr: string
  process: ReturnType<typeof Bun.spawn>
}

const BACKGROUND_OUTPUT_MAX_CHARS = 200_000
// Cap on tracked background commands. Once exceeded, finished (non-running) entries are evicted
// oldest-first so a long-lived worker that starts many background commands does not grow the
// registry without bound. Running commands are never evicted.
const BACKGROUND_COMMANDS_MAX = 64
const backgroundCommands = new Map<string, MutableBackgroundCommand>()

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
 * The migrated tools were written for a remote `Computer` session. In Ankole the AI SDK loop
 * already runs inside Agent Computer, so the same tool contract is satisfied by
 * container filesystem/process/tmux operations rooted at `workspaceRoot`.
 */
export function createContainerComputer(workspaceRoot: string): ContainerComputer {
  const root = resolve(workspaceRoot)

  const safePath = (path: string, cwd?: string): string => {
    const base = cwd ? workspacePath(root, cwd) : root
    const normalized = normalize(path)
    const resolved = normalized.startsWith('/workspace')
      ? resolve(root, `.${normalized.slice('/workspace'.length)}`)
      : normalized.startsWith('/')
        ? resolve(root, `.${normalized}`)
        : resolve(base, normalized)

    if (resolved !== root && !resolved.startsWith(`${root}/`)) {
      throw new Error('path escapes workspace root')
    }
    return resolved
  }

  const runTmux = async (args: string[], opts?: { signal?: AbortSignal }): Promise<CommandFinished> =>
    runContainerControlCommand({ cmd: 'tmux', args, signal: opts?.signal }, root)

  return {
    runCommand(input) {
      return runBubblewrappedCommand(input, root)
    },
    backgroundCommands: {
      start(input) {
        return startBackgroundCommand(input, root)
      },
      status(id) {
        return Promise.resolve(backgroundSnapshot(id))
      },
      kill(id) {
        const command = backgroundCommands.get(id)
        if (!command) return Promise.resolve(null)
        if (command.status === 'running') {
          command.status = 'killed'
          command.endedAtUnixMs = Date.now()
          command.process.kill()
        }
        return Promise.resolve(commandSnapshot(command))
      },
      list() {
        return Promise.resolve(Array.from(backgroundCommands.values()).map(commandSnapshot))
      }
    },
    async readFileToBuffer(input) {
      try {
        return readFileSync(safePath(input.path, input.cwd))
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
        if (opts.input !== undefined) keys.unshift(opts.input)
        if (opts.enter ?? opts.input !== undefined) keys.push('Enter')
        const result = await runTmux(['send-keys', '-t', name, ...keys], runOpts)
        if (result.exitCode !== 0) throw new Error(await result.output('both', runOpts))
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

function workspacePath(root: string, path: string): string {
  const normalized = normalize(path)
  const relative = normalized.startsWith('/workspace')
    ? normalized.slice('/workspace'.length)
    : normalized.startsWith('/')
      ? normalized
      : `/${normalized}`
  const resolved = resolve(root, `.${relative}`)
  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('path escapes workspace root')
  }
  return resolved
}

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
  const timeoutSeconds = Math.max(1, Math.ceil((input.timeoutMs ?? 60_000) / 1000))
  const env = commandEnv(input.env)
  const commandArgv = ['timeout', `${timeoutSeconds}s`, input.cmd, ...(input.args ?? [])]
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

async function startBackgroundCommand(
  input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  },
  workspaceRoot: string
): Promise<BackgroundCommandSnapshot> {
  if (input.signal?.aborted) {
    throw new Error('command aborted')
  }

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const timeoutSeconds = Math.max(1, Math.ceil((input.timeoutMs ?? 1_800_000) / 1000))
  const env = commandEnv(input.env)
  const commandArgv = ['timeout', `${timeoutSeconds}s`, input.cmd, ...(input.args ?? [])]
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
    id,
    command: commandText,
    cwd,
    status: 'running',
    startedAtUnixMs: Date.now(),
    stdout: '',
    stderr: '',
    process: proc
  }

  backgroundCommands.set(id, command)
  evictFinishedBackgroundCommands()
  collectBackgroundStream(proc.stdout, chunk => {
    command.stdout = appendBounded(command.stdout, chunk)
  })
  collectBackgroundStream(proc.stderr, chunk => {
    command.stderr = appendBounded(command.stderr, chunk)
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

function backgroundSnapshot(id: string): BackgroundCommandSnapshot | null {
  const command = backgroundCommands.get(id)
  return command ? commandSnapshot(command) : null
}

function commandSnapshot(command: MutableBackgroundCommand): BackgroundCommandSnapshot {
  return {
    id: command.id,
    command: command.command,
    cwd: command.cwd,
    status: command.status,
    ...(command.exitCode === undefined ? {} : { exitCode: command.exitCode }),
    startedAtUnixMs: command.startedAtUnixMs,
    ...(command.endedAtUnixMs === undefined ? {} : { endedAtUnixMs: command.endedAtUnixMs }),
    async output(mode = 'both') {
      if (mode === 'stdout') return command.stdout
      if (mode === 'stderr') return command.stderr
      return [command.stdout, command.stderr].filter(Boolean).join(command.stderr && command.stdout ? '\n' : '')
    }
  }
}

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

function appendBounded(current: string, chunk: string): string {
  const next = current + chunk
  if (next.length <= BACKGROUND_OUTPUT_MAX_CHARS) return next
  return next.slice(next.length - BACKGROUND_OUTPUT_MAX_CHARS)
}

function commandEnv(inputEnv: Record<string, string> | undefined): Record<string, string> {
  const env: Record<string, string> = {
    PATH: commandPath(process.env.PATH),
    HOME: process.env.HOME ?? '/workspace',
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    ANKOLE_WORKSPACE_ROOT: process.env.ANKOLE_WORKSPACE_ROOT ?? '/workspace'
  }

  for (const [key, value] of Object.entries(inputEnv ?? {})) {
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) env[key] = value
  }

  return env
}

function commandPath(path: string | undefined): string {
  const required = ['/usr/local/bin', '/usr/bin', '/bin']
  const current = path?.split(':').filter(Boolean) ?? []
  return [...required, ...current.filter(entry => !required.includes(entry))].join(':')
}

async function readableToUtf8(stream: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!stream) return ''
  return Buffer.from(await new Response(stream).arrayBuffer()).toString('utf8')
}

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

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, normalize, resolve } from 'node:path'
import { createHash } from 'node:crypto'

export type CommandOutputMode = 'stdout' | 'stderr' | 'both'

export interface CommandFinished {
  exitCode: number
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
}

export interface LocalComputer {
  runCommand(input: {
    cmd: string
    args?: string[]
    cwd?: string
    env?: Record<string, string>
    timeoutMs?: number
    signal?: AbortSignal
  }): Promise<CommandFinished>
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

/** Shared per-run state for the computer tools (workspace root + background ids). */
export interface ComputerToolContext {
  /** Current Ankole Agent UID; used to namespace browser/session artifacts. */
  agentUid: string
  /**
   * Conversation-level execution scope. Persistent shells, tmux names, browser
   * execution sessions/captures/artifacts are namespaced by this so concurrent
   * conversations of one agent do not share execution state.
   */
  executionScopeId: string
  /** Resolve-or-create the agent's local computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<LocalComputer>
  /** Command ids started by future background/process tools; kept only as run context parity. */
  backgroundIds: Set<string>
}

/**
 * Builds the local Computer facade over the mounted Ankole workspace.
 *
 * The migrated tools were written for a remote `Computer` session. In Ankole the AI SDK loop
 * already runs inside Agent Computer, so the same tool contract is satisfied by
 * local filesystem/process/tmux operations rooted at `workspaceRoot`.
 */
export function createLocalComputer(workspaceRoot: string): LocalComputer {
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

  const runTmux = async (args: string[], opts?: { signal?: AbortSignal }): Promise<CommandFinished> => {
    return runLocalCommand({ cmd: 'tmux', args, signal: opts?.signal }, root)
  }

  return {
    runCommand(input) {
      return runLocalCommand(input, root)
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
            return { name, windows: Number.parseInt(windows, 10) || 0, attached: attached === '1' }
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

async function runLocalCommand(
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
  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const timeoutSeconds = Math.max(1, Math.ceil((input.timeoutMs ?? 60_000) / 1000))
  const argv = ['timeout', `${timeoutSeconds}s`, input.cmd, ...(input.args ?? [])]
  const result = Bun.spawnSync(argv, {
    cwd,
    env: { ...process.env, ...input.env },
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const stdout = Buffer.from(result.stdout).toString('utf8')
  const stderr = Buffer.from(result.stderr).toString('utf8')
  return {
    exitCode: result.exitCode ?? 124,
    async output(mode = 'both') {
      if (mode === 'stdout') return stdout
      if (mode === 'stderr') return stderr
      return [stdout, stderr].filter(Boolean).join(stderr && stdout ? '\n' : '')
    }
  }
}

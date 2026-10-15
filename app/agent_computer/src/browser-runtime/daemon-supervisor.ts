import { spawn, type ChildProcess } from 'node:child_process'
import { lstat, rm } from 'node:fs/promises'
import { dirname } from 'node:path'
import { mkdirAgent } from '../common/agent-user'
import { commandEnv } from '../core/execution/command-env'
import { agentProcessArgv, killProcessGroup } from '../core/execution/process-group'

export type BrowserDaemonEvent = {
  kind: 'started' | 'exited' | 'restart_scheduled'
  pid?: number
  code?: number | null
  signal?: NodeJS.Signals | null
  delayMs?: number
}

export class BrowserDaemonSupervisor {
  private child?: ChildProcess
  private desired = false
  private restartTimer?: ReturnType<typeof setTimeout>
  private restartAttempts = 0
  private starting?: Promise<void>

  constructor(
    readonly options: {
      socketPath: string
      daemonEntry: string
      onEvent?: (event: BrowserDaemonEvent) => void
    }
  ) {}

  async start(): Promise<void> {
    this.desired = true
    await this.ensureStarted()
  }

  async stop(): Promise<void> {
    this.desired = false
    if (this.restartTimer) clearTimeout(this.restartTimer)
    this.restartTimer = undefined
    const child = this.child
    this.child = undefined
    if (!child || child.exitCode !== null || child.signalCode !== null) return
    killProcessGroup(child.pid, 'SIGTERM')
    if (await waitForExit(child, 5_000)) return
    killProcessGroup(child.pid)
    await waitForExit(child, 1_000)
  }

  private async ensureStarted(): Promise<void> {
    if (!this.desired || this.child) return
    this.starting ??= this.spawnAndWait().finally(() => {
      this.starting = undefined
    })
    await this.starting
  }

  private async spawnAndWait(): Promise<void> {
    await mkdirAgent(dirname(this.options.socketPath))
    await rm(this.options.socketPath, { force: true })
    // `stop()` can run while a start or restart waits above. It finds no child
    // then, so the daemon must not start after it.
    if (!this.desired) return
    const [command, ...args] = agentProcessArgv([process.execPath, this.options.daemonEntry])
    const child = spawn(command!, args, {
      env: commandEnv(
        {
          ANKOLE_BROWSER_DAEMON_SOCKET: this.options.socketPath,
          ...(process.env.ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS
            ? { ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS: process.env.ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS }
            : {})
        },
        { agentHome: process.env.HOME! }
      ),
      stdio: ['ignore', 'inherit', 'inherit'],
      detached: true
    })
    this.child = child
    let spawnError: Error | undefined
    child.once('exit', (code, signal) => this.handleExit(child, code, signal))
    child.once('error', error => {
      spawnError = error
      if (this.child === child) this.child = undefined
    })
    await waitForSocketOrExit(child, this.options.socketPath, 10_000, () => spawnError)
    this.restartAttempts = 0
    this.options.onEvent?.({ kind: 'started', pid: child.pid })
  }

  private handleExit(child: ChildProcess, code: number | null, signal: NodeJS.Signals | null): void {
    if (this.child !== child) return
    this.child = undefined
    this.options.onEvent?.({ kind: 'exited', code, signal })
    if (!this.desired) return
    const delayMs = Math.min(5_000, 250 * 2 ** this.restartAttempts)
    this.restartAttempts += 1
    this.options.onEvent?.({ kind: 'restart_scheduled', delayMs })
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined
      void this.ensureStarted().catch(() => this.scheduleAfterFailedStart())
    }, delayMs)
    this.restartTimer.unref()
  }

  private scheduleAfterFailedStart(): void {
    if (!this.desired || this.restartTimer) return
    const delayMs = Math.min(5_000, 250 * 2 ** this.restartAttempts)
    this.restartAttempts += 1
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined
      void this.ensureStarted().catch(() => this.scheduleAfterFailedStart())
    }, delayMs)
    this.restartTimer.unref()
  }
}

async function waitForSocketOrExit(
  child: ChildProcess,
  socketPath: string,
  timeoutMs: number,
  spawnError: () => Error | undefined
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const error = spawnError()
    if (error) throw new Error(`failed to spawn ankole-browserd: ${error.message}`, { cause: error })
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`ankole-browserd exited before ready (${child.exitCode ?? child.signalCode})`)
    }
    try {
      if ((await lstat(socketPath)).isSocket()) {
        if (child.exitCode !== null || child.signalCode !== null) {
          throw new Error(`ankole-browserd exited before ready (${child.exitCode ?? child.signalCode})`)
        }
        return
      }
    } catch {
    }
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  killProcessGroup(child.pid, 'SIGTERM')
  throw new Error('ankole-browserd readiness timed out')
}

async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return true
  return await new Promise(resolve => {
    const timer = setTimeout(() => resolve(false), timeoutMs)
    child.once('exit', () => {
      clearTimeout(timer)
      resolve(true)
    })
  })
}

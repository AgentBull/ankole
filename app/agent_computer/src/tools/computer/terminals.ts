import { mkdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { runControlCommand, workspacePath, type CommandFinished } from './commands'
import { injectableWorkerEnv } from './env'

export interface ContainerTerminals {
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

export function createContainerTerminals(
  workspaceRoot: string,
  workerEnv?: Record<string, string>
): ContainerTerminals {
  const root = resolve(workspaceRoot)
  const runTmux = async (args: string[], opts?: { signal?: AbortSignal }): Promise<CommandFinished> =>
    runControlCommand({ cmd: 'tmux', args, signal: opts?.signal }, root)
  // Session env via `-e`, never the tmux server env: one worker's tmux server
  // may host sessions of several agents, so operator variables must stay
  // scoped to the session they were resolved for.
  const sessionEnvArgs = injectableWorkerEnv(workerEnv).flatMap(([key, value]) => ['-e', `${key}=${value}`])

  return {
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
      const result = await runTmux(
        ['new-session', '-d', '-s', name, '-c', cwd, ...size, ...sessionEnvArgs, opts.command],
        runOpts
      )
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

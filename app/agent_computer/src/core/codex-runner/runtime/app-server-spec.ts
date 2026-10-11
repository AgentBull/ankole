import { resolve } from 'node:path'
import { commandEnv } from '../../execution/command-env'
import { codexConfigCLIOverrides, type MaterializedCodexConfig } from './agent-home-config'

/**
 * The launch facts of the Agent's Codex app-server. The process runs as the
 * Agent user in the Agent Home and receives only Agent-scoped environment.
 * Each Job receives Worker, binding, and Browser values through its thread
 * configuration.
 */
export type CodexAppServerSpec = {
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
}

export function codexAppServerSpec(materialized: MaterializedCodexConfig): CodexAppServerSpec {
  return {
    cwd: materialized.agentHome,
    env: codexCommandEnv(materialized),
    commandArgv: [...codexCommand(), 'app-server', '--stdio', ...codexConfigCLIOverrides()]
  }
}

export function codexJobThreadEnv(input: {
  materialized: MaterializedCodexConfig
  workerEnv?: Record<string, string>
  runtimeEnv?: Record<string, string>
  browserEnv?: Record<string, string>
}): Record<string, string> {
  return codexCommandEnv(input.materialized, input.workerEnv, input.runtimeEnv, input.browserEnv)
}

function codexCommandEnv(
  materialized: MaterializedCodexConfig,
  workerEnv?: Record<string, string>,
  runtimeEnv?: Record<string, string>,
  browserEnv?: Record<string, string>
): Record<string, string> {
  const next = commandEnv(materialized.env, { agentHome: materialized.agentHome, workerEnv, runtimeEnv })
  Object.assign(next, browserEnv)
  return next
}

function codexCommand(): string[] {
  const binary = process.env.ANKOLE_CODEX_BINARY
  if (!binary) return ['codex']
  if (!binary.startsWith('/')) return [binary]
  return [resolve(binary)]
}

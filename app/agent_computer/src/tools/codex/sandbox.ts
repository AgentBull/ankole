import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import type { PreparedCodexJobProject } from '../../core/codex-runner/job-project'
import type { MaterializedCodexJobRuntimeFiles } from '../../core/codex-runner/runtime-files'
import type { BrowserSandboxRuntime } from '../../browser-runtime'
import { bubblewrapArgv } from '../computer/bubblewrap'
import { commandEnv } from '../computer/env'
import { codexConfigCLIOverrides, type MaterializedCodexConfig } from './config'

export type CodexAppServerSandboxSpec = {
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
  codexCwd: string
}

const SANDBOX_KERNEL_ROOT = '/repo/app/kernel'

export function codexAppServerSandboxSpec(input: {
  project: PreparedCodexJobProject
  materialized: MaterializedCodexConfig
  runtimeFiles?: MaterializedCodexJobRuntimeFiles
  workerEnv?: Record<string, string>
  runtimeEnv?: Record<string, string>
  browserRuntime?: BrowserSandboxRuntime
}): CodexAppServerSandboxSpec {
  const env = codexSandboxEnv(input.materialized, input.workerEnv, input.runtimeEnv, input.browserRuntime?.env)
  return {
    cwd: input.project.root,
    env,
    codexCwd: input.project.codexCwd,
    commandArgv: bubblewrapArgv({
      workspaceRoot: input.materialized.agentHome,
      cwd: input.project.root,
      env,
      extraBinds: [
        ...(existsSync(SANDBOX_KERNEL_ROOT)
          ? [{ source: SANDBOX_KERNEL_ROOT, target: SANDBOX_KERNEL_ROOT, readonly: true }]
          : []),
        ...(input.browserRuntime?.binds ?? [])
      ],
      commandArgv: [
        ...codexCommandForSandbox(),
        'app-server',
        '--stdio',
        ...codexConfigCLIOverrides(input.project.root)
      ]
    })
  }
}

function codexSandboxEnv(
  materialized: MaterializedCodexConfig,
  workerEnv?: Record<string, string>,
  runtimeEnv?: Record<string, string>,
  browserEnv?: Record<string, string>
): Record<string, string> {
  const next = commandEnv(materialized.env, {
    home: materialized.agentHome,
    ankoleAgentHome: materialized.agentHome,
    workerEnv,
    runtimeEnv
  })
  next.ANKOLE_KERNEL_ROOT = SANDBOX_KERNEL_ROOT
  Object.assign(next, browserEnv)
  return next
}

function codexCommandForSandbox(): string[] {
  const binary = process.env.ANKOLE_CODEX_BINARY
  if (!binary) return ['codex']
  if (!binary.startsWith('/')) return [binary]
  return [resolve(binary)]
}

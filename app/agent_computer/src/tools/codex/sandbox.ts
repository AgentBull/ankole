import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { insideWorkspace, toWorkspacePath as modelPath, WORKSPACE_MODEL_ROOT } from '../../core/workspace-paths'
import type { PreparedCodexJobProject } from '../../core/codex-runner/job-project'
import { bubblewrapArgv } from '../computer/bubblewrap'
import { commandEnv } from '../computer/env'
import { codexConfigCLIOverrides, type MaterializedCodexConfig } from './config'
import {
  CODEX_JOB_SKILLS_SANDBOX_ROOT,
  type MaterializedCodexJobRuntimeFiles
} from '../../core/codex-runner/runtime-files'
import type { BrowserSandboxRuntime } from '../../browser-runtime'

export type CodexAppServerSandboxSpec = {
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
  codexCwd: string
}

// Matches the worker image layout (app/agent_computer/Dockerfile) so sandboxed
// Skill scripts can locate the kernel through ANKOLE_KERNEL_ROOT.
const SANDBOX_KERNEL_ROOT = '/repo/app/kernel'

export function codexAppServerSandboxSpec(input: {
  project: PreparedCodexJobProject
  materialized: MaterializedCodexConfig
  runtimeFiles?: MaterializedCodexJobRuntimeFiles
  /** Operator-managed shell variables resolved for the delegating agent. */
  workerEnv?: Record<string, string>
  browserRuntime?: BrowserSandboxRuntime
}): CodexAppServerSandboxSpec {
  const codexCwd = input.project.codexCwd
  const codexHomeBind = codexHomeBindForSandbox(input.project.root, input.materialized.codexHome)
  const env = codexSandboxEnv(
    input.project.root,
    input.materialized.env,
    codexHomeBind?.target,
    input.workerEnv,
    input.browserRuntime?.env
  )
  const runtimeFileBinds = input.runtimeFiles ? codexJobRuntimeFileBinds(input.runtimeFiles) : []
  const workspaceBinds = input.project.workspaceMounts.map(mount => ({
    source: mount.sourcePath,
    target: mount.modelPath,
    readonly: mount.access === 'read_only'
  }))

  return {
    cwd: input.project.root,
    env,
    codexCwd,
    commandArgv: bubblewrapArgv({
      workspaceRoot: input.project.root,
      cwd: input.project.root,
      env,
      extraBinds: [
        ...(codexHomeBind ? [codexHomeBind] : []),
        ...workspaceBinds,
        ...runtimeFileBinds,
        ...(input.browserRuntime?.binds ?? [])
      ],
      commandArgv: [
        ...codexCommandForSandbox(input.project.root),
        'app-server',
        '--stdio',
        ...codexConfigCLIOverrides()
      ]
    })
  }
}

function codexJobRuntimeFileBinds(runtime: MaterializedCodexJobRuntimeFiles) {
  return [
    { source: runtime.skillsPlaceholderRoot, target: CODEX_JOB_SKILLS_SANDBOX_ROOT, readonly: true },
    ...runtime.skills.flatMap(skill => {
      const target = join(CODEX_JOB_SKILLS_SANDBOX_ROOT, skill.name)
      return [
        { source: skill.sourcePath, target, readonly: true },
        ...(skill.skillFileOverridePath
          ? [{ source: skill.skillFileOverridePath, target: join(target, 'SKILL.md'), readonly: true }]
          : [])
      ]
    }),
    ...(existsSync(SANDBOX_KERNEL_ROOT)
      ? [{ source: SANDBOX_KERNEL_ROOT, target: SANDBOX_KERNEL_ROOT, readonly: true }]
      : [])
  ]
}

function codexSandboxEnv(
  workspaceRoot: string,
  env: Record<string, string>,
  codexHomeSandboxPath?: string,
  workerEnv?: Record<string, string>,
  browserEnv?: Record<string, string>
): Record<string, string> {
  const next = commandEnv(env, {
    home: WORKSPACE_MODEL_ROOT,
    ankoleWorkspaceRoot: WORKSPACE_MODEL_ROOT,
    workerEnv
  })
  if (next.CODEX_HOME) next.CODEX_HOME = codexHomeSandboxPath ?? modelPath(workspaceRoot, next.CODEX_HOME)
  next.ANKOLE_KERNEL_ROOT = SANDBOX_KERNEL_ROOT
  Object.assign(next, browserEnv)
  return next
}

function codexHomeBindForSandbox(
  workspaceRoot: string,
  codexHome: string
): { source: string; target: string; readonly?: boolean } | undefined {
  if (insideWorkspace(workspaceRoot, codexHome)) return undefined
  return { source: codexHome, target: resolve(codexHome) }
}

function codexCommandForSandbox(workspaceRoot: string): string[] {
  const binary = process.env.ANKOLE_CODEX_BINARY
  if (!binary) return ['codex']
  if (!binary.startsWith('/')) return [binary]

  const resolved = resolve(binary)
  return [insideWorkspace(workspaceRoot, resolved) ? modelPath(workspaceRoot, resolved) : resolved]
}

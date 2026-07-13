import { join, posix, resolve } from 'node:path'
import {
  insideWorkspace,
  resolveWorkspacePath,
  toWorkspacePath as modelPath,
  WORKSPACE_MODEL_ROOT
} from '../../core/workspace-paths'
import { bubblewrapArgv } from '../computer/bubblewrap'
import { commandEnv } from '../computer/env'
import { codexConfigCLIOverrides, type MaterializedCodexConfig } from './config'
import { SUBAGENT_SKILLS_SANDBOX_ROOT, type MaterializedSubagentRuntimeFiles } from '../subagent/runtime-files'

export type CodexAppServerSandboxSpec = {
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
  codexCwd: string
}

export function resolveCodexWorkdir(workspaceRoot: string, workdir?: string): string {
  return resolveWorkspacePath(workspaceRoot, workdir ?? WORKSPACE_MODEL_ROOT, {
    nonWorkspaceAbsolute: 'reject',
    errorMessage: 'Codex workdir must stay inside the session workspace'
  })
}

export function codexAppServerSandboxSpec(input: {
  workspaceRoot: string
  workdir: string
  materialized: MaterializedCodexConfig
  runtimeFiles?: MaterializedSubagentRuntimeFiles
  /** Operator-managed shell variables resolved for the delegating agent. */
  workerEnv?: Record<string, string>
}): CodexAppServerSandboxSpec {
  const codexCwd = modelPath(input.workspaceRoot, input.workdir)
  const codexHomeBind = codexHomeBindForSandbox(input.workspaceRoot, input.materialized.codexHome)
  const env = codexSandboxEnv(input.workspaceRoot, input.materialized.env, codexHomeBind?.target, input.workerEnv)
  const runtimeFileBinds = input.runtimeFiles ? subagentRuntimeFileBinds(input.runtimeFiles) : []

  return {
    cwd: input.workspaceRoot,
    env,
    codexCwd,
    commandArgv: bubblewrapArgv({
      workspaceRoot: input.workspaceRoot,
      cwd: input.workdir,
      env,
      extraBinds: [...(codexHomeBind ? [codexHomeBind] : []), ...runtimeFileBinds],
      commandArgv: [
        ...codexCommandForSandbox(input.workspaceRoot),
        'app-server',
        '--stdio',
        ...codexConfigCLIOverrides(),
        ...(input.runtimeFiles
          ? [
              '-c',
              `project_doc_fallback_filenames=[${JSON.stringify(
                posix.relative(codexCwd, input.runtimeFiles.agentsSandboxPath)
              )}]`
            ]
          : [])
      ]
    })
  }
}

function subagentRuntimeFileBinds(runtime: MaterializedSubagentRuntimeFiles) {
  return [
    {
      source: runtime.agentsPath,
      target: runtime.agentsSandboxPath,
      readonly: true,
      createTargetParents: false
    },
    ...(runtime.localAgentsSandboxPath
      ? [
          {
            source: runtime.agentsPath,
            target: runtime.localAgentsSandboxPath,
            readonly: true,
            createTargetParents: false
          }
        ]
      : []),
    { source: runtime.skillsPlaceholderRoot, target: SUBAGENT_SKILLS_SANDBOX_ROOT, readonly: true },
    ...runtime.skills.flatMap(skill => {
      const target = join(SUBAGENT_SKILLS_SANDBOX_ROOT, skill.name)
      return [
        { source: skill.sourcePath, target, readonly: true },
        ...(skill.skillFileOverridePath
          ? [{ source: skill.skillFileOverridePath, target: join(target, 'SKILL.md'), readonly: true }]
          : [])
      ]
    })
  ]
}

function codexSandboxEnv(
  workspaceRoot: string,
  env: Record<string, string>,
  codexHomeSandboxPath?: string,
  workerEnv?: Record<string, string>
): Record<string, string> {
  const next = commandEnv(env, {
    home: WORKSPACE_MODEL_ROOT,
    ankoleWorkspaceRoot: WORKSPACE_MODEL_ROOT,
    workerEnv
  })
  if (next.CODEX_HOME) next.CODEX_HOME = codexHomeSandboxPath ?? modelPath(workspaceRoot, next.CODEX_HOME)
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

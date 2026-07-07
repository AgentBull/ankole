import { resolve } from 'node:path'
import {
  insideWorkspace,
  resolveWorkspacePath,
  toWorkspacePath as modelPath,
  WORKSPACE_MODEL_ROOT
} from '../../core/workspace-paths'
import { bubblewrapArgv } from '../computer/bubblewrap'
import { commandEnv } from '../computer/env'
import { codexConfigCliOverrides, type MaterializedCodexConfig } from './config'

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
}): CodexAppServerSandboxSpec {
  const codexCwd = modelPath(input.workspaceRoot, input.workdir)
  const codexHomeBind = codexHomeBindForSandbox(input.workspaceRoot, input.materialized.codexHome)
  const env = codexSandboxEnv(input.workspaceRoot, input.materialized.env, codexHomeBind?.target)

  return {
    cwd: input.workspaceRoot,
    env,
    codexCwd,
    commandArgv: bubblewrapArgv({
      workspaceRoot: input.workspaceRoot,
      cwd: input.workdir,
      env,
      extraBinds: codexHomeBind ? [codexHomeBind] : [],
      commandArgv: [
        ...codexCommandForSandbox(input.workspaceRoot),
        'app-server',
        '--stdio',
        ...codexConfigCliOverrides()
      ]
    })
  }
}

function codexSandboxEnv(
  workspaceRoot: string,
  env: Record<string, string>,
  codexHomeSandboxPath?: string
): Record<string, string> {
  const next = commandEnv(env, {
    home: WORKSPACE_MODEL_ROOT,
    ankoleWorkspaceRoot: WORKSPACE_MODEL_ROOT
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

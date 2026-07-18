import { chmodSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { sanitizePathSegment } from '../../core/workspace-paths'
import type { CodexRuntimeConfig } from './runtime-config'

export type MaterializedCodexConfig = {
  codexHome: string
  authPath?: string
  initialAuthHash?: string
  env: Record<string, string>
}

export function materializeCodexConfig(input: {
  sharedFsRoot: string
  jobID: string
  runtime: CodexRuntimeConfig
  enableMultiAgent?: boolean
  enablePlugins?: boolean
}): MaterializedCodexConfig {
  const safeJobID = sanitizePathSegment(input.jobID, { replacement: '_' })
  if (safeJobID !== input.jobID) throw new Error('Background agent job id is not a safe path segment')

  const codexHome = join(input.sharedFsRoot, '.ankole', 'background-agent-jobs', safeJobID, 'codex-home')
  mkdirSync(codexHome, { recursive: true, mode: 0o700 })
  chmodSync(codexHome, 0o700)

  const env: Record<string, string> = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    HOME: input.sharedFsRoot,
    CODEX_HOME: codexHome,
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  if (input.runtime.mode === 'aigateway') {
    atomicWrite(
      join(codexHome, 'config.toml'),
      codexConfigToml(input.runtime.aiGatewayKey.baseUrl, input.enableMultiAgent ?? false, input.enablePlugins ?? false)
    )
    rmSync(join(codexHome, 'auth.json'), { force: true })
    env.ANKOLE_AIGATEWAY_API_KEY = input.runtime.aiGatewayKey.apiKey
    return { codexHome, env }
  }

  atomicWrite(
    join(codexHome, 'config.toml'),
    codexConfigToml(undefined, input.enableMultiAgent ?? false, input.enablePlugins ?? false)
  )
  const authPath = join(codexHome, 'auth.json')
  atomicWrite(authPath, input.runtime.authJSON)
  return {
    codexHome,
    authPath,
    initialAuthHash: input.runtime.authHash,
    env
  }
}

export function codexConfigCLIOverrides(): string[] {
  return [
    '-c',
    'approval_policy="never"',
    '-c',
    'sandbox_mode="danger-full-access"',
    '-c',
    'cli_auth_credentials_store="file"'
  ]
}

function codexConfigToml(baseURL: string | undefined, enableMultiAgent: boolean, enablePlugins: boolean): string {
  const common = `approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"
project_doc_max_bytes = 131072

[features]
memories = false
remote_compaction_v2 = false
multi_agent = false
apps = false
enable_mcp_apps = false
tool_suggest = false
plugins = ${enablePlugins}
remote_plugin = false
${
  enableMultiAgent
    ? `
[features.multi_agent_v2]
enabled = true
hide_spawn_agent_metadata = true
`
    : ''
}

[projects."/workspace"]
trust_level = "trusted"
`
  if (!baseURL) return common

  const normalizedBaseURL = baseURL.replace(/\/+$/, '')
  return `model = "coding"
model_provider = "ankole_aigateway"
model_reasoning_effort = "xhigh"
${common}

[model_providers.ankole_aigateway]
name = "Ankole AIGateway"
base_url = ${JSON.stringify(normalizedBaseURL)}
env_key = "ANKOLE_AIGATEWAY_API_KEY"
wire_api = "responses"
supports_websockets = true
`
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`
  writeFileSync(temporary, content, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

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
  runtime: CodexRuntimeConfig
}): MaterializedCodexConfig {
  const safeAccountID = sanitizePathSegment(input.runtime.accountID, { replacement: '_' })
  if (safeAccountID !== input.runtime.accountID) throw new Error('Codex account id is not a safe path segment')

  const codexHome = join(input.sharedFsRoot, '.ankole', 'codex', safeAccountID)
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
    atomicWrite(join(codexHome, 'config.toml'), codexConfigToml(input.runtime.aiGatewayKey.base_url))
    rmSync(join(codexHome, 'auth.json'), { force: true })
    env.ANKOLE_AIGATEWAY_API_KEY = input.runtime.aiGatewayKey.api_key
    return { codexHome, env }
  }

  atomicWrite(join(codexHome, 'config.toml'), codexConfigToml())
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

function codexConfigToml(baseURL?: string): string {
  const common = `approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"
project_doc_max_bytes = 131072

[features]
remote_compaction_v2 = false
multi_agent = false
apps = false
enable_mcp_apps = false
tool_suggest = false
plugins = false
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

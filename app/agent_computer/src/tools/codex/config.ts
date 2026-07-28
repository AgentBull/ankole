import { Buffer } from 'node:buffer'
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { agentHomePaths } from '../../core/agent-home-paths'
import type { CodexRuntimeConfig } from './runtime-config'

export type MaterializedCodexConfig = {
  agentHome: string
  codexHome: string
  authPath?: string
  initialAuthHash?: string
  env: Record<string, string>
}

const AIGATEWAY_MODEL_BINDING_ENV = 'ANKOLE_AIGATEWAY_MODEL_BINDING'

export function materializeCodexConfig(input: {
  agentsRoot: string
  agentUID: string
  runtime: CodexRuntimeConfig
}): MaterializedCodexConfig {
  const paths = agentHomePaths(input.agentsRoot, input.agentUID)
  mkdirSync(paths.codexHome, { recursive: true, mode: 0o700 })
  chmodSync(paths.codexHome, 0o700)

  const configPath = join(paths.codexHome, 'config.toml')
  const common = codexConfigToml(undefined)
  if (input.runtime.mode === 'aigateway') {
    atomicWriteIfChanged(configPath, codexConfigToml(input.runtime.aiGatewayKey.baseUrl))
  } else {
    atomicWriteIfChanged(configPath, common)
  }

  const env: Record<string, string> = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    HOME: paths.home,
    CODEX_HOME: paths.codexHome,
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  if (input.runtime.mode === 'aigateway') {
    env.ANKOLE_AIGATEWAY_API_KEY = input.runtime.aiGatewayKey.apiKey
    env[AIGATEWAY_MODEL_BINDING_ENV] = encodeAIGatewayModelBinding(input.runtime)
    return { agentHome: paths.home, codexHome: paths.codexHome, env }
  }

  const authPath = join(paths.codexHome, 'auth.json')
  atomicWrite(authPath, input.runtime.authJSON)
  return {
    agentHome: paths.home,
    codexHome: paths.codexHome,
    authPath,
    initialAuthHash: input.runtime.authHash,
    env
  }
}

export function codexConfigCLIOverrides(projectRoot: string): string[] {
  return [
    '-c',
    'approval_policy="never"',
    '-c',
    'sandbox_mode="danger-full-access"',
    '-c',
    'cli_auth_credentials_store="file"',
    '-c',
    `projects={ ${JSON.stringify(projectRoot)} = { trust_level = "trusted" } }`
  ]
}

function codexConfigToml(baseURL: string | undefined): string {
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
plugins = false
remote_plugin = false

[features.multi_agent_v2]
enabled = true
hide_spawn_agent_metadata = true
`
  if (!baseURL) return common

  const normalizedBaseURL = baseURL.replace(/\/+$/, '')
  return `model_provider = "ankole_aigateway"
model_auto_compact_token_limit = 100000
${common}

[model_providers.ankole_aigateway]
name = "Ankole AIGateway"
base_url = ${JSON.stringify(normalizedBaseURL)}
env_key = "ANKOLE_AIGATEWAY_API_KEY"
env_http_headers = { "x-ankole-aigateway-model-binding" = "${AIGATEWAY_MODEL_BINDING_ENV}" }
wire_api = "responses"
supports_websockets = true
`
}

function encodeAIGatewayModelBinding(runtime: Extract<CodexRuntimeConfig, { mode: 'aigateway' }>): string {
  return Buffer.from(
    JSON.stringify({
      selector: runtime.modelProfile.selector,
      provider_options: runtime.modelProfile.providerOptions,
      supports_parallel_tool_calls: runtime.modelProfile.supportsParallelToolCalls
    }),
    'utf8'
  ).toString('base64url')
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`
  writeFileSync(temporary, content, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

function atomicWriteIfChanged(path: string, content: string): void {
  if (existsSync(path) && readFileSync(path, 'utf8') === content) return
  atomicWrite(path, content)
}

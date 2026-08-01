import { Buffer } from 'node:buffer'
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { agentHomePaths } from '../../core/agent-home-paths'
import type { CodexRuntimeConfig } from './runtime-config'

export type MaterializedCodexConfig = {
  agentHome: string
  codexHome: string
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
  atomicWriteIfChanged(configPath, codexConfigToml(input.runtime.aiGatewayKey.baseUrl))

  const env: Record<string, string> = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    HOME: paths.home,
    CODEX_HOME: paths.codexHome,
    CODEX_INTERNAL_ORIGINATOR_OVERRIDE: 'codex_cli_rs',
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  env.ANKOLE_AIGATEWAY_API_KEY = input.runtime.aiGatewayKey.apiKey
  env[AIGATEWAY_MODEL_BINDING_ENV] = encodeAIGatewayModelBinding(input.runtime)
  return { agentHome: paths.home, codexHome: paths.codexHome, env }
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

function codexConfigToml(baseURL: string): string {
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

[features.code_mode]
enabled = true

[features.multi_agent_v2]
enabled = true
hide_spawn_agent_metadata = true

# Codex builds these skills into its binary. Keep them out of Worker sessions.
[[skills.config]]
name = "skill-creator"
enabled = false

[[skills.config]]
name = "plugin-creator"
enabled = false

[[skills.config]]
name = "skill-installer"
enabled = false
`
  const normalizedBaseURL = baseURL.replace(/\/+$/, '')
  return `model_provider = "ankole_aigateway"
model_auto_compact_token_limit = 100000
${common}

[model_providers.ankole_aigateway]
name = "Ankole AIGateway"
base_url = ${JSON.stringify(normalizedBaseURL)}
env_http_headers = { "x-ankole-aigateway-model-binding" = "${AIGATEWAY_MODEL_BINDING_ENV}" }
wire_api = "responses"
supports_websockets = true

# Command auth replaces env_key so Codex refreshes the AIGateway models
# manifest (has_command_auth gates should_refresh_models). The command reads
# the same sandbox env variable; refresh_interval_ms=0 keeps the token cached
# because the env value is fixed for the sandbox lifetime.
[model_providers.ankole_aigateway.auth]
command = "/bin/sh"
args = ["-c", "printf %s \\"$ANKOLE_AIGATEWAY_API_KEY\\""]
refresh_interval_ms = 0
`
}

function encodeAIGatewayModelBinding(runtime: CodexRuntimeConfig): string {
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

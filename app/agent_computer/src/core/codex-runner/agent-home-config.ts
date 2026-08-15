import { Buffer } from 'node:buffer'
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { agentHomePaths } from '../agent-home-paths'
import type { CodexRuntimeConfig } from './runtime-config'
import { CODEX_RUNTIME_CONFIG_TOML_ENV, CODEX_RUNTIME_TOKEN_ENV } from './codex-home-lock'

export type MaterializedCodexConfig = {
  agentHome: string
  codexHome: string
  env: Record<string, string>
}

const AIGATEWAY_TOKEN_FILE_NAME = 'ankole-aigateway.token'
const AIGATEWAY_AUTH_REFRESH_INTERVAL_MS = 5 * 60 * 1_000

/**
 * Codex enables OpenAI-only features, such as remote compaction and hosted
 * tools, only for a provider named "OpenAI". The Ankole gateway supports these
 * features, so it claims that name.
 */
export const AIGATEWAY_PROVIDER_NAME = 'OpenAI'

export function materializeCodexConfig(input: { agentsRoot: string; agentUID: string }): MaterializedCodexConfig {
  const paths = agentHomePaths(input.agentsRoot, input.agentUID)
  mkdirSync(paths.codexHome, { recursive: true, mode: 0o700 })
  chmodSync(paths.codexHome, 0o700)

  const env: Record<string, string> = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    HOME: paths.home,
    CODEX_HOME: paths.codexHome,
    CODEX_INTERNAL_ORIGINATOR_OVERRIDE: 'codex_cli_rs',
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  return { agentHome: paths.home, codexHome: paths.codexHome, env }
}

/**
 * Writes the config.toml that production passes through the locked runtime
 * startup script. Only tests call this to launch Codex without that script.
 */
export function resetCodexAgentRuntimeConfig(codexHome: string, baseURL: string): void {
  atomicWriteIfChanged(join(codexHome, 'config.toml'), codexConfigToml(codexHome, baseURL))
}

export function codexAgentRuntimeBootstrapEnv(
  codexHome: string,
  baseURL: string,
  apiKey: string
): Record<string, string> {
  if (!apiKey) throw new Error('AIGateway API key is required for the Agent Codex runtime')
  return {
    [CODEX_RUNTIME_CONFIG_TOML_ENV]: codexConfigToml(codexHome, baseURL),
    [CODEX_RUNTIME_TOKEN_ENV]: `${apiKey}\n`
  }
}

export function codexAgentRuntimeConfigPath(codexHome: string): string {
  return join(codexHome, 'config.toml')
}

/** AgentCodexRuntime serializes updates to this Agent-scoped credential. */
export function refreshCodexAgentRuntimeCredential(codexHome: string, apiKey: string): void {
  if (!apiKey) throw new Error('AIGateway API key is required for the Agent Codex runtime')
  atomicWriteIfChanged(codexAIGatewayTokenPath(codexHome), `${apiKey}\n`)
}

export function codexAIGatewayTokenPath(codexHome: string): string {
  return join(codexHome, AIGATEWAY_TOKEN_FILE_NAME)
}

export function codexAIGatewayAuthConfig(codexHome: string): Record<string, unknown> {
  return {
    command: '/bin/cat',
    args: [codexAIGatewayTokenPath(codexHome)],
    refresh_interval_ms: AIGATEWAY_AUTH_REFRESH_INTERVAL_MS
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

function codexConfigToml(codexHome: string, baseURL: string): string {
  const common = `approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"
project_doc_max_bytes = 131072

[features]
memories = false
remote_compaction_v2 = true
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
name = ${JSON.stringify(AIGATEWAY_PROVIDER_NAME)}
base_url = ${JSON.stringify(normalizedBaseURL)}
wire_api = "responses"
supports_websockets = true

# Command auth replaces env_key so Codex refreshes the AIGateway models
# manifest (has_command_auth gates should_refresh_models). AgentCodexRuntime
# atomically refreshes the private token file. Codex rereads it every five
# minutes and after a 401 response.
[model_providers.ankole_aigateway.auth]
command = "/bin/cat"
args = [${JSON.stringify(codexAIGatewayTokenPath(codexHome))}]
refresh_interval_ms = ${AIGATEWAY_AUTH_REFRESH_INTERVAL_MS}
`
}

export function encodeAIGatewayModelBinding(runtime: CodexRuntimeConfig): string {
  return Buffer.from(
    JSON.stringify({
      selector: runtime.modelProfile.selector,
      provider_options: runtime.modelProfile.providerOptions,
      supports_parallel_tool_calls: runtime.modelProfile.supportsParallelToolCalls,
      input_modalities: runtime.modelProfile.inputModalities,
      ...(runtime.modelProfile.visionFallback
        ? {
            vision_fallback: {
              selector: runtime.modelProfile.visionFallback.selector,
              provider_options: runtime.modelProfile.visionFallback.providerOptions,
              input_modalities: runtime.modelProfile.visionFallback.inputModalities
            }
          }
        : {})
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

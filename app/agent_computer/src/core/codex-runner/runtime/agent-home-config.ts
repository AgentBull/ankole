import { writeFileAtomicSync } from '../../../common/atomic-write'
import { ms } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { chmodSync, existsSync, readFileSync } from 'node:fs'
import { mkdirAgentSync } from '../../../common/agent-user'
import { dirname, join } from 'node:path'
import { agentHomePaths, codexSQLiteHome } from '../../agent-home-paths'
import type { CodexRuntimeConfig } from '../runtime-config'
import { CODEX_RUNTIME_CONFIG_TOML_ENV, CODEX_RUNTIME_TOKEN_ENV } from './codex-home-lock'

export type MaterializedCodexConfig = {
  agentHome: string
  codexHome: string
  sqliteHome: string
  env: Record<string, string>
}

/** Private Agent-scoped token file read by Codex command authentication. */
const AIGATEWAY_TOKEN_FILE_NAME = 'ankole-aigateway.token'
/** Cadence at which Codex rereads the Agent-scoped command credential. */
const AIGATEWAY_AUTH_REFRESH_INTERVAL_MS = ms('5m')

/**
 * Codex gates remote compaction and hosted tools on the literal provider name
 * "OpenAI". AIGateway implements these capabilities, so this compatibility
 * name is required.
 */
export const AIGATEWAY_PROVIDER_NAME = 'OpenAI'

export function materializeCodexConfig(input: { agentHomeRoot: string }): MaterializedCodexConfig {
  const paths = agentHomePaths(input.agentHomeRoot)
  mkdirAgentSync(paths.codexHome, 0o700)
  chmodSync(paths.codexHome, 0o700)

  const sqliteHome = codexSQLiteHome()
  mkdirAgentSync(sqliteHome, 0o700)

  const env: Record<string, string> = {
    // The Worker image sets this variable, and the entry restores it.
    PATH: process.env.PATH!,
    HOME: paths.home,
    CODEX_HOME: paths.codexHome,
    CODEX_SQLITE_HOME: sqliteHome,
    CODEX_INTERNAL_ORIGINATOR_OVERRIDE: 'codex_cli_rs',
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  return { agentHome: paths.home, codexHome: paths.codexHome, sqliteHome, env }
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
  // Do not set an auto-compaction limit here. Codex derives it from the current
  // model window, and AIGateway applies its own earlier threshold.
  return `model_provider = "ankole_aigateway"
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
        : {}),
      ...(runtime.brain
        ? { brain: { operations: runtime.brain.operations, actor_event_id: runtime.brain.actorEventID } }
        : {})
    }),
    'utf8'
  ).toString('base64url')
}

function atomicWriteIfChanged(path: string, content: string): void {
  if (existsSync(path) && readFileSync(path, 'utf8') === content) return
  mkdirAgentSync(dirname(path))
  writeFileAtomicSync(path, content, 0o600)
}

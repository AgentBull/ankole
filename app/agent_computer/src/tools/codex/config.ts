import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { isRecord, type JsonObject } from '@pleisto/active-support'
import { sanitizePathSegment } from '../../core/workspace-paths'
import type { AIGatewayApiKeyResponse } from '../../lanes/rpc_lane'

export const CodexConfigOverrideKey = 'agent_computer.codex.config_override'

export type CodexConfigOverride =
  | {
      mode: 'aigateway'
      config_toml?: string
      auth_json?: JsonObject | string
      env?: Record<string, string>
    }
  | {
      mode: 'official_subscription'
      config_toml?: string
      auth_json?: JsonObject | string
      env?: Record<string, string>
    }

export type MaterializedCodexConfig = {
  codexHome: string
  env: Record<string, string>
}

export function parseCodexConfigOverride(value: unknown): CodexConfigOverride | null {
  if (!isRecord(value)) return null
  const object = value
  const mode = object.mode
  if (mode !== 'aigateway' && mode !== 'official_subscription') return null

  return {
    mode,
    ...(typeof object.config_toml === 'string' ? { config_toml: object.config_toml } : {}),
    ...(typeof object.auth_json === 'string' || isRecord(object.auth_json) ? { auth_json: object.auth_json } : {}),
    ...(isStringRecord(object.env) ? { env: object.env } : {})
  } as CodexConfigOverride
}

export function materializeCodexConfig(input: {
  workspaceRoot: string
  delegationId: string
  override: CodexConfigOverride | null
  aiGatewayKey?: AIGatewayApiKeyResponse
}): MaterializedCodexConfig {
  const safeDelegationId = sanitizePathSegment(input.delegationId, { replacement: '_' })
  const codexHome = join(input.workspaceRoot, '.ankole', 'subagent', safeDelegationId, 'home')
  mkdirSync(codexHome, { recursive: true })

  const env: Record<string, string> = {
    PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    HOME: input.workspaceRoot,
    CODEX_HOME: codexHome,
    LANG: process.env.LANG || 'C.UTF-8',
    TERM: process.env.TERM || 'xterm-256color'
  }

  if (input.override?.mode === 'official_subscription') {
    writeConfigToml(codexHome, input.override.config_toml || officialSubscriptionDefaultConfig())
    syncAuthJson(codexHome, input.override.auth_json)
    Object.assign(env, input.override.env ?? {})
    return { codexHome, env }
  }

  if (input.override?.mode === 'aigateway' && input.override.config_toml) {
    writeConfigToml(codexHome, input.override.config_toml)
    syncAuthJson(codexHome, input.override.auth_json)
    Object.assign(env, input.override.env ?? {})
  } else {
    if (!input.aiGatewayKey) throw new Error('AIGateway Codex config requires an AIGateway API key')
    writeConfigToml(codexHome, aigatewayConfigToml(input.aiGatewayKey.base_url))
    syncAuthJson(codexHome, undefined)
  }

  if (input.aiGatewayKey) env.ANKOLE_AIGATEWAY_API_KEY = input.aiGatewayKey.api_key
  return { codexHome, env }
}

export function codexConfigCliOverrides(): string[] {
  return [
    '-c',
    'approval_policy="never"',
    '-c',
    'sandbox_mode="danger-full-access"',
    '-c',
    'cli_auth_credentials_store="file"'
  ]
}

function aigatewayConfigToml(baseUrl: string): string {
  const normalizedBaseUrl = baseUrl.replace(/\/+$/, '')
  return `model = "coding"
model_provider = "openai"
model_reasoning_effort = "xhigh"
approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"
features.remote_compaction_v2 = false

# Codex enables remote /responses/compact only for its built-in provider ids.
# Override the openai provider slot so Ankole receives v1 compaction requests.
[model_providers.openai]
name = "Ankole AIGateway"
base_url = ${tomlString(normalizedBaseUrl)}
env_key = "ANKOLE_AIGATEWAY_API_KEY"
wire_api = "responses"
supports_websockets = true
`
}

function officialSubscriptionDefaultConfig(): string {
  return `approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"
`
}

function writeConfigToml(codexHome: string, configToml: string): void {
  writeFile(join(codexHome, 'config.toml'), configToml)
}

function syncAuthJson(codexHome: string, authJson: JsonObject | string | undefined): void {
  const path = join(codexHome, 'auth.json')
  if (authJson === undefined) {
    rmSync(path, { force: true })
    return
  }
  const content = typeof authJson === 'string' ? authJson : `${JSON.stringify(authJson, null, 2)}\n`
  writeFile(path, content)
}

function writeFile(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, { mode: 0o600 })
}

function tomlString(value: string): string {
  return JSON.stringify(value)
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every(entry => typeof entry === 'string')
}

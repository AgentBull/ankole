import { mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import type { JsonObject } from '../../fabric/fabric'
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
  cleanupRoot?: string
  env: Record<string, string>
}

export function parseCodexConfigOverride(value: unknown): CodexConfigOverride | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const object = value as Record<string, unknown>
  const mode = object.mode
  if (mode !== 'aigateway' && mode !== 'official_subscription') return null

  return {
    mode,
    ...(typeof object.config_toml === 'string' ? { config_toml: object.config_toml } : {}),
    ...(typeof object.auth_json === 'string' || isJsonObject(object.auth_json) ? { auth_json: object.auth_json } : {}),
    ...(isStringRecord(object.env) ? { env: object.env } : {})
  } as CodexConfigOverride
}

export function materializeCodexConfig(input: {
  workspaceRoot: string
  delegationId: string
  override: CodexConfigOverride | null
  aiGatewayKey?: AIGatewayApiKeyResponse
}): MaterializedCodexConfig {
  const cleanupRoot =
    input.override?.mode === 'official_subscription'
      ? join(tmpdir(), 'ankole-codex-official', safePathSegment(input.delegationId))
      : join(input.workspaceRoot, 'temp', 'codex', safePathSegment(input.delegationId))
  const codexHome = join(cleanupRoot, 'home')
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
    writeAuthJson(codexHome, input.override.auth_json)
    Object.assign(env, input.override.env ?? {})
    return { codexHome, cleanupRoot, env }
  }

  if (input.override?.mode === 'aigateway' && input.override.config_toml) {
    writeConfigToml(codexHome, input.override.config_toml)
    writeAuthJson(codexHome, input.override.auth_json)
    Object.assign(env, input.override.env ?? {})
  } else {
    if (!input.aiGatewayKey) throw new Error('AIGateway Codex config requires an AIGateway API key')
    writeConfigToml(codexHome, aigatewayConfigToml(input.aiGatewayKey.base_url))
  }

  if (input.aiGatewayKey) env.ANKOLE_AIGATEWAY_API_KEY = input.aiGatewayKey.api_key
  return { codexHome, cleanupRoot, env }
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
  return [
    'model = "coding"',
    'model_provider = "ankole_aigateway"',
    'approval_policy = "never"',
    'sandbox_mode = "danger-full-access"',
    'cli_auth_credentials_store = "file"',
    '',
    '[model_providers.ankole_aigateway]',
    'name = "Ankole AIGateway"',
    `base_url = ${tomlString(baseUrl.replace(/\/+$/, ''))}`,
    'env_key = "ANKOLE_AIGATEWAY_API_KEY"',
    'wire_api = "responses"',
    ''
  ].join('\n')
}

function officialSubscriptionDefaultConfig(): string {
  return [
    'approval_policy = "never"',
    'sandbox_mode = "danger-full-access"',
    'cli_auth_credentials_store = "file"',
    ''
  ].join('\n')
}

function writeConfigToml(codexHome: string, configToml: string): void {
  writeFile(join(codexHome, 'config.toml'), configToml.endsWith('\n') ? configToml : `${configToml}\n`)
}

function writeAuthJson(codexHome: string, authJson: JsonObject | string | undefined): void {
  if (authJson === undefined) return
  const content = typeof authJson === 'string' ? authJson : JSON.stringify(authJson, null, 2)
  writeFile(join(codexHome, 'auth.json'), content.endsWith('\n') ? content : `${content}\n`)
}

function writeFile(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, { mode: 0o600 })
}

function tomlString(value: string): string {
  return JSON.stringify(value)
}

function safePathSegment(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, '_')
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isJsonObject(value) && Object.values(value).every(entry => typeof entry === 'string')
}

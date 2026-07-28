import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { parse, stringify } from 'smol-toml'
import { DEFAULT_MCP_TIMEOUT_MS, type MCPServerConfig } from '../../tools/mcp/config'
import type { CodexRuntimeConfig } from '../../tools/codex/runtime-config'

type TomlTable = Record<string, unknown>

export type MaterializedCodexJobProjectConfig = {
  path: string
}

/**
 * Applies Job execution settings and runner safety invariants over the
 * project initialized from selected Agent Plugin workspace templates.
 */
export function materializeCodexJobProjectConfig(input: {
  projectRoot: string
  mcpServers: MCPServerConfig[]
  pluginsEnabled: boolean
  runtimeConfig: CodexRuntimeConfig
}): MaterializedCodexJobProjectConfig {
  const path = join(input.projectRoot, '.codex', 'config.toml')
  const config = readToml(path)

  applyRuntimeConfig(config, input.runtimeConfig)
  applyMCPServers(config, input.mcpServers)
  applyRunnerSafety(config, input.pluginsEnabled)
  atomicWrite(path, stringify(config))

  return { path }
}

function applyRuntimeConfig(config: TomlTable, runtime: CodexRuntimeConfig): void {
  const profile = runtime.modelProfile

  config.model = profile.model
  if (profile.modelReasoningEffort) config.model_reasoning_effort = profile.modelReasoningEffort
  else delete config.model_reasoning_effort

  if (runtime.mode === 'aigateway') {
    delete config.model_provider
    delete config.service_tier
  } else {
    delete config.model_provider
    if (runtime.modelProfile.fastMode) config.service_tier = 'priority'
    else delete config.service_tier
  }
}

function applyMCPServers(config: TomlTable, servers: MCPServerConfig[]): void {
  if (servers.length === 0) {
    delete config.mcp_servers
    return
  }

  const materialized: TomlTable = {}
  for (const server of [...servers].sort((left, right) => compareCodePoints(left.name, right.name))) {
    if (Object.hasOwn(materialized, server.name)) {
      throw new Error(`duplicate Codex MCP server after Skill resolution: ${server.name}`)
    }
    materialized[server.name] =
      server.transport === 'streamable_http'
        ? {
            url: server.url,
            ...(server.bearerTokenEnvVar ? { bearer_token_env_var: server.bearerTokenEnvVar } : {}),
            tool_timeout_sec: (server.timeoutMs ?? DEFAULT_MCP_TIMEOUT_MS) / 1000
          }
        : {
            command: '/bin/sh',
            args: ['-lc', server.command],
            tool_timeout_sec: (server.timeoutMs ?? DEFAULT_MCP_TIMEOUT_MS) / 1000
          }
  }
  config.mcp_servers = materialized
}

function applyRunnerSafety(config: TomlTable, pluginsEnabled: boolean): void {
  config.approval_policy = 'never'
  config.sandbox_mode = 'danger-full-access'
  config.cli_auth_credentials_store = 'file'
  config.web_search = 'disabled'
  config.project_doc_max_bytes = 131_072

  const features = tableAt(config, 'features')
  features.memories = false
  features.remote_compaction_v2 = false
  features.multi_agent = false
  features.apps = false
  features.enable_mcp_apps = false
  features.tool_suggest = false
  features.plugins = pluginsEnabled
  features.remote_plugin = false

  const multiAgent = tableAt(features, 'multi_agent_v2')
  multiAgent.enabled = true
  multiAgent.hide_spawn_agent_metadata = true
}

function readToml(path: string): TomlTable {
  try {
    const parsed = parse(readFileSync(path, 'utf8'))
    if (!isTable(parsed)) throw new Error('TOML root must be a table')
    return parsed
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return {}
    throw new Error(`invalid Codex project config ${path}: ${error instanceof Error ? error.message : String(error)}`)
  }
}

function tableAt(parent: TomlTable, key: string): TomlTable {
  const current = parent[key]
  if (current === undefined) {
    const next = {}
    parent[key] = next
    return next
  }
  if (!isTable(current)) throw new Error(`Codex config ${key} must be a table`)
  return current
}

function isTable(value: unknown): value is TomlTable {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value) && !(value instanceof Date))
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`
  writeFileSync(temporary, content, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

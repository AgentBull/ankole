import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { TOML } from 'bun'

type TomlTable = Record<string, unknown>

export type MaterializedCodexJobProjectConfig = {
  path: string
}

export function readCodexJobProjectConfig(projectRoot: string): Record<string, unknown> {
  return readToml(join(projectRoot, '.codex', 'config.toml'))
}

/**
 * Applies Job execution settings and runner safety invariants over the
 * project initialized from selected Agent Plugin workspace templates.
 *
 * `hostedWebSearch` mirrors the Job's frozen hosted-tool projection: the
 * provider connection decides Codex `web_search`, never the workspace
 * template.
 */
export function materializeCodexJobProjectConfig(input: {
  projectRoot: string
  hostedWebSearch: boolean
}): MaterializedCodexJobProjectConfig {
  const path = join(input.projectRoot, '.codex', 'config.toml')
  const config = readToml(path)

  removeThreadRuntimeConfig(config)
  delete config.mcp_servers
  applyRunnerSafety(config, input.hostedWebSearch)
  // The published Bun types lag the canary runtime's documented stringify API.
  atomicWrite(path, (TOML as typeof TOML & { stringify(value: object): string }).stringify(config))

  return { path }
}

function removeThreadRuntimeConfig(config: TomlTable): void {
  delete config.model
  delete config.model_catalog_json
  delete config.model_reasoning_effort
  delete config.model_provider
  delete config.service_tier

  if (isTable(config.features)) delete config.features.remote_compaction_v2
}

function applyRunnerSafety(config: TomlTable, hostedWebSearch: boolean): void {
  config.approval_policy = 'never'
  config.sandbox_mode = 'danger-full-access'
  config.cli_auth_credentials_store = 'file'
  config.web_search = hostedWebSearch ? 'live' : 'disabled'
  config.project_doc_max_bytes = 131_072

  const features = tableAt(config, 'features')
  features.memories = false
  features.multi_agent = false
  features.apps = false
  features.enable_mcp_apps = false
  features.tool_suggest = false
  features.plugins = false
  features.remote_plugin = false

  const codeMode = tableAt(features, 'code_mode')
  codeMode.enabled = true

  const multiAgent = tableAt(features, 'multi_agent_v2')
  // Sub-agents are an operator reliability choice, not a runner safety
  // invariant. A workspace template that states this native Codex switch keeps
  // its value; Ankole only supplies the default.
  if (typeof multiAgent.enabled !== 'boolean') multiAgent.enabled = true
  multiAgent.hide_spawn_agent_metadata = true
  // Reduce model re-entry after empty waits. See https://github.com/openai/codex/issues/35259.
  multiAgent.min_wait_timeout_ms = 60_000
  multiAgent.default_wait_timeout_ms = 120_000
  delete multiAgent.max_wait_timeout_ms
}

function readToml(path: string): TomlTable {
  try {
    const parsed = TOML.parse(readFileSync(path, 'utf8'))
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

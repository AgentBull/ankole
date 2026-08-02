import { create } from '@bufbuild/protobuf'
import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeCodexJobProjectConfig } from '../src/core/codex-runner/project-config'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { CodexRuntimeConfig } from '../src/tools/codex/runtime-config'

function aigatewayRuntime(): CodexRuntimeConfig {
  return {
    aiGatewayKey: create(AIGatewayAPIKeyResponseSchema, {}),
    modelProfile: {
      model: 'gpt-5.6-sol',
      selector: 'openrouter/openai/gpt-5.6-sol',
      providerOptions: { reasoningEffort: 'xhigh', verbosity: 'low' },
      supportsParallelToolCalls: true,
      modelReasoningEffort: 'xhigh'
    }
  }
}

describe('@ankole/agent-computer Codex job project config', () => {
  it('applies the frozen AIGateway model over template settings and applies runner safety', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-'))
    const configPath = join(root, '.codex', 'config.toml')
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(
      configPath,
      [
        'model = "plugin-model"',
        'model_catalog_json = "/plugin/models.json"',
        'model_reasoning_effort = "medium"',
        'service_tier = "priority"',
        'web_search = "live"',
        '',
        '[features.multi_agent_v2]',
        'enabled = false',
        'max_concurrent_threads_per_session = 99',
        '',
        '[mcp_servers.stale-template-server]',
        'url = "https://stale.example.test/mcp"',
        ''
      ].join('\n')
    )

    try {
      const materialized = materializeCodexJobProjectConfig({
        projectRoot: root,
        pluginsEnabled: true,
        runtimeConfig: aigatewayRuntime()
      })
      const config = TOML.parse(readFileSync(configPath, 'utf8')) as Record<string, any>

      expect(materialized).toEqual({ path: configPath })
      expect(config.model).toBe('gpt-5.6-sol')
      expect(config.model_catalog_json).toBeUndefined()
      expect(config.model_provider).toBeUndefined()
      expect(config.service_tier).toBeUndefined()
      expect(config.model_reasoning_effort).toBe('xhigh')
      expect(config.web_search).toBe('disabled')
      expect(config.features.memories).toBe(false)
      expect(config.features.plugins).toBe(true)
      expect(config.features.code_mode).toEqual({ enabled: true })
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true,
        max_concurrent_threads_per_session: 99
      })
      expect(config.agents).toBeUndefined()
      expect(config.mcp_servers).toBeUndefined()
      expect(readFileSync(configPath, 'utf8')).not.toContain('secret-value')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails closed on invalid template config', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-invalid-'))
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(join(root, '.codex', 'config.toml'), '[features\nplugins = true\n')
    try {
      expect(() =>
        materializeCodexJobProjectConfig({
          projectRoot: root,
          pluginsEnabled: false,
          runtimeConfig: aigatewayRuntime()
        })
      ).toThrow('invalid Codex project config')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('materializes the frozen AIGateway model without template policy fields', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-default-'))
    try {
      materializeCodexJobProjectConfig({
        projectRoot: root,
        pluginsEnabled: false,
        runtimeConfig: aigatewayRuntime()
      })
      const config = TOML.parse(readFileSync(join(root, '.codex', 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.features.plugins).toBe(false)
      expect(config.model).toBe('gpt-5.6-sol')
      expect(config.model_provider).toBeUndefined()
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true
      })
      expect(config.mcp_servers).toBeUndefined()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

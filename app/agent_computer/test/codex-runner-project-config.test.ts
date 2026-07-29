import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { materializeCodexJobProjectConfig } from '../src/core/codex-runner/project-config'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { CodexRuntimeConfig } from '../src/tools/codex/runtime-config'

function aigatewayRuntime(): CodexRuntimeConfig {
  return {
    mode: 'aigateway',
    accountID: 'aigateway',
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

function officialRuntime(input: {
  model: string
  modelReasoningEffort: 'max' | 'ultra'
  fastMode: boolean
}): CodexRuntimeConfig {
  return {
    mode: 'official_subscription',
    accountID: 'account-1',
    authJSON: '{}',
    authHash: 'hash',
    modelProfile: input
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
        'web_search = "live"',
        '',
        '[features.multi_agent_v2]',
        'enabled = false',
        'max_concurrent_threads_per_session = 99',
        ''
      ].join('\n')
    )

    try {
      const materialized = materializeCodexJobProjectConfig({
        projectRoot: root,
        pluginsEnabled: true,
        runtimeConfig: aigatewayRuntime(),
        mcpServers: [
          {
            name: 'remote-data',
            generation: 'remote-generation',
            sourceSkills: ['research'],
            transport: 'streamable_http',
            url: 'https://mcp.example.test/rpc',
            bearerTokenEnvVar: 'REMOTE_DATA_TOKEN',
            timeoutMs: 480_000
          },
          {
            name: 'local-data',
            generation: 'local-generation',
            sourceSkills: ['research'],
            transport: 'stdio',
            command: 'bun run /repo/tools/local-mcp.ts'
          }
        ]
      })
      const config = parse(readFileSync(configPath, 'utf8')) as Record<string, any>

      expect(materialized).toEqual({ path: configPath })
      expect(config.model).toBe('gpt-5.6-sol')
      expect(config.model_catalog_json).toBeUndefined()
      expect(config.model_provider).toBeUndefined()
      expect(config.model_reasoning_effort).toBe('xhigh')
      expect(config.web_search).toBe('disabled')
      expect(config.features.memories).toBe(false)
      expect(config.features.plugins).toBe(true)
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true,
        max_concurrent_threads_per_session: 99
      })
      expect(config.agents).toBeUndefined()
      expect(config.mcp_servers).toEqual({
        'local-data': {
          command: '/bin/sh',
          args: ['-lc', 'bun run /repo/tools/local-mcp.ts'],
          tool_timeout_sec: 360
        },
        'remote-data': {
          url: 'https://mcp.example.test/rpc',
          bearer_token_env_var: 'REMOTE_DATA_TOKEN',
          tool_timeout_sec: 480
        }
      })
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
          runtimeConfig: aigatewayRuntime(),
          mcpServers: []
        })
      ).toThrow('invalid Codex project config')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('writes the official subscription model profile and controls priority service', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-subscription-'))
    const configPath = join(root, '.codex', 'config.toml')
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(configPath, 'model = "template-model"\nservice_tier = "priority"\n')

    try {
      materializeCodexJobProjectConfig({
        projectRoot: root,
        pluginsEnabled: false,
        mcpServers: [],
        runtimeConfig: officialRuntime({
          model: 'gpt-5.6-sol',
          modelReasoningEffort: 'max',
          fastMode: false
        })
      })
      let config = parse(readFileSync(configPath, 'utf8')) as Record<string, any>
      expect(config.model).toBe('gpt-5.6-sol')
      expect(config.model_reasoning_effort).toBe('max')
      expect(config.model_provider).toBeUndefined()
      expect(config.service_tier).toBeUndefined()

      materializeCodexJobProjectConfig({
        projectRoot: root,
        pluginsEnabled: false,
        mcpServers: [],
        runtimeConfig: officialRuntime({
          model: 'gpt-5.6-terra',
          modelReasoningEffort: 'ultra',
          fastMode: true
        })
      })
      config = parse(readFileSync(configPath, 'utf8')) as Record<string, any>
      expect(config.model).toBe('gpt-5.6-terra')
      expect(config.model_reasoning_effort).toBe('ultra')
      expect(config.service_tier).toBe('priority')
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
        runtimeConfig: aigatewayRuntime(),
        mcpServers: []
      })
      const config = parse(readFileSync(join(root, '.codex', 'config.toml'), 'utf8')) as Record<string, any>
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

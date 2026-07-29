import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { codexConfigCLIOverrides, materializeCodexConfig } from '../src/tools/codex/config'
import type { CodexRuntimeConfig } from '../src/tools/codex/runtime-config'

function officialRuntime(accountID: string) {
  return {
    mode: 'official_subscription' as const,
    accountID,
    authJSON: '{}',
    authHash: 'hash',
    modelProfile: { model: 'gpt-5.6-sol', modelReasoningEffort: 'high' as const, fastMode: false }
  }
}

function aigatewayRuntime(): CodexRuntimeConfig {
  return {
    mode: 'aigateway',
    accountID: 'aigateway',
    aiGatewayKey: create(AIGatewayAPIKeyResponseSchema, {
      apiKey: 'agent-key',
      baseUrl: 'https://control.example.test/api/v1/ai-gateway'
    }),
    modelProfile: {
      model: 'gpt-5.6-sol',
      selector: 'openrouter/openai/gpt-5.6-sol',
      providerOptions: {
        reasoningEffort: 'xhigh',
        nested: { preserved: true }
      },
      supportsParallelToolCalls: true,
      modelReasoningEffort: 'xhigh'
    }
  }
}

function bundledModelCatalog(): string {
  return JSON.stringify({
    models: [
      {
        slug: 'gpt-5.6-sol',
        display_name: 'GPT-5.6 Sol',
        base_instructions: 'PRESERVED_BASE_INSTRUCTIONS',
        model_messages: { instructions_template: 'PRESERVED_MODEL_INSTRUCTIONS' },
        use_responses_lite: true,
        supports_search_tool: true,
        tool_mode: 'code_mode_only',
        multi_agent_version: 'v2'
      }
    ]
  })
}

describe('@ankole/agent-computer Codex config', () => {
  it('shares the official Codex Home at Agent scope without CODEX_SQLITE_HOME', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))
    try {
      const materialized = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: officialRuntime('account-1')
      })
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(materialized.agentHome).toBe(join(agentsRoot, 'agent-1'))
      expect(materialized.codexHome).toBe(join(agentsRoot, 'agent-1', '.codex'))
      expect(materialized.env.HOME).toBe(materialized.agentHome)
      expect(materialized.env.CODEX_HOME).toBe(materialized.codexHome)
      expect(materialized.env.CODEX_SQLITE_HOME).toBeUndefined()
      expect(config.features.multi_agent_v2.enabled).toBe(true)

      const overlappingJob = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: officialRuntime('account-1')
      })
      const anotherAgent = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-2',
        runtime: officialRuntime('account-2')
      })

      expect(overlappingJob.codexHome).toBe(materialized.codexHome)
      expect(anotherAgent.codexHome).toBe(join(agentsRoot, 'agent-2', '.codex'))
      expect(anotherAgent.codexHome).not.toBe(materialized.codexHome)
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('trusts a project path through one TOML table override', () => {
    const projectRoot = '/agents/agent.v1/jobs/1000'
    const override = codexConfigCLIOverrides(projectRoot).at(-1)

    expect(override).toBeDefined()
    expect(parse(override!)).toEqual({ projects: { [projectRoot]: { trust_level: 'trusted' } } })
  })

  it('keeps the shared AIGateway provider model-free and sends the frozen binding through one process header', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-aigateway-'))
    try {
      const materialized = materializeCodexConfig(
        {
          agentsRoot,
          agentUID: 'agent-1',
          runtime: aigatewayRuntime()
        },
        { readBundledModelCatalog: bundledModelCatalog }
      )
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      const modelCatalog = JSON.parse(readFileSync(config.model_catalog_json, 'utf8')) as Record<string, any>
      const binding = JSON.parse(
        Buffer.from(materialized.env.ANKOLE_AIGATEWAY_MODEL_BINDING!, 'base64url').toString('utf8')
      )

      expect(config.model).toBeUndefined()
      expect(config.model_provider).toBe('ankole_aigateway')
      expect(config.model_reasoning_effort).toBeUndefined()
      expect(config.model_auto_compact_token_limit).toBe(100000)
      expect(config.model_catalog_json).toBe(join(materialized.codexHome, 'aigateway-model-catalog.json'))
      expect(modelCatalog.models).toEqual([
        expect.objectContaining({
          slug: 'gpt-5.6-sol',
          base_instructions: 'PRESERVED_BASE_INSTRUCTIONS',
          model_messages: { instructions_template: 'PRESERVED_MODEL_INSTRUCTIONS' },
          use_responses_lite: false,
          supports_search_tool: false,
          tool_mode: 'direct',
          multi_agent_version: null
        })
      ])
      expect(config.model_providers.ankole_aigateway.env_http_headers).toEqual({
        'x-ankole-aigateway-model-binding': 'ANKOLE_AIGATEWAY_MODEL_BINDING'
      })
      expect(binding).toEqual({
        selector: 'openrouter/openai/gpt-5.6-sol',
        provider_options: {
          reasoningEffort: 'xhigh',
          nested: { preserved: true }
        },
        supports_parallel_tool_calls: true
      })

      const official = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: officialRuntime('account-1')
      })
      const officialConfig = parse(readFileSync(join(official.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(officialConfig.model).toBeUndefined()
      expect(officialConfig.model_provider).toBeUndefined()
      expect(officialConfig.model_providers).toBeUndefined()
      expect(officialConfig.model_catalog_json).toBeUndefined()
      expect(officialConfig.model_auto_compact_token_limit).toBeUndefined()
      expect(official.env.ANKOLE_AIGATEWAY_MODEL_BINDING).toBeUndefined()
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('rejects an invalid bundled model catalog for AIGateway', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-invalid-catalog-'))
    try {
      expect(() =>
        materializeCodexConfig(
          { agentsRoot, agentUID: 'agent-1', runtime: aigatewayRuntime() },
          { readBundledModelCatalog: () => '{"models":[]}' }
        )
      ).toThrow('must contain at least one model')
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})

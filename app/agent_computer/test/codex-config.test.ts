import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { codexConfigCLIOverrides, materializeCodexConfig } from '../src/tools/codex/config'
import type { CodexRuntimeConfig } from '../src/tools/codex/runtime-config'

function aigatewayRuntime(): CodexRuntimeConfig {
  return {
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

describe('@ankole/agent-computer Codex config', () => {
  it('shares one AIGateway Codex Home at Agent scope without CODEX_SQLITE_HOME', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))
    try {
      const materialized = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: aigatewayRuntime()
      })
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(materialized.agentHome).toBe(join(agentsRoot, 'agent-1'))
      expect(materialized.codexHome).toBe(join(agentsRoot, 'agent-1', '.codex'))
      expect(materialized.env.HOME).toBe(materialized.agentHome)
      expect(materialized.env.CODEX_HOME).toBe(materialized.codexHome)
      expect(materialized.env.CODEX_SQLITE_HOME).toBeUndefined()
      expect(materialized.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE).toBe('codex_cli_rs')
      expect(config.features.code_mode.enabled).toBe(true)
      expect(config.features.multi_agent_v2.enabled).toBe(true)
      expect(config.skills.config).toEqual([
        { name: 'skill-creator', enabled: false },
        { name: 'plugin-creator', enabled: false },
        { name: 'skill-installer', enabled: false }
      ])

      const overlappingJob = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: aigatewayRuntime()
      })
      const anotherAgent = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-2',
        runtime: aigatewayRuntime()
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
      const materialized = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: aigatewayRuntime()
      })
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      const binding = JSON.parse(
        Buffer.from(materialized.env.ANKOLE_AIGATEWAY_MODEL_BINDING!, 'base64url').toString('utf8')
      )

      expect(config.model).toBeUndefined()
      expect(config.model_provider).toBe('ankole_aigateway')
      expect(config.model_reasoning_effort).toBeUndefined()
      expect(config.model_auto_compact_token_limit).toBe(100000)
      expect(config.features.code_mode.enabled).toBe(true)
      expect(config.model_providers.ankole_aigateway.env_http_headers).toEqual({
        'x-ankole-aigateway-model-binding': 'ANKOLE_AIGATEWAY_MODEL_BINDING'
      })
      // Command auth (not env_key) makes Codex refresh the AIGateway models
      // manifest, which serves the supports_search_tool cards.
      expect(config.model_providers.ankole_aigateway.env_key).toBeUndefined()
      expect(config.model_providers.ankole_aigateway.auth).toEqual({
        command: '/bin/sh',
        args: ['-c', 'printf %s "$ANKOLE_AIGATEWAY_API_KEY"'],
        refresh_interval_ms: 0
      })
      expect(binding).toEqual({
        selector: 'openrouter/openai/gpt-5.6-sol',
        provider_options: {
          reasoningEffort: 'xhigh',
          nested: { preserved: true }
        },
        supports_parallel_tool_calls: true
      })
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})

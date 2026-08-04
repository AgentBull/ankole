import { create } from '@bufbuild/protobuf'
import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AIGatewayAPIKeyResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { codexJobThreadConfig } from '../src/core/codex-runner/thread-config'
import {
  codexAIGatewayTokenPath,
  codexConfigCLIOverrides,
  materializeCodexConfig,
  refreshCodexAgentRuntimeCredential,
  resetCodexAgentRuntimeConfig
} from '../src/tools/codex/config'
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
        agentUID: 'agent-1'
      })
      resetCodexAgentRuntimeConfig(materialized.codexHome, aigatewayRuntime().aiGatewayKey.baseUrl)
      refreshCodexAgentRuntimeCredential(materialized.codexHome, aigatewayRuntime().aiGatewayKey.apiKey)
      const config = TOML.parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<
        string,
        any
      >
      expect(materialized.agentHome).toBe(join(agentsRoot, 'agent-1'))
      expect(materialized.codexHome).toBe(join(agentsRoot, 'agent-1', '.codex'))
      expect(materialized.env.HOME).toBe(materialized.agentHome)
      expect(materialized.env.CODEX_HOME).toBe(materialized.codexHome)
      expect(materialized.env.CODEX_SQLITE_HOME).toBeUndefined()
      expect(materialized.env.ANKOLE_AIGATEWAY_API_KEY).toBeUndefined()
      expect(materialized.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE).toBe('codex_cli_rs')
      expect(readFileSync(codexAIGatewayTokenPath(materialized.codexHome), 'utf8')).toBe('agent-key\n')
      expect(config.features.code_mode.enabled).toBe(true)
      expect(config.features.multi_agent_v2.enabled).toBe(true)
      expect(config.skills.config).toEqual([
        { name: 'skill-creator', enabled: false },
        { name: 'plugin-creator', enabled: false },
        { name: 'skill-installer', enabled: false }
      ])

      const overlappingJob = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1'
      })
      const anotherAgent = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-2'
      })

      expect(overlappingJob.codexHome).toBe(materialized.codexHome)
      expect(anotherAgent.codexHome).toBe(join(agentsRoot, 'agent-2', '.codex'))
      expect(anotherAgent.codexHome).not.toBe(materialized.codexHome)
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('keeps CLI overrides process-scoped and trusts the project through thread config', () => {
    const projectRoot = '/agents/agent.v1/jobs/1000'
    const runtime = aigatewayRuntime()
    const threadConfig = codexJobThreadConfig({
      cwd: projectRoot,
      codexHome: '/agents/agent.v1/.codex',
      env: {},
      runtime,
      projectConfig: {
        features: { plugins: false, code_mode: { enabled: true } },
        mcp_servers: { native: { command: 'native-server' } },
        projects: { '/stale': { trust_level: 'untrusted' } }
      }
    })

    expect(codexConfigCLIOverrides()).toEqual([
      '-c',
      'approval_policy="never"',
      '-c',
      'sandbox_mode="danger-full-access"',
      '-c',
      'cli_auth_credentials_store="file"'
    ])
    expect(threadConfig.projects).toEqual({ [projectRoot]: { trust_level: 'trusted' } })
    expect(threadConfig.features).toEqual({ plugins: true, remote_plugin: false, code_mode: { enabled: true } })
    expect(threadConfig.mcp_servers).toEqual({ native: { command: 'native-server' } })
  })

  it('keeps shared config model-free and sends each frozen binding through thread config', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-aigateway-'))
    try {
      const materialized = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1'
      })
      resetCodexAgentRuntimeConfig(materialized.codexHome, aigatewayRuntime().aiGatewayKey.baseUrl)
      const config = TOML.parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<
        string,
        any
      >
      const threadConfig = codexJobThreadConfig({
        cwd: '/agents/agent-1/jobs/job-1',
        codexHome: materialized.codexHome,
        env: { JOB: 'one' },
        runtime: aigatewayRuntime()
      }) as any
      const encodedBinding =
        threadConfig.model_providers.ankole_aigateway.http_headers['x-ankole-aigateway-model-binding']
      const binding = JSON.parse(Buffer.from(encodedBinding, 'base64url').toString('utf8'))

      expect(config.model).toBeUndefined()
      expect(config.model_provider).toBe('ankole_aigateway')
      expect(config.model_reasoning_effort).toBeUndefined()
      expect(config.model_auto_compact_token_limit).toBe(100000)
      expect(config.features.code_mode.enabled).toBe(true)
      expect(config.model_providers.ankole_aigateway.env_http_headers).toBeUndefined()
      expect(materialized.env.ANKOLE_AIGATEWAY_MODEL_BINDING).toBeUndefined()
      // Command auth (not env_key) makes Codex refresh the AIGateway models
      // manifest, which serves the supports_search_tool cards.
      expect(config.model_providers.ankole_aigateway.env_key).toBeUndefined()
      expect(config.model_providers.ankole_aigateway.auth).toEqual({
        command: '/bin/cat',
        args: [codexAIGatewayTokenPath(materialized.codexHome)],
        refresh_interval_ms: 300000
      })
      expect(threadConfig.model_providers.ankole_aigateway.auth).toEqual(config.model_providers.ankole_aigateway.auth)
      expect(binding).toEqual({
        selector: 'openrouter/openai/gpt-5.6-sol',
        provider_options: {
          reasoningEffort: 'xhigh',
          nested: { preserved: true }
        },
        supports_parallel_tool_calls: true
      })
      expect(threadConfig.model_reasoning_effort).toBe('xhigh')
      expect(threadConfig.shell_environment_policy).toEqual({ inherit: 'all', set: { JOB: 'one' } })
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})

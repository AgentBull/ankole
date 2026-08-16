import { create } from '@bufbuild/protobuf'
import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
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
} from '../src/core/codex-runner/agent-home-config'
import type { CodexRuntimeConfig } from '../src/core/codex-runner/runtime-config'

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
      inputModalities: ['text'],
      visionFallback: {
        selector: 'openrouter-vision/google/gemini-3-flash-preview',
        providerOptions: {},
        inputModalities: ['text', 'image']
      },
      modelReasoningEffort: 'xhigh'
    }
  }
}

describe('@ankole/agent-computer Codex config', () => {
  it('shares one AIGateway Codex Home at Agent scope without CODEX_SQLITE_HOME', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))
    const previousStateRoot = process.env.ANKOLE_CODEX_STATE_ROOT
    process.env.ANKOLE_CODEX_STATE_ROOT = join(agentsRoot, 'codex-state')
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
      expect(materialized.codexHome).toBe(join(agentsRoot, 'codex-state', 'agent-1', '.codex'))
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
      expect(anotherAgent.codexHome).toBe(join(agentsRoot, 'codex-state', 'agent-2', '.codex'))
      expect(anotherAgent.codexHome).not.toBe(materialized.codexHome)
    } finally {
      if (previousStateRoot === undefined) delete process.env.ANKOLE_CODEX_STATE_ROOT
      else process.env.ANKOLE_CODEX_STATE_ROOT = previousStateRoot
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('keeps CLI overrides process-scoped and trusts the project through thread config', () => {
    const projectRoot = '/agents/agent.v1/jobs/1000'
    const runtime = aigatewayRuntime()
    const traceparent = '00-11111111111111111111111111111111-1111111111111111-01'
    const observabilityUserHeader = 'x-ankole-observability-user-id'
    const observabilityUserID = 'channel:lark:群聊一'
    const threadConfig = codexJobThreadConfig({
      cwd: projectRoot,
      codexHome: '/agents/agent.v1/.codex',
      env: {},
      runtime,
      turnTracePropagation: { traceparent, observabilityUserID },
      projectConfig: {
        features: { plugins: false, code_mode: { enabled: true } },
        mcp_servers: { native: { command: 'native-server' } },
        model_providers: {
          ankole_aigateway: {
            http_headers: {
              TraceParent: '00-99999999999999999999999999999999-9999999999999999-01',
              'X-Ankole-Observability-User-Id': 'principal:spoofed',
              'x-project-header': 'preserved'
            },
            env_http_headers: {
              TRACEPARENT: 'FORGED_TRACEPARENT_ENV',
              'X-ANKOLE-OBSERVABILITY-USER-ID': 'FORGED_USER_ENV',
              'x-env-project-header': 'PRESERVED_HEADER_ENV'
            }
          }
        },
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
    expect(threadConfig.features).toEqual({
      plugins: true,
      remote_plugin: false,
      code_mode: { enabled: true }
    })
    expect(threadConfig.mcp_servers).toEqual({ native: { command: 'native-server' } })
    const traceHeaders = (threadConfig as any).model_providers.ankole_aigateway.http_headers
    expect(traceHeaders.traceparent).toBe(traceparent)
    expect(traceHeaders[observabilityUserHeader]).toBe(Buffer.from(observabilityUserID).toString('base64url'))
    expect(traceHeaders.TraceParent).toBeUndefined()
    expect(traceHeaders['X-Ankole-Observability-User-Id']).toBeUndefined()
    expect(traceHeaders['x-project-header']).toBe('preserved')
    const envTraceHeaders = (threadConfig as any).model_providers.ankole_aigateway.env_http_headers
    expect(envTraceHeaders.TRACEPARENT).toBeUndefined()
    expect(envTraceHeaders['X-ANKOLE-OBSERVABILITY-USER-ID']).toBeUndefined()
    expect(envTraceHeaders['x-env-project-header']).toBe('PRESERVED_HEADER_ENV')

    const staleHeaderThreadConfig = codexJobThreadConfig({
      cwd: projectRoot,
      codexHome: '/agents/agent.v1/.codex',
      env: {},
      runtime,
      projectConfig: {
        model_providers: {
          ankole_aigateway: {
            http_headers: {
              TraceParent: traceparent,
              'X-Ankole-Observability-User-Id': 'principal:stale'
            },
            env_http_headers: {
              TraceParent: 'STALE_TRACEPARENT_ENV',
              'X-Ankole-Observability-User-Id': 'STALE_USER_ENV'
            }
          }
        }
      }
    }) as any
    expect(staleHeaderThreadConfig.model_providers.ankole_aigateway.http_headers.traceparent).toBeUndefined()
    expect(
      staleHeaderThreadConfig.model_providers.ankole_aigateway.http_headers[observabilityUserHeader]
    ).toBeUndefined()
    expect(staleHeaderThreadConfig.model_providers.ankole_aigateway.http_headers.TraceParent).toBeUndefined()
    expect(
      staleHeaderThreadConfig.model_providers.ankole_aigateway.http_headers['X-Ankole-Observability-User-Id']
    ).toBeUndefined()
    expect(staleHeaderThreadConfig.model_providers.ankole_aigateway.env_http_headers).toEqual({})

    const unattributedThreadConfig = codexJobThreadConfig({
      cwd: projectRoot,
      codexHome: '/agents/agent.v1/.codex',
      env: {},
      runtime,
      turnTracePropagation: { traceparent, observabilityUserID: null }
    }) as any
    expect(unattributedThreadConfig.model_providers.ankole_aigateway.http_headers).toMatchObject({
      traceparent,
      [observabilityUserHeader]: 'none'
    })
  })

  it('keeps shared config model-free and sends each frozen binding through thread config', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-aigateway-'))
    const previousStateRoot = process.env.ANKOLE_CODEX_STATE_ROOT
    process.env.ANKOLE_CODEX_STATE_ROOT = join(agentsRoot, 'codex-state')
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
      expect(config.model_auto_compact_token_limit).toBeUndefined()
      expect(config.features.code_mode.enabled).toBe(true)
      expect(config.model_providers.ankole_aigateway.name).toBe('OpenAI')
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
      expect(threadConfig.model_providers.ankole_aigateway.name).toBe('OpenAI')
      expect(binding).toEqual({
        selector: 'openrouter/openai/gpt-5.6-sol',
        provider_options: {
          reasoningEffort: 'xhigh',
          nested: { preserved: true }
        },
        supports_parallel_tool_calls: true,
        input_modalities: ['text'],
        vision_fallback: {
          selector: 'openrouter-vision/google/gemini-3-flash-preview',
          provider_options: {},
          input_modalities: ['text', 'image']
        }
      })
      expect(threadConfig.model_reasoning_effort).toBe('xhigh')
      expect(threadConfig.shell_environment_policy).toEqual({ inherit: 'all', set: { JOB: 'one' } })
    } finally {
      if (previousStateRoot === undefined) delete process.env.ANKOLE_CODEX_STATE_ROOT
      else process.env.ANKOLE_CODEX_STATE_ROOT = previousStateRoot
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})

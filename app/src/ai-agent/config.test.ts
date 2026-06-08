import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { readAiAgentModelsConfig, resolveAiAgentModelsConfig, writeAiAgentModelsConfig } = await import('./config')

describe('AIAgent runtime model profile config', () => {
  it('materializes primary, light, and heavy model roles with reasoning defaults', () => {
    const inherited = resolveAiAgentModelsConfig({
      primary: {
        providerId: 'openai_main',
        model: 'primary'
      }
    })

    expect(inherited.primary.model).toBe('primary')
    expect(inherited.primary.reasoning).toBe('medium')
    expect(inherited.light.model).toBe('primary')
    expect(inherited.light.reasoning).toBe('low')
    expect(inherited.heavy.model).toBe('primary')
    expect(inherited.heavy.reasoning).toBe('high')

    const explicit = resolveAiAgentModelsConfig({
      primary: {
        providerId: 'openai_main',
        model: 'primary',
        reasoning: 'minimal'
      },
      light: {
        providerId: 'openai_main',
        model: 'light'
      },
      heavy: {
        providerId: 'anthropic_main',
        model: 'heavy',
        reasoning: 'xhigh'
      }
    })

    expect(explicit.primary.reasoning).toBe('minimal')
    expect(explicit.light.model).toBe('light')
    expect(explicit.light.reasoning).toBe('low')
    expect(explicit.heavy.providerId).toBe('anthropic_main')
    expect(explicit.heavy.reasoning).toBe('xhigh')
  })

  it('stores ai_agent.models without replacing external chat-channel metadata', () => {
    const metadata = writeAiAgentModelsConfig(
      {
        owner: 'ops',
        external: {
          adapters: [{ adapter: 'lark', name: 'main', enabled: true }]
        },
        ai_agent: {
          note: 'keep'
        }
      },
      {
        primary: {
          providerId: 'openai_main',
          model: 'gpt-test'
        }
      }
    )

    expect(metadata.external).toEqual({
      adapters: [{ adapter: 'lark', name: 'main', enabled: true }]
    })
    expect(metadata.ai_agent).toMatchObject({
      note: 'keep',
      models: {
        primary: {
          providerId: 'openai_main',
          model: 'gpt-test'
        }
      }
    })
    expect(readAiAgentModelsConfig(metadata)).toEqual({
      primary: {
        providerId: 'openai_main',
        model: 'gpt-test'
      }
    })
  })
})

import { describe, expect, test } from 'bun:test'
import {
  brainEmbeddingAgentOptions,
  brainEmbeddingDraft,
  brainEmbeddingValidationError,
  pluginIDsFromDraft,
  pluginRestartRequired,
  brainDreamingDraft,
  brainDreamingValidationError,
  serializeBrainDreamingDraft,
  serializeBrainEmbeddingDraft,
  settingEditorKind,
  settingStringDraft,
  settingValueKind,
  togglePluginID,
  unknownPluginIDs
} from './setting-value-editor'

describe('setting value editor', () => {
  test('uses the object editor only for JSON objects', () => {
    expect(settingValueKind({ mode: 'strict' })).toBe('object')
    expect(settingValueKind(['one'])).toBe('structured')
    expect(settingValueKind(null)).toBe('structured')
  })

  test('unwraps a JSON string for the text input', () => {
    expect(settingStringDraft('"Asia/Shanghai"')).toBe('Asia/Shanghai')
  })

  test('matches exact key editors before generic fallbacks', () => {
    expect(settingEditorKind('brain.embedding', false, {})).toBe('brainEmbedding')
    expect(settingEditorKind('plugins.enabled_ids', false, [])).toBe('plugins')
    expect(settingEditorKind('system.timezone', false, 'Asia/Shanghai')).toBe('timezone')
    expect(settingEditorKind('i18n.default_locale', false, 'en-US')).toBe('locale')
    expect(settingEditorKind('runtime.secret', true, undefined)).toBe('encrypted')
    expect(settingEditorKind('feature.enabled', false, true)).toBe('boolean')
    expect(settingEditorKind('feature.config', false, {})).toBe('object')
  })

  test('round-trips the Brain embedding editor draft', () => {
    const draft = brainEmbeddingDraft(
      JSON.stringify({ enabled: true, model_agent_uid: 'research-agent', dimensions: 1_024 })
    )

    expect(draft).toEqual({ enabled: true, modelAgentUID: 'research-agent', dimensions: '1024' })
    expect(JSON.parse(serializeBrainEmbeddingDraft(draft))).toEqual({
      enabled: true,
      model_agent_uid: 'research-agent',
      dimensions: 1_024
    })
  })

  test('validates the enabled Brain embedding contract', () => {
    expect(brainEmbeddingValidationError({ enabled: false, model_agent_uid: null, dimensions: null })).toBeUndefined()
    expect(brainEmbeddingValidationError({ enabled: true, model_agent_uid: null, dimensions: 1_024 })).toBe(
      'model_agent'
    )
    expect(brainEmbeddingValidationError({ enabled: true, model_agent_uid: 'agent', dimensions: 0 })).toBe('dimensions')
    expect(brainEmbeddingValidationError({ enabled: false, model_agent_uid: null, dimensions: 1.5 })).toBe('dimensions')
    expect(
      brainEmbeddingValidationError({ enabled: true, model_agent_uid: 'agent', dimensions: 4_096 })
    ).toBeUndefined()
  })

  test('offers only agents with complete embedding profiles', () => {
    const options = brainEmbeddingAgentOptions([
      {
        uid: 'configured',
        display_name: 'Configured',
        status: 'active',
        options: {
          ai_agent: {
            models: {
              embedding: {
                model: 'qwen/qwen3-embedding-8b',
                provider_id: 'openrouter',
                provider_options: {}
              }
            }
          }
        }
      },
      {
        uid: 'disabled',
        display_name: 'Disabled',
        status: 'disabled',
        options: {
          ai_agent: {
            models: { embedding: { model: 'text-embedding-3-large', provider_id: 'openai' } }
          }
        }
      },
      {
        uid: 'missing',
        display_name: 'Missing',
        status: 'active',
        options: { ai_agent: { models: { light: { model: 'gpt-5', provider_id: 'openrouter' } } } }
      },
      {
        uid: 'incomplete',
        display_name: 'Incomplete',
        status: 'active',
        options: { ai_agent: { models: { embedding: { provider_id: 'openrouter' } } } }
      }
    ])

    expect(options).toEqual([
      {
        uid: 'configured',
        displayName: 'Configured',
        model: 'qwen/qwen3-embedding-8b',
        providerID: 'openrouter'
      }
    ])
  })

  test('normalizes plugin drafts and preserves undiscovered ids', () => {
    const selected = pluginIDsFromDraft('["slack", "future", "slack"]')
    expect(selected).toEqual(['future', 'slack'])
    expect(togglePluginID(selected, 'lark', true)).toEqual(['future', 'lark', 'slack'])
    expect(togglePluginID(selected, 'slack', false)).toEqual(['future'])
    expect(unknownPluginIDs(selected, ['slack', 'lark'])).toEqual(['future'])
  })

  test('derives restart state from runtime and next-start selection', () => {
    expect(pluginRestartRequired(true, true)).toBe(false)
    expect(pluginRestartRequired(false, false)).toBe(false)
    expect(pluginRestartRequired(true, false)).toBe(true)
    expect(pluginRestartRequired(false, true)).toBe(true)
  })
})

describe('brain dreaming editor', () => {
  test('routes brain.dreaming to its own editor', () => {
    expect(settingEditorKind('brain.dreaming', false, {})).toBe('brainDreaming')
  })

  test('reads an absent enabled flag as the default rather than as off', () => {
    expect(brainDreamingDraft('{"enabled":null}').enabled).toBe('default')
    expect(brainDreamingDraft('{"enabled":false}').enabled).toBe('off')
    expect(brainDreamingDraft('{"enabled":true}').enabled).toBe('on')
  })

  test('keeps a null cold start lookback apart from zero', () => {
    expect(
      brainDreamingDraft('{"episode_cold_start_lookback_days":null}').numbers.episode_cold_start_lookback_days
    ).toBe('')
    expect(brainDreamingDraft('{"episode_cold_start_lookback_days":0}').numbers.episode_cold_start_lookback_days).toBe(
      '0'
    )

    const draft = brainDreamingDraft('{}')
    const cleared = JSON.parse(serializeBrainDreamingDraft(draft)) as Record<string, unknown>
    expect(cleared.episode_cold_start_lookback_days).toBeNull()
    expect(cleared.enabled).toBeNull()
  })

  test('reports the field that is out of range', () => {
    const value = {
      enabled: null,
      token_limit: 0,
      mutation_limit: 0,
      curation_silence_minutes: 30,
      curation_backlog_rows: 50,
      episode_silence_minutes: 30,
      episode_backlog_rows: 200,
      episode_window_max_rows: 200,
      episode_window_max_tokens: 8_000,
      episode_tail_guard_rows: 20,
      episode_tail_guard_minutes: 360,
      episode_cold_start_lookback_days: 5
    }

    expect(brainDreamingValidationError(value)).toBeUndefined()
    expect(brainDreamingValidationError({ ...value, episode_window_max_rows: 501 })).toBe('episode_window_max_rows')
    expect(brainDreamingValidationError({ ...value, episode_cold_start_lookback_days: null })).toBeUndefined()
    expect(brainDreamingValidationError([])).toBe('invalid')
  })
})

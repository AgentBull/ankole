import { beforeAll, describe, expect, test } from 'bun:test'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import i18n, { loadLocale } from '../../common/i18n'
import { buildModelAliases, filterGroupOptions } from './oidc-clients'

beforeAll(() => loadLocale('en-US'))

const t = i18n.getFixedT('en-US')

describe('OIDC Client editor', () => {
  test('searches user groups by display name, policy name, and description', () => {
    const groups = [
      { id: 'engineering', label: '工程团队', name: 'engineers', description: 'Product builders' },
      { id: 'support', label: '客户成功', name: 'customer-success', description: 'Support operators' }
    ]

    expect(filterGroupOptions(groups, '工程')).toEqual([groups[0]])
    expect(filterGroupOptions(groups, 'CUSTOMER-SUCCESS')).toEqual([groups[1]])
    expect(filterGroupOptions(groups, 'builders')).toEqual([groups[0]])
    expect(filterGroupOptions(groups, '  ')).toEqual(groups)
  })

  test('builds a Client model map from custom aliases and model-profile settings', () => {
    expect(
      buildModelAliases(
        [
          {
            key: 'new:0',
            name: 'research',
            persisted: false,
            profile: {
              contextLength: '131072',
              description: 'Long-context research model',
              model: 'gpt-5.6-sol',
              providerID: 'openai-main',
              providerOptions: {}
            }
          }
        ],
        [provider('openai-main', 'openai')],
        [kind('openai', ['llm'])],
        t
      )
    ).toEqual({
      ok: true,
      value: {
        research: {
          context_length: 131072,
          description: 'Long-context research model',
          model: 'gpt-5.6-sol',
          provider_id: 'openai-main',
          provider_options: {}
        }
      }
    })
  })

  test('rejects fixed Agent profile names as Client aliases', () => {
    const result = buildModelAliases(
      [
        {
          key: 'new:0',
          name: 'primary',
          persisted: false,
          profile: {
            contextLength: '',
            description: 'Reserved alias',
            model: 'gpt-5.6-sol',
            providerID: 'openai-main',
            providerOptions: {}
          }
        }
      ],
      [provider('openai-main', 'openai')],
      [kind('openai', ['llm'])],
      t
    )

    expect(result).toEqual({
      aliasKey: 'new:0',
      error: t('console.models.custom_name_reserved'),
      field: 'name',
      ok: false
    })
  })
})

function provider(providerID: string, providerKind: string): AIGatewayProviderItem {
  return {
    connection_options: {},
    credential_pool: { entries: [], strategy: 'fill_first' },
    id: providerID,
    provider_id: providerID,
    provider_kind: providerKind,
    provider_metadata: {}
  }
}

function kind(providerKind: string, capabilities: string[]): AIGatewayProviderKindItem {
  return {
    capabilities,
    capability_specs: [],
    connection_options: [],
    credential_options: [],
    default_base_url: null,
    label: { default: providerKind },
    provider_kind: providerKind,
    runtime_provider_options: [],
    settings: []
  }
}

import { describe, expect, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  ConfigFields,
  configFieldRequired,
  configFieldValidationMessage,
  localizedText,
  parseConfigFieldInput,
  type ConfigFieldDefinition
} from './config-fields'

const field = (overrides: Partial<ConfigFieldDefinition>): ConfigFieldDefinition => ({
  path: 'credential',
  type: 'string',
  ...overrides
})

describe('configFieldRequired', () => {
  test('keeps unconditional fields required', () => {
    expect(configFieldRequired(field({ required: true }), {})).toBe(true)
  })

  test('requires a conditional field only when every condition matches', () => {
    const conditional = field({
      requiredWhen: [
        { path: 'sync.contacts', value: true },
        { path: 'sync.realtime', value: true }
      ]
    })

    expect(configFieldRequired(conditional, { sync: { contacts: true, realtime: true } })).toBe(true)
    expect(configFieldRequired(conditional, { sync: { contacts: true, realtime: false } })).toBe(false)
    expect(configFieldRequired(conditional, {})).toBe(false)
  })
})

describe('configFieldValidationMessage', () => {
  test('validates one string or every string-array item against a pattern', () => {
    const domainField = field({
      type: 'string_array',
      validation: {
        kind: 'pattern',
        pattern: '^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}$',
        message: { default: 'Enter valid domains.', 'zh-Hans-CN': '请输入有效域名。' }
      }
    })

    expect(configFieldValidationMessage(domainField, ['example.com', 'sub.example.cn'], 'zh-Hans-CN')).toBeUndefined()
    expect(configFieldValidationMessage(domainField, ['example.com', 'not a domain'], 'zh-Hans-CN')).toBe(
      '请输入有效域名。'
    )
    expect(configFieldValidationMessage({ ...domainField, type: 'string' }, 'not a domain', 'en-US')).toBe(
      'Enter valid domains.'
    )
  })

  test('validates JSON objects and their required string properties', () => {
    const jsonField = field({
      validation: {
        kind: 'json_object',
        message: { default: 'Paste a valid service account JSON key.' },
        requiredStringProperties: ['client_email', 'private_key'],
        stringPrefixes: { private_key: '-----BEGIN' }
      }
    })

    expect(
      configFieldValidationMessage(
        jsonField,
        JSON.stringify({ client_email: 'service@example.com', private_key: '-----BEGIN PRIVATE KEY-----' }),
        'en-US'
      )
    ).toBeUndefined()
    expect(configFieldValidationMessage(jsonField, '[]', 'en-US')).toBe('Paste a valid service account JSON key.')
    expect(configFieldValidationMessage(jsonField, '{"client_email":"service@example.com"}', 'en-US')).toBe(
      'Paste a valid service account JSON key.'
    )
    expect(configFieldValidationMessage(jsonField, 'not json', 'en-US')).toBe('Paste a valid service account JSON key.')
  })

  test('does not report empty values because required validation owns them', () => {
    const tokenField = field({
      validation: {
        kind: 'pattern',
        pattern: '^xoxb-',
        message: { default: 'Use a Bot Token that starts with xoxb-.' }
      }
    })

    expect(configFieldValidationMessage(tokenField, '', 'en-US')).toBeUndefined()
  })
})

test('localized labels return selected text and reject non-text values', () => {
  expect(localizedText({ default: 'Provider', 'zh-Hans-CN': '提供商' }, 'zh-Hans-CN')).toBe('提供商')
  expect(localizedText({ default: 'Provider' }, 'zh-Hans-CN')).toBe('Provider')
  for (const value of [
    null,
    [],
    'Provider',
    { default: 1 },
    { default: {} },
    { default: 'Provider', 'zh-Hans-CN': false }
  ]) {
    expect(localizedText(value, 'zh-Hans-CN')).toBeUndefined()
  }
})

describe('parseConfigFieldInput and ConfigFields rendering', () => {
  test('clearing an integer input produces undefined instead of snapping to zero', () => {
    const intField = field({ path: 'port', type: 'integer' })
    expect(parseConfigFieldInput(intField, '')).toBeUndefined()
    expect(parseConfigFieldInput(intField, '0')).toBe(0)
    expect(parseConfigFieldInput(intField, '587')).toBe(587)
    expect(parseConfigFieldInput(field({ path: 'host', type: 'string' }), '')).toBe('')
  })

  test('renders cleared integer fields empty and rotates the advanced trigger chevron on expand', () => {
    const html = renderToStaticMarkup(
      createElement(ConfigFields, {
        config: {},
        fields: [
          field({ path: 'port', type: 'integer', label: { default: 'Port' } }),
          field({ path: 'timeout', type: 'integer', advanced: true, label: { default: 'Timeout' } })
        ],
        locale: 'en-US',
        onChange() {}
      })
    )

    expect(html).toMatch(/<input[^>]*type="number"[^>]*value=""/)
    expect(html).toContain('group flex w-full items-center justify-between')
    expect(html).toContain('transition-transform group-aria-expanded:rotate-180')
  })
})

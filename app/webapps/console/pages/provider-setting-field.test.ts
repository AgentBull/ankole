import { describe, expect, test } from 'bun:test'
import i18n from '../../common/i18n'
import { providerSettingPresentation, selectControlValue, UNSET_SELECT } from './provider-setting-field'

describe('provider setting presentation', () => {
  test('explains the service tier override in both Console languages', () => {
    const zh = i18n.getFixedT('zh-Hans-CN')
    const en = i18n.getFixedT('en-US')

    expect(providerSettingPresentation(zh, 'serviceTier')).toEqual({
      label: '服务等级',
      description: '覆盖此模型档案的服务等级。priority 等可用值取决于模型提供商、账号和模型；留空则使用默认值。'
    })
    expect(providerSettingPresentation(en, 'serviceTier')).toEqual({
      label: 'Service tier',
      description:
        'Overrides the service tier for this model profile. Values such as priority depend on the provider, account, and model. Leave blank to use the default.'
    })
  })

  test('explains OpenAI output controls in both Console languages', () => {
    const zh = i18n.getFixedT('zh-Hans-CN')
    const en = i18n.getFixedT('en-US')

    expect(providerSettingPresentation(zh, 'reasoningSummary')).toEqual({
      label: '推理摘要',
      description: '控制 Responses API 返回的推理摘要；可用程度取决于模型。留空则使用模型提供商的默认值。'
    })
    expect(providerSettingPresentation(zh, 'textVerbosity')).toEqual({
      label: '回答详略',
      description: '设置回答的默认详细程度；具体长度和结构仍由任务要求决定。'
    })
    expect(providerSettingPresentation(en, 'reasoningSummary')).toEqual({
      label: 'Reasoning summary',
      description:
        'Controls the reasoning summary returned by the Responses API. Model support varies. Leave unset to use the provider default.'
    })
    expect(providerSettingPresentation(en, 'textVerbosity')).toEqual({
      label: 'Answer detail',
      description:
        'Sets the default level of detail for answers. Task-specific instructions still control the required length and structure.'
    })
  })

  test('keeps undeclared ProviderDSL keys readable without inventing product copy', () => {
    const t = i18n.getFixedT('en-US')

    expect(providerSettingPresentation(t, 'strictJSONSchema')).toEqual({ label: 'Strict JSON schema' })
  })
})

describe('select control value', () => {
  test('an explicit draft always wins', () => {
    expect(selectControlValue('oauth', 'api_key', true)).toBe('oauth')
    expect(selectControlValue('oauth', 'api_key', false)).toBe('oauth')
  })

  test('a blank draft that keeps the stored value presents the sentinel, never the DSL default', () => {
    expect(selectControlValue('', 'api_key', true)).toBe(UNSET_SELECT)
  })

  test('a blank draft for a new record preselects the DSL default', () => {
    expect(selectControlValue('', 'api_key', false)).toBe('api_key')
    expect(selectControlValue('', '', false)).toBe(UNSET_SELECT)
  })
})

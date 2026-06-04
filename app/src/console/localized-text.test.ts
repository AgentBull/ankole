import { describe, expect, it } from 'bun:test'
import { resolveBullXPluginLocalizedText } from '@agentbull/bullx-sdk/plugins'

describe('BullX plugin localized setup text', () => {
  it('resolves exact locale, language prefix, English fallback, first value, then id fallback', () => {
    expect(
      resolveBullXPluginLocalizedText(
        {
          'en-US': 'Lark',
          'zh-Hans-CN': '飞书',
          ja: 'Lark JA'
        },
        'zh-Hans-CN',
        'adapter.lark'
      )
    ).toBe('飞书')

    expect(
      resolveBullXPluginLocalizedText(
        {
          en: 'English',
          'zh-Hans-CN': '简体中文'
        },
        'en-GB',
        'adapter.lark'
      )
    ).toBe('English')

    expect(
      resolveBullXPluginLocalizedText(
        {
          'en-US': 'American English',
          ja: 'Japanese'
        },
        'fr-FR',
        'adapter.lark'
      )
    ).toBe('American English')

    expect(
      resolveBullXPluginLocalizedText(
        {
          ja: 'Japanese',
          'zh-Hans-CN': '简体中文'
        },
        'fr-FR',
        'adapter.lark'
      )
    ).toBe('Japanese')

    expect(resolveBullXPluginLocalizedText(undefined, 'fr-FR', 'adapter.lark')).toBe('adapter.lark')
  })
})

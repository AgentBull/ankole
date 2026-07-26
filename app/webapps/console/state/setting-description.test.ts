import { describe, expect, test } from 'bun:test'
import i18n from '../../common/i18n'
import { settingDescription } from './setting-description'

describe('settingDescription', () => {
  const t = i18n.getFixedT('zh-Hans-CN')

  test('localizes exact and concrete pattern keys through their registry identity', () => {
    expect(
      settingDescription(t, {
        key: 'plugins.enabled_ids',
        description: 'Plugin ids enabled on the next Ankole process start.'
      })
    ).toBe('下次 Ankole 进程启动时启用的 Control Plane Plugin ID。')

    expect(
      settingDescription(t, {
        key: 'signals_gateway.lark.bindings.primary',
        pattern_id: 'signals_gateway.lark.bindings.*',
        description: 'Encrypted Lark / Feishu chat binding configuration.'
      })
    ).toBe('加密的 Lark / 飞书聊天渠道配置。')
  })

  test('falls back to the canonical registry description for an untranslated key', () => {
    expect(
      settingDescription(t, {
        key: 'extension.future_key',
        description: 'Future extension setting.'
      })
    ).toBe('Future extension setting.')
  })
})

import { beforeAll, describe, expect, test } from 'bun:test'
import i18n, { loadLocale } from '../../common/i18n'
import type { AppConfigurationItem } from '../api/configuration-types'
import { settingDescription, settingGroup, settingGroupID, settingOwnerRoute, settingRows } from './setting-groups'

beforeAll(() => loadLocale('zh-Hans-CN'))

function item(key: string, overrides: Partial<AppConfigurationItem> = {}): AppConfigurationItem {
  return {
    default_present: true,
    editable: true,
    encrypted: false,
    key,
    kind: 'exact',
    overridden: false,
    present: true,
    source: 'default',
    value: null,
    ...overrides
  } as AppConfigurationItem
}

describe('setting groups', () => {
  test('claims only the declared prefixes', () => {
    expect(settingGroupID('observability.traces.enabled')).toBe('observability')
    expect(settingGroupID('observability.tracestore.enabled')).toBeUndefined()
    expect(settingGroupID('observability.metrics.enabled')).toBeUndefined()
    expect(settingGroupID('ai_agent.max_iterations')).toBeUndefined()
    expect(settingGroup('observability')).toEqual({ id: 'observability', prefix: 'observability.traces.' })
    expect(settingGroup('unknown')).toBeUndefined()
  })

  test('collects group members and leaves other keys as their own rows', () => {
    const rows = settingRows([
      item('observability.traces.enabled'),
      item('observability.traces.provider'),
      item('system.timezone'),
      item('i18n.default_locale')
    ])

    expect(rows.groups).toHaveLength(1)
    expect(rows.groups[0]?.items.map(member => member.key)).toEqual([
      'observability.traces.enabled',
      'observability.traces.provider'
    ])
    expect(rows.singles.map(single => single.key)).toEqual(['system.timezone', 'i18n.default_locale'])
    expect(rows.managed).toHaveLength(0)
  })

  test('moves keys the installation owns out of the main list', () => {
    const rows = settingRows([
      item('observability.traces.enabled'),
      item('setup.completed', { editable: false }),
      item('runtime_fabric.worker_auth_key', { editable: false, encrypted: true })
    ])

    expect(rows.managed.map(managed => managed.key)).toEqual(['setup.completed', 'runtime_fabric.worker_auth_key'])
    expect(rows.groups[0]?.items.map(member => member.key)).toEqual(['observability.traces.enabled'])
  })

  test('keeps a read-only group member out of the group it would otherwise join', () => {
    const rows = settingRows([
      item('observability.traces.enabled'),
      item('observability.traces.provider', { editable: false })
    ])

    expect(rows.groups[0]?.items.map(member => member.key)).toEqual(['observability.traces.enabled'])
    expect(rows.managed.map(managed => managed.key)).toEqual(['observability.traces.provider'])
  })

  test('sends the identity activation list to the page that writes it', () => {
    expect(settingOwnerRoute('principals.identity_providers.active')).toBe('/identity')
    expect(settingOwnerRoute('observability.traces.enabled')).toBeUndefined()
  })
})

describe('setting descriptions', () => {
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
        key: 'signals.lark.bindings.primary',
        pattern_id: 'signals.lark.bindings.*',
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

import { describe, expect, test } from 'bun:test'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import { groupOverridden, settingGroupID, settingGroupPrefix, settingOwnerRoute, settingRows } from './setting-groups'

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
    expect(settingGroupID('brain.dreaming')).toBe('brain')
    expect(settingGroupID('brainstorm.enabled')).toBeUndefined()
    expect(settingGroupID('ai_agent.max_iterations')).toBeUndefined()
    expect(settingGroupPrefix('brain')).toBe('brain.')
  })

  test('collects group members and leaves other keys as their own rows', () => {
    const rows = settingRows([
      item('brain.dreaming'),
      item('brain.search'),
      item('system.timezone'),
      item('i18n.default_locale')
    ])

    expect(rows.groups).toHaveLength(1)
    expect(rows.groups[0]?.items.map(member => member.key)).toEqual(['brain.dreaming', 'brain.search'])
    expect(rows.singles.map(single => single.key)).toEqual(['system.timezone', 'i18n.default_locale'])
    expect(rows.managed).toHaveLength(0)
  })

  test('moves keys the installation owns out of the main list', () => {
    const rows = settingRows([
      item('brain.dreaming'),
      item('setup.completed', { editable: false }),
      item('runtime_fabric.worker_auth_key', { editable: false, encrypted: true })
    ])

    expect(rows.managed.map(managed => managed.key)).toEqual(['setup.completed', 'runtime_fabric.worker_auth_key'])
    expect(rows.groups[0]?.items.map(member => member.key)).toEqual(['brain.dreaming'])
  })

  test('keeps a read-only group member out of the group it would otherwise join', () => {
    const rows = settingRows([item('brain.dreaming'), item('brain.embedding', { editable: false })])

    expect(rows.groups[0]?.items.map(member => member.key)).toEqual(['brain.dreaming'])
    expect(rows.managed.map(managed => managed.key)).toEqual(['brain.embedding'])
  })

  test('marks a group overridden when any member carries an installation value', () => {
    expect(groupOverridden({ id: 'brain', items: [item('brain.search')] })).toBe(false)
    expect(groupOverridden({ id: 'brain', items: [item('brain.search', { overridden: true })] })).toBe(true)
  })

  test('sends the identity activation list to the page that writes it', () => {
    expect(settingOwnerRoute('principals.identity_providers.active')).toBe('/identity')
    expect(settingOwnerRoute('brain.dreaming')).toBeUndefined()
  })
})

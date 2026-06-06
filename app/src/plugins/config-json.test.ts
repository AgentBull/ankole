import { describe, expect, it } from 'bun:test'
import type { BullXPluginJsonValue } from '@agentbull/bullx-sdk/plugins'
import {
  defaultPluginConfigForSetup,
  getPluginConfigPath,
  mergePluginConfigObjects,
  setPluginConfigPath,
  type PluginConfigJsonObject
} from './config-json'

describe('plugin config JSON helpers', () => {
  it('builds user-visible defaults without overwriting explicit defaultConfig values', () => {
    const setupDefault = {
      auth: {
        appId: 'configured-app',
        scopes: ['base']
      }
    } satisfies PluginConfigJsonObject

    const config = defaultPluginConfigForSetup({
      defaultConfig: setupDefault,
      fields: [
        {
          path: ['auth', 'appId'],
          defaultValue: 'field-app'
        },
        {
          path: ['auth', 'appSecret'],
          defaultValue: 'field-secret'
        },
        {
          path: ['group_message_mode'],
          defaultValue: 'observe_all'
        }
      ]
    })

    expect(config).toEqual({
      auth: {
        appId: 'configured-app',
        appSecret: 'field-secret',
        scopes: ['base']
      },
      group_message_mode: 'observe_all'
    })

    setNestedValue(config, ['auth', 'scopes'], ['changed'])
    setNestedValue(config, ['auth', 'appSecret'], 'changed-secret')

    expect(setupDefault).toEqual({
      auth: {
        appId: 'configured-app',
        scopes: ['base']
      }
    })
  })

  it('deep-merges operator patches without mutating existing form state', () => {
    const existing = {
      auth: {
        appId: 'old-app',
        appSecret: 'keep-secret'
      },
      group_message_mode: 'observe_all'
    } satisfies PluginConfigJsonObject
    const patch = {
      auth: {
        appId: 'new-app'
      }
    } satisfies PluginConfigJsonObject

    const merged = mergePluginConfigObjects(existing, patch)

    expect(merged).toEqual({
      auth: {
        appId: 'new-app',
        appSecret: 'keep-secret'
      },
      group_message_mode: 'observe_all'
    })
    expect(existing).toEqual({
      auth: {
        appId: 'old-app',
        appSecret: 'keep-secret'
      },
      group_message_mode: 'observe_all'
    })
  })

  it('updates nested field paths while preserving sibling values', () => {
    const source = {
      auth: {
        appId: 'old-app',
        appSecret: 'keep-secret'
      }
    } satisfies PluginConfigJsonObject

    const next = setPluginConfigPath(source, ['auth', 'appId'], 'new-app')

    expect(getPluginConfigPath(next, ['auth', 'appId'])).toBe('new-app')
    expect(getPluginConfigPath(next, ['auth', 'appSecret'])).toBe('keep-secret')
    expect(getPluginConfigPath(source, ['auth', 'appId'])).toBe('old-app')
  })
})

function setNestedValue(source: PluginConfigJsonObject, path: readonly string[], value: BullXPluginJsonValue): void {
  let current: PluginConfigJsonObject = source
  for (const segment of path.slice(0, -1)) {
    const next = current[segment]
    if (!next || typeof next !== 'object' || Array.isArray(next)) throw new Error(`missing object at ${segment}`)
    current = next as PluginConfigJsonObject
  }

  current[path[path.length - 1]!] = value
}

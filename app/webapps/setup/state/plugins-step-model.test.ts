import { describe, expect, test } from 'bun:test'
import { filterSelectedPluginItems, PluginsStepModel } from './plugins-step-model'

describe('PluginsStepModel', () => {
  test('initializes once and preserves local selection across a refetch', () => {
    const model = new PluginsStepModel()

    model.initialize('setup-plugins', ['github'])
    model.setPluginSelected('slack', true)
    model.initialize('setup-plugins', ['notion'])

    expect(model.submission()).toEqual({ pluginIDs: ['github', 'slack'] })
    model[Symbol.dispose]()
  })

  test('restores boot-loaded items when a plugin is selected again', () => {
    const model = new PluginsStepModel()
    const adapters = [
      { adapterID: 'lark', pluginID: 'lark-adapter' },
      { adapterID: 'slack', pluginID: 'slack-adapter' }
    ]

    model.initialize('setup-plugins', ['lark-adapter', 'slack-adapter'])
    model.setPluginSelected('slack-adapter', false)
    expect(filterSelectedPluginItems(adapters, model.selectedPluginIDs.value)).toEqual([adapters[0]])

    model.setPluginSelected('slack-adapter', true)
    expect(filterSelectedPluginItems(adapters, model.selectedPluginIDs.value)).toEqual(adapters)
    model[Symbol.dispose]()
  })
})

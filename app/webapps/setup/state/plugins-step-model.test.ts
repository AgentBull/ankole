import { describe, expect, test } from 'bun:test'
import { PluginsStepModel } from './plugins-step-model'

describe('PluginsStepModel', () => {
  test('initializes once and preserves local selection across a refetch', () => {
    const model = new PluginsStepModel()

    model.initialize('setup-plugins', ['github'])
    model.setPluginSelected('slack', true)
    model.initialize('setup-plugins', ['notion'])

    expect(model.submission()).toEqual({ pluginIDs: ['github', 'slack'] })
    model[Symbol.dispose]()
  })
})

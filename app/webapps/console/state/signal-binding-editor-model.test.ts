import { describe, expect, test } from 'bun:test'
import { SignalBindingEditorModel } from './signal-binding-editor-model'

describe('SignalBindingEditorModel', () => {
  test('adapter changes replace adapter-owned defaults without changing the route-owned agent', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('new:agent-a', {
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      config: { domain: 'example' }
    })
    model.changeAdapter({
      adapterID: 'slack',
      name: 'slack-main',
      groupMessageMode: 'observe_all',
      config: { workspace: 'main' }
    })

    expect(model.adapterID.value).toBe('slack')
    expect(model.name.value).toBe('slack-main')
    expect(model.groupMessageMode.value).toBe('observe_all')
    expect(model.config.value).toEqual({ workspace: 'main' })
    model[Symbol.dispose]()
  })
})

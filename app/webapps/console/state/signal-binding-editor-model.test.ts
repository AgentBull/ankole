import { describe, expect, test } from 'bun:test'
import {
  defaultSignalBindingAgentUID,
  groupMessageModeFromPolicy,
  SignalBindingEditorModel
} from './signal-binding-editor-model'

describe('SignalBindingEditorModel', () => {
  test('uses a valid query agent and otherwise falls back to the first active agent', () => {
    const agents = [{ uid: 'agent-a' }, { uid: 'agent-b' }]

    expect(defaultSignalBindingAgentUID(agents, 'agent-b')).toBe('agent-b')
    expect(defaultSignalBindingAgentUID(agents, 'missing-agent')).toBe('agent-a')
    expect(defaultSignalBindingAgentUID([], 'missing-agent')).toBe('')
  })

  test('restores the editor mode from the stored routing policy', () => {
    expect(groupMessageModeFromPolicy('ignore')).toBe('addressed_only')
    expect(groupMessageModeFromPolicy('record_only')).toBe('observe_all')
    expect(groupMessageModeFromPolicy('may_intervene')).toBe('may_intervene')
  })

  test('the route agent is only the initial target default', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      confidentialMemory: false,
      config: { domain: 'example' }
    })
    expect(model.dirty.value).toBe(false)
    model.selectAgent('agent-b')
    expect(model.dirty.value).toBe(true)
    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      confidentialMemory: false,
      config: { domain: 'example' }
    })

    expect(model.agentUID.value).toBe('agent-b')
    model[Symbol.dispose]()
  })

  test('adapter changes replace adapter-owned defaults without changing the selected agent', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      confidentialMemory: true,
      config: { domain: 'example' }
    })
    model.changeAdapter({
      adapterID: 'slack',
      name: 'slack-main',
      groupMessageMode: 'observe_all',
      confidentialMemory: false,
      config: { workspace: 'main' }
    })

    expect(model.agentUID.value).toBe('agent-a')
    expect(model.adapterID.value).toBe('slack')
    expect(model.name.value).toBe('slack-main')
    expect(model.groupMessageMode.value).toBe('observe_all')
    expect(model.confidentialMemory.value).toBe(false)
    expect(model.config.value).toEqual({ workspace: 'main' })
    expect(model.configPatch.value).toEqual({})
    model[Symbol.dispose]()
  })

  test('tracks only changed config paths for an existing binding update', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('binding:agent-a:lark:lark-main', {
      agentUID: 'agent-a',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'observe_all',
      confidentialMemory: false,
      config: { appID: '', appSecret: '', domain: 'feishu' }
    })

    model.changeConfig('domain', 'lark')
    model.changeConfig('delivery.userName', 'Research Bot')

    expect(model.config.value).toEqual({
      appID: '',
      appSecret: '',
      domain: 'lark',
      delivery: { userName: 'Research Bot' }
    })
    expect(model.configPatch.value).toEqual({
      domain: 'lark',
      delivery: { userName: 'Research Bot' }
    })
    model[Symbol.dispose]()
  })
})

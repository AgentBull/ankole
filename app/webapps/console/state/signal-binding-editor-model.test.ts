import { describe, expect, test } from 'bun:test'
import type { SignalAdapterItem } from '../api/runtime-types'
import {
  groupMessageModeFromPolicy,
  groupSignalAdapters,
  SignalBindingEditorModel
} from './signal-binding-editor-model'

describe('groupSignalAdapters', () => {
  test('renders non-empty groups in the fixed order without changing adapter IDs', () => {
    const adapters = [
      adapter('dingtalk', 'enterprise_im'),
      adapter('email', 'email'),
      adapter('lark', 'enterprise_im'),
      adapter('telegram', 'consumer_im')
    ]

    expect(
      groupSignalAdapters(adapters).map(group => ({
        category: group.category,
        labelKey: group.labelKey,
        adapterIDs: group.adapters.map(item => item.adapter_id)
      }))
    ).toEqual([
      {
        category: 'enterprise_im',
        labelKey: 'console.signals.adapter_group_enterprise_im',
        adapterIDs: ['dingtalk', 'lark']
      },
      {
        category: 'consumer_im',
        labelKey: 'console.signals.adapter_group_consumer_im',
        adapterIDs: ['telegram']
      },
      {
        category: 'email',
        labelKey: 'console.signals.adapter_group_email',
        adapterIDs: ['email']
      }
    ])
  })

  test('hides an empty group and preserves catalog order inside the remaining group', () => {
    const groups = groupSignalAdapters([adapter('slack', 'enterprise_im'), adapter('lark', 'enterprise_im')])

    expect(groups).toHaveLength(1)
    expect(groups[0]?.category).toBe('enterprise_im')
    expect(groups[0]?.adapters.map(item => item.adapter_id)).toEqual(['slack', 'lark'])
  })
})

function adapter(adapterID: string, adapterCategory: SignalAdapterItem['adapter_category']): SignalAdapterItem {
  const enumField = {
    path: 'mode',
    type: 'enum',
    options: []
  }

  return {
    adapter_category: adapterCategory,
    adapter_id: adapterID,
    fields: [],
    group_message_mode_field: enumField,
    unmatched_sender_policy_field: enumField
  }
}

describe('SignalBindingEditorModel', () => {
  test('restores the editor mode from the stored routing policy', () => {
    expect(groupMessageModeFromPolicy('ignore')).toBe('addressed_only')
    expect(groupMessageModeFromPolicy('record_only')).toBe('observe_all')
    expect(groupMessageModeFromPolicy('may_intervene')).toBe('may_intervene')
  })

  test('the route agent is only the initial target default', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      unmatchedSenderPolicy: 'manual_review',
      config: { domain: 'example' }
    })
    expect(model.dirty.value).toBe(false)
    model.selectAgent('agent-b')
    expect(model.dirty.value).toBe(true)
    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      unmatchedSenderPolicy: 'manual_review',
      config: { domain: 'example' }
    })

    expect(model.agentUID.value).toBe('agent-b')
    model[Symbol.dispose]()
  })

  test('adapter changes replace adapter-owned defaults without changing the selected agent', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('new:agent-a', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'addressed_only',
      unmatchedSenderPolicy: 'manual_review',
      config: { domain: 'example' }
    })
    model.changeAdapter({
      routingMode: 'ai_colleague',
      adapterID: 'slack',
      name: 'slack-main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'create_standalone',
      config: { workspace: 'main' }
    })

    expect(model.agentUID.value).toBe('agent-a')
    expect(model.adapterID.value).toBe('slack')
    expect(model.name.value).toBe('slack-main')
    expect(model.groupMessageMode.value).toBe('observe_all')
    expect(model.unmatchedSenderPolicy.value).toBe('create_standalone')
    expect(model.config.value).toEqual({ workspace: 'main' })
    expect(model.configPatch.value).toEqual({})
    model[Symbol.dispose]()
  })

  test('tracks only changed config paths for an existing binding update', () => {
    const model = new SignalBindingEditorModel()

    model.initialize('binding:agent-a:lark:lark-main', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'lark-main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'manual_review',
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

  test('switching connections submits the selected ID and drops discarded manual credential edits', () => {
    const model = new SignalBindingEditorModel()
    model.initialize('binding:agent-a:lark:main', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'manual_review',
      config: { authConfigId: 'connection-a', appID: 'app-a', appSecret: '', domain: 'feishu' }
    })
    expect(model.connectionChanged.value).toBe(false)
    model.changeConfig('appSecret', 'discarded-secret')
    model.changeConfig('delivery.userName', 'Research Bot')
    model.changeConnection({
      authConfigId: 'connection-b',
      delivery: { userName: 'Research Bot' }
    })

    expect(model.config.value).toEqual({ authConfigId: 'connection-b', delivery: { userName: 'Research Bot' } })
    expect(model.configPatch.value).toEqual({ authConfigId: 'connection-b', delivery: { userName: 'Research Bot' } })
    expect(model.connectionChanged.value).toBe(true)
    expect(model.dirty.value).toBe(true)

    model.changeConnection({ authConfigId: 'connection-a', delivery: { userName: 'Research Bot' } })
    expect(model.connectionChanged.value).toBe(false)
    expect(model.configPatch.value.authConfigId).toBe('connection-a')
    model[Symbol.dispose]()
  })

  test('switching to manual credentials explicitly clears the stored connection in the patch', () => {
    const model = new SignalBindingEditorModel()
    model.initialize('binding:agent-a:lark:main', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'manual_review',
      config: { authConfigId: 'connection-a', appSecret: '' }
    })
    model.changeConnection({ appID: '', appSecret: '' })
    expect(model.configPatch.value).toEqual({ authConfigId: null })
    expect(model.connectionChanged.value).toBe(true)
    model.changeConfig('appID', 'manual-app')
    model.changeConfig('appSecret', 'manual-secret')
    expect(model.configPatch.value).toEqual({ authConfigId: null, appID: 'manual-app', appSecret: 'manual-secret' })
    model[Symbol.dispose]()
  })

  test('connection defaults replace the pending values of fields that stay in the form', () => {
    const model = new SignalBindingEditorModel()
    model.initialize('binding:agent-a:lark:main', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'manual_review',
      config: { authConfigId: 'connection-a', identityProvider: '', appSecret: '' }
    })
    model.changeConfig('identityProvider', 'provider-x')
    model.changeConnection({ authConfigId: null, identityProvider: '', appSecret: '' })
    expect(model.configPatch.value).toEqual({ authConfigId: null, identityProvider: '' })
    expect(model.config.value.identityProvider).toBe('')
    model[Symbol.dispose]()
  })

  test('switching connections clears validation errors and keeps narrow nested patches intact', () => {
    const model = new SignalBindingEditorModel()
    model.initialize('binding:agent-a:lark:main', {
      agentUID: 'agent-a',
      routingMode: 'ai_colleague',
      adapterID: 'lark',
      name: 'main',
      groupMessageMode: 'observe_all',
      unmatchedSenderPolicy: 'manual_review',
      config: { authConfigId: 'connection-a', delivery: { userName: 'Old', avatar: 'keep' } }
    })
    model.validationError.value = 'Target agent required'
    model.changeConfig('delivery.userName', 'Research Bot')
    model.changeConnection({ authConfigId: 'connection-b', delivery: { userName: 'Research Bot', avatar: 'keep' } })
    expect(model.validationError.value).toBeUndefined()
    expect(model.configPatch.value).toEqual({ authConfigId: 'connection-b', delivery: { userName: 'Research Bot' } })
    model[Symbol.dispose]()
  })
})

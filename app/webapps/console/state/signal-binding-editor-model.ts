import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import { setPath } from '../../common/config-fields'
import type { SignalAdapterItem, SignalBindingItem, SignalBindingWriteRequest } from '../api/generated/types.gen'

export type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

export type UnmatchedSenderPolicy = NonNullable<SignalBindingWriteRequest['unmatched_sender_policy']>

export type SignalBindingEditorDraft = {
  agentUID: string
  adapterID: string
  name: string
  groupMessageMode: GroupMessageMode | ''
  unmatchedSenderPolicy: UnmatchedSenderPolicy | ''
  config: JSONObject
}

export type SignalBindingAdapterDraft = Omit<SignalBindingEditorDraft, 'agentUID'>

export function groupMessageModeFromPolicy(
  policy: SignalBindingItem['unaddressed_group_message_policy']
): GroupMessageMode {
  if (policy === 'ignore') return 'addressed_only'
  if (policy === 'record_only') return 'observe_all'
  return 'may_intervene'
}

const SIGNAL_ADAPTER_GROUPS = [
  {
    category: 'enterprise_im',
    labelKey: 'console.signals.adapter_group_enterprise_im'
  },
  {
    category: 'consumer_im',
    labelKey: 'console.signals.adapter_group_consumer_im'
  }
] as const

export function groupSignalAdapters(signalAdapters: readonly SignalAdapterItem[]) {
  return SIGNAL_ADAPTER_GROUPS.map(group => ({
    ...group,
    adapters: signalAdapters.filter(adapter => adapter.adapter_category === group.category)
  })).filter(group => group.adapters.length > 0)
}

export const SignalBindingEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const agentUID = signal('')
  const adapterID = signal('')
  const name = signal('')
  const groupMessageMode = signal<GroupMessageMode | ''>('')
  const unmatchedSenderPolicy = signal<UnmatchedSenderPolicy | ''>('')
  const config = signal<JSONObject>({})
  const configPatch = signal<JSONObject>({})
  const initialDraft = signal<SignalBindingEditorDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (agentUID.value !== source.agentUID ||
        adapterID.value !== source.adapterID ||
        name.value !== source.name ||
        groupMessageMode.value !== source.groupMessageMode ||
        unmatchedSenderPolicy.value !== source.unmatchedSenderPolicy ||
        JSON.stringify(config.value) !== JSON.stringify(source.config))
    )
  })

  const apply = (draft: SignalBindingEditorDraft) => {
    batch(() => {
      agentUID.value = draft.agentUID
      adapterID.value = draft.adapterID
      name.value = draft.name
      groupMessageMode.value = draft.groupMessageMode
      unmatchedSenderPolicy.value = draft.unmatchedSenderPolicy
      config.value = draft.config
      configPatch.value = {}
      initialDraft.value = { ...draft, config: { ...draft.config } }
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    agentUID,
    adapterID,
    name,
    groupMessageMode,
    unmatchedSenderPolicy,
    config,
    configPatch,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: SignalBindingEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    selectAgent(nextAgentUID: string) {
      agentUID.value = nextAgentUID
      validationError.value = undefined
    },
    changeAdapter(draft: SignalBindingAdapterDraft) {
      apply({ ...draft, agentUID: agentUID.value })
    },
    changeConfig(path: string, value: unknown) {
      config.value = setPath(config.value, path, value)
      configPatch.value = setPath(configPatch.value, path, value)
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})

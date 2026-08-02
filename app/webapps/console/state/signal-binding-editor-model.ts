import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, createModel, signal } from '@preact/signals-react'
import { setPath } from '../../common/config-fields'
import type { SignalBindingWriteRequest } from '../api/generated/types.gen'

export type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

export type SignalBindingEditorDraft = {
  agentUID: string
  adapterID: string
  name: string
  groupMessageMode: GroupMessageMode | ''
  confidentialMemory: boolean
  config: JSONObject
}

export type SignalBindingAdapterDraft = Omit<SignalBindingEditorDraft, 'agentUID'>

export function defaultSignalBindingAgentUID(agents: readonly { uid: string }[], queryAgentUID: string): string {
  return agents.some(agent => agent.uid === queryAgentUID) ? queryAgentUID : (agents[0]?.uid ?? '')
}

export const SignalBindingEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const agentUID = signal('')
  const adapterID = signal('')
  const name = signal('')
  const groupMessageMode = signal<GroupMessageMode | ''>('')
  const confidentialMemory = signal(false)
  const config = signal<JSONObject>({})
  const configPatch = signal<JSONObject>({})
  const validationError = signal<string>()

  const apply = (draft: SignalBindingEditorDraft) => {
    batch(() => {
      agentUID.value = draft.agentUID
      adapterID.value = draft.adapterID
      name.value = draft.name
      groupMessageMode.value = draft.groupMessageMode
      confidentialMemory.value = draft.confidentialMemory
      config.value = draft.config
      configPatch.value = {}
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    agentUID,
    adapterID,
    name,
    groupMessageMode,
    confidentialMemory,
    config,
    configPatch,
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

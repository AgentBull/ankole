import { useEffect } from 'react'

export type EditorDraftStatus = 'loading' | 'absent' | 'ready'

export type EditorDraftIdentity =
  | { resource: 'agent'; uid?: string }
  | { resource: 'ai-provider'; providerID?: string }
  | { resource: 'identity-provider'; providerID?: string }
  | { resource: 'principal'; uid?: string }
  | { resource: 'principal-group'; name?: string }
  | { resource: 'permission-grant'; id?: string }
  | { resource: 'worker-env'; name?: string }
  | { resource: 'schedule'; id?: string }
  | { resource: 'setting'; key: string }
  | { resource: 'signal-binding'; agentUID: string; adapterID?: string; name?: string }
  | { resource: 'brain-object'; slug?: string }
  | { resource: 'agent-library'; agentUID: string }
  | { resource: 'model-profiles'; agentUID: string }
  | { resource: 'custom-model-profile'; agentUID: string; name: string }

export type EditorDraftModel<Source> = {
  sourceKey: { value: string | undefined }
  initialize: (sourceKey: string, source: Source) => void
}

type ResolvedEditorDraftIdentity = {
  sourceKey: string
  initializeKey: string
}

export function resolveEditorDraftIdentity(identity: EditorDraftIdentity): ResolvedEditorDraftIdentity {
  switch (identity.resource) {
    case 'agent':
      return sameKey(identity.uid ? `agent:${identity.uid}` : 'new')
    case 'ai-provider':
    case 'identity-provider':
      return sameKey(identity.providerID ? `provider:${identity.providerID}` : 'new')
    case 'principal':
      return sameKey(identity.uid ? `principal:${identity.uid}` : 'new')
    case 'principal-group':
      return sameKey(identity.name ? `group:${identity.name}` : 'new')
    case 'permission-grant':
      return sameKey(identity.id ? `grant:${identity.id}` : 'new')
    case 'worker-env':
      return sameKey(`worker-env:${identity.name ?? 'new'}`)
    case 'schedule':
      return sameKey(`cron:${identity.id ?? 'new'}`)
    case 'setting':
      return sameKey(`setting:${identity.key}`)
    case 'signal-binding':
      return sameKey(`binding:${identity.agentUID}:${identity.adapterID ?? ''}:${identity.name ?? 'new'}`)
    case 'brain-object':
      return sameKey(identity.slug ? `object:${identity.slug}` : 'new')
    case 'agent-library':
      return { sourceKey: `agent:${identity.agentUID}`, initializeKey: identity.agentUID }
    case 'model-profiles':
      return sameKey(`agent:${identity.agentUID}`)
    case 'custom-model-profile':
      return sameKey(`agent:${identity.agentUID}:${identity.name}`)
  }
}

/** Seed a draft only when the selected resource identity changes. */
export function seedEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  identity: EditorDraftIdentity,
  source: Source | undefined,
  absent = false
): void {
  seedResolvedEditorDraft(model, resolveEditorDraftIdentity(identity), source, absent)
}

export function useEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  {
    identity,
    source,
    absent
  }: {
    identity: EditorDraftIdentity
    source: Source | undefined
    absent?: () => boolean
  }
): EditorDraftStatus {
  const { sourceKey, initializeKey } = resolveEditorDraftIdentity(identity)
  const isAbsent = absent?.() ?? false

  useEffect(() => {
    seedResolvedEditorDraft(model, { sourceKey, initializeKey }, source, isAbsent)
  }, [initializeKey, isAbsent, model, source, sourceKey])

  if (isAbsent) return 'absent'
  if (source === undefined || model.sourceKey.value !== sourceKey) return 'loading'
  return 'ready'
}

function sameKey(sourceKey: string): ResolvedEditorDraftIdentity {
  return { sourceKey, initializeKey: sourceKey }
}

function seedResolvedEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  identity: ResolvedEditorDraftIdentity,
  source: Source | undefined,
  absent: boolean
): void {
  if (absent || source === undefined || model.sourceKey.value === identity.sourceKey) return
  model.initialize(identity.initializeKey, source)
}

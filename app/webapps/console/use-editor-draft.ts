import { useLayoutEffect } from 'react'

export type EditorDraftStatus = 'loading' | 'absent' | 'ready'

export type EditorDraftIdentity =
  | { resource: 'agent'; uid?: string }
  | { resource: 'tenant'; tenantID?: string }
  | { resource: 'oidc-client'; clientID?: string }
  | { resource: 'ai-provider'; providerID?: string }
  | { resource: 'worker-provider'; providerID?: string }
  | { resource: 'identity-provider'; providerID?: string }
  | { resource: 'principal'; uid?: string }
  | { resource: 'principal-group'; name?: string }
  | { resource: 'permission-grant'; id?: string }
  | { resource: 'worker-env'; name?: string; scope: 'global' | 'tenant' }
  | { resource: 'schedule'; id?: string }
  | { resource: 'setting'; key: string; scope: 'global' | 'tenant' }
  | { resource: 'setting-group'; group: string; scope: 'global' | 'tenant' }
  | { resource: 'signal-binding'; agentUID: string; adapterID?: string; name?: string }
  | { resource: 'brain-object'; slug?: string }
  | { resource: 'agent-library'; agentUID: string }
  | { resource: 'model-profiles'; agentUID: string }
  | { resource: 'custom-model-profile'; agentUID: string; name: string }
  | { resource: 'token-quota'; agentUID: string }

export type EditorDraftModel<Source> = {
  sourceKey: { value: string | undefined }
  initialize: (sourceKey: string, source: Source) => void
  resetSource?: () => void
}

type ResolvedEditorDraftIdentity = {
  sourceKey: string
  initializeKey: string
}

export function resolveEditorDraftIdentity(identity: EditorDraftIdentity): ResolvedEditorDraftIdentity {
  switch (identity.resource) {
    case 'tenant':
      return sameKey(identity.tenantID ? `tenant:${identity.tenantID}` : 'new')
    case 'oidc-client':
      return sameKey(identity.clientID ? `client:${identity.clientID}` : 'new')
    case 'agent':
      return sameKey(identity.uid ? `agent:${identity.uid}` : 'new')
    case 'ai-provider':
    case 'worker-provider':
    case 'identity-provider':
      return sameKey(identity.providerID ? `provider:${identity.providerID}` : 'new')
    case 'principal':
      return sameKey(identity.uid ? `principal:${identity.uid}` : 'new')
    case 'principal-group':
      return sameKey(identity.name ? `group:${identity.name}` : 'new')
    case 'permission-grant':
      return sameKey(identity.id ? `grant:${identity.id}` : 'new')
    case 'worker-env':
      return sameKey(`worker-env:${identity.scope}:${identity.name ?? 'new'}`)
    case 'schedule':
      return sameKey(`cron:${identity.id ?? 'new'}`)
    case 'setting':
      return sameKey(`setting:${identity.scope}:${identity.key}`)
    case 'setting-group':
      return sameKey(`setting-group:${identity.scope}:${identity.group}`)
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
    case 'token-quota':
      return sameKey(`agent:${identity.agentUID}`)
  }
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

  useLayoutEffect(() => () => model.resetSource?.(), [model])

  useLayoutEffect(() => {
    seedEditorDraft(model, { sourceKey, initializeKey }, source, isAbsent)
  }, [initializeKey, isAbsent, model, source, sourceKey])

  if (isAbsent) return 'absent'
  if (source === undefined || model.sourceKey.value !== sourceKey) return 'loading'
  return 'ready'
}

function sameKey(sourceKey: string): ResolvedEditorDraftIdentity {
  return { sourceKey, initializeKey: sourceKey }
}

export function seedEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  identity: ResolvedEditorDraftIdentity,
  source: Source | undefined,
  absent: boolean
): void {
  // Selection changes revoke old request captures before the next source loads.
  if (model.sourceKey.value !== undefined && (absent || model.sourceKey.value !== identity.sourceKey)) {
    model.resetSource?.()
  }
  if (absent || source === undefined || model.sourceKey.value === identity.sourceKey) return
  model.initialize(identity.initializeKey, source)
}

import { createModel, signal } from '@preact/signals-react'
import type { PodConnectorAuthConfigsListResponse } from '../api/generated/types.gen'

export function connectorCredentialFields(fields: Record<string, unknown>[], scheme: string, editing: boolean) {
  const sharedRoot = editing && ['platform_app', 'identity_app'].includes(scheme)
  return [
    ...new Map(
      fields
        .filter(field => sharedRoot || !Array.isArray(field.schemes) || field.schemes.includes(scheme))
        .map(field => [String(field.key), field])
    ).values()
  ]
}

export function connectorReturnTo(
  connection: string,
  scopes?: string[],
  trigger?: { type: string; scope: string; id?: string }
) {
  const params = new URLSearchParams({ connection })
  if (scopes?.length) params.set('scopes', scopes.join(' '))
  if (trigger) {
    params.set('trigger_type', trigger.type)
    params.set('scope_key', trigger.scope)
    if (trigger.id) params.set('trigger_id', trigger.id)
  }
  return `/connectors?${params}`
}

type Connection = PodConnectorAuthConfigsListResponse['connections'][number]
export const ConnectorsModel = createModel(() => {
  const editing = signal<Connection | null | undefined>()
  const plugin = signal('lark')
  const scheme = signal('lark_app')
  const slug = signal('')
  const name = signal('')
  const isDefault = signal(false)
  const secret = signal<Record<string, unknown>>({})
  const metadata = signal<Record<string, unknown>>({})
  const triggerConnection = signal<Connection>()
  const triggerType = signal('')
  const triggerScope = signal('')
  const triggerAccount = signal('')
  return {
    editing,
    plugin,
    scheme,
    slug,
    name,
    isDefault,
    secret,
    metadata,
    triggerConnection,
    triggerType,
    triggerScope,
    triggerAccount,
    openTrigger({ connection, type = '', scope = '' }: { connection: Connection; type?: string; scope?: string }) {
      triggerConnection.value = connection
      triggerType.value = type
      triggerScope.value = scope
      triggerAccount.value = ''
    },
    edit(connection: Connection | null) {
      editing.value = connection
      plugin.value = connection?.plugin_id ?? 'lark'
      scheme.value = connection?.auth_scheme ?? 'lark_app'
      slug.value = connection?.slug ?? ''
      name.value = connection?.display_name ?? ''
      isDefault.value = connection?.is_default ?? false
      secret.value = {}
      metadata.value = { ...connection?.public_metadata }
    }
  }
})

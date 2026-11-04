import { createModel, signal } from '@preact/signals-react'
import type { PodConnectorAuthConfigsListResponse } from '../api/generated/types.gen'
import { podPagePath, podRouteID } from '../../common/pod-url'
import i18n from '../../common/i18n'

export function connectorFailureMessage(error: Record<string, unknown>) {
  if (typeof error.message === 'string' && error.message) return error.message
  if (['oauth_consent_required', 'oauth_reauthorization_required', 'invalid_grant'].includes(String(error.code))) {
    return i18n.t('pod.connectors.status.reauth_required')
  }
  return String(error.code ?? '')
}

export type ConnectorAutomationContext = { pageID: string; jobID: number }

export function automationJobID(params: URLSearchParams) {
  const id = Number(params.get('automation_job'))
  return Number.isSafeInteger(id) && id > 0 ? id : undefined
}

export function connectorAutomationContext(params: URLSearchParams): ConnectorAutomationContext | undefined {
  const pageID = podRouteID(params.get('automation_page') ?? undefined)
  const jobID = automationJobID(params)
  return pageID && jobID ? { pageID, jobID } : undefined
}

export function connectorAutomationReturnTo(context: ConnectorAutomationContext, source?: string) {
  const params = new URLSearchParams({ automation_job: String(context.jobID) })
  if (source) params.set('connector_source', source)
  return `${podPagePath(context.pageID)}?${params}`
}

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

export function connectorReturnTo({
  connection,
  scopes,
  trigger,
  automation,
  subjectKind
}: {
  connection?: string
  scopes?: string[]
  trigger?: { type: string; scope: string; id?: string }
  automation?: ConnectorAutomationContext
  subjectKind?: 'human' | 'app'
}) {
  const params = new URLSearchParams()
  if (connection) params.set('connection', connection)
  if (subjectKind) params.set('subject_kind', subjectKind)
  if (scopes?.length) params.set('scopes', scopes.join(' '))
  if (trigger) {
    params.set('trigger_type', trigger.type)
    params.set('scope_key', trigger.scope)
    if (trigger.id) params.set('trigger_id', trigger.id)
  }
  if (automation) {
    params.set('automation_page', automation.pageID)
    params.set('automation_job', String(automation.jobID))
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

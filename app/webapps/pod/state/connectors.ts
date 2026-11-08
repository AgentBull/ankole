import { createModel, signal } from '@preact/signals-react'
import { isRecord, recordValue, safeJsonParse } from '@agentbull/active-support'
import type { PodConnectorAuthConfigsListResponse, PodConnectorsCatalogResponse } from '../api/generated/types.gen'
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
  subjectKind,
  intent
}: {
  connection?: string
  scopes?: string[]
  trigger?: { type: string; scope: string; id?: string; config?: Record<string, unknown> }
  automation?: ConnectorAutomationContext
  subjectKind?: 'human' | 'app'
  intent?: string | null
}) {
  const params = new URLSearchParams()
  if (connection) params.set('connection', connection)
  if (intent) params.set('intent', intent)
  if (subjectKind) params.set('subject_kind', subjectKind)
  if (scopes?.length) params.set('scopes', scopes.join(' '))
  if (trigger) {
    params.set('trigger_type', trigger.type)
    params.set('scope_key', trigger.scope)
    if (trigger.id) params.set('trigger_id', trigger.id)
    if (trigger.config && Object.keys(trigger.config).length) {
      params.set('trigger_config', JSON.stringify(trigger.config))
    }
  }
  if (automation) {
    params.set('automation_page', automation.pageID)
    params.set('automation_job', String(automation.jobID))
  }
  return `/connectors?${params}`
}

export function connectorTriggerConfigFromURL(params: URLSearchParams): Record<string, unknown> {
  const config = safeJsonParse(params.get('trigger_config') ?? '{}').unwrapOr(undefined)
  return isRecord(config) ? config : {}
}

export type ConnectorConnection = PodConnectorAuthConfigsListResponse['connections'][number]
export type ConnectorDefinition = NonNullable<PodConnectorsCatalogResponse['connectors']>[number]
type Connection = ConnectorConnection
export const ConnectorsModel = createModel(() => {
  const editing = signal<Connection | null | undefined>()
  const triggerConnection = signal<Connection>()
  const triggerType = signal('')
  const triggerScope = signal('')
  const triggerConfig = signal<Record<string, unknown>>({})
  const triggerAccount = signal('')
  const triggerSubject = signal<'human' | 'app'>('human')
  const credentialConnection = signal<Connection>()
  const credentialSubject = signal<'human' | 'app'>('human')
  const credentialsBound = signal(false)
  return {
    editing,
    triggerConnection,
    triggerType,
    triggerScope,
    triggerConfig,
    triggerAccount,
    triggerSubject,
    credentialConnection,
    credentialSubject,
    credentialsBound,
    bindCredentials(connection: Connection, subject: 'human' | 'app') {
      credentialConnection.value = connection
      credentialSubject.value = subject
      credentialsBound.value = false
    },
    openTrigger({
      connection,
      type = '',
      scope = '',
      config = {},
      subject = 'human'
    }: {
      connection: Connection
      type?: string
      scope?: string
      config?: Record<string, unknown>
      subject?: 'human' | 'app'
    }) {
      triggerSubject.value = subject
      triggerConnection.value = connection
      triggerType.value = type
      triggerScope.value = scope
      triggerConfig.value = config
      triggerAccount.value = ''
    },
    triggerAttributes(defaults: Record<string, unknown>, accountID?: string, fixedScopeKey?: string) {
      return {
        auth_config_id: triggerConnection.value!.id ?? undefined,
        connection: triggerConnection.value!.slug,
        trigger_type: triggerType.value,
        scope_key: fixedScopeKey ?? triggerScope.value,
        connected_account_id: accountID,
        config: { ...defaults, ...triggerConfig.value }
      }
    },
    edit(connection: Connection | null) {
      editing.value = connection
    }
  }
})

/** Plugins whose connections carry a connection-level `query` permission. */
export const DATABASE_CONNECTORS = ['postgresql', 'mysql', 'clickhouse']

export type ConnectionAccess = { mode: 'members' | 'restricted'; group_ids: string[]; principal_uids: string[] }

export function connectionAccess(value: unknown): ConnectionAccess {
  const access = recordValue(value)
  const ids = (key: string) => (Array.isArray(access?.[key]) ? (access[key] as unknown[]).map(String) : [])
  return {
    mode: access?.mode === 'restricted' ? 'restricted' : 'members',
    group_ids: ids('group_ids'),
    principal_uids: ids('principal_uids')
  }
}

export const ConnectionEditorModel = createModel((connection: Connection | null) => ({
  access: signal(connectionAccess(connection?.access)),
  editing: signal(connection),
  plugin: signal(connection?.plugin_id ?? 'lark'),
  scheme: signal(connection?.auth_scheme ?? 'lark_app'),
  slug: signal(connection?.slug ?? ''),
  name: signal(connection?.display_name ?? ''),
  isDefault: signal(connection?.is_default ?? false),
  secret: signal<Record<string, unknown>>({}),
  metadata: signal<Record<string, unknown>>({ ...connection?.public_metadata })
}))

export const CredentialBindingModel = createModel(() => ({
  credentials: signal<Record<string, unknown>>({})
}))

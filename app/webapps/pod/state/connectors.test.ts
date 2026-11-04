import { expect, test } from 'bun:test'
import { localReturnPath, podRouteID } from '../../common/pod-url'
import i18n, { loadLocale } from '../../common/i18n'
import {
  automationJobID,
  connectorAutomationContext,
  connectorAutomationReturnTo,
  connectorFailureMessage,
  connectorReturnTo,
  connectorTriggerConfigFromURL,
  ConnectorsModel
} from './connectors'

test('subscription diagnostics keep the upstream reason and localize missing authorization', async () => {
  const previousLocale = i18n.language
  try {
    await loadLocale('zh-Hans-CN')
    await i18n.changeLanguage('zh-Hans-CN')
    expect(connectorFailureMessage({ code: 'upstream_rejected', message: 'Calendar access was revoked.' })).toBe(
      'Calendar access was revoked.'
    )
    expect(connectorFailureMessage({ code: 'oauth_consent_required' })).toBe('需要重新授权')
  } finally {
    await i18n.changeLanguage(previousLocale)
  }
})

test('subscription authorization keeps the original Page and Job through the return route', () => {
  const context = { pageID: '0193b494-3210-7000-8000-000000000001', jobID: 42 }
  const url = new URL(
    connectorReturnTo({
      connection: 'work',
      scopes: ['calendar:read'],
      trigger: { type: 'lark_calendar', scope: 'team/weekly', id: 'subscription-1' },
      automation: context
    }),
    'https://ankole.test'
  )
  expect(connectorAutomationContext(url.searchParams)).toEqual(context)
  expect(url.searchParams.get('trigger_id')).toBe('subscription-1')
  expect(url.searchParams.get('scope_key')).toBe('team/weekly')
  expect(url.searchParams.get('scopes')).toBe('calendar:read')

  const returned = new URL(connectorAutomationReturnTo(context, 'connector://work/calendar'), url)
  expect(podRouteID(returned.pathname.split('/').at(-1))).toBe(context.pageID)
  expect(automationJobID(returned.searchParams)).toBe(context.jobID)
  expect(returned.searchParams.get('connector_source')).toBe('connector://work/calendar')
})

test('connection setup carries the Job without choosing a connection or source', () => {
  const context = { pageID: '0193b494-3210-7000-8000-000000000001', jobID: 42 }
  const params = new URL(connectorReturnTo({ automation: context }), 'https://ankole.test').searchParams
  expect(connectorAutomationContext(params)).toEqual(context)
  expect(params.has('connection')).toBe(false)
  expect(
    new URL(connectorAutomationReturnTo(context), 'https://ankole.test').searchParams.has('connector_source')
  ).toBe(false)
})

test('application authorization preserves its subject and scopes on return', () => {
  const params = new URL(
    connectorReturnTo({ connection: 'work', scopes: ['read', 'write'], subjectKind: 'app' }),
    'https://ankole.test'
  ).searchParams
  expect(params.get('subject_kind')).toBe('app')
  expect(params.get('scopes')).toBe('read write')
})

test('invalid return contexts do not become another Job or an external return URL', () => {
  for (const value of ['', '0', '-1', '1.5', 'NaN', '9007199254740992']) {
    expect(automationJobID(new URLSearchParams({ automation_job: value }))).toBeUndefined()
  }
  expect(
    connectorAutomationContext(new URLSearchParams({ automation_page: 'https://elsewhere.test', automation_job: '42' }))
  ).toBeUndefined()
})

test('authorization preserves the original task intent', () => {
  const origin = 'https://ankole.test'
  for (const path of [
    '/conversations/0024h36h2ncsvrh6daqf6dvvqz',
    '/pages/0024h36h2ncsvrh6daqf6dvvqz?automation_job=42',
    '/conversations/abc?thread=1'
  ]) {
    const params = new URL(connectorReturnTo({ connection: 'figma', intent: path }), origin).searchParams
    expect(params.get('intent')).toBe(path)
    expect(localReturnPath(params.get('intent'), origin)).toBe(path)
  }
})

const hostedConnection = {
  id: null,
  plugin_id: 'calendly',
  mode: 'cloud',
  slug: 'calendly',
  display_name: 'Calendly',
  auth_scheme: 'oauth2',
  status: 'active',
  is_default: false,
  public_metadata: {},
  configured_credential_fields: [],
  inserted_at: null,
  updated_at: null
}

test('personal subscription submission includes the platform default and chosen connected account', () => {
  const model = new ConnectorsModel()
  try {
    model.openTrigger({
      connection: hostedConnection,
      type: 'calendly.invitee.created',
      scope: 'https://api.calendly.com/organizations/org-1'
    })
    expect(model.triggerAttributes({ scope: 'user' }, 'my-account')).toEqual({
      auth_config_id: undefined,
      connection: 'calendly',
      trigger_type: 'calendly.invitee.created',
      scope_key: 'https://api.calendly.com/organizations/org-1',
      connected_account_id: 'my-account',
      config: { scope: 'user' }
    })
  } finally {
    model[Symbol.dispose]()
  }
})

test('authorization round trip preserves an explicit Figma context in the submitted subscription', () => {
  const model = new ConnectorsModel()
  const connection = { ...hostedConnection, plugin_id: 'figma', slug: 'figma', auth_scheme: 'personal_token' }
  const draft = { type: 'figma.file.updated', scope: 'project-42', config: { context: 'project' } }
  const params = new URL(
    connectorReturnTo({ connection: 'figma', subjectKind: 'human', trigger: draft, intent: 'watch-design' }),
    'https://ankole.test'
  ).searchParams
  try {
    model.openTrigger({
      connection,
      type: params.get('trigger_type')!,
      scope: params.get('scope_key')!,
      config: connectorTriggerConfigFromURL(params)
    })
    const submitted = model.triggerAttributes({ context: 'file' }, 'figma-personal')
    expect(submitted.config).toEqual({ context: 'project' })
    expect(submitted.scope_key).toBe('project-42')
    expect(submitted.connected_account_id).toBe('figma-personal')
    expect(params.get('intent')).toBe('watch-design')

    model.openTrigger({ connection, type: 'figma.file_comment.created', scope: 'file-42' })
    expect(model.triggerAttributes({ context: 'file' }, 'figma-personal').config).toEqual({ context: 'file' })
  } finally {
    model[Symbol.dispose]()
  }
})

test('an invalid trigger config URL leaves the platform defaults available', () => {
  for (const value of ['invalid-json', 'null', '[]']) {
    expect(connectorTriggerConfigFromURL(new URLSearchParams({ trigger_config: value }))).toEqual({})
  }
})

test('account-wide subscriptions submit the declared scope without asking for a resource', () => {
  const model = new ConnectorsModel()
  try {
    for (const plugin of ['stripe', 'zendesk']) {
      model.openTrigger({
        connection: { ...hostedConnection, plugin_id: plugin, slug: plugin, auth_scheme: 'api_token' },
        type: plugin === 'stripe' ? 'stripe.invoice.paid' : 'zendesk.ticket.created',
        subject: 'app'
      })
      expect(model.triggerScope.value).toBe('')
      const submitted = model.triggerAttributes({}, 'shared-account', 'account')
      expect(submitted.scope_key).toBe('account')
      expect(submitted.connected_account_id).toBe('shared-account')
    }
  } finally {
    model[Symbol.dispose]()
  }
})

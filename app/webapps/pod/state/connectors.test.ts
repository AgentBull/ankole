import { expect, test } from 'bun:test'
import { podRouteID } from '../../common/pod-url'
import i18n, { loadLocale } from '../../common/i18n'
import {
  automationJobID,
  connectorAutomationContext,
  connectorAutomationReturnTo,
  connectorFailureMessage,
  connectorReturnTo
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

import { describe, expect, test } from 'bun:test'
import type { AppConfigurationItem } from '../api/configuration-types'
import { settingFocus, settingMatches, settingsScope, settingsSearch } from './settings-search'
import { settingGroupID, settingOwnerRoute } from './setting-groups'
import { retentionLength, settingDurationParts } from './setting-value-editor'

const item = (key: string, value: unknown = null, encrypted = false) =>
  ({ key, value, encrypted }) as AppConfigurationItem

describe('settings navigation and search', () => {
  test('readable duration summaries preserve stored units and fractional seconds', () => {
    expect(settingDurationParts('ai_agent.inactivity_timeout_ms', 1800000)).toEqual({ amount: 30, unit: 'minutes' })
    expect(settingDurationParts('ai_agent.inactivity_timeout_ms', 125)).toEqual({ amount: 0.125, unit: 'seconds' })
    expect(settingDurationParts('brain.soft_delete_retention_hours', 72)).toEqual({ amount: 3, unit: 'days' })
    expect(settingDurationParts('ai_agent.max_output_tokens', null)).toBeUndefined()
  })

  test('zero trash retention compares as keeping pages longest', () => {
    expect(retentionLength('pod.trash_retention_days', 30) < retentionLength('pod.trash_retention_days', 0)).toBe(true)
    expect(retentionLength('pod.trash_retention_days', 7)).toBe(7)
    expect(retentionLength('brain.soft_delete_retention_hours', 0)).toBe(0)
    expect(settingDurationParts('pod.trash_retention_days', 0)).toEqual({ amount: 0, unit: 'days' })
    expect(settingDurationParts('ai_agent.inactivity_timeout_ms', 0)).toEqual({ amount: 0, unit: 'seconds' })
  })
  test('starts with tenant tasks and preserves an explicit site context', () => {
    expect(settingsScope(new URLSearchParams())).toBe('tenant')
    expect(settingsScope(new URLSearchParams('scope=global'))).toBe('global')
    expect(settingsScope(new URLSearchParams('scope=tenant'))).toBe('tenant')
    expect(
      settingsSearch(new URLSearchParams('scope=tenant&view=registry&q=otlp_endpoint'), {
        view: 'tasks',
        focus: 'observability.traces.otlp_endpoint'
      })
    ).toEqual({ scope: 'tenant', view: 'tasks', q: 'otlp_endpoint', focus: 'observability.traces.otlp_endpoint' })
  })
  test('finds hidden fields and migrated keys without searching secret values', () => {
    const retention = item('brain.soft_delete_retention_hours', 72)
    expect(settingMatches(retention, 'brain.forgetting.purge_soft_delete_ttl_hours')).toBe(true)
    expect(settingFocus([retention], 'purge_soft_delete_ttl_hours')).toBe(retention.key)
    expect(settingGroupID(retention.key)).toBe('brain')
    const mail = item('authn.email.mail', { password: 'private-value' }, true)
    expect(settingMatches(mail, 'password')).toBe(true)
    expect(settingMatches(mail, 'private-value')).toBe(false)
    expect(settingFocus([mail], 'password')).toBe('authn.email.mail.password')
    const embedding = item('brain.embedding_model')
    expect(settingFocus([embedding], 'dimensions')).toBe('brain.embedding_model.dimensions')
    expect(settingFocus([embedding], 'brain.embedding_model dimensions')).toBe('brain.embedding_model.dimensions')
    expect(settingFocus([embedding], 'brain.embedding_model.dimensions')).toBe('brain.embedding_model.dimensions')
    expect(settingMatches(item('agent_workers.ready_timeout_seconds'), 'agent_computer.worker.ready_timeout')).toBe(
      true
    )
    expect(settingMatches(item('authn.email.send_limits'), 'authn.email.send_email_limit')).toBe(true)
  })
  test('task prefixes have one owner and links name the relevant management tab', () => {
    expect(settingGroupID('authn.email.mail')).toBe('smtp')
    expect(settingGroupID('authn.email.send_limits')).toBe('otp')
    expect(settingOwnerRoute('ai_agent.library.skill_defaults')).toBe('/agent-library?scope=__global__&tab=skills')
    expect(settingOwnerRoute('saas.require_invitation_code')).toBe('/invitation-codes?focus=require-invitation-code')
  })
})

import type { AppConfigurationItem } from '../api/configuration-types'
import { BRAIN_CHUNKING_FIELDS, BRAIN_FORGETTING_FIELDS } from './brain-setting-editor'

export type SettingsScope = 'global' | 'tenant'
export function settingsScope(params: URLSearchParams): SettingsScope {
  return params.get('scope') === 'tenant' ? 'tenant' : 'global'
}

const FIELD_ALIASES: Record<string, string[]> = {
  'brain.soft_delete_retention_hours': ['purge_soft_delete_ttl_hours', 'brain.forgetting.purge_soft_delete_ttl_hours'],
  'authn.email.send_limits': [
    'authn.email.send_window_seconds',
    'authn.email.send_email_limit',
    'authn.email.send_source_limit',
    'authn.email.send_channel_limit'
  ],
  'authn.email.failure_limits': [
    'authn.email.failure_window_seconds',
    'authn.email.failure_email_limit',
    'authn.email.failure_source_limit'
  ],
  'agent_workers.ready_timeout_seconds': ['agent_computer.worker.ready_timeout'],
  'agent_workers.rendered_fetch_idle_ttl_ms': ['worker.rendered_fetch_idle_ttl_ms'],
  'background_agent_jobs.max_running_per_agent': ['agent_computer.background_agent_job.max_running_per_agent']
}

const TASK_FIELDS: Record<string, readonly string[]> = {
  'authn.email.mail': ['server', 'port', 'from', 'ssl', 'username', 'password', 'cacertfile'],
  'brain.chunking': BRAIN_CHUNKING_FIELDS,
  'brain.forgetting': BRAIN_FORGETTING_FIELDS,
  'brain.embedding_model': ['provider_id', 'model', 'dimensions', 'provider_options'],
  'brain.rerank_model': ['provider_id', 'model', 'provider_options']
}

function settingFields(item: AppConfigurationItem) {
  return (
    TASK_FIELDS[item.key] ??
    (!item.encrypted && item.value && typeof item.value === 'object' ? Object.keys(item.value) : [])
  )
}

export function settingSearchTerms(item: AppConfigurationItem): string[] {
  const fields = settingFields(item)
  return [
    item.key,
    item.pattern_id ?? '',
    item.description ?? '',
    ...fields,
    ...fields.map(field => `${item.key}.${field}`),
    ...(FIELD_ALIASES[item.key] ?? [])
  ]
}

export function settingMatches(item: AppConfigurationItem, query: string, description = ''): boolean {
  const terms = [...settingSearchTerms(item), description].join(' ').toLocaleLowerCase()
  return query
    .trim()
    .toLocaleLowerCase()
    .split(/\s+/)
    .every(term => terms.includes(term))
}

export function settingFocus(items: AppConfigurationItem[], query: string): string | undefined {
  const item = items.find(candidate => settingMatches(candidate, query))
  if (!item) return undefined
  const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean)
  const field = settingFields(item).find(name =>
    terms.some(term => name.toLocaleLowerCase().includes(term) || term.endsWith(`.${name.toLocaleLowerCase()}`))
  )
  return field ? `${item.key}.${field}` : item.key
}

export function settingsSearch(params: URLSearchParams, changes: Record<string, string | undefined> = {}) {
  const next = new URLSearchParams(params)
  for (const [key, value] of Object.entries(changes)) {
    if (value === undefined) next.delete(key)
    else next.set(key, value)
  }
  return Object.fromEntries(next)
}

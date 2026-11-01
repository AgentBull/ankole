import { TableRow, useMutation, useQuery, Link, useSearchParams, useConsoleTenant } from '../tenant-context'
import { Badge, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, TableCell } from '@ankole/uikit'
import { useDeferredValue, useState } from 'react'
import { useQuery as useBaseQuery } from '@tanstack/react-query'
import { useRouter } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { RiSettings3Line } from '@remixicon/react'
import { recordValue } from '@agentbull/active-support'
import { dataTenantID } from '../../common/browser-session'
import { linkTarget } from '../../common/router'
import {
  decryptAppConfigurationMutation,
  getAgentAppConfigurationOptions,
  listAppConfigurationsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import { agentListOptions } from '../api/agents'
import {
  decryptSiteAppConfigurationMutation,
  getPrivilegedTenantOptions,
  listSiteAppConfigurationsOptions,
  listTenantsOptions
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from '../api/json-api'
import type { AppConfigurationItem } from '../api/configuration-types'
import { ResourceListPage, ResourceSearch } from '../console-list-page'
import { formatJSON } from '../console-primitives'
import { EncryptedValueInput, ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import {
  settingDescription,
  settingGroupID,
  settingOwnerRoute,
  settingRows,
  type SettingGroup
} from '../state/setting-groups'
import { settingFocus, settingMatches, settingsScope, settingsSearch } from '../state/settings-search'
import { requestErrorMessage } from '../../common/request-errors'
import { settingDecryptedDraft } from '../state/setting-editor-model'
import { DURATION_SWITCHES, settingDurationParts } from '../state/setting-value-editor'

function useSettingsTenantName() {
  const context = useConsoleTenant()
  const tenants = useBaseQuery({ ...listTenantsOptions(), select: document => fromDocument(document) })
  const privileged = useBaseQuery({ ...getPrivilegedTenantOptions(), select: document => fromDocument(document) })
  const id = context?.id ?? dataTenantID() ?? privileged.data?.id
  return tenants.data?.find(item => item.id === id)?.display_name ?? id ?? '—'
}

export function SettingsTenantContext() {
  const { t } = useTranslation()
  const name = useSettingsTenantName()
  return <span className="text-xs text-muted-foreground">{t('console.settings.data_tenant', { name })}</span>
}

export function SettingsList() {
  const { t } = useTranslation()
  const router = useRouter()
  const [params, setParams] = useSearchParams()
  const scope = settingsScope(params)
  const registry = params.get('view') === 'registry'
  const query = params.get('q') ?? ''
  const deferredQuery = useDeferredValue(query)
  const global = useBaseQuery(listSiteAppConfigurationsOptions())
  const tenant = useQuery(listAppConfigurationsOptions())
  const tenantName = useSettingsTenantName()
  const globalItems = new Map((global.data?.app_configurations ?? []).map(item => [item.key, item]))
  const tenantItems = new Map((tenant.data?.app_configurations ?? []).map(item => [item.key, item]))
  const current = scope === 'global' ? globalItems : tenantItems
  const all = new Map([...globalItems, ...tenantItems, ...current])
  const items = [...all.values()].filter(item => {
    const group = settingGroupID(item.key)
    const labels = [
      settingDescription(t, item),
      t(`console.settings.task_${item.key.replaceAll('.', '_')}`, { defaultValue: '' }),
      group ? t(`console.settings.group_${group}`) : '',
      group ? t(`console.settings.group_${group}_description`) : ''
    ].join(' ')
    return (current.has(item.key) || Boolean(deferredQuery.trim())) && settingMatches(item, deferredQuery, labels)
  })
  const rows = settingRows(items)
  const update = (key: string, value: string) =>
    setParams(
      previous => {
        const next = new URLSearchParams(previous)
        next.set(key, value)
        return next
      },
      { replace: key === 'q', preventScrollReset: true }
    )

  const duration = (item: AppConfigurationItem) => {
    if (item.key === 'ai_agent.max_output_tokens' && item.value == null) return t('console.settings.no_explicit_limit')
    const off = DURATION_SWITCHES[item.key]?.off
    if (off && item.value === 0) return t(off)
    const parts = settingDurationParts(item.key, item.value)
    return parts ? `${parts.amount} ${t(`console.settings.unit_${parts.unit}`)}` : undefined
  }
  const value = (item: AppConfigurationItem) =>
    item.kind === 'pattern'
      ? '—'
      : item.encrypted
        ? item.present
          ? '••••••••'
          : t('console.settings.source_missing')
        : item.present
          ? ((!registry ? duration(item) : undefined) ?? formatJSON(item.value ?? null))
          : t('console.settings.source_missing')
  const source = (item: AppConfigurationItem) => (
    <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
      <span>{t(`console.settings.source_${item.source}`)}</span>
      {item.overridden ? <Badge variant="outline">{t('console.settings.independent_override')}</Badge> : null}
      {item.agent_override_supported ? <span>{t('console.settings.agent_override_hint')}</span> : null}
      {item.runtime_status ? (
        <Badge variant={item.runtime_status === 'applied' ? 'secondary' : 'warning'}>
          {t(`console.settings.runtime_${item.runtime_status}`)}
        </Badge>
      ) : null}
    </div>
  )

  const ownerLink = (item: AppConfigurationItem) => {
    let route = settingOwnerRoute(item.key)
    if (!route) return null
    if (item.key.startsWith('ai_agent.library.')) route += `&defaults_scope=${scope}`
    if (item.key.startsWith('ai_gateway.')) route += `?defaults_scope=${scope}`
    const label =
      item.key === 'saas.require_invitation_code'
        ? 'owner_invitations'
        : item.key === 'plugins.enabled_ids'
          ? 'owner_control_plane_plugins'
          : item.key.startsWith('ai_gateway.')
            ? 'owner_model_profiles'
            : item.key.startsWith('ai_agent.library.')
              ? 'owner_library'
              : item.key.startsWith('signals.')
                ? 'owner_signals'
                : 'owner_identity'
    return (
      <Link className="link text-xs" {...linkTarget(route)}>
        {t(`console.settings.${label}`)}
      </Link>
    )
  }

  const singleRow = (summary: AppConfigurationItem) => {
    const item = current.get(summary.key) ?? summary
    const editable = current.has(item.key) && item.editable && !settingOwnerRoute(item.key)
    return (
      <TableRow key={item.key}>
        <TableCell className="max-w-lg whitespace-normal">
          <div className="grid gap-1.5">
            {!registry ? (
              <span className="font-medium">
                {t(`console.settings.task_${item.key.replaceAll('.', '_')}`, { defaultValue: item.key })}
              </span>
            ) : null}
            <code className="break-all text-xs">{item.key}</code>
            <span className="text-xs text-muted-foreground">{settingDescription(t, item)}</span>
            {registry && !item.editable ? (
              <span className="text-xs">
                {t(
                  `console.settings.${item.kind === 'pattern' ? 'reason_pattern' : scope === 'tenant' && item.scope === 'global' ? 'reason_site_only' : settingOwnerRoute(item.key) ? 'reason_owner' : 'reason_system'}`
                )}
              </span>
            ) : null}
          </div>
        </TableCell>
        <TableCell className="max-w-80 whitespace-normal">
          <div className="grid gap-2">
            <code className="line-clamp-3 break-all text-xs">{value(item)}</code>
            {source(item)}
            {registry && item.encrypted && item.present && item.kind !== 'pattern' ? (
              <RegistrySecret key={`${scope}:${dataTenantID()}:${item.key}`} item={item} scope={scope} />
            ) : null}
            {registry && scope === 'tenant' && item.agent_override_supported ? (
              <AgentSettingInspection key={`${dataTenantID()}:${item.key}`} item={item} />
            ) : null}
          </div>
        </TableCell>
        {registry ? (
          <TableCell>
            <span>{item.scope}</span>
            {item.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
            <span className="block text-xs">{item.kind}</span>
          </TableCell>
        ) : null}
        <TableCell className="text-right">
          {ownerLink(item) ??
            (editable && !registry ? (
              <Link
                className="link text-xs"
                to={`/settings/${encodeURIComponent(item.key)}`}
                search={settingsSearch(params, { scope })}>
                {t(
                  item.overridden
                    ? 'common.edit'
                    : scope === 'tenant' && item.scope === 'tenant'
                      ? 'console.settings.create_override'
                      : 'common.edit'
                )}
              </Link>
            ) : registry && settingGroupID(item.key) ? (
              <Link
                className="link text-xs"
                to={`/settings/group/${settingGroupID(item.key)}`}
                search={settingsSearch(params, { scope: item.scope === 'global' ? 'global' : scope, focus: item.key })}>
                {t('console.settings.open_task')}
              </Link>
            ) : (
              <span className="text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
            ))}
        </TableCell>
      </TableRow>
    )
  }

  const groupRow = (group: SettingGroup) => {
    const members = [...all.values()]
      .filter(item => settingGroupID(item.key) === group.id)
      .map(item => current.get(item.key) ?? item)
    const targetScope = members.some(item => current.has(item.key) && item.editable)
      ? scope
      : members.every(item => item.scope === 'pod')
        ? 'tenant'
        : 'global'
    const enabled = members.find(item => item.key.endsWith('.enabled'))
    const mail = group.id === 'smtp' ? recordValue(members[0]?.public_value) : undefined
    const overridden = members.filter(item => item.scope === 'tenant' && item.overridden).length
    const focus = query.trim() ? settingFocus(members, deferredQuery) : undefined
    return (
      <TableRow key={group.id}>
        <TableCell className="max-w-lg whitespace-normal">
          <div className="grid gap-1.5">
            <span className="font-medium">{t(`console.settings.group_${group.id}`)}</span>
            <span className="text-xs text-muted-foreground">{t(`console.settings.group_${group.id}_description`)}</span>
            {focus ? (
              <code className="break-all text-xs">{t('console.settings.matched_field', { key: focus })}</code>
            ) : null}
          </div>
        </TableCell>
        <TableCell className="max-w-80 whitespace-normal">
          <div className="grid gap-2">
            {group.id === 'smtp' ? (
              <>
                <span>
                  {t(mail?.server ? 'console.settings.mail_configured' : 'console.settings.mail_not_configured')}
                </span>
                {mail?.server ? (
                  <span className="break-all text-xs">
                    {String(mail.server)} · {String(mail.from ?? '')}
                  </span>
                ) : null}
                {members[0] ? source(members[0]) : null}
              </>
            ) : null}
            {enabled ? <span>{t(enabled.value ? 'console.status.enabled' : 'console.status.disabled')}</span> : null}
            {scope === 'tenant' && members.some(item => item.scope === 'tenant') ? (
              <span className="text-xs">{t('console.settings.override_count', { count: overridden })}</span>
            ) : null}
            {members
              .filter(
                item =>
                  !item.encrypted &&
                  item.kind !== 'pattern' &&
                  (group.id !== 'brain' ||
                    ['brain.embedding_model', 'brain.search_tokenizer', 'ai_gateway.model_profiles.rerank'].includes(
                      item.key
                    ))
              )
              .slice(0, 3)
              .map(item => (
                <div key={item.key} className="text-xs">
                  <code className="break-all">
                    {item.key.split('.').at(-1)}: {value(item)}
                  </code>
                </div>
              ))}
            {members.find(item => item.runtime_status) ? source(members.find(item => item.runtime_status)!) : null}
          </div>
        </TableCell>
        <TableCell className="text-right">
          <Link
            className="link text-xs"
            to={`/settings/group/${group.id}`}
            search={settingsSearch(params, { scope: targetScope, focus })}>
            {t(targetScope !== scope ? 'console.settings.open_site_task' : 'console.settings.open_task')}
          </Link>
        </TableCell>
      </TableRow>
    )
  }

  const taskSingles = [
    ...rows.singles,
    ...rows.managed.filter(item => (item.kind === 'exact' && settingOwnerRoute(item.key)) || query.trim())
  ]
  const count = registry ? items.length : rows.groups.length + taskSingles.length
  return (
    <ResourceListPage
      title={t('console.settings.title')}
      description={
        scope === 'global'
          ? t('console.settings.site_context')
          : `${t('console.settings.tenant_context')} · ${t('console.settings.data_tenant', { name: tenantName })}`
      }
      columns={
        registry
          ? [t('console.settings.key'), t('console.settings.effective_value'), t('console.settings.registry_policy')]
          : [t('console.settings.task'), t('console.settings.summary')]
      }
      count={count}
      isLoading={global.isLoading || tenant.isLoading}
      isEmpty={count === 0}
      emptyTitle={t('console.settings.empty_title')}
      emptyIcon={<RiSettings3Line aria-hidden />}
      emptyDescription={t('console.no_settings')}
      error={global.error ?? tenant.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => update('q', '')}
      toolbar={
        <>
          <Select
            value={scope}
            onValueChange={next =>
              next &&
              window.location.assign(
                router.buildLocation({
                  to: '/settings',
                  search: settingsSearch(new URLSearchParams(router.latestLocation.searchStr), {
                    scope: String(next),
                    view: params.get('view') ?? undefined,
                    q: params.get('q') ?? undefined
                  })
                }).href
              )
            }>
            <SelectTrigger aria-label={t('console.settings.editing_context')} className="w-52">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="global">{t('console.settings.site_context')}</SelectItem>
              <SelectItem value="tenant">{t('console.settings.tenant_context')}</SelectItem>
            </SelectContent>
          </Select>
          <Select value={registry ? 'registry' : 'tasks'} onValueChange={next => next && update('view', String(next))}>
            <SelectTrigger aria-label={t('console.settings.view')} className="w-52">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="tasks">{t('console.settings.task_view')}</SelectItem>
              <SelectItem value="registry">{t('console.settings.registry_view')}</SelectItem>
            </SelectContent>
          </Select>
          <ResourceSearch
            label={t('console.settings.search')}
            placeholder={t('console.settings.search_fields')}
            value={query}
            onChange={next => update('q', next)}
          />
        </>
      }>
      {registry ? (
        items.map(singleRow)
      ) : (
        <>
          {rows.groups.map(groupRow)}
          {taskSingles.map(singleRow)}
        </>
      )}
    </ResourceListPage>
  )
}

function RegistrySecret({ item, scope }: { item: AppConfigurationItem; scope: 'global' | 'tenant' }) {
  const { t } = useTranslation()
  const reveal = useMutation({
    ...(scope === 'global' ? decryptSiteAppConfigurationMutation() : decryptAppConfigurationMutation()),
    meta: { invalidates: false },
    gcTime: 0
  })
  return (
    <div className="grid gap-2 text-xs">
      <EncryptedValueInput
        readOnly
        value={reveal.data ? settingDecryptedDraft(reveal.data.decrypted_value.value) : ENCRYPTED_VALUE_MASK}
        revealed={reveal.isSuccess}
        revealing={reveal.isPending}
        revealLabel={t('console.settings.reveal')}
        onReveal={() => reveal.mutate({ path: { key: item.key } })}
      />
      {reveal.error ? <span className="text-destructive">{requestErrorMessage(reveal.error)}</span> : null}
    </div>
  )
}

function AgentSettingInspection({ item }: { item: AppConfigurationItem }) {
  const { t } = useTranslation()
  const [uid, setUID] = useState('')
  const agents = useQuery(agentListOptions())
  const resolution = useQuery({
    ...getAgentAppConfigurationOptions({ path: { key: item.key, agent_uid: uid } }),
    enabled: uid !== ''
  })
  const resolved = resolution.data?.app_configuration
  return (
    <div className="grid gap-2">
      <Select value={uid || null} onValueChange={next => setUID(String(next ?? ''))}>
        <SelectTrigger aria-label={t('console.settings.inspect_agent')}>
          <SelectValue placeholder={t('console.settings.inspect_agent')} />
        </SelectTrigger>
        <SelectContent>
          {(agents.data ?? []).map(agent => (
            <SelectItem key={agent.uid} value={agent.uid}>
              {agent.display_name || agent.uid}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {resolution.error ? (
        <span className="text-xs text-destructive">{t('console.settings.agent_resolution_unavailable')}</span>
      ) : resolved ? (
        <span className="text-xs">
          {formatJSON(resolved.value)} · {t(`console.settings.source_${resolved.source}`)}
        </span>
      ) : null}
    </div>
  )
}

import { useQuery, Link } from '../../tenant-context'
import {
  Badge,
  CreatableCombobox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { agentListOptions } from '../../api/agents'
import { fromDocument } from '../../api/json-api'
import { listPrincipalGroupsOptions, listPrincipalsOptions } from '../../api/v2/generated/@tanstack/react-query.gen'
import { SinglePrincipalPicker } from '../../principal-picker'
import { principalGroupDisplayName } from '../../state/principal-group-text'
import { principalLabel } from '../../state/principal-label'
import { brainObjectPath } from './brain-nav'

export type ParsedBrainScope =
  | { kind: 'unset' }
  | { kind: 'world' }
  | { kind: 'group'; name: string }
  | { kind: 'principal'; uid: string }
  | { kind: 'custom'; raw: string }

export function parseBrainScope(value: string | null | undefined): ParsedBrainScope {
  const trimmed = value?.trim() ?? ''
  if (!trimmed) return { kind: 'unset' }
  if (trimmed === 'world') return { kind: 'world' }
  if (trimmed.startsWith('group:') && trimmed.length > 'group:'.length) {
    return { kind: 'group', name: trimmed.slice('group:'.length) }
  }
  if (trimmed.startsWith('principal:') && trimmed.length > 'principal:'.length) {
    return { kind: 'principal', uid: trimmed.slice('principal:'.length) }
  }
  return { kind: 'custom', raw: trimmed }
}

/** Humanizes a Brain holder slug (`people/<uid>`, `agents/<uid>`, or an object slug) and links to its Brain page. */
export function BrainHolderLabel({ holder }: { holder?: string | null }) {
  const isHuman = Boolean(holder?.startsWith('people/'))
  const isAgent = Boolean(holder?.startsWith('agents/'))
  const uid = isHuman ? holder!.slice('people/'.length) : isAgent ? holder!.slice('agents/'.length) : ''

  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: document => fromDocument(document),
    enabled: isHuman && Boolean(uid)
  })
  const agents = useQuery({
    ...agentListOptions(),
    enabled: isAgent && Boolean(uid)
  })

  if (!holder) return <span>—</span>

  if (isHuman && uid) {
    const principal = principals.data?.find(item => item.id === uid)
    const label = principal ? principalLabel(principal) : holder
    return (
      <Link className="link text-xs" title={holder} to={brainObjectPath(holder)}>
        {label}
      </Link>
    )
  }

  if (isAgent && uid) {
    const agent = agents.data?.find(item => item.uid === uid)
    const label = agent ? agent.display_name : holder
    return (
      <Link className="link text-xs" title={holder} to={brainObjectPath(holder)}>
        {label}
      </Link>
    )
  }

  return (
    <Link className="link font-mono text-xs" to={brainObjectPath(holder)}>
      {holder}
    </Link>
  )
}

/** Humanizes a Brain `audience_scope` (`world`, `group:<name>`, `principal:<uid>`). */
export function BrainScopeLabel({ scope }: { scope?: string | null }) {
  const { t } = useTranslation()
  const parsed = parseBrainScope(scope)

  const groups = useQuery({
    ...listPrincipalGroupsOptions(),
    select: document => fromDocument(document),
    enabled: parsed.kind === 'group'
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: document => fromDocument(document),
    enabled: parsed.kind === 'principal'
  })

  if (parsed.kind === 'unset') return <span>—</span>
  if (parsed.kind === 'world') {
    return (
      <Badge title="world" variant="secondary">
        {t('console.brain.scope_world', { defaultValue: 'Shared (world)' })}
      </Badge>
    )
  }
  if (parsed.kind === 'group') {
    const group = groups.data?.find(item => item.name === parsed.name)
    const name = group ? principalGroupDisplayName(t, group) : parsed.name
    return (
      <Badge title={scope ?? undefined} variant="outline">
        {t('console.brain.scope_group_value', { defaultValue: 'Group: {$name}', name })}
      </Badge>
    )
  }
  if (parsed.kind === 'principal') {
    const principal = principals.data?.find(item => item.id === parsed.uid)
    const name = principal ? principalLabel(principal) : parsed.uid
    return (
      <Badge title={scope ?? undefined} variant="outline">
        {t('console.brain.scope_principal_value', { defaultValue: 'Principal: {$name}', name })}
      </Badge>
    )
  }
  return <span className="font-mono text-xs">{parsed.raw}</span>
}

type ScopeMode = 'unset' | 'world' | 'group' | 'principal' | 'custom'

/** Structured selector for `world`, `group:<name>`, `principal:<uid>`, or an optional unset default. */
export function BrainScopeSelector({
  ariaLabel,
  id,
  unsetLabel,
  value,
  onChange
}: {
  ariaLabel?: string
  id?: string
  unsetLabel: string
  value: string
  onChange: (value: string) => void
}) {
  const { t } = useTranslation()
  const parsed = parseBrainScope(value)
  const [selectedMode, setSelectedMode] = useState<ScopeMode>(parsed.kind)

  // Keep mode synchronized when an external reset changes the value category.
  const activeMode: ScopeMode =
    value.trim() === ''
      ? selectedMode === 'group' || selectedMode === 'principal' || selectedMode === 'custom'
        ? selectedMode
        : 'unset'
      : parsed.kind

  const groups = useQuery({
    ...listPrincipalGroupsOptions(),
    select: document => fromDocument(document),
    enabled: activeMode === 'group'
  })
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: document => fromDocument(document),
    enabled: activeMode === 'principal'
  })

  const groupOptions = (groups.data ?? []).map(group => ({
    value: group.name,
    label: principalGroupDisplayName(t, group),
    description: group.name
  }))

  const principalCandidates = (principals.data ?? []).map(principal => ({
    id: principal.id,
    label: principalLabel(principal),
    description: principal.email ?? principal.id
  }))

  const handleModeChange = (nextMode: string | null) => {
    if (
      nextMode !== 'unset' &&
      nextMode !== 'world' &&
      nextMode !== 'group' &&
      nextMode !== 'principal' &&
      nextMode !== 'custom'
    ) {
      return
    }
    setSelectedMode(nextMode)
    if (nextMode === 'unset') onChange('')
    else if (nextMode === 'world') onChange('world')
    else if (nextMode === 'group') {
      const firstGroup = groups.data?.[0]?.name
      onChange(firstGroup ? `group:${firstGroup}` : '')
    } else if (nextMode === 'principal') {
      onChange('')
    } else {
      onChange(parsed.kind === 'custom' ? parsed.raw : '')
    }
  }

  return (
    <div className="grid gap-2">
      <Select value={activeMode} onValueChange={handleModeChange}>
        <SelectTrigger aria-label={ariaLabel} className="w-full" id={id}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="unset">{unsetLabel}</SelectItem>
          <SelectItem value="world">{t('console.brain.scope_world', { defaultValue: 'Shared (world)' })}</SelectItem>
          <SelectItem value="group">{t('console.brain.scope_mode_group', { defaultValue: 'Group' })}</SelectItem>
          <SelectItem value="principal">
            {t('console.brain.scope_mode_principal', { defaultValue: 'Principal (private)' })}
          </SelectItem>
          {activeMode === 'custom' ? (
            <SelectItem value="custom">
              {t('console.brain.scope_mode_custom', { defaultValue: 'Custom scope' })}
            </SelectItem>
          ) : null}
        </SelectContent>
      </Select>

      {activeMode === 'group' ? (
        <CreatableCombobox
          ariaLabel={t('console.brain.scope_group_picker', { defaultValue: 'Group scope' })}
          clearLabel={t('common.clear')}
          createLabel={input => input}
          emptyLabel={t('common.select_empty')}
          options={groupOptions}
          placeholder={t('console.brain.scope_group_placeholder', { defaultValue: 'Select or enter group name' })}
          triggerLabel={t('common.open')}
          value={parsed.kind === 'group' ? parsed.name : ''}
          onValueChange={groupName => onChange(groupName.trim() ? `group:${groupName.trim()}` : '')}
        />
      ) : null}

      {activeMode === 'principal' ? (
        <SinglePrincipalPicker
          ariaLabel={t('console.brain.scope_principal_picker', { defaultValue: 'Principal scope' })}
          candidates={principalCandidates}
          error={principals.error}
          isLoading={principals.isLoading}
          placeholder={t('console.brain.select_principal')}
          value={parsed.kind === 'principal' ? parsed.uid : ''}
          onChange={uid => onChange(uid ? `principal:${uid}` : '')}
        />
      ) : null}

      {activeMode === 'custom' ? (
        <Input
          aria-label={t('console.brain.scope_mode_custom', { defaultValue: 'Custom scope' })}
          className="font-mono"
          placeholder="world | group:<name> | principal:<uid>"
          spellCheck={false}
          value={value}
          onChange={event => onChange(event.target.value)}
        />
      ) : null}
    </div>
  )
}

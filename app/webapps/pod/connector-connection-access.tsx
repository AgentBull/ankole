import { Checkbox, Label, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import type { Signal } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ContentError } from './content-primitives'
import { podSubjects } from './api/generated/sdk.gen'
import { contentKeys } from './content-api'
import type { ConnectionAccess } from './state/connectors'

/** Chooses who may query a database connection; the choice is stored as AuthZ grants. */
export function ConnectionAccessFields({ access }: { access: Signal<ConnectionAccess> }) {
  useSignals()
  const { t } = useTranslation()
  const restricted = access.value.mode === 'restricted'
  const subjects = useQuery({
    queryKey: [...contentKeys.all, 'subjects'],
    queryFn: () => podSubjects(),
    enabled: restricted
  })
  const choices = (subjects.data?.subjects ?? []).filter(
    subject => (subject.kind === 'group' && subject.group_id) || (subject.kind === 'agent' && subject.principal_uid)
  )
  const toggle = (key: 'group_ids' | 'principal_uids', id: string, checked: boolean) => {
    const ids = access.value[key].filter(value => value !== id)
    access.value = { ...access.value, [key]: checked ? [...ids, id] : ids }
  }
  return (
    <div className="grid gap-2">
      <Label>{t('pod.connectors.access')}</Label>
      <Select
        value={access.value.mode}
        onValueChange={value => {
          if (value === 'members' || value === 'restricted') access.value = { ...access.value, mode: value }
        }}>
        <SelectTrigger aria-label={t('pod.connectors.access')}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="members">{t('pod.connectors.access_members')}</SelectItem>
          <SelectItem value="restricted">{t('pod.connectors.access_restricted')}</SelectItem>
        </SelectContent>
      </Select>
      {restricted && (
        <>
          <p className="text-xs text-muted-foreground">{t('pod.connectors.access_restricted_help')}</p>
          <ContentError error={subjects.error} />
          <div className="grid max-h-48 gap-2 overflow-y-auto rounded-lg border p-3">
            {choices.map(subject => {
              const key = subject.kind === 'group' ? 'group_ids' : 'principal_uids'
              const id = (subject.kind === 'group' ? subject.group_id : subject.principal_uid)!
              return (
                <Label key={`${key}:${id}`} className="flex items-center gap-2 font-normal">
                  <Checkbox
                    checked={access.value[key].includes(id)}
                    onCheckedChange={checked => toggle(key, id, checked === true)}
                  />
                  <span className="min-w-0 flex-1 truncate">{subject.name}</span>
                  <span className="text-xs text-muted-foreground">
                    {t(subject.kind === 'group' ? 'pod.connectors.access_group' : 'pod.connectors.access_agent')}
                  </span>
                </Label>
              )
            })}
          </div>
        </>
      )}
    </div>
  )
}

import { useTranslation } from 'react-i18next'
import {
  Badge,
  Select,
  SelectContent,
  SelectItem,
  SelectSeparator,
  SelectTrigger,
  SelectValue,
  Tooltip,
  TooltipContent,
  TooltipTrigger
} from '@ankole/uikit'
import { RiInformationLine } from '@remixicon/react'
import type { PageRole } from '../content-api'
import type { InheritedCollaborator } from '../state/page-sharing'
import { inheritedOriginDescription, sharingRoleLabel, SubjectAvatar, SubjectKindBadges } from './sharing-primitives'

type CollaboratorRowSubject = {
  name: string
  kind: 'human' | 'agent' | 'group' | 'userset'
  role: PageRole
  avatar_url?: string | null
  subtitle?: string | null
  membership?: 'member' | 'guest' | null
  group_domain?: 'operator' | 'directory' | 'im_group' | 'signal_source' | null
  inactive_in_private?: boolean
}

export function CollaboratorRow({
  subject,
  roles,
  origin,
  editable,
  pending,
  onChangeRole,
  onRemove
}: {
  subject: CollaboratorRowSubject
  roles: Partial<Record<PageRole, string>>
  origin?: InheritedCollaborator['origin']
  editable?: boolean
  pending?: boolean
  onChangeRole?(role: PageRole): void
  onRemove?(): void
}) {
  const { t } = useTranslation()
  const displayName = subject.name || t('pod.content.unknown_member')
  const originTip = origin ? inheritedOriginDescription(origin) : undefined
  const roleLabel = roles[subject.role] ?? sharingRoleLabel(subject.role)

  return (
    <li className="flex items-center justify-between gap-3 py-2">
      <div className="flex min-w-0 flex-1 items-center gap-2.5">
        <SubjectAvatar subject={subject} size="default" />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-1.5">
            <span className="truncate text-sm font-medium text-foreground">{displayName}</span>
            {origin === 'private_owner' && <Badge variant="secondary">{t('pod.sharing.badge_owner')}</Badge>}
            <SubjectKindBadges subject={subject} />
            {subject.inactive_in_private && (
              <Badge variant="outline" className="text-muted-foreground">
                {t('pod.sharing.badge_inactive_private')}
              </Badge>
            )}
            {originTip && (
              <Tooltip>
                <TooltipTrigger
                  render={
                    <button
                      type="button"
                      aria-label={originTip}
                      className="inline-flex size-4 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:text-foreground focus-visible:outline-offset-1">
                      <RiInformationLine aria-hidden className="size-3.5" />
                    </button>
                  }
                />
                <TooltipContent>{originTip}</TooltipContent>
              </Tooltip>
            )}
          </div>
          {subject.subtitle && <p className="truncate text-xs text-muted-foreground">{subject.subtitle}</p>}
        </div>
      </div>
      <div className="shrink-0">
        {editable && onChangeRole && onRemove ? (
          <Select<PageRole | '__remove__'>
            value={subject.role}
            disabled={pending}
            onValueChange={next => {
              if (!next || next === subject.role) return
              if (next === '__remove__') {
                onRemove()
              } else {
                onChangeRole(next)
              }
            }}>
            <SelectTrigger size="sm" aria-label={t('pod.content.member_permission')}>
              <SelectValue>{() => roleLabel}</SelectValue>
            </SelectTrigger>
            <SelectContent align="end">
              {Object.entries<string | undefined>(roles).map(([roleKey, label]) => (
                <SelectItem key={roleKey} value={roleKey as PageRole}>
                  {label}
                </SelectItem>
              ))}
              <SelectSeparator />
              <SelectItem value="__remove__" className="text-destructive focus:text-destructive">
                {t('pod.sharing.remove_access')}
              </SelectItem>
            </SelectContent>
          </Select>
        ) : (
          <span className="text-xs text-muted-foreground">{roleLabel}</span>
        )}
      </div>
    </li>
  )
}

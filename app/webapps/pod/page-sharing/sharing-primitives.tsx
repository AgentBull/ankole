import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Avatar, AvatarFallback, AvatarImage, Badge, Button, PopoverTitle } from '@ankole/uikit'
import { RiArrowLeftSLine, RiGroupLine, RiOrganizationChart, RiRobot2Line } from '@remixicon/react'
import { avatarInitials } from '../avatar-initials'
import type { PageRole, PageType } from '../content-api'
import type { InheritedCollaborator } from '../state/page-sharing'

export function SubviewHeader({ title, disabled, onBack }: { title: string; disabled?: boolean; onBack(): void }) {
  const { t: translate } = useTranslation()
  return (
    <div className="flex items-center gap-1.5 px-3 pt-3 pb-2">
      <Button
        type="button"
        variant="ghost"
        size="icon-xs"
        aria-label={translate('pod.sharing.back')}
        title={translate('pod.sharing.back')}
        disabled={disabled}
        onClick={onBack}>
        <RiArrowLeftSLine aria-hidden className="size-4" />
      </Button>
      <PopoverTitle>{title}</PopoverTitle>
    </div>
  )
}

export function SubjectAvatar({
  subject,
  size = 'default'
}: {
  subject: {
    name: string
    kind: 'human' | 'agent' | 'group' | 'userset'
    avatar_url?: string | null
    group_domain?: 'operator' | 'directory' | 'im_group' | 'signal_source' | null
  }
  size?: 'sm' | 'default'
}) {
  const initial = avatarInitials(subject.name)
  return (
    <Avatar size={size}>
      {subject.avatar_url ? <AvatarImage src={subject.avatar_url} alt="" /> : null}
      <AvatarFallback>
        {subject.kind === 'agent' ? (
          <RiRobot2Line aria-hidden className={size === 'sm' ? 'size-3.5' : 'size-4'} />
        ) : subject.kind === 'group' ? (
          subject.group_domain === 'directory' ? (
            <RiOrganizationChart aria-hidden className={size === 'sm' ? 'size-3.5' : 'size-4'} />
          ) : (
            <RiGroupLine aria-hidden className={size === 'sm' ? 'size-3.5' : 'size-4'} />
          )
        ) : (
          initial
        )}
      </AvatarFallback>
    </Avatar>
  )
}

export function SubjectKindBadges({
  subject
}: {
  subject: {
    kind: 'human' | 'agent' | 'group' | 'userset'
    membership?: 'member' | 'guest' | null
    group_domain?: 'operator' | 'directory' | 'im_group' | 'signal_source' | null
  }
}) {
  const { t: translate } = useTranslation()
  return (
    <>
      {subject.kind === 'agent' && <Badge variant="secondary">{translate('pod.sharing.badge_agent')}</Badge>}
      {subject.kind === 'group' && (
        <Badge variant="secondary">
          {subject.group_domain === 'directory'
            ? translate('pod.sharing.badge_department')
            : translate('pod.sharing.badge_group')}
        </Badge>
      )}
      {subject.membership === 'guest' && <Badge variant="secondary">{translate('pod.sharing.badge_guest')}</Badge>}
    </>
  )
}

export function shareTitle(pageType?: PageType): string {
  switch (pageType) {
    case 'doc':
      return t('pod.sharing.title_doc')
    case 'base':
      return t('pod.sharing.title_base')
    case 'applet':
      return t('pod.sharing.title_applet')
    case 'file':
      return t('pod.sharing.title_file')
    default:
      return t('pod.sharing.title_page')
  }
}

export function sharingRoleLabel(role: PageRole, pageType?: PageType): string {
  switch (role) {
    case 'view':
      return t('pod.sharing.role_view')
    case 'contribute':
      return pageType === 'base' ? t('pod.sharing.role_contribute') : t('pod.sharing.role_comment')
    case 'edit':
      return t('pod.sharing.role_edit')
    case 'manage':
      return t('pod.sharing.role_manage')
  }
}

export function availableRolesForPage(pageType?: PageType): Partial<Record<PageRole, string>> {
  if (pageType === 'base') {
    return {
      view: t('pod.sharing.role_view'),
      contribute: t('pod.sharing.role_contribute'),
      edit: t('pod.sharing.role_edit'),
      manage: t('pod.sharing.role_manage')
    }
  }
  if (pageType === 'doc' || pageType === 'file') {
    return {
      view: t('pod.sharing.role_view'),
      contribute: t('pod.sharing.role_comment'),
      edit: t('pod.sharing.role_edit'),
      manage: t('pod.sharing.role_manage')
    }
  }
  return {
    view: t('pod.sharing.role_view'),
    edit: t('pod.sharing.role_edit'),
    manage: t('pod.sharing.role_manage')
  }
}

export function spaceScopeDescription(role: PageRole, pageType?: PageType): string {
  switch (role) {
    case 'manage':
      return t('pod.sharing.scope_space_desc_manage')
    case 'edit':
      return t('pod.sharing.scope_space_desc_edit')
    case 'contribute':
      return pageType === 'base'
        ? t('pod.sharing.scope_space_desc_contribute')
        : t('pod.sharing.scope_space_desc_comment')
    case 'view':
    default:
      return t('pod.sharing.scope_space_desc_view')
  }
}

export function inheritedOriginDescription(origin: InheritedCollaborator['origin']): string {
  switch (origin) {
    case 'space_admin':
      return t('pod.sharing.origin_space_admin')
    case 'space_default':
      return t('pod.sharing.origin_space_default')
    case 'space_agent':
      return t('pod.sharing.origin_space_agent')
    case 'private_owner':
      return t('pod.sharing.origin_private_owner')
    case 'ancestor':
      return t('pod.sharing.origin_ancestor')
  }
}

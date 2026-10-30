import { useTranslation } from 'react-i18next'
import {
  AvatarGroup,
  AvatarGroupCount,
  Badge,
  Button,
  PopoverTitle,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { RiArrowRightSLine, RiBuildingLine, RiLink, RiLockLine, RiSettings3Line } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import type { PageRole, PageSharingDetail, PageType } from '../content-api'
import { ContentError } from '../content-primitives'
import {
  effectiveCollaboratorPreview,
  type PageSharingModel,
  type SharingGrant,
  type SharingScopeTab,
  type SharingSubject
} from '../state/page-sharing'
import { shareTitle, spaceScopeDescription, SubjectAvatar } from './sharing-primitives'
import { SubjectPicker } from './subject-picker'
import type { PageSharingMutations } from './use-page-sharing'

export function MainSharingView({
  pageType,
  hasParent,
  model,
  sharing,
  ordinaryGrants,
  directByKey,
  advancedCount,
  roles,
  canManage,
  mutations,
  copyLink,
  onOpenCollaborators,
  onOpenSettings,
  onStageSubject
}: {
  pageType?: PageType
  hasParent: boolean
  model: InstanceType<typeof PageSharingModel>
  sharing: PageSharingDetail
  ordinaryGrants: readonly SharingGrant[]
  directByKey: ReadonlyMap<string, SharingGrant>
  advancedCount: number
  roles: Partial<Record<PageRole, string>>
  canManage: boolean
  mutations: PageSharingMutations
  copyLink(): Promise<void>
  onOpenCollaborators(): void
  onOpenSettings(): void
  onStageSubject(subject: SharingSubject, defaultRole?: PageRole, defaultScope?: SharingScopeTab): void
}) {
  useSignals()
  const { t } = useTranslation()
  const preview = effectiveCollaboratorPreview(sharing, 4)
  const isPrivate = sharing.scope_kind === 'private'

  return (
    <div className="flex min-h-0 flex-col">
      <div className="flex items-center justify-between gap-2 px-4 pt-3.5 pb-2.5">
        <PopoverTitle>{shareTitle(pageType)}</PopoverTitle>
        {canManage && (
          <Button variant="ghost" size="xs" disabled={mutations.pending} onClick={onOpenSettings}>
            <RiSettings3Line aria-hidden className="size-3.5" />
            {t('pod.sharing.permission_settings')}
            {advancedCount > 0 && (
              <Badge variant="secondary" className="ml-0.5 tabular-nums">
                {advancedCount}
              </Badge>
            )}
          </Button>
        )}
      </div>

      <div className="grid gap-4 overflow-y-auto px-4 pb-3.5">
        <section className="grid gap-2">
          <div className="flex min-h-7 items-center justify-between gap-2">
            <span className="text-[13px] font-medium text-foreground">
              {canManage ? t('pod.sharing.invite_collaborators') : t('pod.sharing.collaborators')}
            </span>
            {(preview.total > 0 || ordinaryGrants.length > 0) && (
              <button
                type="button"
                aria-label={t('pod.sharing.manage_collaborators')}
                disabled={mutations.pending}
                onClick={onOpenCollaborators}
                className="group inline-flex cursor-pointer items-center gap-1 rounded-control px-1.5 py-0.5 transition-colors hover:bg-accent focus-visible:outline-offset-1 disabled:cursor-not-allowed disabled:opacity-50">
                <AvatarGroup className="-space-x-1.5">
                  {preview.items.map(item => (
                    <SubjectAvatar key={item.key} subject={item} size="sm" />
                  ))}
                  {preview.overflow > 0 && (
                    <AvatarGroupCount className="text-[11px] tabular-nums">{`+${preview.overflow}`}</AvatarGroupCount>
                  )}
                </AvatarGroup>
                <RiArrowRightSLine
                  aria-hidden
                  className="size-4 text-muted-foreground transition-transform group-hover:translate-x-0.5"
                />
              </button>
            )}
          </div>

          {canManage && (
            <SubjectPicker
              subjects={sharing.subjects}
              directByKey={directByKey}
              roles={roles}
              pageType={pageType}
              isPrivate={isPrivate}
              query={model.query.value}
              onQueryChange={value => {
                model.query.value = value
              }}
              disabled={mutations.pending}
              collapsible={{
                open: model.browseOpen.value,
                onOpenChange: next => {
                  model.browseOpen.value = next
                }
              }}
              onSelectSubject={(subject, existing) =>
                onStageSubject(
                  subject,
                  existing?.role ?? 'view',
                  existing?.target_scope === 'self'
                    ? 'self'
                    : existing?.target_scope === 'container'
                      ? 'container'
                      : undefined
                )
              }
            />
          )}
        </section>

        <AccessScopeSection
          sharing={sharing}
          pageType={pageType}
          hasParent={hasParent}
          canManage={canManage}
          pending={mutations.pending}
          onChangeInherit={mutations.setInheritPermissions}
        />

        <ContentError error={mutations.error} />
      </div>

      <div className="flex items-center justify-between border-t border-border px-4 py-2.5">
        <Button variant="outline" size="sm" onClick={() => void copyLink()}>
          <RiLink aria-hidden className="size-4" />
          {t('pod.content.copy_link')}
        </Button>
      </div>
    </div>
  )
}

function AccessScopeSection({
  sharing,
  pageType,
  hasParent,
  canManage,
  pending,
  onChangeInherit
}: {
  sharing: PageSharingDetail
  pageType?: PageType
  hasParent: boolean
  canManage: boolean
  pending: boolean
  onChangeInherit(inherit: boolean): void
}) {
  const { t } = useTranslation()
  const isPrivate = sharing.scope_kind === 'private'
  const isPrivateRoot = isPrivate && !hasParent
  const inheritTitle = hasParent
    ? t('pod.sharing.scope_inherit_parent')
    : sharing.space_name || t('pod.sharing.scope_space_fallback')
  const inheritDescription = hasParent
    ? t('pod.sharing.scope_inherit_parent_desc')
    : spaceScopeDescription(sharing.space_role ?? 'view', pageType)

  if (isPrivateRoot) {
    return (
      <section className="grid gap-1.5">
        <span className="text-[13px] font-medium text-foreground">{t('pod.sharing.access_scope')}</span>
        <div className="flex items-start gap-2.5 rounded-control bg-muted/45 px-3 py-2.5">
          <span className="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-muted text-muted-foreground">
            <RiLockLine aria-hidden className="size-4" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-sm font-medium text-foreground">{t('pod.sharing.scope_private_root')}</div>
            <p className="text-xs leading-4 text-muted-foreground">{t('pod.sharing.scope_private_root_desc')}</p>
          </div>
        </div>
      </section>
    )
  }

  const activeMode = sharing.inherit_permissions ? 'inherit' : 'invited'
  const activeTitle = activeMode === 'inherit' ? inheritTitle : t('pod.sharing.scope_invited_only')
  const activeDescription = activeMode === 'inherit' ? inheritDescription : t('pod.sharing.scope_invited_only_desc')
  const ActiveIcon = activeMode === 'inherit' && !isPrivate ? RiBuildingLine : RiLockLine

  return (
    <section className="grid gap-1.5">
      <span className="text-[13px] font-medium text-foreground">{t('pod.sharing.access_scope')}</span>
      <div className="flex items-start gap-2.5 rounded-control bg-muted/45 px-3 py-2.5">
        <span className="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-muted text-foreground">
          <ActiveIcon aria-hidden className="size-4" />
        </span>
        <div className="min-w-0 flex-1 grid gap-1">
          {canManage ? (
            <Select
              value={activeMode}
              disabled={pending}
              onValueChange={next => {
                if (!next || next === activeMode) return
                onChangeInherit(next === 'inherit')
              }}>
              <SelectTrigger size="sm" aria-label={t('pod.sharing.access_scope')} className="max-w-full">
                <SelectValue>{() => activeTitle}</SelectValue>
              </SelectTrigger>
              <SelectContent align="start">
                <SelectItem value="inherit">{inheritTitle}</SelectItem>
                <SelectItem value="invited">{t('pod.sharing.scope_invited_only')}</SelectItem>
              </SelectContent>
            </Select>
          ) : (
            <div className="text-sm font-medium text-foreground">{activeTitle}</div>
          )}
          <p className="text-xs leading-4 text-muted-foreground">{activeDescription}</p>
        </div>
      </div>
    </section>
  )
}

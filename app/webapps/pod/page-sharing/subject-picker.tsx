import { useTranslation } from 'react-i18next'
import { Badge, Button, cn, Command, CommandEmpty, CommandInput, CommandItem, CommandList } from '@ankole/uikit'
import { RiAddLine } from '@remixicon/react'
import type { PageRole, PageType } from '../content-api'
import { sortCandidateSubjects, subjectKey, type SharingGrant, type SharingSubject } from '../state/page-sharing'
import { sharingRoleLabel, SubjectAvatar, SubjectKindBadges } from './sharing-primitives'

type SubjectPickerCollapsibleProps = {
  open: boolean
  onOpenChange(open: boolean): void
}

export function SubjectPicker({
  subjects,
  directByKey,
  roles,
  pageType,
  isPrivate,
  query,
  onQueryChange,
  disabled,
  collapsible,
  onSelectSubject
}: {
  subjects: readonly SharingSubject[]
  directByKey: ReadonlyMap<string, SharingGrant>
  roles: Partial<Record<PageRole, string>>
  pageType?: PageType
  isPrivate: boolean
  query: string
  onQueryChange(value: string): void
  disabled?: boolean
  collapsible?: SubjectPickerCollapsibleProps
  onSelectSubject(subject: SharingSubject, existing?: SharingGrant): void
}) {
  const { t } = useTranslation()
  const showCandidates = collapsible ? collapsible.open || query.trim().length > 0 : true
  const sortedSubjects = sortCandidateSubjects(subjects, directByKey, isPrivate)

  return (
    <Command
      className={cn('h-auto min-h-0 bg-transparent', collapsible && 'overflow-visible')}
      label={t('pod.content.search_collaborators')}
      onBlur={
        collapsible
          ? event => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
                collapsible.onOpenChange(false)
              }
            }
          : undefined
      }
      onKeyDown={
        collapsible
          ? event => {
              if (event.key === 'Escape' && showCandidates) {
                event.preventDefault()
                event.stopPropagation()
                collapsible.onOpenChange(false)
                onQueryChange('')
              }
            }
          : undefined
      }>
      <div className="flex items-center gap-1.5">
        <div className="min-w-0 flex-1">
          <CommandInput
            aria-label={t('pod.content.search_collaborators')}
            placeholder={t('pod.sharing.search_placeholder')}
            value={query}
            disabled={disabled}
            onValueChange={value => {
              onQueryChange(value)
              collapsible?.onOpenChange(true)
            }}
            onFocus={collapsible ? () => collapsible.onOpenChange(true) : undefined}
          />
        </div>
        {collapsible && (
          <Button
            type="button"
            variant="outline"
            size="icon-sm"
            aria-label={t('pod.sharing.browse_candidates')}
            title={t('pod.sharing.browse_candidates')}
            aria-expanded={showCandidates}
            disabled={disabled}
            onClick={() => collapsible.onOpenChange(!collapsible.open)}>
            <RiAddLine aria-hidden className="size-4" />
          </Button>
        )}
      </div>
      {showCandidates && (
        <CommandList
          className={cn(
            'mt-1.5 overflow-y-auto rounded-control border border-border bg-background/70 p-1',
            collapsible ? 'max-h-52' : 'max-h-40'
          )}>
          <CommandEmpty>{t('pod.content.no_matches')}</CommandEmpty>
          {sortedSubjects.map(subject => {
            const key = subjectKey(subject)
            const existing = directByKey.get(key)
            const guestBlocked = isPrivate && subject.membership === 'guest'
            return (
              <CommandItem
                key={key}
                value={key}
                keywords={[subject.name, subject.subtitle ?? '']}
                disabled={disabled || guestBlocked}
                onSelect={() => {
                  if (guestBlocked) return
                  onSelectSubject(subject, existing)
                }}>
                <SubjectAvatar subject={subject} size="sm" />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5">
                    <span className="truncate text-sm">{subject.name}</span>
                    <SubjectKindBadges subject={subject} />
                  </div>
                  {(guestBlocked || subject.subtitle) && (
                    <p className="truncate text-xs text-muted-foreground">
                      {guestBlocked ? t('pod.sharing.guest_disabled_private') : subject.subtitle}
                    </p>
                  )}
                </div>
                {existing && !guestBlocked && (
                  <Badge variant="secondary" className="shrink-0">
                    {roles[existing.role] ?? sharingRoleLabel(existing.role, pageType)}
                  </Badge>
                )}
              </CommandItem>
            )
          })}
        </CommandList>
      )}
    </Command>
  )
}

import { t } from 'i18next'
import {
  Button,
  Checkbox,
  Command,
  CommandEmpty,
  CommandInput,
  CommandItem,
  CommandList,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  toast
} from '@ankole/uikit'
import { RiCloseLine, RiLink } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useContent } from './content-context'
import { contentKeys, pageAPI, pageQuery, type PageRole, type PageSharing } from './content-api'
import { Choice, ContentError, roleLabels } from './content-primitives'

import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { isAdvancedSharingRule, PageSharingModel } from './state/page-sharing'

export function PageSharingButton({ pageID }: { pageID: string }) {
  const [open, setOpen] = useState(false)
  const copyLink = useCopyPageLink(pageID)
  const client = useQueryClient()
  const write = useMutation({
    mutationFn: (draft: PageSharing) => pageAPI.share(pageID, draft),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
    }
  })
  return (
    <Popover
      open={open}
      onOpenChange={next => {
        if (write.isPending) return
        if (next) write.reset()
        setOpen(next)
      }}>
      <PopoverTrigger render={<Button variant="ghost" size="sm" />}>{t('pod.content.share')}</PopoverTrigger>
      <PopoverContent
        align="end"
        sideOffset={8}
        className="grid max-h-[min(70vh,var(--available-height))] w-[min(28rem,calc(100vw-2rem))] gap-3 overflow-y-auto">
        <div className="flex items-center justify-between gap-2">
          <PopoverTitle>{t('pod.content.share_page')}</PopoverTitle>
          <Button variant="outline" size="sm" onClick={() => void copyLink()}>
            <RiLink aria-hidden className="size-4" />
            {t('pod.content.copy_link')}
          </Button>
        </div>
        {open && (
          <SharingForm
            key={pageID}
            pageID={pageID}
            save={draft => write.mutate(draft)}
            pending={write.isPending}
            error={write.error}
          />
        )}
      </PopoverContent>
    </Popover>
  )
}

function SharingForm({
  pageID,
  save,
  pending,
  error
}: {
  pageID: string
  save(draft: PageSharing): void
  pending: boolean
  error: unknown
}) {
  useSignals()
  const model = useModel(PageSharingModel)
  const sharing = useQuery({
    queryKey: contentKeys.sharing(pageID),
    queryFn: () => pageAPI.sharing(pageID)
  })
  const page = useQuery(pageQuery(pageID))
  const availableRoles =
    page.data?.page.type === 'base'
      ? roleLabels
      : { view: roleLabels.view, edit: roleLabels.edit, manage: roleLabels.manage }
  const [query, setQuery] = useState('')
  const [listOpen, setListOpen] = useState(false)
  const [selected, setSelected] = useState('')
  const [role, setRole] = useState<PageRole>('view')
  useEffect(() => {
    if (sharing.data && !sharing.isFetching && !sharing.error && !pending && !error) model.replace(sharing.data)
  }, [sharing.data, sharing.isFetching, sharing.error, model, pending, error])
  const draft = model.draft.value
  if (!draft) {
    return (
      <>
        <ContentError error={sharing.error} retry={() => void sharing.refetch()} />
        {!sharing.error && <p role="status">{t('pod.content.loading_sharing_settings')}</p>}
      </>
    )
  }
  const subjectKey = (subject: { principal_uid?: string | null; group_id?: string | null }) =>
    subject.principal_uid ? `principal:${subject.principal_uid}` : `group:${subject.group_id}`
  const subjectKindLabel = (kind?: string | null) =>
    kind === 'agent' ? t('pod.content.agent_kind') : kind === 'group' ? t('pod.content.group') : ''
  const directGrants = new Map(
    draft.grants
      .filter(grant => !isAdvancedSharingRule(grant) && (grant.principal_uid || grant.group_id))
      .map(grant => [subjectKey(grant), grant] as const)
  )
  const selectedAudience = draft.subjects.find(subject => subjectKey(subject) === selected)
  const sortedSubjects = [...draft.subjects].sort(
    (a, b) => Number(directGrants.has(subjectKey(a))) - Number(directGrants.has(subjectKey(b)))
  )
  const showList = listOpen || query.trim().length > 0
  const commit = (change: () => void) => {
    change()
    const body = model.body()
    if (body) save(body)
  }
  const add = () => {
    if (!selectedAudience) return
    const existing = directGrants.get(selected)
    commit(() =>
      model.add({
        ...selectedAudience,
        role,
        target_scope: existing?.target_scope ?? 'container',
        condition: 'true'
      })
    )
    setSelected('')
    setQuery('')
    setListOpen(false)
  }
  const actionLabels = {
    page_view: t('pod.content.can_view'),
    page_write_records: t('pod.content.can_contribute'),
    page_edit: t('pod.content.can_edit'),
    page_manage: t('pod.content.full_access')
  }
  return (
    <>
      <label className="flex items-start gap-3 text-sm">
        <Checkbox
          checked={draft.inherit_permissions}
          disabled={pending}
          onCheckedChange={checked => commit(() => model.inherit(checked))}
        />
        <span>
          {t('pod.content.inherit_access_from_the_parent_page_or_space')}
          <br />
          <span className="text-xs text-fg-tertiary">
            {t('pod.content.when_off_only_the_members_explicitly_listed_below_can_access')}
          </span>
        </span>
      </label>
      <fieldset className="grid gap-2.5 rounded-control border border-border p-3" disabled={pending}>
        <legend className="px-1 text-sm">{t('pod.content.add_sharing_rule')}</legend>
        <Command
          className="h-auto min-h-0"
          label={t('pod.content.choose_a_member_group_or_agent')}
          onBlur={event => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setListOpen(false)
          }}
          onKeyDown={event => {
            if (event.key === 'Escape' && showList) {
              event.preventDefault()
              event.stopPropagation()
              setListOpen(false)
              setQuery('')
            }
          }}>
          <CommandInput
            aria-label={t('pod.content.search_collaborators')}
            placeholder={t('pod.content.search_collaborators')}
            value={query}
            onValueChange={value => {
              setQuery(value)
              setListOpen(true)
            }}
            onFocus={() => setListOpen(true)}
            disabled={pending}
          />
          {showList && (
            <CommandList className="max-h-44 overflow-y-auto">
              <CommandEmpty>{t('pod.content.no_matches')}</CommandEmpty>
              {sortedSubjects.map(subject => {
                const key = subjectKey(subject)
                const kind = subjectKindLabel(subject.kind)
                const existing = directGrants.get(key)
                return (
                  <CommandItem
                    key={key}
                    value={key}
                    keywords={[subject.name]}
                    data-checked={selected === key}
                    disabled={pending}
                    onSelect={() => {
                      setSelected(key)
                      setQuery('')
                      setListOpen(false)
                    }}>
                    <span className="min-w-0 flex-1 truncate">
                      {subject.name}
                      {kind ? <span className="text-fg-tertiary">{` · ${kind}`}</span> : null}
                    </span>
                    {existing && (
                      <span className="shrink-0 rounded-mini bg-muted px-1.5 py-0.5 text-[11px] leading-4 text-fg-secondary">
                        {roleLabels[existing.role]}
                      </span>
                    )}
                  </CommandItem>
                )
              })}
            </CommandList>
          )}
        </Command>
        {selectedAudience && (
          <div className="flex items-center justify-between gap-2 rounded-control bg-accent/60 px-2.5 py-1.5 text-sm">
            <span className="min-w-0 truncate font-medium">
              {selectedAudience.name}
              {subjectKindLabel(selectedAudience.kind) ? (
                <span className="font-normal text-fg-tertiary">{` · ${subjectKindLabel(selectedAudience.kind)}`}</span>
              ) : null}
            </span>
            <Button
              type="button"
              size="icon-xs"
              variant="ghost"
              aria-label={t('common.clear')}
              title={t('common.clear')}
              disabled={pending}
              onClick={() => setSelected('')}>
              <RiCloseLine aria-hidden className="size-3.5" />
            </Button>
          </div>
        )}
        <div className="flex items-center gap-2">
          <div className="min-w-0 flex-1">
            <Choice
              label={t('pod.content.permission_to_grant')}
              value={role}
              onChange={setRole}
              options={availableRoles}
              disabled={pending}
            />
          </div>
          <Button variant="outline" size="sm" disabled={pending || !selected} onClick={add}>
            {t('pod.content.add')}
          </Button>
        </div>
      </fieldset>
      {draft.grants.length > 0 && (
        <ul className="divide-y divide-border">
          {draft.grants.map((grant, index) => {
            const advanced = isAdvancedSharingRule(grant) || !(grant.role in availableRoles)
            const selfOnly = grant.target_scope === 'self'
            const kind = subjectKindLabel(grant.kind)
            const displayName =
              grant.kind === 'userset'
                ? grant.source_page?.accessible
                  ? grant.source_page.title || t('pod.content.untitled')
                  : t('pod.content.sharing_inaccessible_source')
                : grant.name || t('pod.content.members_with_access')
            return (
              <li key={index} className="grid gap-2 py-2.5 text-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
                    <span className="min-w-0 break-words">{displayName}</span>
                    {kind && <span className="text-xs text-fg-tertiary">{`· ${kind}`}</span>}
                    {selfOnly && (
                      <span className="rounded-mini bg-muted px-1.5 py-0.5 text-[11px] leading-4 text-fg-secondary">
                        {t('pod.content.sharing_scope_self')}
                      </span>
                    )}
                  </div>
                  <div className="flex shrink-0 items-center gap-1.5">
                    {!advanced && (
                      <Choice
                        label={t('pod.content.member_permission')}
                        value={grant.role}
                        disabled={pending}
                        onChange={nextRole => commit(() => model.update(index, { role: nextRole }))}
                        options={availableRoles}
                      />
                    )}
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={pending}
                      onClick={() => commit(() => model.remove(index))}>
                      {t('pod.content.remove')}
                    </Button>
                  </div>
                </div>
                {advanced && (
                  <div className="rounded-control bg-muted/60 p-2 text-xs text-fg-secondary">
                    <span>
                      {grant.actions?.map(action => actionLabels[action]).join(' · ') ?? roleLabels[grant.role]}
                    </span>
                    {grant.source_action && (
                      <span> · {actionLabels[grant.source_action as keyof typeof actionLabels]}</span>
                    )}
                    {(grant.condition ?? 'true') !== 'true' && (
                      <code className="mt-1 block break-words">{grant.condition}</code>
                    )}
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}
      <ContentError error={error} />
      {!!error && (
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={pending || sharing.isFetching}
            onClick={() => {
              void sharing.refetch().then(result => {
                if (result.data && !result.error) model.keepDraft(result.data.sharing_version)
              })
            }}>
            {t('pod.content.keep_my_settings_and_load_the_latest_version')}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            disabled={pending || sharing.isFetching}
            onClick={() => {
              void sharing.refetch().then(result => {
                if (result.data && !result.error) model.replace(result.data)
              })
            }}>
            {t('pod.content.discard_changes_and_load_the_latest_settings')}
          </Button>
        </div>
      )}
      {model.conflictReloaded.value && (
        <p role="status" className="text-sm">
          {t('pod.content.the_latest_version_is_loaded_saving_again_replaces_the_sharing')}
        </p>
      )}
      {!!error && (
        <div className="flex justify-end border-t border-border pt-3">
          <Button
            variant="outline"
            disabled={pending || sharing.isFetching}
            onClick={() => {
              const body = model.body()
              if (body) save(body)
            }}>
            {pending ? t('pod.content.saving') : t('pod.content.save_sharing_settings')}
          </Button>
        </div>
      )}
    </>
  )
}

export function useCopyPageLink(pageID: string) {
  const { pageHref } = useContent()
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(new URL(pageHref(pageID), window.location.origin).href)
      toast.success(t('pod.content.page_link_copied'))
    } catch {
      toast.error(t('pod.content.could_not_copy_the_link_copy_it_from_the_browser'))
    }
  }
  return copy
}

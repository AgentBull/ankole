import { t } from 'i18next'
import { Button, Checkbox, Popover, PopoverContent, PopoverTitle, PopoverTrigger, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useContent } from './content-context'
import { contentKeys, pageAPI, type PageRole, type PageSharing } from './content-api'
import { Choice, ContentError, roleLabels } from './content-primitives'

import type { PodSharing as Sharing } from '../common/api/generated/types.gen'

export function PageSharingButton({ pageID }: { pageID: string }) {
  const [open, setOpen] = useState(false)
  const client = useQueryClient()
  const write = useMutation({
    mutationFn: (draft: PageSharing) => pageAPI.share(pageID, draft),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setOpen(false)
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
        className="max-h-[min(70vh,var(--available-height))] w-[min(28rem,calc(100vw-2rem))] overflow-y-auto">
        <PopoverTitle>{t('pod.content.share_page')}</PopoverTitle>
        {open && (
          <SharingForm
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
  const sharing = useQuery({
    queryKey: contentKeys.sharing(pageID),
    queryFn: () => pageAPI.sharing(pageID)
  })
  const [draft, setDraft] = useState<Sharing>()
  const [conflictReloaded, setConflictReloaded] = useState(false)
  const [selected, setSelected] = useState('')
  const [role, setRole] = useState<PageRole>('view')
  useEffect(() => {
    if (sharing.data && !sharing.isFetching && !sharing.error && !draft) setDraft(sharing.data)
  }, [sharing.data, sharing.isFetching, sharing.error, draft])
  if (!draft) {
    return (
      <>
        <ContentError error={sharing.error} retry={() => void sharing.refetch()} />
        {!sharing.error && <p role="status">{t('pod.content.loading_sharing_settings')}</p>}
      </>
    )
  }
  const subjects = draft.subjects ?? []
  const subjectKey = (subject: { principal_uid?: string | null; group_id?: string | null }) =>
    subject.principal_uid ? `principal:${subject.principal_uid}` : `group:${subject.group_id}`
  const add = () => {
    const subject = subjects.find(subject => subjectKey(subject) === selected)
    if (!subject) return
    const grant = {
      principal_uid: subject.principal_uid ?? null,
      group_id: subject.group_id ?? null,
      role
    }
    setDraft({ ...draft, grants: [...draft.grants.filter(item => subjectKey(item) !== selected), grant] })
    setSelected('')
  }
  return (
    <>
      <label className="flex items-start gap-3 text-sm">
        <Checkbox
          checked={draft.inherit_permissions}
          disabled={pending}
          onCheckedChange={checked => setDraft({ ...draft, inherit_permissions: checked })}
        />
        <span>
          {t('pod.content.inherit_access_from_the_parent_page_or_space')}
          <br />
          <span className="text-xs text-fg-tertiary">
            {t('pod.content.when_off_only_the_members_explicitly_listed_below_can_access')}
          </span>
        </span>
      </label>
      <div className="flex flex-wrap items-end gap-2">
        <Choice
          label={t('pod.content.choose_a_member_group_or_agent')}
          value={selected}
          disabled={pending}
          onChange={setSelected}
          options={{
            '': t('pod.content.choose_a_member_group_or_agent'),
            ...Object.fromEntries(
              subjects.map(subject => [
                subjectKey(subject),
                t('pod.content.message', {
                  value1: subject.name,
                  value2: subject.kind === 'agent' ? ' · Agent' : subject.kind === 'group' ? t('pod.content.group') : ''
                })
              ])
            )
          }}
        />
        <Choice
          label={t('pod.content.permission_to_grant')}
          value={role}
          onChange={setRole}
          options={roleLabels}
          disabled={pending}
        />
        <Button variant="outline" size="sm" disabled={!selected || pending} onClick={add}>
          {t('pod.content.add')}
        </Button>
      </div>
      <ul className="max-h-64 divide-y divide-border overflow-auto">
        {draft.grants.map((grant, index) => (
          <li key={subjectKey(grant)} className="flex flex-wrap items-center gap-2 py-2 text-sm">
            <span className="min-w-0 flex-1 break-words">
              {subjects.find(subject => subjectKey(subject) === subjectKey(grant))?.name ??
                t('pod.content.members_with_access')}
            </span>
            <Choice
              label={t('pod.content.member_permission')}
              value={grant.role}
              disabled={pending}
              onChange={value =>
                setDraft({
                  ...draft,
                  grants: draft.grants.map((item, i) => (i === index ? { ...item, role: value } : item))
                })
              }
              options={roleLabels}
            />
            <Button
              size="sm"
              variant="ghost"
              disabled={pending}
              onClick={() => setDraft({ ...draft, grants: draft.grants.filter((_, i) => i !== index) })}>
              {t('pod.content.remove')}
            </Button>
          </li>
        ))}
      </ul>
      <ContentError error={error} />
      {!!error && (
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={pending || sharing.isFetching}
            onClick={() => {
              void sharing.refetch().then(result => {
                if (result.data && !result.error) {
                  setDraft(current => current && { ...current, sharing_version: result.data.sharing_version })
                  setConflictReloaded(true)
                }
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
                if (result.data && !result.error) {
                  setDraft(result.data)
                  setConflictReloaded(false)
                }
              })
            }}>
            {t('pod.content.discard_changes_and_load_the_latest_settings')}
          </Button>
        </div>
      )}
      {conflictReloaded && (
        <p role="status" className="text-sm">
          {t('pod.content.the_latest_version_is_loaded_saving_again_replaces_the_sharing')}
        </p>
      )}
      <div className="flex justify-end border-t border-border pt-3">
        <Button
          variant="outline"
          disabled={pending}
          onClick={() =>
            save({
              inherit_permissions: draft.inherit_permissions,
              grants: draft.grants,
              sharing_version: draft.sharing_version
            })
          }>
          {pending ? t('pod.content.saving') : t('pod.content.save_sharing_settings')}
        </Button>
      </div>
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

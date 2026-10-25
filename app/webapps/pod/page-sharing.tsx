import { t } from 'i18next'
import { Button, Checkbox, Input, Popover, PopoverContent, PopoverTitle, PopoverTrigger, toast } from '@ankole/uikit'
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
    page.data?.page.type === 'applet'
      ? { view: roleLabels.view, edit: roleLabels.edit, manage: roleLabels.manage }
      : roleLabels
  const [selected, setSelected] = useState('')
  const [role, setRole] = useState<PageRole>('view')
  const [scope, setScope] = useState('container')
  const [subjectQuery, setSubjectQuery] = useState('')
  useEffect(() => {
    if (sharing.data && !sharing.isFetching && !sharing.error) model.initialize(sharing.data)
  }, [sharing.data, sharing.isFetching, sharing.error, model])
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
  const subjects = (draft.subjects ?? []).filter(subject =>
    subject.name.toLocaleLowerCase().includes(subjectQuery.trim().toLocaleLowerCase())
  )
  const add = () => {
    const audience = draft.subjects.find(subject => subjectKey(subject) === selected)
    if (!audience) return
    model.add({ ...audience, role, target_scope: scope, condition: 'true' })
    setSelected('')
  }
  const scopeLabels = { container: t('pod.content.sharing_scope_container'), self: t('pod.content.sharing_scope_self') }
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
          onCheckedChange={checked => model.inherit(checked)}
        />
        <span>
          {t('pod.content.inherit_access_from_the_parent_page_or_space')}
          <br />
          <span className="text-xs text-fg-tertiary">
            {t('pod.content.when_off_only_the_members_explicitly_listed_below_can_access')}
          </span>
        </span>
      </label>
      <fieldset className="grid gap-3 rounded-control border border-border p-3" disabled={pending}>
        <legend className="px-1 text-sm">{t('pod.content.add_sharing_rule')}</legend>
        <Input
          aria-label={t('pod.content.search_collaborators')}
          value={subjectQuery}
          onChange={event => setSubjectQuery(event.target.value)}
          placeholder={t('pod.content.search_collaborators')}
        />
        <Choice
          label={t('pod.content.choose_a_member_group_or_agent')}
          value={selected}
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
        <Choice label={t('pod.content.permission_to_grant')} value={role} onChange={setRole} options={availableRoles} />
        <Choice label={t('pod.content.sharing_scope')} value={scope} onChange={setScope} options={scopeLabels} />
        <Button variant="outline" size="sm" disabled={pending || !selected} onClick={add}>
          {t('pod.content.add')}
        </Button>
      </fieldset>
      <ul className="divide-y divide-border">
        {draft.grants.map((grant, index) => (
          <li key={index} className="grid gap-2 py-3 text-sm">
            <div className="flex items-start justify-between gap-2">
              <span className="min-w-0 break-words">
                {grant.kind === 'userset'
                  ? grant.source_page?.accessible
                    ? grant.source_page.title || t('pod.content.untitled')
                    : t('pod.content.sharing_inaccessible_source')
                  : grant.name || t('pod.content.members_with_access')}
              </span>
              <Button size="sm" variant="ghost" disabled={pending} onClick={() => model.remove(index)}>
                {t('pod.content.remove')}
              </Button>
            </div>
            {isAdvancedSharingRule(grant) || !(grant.role in availableRoles) ? (
              <div className="rounded-control bg-bg-subtle p-2 text-xs text-fg-secondary">
                <span>
                  {grant.actions?.map(action => actionLabels[action]).join(' · ') ?? roleLabels[grant.role]} ·{' '}
                  {scopeLabels[(grant.target_scope ?? 'container') as keyof typeof scopeLabels]}
                </span>
                {grant.source_action && (
                  <span> · {actionLabels[grant.source_action as keyof typeof actionLabels]}</span>
                )}
                {(grant.condition ?? 'true') !== 'true' && (
                  <code className="mt-1 block break-words">{grant.condition}</code>
                )}
              </div>
            ) : (
              <>
                <Choice
                  label={t('pod.content.member_permission')}
                  value={grant.role}
                  disabled={pending}
                  onChange={role => model.update(index, { role })}
                  options={availableRoles}
                />
                <Choice
                  label={t('pod.content.sharing_scope')}
                  value={grant.target_scope ?? 'container'}
                  disabled={pending}
                  onChange={target_scope => model.update(index, { target_scope })}
                  options={scopeLabels}
                />
              </>
            )}
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

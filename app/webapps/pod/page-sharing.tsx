import { t } from 'i18next'
import {
  Button,
  Checkbox,
  Input,
  Textarea,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  toast
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useState } from 'react'
import { useContent } from './content-context'
import { contentKeys, pageAPI, type PageRole, type PageSharing } from './content-api'
import { Choice, ContentError, roleLabels } from './content-primitives'

import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { PageSharingModel } from './state/page-sharing'
import type { Page } from './content-api'

const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

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
  const [selected, setSelected] = useState('')
  const [kind, setKind] = useState<'subject' | 'userset'>('subject')
  const [source, setSource] = useState<Page>()
  const [sourceAction, setSourceAction] = useState('page_view')
  const [role, setRole] = useState<PageRole>('view')
  const [scope, setScope] = useState('container')
  const [condition, setCondition] = useState('true')
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
    const audience =
      kind === 'userset'
        ? source && {
            kind: 'userset' as const,
            name: source.title,
            source_page_id: source.id,
            source_action: sourceAction,
            source_page: { id: source.id, title: source.title, icon: source.icon, accessible: true }
          }
        : draft.subjects.find(subject => subjectKey(subject) === selected)
    if (!audience) return
    model.add({ ...audience, role, target_scope: scope, condition: condition.trim() || 'true' })
    setSelected('')
    setSource(undefined)
  }
  const scopeLabels = { container: t('pod.content.sharing_scope_container'), self: t('pod.content.sharing_scope_self') }
  const actionLabels = {
    page_view: t('pod.content.can_view'),
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
        <Choice<'subject' | 'userset'>
          label={t('pod.content.sharing_audience')}
          value={kind}
          onChange={setKind}
          options={{
            subject: t('pod.content.choose_a_member_group_or_agent'),
            userset: t('pod.content.sharing_userset')
          }}
        />
        {kind === 'subject' ? (
          <>
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
                      value2:
                        subject.kind === 'agent' ? ' · Agent' : subject.kind === 'group' ? t('pod.content.group') : ''
                    })
                  ])
                )
              }}
            />
          </>
        ) : (
          <>
            <Suspense fallback={<p role="status">{t('pod.content.loading')}</p>}>
              <PagePicker
                label={t('pod.content.sharing_source_page')}
                selected={source?.id}
                onSelect={(_id, page) => setSource(page)}
                disabled={pending}
              />
            </Suspense>
            {source && (
              <p className="text-sm" role="status">
                {source.title || t('pod.content.untitled')}
              </p>
            )}
            <Choice
              label={t('pod.content.sharing_source_action')}
              value={sourceAction}
              onChange={setSourceAction}
              options={actionLabels}
            />
          </>
        )}
        <Choice label={t('pod.content.permission_to_grant')} value={role} onChange={setRole} options={roleLabels} />
        <Choice label={t('pod.content.sharing_scope')} value={scope} onChange={setScope} options={scopeLabels} />
        <label className="grid gap-1 text-sm">
          <span>{t('pod.content.sharing_condition')}</span>
          <Textarea
            className="font-mono text-xs"
            value={condition}
            onChange={event => setCondition(event.target.value)}
          />
        </label>
        <Button
          variant="outline"
          size="sm"
          disabled={pending || (kind === 'userset' ? !source : !selected)}
          onClick={add}>
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
            {grant.kind === 'userset' && (
              <Choice
                label={t('pod.content.sharing_source_action')}
                value={grant.source_action ?? 'page_view'}
                disabled={pending}
                onChange={source_action => model.update(index, { source_action })}
                options={actionLabels}
              />
            )}
            <Choice
              label={t('pod.content.member_permission')}
              value={grant.role}
              disabled={pending}
              onChange={role => model.update(index, { role })}
              options={roleLabels}
            />
            <Choice
              label={t('pod.content.sharing_scope')}
              value={grant.target_scope ?? 'container'}
              disabled={pending}
              onChange={target_scope => model.update(index, { target_scope })}
              options={scopeLabels}
            />
            <label className="grid gap-1">
              <span>{t('pod.content.sharing_condition')}</span>
              <Textarea
                className="font-mono text-xs"
                value={grant.condition ?? 'true'}
                disabled={pending}
                onChange={event => model.update(index, { condition: event.target.value })}
              />
            </label>
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

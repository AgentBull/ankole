import {
  Avatar,
  AvatarFallback,
  AvatarImage,
  Badge,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiKey2Line } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAuthZGroupControllerAddMemberMutation,
  ankoleWebAuthZGroupControllerCreateMutation,
  ankoleWebAuthZGroupControllerDeleteMutation,
  ankoleWebAuthZGroupControllerGrantsOptions,
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebAuthZGroupControllerMembersOptions,
  ankoleWebAuthZGroupControllerPreviewComputedMembersMutation,
  ankoleWebAuthZGroupControllerRemoveMemberMutation,
  ankoleWebAuthZGroupControllerShowOptions,
  ankoleWebAuthZGroupControllerUpdateMutation,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { PrincipalGroupItem, PrincipalGroupMemberItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { AddMembershipPicker } from '../add-membership-picker'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { ConfirmDeleteButton, LabeledField, ReadOnlyValue, ResourceEditorPage } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import {
  PrincipalGroupEditorModel,
  type PrincipalGroupEditorDraft,
  type PrincipalGroupKind
} from '../state/principal-group-editor-model'
import { PermissionGrantsSection } from './permission-grant-editor'
import { AccessSubNav } from './principals'

export function PrincipalGroupsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const groups = useQuery(ankoleWebAuthZGroupControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (groups.data?.principal_groups ?? []).filter(group =>
    matchesResourceSearch(searchQuery, group.name, group.display_name, group.description, group.kind)
  )
  const deleteGroup = useMutation({
    ...ankoleWebAuthZGroupControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.principal_groups.deleted', { id: variables.path.name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.principal_groups.title')}
      description={t('console.principal_groups.description')}
      createTo="new"
      createLabel={t('console.principal_groups.new')}
      columns={[
        t('console.principal_groups.name'),
        t('console.principal_groups.display_name'),
        t('console.principal_groups.kind'),
        t('console.principal_groups.members'),
        t('console.principal_groups.grants'),
        t('console.principal_groups.description_label')
      ]}
      isLoading={groups.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.principal_groups.empty_title')}
      emptyIcon={<RiKey2Line aria-hidden />}
      emptyDescription={t('console.principal_groups.empty_description')}
      error={groups.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      count={rows.length}
      subNav={<AccessSubNav />}
      toolbar={
        <ResourceSearch
          label={t('console.principal_groups.search')}
          placeholder={t('console.principal_groups.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(group => {
        // The server also refuses (409) when a group still holds grants; the
        // toast surfaces that message for groups that pass this client-side gate.
        const canDelete = !group.built_in && group.domain === 'operator'
        return (
          <TableRow key={group.id}>
            <TableCell className="font-mono text-xs">
              <Link className="text-foreground hover:text-link hover:underline" to={encodeURIComponent(group.name)}>
                {group.name}
              </Link>
            </TableCell>
            <TableCell>{group.display_name}</TableCell>
            {/* The badges used to wrap inside a narrow column, so a row with two of
                them stood twice as tall as its neighbours and the list read as
                broken. The column widens instead; the table already scrolls. */}
            <TableCell className="whitespace-nowrap">
              <div className="flex items-center gap-1">
                <Badge variant="secondary">{t(`console.principal_groups.kind_${group.kind}`)}</Badge>
                {group.built_in ? <Badge variant="info">{t('console.principal_groups.built_in')}</Badge> : null}
                {group.domain !== 'operator' ? (
                  <Badge variant="outline">{t(`console.principal_groups.domain_${group.domain}`)}</Badge>
                ) : null}
              </div>
            </TableCell>
            <TableCell className="tabular-nums">{group.member_count}</TableCell>
            <TableCell className="tabular-nums">{group.grant_count}</TableCell>
            <TableCell>
              <span className="block max-w-64 truncate" title={group.description ?? undefined}>
                {group.description ?? '—'}
              </span>
            </TableCell>
            <RowActions
              editTo={encodeURIComponent(group.name)}
              editLabel={t('common.edit')}
              deletePending={deleteGroup.isPending}
              deleteConfirm={
                canDelete
                  ? {
                      title: t('console.principal_groups.delete_title'),
                      description: t('console.principal_groups.delete_description', { id: group.name }),
                      confirmLabel: t('common.delete')
                    }
                  : undefined
              }
              onDelete={canDelete ? () => deleteGroup.mutate({ path: { name: group.name } }) : undefined}
            />
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function PrincipalGroupEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(PrincipalGroupEditorModel)
  const params = useParams()
  const name = params.name
  const mode = name ? 'edit' : 'new'

  const group = useQuery({
    ...ankoleWebAuthZGroupControllerShowOptions({ path: { name: name ?? '' } }),
    enabled: Boolean(name)
  })
  const loadedGroup = group.data?.principal_group

  useEffect(() => {
    if (mode === 'new') model.initialize('new', emptyGroupForm())
    else if (loadedGroup) model.initialize(`group:${loadedGroup.name}`, formFromGroup(loadedGroup))
  }, [mode, model, loadedGroup])

  const refresh = () => void queryClient.invalidateQueries()
  const createGroup = useMutation({
    ...ankoleWebAuthZGroupControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.principal_groups.saved', { id: response.principal_group.name }))
      refresh()
      // Land on the new group's editor so members and grants can be managed next.
      navigate(`/access/groups/${encodeURIComponent(response.principal_group.name)}`)
    }
  })
  const updateGroup = useMutation({
    ...ankoleWebAuthZGroupControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.principal_groups.saved', { id: response.principal_group.name }))
      model.markSaved(formFromGroup(response.principal_group))
      refresh()
    }
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError(mode)
    if (draftError) {
      model.validationError.value = t(`console.principal_groups.${draftError}`)
      return
    }
    if (mode === 'new') {
      createGroup.mutate({ body: model.createBody() })
      return
    }
    if (loadedGroup) updateGroup.mutate({ body: model.updateBody(), path: { name: loadedGroup.name } })
  }

  const kind = model.kind.value
  // Built-in groups keep their seeded condition; the server ignores edits to it.
  const conditionReadOnly = Boolean(mode === 'edit' && loadedGroup?.built_in)

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.principal_groups.new') : (name ?? '')}
      description={t('console.principal_groups.editor_description')}
      backTo="/access/groups"
      error={
        model.validationError.value ?? createGroup.error ?? updateGroup.error ?? (mode === 'edit' ? group.error : null)
      }
      submitting={createGroup.isPending || updateGroup.isPending}
      submitDisabled={mode === 'edit' && !model.dirty.value}
      contentWidth={mode === 'edit' ? 'wide' : 'form'}
      supplementary={
        mode === 'edit' && loadedGroup ? (
          <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-10 border-t border-border pt-8 [&>*]:min-w-0">
            <GroupMembersSection group={loadedGroup} />
            <GroupGrantsSection group={loadedGroup} />
          </div>
        ) : null
      }
      onSubmit={submit}>
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        <LabeledField
          label={t('console.principal_groups.name')}
          description={mode === 'new' ? t('console.principal_groups.name_hint') : undefined}
          required={mode === 'new'}>
          {mode === 'edit' ? (
            <ReadOnlyValue mono>{model.name.value}</ReadOnlyValue>
          ) : (
            <Input
              required
              placeholder="research-ops"
              value={model.name.value}
              onChange={event => (model.name.value = event.target.value)}
            />
          )}
        </LabeledField>
        <LabeledField label={t('console.principal_groups.display_name')} required>
          <Input
            required
            value={model.displayName.value}
            onChange={event => (model.displayName.value = event.target.value)}
          />
        </LabeledField>
      </div>
      <LabeledField label={t('console.principal_groups.description_label')}>
        <Input value={model.description.value} onChange={event => (model.description.value = event.target.value)} />
      </LabeledField>
      <LabeledField
        label={t('console.principal_groups.kind')}
        description={mode === 'new' ? t('console.principal_groups.kind_hint') : undefined}>
        {mode === 'edit' ? (
          <ReadOnlyValue>{t(`console.principal_groups.kind_${kind}`)}</ReadOnlyValue>
        ) : (
          <Select value={kind} onValueChange={value => (model.kind.value = (value as PrincipalGroupKind) || 'static')}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="static">{t('console.principal_groups.kind_static')}</SelectItem>
              <SelectItem value="computed">{t('console.principal_groups.kind_computed')}</SelectItem>
            </SelectContent>
          </Select>
        )}
      </LabeledField>
      {kind === 'computed' ? (
        <LabeledField
          label={t('console.principal_groups.condition')}
          description={t('console.principal_groups.condition_hint')}
          required={!conditionReadOnly}>
          {conditionReadOnly ? (
            <ReadOnlyValue mono>{model.computedCondition.value}</ReadOnlyValue>
          ) : (
            <Textarea
              required
              className="min-h-10 font-mono text-xs"
              spellCheck={false}
              value={model.computedCondition.value}
              onChange={event => (model.computedCondition.value = event.target.value)}
            />
          )}
        </LabeledField>
      ) : null}
      {kind === 'computed' && !conditionReadOnly ? (
        <ComputedMembershipPreview condition={model.computedCondition.value} />
      ) : null}
    </ResourceEditorPage>
  )
}

/** Debounced live preview of the principals a CEL membership condition matches. */
function ComputedMembershipPreview({ condition }: { condition: string }) {
  const { t } = useTranslation()
  const preview = useMutation(ankoleWebAuthZGroupControllerPreviewComputedMembersMutation())
  const [result, setResult] = useState<{ condition: string; members?: PrincipalGroupMemberItem[]; error?: string }>()
  const trimmed = condition.trim()

  useEffect(() => {
    if (!trimmed) return
    let cancelled = false
    const timer = window.setTimeout(() => {
      preview
        .mutateAsync({ body: { condition: trimmed } })
        .then(data => {
          if (!cancelled) setResult({ condition: trimmed, members: data.principal_group_members })
        })
        .catch((error: unknown) => {
          if (!cancelled) setResult({ condition: trimmed, error: requestErrorMessage(error) })
        })
    }, 400)
    // Cleanup cancels stale in-flight requests, so an older response resolving
    // after a newer one can never overwrite the fresh result. `preview` is a
    // stable mutation handle; re-running only on the condition keeps the
    // debounce tied to typing, not to mutation state changes.
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [trimmed])

  // Results only render for the condition they were requested with; typing
  // between requests shows the pending skeleton instead of stale matches.
  const fresh = result?.condition === trimmed
  const shown = (fresh ? (result.members ?? []) : []).slice(0, 10)

  return (
    <div className="grid gap-3 border border-border bg-muted/30 p-4" aria-live="polite">
      <p className="text-sm font-medium">{t('console.principal_groups.condition_preview_title')}</p>
      {!trimmed ? (
        <p className="text-sm text-muted-foreground">{t('console.principal_groups.condition_preview_idle')}</p>
      ) : !fresh ? (
        <Skeleton className="h-6 w-2/3" />
      ) : result.error ? (
        <p className="text-sm break-all text-destructive">{result.error}</p>
      ) : (
        <div className="grid gap-2">
          <p className="text-sm text-muted-foreground">
            {t('console.principal_groups.condition_preview_matches', { count: result.members?.length ?? 0 })}
          </p>
          {shown.length > 0 ? (
            <div className="flex flex-wrap items-center gap-2">
              {shown.map(member => (
                <span
                  key={member.uid}
                  className="inline-flex items-center gap-1.5 border border-border bg-card px-2 py-1 text-xs">
                  <MemberAvatar member={member} />
                  <span className="max-w-40 truncate">{member.display_name ?? member.uid}</span>
                </span>
              ))}
              {(result.members?.length ?? 0) > shown.length ? (
                <span className="text-xs text-muted-foreground">
                  {t('console.principal_groups.condition_preview_more', {
                    count: (result.members?.length ?? 0) - shown.length
                  })}
                </span>
              ) : null}
            </div>
          ) : null}
        </div>
      )}
    </div>
  )
}

/**
 * Members section of the group editor. Static operator groups manage stored
 * memberships here; computed groups show the evaluated membership read-only;
 * directory/im_group groups are owned by external sync and skip the endpoint.
 */
function GroupMembersSection({ group }: { group: PrincipalGroupItem }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const synced = group.domain !== 'operator'
  const manageable = !synced && group.kind === 'static'
  const members = useQuery({
    ...ankoleWebAuthZGroupControllerMembersOptions({ path: { name: group.name } }),
    enabled: !synced
  })
  // Candidates feed the add picker, so only manageable groups fetch them.
  const principals = useQuery({
    ...ankoleWebPrincipalControllerIndexOptions(),
    enabled: manageable
  })
  const memberList = members.data?.principal_group_members ?? []

  const addMember = useMutation({
    ...ankoleWebAuthZGroupControllerAddMemberMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.principal_groups.member_added', { id: variables.path.principal_uid }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeMember = useMutation({
    ...ankoleWebAuthZGroupControllerRemoveMemberMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.principal_groups.member_removed', { id: variables.path.principal_uid }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.principal_groups.members_section_title')}</h3>
        <p className="max-w-2xl text-sm leading-6 text-muted-foreground">
          {synced
            ? t('console.principal_groups.members_synced_note')
            : group.kind === 'computed'
              ? t('console.principal_groups.members_computed_note')
              : t('console.principal_groups.members_section_description')}
        </p>
      </div>
      {synced ? null : (
        <>
          {manageable ? (
            <AddMembershipPicker
              ariaLabel={t('console.principal_groups.add_member')}
              placeholder={t('console.principal_groups.add_member_placeholder')}
              emptyText={t('console.principal_groups.add_member_empty')}
              candidates={(principals.data?.principals ?? []).map(principal => ({
                id: principal.uid,
                label: principal.display_name
              }))}
              excludedIDs={new Set(memberList.map(member => member.uid))}
              error={principals.error}
              isLoading={principals.isLoading}
              pending={addMember.isPending}
              onAdd={uid => addMember.mutate({ path: { name: group.name, principal_uid: uid } })}
            />
          ) : null}
          <ErrorBlock error={members.error} />
          {!members.error && !members.isLoading && memberList.length === 0 ? (
            <p className="border border-border bg-card p-6 text-sm text-muted-foreground">
              {t('console.principal_groups.members_empty')}
            </p>
          ) : !members.error ? (
            <div className="overflow-x-auto border border-border bg-card">
              <Table className="min-w-[560px]" aria-busy={members.isLoading}>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('console.principal_groups.member')}</TableHead>
                    <TableHead>{t('console.principal_groups.uid')}</TableHead>
                    <TableHead>{t('console.principal_groups.member_since')}</TableHead>
                    {manageable ? (
                      <TableHead className="w-0 text-right">
                        <span className="sr-only">{t('console.actions')}</span>
                      </TableHead>
                    ) : null}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {members.isLoading ? (
                    <TableRow>
                      <TableCell colSpan={manageable ? 4 : 3}>
                        <div className="grid gap-2">
                          <Skeleton className="h-6 w-full" />
                          <Skeleton className="h-6 w-4/5" />
                        </div>
                      </TableCell>
                    </TableRow>
                  ) : (
                    memberList.map(member => (
                      <TableRow key={member.uid}>
                        <TableCell>
                          <div className="flex items-center gap-2">
                            <MemberAvatar member={member} />
                            <span className="truncate">{member.display_name ?? member.uid}</span>
                          </div>
                        </TableCell>
                        <TableCell className="font-mono text-xs">{member.uid}</TableCell>
                        <TableCell>{formatConsoleDate(member.member_since)}</TableCell>
                        {manageable ? (
                          <TableCell className="w-12 text-right">
                            <ConfirmDeleteButton
                              pending={removeMember.isPending}
                              confirm={{
                                title: t('console.principal_groups.remove_member_title'),
                                description: t('console.principal_groups.remove_member_description', {
                                  id: member.uid
                                }),
                                confirmLabel: t('console.principal_groups.remove_member')
                              }}
                              onConfirm={() =>
                                removeMember.mutate({ path: { name: group.name, principal_uid: member.uid } })
                              }
                            />
                          </TableCell>
                        ) : null}
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </div>
          ) : null}
        </>
      )}
    </section>
  )
}

/** Grant table for the group editor, fed by the group grants endpoint. */
function GroupGrantsSection({ group }: { group: PrincipalGroupItem }) {
  const { t } = useTranslation()
  const grants = useQuery(ankoleWebAuthZGroupControllerGrantsOptions({ path: { name: group.name } }))

  return (
    <PermissionGrantsSection
      title={t('console.principal_groups.grants_section_title')}
      description={t('console.principal_groups.grants_section_description')}
      addLabel={t('console.principal_groups.add_grant')}
      addTo={`/access/groups/${encodeURIComponent(group.name)}/grants/new`}
      empty={t('console.principal_groups.grants_empty')}
      error={grants.error}
      grants={grants.data?.permission_grants ?? []}
      isLoading={grants.isLoading}
    />
  )
}

function MemberAvatar({ member }: { member: PrincipalGroupMemberItem }) {
  return (
    <Avatar size="sm">
      {member.avatar_url ? <AvatarImage src={member.avatar_url} alt="" /> : null}
      <AvatarFallback>{(member.display_name ?? member.uid).slice(0, 1).toUpperCase()}</AvatarFallback>
    </Avatar>
  )
}

function emptyGroupForm(): PrincipalGroupEditorDraft {
  return { name: '', displayName: '', description: '', kind: 'static', computedCondition: '' }
}

function formFromGroup(group: PrincipalGroupItem): PrincipalGroupEditorDraft {
  return {
    name: group.name,
    displayName: group.display_name,
    description: group.description ?? '',
    kind: group.kind,
    computedCondition: group.computed_condition ?? ''
  }
}

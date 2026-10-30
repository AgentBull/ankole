import { TableRow, useMutation, useQuery, Link, useNavigate } from '../tenant-context'
import {
  Badge,
  buttonVariants,
  cn,
  Input,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  Textarea,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useParams } from '@tanstack/react-router'
import {
  createPermissionGrantMutation,
  deletePermissionGrantMutation,
  getPermissionGrantOptions,
  getPrincipalOptions,
  listPrincipalGroupsOptions,
  updatePermissionGrantMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { GetPermissionGrantResponse, PermissionGrant } from '../api/v2/generated/types.gen'
import { type Flat, fromDocument } from '../api/json-api'
import { requestErrorCode, requestErrorDetailList, requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../../common/error-block'
import { EditorNotFound, LabeledField, ReadOnlyValue, ResourceEditorPage } from '../console-form'
import { RowActions } from '../console-list-page'
import { principalGroupDisplayName } from '../state/principal-group-text'
import { principalLabel } from '../state/principal-label'
import {
  PermissionGrantEditorModel,
  type PermissionGrantEditorDraft,
  type PermissionGrantOwner
} from '../state/permission-grant-editor-model'
import { useEditorDraft } from '../use-editor-draft'

/** The flat Console record of a permission grant. */
export type PermissionGrantRecord = Flat<PermissionGrant>

/**
 * Grants table shared by the group editor and the principal detail page: one
 * row per grant with edit/delete row actions and an add link into the editor.
 */
export function PermissionGrantsSection({
  addLabel,
  addTo,
  description,
  empty,
  error,
  grants,
  isLoading,
  title
}: {
  addLabel: string
  addTo: string
  description: string
  empty: string
  error?: unknown
  grants: PermissionGrantRecord[]
  isLoading: boolean
  title: string
}) {
  const { t } = useTranslation()
  const deleteGrant = useMutation({
    ...deletePermissionGrantMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.deleted'))
    },
    onError: error =>
      toast.error(
        requestErrorCode(error) === 'page_grant'
          ? t('console.permission_grants.error_page_grant')
          : requestErrorMessage(error)
      )
  })

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="grid gap-1">
          <h3 className="title-section">{title}</h3>
          <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p>
        </div>
        <Link to={addTo} className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}>
          {addLabel}
        </Link>
      </div>
      <ErrorBlock error={error} />
      {!error && !isLoading && grants.length === 0 ? (
        <p className="border border-border bg-card p-6 text-sm text-muted-foreground">{empty}</p>
      ) : !error ? (
        <div className="overflow-x-auto border border-border bg-card">
          <Table className="min-w-[720px]" aria-busy={isLoading}>
            <TableHeader>
              <TableRow>
                <TableHead>{t('console.permission_grants.resource_pattern')}</TableHead>
                <TableHead>{t('console.permission_grants.action')}</TableHead>
                <TableHead>{t('console.permission_grants.condition')}</TableHead>
                <TableHead>{t('console.permission_grants.description')}</TableHead>
                <TableHead className="w-0 text-right">
                  <span className="sr-only">{t('console.actions')}</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                <TableRow>
                  <TableCell colSpan={5}>
                    <div className="grid gap-2">
                      <Skeleton className="h-6 w-full" />
                      <Skeleton className="h-6 w-4/5" />
                    </div>
                  </TableCell>
                </TableRow>
              ) : (
                grants.map(grant => (
                  <TableRow key={grant.id}>
                    <TableCell className="font-mono text-xs">{grant.resource_pattern}</TableCell>
                    <TableCell>
                      <Badge variant="secondary">{grant.action}</Badge>
                    </TableCell>
                    <TableCell>
                      <span className="block max-w-56 truncate font-mono text-xs" title={grant.condition}>
                        {grant.condition}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span className="block max-w-64 truncate" title={grant.description ?? undefined}>
                        {grant.description ?? '—'}
                      </span>
                    </TableCell>
                    <RowActions
                      editTo={`/access/grants/${encodeURIComponent(grant.id)}`}
                      editLabel={t('common.edit')}
                      deletePending={deleteGrant.isPending}
                      deleteConfirm={{
                        title: t('console.permission_grants.delete_title'),
                        description: t('console.permission_grants.delete_description', {
                          pattern: grant.resource_pattern,
                          action: grant.action
                        }),
                        confirmLabel: t('common.delete')
                      }}
                      onDelete={() => deleteGrant.mutate({ path: { id: grant.id } })}
                    />
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </div>
      ) : null}
    </section>
  )
}

/**
 * Grant editor for both create (owner arrives as a route param via `createFor`)
 * and edit (`/access/grants/:grantID`, owner resolved from the loaded grant).
 */
export function PermissionGrantEditorPage({ createFor }: { createFor?: 'group' | 'principal' }) {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(PermissionGrantEditorModel)
  const params = useParams({ strict: false })
  const grantID = params.grantID
  const mode = grantID ? 'edit' : 'new'

  const owner: PermissionGrantOwner | undefined =
    mode === 'new' && createFor === 'group' && params.name
      ? { groupName: params.name }
      : mode === 'new' && createFor === 'principal' && params.uid
        ? { principalUID: params.uid }
        : undefined

  const grant = useQuery(permissionGrantDetailOptions(grantID ?? ''))
  const loadedGrant = grant.data
  // The edit-mode back link and owner label need the owning group's name, which
  // only the groups index carries (the grant itself stores the opaque group id).
  const groups = useQuery({
    ...listPrincipalGroupsOptions(),
    select: data => fromDocument(data),
    enabled: Boolean(loadedGrant?.group_id || (owner && 'groupName' in owner))
  })
  const ownerGroup = loadedGrant?.group_id
    ? groups.data?.find(group => group.id === loadedGrant.group_id)
    : owner && 'groupName' in owner
      ? groups.data?.find(group => group.name === owner.groupName)
      : undefined
  const ownerGroupName = ownerGroup?.name
  const targetPrincipalUID = owner && 'principalUID' in owner ? owner.principalUID : (loadedGrant?.principal_uid ?? '')
  const ownerPrincipal = useQuery({
    ...getPrincipalOptions({ path: { uid: targetPrincipalUID } }),
    select: data => fromDocument(data),
    enabled: Boolean(targetPrincipalUID),
    retry: false
  })
  const grantDraft = useMemo(
    () => (mode === 'new' ? emptyGrantForm() : loadedGrant ? formFromGrant(loadedGrant) : undefined),
    [loadedGrant, mode]
  )
  const draftStatus = useEditorDraft(model, {
    sourceKey: grantID ? `grant:${grantID}` : 'new',
    source: grantDraft,
    absent: () => mode === 'edit' && requestErrorCode(grant.error) === 'not_found'
  })

  const backTo = ownerBackTo(owner) ?? grantBackTo(loadedGrant, ownerGroupName)
  const resolvedPrincipalLabel = ownerPrincipal.data ? principalLabel(ownerPrincipal.data) : targetPrincipalUID
  const ownerLabel = owner
    ? 'groupName' in owner
      ? t('console.permission_grants.owner_group', {
          id: ownerGroup ? principalGroupDisplayName(t, ownerGroup) : owner.groupName
        })
      : t('console.permission_grants.owner_principal', { id: resolvedPrincipalLabel })
    : loadedGrant
      ? loadedGrant.group_id
        ? t('console.permission_grants.owner_group', {
            id: ownerGroup ? principalGroupDisplayName(t, ownerGroup) : (loadedGrant.group_id ?? '')
          })
        : t('console.permission_grants.owner_principal', { id: resolvedPrincipalLabel })
      : ''

  const createGrant = useMutation({
    ...createPermissionGrantMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.saved'))

      void navigate({ to: backTo })
    }
  })
  const updateGrant = useMutation({
    ...updatePermissionGrantMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.saved'))
    }
  })
  const mutationError = createGrant.error ?? updateGrant.error
  const serverFieldError = (field: string) => {
    const message = requestErrorDetailList(mutationError).find(detail => detail.path === field)?.message
    return typeof message === 'string' ? message : undefined
  }

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError()
    if (draftError) {
      model.validationError.value = t(`console.permission_grants.${draftError}`)
      return
    }
    if (mode === 'new') {
      if (owner) {
        createGrant.mutate({ body: { data: { type: 'permission_grant', attributes: model.createBody(owner) } } })
      }
      return
    }
    if (grantID) {
      const submission = {
        resourcePattern: model.resourcePattern.value,
        action: model.action.value,
        condition: model.condition.value,
        description: model.description.value
      }
      updateGrant.mutate(
        {
          body: { data: { type: 'permission_grant', id: grantID, attributes: model.updateBody() } },
          path: { id: grantID }
        },
        { onSuccess: () => model.markSaved(submission) }
      )
    }
  }

  // A stale or hand-typed grant link must state that the grant is gone, not
  // render an editable form under a red request failure. This is a show
  // endpoint, so a missing grant arrives as a 404 rather than an empty result;
  // any other failure keeps its own error on the form below.
  if (draftStatus === 'absent') {
    return <EditorNotFound backTo={backTo} message={t('console.not_found.description')} />
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.permission_grants.new') : t('console.permission_grants.edit')}
      description={t('console.permission_grants.editor_description')}
      backTo={backTo}
      dirty={model.dirty.value}
      validationError={model.validationError.value}
      error={mutationError ?? (mode === 'edit' ? grant.error : undefined)}
      submitting={createGrant.isPending || updateGrant.isPending}
      submitDisabled={mode === 'edit' && !model.dirty.value}
      submitUnavailable={draftStatus !== 'ready'}
      onSubmit={submit}>
      <LabeledField label={t('console.permission_grants.owner')}>
        <ReadOnlyValue mono>{ownerLabel}</ReadOnlyValue>
      </LabeledField>
      <LabeledField
        label={t('console.permission_grants.resource_pattern')}
        description={t('console.permission_grants.resource_pattern_hint')}
        error={serverFieldError('resource_pattern')}
        required>
        <Input
          aria-invalid={serverFieldError('resource_pattern') ? true : undefined}
          required
          className="font-mono text-xs"
          placeholder="site_console:**"
          spellCheck={false}
          value={model.resourcePattern.value}
          onChange={event => (model.resourcePattern.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField
        label={t('console.permission_grants.action')}
        description={t('console.permission_grants.action_hint')}
        error={serverFieldError('action')}
        required>
        <Input
          aria-invalid={serverFieldError('action') ? true : undefined}
          required
          placeholder="read"
          spellCheck={false}
          value={model.action.value}
          onChange={event => (model.action.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField
        label={t('console.permission_grants.condition')}
        description={t('console.permission_grants.condition_hint')}
        error={serverFieldError('condition')}>
        {/* A CEL condition is usually one short expression. The field starts at
            the height of its sibling inputs and grows with the expression, so
            its underline sits under the text instead of an empty box. */}
        <Textarea
          aria-invalid={serverFieldError('condition') ? true : undefined}
          className="min-h-8 font-mono text-xs"
          spellCheck={false}
          value={model.condition.value}
          onChange={event => (model.condition.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.permission_grants.description')} error={serverFieldError('description')}>
        <Input value={model.description.value} onChange={event => (model.description.value = event.target.value)} />
      </LabeledField>
    </ResourceEditorPage>
  )
}

export function permissionGrantDetailOptions(grantID: string) {
  return {
    ...getPermissionGrantOptions({ path: { id: grantID } }),
    select: (data: GetPermissionGrantResponse) => fromDocument(data),
    enabled: Boolean(grantID),
    refetchOnMount: 'always' as const
  }
}

function ownerBackTo(owner: PermissionGrantOwner | undefined): string | undefined {
  if (!owner) return undefined
  return 'groupName' in owner
    ? `/access/groups/${encodeURIComponent(owner.groupName)}`
    : `/access/principals/${encodeURIComponent(owner.principalUID)}`
}

function grantBackTo(grant: PermissionGrantRecord | undefined, groupName: string | undefined): string {
  if (grant?.group_id) {
    return groupName ? `/access/groups/${encodeURIComponent(groupName)}` : '/access/groups'
  }
  if (grant?.principal_uid) return `/access/principals/${encodeURIComponent(String(grant.principal_uid))}`
  return '/access/groups'
}

function emptyGrantForm(): PermissionGrantEditorDraft {
  return { resourcePattern: '', action: '', condition: 'true', description: '' }
}

function formFromGrant(grant: PermissionGrantRecord): PermissionGrantEditorDraft {
  return {
    resourcePattern: grant.resource_pattern,
    action: grant.action,
    condition: grant.condition,
    description: grant.description ?? ''
  }
}

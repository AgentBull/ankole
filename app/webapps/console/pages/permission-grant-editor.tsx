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
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebPermissionGrantControllerCreateMutation,
  ankoleWebPermissionGrantControllerDeleteMutation,
  ankoleWebPermissionGrantControllerShowOptions,
  ankoleWebPermissionGrantControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { PermissionGrantItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../console-primitives'
import { LabeledField, ReadOnlyValue, ResourceEditorPage } from '../console-form'
import { RowActions } from '../console-list-page'
import {
  PermissionGrantEditorModel,
  type PermissionGrantEditorDraft,
  type PermissionGrantOwner
} from '../state/permission-grant-editor-model'

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
  grants: PermissionGrantItem[]
  isLoading: boolean
  title: string
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const deleteGrant = useMutation({
    ...ankoleWebPermissionGrantControllerDeleteMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.deleted'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="grid gap-1">
          <h3 className="text-lg font-semibold tracking-normal">{title}</h3>
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
  const queryClient = useQueryClient()
  const model = useModel(PermissionGrantEditorModel)
  const params = useParams()
  const grantID = params.grantID
  const mode = grantID ? 'edit' : 'new'

  const owner: PermissionGrantOwner | undefined =
    mode === 'new' && createFor === 'group' && params.name
      ? { groupName: decodeURIComponent(params.name) }
      : mode === 'new' && createFor === 'principal' && params.uid
        ? { principalUID: decodeURIComponent(params.uid) }
        : undefined

  const grant = useQuery({
    ...ankoleWebPermissionGrantControllerShowOptions({ path: { id: grantID ?? '' } }),
    enabled: Boolean(grantID)
  })
  const loadedGrant = grant.data?.permission_grant
  // The edit-mode back link and owner label need the owning group's name, which
  // only the groups index carries (the grant itself stores the opaque group id).
  const groups = useQuery({
    ...ankoleWebAuthZGroupControllerIndexOptions(),
    enabled: Boolean(loadedGrant?.group_id)
  })
  const ownerGroupName = loadedGrant?.group_id
    ? groups.data?.principal_groups.find(group => group.id === loadedGrant.group_id)?.name
    : undefined

  useEffect(() => {
    if (mode === 'new') model.initialize('new', emptyGrantForm())
    else if (loadedGrant) model.initialize(`grant:${loadedGrant.id}`, formFromGrant(loadedGrant))
  }, [mode, model, loadedGrant])

  const backTo = ownerBackTo(owner) ?? grantBackTo(loadedGrant, ownerGroupName)
  const ownerLabel = owner
    ? 'groupName' in owner
      ? t('console.permission_grants.owner_group', { id: owner.groupName })
      : t('console.permission_grants.owner_principal', { id: owner.principalUID })
    : loadedGrant
      ? loadedGrant.group_id
        ? t('console.permission_grants.owner_group', { id: ownerGroupName ?? loadedGrant.group_id })
        : t('console.permission_grants.owner_principal', { id: loadedGrant.principal_uid ?? '' })
      : ''

  const refresh = () => void queryClient.invalidateQueries()
  const createGrant = useMutation({
    ...ankoleWebPermissionGrantControllerCreateMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.saved'))
      refresh()
      navigate(backTo)
    }
  })
  const updateGrant = useMutation({
    ...ankoleWebPermissionGrantControllerUpdateMutation(),
    onSuccess: () => {
      toast.success(t('console.permission_grants.saved'))
      refresh()
    }
  })
  const mutationError = createGrant.error ?? updateGrant.error
  const serverFieldError = (field: string) =>
    mutationError?.error.details?.find(detail => detail.path === field)?.message

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError()
    if (draftError) {
      model.validationError.value = t(`console.permission_grants.${draftError}`)
      return
    }
    if (mode === 'new') {
      if (owner) createGrant.mutate({ body: model.createBody(owner) })
      return
    }
    if (grantID) updateGrant.mutate({ body: model.updateBody(), path: { id: grantID } })
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.permission_grants.new') : t('console.permission_grants.edit')}
      description={t('console.permission_grants.editor_description')}
      backTo={backTo}
      error={model.validationError.value ?? mutationError ?? (mode === 'edit' ? grant.error : undefined)}
      submitting={createGrant.isPending || updateGrant.isPending}
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
          className="font-mono text-xs"
          placeholder="workspace:**"
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
        <Textarea
          aria-invalid={serverFieldError('condition') ? true : undefined}
          className="font-mono text-xs"
          spellCheck={false}
          style={{ minHeight: '6rem' }}
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

function ownerBackTo(owner: PermissionGrantOwner | undefined): string | undefined {
  if (!owner) return undefined
  return 'groupName' in owner
    ? `/access/groups/${encodeURIComponent(owner.groupName)}`
    : `/access/principals/${encodeURIComponent(owner.principalUID)}`
}

function grantBackTo(grant: PermissionGrantItem | undefined, groupName: string | undefined): string {
  if (grant?.group_id) {
    return groupName ? `/access/groups/${encodeURIComponent(groupName)}` : '/access/groups'
  }
  if (grant?.principal_uid) return `/access/principals/${encodeURIComponent(grant.principal_uid)}`
  return '/access/groups'
}

function emptyGrantForm(): PermissionGrantEditorDraft {
  return { resourcePattern: '', action: '', condition: 'true', description: '' }
}

function formFromGrant(grant: PermissionGrantItem): PermissionGrantEditorDraft {
  return {
    resourcePattern: grant.resource_pattern,
    action: grant.action,
    condition: grant.condition,
    description: grant.description ?? ''
  }
}

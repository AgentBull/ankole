import {
  Badge,
  Alert,
  AlertDescription,
  AlertTitle,
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Field,
  FieldDescription,
  FieldLabel,
  Input,
  Switch,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiTerminalBoxLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import {
  ankoleWebWorkerEnvControllerDecryptTenantMutation,
  ankoleWebWorkerEnvControllerDecryptMutation,
  ankoleWebWorkerEnvControllerDeleteTenantMutation,
  ankoleWebWorkerEnvControllerDeleteMutation,
  ankoleWebWorkerEnvControllerIndexTenantOptions,
  ankoleWebWorkerEnvControllerIndexOptions,
  ankoleWebWorkerEnvControllerUpdateTenantMutation,
  ankoleWebWorkerEnvControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { WorkerEnvItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { blankToNull } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput, isEncryptedValueMask } from '../encrypted-value-input'
import { ConfirmDeleteButton, EditorNotFound, LabeledField, ResourceEditorPage } from '../console-form'
import { ResourceListPage, ResourceSearch } from '../console-list-page'
import { WorkerEnvEditorModel } from '../state/worker-env-editor-model'
import { workerEnvValueText } from '../state/worker-env-visibility'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useEditorDraft } from '../use-editor-draft'

export const WORKER_ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

const WORKER_ENV_API = {
  global: {
    index: ankoleWebWorkerEnvControllerIndexOptions,
    update: ankoleWebWorkerEnvControllerUpdateMutation,
    remove: ankoleWebWorkerEnvControllerDeleteMutation,
    decrypt: ankoleWebWorkerEnvControllerDecryptMutation
  },
  tenant: {
    index: ankoleWebWorkerEnvControllerIndexTenantOptions,
    update: ankoleWebWorkerEnvControllerUpdateTenantMutation,
    remove: ankoleWebWorkerEnvControllerDeleteTenantMutation,
    decrypt: ankoleWebWorkerEnvControllerDecryptTenantMutation
  }
} as const

export function WorkerEnvSourceBadge({ source }: { source: WorkerEnvItem['source'] }) {
  const { t } = useTranslation()
  return <Badge variant={source === 'agent' ? 'info' : 'outline'}>{t(`console.worker_envs.source_${source}`)}</Badge>
}

export function WorkerEnvPlaintextWarning({ compact = false }: { compact?: boolean }) {
  const { t } = useTranslation()
  if (compact) {
    return (
      <p className="text-xs leading-5 text-warning-foreground" role="note">
        {t('console.worker_envs.plaintext_warning_description')}
      </p>
    )
  }

  return (
    <Alert>
      <AlertTitle>{t('console.worker_envs.plaintext_warning_title')}</AlertTitle>
      <AlertDescription>{t('console.worker_envs.plaintext_warning_description')}</AlertDescription>
    </Alert>
  )
}

export function WorkerEnvPlaintextConfirmDialog({
  open,
  pending,
  onConfirm,
  onOpenChange
}: {
  open: boolean
  pending: boolean
  onConfirm: () => void
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation()
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.worker_envs.plaintext_confirm_title')}</DialogTitle>
          <DialogDescription>{t('console.worker_envs.plaintext_confirm_description')}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <DialogClose render={<Button size="sm" variant="ghost" />}>{t('common.cancel')}</DialogClose>
          <Button disabled={pending} size="sm" type="button" variant="destructive" onClick={onConfirm}>
            {t('console.worker_envs.plaintext_confirm_action')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function WorkerEnvsListPage() {
  const { t } = useTranslation()
  const globalList = useQuery(ankoleWebWorkerEnvControllerIndexOptions())
  const tenantList = useQuery(ankoleWebWorkerEnvControllerIndexTenantOptions())
  const globalItems = new Map((globalList.data?.worker_envs ?? []).map(item => [item.name, item]))
  const tenantItems = new Map((tenantList.data?.worker_envs ?? []).map(item => [item.name, item]))
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const allItems = [...new Map([...globalItems, ...tenantItems]).values()].sort((a, b) => a.name.localeCompare(b.name))
  const items = searchQuery
    ? allItems.filter(item =>
        matchesResourceSearch(
          searchQuery,
          item.name,
          item.description,
          ...[globalItems.get(item.name), tenantItems.get(item.name)].flatMap(value =>
            value
              ? [
                  value.source,
                  t(`console.worker_envs.source_${value.source}`),
                  value.secret ? t('console.worker_envs.secret') : ''
                ]
              : []
          )
        )
      )
    : allItems

  return (
    <ResourceListPage
      title={t('console.worker_envs.title')}
      description={t('console.worker_envs.description')}
      createAction={
        <div className="flex gap-2">
          <Button render={<Link to="new?scope=global" />} size="sm" variant="outline">
            {t('console.worker_envs.new_global')}
          </Button>
          <Button render={<Link to="new?scope=tenant" />} size="sm">
            {t('console.worker_envs.new_tenant')}
          </Button>
        </div>
      }
      columns={[t('console.worker_envs.name'), t('console.settings.scope_global'), t('console.settings.scope_tenant')]}
      isLoading={globalList.isLoading || tenantList.isLoading}
      isEmpty={items.length === 0}
      count={items.length}
      emptyTitle={t('console.worker_envs.empty_title')}
      emptyIcon={<RiTerminalBoxLine aria-hidden />}
      error={globalList.error ?? tenantList.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.worker_envs.search')}
          placeholder={t('console.worker_envs.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {items.map(item => (
        <TableRow key={item.name}>
          <TableCell className="max-w-[360px] whitespace-normal">
            <div className="grid gap-1.5">
              <span className="break-all font-mono text-xs">{item.name}</span>
              <span className="text-xs leading-5 text-muted-foreground">{item.description}</span>
            </div>
          </TableCell>
          <WorkerEnvValueCell item={globalItems.get(item.name)} scope="global" />
          <WorkerEnvValueCell item={tenantItems.get(item.name)} scope="tenant" />
          <TableCell />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function WorkerEnvValueCell({ item, scope }: { item?: WorkerEnvItem; scope: 'global' | 'tenant' }) {
  const { t } = useTranslation()
  if (!item) return <TableCell className="text-muted-foreground">—</TableCell>
  return (
    <TableCell className="max-w-72 whitespace-normal">
      <div className="grid gap-1.5">
        <code className="line-clamp-3 break-all text-xs">{workerEnvValueText(item)}</code>
        <div className="flex flex-wrap items-center gap-2">
          <WorkerEnvSourceBadge source={item.source} />
          {item.secret ? <Badge variant="info">{t('console.worker_envs.secret')}</Badge> : null}
          <Link className="link text-xs" to={`${encodeURIComponent(item.name)}?scope=${scope}`}>
            {t('common.edit')}
          </Link>
        </div>
      </div>
    </TableCell>
  )
}

export function WorkerEnvEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(WorkerEnvEditorModel)
  const params = useParams()
  const [searchParams] = useSearchParams()
  const scope = searchParams.get('scope') === 'global' ? 'global' : 'tenant'
  const api = WORKER_ENV_API[scope]
  const name = params.name
  const mode = name ? 'edit' : 'new'
  const [plaintextConfirmOpen, setPlaintextConfirmOpen] = useState(false)

  const list = useQuery(api.index())
  const item = name ? list.data?.worker_envs.find(entry => entry.name === name) : undefined
  const workerEnvDraft = useMemo(() => {
    if (mode === 'new') return { name: '', value: '', secret: true, description: '' }
    if (!item || list.isLoading) return undefined
    return {
      name: item.name,
      value: item.secret ? (item.present ? ENCRYPTED_VALUE_MASK : '') : (item.value ?? ''),
      secret: item.secret,
      description: item.description ?? ''
    }
  }, [item, list.isLoading, mode])
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'worker-env', name, scope },
    source: workerEnvDraft,
    absent: () => mode === 'edit' && list.isSuccess && !list.isFetching && !item
  })

  const update = useMutation({
    ...api.update(),
    onSuccess: response => {
      toast.success(t('console.worker_envs.saved', { name: response.worker_env.name }))
      setPlaintextConfirmOpen(false)

      navigate('/worker-envs')
    }
  })
  const remove = useMutation({
    ...api.remove(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.worker_envs.deleted', { name: variables.path.name }))
      model.resetSource()

      navigate('/worker-envs')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const decrypt = useMutation({
    meta: { invalidates: false },
    ...api.decrypt(),
    gcTime: 0,
    onSuccess: response => {
      model.value.value = response.decrypted_value.value
    }
  })

  // The reveal belongs to the env the route edits, so it resets when the
  // route's name changes — not when a background refetch hands the same row
  // back under a new object identity, which would clear an unread
  // `decrypt.error` from the page.
  useEffect(() => decrypt.reset(), [decrypt.reset, name, scope])

  const saveCustom = (submittedName: string) => {
    update.mutate({
      body: {
        ...(isEncryptedValueMask(model.value.value) ? {} : { value: model.value.value }),
        secret: model.secret.value,
        description: blankToNull(model.description.value)
      },
      path: { name: submittedName }
    })
  }

  const submit = () => {
    model.clearValidation()
    const submittedName = mode === 'new' ? model.name.value.trim() : (name ?? '')
    if (!WORKER_ENV_NAME_FORMAT.test(submittedName)) {
      model.validationError.value = t('console.worker_envs.name_invalid')
      return
    }

    if (model.value.value.length === 0) {
      model.validationError.value = t('console.worker_envs.value_required')
      return
    }
    if (!model.secret.value && isEncryptedValueMask(model.value.value)) {
      model.validationError.value = t('console.worker_envs.plaintext_reveal_required')
      return
    }
    if (!model.secret.value) {
      setPlaintextConfirmOpen(true)
      return
    }
    saveCustom(submittedName)
  }

  const submitDisabled = mode === 'edit' && !model.dirty.value

  if (draftStatus === 'absent') {
    return <EditorNotFound backTo="/worker-envs" message={t('console.worker_envs.not_found', { name: name ?? '' })} />
  }

  return (
    <>
      <ResourceEditorPage
        title={mode === 'new' ? t('console.worker_envs.new') : (name ?? '')}
        description={item?.description ?? t('console.worker_envs.editor_description')}
        backTo="/worker-envs"
        dirty={model.dirty.value && !remove.isPending}
        validationError={model.validationError.value}
        error={update.error ?? decrypt.error ?? list.error}
        submitting={update.isPending}
        submitDisabled={submitDisabled}
        submitUnavailable={draftStatus !== 'ready'}
        onSubmit={submit}
        secondary={
          mode === 'edit' && item && item.source === scope ? (
            <ConfirmDeleteButton
              pending={remove.isPending}
              confirm={{
                title: t('console.worker_envs.delete_title'),
                description: t(
                  scope === 'tenant'
                    ? 'console.worker_envs.reset_tenant_description'
                    : 'console.worker_envs.delete_description',
                  { name: item.name }
                ),
                confirmLabel: t('common.delete')
              }}
              onConfirm={() => remove.mutate({ path: { name: item.name } })}
            />
          ) : null
        }>
        <Badge variant="secondary" className="w-fit">
          {t(`console.settings.scope_${scope}`)}
        </Badge>
        {item ? (
          <div className="flex flex-wrap items-center gap-2">
            <WorkerEnvSourceBadge source={item.source} />
            {item.secret ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
          </div>
        ) : null}

        {mode === 'new' ? (
          <LabeledField
            htmlFor="worker-env-name"
            label={t('console.worker_envs.name')}
            description={t('console.worker_envs.name_hint')}
            required>
            <Input
              id="worker-env-name"
              required
              className="font-mono"
              placeholder="SOME_ENV_VAR"
              spellCheck={false}
              value={model.name.value}
              onChange={event => (model.name.value = event.target.value)}
            />
          </LabeledField>
        ) : null}

        <>
          <LabeledField
            htmlFor="worker-env-value"
            label={t('console.worker_envs.value')}
            description={
              model.secret.value || isEncryptedValueMask(model.value.value)
                ? t('console.worker_envs.secret_value_hint')
                : undefined
            }
            required>
            {model.secret.value || isEncryptedValueMask(model.value.value) ? (
              <EncryptedValueInput
                id="worker-env-value"
                required
                className="font-mono"
                revealLabel={t('console.worker_envs.reveal')}
                revealed={item !== undefined && decrypt.data?.decrypted_value.name === item.name}
                revealing={decrypt.isPending}
                value={model.value.value}
                onChange={event => (model.value.value = event.target.value)}
                onReveal={item ? () => decrypt.mutate({ path: { name: item.name } }) : undefined}
              />
            ) : (
              <Input
                id="worker-env-value"
                required
                className="font-mono"
                spellCheck={false}
                value={model.value.value}
                onChange={event => (model.value.value = event.target.value)}
              />
            )}
          </LabeledField>
          <Field orientation="horizontal" className="items-center justify-between border border-border bg-muted/30 p-4">
            <div className="grid gap-1 pr-4">
              <FieldLabel htmlFor="worker-env-secret">{t('console.worker_envs.secret_storage')}</FieldLabel>
              <FieldDescription id="worker-env-secret-hint">{t('console.worker_envs.secret_hint')}</FieldDescription>
            </div>
            <Switch
              id="worker-env-secret"
              aria-describedby="worker-env-secret-hint"
              checked={model.secret.value}
              onCheckedChange={checked => (model.secret.value = checked === true)}
            />
          </Field>
          {!model.secret.value ? <WorkerEnvPlaintextWarning /> : null}
          <LabeledField
            htmlFor="worker-env-description"
            label={t('console.worker_envs.description_label')}
            description={t('console.worker_envs.description_hint')}>
            <Input
              id="worker-env-description"
              value={model.description.value}
              onChange={event => (model.description.value = event.target.value)}
            />
          </LabeledField>
        </>
      </ResourceEditorPage>
      <WorkerEnvPlaintextConfirmDialog
        open={plaintextConfirmOpen}
        pending={update.isPending}
        onOpenChange={setPlaintextConfirmOpen}
        onConfirm={() => {
          setPlaintextConfirmOpen(false)
          saveCustom(mode === 'new' ? model.name.value.trim() : (name ?? ''))
        }}
      />
    </>
  )
}

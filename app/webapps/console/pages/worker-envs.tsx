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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebWorkerEnvControllerDecryptMutation,
  ankoleWebWorkerEnvControllerDeleteMutation,
  ankoleWebWorkerEnvControllerIndexOptions,
  ankoleWebWorkerEnvControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { WorkerEnvItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { blankToNull, formatJSON, parseJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput, isEncryptedValueMask } from '../encrypted-value-input'
import { ConfirmDeleteButton, EditorNotFound, JSONField, LabeledField, ResourceEditorPage } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { WorkerEnvEditorModel } from '../state/worker-env-editor-model'
import { workerEnvValueText } from '../state/worker-env-visibility'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useEditorDraft } from '../use-editor-draft'

export const WORKER_ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

export function WorkerEnvSourceBadge({ source }: { source: WorkerEnvItem['source'] }) {
  const { t } = useTranslation()
  return <Badge variant={source === 'agent' ? 'info' : 'outline'}>{t(`console.worker_envs.source_${source}`)}</Badge>
}

export function WorkerEnvPlaintextWarning({ compact = false }: { compact?: boolean }) {
  const { t } = useTranslation()
  if (compact) {
    return (
      <p className="text-xs leading-5 text-yellow-80 dark:text-yellow-30" role="note">
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
  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebWorkerEnvControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const items = (list.data?.worker_envs ?? []).filter(item =>
    matchesResourceSearch(
      searchQuery,
      item.name,
      item.description,
      item.kind,
      item.source,
      item.secret ? 'encrypted' : '',
      item.present ? 'present' : 'unset'
    )
  )
  const remove = useMutation({
    ...ankoleWebWorkerEnvControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.worker_envs.deleted', { name: variables.path.name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.worker_envs.title')}
      description={t('console.worker_envs.description')}
      createTo="new"
      createLabel={t('console.worker_envs.new')}
      columns={[
        t('console.worker_envs.name'),
        t('console.worker_envs.value'),
        t('console.worker_envs.kind'),
        t('console.worker_envs.source'),
        t('console.worker_envs.state')
      ]}
      isLoading={list.isLoading}
      isEmpty={items.length === 0}
      count={items.length}
      emptyTitle={t('console.worker_envs.empty_title')}
      emptyIcon={<RiTerminalBoxLine aria-hidden />}
      emptyDescription={t('console.worker_envs.empty_description')}
      error={list.error}
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
          <TableCell className="max-w-[280px] font-mono text-xs break-all whitespace-normal">
            <Link className="text-foreground hover:text-link hover:underline" to={encodeURIComponent(item.name)}>
              {item.name}
            </Link>
          </TableCell>
          <TableCell className="max-w-[320px] truncate font-mono text-xs text-muted-foreground">
            {workerEnvValueText(item)}
          </TableCell>
          <TableCell>
            <Badge variant={item.kind === 'declared' ? 'outline' : 'secondary'}>
              {t(`console.worker_envs.kind_${item.kind}`)}
            </Badge>
          </TableCell>
          <TableCell>
            <WorkerEnvSourceBadge source={item.source} />
          </TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {item.secret ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
              {item.present ? null : <Badge variant="outline">{t('console.worker_envs.unset')}</Badge>}
            </div>
          </TableCell>
          <RowActions
            editTo={encodeURIComponent(item.name)}
            editLabel={t('common.edit')}
            deletePending={remove.isPending}
            deleteConfirm={
              item.kind === 'custom'
                ? {
                    title: t('console.worker_envs.delete_title'),
                    description: t('console.worker_envs.delete_description', { name: item.name }),
                    confirmLabel: t('common.delete')
                  }
                : undefined
            }
            onDelete={item.kind === 'custom' ? () => remove.mutate({ path: { name: item.name } }) : undefined}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function WorkerEnvEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(WorkerEnvEditorModel)
  const params = useParams()
  const name = params.name
  const mode = name ? 'edit' : 'new'
  const [plaintextConfirmOpen, setPlaintextConfirmOpen] = useState(false)

  const list = useQuery(ankoleWebWorkerEnvControllerIndexOptions())
  const item = name ? list.data?.worker_envs.find(entry => entry.name === name) : undefined
  const declared = item?.kind === 'declared'
  const workerEnvDraft = useMemo(() => {
    if (mode === 'new') return { name: '', value: '', secret: true, description: '' }
    if (!item || list.isLoading) return undefined
    return {
      name: item.name,
      value: item.secret
        ? item.present
          ? ENCRYPTED_VALUE_MASK
          : ''
        : typeof item.value === 'string'
          ? item.value
          : formatJSON(item.value ?? null),
      secret: item.secret,
      description: item.description ?? ''
    }
  }, [item, list.isLoading, mode])
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'worker-env', name },
    source: workerEnvDraft,
    absent: () => mode === 'edit' && list.isSuccess && !list.isFetching && !item
  })

  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebWorkerEnvControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.worker_envs.saved', { name: response.worker_env.name }))
      setPlaintextConfirmOpen(false)
      refresh()
      navigate('/worker-envs')
    }
  })
  const remove = useMutation({
    ...ankoleWebWorkerEnvControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(
        declared
          ? t('console.worker_envs.reset_done', { name: variables.path.name })
          : t('console.worker_envs.deleted', { name: variables.path.name })
      )
      model.resetSource()
      refresh()
      if (!declared) navigate('/worker-envs')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const decrypt = useMutation({
    ...ankoleWebWorkerEnvControllerDecryptMutation(),
    gcTime: 0,
    onSuccess: response => {
      const revealed = response.decrypted_value.value
      model.value.value = declared
        ? (JSON.stringify(revealed) ?? '')
        : typeof revealed === 'string'
          ? revealed
          : (JSON.stringify(revealed) ?? '')
    }
  })

  // The reveal belongs to the env the route edits, so it resets when the
  // route's name changes — not when a background refetch hands the same row
  // back under a new object identity, which would clear an unread
  // `decrypt.error` from the page.
  useEffect(() => decrypt.reset(), [decrypt.reset, name])

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

    if (declared) {
      if (isEncryptedValueMask(model.value.value)) {
        update.mutate({ body: {}, path: { name: submittedName } })
        return
      }
      const parsed = parseJSON(model.value.value, 'value')
      if (!parsed.ok) {
        model.validationError.value = parsed.error
        return
      }
      update.mutate({ body: { value: parsed.value }, path: { name: submittedName } })
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
          mode === 'edit' && item ? (
            declared ? (
              <ConfirmDeleteButton
                label={t('console.worker_envs.reset')}
                pending={remove.isPending}
                size="sm"
                variant="outline"
                confirm={{
                  title: t('console.worker_envs.reset_confirm_title'),
                  description: t('console.worker_envs.reset_confirm_description', { name: item.name }),
                  confirmLabel: t('console.worker_envs.reset')
                }}
                onConfirm={() => remove.mutate({ path: { name: item.name } })}
              />
            ) : (
              <ConfirmDeleteButton
                pending={remove.isPending}
                confirm={{
                  title: t('console.worker_envs.delete_title'),
                  description: t('console.worker_envs.delete_description', { name: item.name }),
                  confirmLabel: t('common.delete')
                }}
                onConfirm={() => remove.mutate({ path: { name: item.name } })}
              />
            )
          ) : null
        }>
        {item ? (
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={declared ? 'outline' : 'secondary'}>{t(`console.worker_envs.kind_${item.kind}`)}</Badge>
            <WorkerEnvSourceBadge source={item.source} />
            {item.secret ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
            {item.declared_key ? (
              <span className="font-mono text-xs text-muted-foreground">{item.declared_key}</span>
            ) : null}
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

        {declared && item.secret ? (
          <LabeledField
            htmlFor="worker-env-value"
            label={t('console.worker_envs.value')}
            description={t('console.worker_envs.secret_value_hint')}
            required>
            <EncryptedValueInput
              id="worker-env-value"
              required
              className="font-mono"
              revealLabel={t('console.worker_envs.reveal')}
              revealed={decrypt.data?.decrypted_value.name === item.name}
              revealing={decrypt.isPending}
              value={model.value.value}
              onChange={event => (model.value.value = event.target.value)}
              onReveal={() => decrypt.mutate({ path: { name: item.name } })}
            />
          </LabeledField>
        ) : declared ? (
          <JSONField
            label={t('console.worker_envs.value')}
            description={t('console.worker_envs.declared_value_hint')}
            minRows={6}
            required
            value={model.value.value}
            onChange={value => (model.value.value = value)}
          />
        ) : (
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
            <Field
              orientation="horizontal"
              className="items-center justify-between border border-border bg-muted/30 p-4">
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
        )}
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

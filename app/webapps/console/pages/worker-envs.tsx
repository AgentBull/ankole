import {
  Badge,
  Button,
  Checkbox,
  Field,
  FieldDescription,
  FieldLabel,
  Input,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
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
import { JSONField, LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'
import { WorkerEnvEditorModel } from '../state/worker-env-editor-model'

export const WORKER_ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

/** Renders a variable value cell: masked for secrets, JSON-ish for declared values. */
export function workerEnvValueText(item: WorkerEnvItem): string {
  if (item.secret) return '••••••'
  if (!item.present) return ''
  if (typeof item.value === 'string') return item.value
  return item.value === undefined ? '' : formatJSON(item.value)
}

export function WorkerEnvSourceBadge({ source }: { source: WorkerEnvItem['source'] }) {
  const { t } = useTranslation()
  return <Badge variant={source === 'agent' ? 'default' : 'outline'}>{t(`console.worker_envs.source_${source}`)}</Badge>
}

export function WorkerEnvsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebWorkerEnvControllerIndexOptions())
  const items = list.data?.worker_envs ?? []
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
        t('console.worker_envs.state')
      ]}
      isLoading={list.isLoading}
      isEmpty={items.length === 0}
      emptyTitle={t('console.worker_envs.empty_title')}
      emptyDescription={t('console.worker_envs.empty_description')}
      error={list.error}>
      {items.map(item => (
        <TableRow key={item.name} className="cursor-pointer" onClick={() => navigate(encodeURIComponent(item.name))}>
          <TableCell className="max-w-[280px] font-mono text-xs break-all whitespace-normal">{item.name}</TableCell>
          <TableCell className="max-w-[320px] truncate font-mono text-xs text-muted-foreground">
            {workerEnvValueText(item)}
          </TableCell>
          <TableCell>
            <Badge variant={item.kind === 'declared' ? 'outline' : 'secondary'}>
              {t(`console.worker_envs.kind_${item.kind}`)}
            </Badge>
          </TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {item.secret ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
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
  const name = params.name ? decodeURIComponent(params.name) : undefined
  const mode = name ? 'edit' : 'new'

  const list = useQuery(ankoleWebWorkerEnvControllerIndexOptions())
  const item = name ? list.data?.worker_envs.find(entry => entry.name === name) : undefined
  const declared = item?.kind === 'declared'

  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebWorkerEnvControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.worker_envs.saved', { name: response.worker_env.name }))
      refresh()
      navigate(mode === 'new' ? '..' : '..', { relative: 'path' })
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
      if (!declared) navigate('..', { relative: 'path' })
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
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    decrypt.reset()
    if (mode === 'new') {
      model.initialize('worker-env:new', { name: '', value: '', secret: false, description: '' })
      return
    }
    if (!item || list.isLoading) return
    model.initialize(`worker-env:${item.name}`, {
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
    })
  }, [item, list.isLoading, mode, model])

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
    update.mutate({
      body: {
        ...(isEncryptedValueMask(model.value.value) ? {} : { value: model.value.value }),
        secret: model.secret.value,
        description: blankToNull(model.description.value)
      },
      path: { name: submittedName }
    })
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.worker_envs.new') : (name ?? '')}
      description={item?.description ?? t('console.worker_envs.editor_description')}
      backTo=".."
      error={model.validationError.value ?? update.error ?? decrypt.error}
      submitting={update.isPending}
      onSubmit={submit}
      secondary={
        mode === 'edit' && item ? (
          <Button
            disabled={remove.isPending}
            size="sm"
            type="button"
            variant="outline"
            onClick={() => remove.mutate({ path: { name: item.name } })}>
            {declared ? t('console.worker_envs.reset') : t('common.delete')}
          </Button>
        ) : null
      }>
      {item ? (
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={declared ? 'outline' : 'secondary'}>{t(`console.worker_envs.kind_${item.kind}`)}</Badge>
          <WorkerEnvSourceBadge source={item.source} />
          {item.secret ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
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
                className="font-mono"
                revealLabel={t('console.worker_envs.reveal')}
                revealed={decrypt.data?.decrypted_value.name === item?.name}
                revealing={decrypt.isPending}
                value={model.value.value}
                onChange={event => (model.value.value = event.target.value)}
                onReveal={item ? () => decrypt.mutate({ path: { name: item.name } }) : undefined}
              />
            ) : (
              <Input
                id="worker-env-value"
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
            <Checkbox
              id="worker-env-secret"
              aria-describedby="worker-env-secret-hint"
              checked={model.secret.value}
              onCheckedChange={checked => (model.secret.value = checked === true)}
            />
          </Field>
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
  )
}

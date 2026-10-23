import { flushSync } from 'react-dom'
import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  TableCell,
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiServerLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { requestErrorDetailList, requestErrorMessage } from '../../common/request-errors'
import {
  checkWorkerProviderOptions,
  listWorkerProviderKindsOptions
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import {
  createWorkerProviderMutation,
  deleteWorkerProviderMutation,
  listWorkerProvidersOptions,
  updateWorkerProviderMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import {
  ConfirmDeleteButton,
  EditorNotFound,
  LabeledField,
  ReadOnlyValue,
  ResourceEditorPage,
  StatusIndicator
} from '../console-form'
import { ResourceListPage, ResourceSearch } from '../console-list-page'
import { EncryptedValueInput } from '../encrypted-value-input'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import {
  newWorkerProviderDraft,
  workerProvider,
  workerProviderDraft,
  WorkerProviderEditorModel,
  workerProviders
} from '../state/worker-provider-editor-model'
import { useEditorDraft } from '../use-editor-draft'

const providersPath = '/worker-providers'

export function WorkerProvidersListPage() {
  const { t } = useTranslation()
  const providers = useQuery({ ...listWorkerProvidersOptions(), select: workerProviders })
  const [query, setQuery] = useState('')
  const search = effectiveResourceSearchQuery(query, useDeferredValue(query))
  const rows = (providers.data ?? []).filter(provider =>
    matchesResourceSearch(search, provider.provider_id, provider.display_name, provider.kind)
  )

  return (
    <ResourceListPage
      title={t('console.worker_providers.title')}
      description={t('console.worker_providers.description')}
      createTo={`${providersPath}/new`}
      createLabel={t('console.worker_providers.new')}
      columns={['name', 'kind', 'availability', 'agent_count'].map(key => t(`console.worker_providers.${key}`))}
      isLoading={providers.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.worker_providers.empty')}
      emptyDescription={t('console.worker_providers.description')}
      emptyIcon={<RiServerLine aria-hidden />}
      error={providers.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.worker_providers.search')}
          placeholder={t('console.worker_providers.search')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(provider => (
        <TableRow key={provider.provider_id}>
          <TableCell>
            <Link
              data-row-link
              className="text-foreground"
              to={`${providersPath}/${encodeURIComponent(provider.provider_id)}`}>
              {provider.display_name}
            </Link>
            <div className="font-mono text-xs text-muted-foreground">{provider.provider_id}</div>
            {provider.is_default ? <Badge variant="secondary">{t('console.worker_providers.default')}</Badge> : null}
          </TableCell>
          <TableCell>{provider.kind}</TableCell>
          <TableCell>
            <ProviderAvailability providerID={provider.provider_id} />
          </TableCell>
          <TableCell>{provider.agent_count}</TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function ProviderAvailability({ providerID }: { providerID: string }) {
  const { t } = useTranslation()
  const check = useQuery({
    ...checkWorkerProviderOptions({ path: { provider_id: providerID } }),
    retry: false
  })
  return (
    <div className="grid max-w-md justify-items-start gap-2">
      <StatusIndicator tone={check.error ? 'danger' : check.data?.available ? 'positive' : 'info'}>
        {t(
          `console.worker_providers.${check.error ? 'unavailable' : check.data?.available ? 'available' : 'checking'}`
        )}
      </StatusIndicator>
      {check.error ? (
        <p className="break-words text-xs text-destructive-foreground">{requestErrorMessage(check.error)}</p>
      ) : null}
      <Button
        size="xs"
        type="button"
        variant="outline"
        disabled={check.isFetching}
        onClick={() => void check.refetch()}>
        {t('console.worker_providers.check')}
      </Button>
    </div>
  )
}

export function WorkerProviderEditorPage() {
  const { providerID } = useParams({ strict: false })
  return <WorkerProviderEditor key={providerID ?? 'new'} providerID={providerID} />
}

function WorkerProviderEditor({ providerID }: { providerID?: string }) {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(WorkerProviderEditorModel)
  const providers = useQuery({ ...listWorkerProvidersOptions(), select: workerProviders })
  const kinds = useQuery(listWorkerProviderKindsOptions())
  const selected = providers.data?.find(provider => provider.provider_id === providerID)
  const definitions = kinds.data?.worker_provider_kinds
  const source = useMemo(() => {
    if (providerID) return selected ? workerProviderDraft(selected) : undefined
    const initialKind = definitions?.find(item => item.kind === 'docker') ?? definitions?.[0]
    return initialKind ? newWorkerProviderDraft(initialKind) : undefined
  }, [providerID, selected, definitions])
  const status = useEditorDraft(model, {
    sourceKey: providerID ? `provider:${providerID}` : 'new',
    source,
    absent: () => Boolean(providerID && providers.isSuccess && !selected)
  })
  const definition = definitions?.find(item => item.kind === model.kind.value)
  const saved = () => {
    toast.success(t('console.worker_providers.saved'))
  }
  const create = useMutation({
    ...createWorkerProviderMutation(),
    onMutate: () => model.captureSave(),
    onSuccess: (response, _variables, confirm) => {
      const provider = workerProvider(response)
      let accepted = false
      flushSync(() => {
        accepted = confirm?.(workerProviderDraft(provider)) ?? false
      })
      if (!accepted) return
      saved()
      if (!model.dirty.value) {
        void navigate({ to: `${providersPath}/${encodeURIComponent(provider.provider_id)}` })
      }
    }
  })
  const update = useMutation({
    ...updateWorkerProviderMutation(),
    onMutate: () => model.captureSave(),
    onSuccess: (response, _variables, confirm) => {
      if (confirm?.(workerProviderDraft(workerProvider(response)))) saved()
    }
  })
  const remove = useMutation({
    ...deleteWorkerProviderMutation(),
    onMutate: () => window.location.href,
    onSuccess: (_response, _variables, sourceURL) => {
      if (window.location.href !== sourceURL) return
      void navigate({ to: providersPath })
    }
  })
  const saveError = create.error ?? update.error
  const details = requestErrorDetailList(saveError)
  const submit = () => {
    const attributes = {
      display_name: model.displayName.value.trim(),
      config: model.config.value,
      is_default: model.isDefault.value,
      credentials: model.credentials.value
    }
    if (providerID) {
      update.mutate({
        path: { provider_id: providerID },
        body: { data: { type: 'worker_provider', id: selected?.id ?? '', attributes } }
      })
    } else {
      const identity = { provider_id: model.providerID.value.trim(), kind: model.kind.value }
      create.mutate({ body: { data: { type: 'worker_provider', attributes: { ...attributes, ...identity } } } })
    }
  }

  if (status === 'absent') {
    return <EditorNotFound backTo={providersPath} message={t('console.worker_providers.not_found')} />
  }

  return (
    <ResourceEditorPage
      title={providerID ? (selected?.display_name ?? providerID) : t('console.worker_providers.new')}
      description={t('console.worker_providers.editor_description')}
      backTo={providersPath}
      dirty={model.dirty.value && !remove.isPending}
      supplementaryDirty={model.dirty.value && !remove.isPending}
      error={saveError ?? remove.error ?? providers.error ?? kinds.error}
      submitting={create.isPending || update.isPending}
      submitUnavailable={status !== 'ready' || !definition}
      submitDisabled={Boolean(providerID && !model.dirty.value)}
      onSubmit={submit}
      secondary={
        selected ? (
          selected.agent_count > 0 ? (
            <p className="text-xs text-muted-foreground">{t('console.worker_providers.in_use')}</p>
          ) : (
            <ConfirmDeleteButton
              label={t('common.delete')}
              pending={remove.isPending}
              confirm={{
                title: t('console.worker_providers.delete_title'),
                description: selected.display_name,
                confirmLabel: t('common.delete')
              }}
              onConfirm={() => remove.mutate({ path: { provider_id: selected.provider_id } })}
            />
          )
        ) : null
      }>
      {selected && kinds.isSuccess && !definition ? <ProviderAvailability providerID={selected.provider_id} /> : null}
      <fieldset className="contents" disabled={create.isPending || (kinds.isSuccess && !definition)}>
        <LabeledField label={t('console.worker_providers.id')} required={!providerID}>
          {providerID ? (
            <ReadOnlyValue mono>{providerID}</ReadOnlyValue>
          ) : (
            <Input
              value={model.providerID.value}
              onChange={event => (model.providerID.value = event.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
          )}
        </LabeledField>
        <LabeledField label={t('console.worker_providers.name')} required>
          <Input value={model.displayName.value} onChange={event => (model.displayName.value = event.target.value)} />
        </LabeledField>
        <LabeledField label={t('console.worker_providers.kind')} required={!providerID}>
          {providerID ? (
            <ReadOnlyValue>{model.kind.value}</ReadOnlyValue>
          ) : (
            <Select
              value={model.kind.value}
              onValueChange={value => {
                const next = definitions?.find(item => item.kind === value)
                if (next) model.selectKind(next)
              }}>
              <SelectTrigger aria-label={t('console.worker_providers.kind')} className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {definitions?.map(item => (
                  <SelectItem key={item.kind} value={item.kind}>
                    {item.kind}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
        <LabeledField
          label={t('console.worker_providers.default')}
          description={t('console.worker_providers.default_hint')}>
          <Switch checked={model.isDefault.value} onCheckedChange={value => (model.isDefault.value = value)} />
        </LabeledField>
        <LabeledField
          label={t('console.worker_providers.config')}
          description={t('console.worker_providers.config_hint')}
          required>
          <Textarea
            className="min-h-80 font-mono text-xs"
            spellCheck={false}
            value={model.config.value}
            onChange={event => (model.config.value = event.target.value)}
          />
        </LabeledField>
        {details.length ? (
          <ul className="grid gap-2 text-sm text-destructive-foreground" role="alert">
            {details.map((detail, index) => (
              <li key={index}>
                <code>{String(detail.path ?? detail.field ?? '')}</code>
                {typeof detail.line === 'number'
                  ? ` (${t('console.worker_providers.line', { line: detail.line })})`
                  : ''}
                : {String(detail.message ?? '')}
              </li>
            ))}
          </ul>
        ) : null}
        {Object.entries(definition?.credentials ?? {}).map(([name, credential]) => {
          // The API names the stored credentials; their values never leave the server.
          const stored = selected?.stored_credentials.includes(name) ? '********' : undefined
          const removed = model.credentials.value[name] === null
          return (
            <LabeledField
              key={name}
              label={name}
              description={
                removed
                  ? t('console.worker_providers.credential_removed')
                  : t('console.worker_providers.credential_hint')
              }
              required={credential.required && !stored}>
              {name === 'kubeconfig' ? (
                <Textarea
                  className="min-h-40 font-mono text-xs"
                  autoComplete="off"
                  spellCheck={false}
                  placeholder={stored}
                  value={model.credentials.value[name] ?? ''}
                  onChange={event => model.setCredential(name, event.target.value)}
                />
              ) : (
                <EncryptedValueInput
                  disabled={removed}
                  placeholder={removed ? undefined : stored}
                  revealLabel={t('console.aria.reveal_secret')}
                  value={model.credentials.value[name] ?? ''}
                  onChange={event => model.setCredential(name, event.target.value)}
                />
              )}
              {/* The server keeps a kubeconfig: in-cluster and remote access cannot change. */}
              {stored && !credential.required && name !== 'kubeconfig' ? (
                <div>
                  <Button
                    size="xs"
                    type="button"
                    variant="outline"
                    onClick={() => model.setCredential(name, removed ? '' : null)}>
                    {removed
                      ? t('console.worker_providers.credential_keep')
                      : t('console.worker_providers.credential_remove')}
                  </Button>
                </div>
              ) : null}
            </LabeledField>
          )
        })}
      </fieldset>
    </ResourceEditorPage>
  )
}

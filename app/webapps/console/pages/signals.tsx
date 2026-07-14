import {
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useSearchParams } from 'react-router'
import {
  ConfigField,
  ConfigFields,
  defaultConfig,
  localizedText,
  setPath,
  type ConfigFieldDefinition,
  type LocalizedText
} from '../../common/config-fields'
import i18n from '../../common/i18n'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebSignalBindingControllerAdaptersOptions,
  ankoleWebSignalBindingControllerDeleteMutation,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebSignalBindingControllerPutBindingMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { SignalAdapterItem } from '../api/generated/types.gen'
import {
  LabeledField,
  ReadOnlyValue,
  ResourceEditorPage,
  ResourceListPage,
  ResourceSearch,
  RowActions,
  StatusIndicator
} from '../console-shell'
import {
  SignalBindingEditorModel,
  type GroupMessageMode,
  type SignalBindingEditorDraft
} from '../state/signal-binding-editor-model'
import { matchesResourceSearch } from '../state/resource-search'

export function SignalsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const agentUID = searchParams.get('agent') ?? agentList[0]?.uid ?? ''
  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const rows = (bindings.data?.signal_bindings ?? []).filter(binding =>
    matchesResourceSearch(
      deferredQuery,
      binding.name,
      binding.adapter,
      binding.unaddressed_group_message_policy,
      binding.enabled
    )
  )
  const deleteBinding = useMutation({
    ...ankoleWebSignalBindingControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.deleted', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const selectAgent = (uid: string) => setSearchParams(uid ? { agent: uid } : {})

  return (
    <ResourceListPage
      title={t('console.signals.title')}
      description={t('console.signals.description')}
      createTo={agentUID ? `new?agent=${encodeURIComponent(agentUID)}` : undefined}
      createLabel={t('console.signals.new')}
      columns={[
        t('console.signals.name'),
        t('console.signals.adapter'),
        t('console.signals.policy'),
        t('console.signals.state')
      ]}
      isLoading={bindings.isLoading || agents.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.signals.empty_title')}
      emptyDescription={t('console.signals.empty_description')}
      error={agents.error ?? bindings.error}
      isFiltered={Boolean(query.trim())}
      toolbar={
        <div className="grid gap-3 md:grid-cols-[minmax(220px,320px)_minmax(0,1fr)]">
          <div className="border border-border bg-card p-3">
            <LabeledField label={t('console.agents.agent')}>
              <Select value={agentUID} onValueChange={value => selectAgent(String(value))}>
                <SelectTrigger className="w-full">
                  <SelectValue placeholder={t('console.signals.select_agent')} />
                </SelectTrigger>
                <SelectContent>
                  {agentList.map(agent => (
                    <SelectItem key={agent.uid} value={agent.uid}>
                      {agent.uid}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </LabeledField>
          </div>
          <ResourceSearch
            label={t('console.signals.search')}
            placeholder={t('console.signals.search_placeholder')}
            value={query}
            onChange={setQuery}
          />
        </div>
      }>
      {rows.map(binding => (
        <TableRow key={`${binding.adapter}:${binding.name}`}>
          <TableCell className="font-mono text-xs">
            <Link
              className="text-foreground hover:text-primary hover:underline"
              to={reconfigureTo(agentUID, binding.adapter, binding.name)}>
              {binding.name}
            </Link>
          </TableCell>
          <TableCell>{binding.adapter}</TableCell>
          <TableCell>{binding.unaddressed_group_message_policy}</TableCell>
          <TableCell>
            <StatusIndicator tone={binding.enabled ? 'positive' : 'neutral'}>
              {binding.enabled ? t('console.status.enabled') : t('console.status.disabled')}
            </StatusIndicator>
          </TableCell>
          <RowActions
            editTo={reconfigureTo(agentUID, binding.adapter, binding.name)}
            editLabel={t('console.signals.reconfigure')}
            deletePending={deleteBinding.isPending}
            deleteConfirm={{
              title: t('console.signals.delete_title'),
              description: t('console.signals.delete_description', { name: binding.name }),
              confirmLabel: t('common.delete')
            }}
            onDelete={() => deleteBinding.mutate({ path: { agent_uid: agentUID, binding_name: binding.name } })}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function SignalBindingEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(SignalBindingEditorModel)
  const [searchParams] = useSearchParams()
  const locale = i18n.language

  const agentUID = searchParams.get('agent') ?? ''
  const lockedAdapter = searchParams.get('adapter') ?? undefined
  const lockedName = searchParams.get('name') ?? undefined
  const reconfigure = Boolean(lockedName)

  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const signalAdapters = adapters.data?.signal_adapters ?? []

  const activeAdapter =
    signalAdapters.find(adapter => adapter.adapter_id === model.adapterID.value) ?? signalAdapters[0]

  const ready = signalAdapters.length > 0
  useEffect(() => {
    if (!ready) return
    const adapter = signalAdapters.find(item => item.adapter_id === lockedAdapter) ?? signalAdapters[0]
    model.initialize(
      `binding:${agentUID}:${lockedAdapter ?? ''}:${lockedName ?? 'new'}`,
      formFromAdapter(adapter, lockedName)
    )
  }, [agentUID, lockedAdapter, lockedName, model, ready, signalAdapters])

  const saveBinding = useMutation({
    ...ankoleWebSignalBindingControllerPutBindingMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.saved', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
      navigate(`/signals?agent=${encodeURIComponent(agentUID)}`)
    }
  })

  const submit = () => {
    model.clearValidation()
    if (!activeAdapter || !agentUID) return
    const name = model.name.value.trim()
    if (!name) {
      model.validationError.value = t('console.signals.binding_name_required')
      return
    }
    const groupMessageMode = asGroupMessageMode(model.groupMessageMode.value || defaultGroupMessageMode(activeAdapter))
    if (!groupMessageMode) {
      model.validationError.value = t('console.signals.group_message_mode_invalid')
      return
    }
    saveBinding.mutate({
      body: { config: model.config.value, group_message_mode: groupMessageMode },
      path: { adapter_id: activeAdapter.adapter_id, agent_uid: agentUID, binding_name: name }
    })
  }

  return (
    <ResourceEditorPage
      title={reconfigure ? t('console.signals.reconfigure') : t('console.signals.new')}
      description={reconfigure ? t('console.signals.reconfigure_hint') : t('console.signals.editor_description')}
      backTo={`/signals?agent=${encodeURIComponent(agentUID)}`}
      error={model.validationError.value ?? adapters.error ?? saveBinding.error}
      submitting={saveBinding.isPending}
      onSubmit={submit}>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.signals.adapter')}>
          {reconfigure ? (
            <ReadOnlyValue>
              {activeAdapter
                ? localizedUnknown(activeAdapter.display_name, locale, activeAdapter.adapter_id)
                : model.adapterID.value}
            </ReadOnlyValue>
          ) : (
            <Select
              value={activeAdapter?.adapter_id ?? ''}
              onValueChange={value => {
                const adapter = signalAdapters.find(item => item.adapter_id === value)
                if (adapter) model.changeAdapter(formFromAdapter(adapter))
              }}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {signalAdapters.map(adapter => (
                  <SelectItem key={adapter.adapter_id} value={adapter.adapter_id}>
                    {localizedUnknown(adapter.display_name, locale, adapter.adapter_id)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
        <LabeledField label={t('console.signals.binding_name')} required>
          {reconfigure ? (
            <ReadOnlyValue mono>{model.name.value}</ReadOnlyValue>
          ) : (
            <Input value={model.name.value} onChange={event => (model.name.value = event.target.value)} />
          )}
        </LabeledField>
      </div>

      {activeAdapter ? (
        <>
          <ConfigField
            field={asConfigField(activeAdapter.group_message_mode_field)}
            locale={locale}
            value={model.groupMessageMode.value || defaultGroupMessageMode(activeAdapter)}
            onChange={value => (model.groupMessageMode.value = String(value) as GroupMessageMode)}
          />
          <ConfigFields
            config={model.config.value}
            fields={asConfigFields(activeAdapter.fields)}
            locale={locale}
            onChange={(path, value) => (model.config.value = setPath(model.config.value, path, value))}
          />
        </>
      ) : null}
    </ResourceEditorPage>
  )
}

function reconfigureTo(agentUID: string, adapter: string, name: string): string {
  const query = new URLSearchParams({ agent: agentUID, adapter, name })
  return `new?${query.toString()}`
}

function emptyForm(): SignalBindingEditorDraft {
  return { adapterID: '', name: '', groupMessageMode: '', config: {} }
}

function formFromAdapter(adapter: SignalAdapterItem | undefined, name?: string): SignalBindingEditorDraft {
  if (!adapter) return emptyForm()
  return {
    adapterID: adapter.adapter_id,
    name: name ?? `${adapter.adapter_id}-main`,
    groupMessageMode: defaultGroupMessageMode(adapter),
    config: defaultConfig(asConfigFields(adapter.fields))
  }
}

function asConfigFields(fields: readonly unknown[]): ConfigFieldDefinition[] {
  return fields.map(asConfigField)
}

function asConfigField(field: unknown): ConfigFieldDefinition {
  return field as unknown as ConfigFieldDefinition
}

function defaultGroupMessageMode(adapter: SignalAdapterItem): GroupMessageMode | '' {
  const field = asConfigField(adapter.group_message_mode_field)
  return asGroupMessageMode(typeof field.default === 'string' ? field.default : undefined) ?? ''
}

function asGroupMessageMode(value: string | undefined): GroupMessageMode | undefined {
  if (value === 'addressed_only' || value === 'observe_all' || value === 'may_intervene') return value
  return undefined
}

function localizedUnknown(value: unknown, locale: string, fallback: string): string {
  return localizedText(value as LocalizedText, locale) ?? fallback
}

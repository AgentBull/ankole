import {
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiBroadcastLine } from '@remixicon/react'
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
  ankoleWebSignalBindingControllerPutBindingMutation,
  ankoleWebSignalBindingControllerUpdateBindingMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { SignalAdapterItem } from '../api/generated/types.gen'
import { FormSection, LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import {
  defaultSignalBindingAgentUID,
  SignalBindingEditorModel,
  type GroupMessageMode,
  type SignalBindingAdapterDraft
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
      binding.confidential_memory,
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
        t('console.signals.memory_scope'),
        t('console.signals.state')
      ]}
      isLoading={bindings.isLoading || agents.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.signals.empty_title')}
      emptyIcon={<RiBroadcastLine aria-hidden />}
      emptyDescription={t('console.signals.empty_description')}
      error={agents.error ?? bindings.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.signals.search')}
          placeholder={t('console.signals.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <Select value={agentUID} onValueChange={value => selectAgent(String(value))}>
              <SelectTrigger aria-label={t('console.agents.agent')} className="w-56">
                <SelectValue placeholder={t('console.signals.select_agent')} />
              </SelectTrigger>
              <SelectContent emptyLabel={agents.isLoading ? t('common.loading') : t('common.select_no_agents')}>
                {agentList.map(agent => (
                  <SelectItem key={agent.uid} value={agent.uid}>
                    {agent.uid}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          }
        />
      }>
      {rows.map(binding => (
        <TableRow key={`${binding.adapter}:${binding.name}`}>
          <TableCell className="font-mono text-xs">
            <Link
              className="text-foreground hover:text-link hover:underline"
              to={reconfigureTo(agentUID, binding.adapter, binding.name)}>
              {binding.name}
            </Link>
          </TableCell>
          <TableCell>{binding.adapter}</TableCell>
          {/* The stored value is a policy identifier, not a phrase an operator reads. */}
          <TableCell>{t(`console.signals.policy_${binding.unaddressed_group_message_policy}`)}</TableCell>
          <TableCell>
            {binding.confidential_memory
              ? t('console.signals.memory_confidential')
              : t('console.signals.memory_shared')}
          </TableCell>
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

  const sourceAgentUID = searchParams.get('agent') ?? ''
  const lockedAdapter = searchParams.get('adapter') ?? undefined
  const lockedName = searchParams.get('name') ?? undefined
  const reconfigure = Boolean(lockedName)

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const defaultAgentUID = defaultSignalBindingAgentUID(agentList, sourceAgentUID)
  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const signalAdapters = adapters.data?.signal_adapters ?? []
  const currentBindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: sourceAgentUID } }),
    enabled: reconfigure && Boolean(sourceAgentUID)
  })
  const currentBinding = currentBindings.data?.signal_bindings.find(
    binding => binding.adapter === lockedAdapter && binding.name === lockedName
  )

  const activeAdapter =
    signalAdapters.find(adapter => adapter.adapter_id === model.adapterID.value) ?? signalAdapters[0]

  const ready =
    agents.data !== undefined && signalAdapters.length > 0 && (!reconfigure || currentBindings.data !== undefined)
  useEffect(() => {
    if (!ready) return
    const adapter = signalAdapters.find(item => item.adapter_id === lockedAdapter) ?? signalAdapters[0]
    model.initialize(`binding:${sourceAgentUID}:${lockedAdapter ?? ''}:${lockedName ?? 'new'}`, {
      agentUID: defaultAgentUID,
      ...formFromAdapter(adapter, lockedName, currentBinding?.confidential_memory ?? false)
    })
  }, [
    currentBinding?.confidential_memory,
    defaultAgentUID,
    lockedAdapter,
    lockedName,
    model,
    ready,
    signalAdapters,
    sourceAgentUID
  ])

  const createBinding = useMutation({
    ...ankoleWebSignalBindingControllerPutBindingMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.saved', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
      navigate(`/signals?agent=${encodeURIComponent(variables.path.agent_uid)}`)
    }
  })
  const updateBinding = useMutation({
    ...ankoleWebSignalBindingControllerUpdateBindingMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.saved', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
      navigate(`/signals?agent=${encodeURIComponent(variables.body.target_agent_uid)}`)
    }
  })

  const submit = () => {
    model.clearValidation()
    const targetAgentUID = model.agentUID.value
    if (!targetAgentUID) {
      model.validationError.value = t('console.signals.target_agent_required')
      return
    }
    if (!activeAdapter) return
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
    const body = {
      config: reconfigure ? model.configPatch.value : model.config.value,
      group_message_mode: groupMessageMode,
      confidential_memory: model.confidentialMemory.value
    }
    if (reconfigure) {
      updateBinding.mutate({
        body: { ...body, target_agent_uid: targetAgentUID },
        path: { agent_uid: sourceAgentUID, binding_name: name }
      })
    } else {
      createBinding.mutate({
        body,
        path: { adapter_id: activeAdapter.adapter_id, agent_uid: targetAgentUID, binding_name: name }
      })
    }
  }

  const targetAgentUID = model.agentUID.value || defaultAgentUID
  const activeFields = asConfigFields(activeAdapter?.fields ?? [])
  const submitDisabled = reconfigure && !model.dirty.value

  return (
    <ResourceEditorPage
      title={reconfigure ? t('console.signals.reconfigure') : t('console.signals.new')}
      description={reconfigure ? t('console.signals.reconfigure_hint') : t('console.signals.editor_description')}
      backTo={`/signals?agent=${encodeURIComponent(targetAgentUID)}`}
      error={
        model.validationError.value ??
        agents.error ??
        adapters.error ??
        currentBindings.error ??
        createBinding.error ??
        updateBinding.error
      }
      submitting={createBinding.isPending || updateBinding.isPending}
      submitDisabled={submitDisabled}
      submitUnavailable={!ready}
      contentWidth="wide"
      onSubmit={submit}>
      <FormSection title={t('console.signals.section_basic')} description={t('console.signals.section_basic_hint')}>
        <div className="grid grid-cols-1 gap-5 md:grid-cols-3">
          <LabeledField label={t('console.signals.target_agent')} required>
            <Select value={targetAgentUID} onValueChange={value => model.selectAgent(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.signals.select_agent')} />
              </SelectTrigger>
              <SelectContent emptyLabel={agents.isLoading ? t('common.loading') : t('common.select_no_agents')}>
                {agentList.map(agent => (
                  <SelectItem key={agent.uid} value={agent.uid}>
                    {agent.display_name ? `${agent.display_name} · ${agent.uid}` : agent.uid}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </LabeledField>
          <LabeledField label={t('console.signals.adapter')} required={!reconfigure}>
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
                <SelectContent emptyLabel={adapters.isLoading ? t('common.loading') : t('common.select_empty')}>
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
              <Input required value={model.name.value} onChange={event => (model.name.value = event.target.value)} />
            )}
          </LabeledField>
        </div>
      </FormSection>

      {activeAdapter ? (
        <>
          <FormSection
            title={t('console.signals.section_behavior')}
            description={t('console.signals.section_behavior_hint')}>
            <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
              <ConfigField
                field={asConfigField(activeAdapter.group_message_mode_field)}
                locale={locale}
                value={model.groupMessageMode.value || defaultGroupMessageMode(activeAdapter)}
                onChange={value => (model.groupMessageMode.value = String(value) as GroupMessageMode)}
              />
              <LabeledField
                label={t('console.signals.confidential_memory')}
                description={t('console.signals.confidential_memory_hint')}>
                <div className="flex items-center justify-between border border-border p-3">
                  <span className="text-sm text-muted-foreground">
                    {model.confidentialMemory.value
                      ? t('console.signals.memory_confidential')
                      : t('console.signals.memory_shared')}
                  </span>
                  <Switch
                    aria-label={t('console.signals.confidential_memory')}
                    checked={model.confidentialMemory.value}
                    onCheckedChange={checked => (model.confidentialMemory.value = checked)}
                  />
                </div>
              </LabeledField>
            </div>
          </FormSection>
          <FormSection
            title={t('console.signals.section_connection')}
            description={t('console.signals.section_connection_hint')}>
            <ConfigFields
              advancedLabel={t('console.signals.section_advanced')}
              config={model.config.value}
              fields={activeFields}
              locale={locale}
              onChange={(path, value) => model.changeConfig(path, value)}
            />
          </FormSection>
        </>
      ) : null}
    </ResourceEditorPage>
  )
}

function reconfigureTo(agentUID: string, adapter: string, name: string): string {
  const query = new URLSearchParams({ agent: agentUID, adapter, name })
  return `new?${query.toString()}`
}

function emptyForm(): SignalBindingAdapterDraft {
  return { adapterID: '', name: '', groupMessageMode: '', confidentialMemory: false, config: {} }
}

function formFromAdapter(
  adapter: SignalAdapterItem | undefined,
  name?: string,
  confidentialMemory = false
): SignalBindingAdapterDraft {
  if (!adapter) return emptyForm()
  return {
    adapterID: adapter.adapter_id,
    name: name ?? `${adapter.adapter_id}-main`,
    groupMessageMode: defaultGroupMessageMode(adapter),
    confidentialMemory,
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

import { LIST_REFRESH_MS } from '../refresh-intervals'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import {
  Alert,
  AlertDescription,
  Button,
  Input,
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiBroadcastLine, RiPauseCircleLine, RiPlayCircleLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useSearchParams } from 'react-router'
import { ConfigField, ConfigFields, defaultConfig, localizedText } from '../../common/config-fields'
import i18n from '../../common/i18n'
import { requestErrorMessage } from '../../common/request-errors'
import { formatConsoleDate } from '../console-primitives'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebSignalBindingControllerAdaptersOptions,
  ankoleWebSignalBindingControllerDeleteMutation,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebSignalBindingControllerPutBindingMutation,
  ankoleWebSignalBindingControllerRequeueDeliveryMutation,
  ankoleWebSignalBindingControllerShowOptions,
  ankoleWebSignalBindingControllerUpdateBindingMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { SignalAdapterItem, SignalBindingItem, SignalDeliveryFailureItem } from '../api/generated/types.gen'
import { AgentFilter, resolveAgentUID, useAgentScope } from '../console-agent-scope'
import { FormSection, LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import {
  groupMessageModeFromPolicy,
  groupSignalAdapters,
  SignalBindingEditorModel,
  type GroupMessageMode,
  type SignalBindingAdapterDraft,
  type UnmatchedSenderPolicy
} from '../state/signal-binding-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

export function SignalsListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [query, setQuery] = useState('')
  const [showDisabled, setShowDisabled] = useState(false)
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const scope = useAgentScope()
  const signals = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ query: { agent: scope.agentUID || undefined } }),
    refetchInterval: LIST_REFRESH_MS
  })
  const rows = (signals.data?.signal_bindings ?? [])
    .filter(binding => showDisabled || binding.enabled)
    .filter(binding =>
      matchesResourceSearch(
        searchQuery,
        binding.name,
        binding.agent_uid,
        binding.adapter,
        binding.unaddressed_group_message_policy,
        binding.enabled
      )
    )
  const stoppedDeliveries = signals.data?.delivery_failures ?? []
  const disableBinding = useMutation({
    ...ankoleWebSignalBindingControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.disabled', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const enableBinding = useMutation({
    ...ankoleWebSignalBindingControllerUpdateBindingMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.enabled', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const retryDelivery = useMutation({
    ...ankoleWebSignalBindingControllerRequeueDeliveryMutation(),
    onSuccess: () => {
      toast.success(t('console.signals.delivery_retry_success'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.signals.title')}
      description={t('console.signals.description')}
      createTo={
        scope.agents.length > 0
          ? scope.agentUID
            ? `new?${new URLSearchParams({ agent: scope.agentUID, return_agent: scope.agentUID })}`
            : 'new'
          : undefined
      }
      createLabel={t('console.signals.new')}
      columns={[
        t('console.signals.name'),
        t('console.agents.agent'),
        t('console.signals.adapter'),
        t('console.signals.policy'),
        t('console.signals.state')
      ]}
      isLoading={signals.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t(showDisabled ? 'console.signals.empty_title' : 'console.signals.empty_active_title')}
      emptyIcon={<RiBroadcastLine aria-hidden />}
      emptyDescription={t(
        showDisabled ? 'console.signals.empty_description' : 'console.signals.empty_active_description'
      )}
      error={signals.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.signals.search')}
          placeholder={t('console.signals.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <>
              <AgentFilter scope={scope} />
              <FilterSwitch
                checked={showDisabled}
                label={t('console.signals.show_disabled')}
                onChange={setShowDisabled}
              />
            </>
          }
        />
      }
      footer={
        stoppedDeliveries.length > 0 ? (
          <StoppedDeliveries
            rows={stoppedDeliveries}
            retryPending={retryDelivery.isPending}
            onRetry={(agentUID, bindingName, outboundKey) =>
              retryDelivery.mutate({
                path: { agent_uid: agentUID },
                body: { binding_name: bindingName, outbound_key: outboundKey }
              })
            }
          />
        ) : undefined
      }>
      {rows.map(binding => (
        <TableRow key={`${binding.agent_uid}:${binding.adapter}:${binding.name}`}>
          <TableCell className="font-mono text-xs">
            <Link
              className="text-foreground hover:text-link hover:underline"
              to={editTo(binding.agent_uid, binding.adapter, binding.name, scope.agentUID)}>
              {binding.name}
            </Link>
          </TableCell>
          <AgentCell uid={binding.agent_uid} />
          <TableCell>{binding.adapter}</TableCell>
          {/* The stored value is a policy identifier, not a phrase an operator reads. */}
          <TableCell>{t(`console.signals.policy_${binding.unaddressed_group_message_policy}`)}</TableCell>
          <TableCell>
            <StatusIndicator tone={binding.enabled ? 'positive' : 'neutral'}>
              {binding.enabled ? t('console.status.enabled') : t('console.status.disabled')}
            </StatusIndicator>
          </TableCell>
          <RowActions
            actions={[
              binding.enabled
                ? {
                    icon: <RiPauseCircleLine />,
                    label: t('common.disable'),
                    pending: disableBinding.isPending,
                    onAction: () =>
                      disableBinding.mutate({ path: { agent_uid: binding.agent_uid, binding_name: binding.name } })
                  }
                : {
                    icon: <RiPlayCircleLine />,
                    label: t('common.enable'),
                    pending: enableBinding.isPending,
                    onAction: () =>
                      enableBinding.mutate({
                        path: { agent_uid: binding.agent_uid, binding_name: binding.name },
                        body: {
                          target_agent_uid: binding.agent_uid,
                          config: {},
                          group_message_mode: groupMessageModeFromPolicy(binding.unaddressed_group_message_policy),
                          unmatched_sender_policy: binding.unmatched_sender_policy
                        }
                      })
                  }
            ]}
            editTo={editTo(binding.agent_uid, binding.adapter, binding.name, scope.agentUID)}
            editLabel={t('common.edit')}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function StoppedDeliveries({
  onRetry,
  retryPending,
  rows
}: {
  onRetry: (agentUID: string, bindingName: string, outboundKey: string) => void
  retryPending: boolean
  rows: SignalDeliveryFailureItem[]
}) {
  const { t } = useTranslation()

  return (
    <section aria-labelledby="stopped-deliveries-title" className="grid gap-3">
      <div>
        <h2 id="stopped-deliveries-title" className="text-base font-semibold">
          {t('console.signals.stopped_deliveries')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">{t('console.signals.stopped_deliveries_description')}</p>
      </div>
      <Table
        className="min-w-[800px]"
        containerClassName="border border-border bg-card"
        containerLabel={t('console.signals.stopped_deliveries')}>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.signals.name')}</TableHead>
            <TableHead>{t('console.agents.agent')}</TableHead>
            <TableHead>{t('console.signals.delivery_reply')}</TableHead>
            <TableHead>{t('console.signals.delivery_attempts')}</TableHead>
            <TableHead>{t('console.signals.state')}</TableHead>
            <TableHead>{t('console.signals.delivery_duplicate_risk')}</TableHead>
            <TableHead>{t('console.signals.delivery_updated')}</TableHead>
            <TableHead className="text-right">{t('console.actions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map(row => (
            <TableRow key={`${row.agent_uid}:${row.binding_name}:${row.outbound_key}`}>
              <TableCell className="font-mono text-xs">{row.binding_name}</TableCell>
              <AgentCell uid={row.agent_uid} />
              <TableCell>
                <span className="block max-w-64 truncate font-mono text-xs" title={row.outbound_key}>
                  {row.outbound_key}
                </span>
              </TableCell>
              <TableCell>
                {row.attempt_count}/{row.max_attempts}
              </TableCell>
              <TableCell>
                <StatusIndicator tone="danger">{t(`console.signals.delivery_state_${row.state}`)}</StatusIndicator>
              </TableCell>
              <TableCell>{row.possible_duplicate ? t('console.signals.delivery_possible_duplicate') : '—'}</TableCell>
              <TableCell>{formatConsoleDate(row.updated_at)}</TableCell>
              <TableCell className="text-right">
                {row.can_retry ? (
                  <Button
                    disabled={retryPending}
                    size="sm"
                    type="button"
                    variant="outline"
                    onClick={() => onRetry(row.agent_uid, row.binding_name, row.outbound_key)}>
                    {t('common.retry')}
                  </Button>
                ) : (
                  <span className="text-xs text-muted-foreground">{t('console.signals.delivery_retry_unsafe')}</span>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </section>
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
  const returnAgentUID = searchParams.get('return_agent') ?? ''
  const lockedAdapter = searchParams.get('adapter') ?? undefined
  const lockedName = searchParams.get('name') ?? undefined
  const editing = Boolean(lockedName)
  const returnPath = signalBindingReturnPath(returnAgentUID)

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const defaultAgentUID = resolveAgentUID(agentList, sourceAgentUID)
  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const signalAdapters = adapters.data?.signal_adapters ?? []
  const adapterGroups = groupSignalAdapters(signalAdapters)
  const bindingDetail = useQuery({
    ...ankoleWebSignalBindingControllerShowOptions({
      path: { agent_uid: sourceAgentUID, binding_name: lockedName ?? '' }
    }),
    enabled: editing && Boolean(sourceAgentUID),
    retry: false
  })
  const currentBinding = bindingDetail.data?.signal_binding

  const activeAdapter =
    signalAdapters.find(adapter => adapter.adapter_id === model.adapterID.value) ??
    (editing ? undefined : signalAdapters[0])

  const ready = agents.data !== undefined && signalAdapters.length > 0 && (!editing || bindingDetail.data !== undefined)
  useEffect(() => {
    if (!ready) return
    const adapterID = currentBinding?.adapter ?? lockedAdapter
    const adapter = signalAdapters.find(item => item.adapter_id === adapterID) ?? signalAdapters[0]
    const draft =
      editing && currentBinding ? formFromBinding(currentBinding, bindingDetail.data?.config) : formFromAdapter(adapter)
    model.initialize(`binding:${sourceAgentUID}:${lockedAdapter ?? ''}:${lockedName ?? 'new'}`, {
      // An existing binding stays pinned to its stored agent; a fallback here
      // would silently move the binding on save.
      agentUID: editing ? (currentBinding?.agent_uid ?? '') : defaultAgentUID,
      ...draft
    })
  }, [
    bindingDetail.data?.config,
    currentBinding,
    defaultAgentUID,
    editing,
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
      finishSignalBindingSave(
        t('console.signals.saved', { name: variables.path.binding_name }),
        returnPath,
        queryClient,
        navigate
      )
    }
  })
  const updateBinding = useMutation({
    ...ankoleWebSignalBindingControllerUpdateBindingMutation(),
    onSuccess: (_data, variables) => {
      finishSignalBindingSave(
        t('console.signals.saved', { name: variables.path.binding_name }),
        returnPath,
        queryClient,
        navigate
      )
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
    const unmatchedSenderPolicy = asUnmatchedSenderPolicy(
      model.unmatchedSenderPolicy.value || defaultUnmatchedSenderPolicy(activeAdapter)
    )
    if (!unmatchedSenderPolicy) {
      model.validationError.value = t('console.signals.unmatched_sender_policy_invalid')
      return
    }
    const body = {
      config: editing ? model.configPatch.value : model.config.value,
      group_message_mode: groupMessageMode,
      unmatched_sender_policy: unmatchedSenderPolicy
    }
    if (editing) {
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
  const activeFields = activeAdapter?.fields ?? []
  const submitDisabled = editing && !model.dirty.value

  return (
    <ResourceEditorPage
      title={editing ? t('common.edit') : t('console.signals.new')}
      description={editing ? t('console.signals.edit_hint') : t('console.signals.editor_description')}
      backTo={returnPath}
      error={
        model.validationError.value ??
        agents.error ??
        adapters.error ??
        bindingDetail.error ??
        createBinding.error ??
        updateBinding.error
      }
      submitting={createBinding.isPending || updateBinding.isPending}
      submitDisabled={submitDisabled}
      submitUnavailable={!ready}
      contentWidth="wide"
      onSubmit={submit}>
      {/* Saving upserts the binding as enabled (server contract), so an operator
          editing a disabled rule must learn that before pressing Save. */}
      {editing && currentBinding && !currentBinding.enabled ? (
        <Alert variant="warning">
          <AlertDescription>{t('console.signals.edit_reenable_hint')}</AlertDescription>
        </Alert>
      ) : null}
      <FormSection title={t('console.signals.section_basic')} description={t('console.signals.section_basic_hint')}>
        <div className="grid grid-cols-1 gap-5 md:grid-cols-3">
          <LabeledField label={t('console.signals.target_agent')} required>
            <Select value={targetAgentUID || null} onValueChange={value => model.selectAgent(String(value))}>
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
          <LabeledField label={t('console.signals.adapter')} required={!editing}>
            {editing ? (
              <ReadOnlyValue>
                {activeAdapter
                  ? (localizedText(activeAdapter.display_name, locale) ?? activeAdapter.adapter_id)
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
                  {adapterGroups.map(group => (
                    <SelectGroup key={group.category}>
                      <SelectLabel>{t(group.labelKey)}</SelectLabel>
                      {group.adapters.map(adapter => (
                        <SelectItem key={adapter.adapter_id} value={adapter.adapter_id}>
                          {localizedText(adapter.display_name, locale) ?? adapter.adapter_id}
                        </SelectItem>
                      ))}
                    </SelectGroup>
                  ))}
                </SelectContent>
              </Select>
            )}
          </LabeledField>
          <LabeledField label={t('console.signals.binding_name')} required={!editing}>
            {editing ? (
              <ReadOnlyValue>{model.name.value}</ReadOnlyValue>
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
                field={activeAdapter.group_message_mode_field}
                locale={locale}
                value={model.groupMessageMode.value || defaultGroupMessageMode(activeAdapter)}
                onChange={value => (model.groupMessageMode.value = String(value) as GroupMessageMode)}
              />
              <ConfigField
                field={activeAdapter.unmatched_sender_policy_field}
                locale={locale}
                value={model.unmatchedSenderPolicy.value || defaultUnmatchedSenderPolicy(activeAdapter)}
                onChange={value => (model.unmatchedSenderPolicy.value = String(value) as UnmatchedSenderPolicy)}
              />
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
              preservedSecretPaths={bindingDetail.data?.stored_secret_paths}
              preservedSecretPlaceholder={t('common.secret_saved_placeholder')}
            />
          </FormSection>
        </>
      ) : null}
    </ResourceEditorPage>
  )
}

function editTo(agentUID: string, adapter: string, name: string, returnAgentUID: string): string {
  const query = signalBindingEditParams(agentUID, adapter, name, returnAgentUID)
  return `new?${query.toString()}`
}

function signalBindingEditParams(
  agentUID: string,
  adapter: string,
  name: string,
  returnAgentUID: string
): URLSearchParams {
  const query = new URLSearchParams({ agent: agentUID, adapter, name })
  if (returnAgentUID) query.set('return_agent', returnAgentUID)
  return query
}

function signalBindingReturnPath(agentUID: string): string {
  if (!agentUID) return '/signals'
  return `/signals?${new URLSearchParams({ agent: agentUID })}`
}

export function finishSignalBindingSave(
  message: string,
  returnPath: string,
  queryClient: Pick<QueryClient, 'invalidateQueries'>,
  navigate: (path: string) => unknown
): void {
  toast.success(message)
  void queryClient.invalidateQueries()
  navigate(returnPath)
}

function emptyForm(): SignalBindingAdapterDraft {
  return {
    adapterID: '',
    name: '',
    groupMessageMode: '',
    unmatchedSenderPolicy: '',
    config: {}
  }
}

function formFromAdapter(adapter: SignalAdapterItem | undefined): SignalBindingAdapterDraft {
  if (!adapter) return emptyForm()
  return {
    adapterID: adapter.adapter_id,
    name: `${adapter.adapter_id}-main`,
    groupMessageMode: defaultGroupMessageMode(adapter),
    unmatchedSenderPolicy: defaultUnmatchedSenderPolicy(adapter),
    config: defaultConfig(adapter.fields)
  }
}

function formFromBinding(binding: SignalBindingItem, config: unknown): SignalBindingAdapterDraft {
  return {
    adapterID: binding.adapter,
    name: binding.name,
    groupMessageMode: groupMessageModeFromPolicy(binding.unaddressed_group_message_policy),
    unmatchedSenderPolicy: binding.unmatched_sender_policy,
    config: asJSONObject(config)
  }
}

function asJSONObject(value: unknown): JSONObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as JSONObject) : {}
}

function defaultGroupMessageMode(adapter: SignalAdapterItem): GroupMessageMode | '' {
  const field = adapter.group_message_mode_field
  return asGroupMessageMode(typeof field.default === 'string' ? field.default : undefined) ?? ''
}

function asGroupMessageMode(value: string | undefined): GroupMessageMode | undefined {
  if (value === 'addressed_only' || value === 'observe_all' || value === 'may_intervene') return value
  return undefined
}

function defaultUnmatchedSenderPolicy(adapter: SignalAdapterItem): UnmatchedSenderPolicy | '' {
  const field = adapter.unmatched_sender_policy_field
  return asUnmatchedSenderPolicy(typeof field.default === 'string' ? field.default : undefined) ?? ''
}

function asUnmatchedSenderPolicy(value: string | undefined): UnmatchedSenderPolicy | undefined {
  if (value === 'manual_review' || value === 'create_standalone') return value
  return undefined
}

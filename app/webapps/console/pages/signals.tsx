import {
  Badge,
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
import { type JsonObject as JSONObject } from '@pleisto/active-support'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useSearchParams } from 'react-router'
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
import type { SignalAdapterItem, SignalBindingWriteRequest } from '../api/generated/types.gen'
import { LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'

type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

export function SignalsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const agentUID = searchParams.get('agent') ?? agentList[0]?.uid ?? ''
  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const rows = bindings.data?.signal_bindings ?? []
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
      toolbar={
        <div className="max-w-sm">
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
      }>
      {rows.map(binding => (
        <TableRow
          key={`${binding.adapter}:${binding.name}`}
          className="cursor-pointer"
          onClick={() => navigate(reconfigureTo(agentUID, binding.adapter, binding.name))}>
          <TableCell className="font-mono text-xs">{binding.name}</TableCell>
          <TableCell>{binding.adapter}</TableCell>
          <TableCell>{binding.unaddressed_group_message_policy}</TableCell>
          <TableCell>
            <Badge variant={binding.enabled ? 'default' : 'secondary'}>
              {binding.enabled ? t('console.status.enabled') : t('console.status.disabled')}
            </Badge>
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

type SignalForm = {
  adapterID: string
  name: string
  groupMessageMode: GroupMessageMode | ''
  config: JSONObject
}

export function SignalBindingEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams] = useSearchParams()
  const locale = i18n.language

  const agentUID = searchParams.get('agent') ?? ''
  const lockedAdapter = searchParams.get('adapter') ?? undefined
  const lockedName = searchParams.get('name') ?? undefined
  const reconfigure = Boolean(lockedName)

  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const signalAdapters = adapters.data?.signal_adapters ?? []

  const [form, setForm] = useState<SignalForm>(emptyForm())
  const [error, setError] = useState<string>()
  const activeAdapter = signalAdapters.find(adapter => adapter.adapter_id === form.adapterID) ?? signalAdapters[0]

  const ready = signalAdapters.length > 0
  useEffect(() => {
    if (!ready) return
    const adapter = signalAdapters.find(item => item.adapter_id === lockedAdapter) ?? signalAdapters[0]
    setForm(formFromAdapter(adapter, lockedName))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, lockedAdapter, lockedName])

  const saveBinding = useMutation({
    ...ankoleWebSignalBindingControllerPutBindingMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.signals.saved', { name: variables.path.binding_name }))
      void queryClient.invalidateQueries()
      navigate(`..?agent=${encodeURIComponent(agentUID)}`)
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })

  const submit = () => {
    setError(undefined)
    if (!activeAdapter || !agentUID) return
    const name = form.name.trim()
    if (!name) {
      setError(t('console.signals.binding_name_required'))
      return
    }
    const groupMessageMode = asGroupMessageMode(form.groupMessageMode || defaultGroupMessageMode(activeAdapter))
    if (!groupMessageMode) {
      setError(t('console.signals.group_message_mode_invalid'))
      return
    }
    saveBinding.mutate({
      body: { config: form.config, group_message_mode: groupMessageMode },
      path: { adapter_id: activeAdapter.adapter_id, agent_uid: agentUID, binding_name: name }
    })
  }

  return (
    <ResourceEditorPage
      title={reconfigure ? t('console.signals.reconfigure') : t('console.signals.new')}
      description={reconfigure ? t('console.signals.reconfigure_hint') : t('console.signals.editor_description')}
      backTo={`..?agent=${encodeURIComponent(agentUID)}`}
      error={error ?? adapters.error ?? saveBinding.error}
      submitting={saveBinding.isPending}
      onSubmit={submit}>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.signals.adapter')}>
          <Select
            disabled={reconfigure}
            value={activeAdapter?.adapter_id ?? ''}
            onValueChange={value => {
              const adapter = signalAdapters.find(item => item.adapter_id === value)
              if (adapter) setForm(formFromAdapter(adapter))
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
        </LabeledField>
        <LabeledField label={t('console.signals.binding_name')} required>
          <Input
            disabled={reconfigure}
            value={form.name}
            onChange={event => setForm(current => ({ ...current, name: event.target.value }))}
          />
        </LabeledField>
      </div>

      {activeAdapter ? (
        <>
          <ConfigField
            field={asConfigField(activeAdapter.group_message_mode_field)}
            locale={locale}
            value={form.groupMessageMode || defaultGroupMessageMode(activeAdapter)}
            onChange={value =>
              setForm(current => ({ ...current, groupMessageMode: String(value) as GroupMessageMode }))
            }
          />
          <ConfigFields
            config={form.config}
            fields={asConfigFields(activeAdapter.fields)}
            locale={locale}
            onChange={(path, value) =>
              setForm(current => ({ ...current, config: setPath(current.config, path, value) }))
            }
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

function emptyForm(): SignalForm {
  return { adapterID: '', name: '', groupMessageMode: '', config: {} }
}

function formFromAdapter(adapter: SignalAdapterItem | undefined, name?: string): SignalForm {
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

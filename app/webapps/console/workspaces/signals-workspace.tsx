import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow
} from '@ankole/uikit'
import { type JsonObject } from '@pleisto/active-support'
import { RiCloseLine, RiSave3Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
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
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebSignalBindingControllerAdaptersOptions,
  ankoleWebSignalBindingControllerDeleteMutation,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebSignalBindingControllerPutBindingMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem, SignalAdapterItem, SignalBindingWriteRequest } from '../api/generated/types.gen'
import { ErrorBlock, Field, ResourceTable, WorkspaceShell, useSelectFirst } from '../console-primitives'

type SignalDraft = {
  name: string
  adapterId: string
  config: JsonObject
  groupMessageMode: GroupMessageMode | ''
  error?: string
}

type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

export function SignalsWorkspace() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const [selectedUid, setSelectedUid] = useSelectFirst(agents.data?.data, agent => agent.uid)
  const selectedAgent = agents.data?.data.find(agent => agent.uid === selectedUid)
  const signalAdapters = adapters.data?.data ?? []
  const bindings = useQuery({
    ...ankoleWebSignalBindingControllerIndexOptions({
      path: { agent_uid: selectedAgent?.uid ?? '' }
    }),
    enabled: Boolean(selectedAgent?.uid)
  })
  const [draft, setDraft] = useState<SignalDraft>(emptySignalDraft())
  const activeAdapter = signalAdapters.find(adapter => adapter.adapter_id === draft.adapterId) ?? signalAdapters[0]
  const locale = i18n.language
  const refresh = () => void queryClient.invalidateQueries()
  const saveBinding = useMutation({ ...ankoleWebSignalBindingControllerPutBindingMutation(), onSuccess: refresh })
  const deleteBinding = useMutation({ ...ankoleWebSignalBindingControllerDeleteMutation(), onSuccess: refresh })

  useEffect(() => {
    if (signalAdapters.length === 0) return
    if (draft.adapterId && signalAdapters.some(adapter => adapter.adapter_id === draft.adapterId)) return
    setDraft(draftFromSignalAdapter(signalAdapters[0]))
  }, [draft.adapterId, signalAdapters])

  const submit = () => {
    if (!selectedAgent || !activeAdapter) return
    const name = draft.name.trim()
    const groupMessageMode = asGroupMessageMode(draft.groupMessageMode || defaultGroupMessageMode(activeAdapter))

    if (!name) {
      setDraft(current => ({ ...current, error: t('console.signals.binding_name_required') }))
      return
    }

    if (!groupMessageMode) {
      setDraft(current => ({ ...current, error: t('console.signals.group_message_mode_invalid') }))
      return
    }

    saveBinding.mutate({
      body: { config: draft.config, group_message_mode: groupMessageMode },
      path: { adapter_id: activeAdapter.adapter_id, agent_uid: selectedAgent.uid, binding_name: name }
    })
  }

  return (
    <WorkspaceShell title={t('console.signals.title')}>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <AgentSelector agents={agents.data?.data ?? []} value={selectedUid} onChange={setSelectedUid} />
          <div className="mt-4">
            <ErrorBlock error={agents.error ?? adapters.error ?? bindings.error} />
            <ResourceTable
              columns={[
                t('console.signals.name'),
                t('console.signals.adapter'),
                t('console.signals.policy'),
                t('console.signals.state')
              ]}
              empty={!bindings.isLoading && (bindings.data?.data.length ?? 0) === 0}
              loading={bindings.isLoading || agents.isLoading}>
              {bindings.data?.data.map(binding => (
                <TableRow key={`${binding.adapter}:${binding.name}`}>
                  <TableCell className="font-mono text-xs">{binding.name}</TableCell>
                  <TableCell>{binding.adapter}</TableCell>
                  <TableCell>{binding.unaddressed_group_message_policy}</TableCell>
                  <TableCell>
                    <div className="flex items-center justify-between gap-3">
                      <Badge variant={binding.enabled ? 'default' : 'secondary'}>
                        {binding.enabled ? t('console.status.enabled') : t('console.status.disabled')}
                      </Badge>
                      <Button
                        aria-label={t('console.aria.disable_binding')}
                        disabled={!selectedAgent || deleteBinding.isPending}
                        size="icon-xs"
                        type="button"
                        variant="ghost"
                        onClick={() =>
                          selectedAgent &&
                          deleteBinding.mutate({
                            path: { agent_uid: selectedAgent.uid, binding_name: binding.name }
                          })
                        }>
                        <RiCloseLine />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </ResourceTable>
          </div>
        </div>
        <Card size="sm" className="min-w-0">
          <CardHeader>
            <CardTitle>
              {activeAdapter
                ? localizedUnknown(activeAdapter.display_name, locale, activeAdapter.adapter_id)
                : t('console.signals.new')}
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? adapters.error ?? saveBinding.error ?? deleteBinding.error} />
            <Field label={t('console.signals.adapter')}>
              <Select
                value={activeAdapter?.adapter_id ?? ''}
                onValueChange={value => {
                  const adapter = signalAdapters.find(item => item.adapter_id === value)
                  if (adapter) setDraft(draftFromSignalAdapter(adapter))
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
            </Field>
            <Field label={t('console.signals.binding_name')}>
              <Input
                value={draft.name}
                onChange={event => setDraft(current => ({ ...current, name: event.target.value }))}
              />
            </Field>
            {activeAdapter ? (
              <>
                <ConfigField
                  field={asConfigField(activeAdapter.group_message_mode_field)}
                  locale={locale}
                  value={draft.groupMessageMode || defaultGroupMessageMode(activeAdapter)}
                  onChange={value =>
                    setDraft(current => ({
                      ...current,
                      groupMessageMode: String(value) as SignalDraft['groupMessageMode']
                    }))
                  }
                />
                <ConfigFields
                  config={draft.config}
                  fieldGroupClassName="grid gap-4 md:grid-cols-2"
                  fields={asConfigFields(activeAdapter.fields)}
                  locale={locale}
                  onChange={(path, value) =>
                    setDraft(current => ({ ...current, config: setPath(current.config, path, value) }))
                  }
                />
              </>
            ) : null}
            <Button
              disabled={!selectedAgent || !activeAdapter || saveBinding.isPending}
              size="sm"
              type="button"
              onClick={submit}>
              <RiSave3Line data-icon="inline-start" />
              {t('common.save')}
            </Button>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function AgentSelector({
  agents,
  onChange,
  value
}: {
  agents: AgentItem[]
  onChange: (uid: string) => void
  value: string | null
}) {
  const { t } = useTranslation()
  return (
    <Field label={t('console.agents.agent')}>
      <Select value={value ?? ''} onValueChange={next => onChange(String(next))}>
        <SelectTrigger className="w-full md:max-w-sm">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {agents.map(agent => (
            <SelectItem key={agent.uid} value={agent.uid}>
              {agent.uid}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </Field>
  )
}

function emptySignalDraft(): SignalDraft {
  return {
    adapterId: '',
    config: {},
    groupMessageMode: '',
    name: ''
  }
}

function draftFromSignalAdapter(adapter: SignalAdapterItem): SignalDraft {
  return {
    adapterId: adapter.adapter_id,
    config: defaultConfig(asConfigFields(adapter.fields)),
    groupMessageMode: defaultGroupMessageMode(adapter),
    name: `${adapter.adapter_id}-main`
  }
}

function asConfigFields(fields: readonly unknown[]): ConfigFieldDefinition[] {
  return fields.map(asConfigField)
}

function asConfigField(field: unknown) {
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

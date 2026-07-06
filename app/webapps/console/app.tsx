import {
  RiAddLine,
  RiBroadcastLine,
  RiCloseLine,
  RiDeleteBin6Line,
  RiEyeLine,
  RiLogoutBoxRLine,
  RiRefreshLine,
  RiRobot2Line,
  RiSave3Line,
  RiSettings3Line,
  RiSparkling2Line
} from '@remixicon/react'
import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Checkbox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Separator,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { ComponentType, ReactNode } from 'react'
import { useEffect, useMemo, useState } from 'react'
import {
  ConfigField,
  ConfigFields,
  defaultConfig,
  getPath,
  localizedText,
  setPath,
  type ConfigFieldDefinition,
  type LocalizedText
} from '../common/config-fields'
import i18n from '../common/i18n'
import { recordValue, type JsonObject } from '@pleisto/active-support'
import { requestErrorMessage } from '../common/request-errors'
import {
  ankoleWebAgentControllerCreateMutation,
  ankoleWebAgentControllerDeleteMutation,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentControllerUpdateMutation,
  ankoleWebAiGatewayProviderControllerDeleteModelProfileMutation,
  ankoleWebAiGatewayProviderControllerDeleteProviderMutation,
  ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions,
  ankoleWebAiGatewayProviderControllerPutModelProfileMutation,
  ankoleWebAiGatewayProviderControllerPutProviderMutation,
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerDeleteMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerUpdateMutation,
  ankoleWebIdentityProviderControllerAdaptersOptions,
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebIdentityProviderControllerPutProviderMutation,
  ankoleWebIdentityProviderControllerRunSyncMutation,
  ankoleWebSignalBindingControllerAdaptersOptions,
  ankoleWebSignalBindingControllerDeleteMutation,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebSignalBindingControllerPutBindingMutation
} from './api/generated/@tanstack/react-query.gen'
import type {
  AgentItem,
  AiGatewayProviderItem,
  AiGatewayProviderKindItem,
  AppConfigurationItem,
  IdentityProviderAdapterItem,
  IdentityProviderItem,
  SignalAdapterItem,
  SignalBindingWriteRequest
} from './api/generated/types.gen'
import { configureConsoleApiClient, logoutConsoleSession } from './api/tokens'

type Section = 'agents' | 'providers' | 'identity' | 'signals' | 'settings'

type NavItem = {
  id: Section
  label: string
  icon: ComponentType<{ className?: string }>
}

type AgentDraft = {
  uid: string
  displayName: string
  avatarUrl: string
  role: string
  options: string
  error?: string
}

type ProviderDraft = {
  providerId: string
  providerKind: string
  baseUrl: string
  connectionOptions: string
  error?: string
}

type IdentityProviderDraft = {
  adapterId: string
  config: JsonObject
  enabled: boolean
  error?: string
  providerId: string
}

type ProfileDraft = {
  providerId: string
  model: string
  contextLength: string
  providerOptions: string
  error?: string
}

type SignalDraft = {
  name: string
  adapterId: string
  config: JsonObject
  groupMessageMode: GroupMessageMode | ''
  error?: string
}

type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

type ConfigDraft = {
  text: string
  error?: string
}

const NAV_ITEMS: NavItem[] = [
  { id: 'agents', label: 'Agents', icon: RiRobot2Line },
  { id: 'providers', label: 'LLM Providers', icon: RiSparkling2Line },
  { id: 'identity', label: 'Identity Providers', icon: RiSettings3Line },
  { id: 'signals', label: 'Signal Bindings', icon: RiBroadcastLine },
  { id: 'settings', label: 'AppConfigure', icon: RiSettings3Line }
]

const PROFILE_NAMES = ['primary', 'light', 'heavy', 'embedding', 'rerank'] as const
const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

export function ConsoleApp() {
  useMemo(() => configureConsoleApiClient(), [])

  const [section, setSection] = useState<Section>('agents')
  const queryClient = useQueryClient()
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <main className="min-h-screen bg-background text-foreground">
      <header className="flex h-14 items-center justify-between border-b border-border px-4">
        <div className="flex min-w-0 items-center gap-3">
          <div className="grid size-9 place-items-center border border-border bg-muted">
            <RiSettings3Line className="size-4" aria-hidden />
          </div>
          <div className="min-w-0">
            <h1 className="truncate text-base font-semibold tracking-normal">Ankole Console</h1>
            <p className="truncate text-xs text-muted-foreground">Control plane</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button
            aria-label="Refresh"
            size="icon-sm"
            type="button"
            variant="outline"
            onClick={() => void queryClient.invalidateQueries()}>
            <RiRefreshLine />
          </Button>
          <Button
            aria-label="Sign out"
            disabled={logout.isPending}
            size="icon-sm"
            type="button"
            variant="ghost"
            onClick={() => logout.mutate()}>
            <RiLogoutBoxRLine />
          </Button>
        </div>
      </header>

      <div className="grid min-h-[calc(100vh-3.5rem)] grid-cols-1 lg:grid-cols-[248px_minmax(0,1fr)]">
        <aside className="border-b border-border bg-muted/35 p-3 lg:border-r lg:border-b-0">
          <nav className="grid gap-1" aria-label="Console sections">
            {NAV_ITEMS.map(item => {
              const Icon = item.icon
              const active = item.id === section
              return (
                <button
                  key={item.id}
                  className={
                    active
                      ? 'flex h-10 items-center gap-3 border border-primary bg-primary px-3 text-left text-sm text-primary-foreground'
                      : 'flex h-10 items-center gap-3 border border-transparent px-3 text-left text-sm text-muted-foreground hover:border-border hover:bg-background hover:text-foreground'
                  }
                  type="button"
                  onClick={() => setSection(item.id)}>
                  <Icon className="size-4" aria-hidden />
                  <span className="truncate">{item.label}</span>
                </button>
              )
            })}
          </nav>
        </aside>

        <section className="min-w-0 p-4 md:p-6">
          {section === 'agents' ? <AgentsWorkspace /> : null}
          {section === 'providers' ? <ProvidersWorkspace /> : null}
          {section === 'identity' ? <IdentityProvidersWorkspace /> : null}
          {section === 'signals' ? <SignalsWorkspace /> : null}
          {section === 'settings' ? <AppConfigureWorkspace /> : null}
        </section>
      </div>
    </main>
  )
}

function AgentsWorkspace() {
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedUid, setSelectedUid] = useState<string | null>(null)
  const selectedAgent = agents.data?.data.find(agent => agent.uid === selectedUid)
  const modelProfiles = useQuery({
    ...ankoleWebAiGatewayProviderControllerIndexModelProfilesOptions({
      path: { agent_uid: selectedAgent?.uid ?? '' }
    }),
    enabled: Boolean(selectedAgent?.uid)
  })
  const [draft, setDraft] = useState<AgentDraft>(emptyAgentDraft())

  const refresh = () => void queryClient.invalidateQueries()
  const createAgent = useMutation({ ...ankoleWebAgentControllerCreateMutation(), onSuccess: refresh })
  const updateAgent = useMutation({ ...ankoleWebAgentControllerUpdateMutation(), onSuccess: refresh })
  const deleteAgent = useMutation({
    ...ankoleWebAgentControllerDeleteMutation(),
    onSuccess: () => {
      setMode('new')
      setSelectedUid(null)
      refresh()
    }
  })

  useEffect(() => {
    if (!selectedUid && agents.data?.data[0]) {
      setSelectedUid(agents.data.data[0].uid)
      setMode('edit')
    }
  }, [agents.data?.data, selectedUid])

  useEffect(() => {
    setDraft(mode === 'edit' && selectedAgent ? draftFromAgent(selectedAgent) : emptyAgentDraft())
  }, [mode, selectedAgent?.uid])

  const saveAgent = () => {
    const parsed = parseObjectDraft(draft.options, 'options')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }

    const body = {
      display_name: blankToNull(draft.displayName),
      avatar_url: blankToNull(draft.avatarUrl),
      role: draft.role.trim(),
      options: parsed.value
    }

    if (mode === 'new') {
      createAgent.mutate({
        body: {
          ...body,
          uid: draft.uid.trim()
        }
      })
      return
    }

    if (selectedAgent) {
      updateAgent.mutate({
        body,
        path: { agent_uid: selectedAgent.uid }
      })
    }
  }

  return (
    <WorkspaceShell
      title="Agents"
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedUid(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          New
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={agents.error} />
          <ResourceTable
            columns={['UID', 'Role', 'Status']}
            empty={!agents.isLoading && (agents.data?.data.length ?? 0) === 0}
            loading={agents.isLoading}>
            {agents.data?.data.map(agent => (
              <TableRow
                key={agent.uid}
                data-state={agent.uid === selectedAgent?.uid ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedUid(agent.uid)
                }}>
                <TableCell className="font-mono text-xs">{agent.uid}</TableCell>
                <TableCell>{agent.role}</TableCell>
                <TableCell>
                  <Badge variant={agent.status === 'active' ? 'default' : 'secondary'}>{agent.status}</Badge>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>

        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle>{mode === 'new' ? 'New agent' : selectedAgent?.uid}</CardTitle>
              {mode === 'edit' && selectedAgent ? (
                <Button
                  aria-label="Disable agent"
                  disabled={deleteAgent.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => deleteAgent.mutate({ path: { agent_uid: selectedAgent.uid } })}>
                  <RiDeleteBin6Line />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? createAgent.error ?? updateAgent.error ?? deleteAgent.error} />
            <Field label="UID">
              <Input
                disabled={mode === 'edit'}
                value={draft.uid}
                onChange={event => setDraft(current => ({ ...current, uid: event.target.value }))}
              />
            </Field>
            <div className="grid gap-4 md:grid-cols-2">
              <Field label="Display name">
                <Input
                  value={draft.displayName}
                  onChange={event => setDraft(current => ({ ...current, displayName: event.target.value }))}
                />
              </Field>
              <Field label="Role">
                <Input
                  value={draft.role}
                  onChange={event => setDraft(current => ({ ...current, role: event.target.value }))}
                />
              </Field>
            </div>
            <Field label="Avatar URL">
              <Input
                value={draft.avatarUrl}
                onChange={event => setDraft(current => ({ ...current, avatarUrl: event.target.value }))}
              />
            </Field>
            <Field label="Options">
              <Textarea
                className="min-h-40 font-mono text-xs"
                spellCheck={false}
                value={draft.options}
                onChange={event => setDraft(current => ({ ...current, options: event.target.value }))}
              />
            </Field>
            <div className="flex flex-wrap gap-2">
              <Button
                disabled={createAgent.isPending || updateAgent.isPending}
                size="sm"
                type="button"
                onClick={saveAgent}>
                <RiSave3Line data-icon="inline-start" />
                Save
              </Button>
            </div>
            {selectedAgent ? (
              <>
                <Separator />
                <ModelProfilesEditor
                  agent={selectedAgent}
                  error={modelProfiles.error}
                  loading={modelProfiles.isLoading}
                  profiles={recordValue(modelProfiles.data?.data) ?? {}}
                  providers={providers.data?.data ?? []}
                  onChanged={refresh}
                />
              </>
            ) : null}
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function ProvidersWorkspace() {
  const queryClient = useQueryClient()
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery(ankoleWebAiGatewayProviderControllerProviderKindsOptions())
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const selected = providers.data?.data.find(provider => provider.provider_id === selectedId)
  const [draft, setDraft] = useState<ProviderDraft>(emptyProviderDraft())
  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({ ...ankoleWebAiGatewayProviderControllerPutProviderMutation(), onSuccess: refresh })
  const deleteProvider = useMutation({
    ...ankoleWebAiGatewayProviderControllerDeleteProviderMutation(),
    onSuccess: () => {
      setMode('new')
      setSelectedId(null)
      refresh()
    }
  })

  useEffect(() => {
    if (!selectedId && providers.data?.data[0]) {
      setSelectedId(providers.data.data[0].provider_id)
      setMode('edit')
    }
  }, [providers.data?.data, selectedId])

  useEffect(() => {
    setDraft(
      mode === 'edit' && selected ? draftFromProvider(selected) : emptyProviderDraft(providerKinds.data?.data[0])
    )
  }, [mode, selected?.provider_id, providerKinds.data?.data])

  const submit = () => {
    const parsed = parseObjectDraft(draft.connectionOptions, 'connection_options')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }

    const providerId = draft.providerId.trim()
    saveProvider.mutate({
      body: {
        provider_id: providerId,
        provider_kind: draft.providerKind,
        base_url: blankToNull(draft.baseUrl),
        connection_options: parsed.value
      },
      path: { provider_id: providerId }
    })
  }

  return (
    <WorkspaceShell
      title="LLM Providers"
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedId(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          New
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={providers.error ?? providerKinds.error} />
          <ResourceTable
            columns={['Provider', 'Kind', 'Credentials']}
            empty={!providers.isLoading && (providers.data?.data.length ?? 0) === 0}
            loading={providers.isLoading}>
            {providers.data?.data.map(provider => (
              <TableRow
                key={provider.provider_id}
                data-state={provider.provider_id === selected?.provider_id ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedId(provider.provider_id)
                }}>
                <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
                <TableCell>{provider.provider_kind}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-2">
                    {Object.entries(provider.encrypted_options).map(([key, option]) => (
                      <Badge key={key} variant={option.present ? 'default' : 'outline'}>
                        {key}
                      </Badge>
                    ))}
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>
        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle>{mode === 'new' ? 'New provider' : selected?.provider_id}</CardTitle>
              {mode === 'edit' && selected ? (
                <Button
                  aria-label="Disable provider"
                  disabled={deleteProvider.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => deleteProvider.mutate({ path: { provider_id: selected.provider_id } })}>
                  <RiDeleteBin6Line />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? saveProvider.error ?? deleteProvider.error} />
            <Field label="Provider ID">
              <Input
                disabled={mode === 'edit'}
                value={draft.providerId}
                onChange={event => setDraft(current => ({ ...current, providerId: event.target.value }))}
              />
            </Field>
            <Field label="Kind">
              <Select
                value={draft.providerKind}
                onValueChange={value => setDraft(current => ({ ...current, providerKind: String(value) }))}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(providerKinds.data?.data ?? []).map(kind => (
                    <SelectItem key={kind.provider_kind} value={kind.provider_kind}>
                      {providerKindLabel(kind)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Base URL">
              <Input
                value={draft.baseUrl}
                onChange={event => setDraft(current => ({ ...current, baseUrl: event.target.value }))}
              />
            </Field>
            <Field label="Connection options">
              <Textarea
                className="min-h-52 font-mono text-xs"
                spellCheck={false}
                value={draft.connectionOptions}
                onChange={event => setDraft(current => ({ ...current, connectionOptions: event.target.value }))}
              />
            </Field>
            <Button disabled={saveProvider.isPending} size="sm" type="button" onClick={submit}>
              <RiSave3Line data-icon="inline-start" />
              Save
            </Button>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function IdentityProvidersWorkspace() {
  const queryClient = useQueryClient()
  const adapters = useQuery(ankoleWebIdentityProviderControllerAdaptersOptions())
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const identityAdapters = adapters.data?.data ?? []
  const identityProviders = providers.data?.data ?? []
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const selected = identityProviders.find(provider => provider.provider_id === selectedId)
  const [draft, setDraft] = useState<IdentityProviderDraft>(emptyIdentityProviderDraft(identityAdapters[0]))
  const activeAdapter =
    identityAdapters.find(adapter => adapter.adapter_id === draft.adapterId) ??
    identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id) ??
    identityAdapters[0]
  const selectedAdapter = identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id)
  const locale = i18n.language
  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({
    ...ankoleWebIdentityProviderControllerPutProviderMutation(),
    onSuccess: response => {
      setMode('edit')
      setSelectedId(response.data.provider_id)
      refresh()
    }
  })
  const runSync = useMutation({ ...ankoleWebIdentityProviderControllerRunSyncMutation(), onSuccess: refresh })

  useEffect(() => {
    if (!selectedId && identityProviders[0]) {
      setSelectedId(identityProviders[0].provider_id)
      setMode('edit')
    }
  }, [identityProviders, selectedId])

  useEffect(() => {
    if (mode === 'edit' && selected) {
      setDraft(draftFromIdentityProvider(selected))
      return
    }

    if (mode === 'new' && identityAdapters[0]) setDraft(emptyIdentityProviderDraft(identityAdapters[0]))
  }, [mode, selected?.provider_id, identityAdapters])

  const save = () => {
    if (!activeAdapter) return

    const providerId = draft.providerId.trim()
    if (!providerId) {
      setDraft(current => ({ ...current, error: 'Provider ID is required.' }))
      return
    }

    saveProvider.mutate({
      body: {
        adapter_id: activeAdapter.adapter_id,
        config: draft.config,
        enabled: draft.enabled
      },
      path: { provider_id: providerId }
    })
  }

  const canRunSync = Boolean(
    mode === 'edit' &&
    selected &&
    selected.enabled &&
    selectedAdapter &&
    identityProviderSupportsDirectoryFullSync(selectedAdapter) &&
    identityProviderSyncEnabled(selected)
  )

  return (
    <WorkspaceShell
      title="Identity Providers"
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedId(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          New
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={providers.error ?? adapters.error} />
          <ResourceTable
            columns={['Provider', 'Adapter', 'Sync', 'State']}
            empty={!providers.isLoading && identityProviders.length === 0}
            loading={providers.isLoading || adapters.isLoading}>
            {identityProviders.map(provider => (
              <TableRow
                key={provider.provider_id}
                data-state={provider.provider_id === selected?.provider_id ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedId(provider.provider_id)
                }}>
                <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
                <TableCell>{provider.adapter_id}</TableCell>
                <TableCell>
                  <Badge variant={identityProviderSyncEnabled(provider) ? 'default' : 'outline'}>
                    {identityProviderSyncEnabled(provider) ? 'contacts' : 'off'}
                  </Badge>
                </TableCell>
                <TableCell>
                  <Badge variant={provider.enabled ? 'default' : 'secondary'}>
                    {provider.enabled ? 'enabled' : 'disabled'}
                  </Badge>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>

        <Card size="sm" className="min-w-0">
          <CardHeader>
            <CardTitle>{mode === 'new' ? 'New identity provider' : selected?.provider_id}</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? saveProvider.error ?? runSync.error} />
            <Field label="Adapter">
              <Select
                disabled={mode === 'edit'}
                value={activeAdapter?.adapter_id ?? ''}
                onValueChange={value => {
                  const adapter = identityAdapters.find(item => item.adapter_id === value)
                  if (adapter) setDraft(emptyIdentityProviderDraft(adapter))
                }}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {identityAdapters.map(adapter => (
                    <SelectItem key={adapter.adapter_id} value={adapter.adapter_id}>
                      {localizedUnknown(adapter.display_name, locale, adapter.adapter_id)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Provider ID">
              <Input
                disabled={mode === 'edit'}
                value={draft.providerId}
                onChange={event => setDraft(current => ({ ...current, providerId: event.target.value }))}
              />
            </Field>
            <div className="flex items-center justify-between gap-4 border border-border/70 bg-card/60 p-4">
              <div className="grid gap-1">
                <span className="text-sm font-medium">Enabled</span>
                <span className="text-xs text-muted-foreground">Available for login and directory sync.</span>
              </div>
              <Checkbox
                checked={draft.enabled}
                onCheckedChange={checked => setDraft(current => ({ ...current, enabled: checked === true }))}
              />
            </div>
            {activeAdapter ? (
              <ConfigFields
                config={draft.config}
                fieldGroupClassName="grid gap-4 md:grid-cols-2"
                fields={asConfigFields(activeAdapter.fields)}
                locale={locale}
                onChange={(path, value) =>
                  setDraft(current => ({ ...current, config: setPath(current.config, path, value) }))
                }
              />
            ) : null}
            <div className="flex flex-wrap gap-2">
              <Button disabled={!activeAdapter || saveProvider.isPending} size="sm" type="button" onClick={save}>
                <RiSave3Line data-icon="inline-start" />
                Save
              </Button>
              {canRunSync ? (
                <Button
                  disabled={runSync.isPending}
                  size="sm"
                  type="button"
                  variant="outline"
                  onClick={() => selected && runSync.mutate({ path: { provider_id: selected.provider_id } })}>
                  <RiRefreshLine data-icon="inline-start" />
                  Run full sync
                </Button>
              ) : null}
            </div>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function SignalsWorkspace() {
  const queryClient = useQueryClient()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const adapters = useQuery(ankoleWebSignalBindingControllerAdaptersOptions())
  const [selectedUid, setSelectedUid] = useState<string | null>(null)
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
    if (!selectedUid && agents.data?.data[0]) setSelectedUid(agents.data.data[0].uid)
  }, [agents.data?.data, selectedUid])

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
      setDraft(current => ({ ...current, error: 'Binding name is required.' }))
      return
    }

    if (!groupMessageMode) {
      setDraft(current => ({ ...current, error: 'Group message mode is invalid.' }))
      return
    }

    saveBinding.mutate({
      body: { config: draft.config, group_message_mode: groupMessageMode },
      path: { adapter_id: activeAdapter.adapter_id, agent_uid: selectedAgent.uid, binding_name: name }
    })
  }

  return (
    <WorkspaceShell title="Signal Bindings">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <AgentSelector agents={agents.data?.data ?? []} value={selectedUid} onChange={setSelectedUid} />
          <div className="mt-4">
            <ErrorBlock error={agents.error ?? adapters.error ?? bindings.error} />
            <ResourceTable
              columns={['Name', 'Adapter', 'Policy', 'State']}
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
                        {binding.enabled ? 'enabled' : 'disabled'}
                      </Badge>
                      <Button
                        aria-label="Disable binding"
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
                : 'Signal binding'}
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? adapters.error ?? saveBinding.error ?? deleteBinding.error} />
            <Field label="Adapter">
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
            <Field label="Binding name">
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
              Save
            </Button>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function AppConfigureWorkspace() {
  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState<ConfigDraft>({ text: '' })
  const [revealed, setRevealed] = useState<unknown>(undefined)
  const items = list.data?.data ?? []
  const selected = selectedKey ? items.find(item => item.key === selectedKey) : firstConfig(items)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({
      path: { key: selected?.key ?? '' }
    }),
    enabled: Boolean(selected?.editable && selected.key)
  })
  const activeItem = detail.data?.data ?? selected
  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refresh()
    }
  })
  const reset = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refresh()
    }
  })
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    onSuccess: response => setRevealed(response.data.value)
  })

  useEffect(() => {
    if (!selectedKey && selected?.key) setSelectedKey(selected.key)
  }, [selected?.key, selectedKey])

  useEffect(() => {
    setRevealed(undefined)
    setDraft({
      text: formatJson(activeItem?.encrypted && activeItem.value === undefined ? {} : (activeItem?.value ?? null))
    })
  }, [activeItem?.key, activeItem?.source, activeItem?.value])

  const submit = () => {
    if (!activeItem) return
    const parsed = parseJson(draft.text, 'value')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }
    update.mutate({ body: { value: parsed.value }, path: { key: activeItem.key } })
  }

  return (
    <WorkspaceShell title="AppConfigure">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(420px,0.95fr)]">
        <div className="min-w-0">
          <ErrorBlock error={list.error} />
          <ResourceTable
            columns={['Key', 'Kind', 'Source', 'State']}
            empty={!list.isLoading && items.length === 0}
            loading={list.isLoading}>
            {items.map(item => (
              <TableRow
                key={`${item.kind}:${item.key}`}
                data-state={activeItem?.key === item.key ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => setSelectedKey(item.key)}>
                <TableCell className="max-w-[320px] whitespace-normal font-mono text-xs">{item.key}</TableCell>
                <TableCell>
                  <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
                </TableCell>
                <TableCell>{item.source}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-2">
                    {item.encrypted ? <Badge variant="destructive">encrypted</Badge> : null}
                    {item.overridden ? <Badge>global</Badge> : null}
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>
        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle className="break-all font-mono text-base">{activeItem?.key ?? 'No setting'}</CardTitle>
              {activeItem?.editable ? (
                <Button
                  aria-label="Reset"
                  disabled={reset.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => reset.mutate({ path: { key: activeItem.key } })}>
                  <RiCloseLine />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            {activeItem ? (
              <>
                <div className="flex flex-wrap gap-2">
                  <Badge variant={activeItem.kind === 'pattern' ? 'outline' : 'secondary'}>{activeItem.kind}</Badge>
                  <Badge variant="outline">{activeItem.source}</Badge>
                  {activeItem.encrypted ? <Badge variant="destructive">encrypted</Badge> : null}
                </div>
                {activeItem.description ? (
                  <p className="text-sm leading-6 text-muted-foreground">{activeItem.description}</p>
                ) : null}
                <ErrorBlock error={draft.error ?? update.error ?? reset.error ?? decrypt.error} />
                {activeItem.editable ? (
                  <>
                    <Textarea
                      className="min-h-64 font-mono text-xs"
                      spellCheck={false}
                      value={draft.text}
                      onChange={event => setDraft({ text: event.target.value })}
                    />
                    <div className="flex flex-wrap gap-2">
                      <Button disabled={update.isPending} size="sm" type="button" onClick={submit}>
                        <RiSave3Line data-icon="inline-start" />
                        Save
                      </Button>
                      {activeItem.encrypted ? (
                        <Button
                          disabled={decrypt.isPending}
                          size="sm"
                          type="button"
                          variant="outline"
                          onClick={() => decrypt.mutate({ path: { key: activeItem.key } })}>
                          <RiEyeLine data-icon="inline-start" />
                          Reveal
                        </Button>
                      ) : null}
                    </div>
                  </>
                ) : null}
                {revealed !== undefined ? (
                  <pre className="max-h-72 overflow-auto border border-border bg-muted p-3 text-xs">
                    {formatJson(revealed)}
                  </pre>
                ) : null}
              </>
            ) : (
              <p className="text-sm text-muted-foreground">No console-visible settings.</p>
            )}
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function ModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providers
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JsonObject
  providers: AiGatewayProviderItem[]
}) {
  const [drafts, setDrafts] = useState<Record<string, ProfileDraft>>({})
  const saveProfile = useMutation({
    ...ankoleWebAiGatewayProviderControllerPutModelProfileMutation(),
    onSuccess: onChanged
  })
  const clearProfile = useMutation({
    ...ankoleWebAiGatewayProviderControllerDeleteModelProfileMutation(),
    onSuccess: onChanged
  })

  useEffect(() => {
    setDrafts(
      Object.fromEntries(
        PROFILE_NAMES.map(profile => [profile, draftFromProfile(recordValue(profiles[profile]) ?? {})])
      )
    )
  }, [agent.uid, profiles])

  const updateDraft = (profile: string, patch: Partial<ProfileDraft>) => {
    setDrafts(current => ({ ...current, [profile]: { ...(current[profile] ?? emptyProfileDraft()), ...patch } }))
  }

  const submit = (profile: string) => {
    const draft = drafts[profile] ?? emptyProfileDraft()
    const parsedOptions = parseObjectDraft(draft.providerOptions, 'provider_options')
    if (!parsedOptions.ok) {
      updateDraft(profile, { error: parsedOptions.error })
      return
    }
    const contextLength = draft.contextLength.trim() ? Number.parseInt(draft.contextLength, 10) : undefined
    saveProfile.mutate({
      body: {
        provider_id: draft.providerId,
        model: draft.model,
        context_length: Number.isFinite(contextLength) ? contextLength : undefined,
        provider_options: parsedOptions.value
      },
      path: { agent_uid: agent.uid, profile }
    })
  }

  return (
    <section className="grid gap-3">
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-sm font-semibold tracking-normal">Model profiles</h3>
        {loading ? <span className="text-xs text-muted-foreground">Loading</span> : null}
      </div>
      <ErrorBlock error={error ?? saveProfile.error ?? clearProfile.error} />
      <div className="grid gap-3">
        {PROFILE_NAMES.map(profile => {
          const draft = drafts[profile] ?? emptyProfileDraft()
          return (
            <div key={profile} className="grid gap-3 border border-border p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <Badge variant={REQUIRED_PROFILES.has(profile) ? 'default' : 'outline'}>{profile}</Badge>
                <div className="flex gap-2">
                  <Button disabled={saveProfile.isPending} size="xs" type="button" onClick={() => submit(profile)}>
                    <RiSave3Line data-icon="inline-start" />
                    Save
                  </Button>
                  <Button
                    disabled={REQUIRED_PROFILES.has(profile) || clearProfile.isPending}
                    size="xs"
                    type="button"
                    variant="outline"
                    onClick={() => clearProfile.mutate({ path: { agent_uid: agent.uid, profile } })}>
                    Clear
                  </Button>
                </div>
              </div>
              <ErrorBlock error={draft.error} />
              <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_120px]">
                <Field label="Provider">
                  <Select
                    value={draft.providerId}
                    onValueChange={value => updateDraft(profile, { providerId: String(value) })}>
                    <SelectTrigger className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {providers.map(provider => (
                        <SelectItem key={provider.provider_id} value={provider.provider_id}>
                          {provider.provider_id}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field label="Model">
                  <Input value={draft.model} onChange={event => updateDraft(profile, { model: event.target.value })} />
                </Field>
                <Field label="Context">
                  <Input
                    inputMode="numeric"
                    value={draft.contextLength}
                    onChange={event => updateDraft(profile, { contextLength: event.target.value })}
                  />
                </Field>
              </div>
              <Field label="Provider options">
                <Textarea
                  className="min-h-24 font-mono text-xs"
                  spellCheck={false}
                  value={draft.providerOptions}
                  onChange={event => updateDraft(profile, { providerOptions: event.target.value })}
                />
              </Field>
            </div>
          )
        })}
      </div>
    </section>
  )
}

function WorkspaceShell({ action, children, title }: { action?: ReactNode; children: ReactNode; title: string }) {
  return (
    <div className="grid gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-xl font-semibold tracking-normal">{title}</h2>
        {action}
      </div>
      {children}
    </div>
  )
}

function ResourceTable({
  children,
  columns,
  empty,
  loading
}: {
  children: ReactNode
  columns: string[]
  empty: boolean
  loading: boolean
}) {
  return (
    <div className="overflow-hidden border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map(column => (
              <TableHead key={column}>{column}</TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {children}
          {loading ? (
            <TableRow>
              <TableCell colSpan={columns.length} className="text-muted-foreground">
                Loading...
              </TableCell>
            </TableRow>
          ) : null}
          {empty ? (
            <TableRow>
              <TableCell colSpan={columns.length} className="text-muted-foreground">
                No records.
              </TableCell>
            </TableRow>
          ) : null}
        </TableBody>
      </Table>
    </div>
  )
}

function Field({ children, label }: { children: ReactNode; label: string }) {
  return (
    <label className="grid min-w-0 gap-2 text-xs font-medium tracking-normal text-muted-foreground">
      <span>{label}</span>
      {children}
    </label>
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
  return (
    <Field label="Agent">
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

function ErrorBlock({ error }: { error: unknown }) {
  if (!error) return null
  return (
    <div className="border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
      {typeof error === 'string' ? error : requestErrorMessage(error)}
    </div>
  )
}

function emptyAgentDraft(): AgentDraft {
  return {
    uid: '',
    displayName: '',
    avatarUrl: '',
    role: 'Research Analyst',
    options: '{}'
  }
}

function draftFromAgent(agent: AgentItem): AgentDraft {
  return {
    uid: agent.uid,
    displayName: agent.display_name ?? '',
    avatarUrl: agent.avatar_url ?? '',
    role: agent.role,
    options: formatJson(agent.options)
  }
}

function emptyProviderDraft(kind?: AiGatewayProviderKindItem): ProviderDraft {
  return {
    providerId: '',
    providerKind: kind?.provider_kind ?? '',
    baseUrl: kind?.default_base_url ?? '',
    connectionOptions: '{}'
  }
}

function draftFromProvider(provider: AiGatewayProviderItem): ProviderDraft {
  return {
    providerId: provider.provider_id,
    providerKind: provider.provider_kind,
    baseUrl: provider.base_url ?? '',
    connectionOptions: formatJson(provider.connection_options)
  }
}

function emptyIdentityProviderDraft(adapter?: IdentityProviderAdapterItem): IdentityProviderDraft {
  return {
    adapterId: adapter?.adapter_id ?? '',
    config: defaultConfig(asConfigFields(adapter?.fields ?? [])),
    enabled: true,
    providerId: adapter?.default_provider_id ?? ''
  }
}

function draftFromIdentityProvider(provider: IdentityProviderItem): IdentityProviderDraft {
  return {
    adapterId: provider.adapter_id,
    config: recordValue(provider.config) ?? {},
    enabled: provider.enabled,
    providerId: provider.provider_id
  }
}

function emptyProfileDraft(): ProfileDraft {
  return {
    providerId: '',
    model: '',
    contextLength: '',
    providerOptions: '{}'
  }
}

function draftFromProfile(profile: JsonObject): ProfileDraft {
  return {
    providerId: asString(profile.provider_id),
    model: asString(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: formatJson(recordValue(profile.provider_options) ?? {})
  }
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

function identityProviderSyncEnabled(provider: IdentityProviderItem): boolean {
  return getPath(recordValue(provider.config) ?? {}, 'sync.contacts') !== false
}

function identityProviderSupportsDirectoryFullSync(adapter: IdentityProviderAdapterItem): boolean {
  return adapter.capabilities.includes('directory_full_sync')
}

function firstConfig(items: AppConfigurationItem[]): AppConfigurationItem | undefined {
  return items.find(item => item.editable) ?? items[0]
}

function providerKindLabel(kind: AiGatewayProviderKindItem): string {
  const label = kind.label.en ?? kind.label['en-US'] ?? kind.provider_kind
  return `${label} (${kind.provider_kind})`
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function blankToNull(value: string): string | null {
  const text = value.trim()
  return text ? text : null
}

function parseJson(text: string, field: string): { ok: true; value: unknown } | { ok: false; error: string } {
  try {
    return { ok: true, value: JSON.parse(text) }
  } catch (error) {
    return { ok: false, error: `${field} must be valid JSON: ${requestErrorMessage(error)}` }
  }
}

function parseObjectDraft(text: string, field: string): { ok: true; value: JsonObject } | { ok: false; error: string } {
  const parsed = parseJson(text, field)
  if (!parsed.ok) return parsed
  const value = recordValue(parsed.value)
  if (value) return { ok: true, value }
  return { ok: false, error: `${field} must be a JSON object` }
}

function formatJson(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

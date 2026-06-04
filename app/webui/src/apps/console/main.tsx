import {
  RiAddLine,
  RiDeleteBinLine,
  RiLogoutBoxLine,
  RiPencilLine,
  RiPlugLine,
  RiRobot2Line,
  RiSaveLine
} from '@remixicon/react'
import { resolveBullXPluginLocalizedText } from '@agentbull/bullx-sdk/plugins'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { apiDelete, apiGet, apiPost, apiPut, type ApiError } from '@/lib/api'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from '@/uikit/components/empty'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Skeleton } from '@/uikit/components/skeleton'
import { Spinner } from '@/uikit/components/spinner'
import { Switch } from '@/uikit/components/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/uikit/components/table'
import { mountSpa } from '../mount-spa'

type LocalizedText = string | Record<string, string>
type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue }
type JsonObject = { [key: string]: JsonValue }

interface SessionResponse {
  authenticated: boolean
  principalUid?: string
  providerId?: string
  setupRestartRecommended?: boolean
}

interface ConsoleAgent {
  uid: string
  status: 'active' | 'disabled'
  chatChannels: ConsoleChatChannel[]
}

interface ConsoleChatChannel {
  name: string
  adapter: string
  enabled: boolean
  config: JsonObject
  adapterInstalled: boolean
  restartRequired: true
}

interface SetupField {
  path: string[]
  type: 'text' | 'password' | 'select' | 'checkbox' | 'number'
  label: LocalizedText
  description?: LocalizedText
  options?: Array<{ value: string; label: LocalizedText }>
  defaultValue?: JsonValue
  secret?: boolean
}

interface ConsoleChatGatewayAdapter {
  id: string
  pluginId: string
  interactiveConfig: boolean
  setup?: {
    displayName?: LocalizedText
    description?: LocalizedText
    defaultChannelName?: string
    defaultConfig?: JsonValue
    fields: SetupField[]
    interactiveConfig?: {
      displayName?: LocalizedText
      description?: LocalizedText
    }
  }
}

interface InteractiveConfigSession {
  sessionId: string
  adapterId: string
  state: 'running' | 'succeeded' | 'failed' | 'cancelled'
  status?: LocalizedText
  html?: string
  values?: JsonObject
  error?: string
}

function ConsoleApp() {
  const { t } = useTranslation()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const [restartRequired, setRestartRequired] = useState(false)
  const session = useQuery({
    queryKey: ['session'],
    queryFn: () => apiGet<SessionResponse>('/api/session')
  })
  const agents = useAgentsQuery()
  const adapters = useAdaptersQuery()
  const selectedAgent =
    agents.data?.agents.find(agent => agent.uid === selectedAgentUid) ?? agents.data?.agents[0] ?? null

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  const logout = useMutation({
    mutationFn: () => apiDelete('/api/session'),
    onSuccess: () => window.location.assign('/sessions/new')
  })

  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <header className="flex items-center justify-between gap-3 border-b border-border pb-4">
          <div>
            <h1 className="text-lg font-semibold">{t('console.title')}</h1>
            <p className="text-sm text-muted-foreground">{t('console.setup_complete')}</p>
          </div>
          <Button variant="outline" disabled={logout.isPending} onClick={() => logout.mutate()}>
            {t('console.logout')}
            <RiLogoutBoxLine data-icon="inline-end" />
          </Button>
        </header>

        {session.data?.setupRestartRecommended ? (
          <Alert>
            <AlertTitle>{t('console.restart_recommended_title')}</AlertTitle>
            <AlertDescription>{t('console.restart_recommended_body')}</AlertDescription>
          </Alert>
        ) : null}

        {restartRequired ? (
          <Alert>
            <AlertTitle>{t('console.restart_required_title')}</AlertTitle>
            <AlertDescription>{t('console.restart_required_body')}</AlertDescription>
          </Alert>
        ) : null}

        <section className="grid min-h-[560px] gap-6 lg:grid-cols-[360px_minmax(0,1fr)]">
          <AgentListPanel
            agents={agents.data?.agents ?? []}
            loading={agents.isPending}
            error={agents.error}
            selectedAgentUid={selectedAgent?.uid ?? null}
            onSelect={setSelectedAgentUid}
            onChanged={() => setRestartRequired(true)}
          />
          <AgentDetailPanel
            agent={selectedAgent}
            adapters={adapters.data?.adapters ?? []}
            loading={agents.isPending || adapters.isPending}
            error={agents.error ?? adapters.error}
            onChanged={() => setRestartRequired(true)}
          />
        </section>
      </div>
    </main>
  )
}

function AgentListPanel({
  agents,
  loading,
  error,
  selectedAgentUid,
  onSelect,
  onChanged
}: {
  agents: ConsoleAgent[]
  loading: boolean
  error: unknown
  selectedAgentUid: string | null
  onSelect(uid: string): void
  onChanged(): void
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [uid, setUid] = useState('')
  const create = useMutation({
    mutationFn: () => apiPost<{ agent: ConsoleAgent }>('/api/console/agents', { uid }),
    onSuccess: result => {
      setUid('')
      onSelect(result.agent.uid)
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })
  const remove = useMutation({
    mutationFn: (agentUid: string) => apiDelete(`/api/console/agents/${encodeURIComponent(agentUid)}`),
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })

  return (
    <Card className="h-fit rounded-none">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <RiRobot2Line className="size-4" />
          {t('console.agents.title')}
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-5">
        <form
          className="grid gap-3"
          onSubmit={event => {
            event.preventDefault()
            create.mutate()
          }}>
          <Field>
            <FieldLabel>{t('console.agents.uid_label')}</FieldLabel>
            <Input value={uid} autoComplete="off" onChange={event => setUid(event.target.value)} />
          </Field>
          <ErrorAlert error={create.error} title={t('console.agents.create_failed')} />
          <Button type="submit" disabled={!uid.trim() || create.isPending}>
            {create.isPending ? <Spinner /> : <RiAddLine />}
            {t('console.agents.create')}
          </Button>
        </form>

        {loading ? (
          <SkeletonRows rows={4} />
        ) : error ? (
          <ErrorAlert error={error} title={t('console.agents.load_failed')} />
        ) : agents.length === 0 ? (
          <Empty className="border border-dashed border-border p-8">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <RiRobot2Line />
              </EmptyMedia>
              <EmptyTitle>{t('console.agents.empty_title')}</EmptyTitle>
            </EmptyHeader>
          </Empty>
        ) : (
          <div className="border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('console.agents.uid_label')}</TableHead>
                  <TableHead>{t('console.channels.title')}</TableHead>
                  <TableHead className="text-right">{t('console.actions')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {agents.map(agent => (
                  <TableRow
                    key={agent.uid}
                    data-state={selectedAgentUid === agent.uid ? 'selected' : undefined}
                    onClick={() => onSelect(agent.uid)}
                    className="cursor-pointer">
                    <TableCell className="font-mono text-xs text-foreground">{agent.uid}</TableCell>
                    <TableCell>{agent.chatChannels.length}</TableCell>
                    <TableCell>
                      <div className="flex justify-end">
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-xs"
                          aria-label={t('console.agents.delete')}
                          disabled={remove.isPending}
                          onClick={event => {
                            event.stopPropagation()
                            if (window.confirm(t('console.agents.delete_confirm', { uid: agent.uid }))) {
                              remove.mutate(agent.uid)
                            }
                          }}>
                          <RiDeleteBinLine />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function AgentDetailPanel({
  agent,
  adapters,
  loading,
  error,
  onChanged
}: {
  agent: ConsoleAgent | null
  adapters: ConsoleChatGatewayAdapter[]
  loading: boolean
  error: unknown
  onChanged(): void
}) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<ConsoleChatChannel | 'new' | null>(null)

  useEffect(() => {
    setEditing(null)
  }, [agent?.uid])

  if (loading) {
    return (
      <Card className="rounded-none">
        <CardContent className="pt-6">
          <SkeletonRows rows={8} />
        </CardContent>
      </Card>
    )
  }

  if (error) {
    return (
      <Card className="rounded-none">
        <CardContent className="pt-6">
          <ErrorAlert error={error} title={t('console.agents.load_failed')} />
        </CardContent>
      </Card>
    )
  }

  if (!agent) {
    return (
      <Empty className="border border-dashed border-border">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiRobot2Line />
          </EmptyMedia>
          <EmptyTitle>{t('console.agents.empty_title')}</EmptyTitle>
          <EmptyDescription>{t('console.agents.empty_body')}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Card className="rounded-none">
        <CardHeader>
          <CardTitle className="flex min-w-0 items-center justify-between gap-3">
            <span className="truncate font-mono text-base">{agent.uid}</span>
            <Badge variant="outline">{agent.status}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-sm font-semibold">{t('console.channels.title')}</h2>
            <Button type="button" size="sm" onClick={() => setEditing('new')}>
              <RiAddLine />
              {t('console.channels.add')}
            </Button>
          </div>
          <ChannelsTable agent={agent} onEdit={setEditing} onChanged={onChanged} />
        </CardContent>
      </Card>

      {editing ? (
        <ChannelForm
          key={editing === 'new' ? `new-${agent.uid}` : `${agent.uid}-${editing.name}`}
          agent={agent}
          adapters={adapters}
          channel={editing === 'new' ? undefined : editing}
          onClose={() => setEditing(null)}
          onChanged={onChanged}
        />
      ) : null}
    </div>
  )
}

function ChannelsTable({
  agent,
  onEdit,
  onChanged
}: {
  agent: ConsoleAgent
  onEdit(channel: ConsoleChatChannel): void
  onChanged(): void
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const remove = useMutation({
    mutationFn: (channelName: string) =>
      apiDelete(`/api/console/agents/${encodeURIComponent(agent.uid)}/chat-channels/${encodeURIComponent(channelName)}`),
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })

  if (agent.chatChannels.length === 0) {
    return (
      <Empty className="border border-dashed border-border p-8">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiPlugLine />
          </EmptyMedia>
          <EmptyTitle>{t('console.channels.empty_title')}</EmptyTitle>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="border border-border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.channels.name')}</TableHead>
            <TableHead>{t('console.channels.adapter')}</TableHead>
            <TableHead>{t('console.channels.enabled')}</TableHead>
            <TableHead>{t('console.channels.status')}</TableHead>
            <TableHead className="text-right">{t('console.actions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {agent.chatChannels.map(channel => (
            <TableRow key={channel.name}>
              <TableCell className="font-mono text-xs text-foreground">{channel.name}</TableCell>
              <TableCell>{channel.adapter}</TableCell>
              <TableCell>
                <Badge variant={channel.enabled ? 'default' : 'secondary'}>
                  {t(channel.enabled ? 'console.enabled' : 'console.disabled')}
                </Badge>
              </TableCell>
              <TableCell>
                <Badge variant={channel.adapterInstalled ? 'outline' : 'destructive'}>
                  {t(channel.adapterInstalled ? 'console.channels.configured' : 'console.channels.adapter_missing')}
                </Badge>
              </TableCell>
              <TableCell>
                <div className="flex justify-end gap-1">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t('console.channels.edit')}
                    onClick={() => onEdit(channel)}>
                    <RiPencilLine />
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t('console.channels.delete')}
                    disabled={remove.isPending}
                    onClick={() => {
                      if (window.confirm(t('console.channels.delete_confirm', { name: channel.name }))) {
                        remove.mutate(channel.name)
                      }
                    }}>
                    <RiDeleteBinLine />
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}

function ChannelForm({
  agent,
  adapters,
  channel,
  onClose,
  onChanged
}: {
  agent: ConsoleAgent
  adapters: ConsoleChatGatewayAdapter[]
  channel?: ConsoleChatChannel
  onClose(): void
  onChanged(): void
}) {
  const { i18n, t } = useTranslation()
  const queryClient = useQueryClient()
  const [adapterId, setAdapterId] = useState(channel?.adapter ?? adapters[0]?.id ?? '')
  const adapter = adapters.find(item => item.id === adapterId)
  const [name, setName] = useState(channel?.name ?? adapter?.setup?.defaultChannelName ?? adapter?.id ?? '')
  const [enabled, setEnabled] = useState(channel?.enabled ?? true)
  const [config, setConfig] = useState<JsonObject>(() =>
    channel ? cloneJsonObject(channel.config) : defaultConfigForAdapter(adapter)
  )

  useEffect(() => {
    if (!channel && adapter) {
      setName(adapter.setup?.defaultChannelName ?? adapter.id)
      setConfig(defaultConfigForAdapter(adapter))
    }
  }, [adapter?.id, channel])

  const save = useMutation({
    mutationFn: () => {
      const body = {
        name,
        adapter: adapterId,
        enabled,
        config
      }
      if (channel) {
        return apiPut<{ channel: ConsoleChatChannel }>(
          `/api/console/agents/${encodeURIComponent(agent.uid)}/chat-channels/${encodeURIComponent(channel.name)}`,
          body
        )
      }
      return apiPost<{ channel: ConsoleChatChannel }>(
        `/api/console/agents/${encodeURIComponent(agent.uid)}/chat-channels`,
        body
      )
    },
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
      onClose()
    }
  })

  const interactive = useInteractiveConfig(adapter, config, i18n.language, values => {
    setConfig(current => mergeJsonRecords(current, values))
  })

  if (!adapter) {
    return (
      <Alert variant="destructive">
        <AlertTitle>{t('console.channels.adapter_missing')}</AlertTitle>
      </Alert>
    )
  }

  return (
    <Card className="rounded-none">
      <CardHeader>
        <CardTitle>{channel ? t('console.channels.edit') : t('console.channels.add')}</CardTitle>
      </CardHeader>
      <CardContent>
        <form
          className="flex flex-col gap-6"
          onSubmit={event => {
            event.preventDefault()
            save.mutate()
          }}>
          <ErrorAlert error={save.error} title={t('console.channels.save_failed')} />

          <div className="grid gap-5 md:grid-cols-2">
            <Field>
              <FieldLabel>{t('console.channels.name')}</FieldLabel>
              <Input value={name} disabled={Boolean(channel)} onChange={event => setName(event.target.value)} />
            </Field>
            <Field>
              <FieldLabel>{t('console.channels.adapter')}</FieldLabel>
              <Select value={adapterId} disabled={Boolean(channel)} onValueChange={value => setAdapterId(value ?? adapterId)}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {adapters.map(item => (
                    <SelectItem key={item.id} value={item.id}>
                      {adapterLabel(item, i18n.language)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          </div>

          <div className="flex items-center justify-between gap-3 border border-border bg-card px-4 py-3">
            <span className="text-sm">{t('console.channels.enabled')}</span>
            <Switch checked={enabled} onCheckedChange={checked => setEnabled(checked)} />
          </div>

          <FieldGroup className="grid gap-5 md:grid-cols-2">
            {(adapter.setup?.fields ?? []).map(field => (
              <ConfigField
                key={field.path.join('.')}
                field={field}
                locale={i18n.language}
                value={getPath(config, field.path)}
                onChange={value => setConfig(current => setPath(current, field.path, value))}
              />
            ))}
          </FieldGroup>

          {adapter.interactiveConfig ? (
            <div className="flex flex-col gap-3 border border-border p-4">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div className="grid gap-1">
                  <span className="text-sm font-medium">
                    {resolveBullXPluginLocalizedText(
                      adapter.setup?.interactiveConfig?.displayName,
                      i18n.language,
                      t('console.channels.interactive_config')
                    )}
                  </span>
                  {adapter.setup?.interactiveConfig?.description ? (
                    <span className="text-xs text-muted-foreground">
                      {resolveBullXPluginLocalizedText(adapter.setup.interactiveConfig.description, i18n.language)}
                    </span>
                  ) : null}
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <Button type="button" variant="outline" disabled={interactive.running} onClick={interactive.start}>
                    {interactive.running ? <Spinner /> : <RiPlugLine />}
                    {t('console.channels.start_interactive_config')}
                  </Button>
                  {interactive.session ? (
                    <Button type="button" variant="ghost" onClick={interactive.cancel}>
                      {t('console.cancel')}
                    </Button>
                  ) : null}
                </div>
              </div>
              {interactive.session ? (
                <Alert variant={interactive.session.state === 'failed' ? 'destructive' : 'default'}>
                  <AlertTitle>
                    {resolveBullXPluginLocalizedText(
                      interactive.session.status,
                      i18n.language,
                      t(`console.interactive.${interactive.session.state}`)
                    )}
                  </AlertTitle>
                  {interactive.session.html ? (
                    <AlertDescription>
                      <div
                        className="prose prose-sm max-w-none break-words text-sm"
                        dangerouslySetInnerHTML={{ __html: interactive.session.html }}
                      />
                    </AlertDescription>
                  ) : null}
                  {interactive.session.error ? (
                    <AlertDescription>{interactive.session.error}</AlertDescription>
                  ) : null}
                </Alert>
              ) : null}
            </div>
          ) : null}

          <div className="flex flex-wrap items-center gap-3 border-t border-border pt-5">
            <Button type="submit" disabled={save.isPending}>
              {save.isPending ? <Spinner /> : <RiSaveLine />}
              {t('console.save')}
            </Button>
            <Button type="button" variant="ghost" onClick={onClose}>
              {t('console.cancel')}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

function ConfigField({
  field,
  locale,
  value,
  onChange
}: {
  field: SetupField
  locale: string
  value: JsonValue | undefined
  onChange(value: JsonValue): void
}) {
  const label = resolveBullXPluginLocalizedText(field.label, locale, field.path.join('.'))
  const description = resolveBullXPluginLocalizedText(field.description, locale)

  if (field.type === 'checkbox') {
    return (
      <Field orientation="horizontal" className="items-center justify-between border border-border p-4">
        <div className="grid gap-1">
          <FieldLabel>{label}</FieldLabel>
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </div>
        <Switch checked={Boolean(value)} onCheckedChange={checked => onChange(checked)} />
      </Field>
    )
  }

  if (field.type === 'select') {
    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(field.options ?? []).map(option => (
              <SelectItem key={option.value} value={option.value}>
                {resolveBullXPluginLocalizedText(option.label, locale, option.value)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  /*
   * Secret fields come back from the API as presence markers, never plaintext.
   * Leaving the input empty preserves the existing encrypted value on save.
   */
  const secretPresent = isJsonObject(value) && value.present === true
  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        type={field.type === 'password' ? 'password' : field.type === 'number' ? 'number' : 'text'}
        value={secretPresent || value == null || isJsonObject(value) ? '' : String(value)}
        placeholder={secretPresent ? 'saved' : undefined}
        autoComplete={field.type === 'password' ? 'new-password' : 'off'}
        onChange={event => onChange(field.type === 'number' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

function useInteractiveConfig(
  adapter: ConsoleChatGatewayAdapter | undefined,
  config: JsonObject,
  locale: string,
  onValues: (values: JsonObject) => void
) {
  /*
   * The session id is the client-side owner of a server-side interactive flow.
   * Clearing it hides stale session UI and triggers the cleanup effect below,
   * which aborts provider work such as a pending QR-code registration.
   */
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [appliedSessionId, setAppliedSessionId] = useState<string | null>(null)
  const startMutation = useMutation({
    mutationFn: () =>
      apiPost<{ session: InteractiveConfigSession }>('/api/console/interactive-config-sessions', {
        adapterId: adapter?.id,
        currentConfig: config,
        locale
      }),
    onSuccess: result => {
      setAppliedSessionId(null)
      setSessionId(result.session.sessionId)
    }
  })
  const session = useQuery({
    queryKey: ['console-interactive-config-session', sessionId],
    enabled: Boolean(sessionId),
    queryFn: () =>
      apiGet<{ session: InteractiveConfigSession }>(
        `/api/console/interactive-config-sessions/${encodeURIComponent(sessionId ?? '')}`
      ),
    refetchInterval: query => (query.state.data?.session.state === 'running' ? 1000 : false)
  })

  useEffect(() => {
    if (!sessionId) return

    return () => {
      // The API treats DELETE as idempotent, so this cleanup covers explicit
      // cancel, switching adapter/forms, and unmounting the channel editor.
      void apiDelete(`/api/console/interactive-config-sessions/${encodeURIComponent(sessionId)}`).catch(() => {})
    }
  }, [sessionId])

  useEffect(() => {
    const data = session.data?.session
    if (!data || data.state !== 'succeeded' || !data.values || appliedSessionId === data.sessionId) return

    /*
     * Interactive config only patches the visible form. The operator still saves
     * the channel explicitly, which keeps review/restart behavior identical to a
     * manually typed config.
     */
    onValues(data.values)
    setAppliedSessionId(data.sessionId)
  }, [appliedSessionId, onValues, session.data?.session])

  return {
    running: startMutation.isPending || session.data?.session.state === 'running',
    session: sessionId ? (session.data?.session ?? startMutation.data?.session) : undefined,
    start: () => startMutation.mutate(),
    cancel: () => {
      setSessionId(null)
      setAppliedSessionId(null)
    }
  }
}

function useAgentsQuery() {
  return useQuery({
    queryKey: ['console-agents'],
    queryFn: () => apiGet<{ agents: ConsoleAgent[] }>('/api/console/agents')
  })
}

function useAdaptersQuery() {
  return useQuery({
    queryKey: ['console-chat-gateway-adapters'],
    queryFn: () => apiGet<{ adapters: ConsoleChatGatewayAdapter[] }>('/api/console/chat-gateway-adapters')
  })
}

function adapterLabel(adapter: ConsoleChatGatewayAdapter, locale: string): string {
  return resolveBullXPluginLocalizedText(adapter.setup?.displayName, locale, adapter.id) ?? adapter.id
}

function defaultConfigForAdapter(adapter: ConsoleChatGatewayAdapter | undefined): JsonObject {
  let base = isJsonObject(adapter?.setup?.defaultConfig) ? cloneJsonObject(adapter.setup.defaultConfig) : {}
  /*
   * Match the server-side default merge: plugin authors may put defaults in the
   * top-level setup object or next to each field, but the form edits one JSON
   * object regardless of where those defaults came from.
   */
  for (const field of adapter?.setup?.fields ?? []) {
    if (field.defaultValue !== undefined && getPath(base, field.path) === undefined) {
      base = setPath(base, field.path, cloneJsonValue(field.defaultValue))
    }
  }

  return base
}

function ErrorAlert({ error, title }: { error?: unknown; title: string }) {
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">{errorMessage(error)}</pre>
      </AlertDescription>
    </Alert>
  )
}

function SkeletonRows({ rows }: { rows: number }) {
  return (
    <div className="grid gap-3">
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-10 w-full" />
      ))}
    </div>
  )
}

function errorMessage(error: unknown): string {
  if (!error) return ''
  if (error instanceof Error && 'body' in error) return JSON.stringify((error as ApiError).body, null, 2)
  if (error instanceof Error) return error.message
  return JSON.stringify(error, null, 2)
}

function getPath(value: JsonObject, path: string[]): JsonValue | undefined {
  let current: JsonValue | undefined = value
  for (const segment of path) {
    if (!isJsonObject(current)) return undefined
    current = current[segment]
  }

  return current
}

function setPath(source: JsonObject, path: string[], value: JsonValue): JsonObject {
  const target = cloneJsonObject(source)
  let current = target
  for (const segment of path.slice(0, -1)) {
    const existing = current[segment]
    const next = isJsonObject(existing) ? cloneJsonObject(existing) : {}
    current[segment] = next
    current = next
  }
  current[path[path.length - 1]!] = value

  return target
}

function mergeJsonRecords(base: JsonObject, override: JsonObject): JsonObject {
  const next = cloneJsonObject(base)
  for (const [key, value] of Object.entries(override)) {
    const baseValue = next[key]
    if (isJsonObject(baseValue) && isJsonObject(value)) {
      next[key] = mergeJsonRecords(baseValue, value)
      continue
    }
    next[key] = cloneJsonValue(value)
  }

  return next
}

function cloneJsonObject(value: JsonObject): JsonObject {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneJsonValue(item)])) as JsonObject
}

function cloneJsonValue(value: JsonValue): JsonValue {
  if (Array.isArray(value)) return value.map(cloneJsonValue)
  if (isJsonObject(value)) return cloneJsonObject(value)
  return value
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

mountSpa(<ConsoleApp />)

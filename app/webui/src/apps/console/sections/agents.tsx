import { RiAddLine, RiDeleteBinLine, RiPencilLine, RiPlugLine, RiRobot2Line, RiSaveLine } from '@remixicon/react'
import {
  resolveBullXPluginLocalizedText,
  type BullXPluginJsonValue,
  type BullXPluginSetupField
} from '@agentbull/bullx-sdk/plugins'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type {
  AiAgentModelProfileConfig,
  AiAgentModelProfileName,
  AiAgentModelsConfig,
  AiAgentReasoning
} from '@/ai-agent/config'
import type { ConsoleAgent, ConsoleChatChannel, ConsoleExternalGatewayAdapter } from '@/console/service'
import type { LlmProviderModelProjection, LlmProviderProjection } from '@/llm-providers/service'
import {
  clonePluginJsonObject as cloneJsonObject,
  defaultPluginConfigForSetup,
  getPluginConfigPath as getPath,
  isPluginConfigJsonObject as isJsonObject,
  mergePluginConfigObjects as mergeJsonRecords,
  setPluginConfigPath as setPath,
  type PluginConfigJsonObject
} from '@/plugins/config-json'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { CreatableCombobox } from '@/uikit/components/creatable-combobox'
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from '@/uikit/components/empty'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { Switch } from '@/uikit/components/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/uikit/components/table'
import { Textarea } from '@/uikit/components/textarea'
import {
  numberInputValue,
  optionalFiniteNumber,
  optionalPositiveInteger,
  useAdaptersQuery,
  useAgentsQuery
} from '../helpers'
import { ErrorAlert, SectionHeader, SkeletonRows } from '../shared'

type JsonValue = BullXPluginJsonValue
type JsonObject = PluginConfigJsonObject

// Backend response shapes flow from the server via Eden Treaty (no hand-copied
// contracts): agent/channel/adapter shapes come from the console service import
// above; live API responses are typed by `unwrap(api.console.*)`. Setup fields use
// the SDK plugin field type.
type SetupField = BullXPluginSetupField

export function AgentOperationsPage() {
  const { t } = useTranslation()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const [restartRequired, setRestartRequired] = useState(false)
  const agents = useAgentsQuery()
  const adapters = useAdaptersQuery()
  const selectedAgent =
    agents.data?.agents.find(agent => agent.uid === selectedAgentUid) ?? agents.data?.agents[0] ?? null

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.agents.title')} description={t('console.agents.description')} />
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
  )
}

type AiAgentModelProfileFormState = {
  cacheRetention: '' | NonNullable<AiAgentModelProfileConfig['cacheRetention']>
  enabled: boolean
  maxTokens: string
  model: string
  providerId: string
  reasoning: AiAgentReasoning
  temperature: string
}

type AiAgentModelsFormState = Record<AiAgentModelProfileName, AiAgentModelProfileFormState>

const AI_AGENT_MODEL_PROFILES = ['primary', 'light', 'heavy'] as const satisfies readonly AiAgentModelProfileName[]
const AI_AGENT_MODEL_PROFILE_DEFAULT_REASONING: Record<AiAgentModelProfileName, AiAgentReasoning> = {
  primary: 'medium',
  light: 'low',
  heavy: 'high'
}
const AI_AGENT_MODEL_PROFILE_TITLES: Record<AiAgentModelProfileName, string> = {
  primary: 'Primary model',
  light: 'Light model',
  heavy: 'Heavy model'
}
const AI_AGENT_MODEL_PROFILE_TITLE_KEYS: Record<AiAgentModelProfileName, string> = {
  primary: 'console.agents.model_profile_primary',
  light: 'console.agents.model_profile_light',
  heavy: 'console.agents.model_profile_heavy'
}
const REASONING_OPTIONS = [
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh'
] as const satisfies readonly AiAgentReasoning[]
const CACHE_RETENTION_OPTIONS = ['none', 'short', 'long'] as const satisfies readonly NonNullable<
  AiAgentModelProfileConfig['cacheRetention']
>[]

function aiAgentModelsFormFromConfig(models: AiAgentModelsConfig | undefined): AiAgentModelsFormState {
  return {
    primary: aiAgentModelProfileFormFromConfig('primary', models?.primary),
    light: aiAgentModelProfileFormFromConfig('light', models?.light),
    heavy: aiAgentModelProfileFormFromConfig('heavy', models?.heavy)
  }
}

function aiAgentModelProfileFormFromConfig(
  profile: AiAgentModelProfileName,
  config: AiAgentModelProfileConfig | undefined
): AiAgentModelProfileFormState {
  if (!config) return emptyAiAgentModelProfileForm(profile)

  return {
    cacheRetention: config.cacheRetention ?? '',
    enabled: true,
    maxTokens: numberInputValue(config.maxTokens),
    model: config.model,
    providerId: config.providerId,
    reasoning: config.reasoning ?? AI_AGENT_MODEL_PROFILE_DEFAULT_REASONING[profile],
    temperature: numberInputValue(config.temperature)
  }
}

function emptyAiAgentModelProfileForm(profile: AiAgentModelProfileName): AiAgentModelProfileFormState {
  return {
    cacheRetention: '',
    enabled: profile === 'primary',
    maxTokens: '',
    model: '',
    providerId: '',
    reasoning: AI_AGENT_MODEL_PROFILE_DEFAULT_REASONING[profile],
    temperature: ''
  }
}

function buildAiAgentModelsConfig(form: AiAgentModelsFormState): AiAgentModelsConfig | undefined {
  const hasPrimaryInput = Boolean(form.primary.providerId.trim() || form.primary.model.trim())
  if (!hasPrimaryInput && !form.light.enabled && !form.heavy.enabled) return undefined

  const models: AiAgentModelsConfig = {
    primary: aiAgentModelConfigFromForm('primary', form.primary)
  }

  for (const profile of ['light', 'heavy'] as const) {
    if (form[profile].enabled) models[profile] = aiAgentModelConfigFromForm(profile, form[profile])
  }

  return models
}

function aiAgentModelConfigFromForm(
  profile: AiAgentModelProfileName,
  form: AiAgentModelProfileFormState
): AiAgentModelProfileConfig {
  const title = AI_AGENT_MODEL_PROFILE_TITLES[profile]
  const providerId = form.providerId.trim()
  const model = form.model.trim()
  if (!providerId || !model) throw new Error(`${title} requires both provider and model`)

  const config: AiAgentModelProfileConfig = {
    providerId,
    model,
    reasoning: form.reasoning
  }
  const temperature = optionalFiniteNumber(form.temperature, `${title} temperature`)
  const maxTokens = optionalPositiveInteger(form.maxTokens, `${title} max tokens`)
  if (temperature !== undefined) config.temperature = temperature
  if (maxTokens !== undefined) config.maxTokens = maxTokens
  if (form.cacheRetention) config.cacheRetention = form.cacheRetention
  return config
}

function modelProfileInputIncomplete(form: AiAgentModelsFormState): boolean {
  const primaryHasInput = Boolean(form.primary.providerId.trim() || form.primary.model.trim())
  if (!primaryHasInput && (form.light.enabled || form.heavy.enabled)) return true
  if (primaryHasInput && (!form.primary.providerId.trim() || !form.primary.model.trim())) return true

  return AI_AGENT_MODEL_PROFILES.some(profile => {
    if (profile === 'primary' || !form[profile].enabled) return false
    return !form[profile].providerId.trim() || !form[profile].model.trim()
  })
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
  const [soul, setSoul] = useState('')
  const [mission, setMission] = useState('')
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.agents.post({
          uid,
          mission: mission.trim() ? mission : undefined,
          soul: soul.trim() ? soul : undefined
        })
      ),
    onSuccess: result => {
      setUid('')
      setSoul('')
      setMission('')
      onSelect(result.agent.uid)
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })
  const remove = useMutation({
    mutationFn: (agentUid: string) => unwrap(api.console.agents({ uid: agentUid }).delete()),
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
          <Field>
            <FieldLabel>SOUL.md</FieldLabel>
            <Textarea value={soul} onChange={event => setSoul(event.target.value)} className="min-h-28 font-mono" />
          </Field>
          <Field>
            <FieldLabel>MISSION.md</FieldLabel>
            <Textarea
              value={mission}
              onChange={event => setMission(event.target.value)}
              className="min-h-20 font-mono"
            />
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
  adapters: ConsoleExternalGatewayAdapter[]
  loading: boolean
  error: unknown
  onChanged(): void
}) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<ConsoleChatChannel | 'new' | null>(null)
  const queryClient = useQueryClient()
  const [displayName, setDisplayName] = useState('')
  const [avatarUrl, setAvatarUrl] = useState('')
  const [modelsForm, setModelsForm] = useState<AiAgentModelsFormState>(() => aiAgentModelsFormFromConfig(undefined))
  const [soul, setSoul] = useState('')
  const [mission, setMission] = useState('')
  const llmProviders = useQuery({
    queryKey: ['console-llm-providers'],
    enabled: Boolean(agent),
    queryFn: () => unwrap(api.console['llm-providers'].get())
  })
  const llmProviderIdsKey = useMemo(
    () => (llmProviders.data?.providers ?? []).map(provider => provider.providerId).join('\n'),
    [llmProviders.data?.providers]
  )
  const llmProviderModels = useQuery({
    queryKey: ['console-llm-provider-models', llmProviderIdsKey],
    enabled: Boolean(agent && llmProviders.data),
    queryFn: async () => {
      const entries = await Promise.all(
        (llmProviders.data?.providers ?? []).map(async provider => {
          const result = await unwrap(api.console['llm-providers']({ providerId: provider.providerId }).models.get())
          return [provider.providerId, result.models] as const
        })
      )
      return Object.fromEntries(entries) as Record<string, LlmProviderModelProjection[]>
    }
  })
  const agentSoul = useQuery({
    queryKey: ['console-agent-soul', agent?.uid],
    enabled: Boolean(agent?.uid),
    queryFn: () => unwrap(api.console.agents({ uid: agent?.uid ?? '' }).soul.get())
  })
  const agentMission = useQuery({
    queryKey: ['console-agent-mission', agent?.uid],
    enabled: Boolean(agent?.uid),
    queryFn: () => unwrap(api.console.agents({ uid: agent?.uid ?? '' }).mission.get())
  })
  const saveProfile = useMutation({
    mutationFn: () => {
      const models = buildAiAgentModelsConfig(modelsForm)
      return unwrap(
        api.console.agents({ uid: agent?.uid ?? '' }).put({
          displayName: displayName.trim() ? displayName : null,
          avatarUrl: avatarUrl.trim() ? avatarUrl : null,
          llmProfile: models ? { models } : undefined,
          mission,
          soul
        })
      )
    },
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
      queryClient.invalidateQueries({ queryKey: ['console-agent-soul', agent?.uid] })
      queryClient.invalidateQueries({ queryKey: ['console-agent-mission', agent?.uid] })
      queryClient.invalidateQueries({ queryKey: ['console-agent-library-entries', agent?.uid] })
    }
  })

  useEffect(() => {
    setEditing(null)
  }, [agent?.uid])

  useEffect(() => {
    setDisplayName(agent?.displayName ?? '')
    setAvatarUrl(agent?.avatarUrl ?? '')
    setModelsForm(aiAgentModelsFormFromConfig(agent?.llmProfile?.models))
    setSoul('')
    setMission('')
  }, [agent?.uid, agent?.displayName, agent?.avatarUrl, agent?.llmProfile])

  useEffect(() => {
    if (agentSoul.data) setSoul(agentSoul.data.content ?? '')
  }, [agentSoul.data])

  useEffect(() => {
    if (agentMission.data) setMission(agentMission.data.content ?? '')
  }, [agentMission.data])

  const saveDisabled = saveProfile.isPending || modelProfileInputIncomplete(modelsForm)

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
          <CardTitle className="text-base">{t('console.agents.profile_title')}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-5"
            onSubmit={event => {
              event.preventDefault()
              saveProfile.mutate()
            }}>
            <div className="grid gap-4 md:grid-cols-2">
              <Field>
                <FieldLabel>{t('console.agents.display_name_label')}</FieldLabel>
                <Input value={displayName} onChange={event => setDisplayName(event.target.value)} />
              </Field>
              <Field>
                <FieldLabel>{t('console.agents.avatar_url_label')}</FieldLabel>
                <Input value={avatarUrl} onChange={event => setAvatarUrl(event.target.value)} />
              </Field>
            </div>
            <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
              <div className="grid gap-1">
                <h2 className="text-sm font-semibold">{t('console.agents.files_title')}</h2>
                <p className="text-sm text-muted-foreground">{t('console.agents.files_description')}</p>
              </div>
              <FieldGroup className="grid gap-4 lg:grid-cols-2">
                <Field>
                  <FieldLabel>SOUL.md</FieldLabel>
                  <Textarea
                    value={soul}
                    onChange={event => setSoul(event.target.value)}
                    className="min-h-48 font-mono"
                  />
                </Field>
                <Field>
                  <FieldLabel>MISSION.md</FieldLabel>
                  <Textarea
                    value={mission}
                    onChange={event => setMission(event.target.value)}
                    className="min-h-48 font-mono"
                  />
                </Field>
              </FieldGroup>
              <ErrorAlert error={agentSoul.error ?? agentMission.error} title={t('console.agents.files_load_failed')} />
            </section>
            <AiAgentModelProfileForm
              value={modelsForm}
              providers={llmProviders.data?.providers ?? []}
              providerModels={llmProviderModels.data ?? {}}
              loading={llmProviders.isPending || llmProviderModels.isPending}
              error={llmProviders.error ?? llmProviderModels.error}
              onChange={setModelsForm}
            />
            <div className="flex items-center gap-3">
              <Button type="submit" disabled={saveDisabled}>
                {saveProfile.isPending ? <Spinner /> : <RiSaveLine />}
                {t('console.agents.save_profile')}
              </Button>
              <ErrorAlert error={saveProfile.error} title={t('console.agents.profile_save_failed')} />
            </div>
          </form>
        </CardContent>
      </Card>

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

function AiAgentModelProfileForm({
  value,
  providers,
  providerModels,
  loading,
  error,
  onChange
}: {
  value: AiAgentModelsFormState
  providers: LlmProviderProjection[]
  providerModels: Record<string, LlmProviderModelProjection[]>
  loading: boolean
  error: unknown
  onChange(value: AiAgentModelsFormState): void
}) {
  const { t } = useTranslation()
  function patchProfile(profile: AiAgentModelProfileName, patch: Partial<AiAgentModelProfileFormState>) {
    onChange({
      ...value,
      [profile]: {
        ...value[profile],
        ...patch
      }
    })
  }

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="grid gap-1">
          <h2 className="text-sm font-semibold">{t('console.agents.model_profile_title')}</h2>
          <p className="text-sm text-muted-foreground">{t('console.agents.model_profile_description')}</p>
        </div>
        {loading ? (
          <Badge variant="secondary">
            <Spinner />
            {t('console.agents.model_profile_loading')}
          </Badge>
        ) : providers.length === 0 ? (
          <Badge variant="outline">{t('console.agents.model_profile_no_providers')}</Badge>
        ) : (
          <Badge variant="outline">
            {t('console.agents.model_profile_provider_count', { total: providers.length })}
          </Badge>
        )}
      </div>
      <ErrorAlert error={error} title={t('console.agents.model_profile_catalog_failed')} />
      <div className="grid gap-4">
        {AI_AGENT_MODEL_PROFILES.map(profile => (
          <AiAgentModelProfileSection
            key={profile}
            profile={profile}
            value={value[profile]}
            providers={providers}
            providerModels={providerModels}
            onChange={patch => patchProfile(profile, patch)}
          />
        ))}
      </div>
    </section>
  )
}

function AiAgentModelProfileSection({
  profile,
  value,
  providers,
  providerModels,
  onChange
}: {
  profile: AiAgentModelProfileName
  value: AiAgentModelProfileFormState
  providers: LlmProviderProjection[]
  providerModels: Record<string, LlmProviderModelProjection[]>
  onChange(patch: Partial<AiAgentModelProfileFormState>): void
}) {
  const { t } = useTranslation()
  const required = profile === 'primary'
  const enabled = required || value.enabled
  const models = value.providerId ? (providerModels[value.providerId] ?? []) : []
  const selectedModel = models.find(model => model.id === value.model)

  function setEnabled(nextEnabled: boolean) {
    if (required) return
    onChange(
      nextEnabled ? { ...emptyAiAgentModelProfileForm(profile), enabled: true } : emptyAiAgentModelProfileForm(profile)
    )
  }

  return (
    <section className="grid gap-4 border border-border/70 bg-card/40 p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          <span className="text-xs font-semibold uppercase text-muted-foreground">
            {t(AI_AGENT_MODEL_PROFILE_TITLE_KEYS[profile])}
          </span>
          {required ? (
            <Badge variant="secondary">{t('console.agents.model_profile_required')}</Badge>
          ) : enabled ? (
            <Badge variant="outline">{t('console.agents.model_profile_custom')}</Badge>
          ) : null}
        </div>
        {required ? null : (
          <label className="flex items-center gap-2 text-sm text-muted-foreground">
            <Switch checked={enabled} onCheckedChange={checked => setEnabled(Boolean(checked))} />
            {t('console.agents.model_profile_custom')}
          </label>
        )}
      </div>

      {!enabled ? (
        <p className="text-sm text-muted-foreground">{t('console.agents.model_profile_inherited')}</p>
      ) : (
        <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          <Field>
            <FieldLabel>{t('console.agents.provider_label')}</FieldLabel>
            <Select
              value={value.providerId}
              onValueChange={nextProviderId =>
                onChange({
                  providerId: nextProviderId ?? '',
                  model: ''
                })
              }>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.select_provider')} />
              </SelectTrigger>
              <SelectContent>
                {providers.map(provider => (
                  <SelectItem key={provider.providerId} value={provider.providerId}>
                    {provider.providerId}
                  </SelectItem>
                ))}
                {value.providerId && !providers.some(provider => provider.providerId === value.providerId) ? (
                  <SelectItem value={value.providerId}>{value.providerId}</SelectItem>
                ) : null}
              </SelectContent>
            </Select>
          </Field>

          <Field>
            <FieldLabel>{t('console.agents.model_label')}</FieldLabel>
            <CreatableCombobox
              value={value.model}
              options={models.map(model => ({
                value: model.id,
                label: model.name && model.name !== model.id ? model.name : model.id,
                description: model.id
              }))}
              placeholder={
                value.providerId ? t('console.agents.select_model') : t('console.agents.select_provider_first')
              }
              emptyLabel={t('console.agents.no_models')}
              createLabel={model => t('console.agents.use_model', { model })}
              disabled={!value.providerId}
              required={required || Boolean(value.providerId)}
              onValueChange={model => onChange({ model })}
            />
            {selectedModel ? <ModelMetadata model={selectedModel} /> : null}
          </Field>

          <Field>
            <FieldLabel>{t('console.agents.reasoning_label')}</FieldLabel>
            <Select
              value={value.reasoning}
              onValueChange={reasoning =>
                onChange({
                  reasoning: (reasoning || AI_AGENT_MODEL_PROFILE_DEFAULT_REASONING[profile]) as AiAgentReasoning
                })
              }>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {REASONING_OPTIONS.map(reasoning => (
                  <SelectItem key={reasoning} value={reasoning}>
                    {reasoning}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>

          <Field>
            <FieldLabel>{t('console.agents.temperature_label')}</FieldLabel>
            <Input
              type="number"
              step="0.1"
              value={value.temperature}
              onChange={event => onChange({ temperature: event.target.value })}
            />
          </Field>

          <Field>
            <FieldLabel>{t('console.agents.max_tokens_label')}</FieldLabel>
            <Input
              type="number"
              min={1}
              step={1}
              value={value.maxTokens}
              onChange={event => onChange({ maxTokens: event.target.value })}
            />
            {selectedModel?.maxTokens ? (
              <FieldDescription>
                {t('console.agents.model_limit', { limit: selectedModel.maxTokens.toLocaleString() })}
              </FieldDescription>
            ) : null}
          </Field>

          <Field>
            <FieldLabel>{t('console.agents.cache_retention_label')}</FieldLabel>
            <Select
              value={value.cacheRetention || 'default'}
              onValueChange={cacheRetention =>
                onChange({
                  cacheRetention:
                    cacheRetention === 'default'
                      ? ''
                      : (cacheRetention as NonNullable<AiAgentModelProfileConfig['cacheRetention']>)
                })
              }>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="default">{t('console.default_option')}</SelectItem>
                {CACHE_RETENTION_OPTIONS.map(option => (
                  <SelectItem key={option} value={option}>
                    {option}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
        </FieldGroup>
      )}
    </section>
  )
}

function ModelMetadata({ model }: { model: LlmProviderModelProjection }) {
  const { t } = useTranslation()
  return (
    <div className="flex flex-wrap gap-1.5">
      <Badge variant="secondary">{model.api}</Badge>
      <Badge variant="outline">{t('console.agents.ctx_badge', { tokens: model.contextWindow.toLocaleString() })}</Badge>
      {model.reasoning ? <Badge variant="outline">{t('console.agents.reasoning_badge')}</Badge> : null}
      {model.input.map(input => (
        <Badge key={input} variant="outline">
          {input}
        </Badge>
      ))}
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
      unwrap(api.console.agents({ uid: agent.uid })['chat-channels']({ channelName }).delete()),
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
  adapters: ConsoleExternalGatewayAdapter[]
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
        return unwrap(api.console.agents({ uid: agent.uid })['chat-channels']({ channelName: channel.name }).put(body))
      }
      return unwrap(api.console.agents({ uid: agent.uid })['chat-channels'].post(body))
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
              <Select
                value={adapterId}
                disabled={Boolean(channel)}
                onValueChange={value => setAdapterId(value ?? adapterId)}>
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
                  {interactive.session.error ? <AlertDescription>{interactive.session.error}</AlertDescription> : null}
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
  const { t } = useTranslation()
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
        placeholder={secretPresent ? t('console.channels.secret_saved') : undefined}
        autoComplete={field.type === 'password' ? 'new-password' : 'off'}
        onChange={event => onChange(field.type === 'number' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

function useInteractiveConfig(
  adapter: ConsoleExternalGatewayAdapter | undefined,
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
      unwrap(
        api.console['interactive-config-sessions'].post({
          adapterId: adapter?.id ?? '',
          currentConfig: config,
          locale
        })
      ),
    onSuccess: result => {
      setAppliedSessionId(null)
      setSessionId(result.session.sessionId)
    }
  })
  const session = useQuery({
    queryKey: ['console-interactive-config-session', sessionId],
    enabled: Boolean(sessionId),
    queryFn: () => unwrap(api.console['interactive-config-sessions']({ sessionId: sessionId ?? '' }).get()),
    refetchInterval: query => (query.state.data?.session.state === 'running' ? 1000 : false)
  })

  useEffect(() => {
    if (!sessionId) return

    return () => {
      // The API treats DELETE as idempotent, so this cleanup covers explicit
      // cancel, switching adapter/forms, and unmounting the channel editor.
      void unwrap(api.console['interactive-config-sessions']({ sessionId }).delete()).catch(() => {})
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

function adapterLabel(adapter: ConsoleExternalGatewayAdapter, locale: string): string {
  return resolveBullXPluginLocalizedText(adapter.setup?.displayName, locale, adapter.id) ?? adapter.id
}

function defaultConfigForAdapter(adapter: ConsoleExternalGatewayAdapter | undefined): JsonObject {
  return defaultPluginConfigForSetup(adapter?.setup)
}

import {
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  Button,
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  toast
} from '@ankole/uikit'
import { RiArrowLeftLine, RiInformationLine, RiRestartLine, RiSearchLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerPutAgentPluginOverrideMutation,
  ankoleWebAgentLibraryCapabilityControllerPutAgentSkillOverrideMutation,
  ankoleWebAgentLibraryCapabilityControllerPutGlobalAgentPluginMutation,
  ankoleWebAgentLibraryCapabilityControllerPutGlobalSkillMutation,
  ankoleWebControlPlanePluginControllerIndexOptions,
  ankoleWebControlPlanePluginControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AgentLibraryCapabilitiesResponse,
  AgentLibrarySkillCapabilityItem,
  AgentPluginCapabilityItem,
  ControlPlanePluginItem
} from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import {
  GLOBAL_LIBRARY_SCOPE,
  type AgentLibraryTab,
  agentLibraryOverrideValue,
  agentLibraryScopeQuery,
  availableAgentLibraryTabs,
  filterAgentPlugins,
  filterControlPlanePlugins,
  filterSkills,
  humanizeAgentPluginID,
  localizedJSONText,
  parseAgentLibraryOverrideValue
} from '../state/agent-library-capabilities'

export function AgentLibraryPage() {
  const { i18n, t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const scope = searchParams.get('scope') || GLOBAL_LIBRARY_SCOPE
  const [tab, setTab] = useState<AgentLibraryTab>('agent-plugins')
  const [pluginQuery, setPluginQuery] = useState('')
  const [skillQuery, setSkillQuery] = useState('')
  const [controlPlaneQuery, setControlPlaneQuery] = useState('')
  const data = useLibraryCapabilities(scope)
  const capabilityMutations = useCapabilityMutations(scope)
  const controlPlaneMutation = useControlPlanePluginMutation()

  useEffect(() => {
    if (!availableAgentLibraryTabs(scope).includes(tab)) setTab('agent-plugins')
  }, [scope, tab])

  const plugins = filterAgentPlugins(data.capabilities?.agent_plugins ?? [], useDeferredValue(pluginQuery))
  const skills = filterSkills(data.capabilities?.skills ?? [], useDeferredValue(skillQuery))
  const controlPlanePlugins = filterControlPlanePlugins(
    data.controlPlanePlugins,
    useDeferredValue(controlPlaneQuery),
    i18n.language
  )
  const setScope = (value: string) => {
    if (value === GLOBAL_LIBRARY_SCOPE) setSearchParams({})
    else setSearchParams({ scope: value })
  }

  return (
    <div className="grid gap-6">
      <header className="grid gap-4 border-b border-border pb-5 lg:grid-cols-[minmax(0,1fr)_minmax(260px,360px)] lg:items-end">
        <div className="grid gap-1">
          <h2 className="text-2xl font-semibold tracking-tight">{t('console.agent_library_capabilities.title')}</h2>
          <p className="max-w-3xl text-sm leading-6 text-muted-foreground">
            {t('console.agent_library_capabilities.description')}
          </p>
        </div>
        <ScopeSelect scope={scope} agents={data.agents} onChange={setScope} />
      </header>

      <ErrorBlock error={data.error} />

      <Tabs value={tab} onValueChange={value => setTab(value as AgentLibraryTab)} className="gap-5">
        <TabsList className="max-w-full overflow-x-auto">
          <TabsTrigger value="agent-plugins">
            {t('console.agent_library_capabilities.agent_plugins')} {data.capabilities?.agent_plugins.length ?? 0}
          </TabsTrigger>
          <TabsTrigger value="skills">
            {t('console.agent_library_capabilities.skills')} {data.capabilities?.skills.length ?? 0}
          </TabsTrigger>
          {scope === GLOBAL_LIBRARY_SCOPE ? (
            <TabsTrigger value="control-plane-plugins">
              {t('console.agent_library_capabilities.control_plane_plugins')} {data.controlPlanePlugins.length}
            </TabsTrigger>
          ) : null}
        </TabsList>

        <TabsContent value="agent-plugins" className="grid gap-4">
          <CapabilitySearch value={pluginQuery} onChange={setPluginQuery} kind="agent_plugins" />
          <CapabilityGrid
            loading={data.loading}
            empty={plugins.length === 0}
            emptyText={t('console.agent_library_capabilities.no_agent_plugins')}>
            {plugins.map(plugin => (
              <AgentPluginCard
                key={plugin.id}
                plugin={plugin}
                scope={scope}
                pending={capabilityMutations.pending}
                onChange={enabled => capabilityMutations.setAgentPlugin(plugin.id, enabled)}
              />
            ))}
          </CapabilityGrid>
        </TabsContent>

        <TabsContent value="skills" className="grid gap-4">
          <CapabilitySearch value={skillQuery} onChange={setSkillQuery} kind="skills" />
          <CapabilityGrid
            loading={data.loading}
            empty={skills.length === 0}
            emptyText={t('console.agent_library_capabilities.no_skills')}>
            {skills.map(skill => (
              <SkillCard
                key={skill.id}
                skill={skill}
                scope={scope}
                pending={capabilityMutations.pending}
                onChange={enabled => capabilityMutations.setSkill(skill.id, enabled)}
              />
            ))}
          </CapabilityGrid>
        </TabsContent>

        {scope === GLOBAL_LIBRARY_SCOPE ? (
          <TabsContent value="control-plane-plugins" className="grid gap-4">
            <CapabilitySearch value={controlPlaneQuery} onChange={setControlPlaneQuery} kind="control_plane_plugins" />
            <CapabilityGrid
              loading={data.controlPlaneLoading}
              empty={controlPlanePlugins.length === 0}
              emptyText={t('console.agent_library_capabilities.no_control_plane_plugins')}>
              {controlPlanePlugins.map(plugin => (
                <ControlPlanePluginCard
                  key={plugin.id}
                  plugin={plugin}
                  pending={controlPlaneMutation.isPending}
                  onChange={enabled => controlPlaneMutation.mutate({ body: { id: plugin.id, enabled } })}
                />
              ))}
            </CapabilityGrid>
          </TabsContent>
        ) : null}
      </Tabs>
    </div>
  )
}

export function AgentPluginDetailPage() {
  const { t } = useTranslation()
  const { pluginID = '' } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const scope = searchParams.get('scope') || GLOBAL_LIBRARY_SCOPE
  const data = useLibraryCapabilities(scope)
  const mutations = useCapabilityMutations(scope)
  const plugin = data.capabilities?.agent_plugins.find(item => item.id === pluginID)
  const setScope = (value: string) => {
    if (value === GLOBAL_LIBRARY_SCOPE) setSearchParams({})
    else setSearchParams({ scope: value })
  }

  return (
    <div className="grid gap-6">
      <header className="grid gap-4 border-b border-border pb-5 lg:grid-cols-[minmax(0,1fr)_minmax(260px,360px)] lg:items-end">
        <div className="grid gap-3">
          <Link
            to={agentLibraryScopeQuery('/agent-library', scope)}
            className="inline-flex w-fit items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
            <RiArrowLeftLine className="size-4" aria-hidden />
            {t('console.agent_library_capabilities.back')}
          </Link>
          <div>
            <h2 className="text-2xl font-semibold tracking-tight">
              {plugin ? humanizeAgentPluginID(plugin.id) : pluginID}
            </h2>
            <p className="mt-1 max-w-3xl text-sm leading-6 text-muted-foreground">
              {plugin?.description ?? t('console.agent_library_capabilities.plugin_not_found')}
            </p>
          </div>
        </div>
        <ScopeSelect scope={scope} agents={data.agents} onChange={setScope} />
      </header>

      <ErrorBlock error={data.error} />
      {data.loading ? <LoadingCards /> : null}
      {!data.loading && !plugin ? (
        <Alert variant="destructive">
          <RiInformationLine aria-hidden />
          <AlertTitle>{t('console.agent_library_capabilities.plugin_not_found')}</AlertTitle>
          <AlertDescription>{pluginID}</AlertDescription>
        </Alert>
      ) : null}
      {plugin ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="normal-case">{humanizeAgentPluginID(plugin.id)}</CardTitle>
              <CardDescription>
                {t('console.agent_library_capabilities.plugin_version_hash', {
                  version: plugin.version,
                  hash: plugin.content_hash
                })}
              </CardDescription>
              <CardAction>
                <CapabilityControl
                  scope={scope}
                  globalDefault={plugin.global_default_enabled}
                  override={plugin.override_enabled}
                  effective={plugin.effective_enabled}
                  disabled={mutations.pending}
                  onChange={enabled => mutations.setAgentPlugin(plugin.id, enabled)}
                />
              </CardAction>
            </CardHeader>
          </Card>

          <section className="grid gap-3">
            <div>
              <h3 className="text-lg font-semibold">{t('console.agent_library_capabilities.plugin_skills')}</h3>
              <p className="text-sm text-muted-foreground">
                {t('console.agent_library_capabilities.plugin_skills_description')}
              </p>
            </div>
            <CapabilityGrid
              loading={false}
              empty={plugin.skills.length === 0}
              emptyText={t('console.agent_library_capabilities.no_plugin_skills')}>
              {plugin.skills.map(skill => (
                <SkillCard
                  key={skill.id}
                  skill={skill}
                  scope={scope}
                  pending={mutations.pending}
                  parentEnabled={plugin.effective_enabled}
                  onChange={enabled => mutations.setSkill(skill.id, enabled)}
                />
              ))}
            </CapabilityGrid>
          </section>
        </>
      ) : null}
    </div>
  )
}

function ScopeSelect({
  agents,
  onChange,
  scope
}: {
  agents: Array<{ uid: string; display_name?: string | null }>
  onChange: (value: string) => void
  scope: string
}) {
  const { t } = useTranslation()
  return (
    <label className="grid gap-1.5 text-sm font-medium">
      {t('console.agent_library_capabilities.scope')}
      <Select value={scope} onValueChange={value => onChange(String(value))}>
        <SelectTrigger className="w-full">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value={GLOBAL_LIBRARY_SCOPE}>
            {t('console.agent_library_capabilities.global_defaults')}
          </SelectItem>
          {agents.map(agent => (
            <SelectItem key={agent.uid} value={agent.uid}>
              {agent.display_name ? `${agent.display_name} · ${agent.uid}` : agent.uid}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </label>
  )
}

function CapabilitySearch({
  kind,
  onChange,
  value
}: {
  kind: 'agent_plugins' | 'skills' | 'control_plane_plugins'
  onChange: (value: string) => void
  value: string
}) {
  const { t } = useTranslation()
  return (
    <label className="relative block max-w-xl">
      <span className="sr-only">{t(`console.agent_library_capabilities.search_${kind}`)}</span>
      <RiSearchLine className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
      <Input
        className="pl-9"
        value={value}
        placeholder={t(`console.agent_library_capabilities.search_${kind}`)}
        onChange={event => onChange(event.target.value)}
      />
    </label>
  )
}

function AgentPluginCard({
  onChange,
  pending,
  plugin,
  scope
}: {
  onChange: (enabled: boolean | null) => void
  pending: boolean
  plugin: AgentPluginCapabilityItem
  scope: string
}) {
  const { t } = useTranslation()
  return (
    <Card size="sm">
      <CardHeader>
        <CardTitle className="normal-case">
          <Link
            className="hover:text-primary hover:underline"
            to={agentLibraryScopeQuery(`/agent-library/agent-plugins/${plugin.id}`, scope)}>
            {humanizeAgentPluginID(plugin.id)}
          </Link>
        </CardTitle>
        <CardDescription>{plugin.description}</CardDescription>
        <CardAction>
          <CapabilityControl
            scope={scope}
            globalDefault={plugin.global_default_enabled}
            override={plugin.override_enabled}
            effective={plugin.effective_enabled}
            disabled={pending}
            onChange={onChange}
          />
        </CardAction>
      </CardHeader>
      <CardContent className="flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
        <span className="text-xs text-muted-foreground">
          {t('console.agent_library_capabilities.skill_count', { count: plugin.skills.length })}
        </span>
        <Button
          size="sm"
          variant="outline"
          render={<Link to={agentLibraryScopeQuery(`/agent-library/agent-plugins/${plugin.id}`, scope)} />}>
          {t('console.agent_library_capabilities.view_details')}
        </Button>
      </CardContent>
    </Card>
  )
}

function SkillCard({
  onChange,
  parentEnabled = true,
  pending,
  scope,
  skill
}: {
  onChange: (enabled: boolean | null) => void
  parentEnabled?: boolean
  pending: boolean
  scope: string
  skill: AgentLibrarySkillCapabilityItem
}) {
  const { t } = useTranslation()
  return (
    <Card size="sm">
      <CardHeader>
        <CardTitle className="normal-case">{skill.name}</CardTitle>
        <CardDescription>{skill.description}</CardDescription>
        <CardAction>
          <CapabilityControl
            scope={scope}
            globalDefault={skill.global_default_enabled}
            override={skill.override_enabled}
            effective={skill.effective_enabled}
            disabled={pending}
            inheritLabel={
              skill.source_kind === 'installed'
                ? t('console.agent_library_capabilities.inherit_source_default')
                : undefined
            }
            onChange={onChange}
          />
        </CardAction>
      </CardHeader>
      <CardContent className="flex flex-wrap gap-2 border-t border-border pt-4">
        {skill.source_kind === 'installed' ? (
          <Badge variant="secondary">{t('console.agent_library_capabilities.agent_private')}</Badge>
        ) : null}
        {!parentEnabled ? (
          <Badge variant="outline">{t('console.agent_library_capabilities.parent_disabled')}</Badge>
        ) : null}
        <EffectiveBadge enabled={skill.effective_enabled} />
      </CardContent>
    </Card>
  )
}

function ControlPlanePluginCard({
  onChange,
  pending,
  plugin
}: {
  onChange: (enabled: boolean) => void
  pending: boolean
  plugin: ControlPlanePluginItem
}) {
  const { i18n, t } = useTranslation()
  return (
    <Card size="sm">
      <CardHeader>
        <CardTitle className="normal-case">
          {localizedJSONText(plugin.display_name, i18n.language) || plugin.id}
        </CardTitle>
        <CardDescription>{localizedJSONText(plugin.description, i18n.language)}</CardDescription>
        <CardAction>
          <Switch
            aria-label={t('console.agent_library_capabilities.configure_plugin', { id: plugin.id })}
            checked={plugin.configured_enabled}
            disabled={pending}
            onCheckedChange={onChange}
          />
        </CardAction>
      </CardHeader>
      <CardContent className="flex flex-wrap gap-2 border-t border-border pt-4">
        <Badge variant={plugin.active ? 'success' : 'outline'}>
          {plugin.active
            ? t('console.agent_library_capabilities.active_now')
            : t('console.agent_library_capabilities.inactive_now')}
        </Badge>
        <Badge variant={plugin.configured_enabled ? 'secondary' : 'outline'}>
          {plugin.configured_enabled
            ? t('console.agent_library_capabilities.enabled_next_start')
            : t('console.agent_library_capabilities.disabled_next_start')}
        </Badge>
        {plugin.restart_required ? (
          <Badge variant="warning">
            <RiRestartLine className="size-3" aria-hidden />
            {t('console.agent_library_capabilities.restart_required')}
          </Badge>
        ) : null}
      </CardContent>
    </Card>
  )
}

function CapabilityControl({
  disabled,
  effective,
  globalDefault,
  inheritLabel,
  onChange,
  override,
  scope
}: {
  disabled: boolean
  effective: boolean
  globalDefault: boolean
  inheritLabel?: string
  onChange: (enabled: boolean | null) => void
  override: boolean | null
  scope: string
}) {
  const { t } = useTranslation()
  if (scope === GLOBAL_LIBRARY_SCOPE) {
    return (
      <Switch
        aria-label={t('console.agent_library_capabilities.set_global_default')}
        checked={globalDefault}
        disabled={disabled}
        onCheckedChange={checked => onChange(checked)}
      />
    )
  }

  return (
    <div className="grid justify-items-end gap-1">
      <Select
        value={agentLibraryOverrideValue(override)}
        disabled={disabled}
        onValueChange={value => onChange(parseAgentLibraryOverrideValue(String(value)))}>
        <SelectTrigger className="w-40">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="inherit">{inheritLabel ?? t('console.agent_library_capabilities.inherit')}</SelectItem>
          <SelectItem value="enabled">{t('console.agent_library_capabilities.enabled')}</SelectItem>
          <SelectItem value="disabled">{t('console.agent_library_capabilities.disabled')}</SelectItem>
        </SelectContent>
      </Select>
      <span className="text-xs text-muted-foreground">
        {t('console.agent_library_capabilities.effective_state', {
          state: effective
            ? t('console.agent_library_capabilities.enabled')
            : t('console.agent_library_capabilities.disabled')
        })}
      </span>
    </div>
  )
}

function EffectiveBadge({ enabled }: { enabled: boolean }) {
  const { t } = useTranslation()
  return (
    <Badge variant={enabled ? 'success' : 'outline'}>
      {enabled
        ? t('console.agent_library_capabilities.effective_enabled')
        : t('console.agent_library_capabilities.effective_disabled')}
    </Badge>
  )
}

function CapabilityGrid({
  children,
  empty,
  emptyText,
  loading
}: {
  children: React.ReactNode
  empty: boolean
  emptyText: string
  loading: boolean
}) {
  if (loading) return <LoadingCards />
  if (empty) {
    return (
      <p className="border border-dashed border-border p-8 text-center text-sm text-muted-foreground">{emptyText}</p>
    )
  }
  return <div className="grid gap-4 xl:grid-cols-2">{children}</div>
}

function LoadingCards() {
  return (
    <div className="grid gap-4 xl:grid-cols-2" aria-busy="true">
      {[0, 1, 2].map(index => (
        <div key={index} className="h-36 animate-pulse bg-muted" />
      ))}
    </div>
  )
}

function useLibraryCapabilities(scope: string) {
  const global = scope === GLOBAL_LIBRARY_SCOPE
  const agentsQuery = useQuery(ankoleWebAgentControllerIndexOptions())
  const globalQuery = useQuery({
    ...ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions(),
    enabled: global
  })
  const agentQuery = useQuery({
    ...ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions({ path: { agent_uid: scope } }),
    enabled: !global
  })
  const controlPlaneQuery = useQuery({
    ...ankoleWebControlPlanePluginControllerIndexOptions(),
    enabled: global
  })

  return {
    agents: agentsQuery.data?.agents ?? [],
    capabilities: (global ? globalQuery.data : agentQuery.data) as AgentLibraryCapabilitiesResponse | undefined,
    controlPlanePlugins: controlPlaneQuery.data?.control_plane_plugins ?? [],
    controlPlaneLoading: controlPlaneQuery.isLoading,
    error: agentsQuery.error ?? globalQuery.error ?? agentQuery.error ?? controlPlaneQuery.error,
    loading: agentsQuery.isLoading || (global ? globalQuery.isLoading : agentQuery.isLoading)
  }
}

function useCapabilityMutations(scope: string) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const refresh = () => void queryClient.invalidateQueries()
  const success = () => {
    toast.success(t('console.agent_library_capabilities.saved'))
    refresh()
  }
  const error = (mutationError: unknown) => toast.error(requestErrorMessage(mutationError))
  const globalPlugin = useMutation({
    ...ankoleWebAgentLibraryCapabilityControllerPutGlobalAgentPluginMutation(),
    onSuccess: success,
    onError: error
  })
  const agentPlugin = useMutation({
    ...ankoleWebAgentLibraryCapabilityControllerPutAgentPluginOverrideMutation(),
    onSuccess: success,
    onError: error
  })
  const globalSkill = useMutation({
    ...ankoleWebAgentLibraryCapabilityControllerPutGlobalSkillMutation(),
    onSuccess: success,
    onError: error
  })
  const agentSkill = useMutation({
    ...ankoleWebAgentLibraryCapabilityControllerPutAgentSkillOverrideMutation(),
    onSuccess: success,
    onError: error
  })

  return {
    pending: globalPlugin.isPending || agentPlugin.isPending || globalSkill.isPending || agentSkill.isPending,
    setAgentPlugin(id: string, enabled: boolean | null) {
      if (scope === GLOBAL_LIBRARY_SCOPE) globalPlugin.mutate({ path: { id }, body: { enabled: enabled === true } })
      else agentPlugin.mutate({ path: { agent_uid: scope, id }, body: { enabled } })
    },
    setSkill(id: string, enabled: boolean | null) {
      if (scope === GLOBAL_LIBRARY_SCOPE) globalSkill.mutate({ path: { id }, body: { enabled: enabled === true } })
      else agentSkill.mutate({ path: { agent_uid: scope, id }, body: { enabled } })
    }
  }
}

function useControlPlanePluginMutation() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  return useMutation({
    ...ankoleWebControlPlanePluginControllerUpdateMutation(),
    onSuccess: () => {
      toast.success(t('console.agent_library_capabilities.saved_for_restart'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
}

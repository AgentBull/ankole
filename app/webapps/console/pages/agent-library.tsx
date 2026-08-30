import {
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  Button,
  buttonVariants,
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Switch,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiInformationLine, RiRestartLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useState } from 'react'
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
  ankoleWebAgentSkillLessonControllerCreateMutation,
  ankoleWebAgentSkillLessonControllerIndexOptions,
  ankoleWebAgentSkillLessonControllerRetireMutation,
  ankoleWebControlPlanePluginControllerIndexOptions,
  ankoleWebControlPlanePluginControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AgentLibraryCapabilitiesResponse,
  AgentLibrarySkillCapabilityItem,
  AgentPluginCapabilityItem,
  AgentSkillLessonItem,
  ControlPlanePluginItem
} from '../api/generated/types.gen'
import { BackLink, PageHeader, PageStack, RefreshButton } from '../console-page'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { ConfirmDeleteButton, SaveButton } from '../console-form'
import { ResourceSearch } from '../console-list-page'
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
  const lessons = useSkillLessons(scope)
  const controlPlaneMutation = useControlPlanePluginMutation()

  // Derived during render: an agent scope has no control-plane tab, so the
  // stored choice falls back without an effect (and comes back when the
  // operator returns to the global scope).
  const activeTab = availableAgentLibraryTabs(scope).includes(tab) ? tab : 'agent-plugins'

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
    <PageStack>
      <PageHeader
        title={t('console.agent_library_capabilities.title')}
        description={t('console.agent_library_capabilities.description')}
        actions={
          <>
            <RefreshButton />
            <ScopeSelect scope={scope} agents={data.agents} onChange={setScope} />
          </>
        }
      />

      <ErrorBlock error={data.error ?? lessons?.error} />

      <Tabs value={activeTab} onValueChange={value => setTab(value as AgentLibraryTab)} className="min-w-0 gap-5">
        <TabsList className="max-w-full overflow-x-auto">
          {/* The count used to be a bare number after the label, so "Agent Plugins 3"
              read as part of the name. A tag says it is a quantity. */}
          <TabsTrigger value="agent-plugins">
            {t('console.agent_library_capabilities.agent_plugins')}
            <TabCount value={data.capabilities?.agent_plugins.length ?? 0} />
          </TabsTrigger>
          <TabsTrigger value="skills">
            {t('console.agent_library_capabilities.skills')}
            <TabCount value={data.capabilities?.skills.length ?? 0} />
          </TabsTrigger>
          {scope === GLOBAL_LIBRARY_SCOPE ? (
            <TabsTrigger value="control-plane-plugins">
              {t('console.agent_library_capabilities.control_plane_plugins')}
              <TabCount value={data.controlPlanePlugins.length} />
            </TabsTrigger>
          ) : null}
        </TabsList>

        <TabsContent value="agent-plugins" className="grid min-w-0 gap-4">
          <CapabilitySearch value={pluginQuery} onChange={setPluginQuery} kind="agent_plugins" />
          <CapabilityGrid
            loading={data.loading}
            empty={plugins.length === 0}
            isFiltered={Boolean(pluginQuery.trim())}
            emptyDescription={t('console.agent_library.empty_agent_plugins')}
            onClearFilters={() => setPluginQuery('')}>
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

        <TabsContent value="skills" className="grid min-w-0 gap-4">
          <CapabilitySearch value={skillQuery} onChange={setSkillQuery} kind="skills" />
          <CapabilityGrid
            loading={data.loading}
            empty={skills.length === 0}
            isFiltered={Boolean(skillQuery.trim())}
            emptyDescription={t('console.agent_library.empty_skills')}
            onClearFilters={() => setSkillQuery('')}>
            {skills.map(skill => (
              <SkillCard
                key={`${scope}:${skill.id}`}
                skill={skill}
                scope={scope}
                pending={capabilityMutations.pending}
                lessons={lessons}
                onChange={enabled => capabilityMutations.setSkill(skill.id, enabled)}
              />
            ))}
          </CapabilityGrid>
        </TabsContent>

        {scope === GLOBAL_LIBRARY_SCOPE ? (
          <TabsContent value="control-plane-plugins" className="grid min-w-0 gap-4">
            <CapabilitySearch value={controlPlaneQuery} onChange={setControlPlaneQuery} kind="control_plane_plugins" />
            <CapabilityGrid
              loading={data.controlPlaneLoading}
              empty={controlPlanePlugins.length === 0}
              isFiltered={Boolean(controlPlaneQuery.trim())}
              emptyDescription={t('console.agent_library.empty_control_plane_plugins')}
              onClearFilters={() => setControlPlaneQuery('')}>
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
    </PageStack>
  )
}

export function AgentPluginDetailPage() {
  const { t } = useTranslation()
  const { pluginID = '' } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const scope = searchParams.get('scope') || GLOBAL_LIBRARY_SCOPE
  const data = useLibraryCapabilities(scope)
  const mutations = useCapabilityMutations(scope)
  const lessons = useSkillLessons(scope)
  const plugin = data.capabilities?.agent_plugins.find(item => item.id === pluginID)
  const setScope = (value: string) => {
    if (value === GLOBAL_LIBRARY_SCOPE) setSearchParams({})
    else setSearchParams({ scope: value })
  }

  return (
    <PageStack>
      <header className="grid min-w-0 grid-cols-1 gap-4 border-b border-border pb-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
        <div className="grid gap-3">
          <BackLink
            to={agentLibraryScopeQuery('/agent-library', scope)}
            label={t('console.agent_library_capabilities.back')}
          />
          <div>
            <h2 className="text-2xl font-semibold tracking-normal">
              {plugin ? humanizeAgentPluginID(plugin.id) : pluginID}
            </h2>
            <p className="mt-1 max-w-3xl text-sm leading-6 text-muted-foreground">
              {plugin?.description ?? t('console.agent_library_capabilities.plugin_not_found')}
            </p>
          </div>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <RefreshButton />
          <ScopeSelect scope={scope} agents={data.agents} onChange={setScope} />
        </div>
      </header>

      <ErrorBlock error={data.error ?? lessons?.error} />
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
                {t('console.agent_library_capabilities.plugin_version', { version: plugin.version })}
              </CardDescription>
              <CardAction>
                {scope === GLOBAL_LIBRARY_SCOPE ? (
                  <GlobalDefaultSwitch
                    capabilityName={humanizeAgentPluginID(plugin.id)}
                    checked={plugin.global_default_enabled}
                    disabled={mutations.pending}
                    onChange={enabled => mutations.setAgentPlugin(plugin.id, enabled)}
                  />
                ) : (
                  <AgentOverrideControl
                    override={plugin.override_enabled}
                    effective={plugin.effective_enabled}
                    disabled={mutations.pending}
                    onChange={enabled => mutations.setAgentPlugin(plugin.id, enabled)}
                  />
                )}
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
              emptyDescription={t('console.agent_library_capabilities.no_plugin_skills')}>
              {plugin.skills.map(skill => (
                <SkillCard
                  key={`${scope}:${skill.id}`}
                  skill={skill}
                  scope={scope}
                  pending={mutations.pending}
                  parentEnabled={plugin.effective_enabled}
                  lessons={lessons}
                  onChange={enabled => mutations.setSkill(skill.id, enabled)}
                />
              ))}
            </CapabilityGrid>
          </section>
        </>
      ) : null}
    </PageStack>
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
    <label className="grid w-full min-w-64 gap-1.5 text-sm font-medium sm:w-80">
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
  const label = t(`console.agent_library_capabilities.search_${kind}`)
  return <ResourceSearch label={label} placeholder={label} value={value} onChange={onChange} />
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
  const name = humanizeAgentPluginID(plugin.id)
  return (
    // `h-full` plus `mt-auto` below keeps the footers of two cards in one grid row
    // on the same line. Without it a short description pulled its card's footer up
    // and the row read as broken.
    <Card size="sm" className="h-full">
      <CardHeader>
        <CardTitle className="normal-case">
          <Link
            className="hover:text-link hover:underline"
            to={agentLibraryScopeQuery(`/agent-library/agent-plugins/${plugin.id}`, scope)}>
            {name}
          </Link>
        </CardTitle>
        <CardDescription>{plugin.description}</CardDescription>
        <CardAction>
          {scope === GLOBAL_LIBRARY_SCOPE ? (
            <GlobalDefaultSwitch
              capabilityName={name}
              checked={plugin.global_default_enabled}
              disabled={pending}
              onChange={onChange}
            />
          ) : (
            <AgentOverrideControl
              override={plugin.override_enabled}
              effective={plugin.effective_enabled}
              disabled={pending}
              onChange={onChange}
            />
          )}
        </CardAction>
      </CardHeader>
      <CardContent className="mt-auto flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
        <span className="text-xs text-muted-foreground">
          {t('console.agent_library_capabilities.skill_count', { count: plugin.skills.length })}
        </span>
        {/* A styled link, not a Button rendering a link: this control navigates,
            and the button primitive gave the anchor button semantics instead.
            The per-card label also stops every card announcing one same phrase. */}
        <Link
          aria-label={t('common.view_details_for', { name })}
          className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}
          to={agentLibraryScopeQuery(`/agent-library/agent-plugins/${plugin.id}`, scope)}>
          {t('console.agent_library_capabilities.view_details')}
        </Link>
      </CardContent>
    </Card>
  )
}

function SkillCard({
  lessons,
  onChange,
  parentEnabled = true,
  pending,
  scope,
  skill
}: {
  lessons?: SkillLessonsController
  onChange: (enabled: boolean | null) => void
  parentEnabled?: boolean
  pending: boolean
  scope: string
  skill: AgentLibrarySkillCapabilityItem
}) {
  const { t } = useTranslation()
  return (
    <Card size="sm" className="h-full">
      <CardHeader>
        <CardTitle className="normal-case">{skill.name}</CardTitle>
        <CardDescription>{skill.description}</CardDescription>
        <CardAction>
          {scope === GLOBAL_LIBRARY_SCOPE ? (
            <GlobalDefaultSwitch
              capabilityName={skill.name}
              checked={skill.global_default_enabled}
              disabled={pending}
              onChange={onChange}
            />
          ) : (
            <AgentOverrideControl
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
          )}
        </CardAction>
      </CardHeader>
      <CardContent className="mt-auto grid gap-4 border-t border-border pt-4">
        <div className="flex flex-wrap gap-2">
          {skill.source_kind === 'installed' ? (
            <Badge variant="secondary">{t('console.agent_library_capabilities.agent_private')}</Badge>
          ) : null}
          {!parentEnabled ? (
            <Badge variant="outline">{t('console.agent_library_capabilities.parent_disabled')}</Badge>
          ) : null}
          <EffectiveBadge enabled={skill.effective_enabled} />
        </div>
        {lessons ? (
          <SkillLessons
            controller={lessons}
            skillName={skill.name}
            writable={skill.effective_enabled && parentEnabled}
          />
        ) : null}
      </CardContent>
    </Card>
  )
}

function SkillLessons({
  controller,
  skillName,
  writable
}: {
  controller: SkillLessonsController
  skillName: string
  writable: boolean
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<string>()
  const group = controller.bySkill.get(skillName)
  const active = group?.active ?? []
  const retired = group?.retired ?? []
  const adding = draft !== undefined

  return (
    <section className="grid gap-2 border-t border-border pt-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h4 className="text-sm font-medium">{t('console.agent_library_capabilities.lessons')}</h4>
        {writable && !adding ? (
          <Button type="button" size="xs" variant="outline" onClick={() => setDraft('')}>
            {t('console.agent_library_capabilities.lesson_add')}
          </Button>
        ) : null}
      </div>

      {active.length === 0 ? (
        <p className="text-xs text-muted-foreground">{t('console.agent_library_capabilities.lessons_empty')}</p>
      ) : (
        <ul className="grid gap-2">
          {active.map(lesson => (
            <SkillLessonRow key={lesson.id} lesson={lesson}>
              <ConfirmDeleteButton
                label={t('console.agent_library_capabilities.lesson_retire')}
                pending={controller.pending}
                confirm={{
                  title: t('console.agent_library_capabilities.lesson_retire_title'),
                  description: t('console.agent_library_capabilities.lesson_retire_description', {
                    skill: skillName
                  }),
                  confirmLabel: t('console.agent_library_capabilities.lesson_retire')
                }}
                onConfirm={() => controller.retire(lesson.id)}
              />
            </SkillLessonRow>
          ))}
        </ul>
      )}

      {adding ? (
        <form
          className="grid gap-2"
          onSubmit={event => {
            event.preventDefault()
            controller.add(skillName, draft, () => setDraft(undefined))
          }}>
          <Textarea
            aria-label={t('console.agent_library_capabilities.lesson_add')}
            className="min-h-24"
            required
            value={draft}
            placeholder={t('console.agent_library_capabilities.lesson_placeholder')}
            onChange={event => setDraft(event.target.value)}
          />
          <div className="flex justify-end gap-2">
            <Button type="button" size="sm" variant="ghost" onClick={() => setDraft(undefined)}>
              {t('common.cancel')}
            </Button>
            <SaveButton
              type="submit"
              size="sm"
              disabled={controller.pending}
              loading={controller.pending}
              incomplete={!draft.trim() && !controller.pending}>
              {t('common.save')}
            </SaveButton>
          </div>
        </form>
      ) : null}

      {!writable && (active.length > 0 || retired.length > 0) ? (
        <p className="text-xs text-muted-foreground">{t('console.agent_library_capabilities.lessons_disabled_hint')}</p>
      ) : null}

      {retired.length > 0 ? (
        <details>
          <summary className="cursor-pointer text-xs font-medium text-muted-foreground">
            {t('console.agent_library_capabilities.lessons_retired_section', { count: retired.length })}
          </summary>
          <ul className="mt-2 grid gap-2">
            {retired.map(lesson => (
              <SkillLessonRow key={lesson.id} lesson={lesson} />
            ))}
          </ul>
        </details>
      ) : null}
    </section>
  )
}

/** One lesson with its provenance line; active rows slot the retire control into `children`. */
function SkillLessonRow({ children, lesson }: { children?: React.ReactNode; lesson: AgentSkillLessonItem }) {
  const { t } = useTranslation()
  return (
    <li className="grid gap-2 border border-border bg-muted p-3">
      <div className="flex items-start justify-between gap-2">
        <p className="min-w-0 flex-1 whitespace-pre-wrap text-xs leading-5">{lesson.content}</p>
        {children}
      </div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
        <Badge variant={lesson.author_kind === 'human' ? 'secondary' : 'info'}>
          {lesson.author_kind === 'human'
            ? t('console.agent_library_capabilities.lessons_author_human')
            : t('console.agent_library_capabilities.lessons_author_dreaming')}
        </Badge>
        <span>{formatConsoleDate(lesson.created_at)}</span>
        {lesson.checked_release ? (
          <span>
            {t('console.agent_library_capabilities.lessons_checked_release', { release: lesson.checked_release })}
          </span>
        ) : null}
        {lesson.review_after ? (
          <span>
            {t('console.agent_library_capabilities.lessons_review_after', {
              date: formatConsoleDate(lesson.review_after)
            })}
          </span>
        ) : null}
        {lesson.evidence_job_ids.length > 0 ? (
          <span className="flex flex-wrap items-center gap-1.5">
            {t('console.agent_library_capabilities.lessons_evidence')}
            {lesson.evidence_job_ids.map(jobID => (
              <Link key={jobID} className="text-link hover:underline" to={`/background-agent-jobs?job=${jobID}`}>
                #{jobID}
              </Link>
            ))}
          </span>
        ) : null}
        {lesson.retired_at ? (
          <>
            <Badge variant="outline">
              {t(`console.agent_library_capabilities.lessons_retire_reason_${lesson.retire_reason}`)}
            </Badge>
            <span>{formatConsoleDate(lesson.retired_at)}</span>
          </>
        ) : null}
      </div>
    </li>
  )
}

export type SkillLessonGroup = {
  active: AgentSkillLessonItem[]
  retired: AgentSkillLessonItem[]
}

/** Splits the agent's lessons per skill, keeping the server's newest-first order. */
export function groupSkillLessons(lessons: AgentSkillLessonItem[]): Map<string, SkillLessonGroup> {
  const groups = new Map<string, SkillLessonGroup>()
  for (const lesson of lessons) {
    const group = groups.get(lesson.skill_name) ?? { active: [], retired: [] }
    if (lesson.retired_at) group.retired.push(lesson)
    else group.active.push(lesson)
    groups.set(lesson.skill_name, group)
  }
  return groups
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

/** Toggles the installation-wide default for one capability. */
function GlobalDefaultSwitch({
  capabilityName,
  checked,
  disabled,
  onChange
}: {
  /** Names the switch after the capability it toggles, not after what it does. */
  capabilityName: string
  checked: boolean
  disabled: boolean
  onChange: (enabled: boolean) => void
}) {
  const { t } = useTranslation()
  return (
    <Switch
      aria-label={t('console.agent_library_capabilities.set_global_default_for', { name: capabilityName })}
      checked={checked}
      disabled={disabled}
      onCheckedChange={checked => onChange(checked)}
    />
  )
}

/** Sets one agent's override — inherit, enabled, or disabled — and shows the effective result. */
function AgentOverrideControl({
  disabled,
  effective,
  inheritLabel,
  onChange,
  override
}: {
  disabled: boolean
  effective: boolean
  inheritLabel?: string
  onChange: (enabled: boolean | null) => void
  override: boolean | null
}) {
  const { t } = useTranslation()
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

function TabCount({ value }: { value: number }) {
  return (
    <Badge variant="secondary" className="ml-1.5 tabular-nums">
      {value}
    </Badge>
  )
}

function CapabilityGrid({
  children,
  empty,
  emptyDescription,
  isFiltered = false,
  loading,
  onClearFilters
}: {
  children: React.ReactNode
  empty: boolean
  /** Explanation for a source that is empty without a search. */
  emptyDescription?: string
  isFiltered?: boolean
  loading: boolean
  onClearFilters?: () => void
}) {
  const { t } = useTranslation()

  if (loading) return <LoadingCards />
  if (empty) {
    return (
      <Empty className="items-start border border-border bg-card p-8 text-left md:p-10">
        <EmptyHeader className="max-w-xl items-start">
          <EmptyTitle>{isFiltered ? t('console.empty.no_results_title') : t('console.empty.title')}</EmptyTitle>
          {isFiltered || emptyDescription ? (
            <EmptyDescription className="text-balance">
              {isFiltered ? t('console.empty.no_results_description') : emptyDescription}
            </EmptyDescription>
          ) : null}
        </EmptyHeader>
        {isFiltered && onClearFilters ? (
          <Button size="sm" type="button" variant="outline" onClick={onClearFilters}>
            {t('console.empty.clear_filters')}
          </Button>
        ) : null}
      </Empty>
    )
  }
  return <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">{children}</div>
}

function LoadingCards() {
  return (
    <div className="grid grid-cols-1 gap-4 xl:grid-cols-2" aria-busy="true">
      {[0, 1, 2].map(index => (
        <Skeleton key={index} className="h-36" />
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

type SkillLessonsController = {
  bySkill: Map<string, SkillLessonGroup>
  error: unknown
  pending: boolean
  add: (skillName: string, content: string, onSuccess: () => void) => void
  retire: (lessonID: string) => void
}

// Dreaming writes leased lessons through its own gates; this surface is the
// operator's veto and manual path. A retired Dreaming lesson joins the
// immunity list, so Dreaming never re-adds equivalent content.
function useSkillLessons(scope: string): SkillLessonsController | undefined {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const agentScope = scope !== GLOBAL_LIBRARY_SCOPE
  const lessonsQuery = useQuery({
    ...ankoleWebAgentSkillLessonControllerIndexOptions({ path: { agent_uid: scope } }),
    enabled: agentScope
  })
  const onError = (mutationError: unknown) => toast.error(requestErrorMessage(mutationError))
  const refresh = () => void queryClient.invalidateQueries()
  const create = useMutation({
    ...ankoleWebAgentSkillLessonControllerCreateMutation(),
    onSuccess: () => {
      toast.success(t('console.agent_library_capabilities.lesson_added'))
      refresh()
    },
    onError
  })
  const retire = useMutation({
    ...ankoleWebAgentSkillLessonControllerRetireMutation(),
    onSuccess: () => {
      toast.success(t('console.agent_library_capabilities.lesson_retired'))
      refresh()
    },
    onError
  })

  if (!agentScope) return undefined

  return {
    bySkill: groupSkillLessons(lessonsQuery.data?.skill_lessons ?? []),
    error: lessonsQuery.error,
    pending: create.isPending || retire.isPending,
    add(skillName, content, onSuccess) {
      create.mutate({ path: { agent_uid: scope }, body: { skill_name: skillName, content } }, { onSuccess })
    },
    retire(lessonID) {
      retire.mutate({ path: { agent_uid: scope, lesson_id: lessonID } })
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

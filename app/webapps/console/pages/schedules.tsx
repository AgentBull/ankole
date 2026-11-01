import { TableRow, useMutation, useQuery, Link, useSearchParams, useNavigate } from '../tenant-context'
import { uuidV4 } from '@agentbull/active-support'
import { LIST_REFRESH_MS } from '../refresh-intervals'
import {
  Button,
  buttonVariants,
  cn,
  CreatableCombobox,
  CronEditor,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  Textarea,
  toast
} from '@ankole/uikit'
import {
  RiCalendarScheduleLine,
  RiCloseCircleLine,
  RiPauseCircleLine,
  RiPlayCircleLine,
  RiTimerLine
} from '@remixicon/react'
import type { TFunction } from 'i18next'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useParams } from '@tanstack/react-router'
import i18n from '../../common/i18n'
import { linkTarget } from '../../common/router'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { listAgentSessionsOptions, listSignalBindingsOptions } from '../api/v2/generated/@tanstack/react-query.gen'
import { agentListOptions } from '../api/agents'
import { aiGatewayConversationsOptions } from '../api/ai-gateway-conversations'
import type { CronSchedule, ScheduledEvent } from '../api/v2/generated/types.gen'
import { fromDocument, type Flat } from '../api/json-api'
import {
  cancelCheckbackMutation,
  createCronScheduleMutation,
  getCronScheduleOptions,
  listCheckbacksOptions,
  listCronScheduleRunsOptions,
  listCronSchedulesOptions,
  pauseCronScheduleMutation,
  removeCronScheduleMutation,
  resumeCronScheduleMutation,
  runCronScheduleMutation,
  updateCronScheduleMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import { activeAgents, AgentFilter, resolveAgentUID, useAgentScope, type AgentScope } from '../console-agent-scope'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { conversationDisplayName } from '../conversation-presentation'
import {
  ConfirmDeleteButton,
  cronEditorLabels,
  EditorNotFound,
  LabeledField,
  ReadOnlyValue,
  ResourceEditorPage,
  StatusIndicator,
  type StatusTone
} from '../console-form'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch, RowActions, SubNav } from '../console-list-page'
import {
  decomposeEveryMs,
  deliveryTargetDrafts,
  isMutableCronStatus,
  scheduleOccurrenceBound,
  ScheduleEditorModel,
  type ScheduleDelivery,
  type ScheduleEditorDraft,
  type ScheduleFieldErrors,
  type ScheduleIntervalUnit,
  type ScheduleRecurrence
} from '../state/schedule-editor-model'
import { matchesResourceSearch } from '../state/resource-search'
import { timeZoneCurrentTime, timeZoneOffsetLabel, timeZoneOptions } from '../state/timezone-editor'
import { useEditorDraft } from '../use-editor-draft'

// The recurrence and delivery JSON are normalized by the Schedule domain.
// All resource fields, including optional calculations, use the generated contract.
type CronScheduleItem = Flat<CronSchedule> & {
  schedule: ScheduleRecurrence
  delivery?: ScheduleDelivery | null
}

type ScheduledEventItem = Flat<ScheduledEvent>

/** The list of cron schedules, also read by the route loader. */
export function cronScheduleListOptions(agentUID: string | undefined) {
  return listCronSchedulesOptions({ query: { agent: agentUID || undefined } })
}

/** The list of checkbacks, also read by the route loader. */
export function checkbackListOptions(agentUID: string | undefined) {
  return listCheckbacksOptions({ query: { agent: agentUID || undefined, page: { limit: 100 } } })
}

/** A pending checkback still has a wake edge ahead of it; the rest are history. */
function pending(row: ScheduledEventItem): boolean {
  return row.status === 'scheduled'
}

export function SchedulesListPage() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const scope = useAgentScope()
  const hasActiveAgents = activeAgents(scope.agents).length > 0

  const crons = useQuery({
    ...cronScheduleListOptions(scope.agentUID),
    select: document => fromDocument(document) as CronScheduleItem[],
    refetchInterval: LIST_REFRESH_MS
  })

  const agentByUID = new Map(scope.agents.map(agent => [agent.uid, agent]))
  const rows = (crons.data ?? []).filter(row => {
    const agent = agentByUID.get(row.agent_uid)
    return matchesResourceSearch(
      query,
      row.name,
      row.binding_name,
      row.agent_uid,
      agent?.display_name,
      agent?.uid,
      row.owner_session_id,
      row.status,
      scheduleStatusLabel(t, row.status),
      describeSchedule(t, row.schedule)
    )
  })

  const pauseCron = useMutation({
    ...pauseCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.paused'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const resumeCron = useMutation({
    ...resumeCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.resumed'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const runCron = useMutation({
    ...runCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.ran'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCron = useMutation({
    ...removeCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.deleted'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.schedules.title')}
      description={t('console.schedules.description')}
      columns={[
        t('console.schedules.name'),
        t('console.agents.agent'),
        t('console.schedules.owner_session'),
        t('console.schedules.schedule'),
        t('console.schedules.next_fire'),
        t('console.schedules.last_fire'),
        t('console.schedules.state')
      ]}
      count={rows.length}
      createTo={
        hasActiveAgents ? (scope.agentUID ? `new?agent=${encodeURIComponent(scope.agentUID)}` : 'new') : undefined
      }
      createLabel={t('console.schedules.new')}
      emptyIcon={<RiCalendarScheduleLine aria-hidden />}
      emptyTitle={t('console.schedules.empty_title')}
      emptyDescription={
        hasActiveAgents ? t('console.schedules.empty_description') : t('console.schedules.empty_no_agents_description')
      }
      emptyAction={
        hasActiveAgents ? undefined : (
          <Link className={cn(buttonVariants({ size: 'sm' }))} to="/agents/new">
            {t('console.agents.new')}
          </Link>
        )
      }
      error={crons.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim())}
      isLoading={crons.isLoading}
      onClearFilters={() => setQuery('')}
      subNav={<ScheduleTabs scope={scope} />}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.schedules.search')}
          placeholder={t('console.schedules.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={<AgentFilter scope={scope} />}
        />
      }>
      {rows.map(row => {
        const editTo = `/schedules/${encodeURIComponent(row.agent_uid)}/${encodeURIComponent(row.id)}`
        const toggleable = isMutableCronStatus(row.status)
        return (
          <TableRow key={`${row.agent_uid}:${row.id}`}>
            <TableCell className="font-mono text-xs">
              <Link data-row-link className="text-foreground" {...linkTarget(editTo)}>
                {row.name || row.binding_name}
              </Link>
              <div className="text-muted-foreground">{row.binding_name}</div>
            </TableCell>
            <AgentCell uid={row.agent_uid} />
            <TableCell>
              <span className="block max-w-56 truncate font-mono text-xs" title={row.owner_session_id}>
                {row.owner_session_id}
              </span>
            </TableCell>
            <TableCell className="text-xs">
              <span className="font-mono">{describeSchedule(t, row.schedule)}</span>
              {row.timezone ? <div className="text-muted-foreground">{row.timezone}</div> : null}
            </TableCell>
            <TableCell className="text-xs">{formatConsoleDate(row.next_fire_at)}</TableCell>
            <TableCell className="text-xs">{formatConsoleDate(row.last_fire_at)}</TableCell>
            <TableCell>
              <StatusIndicator tone={statusTone(row.status)}>{scheduleStatusLabel(t, row.status)}</StatusIndicator>
            </TableCell>
            <RowActions
              editTo={editTo}
              editLabel={t('common.edit')}
              actions={[
                ...(toggleable
                  ? [
                      {
                        icon: <RiPlayCircleLine />,
                        label: t('console.schedules.run_now'),
                        pending: runCron.isPending,
                        onAction: () =>
                          runCron.mutate({
                            body: { data: { idempotency_key: uuidV4() } },
                            path: { agent_uid: row.agent_uid, id: row.id }
                          })
                      }
                    ]
                  : []),
                ...(toggleable
                  ? [
                      {
                        icon: row.status === 'paused' ? <RiPlayCircleLine /> : <RiPauseCircleLine />,
                        label: row.status === 'paused' ? t('console.schedules.resume') : t('console.schedules.pause'),
                        pending: pauseCron.isPending || resumeCron.isPending,
                        onAction: () => {
                          const path = { agent_uid: row.agent_uid, id: row.id }
                          if (row.status === 'paused') resumeCron.mutate({ path })
                          else pauseCron.mutate({ path })
                        }
                      }
                    ]
                  : [])
              ]}
              deletePending={removeCron.isPending}
              deleteConfirm={{
                title: t('console.schedules.delete_title'),
                description: t('console.schedules.delete_description', { name: row.name || row.binding_name }),
                confirmLabel: t('common.delete')
              }}
              onDelete={() => removeCron.mutate({ path: { agent_uid: row.agent_uid, id: row.id } })}
            />
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function ScheduleCheckbacksPage() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [includeFinished, setIncludeFinished] = useState(false)
  const scope = useAgentScope()

  const checkbacks = useQuery({
    ...checkbackListOptions(scope.agentUID),
    select: document => fromDocument(document),
    refetchInterval: LIST_REFRESH_MS
  })

  const rows = (checkbacks.data ?? [])
    .filter(row => includeFinished || pending(row))
    .filter(row =>
      matchesResourceSearch(
        query,
        row.kind,
        row.status,
        eventStatusLabel(t, row.status),
        row.agent_uid,
        row.session_id,
        row.binding_name
      )
    )

  const cancelCheckback = useMutation({
    ...cancelCheckbackMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.cancelled'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.schedules.title')}
      description={t('console.schedules.description')}
      columns={[
        t('console.schedules.due_at'),
        t('console.agents.agent'),
        t('console.session'),
        t('console.schedules.kind'),
        t('console.schedules.binding'),
        t('console.schedules.reason'),
        t('console.schedules.state')
      ]}
      count={rows.length}
      emptyIcon={<RiTimerLine aria-hidden />}
      emptyTitle={t('console.schedules.checkbacks_empty')}
      error={checkbacks.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim()) || Boolean(scope.agentUID)}
      isLoading={checkbacks.isLoading}
      onClearFilters={() => {
        setQuery('')
        scope.selectAgent('')
      }}
      subNav={<ScheduleTabs scope={scope} />}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.schedules.search')}
          placeholder={t('console.schedules.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <>
              <AgentFilter scope={scope} />
              <FilterSwitch
                checked={includeFinished}
                label={t('console.include_finished')}
                onChange={setIncludeFinished}
              />
            </>
          }
        />
      }>
      {rows.map(row => (
        <TableRow key={`${row.agent_uid}:${row.id}`}>
          <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
          <AgentCell uid={row.agent_uid} />
          <TableCell>
            <span className="block max-w-56 truncate font-mono text-xs" title={row.session_id}>
              {row.session_id}
            </span>
          </TableCell>
          <TableCell className="font-mono text-xs">{row.kind}</TableCell>
          <TableCell className="text-xs">{row.binding_name || '—'}</TableCell>
          <TableCell className="max-w-xs truncate text-xs text-muted-foreground">
            {checkbackReason(row.wake_payload)}
          </TableCell>
          <TableCell>
            <StatusIndicator tone={eventTone(row.status)}>{eventStatusLabel(t, row.status)}</StatusIndicator>
          </TableCell>
          <TableCell className="w-12 text-right">
            {pending(row) ? (
              <ConfirmDeleteButton
                confirm={{
                  title: t('console.schedules.cancel_title'),
                  description: t('console.schedules.cancel_description'),
                  confirmLabel: t('console.schedules.cancel')
                }}
                icon={<RiCloseCircleLine />}
                pending={cancelCheckback.isPending}
                onConfirm={() => cancelCheckback.mutate({ path: { agent_uid: row.agent_uid, id: Number(row.id) } })}
              />
            ) : (
              <span className="text-xs text-muted-foreground">—</span>
            )}
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function ScheduleTabs({ scope }: { scope: AgentScope }) {
  const { t } = useTranslation()
  const suffix = scope.agentUID ? `?agent=${encodeURIComponent(scope.agentUID)}` : ''
  return (
    <SubNav
      ariaLabel={t('console.schedules.title')}
      items={[
        { to: `/schedules${suffix}`, label: t('console.schedules.cron_tab'), end: true },
        { to: `/schedules/checkbacks${suffix}`, label: t('console.schedules.checkbacks_tab') }
      ]}
    />
  )
}

export function ScheduleCronEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(ScheduleEditorModel)
  const params = useParams({ strict: false }) as { agent?: string; cronID?: string }
  const [searchParams, setSearchParams] = useSearchParams()
  const locale = i18n.language

  const routeAgentUID = params.agent ?? searchParams.get('agent') ?? ''
  const cronID = params.cronID
  const editing = Boolean(cronID)

  const agents = useQuery(agentListOptions())
  const agentList = activeAgents(agents.data ?? [])
  // An existing schedule is pinned to its agent; a new one starts from the
  // resolved `?agent=` request.
  const agentUID = editing ? routeAgentUID : resolveAgentUID(agentList, routeAgentUID)
  const selectedAgent = (agents.data ?? []).find(agent => agent.uid === agentUID)

  const selectAgent = (uid: string) => {
    setSearchParams({ agent: uid }, { replace: true })
    model.resetAgentScope()
  }

  const bindings = useQuery({
    ...listSignalBindingsOptions({ query: { agent: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const bindingList = bindings.data?.signal_bindings ?? []

  // Session ids are opaque caller-chosen strings, so a new schedule needs one
  // typed in. The enumerated list is a convenience, not the full set.
  const sessions = useQuery({
    ...listAgentSessionsOptions({ path: { agent_uid: agentUID } }),
    enabled: !editing && Boolean(agentUID)
  })
  const sessionList = sessions.data?.sessions ?? []

  const conversations = useQuery({
    ...aiGatewayConversationsOptions({ subject_uid: agentUID || undefined, limit: 50 }),
    enabled: Boolean(agentUID)
  })
  const conversationOptions = (conversations.data?.conversations ?? []).map(conversation => {
    const label = conversationDisplayName(conversation)
    return {
      value: conversation.id,
      label,
      description:
        label === conversation.conversation_key
          ? conversation.id
          : `${conversation.conversation_key} · ${conversation.id}`
    }
  })

  const existing = useQuery({
    ...getCronScheduleOptions({ path: { agent_uid: agentUID, id: cronID ?? '' } }),
    select: document => fromDocument(document) as CronScheduleItem,
    enabled: editing && Boolean(agentUID && cronID)
  })
  const existingRow = existing.data

  const runs = useQuery({
    ...listCronScheduleRunsOptions({
      path: { agent_uid: agentUID, cron_schedule_id: cronID ?? '' },
      query: { page: { limit: 25 } }
    }),
    select: document => fromDocument(document),
    enabled: editing && Boolean(agentUID && cronID)
  })
  const runRows = runs.data ?? []

  // A reopened editor must not seed its draft from an invalidated cache entry.
  const sourceKey = `cron:${agentUID}:${cronID ?? 'new'}`
  const sourceReady =
    model.sourceKey.value === sourceKey || (!existing.isError && (!existing.isStale || existing.isFetchedAfterMount))
  const scheduleDraft = useMemo(
    () => (editing ? (existingRow && sourceReady ? draftFromCron(existingRow) : undefined) : emptyDraft()),
    [editing, existingRow, sourceReady]
  )
  const draftStatus = useEditorDraft(model, {
    sourceKey,
    source: scheduleDraft,
    absent: () => editing && requestErrorCode(existing.error) === 'not_found'
  })

  // Save errors render once in the page ErrorBlock; a toast on top of the
  // same message would say it twice.
  const saveCron = useMutation({
    ...createCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void navigate(linkTarget(backTo))
    }
  })
  const updateCron = useMutation({
    ...updateCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.saved'))
      void navigate(linkTarget(backTo))
    }
  })

  const runCron = useMutation({
    ...runCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.ran'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const pauseCron = useMutation({
    ...pauseCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.paused'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const resumeCron = useMutation({
    ...resumeCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.resumed'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCron = useMutation({
    ...removeCronScheduleMutation(),
    onSuccess: () => {
      toast.success(t('console.schedules.deleted'))

      void navigate(linkTarget(backTo))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const validateFields = (): boolean => {
    const errors: ScheduleFieldErrors = {}
    if (!editing && !model.ownerSessionId.value.trim()) {
      errors.ownerSessionId = t('console.schedules.session_required')
    }
    if (!model.name.value.trim()) {
      errors.name = t('common.field_required', { field: t('console.schedules.name') })
    }
    if (!model.hasAutomationJob.value && !model.task.value.trim()) {
      errors.task = t('common.field_required', { field: t('console.schedules.task') })
    }
    const kind = model.scheduleKind.value || 'cron'
    if (kind === 'cron') {
      if (!model.cronExpression.value.trim()) {
        errors.cronExpression = t('common.field_required', { field: t('console.schedules.expression') })
      }
    } else {
      const ms = Number(model.everyMs.value)
      if (!Number.isFinite(ms) || ms <= 0) {
        errors.interval = t('common.field_invalid', {
          field: t('console.schedules.interval', { defaultValue: 'Interval' })
        })
      }
      if (!model.anchorAt.value.trim()) {
        errors.anchorAt = t(model.anchorInput.value.trim() ? 'common.field_invalid' : 'common.field_required', {
          field: t('console.schedules.anchor_at')
        })
      }
    }
    const targetErrors: Record<number, string> = {}
    model.deliveryTargets.value.forEach((target, index) => {
      if (!target.conversationId.trim()) {
        targetErrors[index] = t('common.field_required', { field: t('console.schedules.delivery_conversation') })
      }
    })
    if (Object.keys(targetErrors).length > 0) {
      errors.deliveryConversationIds = targetErrors
    }
    model.fieldErrors.value = errors
    return Object.keys(errors).length === 0
  }

  const submit = () => {
    model.clearValidation()
    if (!agentUID) {
      model.validationError.value = t('console.schedules.scope_required')
      return
    }
    if (!validateFields()) return
    if (editing) {
      if (!cronID || !existingRow || !isMutableCronStatus(existingRow.status)) return
      const body = model.toUpdateBody()
      if (!body) {
        model.validationError.value = t('console.schedules.schedule_invalid')
        return
      }
      if (Object.keys(body).length === 0) {
        void navigate(linkTarget(backTo))
        return
      }
      updateCron.mutate({ body: { data: body }, path: { agent_uid: agentUID, id: cronID } })
      return
    }
    const body = model.toCreateBody(uuidV4())
    if (!body) {
      model.validationError.value = t('console.schedules.schedule_invalid')
      return
    }
    saveCron.mutate({ body: { data: body }, path: { agent_uid: agentUID } })
  }

  const backTo = agentUID ? `/schedules?agent=${encodeURIComponent(agentUID)}` : '/schedules'

  if (draftStatus === 'absent') {
    return <EditorNotFound backTo={backTo} message={t('console.not_found.description')} />
  }

  const updateBody = editing ? model.toUpdateBody() : undefined
  const unchanged = Boolean(editing && updateBody && Object.keys(updateBody).length === 0)
  const existingRunnable = Boolean(existingRow && isMutableCronStatus(existingRow.status))
  const terminalReadOnly = Boolean(editing && existingRow && !existingRunnable)

  return (
    <ResourceEditorPage
      title={editing ? t('console.schedules.edit') : t('console.schedules.new')}
      backTo={backTo}
      dirty={model.dirty.value && !removeCron.isPending}
      description={
        terminalReadOnly && existingRow
          ? t('console.schedules.terminal_read_only', { status: scheduleStatusLabel(t, existingRow.status) })
          : undefined
      }
      validationError={model.validationError.value}
      error={agents.error ?? bindings.error ?? existing.error ?? saveCron.error ?? updateCron.error}
      {...(terminalReadOnly
        ? { readOnly: true as const }
        : {
            onSubmit: submit,
            submitting: saveCron.isPending || updateCron.isPending,
            submitDisabled: unchanged,
            submitDisabledReason: t('common.save_disabled'),
            submitUnavailable: draftStatus !== 'ready'
          })}
      secondary={
        editing && existingRow ? (
          <div className="flex flex-wrap items-center gap-2">
            {existingRunnable ? (
              <Button
                size="sm"
                type="button"
                variant="outline"
                disabled={runCron.isPending}
                onClick={() =>
                  runCron.mutate({
                    body: { data: { idempotency_key: uuidV4() } },
                    path: { agent_uid: agentUID, id: existingRow.id }
                  })
                }>
                <RiPlayCircleLine data-icon="inline-start" />
                {t('console.schedules.run_now')}
              </Button>
            ) : null}
            {existingRunnable ? (
              <Button
                size="sm"
                type="button"
                variant="outline"
                disabled={pauseCron.isPending || resumeCron.isPending}
                onClick={() => {
                  const path = { agent_uid: agentUID, id: existingRow.id }
                  if (existingRow.status === 'paused') resumeCron.mutate({ path })
                  else pauseCron.mutate({ path })
                }}>
                {existingRow.status === 'paused' ? (
                  <RiPlayCircleLine data-icon="inline-start" />
                ) : (
                  <RiPauseCircleLine data-icon="inline-start" />
                )}
                {existingRow.status === 'paused' ? t('console.schedules.resume') : t('console.schedules.pause')}
              </Button>
            ) : null}
            <ConfirmDeleteButton
              confirm={{
                title: t('console.schedules.delete_title'),
                description: t('console.schedules.delete_description', {
                  name: existingRow.name || existingRow.binding_name
                }),
                confirmLabel: t('common.delete')
              }}
              label={t('common.delete')}
              pending={removeCron.isPending}
              size="sm"
              onConfirm={() => removeCron.mutate({ path: { agent_uid: agentUID, id: existingRow.id } })}
            />
          </div>
        ) : undefined
      }
      supplementary={
        editing ? (
          <div className="flex flex-col gap-3">
            <LabeledField label={t('console.schedules.next_fire')}>
              <ReadOnlyValue>{formatConsoleDate(existingRow?.next_fire_at)}</ReadOnlyValue>
            </LabeledField>
            <h3 className="text-sm font-medium">{t('console.schedules.run_history')}</h3>
            <ErrorBlock error={runs.error} />
            {runs.error ? null : runRows.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('console.schedules.no_runs')}</p>
            ) : (
              <div className="border border-border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('console.schedules.due_at')}</TableHead>
                      <TableHead>{t('console.schedules.state')}</TableHead>
                      <TableHead>{t('console.schedules.fired_at')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {runRows.map(row => (
                      <TableRow key={row.id}>
                        <TableCell className="text-xs">{formatConsoleDate(row.due_at)}</TableCell>
                        <TableCell>
                          <StatusIndicator tone={eventTone(row.status)}>
                            {eventStatusLabel(t, row.status)}
                          </StatusIndicator>
                        </TableCell>
                        <TableCell className="text-xs">{formatConsoleDate(row.fired_at)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </div>
        ) : null
      }>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <LabeledField
          label={t('console.agents.agent')}
          required={!editing}
          description={!editing ? t('console.schedules.agent_execution_hint') : undefined}>
          {editing ? (
            <ReadOnlyValue>
              {selectedAgent
                ? selectedAgent.display_name
                  ? `${selectedAgent.display_name} · ${selectedAgent.uid}`
                  : selectedAgent.uid
                : agentUID || '—'}
            </ReadOnlyValue>
          ) : (
            <Select value={agentUID || null} onValueChange={value => selectAgent(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.select_agent')} />
              </SelectTrigger>
              <SelectContent emptyLabel={agents.isLoading ? t('common.loading') : t('common.select_no_agents')}>
                {agentList.map(agent => (
                  <SelectItem key={agent.uid} value={agent.uid}>
                    {agent.display_name} · {agent.uid}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
        {editing ? (
          <LabeledField label={t('console.schedules.owner_session')}>
            <ReadOnlyValue mono>{model.ownerSessionId.value || '—'}</ReadOnlyValue>
          </LabeledField>
        ) : (
          <LabeledField
            label={t('console.schedules.owner_session')}
            required
            description={t('console.schedules.session_hint')}
            error={model.fieldErrors.value.ownerSessionId}>
            <CreatableCombobox
              ariaLabel={t('console.schedules.owner_session')}
              clearLabel={t('common.clear')}
              value={model.ownerSessionId.value}
              options={sessionList.map(session => ({
                value: session.session_id,
                label: session.title ? `${session.title} — ${session.session_id}` : session.session_id
              }))}
              placeholder={t('console.schedules.session_placeholder')}
              emptyLabel={sessions.isLoading ? t('common.loading') : t('console.schedules.session_empty')}
              createLabel={value => t('console.schedules.session_use', { session: value })}
              triggerLabel={t('common.open')}
              onValueChange={value => {
                model.ownerSessionId.value = value
                if (model.fieldErrors.value.ownerSessionId) {
                  model.fieldErrors.value = { ...model.fieldErrors.value, ownerSessionId: undefined }
                }
              }}
            />
          </LabeledField>
        )}
      </div>

      {editing && existingRow ? (
        <LabeledField
          label={t('console.schedules.execution_session')}
          description={t('console.schedules.execution_session_hint')}>
          <ReadOnlyValue mono>{existingRow.execution_session_id}</ReadOnlyValue>
        </LabeledField>
      ) : null}

      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <LabeledField label={t('console.schedules.binding')}>
          {editing ? (
            <ReadOnlyValue mono>{model.bindingName.value || '—'}</ReadOnlyValue>
          ) : (
            <Select value={model.bindingName.value} onValueChange={value => model.setBindingName(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.schedules.binding_placeholder')} />
              </SelectTrigger>
              <SelectContent emptyLabel={t('console.schedules.binding_empty')}>
                <SelectItem value="">{t('console.schedules.native_delivery')}</SelectItem>
                {bindingList.map(binding => (
                  <SelectItem key={`${binding.adapter}:${binding.name}`} value={binding.name}>
                    {binding.name}
                    <span className="text-muted-foreground"> ({binding.adapter})</span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
          {!editing && agentUID && !bindings.isLoading && bindingList.length === 0 ? (
            <p className="text-xs leading-5 text-muted-foreground">
              {t('console.schedules.binding_empty_hint')}{' '}
              <Link className="link" {...linkTarget(`/signals/new?agent=${encodeURIComponent(agentUID)}`)}>
                {t('console.schedules.binding_empty_action')}
              </Link>
            </p>
          ) : null}
        </LabeledField>
        <LabeledField
          label={t('console.schedules.name')}
          required
          description={t('console.schedules.name_hint')}
          error={model.fieldErrors.value.name}
          invalidError={t('common.field_required', { field: t('console.schedules.name') })}>
          <Input
            pattern=".*\S.*"
            value={model.name.value}
            onChange={event => {
              model.name.value = event.target.value
              if (model.fieldErrors.value.name) {
                model.fieldErrors.value = { ...model.fieldErrors.value, name: undefined }
              }
            }}
          />
        </LabeledField>
      </div>

      <LabeledField
        label={t('console.schedules.task')}
        required={!model.hasAutomationJob.value}
        description={t('console.schedules.task_hint')}
        error={model.fieldErrors.value.task}>
        <Textarea
          rows={4}
          value={model.task.value}
          onChange={event => {
            model.task.value = event.target.value
            if (model.fieldErrors.value.task) {
              model.fieldErrors.value = { ...model.fieldErrors.value, task: undefined }
            }
          }}
        />
      </LabeledField>

      <LabeledField label={t('console.schedules.schedule_kind')}>
        <Select
          value={model.scheduleKind.value || 'cron'}
          onValueChange={value => (model.scheduleKind.value = value === 'every' ? 'every' : 'cron')}>
          <SelectTrigger className="w-full md:max-w-sm">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="cron">{t('console.schedules.kind_cron')}</SelectItem>
            <SelectItem value="every">{t('console.schedules.kind_every')}</SelectItem>
          </SelectContent>
        </Select>
      </LabeledField>

      {model.scheduleKind.value === 'every' ? (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <LabeledField
            label={t('console.schedules.interval', { defaultValue: 'Interval' })}
            required
            error={model.fieldErrors.value.interval}>
            <div className="flex items-center gap-2">
              <Input
                aria-label={t('console.schedules.interval', { defaultValue: 'Interval' })}
                className="min-w-0 flex-1"
                min="1"
                required
                type="number"
                value={model.intervalValue.value}
                onChange={event => {
                  model.setIntervalValue(event.target.value)
                  if (model.fieldErrors.value.interval) {
                    model.fieldErrors.value = { ...model.fieldErrors.value, interval: undefined }
                  }
                }}
              />
              <Select
                value={model.intervalUnit.value}
                onValueChange={value => model.setIntervalUnit(value as ScheduleIntervalUnit)}>
                <SelectTrigger
                  aria-label={t('console.schedules.interval_unit', { defaultValue: 'Interval unit' })}
                  className="w-36 shrink-0">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="seconds">
                    {t('console.schedules.unit_seconds', { defaultValue: 'Seconds' })}
                  </SelectItem>
                  <SelectItem value="minutes">
                    {t('console.schedules.unit_minutes', { defaultValue: 'Minutes' })}
                  </SelectItem>
                  <SelectItem value="hours">{t('console.schedules.unit_hours', { defaultValue: 'Hours' })}</SelectItem>
                  <SelectItem value="days">{t('console.schedules.unit_days', { defaultValue: 'Days' })}</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </LabeledField>
          <LabeledField
            label={t('console.schedules.anchor_at')}
            required
            description={anchorHintText(t, locale)}
            error={model.fieldErrors.value.anchorAt}>
            <Input
              step={1}
              type="datetime-local"
              value={model.anchorInput.value}
              onChange={event => {
                model.setAnchorLocal(event.target.value)
                if (model.fieldErrors.value.anchorAt) {
                  model.fieldErrors.value = { ...model.fieldErrors.value, anchorAt: undefined }
                }
              }}
            />
          </LabeledField>
        </div>
      ) : (
        <div className="grid gap-3">
          <LabeledField
            label={t('console.schedules.expression')}
            required
            description={t('console.schedules.expression_hint')}
            error={model.fieldErrors.value.cronExpression}>
            <CronEditor
              labels={cronEditorLabels(t)}
              value={model.cronExpression.value}
              onChange={expression => {
                model.cronExpression.value = expression
                if (model.fieldErrors.value.cronExpression) {
                  model.fieldErrors.value = { ...model.fieldErrors.value, cronExpression: undefined }
                }
              }}
            />
          </LabeledField>
          <LabeledField
            label={t('console.schedules.timezone')}
            description={timezoneHintText(t, locale, model.timezone.value)}>
            <CreatableCombobox
              ariaLabel={t('console.schedules.timezone')}
              clearLabel={t('common.clear')}
              createLabel={value =>
                t('console.schedules.timezone_use', { defaultValue: 'Use {$timezone}', timezone: value })
              }
              emptyLabel={t('common.select_empty')}
              options={timeZoneOptions(locale, model.timezone.value.trim())}
              placeholder="Asia/Shanghai"
              triggerLabel={t('common.open')}
              value={model.timezone.value}
              onValueChange={value => (model.timezone.value = value)}
            />
          </LabeledField>
        </div>
      )}

      <div className="flex flex-col gap-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-sm font-medium">{t('console.schedules.delivery_targets')}</h3>
            <p className="text-xs text-muted-foreground">{t('console.schedules.delivery_targets_hint')}</p>
          </div>
          <Button type="button" size="sm" variant="outline" onClick={() => model.addDeliveryTarget()}>
            {t('console.schedules.add_delivery_target')}
          </Button>
        </div>

        {model.deliveryTargets.value.map((target, index) => (
          <div key={index} className="flex flex-col gap-3 border border-border p-3">
            <div className="flex items-center justify-between gap-3">
              <span className="text-xs font-medium text-muted-foreground">
                {t('console.schedules.delivery_target', { number: index + 1 })}
              </span>
              {index > 0 ? (
                <Button type="button" size="xs" variant="ghost" onClick={() => model.removeDeliveryTarget(index)}>
                  {t('common.delete')}
                </Button>
              ) : null}
            </div>

            <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
              <LabeledField label={t('console.schedules.binding')}>
                {index === 0 ? (
                  <ReadOnlyValue mono>{model.bindingName.value || '—'}</ReadOnlyValue>
                ) : (
                  <Select
                    value={target.bindingName}
                    onValueChange={value => model.updateDeliveryTarget(index, { bindingName: String(value) })}>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder={t('console.schedules.binding_placeholder')} />
                    </SelectTrigger>
                    <SelectContent emptyLabel={t('common.select_empty')}>
                      <SelectItem value="">{t('console.schedules.native_delivery')}</SelectItem>
                      {bindingList.map(binding => (
                        <SelectItem key={`${binding.adapter}:${binding.name}`} value={binding.name}>
                          {binding.name}
                          <span className="text-muted-foreground"> ({binding.adapter})</span>
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              </LabeledField>
              <LabeledField
                label={t('console.schedules.delivery_conversation')}
                required
                error={model.fieldErrors.value.deliveryConversationIds?.[index]}>
                <CreatableCombobox
                  ariaLabel={t('console.schedules.delivery_conversation')}
                  clearLabel={t('common.clear')}
                  createLabel={value =>
                    t('console.schedules.delivery_conversation_use', {
                      defaultValue: 'Use {$conversation}',
                      conversation: value
                    })
                  }
                  emptyLabel={conversations.isLoading ? t('common.loading') : t('console.schedules.session_empty')}
                  options={conversationOptions}
                  placeholder={t('console.schedules.delivery_conversation_placeholder', {
                    defaultValue: 'Select a conversation or enter an ID'
                  })}
                  required
                  triggerLabel={t('common.open')}
                  value={target.conversationId}
                  onValueChange={value => {
                    model.updateDeliveryTarget(index, { conversationId: value })
                    if (model.fieldErrors.value.deliveryConversationIds?.[index]) {
                      const nextTargets = { ...model.fieldErrors.value.deliveryConversationIds }
                      delete nextTargets[index]
                      model.fieldErrors.value = {
                        ...model.fieldErrors.value,
                        deliveryConversationIds: Object.keys(nextTargets).length > 0 ? nextTargets : undefined
                      }
                    }
                  }}
                />
              </LabeledField>
              <LabeledField label={t('console.schedules.delivery_thread')}>
                <Input
                  value={target.threadId}
                  onChange={event => model.updateDeliveryTarget(index, { threadId: event.target.value })}
                />
              </LabeledField>
            </div>
          </div>
        ))}
      </div>

      {!editing ? (
        <LabeledField label={t('console.schedules.status_field')}>
          <Select
            value={model.status.value || 'active'}
            onValueChange={value => (model.status.value = value === 'paused' ? 'paused' : 'active')}>
            <SelectTrigger className="w-full md:max-w-sm">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="active">{t('console.schedules.status_active')}</SelectItem>
              <SelectItem value="paused">{t('console.schedules.status_paused')}</SelectItem>
            </SelectContent>
          </Select>
        </LabeledField>
      ) : null}
    </ResourceEditorPage>
  )
}

/** Localized status labels; an unknown token renders as itself instead of a raw i18n key. */
function scheduleStatusLabel(t: TFunction, status: string): string {
  return t(`console.schedules.status_${status}`, { defaultValue: status })
}

function eventStatusLabel(t: TFunction, status: string): string {
  return t(`console.schedules.event_status_${status}`, { defaultValue: status })
}

function anchorHintText(t: TFunction, locale: string): string {
  const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const offset = localZone ? timeZoneOffsetLabel(localZone, locale) : undefined
  const zoneLabel = localZone && offset ? `${localZone} (${offset})` : localZone
  return zoneLabel ? `${t('console.schedules.anchor_hint')} (${zoneLabel})` : t('console.schedules.anchor_hint')
}

function timezoneHintText(t: TFunction, locale: string, timezone: string): string {
  const trimmed = timezone.trim()
  const preview = trimmed ? timeZoneCurrentTime(trimmed, locale) : undefined
  return preview ? `${t('console.schedules.timezone_hint')} — ${preview}` : t('console.schedules.timezone_hint')
}

const INTERVAL_UNIT_SUFFIX: Record<ScheduleIntervalUnit, string> = {
  days: 'd',
  hours: 'h',
  minutes: 'm',
  seconds: 's'
}

function describeSchedule(t: TFunction, schedule: ScheduleRecurrence): string {
  if (schedule.kind === 'cron') return schedule.expression ?? '—'
  const everyMs = schedule.every_ms ?? 0
  let interval: string
  if (everyMs <= 0) {
    interval = '?'
  } else if (everyMs % 1_000 !== 0) {
    interval = `${everyMs}ms`
  } else {
    const { value, unit } = decomposeEveryMs(String(everyMs))
    interval = `${value}${INTERVAL_UNIT_SUFFIX[unit]}`
  }
  return t('console.schedules.every_interval', { interval })
}

function checkbackReason(payload: ScheduledEventItem['wake_payload']): string {
  const reason = payload.reason
  return typeof reason === 'string' ? reason : '—'
}

function statusTone(status: string): 'positive' | 'warning' | 'neutral' | 'danger' {
  switch (status) {
    case 'active':
      return 'positive'
    case 'paused':
      return 'warning'
    case 'deleted':
    case 'completed':
      return 'neutral'
    case 'failed':
      return 'danger'
    default:
      return 'neutral'
  }
}

function eventTone(status: string): StatusTone {
  switch (status) {
    case 'fired':
      return 'positive'
    case 'scheduled':
      return 'info'
    case 'cancelled':
      return 'neutral'
    case 'failed':
      return 'danger'
    default:
      return 'neutral'
  }
}

function draftFromCron(row: CronScheduleItem): ScheduleEditorDraft {
  const { schedule, payload } = row
  return {
    ownerSessionId: row.owner_session_id,
    bindingName: row.binding_name ?? '',
    name: row.name,
    status: isMutableCronStatus(row.status) ? row.status : '',
    scheduleKind: schedule.kind,
    cronExpression: schedule.expression ?? '',
    everyMs: String(schedule.every_ms ?? ''),
    anchorAt: schedule.anchor_at ?? '',
    timezone: row.timezone,
    occurrences: scheduleOccurrenceBound(schedule),
    deliveryTargets: deliveryTargetDrafts(row.delivery),
    task: typeof payload.task === 'string' ? payload.task : '',
    payload: { ...payload },
    hasAutomationJob: row.automation_job_id != null
  }
}

function emptyDraft(): ScheduleEditorDraft {
  return {
    ownerSessionId: '',
    bindingName: '',
    name: '',
    status: 'active',
    scheduleKind: 'cron',
    cronExpression: '0 9 * * *',
    everyMs: '',
    anchorAt: '',
    timezone: '',
    deliveryTargets: [{ bindingName: '', conversationId: '', threadId: '' }],
    task: '',
    payload: {},
    hasAutomationJob: false
  }
}

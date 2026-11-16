import { Button, Input, Label, Skeleton, SwitchRow, Textarea, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../common/request-errors'
import { podEventBindingPut, updatePodJobRoutine } from './api/generated/sdk.gen'
import {
  buildCoalescePayload,
  coalesceMatchesBinding,
  ConnectorEventSourceFields,
  describeBindingFilter,
  eventTypeFilterExpression,
  isValidCoalesceInput,
  parseCoalesceSettings,
  useConnectorEventSources
} from './connector-event-picker'
import { ContentError } from './content-primitives'
import { jobRoutineBindingsQuery, jobsError, jobsKeys, type JobBoardItem, type JobRoutineDetail } from './jobs-api'

export function routineHasSchedule(item: Pick<JobBoardItem, 'schedule'>): boolean {
  return Boolean(item.schedule && typeof item.schedule.expression === 'string' && item.schedule.expression.trim())
}

function extractCronExpression(schedule: Record<string, unknown> | null | undefined): string {
  return typeof schedule?.expression === 'string' && schedule.expression.trim()
    ? schedule.expression.trim()
    : '0 9 * * 1-5'
}

function extractCronTimezone(item: JobBoardItem): string {
  if (typeof item.timezone === 'string' && item.timezone.trim()) return item.timezone.trim()
  const schedTz = item.schedule && typeof item.schedule.timezone === 'string' ? item.schedule.timezone.trim() : ''
  return schedTz || 'UTC'
}

export function buildRoutineUpdatePayload({
  title,
  task,
  quietSuccess,
  initialHasSchedule,
  hasSchedule,
  expression,
  timezone
}: {
  title: string
  task: string
  quietSuccess: boolean
  initialHasSchedule: boolean
  hasSchedule: boolean
  expression: string
  timezone: string
}): NonNullable<Parameters<typeof updatePodJobRoutine>[0]['body']>['data'] {
  return {
    title: title.trim(),
    task: task.trim(),
    quietSuccess,
    ...(hasSchedule
      ? { repeat: { expression: expression.trim(), timezone: timezone.trim() || 'UTC' } }
      : initialHasSchedule
        ? { removeSchedule: true }
        : {})
  }
}

export function RoutineInlineEditForm({
  rawID,
  item,
  detail,
  onCancel,
  onSaved
}: {
  rawID: string
  item: JobBoardItem
  detail: JobRoutineDetail
  onCancel: () => void
  onSaved: () => void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const formHeadingId = useId()
  const titleInputId = useId()
  const taskInputId = useId()
  const expressionInputId = useId()
  const timezoneInputId = useId()

  const bindings = useQuery(jobRoutineBindingsQuery(rawID))
  const hasEnabledEventBinding = (bindings.data?.bindings ?? []).some(binding => binding.enabled)
  const initialHasSchedule = routineHasSchedule(item)

  const [title, setTitle] = useState(item.title)
  const [task, setTask] = useState(detail.instructions)
  const [hasSchedule, setHasSchedule] = useState(initialHasSchedule)
  const [expression, setExpression] = useState(() => extractCronExpression(item.schedule))
  const [timezone, setTimezone] = useState(() => extractCronTimezone(item))
  const [quietSuccess, setQuietSuccess] = useState(detail.quietSuccess ?? true)

  const saveMutation = useMutation({
    mutationFn: () =>
      updatePodJobRoutine({
        path: { raw_id: rawID },
        body: {
          data: buildRoutineUpdatePayload({
            title,
            task,
            quietSuccess,
            initialHasSchedule,
            hasSchedule,
            expression,
            timezone
          })
        }
      }),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: jobsKeys.all })
      onSaved()
    }
  })

  const validCron = !hasSchedule || expression.trim().split(/\s+/).length === 5
  const validScheduleState = hasSchedule ? validCron : !initialHasSchedule || hasEnabledEventBinding
  const canToggleSchedule = !initialHasSchedule || hasEnabledEventBinding
  const canSave = !saveMutation.isPending && Boolean(title.trim()) && Boolean(task.trim()) && validScheduleState

  return (
    <form
      aria-labelledby={formHeadingId}
      className="grid gap-3 rounded-surface border border-border bg-background-secondary/50 p-3 text-xs"
      onSubmit={event => {
        event.preventDefault()
        if (canSave) saveMutation.mutate()
      }}>
      <h3 id={formHeadingId} className="text-xs font-medium text-foreground">
        {t('pod.jobs.action_edit')}
      </h3>

      {saveMutation.error ? <ContentError error={jobsError(saveMutation.error)} /> : null}

      <div className="grid gap-1.5">
        <Label htmlFor={titleInputId}>{t('pod.jobs.field_title')}</Label>
        <Input
          id={titleInputId}
          name="title"
          required
          maxLength={200}
          value={title}
          onChange={event => setTitle(event.target.value)}
        />
      </div>

      <div className="grid gap-1.5">
        <Label htmlFor={taskInputId}>{t('pod.jobs.field_task')}</Label>
        <Textarea
          id={taskInputId}
          name="task"
          required
          rows={4}
          maxLength={20_000}
          value={task}
          onChange={event => setTask(event.target.value)}
        />
      </div>

      {canToggleSchedule && (
        <SwitchRow
          labelFirst
          rowClassName="flex items-center justify-between gap-3 text-xs"
          label={t('pod.jobs.field_schedule')}
          checked={hasSchedule}
          onCheckedChange={setHasSchedule}
        />
      )}

      {hasSchedule && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="grid gap-1.5">
            <Label htmlFor={expressionInputId}>{t('pod.jobs.field_cron_expression')}</Label>
            <Input
              id={expressionInputId}
              name="expression"
              required
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              aria-invalid={!validCron || undefined}
              value={expression}
              onChange={event => setExpression(event.target.value)}
            />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor={timezoneInputId}>{t('pod.jobs.field_timezone')}</Label>
            <Input
              id={timezoneInputId}
              name="timezone"
              required
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              value={timezone}
              onChange={event => setTimezone(event.target.value)}
            />
          </div>
        </div>
      )}

      <SwitchRow
        labelFirst
        rowClassName="flex items-center justify-between gap-3 text-xs"
        label={t('pod.jobs.field_quiet_success')}
        checked={quietSuccess}
        onCheckedChange={setQuietSuccess}
      />

      <div className="flex items-center justify-end gap-2 pt-1">
        <Button type="button" size="xs" variant="ghost" disabled={saveMutation.isPending} onClick={onCancel}>
          {t('common.cancel')}
        </Button>
        <Button type="submit" size="xs" disabled={!canSave}>
          {t('common.save')}
        </Button>
      </div>
    </form>
  )
}

export function RoutineEventTriggersSection({
  rawID,
  manageable,
  hasSchedule = false
}: {
  rawID: string
  manageable: boolean
  hasSchedule?: boolean
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const bindings = useQuery(jobRoutineBindingsQuery(rawID))
  const enabledBindings = (bindings.data?.bindings ?? []).filter(binding => binding.enabled)
  const sources = useConnectorEventSources({
    enabled: manageable || enabledBindings.length > 0
  })

  const [selectedRef, setSelectedRef] = useState('')
  const [eventType, setEventType] = useState('')
  const [coalesceEdits, setCoalesceEdits] = useState<{
    key: string
    windowSec: string
    maxBatch: string
  } | null>(null)

  const activeSource = selectedRef ? sources.choices.find(item => item.reference === selectedRef) : sources.choices[0]
  const resolvedEventType = activeSource?.eventTypes.includes(eventType) ? eventType : ''
  const filterExpr = eventTypeFilterExpression(resolvedEventType)
  const filters: Record<string, unknown> = filterExpr ? { cel: filterExpr } : {}

  const matchingBinding = (bindings.data?.bindings ?? []).find(
    binding =>
      binding.config_ref === activeSource?.reference &&
      Object.keys(binding.filters).length === (filterExpr ? 1 : 0) &&
      binding.filters.cel === filterExpr
  )
  const alreadyConnected = matchingBinding?.enabled === true

  const selectionKey = `${activeSource?.reference ?? ''}::${filterExpr ?? ''}`
  const defaultCoalesce = matchingBinding
    ? parseCoalesceSettings(matchingBinding.coalesce)
    : { windowSec: 5, maxBatch: 20 }
  const coalesceWindowSec =
    coalesceEdits?.key === selectionKey ? coalesceEdits.windowSec : String(defaultCoalesce.windowSec)
  const coalesceMaxBatch =
    coalesceEdits?.key === selectionKey ? coalesceEdits.maxBatch : String(defaultCoalesce.maxBatch)
  const validCoalesce = isValidCoalesceInput(coalesceWindowSec, coalesceMaxBatch)
  const coalescePayload = validCoalesce ? buildCoalescePayload(coalesceWindowSec, coalesceMaxBatch) : undefined
  const coalesceUnchanged = Boolean(
    alreadyConnected && coalescePayload && coalesceMatchesBinding(matchingBinding.coalesce, coalescePayload)
  )
  const cannotDisconnectLast = !hasSchedule && enabledBindings.length <= 1

  const bindingMutation = useMutation({
    mutationFn: (payload: NonNullable<Parameters<typeof podEventBindingPut>[0]['body']>['data']) =>
      podEventBindingPut({ body: { data: payload } }),
    onSuccess: () => {
      setCoalesceEdits(null)
      void client.invalidateQueries({ queryKey: jobsKeys.all })
    },
    onError: error => {
      toast.error(requestErrorMessage(jobsError(error)))
    }
  })

  if (!manageable && (bindings.isPending || enabledBindings.length === 0)) {
    return null
  }

  return (
    <section className="grid gap-2">
      <h3 className="text-xs font-medium text-fg-tertiary">{t('pod.jobs.event_triggers')}</h3>

      {bindings.error ? <ContentError error={jobsError(bindings.error)} /> : null}

      {bindings.isPending ? (
        <Skeleton className="h-12 w-full" />
      ) : (
        <>
          {enabledBindings.length > 0 &&
            (sources.isPending ? (
              <Skeleton className="h-12 w-full" />
            ) : (
              <div className="grid gap-1.5">
                {enabledBindings.map(binding => {
                  const origin = sources.origins.find(candidate => candidate.reference === binding.config_ref)
                  const coalesce = parseCoalesceSettings(binding.coalesce)
                  return (
                    <div
                      key={binding.id}
                      className="flex flex-wrap items-center justify-between gap-2 rounded-surface border border-border/80 bg-card px-3 py-2.5 text-xs">
                      <div className="min-w-0 flex-1 grid gap-0.5">
                        <p className="truncate font-medium text-foreground">{origin?.label ?? binding.name}</p>
                        <p className="text-fg-tertiary">
                          {describeBindingFilter(
                            binding.filters,
                            origin?.eventTypes ?? [],
                            t('pod.automation.any_event')
                          )}
                          {' · '}
                          {coalesce.windowSec}s / {coalesce.maxBatch}
                        </p>
                      </div>
                      {manageable && (
                        <Button
                          type="button"
                          size="xs"
                          variant="outline"
                          disabled={bindingMutation.isPending || cannotDisconnectLast}
                          onClick={() =>
                            bindingMutation.mutate({
                              id: binding.id,
                              name: binding.name,
                              config_ref: binding.config_ref,
                              agent_routine_id: rawID,
                              enabled: false,
                              filters: binding.filters,
                              coalesce: binding.coalesce ?? undefined,
                              watched_field_ids: binding.watched_field_ids
                            })
                          }>
                          {t('pod.automation.disconnect_event')}
                        </Button>
                      )}
                    </div>
                  )
                })}
              </div>
            ))}

          {manageable && (
            <div className="grid gap-2.5 rounded-surface border border-border/80 bg-background-secondary/45 p-3 text-xs">
              <ConnectorEventSourceFields
                sources={sources}
                selectedRef={selectedRef}
                onSelectRef={setSelectedRef}
                eventType={eventType}
                onSelectEventType={setEventType}
                coalesceWindowSec={coalesceWindowSec}
                onCoalesceWindowSecChange={windowSec =>
                  setCoalesceEdits({ key: selectionKey, windowSec, maxBatch: coalesceMaxBatch })
                }
                coalesceMaxBatch={coalesceMaxBatch}
                onCoalesceMaxBatchChange={maxBatch =>
                  setCoalesceEdits({ key: selectionKey, windowSec: coalesceWindowSec, maxBatch })
                }
                disabled={bindingMutation.isPending}
              />
              {activeSource && !sources.isPending && (
                <Button
                  type="button"
                  size="xs"
                  variant="outline"
                  className="justify-self-start"
                  disabled={bindingMutation.isPending || !validCoalesce || (alreadyConnected && coalesceUnchanged)}
                  onClick={() => {
                    if (!coalescePayload) return
                    bindingMutation.mutate({
                      id: matchingBinding?.id,
                      name: matchingBinding?.name,
                      config_ref: activeSource.reference,
                      agent_routine_id: rawID,
                      enabled: true,
                      filters,
                      coalesce: coalescePayload,
                      watched_field_ids: matchingBinding?.watched_field_ids
                    })
                  }}>
                  {t(
                    !alreadyConnected
                      ? 'pod.automation.connect_event'
                      : coalesceUnchanged
                        ? 'pod.automation.event_already_connected'
                        : 'common.save'
                  )}
                </Button>
              )}
            </div>
          )}
        </>
      )}
    </section>
  )
}

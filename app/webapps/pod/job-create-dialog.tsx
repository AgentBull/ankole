import {
  Button,
  CronEditor,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  SwitchRow,
  Tabs,
  TabsList,
  TabsTrigger,
  Textarea,
  ToggleGroup,
  ToggleGroupItem
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useId, useMemo, useRef, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { cronEditorLabels } from '../common/cron-editor-labels'
import { podKeys } from './api'
import { createPodJob, podConversations } from './api/generated/sdk.gen'
import { conversationLabel } from './chat/conversation-row'
import { ConnectorEventSourceFields, useConnectorEventSources } from './connector-event-picker'
import { ContentError } from './content-primitives'
import { jobsError, jobsKeys, type JobBoardItem, type JobCandidateAgent } from './jobs-api'
import {
  DEFAULT_DELIVERY,
  JobCreateFormModel,
  resolveJobCandidateAgent,
  type JobStarterPreset,
  type RoutineTriggerMode
} from './state/job-create-form'

export type { JobStarterPreset }

const TRIGGER_MODES: ReadonlyArray<{ value: RoutineTriggerMode; labelKey: string }> = [
  { value: 'schedule', labelKey: 'pod.jobs.trigger_mode_schedule' },
  { value: 'event', labelKey: 'pod.jobs.trigger_mode_event' },
  { value: 'hybrid', labelKey: 'pod.jobs.trigger_mode_hybrid' }
]

export function JobCreateFormContent({
  agents,
  preset,
  onClose,
  onCreated,
  onPendingChange
}: {
  agents: JobCandidateAgent[]
  preset?: JobStarterPreset | null
  onClose: () => void
  onCreated: (item: JobBoardItem) => void
  onPendingChange?: (pending: boolean) => void
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const triggerModeLabelId = useId()
  const form = useModel(() => new JobCreateFormModel(preset, agents))

  const anyBackgroundCapable = agents.some(agent => agent.canRunBackgroundJob)
  const selectedAgent = resolveJobCandidateAgent(agents, form.agentUID.value)
  const resolvedAgentUID = selectedAgent?.uid ?? ''
  const effectiveMode: 'one_off' | 'cron' =
    (agents.length > 0 && !anyBackgroundCapable) || (selectedAgent && !selectedAgent.canRunBackgroundJob)
      ? 'cron'
      : form.mode.value

  const hasScheduleTrigger = form.hasScheduleTrigger.value
  const hasEventTrigger = form.hasEventTrigger.value

  const connectorSources = useConnectorEventSources({
    enabled: effectiveMode === 'cron' && hasEventTrigger
  })
  const eventSelection = form.resolveEventSelection(connectorSources.choices)

  const recentConversations = useQuery({
    queryKey: [...podKeys.conversations, 'jobs-delivery'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 30 }, signal }),
    enabled: Boolean(resolvedAgentUID)
  })

  const matchingRooms = useMemo(() => {
    if (!resolvedAgentUID) return []
    return (recentConversations.data?.conversations ?? []).filter(room =>
      room.agents.some(agent => agent.uid === resolvedAgentUID)
    )
  }, [recentConversations.data?.conversations, resolvedAgentUID])

  const deliveryConversationID =
    form.deliveryConversationID.value !== DEFAULT_DELIVERY &&
    recentConversations.data &&
    !matchingRooms.some(room => room.id === form.deliveryConversationID.value)
      ? DEFAULT_DELIVERY
      : form.deliveryConversationID.value

  const createMutation = useMutation({
    mutationFn: async () => {
      onPendingChange?.(true)
      try {
        return await createPodJob({
          body: {
            data: {
              requestID: form.requestID.value,
              mode: effectiveMode,
              agentUID: resolvedAgentUID,
              title: form.title.value.trim(),
              task: form.task.value.trim(),
              ...(deliveryConversationID !== DEFAULT_DELIVERY ? { conversationID: deliveryConversationID } : {}),
              ...(effectiveMode === 'cron'
                ? {
                    ...(hasScheduleTrigger
                      ? {
                          repeat: {
                            expression: form.expression.value.trim(),
                            timezone: form.timezone.value.trim() || 'UTC'
                          }
                        }
                      : {}),
                    ...(hasEventTrigger && eventSelection.activeSource
                      ? {
                          eventTriggers: [
                            {
                              configRef: eventSelection.activeSource.reference,
                              filters: eventSelection.filters,
                              coalesce: form.coalesce.value
                            }
                          ]
                        }
                      : {}),
                    quietSuccess: form.quietSuccess.value,
                    runNow: form.runNow.value
                  }
                : {})
            }
          }
        })
      } finally {
        onPendingChange?.(false)
      }
    },
    onSuccess: created => {
      void client.invalidateQueries({ queryKey: jobsKeys.all })
      onClose()
      onCreated(created)
    }
  })

  const validCron = effectiveMode !== 'cron' || form.validCron.value
  const validEventTrigger =
    effectiveMode !== 'cron' || !hasEventTrigger || (Boolean(eventSelection.activeSource) && form.validCoalesce.value)
  const canSubmit =
    !createMutation.isPending &&
    Boolean(resolvedAgentUID) &&
    form.hasRequiredText.value &&
    validCron &&
    validEventTrigger

  return (
    <form
      className="grid gap-4"
      onSubmit={event => {
        event.preventDefault()
        if (canSubmit) createMutation.mutate()
      }}>
      {createMutation.error ? <ContentError error={jobsError(createMutation.error)} /> : null}

      <Tabs value={effectiveMode} onValueChange={value => form.selectMode(value as 'one_off' | 'cron', agents)}>
        <TabsList className="grid w-full grid-cols-2">
          <TabsTrigger value="one_off" disabled={agents.length > 0 && !anyBackgroundCapable}>
            {t('pod.jobs.mode_one_off')}
          </TabsTrigger>
          <TabsTrigger value="cron">{t('pod.jobs.mode_cron')}</TabsTrigger>
        </TabsList>
      </Tabs>

      <div className="grid gap-1.5">
        <Label id="job-create-agent-label">{t('pod.jobs.field_agent')}</Label>
        <Select
          value={resolvedAgentUID}
          onValueChange={value => {
            if (value) form.selectAgent(value, agents)
          }}>
          <SelectTrigger aria-labelledby="job-create-agent-label" className="w-full">
            <SelectValue placeholder={t('pod.jobs.field_agent')} />
          </SelectTrigger>
          <SelectContent>
            {agents.map(agent => (
              <SelectItem
                key={agent.uid}
                value={agent.uid}
                disabled={effectiveMode === 'one_off' && !agent.canRunBackgroundJob}>
                {agent.displayName} (@{agent.uid})
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="grid gap-1.5">
        <Label htmlFor="job-create-title">{t('pod.jobs.field_title')}</Label>
        <Input
          id="job-create-title"
          name="title"
          required
          maxLength={200}
          placeholder={t('pod.jobs.field_title_placeholder')}
          value={form.title.value}
          onChange={event => {
            form.title.value = event.target.value
          }}
        />
      </div>

      <div className="grid gap-1.5">
        <Label htmlFor="job-create-task">{t('pod.jobs.field_task')}</Label>
        <Textarea
          id="job-create-task"
          name="task"
          required
          rows={4}
          maxLength={20_000}
          placeholder={t('pod.jobs.field_task_placeholder')}
          value={form.task.value}
          onChange={event => {
            form.task.value = event.target.value
          }}
        />
      </div>

      {effectiveMode === 'cron' && (
        <div className="grid gap-3 rounded-surface border border-border-subtle bg-layer-01/60 p-3">
          <div className="grid gap-1.5">
            <Label id={triggerModeLabelId}>{t('pod.jobs.trigger_mode')}</Label>
            <ToggleGroup
              aria-labelledby={triggerModeLabelId}
              size="sm"
              spacing={0}
              className="flex-wrap"
              value={[form.triggerMode.value]}
              onValueChange={next => {
                const chosen = next.at(-1) as RoutineTriggerMode | undefined
                if (chosen) form.triggerMode.value = chosen
              }}>
              {TRIGGER_MODES.map(option => (
                <ToggleGroupItem key={option.value} value={option.value}>
                  {t(option.labelKey)}
                </ToggleGroupItem>
              ))}
            </ToggleGroup>
          </div>

          {hasScheduleTrigger && (
            <>
              <CronEditor
                value={form.expression.value}
                onChange={next => {
                  form.expression.value = next
                }}
                disabled={createMutation.isPending}
                labels={cronEditorLabels(t)}
              />

              <div className="grid gap-1.5">
                <Label htmlFor="job-create-timezone">{t('pod.jobs.field_timezone')}</Label>
                <Input
                  id="job-create-timezone"
                  name="timezone"
                  required
                  autoCapitalize="off"
                  autoCorrect="off"
                  spellCheck={false}
                  disabled={createMutation.isPending}
                  value={form.timezone.value}
                  onChange={event => {
                    form.timezone.value = event.target.value
                  }}
                />
              </div>
            </>
          )}

          {hasEventTrigger && (
            <ConnectorEventSourceFields
              sources={connectorSources}
              selectedRef={form.eventSourceRef.value}
              onSelectRef={ref => form.selectEventSource(ref)}
              eventType={form.eventType.value}
              onSelectEventType={next => {
                form.eventType.value = next
              }}
              coalesceWindowSec={form.coalesceWindowSec.value}
              onCoalesceWindowSecChange={next => {
                form.coalesceWindowSec.value = next
              }}
              coalesceMaxBatch={form.coalesceMaxBatch.value}
              onCoalesceMaxBatchChange={next => {
                form.coalesceMaxBatch.value = next
              }}
              disabled={createMutation.isPending}
            />
          )}

          <SwitchRow
            labelFirst
            rowClassName="flex items-center justify-between gap-3 text-sm"
            label={t('pod.jobs.field_quiet_success')}
            checked={form.quietSuccess.value}
            onCheckedChange={checked => {
              form.quietSuccess.value = checked
            }}
          />

          <SwitchRow
            labelFirst
            rowClassName="flex items-center justify-between gap-3 text-sm"
            label={t('pod.jobs.field_run_now')}
            checked={form.runNow.value}
            onCheckedChange={checked => {
              form.runNow.value = checked
            }}
          />
        </div>
      )}

      <div className="grid gap-1.5">
        <Label id="job-create-delivery-label">{t('pod.jobs.field_delivery')}</Label>
        <Select
          loading={recentConversations.isPending}
          value={deliveryConversationID}
          onValueChange={value => {
            if (value) form.deliveryConversationID.value = value
          }}>
          <SelectTrigger aria-labelledby="job-create-delivery-label" className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={DEFAULT_DELIVERY}>
              {effectiveMode === 'one_off' ? t('pod.jobs.delivery_standalone') : t('pod.jobs.delivery_agent_dm')}
            </SelectItem>
            {matchingRooms.map(room => (
              <SelectItem key={room.id} value={room.id}>
                {conversationLabel(room, t('pod.content.untitled'))}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <DialogFooter>
        <Button type="button" variant="ghost" disabled={createMutation.isPending} onClick={onClose}>
          {t('common.cancel')}
        </Button>
        <Button type="submit" disabled={!canSubmit}>
          {effectiveMode === 'one_off' ? t('pod.jobs.submit_one_off') : t('pod.jobs.submit_cron')}
        </Button>
      </DialogFooter>
    </form>
  )
}

export function JobCreateDialog({
  open,
  onOpenChange,
  agents,
  preset,
  returnFocus,
  onCreated
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  agents: JobCandidateAgent[]
  preset?: JobStarterPreset | null
  returnFocus?: RefObject<HTMLElement | null>
  onCreated: (item: JobBoardItem) => void
}) {
  const { t } = useTranslation()
  const pendingRef = useRef(false)
  if (!open) return null

  const presetKey = preset
    ? `${preset.mode}:${preset.agentUID ?? ''}:${preset.title ?? ''}:${preset.expression ?? ''}`
    : 'default'

  return (
    <Dialog
      open
      onOpenChange={next => {
        if (!pendingRef.current) onOpenChange(next)
      }}>
      <DialogContent
        className="max-h-[min(88vh,44rem)] w-[min(34rem,calc(100vw-2rem))] overflow-y-auto"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}>
        <DialogTitle>{t('pod.jobs.create_title')}</DialogTitle>
        <DialogDescription>{t('pod.jobs.create_description')}</DialogDescription>
        <JobCreateFormContent
          key={presetKey}
          agents={agents}
          preset={preset}
          onPendingChange={pending => {
            pendingRef.current = pending
          }}
          onClose={() => onOpenChange(false)}
          onCreated={onCreated}
        />
      </DialogContent>
    </Dialog>
  )
}

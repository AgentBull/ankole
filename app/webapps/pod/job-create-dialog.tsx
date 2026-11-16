import { uuidV4 } from '@agentbull/active-support'
import {
  Button,
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
  Textarea
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys } from './api'
import { createPodJob, podConversations } from './api/generated/sdk.gen'
import { conversationLabel } from './chat/conversation-row'
import { ContentError } from './content-primitives'
import { jobsError, jobsKeys, type JobBoardItem, type JobCandidateAgent } from './jobs-api'

export type JobStarterPreset = {
  mode: 'one_off' | 'cron'
  agentUID?: string
  title?: string
  task?: string
  expression?: string
}

const DEFAULT_DELIVERY = '__default__'

const SCHEDULE_PRESETS = [
  { value: '0 9 * * 1-5', labelKey: 'pod.jobs.presets.weekdays_morning' },
  { value: '0 9 * * *', labelKey: 'pod.jobs.presets.daily_morning' },
  { value: '0 9 * * 1', labelKey: 'pod.jobs.presets.weekly_monday' },
  { value: '0 * * * *', labelKey: 'pod.jobs.presets.hourly' }
] as const

function defaultTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  } catch {
    return 'UTC'
  }
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
  const client = useQueryClient()

  const anyBackgroundCapable = agents.some(agent => agent.canRunBackgroundJob)
  const [mode, setMode] = useState<'one_off' | 'cron'>('one_off')
  const [agentUID, setAgentUID] = useState('')
  const [title, setTitle] = useState('')
  const [task, setTask] = useState('')
  const [schedulePreset, setSchedulePreset] = useState<string>('0 9 * * 1-5')
  const [expression, setExpression] = useState('0 9 * * 1-5')
  const [timezone, setTimezone] = useState(defaultTimezone)
  const [quietSuccess, setQuietSuccess] = useState(true)
  const [runNow, setRunNow] = useState(false)
  const [deliveryConversationID, setDeliveryConversationID] = useState(DEFAULT_DELIVERY)
  const [requestID, setRequestID] = useState(uuidV4)

  const createMutation = useMutation({
    mutationFn: () =>
      createPodJob({
        body: {
          data: {
            requestID,
            mode: effectiveMode,
            agentUID,
            title: title.trim(),
            task: task.trim(),
            ...(deliveryConversationID !== DEFAULT_DELIVERY ? { conversationID: deliveryConversationID } : {}),
            ...(effectiveMode === 'cron'
              ? {
                  repeat: {
                    expression: expression.trim(),
                    timezone: timezone.trim() || 'UTC'
                  },
                  quietSuccess,
                  runNow
                }
              : {})
          }
        }
      }),
    onSuccess: created => {
      void client.invalidateQueries({ queryKey: jobsKeys.all })
      onOpenChange(false)
      onCreated(created)
    }
  })

  useEffect(() => {
    if (!open) return
    const presetAgent = preset?.agentUID ? agents.find(agent => agent.uid === preset.agentUID) : undefined
    const initialMode: 'one_off' | 'cron' =
      preset?.mode === 'cron' || !anyBackgroundCapable || (presetAgent && !presetAgent.canRunBackgroundJob)
        ? 'cron'
        : 'one_off'
    const preferredAgent =
      presetAgent ??
      (initialMode === 'one_off' ? (agents.find(agent => agent.canRunBackgroundJob) ?? agents[0]) : agents[0])
    const nextExpression = preset?.expression ?? '0 9 * * 1-5'
    const knownPreset = SCHEDULE_PRESETS.some(entry => entry.value === nextExpression) ? nextExpression : 'custom'
    setMode(initialMode)
    setAgentUID(preferredAgent?.uid ?? '')
    setTitle(preset?.title ?? '')
    setTask(preset?.task ?? '')
    setExpression(nextExpression)
    setSchedulePreset(knownPreset)
    setTimezone(defaultTimezone())
    setQuietSuccess(true)
    setRunNow(false)
    setDeliveryConversationID(DEFAULT_DELIVERY)
    setRequestID(uuidV4())
    createMutation.reset()
  }, [open, preset])

  const selectedAgent = agents.find(agent => agent.uid === agentUID) ?? agents[0]
  const effectiveMode: 'one_off' | 'cron' = selectedAgent && !selectedAgent.canRunBackgroundJob ? 'cron' : mode

  const recentConversations = useQuery({
    queryKey: [...podKeys.conversations, 'jobs-delivery'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 30 }, signal }),
    enabled: open && Boolean(selectedAgent?.uid)
  })

  const matchingRooms = useMemo(() => {
    const uid = selectedAgent?.uid
    if (!uid) return []
    return (recentConversations.data?.conversations ?? []).filter(room => room.agents.some(agent => agent.uid === uid))
  }, [recentConversations.data?.conversations, selectedAgent?.uid])

  useEffect(() => {
    if (
      deliveryConversationID !== DEFAULT_DELIVERY &&
      recentConversations.data &&
      !matchingRooms.some(room => room.id === deliveryConversationID)
    ) {
      setDeliveryConversationID(DEFAULT_DELIVERY)
    }
  }, [deliveryConversationID, matchingRooms, recentConversations.data])

  const validCron = effectiveMode !== 'cron' || expression.trim().split(/\s+/).length === 5
  const canSubmit =
    !createMutation.isPending && Boolean(agentUID) && Boolean(title.trim()) && Boolean(task.trim()) && validCron

  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!createMutation.isPending) onOpenChange(next)
      }}>
      <DialogContent
        className="max-h-[min(88vh,44rem)] w-[min(34rem,calc(100vw-2rem))] overflow-y-auto"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}>
        <DialogTitle>{t('pod.jobs.create_title')}</DialogTitle>
        <DialogDescription>{t('pod.jobs.create_description')}</DialogDescription>

        <form
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            if (canSubmit) createMutation.mutate()
          }}>
          {createMutation.error ? <ContentError error={jobsError(createMutation.error)} /> : null}

          <Tabs
            value={effectiveMode}
            onValueChange={value => {
              const next = value as 'one_off' | 'cron'
              setMode(next)
              if (next === 'one_off' && selectedAgent && !selectedAgent.canRunBackgroundJob) {
                const candidate = agents.find(agent => agent.canRunBackgroundJob)
                if (candidate) setAgentUID(candidate.uid)
              }
            }}>
            <TabsList className="grid w-full grid-cols-2">
              <TabsTrigger value="one_off" disabled={!anyBackgroundCapable}>
                {t('pod.jobs.mode_one_off')}
              </TabsTrigger>
              <TabsTrigger value="cron">{t('pod.jobs.mode_cron')}</TabsTrigger>
            </TabsList>
          </Tabs>

          <div className="grid gap-1.5">
            <Label id="job-create-agent-label">{t('pod.jobs.field_agent')}</Label>
            <Select
              value={agentUID}
              onValueChange={value => {
                if (!value) return
                setAgentUID(value)
                const chosen = agents.find(agent => agent.uid === value)
                if (chosen && !chosen.canRunBackgroundJob && mode === 'one_off') {
                  setMode('cron')
                }
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
              required
              maxLength={200}
              placeholder={t('pod.jobs.field_title_placeholder')}
              value={title}
              onChange={event => setTitle(event.target.value)}
            />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="job-create-task">{t('pod.jobs.field_task')}</Label>
            <Textarea
              id="job-create-task"
              required
              rows={4}
              maxLength={20_000}
              placeholder={t('pod.jobs.field_task_placeholder')}
              value={task}
              onChange={event => setTask(event.target.value)}
            />
          </div>

          {effectiveMode === 'cron' && (
            <div className="grid gap-3 rounded-surface border border-border-subtle bg-layer-01/60 p-3">
              <div className="grid gap-1.5">
                <Label id="job-create-preset-label">{t('pod.jobs.field_schedule')}</Label>
                <Select
                  value={schedulePreset}
                  onValueChange={value => {
                    if (!value) return
                    setSchedulePreset(value)
                    if (value !== 'custom') setExpression(value)
                  }}>
                  <SelectTrigger aria-labelledby="job-create-preset-label" className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {SCHEDULE_PRESETS.map(entry => (
                      <SelectItem key={entry.value} value={entry.value}>
                        {t(entry.labelKey)}
                      </SelectItem>
                    ))}
                    <SelectItem value="custom">{t('pod.jobs.presets.custom')}</SelectItem>
                  </SelectContent>
                </Select>
              </div>

              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div className="grid gap-1.5">
                  <Label htmlFor="job-create-expression">{t('pod.jobs.field_cron_expression')}</Label>
                  <Input
                    id="job-create-expression"
                    required
                    value={expression}
                    aria-invalid={!validCron || undefined}
                    placeholder="0 9 * * 1-5"
                    onChange={event => {
                      const next = event.target.value
                      setExpression(next)
                      const matched = SCHEDULE_PRESETS.find(entry => entry.value === next.trim())
                      setSchedulePreset(matched ? matched.value : 'custom')
                    }}
                  />
                </div>
                <div className="grid gap-1.5">
                  <Label htmlFor="job-create-timezone">{t('pod.jobs.field_timezone')}</Label>
                  <Input
                    id="job-create-timezone"
                    required
                    value={timezone}
                    onChange={event => setTimezone(event.target.value)}
                  />
                </div>
              </div>

              <SwitchRow
                labelFirst
                rowClassName="flex items-center justify-between gap-3 text-sm"
                label={t('pod.jobs.field_quiet_success')}
                checked={quietSuccess}
                onCheckedChange={setQuietSuccess}
              />

              <SwitchRow
                labelFirst
                rowClassName="flex items-center justify-between gap-3 text-sm"
                label={t('pod.jobs.field_run_now')}
                checked={runNow}
                onCheckedChange={setRunNow}
              />
            </div>
          )}

          <div className="grid gap-1.5">
            <Label id="job-create-delivery-label">{t('pod.jobs.field_delivery')}</Label>
            <Select
              value={deliveryConversationID}
              onValueChange={value => {
                if (value) setDeliveryConversationID(value)
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
            <Button
              type="button"
              variant="ghost"
              disabled={createMutation.isPending}
              onClick={() => onOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <Button type="submit" disabled={!canSubmit}>
              {effectiveMode === 'one_off' ? t('pod.jobs.submit_one_off') : t('pod.jobs.submit_cron')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

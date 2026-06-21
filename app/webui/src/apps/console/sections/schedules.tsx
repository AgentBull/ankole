import { RiAddLine, RiDeleteBinLine, RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ScheduledTaskSchedule } from '@/common/db-schema'
import { isPluginConfigJsonObject as isJsonObject, type PluginConfigJsonObject } from '@/plugins/config-json'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Input } from '@/uikit/components/input'
import { Spinner } from '@/uikit/components/spinner'
import { Switch } from '@/uikit/components/switch'
import { TableCell, TableRow } from '@/uikit/components/table'
import { Textarea } from '@/uikit/components/textarea'
import { formatDate, useAgentsQuery } from '../helpers'
import { AgentSelector, ErrorAlert, SectionHeader, TableCard } from '../shared'

type JsonObject = PluginConfigJsonObject

type ScheduledTaskDeliveryInput = {
  binding_name: string
  room_id: string
  thread_id?: string
}

/** Manages scheduled agent deliveries from the console, including manual runs and run history. */
export function SchedulesPage() {
  const { t } = useTranslation()
  const agents = useAgentsQuery()
  const queryClient = useQueryClient()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [message, setMessage] = useState('')
  const [taskEnabled, setTaskEnabled] = useState(true)
  const [scheduleJson, setScheduleJson] = useState('{"kind":"every","every_ms":3600000}')
  const [deliveryJson, setDeliveryJson] = useState('')
  const tasks = useQuery({
    queryKey: ['console-scheduled-tasks', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid })['scheduled-tasks'].get())
  })
  const selectedTask = tasks.data?.tasks.find(task => task.id === selectedTaskId)
  const runs = useQuery({
    queryKey: ['console-scheduled-task-runs', selectedTaskId],
    enabled: Boolean(selectedTaskId),
    queryFn: () => unwrap(api.console['scheduled-tasks']({ taskId: selectedTaskId ?? '' }).runs.get())
  })
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.agents({ uid: selectedUid })['scheduled-tasks'].post({
          name,
          enabled: true,
          schedule: parseScheduleJson(scheduleJson),
          payload: { message },
          delivery: deliveryJson.trim() ? parseDeliveryJson(deliveryJson) : null
        })
      ),
    onSuccess: result => {
      setName('')
      setMessage('')
      setTaskEnabled(true)
      setScheduleJson('{"kind":"every","every_ms":3600000}')
      setDeliveryJson('')
      setSelectedTaskId(result.task.id)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['scheduled-tasks']({ taskId: selectedTaskId ?? '' }).put({
          name,
          enabled: taskEnabled,
          schedule: parseScheduleJson(scheduleJson),
          payload: { message },
          delivery: deliveryJson.trim() ? parseDeliveryJson(deliveryJson) : null
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
  })
  const toggle = useMutation({
    mutationFn: (input: { taskId: string; enabled: boolean }) =>
      unwrap(api.console['scheduled-tasks']({ taskId: input.taskId }).put({ enabled: input.enabled })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
  })
  const runNow = useMutation({
    mutationFn: (taskId: string) => unwrap(api.console['scheduled-tasks']({ taskId }).run.post()),
    onSuccess: (_, taskId) => {
      setSelectedTaskId(taskId)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-task-runs', taskId] })
    }
  })
  const remove = useMutation({
    mutationFn: (taskId: string) => unwrap(api.console['scheduled-tasks']({ taskId }).delete()),
    onSuccess: (_, taskId) => {
      if (selectedTaskId === taskId) setSelectedTaskId(null)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
    }
  })

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  useEffect(() => {
    if (!selectedTask) return
    setName(selectedTask.name)
    setMessage(typeof selectedTask.payload.message === 'string' ? selectedTask.payload.message : '')
    setTaskEnabled(selectedTask.enabled)
    setScheduleJson(JSON.stringify(selectedTask.schedule, null, 2))
    setDeliveryJson(selectedTask.delivery ? JSON.stringify(selectedTask.delivery, null, 2) : '')
  }, [selectedTask])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.schedules.title')} description={t('console.schedules.description')} />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">
            {selectedTaskId ? t('console.schedules.edit_task') : t('console.schedules.create_task')}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              selectedTaskId ? update.mutate() : create.mutate()
            }}>
            <div className="grid gap-4 lg:grid-cols-[1fr_1fr_auto]">
              <Input
                placeholder={t('console.schedules.name_placeholder')}
                value={name}
                onChange={event => setName(event.target.value)}
              />
              <Input
                placeholder={t('console.schedules.message_placeholder')}
                value={message}
                onChange={event => setMessage(event.target.value)}
              />
              <div className="flex items-center justify-between gap-3 border border-border px-4 py-3">
                <span className="text-sm">{t('console.enabled')}</span>
                <Switch checked={taskEnabled} onCheckedChange={checked => setTaskEnabled(checked)} />
              </div>
            </div>
            <div className="grid gap-4 lg:grid-cols-2">
              <Textarea
                value={scheduleJson}
                onChange={event => setScheduleJson(event.target.value)}
                className="min-h-24 font-mono"
              />
              <Textarea
                placeholder={t('console.schedules.delivery_placeholder')}
                value={deliveryJson}
                onChange={event => setDeliveryJson(event.target.value)}
                className="min-h-24 font-mono"
              />
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="submit"
                disabled={!selectedUid || !name.trim() || !message.trim() || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? <Spinner /> : selectedTaskId ? <RiSaveLine /> : <RiAddLine />}
                {selectedTaskId ? t('console.schedules.save_task') : t('console.schedules.create_button')}
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setSelectedTaskId(null)
                  setName('')
                  setMessage('')
                  setTaskEnabled(true)
                  setScheduleJson('{"kind":"every","every_ms":3600000}')
                  setDeliveryJson('')
                }}>
                {t('console.clear')}
              </Button>
            </div>
          </form>
          <ErrorAlert error={create.error ?? update.error} title={t('console.schedules.save_failed')} />
        </CardContent>
      </Card>
      <TableCard
        loading={agents.isPending || tasks.isPending}
        error={agents.error ?? tasks.error}
        empty={(tasks.data?.tasks.length ?? 0) === 0}
        columns={[
          t('console.schedules.column_name'),
          t('console.enabled'),
          t('console.schedules.column_schedule'),
          t('console.schedules.column_next_run'),
          t('console.schedules.column_last_status'),
          t('console.actions')
        ]}>
        {(tasks.data?.tasks ?? []).map(task => (
          <TableRow
            key={task.id}
            data-state={selectedTaskId === task.id ? 'selected' : undefined}
            className="cursor-pointer"
            onClick={() => setSelectedTaskId(task.id)}>
            <TableCell className="font-medium">{task.name}</TableCell>
            <TableCell>
              <Badge variant={task.enabled ? 'default' : 'secondary'}>
                {task.enabled ? t('console.badge_enabled') : t('console.badge_disabled')}
              </Badge>
            </TableCell>
            <TableCell className="font-mono text-xs">{formatJson(task.schedule)}</TableCell>
            <TableCell>{formatDate(task.nextRunAt)}</TableCell>
            <TableCell>{task.lastStatus ?? '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  disabled={toggle.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    toggle.mutate({ taskId: task.id, enabled: !task.enabled })
                  }}>
                  {task.enabled ? t('console.disable') : t('console.enable')}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={runNow.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    runNow.mutate(task.id)
                  }}>
                  {t('console.schedules.run_now')}
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={remove.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    if (window.confirm(t('console.schedules.delete_confirm', { name: task.name }))) {
                      remove.mutate(task.id)
                    }
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
      {selectedTaskId ? (
        <TableCard
          loading={runs.isPending}
          error={runs.error}
          empty={(runs.data?.runs.length ?? 0) === 0}
          columns={[
            t('console.schedules.column_run'),
            t('console.schedules.column_status'),
            t('console.schedules.column_trigger'),
            t('console.schedules.column_started'),
            t('console.schedules.column_finished'),
            t('console.schedules.column_error')
          ]}>
          {(runs.data?.runs ?? []).map(run => (
            <TableRow key={run.id}>
              <TableCell className="font-mono text-xs">{run.id}</TableCell>
              <TableCell>
                <Badge
                  variant={
                    run.status === 'succeeded' ? 'default' : run.status === 'failed' ? 'destructive' : 'secondary'
                  }>
                  {run.status}
                </Badge>
              </TableCell>
              <TableCell>{run.trigger}</TableCell>
              <TableCell>{formatDate(run.startedAt)}</TableCell>
              <TableCell>{formatDate(run.finishedAt)}</TableCell>
              <TableCell className="max-w-[320px] truncate">{run.error ?? '-'}</TableCell>
            </TableRow>
          ))}
        </TableCard>
      ) : null}
    </div>
  )
}

/** Formats stored schedule payloads for compact table display even when an unexpected value leaks through. */
function formatJson(value: unknown): string {
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

/** Keeps the free-form JSON editor constrained to objects because the scheduler expects object-shaped contracts. */
function parseJsonObject(value: string, label: string): JsonObject {
  const parsed = JSON.parse(value) as unknown
  if (!isJsonObject(parsed)) throw new Error(`${label} must be a JSON object`)
  return parsed
}

/** Parses the schedule JSON into the scheduler union type after the runtime object-shape guard passes. */
function parseScheduleJson(value: string): ScheduledTaskSchedule {
  return parseJsonObject(value, 'schedule') as unknown as ScheduledTaskSchedule
}

/** Normalizes optional delivery fields so console JSON can round-trip values copied from API responses. */
function parseDeliveryJson(value: string): ScheduledTaskDeliveryInput {
  const delivery = parseJsonObject(value, 'delivery') as unknown as ScheduledTaskDeliveryInput
  if (delivery.thread_id === null) delete (delivery as { thread_id?: unknown }).thread_id
  return delivery
}

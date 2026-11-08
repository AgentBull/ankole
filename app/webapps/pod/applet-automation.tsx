import { cronEditorLabels } from '../common/cron-editor-labels'
import { dateTimeLocalValue, formatDateTime } from '../common/date-time'
import {
  Button,
  CronEditor,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  Input,
  Label,
  Textarea
} from '@ankole/uikit'
import {
  createAppletJobs,
  createJobSources,
  type AppletJob,
  type JobDelivery,
  type JobSchedule,
  type JobWebhook
} from '@ankole/applet-sdk'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from 'react'
import type { ActionRun } from '@ankole/applet-sdk/types'
import { useTranslation } from 'react-i18next'
import { Link } from '@tanstack/react-router'
import { Choice as ChoiceControl, ContentError, ContentSkeleton, InlineLoading } from './content-primitives'
import { contentKeys, podRequest, type PageDetail } from './content-api'
import * as api from './api/generated/sdk.gen'
import { automationJobID, connectorFailureMessage, connectorReturnTo } from './state/connectors'

const pod = { request: podRequest }
type Change = (operation: () => Promise<unknown>) => void
const json = (value: unknown) => JSON.stringify(value, null, 2)

function Choice<T extends string>(props: {
  label: string
  value: T
  onChange(value: NoInfer<T>): void
  options: Partial<Record<NoInfer<T>, string>>
}) {
  return (
    <div className="grid gap-1.5">
      <p className="text-sm font-medium">{props.label}</p>
      <ChoiceControl {...props} />
    </div>
  )
}

function object(form: FormData, field: string) {
  const value = JSON.parse(String(form.get(field) || '{}'))
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Expected a JSON object')
  return value as Record<string, unknown>
}

function Field({
  name,
  label,
  value = '',
  type = 'text',
  required = true,
  multiline = false
}: {
  name: string
  label: string
  value?: string
  type?: string
  required?: boolean
  multiline?: boolean
}) {
  const id = useId()
  const props = { id, name, defaultValue: value, required }
  return (
    <div className="grid gap-1.5">
      <Label htmlFor={id}>{label}</Label>
      {multiline ? <Textarea {...props} rows={3} className="font-mono text-sm" /> : <Input {...props} type={type} />}
    </div>
  )
}

function Form({
  children,
  submit,
  busy,
  onSubmit
}: {
  children: ReactNode
  submit: string
  busy: boolean
  onSubmit(data: FormData): void
}) {
  return (
    <form
      className="grid gap-3"
      onSubmit={(event: FormEvent<HTMLFormElement>) => {
        event.preventDefault()
        onSubmit(new FormData(event.currentTarget))
      }}>
      {children}
      <Button type="submit" disabled={busy} className="justify-self-start">
        {submit}
      </Button>
    </form>
  )
}

export function AppletAutomationDialog({
  detail,
  open,
  onOpenChange
}: {
  detail: PageDetail
  open: boolean
  onOpenChange(open: boolean): void
}) {
  const { t } = useTranslation()
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="pod-dialog-wide" closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('pod.automation.title')}</DialogTitle>
          <DialogDescription>{t('pod.automation.description')}</DialogDescription>
        </DialogHeader>
        {open && <Manager detail={detail} />}
      </DialogContent>
    </Dialog>
  )
}

function Manager({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const key = [...contentKeys.page(detail.page.id), 'automation']
  const jobs = createAppletJobs(pod, detail.page.id)
  const list = useQuery({ queryKey: [...key, 'jobs'], queryFn: jobs.list })
  const actions = useQuery({
    queryKey: [...contentKeys.page(detail.page.id), 'action-keys', detail.page.revision],
    queryFn: jobs.actions
  })
  const [selected, setSelected] = useState(() => automationJobID(new URLSearchParams(window.location.search)))
  const [creating, setCreating] = useState(false)
  const errorElement = useRef<HTMLDivElement>(null)
  const change = useMutation({
    mutationFn: (operation: () => Promise<unknown>) => operation(),
    onSuccess: () => client.invalidateQueries({ queryKey: key })
  })
  const job = selected === undefined ? list.data?.[0] : list.data?.find(item => item.id === selected)
  const canEdit = detail.actions.includes('node_edit')
  const canCreate = detail.actions.includes('node_contribute')
  useEffect(() => {
    if (!change.error) return
    errorElement.current?.scrollIntoView({ block: 'center' })
    errorElement.current?.focus({ preventScroll: true })
  }, [change.error])

  return (
    <div className="grid gap-5">
      {!!(change.error ?? list.error) && (
        <div ref={errorElement} tabIndex={-1}>
          <ContentError error={change.error ?? list.error} />
        </div>
      )}
      {list.isPending && <ContentSkeleton variant="list" rows={2} />}
      <div className="flex flex-wrap items-center gap-3">
        {!!list.data?.length && (
          <div className="min-w-48 flex-1">
            <Choice
              label={t('pod.automation.job')}
              value={String(job?.id ?? '')}
              onChange={id => setSelected(Number(id))}
              options={Object.fromEntries(list.data.map(item => [String(item.id), item.label]))}
            />
          </div>
        )}
        {canCreate && (
          <Button variant="outline" onClick={() => setCreating(!creating)}>
            {t('pod.automation.new_job')}
          </Button>
        )}
      </div>
      {!list.isPending && !list.data?.length && (
        <p className="text-sm text-muted-foreground">{t('pod.automation.no_jobs')}</p>
      )}
      {list.isSuccess && selected !== undefined && !job && (
        <p role="status" className="text-sm text-muted-foreground">
          {t('pod.automation.return_job_unavailable')}
        </p>
      )}
      {creating && (
        <section className="rounded-lg border p-4">
          <ContentError error={actions.error} />
          {actions.data?.length ? (
            <JobForm
              busy={change.isPending}
              actions={actions.data}
              canEdit={canEdit}
              onSave={input =>
                change.mutate(async () => {
                  const created = await jobs.create(input)
                  setSelected(created.id)
                  setCreating(false)
                })
              }
            />
          ) : actions.isPending ? (
            <InlineLoading />
          ) : (
            <p className="text-sm">{t('pod.automation.no_actions')}</p>
          )}
        </section>
      )}
      {job && (
        <JobDetails
          key={job.id}
          job={job}
          pageID={detail.page.id}
          canManage={job.authorization_kind === 'service' ? canEdit : canCreate}
          busy={change.isPending}
          change={operation => change.mutate(operation)}
        />
      )}
    </div>
  )
}

function JobForm({
  job,
  actions,
  canEdit,
  busy,
  onSave
}: {
  job?: AppletJob
  actions: string[]
  canEdit: boolean
  busy: boolean
  onSave(input: {
    action_key: string
    label: string
    authorization_kind: 'human' | 'service'
    config: Record<string, unknown>
  }): void
}) {
  const { t } = useTranslation()
  const [action, setAction] = useState(job?.action_key ?? actions[0] ?? '')
  const [authority, setAuthority] = useState<'human' | 'service'>(job?.authorization_kind ?? 'human')
  const [error, setError] = useState<unknown>()
  return (
    <Form
      busy={busy}
      submit={t(job ? 'common.save' : 'pod.automation.create_job')}
      onSubmit={data => {
        try {
          const config = object(data, 'config')
          setError(undefined)
          onSave({ action_key: action, label: String(data.get('label')), authorization_kind: authority, config })
        } catch (error) {
          setError(error)
        }
      }}>
      <ContentError error={error} />
      {!job && (
        <Choice
          label={t('pod.automation.action')}
          value={action}
          onChange={setAction}
          options={Object.fromEntries(actions.map(value => [value, value]))}
        />
      )}
      <Field name="label" label={t('pod.automation.name')} value={job?.label ?? action} />
      {!job && (
        <Choice
          label={t('pod.automation.authority')}
          value={authority}
          onChange={setAuthority}
          options={{ human: t('pod.automation.personal'), ...(canEdit ? { service: t('pod.automation.team') } : {}) }}
        />
      )}
      <Field name="config" label={t('pod.automation.config')} value={json(job?.config ?? {})} multiline />
    </Form>
  )
}

function JobDetails({
  job,
  pageID,
  canManage,
  busy,
  change
}: {
  job: AppletJob
  pageID: string
  canManage: boolean
  busy: boolean
  change: Change
}) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [selectedRun, setSelectedRun] = useState<ActionRun>()
  const jobs = createAppletJobs(pod, pageID)
  const sources = createJobSources(pod, pageID, job.id)
  const key = [...contentKeys.page(pageID), 'automation', job.id]
  const schedules = useQuery({
    queryKey: [...key, 'schedules'],
    queryFn: sources.schedules.list,
    refetchInterval: 5000
  })
  const webhooks = useQuery({ queryKey: [...key, 'webhooks'], queryFn: sources.webhooks.list, refetchInterval: 5000 })
  const runs = useQuery({ queryKey: [...key, 'runs'], queryFn: () => jobs.runs(job.id), refetchInterval: 2000 })
  const active = canManage && job.status === 'active'
  const sourceNames: Record<string, string> = Object.fromEntries([
    ...(schedules.data ?? []).map(item => [`ankole:schedule:${item.id}`, item.name]),
    ...(webhooks.data ?? []).map(({ endpoint }) => [`ankole:webhook:${endpoint.id}`, endpoint.label])
  ])
  const runSource = (run: ActionRun) => {
    const source = run.event.source
    return typeof source === 'string' ? (sourceNames[source] ?? source) : undefined
  }
  const currentRun = selectedRun && (runs.data?.find(run => run.id === selectedRun.id) ?? selectedRun)
  const onRun = (id: number) =>
    change(async () => {
      const result = await podRequest<{ run: ActionRun }>(`/pages/${pageID}/runs/${id}`)
      setSelectedRun(result.run)
    })
  return (
    <div className="grid gap-6">
      <ContentError error={schedules.error ?? webhooks.error ?? runs.error} />
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <span>
          {job.action_key} · {t(`pod.automation.${job.authorization_kind === 'human' ? 'personal' : 'team'}`)} ·{' '}
          {t(`pod.automation.status_${job.status}`)}
        </span>
        {active && (
          <Button size="sm" variant="ghost" onClick={() => setEditing(!editing)}>
            {t('common.edit')}
          </Button>
        )}
        {canManage && (
          <Button size="sm" variant="ghost" onClick={() => setDeleting(!deleting)}>
            {t('pod.automation.delete_job')}
          </Button>
        )}
      </div>
      {!canManage && <p className="text-sm text-muted-foreground">{t('pod.automation.job_read_only')}</p>}
      {deleting && (
        <div className="rounded-lg border p-3 text-sm">
          <p>{t('pod.automation.delete_job_help')}</p>
          <div className="mt-3 flex gap-2">
            <Button variant="destructive" disabled={busy} onClick={() => change(() => jobs.delete(job.id))}>
              {t('common.delete')}
            </Button>
            <Button variant="ghost" onClick={() => setDeleting(false)}>
              {t('common.cancel')}
            </Button>
          </div>
        </div>
      )}
      {editing && (
        <JobForm
          job={job}
          actions={[job.action_key]}
          canEdit={false}
          busy={busy}
          onSave={input =>
            change(async () => {
              await jobs.configure(job.id, { label: input.label, config: input.config })
              setEditing(false)
            })
          }
        />
      )}
      <Schedules
        items={schedules.data ?? []}
        sources={sources}
        active={active}
        busy={busy}
        change={change}
        onRun={onRun}
      />
      <Webhooks
        items={webhooks.data ?? []}
        sources={sources}
        active={active}
        busy={busy}
        change={change}
        onRun={onRun}
      />
      {active && <ConnectorEvents job={job} pageID={pageID} busy={busy} change={change} />}
      <section className="grid gap-3" aria-label={t('pod.automation.history')}>
        <h3 className="font-medium">{t('pod.automation.history')}</h3>
        {currentRun && <SelectedRun run={currentRun} source={runSource(currentRun)} />}
        {!runs.data?.length && <p className="text-sm text-muted-foreground">{t('pod.automation.no_runs')}</p>}
        {runs.data?.map(run => (
          <details key={run.id} className="rounded-lg border p-3 text-sm">
            <summary className="cursor-pointer break-words">
              <RunSummary run={run} source={runSource(run)} />
            </summary>
            <RunContent run={run} />
          </details>
        ))}
      </section>
    </div>
  )
}

function RunSummary({ run, source }: { run: ActionRun; source?: string }) {
  const { t } = useTranslation()
  const time = run.started_at ?? (typeof run.event.time === 'string' ? run.event.time : undefined)
  return (
    <>
      #{run.id} · {t(`pod.automation.status_${run.status}`)}
      {time && <span className="text-muted-foreground"> · {formatDateTime(time, undefined, 'medium')}</span>}
      {source && (
        <span className="block break-words text-muted-foreground">
          {t('pod.automation.run_source')}: {source}
          {typeof run.event.type === 'string' && ` · ${run.event.type}`}
        </span>
      )}
    </>
  )
}

function RunContent({ run }: { run: ActionRun }) {
  const { t } = useTranslation()
  return (
    <div className="mt-2 grid min-w-0 gap-2">
      {run.finished_at && (
        <p className="text-muted-foreground">
          {t('pod.automation.run_finished')}: {formatDateTime(run.finished_at, undefined, 'medium')}
        </p>
      )}
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words">
        {json({ progress: run.progress, result: run.result, error: run.error })}
      </pre>
      <details>
        <summary className="cursor-pointer">{t('pod.automation.run_input')}</summary>
        <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words">{json(run.event)}</pre>
      </details>
      {(run.stdout || run.stderr) && (
        <details>
          <summary className="cursor-pointer">{t('pod.automation.run_logs')}</summary>
          <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words">
            {[run.stdout && `stdout:\n${run.stdout}`, run.stderr && `stderr:\n${run.stderr}`]
              .filter(Boolean)
              .join('\n\n')}
          </pre>
          {(run.stdout_truncated || run.stderr_truncated) && (
            <p className="text-muted-foreground">{t('pod.automation.logs_truncated')}</p>
          )}
        </details>
      )}
    </div>
  )
}

function SelectedRun({ run, source }: { run: ActionRun; source?: string }) {
  const { t } = useTranslation()
  const element = useRef<HTMLDivElement>(null)
  useEffect(() => {
    element.current?.scrollIntoView({ block: 'nearest' })
    element.current?.focus()
  }, [run.id])
  return (
    <div
      ref={element}
      tabIndex={-1}
      className="rounded-lg border p-3 text-sm"
      aria-label={t('pod.automation.run_details')}>
      <p className="break-words">
        <RunSummary run={run} source={source} />
      </p>
      <RunContent run={run} />
    </div>
  )
}

type Sources = ReturnType<typeof createJobSources>
type Controls = { sources: Sources; active: boolean; busy: boolean; change: Change; onRun(id: number): void }

function Schedules({ items, sources, active, busy, change, onRun }: Controls & { items: JobSchedule[] }) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<JobSchedule | null | undefined>()
  const [history, setHistory] = useState<string>()
  return (
    <section className="grid gap-3" aria-label={t('pod.automation.schedules')}>
      <div className="flex items-center justify-between gap-3">
        <h3 className="font-medium">{t('pod.automation.schedules')}</h3>
        {active && (
          <Button size="sm" variant="outline" onClick={() => setEditing(null)}>
            {t('pod.automation.add_schedule')}
          </Button>
        )}
      </div>
      {items.map(item => (
        <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3 text-sm">
          <div>
            <p>
              {item.name} · {t(`pod.automation.status_${item.status}`)}
            </p>
            <p className="text-muted-foreground">
              {t('pod.automation.next_run')}:{' '}
              {item.next_fire_at ? formatDateTime(item.next_fire_at, undefined, 'medium') : '—'}
            </p>
            <Button size="sm" variant="link" onClick={() => setHistory(history === item.id ? undefined : item.id)}>
              {t('pod.automation.trigger_history')}
            </Button>
          </div>
          {active && (
            <div className="flex flex-wrap gap-2">
              <Button size="sm" variant="ghost" disabled={item.status === 'completed'} onClick={() => setEditing(item)}>
                {t('common.edit')}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={busy || item.status === 'completed'}
                onClick={() => change(() => sources.schedules[item.status === 'active' ? 'pause' : 'resume'](item.id))}>
                {t(item.status === 'active' ? 'pod.automation.pause' : 'pod.automation.resume')}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={busy || item.status === 'completed'}
                onClick={() => change(() => sources.schedules.run(item.id, crypto.randomUUID()))}>
                {t('pod.automation.run_now')}
              </Button>
              <Button
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => change(() => sources.schedules.delete(item.id))}>
                {t('common.delete')}
              </Button>
            </div>
          )}
        </div>
      ))}
      {history && <ScheduleHistory id={history} sources={sources} onRun={onRun} />}
      {editing !== undefined && (
        <div className="rounded-lg border p-4">
          <ScheduleForm
            key={editing?.id ?? 'new'}
            schedule={editing}
            busy={busy}
            onSave={input =>
              change(async () => {
                await sources.schedules.put(input)
                setEditing(undefined)
              })
            }
          />
          <Button variant="ghost" className="mt-2" onClick={() => setEditing(undefined)}>
            {t('common.cancel')}
          </Button>
        </div>
      )}
    </section>
  )
}

function ScheduleForm({
  schedule,
  busy,
  onSave
}: {
  schedule: JobSchedule | null
  busy: boolean
  onSave(input: Parameters<Sources['schedules']['put']>[0]): void
}) {
  const { t } = useTranslation()
  const [kind, setKind] = useState(schedule?.schedule.kind === 'cron' ? 'cron' : 'every')
  const [expression, setExpression] = useState(String(schedule?.schedule.expression ?? '0 9 * * *'))
  const [error, setError] = useState<unknown>()
  return (
    <Form
      busy={busy}
      submit={t('common.save')}
      onSubmit={data => {
        try {
          const payload = object(data, 'payload')
          const timezone = String(data.get('timezone'))
          const definition =
            kind === 'every'
              ? {
                  kind,
                  every_ms: Number(data.get('minutes')) * 60000,
                  anchor_at: schedule?.schedule.anchor_at ?? new Date().toISOString()
                }
              : { kind, expression }
          setError(undefined)
          onSave({
            id: schedule?.id,
            name: String(data.get('name')),
            timezone,
            payload,
            schedule: { ...(schedule?.schedule.kind === kind ? schedule.schedule : {}), ...definition, timezone }
          })
        } catch (error) {
          setError(error)
        }
      }}>
      <ContentError error={error} />
      <Field name="name" label={t('pod.automation.name')} value={schedule?.name} />
      <Choice
        label={t('pod.automation.recurrence')}
        value={kind}
        onChange={setKind}
        options={{ every: t('pod.automation.interval'), cron: t('pod.automation.cron') }}
      />
      {kind === 'every' ? (
        <Field
          name="minutes"
          label={t('pod.automation.minutes')}
          type="number"
          value={String(Number(schedule?.schedule.every_ms ?? 3600000) / 60000)}
        />
      ) : (
        <CronEditor value={expression} onChange={setExpression} disabled={busy} labels={cronEditorLabels(t)} />
      )}
      <Field
        name="timezone"
        label={t('pod.automation.timezone')}
        value={schedule?.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone}
      />
      <Field name="payload" label={t('pod.automation.payload')} value={json(schedule?.payload ?? {})} multiline />
    </Form>
  )
}

function ScheduleHistory({ id, sources, onRun }: { id: string; sources: Sources; onRun(id: number): void }) {
  const { t } = useTranslation()
  const history = useQuery({
    queryKey: [...contentKeys.all, 'schedule-history', id],
    queryFn: () => sources.schedules.runs(id),
    refetchInterval: 2000
  })
  return (
    <div className="grid gap-2 rounded-lg border p-3 text-sm">
      <ContentError error={history.error} />
      {history.data?.events.map(event => (
        <p key={event.id}>
          {event.cron_fire_slot_at ? formatDateTime(event.cron_fire_slot_at, undefined, 'medium') : `#${event.id}`} ·{' '}
          {t(`pod.automation.status_${event.status}`)}
          {Object.keys(event.last_fire_error).length > 0 && <span> · {json(event.last_fire_error)}</span>}
        </p>
      ))}
      <Deliveries items={history.data?.deliveries ?? []} onRun={onRun} />
    </div>
  )
}

function Deliveries({ items, onRun }: { items: JobDelivery[]; onRun(id: number): void }) {
  const { t } = useTranslation()
  return (
    <details className="text-sm">
      <summary className="cursor-pointer">
        {t('pod.automation.deliveries')} ({items.length})
      </summary>
      {items.map((item, index) => (
        <p key={index} className="mt-2 break-all">
          {formatDateTime(item.received_at, undefined, 'medium')} ·{' '}
          {item.automation_job_run_id ? (
            <Button size="sm" variant="link" onClick={() => onRun(item.automation_job_run_id!)}>
              #{item.automation_job_run_id}
            </Button>
          ) : (
            '—'
          )}{' '}
          · {t(`pod.automation.status_${item.run_status ?? 'queued'}`)}
          {item.coalesced && ` · ${t('pod.automation.coalesced')}`}
        </p>
      ))}
    </details>
  )
}

function Webhooks({
  items,
  sources,
  active,
  busy,
  change,
  onRun
}: Controls & { items: Array<{ endpoint: JobWebhook; deliveries: JobDelivery[] }> }) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<JobWebhook | null | undefined>()
  const [callback, setCallback] = useState('')
  const [copied, setCopied] = useState(false)
  return (
    <section className="grid gap-3" aria-label={t('pod.automation.webhooks')}>
      <div className="flex items-center justify-between gap-3">
        <h3 className="font-medium">{t('pod.automation.webhooks')}</h3>
        {active && (
          <Button size="sm" variant="outline" onClick={() => setEditing(null)}>
            {t('pod.automation.add_webhook')}
          </Button>
        )}
      </div>
      {!!callback && (
        <div className="grid gap-2 rounded-lg border p-3 text-sm">
          <p>{t('pod.automation.callback_help')}</p>
          <Input
            aria-label={t('pod.automation.callback')}
            readOnly
            value={callback}
            onFocus={event => event.target.select()}
          />
          <Button
            size="sm"
            variant="outline"
            className="justify-self-start"
            onClick={() =>
              change(async () => {
                await navigator.clipboard.writeText(callback)
                setCopied(true)
              })
            }>
            {t(copied ? 'pod.automation.copied' : 'common.copy')}
          </Button>
        </div>
      )}
      {items.map(({ endpoint: item, deliveries }) => (
        <div key={item.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3 text-sm">
          <div>
            <p>
              {item.label} · {t(`pod.automation.status_${item.status}`)}
            </p>
            <p className="text-muted-foreground">
              {t('pod.automation.expires')}: {formatDateTime(item.expires_at, undefined, 'medium')}
            </p>
            <Deliveries items={deliveries} onRun={onRun} />
          </div>
          {active && ['active', 'armed', 'paused'].includes(item.status) && (
            <div className="flex flex-wrap gap-2">
              <Button size="sm" variant="ghost" onClick={() => setEditing(item)}>
                {t('common.edit')}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() => change(() => sources.webhooks[item.status === 'paused' ? 'resume' : 'pause'](item.id))}>
                {t(item.status === 'paused' ? 'pod.automation.resume' : 'pod.automation.pause')}
              </Button>
              <Button
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => change(() => sources.webhooks.cancel(item.id))}>
                {t('pod.automation.revoke')}
              </Button>
            </div>
          )}
        </div>
      ))}
      {editing !== undefined && (
        <div className="rounded-lg border p-4">
          <WebhookForm
            key={editing?.id ?? 'new'}
            endpoint={editing}
            busy={busy}
            onSave={input =>
              change(async () => {
                if (editing) {
                  await sources.webhooks.update(editing.id, { label: input.label, expires_at: input.expires_at })
                } else {
                  const result = await sources.webhooks.create(input)
                  setCallback(new URL(result.callback_path, window.location.origin).href)
                  setCopied(false)
                }
                setEditing(undefined)
              })
            }
          />
          <Button className="mt-2" variant="ghost" onClick={() => setEditing(undefined)}>
            {t('common.cancel')}
          </Button>
        </div>
      )}
    </section>
  )
}

function WebhookForm({
  endpoint,
  busy,
  onSave
}: {
  endpoint: JobWebhook | null
  busy: boolean
  onSave(input: Parameters<Sources['webhooks']['create']>[0]): void
}) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<'standing' | 'one_shot'>(endpoint?.mode ?? 'standing')
  const [format, setFormat] = useState<'raw' | 'cloudevents'>(endpoint?.event_format ?? 'raw')
  const expires = new Date(endpoint?.expires_at ?? Date.now() + 30 * 86400000)
  const local = dateTimeLocalValue(expires.toISOString()).slice(0, 16)
  return (
    <Form
      busy={busy}
      submit={t('common.save')}
      onSubmit={data =>
        onSave({
          label: String(data.get('label')),
          expires_at: new Date(String(data.get('expires'))).toISOString(),
          mode,
          event_format: format
        })
      }>
      <Field name="label" label={t('pod.automation.name')} value={endpoint?.label} />
      <Field name="expires" label={t('pod.automation.expires')} type="datetime-local" value={local} />
      {!endpoint && (
        <>
          <Choice
            label={t('pod.automation.mode')}
            value={mode}
            onChange={setMode}
            options={{ standing: t('pod.automation.standing'), one_shot: t('pod.automation.one_shot') }}
          />
          <Choice
            label={t('pod.automation.format')}
            value={format}
            onChange={setFormat}
            options={{ raw: t('pod.automation.raw'), cloudevents: 'CloudEvents' }}
          />
        </>
      )}
    </Form>
  )
}

function ConnectorEvents({
  job,
  pageID,
  busy,
  change
}: {
  job: AppletJob
  pageID: string
  busy: boolean
  change: Change
}) {
  const { t } = useTranslation()
  const key = [...contentKeys.page(pageID), 'automation', 'connectors']
  const catalog = useQuery({ queryKey: [...key, 'catalog'], queryFn: () => api.podConnectorsCatalog() })
  const triggers = useQuery({
    queryKey: [...key, 'triggers'],
    queryFn: () => api.podConnectorTriggersList(),
    refetchInterval: 5000
  })
  const connections = useQuery({
    queryKey: [...key, 'connections'],
    queryFn: () => api.podConnectorAuthConfigsList(),
    refetchInterval: 5000
  })
  const [selected, setSelected] = useState(() => {
    const params = new URLSearchParams(window.location.search)
    return automationJobID(params) === job.id ? (params.get('connector_source') ?? '') : ''
  })
  const [eventType, setEventType] = useState('')
  const visibleConnections = connections.data?.connections ?? []
  const origins = (triggers.data?.triggers ?? []).flatMap(item => {
    const connection = visibleConnections.find(value => value.id === item.auth_config_id)
    const definition = catalog.data?.connectors
      ?.find(value => value.plugin_id === connection?.plugin_id)
      ?.trigger_types?.find(value => value.id === item.trigger_type)
    return connection && item.status !== 'deleting'
      ? [
          {
            reference: item.config_ref,
            label: `${connection.display_name} · ${definition?.label ?? item.trigger_type} · ${item.scope_key}`,
            connectionStatus: connection.status,
            status: item.status,
            subscription: true,
            eventTypes: [] as string[],
            lastError: item.last_error,
            manageURL: connectorReturnTo({
              connection: connection.slug,
              trigger: { type: item.trigger_type, scope: item.scope_key, id: item.id },
              automation: { pageID, jobID: job.id }
            })
          }
        ]
      : []
  })
  if (catalog.data?.can_manage) {
    for (const connection of visibleConnections) {
      const declaration = catalog.data.connectors?.find(item => item.id === connection.plugin_id)
      for (const stream of declaration?.event_streams ?? []) {
        origins.push({
          reference: `connector://${connection.id}/${stream.id}`,
          label: `${connection.display_name} · ${stream.label}`,
          connectionStatus: connection.status,
          status: connection.status,
          subscription: false,
          eventTypes: stream.event_types,
          lastError: null,
          manageURL: connectorReturnTo({ connection: connection.slug, automation: { pageID, jobID: job.id } })
        })
      }
    }
  }
  const choices = origins.filter(item => item.connectionStatus === 'active')
  const source = selected ? choices.find(item => item.reference === selected) : choices[0]
  const selectedType = source?.eventTypes.includes(eventType) ? eventType : ''
  const filter = selectedType ? `signal.type == ${JSON.stringify(selectedType)}` : undefined
  const bindings = useQuery({
    queryKey: [...key, 'bindings', job.id],
    queryFn: () => api.podEventBindings({ query: { job_id: job.id } })
  })
  const binding = bindings.data?.bindings.find(
    item =>
      item.config_ref === source?.reference &&
      Object.keys(item.filters).length === (filter ? 1 : 0) &&
      item.filters.cel === filter
  )
  const connected = binding?.enabled === true
  const linked = (bindings.data?.bindings ?? []).flatMap(item => {
    const origin = origins.find(origin => origin.reference === item.config_ref)
    return item.enabled && origin ? [{ binding: item, source: origin }] : []
  })
  return (
    <section className="grid gap-3" aria-label={t('pod.automation.connector_events')}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-medium">{t('pod.automation.connector_events')}</h3>
        <Link
          className="text-sm underline underline-offset-4"
          to={connectorReturnTo({ automation: { pageID, jobID: job.id } })}>
          {t('pod.automation.open_connectors')}
        </Link>
      </div>
      <ContentError error={catalog.error ?? triggers.error ?? connections.error ?? bindings.error} />
      {!!linked.length && (
        <div className="grid gap-2" aria-label={t('pod.automation.linked_events')}>
          <h4 className="text-sm font-medium">{t('pod.automation.linked_events')}</h4>
          {linked.map(({ binding: item, source: origin }) => (
            <div
              key={item.id}
              className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3 text-sm">
              <div className="min-w-0 flex-1 break-words">
                <p>{origin.label}</p>
                <p className="text-muted-foreground">
                  {Object.keys(item.filters).length === 0
                    ? t('pod.automation.any_event')
                    : (origin.eventTypes.find(type => item.filters.cel === `signal.type == ${JSON.stringify(type)}`) ??
                      json(item.filters))}
                </p>
                <p className="text-muted-foreground">
                  {t('pod.automation.connection_status')}:{' '}
                  {t(`pod.connectors.status.${origin.connectionStatus}`, { defaultValue: origin.connectionStatus })}
                  {origin.subscription && (
                    <>
                      {' · '}
                      {t('pod.automation.subscription_status')}:{' '}
                      {t(`pod.connectors.status.${origin.status}`, { defaultValue: origin.status })}
                    </>
                  )}
                </p>
                {origin.lastError && (
                  <p className="text-destructive [overflow-wrap:anywhere]">
                    {connectorFailureMessage(origin.lastError)}
                  </p>
                )}
                <Link className="underline underline-offset-4" to={origin.manageURL}>
                  {t('pod.automation.manage_event_source')}
                </Link>
                {origin.connectionStatus === 'active' &&
                  (origin.status === 'active' || ['provisioning', 'paused'].includes(origin.status)) && (
                    <p className="text-muted-foreground">
                      {t(
                        origin.status === 'active' ? 'pod.automation.event_connected' : 'pod.automation.event_waiting'
                      )}
                    </p>
                  )}
              </div>
              <Button
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() =>
                  change(async () => {
                    await api.podEventBindingPut({
                      body: {
                        data: {
                          id: item.id,
                          name: item.name,
                          config_ref: item.config_ref,
                          automation_job_id: job.id,
                          enabled: false,
                          filters: item.filters,
                          watched_field_ids: item.watched_field_ids
                        }
                      }
                    })
                  })
                }>
                {t('pod.automation.disconnect_event')}
              </Button>
            </div>
          ))}
        </div>
      )}
      {!!choices.length && (
        <Choice
          label={t('pod.automation.event_source')}
          value={source?.reference ?? ''}
          onChange={value => {
            setSelected(value)
            setEventType('')
          }}
          options={Object.fromEntries(choices.map(item => [item.reference, item.label]))}
        />
      )}
      {source ? (
        <>
          {!!source.eventTypes.length && (
            <Choice
              label={t('pod.automation.event_type')}
              value={selectedType || 'all'}
              onChange={value => setEventType(value === 'all' ? '' : value)}
              options={{
                all: t('pod.automation.any_event'),
                ...Object.fromEntries(source.eventTypes.map(type => [type, type]))
              }}
            />
          )}
          <p className="text-sm text-muted-foreground">
            {t(source.subscription ? 'pod.automation.subscription_status' : 'pod.automation.connection_status')}:{' '}
            {t(`pod.connectors.status.${source.status}`, { defaultValue: source.status })}
          </p>
          {!connected && source.lastError && (
            <p className="text-sm text-destructive [overflow-wrap:anywhere]">
              {connectorFailureMessage(source.lastError)}{' '}
              <Link className="underline underline-offset-4" to={source.manageURL}>
                {t('pod.automation.manage_event_source')}
              </Link>
            </p>
          )}
          {!connected && <p className="text-sm text-muted-foreground">{t('pod.automation.event_disconnected')}</p>}
          <Button
            className="justify-self-start"
            variant="outline"
            disabled={busy || connected || bindings.isPending || !!bindings.error}
            onClick={() =>
              change(async () => {
                await api.podEventBindingPut({
                  body: {
                    data: {
                      id: binding?.id,
                      config_ref: source.reference,
                      automation_job_id: job.id,
                      enabled: true,
                      filters: filter ? { cel: filter } : {}
                    }
                  }
                })
              })
            }>
            {t(connected ? 'pod.automation.event_already_connected' : 'pod.automation.connect_event')}
          </Button>
        </>
      ) : (
        !triggers.isPending &&
        !connections.isPending && (
          <p className="text-sm text-muted-foreground">
            {t(selected ? 'pod.automation.return_source_unavailable' : 'pod.automation.no_events')}
          </p>
        )
      )}
    </section>
  )
}

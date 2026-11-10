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
  Textarea
} from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { createPodRunnerJob } from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { runnerDevicesQuery } from '../runner-devices'

export function RunnerJobDialog({
  conversationID,
  agentUID,
  onCreated
}: {
  conversationID: string
  agentUID: string
  onCreated: (id: number) => void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [runnerID, setRunnerID] = useState('')
  const [title, setTitle] = useState('')
  const [task, setTask] = useState('')
  const [requestID, setRequestID] = useState(uuidV4)
  const devices = useQuery(runnerDevicesQuery())
  const eligible = devices.data?.devices.filter(
    device => device.status !== 'pairing' && device.bindings.some(binding => binding.agentUID === agentUID)
  )
  const job = useMutation({
    mutationFn: () =>
      createPodRunnerJob({
        path: { id: conversationID },
        body: { data: { runnerID, agentUID, title, task, requestID } }
      }),
    onSuccess: result => {
      setOpen(false)
      setTitle('')
      setTask('')
      setRequestID(uuidV4())
      onCreated(result.jobID)
    }
  })

  if (!eligible?.length) return null

  return (
    <Dialog
      open={open}
      onOpenChange={value => {
        if (!job.isPending) setOpen(value)
      }}>
      <div>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(true)}>
          {t('pod.runner.run_on_device')}
        </Button>
      </div>
      <DialogContent>
        <DialogTitle>{t('pod.runner.run_on_device')}</DialogTitle>
        <DialogDescription>{t('pod.runner.job_description')}</DialogDescription>
        <form
          className="grid gap-3"
          onSubmit={event => {
            event.preventDefault()
            if (runnerID && title.trim() && task.trim()) job.mutate()
          }}>
          <ContentError error={job.error} />
          <Label htmlFor="runner-job-device">{t('pod.runner.device_name')}</Label>
          <select
            id="runner-job-device"
            className="min-h-9 rounded-md border border-input bg-background px-2 text-sm"
            required
            value={runnerID}
            onChange={event => setRunnerID(event.target.value)}>
            <option value="">{t('pod.runner.choose_device')}</option>
            {eligible.map(device => (
              <option key={device.id} value={device.id}>
                {device.name} · {t(`pod.runner.status_${device.status}`)}
              </option>
            ))}
          </select>
          <Label htmlFor="runner-job-title">{t('pod.runner.job_title')}</Label>
          <Input
            id="runner-job-title"
            required
            maxLength={200}
            value={title}
            onChange={event => setTitle(event.target.value)}
          />
          <Label htmlFor="runner-job-task">{t('pod.runner.job_task')}</Label>
          <Textarea
            id="runner-job-task"
            required
            maxLength={20_000}
            value={task}
            onChange={event => setTask(event.target.value)}
          />
          <DialogFooter>
            <Button type="submit" disabled={job.isPending || !runnerID || !title.trim() || !task.trim()}>
              {t('pod.runner.start_job')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

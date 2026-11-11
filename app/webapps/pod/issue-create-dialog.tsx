import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Textarea
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { agentsQuery, podKeys } from './api'
import { createPodIssue, ensurePodPersonalAssistant } from './api/generated/sdk.gen'
import { Choice, ContentError } from './content-primitives'
import { workKeys, type WorkItem } from './work-api'

// The personal assistant exists only after its owner first uses it, so the form names it before it has a uid.
const ASSISTANT = 'assistant'

/** Creates an Issue for an Agent. The Agent starts at once unless the creator chooses to start later. */
export function IssueCreateDialog({
  open,
  onOpenChange,
  onCreated
}: {
  open: boolean
  onOpenChange(open: boolean): void
  onCreated(item: WorkItem): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const formID = useId()
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const options: Record<string, string> = {
    ...(agents.data?.personalAssistantAvailable
      ? { [ASSISTANT]: agents.data.personalAssistant?.displayName || t('pod.chat.personal_assistant') }
      : {}),
    ...Object.fromEntries((agents.data?.agents ?? []).map(agent => [agent.uid, agent.displayName]))
  }
  const first = Object.keys(options)[0] ?? ''
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [agent, setAgent] = useState('')
  const [start, setStart] = useState<'now' | 'later'>('now')
  useEffect(() => {
    if (!open) return
    setTitle('')
    setDescription('')
    setAgent('')
    setStart('now')
  }, [open])
  const chosen = agent in options ? agent : first
  const create = useMutation({
    mutationFn: async () => {
      const agentUID = chosen === ASSISTANT ? (await ensurePodPersonalAssistant()).uid : chosen
      return createPodIssue({
        body: { data: { title: title.trim(), description, agentUID, start: start === 'now' } }
      })
    },
    onSuccess: item => {
      void client.invalidateQueries({ queryKey: workKeys.all })
      void client.invalidateQueries({ queryKey: podKeys.agents })
      onOpenChange(false)
      onCreated(item)
    }
  })
  const ready = !!title.trim() && !!chosen && !create.isPending
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogTitle>{t('pod.work.new_issue')}</DialogTitle>
        <DialogDescription>{t('pod.work.new_issue_hint')}</DialogDescription>
        <form
          id={formID}
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            if (ready) create.mutate()
          }}>
          <label className="grid gap-1.5 text-sm">
            {t('pod.work.title_label')}
            <Input value={title} maxLength={200} autoFocus onChange={event => setTitle(event.target.value)} />
          </label>
          <label className="grid gap-1.5 text-sm">
            {t('pod.work.description')}
            <Textarea
              value={description}
              rows={4}
              placeholder={t('pod.work.description_placeholder')}
              onChange={event => setDescription(event.target.value)}
            />
          </label>
          <div className="flex flex-wrap gap-2">
            {chosen ? (
              <Choice label={t('pod.work.agent_label')} value={chosen} onChange={setAgent} options={options} />
            ) : (
              agents.isSuccess && <p className="text-sm text-fg-secondary">{t('pod.work.no_agent')}</p>
            )}
            <Choice<'now' | 'later'>
              label={t('pod.work.start_label')}
              value={start}
              onChange={setStart}
              options={{ now: t('pod.work.start_now'), later: t('pod.work.start_later') }}
            />
          </div>
        </form>
        <ContentError error={create.error || agents.error} />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={create.isPending}>
            {t('common.cancel')}
          </Button>
          <Button type="submit" form={formID} disabled={!ready}>
            {t('pod.work.create_issue')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

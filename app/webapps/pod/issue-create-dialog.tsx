import {
  Button,
  Checkbox,
  CronEditor,
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
import { cronEditorLabels } from '../common/cron-editor-labels'
import { agentsQuery, podKeys } from './api'
import { createPodIssue, ensurePodPersonalAssistant } from './api/generated/sdk.gen'
import { Choice, ContentError } from './content-primitives'
import { workKeys, type WorkItem } from './work-api'

// The personal assistant exists only after its owner first uses it, so the form names it before it has a uid.
const ASSISTANT = 'assistant'

/** Splits typed labels on commas, the way people list them. */
export function parseLabels(text: string) {
  return [
    ...new Set(
      text
        .split(/[,，、]/)
        .map(label => label.trim())
        .filter(Boolean)
    )
  ]
}

/**
 * Creates an Issue for an Agent. The Agent starts at once unless the creator chooses to start later. An Issue can
 * repeat on a schedule, belong to a parent Issue, carry labels, and name the Squad of colleagues among whom a
 * personal assistant shares the work.
 */
export function IssueCreateDialog({
  open,
  onOpenChange,
  onCreated,
  parent
}: {
  open: boolean
  onOpenChange(open: boolean): void
  onCreated(item: WorkItem): void
  parent?: { id: string; title: string }
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
  const colleagues = (agents.data?.agents ?? []).filter(agent => agent.agentType === 'ai_colleague')
  const first = Object.keys(options)[0] ?? ''
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [agent, setAgent] = useState('')
  const [start, setStart] = useState<'now' | 'later'>('now')
  const [labels, setLabels] = useState('')
  const [squad, setSquad] = useState<string[]>([])
  const [repeat, setRepeat] = useState<'none' | 'on'>('none')
  const [expression, setExpression] = useState('0 9 * * 1')
  useEffect(() => {
    if (!open) return
    setTitle('')
    setDescription('')
    setAgent('')
    setStart('now')
    setLabels('')
    setSquad([])
    setRepeat('none')
    setExpression('0 9 * * 1')
  }, [open])
  const chosen = agent in options ? agent : first
  const assistant = chosen === ASSISTANT || chosen === agents.data?.personalAssistant?.uid
  const create = useMutation({
    mutationFn: async () => {
      const agentUID = chosen === ASSISTANT ? (await ensurePodPersonalAssistant()).uid : chosen
      return createPodIssue({
        body: {
          data: {
            title: title.trim(),
            description,
            agentUID,
            start: start === 'now',
            labels: parseLabels(labels),
            ...(parent ? { parentID: parent.id } : {}),
            ...(assistant && squad.length ? { squadUIDs: squad } : {}),
            ...(repeat === 'on'
              ? { repeat: { expression, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone } }
              : {})
          }
        }
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
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogTitle>{t(parent ? 'pod.work.new_sub_issue' : 'pod.work.new_issue')}</DialogTitle>
        <DialogDescription>
          {repeat === 'on' ? t('pod.work.repeat_hint') : t('pod.work.new_issue_hint')}
        </DialogDescription>
        <form
          id={formID}
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            if (ready) create.mutate()
          }}>
          {parent && <p className="text-sm text-fg-secondary">{t('pod.work.parent_label', { title: parent.title })}</p>}
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
          <label className="grid gap-1.5 text-sm">
            {t('pod.work.labels')}
            <Input
              value={labels}
              placeholder={t('pod.work.labels_placeholder')}
              onChange={event => setLabels(event.target.value)}
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
            <Choice<'none' | 'on'>
              label={t('pod.work.repeat_label')}
              value={repeat}
              onChange={setRepeat}
              options={{ none: t('pod.work.repeat.none'), on: t('pod.work.repeat.on') }}
            />
          </div>
          {repeat === 'on' && <CronEditor value={expression} onChange={setExpression} labels={cronEditorLabels(t)} />}
          {assistant && colleagues.length > 0 && (
            <fieldset className="grid gap-1.5 text-sm">
              <legend className="mb-1.5">{t('pod.work.squad')}</legend>
              <p className="text-xs text-fg-secondary">{t('pod.work.squad_hint')}</p>
              <div className="flex flex-wrap gap-x-4 gap-y-1.5">
                {colleagues.map(colleague => (
                  <label key={colleague.uid} className="flex items-center gap-2">
                    <Checkbox
                      checked={squad.includes(colleague.uid)}
                      onCheckedChange={checked =>
                        setSquad(current =>
                          checked ? [...current, colleague.uid] : current.filter(uid => uid !== colleague.uid)
                        )
                      }
                    />
                    <span className="truncate">{colleague.displayName}</span>
                  </label>
                ))}
              </div>
            </fieldset>
          )}
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

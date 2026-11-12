import { agentLabel } from './conversation-row'
import { MemberOptions, type MemberCandidate } from './member-options'
import {
  Button,
  Checkbox,
  Command,
  CommandEmpty,
  CommandInput,
  CommandList,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Textarea
} from '@ankole/uikit'
import { uuidV4 } from '@agentbull/active-support'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useEffect, useEffectEvent, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation, podPublicOrigin } from '../../common/browser-context'
import { usePageHref } from '../use-page-metadata'
import { useDebouncedValue } from '../../common/use-debounced-value'
import { agentsQuery, podKeys, type ConversationDetail } from '../api'
import { createConversation, podChatTeammates, updateConversation } from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { ChatAvatar } from './chat-avatar'
import { teammatesKey } from './room-api'

type Member = MemberCandidate

/**
 * Starts a group from an assistant task or a colleague DM. The source conversation stays as it is: an assistant
 * task stays private and a DM keeps its pair, so the group begins with the people the user picks, a name, and
 * a first message. Pages that the source conversation referenced are offered in the first message.
 */
export function NewGroupDialog({
  detail,
  open,
  onOpenChange
}: {
  detail: ConversationDetail
  open: boolean
  onOpenChange(open: boolean): void
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const room = detail.conversation
  const fromTask = room.conversationKind === 'assistant_task'
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  const navigate = useNavigate()
  const client = useQueryClient()
  const formID = useId()
  // The source conversation's other members start checked; the viewer and the personal assistant are not choices.
  const initial = (): Member[] =>
    room.participants
      .filter(member => member.uid !== room.viewer.uid && member.agentType !== 'personal_assistant')
      .map(member => ({
        uid: member.uid,
        displayName: member.displayName,
        avatarURL: member.avatarURL,
        agent: member.type === 'agent'
      }))
  const pageLinks = [
    ...new Set([
      ...detail.artifacts.pageIDs,
      ...detail.pendingQueues.flatMap(queue =>
        queue.inputs.flatMap(input => input.links.filter(link => link.kind === 'page').map(link => link.id))
      )
    ])
  ].map(id => ({ id, url: new URL(pageHref(id), podPublicOrigin()).href }))
  const [name, setName] = useState('')
  const [message, setMessage] = useState('')
  const [candidates, setCandidates] = useState<Member[]>([])
  const [checked, setChecked] = useState<Set<string>>(new Set())
  const [query, setQuery] = useState('')
  const search = useDebouncedValue(query, 180)
  const reset = useEffectEvent(() => {
    const members = initial()
    setName(fromTask ? room.title : colleague ? colleague.displayName : '')
    setMessage(pageLinks.map(link => link.url).join('\n'))
    setCandidates(members)
    setChecked(new Set(members.map(member => member.uid)))
    setQuery('')
  })
  useEffect(() => {
    if (open) reset()
  }, [open])
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const people = useQuery({
    queryKey: [...teammatesKey(), search],
    queryFn: ({ signal }) => podChatTeammates({ query: { query: search }, signal }),
    enabled: open
  })
  const known = new Set(candidates.map(member => member.uid))
  const needle = query.trim().replace(/^@/, '').toLocaleLowerCase()
  const morePeople = (query === search ? (people.data?.teammates ?? []) : []).filter(
    person => person.uid !== room.viewer.uid && !known.has(person.uid)
  )
  const moreAgents = (agents.data?.agents ?? []).filter(
    agent =>
      !known.has(agent.uid) &&
      `${agent.uid} ${agent.displayName} ${agent.role ?? ''}`.toLocaleLowerCase().includes(needle)
  )
  const add = (member: Member) => {
    setCandidates(current => [...current, member])
    setChecked(current => new Set([...current, member.uid]))
    setQuery('')
  }
  const members = candidates.filter(member => checked.has(member.uid))
  const missing = !members.length
    ? 'pod.superagent.group_needs_member'
    : !message.trim()
      ? 'pod.superagent.group_needs_message'
      : undefined
  const create = useMutation({
    mutationFn: async () => {
      const created = await createConversation({
        body: {
          data: {
            conversationID: uuidV4(),
            messageID: uuidV4(),
            roomMode: 'group',
            text: message.trim(),
            agentUIDs: members.filter(member => member.agent).map(member => member.uid),
            participantUIDs: members.filter(member => !member.agent).map(member => member.uid),
            links: pageLinks.filter(link => message.includes(link.url)).map(link => ({ kind: 'page', id: link.id }))
          }
        }
      })
      const title = name.trim()
      if (title && title !== created.conversation.title) {
        await updateConversation({ path: { id: created.conversation.id }, body: { data: { title } } })
      }
      return created
    },
    onSuccess: created => {
      void client.invalidateQueries({ queryKey: podKeys.conversations })
      onOpenChange(false)
      void navigate({ to: podLocation(`/conversations/${created.conversation.id}`).pathname })
    }
  })
  return (
    <Dialog open={open} onOpenChange={next => !create.isPending && onOpenChange(next)}>
      <DialogContent className="pod-chat-share" closeLabel={t('common.close')}>
        <DialogTitle>{t(fromTask ? 'pod.superagent.convert_to_group' : 'pod.superagent.new_group')}</DialogTitle>
        <DialogDescription>
          {fromTask
            ? t('pod.superagent.convert_to_group_hint')
            : t('pod.superagent.new_group_hint', { name: colleague ? agentLabel(colleague) : room.title })}
        </DialogDescription>
        <form
          id={formID}
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            if (!missing && !create.isPending) create.mutate()
          }}>
          <label className="grid gap-1.5 text-sm">
            {t('pod.superagent.group_name')}
            <Input value={name} onChange={event => setName(event.target.value)} />
          </label>
          <fieldset className="grid gap-1.5">
            <legend className="mb-1.5 text-sm">{t('pod.superagent.group_members')}</legend>
            <div className="pod-chat-member">
              <ChatAvatar name={t('pod.chat_timeline.you')} />
              <span>{t('pod.chat_timeline.you')}</span>
            </div>
            {candidates.map(member => (
              <label key={member.uid} className="pod-chat-member cursor-pointer">
                <ChatAvatar name={member.displayName} src={member.avatarURL} agent={member.agent} />
                <span>{member.displayName}</span>
                <Checkbox
                  checked={checked.has(member.uid)}
                  onCheckedChange={value =>
                    setChecked(current => {
                      const next = new Set(current)
                      if (value) next.add(member.uid)
                      else next.delete(member.uid)
                      return next
                    })
                  }
                />
              </label>
            ))}
            <Command shouldFilter={false} className="mt-1">
              <CommandInput
                aria-label={t('pod.chat_room.search_people_agents')}
                value={query}
                onValueChange={setQuery}
                placeholder={t('pod.superagent.add_members')}
              />
              {!!query.trim() && (
                <CommandList>
                  <CommandEmpty>
                    {t(query !== search || people.isPending ? 'pod.content.loading' : 'pod.chat_room.no_matches')}
                  </CommandEmpty>
                  <MemberOptions people={morePeople} agents={moreAgents} onSelect={add} />
                </CommandList>
              )}
            </Command>
          </fieldset>
          <label className="grid gap-1.5 text-sm">
            {t('pod.superagent.group_message')}
            <Textarea
              value={message}
              rows={3}
              placeholder={t('pod.superagent.group_message_placeholder')}
              onChange={event => setMessage(event.target.value)}
            />
          </label>
        </form>
        <ContentError error={people.error || agents.error || create.error} />
        <DialogFooter className="items-center">
          {missing && <p className="mr-auto text-xs text-fg-tertiary">{t(missing)}</p>}
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={create.isPending}>
            {t('common.cancel')}
          </Button>
          <Button type="submit" form={formID} disabled={!!missing || create.isPending}>
            {t('pod.superagent.create_group')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

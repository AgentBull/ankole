import {
  Button,
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  Dialog,
  DialogContent,
  DialogTitle,
  Switch
} from '@ankole/uikit'
import { RiCheckLine, RiCloseLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { agentsQuery, type ConversationDetail } from '../api'
import { podChatTeammates } from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { ChatAvatar } from './chat-avatar'
import { teammatesKey, useRoomActions } from './room-api'

export function SharePopover({
  detail,
  open,
  onOpenChange
}: {
  detail: ConversationDetail
  open: boolean
  onOpenChange(open: boolean): void
}) {
  const { t } = useTranslation()
  const room = detail.conversation
  const actions = useRoomActions(room.id)
  const [selected, setSelected] = useState<string[]>([])
  const [query, setQuery] = useState('')
  const search = useDeferredValue(query)
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const people = useQuery({
    queryKey: [...teammatesKey(), search],
    queryFn: () => podChatTeammates({ query: { query: search } }),
    enabled: open
  })
  const existing = new Set(room.participants.map(member => member.uid))
  const canParticipate = room.canManage || existing.has(room.viewer.uid)
  const callable = new Set(agents.data?.agents.map(agent => agent.uid))
  const availablePeople = (people.data?.teammates ?? []).filter(person => !existing.has(person.uid))
  const availableAgents = (agents.data?.agents ?? []).filter(
    agent =>
      !existing.has(agent.uid) && agent.displayName.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase())
  )
  const toggle = (uid: string) =>
    setSelected(current => (current.includes(uid) ? current.filter(id => id !== uid) : [...current, uid]))
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!next) {
          setSelected([])
          setQuery('')
        }
        onOpenChange(next)
      }}>
      <DialogContent className="pod-chat-share" closeLabel={t('common.close')}>
        <DialogTitle>{t('pod.chat_room.invite')}</DialogTitle>
        {canParticipate && (
          <Command shouldFilter={false}>
            <CommandInput
              aria-label={t('pod.chat_room.search_people_agents')}
              value={query}
              onValueChange={setQuery}
              placeholder={t('pod.chat_room.search_people_agents')}
            />
            <CommandList>
              <CommandEmpty>{t('pod.chat_room.no_matches')}</CommandEmpty>
              {!!availablePeople.length && (
                <CommandGroup heading={t('pod.chat_room.people')}>
                  {availablePeople.map(person => (
                    <CommandItem
                      key={person.uid}
                      value={`human ${person.displayName} ${person.uid}`}
                      onSelect={() => toggle(person.uid)}>
                      <ChatAvatar name={person.displayName} src={person.avatarURL} />
                      <span>{person.displayName}</span>
                      {selected.includes(person.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
                    </CommandItem>
                  ))}
                </CommandGroup>
              )}
              {!!availableAgents.length && (
                <CommandGroup heading={t('pod.chat_room.agents')}>
                  {availableAgents.map(agent => (
                    <CommandItem
                      key={agent.uid}
                      value={`agent ${agent.displayName} ${agent.uid}`}
                      onSelect={() => toggle(agent.uid)}>
                      <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
                      <span>{agent.displayName}</span>
                      {selected.includes(agent.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
                    </CommandItem>
                  ))}
                </CommandGroup>
              )}
            </CommandList>
          </Command>
        )}
        <ContentError error={people.error || agents.error || actions.participants.error} />
        {canParticipate && (
          <Button
            disabled={!selected.length || actions.participants.isPending}
            onClick={() => actions.participants.mutate({ addUIDs: selected }, { onSuccess: () => setSelected([]) })}>
            {t('pod.chat_room.invite_selected', { count: selected.length })}
          </Button>
        )}
        <section className="pod-chat-members">
          <h3>{t('pod.chat_room.in_room')}</h3>
          {room.participants.map(member => (
            <div key={member.uid} className="pod-chat-member">
              <ChatAvatar name={member.displayName} src={member.avatarURL} agent={member.type === 'agent'} />
              <span className="min-w-0 flex-1 truncate">{member.displayName}</span>
              {member.type === 'agent' && room.roomMode === 'group' && (
                <Switch
                  aria-label={t('pod.chat_room.intervene_agent', { name: member.displayName })}
                  checked={member.mayIntervene}
                  disabled={actions.participants.isPending || !canParticipate || !callable.has(member.uid)}
                  onCheckedChange={checked =>
                    actions.participants.mutate({ agentUID: member.uid, mayIntervene: checked })
                  }
                />
              )}
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.chat_room.remove_member', { name: member.displayName })}
                disabled={
                  actions.participants.isPending ||
                  member.role === 'owner' ||
                  (!room.canManage && member.uid !== room.viewer.uid) ||
                  (member.type === 'agent' && room.agents.length <= 1)
                }
                onClick={() => actions.participants.mutate({ removeUIDs: [member.uid] })}>
                <RiCloseLine aria-hidden />
              </Button>
            </div>
          ))}
          <p className="pod-chat-subtle">
            {t(room.roomMode === 'group' ? 'pod.chat_room.intervene_hint' : 'pod.chat_room.direct_chat_hint')}
          </p>
        </section>
        {room.pageID && (
          <fieldset className="pod-chat-access">
            <legend>{t('pod.chat_room.visibility')}</legend>
            {(['participants', 'anchor_page'] as const).map(scope => (
              <label key={scope}>
                <input
                  type="radio"
                  name="room-scope"
                  value={scope}
                  checked={room.accessScope === scope}
                  disabled={actions.update.isPending || !room.canManage}
                  onChange={() => actions.update.mutate({ accessScope: scope })}
                />
                {t(`pod.chat_room.scope_${scope}`)}
              </label>
            ))}
          </fieldset>
        )}
      </DialogContent>
    </Dialog>
  )
}

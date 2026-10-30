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
  DialogFooter,
  DialogTitle,
  RadioGroup,
  RadioGroupItem,
  Switch,
  toast
} from '@ankole/uikit'
import { RiCheckLine, RiCloseLine, RiLink } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useDebouncedValue } from '../../common/use-debounced-value'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import { agentsQuery, type ConversationDetail } from '../api'
import { podChatTeammates } from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { ChatAvatar } from './chat-avatar'
import { teammatesKey, useRoomActions } from './room-api'

type SelectedCandidate = {
  uid: string
  displayName: string
  avatarURL?: string | null
  agent: boolean
}

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
  const [selected, setSelected] = useState<SelectedCandidate[]>([])
  const [removingMember, setRemovingMember] = useState<ConversationDetail['conversation']['participants'][number]>()
  const [query, setQuery] = useState('')
  const search = useDebouncedValue(query, 180)
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const people = useQuery({
    queryKey: [...teammatesKey(), search],
    queryFn: ({ signal }) => podChatTeammates({ query: { query: search }, signal }),
    enabled: open
  })
  const existing = new Set(room.participants.map(member => member.uid))
  const canParticipate = room.canManage || existing.has(room.viewer.uid)
  const callable = new Set(agents.data?.agents.map(agent => agent.uid))
  const availablePeople = (query === search ? (people.data?.teammates ?? []) : []).filter(
    person => !existing.has(person.uid)
  )
  const availableAgents = (agents.data?.agents ?? []).filter(
    agent =>
      !existing.has(agent.uid) && agent.displayName.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())
  )
  const activeSelected = selected.filter(candidate => !existing.has(candidate.uid))
  const selectedUIDs = new Set(activeSelected.map(candidate => candidate.uid))
  const toggle = (candidate: SelectedCandidate) =>
    setSelected(current =>
      current.some(item => item.uid === candidate.uid)
        ? current.filter(item => item.uid !== candidate.uid)
        : [...current, candidate]
    )
  return (
    <>
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
          <div className="flex items-center justify-between gap-2 pr-8">
            <DialogTitle>{t(canParticipate ? 'pod.chat_room.invite' : 'pod.chat_room.in_room')}</DialogTitle>
            <Button
              size="xs"
              variant="ghost"
              onClick={() => {
                void navigator.clipboard
                  .writeText(new URL(podLocation(`/conversations/${room.id}`).pathname, window.location.origin).href)
                  .then(
                    () => toast.success(t('pod.chat_room.link_copied')),
                    () => toast.error(t('pod.chat_room.copy_failed'))
                  )
              }}>
              <RiLink aria-hidden />
              {t('pod.chat_room.copy_link')}
            </Button>
          </div>
          {canParticipate && (
            <Command shouldFilter={false}>
              <CommandInput
                aria-label={t('pod.chat_room.search_people_agents')}
                value={query}
                onValueChange={setQuery}
                placeholder={t('pod.chat_room.search_people_agents')}
              />
              <CommandList>
                <CommandEmpty>
                  {t(
                    query !== search || people.isPending || agents.isPending
                      ? 'pod.content.loading'
                      : 'pod.chat_room.no_matches'
                  )}
                </CommandEmpty>
                {!!availablePeople.length && (
                  <CommandGroup heading={t('pod.chat_room.people')}>
                    {availablePeople.map(person => (
                      <CommandItem
                        key={person.uid}
                        value={`human ${person.displayName} ${person.uid}`}
                        onSelect={() =>
                          toggle({
                            uid: person.uid,
                            displayName: person.displayName,
                            avatarURL: person.avatarURL,
                            agent: false
                          })
                        }>
                        <ChatAvatar name={person.displayName} src={person.avatarURL} />
                        <span>{person.displayName}</span>
                        {selectedUIDs.has(person.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
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
                        onSelect={() =>
                          toggle({
                            uid: agent.uid,
                            displayName: agent.displayName,
                            avatarURL: agent.avatarURL,
                            agent: true
                          })
                        }>
                        <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
                        <span>{agent.displayName}</span>
                        {selectedUIDs.has(agent.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
                      </CommandItem>
                    ))}
                  </CommandGroup>
                )}
              </CommandList>
            </Command>
          )}
          <ContentError error={people.error || agents.error || actions.participants.error || actions.update.error} />
          {canParticipate && activeSelected.length > 0 && (
            <div className="grid gap-2">
              <div className="pod-chat-share-selected flex flex-wrap gap-1.5">
                {activeSelected.map(item => (
                  <span
                    key={item.uid}
                    className="inline-flex max-w-full items-center gap-1.5 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs">
                    <ChatAvatar name={item.displayName} src={item.avatarURL} agent={item.agent} />
                    <span className="truncate">{item.displayName}</span>
                    <button
                      type="button"
                      className="text-fg-tertiary hover:text-foreground"
                      aria-label={t('pod.chat_room.remove_member', { name: item.displayName })}
                      onClick={() => setSelected(current => current.filter(entry => entry.uid !== item.uid))}>
                      <RiCloseLine aria-hidden className="size-3.5" />
                    </button>
                  </span>
                ))}
              </div>
              <Button
                disabled={actions.participants.isPending}
                onClick={() =>
                  actions.participants.mutate(
                    { addUIDs: activeSelected.map(item => item.uid) },
                    { onSuccess: () => setSelected([]) }
                  )
                }>
                {t('pod.chat_room.invite_selected', { count: activeSelected.length })}
              </Button>
            </div>
          )}
          <section className="pod-chat-members">
            <h3>{t('pod.chat_room.in_room')}</h3>
            {room.participants.map(member => {
              const showRemove = room.canManage && member.uid !== room.viewer.uid && member.role !== 'owner'
              return (
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
                  {showRemove && (
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      aria-label={t('pod.chat_room.remove_member', { name: member.displayName })}
                      disabled={actions.participants.isPending || (member.type === 'agent' && room.agents.length <= 1)}
                      onClick={() => {
                        if (member.type === 'human') {
                          setRemovingMember(member)
                        } else {
                          actions.participants.mutate({ removeUIDs: [member.uid] })
                        }
                      }}>
                      <RiCloseLine aria-hidden />
                    </Button>
                  )}
                </div>
              )
            })}
            <p className="pod-chat-subtle">
              {t(room.roomMode === 'group' ? 'pod.chat_room.intervene_hint' : 'pod.chat_room.direct_chat_hint')}
            </p>
          </section>
          {room.pageID && (
            <div className="pod-chat-access">
              <p id={`pod-chat-scope-${room.id}`} className="text-xs font-medium text-fg-secondary">
                {t('pod.chat_room.visibility')}
              </p>
              <RadioGroup
                aria-labelledby={`pod-chat-scope-${room.id}`}
                value={room.accessScope}
                disabled={actions.update.isPending || !room.canManage}
                onValueChange={value => {
                  if ((value === 'participants' || value === 'anchor_page') && value !== room.accessScope) {
                    actions.update.mutate({ accessScope: value })
                  }
                }}>
                {(['participants', 'anchor_page'] as const).map(scope => (
                  <label key={scope} className="flex cursor-pointer items-center gap-2 text-xs">
                    <RadioGroupItem value={scope} />
                    <span>{t(`pod.chat_room.scope_${scope}`)}</span>
                  </label>
                ))}
              </RadioGroup>
            </div>
          )}
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!removingMember}
        onOpenChange={next => !next && !actions.participants.isPending && setRemovingMember(undefined)}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.chat_room.remove_member', { name: removingMember?.displayName ?? '' })}</DialogTitle>
          <p className="text-sm">
            {t('pod.chat_room.remove_member_confirm', {
              name: removingMember?.displayName ?? '',
              defaultValue: 'Remove {$name} from this conversation?'
            })}
          </p>
          <DialogFooter>
            <Button
              variant="outline"
              disabled={actions.participants.isPending}
              onClick={() => setRemovingMember(undefined)}>
              {t('common.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={actions.participants.isPending}
              onClick={() =>
                removingMember &&
                actions.participants.mutate(
                  { removeUIDs: [removingMember.uid] },
                  { onSuccess: () => setRemovingMember(undefined) }
                )
              }>
              {t('pod.content.remove')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}

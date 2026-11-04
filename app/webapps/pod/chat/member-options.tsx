import { CommandGroup, CommandItem } from '@ankole/uikit'
import { RiCheckLine } from '@remixicon/react'
import { useTranslation } from 'react-i18next'
import { ChatAvatar } from './chat-avatar'
import { agentLabel } from './conversation-row'

export type MemberCandidate = { uid: string; displayName: string; avatarURL?: string | null; agent: boolean }

/** Both group creation and sharing present the same people and callable Agents. */
export function MemberOptions({
  people,
  agents,
  onSelect,
  selected
}: {
  people: Omit<MemberCandidate, 'agent'>[]
  agents: (Parameters<typeof agentLabel>[0] & { avatarURL?: string | null })[]
  onSelect(member: MemberCandidate): void
  selected?: ReadonlySet<string>
}) {
  const { t } = useTranslation()
  return (
    <>
      {!!people.length && (
        <CommandGroup heading={t('pod.chat_room.people')}>
          {people.map(person => (
            <CommandItem
              key={person.uid}
              value={`human ${person.displayName} ${person.uid}`}
              onSelect={() =>
                onSelect({
                  uid: person.uid,
                  displayName: person.displayName,
                  avatarURL: person.avatarURL,
                  agent: false
                })
              }>
              <ChatAvatar name={person.displayName} src={person.avatarURL} />
              <span>{person.displayName}</span>
              {selected?.has(person.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
            </CommandItem>
          ))}
        </CommandGroup>
      )}
      {!!agents.length && (
        <CommandGroup heading={t('pod.chat_room.agents')}>
          {agents.map(agent => (
            <CommandItem
              key={agent.uid}
              value={`agent ${agent.displayName} ${agent.uid}`}
              onSelect={() =>
                onSelect({ uid: agent.uid, displayName: agent.displayName, avatarURL: agent.avatarURL, agent: true })
              }>
              <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
              <span>{agentLabel(agent)}</span>
              {selected?.has(agent.uid) && <RiCheckLine aria-hidden className="ml-auto size-4" />}
            </CommandItem>
          ))}
        </CommandGroup>
      )}
    </>
  )
}

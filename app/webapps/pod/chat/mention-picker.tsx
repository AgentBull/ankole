import { useQuery } from '@tanstack/react-query'
import type { Ref, RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { agentsQuery, type ConversationDetail } from '../api'
import { podChatTeammates } from '../api/generated/sdk.gen'
import { pageSearchQuery } from '../content-api'
import { ContentError } from '../content-primitives'
import { teammatesKey } from './room-api'
import { ChatAvatar } from './chat-avatar'
import { ComposerCompletionList, type CompletionHandle, type CompletionOption } from './composer-completion'

export type MentionChoice = { type: 'agent' | 'human' | 'page'; uid: string; displayName: string }
export function MentionPicker({
  detail,
  pagesOnly = false,
  allowAgents = true,
  query,
  id,
  input,
  handle,
  onChoose,
  onClose
}: {
  detail?: ConversationDetail
  pagesOnly?: boolean
  allowAgents?: boolean
  query: string
  id: string
  input: RefObject<HTMLTextAreaElement | null>
  handle: Ref<CompletionHandle>
  onChoose(choice: MentionChoice): void
  onClose(): void
}) {
  const { t } = useTranslation()
  const agents = useQuery({ ...agentsQuery, enabled: !pagesOnly && allowAgents })
  const people = useQuery({
    queryKey: [...teammatesKey(), query],
    queryFn: () => podChatTeammates({ query: { query } }),
    enabled: !pagesOnly
  })
  const pages = useQuery(pageSearchQuery(query))
  const inRoom = new Set(detail?.conversation.participants.map(person => person.uid))
  const matches = (name: string) => name.toLocaleLowerCase().includes(query.toLocaleLowerCase())
  const options: CompletionOption[] = [
    ...(!pagesOnly && allowAgents
      ? (agents.data?.agents ?? [])
          .filter(agent => matches(agent.displayName))
          .map(agent => ({
            id: agent.uid,
            group: t('pod.chat_room.agents'),
            content: (
              <>
                <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
                <span>{agent.displayName}</span>
                {detail && !inRoom.has(agent.uid) && (
                  <small className="ml-auto text-fg-tertiary">{t('pod.chat_room.invite_mention')}</small>
                )}
              </>
            ),
            choose: () => onChoose({ type: 'agent', uid: agent.uid, displayName: agent.displayName })
          }))
      : []),
    ...(!pagesOnly
      ? (people.data?.teammates ?? []).map(person => ({
          id: person.uid,
          group: t('pod.chat_room.people'),
          content: (
            <>
              <ChatAvatar name={person.displayName} src={person.avatarURL} />
              <span>{person.displayName}</span>
            </>
          ),
          choose: () => onChoose({ type: 'human', uid: person.uid, displayName: person.displayName })
        }))
      : []),
    ...(pages.data?.pages ?? []).map(page => ({
      id: page.id,
      group: t('pod.chat_room.pages_artifacts'),
      content: <span>{page.title || t('pod.content.untitled')}</span>,
      choose: () => onChoose({ type: 'page', uid: page.id, displayName: page.title || t('pod.content.untitled') })
    }))
  ]
  return (
    <ComposerCompletionList
      id={id}
      query={query}
      options={options}
      input={input}
      handle={handle}
      loading={pages.isFetching || (!pagesOnly && (agents.isFetching || people.isFetching))}
      onClose={onClose}>
      <ContentError error={pages.error || people.error || agents.error} />
    </ComposerCompletionList>
  )
}

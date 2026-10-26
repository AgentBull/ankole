import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../../common/i18n'
import type { ConversationDetail } from '../api'
import { useChatCommands } from '../chat-commands'
import { MessageActions } from '../chat/message-actions'
import { ChatModel } from './chat'
import { ChatDrafts } from './chat-drafts'

beforeAll(() => loadLocale('en-US'))

function detail(agentUIDs: string[]): ConversationDetail {
  const agents = ['agent-a', 'agent-b'].map(uid => ({
    uid,
    displayName: uid,
    active: true,
    type: 'agent' as const,
    role: 'agent' as const,
    mayIntervene: false
  }))
  const question: ConversationDetail['messages'][number] = {
    id: 'latest-question',
    seq: 2,
    authorType: 'human',
    authorUID: 'person',
    authorDisplayName: 'Person',
    authorArchived: false,
    kind: 'message',
    text: 'Review this requirement',
    createdAt: '2026-10-25T00:00:00Z',
    signalID: null,
    replyToMessageID: null,
    mentions: [],
    links: [],
    attachments: [],
    savedPages: []
  }
  return {
    latestInput: { messageID: question.id, authorUID: 'person', agentUIDs },
    messages: [
      question,
      {
        ...question,
        id: 'reply-a',
        seq: 3,
        authorType: 'agent',
        authorUID: 'agent-a',
        text: 'Reviewed',
        signalID: 'signal-a',
        replyToMessageID: question.id
      }
    ],
    messageRange: { firstSeq: 2, lastSeq: 3 },
    olderMessagesBeforeSeq: 2,
    removedMessageIDs: [],
    artifacts: { pageIDs: [], attachments: [] },
    activities: [],
    pendingInteractions: [],
    linkedRuns: [],
    pendingQueues: agents.map(agent => ({
      agentUID: agent.uid,
      queueVersion: `${agent.uid}-version`,
      paused: false,
      inputs: [],
      workStatus: { state: agent.uid === 'agent-a' ? 'idle' : 'running', retryAt: null }
    })),
    conversation: {
      id: 'conversation',
      title: 'Team review',
      titleCustomized: false,
      pageID: null,
      roomMode: 'group',
      accessScope: 'participants',
      createdBy: 'person',
      canDelete: true,
      canManage: true,
      lastMessageSeq: 3,
      lastActivityAt: '2026-10-25T00:00:00Z',
      rowStatus: 'streaming',
      viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 3 },
      agents,
      agent: agents[0],
      participants: [
        ...agents,
        { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false }
      ]
    }
  }
}

function commands(
  data: ConversationDetail,
  callableAgentUIDs = ['agent-a', 'agent-b'],
  draft = '',
  prepare?: (model: InstanceType<typeof ChatModel>) => void
) {
  const model = new ChatModel()
  model.draft.value = draft
  prepare?.(model)
  const client = new QueryClient()
  let result!: ReturnType<typeof useChatCommands>
  function Subject() {
    result = useChatCommands({
      model,
      drafts: new ChatDrafts(),
      conversationID: data.conversation.id,
      data,
      agentUID: 'agent-b',
      agentsError: false,
      callableAgentUIDs,
      refresh: async () => data
    })
    return null
  }
  renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <Subject />
    </QueryClientProvider>
  )
  client.clear()
  return { result, model }
}

test('an anchor-page DM accepts a Human-only post without permission to invoke its Agent', () => {
  const shared = detail([])
  shared.conversation.roomMode = 'dm'
  shared.conversation.accessScope = 'anchor_page'
  expect(commands(shared, [], 'A teammate observation').result.canSubmit).toBe(true)
  shared.conversation.accessScope = 'participants'
  expect(commands(shared, [], 'A teammate observation').result.canSubmit).toBe(false)
})

test('retry refuses an unavailable selected recipient and keeps the failed message', () => {
  for (const unavailable of ['inactive', 'not-callable', 'removed']) {
    const data = detail([])
    if (unavailable === 'inactive') data.conversation.agents[0]!.active = false
    if (unavailable === 'removed') data.conversation.agents = data.conversation.agents.slice(1)
    const callable = unavailable === 'not-callable' ? ['agent-b'] : ['agent-a', 'agent-b']
    const { result, model } = commands(data, callable, 'Retry this message', model => {
      model.targetAgentUID.value = 'agent-a'
      const submission = model.submit(data.conversation.id, 'agent-b', () => 'failed-message')
      model.failed(new Error('send failed'), submission.messageID)
    })

    expect(result.canSubmit).toBe(false)
    expect(result.recipientAvailable).toBe(false)
    result.submit()
    expect(model.pending.value?.state).toBe('failed')
    expect(model.draft.value).toBe('Retry this message')
  }
})

test('a group broadcast does not require an individually callable recipient', () => {
  expect(commands(detail([]), [], 'A group observation').result.canSubmit).toBe(true)
})

test('an edit uses its saved recipient independently of the composer selection', () => {
  const data = detail(['agent-a'])
  const { result } = commands(data, ['agent-a'], '', model => {
    model.targetAgentUID.value = 'agent-b'
    model.beginEdit({
      messageID: data.messages[0]!.id,
      text: 'Edited message',
      links: [],
      mentions: [],
      queueVersion: 'agent-a-version',
      kind: 'last',
      hasAttachments: false,
      agentUID: 'agent-a'
    })
  })
  expect(result.canSubmit).toBe(true)
  expect(result.recipientAvailable).toBe(true)
})

test('an answer uses the question recipient independently of the composer selection', () => {
  const data = detail([])
  data.pendingInteractions = [
    {
      interaction_id: 'question',
      agentUID: 'agent-a',
      messageID: 'question-message',
      tool_call_id: 'question-call',
      question: 'Where should the report go?',
      choices: [],
      allow_free_text: true,
      state: 'pending'
    }
  ]
  const { result } = commands(data, ['agent-a'], 'Save it here', model => {
    model.targetAgentUID.value = 'agent-b'
    model.startAnswer('question')
  })
  expect(result.canSubmit).toBe(true)
  expect(result.recipientAvailable).toBe(true)
})

test('editing a single Agent request uses its actual target while another Agent works', () => {
  const data = detail(['agent-a'])
  const { result, model } = commands(data)
  expect(result.working).toBe(true)
  expect(result.messageActions?.editDisabledReason).toBeUndefined()
  expect(result.messageActions?.edit).toBeDefined()
  result.messageActions!.edit!(data.messages[0]!)
  expect(model.editing.value).toMatchObject({
    messageID: 'latest-question',
    agentUID: 'agent-a',
    queueVersion: 'agent-a-version',
    kind: 'last'
  })
})

test('silent multi-Agent targets and Human-only discussion explain their edit restriction', () => {
  for (const [targets, reason] of [
    [[], 'pod.chat_timeline.no_agent_edit'],
    [['agent-a', 'agent-b'], 'pod.chat_timeline.multi_agent_edit']
  ] as const) {
    const data = detail([...targets])
    const { result, model } = commands(data)
    expect(data.messages.filter(message => message.authorType === 'agent')).toHaveLength(1)
    expect(result.messageActions?.edit).toBeDefined()
    expect(result.messageActions?.editDisabledReason).toBe(i18n.t(reason))
    const html = renderToStaticMarkup(
      <MessageActions
        text={data.messages[0]!.text ?? ''}
        onEdit={() => result.messageActions!.edit!(data.messages[0]!)}
        editDisabledReason={result.messageActions!.editDisabledReason}
      />
    )
    expect(html).toContain('disabled=""')
    expect(html).toContain('aria-description=')
    expect(model.editing.value).toBeUndefined()
  }
})

test('the actual target must be idle and have no queued inputs before history can be edited', () => {
  const running = detail(['agent-b'])
  expect(commands(running).result.messageActions?.edit).toBeUndefined()
  const queued = detail(['agent-a'])
  queued.pendingQueues[0]!.inputs = [
    {
      messageID: 'next-question',
      agentUID: 'agent-a',
      authorUID: 'person',
      text: 'Next request',
      mentions: [],
      links: [],
      attachments: [],
      deliveryMode: 'queue',
      modelProfile: 'primary'
    }
  ]
  expect(commands(queued).result.messageActions?.edit).toBeUndefined()
})

test('loaded older messages cannot become editable when the canonical latest input belongs to a colleague', () => {
  const data = detail(['agent-a'])
  data.latestInput = { messageID: 'newer-colleague-message', authorUID: 'colleague', agentUIDs: ['agent-a'] }
  const { result, model } = commands(data)
  expect(result.messageActions?.edit).toBeUndefined()
  result.recallLast()
  expect(model.editing.value).toBeUndefined()
})

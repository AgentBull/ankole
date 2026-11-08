import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../../common/i18n'
import type { ConversationDetail } from '../api'
import { client as podClient } from '../api/generated/client.gen'
import { useChatCommands } from '../chat-commands'
import { InlineMessageEditor } from '../chat/inline-message-editor'
import { MessageActions } from '../chat/message-actions'
import { QueuedStrip } from '../chat/queued-strip'
import { modelSelectionKey } from '../model-controls'
import { ChatModel } from './chat'
import { ChatDrafts } from './chat-drafts'

beforeAll(() => loadLocale('en-US'))

test('first personal-assistant send creates the assistant once and retries only the failed message', async () => {
  const original = podClient.getConfig()
  const requests: { path: string; body?: { data: Record<string, unknown> } }[] = []
  const model = new ChatModel()
  model.draft.value = 'Summarize my notes'
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  let command!: ReturnType<typeof useChatCommands>
  let failSend = true
  podClient.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (input: RequestInfo | URL) => {
      const request = input as Request
      const path = new URL(request.url).pathname
      const body = request.body ? await request.json() : undefined
      requests.push({ path, body })
      if (path === '/api/v2/pod/personal-assistant') return Response.json({ uid: 'my-assistant' })
      expect(path).toBe('/api/v2/pod/conversations')
      expect(body.data.agentUID).toBe('my-assistant')
      if (failSend) throw new Error('Message delivery unavailable')
      const response = detail(['my-assistant'])
      response.conversation.id = body.data.conversationID
      return Response.json(response)
    }) as typeof fetch
  })
  function Subject() {
    command = useChatCommands({
      model,
      drafts: new ChatDrafts(),
      agentUID: '',
      personalAssistant: true,
      agentsError: false,
      callableAgentUIDs: [],
      refresh: async () => undefined
    })
    return null
  }
  const submit = () =>
    new Promise<void>(resolve => {
      const unsubscribe = client.getMutationCache().subscribe(event => {
        if (event.type === 'updated' && ['success', 'error'].includes(event.mutation.state.status)) {
          unsubscribe()
          resolve()
        }
      })
      command.submit()
    })

  try {
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <Subject />
      </QueryClientProvider>
    )
    expect(command.canSubmit).toBe(true)
    expect(requests).toHaveLength(0)
    await submit()
    expect(model.pending.value?.state).toBe('failed')
    expect(model.pending.value?.agentUID).toBe('my-assistant')
    expect(model.draft.value).toBe('Summarize my notes')
    failSend = false
    await submit()
    expect(requests.map(request => request.path)).toEqual([
      '/api/v2/pod/personal-assistant',
      '/api/v2/pod/conversations',
      '/api/v2/pod/conversations'
    ])
    expect(requests[2]!.body).toEqual(requests[1]!.body)
    expect(model.pending.value).toBeUndefined()
  } finally {
    podClient.setConfig(original)
    client.clear()
  }
})

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
    editableInputs: [{ messageID: question.id, agentUIDs, supersededByParticipant: false }],
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
      conversationKind: 'group',
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
  const { result: inlineResult } = commands(data, ['agent-a'], '', model => {
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
  expect(inlineResult.canSubmitEdit).toBe(true)
  expect(inlineResult.editRecipientAvailable).toBe(true)

  const { result: queueResult } = commands(data, ['agent-a'], '', model => {
    model.targetAgentUID.value = 'agent-b'
    model.beginEdit({
      messageID: 'queued-message',
      text: 'Edited queued message',
      links: [],
      mentions: [],
      queueVersion: 'agent-a-version',
      kind: 'queue',
      hasAttachments: false,
      agentUID: 'agent-a'
    })
  })
  expect(queueResult.canSubmit).toBe(true)
  expect(queueResult.recipientAvailable).toBe(true)
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

test('inline timeline editing remains available while the target Agent is streaming or has queued follow-ups', () => {
  const running = detail(['agent-b'])
  const { result: runningCommands, model: runningModel } = commands(running, ['agent-a', 'agent-b'], 'Composer draft')
  expect(runningCommands.messageActions?.canEdit(running.messages[0]!)).toBe(true)
  runningCommands.messageActions!.edit!(running.messages[0]!)
  expect(runningModel.editing.value).toMatchObject({
    messageID: 'latest-question',
    agentUID: 'agent-b',
    kind: 'last'
  })
  expect(runningModel.draft.value).toBe('Composer draft')

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
  const { result: queuedCommands, model: queuedModel } = commands(queued, ['agent-a', 'agent-b'], 'Keep draft')
  expect(queuedCommands.messageActions?.canEdit(queued.messages[0]!)).toBe(true)
  queuedCommands.messageActions!.edit!(queued.messages[0]!)
  expect(queuedModel.editing.value?.messageID).toBe('latest-question')
  expect(queuedModel.draft.value).toBe('Keep draft')
})

test('multi-turn history exposes all non-superseded viewer messages for inline edit and backtrack', () => {
  const data = detail(['agent-a'])
  const base = data.messages[0]!
  data.messages = [
    { ...base, id: 'turn-1', seq: 1, text: 'First prompt' },
    { ...data.messages[1]!, id: 'reply-1', seq: 2, replyToMessageID: 'turn-1' },
    { ...base, id: 'turn-2', seq: 3, text: 'Second prompt' },
    { ...data.messages[1]!, id: 'reply-2', seq: 4, replyToMessageID: 'turn-2' },
    { ...base, id: 'turn-3', seq: 5, text: 'Third prompt' }
  ]
  data.editableInputs = [
    { messageID: 'turn-1', agentUIDs: ['agent-a'], supersededByParticipant: true },
    { messageID: 'turn-2', agentUIDs: ['agent-a'], supersededByParticipant: false },
    { messageID: 'turn-3', agentUIDs: ['agent-a'], supersededByParticipant: false }
  ]
  data.latestInput = { messageID: 'turn-3', authorUID: 'person', agentUIDs: ['agent-a'] }
  const { result, model } = commands(data, ['agent-a', 'agent-b'], '')

  expect(result.messageActions?.editDisabledReasonFor(data.messages[0]!)).toBe(
    i18n.t('pod.chat.errors.reply_unavailable')
  )
  expect(result.editableMessageIDs).toEqual(['turn-2', 'turn-3'])
  result.messageActions!.edit!(data.messages[0]!)
  expect(model.editing.value).toBeUndefined()

  expect(result.enterBacktrack()).toBe(true)
  expect(model.backtrackMessageID.value).toBe('turn-3')
  result.recallLast()
  expect(model.editing.value?.messageID).toBe('turn-3')

  result.messageActions!.edit!(data.messages[2]!)
  expect(model.editing.value?.messageID).toBe('turn-2')
  const client = new QueryClient()
  const html = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <InlineMessageEditor
        model={model}
        message={data.messages[2]!}
        detail={data}
        canSubmit={true}
        recipientAvailable={true}
        submitting={false}
        editConflict={false}
        recovery={{ loading: false, error: null, refresh: () => {}, useSaved: () => {} }}
        onSubmit={() => {}}
        onCancel={() => {}}
      />
    </QueryClientProvider>
  )
  client.clear()
  expect(html).toContain(i18n.t('pod.chat.edit_message_label'))
  expect(html).toContain(i18n.t('pod.chat.edit_reverts_later'))
  expect(html).toContain('aria-describedby=')
  expect(html).toContain('Second prompt')
})

test('submit chooses steer when idle, follows follow-up mode when working, and queues on active profile mismatch', async () => {
  const original = podClient.getConfig()
  const deliveries: string[] = []
  podClient.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (input: RequestInfo | URL) => {
      const request = input as Request
      const body = await request.json()
      deliveries.push(body.data.deliveryMode)
      return Response.json(detail(['agent-b']))
    }) as typeof fetch
  })
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const run = async (
    data: ConversationDetail,
    draft: string,
    setup?: (model: InstanceType<typeof ChatModel>) => void,
    override?: 'steer' | 'queue'
  ) => {
    const model = new ChatModel()
    model.setFollowUpBehavior('steer')
    model.draft.value = draft
    setup?.(model)
    let current!: ReturnType<typeof useChatCommands>
    function Subject() {
      current = useChatCommands({
        model,
        drafts: new ChatDrafts(),
        conversationID: data.conversation.id,
        data,
        agentUID: 'agent-b',
        agentsError: false,
        callableAgentUIDs: ['agent-a', 'agent-b'],
        refresh: async () => data
      })
      return null
    }
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <Subject />
      </QueryClientProvider>
    )
    await new Promise<void>(resolve => {
      const unsubscribe = client.getMutationCache().subscribe(event => {
        if (event.type === 'updated' && ['success', 'error'].includes(event.mutation.state.status)) {
          unsubscribe()
          resolve()
        }
      })
      current.submit(override)
    })
    return current
  }

  try {
    const idleRoom = detail(['agent-a'])
    idleRoom.conversation.roomMode = 'dm'
    idleRoom.pendingQueues[1]!.workStatus = { state: 'idle', retryAt: null }
    await run(idleRoom, 'Start fresh turn', model => model.setFollowUpBehavior('queue'))
    expect(deliveries.at(-1)).toBe('steer')

    const activeRoom = detail(['agent-b'])
    activeRoom.conversation.roomMode = 'dm'
    await run(activeRoom, 'Steer active turn')
    expect(deliveries.at(-1)).toBe('steer')

    await run(activeRoom, 'Explicit alternate queue', undefined, 'queue')
    expect(deliveries.at(-1)).toBe('queue')

    await run(activeRoom, 'Configured queue default', model => model.setFollowUpBehavior('queue'))
    expect(deliveries.at(-1)).toBe('queue')

    client.setQueryData([...modelSelectionKey(activeRoom.conversation.id), 'agent-b'], {
      profile: 'reasoning',
      activeProfile: 'primary'
    })
    const mismatched = await run(activeRoom, 'Profile changed mid-turn', model => model.setFollowUpBehavior('steer'))
    expect(mismatched.canSteerTarget).toBe(false)
    expect(mismatched.deliveryModes).toEqual({ primary: 'queue' })
    expect(deliveries.at(-1)).toBe('queue')
  } finally {
    new ChatModel().setFollowUpBehavior('steer')
    podClient.setConfig(original)
    client.clear()
  }
})

test('takeBackLastQueued pops the latest viewer queue item and QueuedStrip hides steer-only queues', async () => {
  const original = podClient.getConfig()
  const retracted: string[] = []
  const data = detail(['agent-b'])
  data.conversation.roomMode = 'dm'
  data.messages.push(
    { ...data.messages[0]!, id: 'steered-1', seq: 4, text: 'Steer now' },
    { ...data.messages[0]!, id: 'queued-1', seq: 5, text: 'Queued first' },
    { ...data.messages[0]!, id: 'queued-2', seq: 6, text: 'Queued second' }
  )
  data.pendingQueues[1]!.inputs = [
    {
      messageID: 'steered-1',
      agentUID: 'agent-b',
      authorUID: 'person',
      text: 'Steer now',
      deliveryMode: 'steer',
      modelProfile: 'primary',
      mentions: [],
      links: [],
      attachments: []
    },
    {
      messageID: 'queued-1',
      agentUID: 'agent-b',
      authorUID: 'person',
      text: 'Queued first',
      deliveryMode: 'queue',
      modelProfile: 'primary',
      mentions: [],
      links: [],
      attachments: []
    },
    {
      messageID: 'queued-2',
      agentUID: 'agent-b',
      authorUID: 'person',
      text: 'Queued second',
      deliveryMode: 'queue',
      modelProfile: 'primary',
      mentions: [],
      links: [],
      attachments: []
    }
  ]
  podClient.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (input: RequestInfo | URL) => {
      const request = input as Request
      const body = await request.json()
      retracted.push(body.data.messageID)
      return Response.json(data)
    }) as typeof fetch
  })
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const model = new ChatModel()
  let current!: ReturnType<typeof useChatCommands>
  function Subject() {
    current = useChatCommands({
      model,
      drafts: new ChatDrafts(),
      conversationID: data.conversation.id,
      data,
      agentUID: 'agent-b',
      agentsError: false,
      callableAgentUIDs: ['agent-b'],
      refresh: async () => data
    })
    return null
  }
  try {
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <Subject />
      </QueryClientProvider>
    )
    const stripHtml = renderToStaticMarkup(
      <QueuedStrip
        detail={data}
        disabled={false}
        editing={true}
        editingMessageID="queued-1"
        callableAgentUIDs={['agent-b']}
        change={() => {}}
        edit={() => {}}
        takeBack={() => {}}
      />
    )
    expect(stripHtml).toContain('Queued first')
    expect(stripHtml).toContain('Queued second')
    expect(stripHtml).not.toContain('Steer now')
    expect(stripHtml).toContain('(2)')
    expect(stripHtml).toContain('data-editing="true"')
    expect(stripHtml).toContain('pod-chat-queue-hint')
    expect(stripHtml).toContain('Steer')

    data.pendingQueues[1]!.paused = true
    data.pendingQueues[1]!.workStatus = { state: 'idle', retryAt: null }
    const pausedIdleHtml = renderToStaticMarkup(
      <QueuedStrip
        detail={data}
        disabled={false}
        editing={false}
        callableAgentUIDs={['agent-b']}
        change={() => {}}
        edit={() => {}}
        takeBack={() => {}}
      />
    )
    expect(pausedIdleHtml).not.toContain('pod-chat-queue-hint')
    expect(pausedIdleHtml).toContain('Send')
    data.pendingQueues[1]!.paused = false
    data.pendingQueues[1]!.workStatus = { state: 'running', retryAt: null }

    await new Promise<void>(resolve => {
      const unsubscribe = client.getMutationCache().subscribe(event => {
        if (event.type === 'updated' && ['success', 'error'].includes(event.mutation.state.status)) {
          unsubscribe()
          resolve()
        }
      })
      expect(current.takeBackLastQueued()).toBe(true)
    })
    expect(retracted).toEqual(['queued-2'])
    expect(model.draft.value).toBe('Queued second')

    data.pendingQueues[1]!.inputs = data.pendingQueues[1]!.inputs.slice(0, 1)
    data.pendingQueues[1]!.paused = true
    expect(
      renderToStaticMarkup(
        <QueuedStrip
          detail={data}
          disabled={false}
          editing={false}
          callableAgentUIDs={['agent-b']}
          change={() => {}}
          edit={() => {}}
          takeBack={() => {}}
        />
      )
    ).toBe('')
  } finally {
    podClient.setConfig(original)
    client.clear()
  }
})

test('submitEdit accepts unchanged text for branch re-runs and invokes onInlineEditSettled only for edit_last', async () => {
  const original = podClient.getConfig()
  const actions: string[] = []
  const data = detail(['agent-a'])
  data.pendingQueues[1]!.workStatus = { state: 'idle', retryAt: null }
  podClient.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (input: RequestInfo | URL) => {
      const request = input as Request
      const body = await request.json()
      actions.push(`${body.data.action}:${body.data.text}`)
      return Response.json(data)
    }) as typeof fetch
  })
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const model = new ChatModel()
  let settledCount = 0
  let current!: ReturnType<typeof useChatCommands>
  function Subject() {
    current = useChatCommands({
      model,
      drafts: new ChatDrafts(),
      conversationID: data.conversation.id,
      data,
      agentUID: 'agent-a',
      agentsError: false,
      callableAgentUIDs: ['agent-a', 'agent-b'],
      refresh: async () => data,
      onInlineEditSettled: () => {
        settledCount += 1
      }
    })
    return null
  }
  const renderSubject = () =>
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <Subject />
      </QueryClientProvider>
    )

  try {
    renderSubject()
    current.messageActions!.edit!(data.messages[0]!)
    renderSubject()
    // Unchanged text remains submittable so users can branch/re-run from an earlier message like Codex.
    expect(model.editDraft.value).toBe(data.messages[0]!.text)
    expect(current.canSubmitEdit).toBe(true)

    await new Promise<void>(resolve => {
      const unsubscribe = client.getMutationCache().subscribe(event => {
        if (event.type === 'updated' && ['success', 'error'].includes(event.mutation.state.status)) {
          unsubscribe()
          resolve()
        }
      })
      current.submitEdit()
    })
    expect(actions).toEqual([`edit_last:${data.messages[0]!.text}`])
    expect(settledCount).toBe(1)
    expect(model.editing.value).toBeUndefined()

    // Editing a pending queue item via Composer does not trigger onInlineEditSettled.
    const queuedInput = {
      messageID: 'queued-only',
      agentUID: 'agent-a',
      authorUID: 'person',
      text: 'Queued item',
      deliveryMode: 'queue' as const,
      modelProfile: 'primary',
      mentions: [],
      links: [],
      attachments: []
    }
    data.pendingQueues[0]!.inputs = [queuedInput]
    renderSubject()
    current.editQueued(queuedInput, 'agent-a')
    model.draft.value = 'Updated queued item'
    renderSubject()

    await new Promise<void>(resolve => {
      const unsubscribe = client.getMutationCache().subscribe(event => {
        if (event.type === 'updated' && ['success', 'error'].includes(event.mutation.state.status)) {
          unsubscribe()
          resolve()
        }
      })
      current.submit()
    })
    expect(actions).toEqual([`edit_last:${data.messages[0]!.text}`, 'edit:Updated queued item'])
    expect(settledCount).toBe(1)
  } finally {
    podClient.setConfig(original)
    client.clear()
  }
})

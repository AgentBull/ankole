import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { podKeys, type ConversationDetail } from '../api'
import { NextStepsMenu, nextStepDraft } from '../chat/next-steps-menu'
import { ReplySuggestionGhost, replySuggestionTarget, useReplySuggestion } from '../chat/reply-suggestion'

beforeAll(async () => {
  await loadLocale('en-US')
})

const step = (id: string, ambitious = false) => ({
  id,
  title: `Review ${id}`,
  outcome: `A checked ${id}`,
  effort: '10 minutes',
  whyNow: 'The plan waits for it',
  ambitious
})

test('the chat home shows the assistant menu, and keeps its starters until a menu exists', () => {
  const render = (client: QueryClient) =>
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <NextStepsMenu fallback={<p>starters</p>} onChoose={() => {}} />
      </QueryClientProvider>
    ).replace(/[\u2066-\u2069]/g, '')
  const client = new QueryClient({ defaultOptions: { queries: { staleTime: Infinity } } })
  expect(render(client)).toContain('starters')
  client.setQueryData(podKeys.nextSteps, { steps: [step('plan', true), step('budget')] })
  const html = render(client)
  expect(html).toContain('Next steps')
  expect(html).toContain('Review plan')
  expect(html).toContain('10 minutes · The plan waits for it')
  expect(html.match(/>10x</g)).toHaveLength(1)
  expect(html).not.toContain('starters')
  expect(nextStepDraft(step('plan'), 'Expected result: A checked plan')).toBe(
    'Review plan\n\nExpected result: A checked plan'
  )
})

test('a reply suggestion targets an idle Agent reply when the viewer is the only Human', () => {
  const message = (
    id: string,
    authorType: 'agent' | 'human',
    kind: 'message' | 'notice' = 'message',
    richContent?: Record<string, unknown>
  ) => ({
    id,
    authorType,
    kind,
    richContent
  })
  const member = (uid: string, type: 'human' | 'agent') => ({ uid, type })
  const detail = (overrides: Record<string, unknown> = {}) =>
    ({
      messages: [message('ask', 'human'), message('reply', 'agent')],
      pendingInteractions: [],
      pendingQueues: [],
      linkedRuns: [],
      conversation: { rowStatus: 'idle', participants: [member('alice', 'human'), member('planner', 'agent')] },
      ...overrides
    }) as never

  expect(replySuggestionTarget(detail())).toBe('reply')
  expect(
    replySuggestionTarget(
      detail({
        conversation: { rowStatus: 'unread', participants: [member('alice', 'human'), member('planner', 'agent')] }
      })
    )
  ).toBe('reply')
  expect(replySuggestionTarget(detail({ messages: [message('reply', 'agent'), message('ask', 'human')] }))).toBe(
    undefined
  )
  expect(replySuggestionTarget(detail({ messages: [message('joined', 'agent', 'notice')] }))).toBe(undefined)
  expect(
    replySuggestionTarget(
      detail({
        conversation: {
          participants: [member('alice', 'human'), member('bob', 'human'), member('planner', 'agent')]
        }
      })
    )
  ).toBe(undefined)
  expect(replySuggestionTarget(detail({ pendingInteractions: [{}] }))).toBe(undefined)
  expect(replySuggestionTarget(detail({ pendingQueues: [{ inputs: [], workStatus: { state: 'running' } }] }))).toBe(
    undefined
  )
  expect(
    replySuggestionTarget(detail({ pendingQueues: [{ inputs: [{ messageID: 'q1' }], workStatus: { state: 'idle' } }] }))
  ).toBe(undefined)
  for (const status of ['queued', 'running', 'waiting_on_user', 'awaiting_input', 'sleeping']) {
    expect(replySuggestionTarget(detail({ linkedRuns: [{ status }] }))).toBe(undefined)
  }
  for (const status of ['succeeded', 'completed', 'failed', 'stopped', 'cancelled']) {
    expect(replySuggestionTarget(detail({ linkedRuns: [{ status }] }))).toBe('reply')
  }
  for (const rowStatus of ['waiting_choice', 'streaming', 'queued', 'running_background']) {
    expect(
      replySuggestionTarget(
        detail({
          conversation: { rowStatus, participants: [member('alice', 'human'), member('planner', 'agent')] }
        })
      )
    ).toBe(undefined)
  }
  expect(
    replySuggestionTarget(
      detail({
        messages: [
          message('ask', 'human'),
          message('reply', 'agent', 'message', { action_card: { card_id: 'c1', status: 'prepared' } })
        ]
      })
    )
  ).toBe(undefined)
  expect(
    replySuggestionTarget(
      detail({
        messages: [
          message('ask', 'human'),
          message('reply', 'agent', 'message', { action_card: { card_id: 'c1', status: 'executed' } })
        ]
      })
    )
  ).toBe('reply')

  function InlineSuggestionProbe({ detail: probeDetail, idle }: { detail: ConversationDetail; idle: boolean }) {
    const suggestion = useReplySuggestion({
      conversationID: 'conv-1',
      detail: probeDetail,
      idle,
      onUse: () => {}
    })
    return <ReplySuggestionGhost suggestion={suggestion} />
  }

  const client = new QueryClient({ defaultOptions: { queries: { staleTime: Infinity } } })
  client.setQueryData(podKeys.replySuggestion('conv-1', 'reply'), {
    messageID: 'reply',
    text: 'Paste the new webhook token'
  })
  const runningHtml = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <InlineSuggestionProbe detail={detail({ linkedRuns: [{ status: 'running' }] })} idle />
    </QueryClientProvider>
  )
  expect(runningHtml).toBe('')
  const busyComposerHtml = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <InlineSuggestionProbe detail={detail()} idle={false} />
    </QueryClientProvider>
  )
  expect(busyComposerHtml).toBe('')
  const completedHtml = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <InlineSuggestionProbe detail={detail({ linkedRuns: [{ status: 'succeeded' }] })} idle />
    </QueryClientProvider>
  ).replace(/[\u2066-\u2069]/g, '')
  expect(completedHtml).toContain('pod-chat-composer-suggestion')
  expect(completedHtml).toContain('Paste the new webhook token')
  expect(completedHtml).toContain('⇥')
  expect(completedHtml).toContain('Tab</kbd>')
  expect(completedHtml).toContain('aria-label="Tab — Use the suggested reply: Paste the new webhook token"')
  expect(completedHtml).toContain('title="Press Tab to use this suggestion"')
})

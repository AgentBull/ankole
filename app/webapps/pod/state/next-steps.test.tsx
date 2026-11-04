import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { podKeys } from '../api'
import { NextStepsMenu, nextStepDraft } from '../chat/next-steps-menu'
import { replySuggestionTarget } from '../chat/reply-suggestion'

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
  const message = (id: string, authorType: 'agent' | 'human', kind: 'message' | 'notice' = 'message') => ({
    id,
    authorType,
    kind
  })
  const member = (uid: string, type: 'human' | 'agent') => ({ uid, type })
  const detail = (overrides: Record<string, unknown> = {}) =>
    ({
      messages: [message('ask', 'human'), message('reply', 'agent')],
      pendingInteractions: [],
      pendingQueues: [],
      conversation: { participants: [member('alice', 'human'), member('planner', 'agent')] },
      ...overrides
    }) as never

  expect(replySuggestionTarget(detail())).toBe('reply')
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
})

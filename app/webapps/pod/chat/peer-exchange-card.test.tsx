import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterContextProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { podKeys } from '../api'
import { PeerExchangeCard, pairPeerExchanges } from './peer-exchange-card'
import type { TimelineMessage } from './types'

const locales = ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'] as const
const conversationID = '019a0000-0000-7000-8000-000000000001'
const exchangeID = '019a0000-0000-7000-8000-000000000002'
const peer = { exchange_id: exchangeID, agent_uid: 'legal' }

const message = (id: string, text: string, createdAt: string, richContent: TimelineMessage['richContent']) =>
  ({
    id,
    seq: 1,
    authorType: 'agent',
    authorUID: 'assistant',
    authorDisplayName: 'Assistant',
    authorArchived: false,
    kind: 'message',
    text,
    createdAt,
    links: [],
    attachments: [],
    mentions: [],
    savedPages: [],
    replyToMessageID: null,
    signalID: null,
    richContent
  }) as TimelineMessage

const request = message(
  '019a0000-0000-7000-8000-000000000003',
  'Review the supplier contracts',
  '2026-11-02T04:00:00Z',
  {
    agent_peer_outbound: peer
  }
)
const reply = message(
  '019a0000-0000-7000-8000-000000000004',
  'Clause 4 caps liability too low.',
  '2026-11-02T04:03:20Z',
  {
    agent_peer_inbound: peer
  }
)

beforeAll(async () => {
  await Promise.all(locales.map(locale => loadLocale(locale)))
})

function renderCard(
  status: string | undefined,
  props: Partial<Parameters<typeof PeerExchangeCard>[0]> = {},
  locale: (typeof locales)[number] = 'en-US'
) {
  const client = new QueryClient()
  const router = createRouter({
    routeTree: createRootRoute(),
    history: createMemoryHistory({ initialEntries: ['/'] })
  })
  client.setQueryData(podKeys.agents, {
    agents: [{ uid: 'legal', displayName: 'Legal review', type: 'agent', active: true, mayIntervene: false }],
    personalAssistantAvailable: true
  })
  if (status) {
    client.setQueryData([...podKeys.detail(conversationID), 'peer', exchangeID], {
      id: exchangeID,
      agentUID: 'legal',
      status,
      text: '',
      messages: []
    })
  }
  const clone = i18n.cloneInstance({ lng: locale })
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={clone}>
        <QueryClientProvider client={client}>
          <RouterContextProvider router={router}>
            <PeerExchangeCard conversationID={conversationID} peer={peer} request={request} {...props} />
          </RouterContextProvider>
        </QueryClientProvider>
      </I18nextProvider>
    )
  } finally {
    client.clear()
  }
}

test('a delegation row names the colleague and states where the work stands in every locale', () => {
  for (const locale of locales) {
    const t = i18n.getFixedT(locale)
    for (const [status, key, stoppable] of [
      ['queued', 'pod.chat_timeline.queued', true],
      ['running', 'pod.superagent.delegation_running', true],
      ['retrying', 'pod.chat_timeline.retrying', true],
      ['waiting_choice', 'pod.superagent.delegation_waiting', true],
      ['idle', 'pod.superagent.delegation_ended', false]
    ] as const) {
      const html = renderCard(status, {}, locale)
      expect(html).toContain(t('pod.superagent.delegated_to', { name: 'Legal review' }))
      expect(html).toContain(`role="status" class="pod-peer-exchange-state">${t(key)}</span>`)
      const stop = `aria-label="${t('pod.superagent.stop_delegation', { name: 'Legal review' })}"`
      if (stoppable) expect(html).toContain(stop)
      else expect(html).not.toContain(stop)
    }
  }
})

test('a delegation that has a reply shows the start of the answer and how long it took', () => {
  const html = renderCard('idle', { reply })
  expect(html).toContain('data-state="done"')
  expect(html).toContain(i18n.getFixedT('en-US')('pod.superagent.delegation_done', { time: '3m 20s' }))
  expect(html).toContain('Clause 4 caps liability too low.')
  expect(html).not.toContain('aria-label="Stop Legal review"')
})

test('a freshly sent delegation reads as handed off until its state arrives', () => {
  const html = renderCard(undefined)
  expect(html).toContain(`>${i18n.getFixedT('en-US')('pod.superagent.delegation_sent')}</span>`)
  expect(html).not.toContain(i18n.getFixedT('en-US')('pod.superagent.delegation_ended'))
})

test('a reply joins the nearest earlier delegation of its exchange, and only the latest delegation stays live', () => {
  const second = message('019a0000-0000-7000-8000-000000000005', 'Now check the appendix', '2026-11-02T05:00:00Z', {
    agent_peer_outbound: peer
  })
  const orphan = message('019a0000-0000-7000-8000-000000000006', 'Earlier answer', '2026-11-02T03:00:00Z', {
    agent_peer_inbound: { exchange_id: '019a0000-0000-7000-8000-000000000009', agent_uid: 'legal' }
  })
  const pairs = pairPeerExchanges([orphan, request, reply, second])
  expect(pairs.replies.get(request.id)).toBe(reply.id)
  expect(pairs.replies.has(second.id)).toBe(false)
  expect([...pairs.paired]).toEqual([reply.id])
  expect([...pairs.latest]).toEqual([second.id])
})

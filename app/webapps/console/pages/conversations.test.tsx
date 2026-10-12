import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter, Route, Routes } from 'react-router'
import { loadLocale } from '../../common/i18n'
import {
  ankoleWebAiGatewayConversationControllerMessagesQueryKey,
  ankoleWebAiGatewayConversationControllerShowQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import type { AiGatewayMessageItem } from '../api/generated/types.gen'
import { ConversationDetailPage } from './conversations'

beforeAll(() => loadLocale('en-US'))

describe('Conversation reply model facts', () => {
  test('distinguishes profiles that use the same model on text and tool rows', () => {
    const html = renderMessages([
      message('primary'),
      message('light', [{ type: 'function_call', name: 'command', call_id: 'c1', arguments: '{}' }]),
      message('heavy')
    ])

    for (const profile of ['primary', 'light', 'heavy']) expect(html).toContain(`Model profile: ${profile}`)
    expect(html.match(/Model: gpt-5\.5/g)).toHaveLength(3)
  })

  test('keeps the requested profile beside the model actually reported by the provider', () => {
    const html = renderMessages([
      message('coding', undefined, { request_model: 'provider/requested-model', provider_model: 'actual-model' })
    ])

    expect(html).toContain('Model profile: coding')
    expect(html).toContain('Model: actual-model')
    expect(html).not.toContain('Model: provider/requested-model')
  })

  test('shows the request selector while generating and never infers a profile for old or raw records', () => {
    const html = renderMessages([
      message(undefined, undefined, { provider_model: undefined, request_model: 'provider/gpt-5.5' })
    ])

    expect(html).toContain('Model: provider/gpt-5.5')
    expect(html).not.toContain('Model profile:')
  })

  test('does not render a malformed profile or fabricate model facts for tool journals and checkpoints', () => {
    const malformed = message(undefined, undefined, { model_profile: { invalid: true } })
    const journal = { ...message(undefined), id: 'journal', metadata: { tool_result_journal: true } }
    const checkpoint = { ...message(undefined), id: 'checkpoint', type: 'checkpoint' as const, metadata: {} }
    const html = renderMessages([malformed, journal, checkpoint])

    expect(html).not.toContain('Model profile:')
    expect(html.match(/Model: gpt-5\.5/g)).toHaveLength(1)
    expect(html).not.toContain('[object Object]')
  })
})

function message(
  profile?: string,
  content: AiGatewayMessageItem['content'] = [
    { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Reply' }] }
  ],
  metadata: AiGatewayMessageItem['metadata'] = {}
): AiGatewayMessageItem {
  return {
    id: profile ?? 'legacy',
    subject_uid: 'agent-a',
    conversation_id: 'conversation-a',
    type: 'message',
    status: 'complete',
    content,
    metadata: {
      model_profile: profile,
      provider_model: 'gpt-5.5',
      ...metadata
    },
    inserted_at: '2026-10-11T00:00:00Z',
    updated_at: '2026-10-11T00:00:00Z'
  }
}

function renderMessages(messages: AiGatewayMessageItem[]) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  client.setQueryData(
    ankoleWebAiGatewayConversationControllerShowQueryKey({ path: { conversation_id: 'conversation-a' } }),
    {
      conversation: {
        id: 'conversation-a',
        subject_uid: 'agent-a',
        conversation_key: 'profile-metadata',
        display_name: null,
        kind: 'custom',
        message_count: messages.length,
        metadata: {},
        inserted_at: '2026-10-11T00:00:00Z',
        updated_at: '2026-10-11T00:00:00Z'
      }
    }
  )
  client.setQueryData(
    ankoleWebAiGatewayConversationControllerMessagesQueryKey({
      path: { conversation_id: 'conversation-a' },
      query: { cursor: undefined, limit: 200 }
    }),
    { messages, next_cursor: null }
  )

  return renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={['/conversations/conversation-a']}>
        <Routes>
          <Route path="/conversations/:conversationID" element={<ConversationDetailPage />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

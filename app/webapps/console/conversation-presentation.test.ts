import { describe, expect, test } from 'bun:test'
import type { AiGatewayConversationItem as AIGatewayConversationItem } from './api/generated/types.gen'
import { conversationDisplayName } from './conversation-presentation'
import i18n from '../common/i18n'

type ConversationNameSource = Pick<AIGatewayConversationItem, 'conversation_key' | 'display_name' | 'kind' | 'metadata'>

function conversation(overrides: Partial<ConversationNameSource> = {}): ConversationNameSource {
  return {
    conversation_key: 'brain.dreaming:run-id:shared',
    display_name: null,
    kind: 'dreaming',
    metadata: {},
    ...overrides
  }
}

describe('conversationDisplayName', () => {
  test('keeps a resolved channel or peer name', () => {
    expect(conversationDisplayName(conversation({ display_name: '季琛' }))).toBe('季琛')
  })

  test('names Dreaming stores instead of exposing their internal session key', () => {
    expect(conversationDisplayName(conversation({ metadata: { brain: { visibility: 'shared' } } }))).toBe(
      i18n.t('console.brain.store_shared')
    )
    expect(conversationDisplayName(conversation({ metadata: { brain: { visibility: 'self' } } }))).toBe(
      i18n.t('console.brain.store_self')
    )
  })

  test('uses a kind name for other managed conversations and preserves custom keys', () => {
    expect(conversationDisplayName(conversation({ kind: 'job' }))).toBe(i18n.t('console.conversations.kind.job'))
    expect(
      conversationDisplayName(
        conversation({ conversation_key: 'operator-session', kind: 'custom', metadata: {}, display_name: null })
      )
    ).toBe('operator-session')
  })
})

import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { ActionCardView } from './action-card-view'
import type { ActionCardState } from './types'

beforeAll(() => loadLocale('en-US'))

function render(card: ActionCardState) {
  const client = new QueryClient()
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <ActionCardView card={card} />
        </QueryClientProvider>
      </I18nextProvider>
    )
  } finally {
    client.clear()
  }
}

test('sharing approval shows each recipient, permission, scope and condition', () => {
  const html = render({
    card_id: 'sharing-card',
    action_kind: 'pod.page.set_sharing',
    summary: 'Share the report',
    payload: {
      grants: [
        { principal_uid: 'alice', role: 'view', target_scope: 'self' },
        {
          group_id: 'reviewers',
          actions: ['node_comment'],
          target_scope: 'container',
          condition: 'principal.status == "active"'
        },
        { source_node_id: 'source-page', source_action: 'node_view', role: 'edit', target_scope: 'self' }
      ]
    }
  })
  for (const detail of [
    'alice',
    'view',
    'reviewers',
    'node_comment',
    'source-page',
    'node_view',
    'edit',
    'principal.status'
  ]) {
    expect(html).toContain(detail)
  }
  expect(html).toContain(i18n.t('pod.content.sharing_scope_self'))
  expect(html).toContain(i18n.t('pod.content.sharing_scope_container'))
})

test('participant approval shows names with stable UIDs and unnamed participants', () => {
  const html = render({
    card_id: 'members-card',
    action_kind: 'conversation.add_participants',
    summary: 'Invite reviewers',
    payload: {
      participant_uids: ['alice', 'bob'],
      participants: [{ uid: 'alice', name: 'Alice Smith' }]
    }
  })
  expect(html).toContain('Alice Smith (@alice)')
  expect(html).toContain('@bob')
})

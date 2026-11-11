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

test('knowledge approval exposes the captured version, changes and complete Markdown before approval', () => {
  const html = render({
    card_id: 'knowledge-card',
    action_kind: 'pod.knowledge.save',
    summary: 'Update the team rule',
    payload: {
      node_title: 'Team rule',
      base_revision: 7,
      diff: '- Review every month\n+ Review every week',
      markdown: '---\nsummary: weekly review\n---\n# Review policy\n\n<script>literal draft</script>'
    }
  })
  expect(html).toContain(i18n.t('pod.chat_action_card.page_target', { title: 'Team rule' }))
  expect(html).toContain('Based on version 7')
  expect(html).toContain('<details open=""')
  expect(html).toContain('- Review every month\n+ Review every week')
  expect(html).toContain('Complete draft')
  expect(html).toContain('summary: weekly review')
  expect(html).toContain('&lt;script&gt;literal draft&lt;/script&gt;')
  expect(html.indexOf('Complete draft')).toBeLessThan(html.indexOf('Confirm &amp; Execute'))
})

test('an empty knowledge draft remains inspectable as an intentional empty document', () => {
  const html = render({
    card_id: 'empty-knowledge-card',
    action_kind: 'pod.knowledge.save',
    summary: 'Clear the rule',
    payload: { node_title: 'Team rule', base_revision: 8, diff: '- Old rule', markdown: '' }
  })
  expect(html).toContain('(Empty document)')
  expect(html).toContain('- Old rule')
})

test('sharing approval renders deterministic current-access preview when explain_summaries are present', () => {
  const html = render({
    card_id: 'sharing-explain-card',
    action_kind: 'pod.page.set_sharing',
    summary: 'Grant Research Colleague view access',
    payload: {
      grants: [{ principal_uid: 'research', role: 'view', target_scope: 'container' }],
      explain_summaries: [
        {
          subject_uid: 'research',
          subject_name: 'Research Colleague',
          current_allowed: false,
          current_role: null,
          decision_reason: 'No matching grant on this restricted page.'
        },
        {
          subject_uid: 'alice',
          subject_name: 'Alice Smith',
          current_allowed: true,
          current_role: 'manage',
          decision_reason: 'Space administrator retains management access.'
        }
      ]
    }
  })
  expect(html).toContain('Current access before this change')
  expect(html).toContain('Research Colleague (@research): Denied — No matching grant on this restricted page.')
  expect(html).toContain('Alice Smith (@alice): Allowed (manage) — Space administrator retains management access.')
})

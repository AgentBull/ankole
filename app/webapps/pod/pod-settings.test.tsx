import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import type { PodAdminIdentityDirectoryResponse } from './api/generated/types.gen'
import { ManagedAgent } from './pod-settings'
import { PodProviderDirectoryReview } from './pod-settings-directory'

test('each Agent card and its actions name the Agent they act on', async () => {
  await loadLocale('en-US')
  const html = renderToStaticMarkup(
    <QueryClientProvider client={new QueryClient()}>
      <I18nextProvider i18n={i18n}>
        <ManagedAgent
          agent={{
            uid: 'sales-bot',
            displayName: 'Sales Bot',
            ownerUID: 'alice',
            status: 'active',
            type: 'ai_colleague'
          }}
          onSuccess={async () => {}}
        />
      </I18nextProvider>
    </QueryClientProvider>
  )

  const labelledBy = html.match(/role="group" aria-labelledby="([^"]+)"/)?.[1]
  expect(labelledBy).toBeDefined()
  expect(html).toContain(`<h2 id="${labelledBy}">Sales Bot</h2>`)
  // Interpolated values arrive wrapped in Unicode bidi isolates.
  expect(html).toContain('aria-label="Disable \u2068Sales Bot\u2069"')
  expect(html).toContain('aria-label="Rename UID of \u2068sales-bot\u2069"')
})

test('PodProviderDirectoryReview renders skeletons for unresolved missing_uids while members load and shows review_reason', async () => {
  await loadLocale('en-US')
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const directoryPayload: PodAdminIdentityDirectoryResponse = {
    snapshot: {
      provider_id: 'okta',
      status: 'review_required',
      revision: 1,
      snapshot_fingerprint: 'fp-1',
      member_uids: ['u_present'],
      missing_uids: ['u_missing_raw'],
      last_success_at: '2026-11-01T10:00:00Z'
    },
    events: [
      {
        id: 'ev-1',
        event_id: 'okta-ev-1',
        event_type: 'user.deprovisioned',
        status: 'dismissed',
        external_ids: ['ext-77'],
        reason: 'Contractor contract ended',
        review_reason: 'Keep temporary guest seat until Friday',
        reviewed_by: { tenant_id: 't1', uid: 'u_admin' },
        inserted_at: '2026-11-01T10:05:00Z'
      }
    ]
  }
  client.setQueryData(['pod-admin-directory', 'okta'], directoryPayload)

  try {
    const loadingHtml = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <I18nextProvider i18n={i18n}>
          <PodProviderDirectoryReview providerID="okta" membersLoading />
        </I18nextProvider>
      </QueryClientProvider>
    )
    expect(loadingHtml).toContain('data-slot="skeleton"')
    expect(loadingHtml).not.toContain('u_missing_raw')
    expect(loadingHtml).not.toContain('u_admin')
    expect(loadingHtml).toContain('Keep temporary guest seat until Friday')

    const settledHtml = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <I18nextProvider i18n={i18n}>
          <PodProviderDirectoryReview
            providerID="okta"
            members={[
              {
                uid: 'u_missing_raw',
                displayName: 'Grace Hopper',
                email: 'grace@example.test',
                membership: 'member',
                administrator: false,
                status: 'active',
                credentials: []
              },
              {
                uid: 'u_admin',
                displayName: 'Ada Lovelace',
                email: 'ada@example.test',
                membership: 'member',
                administrator: true,
                status: 'active',
                credentials: []
              }
            ]}
          />
        </I18nextProvider>
      </QueryClientProvider>
    )
    expect(settledHtml).toContain('Grace Hopper · grace@example.test')
    expect(settledHtml).toContain('Ada Lovelace')
    expect(settledHtml).toContain('Keep temporary guest seat until Friday')
  } finally {
    client.clear()
  }
})

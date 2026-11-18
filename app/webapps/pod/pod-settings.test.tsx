import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import type { PodAdminIdentityDirectoryResponse, PodAdminSettingsResponse } from './api/generated/types.gen'
import { GeneralSettings, ManagedAgent } from './pod-settings'
import { PodProviderDirectoryReview } from './pod-settings-directory'
import { PodSettingsModel } from './state/pod-settings'

test('General settings show no value for any field until the server has answered', async () => {
  await loadLocale('en-US')
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const model = new PodSettingsModel()
  const render = () =>
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <I18nextProvider i18n={i18n}>
          <GeneralSettings model={model} />
        </I18nextProvider>
      </QueryClientProvider>
    )

  try {
    // The first frame, before the response seeds the form, keeps the labels and shows skeletons in place of values.
    const loading = render()
    expect(loading).toContain('aria-busy="true"')
    expect(loading).toContain('Allow external guests')
    expect(loading).toContain('data-slot="skeleton"')
    expect(loading).not.toContain('role="checkbox"')
    expect(loading).not.toContain('role="combobox"')
    expect(loading).not.toContain('English')

    const settings: PodAdminSettingsResponse = {
      displayName: 'Acme Space',
      defaultLocale: 'zh-Hans-CN',
      allowExternalGuests: false,
      emailAvailable: true,
      loginPolicy: {
        allow_email_otp: true,
        allow_member_credential_change: true,
        require_sso_for_members: false,
        allow_invite_links: true,
        allowed_email_domains: []
      }
    }
    client.setQueryData(['pod-admin-settings'], settings)
    model.initialize('pod-1', settings)
    const loaded = render()
    expect(loaded).not.toContain('data-slot="skeleton"')
    expect(loaded).toContain('简体中文')
    expect(loaded).toContain('value="Acme Space"')
    // The guest policy is the first checkbox and shows the stored answer: off.
    expect(loaded.match(/role="checkbox"[^>]*aria-checked="(true|false)"/)?.[1]).toBe('false')
  } finally {
    client.clear()
  }
})

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

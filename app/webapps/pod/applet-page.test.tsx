import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { AppletRuntimeProvider, useTable, useTableRecords } from '@ankole/applet-sdk'
import type { AppletRuntime, BaseRecord, WriteResult } from '@ankole/applet-sdk/types'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToReadableStream, renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { setPodRuntimeBootstrap } from '../common/pod-bootstrap'
import { resolveAppletFrameTitle } from './applet-host'
import { AppletPage } from './applet-page'
import { contentKeys, type PageDetail } from './content-api'
import { ContentScope } from './content-context'
import { PageEmbed } from './document-embeds'
import { PageContent } from './page-content'
import { DocumentDraftModel } from './state/document-draft'

beforeAll(() => loadLocale('en-US'))

const appletID = '00112233-4455-6677-8899-aabbccddeeff'

function appletDetail(deletedAt: string | null): PageDetail {
  return {
    bindings: {},
    bindings_digest: '',
    page: {
      id: appletID,
      name: 'Revenue Simulator',
      title: 'Revenue Simulator',
      icon: '🧩',
      type: 'applet',
      position: 'a0',
      inherit_permissions: true,
      metadata: {},
      revision: 3,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T11:00:00Z',
      deleted_at: deletedAt,
      actions: ['node_view'],
      role: 'view'
    },
    ancestors: [],
    actions: ['node_view'],
    role: 'view',
    child_count: 0
  }
}

describe('Trashed Applet Pages remain inactive', () => {
  test('standalone trashed Applet Page renders the inactive notice without mounting an Applet runtime or iframe', async () => {
    const detail = appletDetail('2026-10-30T12:00:00Z')
    // Rendering without ContentScope proves neither useContent(), usePageRealtime(), nor mountApplet() runs.
    const directHtml = renderToStaticMarkup(<AppletPage detail={detail} />)
    const stream = await renderToReadableStream(<PageContent detail={detail} />)
    await stream.allReady
    const contentHtml = await new Response(stream).text()

    for (const html of [directHtml, contentHtml]) {
      expect(html).toContain('role="status"')
      expect(html).toContain(t('pod.content.applet_inactive_in_trash'))
      expect(html).not.toContain('<iframe')
      expect(html).not.toContain(t('pod.content.loading_applet'))
    }
  })

  test('embedded Applet Page stays inactive when either the host document or the embedded Applet is in Trash', () => {
    for (const [hostTrashed, embedDeletedAt] of [
      [true, null],
      [false, '2026-10-30T12:00:00Z']
    ] as const) {
      const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
      const draft = new DocumentDraftModel()
      client.setQueryData(contentKeys.page(appletID), appletDetail(embedDeletedAt))
      try {
        const html = renderToStaticMarkup(
          <QueryClientProvider client={client}>
            <PageEmbed
              attributes={{ ref: appletID }}
              canEdit={false}
              trashed={hostTrashed}
              model={draft}
              remove={() => {}}
              configure={() => {}}
              openPage={() => {}}
            />
          </QueryClientProvider>
        )
        expect(html).toContain('Revenue Simulator')
        expect(html).toContain(t('pod.content.applet_inactive_in_trash'))
        expect(html).not.toContain('<iframe')
        expect(html).not.toContain(t('pod.content.loading_applet'))
      } finally {
        draft[Symbol.dispose]()
        client.clear()
      }
    }
  })
})

describe('Applet iframe accessible title', () => {
  test('resolveAppletFrameTitle uses the trimmed Page title and falls back to the localized Applet label when blank', () => {
    expect(resolveAppletFrameTitle('  Revenue Simulator  ')).toBe('Revenue Simulator')
    expect(resolveAppletFrameTitle('')).toBe(t('pod.content.applet'))
    expect(resolveAppletFrameTitle('   ')).toBe(t('pod.content.applet'))
  })
})

describe('Applet continuity ownership claim button', () => {
  test('renders claim button when can_claim is true even if role !== manage and realtime.principal falls back to principalUID()', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    setPodRuntimeBootstrap({
      mode: 'desktop',
      platform: 'macos',
      workspaceKey: 'ws-1',
      podOrigin: 'https://pod.example.test',
      siteOrigin: 'https://site.example.test',
      tenantId: 'tenant-1',
      principalUid: 'pod-admin-uid',
      activePlugins: [],
      features: {},
      locale: 'en-US'
    })
    const contentValue = {
      realtime: { principal: undefined } as never,
      base: {} as never,
      readDenial: () => undefined,
      principals: async () => [],
      dispose() {},
      pageHref: (id: string) => `/pages/${id}`
    }

    try {
      const claimableByAdmin: PageDetail = {
        ...appletDetail(null),
        role: 'view',
        applet_owner: {
          continuity_active: true,
          can_claim: true,
          effective_name: 'Former Owner',
          effective_uid: 'former-owner',
          owner_uid: 'former-owner'
        }
      }
      const claimableHtml = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <ContentScope value={contentValue}>
            <AppletPage detail={claimableByAdmin} />
          </ContentScope>
        </QueryClientProvider>
      )
      expect(claimableHtml.replaceAll('&#x27;', "'")).toContain(t('pod.content.applet_continuity_banner'))
      expect(claimableHtml).toContain(t('pod.content.applet_claim_ownership'))

      const notClaimableDespiteManage: PageDetail = {
        ...appletDetail(null),
        role: 'manage',
        applet_owner: {
          continuity_active: true,
          can_claim: false,
          effective_name: 'Former Owner',
          effective_uid: 'former-owner',
          owner_uid: 'former-owner'
        }
      }
      const unclaimableHtml = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <ContentScope value={contentValue}>
            <AppletPage detail={notClaimableDespiteManage} />
          </ContentScope>
        </QueryClientProvider>
      )
      expect(unclaimableHtml.replaceAll('&#x27;', "'")).toContain(t('pod.content.applet_continuity_banner'))
      expect(unclaimableHtml).not.toContain(t('pod.content.applet_claim_ownership'))
    } finally {
      setPodRuntimeBootstrap(undefined)
      client.clear()
    }
  })
})

describe('Declarative table binding hooks', () => {
  test('useTable writes feed optimistic cell previews in useTableRecords and respect explicit enabled: false', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    const initialRow: BaseRecord = {
      id: 'rec_1',
      data: { 'fld-amount': 100 },
      versions: { 'fld-amount': 2 },
      created_at: '2026-11-01T00:00:00Z',
      updated_at: '2026-11-01T00:00:00Z',
      created_by: 'usr_1',
      updated_by: 'usr_1'
    }
    client.setQueryData(['base', 'table-b', 'records', {}], {
      records: [initialRow],
      complete: true,
      data_version: 1
    })

    let resolveWrite: ((value: WriteResult) => void) | undefined
    let disabledQueries = 0
    let triggerUpdate: (() => Promise<WriteResult>) | undefined
    let observedGatedFetchStatus: string | undefined

    function TestApplet() {
      const orders = useTable('orders')
      const live = useTableRecords('orders')
      const gated = useTableRecords('orders', {
        search: 'gated',
        filter: { conjunction: 'and', conditions: [{ field_id: 'fld-amount', operator: 'gt', value: 0 }] },
        enabled: false
      })
      observedGatedFetchStatus = gated.fetchStatus
      const row = live.data?.records[0]
      triggerUpdate = () => orders.update(initialRow, { amount: 250 })
      return (
        <div>
          <span data-amount={row ? String(orders.read(row).amount) : 'none'} />
          <span data-gated={String(gated.configured)} />
        </div>
      )
    }

    const runtime: AppletRuntime = {
      pageID: appletID,
      title: 'Orders',
      revision: 1,
      instanceID: 'inst_1',
      actions: ['node_view', 'node_contribute'],
      bindings: {
        orders: {
          tableId: 'table-b',
          fields: { amount: 'fld-amount' },
          status: 'ready',
          missing: [],
          required: true,
          description: null
        }
      },
      bindingsDigest: 'digest-1',
      queryClient: client,
      readDenial: () => undefined,
      principal: { uid: 'usr_1' },
      theme: 'light',
      embedded: false,
      base: {
        key: id => ['base', id],
        schema: async () => {
          throw new Error('unexpected schema')
        },
        records: async (_id, query) => {
          if (query.search === 'gated') disabledQueries++
          return { records: [initialRow], complete: true, data_version: 1 }
        },
        aggregate: async () => ({ groups: [], data_version: 1 }),
        write: () =>
          new Promise<WriteResult>(resolve => {
            resolveWrite = resolve
          }),
        subscribe: () => () => {}
      },
      routes: { key: () => ['routes'], call: async () => undefined as never },
      pod: {
        request: async () => undefined as never,
        fileURL: () => '',
        navigateToPage() {},
        openChat() {},
        principals: async () => []
      },
      runs: { key: id => ['run', id], get: async () => undefined as never, subscribe: () => () => {} },
      channel: () => ({
        presence: () => [],
        subscribe: () => () => {},
        on: () => () => {},
        close() {},
        broadcast: async () => {}
      })
    }

    const renderApplet = () =>
      renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <AppletRuntimeProvider runtime={runtime}>
            <TestApplet />
          </AppletRuntimeProvider>
        </QueryClientProvider>
      )

    try {
      expect(renderApplet()).toContain('data-amount="100"')
      expect(observedGatedFetchStatus).toBe('idle')
      expect(disabledQueries).toBe(0)

      const writePromise = triggerUpdate!()
      // While the Base write is still in flight, useTableRecords previews the pending logical edit immediately!
      expect(renderApplet()).toContain('data-amount="250"')

      await Promise.resolve()
      resolveWrite!({ records: [], deleted_ids: [], data_version: 2 })
      await writePromise
    } finally {
      client.clear()
    }
  })
})

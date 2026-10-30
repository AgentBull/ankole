import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToReadableStream, renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { AppletPage } from './applet-page'
import { contentKeys, type PageDetail } from './content-api'
import { PageEmbed } from './document-editor'
import { PageContent } from './page-content'
import { PageDraftModel } from './state/page-draft'

beforeAll(() => loadLocale('en-US'))

const appletID = '00112233-4455-6677-8899-aabbccddeeff'

function appletDetail(deletedAt: string | null): PageDetail {
  return {
    page: {
      id: appletID,
      title: 'Revenue Simulator',
      icon: '🧩',
      type: 'applet',
      position: 'a0',
      inherit_permissions: true,
      revision: 3,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T11:00:00Z',
      deleted_at: deletedAt,
      actions: ['page_view'],
      role: 'view'
    },
    ancestors: [],
    actions: ['page_view'],
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
      const draft = new PageDraftModel()
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

import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import { AppletBindingsTab, reconcileSlotDraft } from './applet-bindings'
import { contentKeys, type PageDetail } from './content-api'

beforeAll(() => loadLocale('en-US'))

function makeDetail(bindingsDigest: string): PageDetail {
  return {
    bindings: {},
    bindings_digest: bindingsDigest,
    page: {
      id: '00112233-4455-6677-8899-aabbccddeeff',
      name: 'QC Applet',
      title: 'QC Applet',
      icon: '🧩',
      type: 'applet',
      position: 'a0',
      inherit_permissions: true,
      metadata: {},
      revision: 1,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T11:00:00Z',
      deleted_at: null,
      actions: ['node_edit'],
      role: 'manage'
    },
    ancestors: [],
    actions: ['node_edit'],
    role: 'manage',
    child_count: 0
  }
}

describe('Applet bindings slot draft preservation', () => {
  test('reconcileSlotDraft preserves unsaved sibling edits and mid-save edits when server baseline updates', () => {
    const slotBPrevious = { signature: 'tbl_1:{}', table: 'tbl_1', fields: {} }
    // Sibling slot B was untouched on the server -> keep local unsaved table & field draft.
    expect(
      reconcileSlotDraft({ table: 'tbl_custom', fields: { status: 'fld_2' } }, slotBPrevious, slotBPrevious)
    ).toBeUndefined()

    // Even if another collaborator changed slot B on the server while user has dirty local edits, keep local draft.
    const slotBNext = { signature: 'tbl_remote:{"k":"f1"}', table: 'tbl_remote', fields: { k: 'f1' } }
    expect(
      reconcileSlotDraft({ table: 'tbl_custom', fields: { status: 'fld_2' } }, slotBPrevious, slotBNext)
    ).toBeUndefined()

    // Clean sibling slot adopts the new server values automatically.
    expect(reconcileSlotDraft({ table: 'tbl_1', fields: {} }, slotBPrevious, slotBNext)).toEqual({
      table: 'tbl_remote',
      fields: { k: 'f1' }
    })
  })

  test('changing detail.bindings_digest keeps previous query data mounted instead of falling back to ContentLoading', () => {
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false } }
    })
    const detailV1 = makeDetail('digest-v1')
    const detailV2 = makeDetail('digest-v2')
    const cachedBindings = {
      manifest: {
        tables: {
          primary: { tableId: 'tbl_a', required: true, fields: {} },
          secondary: { tableId: 'tbl_b', required: false, fields: {} }
        }
      },
      bindings: {
        primary: { tableId: 'tbl_a', status: 'ready', missing: [], fields: {} },
        secondary: { tableId: 'tbl_b', status: 'ready', missing: [], fields: {} }
      },
      overrides: {}
    }

    client.setQueryData([...contentKeys.page(detailV1.page.id), 'bindings', 'digest-v1'], cachedBindings)
    client.setQueryData([...contentKeys.all, 'binding-schema', 'tbl_a'], {
      table: { id: 'tbl_a', name: 'Orders' },
      fields: []
    })
    client.setQueryData([...contentKeys.all, 'binding-schema', 'tbl_b'], {
      table: { id: 'tbl_b', name: 'Audit Log' },
      fields: []
    })

    // Seed v2 cache to match what placeholderData: keepPreviousData preserves while v2 is fetching in the browser.
    client.setQueryData([...contentKeys.page(detailV2.page.id), 'bindings', 'digest-v2'], cachedBindings)
    try {
      const html = renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <AppletBindingsTab detail={detailV2} />
          </QueryClientProvider>
        </I18nextProvider>
      )
      expect(html).toContain('primary')
      expect(html).toContain('secondary')
      expect(html).toContain('Orders')
      expect(html).toContain('Audit Log')
    } finally {
      client.clear()
    }
  })
})

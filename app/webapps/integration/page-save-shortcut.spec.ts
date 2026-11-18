import { expect, test, type Page, type Route } from '@playwright/test'
import * as XLSX from 'xlsx'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import { pageRoute } from './pod-browser/routes'

type KeyCapture = {
  key: string
  metaKey: boolean
  ctrlKey: boolean
  repeat: boolean
  defaultPrevented: boolean
}

async function installSessionAndKeyProbe(page: Page) {
  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'person',
        displayName: 'Person',
        canManagePod: false,
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )
  await page.addInitScript(() => {
    const events: KeyCapture[] = []
    const tracked = new WeakMap<KeyboardEvent, KeyCapture>()
    const originalPreventDefault = Event.prototype.preventDefault
    Event.prototype.preventDefault = function () {
      if (this instanceof KeyboardEvent) {
        const entry = tracked.get(this)
        if (entry) entry.defaultPrevented = true
      }
      return originalPreventDefault.call(this)
    }
    Object.assign(window, {
      __saveKeyEvents: events,
      __clearSaveKeyEvents: () => {
        events.length = 0
      }
    })
    window.addEventListener(
      'keydown',
      event => {
        if (event.key.toLowerCase() === 's') {
          const entry: KeyCapture = {
            key: event.key,
            metaKey: event.metaKey,
            ctrlKey: event.ctrlKey,
            repeat: event.repeat,
            defaultPrevented: event.defaultPrevented
          }
          tracked.set(event, entry)
          events.push(entry)
        }
      },
      true
    )
  })
}

const readKeyEvents = (page: Page) =>
  page.evaluate(() => (window as unknown as { __saveKeyEvents: KeyCapture[] }).__saveKeyEvents)
const clearKeyEvents = (page: Page) =>
  page.evaluate(() => (window as unknown as { __clearSaveKeyEvents: () => void }).__clearSaveKeyEvents())

test('Document Page intercepts Mod+S, shows top-bar Saving status until the server replies, and avoids duplicate title or sync requests', async ({
  page
}) => {
  await page.setViewportSize({ width: 1280, height: 800 })
  await installSessionAndKeyProbe(page)

  const docID = '019a2b00-0000-7000-8000-000000000101'
  const viewerDocID = '019a2b00-0000-7000-8000-000000000102'
  let docTitle = 'Product Spec'
  const topicRevisions = new Map<string, number>()
  const revisionOf = (topic: string) => topicRevisions.get(topic) ?? 1
  let holdSync = false
  let holdChanges = false
  const pendingSyncReplies: (() => void)[] = []
  const pendingChangeReplies: (() => void)[] = []
  let syncCount = 0
  let changeCount = 0
  const pendingTitlePatches: Route[] = []
  let totalTitlePatches = 0

  await page.routeWebSocket('**/pod/socket/**', ws => {
    ws.onMessage(raw => {
      if (typeof raw !== 'string') return
      const [joinRef, ref, topic, event, payload] = JSON.parse(raw) as [
        string | null,
        string | null,
        string,
        string,
        Record<string, unknown>
      ]
      const reply = (response: unknown) => {
        ws.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]))
      }
      if (event === 'phx_join') {
        reply({
          presence_session: 'sess-doc',
          page: { id: topic.replace(/^page:/, ''), revision: revisionOf(topic) }
        })
        return
      }
      if (event === 'sync') {
        syncCount++
        const finish = () => reply({ revision: revisionOf(topic), changes: [] })
        if (holdSync) pendingSyncReplies.push(finish)
        else finish()
        return
      }
      if (event === 'changes') {
        changeCount++
        const finish = () => {
          const nextRevision = revisionOf(topic) + 1
          topicRevisions.set(topic, nextRevision)
          reply({
            revision: nextRevision,
            changes: [
              {
                revision: nextRevision,
                kind: 'change',
                client_id: payload.client_id,
                client_seq: payload.client_seq,
                changes: payload.changes
              }
            ]
          })
        }
        if (holdChanges) pendingChangeReplies.push(finish)
        else finish()
        return
      }
      reply({})
    })
  })

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()
    if (url.pathname === `/api/v2/pod/pages/${docID}`) {
      if (method === 'PATCH') {
        totalTitlePatches++
        docTitle = route.request().postDataJSON().data.title ?? docTitle
        pendingTitlePatches.push(route)
        return
      }
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_comment', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          content: { content: '<page><p>Initial paragraph</p></page>', plain_text: 'Initial paragraph' },
          page: {
            id: docID,
            title: docTitle,
            type: 'doc',
            position: 'a0',
            revision: revisionOf(`page:${docID}`),
            inherit_permissions: true,
            created_at: '2026-11-01T00:00:00Z',
            updated_at: '2026-11-01T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${viewerDocID}`) {
      return route.fulfill({
        json: {
          actions: ['node_view'],
          role: 'view',
          ancestors: [],
          child_count: 0,
          content: { content: '<page><p>Read-only body</p></page>', plain_text: 'Read-only body' },
          page: {
            id: viewerDocID,
            title: 'Read-only Doc',
            type: 'doc',
            position: 'a1',
            revision: 1,
            inherit_permissions: true,
            created_at: '2026-11-01T00:00:00Z',
            updated_at: '2026-11-01T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname.endsWith('/state')) return route.fulfill({ status: 204 })
    if (url.pathname.endsWith('/comments/summary')) return route.fulfill({ json: { total: 0, resolved_ids: [] } })
    if (url.pathname === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'test-token', principal: { uid: 'person', name: 'Person' } } })
    }
    if (url.pathname.endsWith('/children') || url.pathname === '/api/v2/pod/pages') {
      return route.fulfill({ json: { pages: [], can_create_space: true, can_create_private: true } })
    }
    if (url.pathname.endsWith('/attention')) return route.fulfill({ json: [] })
    if (url.pathname.endsWith('/agents')) return route.fulfill({ json: { agents: [] } })
    return route.fulfill({ json: { conversations: [], entries: [] } })
  })

  await page.goto(pageRoute(docID))
  const body = page.locator('.pod-document .editor-content')
  await expect(body).toContainText('Initial paragraph', { timeout: 15_000 })
  await expect(page.locator('header [data-sync-status="saved"]')).toBeVisible()
  await body.click()

  // 1. Clean Document Page + Meta+s triggers 1 sync, prevents default, and shows visible "Saving…" in top bar.
  await clearKeyEvents(page)
  const syncBefore = syncCount
  const changesBefore = changeCount
  holdSync = true
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingSyncReplies.length).toBe(1)
  expect(syncCount).toBe(syncBefore + 1)
  expect(changeCount).toBe(changesBefore)

  const savingBadge = page.locator('header [data-sync-status="saving"]')
  await expect(savingBadge).toBeVisible()
  const savingLabel = savingBadge.getByText('Saving…', { exact: true })
  await expect(savingLabel).toBeVisible()
  await expect(savingLabel).not.toHaveClass(/sr-only/)

  // Pressing Control+s or auto-repeating while already saving still prevents default without sending a 2nd request.
  await page.keyboard.press('Control+s')
  await page.evaluate(() => {
    document.activeElement?.dispatchEvent(
      new KeyboardEvent('keydown', { key: 's', metaKey: true, repeat: true, bubbles: true, cancelable: true })
    )
  })
  expect(syncCount).toBe(syncBefore + 1)
  const captured = await readKeyEvents(page)
  expect(captured.length).toBeGreaterThanOrEqual(3)
  expect(captured.every(entry => entry.defaultPrevented)).toBe(true)

  holdSync = false
  pendingSyncReplies.splice(0).forEach(reply => reply())
  await expect(page.locator('header [data-sync-status="saved"]')).toBeVisible()
  await expect(page.locator('header [data-sync-status="saved"] span')).toHaveClass(/sr-only/)

  // 2. Dirty Document body + Meta+s flushes changes immediately with 0 extra sync and shows visible "Saving…".
  const syncBeforeBodySave = syncCount
  const changesBeforeBodySave = changeCount
  holdChanges = true
  await page.keyboard.insertText('!')
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingChangeReplies.length).toBe(1)
  expect(changeCount).toBe(changesBeforeBodySave + 1)
  expect(syncCount).toBe(syncBeforeBodySave)
  await expect(savingBadge).toBeVisible()
  await expect(savingLabel).toBeVisible()

  holdChanges = false
  pendingChangeReplies.splice(0).forEach(reply => reply())
  await expect(page.locator('header [data-sync-status="saved"]')).toBeVisible()

  // 3. Dirty title + Control+s flushes the title PATCH immediately, skips redundant body sync, and cancels the 500ms timer.
  const title = page.getByRole('textbox', { name: 'Page title', exact: true })
  await title.click()
  await title.fill('Updated Spec Title')
  const syncBeforeTitleSave = syncCount
  await page.keyboard.press('Control+s')
  await expect.poll(() => pendingTitlePatches.length).toBe(1)
  await expect(savingBadge).toBeVisible()
  expect(syncCount).toBe(syncBeforeTitleSave)

  const patchRoute = pendingTitlePatches.shift()!
  await patchRoute.fulfill({
    json: {
      page: {
        id: docID,
        title: docTitle,
        type: 'doc',
        position: 'a0',
        revision: 1,
        inherit_permissions: true,
        created_at: '2026-11-01T00:00:00Z',
        updated_at: '2026-11-01T00:01:00Z'
      }
    }
  })
  await expect(page.locator('header [data-sync-status="saved"]')).toBeVisible()
  await page.waitForTimeout(600)
  expect(totalTitlePatches).toBe(1)

  // 3. Read-only Document Page does not intercept Mod+S or trigger saves.
  await page.goto(pageRoute(viewerDocID))
  await expect(page.locator('.pod-document')).toContainText('Read-only body')
  await clearKeyEvents(page)
  const syncBeforeViewer = syncCount
  await page.keyboard.press('Meta+s')
  const viewerEvents = await readKeyEvents(page)
  expect(viewerEvents).toHaveLength(1)
  expect(viewerEvents[0]!.defaultPrevented).toBe(false)
  expect(syncCount).toBe(syncBeforeViewer)
})

test('Spreadsheet, Base, and Knowledge Pages handle Mod+S in editable states with top-bar Saving status', async ({
  page
}) => {
  await page.setViewportSize({ width: 1280, height: 800 })
  await installSessionAndKeyProbe(page)

  const sheetID = '019a2b00-0000-7000-8000-000000000201'
  const baseID = '019a2b00-0000-7000-8000-000000000202'
  const tableID = '019a2b00-0000-7000-8000-000000000203'
  const knowledgeID = '019a2b00-0000-7000-8000-000000000204'

  const workbook = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([['Item', 'Amount']]), 'Sheet1')
  const workbookBytes = Buffer.from(XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' }))
  const sha256 = 'a'.repeat(64)

  let officeRevision = 1
  let holdOfficeApply = false
  let holdOfficeSync = false
  const pendingOfficeReplies: (() => void)[] = []
  let officeApplyCount = 0
  let officeSyncCount = 0

  let recordValue = 'Kickoff'
  const pendingRecordPatches: Route[] = []
  let totalRecordPatches = 0
  let holdBaseSync = false
  const pendingBaseSyncs: Route[] = []

  let knowledgeXML = '<page><p>Initial note</p></page>'
  let knowledgeRevision = 1
  let holdKnowledgeSync = false
  const pendingKnowledgeSyncs: Route[] = []
  const pendingKnowledgeWrites: Route[] = []

  await page.routeWebSocket('**/pod/socket/**', ws => {
    ws.onMessage(raw => {
      if (typeof raw !== 'string') return
      const [joinRef, ref, topic, event, payload] = JSON.parse(raw) as [
        string | null,
        string | null,
        string,
        string,
        Record<string, unknown>
      ]
      const reply = (response: unknown) => {
        ws.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]))
      }
      if (event === 'phx_join') {
        reply({
          presence_session: 'sess-office',
          page: { id: topic.replace(/^page:/, ''), revision: officeRevision }
        })
        return
      }
      if (event === 'office:sync') {
        officeSyncCount++
        const finish = () => reply({ revision: officeRevision, changes: [], reset_required: false })
        if (holdOfficeSync) pendingOfficeReplies.push(finish)
        else finish()
        return
      }
      if (event === 'office:apply') {
        officeApplyCount++
        const finish = () => {
          officeRevision++
          reply({
            revision: officeRevision,
            changes: [
              {
                revision: officeRevision,
                kind: 'op',
                client_id: payload.client_id,
                client_seq: payload.client_seq,
                op: payload.op
              }
            ]
          })
        }
        if (holdOfficeApply) pendingOfficeReplies.push(finish)
        else finish()
        return
      }
      reply({})
    })
  })

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()

    // Spreadsheet Page routes
    if (url.pathname === `/api/v2/pod/pages/${sheetID}`) {
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          page: {
            id: sheetID,
            title: 'Budget.xlsx',
            type: 'file',
            position: 'a0',
            revision: officeRevision,
            inherit_permissions: true,
            created_at: '2026-11-01T00:00:00Z',
            updated_at: '2026-11-01T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${sheetID}/files`) {
      return route.fulfill({
        json: {
          files: [
            {
              path: 'Budget.xlsx',
              sha256,
              size: workbookBytes.byteLength,
              content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              object_id: 'obj_budget',
              role: 'file'
            }
          ]
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${sheetID}/office`) {
      return route.fulfill({
        json: {
          format: 'spreadsheet',
          revision: officeRevision,
          file: { path: 'Budget.xlsx', sha256, object_id: 'obj_budget', size: workbookBytes.byteLength },
          ops: [],
          metadata: {}
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${sheetID}/files/content`) {
      return route.fulfill({
        status: 200,
        contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        body: workbookBytes
      })
    }

    // Base Page routes
    if (url.pathname === `/api/v2/pod/pages/${baseID}`) {
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_contribute', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          page: {
            id: baseID,
            title: 'Sprint Tracker',
            type: 'base',
            position: 'a1',
            revision: 1,
            inherit_permissions: true,
            created_at: '2026-11-01T00:00:00Z',
            updated_at: '2026-11-01T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/bases/${baseID}`) {
      if (holdBaseSync) {
        pendingBaseSyncs.push(route)
        return
      }
      return route.fulfill({
        json: {
          tables: [
            {
              id: tableID,
              page_id: baseID,
              name: 'Tasks',
              data_version: 1,
              record_count: 1,
              unique_field_ids: [],
              emit_changes: false
            }
          ]
        }
      })
    }
    if (url.pathname === `/api/v2/pod/tables/${tableID}`) {
      return route.fulfill({
        json: {
          table: {
            id: tableID,
            page_id: baseID,
            name: 'Tasks',
            data_version: 1,
            record_count: 1,
            unique_field_ids: [],
            emit_changes: false
          },
          fields: [{ id: 'f_title', name: 'Name', type: 'text', config: {}, version: 1, is_primary: true }],
          views: [{ id: 'v_grid', name: 'Grid', type: 'grid', version: 1, config: {} }],
          mode: 'remote',
          timezone: 'UTC',
          limits: { group_count: 50, query_rows: 200, record_bytes: 65536, statement_timeout_ms: 5000 },
          local_query: { jsonb_compare: true, text_contains_ascii: true }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/tables/${tableID}/query`) {
      return route.fulfill({
        json: {
          complete: true,
          data_version: 1,
          page_token: null,
          records: [
            {
              id: 'rec_1',
              created_at: '2026-11-01T00:00:00Z',
              created_by: 'person',
              updated_at: '2026-11-01T00:00:00Z',
              updated_by: 'person',
              versions: { f_title: 1 },
              data: { f_title: recordValue }
            }
          ]
        }
      })
    }
    if (url.pathname === `/api/v2/pod/tables/${tableID}/aggregate`) {
      return route.fulfill({ json: { groups: [{ values: [], metrics: { count: 1 } }] } })
    }
    if (url.pathname === `/api/v2/pod/tables/${tableID}/records` && method === 'POST') {
      totalRecordPatches++
      const body = route.request().postDataJSON()
      const updated = body.data?.update?.[0]
      if (updated?.data?.f_title !== undefined) recordValue = updated.data.f_title
      pendingRecordPatches.push(route)
      return
    }

    // Knowledge Page routes
    if (url.pathname === `/api/v2/pod/pages/${knowledgeID}`) {
      if (holdKnowledgeSync && method === 'GET') {
        pendingKnowledgeSyncs.push(route)
        return
      }
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          content: { content: knowledgeXML, plain_text: 'Initial note' },
          page: {
            id: knowledgeID,
            title: 'Architecture Note',
            type: 'knowledge',
            position: 'a2',
            revision: knowledgeRevision,
            metadata: { summary: 'Initial' },
            inherit_permissions: true,
            created_at: '2026-11-01T00:00:00Z',
            updated_at: '2026-11-01T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${knowledgeID}/content` && method === 'PUT') {
      pendingKnowledgeWrites.push(route)
      return
    }

    if (url.pathname.endsWith('/state')) return route.fulfill({ status: 204 })
    if (url.pathname.endsWith('/comments/summary')) return route.fulfill({ json: { total: 0, resolved_ids: [] } })
    if (url.pathname === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'test-token', principal: { uid: 'person', name: 'Person' } } })
    }
    if (url.pathname.endsWith('/children') || url.pathname === '/api/v2/pod/pages') {
      return route.fulfill({ json: { pages: [], can_create_space: true, can_create_private: true } })
    }
    if (url.pathname.endsWith('/attention')) return route.fulfill({ json: [] })
    if (url.pathname.endsWith('/agents')) return route.fulfill({ json: { agents: [] } })
    return route.fulfill({ json: { conversations: [], entries: [], links: [], backlinks: [] } })
  })

  const topBarSaving = page.locator('header [data-page-save-status="saving"]')

  // --- A. Spreadsheet Page (.xlsx) ---
  await page.goto(pageRoute(sheetID))
  const cellEditor = page.locator('[data-spreadsheet-cell-editor]')
  // The first visit compiles the lazy spreadsheet modules in the Vite server.
  await expect(cellEditor).toBeAttached({ timeout: 20_000 })
  await expect.poll(() => officeSyncCount).toBeGreaterThanOrEqual(1)
  await cellEditor.focus()

  // Clean spreadsheet + Meta+s -> 1 office:sync and top-bar "Saving…" while pending.
  await clearKeyEvents(page)
  const sheetSyncBefore = officeSyncCount
  holdOfficeSync = true
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingOfficeReplies.length).toBe(1)
  expect(officeSyncCount).toBe(sheetSyncBefore + 1)
  await expect(topBarSaving).toBeVisible()
  await expect(topBarSaving).toContainText('Saving…')
  const sheetKeys = await readKeyEvents(page)
  expect(sheetKeys).toHaveLength(1)
  expect(sheetKeys[0]!.defaultPrevented).toBe(true)

  holdOfficeSync = false
  pendingOfficeReplies.splice(0).forEach(reply => reply())
  await expect(topBarSaving).toHaveCount(0)

  // Open cell draft + Control+s -> commits draft via 1 office:apply without extra office:sync.
  await page.keyboard.type('256')
  const syncBeforeApply = officeSyncCount
  holdOfficeApply = true
  await page.keyboard.press('Control+s')
  await expect.poll(() => pendingOfficeReplies.length).toBe(1)
  expect(officeApplyCount).toBe(1)
  expect(officeSyncCount).toBe(syncBeforeApply)
  await expect(topBarSaving).toBeVisible()

  holdOfficeApply = false
  pendingOfficeReplies.splice(0).forEach(reply => reply())
  await expect(topBarSaving).toHaveCount(0)

  // --- B. Base Page ---
  await page.goto(pageRoute(baseID))
  const firstBaseCell = page.locator('.pod-base-grid [data-grid-record="rec_1"] input').first()
  await expect(firstBaseCell).toBeVisible()
  await firstBaseCell.click()
  await firstBaseCell.fill('Kickoff Updated')

  await clearKeyEvents(page)
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingRecordPatches.length).toBe(1)
  await expect(topBarSaving).toBeVisible()
  await expect(topBarSaving).toContainText('Saving…')
  const baseKeys = await readKeyEvents(page)
  expect(baseKeys).toHaveLength(1)
  expect(baseKeys[0]!.defaultPrevented).toBe(true)

  const recordPatch = pendingRecordPatches.shift()!
  await recordPatch.fulfill({
    json: {
      data_version: 2,
      records: [
        {
          id: 'rec_1',
          created_at: '2026-11-01T00:00:00Z',
          created_by: 'person',
          updated_at: '2026-11-01T00:01:00Z',
          updated_by: 'person',
          versions: { f_title: 2 },
          data: { f_title: recordValue }
        }
      ]
    }
  })
  await expect(topBarSaving).toHaveCount(0)
  // Blurring after Mod+S does not fire a duplicate PATCH.
  await firstBaseCell.blur()
  expect(totalRecordPatches).toBe(1)

  // Clean Base Page + Control+s -> 1 tables refresh with top-bar Saving… until fulfilled.
  holdBaseSync = true
  await page.keyboard.press('Control+s')
  await expect.poll(() => pendingBaseSyncs.length).toBe(1)
  await expect(topBarSaving).toBeVisible()
  holdBaseSync = false
  await pendingBaseSyncs.shift()!.fulfill({
    json: {
      tables: [
        {
          id: tableID,
          page_id: baseID,
          name: 'Tasks',
          data_version: 1,
          record_count: 1,
          unique_field_ids: [],
          emit_changes: false
        }
      ]
    }
  })
  await expect(topBarSaving).toHaveCount(0)

  // --- C. Knowledge Page (Reader mode vs Edit mode) ---
  await page.goto(pageRoute(knowledgeID))
  const editButton = page.locator('[data-knowledge-page]').getByRole('button', { name: 'Edit', exact: true })
  await expect(editButton).toBeVisible()
  await editButton.focus()

  // Reader mode (outside title input) does not intercept Mod+S.
  await clearKeyEvents(page)
  await page.keyboard.press('Meta+s')
  const readerEvents = await readKeyEvents(page)
  expect(readerEvents).toHaveLength(1)
  expect(readerEvents[0]!.defaultPrevented).toBe(false)
  expect(pendingKnowledgeWrites).toHaveLength(0)

  // Entering Edit mode while clean makes Mod+S perform 1 GET refresh (0 PUTs), stay in Edit mode,
  // and rebase onto any remote revision before the author types.
  await editButton.click()
  let knowledgeEditor = page.locator('[data-knowledge-page] .editor-content[contenteditable]').last()
  await expect(knowledgeEditor).toBeVisible()
  await expect(knowledgeEditor).toBeFocused()

  knowledgeRevision = 2
  knowledgeXML = '<page><p>Remote note v2</p></page>'
  holdKnowledgeSync = true
  await clearKeyEvents(page)
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingKnowledgeSyncs.length).toBe(1)
  expect(pendingKnowledgeWrites).toHaveLength(0)
  await expect(topBarSaving).toBeVisible()
  const cleanKnowledgeKeys = await readKeyEvents(page)
  expect(cleanKnowledgeKeys).toHaveLength(1)
  expect(cleanKnowledgeKeys[0]!.defaultPrevented).toBe(true)

  holdKnowledgeSync = false
  await pendingKnowledgeSyncs.shift()!.fulfill({
    json: {
      actions: ['node_view', 'node_edit', 'node_manage'],
      role: 'manage',
      ancestors: [],
      child_count: 0,
      content: { content: knowledgeXML, plain_text: 'Remote note v2' },
      page: {
        id: knowledgeID,
        title: 'Architecture Note',
        type: 'knowledge',
        position: 'a2',
        revision: knowledgeRevision,
        metadata: { summary: 'Initial' },
        inherit_permissions: true,
        created_at: '2026-11-01T00:00:00Z',
        updated_at: '2026-11-01T00:01:00Z'
      }
    }
  })
  await expect(topBarSaving).toHaveCount(0)
  knowledgeEditor = page.locator('[data-knowledge-page] .editor-content[contenteditable]').last()
  await expect(knowledgeEditor).toBeVisible()
  await expect(knowledgeEditor).toContainText('Remote note v2')

  // Dirty Edit mode + Mod+S submits 1 PUT with the rebased base_revision (2) and shows Saving… until fulfilled.
  await knowledgeEditor.locator('p').first().click()
  await page.keyboard.insertText(' updated')

  await clearKeyEvents(page)
  await page.keyboard.press('Meta+s')
  await expect.poll(() => pendingKnowledgeWrites.length).toBe(1)
  await expect(topBarSaving).toBeVisible()
  const knowledgeKeys = await readKeyEvents(page)
  expect(knowledgeKeys).toHaveLength(1)
  expect(knowledgeKeys[0]!.defaultPrevented).toBe(true)

  const writeRoute = pendingKnowledgeWrites.shift()!
  expect(writeRoute.request().postDataJSON().data.base_revision).toBe(2)
  knowledgeRevision++
  knowledgeXML = '<page><p>Remote note v2 updated</p></page>'
  await writeRoute.fulfill({
    json: {
      content: { content: knowledgeXML, plain_text: 'Remote note v2 updated' },
      page: {
        id: knowledgeID,
        title: 'Architecture Note',
        type: 'knowledge',
        position: 'a2',
        revision: knowledgeRevision,
        metadata: { summary: 'Initial' },
        inherit_permissions: true,
        created_at: '2026-11-01T00:00:00Z',
        updated_at: '2026-11-01T00:02:00Z'
      }
    }
  })
  await expect(topBarSaving).toHaveCount(0)
})

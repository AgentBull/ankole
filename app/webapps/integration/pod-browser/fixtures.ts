import { readFileSync } from 'node:fs'
import { expect, type BrowserContext, type Page } from '@playwright/test'

export type Login = { uid: string; email: string; password: string }
type Identity = Login & { cookies: Parameters<BrowserContext['addCookies']>[0] }

type State = {
  base_url: string
  tenant_id: string
  tenant_slug: string
  original_site_locale: string
  report_id: string
  database_id: string
  table_id: string
  amount_field_id: string
  status_field_id: string
  applet_id: string
  runtime_test_applet_id: string
  backend_report_id: string
  backend_database_id: string
  backend_applet_id: string
  backend_table_id: string
  backend_stock_field_id: string
  backend_record_id: string
  backend_publish_v2_files: unknown[]
  conversation_id: string
  chat_controls_conversation_id: string
  chat_controls_reply_id: string
  chat_regenerate_conversation_id: string
  chat_regenerate_reply_id: string
  chat_failed_conversation_id: string
  chat_failed_reply_id: string
  history_conversation_id: string
  recovery_conversation_id: string
  message_id: string
  chat_text: string
  chat_attachment_name: string
  publish_v2_files: unknown[]
  owner: Identity
  member: Identity
  viewer: Identity
  other_pod: Login & { base_url: string; page_id: string }
  agent_uid: string
}

const statePath = process.env.POD_BROWSER_STATE_PATH
if (!statePath) throw new Error('Start the dedicated real Pod browser fixture and set POD_BROWSER_STATE_PATH')
export const state = JSON.parse(readFileSync(statePath, 'utf8')) as State

export async function login(page: Page, credentials: Login) {
  await page.getByRole('textbox', { name: '邮箱', exact: true }).fill(credentials.email)
  await page.getByLabel('密码', { exact: true }).fill(credentials.password)
  const completed = page.waitForResponse(
    response =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === '/api/v2/browser/sessions/local-password'
  )
  await page.getByRole('button', { name: '登录', exact: true }).click()
  expect((await completed).status()).toBe(201)
}

// Return the actual HTTP status for tests of rejected capability calls.
export async function requestResponse(page: Page, path: string, method = 'GET', body?: unknown, revision?: number) {
  return page.evaluate(
    async ({ path, method, body, revision }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const applet = /^\/pages\/[^/]+\/routes(?:\/|$)/.test(path)
      const mediaType = applet ? 'application/json' : 'application/vnd.api+json'
      const response = await fetch(`/api/v2/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: mediaType,
          'content-type': mediaType,
          'x-csrf-token': meta('csrf-token'),
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          ...(revision === undefined ? {} : { 'x-ankole-applet-revision': String(revision) })
        },
        ...(body === undefined ? {} : { body: JSON.stringify(applet ? body : { data: body }) })
      })
      return { status: response.status, body: response.status === 204 ? null : await response.json() }
    },
    { path, method, body, revision }
  )
}

export async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  const response = await requestResponse(page, path, method, body)
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Real Pod API ${method} ${path} failed: ${response.status} ${JSON.stringify(response.body)}`)
  }
  return response.body
}

// These setup writes need a current sharing version. Stale-version tests use request directly.
export async function requestWithSharingVersion<T>(
  page: Page,
  path: string,
  method = 'GET',
  body?: unknown
): Promise<T> {
  if (method === 'PUT' && path.endsWith('/sharing')) {
    const baseline = await request<{ sharing_version: string }>(page, path)
    body = { ...(body as Record<string, unknown>), sharing_version: baseline.sharing_version }
  }
  return request<T>(page, path, method, body)
}

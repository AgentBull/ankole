import 'reflect-metadata'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { Principals } = await import('@/common/db-schema')
const { createWebServer } = await import('@/core/web-server')
const { ensureBuiltInAdminGroup } = await import('@/principals/authorization/groups')
const { insertMembership } = await import('@/principals/authorization/memberships')
const { createHuman } = await import('@/principals/human-users/service')
const { ADMIN_SESSION_COOKIE, cookieHeader, createAdminSessionCookie } = await import('@/principals/admin-auth/session')

const webServer = await createWebServer({ serveStaticAssets: false })
const testPrefix = `test_console_routes_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
let adminCookie = ''

beforeEach(async () => {
  await clearTestRows()
  const adminUid = `${testPrefix}_admin`
  await createHuman({ uid: adminUid })
  const adminGroup = await ensureBuiltInAdminGroup()
  await insertMembership(adminUid, adminGroup.id)
  adminCookie = cookieHeader(
    ADMIN_SESSION_COOKIE,
    createAdminSessionCookie({
      principalUid: adminUid,
      providerId: 'test',
      externalId: 'test-admin'
    }),
    { secure: false }
  )
})

afterEach(async () => {
  await clearTestRows()
})

describe('console routes error responses', () => {
  it('returns JSON for non-domain errors raised inside console routes', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/console/agents', {
        method: 'POST',
        headers: {
          Origin: 'http://localhost',
          'Content-Type': 'application/json',
          Cookie: adminCookie
        },
        body: JSON.stringify({ uid: '' })
      })
    )

    expect(response.status).toBe(422)
    expect(response.headers.get('content-type')).toContain('application/json')
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: 422
      }
    })
  })
})

async function clearTestRows(): Promise<void> {
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
}

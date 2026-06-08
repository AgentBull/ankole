import { Elysia, t } from 'elysia'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { activeHumanAdmin } from '@/principals/admin-auth/access'
import { readAdminSessionCookie } from '@/principals/admin-auth/session'
import {
  type HeartbeatInput,
  listWorkers,
  recordHeartbeat,
  type RegisterWorkerInput,
  registerWorker,
  removeAgentPin,
  resolveComputerWorker,
  ComputerDomainError,
  setAgentPin
} from './service'

const jsonObject = t.Record(t.String(), t.Unknown())

const registerBody = t.Object({
  workerId: t.String({ minLength: 1 }),
  instanceId: t.String({ minLength: 1 }),
  baseUrl: t.String({ minLength: 1 }),
  version: t.Optional(t.Union([t.String(), t.Null()])),
  features: t.Optional(t.Array(t.String())),
  capacity: t.Optional(jsonObject),
  metadata: t.Optional(jsonObject)
})

const heartbeatBody = t.Object({
  workerId: t.String({ minLength: 1 }),
  instanceId: t.String({ minLength: 1 }),
  status: t.Optional(t.String()),
  runningSessions: t.Optional(t.Number()),
  runningCommands: t.Optional(t.Number()),
  load: t.Optional(jsonObject)
})

const resolveBody = t.Object({ agentUid: t.String({ minLength: 1 }) })

const pinBody = t.Object({
  agentUid: t.String({ minLength: 1 }),
  workerId: t.String({ minLength: 1 }),
  reason: t.Optional(t.Union([t.String(), t.Null()]))
})

export function computerRoutes() {
  return new Elysia({ name: 'computer-routes' })
    .onError(({ code, error, set }) => {
      if (error instanceof ComputerDomainError) {
        set.status = error.status
        return { error: { code: error.code, message: error.message } }
      }
      const status =
        typeof error === 'object' && error && 'status' in error && typeof error.status === 'number' ? error.status : 500
      if (status >= 500) logger.error({ error, code }, 'Computer API Error')
      else logger.warn({ error, code }, 'Computer API Error')
      set.status = status
      return { error: { code: 'computer_error', message: error instanceof Error ? error.message : String(error) } }
    })
    .post(
      '/internal/computer/workers/register',
      ({ body, request }) => {
        requireServiceAuth(request)
        return registerWorker(body as RegisterWorkerInput).then(() => ({ ok: true }))
      },
      { body: registerBody }
    )
    .post(
      '/internal/computer/workers/heartbeat',
      ({ body, request }) => {
        requireServiceAuth(request)
        return recordHeartbeat(body as HeartbeatInput).then(() => ({ ok: true }))
      },
      { body: heartbeatBody }
    )
    .post(
      '/internal/computer/sessions/resolve',
      ({ body, request }) => {
        requireServiceAuth(request)
        return resolveComputerWorker(body.agentUid)
      },
      { body: resolveBody }
    )
    .get('/api/console/computer/workers', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { workers: await listWorkers() }
    })
    .post(
      '/api/console/computer/pins',
      async ({ body, request, set }) => {
        const { principalUid } = await requireConsoleAdmin(request)
        await setAgentPin({ ...body, createdByPrincipalUid: principalUid })
        set.status = 201
        return { ok: true }
      },
      { body: pinBody }
    )
    .delete('/api/console/computer/pins/:agentUid', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      await removeAgentPin(params.agentUid)
      set.status = 204
    })
}

/**
 * Internal service-to-service auth: workers (and external SDK callers) present the
 * shared `BULLX_COMPUTER_TOKEN` as a Bearer token. When the secret is unset (dev),
 * the check is skipped.
 */
function requireServiceAuth(request: Request): void {
  const expected = AppEnv.BULLX_COMPUTER_TOKEN
  if (!expected) return
  const header = request.headers.get('authorization')
  const token = header?.startsWith('Bearer ') ? header.slice('Bearer '.length) : undefined
  if (token !== expected) throw new ComputerDomainError(401, 'unauthorized', 'invalid computer service token')
}

async function requireConsoleAdmin(request: Request): Promise<{ principalUid: string }> {
  const session = readAdminSessionCookie(request.headers.get('cookie'))
  if (session && (await activeHumanAdmin(session.principalUid))) {
    return { principalUid: session.principalUid }
  }
  throw new ComputerDomainError(401, 'unauthorized', 'admin session required')
}

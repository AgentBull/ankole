import { Elysia } from 'elysia'
import { z } from 'zod'
import { logger } from '@/common/logger'
import { AiAgentModelsConfigSchema } from '@/ai-agent/config'
import { AppEnv } from '@/config/env'
import {
  LlmProviderCheckInputSchema,
  LlmProviderCreateInputSchema,
  LlmProviderUpdateInputSchema,
  checkLlmProvider,
  createLlmProvider,
  deleteLlmProvider,
  getLlmProvider,
  listLlmProviderModels,
  listLlmProviders,
  listPiLlmProviders,
  updateLlmProvider
} from '@/llm-providers/service'
import { activeHumanAdmin } from '@/principals/admin-auth/access'
import { readAdminSessionCookie } from '@/principals/admin-auth/session'
import {
  ConsoleDomainError,
  createConsoleAgent,
  createConsoleChatChannel,
  deleteConsoleAgent,
  deleteConsoleChatChannel,
  deleteConsoleInteractiveConfigSession,
  getConsoleAgent,
  getConsoleInteractiveConfigSession,
  listConsoleAgents,
  listConsoleExternalGatewayAdapters,
  listConsoleExternalRooms,
  startConsoleInteractiveConfigSession,
  updateConsoleAgent,
  updateConsoleChatChannel
} from './service'
import type { JsonObject } from '@/common/db-schema'

const jsonObjectSchema = z.custom<JsonObject>(
  value => typeof value === 'object' && value !== null && !Array.isArray(value)
)

const createAgentBodySchema = z
  .object({
    uid: z.string().min(1),
    displayName: z.string().nullable().optional(),
    avatarUrl: z.string().nullable().optional(),
    llmProfile: z
      .object({
        models: AiAgentModelsConfigSchema
      })
      .strict()
      .optional()
  })
  .strict()

const updateAgentBodySchema = z
  .object({
    displayName: z.string().nullable().optional(),
    avatarUrl: z.string().nullable().optional(),
    llmProfile: z
      .object({
        models: AiAgentModelsConfigSchema
      })
      .strict()
      .optional()
  })
  .strict()

const updateLlmProviderBodySchema = LlmProviderUpdateInputSchema.omit({ providerId: true })

const upsertChatChannelBodySchema = z
  .object({
    name: z.string().min(1).optional(),
    adapter: z.string().min(1).optional(),
    enabled: z.boolean().optional(),
    config: jsonObjectSchema.optional()
  })
  .strict()

const interactiveConfigBodySchema = z
  .object({
    adapterId: z.string().min(1),
    currentConfig: jsonObjectSchema.optional(),
    locale: z.string().optional()
  })
  .strict()

type MutableResponseSet = {
  status?: number | string
}

export function consoleRoutes() {
  return new Elysia({ name: 'console-routes' })
    .onError(({ code, error, set }) => {
      if (error instanceof ConsoleDomainError) {
        set.status = error.status
        return { error: error.message }
      }

      const status = statusFromError(error)
      const isInternalServerError = status >= 500
      isInternalServerError
        ? logger.error({ error, code }, 'Console API Error')
        : logger.warn({ error, code }, 'Console API Error')
      set.status = status
      return {
        error: {
          code: status,
          status: String(code),
          message:
            AppEnv.IS_PRODUCTION && isInternalServerError
              ? 'Internal Server Error'
              : error instanceof Error
                ? error.message
                : String(error)
        }
      }
    })
    .get('/api/console/external-gateway-adapters', async ({ request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { adapters: await listConsoleExternalGatewayAdapters() }
    })
    .get('/api/console/llm-providers', async ({ request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return {
        providers: await listLlmProviders(),
        piProviders: listPiLlmProviders()
      }
    })
    .post('/api/console/llm-providers', async ({ body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = LlmProviderCreateInputSchema.parse(body)
      set.status = 201
      return { provider: await createLlmProvider(parsed) }
    })
    .post('/api/console/llm-providers/check', async ({ body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = LlmProviderCheckInputSchema.parse(body)
      return await checkLlmProvider(parsed)
    })
    .get('/api/console/llm-providers/:providerId', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { provider: await getLlmProvider(params.providerId) }
    })
    .put('/api/console/llm-providers/:providerId', async ({ params, body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = updateLlmProviderBodySchema.parse(body)
      return { provider: await updateLlmProvider({ providerId: params.providerId, ...parsed }) }
    })
    .delete('/api/console/llm-providers/:providerId', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      await deleteLlmProvider(params.providerId)
      set.status = 204
    })
    .get('/api/console/llm-providers/:providerId/models', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { models: await listLlmProviderModels(params.providerId) }
    })
    .get('/api/console/agents', async ({ request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { agents: await listConsoleAgents() }
    })
    .post('/api/console/agents', async ({ body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = createAgentBodySchema.parse(body)
      set.status = 201
      return { agent: await createConsoleAgent(parsed.uid, admin.principalUid, parsed) }
    })
    .get('/api/console/agents/:uid', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { agent: await getConsoleAgent(params.uid) }
    })
    .put('/api/console/agents/:uid', async ({ params, body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = updateAgentBodySchema.parse(body)
      return { agent: await updateConsoleAgent(params.uid, parsed) }
    })
    .delete('/api/console/agents/:uid', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      await deleteConsoleAgent(params.uid)
      set.status = 204
    })
    .get('/api/console/agents/:uid/chat-channels', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { channels: await listConsoleExternalRooms(params.uid) }
    })
    .post('/api/console/agents/:uid/chat-channels', async ({ params, body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = upsertChatChannelBodySchema.parse(body)
      set.status = 201
      return { channel: await createConsoleChatChannel(params.uid, parsed) }
    })
    .put('/api/console/agents/:uid/chat-channels/:channelName', async ({ params, body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = upsertChatChannelBodySchema.parse(body)
      return { channel: await updateConsoleChatChannel(params.uid, params.channelName, parsed) }
    })
    .delete('/api/console/agents/:uid/chat-channels/:channelName', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      await deleteConsoleChatChannel(params.uid, params.channelName)
      set.status = 204
    })
    .post('/api/console/interactive-config-sessions', async ({ body, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      const parsed = interactiveConfigBodySchema.parse(body)
      set.status = 201
      return { session: await startConsoleInteractiveConfigSession(parsed) }
    })
    .get('/api/console/interactive-config-sessions/:sessionId', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      return { session: getConsoleInteractiveConfigSession(params.sessionId) }
    })
    .delete('/api/console/interactive-config-sessions/:sessionId', async ({ params, request, set }) => {
      const admin = await requireConsoleAdmin(request, set)
      if (!admin.ok) return { error: admin.error }

      deleteConsoleInteractiveConfigSession(params.sessionId)
      set.status = 204
    })
}

function statusFromError(error: unknown): number {
  if (error instanceof z.ZodError) return 422
  if (typeof error === 'object' && error && 'status' in error && typeof error.status === 'number') return error.status

  return 500
}

async function requireConsoleAdmin(
  request: Request,
  set: MutableResponseSet
): Promise<{ ok: true; principalUid: string } | { ok: false; error: string }> {
  const session = readAdminSessionCookie(request.headers.get('cookie'))
  if (session && (await activeHumanAdmin(session.principalUid))) {
    return { ok: true, principalUid: session.principalUid }
  }

  set.status = 401
  return { ok: false, error: 'admin session required' }
}

import { Elysia } from 'elysia'
import { z } from 'zod'
import { statusFromError } from '@/common/errors'
import { logger } from '@/common/logger'
import { AiAgentModelsConfigSchema } from '@/ai-agent/config'
import { AppEnv } from '@/config/env'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'
import type { JsonObject } from '@/common/db-schema'
import type { UpsertConsoleAgentInput } from './service'
import {
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

// Loose JSON object body fragment. Deep domain validation stays in the service
// layer, so route schemas only describe request shape for Eden Treaty.
const jsonObjectBody = appConfigJsonRecordSchema as z.ZodType<JsonObject>

const llmProviderCreateBody = z.object({
  providerId: z.string().min(1),
  piProvider: z.string().min(1),
  baseUrl: z.string().nullable().optional(),
  apiKey: z.string().nullable().optional(),
  providerOptions: jsonObjectBody.optional()
})

const llmProviderUpdateBody = z.object({
  piProvider: z.string().min(1).optional(),
  baseUrl: z.string().nullable().optional(),
  apiKey: z.string().nullable().optional(),
  providerOptions: jsonObjectBody.optional()
})

const llmProviderCheckBody = z.object({
  providerId: z.string().min(1).optional(),
  piProvider: z.string().min(1).optional(),
  model: z.string().min(1).optional(),
  baseUrl: z.string().nullable().optional(),
  apiKey: z.string().nullable().optional(),
  providerOptions: jsonObjectBody.optional()
})

const llmProfileBody = z.object({ models: z.unknown() }).optional()

const createAgentBody = z.object({
  uid: z.string().min(1),
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  llmProfile: llmProfileBody
})

const updateAgentBody = z.object({
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  llmProfile: llmProfileBody
})

const upsertChatChannelBody = z.object({
  name: z.string().min(1).optional(),
  adapter: z.string().min(1).optional(),
  enabled: z.boolean().optional(),
  config: jsonObjectBody.optional()
})

const interactiveConfigBody = z.object({
  adapterId: z.string().min(1),
  currentConfig: jsonObjectBody.optional(),
  locale: z.string().optional()
})

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
    .get('/api/console/external-gateway-adapters', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { adapters: await listConsoleExternalGatewayAdapters() }
    })
    .get('/api/console/llm-providers', async ({ request }) => {
      await requireConsoleAdmin(request)
      return {
        providers: await listLlmProviders(),
        piProviders: listPiLlmProviders()
      }
    })
    .post(
      '/api/console/llm-providers',
      async ({ body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { provider: await createLlmProvider(body) }
      },
      { body: llmProviderCreateBody }
    )
    .post(
      '/api/console/llm-providers/check',
      async ({ body, request }) => {
        await requireConsoleAdmin(request)
        return await checkLlmProvider(body)
      },
      { body: llmProviderCheckBody }
    )
    .get('/api/console/llm-providers/:providerId', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { provider: await getLlmProvider(params.providerId) }
    })
    .put(
      '/api/console/llm-providers/:providerId',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { provider: await updateLlmProvider({ providerId: params.providerId, ...body }) }
      },
      { body: llmProviderUpdateBody }
    )
    .delete('/api/console/llm-providers/:providerId', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      await deleteLlmProvider(params.providerId)
      set.status = 204
    })
    .get('/api/console/llm-providers/:providerId/models', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { models: await listLlmProviderModels(params.providerId) }
    })
    .get('/api/console/agents', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { agents: await listConsoleAgents() }
    })
    .post(
      '/api/console/agents',
      async ({ body, request, set }) => {
        const { principalUid } = await requireConsoleAdmin(request)
        set.status = 201
        return { agent: await createConsoleAgent(body.uid, principalUid, agentInput(body)) }
      },
      { body: createAgentBody }
    )
    .get('/api/console/agents/:uid', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { agent: await getConsoleAgent(params.uid) }
    })
    .put(
      '/api/console/agents/:uid',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { agent: await updateConsoleAgent(params.uid, agentInput(body)) }
      },
      { body: updateAgentBody }
    )
    .delete('/api/console/agents/:uid', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      await deleteConsoleAgent(params.uid)
      set.status = 204
    })
    .get('/api/console/agents/:uid/chat-channels', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { channels: await listConsoleExternalRooms(params.uid) }
    })
    .post(
      '/api/console/agents/:uid/chat-channels',
      async ({ params, body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { channel: await createConsoleChatChannel(params.uid, body) }
      },
      { body: upsertChatChannelBody }
    )
    .put(
      '/api/console/agents/:uid/chat-channels/:channelName',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { channel: await updateConsoleChatChannel(params.uid, params.channelName, body) }
      },
      { body: upsertChatChannelBody }
    )
    .delete('/api/console/agents/:uid/chat-channels/:channelName', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      await deleteConsoleChatChannel(params.uid, params.channelName)
      set.status = 204
    })
    .post(
      '/api/console/interactive-config-sessions',
      async ({ body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { session: await startConsoleInteractiveConfigSession(body) }
      },
      { body: interactiveConfigBody }
    )
    .get('/api/console/interactive-config-sessions/:sessionId', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { session: getConsoleInteractiveConfigSession(params.sessionId) }
    })
    .delete('/api/console/interactive-config-sessions/:sessionId', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      deleteConsoleInteractiveConfigSession(params.sessionId)
      set.status = 204
    })
}

/**
 * Coerces a route-validated agent body into the service input, validating the
 * nested model profile with its zod schema (the service re-validates too).
 */
function agentInput(body: {
  displayName?: string | null
  avatarUrl?: string | null
  llmProfile?: { models: unknown }
}): UpsertConsoleAgentInput {
  return {
    displayName: body.displayName,
    avatarUrl: body.avatarUrl,
    llmProfile: body.llmProfile ? { models: AiAgentModelsConfigSchema.parse(body.llmProfile.models) } : undefined
  }
}

/**
 * Requires an active human-admin session. Throws `ConsoleDomainError(401)` when
 * absent so handler success paths return a clean (Eden-Treaty-friendly) shape
 * instead of a `{ data } | { error }` union.
 */
export async function requireConsoleAdmin(request: Request): Promise<{ principalUid: string }> {
  const session = readAdminSessionCookie(request.headers.get('cookie'))
  if (session && (await activeHumanAdmin(session.principalUid))) {
    return { principalUid: session.principalUid }
  }

  throw new ConsoleDomainError(401, 'admin session required')
}

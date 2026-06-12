import { Elysia } from 'elysia'
import { z } from 'zod'
import { DomainError, statusFromError } from '@/common/errors'
import { logger } from '@/common/logger'
import { AiAgentModelsConfigSchema } from '@/ai-agent/config'
import { AppEnv } from '@/config/env'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'
import type { JsonObject } from '@/common/db-schema'
import type { UpsertConsoleAgentInput } from './service'
import {
  llmProviderCreateBody,
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
import { clientIpFromRequest, createAuthRateLimiter } from '@/security/auth-rate-limit'
import { PrincipalDomainError } from '@/principals/principals/service'
import { createPrincipalGroup, deletePrincipalGroup, updatePrincipalGroup } from '@/principals/authorization/groups'
import { testConsoleChatRecallEmbedding } from '@/chat-recall/service'
import {
  createConsoleAgent,
  createConsoleChatChannel,
  createConsoleHumanUser,
  deleteConsoleAgent,
  deleteConsoleChatChannel,
  deleteConsoleInteractiveConfigSession,
  getConsoleAgentMission,
  getConsoleAgentSoul,
  getConsoleChatRecall,
  getConsoleOverview,
  getConsoleAgent,
  getConsoleInteractiveConfigSession,
  getConsoleSettings,
  getConsoleWebTools,
  listConsoleAgentLibraryEntries,
  listConsoleAgentLiveStreams,
  listConsoleAgentSkills,
  readConsoleAgentLiveOutput,
  readConsoleAgentReasoningTrace,
  listConsoleAgents,
  listConsoleExternalGatewayAdapters,
  listConsoleExternalRooms,
  listConsoleHumanUsers,
  listConsoleLibrarySkills,
  listConsolePrincipalGroups,
  pauseConsoleChatRecall,
  reindexConsoleChatRecall,
  resumeConsoleChatRecall,
  setConsoleAgentSkillAssignment,
  setConsoleAgentMission,
  setConsoleAgentSoul,
  startConsoleInteractiveConfigSession,
  updateConsoleAgent,
  updateConsoleChatRecall,
  updateConsoleChatChannel,
  updateConsoleHumanUser,
  updateConsoleSettings,
  updateConsoleWebTools
} from './service'

// Loose JSON object body fragment. Deep domain validation stays in the service
// layer, so route schemas only describe request shape for Eden Treaty.
const jsonObjectBody = appConfigJsonRecordSchema as z.ZodType<JsonObject>

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

const liveOutputQuery = z.object({
  conversationId: z.string().min(1),
  streamId: z.string().min(1),
  after: z.string().optional()
})

const reasoningTraceOutputQuery = z.object({
  conversationId: z.string().min(1),
  traceId: z.string().min(1),
  after: z.string().optional()
})

const createAgentBody = z.object({
  uid: z.string().min(1),
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  llmProfile: llmProfileBody,
  mission: z.string().optional(),
  soul: z.string().optional()
})

const updateAgentBody = z.object({
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  llmProfile: llmProfileBody,
  mission: z.string().optional(),
  soul: z.string().optional()
})

const createHumanBody = z.object({
  uid: z.string().min(1),
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  email: z.string().nullable().optional(),
  phone: z.string().nullable().optional()
})

const updateHumanBody = z.object({
  displayName: z.string().nullable().optional(),
  avatarUrl: z.string().nullable().optional(),
  email: z.string().nullable().optional(),
  phone: z.string().nullable().optional(),
  status: z.enum(['active', 'disabled']).optional()
})

const createPrincipalGroupBody = z.object({
  name: z.string().min(1),
  kind: z.enum(['static', 'computed']).optional(),
  description: z.string().nullable().optional(),
  computedCondition: z.string().nullable().optional()
})

const updatePrincipalGroupBody = z.object({
  description: z.string().nullable().optional(),
  computedCondition: z.string().nullable().optional()
})

const skillAssignmentBody = z.object({
  enabled: z.boolean(),
  reason: z.string().nullable().optional()
})

const soulBody = z.object({
  content: z.string()
})

const consoleAdminRateLimiter = createAuthRateLimiter()
const CONSOLE_ADMIN_SCOPE = 'console-admin'

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

// Loose request shape; each field is validated against its config definition's
// own schema in the service layer.
const updateConsoleSettingsBody = z.object({
  defaultLocale: z.string().min(1).optional(),
  timezone: z.string().min(1).optional(),
  publicBaseUrl: z.string().min(1).optional()
})

const updateConsoleWebToolsBody = z
  .object({
    searchProvider: z.string().min(1).nullable().optional(),
    extractProvider: z.string().min(1).nullable().optional(),
    exaApiKey: z.string().min(1).nullable().optional(),
    parallelApiKey: z.string().min(1).nullable().optional(),
    jinaApiKey: z.string().min(1).nullable().optional()
  })
  .strict()

const chatRecallConfigBody = z
  .object({
    vector: z
      .object({
        enabled: z.boolean().optional(),
        providerKind: z.enum(['openai', 'openrouter', 'vllm']).optional(),
        providerId: z.string().min(1).optional(),
        model: z.string().min(1).optional(),
        dimensions: z.number().int().positive().optional(),
        batchSize: z.number().int().min(1).max(256).optional(),
        concurrency: z.number().int().min(1).max(8).optional(),
        indexStrategy: z.enum(['auto', 'halfvec_hnsw', 'binary_quantized_hnsw', 'exact_only']).optional()
      })
      .strict()
      .optional(),
    rerank: z
      .object({
        limit: z.number().int().min(1).max(50).optional(),
        rrfK: z.number().positive().optional(),
        recencyHalfLifeDays: z.number().positive().optional(),
        mmrLambda: z.number().min(0).max(1).optional()
      })
      .strict()
      .optional(),
    worker: z
      .object({
        enabled: z.boolean().optional(),
        pollIntervalMs: z.number().int().min(250).max(300_000).optional(),
        maxAttempts: z.number().int().min(1).max(20).optional()
      })
      .strict()
      .optional()
  })
  .strict()

export function consoleRoutes() {
  return new Elysia({ name: 'console-routes' })
    .onError(({ code, error, set }) => {
      if (error instanceof DomainError) {
        set.status = error.status
        return { error: error.message }
      }
      if (error instanceof PrincipalDomainError) {
        set.status = statusForPrincipalError(error)
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
    .get('/api/console/overview', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { overview: await getConsoleOverview() }
    })
    .get('/api/console/settings', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { settings: await getConsoleSettings() }
    })
    .put(
      '/api/console/settings',
      async ({ body, request }) => {
        await requireConsoleAdmin(request)
        return { settings: await updateConsoleSettings(body) }
      },
      { body: updateConsoleSettingsBody }
    )
    .get('/api/console/web-tools', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { webTools: await getConsoleWebTools() }
    })
    .put(
      '/api/console/web-tools',
      async ({ body, request }) => {
        await requireConsoleAdmin(request)
        return { webTools: await updateConsoleWebTools(body) }
      },
      { body: updateConsoleWebToolsBody }
    )
    .get('/api/console/chat-recall', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { chatRecall: await getConsoleChatRecall() }
    })
    .put(
      '/api/console/chat-recall',
      async ({ body, request }) => {
        await requireConsoleAdmin(request)
        return { chatRecall: await updateConsoleChatRecall(body) }
      },
      { body: chatRecallConfigBody }
    )
    .post('/api/console/chat-recall/embedding-test', async ({ request }) => {
      await requireConsoleAdmin(request)
      return await testConsoleChatRecallEmbedding()
    })
    .post('/api/console/chat-recall/reindex', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { chatRecall: await reindexConsoleChatRecall() }
    })
    .post('/api/console/chat-recall/pause', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { chatRecall: await pauseConsoleChatRecall() }
    })
    .post('/api/console/chat-recall/resume', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { chatRecall: await resumeConsoleChatRecall() }
    })
    .get('/api/console/human-users', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { humans: await listConsoleHumanUsers() }
    })
    .post(
      '/api/console/human-users',
      async ({ body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { human: await createConsoleHumanUser(body) }
      },
      { body: createHumanBody }
    )
    .put(
      '/api/console/human-users/:principalUid',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { human: await updateConsoleHumanUser(params.principalUid, body) }
      },
      { body: updateHumanBody }
    )
    .get('/api/console/principal-groups', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { groups: await listConsolePrincipalGroups() }
    })
    .post(
      '/api/console/principal-groups',
      async ({ body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { group: await createPrincipalGroup(body) }
      },
      { body: createPrincipalGroupBody }
    )
    .put(
      '/api/console/principal-groups/:id',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { group: await updatePrincipalGroup(params.id, body) }
      },
      { body: updatePrincipalGroupBody }
    )
    .delete('/api/console/principal-groups/:id', async ({ params, request, set }) => {
      await requireConsoleAdmin(request)
      await deletePrincipalGroup(params.id)
      set.status = 204
    })
    .get('/api/console/library-skills', async ({ request }) => {
      await requireConsoleAdmin(request)
      return { skills: await listConsoleLibrarySkills() }
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
    .get('/api/console/agents/:uid/live-streams', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { streams: await listConsoleAgentLiveStreams(params.uid) }
    })
    .get(
      '/api/console/agents/:uid/live-output',
      async ({ params, query, request }) => {
        await requireConsoleAdmin(request)
        return await readConsoleAgentLiveOutput({
          agentUid: params.uid,
          conversationId: query.conversationId,
          streamId: query.streamId,
          after: typeof query.after === 'string' && query.after.length > 0 ? query.after : undefined
        })
      },
      { query: liveOutputQuery }
    )
    .get(
      '/api/console/agents/:uid/reasoning-trace-output',
      async ({ params, query, request }) => {
        await requireConsoleAdmin(request)
        return await readConsoleAgentReasoningTrace({
          agentUid: params.uid,
          conversationId: query.conversationId,
          traceId: query.traceId,
          after: typeof query.after === 'string' && query.after.length > 0 ? query.after : undefined
        })
      },
      { query: reasoningTraceOutputQuery }
    )
    .get('/api/console/agents/:uid/skills', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { skills: await listConsoleAgentSkills(params.uid) }
    })
    .put(
      '/api/console/agents/:uid/skills/:skillName',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        await setConsoleAgentSkillAssignment({
          agentUid: params.uid,
          skillName: params.skillName,
          enabled: body.enabled,
          reason: body.reason
        })
        return { ok: true }
      },
      { body: skillAssignmentBody }
    )
    .get('/api/console/agents/:uid/library-entries', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return { entries: await listConsoleAgentLibraryEntries(params.uid) }
    })
    .get('/api/console/agents/:uid/soul', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return await getConsoleAgentSoul(params.uid)
    })
    .put(
      '/api/console/agents/:uid/soul',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return await setConsoleAgentSoul(params.uid, body.content)
      },
      { body: soulBody }
    )
    .get('/api/console/agents/:uid/mission', async ({ params, request }) => {
      await requireConsoleAdmin(request)
      return await getConsoleAgentMission(params.uid)
    })
    .put(
      '/api/console/agents/:uid/mission',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return await setConsoleAgentMission(params.uid, body.content)
      },
      { body: soulBody }
    )
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

function statusForPrincipalError(error: PrincipalDomainError): number {
  if (error.reason === 'not_found' || error.reason === 'not_human' || error.reason === 'not_agent') return 404
  if (
    error.reason === 'invalid_request' ||
    error.reason === 'built_in_group' ||
    error.reason === 'computed_group' ||
    error.reason === 'group_has_grants' ||
    error.reason === 'last_active_human_admin' ||
    error.reason === 'last_admin_member'
  ) {
    return 422
  }
  if (error.reason === 'forbidden') return 403
  return 400
}

/**
 * Coerces a route-validated agent body into the service input, validating the
 * nested model profile with its zod schema (the service re-validates too).
 */
function agentInput(body: {
  displayName?: string | null
  avatarUrl?: string | null
  llmProfile?: { models: unknown }
  mission?: string
  soul?: string
}): UpsertConsoleAgentInput {
  return {
    displayName: body.displayName,
    avatarUrl: body.avatarUrl,
    llmProfile: body.llmProfile ? { models: AiAgentModelsConfigSchema.parse(body.llmProfile.models) } : undefined,
    mission: body.mission,
    soul: body.soul
  }
}

/**
 * Requires an active human-admin session. Throws `DomainError(401)` when
 * absent so handler success paths return a clean (Eden-Treaty-friendly) shape
 * instead of a `{ data } | { error }` union.
 */
export async function requireConsoleAdmin(request: Request): Promise<{ principalUid: string }> {
  const clientIp = clientIpFromRequest(request)
  const limit = consoleAdminRateLimiter.check(clientIp, CONSOLE_ADMIN_SCOPE)
  if (!limit.allowed) throw new DomainError(429, 'too many failed admin authentication attempts')

  const session = readAdminSessionCookie(request.headers.get('cookie'))
  if (session && (await activeHumanAdmin(session.principalUid))) {
    consoleAdminRateLimiter.reset(clientIp, CONSOLE_ADMIN_SCOPE)
    return { principalUid: session.principalUid }
  }

  consoleAdminRateLimiter.recordFailure(clientIp, CONSOLE_ADMIN_SCOPE)
  throw new DomainError(401, 'admin session required')
}

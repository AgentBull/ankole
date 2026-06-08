import { Elysia, t } from 'elysia'
import { statusFromError } from '@/common/errors'
import { appConfigService, type AppConfigJsonValue } from '@/config/app-configure'
import { AppEnv } from '@/config/env'
import { AppI18nDefaultLocaleConfig } from '@/config/i18n'
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, isSupportedLocale } from '@/config/i18n-locales'
import { appendSetCookie } from '@/core/http'
import {
  checkLlmProvider,
  listLlmProviderModels,
  listLlmProviders,
  listPiLlmProviders,
  saveLlmProviders
} from '@/llm-providers/service'
import { AdminAuthPublicBaseUrlConfig } from '@/principals/admin-auth/config'
import { cookieHeader, newOpaqueToken, safeReturnTo } from '@/principals/admin-auth/session'
import {
  identityProviderOidcRedirectUri,
  requestPublicBaseUrl,
  resolveIdentityProviderPublicBaseUrl
} from '@/principals/admin-auth/oidc'
import { ActiveIdentityProvidersConfig, identityProviderConfigKey } from '@/principals/identity-providers/config'
import {
  getEnabledIdentityProviderAdapter,
  listEnabledIdentityProviderAdapters
} from '@/principals/identity-providers/adapters'
import { loadPluginCatalog } from '@/plugins/catalog'
import { clonePluginJsonValue } from '@/plugins/config-json'
import { createNoopIdentityProviderSyncSink } from '@/principals/identity-providers/noop-sync-sink'
import { SetupBootstrapActivationCodeConfig, SetupCompletedConfig } from './config'
import {
  SETUP_OIDC_STATE_COOKIE,
  createSetupOidcStateCookie,
  readSetupSessionCookie,
  setupSessionExpiredCookie,
  setupSessionSetCookie
} from './session'
import { persistExactEnabledPluginIds } from './plugins'

// Loose JSON object body fragment. Deep domain validation stays in the service
// layer (zod), so route typebox only describes request shape for Eden Treaty.
const jsonObjectBody = t.Record(t.String(), t.Unknown())

const setupSessionBody = t.Object({
  activationCode: t.String({ minLength: 1 }),
  locale: t.Optional(t.String())
})

const pluginSelectionBody = t.Object({
  pluginIds: t.Array(t.String({ minLength: 1 }))
})

const identityProviderConfigBody = t.Object({
  adapter: t.String({ minLength: 1 }),
  config: t.Unknown(),
  enabled: t.Optional(t.Boolean())
})

// Provider entries are re-validated by the service (saveLlmProviders parses each
// with LlmProviderCreateInputSchema); the route schema describes the request
// shape for Treaty and leaves deep option validation to the service.
const llmProviderCreateBody = t.Object({
  providerId: t.String({ minLength: 1 }),
  piProvider: t.String({ minLength: 1 }),
  baseUrl: t.Optional(t.Union([t.String(), t.Null()])),
  apiKey: t.Optional(t.Union([t.String(), t.Null()])),
  providerOptions: t.Optional(jsonObjectBody)
})

const llmProvidersBody = t.Object({
  providers: t.Array(llmProviderCreateBody)
})

const llmProviderCheckBody = t.Object({
  providerId: t.Optional(t.String({ minLength: 1 })),
  piProvider: t.Optional(t.String({ minLength: 1 })),
  model: t.Optional(t.String({ minLength: 1 })),
  baseUrl: t.Optional(t.Union([t.String(), t.Null()])),
  apiKey: t.Optional(t.Union([t.String(), t.Null()])),
  providerOptions: t.Optional(jsonObjectBody)
})

const oidcAuthorizationQuery = t.Object({
  return_to: t.Optional(t.String())
})

/**
 * Setup-scoped domain error. Thrown by {@link requireActiveSetupSession} so the
 * `onError` handler maps it to a status and the handler success paths return a
 * clean (Eden-Treaty-friendly) shape instead of a `{ data } | { error }` union.
 */
export class SetupDomainError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
    this.name = 'SetupDomainError'
  }
}

export function setupRoutes() {
  return new Elysia({ name: 'setup-routes' })
    .onError(({ error, set }) => {
      const status = statusFromError(error)
      set.status = status
      return {
        error:
          error instanceof Error
            ? error.message
            : typeof error === 'string'
              ? error
              : status === 500
                ? 'Internal Server Error'
                : 'request failed'
      }
    })
    .get('/api/setup/state', async ({ request }) => {
      const completed = (await appConfigService.get(SetupCompletedConfig)) === true
      const setupSession = readSetupSessionCookie(request.headers.get('cookie'))
      const currentLocale = (await appConfigService.get(AppI18nDefaultLocaleConfig)) ?? DEFAULT_LOCALE

      return {
        completed,
        authenticated: !completed && setupSession !== undefined,
        currentLocale,
        availableLocales: [...SUPPORTED_LOCALES]
      }
    })
    .post(
      '/api/setup/sessions',
      async ({ body, set }) => {
        const completed = (await appConfigService.get(SetupCompletedConfig)) === true
        if (completed) {
          set.status = 409
          return { error: 'setup already completed' }
        }

        const locale = body.locale?.trim()
        const selectedLocale = locale && isSupportedLocale(locale) ? locale : undefined
        if (locale && !selectedLocale) {
          set.status = 422
          return { error: 'unsupported locale' }
        }

        const expected = await appConfigService.get(SetupBootstrapActivationCodeConfig)
        const submitted = body.activationCode.trim().toUpperCase()
        if (!expected || submitted !== expected) {
          set.status = 401
          return { error: 'invalid bootstrap activation code' }
        }

        if (selectedLocale) await appConfigService.set(AppI18nDefaultLocaleConfig, selectedLocale)

        appendSetCookie(set, setupSessionSetCookie(AppEnv.IS_PRODUCTION))
        return { ok: true }
      },
      { body: setupSessionBody }
    )
    .delete('/api/setup/sessions/current', ({ set }) => {
      appendSetCookie(set, setupSessionExpiredCookie(AppEnv.IS_PRODUCTION))
      return { ok: true }
    })
    .get('/api/setup/plugins', async ({ request }) => {
      await requireActiveSetupSession(request)

      const catalog = await loadPluginCatalog()
      return {
        plugins: catalog.plugins.map(plugin => ({
          id: plugin.metadata.id,
          metadata: plugin.metadata
        })),
        enabledPluginIds: catalog.enabledPluginIds
      }
    })
    .put(
      '/api/setup/plugins/enabled',
      async ({ body, request }) => {
        await requireActiveSetupSession(request)

        const enabledPluginIds = await persistExactEnabledPluginIds(body.pluginIds)
        return { enabledPluginIds }
      },
      { body: pluginSelectionBody }
    )
    .get('/api/setup/llm-providers', async ({ request }) => {
      await requireActiveSetupSession(request)

      return {
        providers: await listLlmProviders(),
        piProviders: listPiLlmProviders()
      }
    })
    .put(
      '/api/setup/llm-providers',
      async ({ body, request }) => {
        await requireActiveSetupSession(request)

        return { providers: await saveLlmProviders(body.providers) }
      },
      { body: llmProvidersBody }
    )
    .post(
      '/api/setup/llm-providers/check',
      async ({ body, request }) => {
        await requireActiveSetupSession(request)

        return await checkLlmProvider(body)
      },
      { body: llmProviderCheckBody }
    )
    .get('/api/setup/llm-providers/:providerId/models', async ({ params, request }) => {
      await requireActiveSetupSession(request)

      return { models: await listLlmProviderModels(params.providerId) }
    })
    .get('/api/setup/identity-provider-adapters', async ({ request }) => {
      await requireActiveSetupSession(request)

      return {
        adapters: await listEnabledIdentityProviderAdapters()
      }
    })
    .put(
      '/api/setup/identity-providers/:providerId',
      async ({ params, body, request }) => {
        await requireActiveSetupSession(request)

        const enabled = body.enabled ?? true
        const config = body.config as AppConfigJsonValue
        const publicBaseUrl = requestPublicBaseUrl(request)
        const factory = await getEnabledIdentityProviderAdapter(body.adapter)
        /*
         * Create once before persistence so adapter-owned schema/credential checks
         * fail while the user is still on the setup form. The no-op sync sink
         * prevents this validation instance from applying directory changes.
         */
        await factory.create({
          providerId: params.providerId,
          config: clonePluginJsonValue(config),
          publicBaseUrl,
          isProduction: AppEnv.IS_PRODUCTION,
          syncSink: createNoopIdentityProviderSyncSink()
        })

        await appConfigService.setByKey(identityProviderConfigKey(params.providerId), config)
        await upsertActiveIdentityProvider({
          providerId: params.providerId,
          adapter: body.adapter,
          enabled
        })
        // First setup captures the browser-visible origin as the later OIDC base URL.
        await appConfigService.set(AdminAuthPublicBaseUrlConfig, publicBaseUrl)

        return {
          providerId: params.providerId,
          adapter: body.adapter,
          enabled
        }
      },
      { body: identityProviderConfigBody }
    )
    .post(
      '/api/setup/identity-providers/:providerId/oidc/authorizations',
      async ({ params, query, request, set }) => {
        await requireActiveSetupSession(request)

        const provider = await createSetupOidcProvider(params.providerId, request)
        if (!provider.adapter.buildOidcAuthorizationUrl) {
          set.status = 404
          return { error: 'identity provider does not support OIDC' }
        }

        const state = newOpaqueToken()
        const nonce = newOpaqueToken()
        const publicBaseUrl = await resolveIdentityProviderPublicBaseUrl(request)
        const redirectUri = identityProviderOidcRedirectUri(publicBaseUrl, params.providerId)
        const returnTo = safeReturnTo(typeof query.return_to === 'string' ? query.return_to : '/console')
        const stateCookie = createSetupOidcStateCookie({
          providerId: params.providerId,
          state,
          nonce,
          returnTo,
          redirectUri
        })
        appendSetCookie(
          set,
          cookieHeader(SETUP_OIDC_STATE_COOKIE, stateCookie, {
            secure: AppEnv.IS_PRODUCTION
          })
        )

        const authorizationUrl = await provider.adapter.buildOidcAuthorizationUrl({
          redirectUri,
          state,
          nonce,
          returnTo
        })
        return { authorizationUrl }
      },
      { query: oidcAuthorizationQuery }
    )
}

/**
 * Requires an active setup session. Throws {@link SetupDomainError} (409 once
 * setup has completed, 401 otherwise) so handler success paths return a clean
 * (Eden-Treaty-friendly) shape instead of a `{ data } | { error }` union.
 */
async function requireActiveSetupSession(request: Request): Promise<void> {
  const completed = (await appConfigService.get(SetupCompletedConfig)) === true
  if (completed) throw new SetupDomainError(409, 'setup already completed')

  /*
   * A setup session only proves possession of the current bootstrap activation
   * code. Once setup.completed flips to true, old setup cookies must stop
   * authorizing `/api/setup/*` even if their 24h TTL has not expired yet.
   */
  const setupSession = readSetupSessionCookie(request.headers.get('cookie'))
  if (setupSession) return

  throw new SetupDomainError(401, 'setup session required')
}

async function upsertActiveIdentityProvider(input: { providerId: string; adapter: string; enabled: boolean }) {
  const providers = [...((await appConfigService.get(ActiveIdentityProvidersConfig)) ?? [])]
  const existingIndex = providers.findIndex(provider => provider.providerId === input.providerId)
  const next = {
    providerId: input.providerId,
    adapter: input.adapter,
    enabled: input.enabled
  }

  if (existingIndex === -1) providers.push(next)
  else providers[existingIndex] = next

  await appConfigService.set(ActiveIdentityProvidersConfig, providers)
}

async function createSetupOidcProvider(providerId: string, request: Request) {
  const active = ((await appConfigService.get(ActiveIdentityProvidersConfig)) ?? []).find(
    provider => provider.providerId === providerId && provider.enabled !== false
  )
  if (!active) throw new Error(`Identity provider is not configured: ${providerId}`)

  const factory = await getEnabledIdentityProviderAdapter(active.adapter)
  const config = await appConfigService.getByKey(identityProviderConfigKey(providerId))
  const publicBaseUrl = await resolveIdentityProviderPublicBaseUrl(request)
  const adapter = await factory.create({
    providerId,
    config: clonePluginJsonValue(config),
    publicBaseUrl,
    isProduction: AppEnv.IS_PRODUCTION,
    syncSink: createNoopIdentityProviderSyncSink()
  })

  return {
    active,
    adapter
  }
}

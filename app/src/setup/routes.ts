import { Elysia } from 'elysia'
import { z } from 'zod'
import { appConfigService, type AppConfigJsonValue } from '@/config/app-configure'
import { AppEnv } from '@/config/env'
import { AppI18nDefaultLocaleConfig } from '@/config/i18n'
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, isSupportedLocale } from '@/config/i18n-locales'
import { appendSetCookie } from '@/core/http'
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

const setupSessionBodySchema = z
  .object({
    activationCode: z.string().min(1),
    locale: z.string().optional()
  })
  .strict()

const pluginSelectionSchema = z
  .object({
    pluginIds: z.array(z.string().min(1))
  })
  .strict()

const identityProviderConfigSchema = z
  .object({
    adapter: z.string().min(1),
    config: z.custom<AppConfigJsonValue>(),
    enabled: z.boolean().default(true)
  })
  .strict()

type MutableResponseSet = {
  status?: number | string
}

type SetupAccessResult = { ok: true } | { ok: false; error: string }

export function setupRoutes() {
  return new Elysia({ name: 'setup-routes' })
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
    .post('/api/setup/sessions', async ({ body, set }) => {
      const completed = (await appConfigService.get(SetupCompletedConfig)) === true
      if (completed) {
        set.status = 409
        return { error: 'setup already completed' }
      }

      const parsed = setupSessionBodySchema.parse(body)
      const locale = parsed.locale?.trim()
      const selectedLocale = locale && isSupportedLocale(locale) ? locale : undefined
      if (locale && !selectedLocale) {
        set.status = 422
        return { error: 'unsupported locale' }
      }

      const expected = await appConfigService.get(SetupBootstrapActivationCodeConfig)
      const submitted = parsed.activationCode.trim().toUpperCase()
      if (!expected || submitted !== expected) {
        set.status = 401
        return { error: 'invalid bootstrap activation code' }
      }

      if (selectedLocale) await appConfigService.set(AppI18nDefaultLocaleConfig, selectedLocale)

      appendSetCookie(set, setupSessionSetCookie(AppEnv.IS_PRODUCTION))
      return { ok: true }
    })
    .delete('/api/setup/sessions/current', ({ set }) => {
      appendSetCookie(set, setupSessionExpiredCookie(AppEnv.IS_PRODUCTION))
      return { ok: true }
    })
    .get('/api/setup/plugins', async ({ request, set }) => {
      const access = await requireActiveSetupSession(request, set)
      if (!access.ok) return { error: access.error }

      const catalog = await loadPluginCatalog()
      return {
        plugins: catalog.plugins.map(plugin => ({
          id: plugin.metadata.id,
          metadata: plugin.metadata
        })),
        enabledPluginIds: catalog.enabledPluginIds
      }
    })
    .put('/api/setup/plugins/enabled', async ({ body, request, set }) => {
      const access = await requireActiveSetupSession(request, set)
      if (!access.ok) return { error: access.error }

      const parsed = pluginSelectionSchema.parse(body)
      const enabledPluginIds = await persistExactEnabledPluginIds(parsed.pluginIds)
      return { enabledPluginIds }
    })
    .get('/api/setup/identity-provider-adapters', async ({ request, set }) => {
      const access = await requireActiveSetupSession(request, set)
      if (!access.ok) return { error: access.error }

      return {
        adapters: await listEnabledIdentityProviderAdapters()
      }
    })
    .put('/api/setup/identity-providers/:providerId', async ({ params, body, request, set }) => {
      const access = await requireActiveSetupSession(request, set)
      if (!access.ok) return { error: access.error }

      const parsed = identityProviderConfigSchema.parse(body)
      const publicBaseUrl = requestPublicBaseUrl(request)
      const factory = await getEnabledIdentityProviderAdapter(parsed.adapter)
      /*
       * Create once before persistence so adapter-owned schema/credential checks
       * fail while the user is still on the setup form. The no-op sync sink
       * prevents this validation instance from applying directory changes.
       */
      await factory.create({
        providerId: params.providerId,
        config: clonePluginJsonValue(parsed.config),
        publicBaseUrl,
        isProduction: AppEnv.IS_PRODUCTION,
        syncSink: createNoopIdentityProviderSyncSink()
      })

      await appConfigService.setByKey(identityProviderConfigKey(params.providerId), parsed.config)
      await upsertActiveIdentityProvider({
        providerId: params.providerId,
        adapter: parsed.adapter,
        enabled: parsed.enabled
      })
      // First setup captures the browser-visible origin as the later OIDC base URL.
      await appConfigService.set(AdminAuthPublicBaseUrlConfig, publicBaseUrl)

      return {
        providerId: params.providerId,
        adapter: parsed.adapter,
        enabled: parsed.enabled
      }
    })
    .post('/api/setup/identity-providers/:providerId/oidc/authorizations', async ({ params, query, request, set }) => {
      const access = await requireActiveSetupSession(request, set)
      if (!access.ok) return { error: access.error }

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
    })
}

async function requireActiveSetupSession(request: Request, set: MutableResponseSet): Promise<SetupAccessResult> {
  const completed = (await appConfigService.get(SetupCompletedConfig)) === true
  if (completed) {
    set.status = 409
    return { ok: false, error: 'setup already completed' }
  }

  /*
   * A setup session only proves possession of the current bootstrap activation
   * code. Once setup.completed flips to true, old setup cookies must stop
   * authorizing `/api/setup/*` even if their 24h TTL has not expired yet.
   */
  const setupSession = readSetupSessionCookie(request.headers.get('cookie'))
  if (setupSession) return { ok: true }

  set.status = 401
  return { ok: false, error: 'setup session required' }
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

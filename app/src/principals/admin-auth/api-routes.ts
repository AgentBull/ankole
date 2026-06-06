import { Elysia } from 'elysia'
import { AppEnv } from '@/config/env'
import { appConfigService } from '@/config/app-configure'
import { appendSetCookie, redirectWithSetCookies } from '@/core/http'
import { rootInitAdmin } from '../authorization/service'
import { upsertIdentityProviderUser } from '../identity-providers/service'
import { ActiveIdentityProvidersConfig, identityProviderConfigKey } from '../identity-providers/config'
import { createNoopIdentityProviderSyncSink } from '../identity-providers/noop-sync-sink'
import { getEnabledIdentityProviderAdapter } from '../identity-providers/adapters'
import { clonePluginJsonValue } from '@/plugins/config-json'
import { SetupBootstrapActivationCodeConfig, SetupCompletedConfig } from '@/setup/config'
import { isSetupCompletionRestartRecommended, markSetupCompletionRestartRecommended } from '@/setup/runtime-state'
import {
  SETUP_OIDC_STATE_COOKIE,
  readSetupOidcStateCookie,
  setupSessionExpiredCookie,
  type SetupOidcStatePayload
} from '@/setup/session'
import { activeHumanAdmin } from './access'
import { identityProviderOidcRedirectUri, resolveIdentityProviderPublicBaseUrl } from './oidc'
import {
  ADMIN_OIDC_STATE_COOKIE,
  ADMIN_SESSION_COOKIE,
  ADMIN_SESSION_TTL_SECONDS,
  cookieHeader,
  createAdminSessionCookie,
  createOidcStateCookie,
  expiredCookieHeader,
  newOpaqueToken,
  readAdminSessionCookie,
  readOidcStateCookie,
  safeReturnTo
} from './session'

export function sessionApiRoutes() {
  return new Elysia({ name: 'session-api-routes' })
    .get('/api/session', async ({ request, set }) => {
      const session = readAdminSessionCookie(request.headers.get('cookie'))
      if (!session || !(await activeHumanAdmin(session.principalUid))) {
        set.status = 401
        return { authenticated: false }
      }

      return {
        authenticated: true,
        principalUid: session.principalUid,
        providerId: session.providerId,
        setupRestartRecommended: isSetupCompletionRestartRecommended()
      }
    })
    .delete('/api/session', ({ set }) => {
      appendSetCookie(set, expiredCookieHeader(ADMIN_SESSION_COOKIE, AppEnv.IS_PRODUCTION))
      return { ok: true }
    })
    .get('/api/identity-providers', async () => {
      const activeProviders = ((await appConfigService.get(ActiveIdentityProvidersConfig)) ?? []).filter(
        provider => provider.enabled !== false
      )

      return {
        providers: activeProviders.map(provider => ({
          providerId: provider.providerId,
          adapter: provider.adapter
        }))
      }
    })
    .post('/api/identity-providers/:providerId/oidc/authorizations', async ({ params, query, request, set }) => {
      const provider = await createOidcProvider(params.providerId, request)
      if (!provider.adapter.buildOidcAuthorizationUrl) {
        set.status = 404
        return { error: 'identity provider does not support OIDC' }
      }

      const publicBaseUrl = await resolveIdentityProviderPublicBaseUrl(request)
      const redirectUri = identityProviderOidcRedirectUri(publicBaseUrl, params.providerId)
      const state = newOpaqueToken()
      const nonce = newOpaqueToken()
      const returnTo = safeReturnTo(typeof query.return_to === 'string' ? query.return_to : '/console')
      const stateCookie = createOidcStateCookie({
        providerId: params.providerId,
        state,
        nonce,
        returnTo,
        redirectUri
      })
      appendSetCookie(set, cookieHeader(ADMIN_OIDC_STATE_COOKIE, stateCookie, { secure: AppEnv.IS_PRODUCTION }))

      const authorizationUrl = await provider.adapter.buildOidcAuthorizationUrl({
        redirectUri,
        state,
        nonce,
        returnTo
      })
      return { authorizationUrl }
    })
    .get('/sessions/oidc/:providerId/callback', async ({ params, query, request, set }) => {
      const code = typeof query.code === 'string' ? query.code : undefined
      const state = typeof query.state === 'string' ? query.state : undefined
      if (!code || !state) {
        set.status = 400
        return { error: 'invalid OIDC state' }
      }

      const setupState = readSetupOidcStateCookie(request.headers.get('cookie'))
      if (setupState?.state === state) {
        return completeSetupOidcCallback({
          providerId: params.providerId,
          code,
          oidcState: setupState,
          request,
          set,
          state
        })
      }

      const oidcState = readOidcStateCookie(request.headers.get('cookie'))
      if (!oidcState || oidcState.state !== state) {
        set.status = 400
        return { error: 'invalid OIDC state' }
      }

      if (oidcState.providerId !== params.providerId) {
        set.status = 400
        return { error: 'invalid OIDC provider' }
      }

      const provider = await createOidcProvider(params.providerId, request)
      if (!provider.adapter.completeOidcLogin) {
        set.status = 404
        return { error: 'identity provider does not support OIDC' }
      }

      const result = await provider.adapter.completeOidcLogin({
        code,
        state,
        nonce: oidcState.nonce,
        redirectUri: oidcState.redirectUri
      })
      const principalUid = await upsertIdentityProviderUser(params.providerId, result.user)
      if (!(await activeHumanAdmin(principalUid))) {
        set.status = 403
        return { error: 'admin access required' }
      }

      const sessionCookie = createAdminSessionCookie({
        principalUid,
        providerId: oidcState.providerId,
        externalId: result.user.externalId
      })
      return redirectWithSetCookies(oidcState.returnTo, [
        expiredCookieHeader(ADMIN_OIDC_STATE_COOKIE, AppEnv.IS_PRODUCTION),
        cookieHeader(ADMIN_SESSION_COOKIE, sessionCookie, {
          secure: AppEnv.IS_PRODUCTION,
          maxAgeSeconds: ADMIN_SESSION_TTL_SECONDS
        })
      ])
    })
}

async function completeSetupOidcCallback(input: {
  providerId: string
  code: string
  oidcState: SetupOidcStatePayload
  request: Request
  set: { headers?: Record<string, unknown>; status?: number | string }
  state: string
}) {
  if (input.oidcState.providerId !== input.providerId) {
    input.set.status = 400
    return { error: 'invalid OIDC provider' }
  }

  const provider = await createOidcProvider(input.providerId, input.request)
  if (!provider.adapter.completeOidcLogin) {
    input.set.status = 404
    return { error: 'identity provider does not support OIDC' }
  }

  const result = await provider.adapter.completeOidcLogin({
    code: input.code,
    state: input.state,
    nonce: input.oidcState.nonce,
    redirectUri: input.oidcState.redirectUri
  })
  const principalUid = await upsertIdentityProviderUser(input.providerId, result.user)
  await rootInitAdmin(principalUid)
  await appConfigService.set(SetupCompletedConfig, true)
  await appConfigService.delete(SetupBootstrapActivationCodeConfig)
  // The saved provider is durable, but the already-started runtime has not loaded it.
  markSetupCompletionRestartRecommended()

  const sessionCookie = createAdminSessionCookie({
    principalUid,
    providerId: input.oidcState.providerId,
    externalId: result.user.externalId
  })
  return redirectWithSetCookies('/console', [
    expiredCookieHeader(SETUP_OIDC_STATE_COOKIE, AppEnv.IS_PRODUCTION),
    setupSessionExpiredCookie(AppEnv.IS_PRODUCTION),
    cookieHeader(ADMIN_SESSION_COOKIE, sessionCookie, {
      secure: AppEnv.IS_PRODUCTION,
      maxAgeSeconds: ADMIN_SESSION_TTL_SECONDS
    })
  ])
}

async function createOidcProvider(providerId: string, request: Request) {
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

  return { active, adapter }
}

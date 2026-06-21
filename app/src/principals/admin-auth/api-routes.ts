import { Elysia, t } from 'elysia'
import { createOidcLoginAdapter } from '@/principals/identity-providers/adapters'
import { AppEnv } from '@/config/env'
import { appConfigService } from '@/config/app-configure'
import { appendSetCookie, redirectWithSetCookies } from '@/core/http'
import { rootInitAdmin } from '../authorization/service'
import { upsertIdentityProviderUser } from '../identity-providers/service'
import { ActiveIdentityProvidersConfig } from '../identity-providers/config'
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

/**
 * HTTP surface for admin-console authentication: session introspection, logout,
 * the list of usable identity providers, OIDC authorization-URL minting, and the
 * provider callback that turns a successful login into an admin session cookie.
 *
 * The flow is the standard OIDC authorization-code dance: the SPA asks for an
 * authorization URL (which also sets a sealed state cookie), the browser visits
 * the provider, and the provider redirects back to the callback route with a
 * `code` and the `state`. Every anti-CSRF / anti-replay guard lives in the
 * callback. PKCE is not used here; binding is done with the sealed `state` and
 * `nonce` carried in the cookie instead.
 */
export function sessionApiRoutes() {
  return (
    new Elysia({ name: 'session-api-routes' })
      // Introspects the current login. The sealed cookie alone is not trusted as
      // authorization: `activeHumanAdmin` is re-checked on every call so a revoked
      // or disabled admin is rejected mid-session even though their cookie is
      // still cryptographically valid and unexpired.
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
      // Logout. There is no server-side session record to revoke, so logout is
      // just instructing the browser to drop the sealed cookie; the cookie's own
      // expiry bounds any copy that was already captured.
      .delete('/api/session', ({ set }) => {
        appendSetCookie(set, expiredCookieHeader(ADMIN_SESSION_COOKIE, AppEnv.IS_PRODUCTION))
        return { ok: true }
      })
      // Lists providers the login screen may offer. Only the provider id and
      // adapter name are exposed; provider secrets/config never leave the server.
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
      // Begins login: mints the provider authorization URL and binds the handshake
      // to this browser via a sealed state cookie.
      //
      // `state` and `nonce` are fresh per attempt. Both are placed in the
      // authorization URL *and* sealed into the cookie so the callback can compare
      // them: `state` ties the redirect back to this browser (CSRF defense) and
      // `nonce` will be checked inside the returned ID token (replay defense). The
      // exact `redirectUri` is sealed too so the callback verifies the token
      // against the same URI the provider saw. `returnTo` is sanitized up front to
      // a same-origin path so the post-login redirect cannot be hijacked.
      .post(
        '/api/identity-providers/:providerId/oidc/authorizations',
        async ({ params, query, request, set }) => {
          const provider = await createOidcLoginAdapter(params.providerId, request)
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
        },
        { query: t.Object({ return_to: t.Optional(t.String()) }) }
      )
      // OIDC redirect target. The provider sends the browser here with `code` and
      // `state`; this route validates the handshake and, on success, issues the
      // admin session cookie.
      //
      // One path serves two flows. First-run setup and normal admin login share
      // this same callback URL, so the handler decides which one is in flight by
      // matching the returned `state` against the setup state cookie first, then
      // the admin state cookie. The `state` value is what disambiguates; a request
      // can only satisfy whichever cookie it actually carries.
      .get('/sessions/oidc/:providerId/callback', async ({ params, query, request, set }) => {
        const code = typeof query.code === 'string' ? query.code : undefined
        const state = typeof query.state === 'string' ? query.state : undefined
        if (!code || !state) {
          set.status = 400
          return { error: 'invalid OIDC state' }
        }

        // Setup branch: a live setup handshake is recognized by an exact `state`
        // match against the setup cookie. Checked before admin login so the very
        // first administrator can be bootstrapped through the same endpoint.
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

        // CSRF check: the `state` from the provider must equal the `state` sealed
        // into this browser's cookie at authorization time. A login request forged
        // by another site will not carry a matching state cookie and is rejected.
        const oidcState = readOidcStateCookie(request.headers.get('cookie'))
        if (!oidcState || oidcState.state !== state) {
          set.status = 400
          return { error: 'invalid OIDC state' }
        }

        // Defends against a state cookie minted for a different provider being
        // replayed against this provider's callback path.
        if (oidcState.providerId !== params.providerId) {
          set.status = 400
          return { error: 'invalid OIDC provider' }
        }

        const provider = await createOidcLoginAdapter(params.providerId, request)
        if (!provider.adapter.completeOidcLogin) {
          set.status = 404
          return { error: 'identity provider does not support OIDC' }
        }

        // Hands the code back to the adapter together with the sealed `nonce` and
        // `redirectUri`. The adapter exchanges the code and verifies the ID token,
        // including that its nonce equals the one we issued (replay defense) and
        // that the redirect URI matches.
        const result = await provider.adapter.completeOidcLogin({
          code,
          state,
          nonce: oidcState.nonce,
          redirectUri: oidcState.redirectUri
        })
        // A verified external identity is not yet an authorization decision. Map it
        // to a Principal, then require that Principal be an active human admin
        // before any session is issued — authentication alone never grants console
        // access.
        const principalUid = await upsertIdentityProviderUser(params.providerId, result.user)
        if (!(await activeHumanAdmin(principalUid))) {
          set.status = 403
          return { error: 'admin access required' }
        }

        // Login succeeded: clear the one-shot state cookie and set the session
        // cookie in the same response, then redirect to the sanitized return path.
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
  )
}

/**
 * Completes the first-run OIDC handshake and promotes the authenticated user to
 * the first root administrator.
 *
 * This is the privileged sibling of the normal login callback. The difference is
 * the `rootInitAdmin` step: instead of checking that the user is *already* an
 * admin, it claims the empty installation by making this Principal the first
 * admin, then flips setup to completed. `rootInitAdmin` is race-safe on its own
 * (it locks and rechecks the open state), so two concurrent setup callbacks
 * cannot both seize root.
 *
 * Same provider-match guard as the login path runs first; the `state`/`nonce`
 * verification already happened against the setup state cookie at the call site.
 */
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

  const provider = await createOidcLoginAdapter(input.providerId, input.request)
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
  // Setup is now closed: mark it completed and burn the one-time bootstrap
  // activation code so the open setup window cannot be reused to claim root.
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

import { and, eq } from 'drizzle-orm'
import { Elysia } from 'elysia'
import { DB } from '@/common/database'
import { PrincipalGroupMemberships, PrincipalGroups, Principals } from '@/common/db-schema'
import { rootContainer } from '@/common/di'
import { AppEnv } from '@/config/env'
import { appConfigService } from '@/config/app-configure'
import { ADMIN_GROUP_NAME } from '../authorization/groups'
import { upsertIdentityProviderUser } from '../identity-providers/service'
import { IdentityProviderRuntime } from '../identity-providers/runtime'
import { AdminAuthPublicBaseUrlConfig } from './config'
import {
  ADMIN_OIDC_STATE_COOKIE,
  ADMIN_SESSION_COOKIE,
  cookieHeader,
  createAdminSessionCookie,
  createOidcStateCookie,
  expiredCookieHeader,
  newOpaqueToken,
  readAdminSessionCookie,
  readOidcStateCookie,
  safeReturnTo
} from './session'

export function adminAuthRoutes(runtime: IdentityProviderRuntime = rootContainer.resolve(IdentityProviderRuntime)) {
  return new Elysia({ name: 'admin-auth-routes' })
    .get('/admin/login', () => loginPlaceholder())
    .get('/admin/auth/oidc/:providerId', async ({ params, query, set, redirect }) => {
      const provider = runtime.getProviderAdapter(params.providerId)
      if (!provider?.buildOidcAuthorizationUrl) {
        set.status = 404
        return { error: 'identity provider does not support OIDC' }
      }

      const publicBaseUrl = await requirePublicBaseUrl()
      const redirectUri = `${publicBaseUrl}/admin/auth/oidc/${encodeURIComponent(params.providerId)}/callback`
      const state = newOpaqueToken()
      const nonce = newOpaqueToken()
      const returnTo = safeReturnTo(typeof query.return_to === 'string' ? query.return_to : undefined)
      const stateCookie = createOidcStateCookie({
        providerId: params.providerId,
        state,
        nonce,
        returnTo,
        redirectUri
      })

      appendSetCookie(set, cookieHeader(ADMIN_OIDC_STATE_COOKIE, stateCookie, { secure: AppEnv.IS_PRODUCTION }))
      const authorizationUrl = await provider.buildOidcAuthorizationUrl({
        redirectUri,
        state,
        nonce,
        returnTo
      })

      return redirect(authorizationUrl, 302)
    })
    .get('/admin/auth/oidc/:providerId/callback', async ({ params, query, request, set, redirect }) => {
      const provider = runtime.getProviderAdapter(params.providerId)
      if (!provider?.completeOidcLogin) {
        set.status = 404
        return { error: 'identity provider does not support OIDC' }
      }

      const code = typeof query.code === 'string' ? query.code : undefined
      const state = typeof query.state === 'string' ? query.state : undefined
      const oidcState = readOidcStateCookie(request.headers.get('cookie'))
      if (!code || !state || !oidcState || oidcState.providerId !== params.providerId || oidcState.state !== state) {
        set.status = 400
        return { error: 'invalid OIDC state' }
      }

      const result = await provider.completeOidcLogin({
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
        providerId: params.providerId,
        externalId: result.user.externalId
      })
      appendSetCookie(set, expiredCookieHeader(ADMIN_OIDC_STATE_COOKIE, AppEnv.IS_PRODUCTION))
      appendSetCookie(set, cookieHeader(ADMIN_SESSION_COOKIE, sessionCookie, { secure: AppEnv.IS_PRODUCTION }))
      return redirect(oidcState.returnTo, 302)
    })
    .get('/admin/session', async ({ request, set }) => {
      const session = readAdminSessionCookie(request.headers.get('cookie'))
      if (!session || !(await activeHumanAdmin(session.principalUid))) {
        set.status = 401
        return { authenticated: false }
      }

      return {
        authenticated: true,
        principalUid: session.principalUid,
        providerId: session.providerId
      }
    })
    .post('/admin/logout', ({ set }) => {
      appendSetCookie(set, expiredCookieHeader(ADMIN_SESSION_COOKIE, AppEnv.IS_PRODUCTION))
      return { ok: true }
    })
    .get('/admin', async ({ request, set }) => {
      // The HTML is intentionally a placeholder for now; the gate in front of
      // it is not. Keeping real session validation here lets the future admin
      // UI mount without changing the OIDC/session contract again.
      const session = readAdminSessionCookie(request.headers.get('cookie'))
      if (!session || !(await activeHumanAdmin(session.principalUid))) {
        set.status = 401
        return loginPlaceholder()
      }

      return new Response('<!doctype html><title>BullX Admin</title><main>BullX Admin Console</main>', {
        headers: { 'content-type': 'text/html; charset=utf-8' }
      })
    })
}

async function requirePublicBaseUrl(): Promise<string> {
  const publicBaseUrl = await appConfigService.get(AdminAuthPublicBaseUrlConfig)
  if (!publicBaseUrl) throw new Error('admin_auth.public_base_url is required for OIDC login')

  return publicBaseUrl.replace(/\/+$/, '')
}

async function activeHumanAdmin(principalUid: string): Promise<boolean> {
  const [row] = await DB.select({ uid: Principals.uid })
    .from(Principals)
    .innerJoin(PrincipalGroupMemberships, eq(PrincipalGroupMemberships.principalUid, Principals.uid))
    .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
    .where(
      and(
        eq(Principals.uid, principalUid),
        eq(Principals.type, 'human'),
        eq(Principals.status, 'active'),
        eq(PrincipalGroups.name, ADMIN_GROUP_NAME),
        eq(PrincipalGroups.builtIn, true)
      )
    )
    .limit(1)

  return row !== undefined
}

function loginPlaceholder(): Response {
  return new Response('<!doctype html><title>BullX Admin Login</title><main>BullX Admin Login</main>', {
    headers: { 'content-type': 'text/html; charset=utf-8' }
  })
}

function appendSetCookie(set: { headers?: Record<string, unknown> }, value: string): void {
  const existing = set.headers?.['Set-Cookie']
  if (!set.headers) set.headers = {}
  if (!existing) {
    set.headers['Set-Cookie'] = value
    return
  }

  set.headers['Set-Cookie'] = Array.isArray(existing) ? [...existing, value] : [String(existing), value]
}

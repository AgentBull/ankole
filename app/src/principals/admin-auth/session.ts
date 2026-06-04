import { aeadDecrypt, aeadEncrypt } from '@agentbull/bullx-native-addons'
import { ms } from '@pleisto/active-support'
import { getSecretKey, SecretKeyPurpose } from '@/common/kms'

export const ADMIN_SESSION_COOKIE = '_bullx_agent_session'
export const ADMIN_OIDC_STATE_COOKIE = '_bullx_agent_oidc_state'

const ADMIN_SESSION_TTL_MS = ms('12h')
const OIDC_STATE_TTL_MS = ms('10m')

export interface AdminSessionPayload {
  principalUid: string
  providerId: string
  externalId: string
  issuedAt: number
  expiresAt: number
}

export interface AdminOidcStatePayload {
  providerId: string
  state: string
  nonce: string
  returnTo: string
  redirectUri: string
  issuedAt: number
  expiresAt: number
}

/**
 * Creates the admin-console login session cookie.
 *
 * Admin auth is cookie-based because the OIDC callback must bind browser state
 * to a post-login session before any SPA/API token flow exists. The payload is
 * sealed, not merely signed, so provider/user ids do not leak into client-side
 * readable cookie values.
 */
export function createAdminSessionCookie(input: Omit<AdminSessionPayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return sealCookie({
    ...input,
    issuedAt: now,
    expiresAt: now + ADMIN_SESSION_TTL_MS
  })
}

export function createOidcStateCookie(input: Omit<AdminOidcStatePayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return sealCookie({
    ...input,
    issuedAt: now,
    expiresAt: now + OIDC_STATE_TTL_MS
  })
}

export function readAdminSessionCookie(header: string | null): AdminSessionPayload | undefined {
  const value = parseCookieHeader(header)?.[ADMIN_SESSION_COOKIE]
  if (!value) return undefined

  return readSealedCookie<AdminSessionPayload>(value)
}

export function readOidcStateCookie(header: string | null): AdminOidcStatePayload | undefined {
  const value = parseCookieHeader(header)?.[ADMIN_OIDC_STATE_COOKIE]
  if (!value) return undefined

  return readSealedCookie<AdminOidcStatePayload>(value)
}

export function cookieHeader(
  name: string,
  value: string,
  options: { maxAgeSeconds?: number; secure: boolean }
): string {
  const maxAge = options.maxAgeSeconds === undefined ? '' : `; Max-Age=${options.maxAgeSeconds}`
  const secure = options.secure ? '; Secure' : ''
  return `${name}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax${secure}${maxAge}`
}

export function expiredCookieHeader(name: string, secure: boolean): string {
  const securePart = secure ? '; Secure' : ''
  return `${name}=; Path=/; HttpOnly; SameSite=Lax${securePart}; Max-Age=0`
}

export function safeReturnTo(value: string | null | undefined): string {
  if (!value) return '/admin'
  if (!value.startsWith('/') || value.startsWith('//')) return '/admin'

  return value
}

export function newOpaqueToken(): string {
  return crypto.randomUUID().replaceAll('-', '')
}

function readSealedCookie<TPayload extends { expiresAt: number }>(value: string): TPayload | undefined {
  try {
    const payload = JSON.parse(aeadDecrypt(value, sessionKey()).toString('utf-8')) as TPayload
    if (payload.expiresAt < Date.now()) return undefined

    return payload
  } catch {
    return undefined
  }
}

function sealCookie(payload: unknown): string {
  return aeadEncrypt(JSON.stringify(payload), sessionKey())
}

function sessionKey(): string {
  return getSecretKey(SecretKeyPurpose.ADMIN_AUTH_SESSION, 'admin-auth-cookie')
}

function parseCookieHeader(header: string | null): Record<string, string> | undefined {
  const cookies: Record<string, string> = {}
  if (!header) return cookies

  for (const part of header.split(';')) {
    const [name, ...rest] = part.trim().split('=')
    if (!name || rest.length === 0) continue

    try {
      cookies[name] = decodeURIComponent(rest.join('='))
    } catch {
      // Malformed cookies should behave like absent credentials. Surfacing a
      // 500/400 here would let a bad client cookie break the admin placeholder
      // page instead of simply forcing a fresh login.
      return undefined
    }
  }

  return cookies
}

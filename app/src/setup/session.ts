import { ms } from '@pleisto/active-support'
import { SecretKeyPurpose } from '@/common/kms'
import { createSealedCookieCodec, type OidcStateCookiePayload } from '@/common/sealed-cookie'
import { cookieHeader, expiredCookieHeader, newOpaqueToken, parseCookieHeader } from '@/principals/admin-auth/session'

export const SETUP_SESSION_COOKIE = '_bullx_agent_setup_session'
export const SETUP_OIDC_STATE_COOKIE = '_bullx_agent_setup_oidc_state'

const SETUP_SESSION_TTL_MS = ms('24h')
const OIDC_STATE_TTL_MS = ms('10m')

const setupCookieCodec = createSealedCookieCodec(SecretKeyPurpose.ADMIN_AUTH_SESSION, 'setup-cookie')

export interface SetupSessionPayload {
  sessionId: string
  issuedAt: number
  expiresAt: number
}

export type SetupOidcStatePayload = OidcStateCookiePayload

/**
 * Creates a sealed setup-session cookie payload.
 *
 * This proves possession of the bootstrap activation code, not an admin login.
 * Route guards must still check `setup.completed` before trusting it.
 */
export function createSetupSessionCookie(): string {
  const now = Date.now()
  return setupCookieCodec.seal({
    sessionId: newOpaqueToken(),
    issuedAt: now,
    expiresAt: now + SETUP_SESSION_TTL_MS
  })
}

/**
 * Reads and validates the setup-session cookie from a request header.
 */
export function readSetupSessionCookie(header: string | null): SetupSessionPayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_SESSION_COOKIE]
  if (!value) return undefined

  return setupCookieCodec.read<SetupSessionPayload>(value)
}

/**
 * Creates the short-lived OIDC state cookie used during setup-time provider tests.
 */
export function createSetupOidcStateCookie(input: Omit<SetupOidcStatePayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return setupCookieCodec.seal({
    ...input,
    issuedAt: now,
    expiresAt: now + OIDC_STATE_TTL_MS
  })
}

/**
 * Reads the setup OIDC state cookie from a request header.
 */
export function readSetupOidcStateCookie(header: string | null): SetupOidcStatePayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_OIDC_STATE_COOKIE]
  if (!value) return undefined

  return setupCookieCodec.read<SetupOidcStatePayload>(value)
}

/**
 * Builds the HTTP `Set-Cookie` header for a new setup session.
 */
export function setupSessionSetCookie(secure: boolean): string {
  return cookieHeader(SETUP_SESSION_COOKIE, createSetupSessionCookie(), {
    secure,
    maxAgeSeconds: Math.floor(SETUP_SESSION_TTL_MS / 1000)
  })
}

/**
 * Builds the HTTP `Set-Cookie` header that clears setup-session state.
 */
export function setupSessionExpiredCookie(secure: boolean): string {
  return expiredCookieHeader(SETUP_SESSION_COOKIE, secure)
}

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

export function createSetupSessionCookie(): string {
  const now = Date.now()
  return setupCookieCodec.seal({
    sessionId: newOpaqueToken(),
    issuedAt: now,
    expiresAt: now + SETUP_SESSION_TTL_MS
  })
}

export function readSetupSessionCookie(header: string | null): SetupSessionPayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_SESSION_COOKIE]
  if (!value) return undefined

  return setupCookieCodec.read<SetupSessionPayload>(value)
}

export function createSetupOidcStateCookie(input: Omit<SetupOidcStatePayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return setupCookieCodec.seal({
    ...input,
    issuedAt: now,
    expiresAt: now + OIDC_STATE_TTL_MS
  })
}

export function readSetupOidcStateCookie(header: string | null): SetupOidcStatePayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_OIDC_STATE_COOKIE]
  if (!value) return undefined

  return setupCookieCodec.read<SetupOidcStatePayload>(value)
}

export function setupSessionSetCookie(secure: boolean): string {
  return cookieHeader(SETUP_SESSION_COOKIE, createSetupSessionCookie(), {
    secure,
    maxAgeSeconds: Math.floor(SETUP_SESSION_TTL_MS / 1000)
  })
}

export function setupSessionExpiredCookie(secure: boolean): string {
  return expiredCookieHeader(SETUP_SESSION_COOKIE, secure)
}

import { aeadDecrypt, aeadEncrypt } from '@agentbull/bullx-native-addons'
import { ms } from '@pleisto/active-support'
import { getSecretKey, SecretKeyPurpose } from '@/common/kms'
import { cookieHeader, expiredCookieHeader, newOpaqueToken, parseCookieHeader } from '@/principals/admin-auth/session'

export const SETUP_SESSION_COOKIE = '_bullx_agent_setup_session'
export const SETUP_OIDC_STATE_COOKIE = '_bullx_agent_setup_oidc_state'

const SETUP_SESSION_TTL_MS = ms('24h')
const OIDC_STATE_TTL_MS = ms('10m')

export interface SetupSessionPayload {
  sessionId: string
  issuedAt: number
  expiresAt: number
}

export interface SetupOidcStatePayload {
  providerId: string
  state: string
  nonce: string
  returnTo: string
  redirectUri: string
  issuedAt: number
  expiresAt: number
}

export function createSetupSessionCookie(): string {
  const now = Date.now()
  return sealSetupCookie({
    sessionId: newOpaqueToken(),
    issuedAt: now,
    expiresAt: now + SETUP_SESSION_TTL_MS
  })
}

export function readSetupSessionCookie(header: string | null): SetupSessionPayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_SESSION_COOKIE]
  if (!value) return undefined

  return readSetupCookie<SetupSessionPayload>(value)
}

export function createSetupOidcStateCookie(input: Omit<SetupOidcStatePayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return sealSetupCookie({
    ...input,
    issuedAt: now,
    expiresAt: now + OIDC_STATE_TTL_MS
  })
}

export function readSetupOidcStateCookie(header: string | null): SetupOidcStatePayload | undefined {
  const value = parseCookieHeader(header)?.[SETUP_OIDC_STATE_COOKIE]
  if (!value) return undefined

  return readSetupCookie<SetupOidcStatePayload>(value)
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

function readSetupCookie<TPayload extends { expiresAt: number }>(value: string): TPayload | undefined {
  try {
    const payload = JSON.parse(aeadDecrypt(value, setupSessionKey()).toString('utf-8')) as TPayload
    if (payload.expiresAt < Date.now()) return undefined

    return payload
  } catch {
    return undefined
  }
}

function sealSetupCookie(payload: unknown): string {
  return aeadEncrypt(JSON.stringify(payload), setupSessionKey())
}

function setupSessionKey(): string {
  return getSecretKey(SecretKeyPurpose.ADMIN_AUTH_SESSION, 'setup-cookie')
}

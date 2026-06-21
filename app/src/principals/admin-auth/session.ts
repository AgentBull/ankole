import { ms } from '@pleisto/active-support'
import { SecretKeyPurpose } from '@/common/kms'
import { createSealedCookieCodec, type OidcStateCookiePayload } from '@/common/sealed-cookie'

export const ADMIN_SESSION_COOKIE = '_bullx_agent_session'
export const ADMIN_OIDC_STATE_COOKIE = '_bullx_agent_oidc_state'

// The login session lives much longer than the in-flight OIDC handshake. The
// state cookie only has to survive one redirect round-trip to the provider and
// back, so its 10-minute lifetime bounds how long a stolen or replayed `state`
// value stays usable; the session itself is a normal 7-day console login.
const ADMIN_SESSION_TTL_MS = ms('7d')
const OIDC_STATE_TTL_MS = ms('10m')

export const ADMIN_SESSION_TTL_SECONDS = Math.floor(ADMIN_SESSION_TTL_MS / 1000)

// Both the session and the OIDC-state cookie are sealed with the same key
// purpose/context. The seal is keyed AEAD, so a client can neither read the
// payload nor forge or tamper with one without the server key — any edit fails
// the auth tag and `read` returns undefined (see the session.test tamper case).
const adminCookieCodec = createSealedCookieCodec(SecretKeyPurpose.ADMIN_AUTH_SESSION, 'admin-auth-cookie')

export interface AdminSessionPayload {
  principalUid: string
  providerId: string
  externalId: string
  issuedAt: number
  expiresAt: number
}

export type AdminOidcStatePayload = OidcStateCookiePayload

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
  return adminCookieCodec.seal({
    ...input,
    issuedAt: now,
    expiresAt: now + ADMIN_SESSION_TTL_MS
  })
}

/**
 * Seals the pre-login OIDC handshake state (provider, `state`, `nonce`,
 * `returnTo`, `redirectUri`) into a short-lived cookie.
 *
 * Carrying `state`/`nonce`/`redirectUri` in a sealed cookie (rather than
 * server-side storage) keeps the flow stateless while still being safe: the
 * client cannot read or alter the values, so the callback can trust the `state`
 * it echoes back to defend against CSRF and the `nonce` to defend against token
 * replay. `expiresAt` bounds the handshake window.
 */
export function createOidcStateCookie(input: Omit<AdminOidcStatePayload, 'issuedAt' | 'expiresAt'>): string {
  const now = Date.now()
  return adminCookieCodec.seal({
    ...input,
    issuedAt: now,
    expiresAt: now + OIDC_STATE_TTL_MS
  })
}

export function readAdminSessionCookie(header: string | null): AdminSessionPayload | undefined {
  const value = parseCookieHeader(header)?.[ADMIN_SESSION_COOKIE]
  if (!value) return undefined

  return adminCookieCodec.read<AdminSessionPayload>(value)
}

export function readOidcStateCookie(header: string | null): AdminOidcStatePayload | undefined {
  const value = parseCookieHeader(header)?.[ADMIN_OIDC_STATE_COOKIE]
  if (!value) return undefined

  return adminCookieCodec.read<AdminOidcStatePayload>(value)
}

/**
 * Builds the `Set-Cookie` header for a sealed admin cookie.
 *
 * The attributes are the security contract for these cookies, not cosmetic:
 * `HttpOnly` keeps the sealed value out of reach of page scripts (so an XSS bug
 * cannot exfiltrate a session), `SameSite=Lax` blocks the cookie on cross-site
 * POSTs while still allowing the top-level redirect back from the OIDC provider,
 * and `Secure` (production only — omitted on plain-HTTP local dev) keeps it off
 * non-TLS connections. A missing `maxAgeSeconds` yields a session cookie.
 */
export function cookieHeader(
  name: string,
  value: string,
  options: { maxAgeSeconds?: number; secure: boolean }
): string {
  const maxAge = options.maxAgeSeconds === undefined ? '' : `; Max-Age=${options.maxAgeSeconds}`
  const secure = options.secure ? '; Secure' : ''
  return `${name}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax${secure}${maxAge}`
}

/**
 * Builds a `Set-Cookie` header that deletes a cookie.
 *
 * `Max-Age=0` with an empty value tells the browser to drop it now. The other
 * attributes are repeated because a browser only overwrites a cookie when the
 * name, Path, and security flags match the original; an attribute mismatch would
 * leave the old cookie in place. Used for logout and for clearing the one-shot
 * OIDC-state cookie once the handshake completes.
 */
export function expiredCookieHeader(name: string, secure: boolean): string {
  const securePart = secure ? '; Secure' : ''
  return `${name}=; Path=/; HttpOnly; SameSite=Lax${securePart}; Max-Age=0`
}

/**
 * Constrains the post-login redirect target to a same-origin path.
 *
 * `returnTo` originates from a client query parameter, so it is an open-redirect
 * vector: a value like `https://evil.example` or the protocol-relative `//evil`
 * would send a freshly authenticated admin to an attacker site. Only a single
 * leading slash (a same-site absolute path) is accepted; anything else falls
 * back to the console home.
 */
export function safeReturnTo(value: string | null | undefined): string {
  if (!value) return '/console'
  if (!value.startsWith('/') || value.startsWith('//')) return '/console'

  return value
}

/**
 * Mints a high-entropy, URL-safe opaque token for the OIDC `state` and `nonce`.
 *
 * Hyphens are stripped only so the value drops cleanly into a URL query without
 * encoding; the security property is the 122 bits of randomness from
 * `crypto.randomUUID`, not the format.
 */
export function newOpaqueToken(): string {
  return crypto.randomUUID().replaceAll('-', '')
}

/**
 * Parses a raw `Cookie` header into a name to value map.
 *
 * Distinguishes two empty-ish cases on purpose: a missing header is normal and
 * yields an empty map, but a header that fails to decode yields `undefined` so
 * callers treat a corrupt cookie jar as "no credentials" rather than reading
 * stale entries from a partially parsed header (see the malformed branch below).
 */
export function parseCookieHeader(header: string | null): Record<string, string> | undefined {
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

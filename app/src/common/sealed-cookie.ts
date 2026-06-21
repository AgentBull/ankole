import { sealJson, unsealJson } from './aead-seal'
import { getSecretKey, SecretKeyPurpose } from './kms'

/**
 * Sealed (AEAD-encrypted) cookie codec.
 *
 * Admin-console and first-run setup both bind short-lived browser state to a
 * sealed cookie before any SPA/API token flow exists. The seal/unseal logic is
 * identical; only the KMS key context differs. This is the single home for that
 * codec so the two cookie surfaces cannot drift.
 */
export interface SealedCookieCodec {
  /** Seal an arbitrary JSON payload into an opaque cookie value. */
  seal(payload: unknown): string
  /** Unseal and JSON-parse a cookie value; returns `undefined` when invalid or expired. */
  read<TPayload extends { expiresAt: number }>(value: string): TPayload | undefined
}

/**
 * Builds a codec bound to one `(purpose, context)` key domain.
 *
 * Confidentiality and integrity come from the AEAD seal: the client never sees
 * the plaintext and cannot forge or edit a cookie without the server key, so
 * the payload is fully server-trusted on read. The only protections this layer
 * adds on top are the `expiresAt` bound below and key-domain isolation (a cookie
 * sealed for one surface fails to unseal for another, because the derived key
 * differs).
 *
 * The key is fetched per call via `key()` rather than captured once, so a
 * mid-process root-secret rotation takes effect for new operations without
 * re-creating the codec.
 */
export function createSealedCookieCodec(purpose: SecretKeyPurpose, context: string): SealedCookieCodec {
  const key = () => getSecretKey(purpose, context)
  return {
    seal(payload: unknown): string {
      return sealJson(payload, key())
    },
    read<TPayload extends { expiresAt: number }>(value: string): TPayload | undefined {
      try {
        const payload = unsealJson<TPayload>(value, key())
        // Self-expiry: the seal proves authenticity but not freshness, so a
        // valid-but-old cookie is still rejected. This is the only replay bound —
        // there is no server-side nonce store, so a captured cookie remains
        // usable until `expiresAt`. Kept short upstream to limit that window.
        if (payload.expiresAt < Date.now()) return undefined

        return payload
      } catch {
        // Any failure — wrong key (e.g. after rotation or wrong purpose),
        // malformed framing, or a failed auth tag — is treated as "no valid
        // cookie" rather than an error, so a tampered or stale value just logs
        // the user out instead of breaking the request.
        return undefined
      }
    }
  }
}

/**
 * OIDC redirect-state cookie payload.
 *
 * Shared by the admin-auth and setup OIDC flows: both bind the same provider /
 * state / nonce / redirect fields to a sealed cookie across the redirect.
 */
export interface OidcStateCookiePayload {
  providerId: string
  state: string
  nonce: string
  returnTo: string
  redirectUri: string
  issuedAt: number
  expiresAt: number
}

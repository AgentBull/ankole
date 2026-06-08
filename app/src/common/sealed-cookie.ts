import { aeadDecrypt, aeadEncrypt } from '@agentbull/bullx-native-addons'
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

export function createSealedCookieCodec(purpose: SecretKeyPurpose, context: string): SealedCookieCodec {
  const key = () => getSecretKey(purpose, context)
  return {
    seal(payload: unknown): string {
      return aeadEncrypt(JSON.stringify(payload), key())
    },
    read<TPayload extends { expiresAt: number }>(value: string): TPayload | undefined {
      try {
        const payload = JSON.parse(aeadDecrypt(value, key()).toString('utf-8')) as TPayload
        if (payload.expiresAt < Date.now()) return undefined

        return payload
      } catch {
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

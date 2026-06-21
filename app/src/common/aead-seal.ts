import { aeadDecrypt, aeadEncrypt, deriveKey } from '@agentbull/bullx-native-addons'

/**
 * Thin "seal" wrapper over the native XChaCha20-Poly1305-IETF AEAD primitive.
 *
 * This module is the single at-rest symmetric envelope used across BullX
 * (DB-stored secrets, sealed cookies, reasoning-trace refs). It exists so call
 * sites talk about sealing a value with a key, and never touch nonces, base64,
 * or the on-wire framing themselves.
 *
 * Envelope: the native layer draws a fresh random 24-byte nonce per call and
 * returns `base64url(nonce).base64url(ciphertext+tag)` (the `.` separator is
 * safe because it is outside the base64url alphabet). The nonce travels with the
 * ciphertext, so the same key safely seals many values. The Poly1305 tag makes
 * tampering detectable: any bit flip fails decryption rather than returning
 * garbage.
 *
 * Note on associated data: these helpers seal the value alone and pass no AEAD
 * associated data (AAD). Integrity covers the ciphertext, not any surrounding
 * context (row id, purpose, ...). Domain separation is instead achieved upstream
 * by deriving a distinct per-purpose key (see {@link deriveSealKey} and
 * `kms.ts`), so a blob sealed for one purpose cannot be unsealed under another.
 */

/** Seals bytes or a UTF-8 string into the opaque nonce-prefixed envelope above. */
export function sealText(value: string | Buffer, key: string): string {
  return aeadEncrypt(value, key)
}

/**
 * Reverses {@link sealText}, decoding the plaintext as UTF-8.
 *
 * Throws when the key is wrong, the framing is malformed, or the Poly1305 tag
 * does not verify; callers that treat a bad/forged value as "absent" must catch
 * (see `sealed-cookie.ts`).
 */
export function unsealText(value: string, key: string): string {
  return aeadDecrypt(value, key).toString('utf-8')
}

/** Seals an arbitrary JSON-serializable value. Shape is the caller's contract, not enforced here. */
export function sealJson(value: unknown, key: string): string {
  return sealText(JSON.stringify(value), key)
}

/**
 * Unseals and JSON-parses. The `TValue` cast is unchecked — decryption proves
 * the bytes were sealed under this key, not that they match the expected shape.
 */
export function unsealJson<TValue = unknown>(value: string, key: string): TValue {
  return JSON.parse(unsealText(value, key)) as TValue
}

/**
 * Derives a purpose-scoped 32-byte seal key from a higher-level secret via the
 * native BLAKE3 KDF.
 *
 * `subKeyId` is the domain-separation tag (used verbatim, case-sensitive) and
 * `context` is an optional non-secret, low-entropy disambiguator. Different
 * `subKeyId`/`context` pairs yield independent keys from the same seed, which is
 * how this codebase keeps one root secret from being reused across unrelated
 * surfaces. The hex output is exactly the key width the AEAD cipher expects.
 */
export function deriveSealKey(keySeed: string | Buffer, subKeyId: string, context?: string): string {
  return deriveKey(keySeed, subKeyId, context)
}

import { deriveKey } from '@agentbull/bullx-native-addons'
import { AppEnv } from '@/config/env'

/**
 * Minimal key-management layer for a single self-hosted BullX installation.
 *
 * There is one operator-provided root secret (`AppEnv.ROOT_SECRET`); every
 * symmetric key in the system is derived from it on demand rather than stored.
 * The installation rotates by rotating that single root secret. There is no
 * external KMS/HSM and no per-key persistence — deliberately boring for a
 * self-hosted product where the operator already controls the host.
 */

/**
 * Domain-separation tags for derived keys. Each purpose produces an independent
 * key from the same root secret, so a compromise or misuse of one surface (e.g.
 * a leaked admin-session key) cannot decrypt another (e.g. DB-stored secrets).
 * Adding a purpose is a code change, which keeps the set of key domains auditable
 * in one place.
 */
export enum SecretKeyPurpose {
  DATABASE_ENCRYPTION = 'database_encryption',
  ADMIN_AUTH_SESSION = 'admin_auth_session',
  AI_AGENT_REASONING_TRACE = 'ai_agent_reasoning_trace'
}

/**
 * Derives the symmetric key for a given purpose from the root secret.
 *
 * `purpose` is the primary domain separator; the optional `context` narrows
 * further within a purpose (e.g. one cookie surface vs another) without minting a
 * new enum value. Because derivation is deterministic, the key is recomputed each
 * call rather than cached, which keeps long-lived key material out of process
 * memory between uses. Rotating `AppEnv.ROOT_SECRET` invalidates everything
 * sealed under the old secret — accepted, since these are short-lived sessions
 * and re-encryptable at-rest blobs, not long-term archives.
 */
export function getSecretKey(purpose: SecretKeyPurpose, context?: string): string {
  return deriveKey(AppEnv.ROOT_SECRET, purpose, context)
}

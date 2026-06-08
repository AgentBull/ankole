import { createHmac } from 'node:crypto'

/**
 * Minimal HS256 JWT signer for computer session tokens. The worker daemon verifies
 * these with `jsonwebtoken` (HS256) using the same shared secret
 * (`BULLX_COMPUTER_TOKEN`). Keeping it tiny avoids pulling a JWT dependency for a
 * single, internal token shape.
 */

export interface ComputerTokenClaims {
  agentUid: string
  workerId: string
  instanceId: string
  /** Expiry, seconds since epoch. */
  exp: number
}

function base64url(input: string | Buffer): string {
  return Buffer.from(input).toString('base64url')
}

export function signComputerToken(claims: ComputerTokenClaims, secret: string): string {
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const payload = base64url(JSON.stringify(claims))
  const data = `${header}.${payload}`
  const signature = base64url(createHmac('sha256', secret).update(data).digest())
  return `${data}.${signature}`
}

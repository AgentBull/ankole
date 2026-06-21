import type { ResolveSessionResponse } from '../types'
import { BaseClient } from './base-client'

/**
 * Client for the BullX app control plane. Unlike {@link WorkerClient} this talks to
 * the app over plain HTTP (no mTLS): its one job is to ask which worker hosts an
 * agent and to hand back the mTLS material to then reach that worker directly.
 */
export class ControlClient extends BaseClient {
  /**
   * Resolves an agent to its worker binding (coordinates + client certs). Callers
   * wrap this in `withRetry` because resolution is transient — it can briefly fail
   * during deploys or rebinding — and is safe to retry.
   */
  resolveSession(agentUid: string, signal?: AbortSignal): Promise<ResolveSessionResponse> {
    return this.json<ResolveSessionResponse>({
      method: 'POST',
      path: '/internal/computer/sessions/resolve',
      contentType: 'application/json',
      body: JSON.stringify({ agentUid }),
      signal
    })
  }
}

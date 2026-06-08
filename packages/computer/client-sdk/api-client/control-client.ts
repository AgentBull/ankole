import type { ResolveSessionResponse } from '../types'
import { BaseClient } from './base-client'

/** Client for the BullX app control plane (worker resolution / binding). */
export class ControlClient extends BaseClient {
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

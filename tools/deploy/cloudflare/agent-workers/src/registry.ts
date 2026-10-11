import { DurableObject } from 'cloudflare:workers'
import type { Env } from './env'

export type RegistryEntry = { agent_uid: string; provider_id: string }

/** Entries remain after an instance stops, until Agent storage is deleted. */
export class Registry extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS agents (agent_uid TEXT PRIMARY KEY, provider_id TEXT NOT NULL)')
  }

  add(agentUid: string, providerId: string): void {
    this.ctx.storage.sql.exec(
      'INSERT INTO agents (agent_uid, provider_id) VALUES (?, ?) ON CONFLICT (agent_uid) DO UPDATE SET provider_id = excluded.provider_id',
      agentUid,
      providerId
    )
  }

  remove(agentUid: string, providerId: string): void {
    this.ctx.storage.sql.exec('DELETE FROM agents WHERE agent_uid = ? AND provider_id = ?', agentUid, providerId)
  }

  list(providerId: string): RegistryEntry[] {
    return this.ctx.storage.sql
      .exec<RegistryEntry>(
        'SELECT agent_uid, provider_id FROM agents WHERE provider_id = ? ORDER BY agent_uid',
        providerId
      )
      .toArray()
  }
}

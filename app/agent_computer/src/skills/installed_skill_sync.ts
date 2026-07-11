import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnStart } from '../lanes/actor_lane'
import type { InstalledSkillObservation } from './types'
import { scanInstalledSkills } from './installed_skills'

export type InstalledSkillSyncLogger = {
  warning(event: string, message: string, fields?: JSONObject): void
  error(event: string, message: string, fields?: JSONObject): void
}

export type InstalledSkillReplaceRequester = (request: {
  request_id: string
  turn: TurnStart['turn']
  observations: InstalledSkillObservation[]
}) => Promise<unknown>

export type InstalledSkillSyncOptions = {
  agentInstalledSkillsRoot?: string
  replaceInstalledSkillObservations?: InstalledSkillReplaceRequester
  memoTtlMs?: number
  logger?: InstalledSkillSyncLogger
}

type InstalledSkillSyncMemo = {
  fingerprint: string
  syncedAtMs: number
}

const installedSkillSyncMemo = new Map<string, InstalledSkillSyncMemo>()
const defaultInstalledSkillSyncMemoTtlMs = 60_000

export async function syncInstalledSkillsForTurn(turnStart: TurnStart, opts: InstalledSkillSyncOptions): Promise<void> {
  if (!opts.agentInstalledSkillsRoot || !opts.replaceInstalledSkillObservations) return

  const agentUID = turnStart.turn.actor.agent_uid

  try {
    const scan = await scanInstalledSkills(opts.agentInstalledSkillsRoot, agentUID)
    for (const diagnostic of scan.diagnostics) {
      if (diagnostic.severity === 'error') {
        opts.logger?.error('worker.installed_skill_diagnostic', 'worker installed skill diagnostic', {
          agent_uid: agentUID,
          diagnostic
        })
      } else {
        opts.logger?.warning('worker.installed_skill_diagnostic', 'worker installed skill diagnostic', {
          agent_uid: agentUID,
          diagnostic
        })
      }
    }

    if (installedSkillSyncMemoFresh(agentUID, scan.fingerprint, opts)) return

    await opts.replaceInstalledSkillObservations({
      request_id: `skills-installed-replace-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      observations: scan.observations
    })

    installedSkillSyncMemo.set(agentUID, { fingerprint: scan.fingerprint, syncedAtMs: Date.now() })
  } catch (error) {
    opts.logger?.warning('worker.installed_skill_sync_failed', 'worker installed skill sync failed', {
      agent_uid: agentUID,
      error: error instanceof Error ? error : new Error(String(error))
    })
  }
}

function installedSkillSyncMemoFresh(agentUID: string, fingerprint: string, opts: InstalledSkillSyncOptions): boolean {
  const memo = installedSkillSyncMemo.get(agentUID)
  if (!memo || memo.fingerprint !== fingerprint) return false

  const ttlMs = opts.memoTtlMs ?? defaultInstalledSkillSyncMemoTtlMs
  return ttlMs > 0 && Date.now() - memo.syncedAtMs < ttlMs
}

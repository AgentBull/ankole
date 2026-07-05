import type { TurnStart } from '../../lanes/actor_lane'
import type { AgentConversationContext } from '../../lanes/rpc_lane'
import { logWorkerEvent } from '../../worker/logging'
import { scanInstalledSkills } from '../../worker/installed_skills'
import type { TextTurnLoopOptions } from './turn_options'

type InstalledSkillSyncMemo = {
  fingerprint: string
  syncedAtMs: number
}

const installedSkillSyncMemo = new Map<string, InstalledSkillSyncMemo>()
const defaultInstalledSkillSyncMemoTtlMs = 60_000

/**
 * Returns the already-resolved conversation context or asks the control plane.
 *
 * Tests and ambient turns can pass a context directly, but production text turns
 * must resolve it through RuntimeFabric so identity, prompt, and skill metadata
 * stay control-plane-owned.
 */
export async function resolveAgentConversationContext(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<AgentConversationContext> {
  // Installed skills are filesystem facts owned by the worker. Keep the PG
  // registry fresh even when a test or specialized caller injects context.
  await syncInstalledSkillsBeforeContext(turnStart, opts)
  if (opts.agentConversationContext) return opts.agentConversationContext
  if (!opts.requestAgentConversationContext) {
    throw new Error('agent conversation context RPC is required')
  }

  return await opts.requestAgentConversationContext({
    request_id: `agent-conversation-context-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    actor_event: turnStart.actor_event
  })
}

async function syncInstalledSkillsBeforeContext(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<void> {
  if (!opts.agentInstalledSkillsRoot || !opts.replaceInstalledSkillObservations) return

  const agentUid = turnStart.turn.actor.agent_uid

  try {
    const scan = await scanInstalledSkills(opts.agentInstalledSkillsRoot, agentUid)
    for (const diagnostic of scan.diagnostics) {
      logWorkerEvent('worker.installed_skill_diagnostic', { agent_uid: agentUid, diagnostic }, 'stderr')
    }

    if (installedSkillSyncMemoFresh(agentUid, scan.fingerprint, opts)) return

    await opts.replaceInstalledSkillObservations({
      request_id: `skills-installed-replace-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      observations: scan.observations
    })

    installedSkillSyncMemo.set(agentUid, { fingerprint: scan.fingerprint, syncedAtMs: Date.now() })
  } catch (error) {
    logWorkerEvent(
      'worker.installed_skill_sync_failed',
      {
        agent_uid: agentUid,
        error: error instanceof Error ? error.message : String(error)
      },
      'stderr'
    )
  }
}

function installedSkillSyncMemoFresh(agentUid: string, fingerprint: string, opts: TextTurnLoopOptions): boolean {
  const memo = installedSkillSyncMemo.get(agentUid)
  if (!memo || memo.fingerprint !== fingerprint) return false

  const ttlMs = opts.installedSkillSyncMemoTtlMs ?? defaultInstalledSkillSyncMemoTtlMs
  return ttlMs > 0 && Date.now() - memo.syncedAtMs < ttlMs
}

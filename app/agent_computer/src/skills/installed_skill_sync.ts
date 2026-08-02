import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { TurnStart } from '../lanes/actor_lane'
import { rpcMethods, type RPCRequester } from '../lanes/rpc_lane'
import { scanInstalledSkills } from './installed_skills'

export type InstalledSkillSyncLogger = {
  warning(event: string, message: string, fields?: JSONObject): void
  error(event: string, message: string, fields?: JSONObject): void
}

export type InstalledSkillSyncOptions = {
  agentInstalledSkillsRoot: string
  rpc: RPCRequester
  abortSignal?: AbortSignal
  memoTtlMs?: number
  logger?: InstalledSkillSyncLogger
}

type InstalledSkillSyncMemo = {
  snapshot: string
  syncedAtMs: number
}

const installedSkillSyncMemo = new Map<string, InstalledSkillSyncMemo>()
const defaultInstalledSkillSyncMemoTtlMs = 60_000

export async function syncInstalledSkillsForTurn(turnStart: TurnStart, opts: InstalledSkillSyncOptions): Promise<void> {
  const agentUID = turnStart.turn.actor.agent_uid

  try {
    const scan = await abortableInstalledSkillSyncStep(
      () => scanInstalledSkills(opts.agentInstalledSkillsRoot),
      opts.abortSignal
    )
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

    if (installedSkillSyncMemoFresh(agentUID, scan.snapshot, opts)) return

    await abortableInstalledSkillSyncStep(
      () =>
        opts.rpc(
          rpcMethods.skillsInstalledReplace,
          {
            observations: scan.observations.map(observation => ({
              skillName: observation.skill_name,
              description: observation.description,
              defaultEnabled: observation.default_enabled,
              tags: observation.tags,
              category: observation.category ?? '',
              disableModelInvocation: observation.disable_model_invocation,
              ankoleRuntime: observation.ankole_runtime ?? ''
            }))
          },
          { turn: turnStart.turn }
        ),
      opts.abortSignal
    )

    installedSkillSyncMemo.set(agentUID, { snapshot: scan.snapshot, syncedAtMs: Date.now() })
  } catch (error) {
    if (opts.abortSignal?.aborted) opts.abortSignal.throwIfAborted()

    opts.logger?.warning('worker.installed_skill_sync_failed', 'worker installed skill sync failed', {
      agent_uid: agentUID,
      error: error instanceof Error ? error : new Error(String(error))
    })
  }
}

function abortableInstalledSkillSyncStep<T>(start: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  signal?.throwIfAborted()
  const operation = start()
  if (!signal) return operation

  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason)
    signal.addEventListener('abort', onAbort, { once: true })
    operation.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

function installedSkillSyncMemoFresh(agentUID: string, snapshot: string, opts: InstalledSkillSyncOptions): boolean {
  const memo = installedSkillSyncMemo.get(agentUID)
  if (!memo || memo.snapshot !== snapshot) return false

  const ttlMs = opts.memoTtlMs ?? defaultInstalledSkillSyncMemoTtlMs
  return ttlMs > 0 && Date.now() - memo.syncedAtMs < ttlMs
}

import { isRecord } from '@pleisto/active-support'
import { assertRPCResponse, type AppConfigureResolveResponse } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import type { TextTurnLoopOptions } from './turn_options'

export const DeepResearchConfigKey = 'agent_computer.deep_research'

export type DeepResearchRuntimeConfig = {
  wallclockBudgetMs: number
  submissionGraceMs: number
  retentionDays: number
}

/** Resolves the control-plane-owned policy once at the start of a research attempt. */
export async function resolveDeepResearchRuntimeConfig(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<DeepResearchRuntimeConfig> {
  if (!opts.requestAppConfigure) throw new Error('Deep Research requires the control-plane AppConfigure resolver')

  const response = await opts.requestAppConfigure({
    request_id: `app-configure-deep-research-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid,
    keys: [DeepResearchConfigKey]
  })
  assertRPCResponse<AppConfigureResolveResponse>(response, 'Deep Research runtime config rejected')
  const value = response.values[DeepResearchConfigKey]?.value
  if (!isRecord(value)) throw new Error('Deep Research runtime config is not an object')

  return {
    wallclockBudgetMs: requiredInteger(value.wallclock_budget, 'wallclock_budget'),
    submissionGraceMs: requiredInteger(value.submission_grace, 'submission_grace'),
    retentionDays: requiredInteger(value.retention_days, 'retention_days')
  }
}

function requiredInteger(value: unknown, key: string): number {
  if (!Number.isInteger(value) || typeof value !== 'number') {
    throw new Error(`Deep Research runtime config ${key} must be an integer`)
  }
  return value
}

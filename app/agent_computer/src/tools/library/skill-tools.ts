import { z } from 'zod'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import type { RPCRequester, RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { SkillFileRoots } from '../../skills/effective-skill'
import { createSkillLoader, type SkillLoadDetails, type SkillLoader } from '../../skills/skill-loader'

// `name` is the enabled skill name from RuntimeFabric. `filePath` lets the model
// follow references out of SKILL.md without a second tool, but resolution always
// stays inside the skill's source directory.
const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

export type { SkillFileRoots } from '../../skills/effective-skill'

export interface CreateSkillToolsOptions {
  turn: ActorTurnRef
  enabledSkills?: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
  loader?: SkillLoader
}

/**
 * Creates the skill tools available to the model.
 *
 * `skill_view` reads base skill files from their real source roots and resolves
 * the per-agent skill-lesson block over RuntimeFabric only for SKILL.md. The
 * lesson block is read-only here: lessons are written by Dreaming and the
 * Console, and skill assignment remains a control-plane concern.
 */
export function createSkillTools(opts: CreateSkillToolsOptions): WorkerAgentTool[] {
  const loader =
    opts.loader ??
    createSkillLoader({
      turn: opts.turn,
      enabledSkills: opts.enabledSkills,
      skillRoots: opts.skillRoots,
      rpc: opts.rpc,
      runtime: 'main'
    })
  return [createSkillViewTool(loader)]
}

/**
 * `skill_view`: loads a skill's instructions on demand. The system prompt only lists
 * skills as an index (name + one-line description); when the model decides a listed
 * skill covers the task it is about to do, it calls this to pull in the full SOP.
 *
 * It deliberately cannot enable a skill: a missing skill source surfaces as a
 * thrown read error, since enabling/assigning skills is a control-plane decision,
 * not something the model does.
 */
export function createSkillViewTool(loader: SkillLoader): WorkerAgentTool<typeof SkillViewParams, SkillLoadDetails> {
  return defineWorkerTool({
    name: 'skill_view',
    description:
      'Read an enabled Skill file. In the main runtime, a background-job-only Skill returns routing guidance and rejects referenced resources; inside a background agent job, skill_view loads its full instructions. Read referenced files only when needed and resolve relative paths from the returned Skill directory. This tool cannot enable disabled Skills.',
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => ({
      key: 'signals_gateway.reply.activity.skill_load',
      bindings: { name: params.name }
    }),
    async execute(_toolCallId, params) {
      return await loader.load(params)
    }
  })
}

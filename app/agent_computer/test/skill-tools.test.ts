import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { createSkillTools } from '../src/tools/library/skill-tools'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import type { JobTurnRef } from '../src/lanes/session_lane'
import { createSkillLoader } from '../src/skills/skill-loader'

const turn: JobTurnRef = {
  session: { session_id: 'job:1000' },
  job_id: 1000,
  attempt: 2,
  signal_id: '00000000-0000-0000-0000-000000000000'
}
const skill = create(RuntimeSkillSummarySchema, {
  skillName: 'voice-drafting-method',
  sourceKind: 'builtin',
  relativePath: 'voice-drafting-method',
  metadataJson: jsonBytes({ 'ankole-runtime': 'background_job', brain_recall_only: true })
})
const unusedRPC = (async () => {
  throw new Error('unexpected RPC')
}) as unknown as RPCRequester

describe('Job skill_view adapter', () => {
  it('exposes one read tool and keeps paths out of activity text', () => {
    const tools = createSkillTools({ turn, rpc: unusedRPC })
    expect(tools.map(tool => tool.name)).toEqual(['skill_view'])
    expect(tools[0]!.describeActivity({ name: 'pdf', filePath: 'references/private.md' })).toEqual({
      key: 'conversations.delivery.reply.activity.skill_load',
      bindings: { name: 'pdf' }
    })
  })

  it('loads prompt-hidden instructions and referenced files from the same fenced owner', async () => {
    const calls: unknown[] = []
    const loaded: string[] = []
    const rpc = (async (method: unknown, payload: unknown, scope: unknown) => {
      expect(method).toBe('tools.read')
      expect(scope).toEqual({ jobTurn: turn })
      const request = payload as { name: string; argumentsJson: Uint8Array }
      expect(request.name).toBe('skill_view')
      const args = jsonObjectFromBytes(request.argumentsJson, 'args')!
      calls.push(args)
      return {
        bodyJson: jsonBytes({
          output: args.filePath ? '# Reference' : '# Instructions with dated field notes',
          details: {}
        })
      }
    }) as unknown as RPCRequester
    const loader = createSkillLoader({ turn, rpc, enabledSkills: [skill], onSkillLoaded: name => loaded.push(name) })
    const tool = createSkillTools({ turn, rpc: unusedRPC, loader })[0]!
    expect((await tool.execute('first', { name: skill.skillName })).content[0]).toEqual({
      type: 'text',
      text: '# Instructions with dated field notes'
    })
    expect(
      (await tool.execute('reference', { name: skill.skillName, filePath: 'references/examples.md' })).content[0]
    ).toEqual({
      type: 'text',
      text: '# Reference'
    })
    expect(calls).toEqual([{ name: skill.skillName }, { name: skill.skillName, filePath: 'references/examples.md' }])
    expect(loaded).toEqual([skill.skillName, skill.skillName])
    loader.disable([skill.skillName])
    await expect(loader.load({ name: skill.skillName, filePath: 'references/examples.md' })).rejects.toThrow(
      'not enabled'
    )
    expect(calls).toHaveLength(2)
  })

  it('propagates current enablement and resource-confinement rejections from the owner', async () => {
    const rpc = (async () => {
      throw new Error('skill_not_enabled')
    }) as unknown as RPCRequester
    const loader = createSkillLoader({ turn, rpc, enabledSkills: [skill] })
    await expect(loader.load({ name: skill.skillName })).rejects.toThrow('skill_not_enabled')
    await expect(loader.load({ name: 'absent' })).rejects.toThrow('not enabled')
    const confinement = createSkillLoader({
      turn,
      enabledSkills: [skill],
      rpc: (async () => {
        throw new Error('invalid skill file path')
      }) as unknown as RPCRequester
    })
    await expect(confinement.load({ name: skill.skillName, filePath: '../private.txt' })).rejects.toThrow(
      'invalid skill file path'
    )
  })
})

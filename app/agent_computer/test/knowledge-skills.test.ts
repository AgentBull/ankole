import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeKnowledgeSkills } from '../src/skills/knowledge-skills'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes } from '../src/fabric/envelope_proto'
import type { RPCRequester } from '../src/lanes/rpc_lane'

const skill = create(RuntimeSkillSummarySchema, { skillName: 'demo', sourceKind: 'builtin', relativePath: 'demo' })

describe('conversation-visible Skill packages', () => {
  it('uses the fenced Pod package, preserves executable files and refreshes removed files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'ankole-skill-turn-'))
    const frame = { run: { session: { session_id: 'conversation:1' }, signal_id: 'signal-1', epoch: 1 } }
    let files = [
      { path: 'SKILL.md', content: Buffer.from('Skill and visible supplement.').toString('base64'), mode: 0o444 },
      { path: 'scripts/run.sh', content: Buffer.from('echo current').toString('base64'), mode: 0o755 }
    ]
    const rpc = (async (method: string, payload: unknown, actualFrame: unknown) => {
      expect(method).toBe('pod.read')
      expect(payload).toMatchObject({ operation: 'skills.bundle' })
      expect(actualFrame).toEqual(frame)
      return { bodyJson: jsonBytes({ files }) }
    }) as unknown as RPCRequester
    try {
      const projected = await materializeKnowledgeSkills({ root, frame, skills: [skill], rpc })
      expect(projected.skills[0]?.sourceKind).toBe('installed')
      expect(await readFile(join(root, 'demo/SKILL.md'), 'utf8')).toBe('Skill and visible supplement.')
      expect((await stat(join(root, 'demo/scripts/run.sh'))).mode & 0o777).toBe(0o555)
      files = [{ path: 'SKILL.md', content: Buffer.from('Updated contract.').toString('base64'), mode: 0o444 }]
      await materializeKnowledgeSkills({ root, frame, skills: [skill], rpc })
      expect(await readFile(join(root, 'demo/SKILL.md'), 'utf8')).toBe('Updated contract.')
      expect(
        await stat(join(root, 'demo/scripts/run.sh')).then(
          () => true,
          () => false
        )
      ).toBe(false)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
})

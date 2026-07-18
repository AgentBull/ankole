import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { TurnStart } from '../src/lanes/actor_lane'
import { syncInstalledSkillsForTurn } from '../src/skills/installed_skill_sync'
import type { InstalledSkillSyncOptions } from '../src/skills/installed_skill_sync'
import { create } from '@bufbuild/protobuf'
import { InstalledSkillReplaceResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequestInit, type RPCRequester } from '../src/lanes/rpc_lane'

type PushedObservations = RPCRequestInit<'skills.installed.replace'>['observations'] & object

describe('@ankole/agent-computer installed skill sync', () => {
  it('pushes installed skill observations and memoizes unchanged scans', async () => {
    const root = tempRoot('turn-context-installed-skills')
    try {
      const agentUID = `agent-${Date.now()}`
      const turnStart = turnStartFor(agentUID)
      const skillDir = join(root, agentUID, 'agent-notes')
      mkdirSync(skillDir, { recursive: true })
      writeFileSync(
        join(skillDir, 'SKILL.md'),
        [
          '---',
          'name: agent-notes',
          'description: Agent installed notes.',
          'default_enabled: true',
          '---',
          '',
          '# Agent Notes',
          ''
        ].join('\n')
      )

      const pushedObservations: PushedObservations[] = []
      const opts: InstalledSkillSyncOptions = {
        agentInstalledSkillsRoot: root,
        rpc: (async (method: unknown, payload: unknown) => {
          expect(method).toBe(rpcMethods.skillsInstalledReplace)
          const request = payload as { observations: PushedObservations }
          pushedObservations.push(request.observations)
          return create(InstalledSkillReplaceResponseSchema, {
            changed: true,
            skills: request.observations.length,
            files: request.observations.reduce((sum, observation) => sum + (observation.fileCount ?? 0), 0),
            contentHash: '7b16fe7c3e492b87d9615265f0856cec'
          })
        }) as RPCRequester
      }

      await syncInstalledSkillsForTurn(turnStart, opts)
      expect(pushedObservations).toHaveLength(1)
      expect(pushedObservations[0]![0]).toMatchObject({ skillName: 'agent-notes' })

      await syncInstalledSkillsForTurn(turnStart, opts)
      expect(pushedObservations).toHaveLength(1)

      await syncInstalledSkillsForTurn(turnStart, { ...opts, memoTtlMs: 0 })
      expect(pushedObservations).toHaveLength(2)

      rmSync(skillDir, { recursive: true, force: true })
      await syncInstalledSkillsForTurn(turnStart, opts)
      expect(pushedObservations).toHaveLength(3)
      expect(pushedObservations[2]).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function tempRoot(name: string): string {
  const root = join(tmpdir(), `ankole-${name}-${Date.now()}-${Math.random()}`)
  mkdirSync(root, { recursive: true })
  return root
}

function turnStartFor(agentUID: string): TurnStart {
  return {
    turn: {
      actor: {
        agent_uid: agentUID,
        session_id: 'session-1'
      },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000901',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000901',
      queue_sequence: 1,
      type: 'im.message.received',
      source_event_id: 'source-1',
      payload_json: {}
    }
  }
}

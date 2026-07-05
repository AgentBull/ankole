import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveAgentConversationContext } from '../src/core/turns/turn_context'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'

describe('@ankole/agent-computer turn context', () => {
  it('syncs installed skill observations before resolving context and memoizes unchanged scans', async () => {
    const root = tempRoot('turn-context-installed-skills')
    try {
      const agentUid = `agent-${Date.now()}`
      const turnStart = turnStartFor(agentUid)
      const skillDir = join(root, agentUid, 'agent-notes')
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

      const order: string[] = []
      const pushedObservations: unknown[][] = []
      const opts: TextTurnLoopOptions = {
        workspaceRoot: root,
        agentInstalledSkillsRoot: root,
        requestAIGatewayApiKey: async () => {
          throw new Error('not used')
        },
        replaceInstalledSkillObservations: async request => {
          order.push('replace')
          pushedObservations.push(request.observations)
          return {
            request_id: request.request_id,
            agent_uid: agentUid,
            session_id: 'session-1',
            changed: true,
            skills: request.observations.length,
            files: request.observations.reduce((sum, observation) => sum + (observation.file_count ?? 0), 0),
            content_hash: '7b16fe7c3e492b87d9615265f0856cec'
          }
        },
        requestAgentConversationContext: async request => {
          order.push('context')
          return {
            request_id: request.request_id,
            agent_uid: agentUid,
            session_id: 'session-1',
            turn: turnStart.turn,
            skills: []
          }
        }
      }

      await resolveAgentConversationContext(turnStart, opts)
      expect(order).toEqual(['replace', 'context'])
      expect(pushedObservations).toHaveLength(1)
      expect(pushedObservations[0]![0]).toMatchObject({ skill_name: 'agent-notes' })

      await resolveAgentConversationContext(turnStart, opts)
      expect(order).toEqual(['replace', 'context', 'context'])
      expect(pushedObservations).toHaveLength(1)

      await resolveAgentConversationContext(turnStart, { ...opts, installedSkillSyncMemoTtlMs: 0 })
      expect(order).toEqual(['replace', 'context', 'context', 'replace', 'context'])
      expect(pushedObservations).toHaveLength(2)

      rmSync(skillDir, { recursive: true, force: true })
      await resolveAgentConversationContext(turnStart, opts)
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

function turnStartFor(agentUid: string): TurnStart {
  return {
    turn: {
      actor: {
        agent_uid: agentUid,
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

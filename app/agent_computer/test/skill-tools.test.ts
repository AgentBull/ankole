import { describe, expect, it } from 'bun:test'
import { createSkillTools } from '../src/tools/library/skill-tools'
import type { ActorTurnRef } from '../src/actor_lane'

describe('@ankole/agent-computer skill tools', () => {
  it('skill_append appends notes to the existing skill overlay', async () => {
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    }
    const writes: unknown[] = []

    const tools = createSkillTools('/workspace', {
      turn,
      enabledSkills: ['nano-pdf'],
      requestSkillOverlay: async request => ({
        request_id: request.request_id,
        agent_uid: turn.actor.agent_uid,
        session_id: turn.actor.session_id,
        skill_name: request.skill_name,
        has_overlay: true,
        overlay_json: { text: 'Prefer page-by-page verification.' },
        content_hash: 'hash-1'
      }),
      replaceSkillOverlay: async request => {
        writes.push(request)
        return {
          request_id: request.request_id,
          agent_uid: turn.actor.agent_uid,
          session_id: turn.actor.session_id,
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: request.overlay_json ?? {},
          content_hash: 'hash-2'
        }
      }
    })

    const tool = tools.find(candidate => candidate.name === 'skill_append')
    expect(tool).toBeTruthy()

    await tool!.execute('call-1', {
      name: 'nano-pdf',
      content: 'Use render output as final evidence.'
    })

    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatchObject({
      skill_name: 'nano-pdf',
      overlay_json: {
        text: 'Prefer page-by-page verification.\n\nUse render output as final evidence.'
      }
    })
  })

  it('skill_append creates the overlay text when no overlay exists yet', async () => {
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000002',
      revision: 0
    }
    const writes: unknown[] = []

    const tools = createSkillTools('/workspace', {
      turn,
      enabledSkills: ['nano-pdf'],
      requestSkillOverlay: async request => ({
        request_id: request.request_id,
        agent_uid: turn.actor.agent_uid,
        session_id: turn.actor.session_id,
        skill_name: request.skill_name,
        has_overlay: false,
        overlay_json: {},
        content_hash: undefined
      }),
      replaceSkillOverlay: async request => {
        writes.push(request)
        return {
          request_id: request.request_id,
          agent_uid: turn.actor.agent_uid,
          session_id: turn.actor.session_id,
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: request.overlay_json ?? {},
          content_hash: 'hash-1'
        }
      }
    })

    const tool = tools.find(candidate => candidate.name === 'skill_append')
    expect(tool).toBeTruthy()

    await tool!.execute('call-1', {
      name: 'nano-pdf',
      content: 'Create the first overlay note.'
    })

    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatchObject({
      skill_name: 'nano-pdf',
      overlay_json: {
        text: 'Create the first overlay note.'
      }
    })
  })
})

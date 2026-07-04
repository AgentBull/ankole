import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { createSkillTools } from '../src/tools/library/skill-tools'
import type { ActorTurnRef } from '../src/lanes/actor_lane'

describe('@ankole/agent-computer skill tools', () => {
  it('skill_view reads internal builtin skills and renders the skill directory attribute', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-${Date.now()}-${Math.random()}`)
    const builtinRoot = join(root, 'library')
    const internalRoot = join(root, 'internal')
    try {
      writeFileSyncWithParents(
        join(builtinRoot, 'nano-pdf', 'SKILL.md'),
        ['---', 'name: nano-pdf', 'description: Public PDF skill.', '---', '', '# Public nano-pdf', ''].join('\n')
      )
      writeFileSyncWithParents(
        join(internalRoot, 'nano-pdf', 'SKILL.md'),
        ['---', 'name: nano-pdf', 'description: Internal PDF skill.', '---', '', '# Internal nano-pdf', ''].join('\n')
      )

      const tools = createSkillTools('/workspace', {
        enabledSkills: [
          {
            skill_name: 'nano-pdf',
            source_kind: 'builtin',
            relative_path: 'nano-pdf',
            metadata: { skill_root: 'internal' }
          }
        ],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          internalSkillsRoot: internalRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        }
      })

      const tool = tools.find(candidate => candidate.name === 'skill_view')
      expect(tool).toBeTruthy()

      const result = await tool!.execute('call-1', { name: 'nano-pdf' })
      const text = result.content[0]?.type === 'text' ? result.content[0].text : ''
      expect(text).toContain('# Internal nano-pdf')
      expect(text).not.toContain('# Public nano-pdf')
      expect(text).toContain(`directory="${join(internalRoot, 'nano-pdf')}"`)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

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

function writeFileSyncWithParents(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

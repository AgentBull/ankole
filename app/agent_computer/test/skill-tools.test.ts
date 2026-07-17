import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { createSkillTools } from '../src/tools/library/skill-tools'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import type { ActorTurnRef } from '../src/lanes/actor_lane'

const testTurn: ActorTurnRef = {
  actor: { agent_uid: 'agent-1', session_id: 'session-1' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: '00000000-0000-0000-0000-000000000000',
  revision: 0
}

const unusedRPC = (async () => {
  throw new Error('RPC is not used by this test')
}) as RPCRequester

function overlayResolveRPC(text?: string): RPCRequester {
  return (async (method: unknown, payload: unknown) => {
    expect(method).toBe(rpcMethods.skillsOverlayResolve)
    const request = payload as { skill_name: string }
    return {
      request_id: 'req-1',
      agent_uid: 'agent-1',
      session_id: 'session-1',
      skill_name: request.skill_name,
      has_overlay: Boolean(text),
      overlay_json: text ? { text } : {},
      content_hash: 'overlay-hash'
    }
  }) as RPCRequester
}

describe('@ankole/agent-computer skill tools', () => {
  it('describes skill work by name without exposing file paths or update content', () => {
    const tools = createSkillTools('/workspace', { turn: testTurn, rpc: unusedRPC })
    const view = tools.find(tool => tool.name === 'skill_view')!
    const append = tools.find(tool => tool.name === 'skill_append')!
    const replace = tools.find(tool => tool.name === 'skill_replace')!

    const viewActivity = view.describeActivity(
      view.schema.parse({ name: 'openai-docs', filePath: 'references/private/internal.md' })
    )
    expect(viewActivity).toContain('openai-docs')
    expect(viewActivity).not.toContain('references/private/internal.md')

    for (const tool of [append, replace]) {
      const activity = tool.describeActivity(tool.schema.parse({ name: 'openai-docs', content: 'do-not-leak' }))
      expect(activity).toContain('openai-docs')
      expect(activity).not.toContain('do-not-leak')
    }
  })

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
        turn: testTurn,
        rpc: overlayResolveRPC(),
        enabledSkills: [
          {
            skill_name: 'nano-pdf',
            source_kind: 'builtin',
            relative_path: 'nano-pdf',
            skill_root: 'internal'
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

  it('skill_view keeps an explicit library root even when an internal directory also exists', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-library-${Date.now()}-${Math.random()}`)
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
        turn: testTurn,
        rpc: overlayResolveRPC(),
        enabledSkills: [
          {
            skill_name: 'nano-pdf',
            source_kind: 'builtin',
            relative_path: 'nano-pdf',
            skill_root: 'library'
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
      expect(text).toContain('# Public nano-pdf')
      expect(text).not.toContain('# Internal nano-pdf')
      expect(text).toContain(`directory="${join(builtinRoot, 'nano-pdf')}"`)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_view routes long-running skills to a BackgroundAgentJob without exposing their body or resources', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-long-${Date.now()}-${Math.random()}`)
    const builtinRoot = join(root, 'library')
    let overlayReads = 0
    let overlayWrites = 0
    try {
      writeFileSyncWithParents(
        join(builtinRoot, 'long-report', 'SKILL.md'),
        ['---', 'name: long-report', 'description: Long report.', '---', '', '# Private operation body', ''].join('\n')
      )
      writeFileSyncWithParents(join(builtinRoot, 'long-report', 'references', 'private.md'), 'private reference')

      const tools = createSkillTools('/workspace', {
        turn: testTurn,
        enabledSkills: [
          {
            skill_name: 'long-report',
            source_kind: 'builtin',
            relative_path: 'long-report',
            metadata: { long_running: true }
          }
        ],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        },
        rpc: (async (method: unknown) => {
          if (method === rpcMethods.skillsOverlayResolve) {
            overlayReads += 1
            return {
              request_id: 'req-1',
              agent_uid: 'agent-1',
              session_id: 'session-1',
              skill_name: 'long-report',
              has_overlay: true,
              overlay_json: { text: 'private overlay' },
              content_hash: 'overlay-hash'
            }
          }
          overlayWrites += 1
          throw new Error('unexpected long-running Skill overlay write')
        }) as RPCRequester
      })

      const tool = tools.find(candidate => candidate.name === 'skill_view')!
      const result = await tool.execute('call-long', { name: 'long-report' })
      const text = result.content[0]?.type === 'text' ? result.content[0].text : ''
      expect(text).toContain('background_agent_job(start)')
      expect(text).toContain('use the long-report Skill')
      expect(text).not.toContain('Private operation body')
      expect(text).not.toContain('private overlay')
      expect(overlayReads).toBe(0)

      await expect(
        tool.execute('call-long-reference', { name: 'long-report', filePath: 'references/private.md' })
      ).rejects.toThrow('available only inside a BackgroundAgentJob')

      const append = tools.find(candidate => candidate.name === 'skill_append')!
      const replace = tools.find(candidate => candidate.name === 'skill_replace')!
      await expect(
        append.execute('call-long-append', { name: 'long-report', content: 'blind append' })
      ).rejects.toThrow('available only inside a BackgroundAgentJob')
      await expect(
        replace.execute('call-long-replace', { name: 'long-report', content: 'blind replacement' })
      ).rejects.toThrow('available only inside a BackgroundAgentJob')
      expect(overlayReads).toBe(0)
      expect(overlayWrites).toBe(0)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_view enforces enabled scope, real-path confinement, and overlay composition', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-boundary-${Date.now()}-${Math.random()}`)
    const builtinRoot = join(root, 'library')
    const skillRoot = join(builtinRoot, 'enabled-skill')
    const outsideFile = join(root, 'outside-secret.txt')
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000003',
      revision: 0
    }

    try {
      writeFileSyncWithParents(
        join(skillRoot, 'SKILL.md'),
        ['---', 'name: enabled-skill', 'description: Enabled.', '---', '', '# Base instructions', ''].join('\n')
      )
      writeFileSync(outsideFile, 'must not be readable')
      symlinkSync(outsideFile, join(skillRoot, 'escaped.txt'))

      const tools = createSkillTools('/workspace', {
        turn,
        enabledSkills: [{ skill_name: 'enabled-skill', source_kind: 'builtin', relative_path: 'enabled-skill' }],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        },
        rpc: overlayResolveRPC('Agent-specific evidence rule.')
      })
      const tool = tools.find(candidate => candidate.name === 'skill_view')!

      const result = await tool.execute('call-enabled', { name: 'enabled-skill' })
      const text = result.content[0]?.type === 'text' ? result.content[0].text : ''
      expect(text).toContain('# Base instructions')
      expect(text).toContain('Agent-specific additions:')
      expect(text).toContain('Agent-specific evidence rule.')

      await expect(tool.execute('call-disabled', { name: 'disabled-skill' })).rejects.toThrow('skill is not enabled')
      await expect(
        tool.execute('call-traversal', { name: 'enabled-skill', filePath: '../outside-secret.txt' })
      ).rejects.toThrow('invalid skill file path')
      await expect(tool.execute('call-symlink', { name: 'enabled-skill', filePath: 'escaped.txt' })).rejects.toThrow(
        'symbolic link'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_append sends one atomic append request to the control plane', async () => {
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
      enabledSkills: [{ skill_name: 'nano-pdf', source_kind: 'builtin', relative_path: 'nano-pdf' }],
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.skillsOverlayAppend)
        const request = payload as { skill_name: string; content: string }
        writes.push(request)
        return {
          request_id: 'req-1',
          agent_uid: turn.actor.agent_uid,
          session_id: turn.actor.session_id,
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: { text: 'Prefer page-by-page verification.\n\nUse render output as final evidence.' },
          content_hash: 'hash-2'
        }
      }) as RPCRequester
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
      content: 'Use render output as final evidence.'
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
      enabledSkills: [{ skill_name: 'nano-pdf', source_kind: 'builtin', relative_path: 'nano-pdf' }],
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.skillsOverlayAppend)
        const request = payload as { skill_name: string; content: string }
        writes.push(request)
        return {
          request_id: 'req-1',
          agent_uid: turn.actor.agent_uid,
          session_id: turn.actor.session_id,
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: { text: request.content },
          content_hash: 'hash-1'
        }
      }) as RPCRequester
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
      content: 'Create the first overlay note.'
    })
  })

  it('skill_replace resolves the latest hash and sends a compare-and-swap replacement', async () => {
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000004',
      revision: 0
    }
    const writes: unknown[] = []
    const tools = createSkillTools('/workspace', {
      turn,
      enabledSkills: [{ skill_name: 'nano-pdf', source_kind: 'builtin', relative_path: 'nano-pdf' }],
      rpc: (async (method: unknown, payload: unknown) => {
        if (method === rpcMethods.skillsOverlayResolve) {
          const request = payload as { skill_name: string }
          return {
            request_id: 'req-1',
            agent_uid: turn.actor.agent_uid,
            session_id: turn.actor.session_id,
            skill_name: request.skill_name,
            has_overlay: true,
            overlay_json: { text: 'Old duplicated notes.' },
            content_hash: 'current-hash'
          }
        }
        expect(method).toBe(rpcMethods.skillsOverlayReplace)
        const request = payload as { skill_name: string; overlay_json?: Record<string, unknown> }
        writes.push(request)
        return {
          request_id: 'req-1',
          agent_uid: turn.actor.agent_uid,
          session_id: turn.actor.session_id,
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: request.overlay_json ?? {},
          content_hash: 'replacement-hash'
        }
      }) as RPCRequester
    })

    const tool = tools.find(candidate => candidate.name === 'skill_replace')!
    await tool.execute('call-replace', {
      name: 'nano-pdf',
      content: 'One concise current lesson.'
    })

    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatchObject({
      skill_name: 'nano-pdf',
      content: 'One concise current lesson.',
      overlay_json: { text: 'One concise current lesson.' },
      expected_content_hash: 'current-hash'
    })
  })
})

function writeFileSyncWithParents(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

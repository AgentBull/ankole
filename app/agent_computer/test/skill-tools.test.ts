import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { create } from '@bufbuild/protobuf'
import { createSkillTools } from '../src/tools/library/skill-tools'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  RuntimeSkillSummarySchema,
  SkillOverlayResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
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
    const request = payload as { skillName: string }
    return create(SkillOverlayResponseSchema, {
      skillName: request.skillName,
      hasOverlay: Boolean(text),
      overlayJson: jsonBytes(text ? { text } : {}),
      contentHash: 'overlay-hash'
    })
  }) as RPCRequester
}

describe('@ankole/agent-computer skill tools', () => {
  it('describes skill work by name without exposing file paths or update content', () => {
    const tools = createSkillTools('/agents/agent-1/sessions/session-1', { turn: testTurn, rpc: unusedRPC })
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

      const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
        turn: testTurn,
        rpc: overlayResolveRPC(),
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'nano-pdf',
            sourceKind: 'builtin',
            relativePath: 'nano-pdf',
            skillRoot: 'internal'
          })
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

      const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
        turn: testTurn,
        rpc: overlayResolveRPC(),
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'nano-pdf',
            sourceKind: 'builtin',
            relativePath: 'nano-pdf',
            skillRoot: 'library'
          })
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

  it('skill_view routes background-job skills without exposing their body or resources', async () => {
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

      const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
        turn: testTurn,
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'long-report',
            sourceKind: 'builtin',
            relativePath: 'long-report',
            metadataJson: jsonBytes({ 'ankole-runtime': 'background_job' })
          })
        ],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        },
        rpc: (async (method: unknown) => {
          if (method === rpcMethods.skillsOverlayResolve) {
            overlayReads += 1
            return create(SkillOverlayResponseSchema, {
              skillName: 'long-report',
              hasOverlay: true,
              overlayJson: jsonBytes({ text: 'private overlay' }),
              contentHash: 'overlay-hash'
            })
          }
          overlayWrites += 1
          throw new Error('unexpected background-job Skill overlay write')
        }) as RPCRequester
      })

      const tool = tools.find(candidate => candidate.name === 'skill_view')!
      const result = await tool.execute('call-long', { name: 'long-report' })
      const text = result.content[0]?.type === 'text' ? result.content[0].text : ''
      expect(text).toContain('create_background_job')
      expect(text).toContain('use the long-report Skill')
      expect(text).not.toContain('Private operation body')
      expect(text).not.toContain('private overlay')
      expect(text).not.toContain('skill://')
      expect(text).not.toContain('directory=')
      expect(overlayReads).toBe(0)

      await expect(
        tool.execute('call-long-reference', { name: 'long-report', filePath: 'references/private.md' })
      ).rejects.toThrow('available only inside a background agent job')

      const append = tools.find(candidate => candidate.name === 'skill_append')!
      const replace = tools.find(candidate => candidate.name === 'skill_replace')!
      await expect(
        append.execute('call-long-append', { name: 'long-report', content: 'blind append' })
      ).rejects.toThrow('available only inside a background agent job')
      await expect(
        replace.execute('call-long-replace', { name: 'long-report', content: 'blind replacement' })
      ).rejects.toThrow('available only inside a background agent job')
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

      const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
        turn,
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'enabled-skill',
            sourceKind: 'builtin',
            relativePath: 'enabled-skill'
          })
        ],
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

    const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
      turn,
      enabledSkills: [
        create(RuntimeSkillSummarySchema, { skillName: 'nano-pdf', sourceKind: 'builtin', relativePath: 'nano-pdf' })
      ],
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.skillsOverlayAppend)
        const request = payload as { skillName: string; content: string }
        writes.push(request)
        return create(SkillOverlayResponseSchema, {
          skillName: request.skillName,
          hasOverlay: true,
          overlayJson: jsonBytes({ text: 'Prefer page-by-page verification.\n\nUse render output as final evidence.' }),
          contentHash: 'hash-2'
        })
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
      skillName: 'nano-pdf',
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

    const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
      turn,
      enabledSkills: [
        create(RuntimeSkillSummarySchema, { skillName: 'nano-pdf', sourceKind: 'builtin', relativePath: 'nano-pdf' })
      ],
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.skillsOverlayAppend)
        const request = payload as { skillName: string; content: string }
        writes.push(request)
        return create(SkillOverlayResponseSchema, {
          skillName: request.skillName,
          hasOverlay: true,
          overlayJson: jsonBytes({ text: request.content }),
          contentHash: 'hash-1'
        })
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
      skillName: 'nano-pdf',
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
    const tools = createSkillTools('/agents/agent-1/sessions/session-1', {
      turn,
      enabledSkills: [
        create(RuntimeSkillSummarySchema, { skillName: 'nano-pdf', sourceKind: 'builtin', relativePath: 'nano-pdf' })
      ],
      rpc: (async (method: unknown, payload: unknown) => {
        if (method === rpcMethods.skillsOverlayResolve) {
          const request = payload as { skillName: string }
          return create(SkillOverlayResponseSchema, {
            skillName: request.skillName,
            hasOverlay: true,
            overlayJson: jsonBytes({ text: 'Old duplicated notes.' }),
            contentHash: 'current-hash'
          })
        }
        expect(method).toBe(rpcMethods.skillsOverlayReplace)
        const request = payload as { skillName: string; overlayJson?: Uint8Array }
        writes.push(request)
        return create(SkillOverlayResponseSchema, {
          skillName: request.skillName,
          hasOverlay: true,
          overlayJson: request.overlayJson ?? new Uint8Array(0),
          contentHash: 'replacement-hash'
        })
      }) as RPCRequester
    })

    const tool = tools.find(candidate => candidate.name === 'skill_replace')!
    await tool.execute('call-replace', {
      name: 'nano-pdf',
      content: 'One concise current lesson.'
    })

    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatchObject({
      skillName: 'nano-pdf',
      content: 'One concise current lesson.',
      expectedContentHash: 'current-hash'
    })
    const replaceWrite = writes[0] as { overlayJson: Uint8Array }
    expect(jsonObjectFromBytes(replaceWrite.overlayJson, 'overlay_json')).toEqual({
      text: 'One concise current lesson.'
    })
  })
})

function writeFileSyncWithParents(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

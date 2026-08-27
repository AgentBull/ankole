import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { create } from '@bufbuild/protobuf'
import { createSkillTools } from '../src/tools/library/skill-tools'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  RuntimeSkillSummarySchema,
  SkillOverlayResolveResponseSchema,
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
    const request = payload as { skillNames: string[] }
    return create(SkillOverlayResolveResponseSchema, {
      overlays: request.skillNames.map(skillName =>
        create(SkillOverlayResponseSchema, {
          skillName,
          hasOverlay: Boolean(text),
          overlayJson: jsonBytes(text ? { text } : {}),
          contentHash: 'overlay-hash'
        })
      )
    })
  }) as RPCRequester
}

describe('@ankole/agent-computer skill tools', () => {
  it('exposes only skill_view and describes skill work by name without exposing file paths', () => {
    const tools = createSkillTools({ turn: testTurn, rpc: unusedRPC })
    expect(tools.map(tool => tool.name)).toEqual(['skill_view'])

    const view = tools[0]!
    const viewActivity = view.describeActivity(
      view.schema.parse({ name: 'openai-docs', filePath: 'references/private/internal.md' })
    )
    expect(viewActivity).toEqual({
      key: 'signals_gateway.reply.activity.skill_load',
      bindings: { name: 'openai-docs' }
    })
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

      const tools = createSkillTools({
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

      const tools = createSkillTools({
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
    try {
      writeFileSyncWithParents(
        join(builtinRoot, 'long-report', 'SKILL.md'),
        ['---', 'name: long-report', 'description: Long report.', '---', '', '# Private operation body', ''].join('\n')
      )
      writeFileSyncWithParents(join(builtinRoot, 'long-report', 'references', 'private.md'), 'private reference')

      const tools = createSkillTools({
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
            return create(SkillOverlayResolveResponseSchema, {
              overlays: [
                create(SkillOverlayResponseSchema, {
                  skillName: 'long-report',
                  hasOverlay: true,
                  overlayJson: jsonBytes({ text: 'private overlay' }),
                  contentHash: 'overlay-hash'
                })
              ]
            })
          }
          throw new Error('unexpected background-job Skill RPC')
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
      expect(overlayReads).toBe(0)
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

      const tools = createSkillTools({
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
})

function writeFileSyncWithParents(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

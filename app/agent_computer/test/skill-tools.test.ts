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
import { createSkillLoader } from '../src/skills/skill-loader'

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
          text: text ?? '',
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
                  text: 'private overlay',
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
      expect(overlayReads).toBe(1)

      await expect(
        tool.execute('call-long-reference', { name: 'long-report', filePath: 'references/private.md' })
      ).rejects.toThrow('available only inside a background agent job')
      expect(overlayReads).toBe(1)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('Background Job skill_view fully loads a brain-recall-only Skill through the shared loader', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-background-${Date.now()}-${Math.random()}`)
    const builtinRoot = join(root, 'library')
    const loadedNames: string[] = []
    try {
      writeFileSyncWithParents(
        join(builtinRoot, 'voice-drafting-method', 'SKILL.md'),
        [
          '---',
          'name: voice-drafting-method',
          'description: Draft in a specific voice.',
          '---',
          '',
          '# Full voice drafting method',
          ''
        ].join('\n')
      )
      writeFileSyncWithParents(
        join(builtinRoot, 'voice-drafting-method', 'references', 'examples.md'),
        '# Voice examples'
      )
      const skill = create(RuntimeSkillSummarySchema, {
        skillName: 'voice-drafting-method',
        sourceKind: 'builtin',
        relativePath: 'voice-drafting-method',
        metadataJson: jsonBytes({ 'ankole-runtime': 'background_job', brain_recall_only: true })
      })
      const loader = createSkillLoader({
        turn: testTurn,
        enabledSkills: [skill],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        },
        rpc: overlayResolveRPC('Use the preferred cadence.'),
        runtime: 'background_job',
        onSkillLoaded: name => loadedNames.push(name)
      })
      const tool = createSkillTools({ turn: testTurn, rpc: unusedRPC, loader })[0]!

      const instructions = await tool.execute('call-background', { name: 'voice-drafting-method' })
      const reference = await tool.execute('call-background-reference', {
        name: 'voice-drafting-method',
        filePath: 'references/examples.md'
      })
      const instructionText = instructions.content[0]?.type === 'text' ? instructions.content[0].text : ''
      const referenceText = reference.content[0]?.type === 'text' ? reference.content[0].text : ''

      expect(instructionText).toContain('# Full voice drafting method')
      expect(instructionText).toContain('Use the preferred cadence.')
      expect(instructionText).not.toContain('create_background_job')
      expect(referenceText).toContain('# Voice examples')
      expect(loadedNames).toEqual(['voice-drafting-method', 'voice-drafting-method'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skill_view rechecks effective enablement before reading a referenced file mid-turn', async () => {
    const root = join(tmpdir(), `ankole-skill-tools-disable-${Date.now()}-${Math.random()}`)
    const builtinRoot = join(root, 'library')
    const referencePath = join(builtinRoot, 'voice-drafting-method', 'references', 'examples.md')
    let enabled = true

    try {
      writeFileSyncWithParents(
        join(builtinRoot, 'voice-drafting-method', 'SKILL.md'),
        ['---', 'name: voice-drafting-method', 'description: Draft in a specific voice.', '---', ''].join('\n')
      )
      writeFileSyncWithParents(referencePath, '# Voice examples')

      const tool = createSkillTools({
        turn: testTurn,
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'voice-drafting-method',
            sourceKind: 'builtin',
            relativePath: 'voice-drafting-method'
          })
        ],
        skillRoots: {
          builtinSkillsRoot: builtinRoot,
          agentInstalledSkillsRoot: join(root, 'installed')
        },
        rpc: (async () => {
          if (!enabled) throw new Error('skill_not_enabled')
          return create(SkillOverlayResolveResponseSchema, {
            overlays: [
              create(SkillOverlayResponseSchema, {
                skillName: 'voice-drafting-method',
                hasOverlay: false
              })
            ]
          })
        }) as RPCRequester
      })[0]!

      const first = await tool.execute('call-reference-enabled', {
        name: 'voice-drafting-method',
        filePath: 'references/examples.md'
      })
      expect(first.content[0]?.type === 'text' ? first.content[0].text : '').toContain('# Voice examples')

      enabled = false
      rmSync(referencePath)

      await expect(
        tool.execute('call-reference-disabled', {
          name: 'voice-drafting-method',
          filePath: 'references/examples.md'
        })
      ).rejects.toThrow('skill_not_enabled')
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

import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  RuntimeSkillSummarySchema,
  SkillOverlayResolveResponseSchema,
  SkillOverlayResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  materializeCodexJobRuntimeFiles,
  readCodexJobGuidance,
  renderCodexJobAgents
} from '../src/core/codex-runner/runtime-files'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'

describe('@ankole/agent-computer Codex Job runtime files', () => {
  it('renders the real Job workspace in AGENTS.md', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION'
    }).content
    expect(content).toContain('/agents/agent-1/jobs/job-1')
    expect(content).toContain('real paths inside this Worker')
    expect(content).toContain('request_parent_input')
  })

  it('renders the shared Job guidance template after the execution context', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      jobGuidance: 'Guidance body.'
    }).content
    expect(content).toContain('## Job Guidance\n\nGuidance body.')
    expect(content.indexOf('## Execution Context')).toBeLessThan(content.indexOf('## Job Guidance'))

    const without = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION'
    }).content
    expect(without).not.toContain('## Job Guidance')
  })

  it('reads the bundled AGENT_JOB.md template through the builtin library root', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-job-guidance-'))
    try {
      expect(readCodexJobGuidance(root)).toBeUndefined()
      mkdirSync(join(root, 'templates'), { recursive: true })
      writeFileSync(join(root, 'templates', 'AGENT_JOB.md'), '\n')
      expect(readCodexJobGuidance(root)).toBeUndefined()
      writeFileSync(join(root, 'templates', 'AGENT_JOB.md'), 'Wait guidance.\n')
      expect(readCodexJobGuidance(root)).toBe('Wait guidance.')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('projects selected Skills through one stable Agent material path and refreshes overlays in place', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-job-skills-'))
    const jobRoot = join(root, 'agents', 'agent-1', 'jobs', 'job-1')
    const builtin = join(root, 'builtin')
    const source = join(builtin, 'plain-skill')
    const secondSource = join(builtin, 'second-skill')
    mkdirSync(source, { recursive: true })
    mkdirSync(secondSource, { recursive: true })
    mkdirSync(jobRoot, { recursive: true })
    writeFileSync(join(source, 'SKILL.md'), '---\nname: plain-skill\ndescription: Plain.\n---\n\n# Base\n')
    writeFileSync(join(source, 'reference.md'), 'reference-v1\n')
    writeFileSync(join(secondSource, 'SKILL.md'), '# Second\n')
    let overlay = 'Overlay v1.'
    const overlayRequests: string[][] = []
    const agentSkillsRoot = join(root, 'agents', 'agent-1', 'runtime-materials', 'skills')

    const runtime = await materializeCodexJobRuntimeFiles({
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'job:job-1' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      jobRoot,
      agentSkillsRoot,
      enabledSkills: [
        create(RuntimeSkillSummarySchema, {
          skillName: 'plain-skill',
          sourceKind: 'builtin',
          relativePath: 'plain-skill'
        }),
        create(RuntimeSkillSummarySchema, {
          skillName: 'second-skill',
          sourceKind: 'builtin',
          relativePath: 'second-skill'
        })
      ],
      skillRoots: { builtinSkillsRoot: builtin, agentInstalledSkillsRoot: join(root, 'installed') },
      rpc: (async (method, payload) => {
        expect(String(method)).toBe(rpcMethods.skillsOverlayResolve)
        const names = (payload as { skillNames: string[] }).skillNames
        overlayRequests.push(names)
        return create(SkillOverlayResolveResponseSchema, {
          overlays: names.map(name =>
            create(SkillOverlayResponseSchema, {
              skillName: name,
              ...(name === 'plain-skill' && overlay
                ? { hasOverlay: true, overlayJson: jsonBytes({ text: overlay }) }
                : {})
            })
          )
        })
      }) as RPCRequester
    })

    try {
      expect(runtime.skillsRoot).toBe(join(jobRoot, '.agents', 'skills'))
      expect(runtime.skills[0]?.sourcePath).toBe(join(runtime.skillsRoot, 'plain-skill'))
      expect(lstatSync(join(runtime.skillsRoot, 'plain-skill')).isSymbolicLink()).toBe(true)
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'SKILL.md'), 'utf8')).toContain('Overlay v1.')
      expect(overlayRequests).toEqual([['plain-skill', 'second-skill']])
      expect(lstatSync(join(agentSkillsRoot, 'plain-skill', 'reference.md')).isSymbolicLink()).toBe(true)

      overlay = 'Overlay v2.'
      expect(await runtime.refreshSkill('plain-skill')).toBe(true)
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'SKILL.md'), 'utf8')).toContain('Overlay v2.')
      writeFileSync(join(source, 'reference.md'), 'reference-v2\n')
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'reference.md'), 'utf8')).toBe('reference-v2\n')

      overlay = ''
      expect(await runtime.refreshSkill('plain-skill')).toBe(true)
      expect(lstatSync(join(agentSkillsRoot, 'plain-skill', 'SKILL.md')).isSymbolicLink()).toBe(false)
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'SKILL.md'), 'utf8')).toContain('# Base')
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'SKILL.md'), 'utf8')).not.toContain('Overlay v2.')
      expect(await runtime.refreshSkill('missing')).toBe(false)
      expect(overlayRequests).toEqual([['plain-skill', 'second-skill'], ['plain-skill'], ['plain-skill']])
      runtime.cleanup()
      expect(existsSync(runtime.skillsRoot)).toBeTrue()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  RuntimeSkillSummarySchema,
  SkillOverlayResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { materializeCodexJobRuntimeFiles, renderCodexJobAgents } from '../src/core/codex-runner/runtime-files'
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

  it('projects selected Skills into the real Job .ankole directory', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-job-skills-'))
    const jobRoot = join(root, 'agents', 'agent-1', 'jobs', 'job-1')
    const builtin = join(root, 'builtin')
    const source = join(builtin, 'plain-skill')
    mkdirSync(source, { recursive: true })
    mkdirSync(jobRoot, { recursive: true })
    writeFileSync(join(source, 'SKILL.md'), '---\nname: plain-skill\ndescription: Plain.\n---\n\n# Base\n')

    const runtime = await materializeCodexJobRuntimeFiles({
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'job:job-1' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      jobRoot,
      enabledSkills: [
        create(RuntimeSkillSummarySchema, {
          skillName: 'plain-skill',
          sourceKind: 'builtin',
          relativePath: 'plain-skill'
        })
      ],
      skillRoots: { builtinSkillsRoot: builtin, agentInstalledSkillsRoot: join(root, 'installed') },
      rpc: (async method => {
        expect(String(method)).toBe(rpcMethods.skillsOverlayResolve)
        return create(SkillOverlayResponseSchema, {
          skillName: 'plain-skill',
          hasOverlay: true,
          overlayJson: jsonBytes({ text: 'Overlay.' })
        })
      }) as RPCRequester
    })

    try {
      expect(runtime.skillsRoot).toBe(join(jobRoot, '.ankole', 'skills'))
      expect(runtime.skills[0]?.sourcePath).toBe(join(runtime.skillsRoot, 'plain-skill'))
      expect(readFileSync(join(runtime.skillsRoot, 'plain-skill', 'SKILL.md'), 'utf8')).toContain('Overlay.')
      runtime.cleanup()
      expect(existsSync(runtime.skillsRoot)).toBeTrue()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

import { describe, expect, it } from 'bun:test'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeSubagentRuntimeFiles } from '../src/tools/subagent/runtime-files'
import type { ActorTurnRef } from '../src/lanes/actor_lane'

describe('@ankole/agent-computer subagent runtime files', () => {
  it('materializes task AGENTS context and native enabled skills without copying skill directories', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-files-'))
    const workspaceRoot = join(root, 'workspace')
    const workdir = join(workspaceRoot, 'project')
    const builtinSkillsRoot = join(root, 'skills')
    const plainSkillRoot = join(builtinSkillsRoot, 'plain-skill')
    const overlaySkillRoot = join(builtinSkillsRoot, 'overlay-skill')
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'subagent:delegation-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    }

    mkdirSync(workdir, { recursive: true })
    mkdirSync(plainSkillRoot, { recursive: true })
    mkdirSync(join(overlaySkillRoot, 'references'), { recursive: true })
    writeFileSync(join(workdir, 'AGENTS.md'), '# Existing project guidance\n\nPreserve this rule.\n')
    writeFileSync(
      join(plainSkillRoot, 'SKILL.md'),
      ['---', 'name: plain-skill', 'description: Plain skill.', '---', '', '# Plain instructions', ''].join('\n')
    )
    writeFileSync(
      join(overlaySkillRoot, 'SKILL.md'),
      ['---', 'name: overlay-skill', 'description: Overlay skill.', '---', '', '# Base instructions', ''].join('\n')
    )
    writeFileSync(join(overlaySkillRoot, 'references', 'guide.md'), '# Guide\n')

    const runtime = await materializeSubagentRuntimeFiles({
      workspaceRoot,
      workdir,
      workdirForModel: '/workspace/project',
      durableArtifactsRootForModel: '/workspace/user-files',
      soul: 'SOUL: Evidence first.',
      mission: 'MISSION: Deliver reliable work.',
      brainSnapshot: {
        pinned_memo: {
          entry_id: '00000000-0000-7000-8000-000000000021',
          name: 'Agent memo',
          markdown: 'Always verify the final artifact.',
          truncated: false,
          store: 'public'
        }
      },
      background: 'The audience is the operations team.',
      notes: 'Keep the handoff concise. TASK_SENTINEL_MUST_NOT_APPEAR is not a task instruction.',
      timezone: 'Asia/Singapore',
      now: new Date('2026-07-11T03:00:00.000Z'),
      turn,
      enabledSkills: [
        { skill_name: 'plain-skill', source_kind: 'builtin', relative_path: 'plain-skill' },
        {
          skill_name: 'overlay-skill',
          source_kind: 'builtin',
          relative_path: 'overlay-skill',
          has_agent_overlay: true,
          metadata: { long_running: true }
        }
      ],
      skillRoots: {
        builtinSkillsRoot,
        agentInstalledSkillsRoot: join(root, 'installed')
      },
      requestSkillOverlay: async request => ({
        request_id: request.request_id,
        agent_uid: 'agent-1',
        session_id: 'subagent:delegation-1',
        skill_name: request.skill_name,
        has_overlay: true,
        overlay_json: { text: 'Agent-specific verification rule.' },
        content_hash: 'overlay-hash'
      })
    })

    try {
      const agents = readFileSync(runtime.agentsPath, 'utf8')
      expect(runtime.localAgentsFilename).toBe('AGENTS.md')
      expect(runtime.localAgentsSandboxPath).toBe('/workspace/project/AGENTS.md')
      expect(agents).toContain('# Existing project guidance')
      expect(agents).toContain('## SOUL\n\nSOUL: Evidence first.')
      expect(agents).toContain('## MISSION\n\nMISSION: Deliver reliable work.')
      expect(agents).toContain('## Frozen Brain Snapshot')
      expect(agents).toContain('Always verify the final artifact.')
      expect(agents).toContain('Projected Brain tools may read and write durable memory')
      expect(agents).toContain('## Background\n\nThe audience is the operations team.')
      expect(agents).toContain('## Notes\n\nKeep the handoff concise.')
      expect(agents).toContain('Asia/Singapore')
      expect(agents).toContain('/workspace/project')
      expect(agents).not.toContain('Complete task to send to Codex')

      expect(runtime.expectedSkillNames).toEqual(['overlay-skill', 'plain-skill'])
      expect(runtime.skills.map(skill => ({ name: skill.name, sourcePath: skill.sourcePath }))).toEqual([
        { name: 'overlay-skill', sourcePath: realpathSync(overlaySkillRoot) },
        { name: 'plain-skill', sourcePath: realpathSync(plainSkillRoot) }
      ])
      const overlay = runtime.skills.find(skill => skill.name === 'overlay-skill')
      expect(overlay?.skillFileOverridePath).toBeString()
      const effectiveSkill = readFileSync(overlay!.skillFileOverridePath!, 'utf8')
      expect(effectiveSkill).toStartWith('---\nname: overlay-skill')
      expect(effectiveSkill).toContain('# Base instructions')
      expect(effectiveSkill).toContain('Agent-specific additions:')
      expect(effectiveSkill).toContain('Agent-specific verification rule.')
      expect(effectiveSkill).not.toContain('Ankole long-running skill discipline')
    } finally {
      const runtimeRoot = runtime.root
      runtime.cleanup()
      expect(existsSync(runtimeRoot)).toBe(false)
      expect(existsSync(join(workspaceRoot, '.ankole'))).toBe(false)
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('prefers same-level override guidance and isolates concurrent delegation documents', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-isolation-'))
    const workspaceRoot = join(root, 'workspace')
    const workdir = join(workspaceRoot, 'project')
    mkdirSync(workdir, { recursive: true })
    writeFileSync(join(workdir, 'AGENTS.md'), 'AGENTS_MD_MUST_BE_SHADOWED\n')
    writeFileSync(join(workdir, 'AGENTS.override.md'), 'EXISTING_OVERRIDE_GUIDANCE\n')

    const base = {
      workspaceRoot,
      workdir,
      workdirForModel: '/workspace/project',
      durableArtifactsRootForModel: '/workspace/user-files',
      mission: 'Shared mission.',
      timezone: 'Asia/Singapore',
      now: new Date('2026-07-11T03:00:00.000Z'),
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'subagent:delegation' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      } satisfies ActorTurnRef,
      enabledSkills: []
    }

    const [first, second] = await Promise.all([
      materializeSubagentRuntimeFiles({
        ...base,
        soul: 'FIRST_DELEGATION_SOUL',
        background: 'FIRST_DELEGATION_BACKGROUND'
      }),
      materializeSubagentRuntimeFiles({
        ...base,
        soul: 'SECOND_DELEGATION_SOUL',
        background: 'SECOND_DELEGATION_BACKGROUND'
      })
    ])

    try {
      expect(first.root).not.toBe(second.root)
      expect(first.localAgentsFilename).toBe('AGENTS.override.md')
      expect(second.localAgentsFilename).toBe('AGENTS.override.md')
      expect(first.localAgentsSandboxPath).toBe('/workspace/project/AGENTS.override.md')
      const firstAgents = readFileSync(first.agentsPath, 'utf8')
      const secondAgents = readFileSync(second.agentsPath, 'utf8')
      expect(firstAgents).toContain('EXISTING_OVERRIDE_GUIDANCE')
      expect(firstAgents).not.toContain('AGENTS_MD_MUST_BE_SHADOWED')
      expect(firstAgents).toContain('FIRST_DELEGATION_SOUL')
      expect(firstAgents).not.toContain('SECOND_DELEGATION_SOUL')
      expect(secondAgents).toContain('SECOND_DELEGATION_SOUL')
      expect(secondAgents).not.toContain('FIRST_DELEGATION_SOUL')
    } finally {
      first.cleanup()
      second.cleanup()
      expect(existsSync(join(workspaceRoot, '.ankole'))).toBe(false)
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('overlays an empty same-level override instead of letting it suppress task AGENTS', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-empty-agents-'))
    const workspaceRoot = join(root, 'workspace')
    const workdir = join(workspaceRoot, 'project')
    mkdirSync(workdir, { recursive: true })
    writeFileSync(join(workdir, 'AGENTS.override.md'), '')
    writeFileSync(join(workdir, 'AGENTS.md'), 'MUST_REMAIN_SHADOWED\n')

    const runtime = await materializeSubagentRuntimeFiles({
      workspaceRoot,
      workdir,
      workdirForModel: '/workspace/project',
      durableArtifactsRootForModel: '/workspace/user-files',
      soul: 'EMPTY_OVERRIDE_TASK_SOUL',
      mission: 'Complete the delegated task.',
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'subagent:delegation' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      enabledSkills: []
    })

    try {
      expect(runtime.localAgentsFilename).toBe('AGENTS.override.md')
      expect(runtime.localAgentsSandboxPath).toBe('/workspace/project/AGENTS.override.md')
      const agents = readFileSync(runtime.agentsPath, 'utf8')
      expect(agents).toContain('EMPTY_OVERRIDE_TASK_SOUL')
      expect(agents).not.toContain('MUST_REMAIN_SHADOWED')
    } finally {
      runtime.cleanup()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('resolves a same-level AGENTS symlink to its sandbox-visible target', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-agents-symlink-'))
    const workspaceRoot = join(root, 'workspace')
    const workdir = join(workspaceRoot, 'project')
    const rulesDir = join(workspaceRoot, 'rules')
    mkdirSync(workdir, { recursive: true })
    mkdirSync(rulesDir, { recursive: true })
    writeFileSync(join(rulesDir, 'delegated.md'), 'SYMLINKED_LOCAL_GUIDANCE\n')
    symlinkSync('../rules/delegated.md', join(workdir, 'AGENTS.md'))

    const runtime = await materializeSubagentRuntimeFiles({
      workspaceRoot,
      workdir,
      workdirForModel: '/workspace/project',
      durableArtifactsRootForModel: '/workspace/user-files',
      soul: 'SOUL',
      mission: 'MISSION',
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'subagent:delegation' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      enabledSkills: []
    })

    try {
      expect(runtime.localAgentsFilename).toBe('AGENTS.md')
      expect(runtime.localAgentsSandboxPath).toBe('/workspace/rules/delegated.md')
      expect(readFileSync(runtime.agentsPath, 'utf8')).toContain('SYMLINKED_LOCAL_GUIDANCE')
    } finally {
      runtime.cleanup()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails setup instead of silently dropping invalid enabled Skill metadata', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-subagent-runtime-invalid-skill-'))
    const workspaceRoot = join(root, 'workspace')
    const workdir = join(workspaceRoot, 'project')
    mkdirSync(workdir, { recursive: true })

    try {
      await expect(
        materializeSubagentRuntimeFiles({
          workspaceRoot,
          workdir,
          workdirForModel: '/workspace/project',
          durableArtifactsRootForModel: '/workspace/user-files',
          soul: 'SOUL',
          mission: 'MISSION',
          turn: {
            actor: { agent_uid: 'agent-1', session_id: 'subagent:delegation' },
            activation_uid: 'activation-1',
            actor_epoch: 1,
            actor_event_id: '00000000-0000-0000-0000-000000000001',
            revision: 0
          },
          enabledSkills: [{ skill_name: '../invalid', source_kind: 'builtin', relative_path: '../invalid' }]
        })
      ).rejects.toThrow('enabled skill has invalid name: ../invalid')
      expect(existsSync(join(workspaceRoot, '.ankole'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeCodexJobRuntimeFiles, renderCodexJobAgents } from '../src/core/codex-runner/runtime-files'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import type { CodexJobWorkspaceMount } from '../src/core/codex-runner/job-project'

const unusedRPC = (async () => {
  throw new Error('RPC is not used by this fixture')
}) as RPCRequester

describe('@ankole/agent-computer Codex job runtime files', () => {
  it('renders generic multi-mount execution context for project AGENTS.md', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-background-agent-job-runtime-'))
    const ownerRoot = join(root, 'owner')
    const source = join(ownerRoot, 'source')
    const output = join(ownerRoot, 'output')
    mkdirSync(source, { recursive: true })
    mkdirSync(output, { recursive: true })
    writeFileSync(join(source, 'AGENTS.md'), '# Source guidance\n')
    const mounts = [workspaceMount('source', source, 'read_only'), workspaceMount('workspace', output, 'read_write')]

    const rendered = renderCodexJobAgents({
      guidanceWorkspaceRoot: ownerRoot,
      workspaceMounts: mounts,
      soul: 'SOUL',
      mission: 'Complete the task.'
    })

    try {
      const agents = rendered.content
      expect(agents).toContain('## Mounted workspace guidance: source')
      expect(agents).toContain('/workspace/workspaces/source (read_only)')
      expect(agents).toContain('/workspace/workspaces/workspace (read_write)')
      expect(agents).not.toContain('Deep Research')
      expect(agents).not.toContain('Artifact contract')
      expect(agents).not.toContain('Plugin Options')
      expect(agents).toContain('the lead agent must call request_parent_input')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('materializes selected standalone Skills with overlays without copying directories', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-background-agent-job-skills-'))
    const ownerRoot = join(root, 'owner')
    const workspace = join(ownerRoot, 'workspace')
    const builtinSkillsRoot = join(root, 'skills')
    const skillRoot = join(builtinSkillsRoot, 'plain-skill')
    mkdirSync(workspace, { recursive: true })
    mkdirSync(skillRoot, { recursive: true })
    writeFileSync(join(skillRoot, 'SKILL.md'), '---\nname: plain-skill\ndescription: Plain.\n---\n\n# Base\n')

    const runtime = await materializeCodexJobRuntimeFiles({
      turn: turn(),
      enabledSkills: [{ skill_name: 'plain-skill', source_kind: 'builtin', relative_path: 'plain-skill' }],
      skillRoots: { builtinSkillsRoot, agentInstalledSkillsRoot: join(root, 'installed') },
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.skillsOverlayResolve)
        const request = payload as { skill_name: string }
        return {
          request_id: 'req-1',
          agent_uid: 'agent-1',
          session_id: 'job:job-1',
          skill_name: request.skill_name,
          has_overlay: true,
          overlay_json: { text: 'Agent overlay.' },
          content_hash: 'overlay-hash'
        }
      }) as RPCRequester
    })

    try {
      expect(runtime.expectedSkillNames).toEqual(['plain-skill'])
      expect(runtime.skills[0]?.sourcePath).toBe(realpathSync(skillRoot))
      expect(readFileSync(runtime.skills[0]!.skillFileOverridePath!, 'utf8')).toContain('Agent overlay.')
    } finally {
      const runtimeRoot = runtime.root
      runtime.cleanup()
      expect(existsSync(runtimeRoot)).toBe(false)
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('renders independent guidance values and rejects invalid Skill metadata', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-background-agent-job-runtime-isolation-'))
    const ownerRoot = join(root, 'owner')
    const workspace = join(ownerRoot, 'workspace')
    mkdirSync(workspace, { recursive: true })
    const base = {
      guidanceWorkspaceRoot: ownerRoot,
      workspaceMounts: [workspaceMount('workspace', workspace, 'read_write')],
      mission: 'Shared mission.'
    }

    const first = renderCodexJobAgents({ ...base, soul: 'FIRST_JOB_SOUL' })
    const second = renderCodexJobAgents({ ...base, soul: 'SECOND_JOB_SOUL' })
    expect(first.content).toContain('FIRST_JOB_SOUL')
    expect(first.content).not.toContain('SECOND_JOB_SOUL')
    expect(second.content).toContain('SECOND_JOB_SOUL')

    await expect(
      materializeCodexJobRuntimeFiles({
        turn: turn(),
        enabledSkills: [{ skill_name: '../invalid', source_kind: 'builtin', relative_path: '../invalid' }],
        rpc: unusedRPC
      })
    ).rejects.toThrow('enabled skill has invalid name: ../invalid')
    rmSync(root, { recursive: true, force: true })
  })
})

function workspaceMount(id: string, sourcePath: string, access: 'read_only' | 'read_write'): CodexJobWorkspaceMount {
  return {
    id,
    sourcePath,
    projectPath: join(sourcePath, '.mountpoint'),
    modelPath: `/workspace/workspaces/${id}`,
    ownerModelPath: `/workspace/${id}`,
    access
  }
}

function turn(): ActorTurnRef {
  return {
    actor: { agent_uid: 'agent-1', session_id: 'job:job-1' },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    actor_event_id: '00000000-0000-0000-0000-000000000001',
    revision: 0
  }
}

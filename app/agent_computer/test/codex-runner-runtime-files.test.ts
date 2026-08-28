import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  migrateLegacyCodexJobSkillRoots,
  readCodexJobGuidance,
  renderCodexJobAgents
} from '../src/core/codex-runner/job/runtime-files'

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

  it('renders the Job start time in the installation timezone it labels', () => {
    const now = new Date('2026-08-05T21:27:51.933Z')
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      timezone: 'Asia/Shanghai',
      now
    }).content
    expect(content).toContain('Job start time: 2026-08-06 05:27 (Asia/Shanghai).')
    expect(content).toContain('Report times in Asia/Shanghai')
    expect(content).not.toContain(now.toISOString())

    const withoutTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      now
    }).content
    expect(withoutTimezone).toContain('Job start time: 2026-08-05 21:27 (UTC).')

    // A timezone Intl cannot use must degrade the clock and its label together.
    const unusableTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      timezone: 'Mars/Olympus_Mons',
      now
    }).content
    expect(unusableTimezone).toContain('Job start time: 2026-08-05 21:27 (UTC).')
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

  it('renders the Ankole Skill catalog and lazy Skill routing rule in trusted Job guidance', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      skillsPrompt: '## Skills\n\n<available_skills>\n  general:\n    - ordinary\n</available_skills>',
      lazySkillRouting: true
    }).content

    expect(content).toContain('## Skills')
    expect(content).toContain('- ordinary')
    expect(content).toContain('A `lazyload-agent-skills/` record is a Skill discovery record')
  })

  it('migrates legacy Skill roots once without replacing existing AGENTS guidance', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-job-skill-migration-'))
    const original = '# Existing Job guidance\n\nKeep this operator constraint.\n'
    const skillsPrompt = '## Skills\n\n<available_skills>\n  general:\n    - ordinary\n</available_skills>'
    const agentsPath = join(root, 'AGENTS.md')

    try {
      writeFileSync(agentsPath, original)
      mkdirSync(join(root, '.agents', 'skills', 'legacy'), { recursive: true })
      mkdirSync(join(root, '.ankole', 'agent-plugins', 'legacy'), { recursive: true })

      expect(migrateLegacyCodexJobSkillRoots({ jobRoot: root, runtimeThreadID: 'thread-old', skillsPrompt })).toBe(true)
      const migrated = readFileSync(agentsPath, 'utf8')
      expect(migrated.startsWith(original)).toBe(true)
      expect(migrated).toContain(skillsPrompt)
      expect(migrated.match(/ankole-background-job-skill-view-v1=/g)).toHaveLength(1)
      expect(existsSync(join(root, '.agents', 'skills'))).toBe(false)
      expect(existsSync(join(root, '.ankole', 'agent-plugins'))).toBe(false)
      expect(migrateLegacyCodexJobSkillRoots({ jobRoot: root, runtimeThreadID: 'thread-old', skillsPrompt })).toBe(true)
      expect(readFileSync(agentsPath, 'utf8')).toBe(migrated)

      mkdirSync(join(root, '.agents', 'skills'), { recursive: true })
      expect(
        migrateLegacyCodexJobSkillRoots({
          jobRoot: root,
          runtimeThreadID: 'thread-new',
          skillsPrompt: '## Skills\n\nThis must not replace the one-time index.'
        })
      ).toBe(false)
      expect(readFileSync(agentsPath, 'utf8')).toBe(migrated)
      expect(existsSync(join(root, '.agents', 'skills'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

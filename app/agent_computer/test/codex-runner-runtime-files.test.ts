import { describe, expect, it } from 'bun:test'
import { renderCodexJobAgents } from '../src/core/codex-runner/job/runtime-files'

describe('@ankole/agent-computer Codex Job runtime files', () => {
  it('renders the real Job workspace in AGENTS.md', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION'
    }).content
    expect(content).toContain('/agents/agent-1/jobs/job-1')
    expect(content).toContain('private Drive with ankole-files put')
    expect(content).toContain('The Job workspace is a temporary working directory.')
    expect(content).toContain('ankole-pod chat attachment get')
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
    expect(content).toContain('2026-08-06 05:27 (Asia/Shanghai)')
    expect(content).not.toContain(now.toISOString())

    const withoutTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      now
    }).content
    expect(withoutTimezone).toContain('2026-08-05 21:27 (UTC)')

    // A timezone Intl cannot use must degrade the clock and its label together.
    const unusableTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      timezone: 'Mars/Olympus_Mons',
      now
    }).content
    expect(unusableTimezone).toContain('2026-08-05 21:27 (UTC)')
  })

  it('keeps control-plane Page and delivery instructions in the real Job context', () => {
    const instructions = 'Current Page ID: page-123. Save the research report as an editable Pod Page.'
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      podInstructions: instructions
    }).content
    expect(content).toContain(instructions)
  })

  it('renders the Ankole Skill catalog in trusted Job guidance', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      soul: 'SOUL',
      mission: 'MISSION',
      skillsPrompt: '## Skills\n\n<available_skills>\n  general:\n    - ordinary\n</available_skills>',
      lazySkillRouting: true
    }).content

    expect(content).toContain('## Skills')
    expect(content).toContain('- ordinary')
  })
})

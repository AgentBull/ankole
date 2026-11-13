import { describe, expect, it } from 'bun:test'
import { renderCodexJobAgents } from '../src/core/codex-runner/job/runtime-files'

describe('@ankole/agent-computer Codex Job runtime files', () => {
  it('renders the real Job workspace in turn instructions', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1'
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
      timezone: 'Asia/Shanghai',
      now
    }).content
    expect(content).toContain('2026-08-06 05:27 (Asia/Shanghai)')
    expect(content).not.toContain(now.toISOString())

    const withoutTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      now
    }).content
    expect(withoutTimezone).toContain('2026-08-05 21:27 (UTC)')

    // A timezone Intl cannot use must degrade the clock and its label together.
    const unusableTimezone = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      timezone: 'Mars/Olympus_Mons',
      now
    }).content
    expect(unusableTimezone).toContain('2026-08-05 21:27 (UTC)')
  })

  it('keeps control-plane Page and delivery instructions in the real Job context', () => {
    const instructions = 'Current Page ID: page-123. Save the research report as an editable Pod Page.'
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      podInstructions: instructions
    }).content
    expect(content).toContain(instructions)
  })

  it('renders the Ankole Skill catalog in trusted Job guidance', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1',
      skillsPrompt: '## Skills\n\n<available_skills>\n  general:\n    - ordinary\n</available_skills>'
    }).content

    expect(content).toContain('## Skills')
    expect(content).toContain('- ordinary')
  })

  it('requires progressive draft checkpointing and verbatim original-task acceptance verification', () => {
    const content = renderCodexJobAgents({
      jobRoot: '/agents/agent-1/jobs/job-1'
    }).content

    expect(content).toContain('materialize an initial working draft')
    expect(content).toContain('reconcile every acceptance criterion against the original task verbatim')
    expect(content).toContain('Outcome: incomplete')
    expect(content).toContain('request about 4000 max_output_tokens')
    expect(content).toContain('no `node` or `npm`')
    expect(content).toContain(`ankole-pod pages.read '{"id":"<id>"}'`)
  })
})

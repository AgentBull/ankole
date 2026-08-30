import { describe, expect, it } from 'bun:test'
import { CodexSkillUsageTracker, skillDisabledNotice } from '../src/core/codex-runner/job/skill-usage'

describe('@ankole/agent-computer Codex Skill usage', () => {
  it('separates availability from use and sends one disable notice only after evidence', () => {
    const tracker = new CodexSkillUsageTracker({
      availableSkillNames: ['docx', 'pdf'],
      mcpServers: []
    })

    tracker.disable(['pdf'])
    expect(tracker.pendingDisabledNotices()).toEqual([])

    expect(tracker.recordLoaded('pdf')).toEqual(['pdf'])
    expect(tracker.pendingDisabledNotices()).toEqual(['pdf'])
    expect(skillDisabledNotice('pdf')).toBe(
      'Skill `pdf` has been disabled for this Agent. Do not use it again in this Job. Continue with the remaining capabilities. If no valid alternative exists, explain the blocker.'
    )

    tracker.markNotified('pdf')
    expect(tracker.pendingDisabledNotices()).toEqual([])
    expect(tracker.recordLoaded('pdf')).toEqual([])
  })

  it('attributes uniquely owned MCP servers without guessing shared ownership', () => {
    const tracker = new CodexSkillUsageTracker({
      availableSkillNames: ['docx', 'pdf'],
      mcpServers: [
        {
          name: 'pdf-reader',
          transport: 'stdio',
          command: 'pdf-reader',
          sourceSkills: ['pdf']
        },
        {
          name: 'shared',
          transport: 'stdio',
          command: 'shared',
          sourceSkills: ['docx', 'pdf']
        }
      ]
    })
    expect(tracker.observeItem({ type: 'mcpToolCall', server: 'pdf-reader', tool: 'open' })).toEqual(['pdf'])
    expect(tracker.observeItem({ type: 'mcpToolCall', server: 'shared', tool: 'open' })).toEqual([])
  })

  it('marks the browser Skill used when a command invokes the runtime-injected CLI', () => {
    const tracker = new CodexSkillUsageTracker({
      availableSkillNames: ['browser', 'pdf'],
      mcpServers: []
    })

    expect(
      tracker.observeItem({
        type: 'commandExecution',
        cwd: '/jobs/1000',
        command: "ankole-browser open 'https://example.com' && ankole-browser snapshot -i"
      })
    ).toEqual(['browser'])

    const bounded = new CodexSkillUsageTracker({ availableSkillNames: ['browser'], mcpServers: [] })
    expect(
      bounded.observeItem({
        type: 'commandExecution',
        cwd: '/jobs/1000',
        command: 'cat ankole-browser-notes.md'
      })
    ).toEqual([])
    expect(
      bounded.observeItem({
        type: 'commandExecution',
        cwd: '/jobs/1000',
        command: '/usr/local/bin/ankole-browser open https://example.com'
      })
    ).toEqual(['browser'])

    const withoutBrowser = new CodexSkillUsageTracker({ availableSkillNames: ['pdf'], mcpServers: [] })
    expect(
      withoutBrowser.observeItem({
        type: 'commandExecution',
        cwd: '/jobs/1000',
        command: 'ankole-browser open https://example.com'
      })
    ).toEqual([])
  })

  it('rebuilds bounded prior-attempt usage without marking every available Skill as used', () => {
    const tracker = new CodexSkillUsageTracker({
      availableSkillNames: ['docx', 'pdf'],
      mcpServers: [],
      attemptHistory: [
        {
          $typeName: 'ankole.runtime_fabric.v1.BackgroundAgentJobAttemptHistoryEntry',
          attempt: 1,
          turnStatuses: ['failed'],
          summary: 'retry',
          usedSkillNames: ['pdf', 'removed-skill']
        }
      ]
    })

    expect([...tracker.usedSkillNames]).toEqual(['pdf'])
    tracker.disable(['docx', 'pdf'])
    expect(tracker.pendingDisabledNotices()).toEqual(['pdf'])
  })
})

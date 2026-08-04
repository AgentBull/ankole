import { describe, expect, it } from 'bun:test'
import {
  CodexSkillUsageTracker,
  explicitSkillReference,
  skillDisabledNotice
} from '../src/core/codex-runner/skill-usage'

describe('@ankole/agent-computer Codex Skill usage', () => {
  it('separates availability from use and sends one disable notice only after evidence', () => {
    const tracker = new CodexSkillUsageTracker({
      availableSkillNames: ['docx', 'pdf'],
      mcpServers: []
    })

    tracker.disable(['pdf'])
    expect(tracker.pendingDisabledNotices()).toEqual([])

    expect(tracker.observeInput('Use $pdf, then summarize the result.')).toEqual(['pdf'])
    expect(tracker.pendingDisabledNotices()).toEqual(['pdf'])
    expect(skillDisabledNotice('pdf')).toBe(
      'Skill `pdf` has been disabled for this Agent. Do not use it again in this Job. Continue with the remaining capabilities. If no valid alternative exists, explain the blocker.'
    )

    tracker.markNotified('pdf')
    expect(tracker.pendingDisabledNotices()).toEqual([])
    expect(tracker.observeInput('Use $pdf again.')).toEqual([])
  })

  it('recognizes exact Skill references, known paths, and uniquely owned MCP servers', () => {
    expect(explicitSkillReference('run $deep-research now', 'deep-research')).toBe(true)
    expect(explicitSkillReference('run $deep-research-extra now', 'deep-research')).toBe(false)

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
    tracker.setDiscoveredSkills('/jobs/1000', [
      { name: 'docx', path: '/jobs/1000/.agents/skills/docx/SKILL.md', enabled: true },
      { name: 'pdf', path: '/jobs/1000/.agents/skills/pdf/SKILL.md', enabled: true }
    ])

    expect(
      tracker.observeItem({
        type: 'commandExecution',
        cwd: '/jobs/1000',
        command: 'sed -n 1,20p .agents/skills/docx/SKILL.md'
      })
    ).toEqual(['docx'])
    expect(tracker.observeItem({ type: 'mcpToolCall', server: 'pdf-reader', tool: 'open' })).toEqual(['pdf'])
    expect(tracker.observeItem({ type: 'mcpToolCall', server: 'shared', tool: 'open' })).toEqual([])
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

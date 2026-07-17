import { describe, expect, it } from 'bun:test'
import { actorEventText } from '../src/core/turns/actor_event_text'

describe('@ankole/agent-computer addressed empty-text input', () => {
  it('renders a bare mention as a summons pointing at channel context', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            author: { display_name: '余丰任' },
            text: ''
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('余丰任 addressed you')
    expect(text).toContain('without any message text')
    expect(text).toContain('quoted recent conversation')
    expect(text).not.toContain('Handle actor event of type')
  })

  it('describes attachment-only addressed messages instead of the generic fallback', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            author: { name: 'Alice' },
            attachments: [
              {
                name: 'strategy.pdf',
                resource_type: 'file',
                agent_computer_path: '/workspace/user-files/inbox/strategy.pdf'
              }
            ]
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('Alice sent the attached files without any message text.')
    expect(text).toContain('Attachments:')
    expect(text).toContain('strategy.pdf')
  })

  it('keeps the generic fallback for other empty events', () => {
    expect(actorEventText({}, 'signal.entry.removed')).toBe('Handle actor event of type signal.entry.removed.')
  })

  it('keeps an explicit resolved reply target beside the current message', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            text: "Why was today's work lower quality?",
            reply_to_source_entry_id: 'msg-yesterday-report',
            reply_to: {
              source_entry_id: 'msg-yesterday-report',
              resolution: 'resolved',
              role: 'agent',
              author: { display_name: 'Research Agent' },
              text: "Yesterday's complete report"
            }
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('source_entry_id: msg-yesterday-report')
    expect(text).toContain("Yesterday's complete report")
    expect(text).toContain("Current message:\nWhy was today's work lower quality?")
    expect(text.indexOf("Yesterday's complete report")).toBeLessThan(
      text.indexOf("Why was today's work lower quality?")
    )
  })

  it('does not silently replace an unresolved reply target with ambient history', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            text: 'Compare the quality.',
            reply_to_source_entry_id: 'missing-target',
            reply_to: { source_entry_id: 'missing-target', resolution: 'unresolved' }
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('content could not be resolved')
    expect(text).toContain('reply_to_source_entry_id: missing-target')
    expect(text).toContain('Do not silently substitute another message')
  })

  it('describes materialized attachments on the replied-to entry without pretending they were re-sent', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            author: { display_name: 'Alice' },
            text: '',
            attachments: [],
            reply_to_source_entry_id: 'parent-file',
            reply_to: {
              source_entry_id: 'parent-file',
              resolution: 'resolved',
              role: 'human',
              attachments: [
                {
                  name: 'strategy.pdf',
                  resource_type: 'file',
                  agent_computer_path: '/workspace/user-files/inbox/strategy.pdf'
                }
              ]
            }
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('attachments:')
    expect(text).toContain('strategy.pdf')
    expect(text).toContain('Alice replied without adding any message text.')
    expect(text).not.toContain('Alice sent the attached files')
  })
})

describe('@ankole/agent-computer background agent job failure input', () => {
  it('offers direct correction or same-session continuation without forcing either', () => {
    const text = actorEventText(
      {
        data: {
          job_id: '019f64b1-4198-7200-9e22-6fb8fa8a3db8',
          title: 'Market classification research',
          runtime: 'task_worker',
          result_summary: 'Codex upstream returned HTTP 502.',
          attempts: 3,
          workdir: '/workspace'
        }
      },
      'background_agent_job.failed'
    )

    expect(text).toContain('Job: 019f64b1-4198-7200-9e22-6fb8fa8a3db8')
    expect(text).not.toContain('Runtime: task_worker')
    expect(text).not.toContain('Workdir: /workspace')
    expect(text).toContain('workspace mounts, and artifact observations before repeating any side effect')
    expect(text).toContain('make and verify it directly')
    expect(text).toContain('If the work benefits from the existing Job context')
    expect(text).toContain('call background_agent_job(steer)')
    expect(text).toContain('resume it')
    expect(text).not.toContain('background_agent_job(start)')
  })
})

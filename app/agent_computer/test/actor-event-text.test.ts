import { describe, expect, it } from 'bun:test'
import { actorEventText } from '../src/core/turns/actor_event_text'

describe('@ankole/agent-computer reply action input', () => {
  it('treats the callback payload shape from before canonical answers as stale', () => {
    const text = actorEventText(
      {
        data: {
          action: {
            value: {
              interactionId: 'clarify:call-1',
              selectedOptionId: 'operators',
              optionValue: 'Operators'
            }
          }
        }
      },
      'signal.action.invoked'
    )

    expect(text).toContain('old or invalid data shape')
    expect(text).toContain('stale')
    expect(text).not.toContain('Operators')
    expect(text).not.toContain('Continue the conversation')
  })
})

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

  it('does not use an opaque author id as a speaker label', () => {
    const text = actorEventText(
      {
        data: {
          entry: {
            author: { id: '019f0000-0000-7000-8000-000000000042' },
            text: ''
          }
        }
      },
      'im.message.addressed'
    )

    expect(text).toContain('A user addressed you')
    expect(text).not.toContain('019f0000-0000-7000-8000-000000000042')
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
                agent_computer_path: '/agents/agent-1/user-files/inbox/strategy.pdf'
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

    expect(text).not.toContain('source_entry_id')
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
    expect(text).not.toContain('missing-target')
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
                  agent_computer_path: '/agents/agent-1/user-files/inbox/strategy.pdf'
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
  it('offers direct correction or a new durable Job without terminal continuation', () => {
    const text = actorEventText(
      {
        data: {
          job_id: 1000,
          title: 'Market classification research',
          runtime: 'task_worker',
          result_summary: 'Codex upstream returned HTTP 502.',
          attempts: 3,
          workdir: '/agents/agent-1/sessions/session-1'
        }
      },
      'background_agent_job.failed'
    )

    expect(text).toContain('Job: 1000')
    expect(text).not.toContain('Runtime: task_worker')
    expect(text).not.toContain('Workdir: /agents/agent-1/sessions/session-1')
    expect(text).toContain('Use show_background_job_details')
    expect(text).toContain('concrete status or recent trajectory')
    expect(text).toContain('make and verify it directly')
    expect(text).toContain('Create a new BackgroundAgentJob')
    expect(text).not.toContain('background_agent_job(steer)')
    expect(text).not.toContain('resume it')
    expect(text).not.toContain('background_agent_job(start)')
  })
})

describe('@ankole/agent-computer background agent job waiting input', () => {
  it('shows semantic questions without Codex recovery ids', () => {
    const internalID = '019f0000-0000-7000-8000-000000000001'
    const text = actorEventText(
      {
        data: {
          job_id: 1000,
          title: 'Market classification research',
          pending_user_input: {
            threadId: internalID,
            turnId: internalID,
            itemId: internalID,
            questions: [
              {
                id: internalID,
                header: 'Audience',
                question: 'Who should this brief target?',
                isSecret: true,
                options: [
                  {
                    id: internalID,
                    label: 'Operators',
                    description: 'Console operators',
                    value: internalID
                  }
                ]
              }
            ]
          }
        }
      },
      'background_agent_job.waiting'
    )

    expect(text).toContain('Job: 1000')
    expect(text).toContain('Who should this brief target?')
    expect(text).toContain('Operators')
    expect(text).toContain('Console operators')
    expect(text).toContain('"sensitive":true')
    expect(text).not.toContain(internalID)
    expect(text).not.toContain('threadId')
    expect(text).not.toContain('turnId')
    expect(text).not.toContain('itemId')
  })
})

describe('@ankole/agent-computer background agent job completion input', () => {
  it('hands owner-visible artifact paths directly to reply_attachment', () => {
    const projectPath = '/agents/agent-1/jobs/1000'
    const artifactPath = `${projectPath}/report/report.md`
    const text = actorEventText(
      {
        data: {
          job_id: 1000,
          title: 'Market classification research',
          result_summary: 'Research complete.',
          project_path: projectPath,
          artifacts: { total_count: 1, paths: [artifactPath], truncated: false }
        }
      },
      'background_agent_job.completed'
    )

    expect(text).toContain(`Project path: ${projectPath}`)
    expect(text).toContain(`Artifacts ready for reply_attachment:\n- ${artifactPath}`)
    expect(text).toContain('Send the relevant files with reply_attachment')
  })

  it('bounds a hostile artifact list while preserving handoff after a long summary', () => {
    const projectPath = '/agents/agent-1/jobs/1000'
    const mountedOutputRoot = '/agents/agent-1/user-files/research-output'
    const paths = Array.from({ length: 50_000 }, (_, index) => `${projectPath}/report/artifact-${index}.pdf`)
    const text = actorEventText(
      {
        data: {
          job_id: 1000,
          result_summary: '大'.repeat(20_000),
          project_path: projectPath,
          artifacts: { total_count: paths.length, paths, truncated: false },
          artifact_roots: {
            total_count: 2,
            paths: [projectPath, mountedOutputRoot],
            truncated: false
          }
        }
      },
      'background_agent_job.completed'
    )

    expect(new TextEncoder().encode(text).byteLength).toBeLessThanOrEqual(32_768)
    expect(text).toContain('...[truncated]')
    expect(text).toContain(`Project path: ${projectPath}`)
    expect(text).toContain(`Artifact discovery roots:\n- ${projectPath}\n- ${mountedOutputRoot}`)
    expect(text).toContain('Artifact handoff: showing 32 of 50000 paths (truncated).')
    expect(text).toContain(paths[0]!)
    expect(text).not.toContain(paths.at(-1)!)
    expect(text).toContain('Use show_background_job_details')
  })
})

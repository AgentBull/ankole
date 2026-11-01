import { labeledZonedDateTime } from '../../../common/zoned-time'

export function renderCodexJobAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  skillsPrompt?: string
  podInstructions?: string
  lazySkillRouting?: boolean
  timezone?: string | null
  now?: Date
}): { content: string } {
  return {
    content: renderTaskAgents({
      jobRoot: input.jobRoot,
      soul: input.soul,
      mission: input.mission,
      skillsPrompt: input.skillsPrompt,
      podInstructions: input.podInstructions,
      lazySkillRouting: input.lazySkillRouting,
      timezone: input.timezone,
      now: input.now ?? new Date()
    })
  }
}

export function codexJobDriveContext(): string {
  return [
    'The Job workspace is a temporary working directory. Save files that must be kept or delivered in your private Drive with ankole-files put and return the resulting nodeId to the caller.',
    'Download received attachments with the ankole-pod chat attachment get command included in the conversation context. That command reads the bytes selected by the original message.',
    'Other conversations have separate Worker workspaces. Access to shared Drive nodes uses your own Principal permissions.'
  ].join('\n')
}

function renderTaskAgents(input: {
  jobRoot: string
  soul: string
  mission: string
  skillsPrompt?: string
  podInstructions?: string
  lazySkillRouting?: boolean
  timezone?: string | null
  now: Date
}): string {
  const startedAt = labeledZonedDateTime(input.now, input.timezone)
  const executionContext = [
    startedAt
      ? `Job start time: ${startedAt.text} (${startedAt.timezone}). Report times in ${startedAt.timezone}; the Worker system clock is UTC, so shell commands and the environment_context timezone show UTC.`
      : '',
    `Job workspace (the process cwd): ${input.jobRoot}.`,
    'All absolute paths shown to you are the real paths inside this Worker. Relative paths resolve from the Job workspace.',
    codexJobDriveContext(),
    input.podInstructions,
    'Your final message is the Job result and the caller accepts it as the verification record: verify the work against what the task says the deliverable must satisfy, and state the outcome with evidence, relevant paths, and remaining risks.',
    'The caller owns user-visible replies, attachments, scheduling, and durable Skill writes.',
    'If genuinely required information is missing, the lead agent must call request_parent_input; child agents must report the question to the lead.',
    input.lazySkillRouting
      ? 'A `recall` or `get_page` result that names a `lazyload-agent-skills/` record is a Skill discovery record; load that Skill with `skill_view`.'
      : '',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ]
    .filter(Boolean)
    .join('\n')

  return [
    '# Ankole Background Agent Job Context',
    section('SOUL', input.soul),
    section('MISSION', input.mission),
    section('Execution Context', executionContext),
    input.skillsPrompt?.trim()
  ]
    .filter(Boolean)
    .join('\n\n')
    .trim()
    .concat('\n')
}

function section(title: string, content: string | undefined): string {
  const text = content?.trim()
  return text ? `## ${title}\n\n${text}` : ''
}

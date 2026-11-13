import { labeledZonedDateTime } from '../../../common/zoned-time'

export function renderCodexJobAgents(input: {
  jobRoot: string
  skillsPrompt?: string
  podInstructions?: string
  driveInstructions?: string
  timezone?: string | null
  now?: Date
}): { content: string } {
  return {
    content: renderTaskAgents({
      jobRoot: input.jobRoot,
      skillsPrompt: input.skillsPrompt,
      podInstructions: input.podInstructions,
      driveInstructions: input.driveInstructions,
      timezone: input.timezone,
      now: input.now ?? new Date()
    })
  }
}

export function codexJobDriveContext(): string {
  return [
    'The Job workspace is a temporary working directory. Save files that must be kept or delivered in your private Drive with ankole-files put and return the resulting node_id to the caller.',
    'Download received attachments with the ankole-pod chat attachment get command included in the conversation context. That command reads the bytes selected by the original message.',
    'Other conversations have separate Worker workspaces. Access to shared Drive nodes uses your own Principal permissions.'
  ].join('\n')
}

function renderTaskAgents(input: {
  jobRoot: string
  skillsPrompt?: string
  podInstructions?: string
  driveInstructions?: string
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
    input.driveInstructions || codexJobDriveContext(),
    input.podInstructions,
    'Each tool output stays in context and is read again on every later step, so keep it small: request about 4000 max_output_tokens for a command unless you need more, cut long lines with `rg -M 300` or `cut -c1-300`, and write a large result to a Job workspace file and read it in parts.',
    'This computer has Bun and no `node` or `npm`: run JavaScript and TypeScript with `bun`, and use `bun run -` for a script on stdin.',
    'An `ankole:page/<id>` link names a Pod Page; read it with `ankole-pod pages.read \'{"id":"<id>"}\'` rather than opening it in a browser.',
    'When the task produces documents, reports, Pages, code changes, or data files, materialize an initial working draft to the target Page, Drive path, or Job workspace as soon as the core plan and facts are clear, then refine and verify it in place instead of holding all writes until the end.',
    'Before ending the Job, reconcile every acceptance criterion against the original task verbatim without relaxing constraints. Your final message is the verification record: report the outcome with concrete evidence, saved deliverable paths, and remaining risks; if any required criterion remains unmet or blocked, state `Outcome: incomplete` explicitly alongside completed artifact paths and the exact unmet criteria.',
    'The caller owns user-visible replies, attachments, scheduling, and durable Skill writes.',
    'If genuinely required information is missing, the lead agent must call request_parent_input; child agents must report the question to the lead.',
    'Complete foreground work before ending the turn; do not leave required shell jobs running in the background.'
  ]
    .filter(Boolean)
    .join('\n')

  return [
    '# Ankole Background Agent Job Context',
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

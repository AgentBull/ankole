import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterContextProvider } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../../common/i18n'
import { attachmentPreviewKind } from '../attachment-preview'
import type { PodActivity } from '../api'
import { ChoiceCard } from '../chat/choice-card'
import { CollapsedWorkView } from '../chat/collapsed-work-view'
import MarkdownRenderer from '../chat/markdown-renderer'
import type { ClarifyPrompt, ExecutionSummary } from '../chat/types'
import type { LinkedExecution, TimelineLiveStream, TimelineMessage } from '../chat/types'
import {
  interleavedReplySources,
  messageTime,
  placeLinkedExecutions,
  uncommittedStreams,
  timelineEventLabel,
  timelineTurns,
  unloadedPendingQuestions
} from '../chat/timeline-projections'
import { activitySteps } from '../chat/collapsed-work-view'
import { findMessageStep, firstUnreadMessageID } from '../chat-history'
import {
  ToolRunView,
  commandDetails,
  formatToolDetail,
  groupExploration,
  humanizeToolName,
  patchDetails,
  stepTitle
} from '../chat/tool-run-view'
import { MessageActions } from '../chat/message-actions'
import { LinkedExecutionCard } from '../chat/linked-execution-card'
import { MessageView } from '../chat/timeline-message'
import {
  BACKTRACK_DOUBLE_ESCAPE_MS,
  consumeEmptyComposerEscape,
  shouldYieldBacktrackToOverlay
} from '../chat/use-timeline-backtrack'
import { ChatModel } from './chat'

const render = (element: Parameters<typeof renderToStaticMarkup>[0]) =>
  renderToStaticMarkup(element).replace(/[\u2066-\u2069]/g, '')

beforeAll(async () => {
  await Promise.all(['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'].map(locale => loadLocale(locale)))
})

const execution: ExecutionSummary = {
  duration_ms: 4210,
  thinking_summary: 'Check the page structure, then query the records.',
  steps: [
    {
      id: 'read',
      tool: 'pod.pages.read',
      title: 'Read page Q4 Roadmap',
      status: 'completed',
      duration_ms: 180,
      input: JSON.stringify({ page: 'Q4' })
    },
    {
      id: 'query',
      tool: 'pod.base.query',
      title: 'Queried Tasks (18 rows)',
      status: 'completed',
      duration_ms: 340,
      output: JSON.stringify({ count: 18 })
    }
  ]
}

test('a work summary shows the turn’s thinking and steps, and never its model usage', () => {
  const usage = {
    rounds: 2,
    reported_rounds: 2,
    input_tokens: 94_900,
    output_tokens: 699,
    cached_input_tokens: 94_208,
    cache_creation_input_tokens: null,
    reasoning_tokens: 0,
    models: [
      {
        model: 'openai/gpt-6-astra',
        provider_model: 'gpt-6-astra',
        model_profile: 'primary',
        served_profile: 'primary',
        rounds: 2,
        reported_rounds: 2,
        input_tokens: 94_900,
        output_tokens: 699,
        cached_input_tokens: 94_208,
        cache_creation_input_tokens: null,
        reasoning_tokens: 0
      }
    ]
  }
  // A reply that used no tool and summarized no thinking has no work summary, whatever usage its record carries.
  expect(render(<CollapsedWorkView execution={{ duration_ms: 2_000, steps: [], usage }} attention />)).toBe('')
  // A reply with steps lists them and nothing about the model or its tokens.
  const html = render(<CollapsedWorkView execution={{ ...execution, usage }} attention />)
  expect(html).toContain('Work steps</span>')
  expect(html).toContain('Read page Q4 Roadmap')
  expect(html).not.toContain('gpt-6-astra')
  expect(html).not.toContain('94,900')
  expect(html).not.toContain('token')
})

test('a persisted execution restores all tool details inside a collapsed completed turn', () => {
  const html = render(<CollapsedWorkView execution={JSON.parse(JSON.stringify(execution))} />)
  expect(html).toContain('<details class="pod-chat-work">')
  expect(html).not.toContain('<details class="pod-chat-work" open')
  expect(html).toContain('Work steps</span>')
  expect(html).not.toContain('<time>')
  expect(html).not.toContain('pod-chat-working-spinner')
  expect(html).not.toContain('pod-chat-work-content')
  const expanded = render(<CollapsedWorkView execution={JSON.parse(JSON.stringify(execution))} attention />)
  expect(expanded).toContain('Check the page structure')
  expect(expanded).toContain('Read page Q4 Roadmap')
  expect(expanded).toContain('Queried Tasks (18 rows)')
  expect(expanded).toContain('&quot;count&quot;: 18')
})

test('active, failed, stopped and pending-decision work stays expanded', () => {
  for (const [props, summary] of [
    [{ active: true, execution: { ...execution, steps: [{ ...execution.steps![0]!, status: 'running' }] } }, undefined],
    [{ attention: true }, 'Work steps'],
    [{ execution: { ...execution, status: 'stopped' } }, 'Stopped'],
    [{ execution: { ...execution, status: 'failed' } }, 'Failed']
  ] satisfies [Partial<Parameters<typeof CollapsedWorkView>[0]>, string | undefined][]) {
    const html = render(<CollapsedWorkView execution={execution} {...props} />)
    expect(html).toMatch(/<details class="pod-chat-work"[^>]* open="">/)
    if (summary) expect(html).toContain(summary)
  }
  expect(render(<CollapsedWorkView execution={{ ...execution, status: 'stopped' }} />)).toContain(
    'data-outcome="stopped"'
  )
  expect(render(<CollapsedWorkView execution={{ ...execution, status: 'failed' }} />)).toContain(
    'data-outcome="failed"'
  )
})

test('a turn that recovers from a failed step finishes collapsed and marks the error so people can report it', () => {
  const recovered = {
    ...execution,
    status: 'completed',
    steps: [{ ...execution.steps![0]!, status: 'failed' }, execution.steps![1]!]
  }
  const html = render(<CollapsedWorkView execution={recovered} />)
  expect(html).toContain('<details class="pod-chat-work">')
  expect(html).not.toContain('data-outcome')
  expect(html).toContain('Work steps</span>')
  expect(html).toContain('<span class="pod-chat-work-errors">· 1 error</span>')
  expect(render(<CollapsedWorkView execution={execution} />)).not.toContain('pod-chat-work-errors')
  // A failed turn already says so, so its header does not count errors again.
  expect(render(<CollapsedWorkView execution={{ ...recovered, status: 'failed' }} />)).not.toContain(
    'pod-chat-work-errors'
  )
})

test('a step reads as the activity label people saw while it ran, in their language', () => {
  const created = {
    title: 'create_background_job',
    tool: 'create_background_job',
    label_key: 'conversations.delivery.reply.activity.background_job_create',
    label_bindings: {}
  }
  expect(stepTitle(created, i18n.getFixedT('zh-Hans-CN'))).toBe('创建后台 Agent 任务')
  expect(stepTitle(created, i18n.getFixedT('en-US'))).toBe('Creating a Background Agent Job')
  // A step recorded before labels existed keeps its title or a readable tool name.
  expect(stepTitle(execution.steps![0]!, i18n.getFixedT('zh-Hans-CN'))).toBe('Read page Q4 Roadmap')
  expect(stepTitle({ title: 'create_background_job', tool: 'create_background_job' }, i18n.getFixedT('en-US'))).toBe(
    'Create background job'
  )
  expect(render(<ToolRunView steps={[{ ...created, id: 'job', status: 'completed' }]} />)).toContain(
    'Creating a Background Agent Job'
  )
})

test('live thinking uses one collapsed disclosure with a loading indicator and keeps the complete text available when opened', () => {
  const thinking = { thinking_summary: 'Complete recorded reasoning text', steps: [] }
  const collapsed = render(<CollapsedWorkView execution={thinking} active />)
  expect(collapsed).toContain('<details class="pod-chat-work pod-chat-thinking">')
  expect(collapsed).toContain('pod-chat-working-spinner')
  expect(collapsed).not.toContain('<time>')
  expect(collapsed.match(/>Thinking</g)).toHaveLength(1)
  expect(collapsed).not.toContain('Complete recorded reasoning text')
  const opened = render(<CollapsedWorkView execution={thinking} active attention />)
  expect(opened.match(/>Thinking</g)).toHaveLength(1)
  expect(opened).toContain('Complete recorded reasoning text')
})

test('live work stays open while the model thinks between steps', () => {
  const html = render(
    <CollapsedWorkView
      active
      phaseLabel="Understanding the request"
      execution={{
        thinking_summary: 'Deciding what to read next',
        steps: [{ id: 'mkdir', tool: 'exec_command', title: 'Run command · mkdir', status: 'completed' }]
      }}
    />
  )
  expect(html).toContain('<details class="pod-chat-work" open="">')
  expect(html).toContain('Understanding the request')
  expect(html).toContain('Run command · mkdir')
  // The reasoning between steps stays one click away instead of replacing the step list.
  expect(html).toContain('<details class="pod-chat-thinking">')
})

test('a stopped tool loaded from history does not present an active spinner or a success mark', () => {
  const html = render(
    <ToolRunView steps={[{ id: 'stopped-tool', tool: 'bash', title: 'Stopped command', status: 'stopped' }]} />
  )
  expect(html).toContain('data-status="stopped"')
  expect(html).toContain('aria-label="Stopped"')
  expect(html).not.toContain('animate-spin')
  expect(html).not.toContain('aria-label="Completed"')
  expect(html).not.toContain('<details')
})

test('consecutive reads, searches, and listings fold into one collapsed row that counts them', async () => {
  const labeled = (id: string, key: string, bindings: Record<string, string>) => ({
    id,
    tool: 'command',
    title: id,
    status: 'completed',
    label_key: `conversations.delivery.reply.activity.${key}`,
    label_bindings: bindings
  })
  const steps = [
    labeled('read', 'file_read_target', { path: 'src/main.tsx' }),
    labeled('grep', 'search_code_target', { query: 'useActivityLabel' }),
    labeled('cat', 'command_read_files_family', { family: 'cat' }),
    labeled('ls', 'command_list_files_family', { family: 'ls' }),
    labeled('test', 'command_test_family', { family: 'bun test' }),
    labeled('lone-read', 'file_read_target', { path: 'src/style.css' }),
    {
      id: 'skill',
      tool: 'read_file',
      title: 'Read file',
      status: 'completed',
      input: { path: '/drive/Skills/ocr/SKILL.md' }
    },
    { id: 'legacy-grep', tool: 'grep', title: 'grep', status: 'completed' },
    { id: 'legacy-find', tool: 'find', title: 'find', status: 'completed' }
  ]

  expect(groupExploration(steps).map(entry => (Array.isArray(entry) ? entry.map(step => step.id) : entry.id))).toEqual([
    ['read', 'grep', 'cat', 'ls'],
    'test',
    'lone-read',
    'skill',
    ['legacy-grep', 'legacy-find']
  ])

  const html = render(<ToolRunView steps={steps} />)
  expect(html.match(/<details class="pod-chat-tool-group" data-status="completed">/g)).toHaveLength(2)
  expect(html).toContain('Read 2 files · Searched 1 time · Listed 1 directory')
  expect(html).toContain('Searched 2 times')
  expect(html).toContain('Searching code: “useActivityLabel”')
  expect(html).toContain('Running tests · bun test')

  // A folded row shows a running read first, and expands automatically when a step inside failed.
  const groupStatus = (statuses: string[]): Array<string | undefined> | undefined =>
    /<details( open="")? class="pod-chat-tool-group" data-status="(\w+)"><summary>.*?aria-label="(\w+)"/
      .exec(
        render(<ToolRunView steps={statuses.map((status, index) => ({ ...steps[0]!, id: `s${index}`, status }))} />)
      )
      ?.slice(1)
  expect(groupStatus(['completed', 'failed', 'running'])).toEqual<Array<string | undefined>>([
    undefined,
    'running',
    'Running'
  ])
  expect(groupStatus(['completed', 'error'])).toEqual<Array<string | undefined>>([' open=""', 'failed', 'Failed'])
  expect(groupStatus(['completed', 'cancelled'])).toEqual<Array<string | undefined>>([undefined, 'stopped', 'Stopped'])
  expect(groupStatus(['completed', 'completed'])).toEqual<Array<string | undefined>>([
    undefined,
    'completed',
    'Completed'
  ])

  await i18n.changeLanguage('zh-Hans-CN')
  try {
    expect(render(<ToolRunView steps={steps} />)).toContain('读取 2 个文件 · 搜索 1 次 · 列出 1 个目录')
  } finally {
    await i18n.changeLanguage('en-US')
  }
})

test('live work uses the room activity phases before the final reply is committed', () => {
  const model = new ChatModel()
  const activity: PodActivity = {
    conversationID: 'conversation',
    agentUID: 'agent',
    sessionID: 'conversation:conversation',
    signalID: 'signal',
    responseID: 'response',
    epoch: 1,
    revision: 1,
    state: 'active',
    tools: [
      { operation_id: 'read', phase: 'completed', label: 'Read the report', duration_ms: 42 },
      { operation_id: 'query', phase: 'failed', label: 'Query the table', duration_ms: 18 },
      { operation_id: 'write', phase: 'running', label: 'Update the report' }
    ]
  }

  model.observeActivity(activity)
  const received = model.activities.value.agent!
  const steps = activitySteps(received, item => item.label!)
  expect(steps.map(step => [step.id, step.status, step.duration_ms])).toEqual([
    ['read', 'completed', 42],
    ['query', 'failed', 18],
    ['write', 'running', undefined]
  ])

  const html = render(<CollapsedWorkView active execution={{ steps }} />)
  expect(html).toContain('Update the report')
  expect(html).toContain('data-status="completed"')
  expect(html).toContain('data-status="failed"')
  expect(html).toContain('data-status="running"')

  const waiting = render(
    <CollapsedWorkView active phaseLabel="Waiting for computer capacity" execution={{ steps: [] }} />
  )
  expect(waiting).toContain('Waiting for computer capacity')
  expect(waiting).toContain('pod-chat-working-spinner')
  expect(waiting).not.toContain('<time>')
  expect(waiting).not.toContain('<details')

  const completed = render(<CollapsedWorkView phaseLabel="Waiting for computer capacity" execution={execution} />)
  expect(completed).toContain('Work steps')
  expect(completed).not.toContain('<time>')
  expect(completed).not.toContain('Waiting for computer capacity')

  const parallel = render(
    <CollapsedWorkView
      active
      execution={{
        steps: [
          { id: 'read', tool: 'read', title: 'Reading the report', status: 'running' },
          { id: 'search', tool: 'search', title: 'Searching source material', status: 'running' }
        ]
      }}
    />
  )
  // Parallel steps share the header, and the folded list keeps the shape it has with one running step.
  expect(parallel).toContain('Reading the report · Searching source material')
  expect(parallel).not.toContain('tool calls')
  expect(parallel.match(/>Searching source material</g)).toHaveLength(1)
  expect(parallel).toContain('<details class="pod-chat-tool-group">')
})

test('active work highlights the current action without forcing its accumulated thinking and tool history open', () => {
  const html = render(
    <CollapsedWorkView
      active
      phaseLabel="Waiting for computer capacity"
      execution={{
        ...execution,
        steps: [
          ...execution.steps!,
          { id: 'current', tool: 'pod.pages.write', title: 'Updating the report', status: 'running' }
        ]
      }}
    />
  )
  expect(html).toContain('Updating the report')
  expect(html).not.toContain('Waiting for computer capacity')
  expect(html).toContain('<details class="pod-chat-thinking">')
  expect(html).toContain('<details class="pod-chat-tool-group">')
  expect(html).toContain('Work steps')
  expect(html).not.toContain('tool calls')
  expect(html).not.toContain('0.0s')
  expect(html).toContain('Check the page structure')
  expect(html).toContain('Queried Tasks (18 rows)')
})

test('terminal details show the real command, output and exit code without exposing a JSON envelope as the command', () => {
  const command = {
    id: 'command',
    tool: 'command',
    title: 'Check the workspace',
    status: 'completed',
    input: JSON.stringify({ command: 'git status --short', workdir: '/workspace' }),
    output: 'exit_code=0\nduration=120ms\n M report.md'
  }
  expect(commandDetails(command)).toEqual({
    command: 'git status --short',
    workdir: '/workspace',
    stdout: ' M report.md',
    stderr: undefined,
    exitCode: 0
  })
  const html = render(<ToolRunView steps={[command]} />)
  expect(html).toContain('Exit 0')
  expect(html).toContain('git status --short')
  expect(html).toContain(' M report.md')
  expect(html).not.toContain('&quot;command&quot;')
  expect(html).not.toContain('duration=120ms')
  const structured = { ...command, output: JSON.stringify({ stderr: 'Permission denied', exit_code: 2 }) }
  expect(commandDetails(structured)).toMatchObject({ stdout: undefined, stderr: 'Permission denied', exitCode: 2 })
  const failed = render(<ToolRunView steps={[{ ...structured, status: 'failed' }]} />)
  expect(failed).toContain('Exit 2')
  expect(failed).toContain('pod-chat-command-stderr')
  expect(failed).not.toContain('&quot;stderr&quot;')
  expect(commandDetails({ ...command, input: '{"command":' })).toBeUndefined()
})

test('apply_patch work shows each changed file with its counts and changed lines', () => {
  const input = [
    '*** Begin Patch',
    '*** Update File: src/report.ts',
    '*** Move to: src/summary.ts',
    '@@ export function total',
    ' const rows = load()',
    '-return rows.length',
    '+return rows.filter(Boolean).length',
    '+// counted once',
    '*** Add File: notes.md',
    '+# Notes',
    '*** Delete File: old.txt',
    '*** End Patch'
  ].join('\n')
  const patch = patchDetails({ tool: 'apply_patch', input })!
  expect(patch).toMatchObject({ added: 3, removed: 1, truncated: false })
  expect(patch.files.map(file => [file.kind, file.path, file.movePath, file.added, file.removed])).toEqual([
    ['update', 'src/report.ts', 'src/summary.ts', 2, 1],
    ['add', 'notes.md', undefined, 1, 0],
    ['delete', 'old.txt', undefined, 0, 0]
  ])
  const html = render(
    <ToolRunView
      steps={[{ id: 'patch', tool: 'apply_patch', title: 'apply_patch', status: 'completed', input, output: 'Done!' }]}
    />
  )
  expect(html).toContain('src/report.ts → src/summary.ts')
  expect(html).toContain('<span data-marker="-">-return rows.length</span>')
  expect(html).toContain('Lines added: 3, lines removed: 1')
  expect(html).toContain('Deleted')
  expect(html).not.toContain('*** Begin Patch')
  // The work history keeps only an excerpt of long input, and other tools keep their plain detail.
  expect(patchDetails({ tool: 'apply_patch', input: `${input.split('\n*** Add File')[0]}\n…` })!.truncated).toBe(true)
  expect(patchDetails({ tool: 'apply_patch', input: '{"changes":[]}' })).toBeUndefined()
  expect(patchDetails({ tool: 'command', input })).toBeUndefined()
})

test('the new-messages boundary is the first reply from someone else that was unread on entry', () => {
  const message = (id: string, seq: number, authorUID: string, kind: 'message' | 'notice' = 'message') =>
    ({ id, seq, authorUID, kind, authorType: authorUID === 'viewer' ? 'human' : 'agent' }) as never
  const detail = {
    conversation: { viewer: { uid: 'viewer' } } as never,
    olderMessagesBeforeSeq: null,
    messages: [
      message('read', 4, 'agent'),
      message('own', 5, 'viewer'),
      message('joined', 6, 'agent', 'notice'),
      message('reply', 7, 'agent'),
      message('live', 9, 'agent')
    ]
  }
  expect(firstUnreadMessageID(detail, { readSeq: 4, lastSeq: 8 })).toBe('reply')
  // Messages that arrive after entry never open a divider of their own.
  expect(firstUnreadMessageID(detail, { readSeq: 8, lastSeq: 8 })).toBeUndefined()
  // An unread boundary inside unloaded history is not guessed from the loaded window.
  expect(firstUnreadMessageID({ ...detail, olderMessagesBeforeSeq: 4 }, { readSeq: 2, lastSeq: 8 })).toBeUndefined()
  expect(firstUnreadMessageID({ ...detail, olderMessagesBeforeSeq: 4 }, { readSeq: 3, lastSeq: 8 })).toBe('read')
})

test('a searched message loads older pages until it is reachable, then opens the find there', () => {
  const detail = { olderMessagesBeforeSeq: 600, messages: [{ id: 'm600', seq: 600 }] } as never
  expect(findMessageStep(detail, 120, 0, false)).toBe('load_older')
  expect(findMessageStep(detail, 600, 0, false)).toEqual({ messageID: 'm600' })
  // A failed page, exhausted history, the page budget, or a withdrawn target opens the find without a target.
  expect(findMessageStep(detail, 120, 0, true)).toEqual({})
  expect(findMessageStep(detail, 120, 10, false)).toEqual({})
  expect(findMessageStep({ olderMessagesBeforeSeq: null, messages: [] } as never, 120, 0, false)).toEqual({})
  expect(findMessageStep(detail, 700, 0, false)).toEqual({})
})

test('answered and superseded decisions remain locked when loaded from durable interaction state', () => {
  const client = new QueryClient()
  const prompt: ClarifyPrompt = {
    state: 'pending',
    tool_call_id: 'call-1',
    interaction_id: 'source:clarify:call-1',
    question: 'Where should this report go?',
    choices: [
      { id: 'one', label: 'Q4 table', description: 'Write the structured records.' },
      { id: 'two', label: 'Draft page' }
    ],
    allow_free_text: true
  }
  try {
    const html = render(
      <QueryClientProvider client={client}>
        <ChoiceCard
          prompt={prompt}
          interaction={{ state: 'answered', choice_id: 'two', answered_by_name: 'Alice' }}
          onAnswer={async () => {
            throw new Error('The answered decision must stay locked')
          }}
        />
      </QueryClientProvider>
    )
    expect(html).toContain('data-state="answered"')
    expect(html).toContain('Answered by Alice')
    expect(html).toContain('aria-pressed="true"')
    expect(html).toContain('disabled=""')
    expect(html).not.toContain('<input')
    const old = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <ChoiceCard prompt={prompt} interaction={{ state: 'superseded' }} />
      </QueryClientProvider>
    )
    expect(old).toContain('Superseded')
    expect(old).not.toContain('<input')
  } finally {
    client.clear()
  }
})

test('a pending decision explains why a viewer cannot invoke its Agent and offers no answer action', () => {
  const client = new QueryClient()
  try {
    const prompt: ClarifyPrompt = {
      state: 'pending',
      tool_call_id: 'call',
      interaction_id: 'source:clarify:call',
      question: 'Where should this go?',
      choices: [{ id: 'one', label: 'Shared report' }],
      allow_free_text: true
    }
    const html = render(
      <QueryClientProvider client={client}>
        <ChoiceCard
          prompt={prompt}
          interaction={prompt}
          readOnlyReason="Ask an administrator for access to this Agent."
        />
      </QueryClientProvider>
    )
    expect(html).toContain('Ask an administrator for access to this Agent.')
    expect(html).toContain('disabled=""')
    expect(html).not.toContain('aria-keyshortcuts=')
  } finally {
    client.clear()
  }
})

test('chat Markdown renders GFM and math while code stays escaped before highlighting', () => {
  const html = renderToStaticMarkup(
    <MarkdownRenderer
      text={'| Name | Count |\n| --- | --- |\n| Tasks | 18 |\n\n$$x^2$$\n\n```html\n<script>alert(1)</script>\n```'}
    />
  )
  expect(html).toContain('<table')
  expect(html).toContain('Copy table')
  expect(html).toContain('katex')
  expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;')
  expect(html).not.toContain('<script>')
  expect(html).toContain('Wrap lines')
})

test('CJK punctuation ends an autolink without absorbing following prose', () => {
  const html = renderToStaticMarkup(<MarkdownRenderer text={'请查看 https://example.com，继续讨论。'} />)
  expect(html).toContain('href="https://example.com"')
  expect(html).not.toContain('href="https://example.com，')
  expect(html).toContain('继续讨论。')
  const explicit = renderToStaticMarkup(<MarkdownRenderer text={'[中文页面](https://example.com/名字，目录)'} />)
  expect(explicit).toContain('href="https://example.com/%E5%90%8D%E5%AD%97%EF%BC%8C%E7%9B%AE%E5%BD%95"')
})

test('a model-written invalid Pod page reference stays readable without a fake link or render failure', () => {
  for (const id of ['deadbeef', 'not-a-page', '00112233-4455-6677-8899-notuuid']) {
    const html = render(<MarkdownRenderer text={`Read [the report](ankole:page/${id}) before continuing.`} />)
    expect(html).toContain('<span>the report</span>')
    expect(html).toContain('before continuing.')
    expect(html).not.toContain('href=')
  }
})

test('room events identify the actor and action in all four locales and preserve unknown notices', () => {
  const event = {
    type: 'participants_added',
    actor_uid: 'alice',
    actor_name: 'Alice',
    targets: [
      { uid: 'bob', name: 'Bob', type: 'human' },
      { uid: 'carol', name: 'Carol', type: 'agent' }
    ],
    detail: 'Participants joined'
  }
  const invitations = {
    'en-US': 'Alice invited Bob and Carol to the conversation.',
    'zh-Hans-CN': 'Alice 邀请 Bob和Carol 加入会话',
    'ja-JP': 'Alice が Bob、Carol を会話に招待しました',
    'ko-KR': 'Alice 님이 Bob 및 Carol 님을 대화에 초대했습니다'
  }
  const plain = (text: string) => text.replace(/[\u2066-\u2069]/g, '')
  for (const [locale, invitation] of Object.entries(invitations)) {
    const translate = i18n.getFixedT(locale)
    const label = (changes: Partial<typeof event>) =>
      plain(
        timelineEventLabel(
          { text: 'Original system notice', richContent: { event: { ...event, ...changes } } },
          translate,
          locale
        )
      )
    expect(label({})).toBe(invitation)
    expect(label({ type: 'title_renamed', detail: 'Q4 Plan' })).toContain('Alice')
    expect(label({ type: 'title_renamed', detail: 'Q4 Plan' })).toContain('Q4 Plan')
    expect(label({ type: 'participant_removed' })).toContain('Alice')
    expect(label({ type: 'participant_removed' })).toContain('Bob')
    const shared = label({ type: 'access_scope_changed', detail: 'anchor_page' })
    expect(shared).toContain('Alice')
    expect(shared).toContain(plain(translate('pod.chat_room.scope_anchor_page')))
    expect(shared).not.toContain('anchor_page')
    expect(label({ type: 'future_notice', detail: 'internal detail' })).toBe('Original system notice')
  }
  expect(
    plain(
      timelineEventLabel(
        {
          text: 'fallback',
          richContent: {
            event: {
              ...event,
              type: 'participant_removed',
              actor_uid: 'bob',
              actor_name: 'Bob',
              targets: [event.targets[0]!]
            }
          }
        },
        i18n.getFixedT('en-US'),
        'en-US'
      )
    )
  ).toBe('Bob left the conversation.')
})

test('editing a prior request keeps the artifact warning in its tooltip', () => {
  const html = render(<MessageActions text="Original request" onEdit={() => {}} />)
  expect(html).toContain('aria-label="Edit and regenerate"')
  expect(html).toContain('Edit and regenerate · Regenerating keeps changes already made to pages, bases, and applets.')
  expect(render(<MessageActions text="Latest answer" alwaysVisible />)).toContain('data-visible="true"')
  expect(render(<MessageActions text="Retryable request" onRetry={() => {}} />)).toContain('data-visible="true"')
})

test('a reply’s action row offers select, quote, and copy as 32px buttons, then the time; an own message states the time first', () => {
  const props = {
    text: 'Answer',
    time: '2026-11-10T09:00:00Z',
    onQuote() {},
    onSelectMessage() {},
    onEdit() {}
  }
  const order = (html: string) =>
    [...html.matchAll(/<(button|time)\b[^>]*>/g)].map(([tag, name]) =>
      name === 'time' ? 'time' : /aria-label="([^"]+)"/.exec(tag)?.[1]
    )
  const reply = render(<MessageActions {...props} />)
  expect(order(reply)).toEqual(['Select messages', 'Quote reply', 'Copy message', 'Edit and regenerate', 'time'])
  expect(reply.match(/data-slot="button"/g)).toHaveLength(4)
  expect(reply).not.toContain('size-6')
  expect(reply).toContain('size-8')
  expect(order(render(<MessageActions {...props} timeFirst />))[0]).toBe('time')
})

test('the work summary replaces the native disclosure triangle with a 24px caret that turns while open', () => {
  const html = render(<CollapsedWorkView execution={execution} />)
  expect(html).toMatch(/<summary[^>]*><svg[^>]*class="[^"]*pod-chat-disclosure-caret/)
  expect(render(<CollapsedWorkView execution={{ ...execution, status: 'failed' }} />)).toMatch(
    /<details class="pod-chat-work"[^>]* open=""><summary[^>]*><svg[^>]*pod-chat-disclosure-caret/
  )
})

test('tool steps omit empty disclosures and humanize raw tool identifiers', () => {
  for (const empty of [null, undefined, '', '   ', {}, [], '{}', '[]', '""']) {
    expect(formatToolDetail(empty)).toBeUndefined()
  }
  expect(formatToolDetail('{"count":3}')).toBe('{\n  "count": 3\n}')
  expect(humanizeToolName('mcp__github__search_api_issues')).toBe('Search API issues')
  expect(humanizeToolName('pod.pages.read_document')).toBe('Pod pages read document')
  const html = render(
    <ToolRunView
      steps={[
        {
          id: 'empty-step',
          tool: 'mcp__github__search_api_issues',
          title: 'mcp__github__search_api_issues',
          status: 'completed',
          input: '{}',
          output: '[]'
        }
      ]}
    />
  )
  expect(html).toContain('Search API issues')
  expect(html).not.toContain('<details')
})

test('choice cards expose numeric shortcuts only for the first four active keyboard choices and preserve astral initials', () => {
  const client = new QueryClient()
  const choices = Array.from({ length: 5 }, (_, index) => ({ id: `c-${index + 1}`, label: `Option ${index + 1}` }))
  const prompt: ClarifyPrompt = {
    state: 'pending',
    tool_call_id: 'call-shortcuts',
    interaction_id: 'source:clarify:call-shortcuts',
    question: 'Choose one:',
    choices,
    allow_free_text: false
  }
  try {
    const inactive = render(
      <QueryClientProvider client={client}>
        <ChoiceCard prompt={prompt} interaction={prompt} onAnswer={async () => {}} />
      </QueryClientProvider>
    )
    expect(inactive).not.toContain('<kbd>')
    expect(inactive).not.toContain('aria-keyshortcuts=')

    const active = render(
      <QueryClientProvider client={client}>
        <ChoiceCard prompt={prompt} interaction={prompt} onAnswer={async () => {}} keyboardActive />
      </QueryClientProvider>
    )
    expect(active.match(/<kbd>\d+<\/kbd>/g)).toEqual(['<kbd>1</kbd>', '<kbd>2</kbd>', '<kbd>3</kbd>', '<kbd>4</kbd>'])
    expect(active).not.toContain('aria-keyshortcuts="5"')

    const answered = render(
      <QueryClientProvider client={client}>
        <ChoiceCard
          prompt={prompt}
          interaction={{ state: 'answered', choice_id: 'c-1', answered_by_name: '🚀 Rocket' }}
        />
      </QueryClientProvider>
    )
    expect(answered).toContain('<span class="pod-chat-event-avatar" aria-hidden="true">🚀</span>')
  } finally {
    client.clear()
  }
})

test('frozen attachments choose the existing in-chat preview for supported office and code files', () => {
  expect(attachmentPreviewKind('report.pdf', 'application/pdf')).toBe('pdf')
  expect(attachmentPreviewKind('budget.xlsx')).toBe('spreadsheet')
  expect(attachmentPreviewKind('slides.pptx')).toBe('presentation')
  expect(attachmentPreviewKind('worker.rs', 'application/octet-stream')).toBe('text')
  expect(attachmentPreviewKind('preview.png', 'image/png')).toBe('image')
  expect(attachmentPreviewKind('bundle.zip', 'application/zip')).toBeUndefined()
  expect(attachmentPreviewKind('demo.mp4', 'video/mp4')).toBe('video')
  expect(attachmentPreviewKind('memo.m4a', 'audio/mp4')).toBe('audio')
  expect(attachmentPreviewKind('worker.ts', 'video/mp2t')).toBe('text')
})

test('attachments without a recorded media type preview by extension with the Pod file page formats', () => {
  expect(attachmentPreviewKind('report.pdf')).toBe('pdf')
  expect(attachmentPreviewKind('photo.jpg', 'application/octet-stream')).toBe('image')
  expect(attachmentPreviewKind('logo.svg', 'image/svg+xml')).toBe('image')
  expect(attachmentPreviewKind('clip.mov')).toBe('video')
  expect(attachmentPreviewKind('行情.csv')).toBe('table')
  expect(attachmentPreviewKind('export.tsv', 'text/tab-separated-values')).toBe('table')
  expect(attachmentPreviewKind('macro.xlsm')).toBe('spreadsheet')
  expect(attachmentPreviewKind('legacy.xlsb', 'application/vnd.ms-excel.sheet.binary.macroenabled.12')).toBe(
    'spreadsheet'
  )
  expect(attachmentPreviewKind('研报.md', 'text/markdown')).toBe('markdown')
  expect(attachmentPreviewKind('notes.markdown')).toBe('markdown')
  expect(attachmentPreviewKind('page.html', 'text/html')).toBe('text')
  expect(attachmentPreviewKind('proposal.docx')).toBe('word')
  expect(attachmentPreviewKind('template.docm')).toBe('word')
  expect(attachmentPreviewKind('deck.pptx')).toBe('presentation')
  expect(attachmentPreviewKind('legacy.doc')).toBeUndefined()
})

test('a committed clarification replaces its stream without hiding another Agent', () => {
  const streams: TimelineLiveStream[] = [
    {
      agentUID: 'research',
      responseID: 'research-response',
      signalIDs: ['research-signal'],
      text: 'Research answer',
      thinkingSummary: 'Checking evidence'
    },
    {
      agentUID: 'writer',
      responseID: 'writer-response',
      signalIDs: ['writer-signal'],
      text: 'Draft answer',
      thinkingSummary: 'Writing a summary'
    }
  ]
  const clarification: TimelineMessage = {
    attachments: [],
    authorArchived: false,
    authorDisplayName: 'Research Agent',
    createdAt: '2026-10-25T00:00:00Z',
    kind: 'message',
    seq: 2,
    text: 'Which source?',
    links: [],
    mentions: [],
    savedPages: [],
    id: 'question',
    authorType: 'agent',
    authorUID: 'research',
    signalID: 'research-signal',
    richContent: {
      clarify: {
        state: 'pending',
        tool_call_id: 'question',
        interaction_id: 'research-signal:clarify:question',
        question: 'Which source?',
        choices: [],
        allow_free_text: true
      }
    }
  }
  expect(uncommittedStreams([clarification], streams).map(stream => stream.agentUID)).toEqual(['writer'])
  const final = { ...clarification, id: 'final', richContent: { execution } }
  expect(uncommittedStreams([clarification, final], streams).map(stream => stream.agentUID)).toEqual(['writer'])
})

test('turn navigation keeps late parallel answers with the question each Agent actually received', () => {
  const messages: Parameters<typeof timelineTurns>[0] = [
    { id: 'research-ask', kind: 'message', authorType: 'human', text: 'Research the sources.' },
    { id: 'writing-ask', kind: 'message', authorType: 'human', text: 'Draft the announcement.' },
    {
      id: 'research-question',
      kind: 'message',
      authorType: 'agent',
      text: 'Which source?',
      replyToMessageID: 'research-ask',
      richContent: { clarify: { state: 'answered' } }
    },
    {
      id: 'research-answer',
      kind: 'message',
      authorType: 'agent',
      text: 'Verified research findings.',
      replyToMessageID: 'research-ask'
    },
    {
      id: 'writing-answer',
      kind: 'message',
      authorType: 'agent',
      text: 'Draft announcement.',
      replyToMessageID: 'writing-ask'
    }
  ]
  expect(timelineTurns(messages)).toEqual([
    { id: 'research-ask', text: 'Research the sources.', preview: 'Verified research findings.' },
    { id: 'writing-ask', text: 'Draft the announcement.', preview: 'Draft announcement.' }
  ])
})

test('turn navigation does not invent a source for independent work or a question outside the loaded history', () => {
  expect(
    timelineTurns([
      { id: 'ask', kind: 'message', authorType: 'human', text: 'Current question.' },
      { id: 'independent', kind: 'message', authorType: 'agent', text: 'Independent update.' },
      { id: 'old-answer', kind: 'message', authorType: 'agent', text: 'Earlier answer.', replyToMessageID: 'old-ask' }
    ])
  ).toEqual([{ id: 'ask', text: 'Current question.' }])
})

test('interleaved replies expose the actual question and author without adding context to an ordinary exchange', () => {
  const messages: Parameters<typeof interleavedReplySources>[0] = [
    { id: 'ask-a', kind: 'message', authorType: 'human', authorDisplayName: 'Alice', text: 'Research the sources.' },
    {
      id: 'answer-a',
      kind: 'message',
      authorType: 'agent',
      authorDisplayName: 'Research Agent',
      text: 'Initial findings.',
      replyToMessageID: 'ask-a'
    },
    { id: 'ask-b', kind: 'message', authorType: 'human', authorDisplayName: 'Bob', text: 'Draft the announcement.' },
    {
      id: 'late-a',
      kind: 'message',
      authorType: 'agent',
      authorDisplayName: 'Research Agent',
      text: 'Additional verified findings.',
      replyToMessageID: 'ask-a'
    },
    {
      id: 'answer-b',
      kind: 'message',
      authorType: 'agent',
      authorDisplayName: 'Writing Agent',
      text: 'Draft announcement.',
      replyToMessageID: 'ask-b'
    }
  ]
  const sources = interleavedReplySources(messages)
  expect([...sources.keys()]).toEqual(['late-a'])
  expect(sources.get('late-a')).toMatchObject({
    id: 'ask-a',
    authorDisplayName: 'Alice',
    text: 'Research the sources.'
  })
})

test('linked executions appear during live work and move to its final reply once, across clarification messages', () => {
  const question: Parameters<typeof placeLinkedExecutions>[0][number] = {
    id: 'question',
    authorType: 'agent',
    kind: 'message',
    signalID: 'source',
    richContent: { clarify: { state: 'answered' } }
  }
  const followup = { ...question, id: 'followup' }
  const final = { ...question, id: 'final', richContent: { execution } }
  const stream: TimelineLiveStream = {
    agentUID: 'research',
    responseID: 'response',
    signalIDs: ['source'],
    text: 'Preparing the final answer.',
    thinkingSummary: ''
  }
  const run: LinkedExecution = {
    id: '42',
    kind: 'background_agent_job',
    title: 'Source collection',
    status: 'running',
    agentUID: 'research',
    sourceSignalID: 'source',
    createdAt: '2026-10-25T00:00:00Z',
    updatedAt: '2026-10-25T00:00:01Z'
  }
  const live = placeLinkedExecutions([question, followup], [stream], [run])
  expect(live.messages.size).toBe(0)
  expect([...live.streams.entries()]).toEqual([['research', [run]]])
  const waiting = placeLinkedExecutions([question, followup], [], [run])
  expect([...waiting.messages.entries()]).toEqual([['followup', [run]]])
  const completed = placeLinkedExecutions([question, followup, final], [], [run])
  expect(completed.streams.size).toBe(0)
  expect([...completed.messages.entries()]).toEqual([['final', [run]]])
  const silent = placeLinkedExecutions(
    [{ id: 'trigger', kind: 'message', authorType: 'human' }],
    [],
    [{ ...run, sourceMessageID: 'trigger' }]
  )
  expect([...silent.messages.entries()]).toEqual([['trigger', [{ ...run, sourceMessageID: 'trigger' }]]])
})

test('an unresolved question stays actionable outside a 500-message history window and is not duplicated when loaded', () => {
  const question: ReturnType<typeof unloadedPendingQuestions>[number] = {
    interaction_id: 'old-source:clarify:old-question',
    messageID: 'old-question',
    agentUID: 'research',
    tool_call_id: 'old-call',
    question: 'Which report should receive the findings?',
    choices: [{ id: 'report', label: 'Shared report', description: null }],
    allow_free_text: true,
    state: 'pending'
  }
  const loadedQuestion = { ...question, interaction_id: 'current-question', messageID: 'recent-question' }
  const interactions = [
    question,
    { ...question, interaction_id: 'answered-question', messageID: 'answered', state: 'answered' },
    { ...question, interaction_id: 'superseded-question', messageID: 'superseded', state: 'superseded' },
    loadedQuestion
  ]
  const messages = [
    ...Array.from({ length: 499 }, (_, index) => ({ id: `statement-${index}` })),
    { id: loadedQuestion.messageID }
  ]
  expect(unloadedPendingQuestions(interactions, messages)).toEqual([question])
  expect(unloadedPendingQuestions(interactions, [{ id: question.messageID }, ...messages])).toEqual([])
})

test('a message older than 24 hours names its day as well as its time', () => {
  const now = new Date(2026, 9, 29, 15, 0)
  expect(messageTime(new Date(2026, 9, 29, 9, 41).toISOString(), 'en-US', now)).toBe('09:41 AM')
  // Yesterday evening is still inside the last 24 hours, so it shows only its time.
  expect(messageTime(new Date(2026, 9, 28, 18, 32).toISOString(), 'en-US', now)).toBe('06:32 PM')
  expect(messageTime(new Date(2026, 9, 28, 15, 0).toISOString(), 'en-US', now)).toMatch(/^Oct 28(?:,| at) 03:00 PM$/)
  expect(messageTime(new Date(2026, 9, 27, 9, 41).toISOString(), 'en-US', now)).toMatch(/^Oct 27(?:,| at) 09:41 AM$/)
  expect(messageTime(new Date(2025, 11, 31, 23, 5).toISOString(), 'en-US', now)).toMatch(
    /^Dec 31, 2025(?:,| at) 11:05 PM$/
  )
})

test('consumeEmptyComposerEscape consumes both arming and entering Escape presses only when editable messages exist', () => {
  let entered = 0
  const enterBacktrack = () => {
    entered += 1
    return true
  }

  expect(
    consumeEmptyComposerEscape({
      now: 1000,
      lastEscapeAt: null,
      canEnterBacktrack: false,
      enterBacktrack
    })
  ).toEqual({ handled: false, nextLastEscapeAt: null })
  expect(entered).toBe(0)

  const armed = consumeEmptyComposerEscape({
    now: 1000,
    lastEscapeAt: null,
    canEnterBacktrack: true,
    enterBacktrack
  })
  expect(armed).toEqual({ handled: true, nextLastEscapeAt: 1000 })
  expect(entered).toBe(0)

  const activated = consumeEmptyComposerEscape({
    now: 1000 + BACKTRACK_DOUBLE_ESCAPE_MS,
    lastEscapeAt: armed.nextLastEscapeAt,
    canEnterBacktrack: true,
    enterBacktrack
  })
  expect(activated).toEqual({ handled: true, nextLastEscapeAt: null })
  expect(entered).toBe(1)

  const expired = consumeEmptyComposerEscape({
    now: 1000 + BACKTRACK_DOUBLE_ESCAPE_MS + 1,
    lastEscapeAt: 1000,
    canEnterBacktrack: true,
    enterBacktrack
  })
  expect(expired).toEqual({ handled: true, nextLastEscapeAt: 1000 + BACKTRACK_DOUBLE_ESCAPE_MS + 1 })
  expect(entered).toBe(1)
})

test('shouldYieldBacktrackToOverlay ignores ancestor Sheet dialogs containing the chat container while yielding to inner or portaled popups', () => {
  const chatContainer = {} as unknown as Node
  const ancestorSheetDialog = {
    contains: (node: Node | null) => node === chatContainer
  }
  const innerPopoverDialog = {
    contains: () => false
  }

  expect(shouldYieldBacktrackToOverlay({ closest: () => ancestorSheetDialog }, chatContainer)).toBe(false)

  expect(shouldYieldBacktrackToOverlay({ closest: () => innerPopoverDialog }, chatContainer)).toBe(true)

  expect(shouldYieldBacktrackToOverlay({ closest: () => null }, chatContainer)).toBe(false)
  expect(shouldYieldBacktrackToOverlay(null, chatContainer)).toBe(false)
})

test('a live reply and the committed message that replaces it render the same tree down to the reply text', () => {
  const client = new QueryClient()
  const model = new ChatModel()
  const shared = {
    model,
    conversationID: 'room',
    linkedRuns: [],
    onJumpToSource() {},
    keyboardActive: false,
    own: false
  }
  const live: TimelineLiveStream = {
    agentUID: 'agent',
    agentName: 'Planner',
    responseID: 'response',
    signalIDs: ['signal'],
    text: 'East leads this quarter.',
    thinkingSummary: 'Comparing regions'
  }
  const committed = {
    id: 'reply',
    seq: 3,
    kind: 'message',
    authorType: 'agent',
    authorUID: 'agent',
    authorDisplayName: 'Planner',
    authorArchived: false,
    text: 'East leads this quarter.',
    createdAt: '2026-11-10T09:00:00Z',
    signalID: 'signal',
    replyToMessageID: null,
    mentions: [],
    savedPages: [],
    links: [],
    attachments: [],
    richContent: { execution: { thinking_summary: 'Comparing regions', steps: [] } }
  } as unknown as TimelineMessage
  // The element names from the message to its reply text; React keeps a subtree whose path matches.
  const path = (html: string) => {
    const before = html.slice(0, html.search(/<div[^>]*class="[^"]*pod-chat-markdown/))
    const open: string[] = []
    for (const [, closing, name] of before.matchAll(/<(\/?)([a-z0-9]+)[^>]*>/g)) {
      // An icon's path closes itself in some markup and with a tag in other markup, so it never counts.
      if (['br', 'img', 'input', 'meta', 'path'].includes(name!)) continue
      if (closing) open.pop()
      else open.push(name!)
    }
    return open.join('>')
  }
  try {
    const wrap = (view: ReactNode) => render(<QueryClientProvider client={client}>{view}</QueryClientProvider>)
    const liveHTML = wrap(<MessageView {...shared} live={live} showActions={false} />)
    const committedHTML = wrap(<MessageView {...shared} message={committed} showActions />)
    expect(liveHTML).toContain('data-live-agent="agent"')
    expect(committedHTML).not.toContain('data-live-agent')
    expect(path(liveHTML)).toBe(path(committedHTML))
    expect(path(liveHTML)).toBe('article>div')
  } finally {
    client.clear()
  }
})

test('first-class memory, web, and read-only ankole-pod steps fold while writes and mcporter stay expanded', () => {
  const steps = [
    {
      id: 'mem-1',
      tool: 'brain.search',
      title: 'Search memory: Q4 OKRs',
      status: 'completed',
      label_key: 'conversations.delivery.reply.activity.memory_recall',
      label_bindings: { query: 'Q4 OKRs' }
    },
    {
      id: 'web-1',
      tool: 'web_search',
      title: 'Search web: Ash JSON API',
      status: 'completed',
      label_key: 'conversations.delivery.reply.activity.web_search',
      label_bindings: { query: 'Ash JSON API' }
    },
    {
      id: 'pod-read-1',
      tool: 'command',
      title: 'Read page: Architecture',
      status: 'completed',
      input: { command: '/bin/zsh -lc \'ankole-pod pages.read {"id":"page-1"}\'' }
    },
    {
      id: 'pod-write-1',
      tool: 'command',
      title: 'Run command: ankole-pod base.write',
      status: 'completed',
      input: { command: 'ankole-pod base.write \'{"id":"base-1"}\'' }
    },
    {
      id: 'mcp-1',
      tool: 'command',
      title: 'Run command: mcporter call github.list_issues',
      status: 'completed',
      input: { command: 'mcporter call github.list_issues' }
    }
  ]

  expect(groupExploration(steps).map(entry => (Array.isArray(entry) ? entry.map(step => step.id) : entry.id))).toEqual([
    ['mem-1', 'web-1', 'pod-read-1'],
    'pod-write-1',
    'mcp-1'
  ])

  const html = render(<ToolRunView steps={steps} />)
  expect(html).toContain('Recalled 1 memory · Checked 1 web source · Read 1 Pod resource')
})

test('LinkedExecutionCard renders inline choices and quick-reply composer as a sibling outside the main button when waiting_on_user', () => {
  const client = new QueryClient()
  const run: LinkedExecution = {
    id: '42',
    kind: 'background_agent_job',
    title: 'Migrate staging schema',
    agentUID: 'ops_agent',
    status: 'waiting_on_user',
    stoppable: true,
    canMessage: true,
    pendingQuestions: [
      {
        id: 'q1',
        header: 'Strategy',
        question: 'Proceed with online index rebuild?',
        options: [
          { label: 'Yes, online', description: 'Zero downtime' },
          { label: 'Maintenance window', description: 'Faster lock' }
        ]
      }
    ],
    createdAt: '2026-11-11T08:00:00Z',
    updatedAt: '2026-11-11T08:01:00Z'
  }
  try {
    const html = render(
      <QueryClientProvider client={client}>
        <LinkedExecutionCard run={run} conversationID="conv-1" />
      </QueryClientProvider>
    )
    expect(html).toContain('pod-chat-linked-run-answer')
    expect(html).toContain('Proceed with online index rebuild?')
    expect(html).toContain('Yes, online')
    expect(html).toContain('Type your answer to continue this task…')
    // Ensure interactive answer controls are NOT nested inside the main inspector button.
    const mainButtonMatch = /<button[^>]*class="pod-chat-linked-run-main"[^>]*>([\s\S]*?)<\/button>/.exec(html)
    expect(mainButtonMatch?.[1]).not.toContain('pod-chat-linked-run-answer')
  } finally {
    client.clear()
  }
})

test('blocked connector steps render honest blocked state and ConnectorAuthCardView via InteractionSurface', () => {
  const client = new QueryClient()
  const model = new ChatModel()
  const message = {
    id: 'msg-blocked',
    seq: 4,
    kind: 'message',
    authorType: 'agent',
    authorUID: 'agent',
    authorDisplayName: 'Assistant',
    authorArchived: false,
    text: 'I need GitHub access to inspect acme/app.',
    createdAt: '2026-11-11T09:00:00Z',
    signalID: 'sig-1',
    replyToMessageID: null,
    mentions: [],
    savedPages: [],
    links: [],
    attachments: [],
    richContent: {
      connector_auth: {
        wait_id: 'wait-1',
        interaction_id: 'sig-1:connector_auth:wait-1',
        connection_slug: 'work',
        display_name: 'GitHub (Work)',
        plugin_id: 'github',
        toolkit: 'github',
        tool_name: 'repos_get',
        subject_kind: 'human',
        auth_scheme: 'oauth2',
        required_scopes: ['repo'],
        authorization_url: '/connectors?connection=work&subject_kind=human',
        state: 'pending'
      },
      execution: {
        steps: [
          {
            id: 'step-gh',
            tool: 'command',
            title: 'Run command: mcporter call github.repos_get',
            status: 'blocked',
            input: { command: 'mcporter call github.repos_get owner=acme repo=app' }
          }
        ]
      }
    }
  } as unknown as TimelineMessage

  try {
    const html = render(
      <QueryClientProvider client={client}>
        <MessageView
          model={model}
          conversationID="conv-1"
          linkedRuns={[]}
          onJumpToSource={() => {}}
          keyboardActive={false}
          own={false}
          message={message}
          showActions
        />
      </QueryClientProvider>
    )
    expect(html).toContain('data-testid="chat-connector-auth-card"')
    expect(html).toContain('GitHub (Work)')
    expect(html).toContain('Connect &amp; Authorize')
    expect(html).toContain('data-status="blocked"')

    const prevDocument = globalThis.document
    globalThis.document = {
      querySelector: (sel: string) =>
        sel === 'meta[name="ankole-principal"]' ? ({ content: 'bob' } as HTMLMetaElement) : null
    } as unknown as Document
    try {
      const otherViewerMessage = {
        ...message,
        richContent: {
          ...message.richContent,
          connector_auth: {
            ...message.richContent!.connector_auth!,
            human_uid: 'alice'
          }
        }
      } as unknown as TimelineMessage
      const bobHtml = render(
        <QueryClientProvider client={client}>
          <MessageView
            model={model}
            conversationID="conv-1"
            linkedRuns={[]}
            onJumpToSource={() => {}}
            keyboardActive={false}
            own={false}
            message={otherViewerMessage}
            showActions
          />
        </QueryClientProvider>
      )
      expect(bobHtml).toContain('Waiting for @alice to connect GitHub (Work).')
      expect(bobHtml).not.toContain('Connect &amp; Authorize')
      expect(bobHtml).not.toContain('Connected · Resuming automatically')
    } finally {
      globalThis.document = prevDocument
    }
  } finally {
    client.clear()
  }
})

test('library.skill.save ActionCard renders ownership details, diff/draft disclosures, and ChatModel prefixes attachedSkill', () => {
  const client = new QueryClient()
  const model = new ChatModel()
  model.attachedSkill.value = { slug: 'pg-audit', name: 'Postgres Audit' }
  model.draft.value = 'Inspect slow queries on orders'
  expect(model.hasContent.value).toBe(true)

  const submission = model.submit('conv-1', 'assistant', () => 'msg-1')
  expect(submission.text).toBe('/pg-audit Inspect slow queries on orders')
  model.accepted(submission)
  expect(model.draft.value).toBe('')
  expect(model.attachedSkill.value).toBeNull()

  const cardMessage = {
    id: 'msg-skill-card',
    seq: 5,
    kind: 'message',
    authorType: 'agent',
    authorUID: 'assistant',
    authorDisplayName: 'Personal Assistant',
    authorArchived: false,
    text: '',
    createdAt: '2026-11-11T09:05:00Z',
    signalID: 'sig-2',
    replyToMessageID: null,
    mentions: [],
    savedPages: [],
    links: [],
    attachments: [],
    richContent: {
      action_card: {
        card_id: 'card-skill-1',
        action_kind: 'library.skill.save',
        summary: 'Save Postgres Index Audit workflow as a Personal Skill.',
        status: 'prepared',
        payload: {
          operation: 'update',
          slug: 'pg-audit',
          skill_name: 'Postgres Audit',
          target: 'personal',
          agent_uid: 'assistant',
          base_revision: 1,
          diff: '- 1. Check index\n+ 1. Check covering keyset index',
          markdown: '# Postgres Audit\n\n## When to Use\nWhen auditing slow queries.'
        }
      }
    }
  } as unknown as TimelineMessage

  const replyMessage = {
    id: 'msg-agent-reply',
    seq: 6,
    kind: 'message',
    authorType: 'agent',
    authorUID: 'assistant',
    authorDisplayName: 'Personal Assistant',
    authorArchived: false,
    text: 'Audit complete: keyset index reduced latency from 840ms to 4ms.',
    createdAt: '2026-11-11T09:06:00Z',
    signalID: 'sig-3',
    replyToMessageID: null,
    mentions: [],
    savedPages: [],
    links: [],
    attachments: []
  } as unknown as TimelineMessage

  try {
    const cardHtml = render(
      <QueryClientProvider client={client}>
        <MessageView
          model={model}
          conversationID="conv-1"
          linkedRuns={[]}
          onJumpToSource={() => {}}
          onResolveActionCard={async () => {}}
          keyboardActive={false}
          own={false}
          message={cardMessage}
          showActions
        />
      </QueryClientProvider>
    )
    expect(cardHtml).toContain('Save Skill approval')
    expect(cardHtml).toContain('Postgres Audit (/pg-audit)')
    expect(cardHtml).toContain('Scope: Personal Skill (only on your Personal Assistant)')
    expect(cardHtml).toContain('Check covering keyset index')

    const redactedCardMessage = {
      ...cardMessage,
      richContent: {
        action_card: {
          ...cardMessage.richContent!.action_card!,
          payload: {
            operation: 'update',
            slug: 'pg-audit',
            skill_name: 'Postgres Audit',
            target: 'personal',
            agent_uid: 'assistant',
            base_revision: 1,
            redacted: true
          }
        }
      }
    } as unknown as TimelineMessage
    const redactedHtml = render(
      <QueryClientProvider client={client}>
        <MessageView
          model={model}
          conversationID="conv-1"
          linkedRuns={[]}
          onJumpToSource={() => {}}
          onResolveActionCard={async () => {}}
          keyboardActive={false}
          own={false}
          message={redactedCardMessage}
          showActions
        />
      </QueryClientProvider>
    )
    expect(redactedHtml).toContain('Draft content is only visible to the Personal Assistant owner.')
    expect(redactedHtml).not.toContain('Check covering keyset index')

    const replyHtml = render(
      <QueryClientProvider client={client}>
        <MessageView
          model={model}
          conversationID="conv-1"
          linkedRuns={[]}
          onJumpToSource={() => {}}
          onSaveAsSkill={() => {}}
          keyboardActive={false}
          own={false}
          message={replyMessage}
          showActions
        />
      </QueryClientProvider>
    )
    expect(replyHtml).toContain('Save as Skill (/learn)')
  } finally {
    client.clear()
  }
})

test('MessageView renders PageAccessCardView with 4-stage waterfall for managers and redacts restricted titles for non-managers', () => {
  const client = new QueryClient()
  const model = new ChatModel()

  const managerMessage = {
    id: 'msg-access-manager',
    seq: 7,
    kind: 'message',
    authorType: 'agent',
    authorUID: 'research',
    authorDisplayName: 'Research Colleague',
    authorArchived: false,
    text: 'I need view access to Q4 Strategy to finish this analysis.',
    createdAt: '2026-11-11T09:10:00Z',
    signalID: 'sig-access-1',
    replyToMessageID: null,
    mentions: [],
    savedPages: [],
    links: [],
    attachments: [],
    richContent: {
      access_blocked: {
        interaction_id: 'sig-access-1:access_blocked:msg-access-manager',
        state: 'pending',
        page_id: '019a0000-0000-7000-8000-000000000001',
        page_title: 'Q4 Strategy',
        agent_uid: 'research',
        agent_name: 'Research Colleague',
        grant_target_uid: 'research',
        target_name: 'Research Colleague',
        can_grant: true,
        already_granted: false,
        explain: {
          page_id: '019a0000-0000-7000-8000-000000000001',
          subject_uid: 'research',
          subject_name: 'Research Colleague',
          authority_uid: 'research',
          action: 'node_view',
          allowed: false,
          effective_role: null,
          decision_reason: 'Inheritance is turned off on this page and @research has no explicit grant.',
          stages: [
            { id: 'subject_resolution', status: 'pass', summary: 'Evaluated as AI Colleague @research.' },
            { id: 'space_and_trash_gate', status: 'pass', summary: 'Active Space page.' },
            { id: 'acl_anchor_chain', status: 'fail', summary: 'No matching grant on restricted anchor.' },
            { id: 'brain_disclosure_gate', status: 'skip', summary: 'Skipped after ACL denial.' }
          ]
        }
      }
    }
  } as unknown as TimelineMessage

  const viewerMessage = {
    ...managerMessage,
    id: 'msg-access-viewer',
    text: 'I need view access to a restricted page to continue.',
    richContent: {
      access_blocked: {
        interaction_id: 'sig-access-2:access_blocked:msg-access-viewer',
        state: 'pending',
        page_id: '019a0000-0000-7000-8000-000000000002',
        page_title: null,
        agent_uid: 'research',
        agent_name: 'Research Colleague',
        grant_target_uid: 'research',
        target_name: 'Research Colleague',
        can_grant: false,
        already_granted: false,
        explain: null
      }
    }
  } as unknown as TimelineMessage

  const router = createRouter({
    routeTree: createRootRoute(),
    history: createMemoryHistory({ initialEntries: ['/'] })
  })

  try {
    const managerHtml = render(
      <QueryClientProvider client={client}>
        <RouterContextProvider router={router}>
          <MessageView
            model={model}
            conversationID="conv-1"
            linkedRuns={[]}
            onJumpToSource={() => {}}
            keyboardActive={false}
            own={false}
            message={managerMessage}
            showActions
          />
        </RouterContextProvider>
      </QueryClientProvider>
    )
    expect(managerHtml).toContain('chat-page-access-card')
    expect(managerHtml).toContain('Q4 Strategy')
    expect(managerHtml).toContain('Grant View &amp; Continue')
    expect(managerHtml).toContain('Why access was blocked (4 stages)')
    expect(managerHtml).toContain('access-waterfall')
    expect(managerHtml).toContain('No matching grant on restricted anchor.')

    const viewerHtml = render(
      <QueryClientProvider client={client}>
        <RouterContextProvider router={router}>
          <MessageView
            model={model}
            conversationID="conv-1"
            linkedRuns={[]}
            onJumpToSource={() => {}}
            keyboardActive={false}
            own={false}
            message={viewerMessage}
            showActions
          />
        </RouterContextProvider>
      </QueryClientProvider>
    )
    expect(viewerHtml).toContain('Restricted page')
    expect(viewerHtml).toContain('Waiting for a page manager to grant view access.')
    expect(viewerHtml).not.toContain('Grant View &amp; Continue')
    expect(viewerHtml).not.toContain('Q4 Strategy')
  } finally {
    client.clear()
  }
})

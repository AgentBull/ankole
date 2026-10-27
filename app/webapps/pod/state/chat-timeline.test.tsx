import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
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
  activitySteps,
  interleavedReplySources,
  placeLinkedExecutions,
  uncommittedStreams,
  timelineEventLabel,
  timelineTurns,
  unloadedPendingQuestions
} from '../chat/turn-timeline'
import { ToolRunView, commandDetails, formatToolDetail, humanizeToolName } from '../chat/tool-run-view'
import { MessageActions } from '../chat/message-actions'
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
      input: { page: 'Q4' }
    },
    {
      id: 'query',
      tool: 'pod.base.query',
      title: 'Queried Tasks (18 rows)',
      status: 'completed',
      duration_ms: 340,
      output: { count: 18 }
    }
  ]
}

test('a persisted execution restores all tool details inside a collapsed completed turn', () => {
  const html = render(<CollapsedWorkView execution={JSON.parse(JSON.stringify(execution))} />)
  expect(html).toContain('<details class="pod-chat-work">')
  expect(html).not.toContain('<details class="pod-chat-work" open')
  expect(html).toContain('Worked for 4.2s · 2 tools')
  expect(html).not.toContain('pod-chat-work-content')
  const expanded = render(<CollapsedWorkView execution={JSON.parse(JSON.stringify(execution))} attention />)
  expect(expanded).toContain('Check the page structure')
  expect(expanded).toContain('Read page Q4 Roadmap')
  expect(expanded).toContain('Queried Tasks (18 rows)')
  expect(expanded).toContain('&quot;count&quot;: 18')
})

test('active, failed, stopped and pending-decision work stays expanded', () => {
  for (const props of [
    { active: true, execution: { ...execution, steps: [{ ...execution.steps![0]!, status: 'running' }] } },
    { attention: true },
    { execution: { ...execution, status: 'stopped' } },
    { execution: { ...execution, steps: [{ ...execution.steps![0]!, status: 'failed' }] } }
  ]) {
    const html = renderToStaticMarkup(<CollapsedWorkView execution={execution} {...props} />)
    expect(html).toContain('<details class="pod-chat-work" open="">')
  }
})

test('live thinking uses one collapsed disclosure with its timer and keeps the complete text available when opened', () => {
  const thinking = { thinking_summary: 'Complete recorded reasoning text', steps: [] }
  const collapsed = render(<CollapsedWorkView execution={thinking} active />)
  expect(collapsed).toContain('<details class="pod-chat-work pod-chat-thinking">')
  expect(collapsed.match(/>Thinking</g)).toHaveLength(1)
  expect(collapsed).not.toContain('Complete recorded reasoning text')
  const opened = render(<CollapsedWorkView execution={thinking} active attention />)
  expect(opened.match(/>Thinking</g)).toHaveLength(1)
  expect(opened).toContain('Complete recorded reasoning text')
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
  expect(waiting).not.toContain('<details')

  const completed = render(<CollapsedWorkView phaseLabel="Waiting for computer capacity" execution={execution} />)
  expect(completed).toContain('Worked for 4.2s · 2 tools')
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
  expect(parallel).toContain('2 tool calls')
  expect(parallel.match(/Searching source material/g)).toHaveLength(1)
  expect(parallel).not.toContain('pod-chat-tool-group')
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
  expect(html).toContain('3 tool calls')
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
  const structured = { ...command, output: { stderr: 'Permission denied', exit_code: 2 } }
  expect(commandDetails(structured)).toMatchObject({ stdout: undefined, stderr: 'Permission denied', exitCode: 2 })
  const failed = render(<ToolRunView steps={[{ ...structured, status: 'failed' }]} />)
  expect(failed).toContain('Exit 2')
  expect(failed).toContain('pod-chat-command-stderr')
  expect(failed).not.toContain('&quot;stderr&quot;')
  expect(commandDetails({ ...command, input: '{"command":' })).toBeUndefined()
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
      text={'| Name | Count |\n| --- | --- |\n| Tasks | 18 |\n\n$x^2$\n\n```html\n<script>alert(1)</script>\n```'}
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
          input: {},
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

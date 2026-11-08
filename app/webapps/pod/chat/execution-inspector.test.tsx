import { afterEach, beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../../common/i18n'
import { podKeys } from '../api'
import { PodPanelPresence } from '../panel-motion'
import { ActivityView, CollapsedWorkView } from './collapsed-work-view'
import { ExecutionInspectorPanel } from './execution-inspector-panel'
import { buildNarrativeSegments, executionItemToStep, shouldShowOutcomeSummary } from './execution-narrative'
import { LinkedExecutionCard, cleanExecutionPreview } from './linked-execution-card'
import { ToolRunView, formatToolDetail } from './tool-run-view'
import {
  collapseExecutionChains,
  filterPromotedExecutionSteps,
  isExecutionActive,
  placeLinkedExecutions
} from './timeline-projections'
import type { ConversationExecutionDetail, ConversationExecutionItem, ExecutionStep, LinkedExecution } from './types'

const render = (element: Parameters<typeof renderToStaticMarkup>[0]) => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderToStaticMarkup(<QueryClientProvider client={client}>{element}</QueryClientProvider>).replace(
    /[\u2066-\u2069]/g,
    ''
  )
}

beforeAll(async () => {
  await Promise.all(['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'].map(locale => loadLocale(locale)))
})

afterEach(async () => {
  await i18n.changeLanguage('en-US')
})

test('skill_view and SKILL.md steps render as non-expandable semantic badges across locales without leaking prompts', async () => {
  const skillStep: ExecutionStep = {
    id: 'skill-1',
    tool: 'skill_view',
    toolKind: 'skill',
    title: 'Load skill: pod-content',
    skill_name: 'pod-content',
    status: 'completed',
    input: '{"name":"pod-content"}',
    output: '[{"text":"<skill name=\\"pod-content\\">Secret system prompt</skill>"}]'
  }
  const readSkillStep: ExecutionStep = {
    id: 'skill-2',
    tool: 'read_file',
    title: 'Read file: /drive/Skills/deep-research/SKILL.md',
    status: 'completed',
    input: { path: '/drive/Skills/deep-research/SKILL.md' },
    output: '# Internal SKILL.md instructions'
  }

  await i18n.changeLanguage('zh-Hans-CN')
  const zhHtml = render(<ToolRunView steps={[skillStep, readSkillStep]} />)
  expect(zhHtml).toContain('已加载技能 · pod-content')
  expect(zhHtml).toContain('已加载技能 · deep-research')
  expect(zhHtml).not.toContain('<details')
  expect(zhHtml).not.toContain('Secret system prompt')
  expect(zhHtml).not.toContain('Internal SKILL.md instructions')
  expect(zhHtml).not.toContain('pod-chat-tool-code')

  const liveHtml = render(
    <ActivityView
      activity={{
        conversationID: 'conv-1',
        agentUID: 'assistant',
        sessionID: 'conversation:conv-1',
        signalID: 'sig-1',
        responseID: 'resp-1',
        epoch: 1,
        revision: 1,
        state: 'active',
        tools: [
          {
            operation_id: 'call_skill_1',
            tool: 'skill_view',
            label: 'Skill view',
            label_bindings: { name: 'pod-content' },
            phase: 'running'
          }
        ]
      }}
    />
  )
  expect(liveHtml).toContain('已加载技能 · pod-content')
  expect(liveHtml).not.toContain('Skill view')

  await i18n.changeLanguage('en-US')
  const enHtml = render(<ToolRunView steps={[skillStep]} />)
  expect(enHtml).toContain('Loaded skill · pod-content')
  expect(enHtml).not.toContain('<details')
})

test('write_file, edit_file, and failed SKILL.md steps keep full expandable error details instead of masquerading as loaded skills', async () => {
  const failedWriteSkill: ExecutionStep = {
    id: 'write-fail',
    tool: 'write_file',
    title: 'Write file: /drive/Skills/custom/SKILL.md',
    status: 'failed',
    input: { path: '/drive/Skills/custom/SKILL.md', content: '# Draft' },
    output: 'Error: Read-only filesystem'
  }
  const failedReadSkill: ExecutionStep = {
    id: 'read-fail',
    tool: 'read_file',
    title: 'Read file: /drive/Skills/missing/SKILL.md',
    status: 'failed',
    input: { path: '/drive/Skills/missing/SKILL.md' },
    output: 'ENOENT: no such file or directory'
  }
  const editSkill: ExecutionStep = {
    id: 'edit-ok',
    tool: 'edit_file',
    title: 'Edit file: /drive/Skills/custom/SKILL.md',
    status: 'completed',
    input: { path: '/drive/Skills/custom/SKILL.md' },
    output: 'Updated 1 block'
  }

  await i18n.changeLanguage('zh-Hans-CN')
  const zhHtml = render(<ToolRunView steps={[failedWriteSkill, failedReadSkill, editSkill]} />)
  expect(zhHtml).not.toContain('已加载技能')
  expect(zhHtml).toContain('Error: Read-only filesystem')
  expect(zhHtml).toContain('ENOENT: no such file or directory')
  expect(zhHtml).toContain('Updated 1 block')
  expect((zhHtml.match(/<details/g) ?? []).length).toBe(3)
})

test('ToolRunView renders structured fileChange diffs and formatToolDetail suppresses empty JSON noise', () => {
  expect(formatToolDetail('{}')).toBeUndefined()
  expect(formatToolDetail('[]')).toBeUndefined()
  expect(formatToolDetail({})).toBeUndefined()
  expect(formatToolDetail('"<skill name=\\"x\\">secret</skill>"')).toBeUndefined()
  expect(formatToolDetail('[{"type":"input_text","text":"Hello world"}]')).toBe('Hello world')

  const patchStep: ExecutionStep = {
    id: 'patch-1',
    tool: 'apply_patch',
    toolKind: 'patch',
    title: 'Edit 1 file',
    status: 'completed',
    files: [
      {
        path: 'src/waitlist.ts',
        kind: 'update',
        diff: '@@ -1,2 +1,3 @@\n const list = []\n-export default list\n+export function addEmail(email: string) {\n+  return list.push(email)\n+}'
      }
    ]
  }

  const html = render(<ToolRunView steps={[patchStep]} />)
  expect(html).toContain('src/waitlist.ts')
  expect(html).toContain('+3')
  expect(html).toContain('−1')
  expect(html).toContain('export function addEmail')
})

test('filterPromotedExecutionSteps hides duplicate launch tool rows while preserving skills and failed launches', () => {
  const steps: ExecutionStep[] = [
    { id: 's1', tool: 'skill_view', skill_name: 'pod-content', title: 'Load skill: pod-content', status: 'completed' },
    { id: 'call-job', tool: 'create_background_job', title: 'Create background job: Waitlist', status: 'completed' },
    { id: 'call-wf', tool: 'workflow', title: 'Run workflow: Sync', status: 'completed' },
    { id: 'call-fail', tool: 'create_background_job', title: 'Create background job: Broken', status: 'failed' }
  ]
  const runs: LinkedExecution[] = [
    {
      id: '101',
      kind: 'background_agent_job',
      agentUID: 'assistant',
      title: 'Waitlist',
      status: 'running',
      sourceToolCallID: 'call-job',
      createdAt: '2026-11-05T03:49:00Z',
      updatedAt: '2026-11-05T03:50:00Z'
    },
    {
      id: '202',
      kind: 'workflow',
      agentUID: 'assistant',
      title: 'Sync',
      status: 'running',
      sourceToolCallID: 'call-wf',
      createdAt: '2026-11-05T03:49:00Z',
      updatedAt: '2026-11-05T03:50:00Z'
    }
  ]

  const filtered = filterPromotedExecutionSteps(steps, runs)
  expect(filtered.map(step => step.id)).toEqual(['s1', 'call-fail'])

  const collapsedHtml = render(<CollapsedWorkView execution={{ duration_ms: 1200, steps: filtered }} attention />)
  expect(collapsedHtml).toContain('Loaded skill · pod-content')
  expect(collapsedHtml).not.toContain('Create background job: Waitlist')
})

test('collapseExecutionChains folds respawn continuations onto the latest card while inheriting timeline anchors', () => {
  const first: LinkedExecution = {
    id: '10',
    kind: 'background_agent_job',
    agentUID: 'assistant',
    title: 'Build waitlist',
    status: 'completed',
    sourceSignalID: 'sig-origin',
    sourceMessageID: 'msg-human',
    sourceToolCallID: 'call-10',
    successorJobID: '11',
    createdAt: '2026-11-05T03:00:00Z',
    updatedAt: '2026-11-05T03:05:00Z'
  }
  const second: LinkedExecution = {
    id: '11',
    kind: 'background_agent_job',
    agentUID: 'assistant',
    title: 'Build waitlist',
    status: 'running',
    continuedFromJobID: '10',
    createdAt: '2026-11-05T03:06:00Z',
    updatedAt: '2026-11-05T03:07:00Z'
  }

  const collapsed = collapseExecutionChains([first, second])
  expect(collapsed).toHaveLength(1)
  expect(collapsed[0]?.id).toBe('11')
  expect(collapsed[0]?.sourceSignalID).toBe('sig-origin')
  expect(collapsed[0]?.sourceMessageID).toBe('msg-human')
  expect(collapsed[0]?.chainIDs).toEqual(['11', '10'])
  expect(
    isExecutionActive(
      { type: 'execution', kind: 'background_agent_job', runID: '10', title: 'Build waitlist' },
      collapsed[0]!
    )
  ).toBe(true)

  const placement = placeLinkedExecutions(
    [{ id: 'msg-agent', kind: 'message', authorType: 'agent', signalID: 'sig-origin', richContent: {} }],
    [],
    [first, second]
  )
  expect(placement.messages.get('msg-agent')?.map(run => run.id)).toEqual(['11'])
})

test('LinkedExecutionCard renders a single status mark, suppresses redundant agent names and {} previews, and shows progress + Stop', async () => {
  expect(cleanExecutionPreview('{}')).toBeUndefined()
  expect(cleanExecutionPreview('```json\n{}\n```')).toBeUndefined()
  expect(cleanExecutionPreview('### Progress\nCreated **waitlist** table')).toBe('Progress Created waitlist table')

  await i18n.changeLanguage('zh-Hans-CN')
  const run: LinkedExecution = {
    id: '42',
    kind: 'background_agent_job',
    title: 'Build waitlist management app',
    status: 'running',
    agentUID: 'assistant',
    agentName: '助理 (丁立的助理)',
    stoppable: true,
    stepCount: 5,
    planCompleted: 2,
    planTotal: 4,
    summary: '已创建多维表，正在配置 Webhook Automation Job。',
    createdAt: '2026-11-05T03:49:00Z',
    startedAt: '2026-11-05T03:49:01Z',
    updatedAt: '2026-11-05T03:52:41Z'
  }

  const html = render(<LinkedExecutionCard run={run} conversationID="conv-1" showAgentName={false} isActive />)
  expect(html).toContain('Build waitlist management app')
  expect(html).not.toContain('助理 (丁立的助理)')
  expect(html).toContain('运行中 · 计划 2/4')
  expect(html).toContain('已创建多维表，正在配置 Webhook Automation Job。')
  expect(html).toContain('停止')
  // Exactly one spinning loader mark on the card (no duplicate right-hand spinner).
  expect((html.match(/pod-chat-working-spinner/g) ?? []).length).toBe(1)

  const groupHtml = render(<LinkedExecutionCard run={run} conversationID="conv-1" showAgentName />)
  expect(groupHtml).toContain('助理 (丁立的助理) · 运行中 · 计划 2/4')
})

test('buildNarrativeSegments and shouldShowOutcomeSummary organize prose, steer messages, and collapsible tool groups cleanly', () => {
  const items: ConversationExecutionItem[] = [
    { id: 'r1', kind: 'reasoning', text: 'Inspect existing tables first.' },
    {
      id: 't1',
      kind: 'tool',
      tool: 'skill_view',
      toolKind: 'skill',
      skillName: 'pod-content',
      title: 'Load skill: pod-content',
      status: 'completed'
    },
    {
      id: 't2',
      kind: 'tool',
      tool: 'command',
      toolKind: 'command',
      title: 'Run command: ankole-pod base.schema',
      status: 'completed',
      command: { command: 'ankole-pod base.schema', exitCode: 0, output: 'email: text' }
    },
    { id: 'm1', kind: 'message', text: 'Checked existing schema; creating Automation Job next.', phase: 'commentary' },
    { id: 's1', kind: 'steer_message', text: 'Also normalize email to lowercase.' },
    {
      id: 't3',
      kind: 'tool',
      tool: 'apply_patch',
      toolKind: 'patch',
      title: 'Edit 1 file',
      status: 'in_progress'
    }
  ]

  const liveSegments = buildNarrativeSegments(items, true)
  expect(liveSegments.map(seg => seg.kind)).toEqual(['work_group', 'message', 'steer', 'work_group'])
  if (liveSegments[0]?.kind === 'work_group') {
    expect(liveSegments[0].defaultOpen).toBe(false)
    expect(liveSegments[0].steps).toHaveLength(2)
    expect(liveSegments[0].reasoning).toEqual(['Inspect existing tables first.'])
  }
  if (liveSegments[3]?.kind === 'work_group') {
    expect(liveSegments[3].defaultOpen).toBe(true)
  }

  const cmdStep = executionItemToStep(items[2]!)
  expect(cmdStep.input).toEqual({ command: 'ankole-pod base.schema', workdir: undefined })

  expect(shouldShowOutcomeSummary('{}', items)).toBe(false)
  expect(shouldShowOutcomeSummary('[]', items)).toBe(false)
  expect(shouldShowOutcomeSummary('Checked existing schema; creating Automation Job next.', items.slice(0, 4))).toBe(
    false
  )
  expect(shouldShowOutcomeSummary('Waitlist app and webhook deployed.', items)).toBe(true)
})

test('ExecutionInspectorPanel renders completed Workflow outcomeText even when the Workflow made zero agent calls', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const workflowDetail: ConversationExecutionDetail = {
    id: '77',
    kind: 'workflow',
    title: 'Reconcile invoices',
    agentUID: 'assistant',
    status: 'completed',
    task: null,
    createdAt: '2026-11-05T03:00:00Z',
    startedAt: '2026-11-05T03:00:01Z',
    completedAt: '2026-11-05T03:00:04Z',
    updatedAt: '2026-11-05T03:00:04Z',
    stoppable: false,
    canMessage: false,
    continuedFromJobID: null,
    successorJobID: null,
    outcomeText: 'Reconciled **42** supplier invoices with zero discrepancies.',
    errorText: null,
    stepCount: 0,
    pendingQuestions: [],
    plan: null,
    threads: [],
    workflowCounts: {
      total: 0,
      completed: 0,
      running: 0,
      queued: 0,
      sleeping: 0,
      failed: 0
    },
    items: [],
    nextCursor: null
  }

  client.setQueryData([...podKeys.detail('conv-1'), 'execution', 'workflow', '77'], {
    pages: [workflowDetail],
    pageParams: [null]
  })

  try {
    await i18n.changeLanguage('en-US')
    const html = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <PodPanelPresence animate={false}>
          <ExecutionInspectorPanel
            conversationID="conv-1"
            target={{ type: 'execution', kind: 'workflow', runID: '77', title: 'Reconcile invoices' }}
            onClose={() => {}}
            onSwitchTarget={() => {}}
          />
        </PodPanelPresence>
      </QueryClientProvider>
    ).replace(/[\u2066-\u2069]/g, '')

    expect(html).toContain('pod-chat-inspector-outcome')
    expect(html).toContain('Reconciled')
    expect(html).toContain('supplier invoices with zero discrepancies.')
    expect(html).not.toContain(i18n.getFixedT('en-US')('pod.chat_timeline.no_execution_steps'))
  } finally {
    client.clear()
  }
})

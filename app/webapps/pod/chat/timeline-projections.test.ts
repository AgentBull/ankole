import { describe, expect, test } from 'bun:test'
import type { ConversationMessage } from '../api'
import type { DisplayMessage } from '../state/chat'
import {
  collapseExecutionChains,
  continuesPrevious,
  filterPromotedExecutionSteps,
  interleavedReplySources,
  isExecutionActive,
  isPeerActive,
  placeLinkedExecutions,
  resolveCommittedMessageEditState,
  timelineTurns,
  uncommittedStreams,
  unloadedPendingQuestions
} from './timeline-projections'

function makeMessage(overrides: Partial<ConversationMessage> & Pick<ConversationMessage, 'id'>): ConversationMessage {
  return {
    id: overrides.id,
    seq: overrides.seq ?? 1,
    authorType: overrides.authorType ?? 'human',
    authorUID: overrides.authorUID ?? 'alice',
    authorDisplayName: overrides.authorDisplayName ?? 'Alice',
    authorArchived: overrides.authorArchived ?? false,
    kind: overrides.kind ?? 'message',
    text: overrides.text ?? 'Hello',
    createdAt: overrides.createdAt ?? '2026-11-08T00:00:00Z',
    signalID: overrides.signalID ?? null,
    replyToMessageID: overrides.replyToMessageID ?? null,
    mentions: overrides.mentions ?? [],
    links: overrides.links ?? [],
    attachments: overrides.attachments ?? [],
    savedPages: overrides.savedPages ?? []
  }
}

describe('timeline-projections', () => {
  test('continuesPrevious groups same-author committed messages within five minutes unless interleaved reply source exists', () => {
    const first: DisplayMessage = {
      type: 'committed',
      message: makeMessage({ id: 'm1', createdAt: '2026-11-08T00:00:00Z' })
    }
    const withinWindow: DisplayMessage = {
      type: 'committed',
      message: makeMessage({ id: 'm2', createdAt: '2026-11-08T00:04:59Z' })
    }
    const outsideWindow: DisplayMessage = {
      type: 'committed',
      message: makeMessage({ id: 'm3', createdAt: '2026-11-08T00:05:00Z' })
    }

    expect(continuesPrevious(first, withinWindow, false)).toBe(true)
    expect(continuesPrevious(first, withinWindow, true)).toBe(false)
    expect(continuesPrevious(first, outsideWindow, false)).toBe(false)
  })

  test('resolveCommittedMessageEditState combines permission, disabled reason, inline edit target, and backtrack focus', () => {
    const turn1 = makeMessage({ id: 'turn-1', authorUID: 'alice' })
    const turn2 = makeMessage({ id: 'turn-2', authorUID: 'alice' })

    // Falls back to latestInput when actions.canEdit is omitted
    expect(
      resolveCommittedMessageEditState({
        message: turn2,
        actions: { edit: () => {}, editDisabledReason: 'Agent archived' },
        latestInput: { messageID: 'turn-2', authorUID: 'alice', agentUIDs: ['assistant'] },
        viewerUID: 'alice',
        activeEditTarget: { kind: 'last', messageID: 'turn-2' },
        hasInlineEditContext: true,
        backtrackID: 'turn-2'
      })
    ).toEqual({
      canEdit: true,
      editDisabledReason: 'Agent archived',
      editingInline: true,
      backtrackActive: true
    })

    // Queue edits stay in the composer rather than opening the inline timeline editor
    expect(
      resolveCommittedMessageEditState({
        message: turn1,
        actions: {
          canEdit: msg => msg.id === 'turn-1',
          edit: () => {},
          editDisabledReasonFor: msg => (msg.id === 'turn-1' ? undefined : 'Superseded')
        },
        viewerUID: 'alice',
        activeEditTarget: { kind: 'queue', messageID: 'turn-1' },
        hasInlineEditContext: true,
        backtrackID: 'turn-2'
      })
    ).toEqual({
      canEdit: true,
      editDisabledReason: undefined,
      editingInline: false,
      backtrackActive: false
    })
  })

  test('uncommittedStreams, timelineTurns, interleavedReplySources, and unloadedPendingQuestions project turn structure', () => {
    const h1 = makeMessage({ id: 'h1', text: 'First question' })
    const h2 = makeMessage({ id: 'h2', text: 'Second question', authorUID: 'bob', authorDisplayName: 'Bob' })
    const a1 = makeMessage({
      id: 'a1',
      authorType: 'agent',
      authorUID: 'assistant',
      authorDisplayName: 'Assistant',
      text: 'Answer to first',
      signalID: 'sig-1',
      replyToMessageID: 'h1'
    })

    expect(
      uncommittedStreams(
        [h1, a1],
        [
          {
            agentUID: 'assistant',
            agentName: 'Assistant',
            responseID: 'r1',
            signalIDs: ['sig-1'],
            text: 'done',
            thinkingSummary: ''
          },
          {
            agentUID: 'researcher',
            agentName: 'Researcher',
            responseID: 'r2',
            signalIDs: ['sig-2'],
            text: 'live',
            thinkingSummary: ''
          }
        ]
      ).map(s => s.agentUID)
    ).toEqual(['researcher'])

    expect(timelineTurns([h1, h2, a1])).toEqual([
      { id: 'h1', text: 'First question', preview: 'Answer to first' },
      { id: 'h2', text: 'Second question' }
    ])

    const sources = interleavedReplySources([h1, h2, a1])
    expect(sources.get('a1')?.id).toBe('h1')

    expect(
      unloadedPendingQuestions(
        [
          {
            interaction_id: 'i-loaded',
            tool_call_id: 'tc-1',
            messageID: 'a1',
            agentUID: 'assistant',
            state: 'pending',
            question: 'Loaded?',
            choices: [],
            allow_free_text: true
          },
          {
            interaction_id: 'i-unloaded',
            tool_call_id: 'tc-2',
            messageID: 'a-missing',
            agentUID: 'assistant',
            state: 'pending',
            question: 'Unloaded?',
            choices: [],
            allow_free_text: true
          }
        ],
        [h1, a1]
      ).map(item => item.interaction_id)
    ).toEqual(['i-unloaded'])
  })

  test('collapseExecutionChains, filterPromotedExecutionSteps, placeLinkedExecutions, and inspector active checks', () => {
    const job1 = {
      kind: 'background_agent_job' as const,
      id: 'job-1',
      agentUID: 'assistant',
      title: 'Step 1',
      status: 'completed' as const,
      createdAt: '2026-11-08T00:00:01Z',
      updatedAt: '2026-11-08T00:00:02Z',
      sourceSignalID: 'sig-1',
      sourceMessageID: 'h1',
      sourceToolCallID: 'call-1',
      successorJobID: 'job-2'
    }
    const job2 = {
      kind: 'background_agent_job' as const,
      id: 'job-2',
      agentUID: 'assistant',
      title: 'Step 2',
      status: 'running' as const,
      createdAt: '2026-11-08T00:00:03Z',
      updatedAt: '2026-11-08T00:00:04Z',
      continuedFromJobID: 'job-1'
    }

    const collapsed = collapseExecutionChains([job1, job2])
    expect(collapsed).toHaveLength(1)
    expect(collapsed[0]!.id).toBe('job-2')
    expect(collapsed[0]!.chainIDs).toEqual(['job-2', 'job-1'])
    expect(collapsed[0]!.sourceSignalID).toBe('sig-1')

    expect(isExecutionActive({ type: 'execution', kind: 'background_agent_job', runID: 'job-1' }, collapsed[0]!)).toBe(
      true
    )
    expect(isPeerActive({ type: 'peer', exchangeID: 'ex-1', agentUID: 'assistant' }, 'ex-1')).toBe(true)

    expect(
      filterPromotedExecutionSteps(
        [
          { id: 'call-1', tool: 'create_background_job', title: 'Start job', status: 'completed' },
          { id: 'call-2', tool: 'read_file', title: 'Read', status: 'completed' },
          { id: 'call-3', tool: 'create_background_job', title: 'Failed job', status: 'failed' }
        ],
        collapsed
      ).map(step => step.id)
    ).toEqual(['call-2', 'call-3'])

    const placement = placeLinkedExecutions(
      [makeMessage({ id: 'h1' }), makeMessage({ id: 'a1', authorType: 'agent', signalID: 'sig-1' })],
      [],
      [job1, job2]
    )
    expect(placement.messages.get('a1')?.map(run => run.id)).toEqual(['job-2'])
  })
})

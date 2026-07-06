import { describe, expect, it } from 'bun:test'
import type { JsonObject, TurnStart } from '../src/lanes/actor_lane'
import { createMemoryTools } from '../src/tools/memory/memory-tools'

describe('memory tools', () => {
  it('describes memory_note as proactive current-channel memory management', () => {
    const memoryNote = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRpc: async (): Promise<JsonObject> => ({ status: 'ok' })
    }).find(tool => tool.name === 'memory_note')

    expect(memoryNote?.description).toContain('current channel only')
    expect(memoryNote?.description).toContain('Use action=list when the user asks what you remember')
    expect(memoryNote?.description).toContain('Save proactively when the user states a preference')
    expect(memoryNote?.description).toContain('The best memory stops the user repeating themselves')
    expect(memoryNote?.description).toContain('Skip trivial or obvious info')
    expect(memoryNote?.description).toContain('confirm in the visible reply exactly what changed')
  })
})

function turnStartForMemoryTool(): TurnStart {
  return {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      queue_sequence: 1,
      type: 'im.message.addressed',
      source_event_id: 'source-1',
      binding_name: 'mock',
      signal_channel_id: 'mock:chat:memory',
      provider_thread_id: 'thread-1',
      source_entry_id: 'entry-1',
      payload_json: {}
    }
  }
}

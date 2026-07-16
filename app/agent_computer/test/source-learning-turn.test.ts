import { createHash } from 'node:crypto'
import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnStart } from '../src/lanes/actor_lane'
import { createBrainSourceLearningReader, createSourceLearningTurnTools } from '../src/tools/brain/source-learning-turn'

const workspaces: string[] = []

afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(path => rm(path, { recursive: true, force: true })))
})

describe('source learning turn toolset', () => {
  test('exposes exactly the snapshot reader plus the Brain read/write tools', async () => {
    const { workspace, turnStart } = await sourceWorkspace('short source')
    const learning = createSourceLearningTurnTools({
      turnStart,
      workspaceRoot: workspace,
      requestMemoryRPC: async (): Promise<JSONObject> => ({ status: 'ok' })
    })

    expect(learning.tools.map(tool => tool.name)).toEqual([
      'source_read',
      'memory_search',
      'memory_open',
      'memory_update',
      'memory_browse'
    ])
    const update = learning.tools.find(tool => tool.name === 'memory_update')!
    expect(update.description).toContain('the exact marker src:brain-source:source-1')
    expect(update.isDestructive).toBe(true)
  })

  test('requires the Brain memory RPC seam instead of degrading to a read-only run', async () => {
    const { workspace, turnStart } = await sourceWorkspace('short source')

    expect(() => createSourceLearningTurnTools({ turnStart, workspaceRoot: workspace })).toThrow(
      'source learning turn requires the Brain memory RPC seam'
    )
  })

  test('gates memory_update on complete reading and fails an unfinished turn', async () => {
    const { workspace, turnStart } = await sourceWorkspace('short source')
    let rpcCalls = 0
    const learning = createSourceLearningTurnTools({
      turnStart,
      workspaceRoot: workspace,
      requestMemoryRPC: async (): Promise<JSONObject> => {
        rpcCalls += 1
        return { status: 'updated' }
      }
    })
    const toolNamed = (name: string) => learning.tools.find(tool => tool.name === name)!
    const updateParams = {
      operation: 'create_entry',
      name: 'Learned page',
      type: 'topic',
      initial_body: 'Claim from the source. src:brain-source:source-1'
    }

    await expect(toolNamed('memory_update').execute('call-blocked', updateParams)).rejects.toThrow(
      'memory_update is unavailable until source_read reports complete=true'
    )
    expect(rpcCalls).toBe(0)
    expect(() => learning.assertCompleted()).toThrow('ended before source_read reported complete=true')

    const page = await toolNamed('source_read').execute('call-read', {})
    expect(page.details.complete).toBe(true)

    await toolNamed('memory_update').execute('call-write', updateParams)
    expect(rpcCalls).toBe(1)
    expect(() => learning.assertCompleted()).not.toThrow()
  })
})

describe('brain source learning reader', () => {
  test('byte-verifies the source and paginates a long line without dropping characters', async () => {
    const content = `first:${'x'.repeat(60_000)}:last`
    const { workspace, turnStart } = await sourceWorkspace(content)
    const reader = createBrainSourceLearningReader(turnStart, workspace)

    expect(() => reader.assertReadyToWrite()).toThrow('memory_update is unavailable')
    const first = await reader.tool.execute('call-1', reader.tool.schema.parse({ path: '/workspace/other' }))
    expect(first.details.complete).toBe(false)
    expect(first.details.nextCursor).toBeString()
    expect(first.content[0]?.type === 'text' && first.content[0].text.startsWith('first:')).toBe(true)
    expect(() => reader.assertReadyToWrite()).toThrow('memory_update is unavailable')

    await expect(
      reader.tool.execute('call-skip', {
        cursor: Buffer.from(`v1:${content.length - 1}`, 'utf8').toString('base64url')
      })
    ).rejects.toThrow('exact cursor returned by the previous page')
    expect(() => reader.assertReadyToWrite()).toThrow('memory_update is unavailable')

    const second = await reader.tool.execute('call-2', reader.tool.schema.parse({ cursor: first.details.nextCursor }))
    expect(second.details).toEqual({
      complete: true,
      documentID: 'brain-source:source-1',
      totalCharacters: content.length
    })
    expect(second.content[0]?.type === 'text' && second.content[0].text.includes(':last')).toBe(true)
    expect(() => reader.assertReadyToWrite()).not.toThrow()
    expect(() => reader.assertCompleted()).not.toThrow()
  })

  test('fails closed when the run-local bytes do not match the immutable descriptor', async () => {
    const { workspace, turnStart } = await sourceWorkspace('actual bytes')
    const source = turnStart.actor_event.payload_json?.data
    if (source && typeof source === 'object' && !Array.isArray(source)) {
      const descriptor = (source as Record<string, unknown>).retained_source
      if (descriptor && typeof descriptor === 'object' && !Array.isArray(descriptor)) {
        ;(descriptor as Record<string, unknown>).sha256 = '0'.repeat(64)
      }
    }
    const reader = createBrainSourceLearningReader(turnStart, workspace)

    await expect(reader.tool.execute('call-1', {})).rejects.toThrow('SHA-256 mismatch')
    expect(() => reader.assertCompleted()).toThrow('failed while reading')
  })

  test('rejects a learning event without a complete source descriptor', () => {
    const invalid = turnStartFor(Buffer.from('source'))
    invalid.actor_event.payload_json = {}

    expect(() => createBrainSourceLearningReader(invalid, '/tmp')).toThrow(
      'brain source learning event is missing its immutable source descriptor'
    )
  })
})

async function sourceWorkspace(content: string) {
  const bytes = Buffer.from(content)
  const workspace = await mkdtemp(join(tmpdir(), 'ankole-brain-source-'))
  workspaces.push(workspace)
  await mkdir(join(workspace, 'source'))
  await writeFile(join(workspace, 'source', 'manual.md'), bytes)
  return { workspace, turnStart: turnStartFor(bytes) }
}

function turnStartFor(bytes: Buffer): TurnStart {
  const actorEventID = '00000000-0000-0000-0000-000000000123'

  return {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'source-session' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: actorEventID,
      revision: 0
    },
    actor_event: {
      actor_event_id: actorEventID,
      queue_sequence: 1,
      type: 'brain.source.learn',
      source_event_id: 'source-learning-1',
      source_entry_id: 'brain-source:source-1',
      payload_json: {
        data: {
          retained_source: {
            byte_size: bytes.byteLength,
            document_id: 'brain-source:source-1',
            media_type: 'text/markdown',
            path: '/workspace/source/manual.md',
            sha256: createHash('sha256').update(bytes).digest('hex'),
            title: 'Manual'
          }
        }
      }
    }
  }
}

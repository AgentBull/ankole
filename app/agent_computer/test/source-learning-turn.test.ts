import { createHash } from 'node:crypto'
import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
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
    const { agentHome, workspace, turnStart } = await sourceWorkspace('short source')
    const learning = createSourceLearningTurnTools({
      turnStart,
      agentHome,
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
    expect(update.description).toContain('the exact marker src:source_1')
    expect(update.description).not.toContain('brain-source:source-1')
    expect(update.isDestructive).toBe(true)
    for (const tool of learning.tools) {
      expect(tool.description).not.toContain('The long-term memory system (codename Brain)')
    }
  })

  test('gates memory_update on complete reading and fails an unfinished turn', async () => {
    const { agentHome, workspace, turnStart } = await sourceWorkspace('short source')
    const rpcPayloads: JSONObject[] = []
    const learning = createSourceLearningTurnTools({
      turnStart,
      agentHome,
      workspaceRoot: workspace,
      requestMemoryRPC: async (_method, payload): Promise<JSONObject> => {
        rpcPayloads.push(payload as JSONObject)
        return { status: 'updated' }
      }
    })
    const toolNamed = (name: string) => learning.tools.find(tool => tool.name === name)!
    const updateParams = {
      operation: 'create_entry',
      name: 'Learned page',
      type: 'topic',
      initial_body: 'Claim from the source. src:source_1'
    }

    await expect(toolNamed('memory_update').execute('call-blocked', updateParams)).rejects.toThrow(
      'memory_update is unavailable until source_read reports complete=true'
    )
    expect(rpcPayloads).toHaveLength(0)
    expect(() => learning.assertCompleted()).toThrow('ended before source_read reported complete=true')

    const page = await toolNamed('source_read').execute('call-read', {})
    expect(page.details.complete).toBe(true)

    await toolNamed('memory_update').execute('call-write', updateParams)
    expect(rpcPayloads).toHaveLength(1)
    expect(rpcPayloads[0]).toMatchObject({
      operation: {
        case: 'createEntry',
        value: { initialBody: 'Claim from the source. src:brain-source:source-1' }
      }
    })
    expect(() => learning.assertCompleted()).not.toThrow()
  })
})

describe('brain source learning reader', () => {
  test('byte-verifies the source and paginates a long line without dropping characters', async () => {
    const content = `first:${'x'.repeat(60_000)}:last`
    const { agentHome, workspace, turnStart } = await sourceWorkspace(content)
    const reader = createBrainSourceLearningReader(turnStart, agentHome, workspace)

    expect(() => reader.assertReadyToWrite()).toThrow('memory_update is unavailable')
    expect(reader.tool.schema.safeParse({ path: '/agents/agent-1/other' }).success).toBe(false)
    expect(reader.tool.schema.safeParse({ cursor: 'opaque' }).success).toBe(false)
    const first = await reader.tool.execute('call-1', {})
    expect(first.details.complete).toBe(false)
    expect(first.content[0]?.type === 'text' && first.content[0].text.startsWith('first:')).toBe(true)
    expect(first.content[0]?.type === 'text' && first.content[0].text.includes('cursor=')).toBe(false)
    expect(() => reader.assertReadyToWrite()).toThrow('memory_update is unavailable')

    const second = await reader.tool.execute('call-2', {})
    expect(second.details).toEqual({
      complete: true,
      source: 'source_1',
      totalCharacters: content.length
    })
    expect(second.content[0]?.type === 'text' && second.content[0].text.includes(':last')).toBe(true)
    expect(() => reader.assertReadyToWrite()).not.toThrow()
    expect(() => reader.assertCompleted()).not.toThrow()
  })

  test('fails closed when the run-local bytes do not match the immutable descriptor', async () => {
    const { agentHome, workspace, turnStart } = await sourceWorkspace('actual bytes')
    const source = turnStart.actor_event.payload_json?.data
    if (source && typeof source === 'object' && !Array.isArray(source)) {
      const descriptor = (source as Record<string, unknown>).retained_source
      if (descriptor && typeof descriptor === 'object' && !Array.isArray(descriptor)) {
        ;(descriptor as Record<string, unknown>).sha256 = '0'.repeat(64)
      }
    }
    const reader = createBrainSourceLearningReader(turnStart, agentHome, workspace)

    await expect(reader.tool.execute('call-1', {})).rejects.toThrow('SHA-256 mismatch')
    expect(() => reader.assertCompleted()).toThrow('failed while reading')
  })

  test('rejects a retained source symlink that resolves outside the learning workspace', async () => {
    const bytes = Buffer.from('outside source')
    const root = await mkdtemp(join(tmpdir(), 'ankole-brain-source-symlink-'))
    workspaces.push(root)
    const agentHome = join(root, 'agent-1')
    const workspace = join(agentHome, 'sessions', 'session-1')
    const outsidePath = join(root, 'outside.md')
    await mkdir(join(workspace, 'source'), { recursive: true })
    await writeFile(outsidePath, bytes)
    await symlink(outsidePath, join(workspace, 'source', 'manual.md'))
    const reader = createBrainSourceLearningReader(
      turnStartFor(bytes, join(workspace, 'source', 'manual.md')),
      agentHome,
      workspace
    )

    await expect(reader.tool.execute('call-1', {})).rejects.toThrow(
      'retained source path resolves outside workspace roots'
    )
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
  const root = await mkdtemp(join(tmpdir(), 'ankole-brain-source-'))
  workspaces.push(root)
  const agentHome = join(root, 'agent-1')
  const workspace = join(agentHome, 'sessions', 'session-1')
  await mkdir(join(workspace, 'source'), { recursive: true })
  const path = join(workspace, 'source', 'manual.md')
  await writeFile(path, bytes)
  return { agentHome, workspace, turnStart: turnStartFor(bytes, path) }
}

function turnStartFor(bytes: Buffer, path = '/agents/agent-1/sessions/session-1/source/manual.md'): TurnStart {
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
            path,
            sha256: createHash('sha256').update(bytes).digest('hex'),
            title: 'Manual'
          }
        }
      }
    }
  }
}

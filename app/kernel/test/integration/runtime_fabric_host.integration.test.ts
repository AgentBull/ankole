import { describe, expect, it } from 'bun:test'
import { fileURLToPath } from 'node:url'
import {
  connectRuntimeFabric,
  type RuntimeFabricEnvelope,
  type RuntimeFabricHost
} from '../../../agent_computer/src/fabric/fabric'

describe('RuntimeFabric native host adapter integration', () => {
  it('classifies real native envelope and multipart receives and owns dealer stop', async () => {
    const endpointPath = `/tmp/ankole-runtime-fabric-napi-peer-${crypto.randomUUID()}.endpoint`
    const kernelRoot = fileURLToPath(new URL('../..', import.meta.url))
    const peer = Bun.spawn(
      [
        'cargo',
        'run',
        '--quiet',
        '--example',
        'runtime_fabric_napi_peer',
        '--no-default-features',
        '--features',
        'napi',
        '--',
        endpointPath
      ],
      {
        cwd: kernelRoot,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe'
      }
    )
    let fabric: RuntimeFabricHost | undefined

    try {
      const endpoint = await waitForFixtureEndpoint(endpointPath)
      fabric = connectRuntimeFabric({
        endpoint,
        workerId: 'worker-binding-roundtrip',
        workerAuthKey: 'binding-secret'
      })
      await fabric.sendEnvelope(testEnvelope('worker-binding-roundtrip'))

      expect(await fabric.receive(2_000)).toMatchObject({
        kind: 'envelope',
        envelope: { message_id: 'binding-roundtrip-envelope' }
      })
      const fileOutcome = await fabric.receive(2_000)
      expect(fileOutcome.kind).toBe('worker_file')
      if (fileOutcome.kind === 'worker_file') {
        expect(fileOutcome.frames.map(frame => frame.toString())).toEqual([
          'ANKOLE_FILE/1',
          'READ_OPEN',
          'binding-transfer'
        ])
      }

      peer.stdin.write('stop\n')
      peer.stdin.end()
      expect(await peer.exited).toBe(0)

      fabric.stop()
      fabric.stop()
      expect(await fabric.sendEnvelope(testEnvelope('stopped-worker')).catch(caught => caught)).toMatchObject({
        code: 'socket_closed'
      })
    } finally {
      fabric?.stop()
      peer.kill()
      await Bun.file(endpointPath)
        .delete()
        .catch(() => undefined)
    }
  }, 30_000)
})

function testEnvelope(workerId: string): RuntimeFabricEnvelope {
  return {
    protocol_version: 1,
    message_id: `worker-ready-${workerId}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_ready',
      worker_ready: {
        worker_id: workerId,
        runtime: 'bun',
        version: 'test',
        capacity_json: { available_turn_slots: 1 }
      }
    }
  }
}

async function waitForFixtureEndpoint(path: string): Promise<string> {
  for (let attempt = 0; attempt < 1_200; attempt += 1) {
    const endpoint = Bun.file(path)
    if (await endpoint.exists()) {
      const value = (await endpoint.text()).trim()
      if (value.length > 0) return value
    }
    await Bun.sleep(25)
  }

  throw new Error('timed out waiting for RuntimeFabric native test peer')
}

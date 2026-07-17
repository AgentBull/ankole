import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import type { BrowserMaterial, BrowserRequest } from '../src/protocol'
import { ActiveBrowserLimiter } from '../src/daemon/active-browser-limiter'
import { SessionActor } from '../src/daemon/session-actor'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('session actor lifecycle', () => {
  test('purge clears retained material and evicts the disposable actor', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-actor-')
    roots.push(root)
    const material = localMaterial(root)
    let disposed: SessionActor | undefined
    const actor = new SessionActor('br_1234567890abcdef', 'default', new ActiveBrowserLimiter(1), candidate => {
      disposed = candidate
    })

    const result = await actor.dispatch(request(material, { name: 'lifecycle', args: { verb: 'purge' } }))

    expect(result.data).toEqual({ purged: true })
    expect(disposed).toBe(actor)
  })
})

function localMaterial(root: string): BrowserMaterial {
  return {
    protocol_version: 1,
    route_id: 'br_1234567890abcdef',
    data_root: join(root, 'data'),
    artifact_root: join(root, 'artifacts'),
    immutable_fingerprint: 'sha256:test',
    material_generation: 0,
    profile: { mode: 'persistent_user_data_dir' },
    backend: { kind: 'local_chromium', executable: '/bin/false', args: [] },
    navigation: { ssrf_filter: true, allow_file_urls: false },
    idle_ttl_ms: 60_000
  }
}

function request(material: BrowserMaterial, command: BrowserRequest['command']): BrowserRequest {
  return {
    v: 1,
    id: 'req-test',
    route: material.route_id,
    session: 'default',
    material,
    deadline_unix_ms: Date.now() + 1_000,
    command
  }
}

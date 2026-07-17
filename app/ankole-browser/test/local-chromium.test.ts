import { afterEach, describe, expect, test } from 'bun:test'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { connectLocalChromium } from '../src/browser/local-chromium'
import type { BrowserMaterial } from '../src/protocol'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('local Chromium ownership', () => {
  test('terminates the detached process when CDP attach fails', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-local-')
    roots.push(root)
    const executable = join(root, 'fake-chromium.sh')
    await writeFile(
      executable,
      [
        '#!/bin/sh',
        'printf \'%s\\n\' "$$" > fake.pid',
        "printf '%s\\n' 'DevTools listening on ws://127.0.0.1:1/devtools/browser/fake' >&2",
        'exec sleep 60',
        ''
      ].join('\n')
    )
    await chmod(executable, 0o755)
    const material = localMaterial(root, executable)

    await expect(connectLocalChromium(material, 'default')).rejects.toBeInstanceOf(Error)

    const pid = Number(await readFile(join(root, 'data', 'sessions', 'default', 'fake.pid'), 'utf8'))
    expect(processAlive(pid)).toBe(false)
  }, 5_000)
})

function localMaterial(root: string, executable: string): BrowserMaterial {
  return {
    protocol_version: 1,
    route_id: 'br_1234567890abcdef',
    data_root: join(root, 'data'),
    artifact_root: join(root, 'artifacts'),
    immutable_fingerprint: 'sha256:test',
    material_generation: 0,
    profile: { mode: 'persistent_user_data_dir' },
    backend: { kind: 'local_chromium', executable, args: [] },
    navigation: { ssrf_filter: true, allow_file_urls: false },
    idle_ttl_ms: 60_000
  }
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

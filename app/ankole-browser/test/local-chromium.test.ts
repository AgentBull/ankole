import { spawn } from 'node:child_process'
import { afterEach, describe, expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { connectLocalChromium, purgeDetachedLocalChromium } from '../src/browser/local-chromium'
import type { BrowserMaterial } from '../src/protocol'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('local Chromium ownership', () => {
  test('unreachable persisted CDP preserves the profile and never signals an unrelated live PID', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-pid-')
    roots.push(root)
    const child = spawn('/bin/sleep', ['30'], { stdio: 'ignore' })
    await new Promise<void>((resolve, reject) => {
      child.once('spawn', resolve)
      child.once('error', reject)
    })
    let exited = false
    child.once('exit', () => {
      exited = true
    })
    const material = localMaterial(root, '/bin/false')
    const session = join(material.data_root, 'sessions/default')
    const profile = join(session, 'profile')
    const metadata = JSON.stringify({
      pid: child.pid,
      endpoint: 'ws://127.0.0.1:1/devtools/browser/old',
      profile_dir: profile,
      started_at: '2000-01-01T00:00:00Z'
    })
    try {
      await mkdir(profile, { recursive: true })
      await writeFile(join(profile, 'keep.txt'), 'user data')
      await writeFile(join(session, 'live.json'), metadata)
      await expect(purgeDetachedLocalChromium(material, 'default')).rejects.toMatchObject({
        code: 'backend_unavailable'
      })
      expect(exited).toBe(false)
      expect(await readFile(join(session, 'live.json'), 'utf8')).toBe(metadata)
      expect(await readFile(join(profile, 'keep.txt'), 'utf8')).toBe('user data')
    } finally {
      child.kill('SIGKILL')
      if (!exited) await new Promise(resolve => child.once('exit', resolve))
    }
  })

  test('a missing Chromium executable fails without waiting for an exit from a process that never spawned', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-spawn-')
    roots.push(root)
    await expect(
      connectLocalChromium(localMaterial(root, join(root, 'missing-chromium')), 'default')
    ).rejects.toBeInstanceOf(Error)
  }, 5_000)

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

import { strict as assert } from 'node:assert'
import { existsSync } from 'node:fs'
import { mkdir, readFile, symlink } from 'node:fs/promises'
import type { DriveView } from '../../../src/drive/mounts'
const runtime = '/repo/app/agent_computer/src'
const { driveMounts } = await import(`${runtime}/drive/mounts.ts`)
const { linkMountedSkills } = await import(`${runtime}/skills/knowledge-skills.ts`)
const { resolveScopedDrivePath } = await import(`${runtime}/drive/paths.ts`)
const { materializeCodexConfig } = await import(`${runtime}/core/codex-runner/runtime/agent-home-config.ts`)
const { codexAppServerSpec } = await import(`${runtime}/core/codex-runner/runtime/app-server-spec.ts`)
const { AgentCodexRuntimeManager } = await import(`${runtime}/core/codex-runner/runtime/agent-runtime-manager.ts`)

const configs = await Bun.file('/test-config/views.json').json()
const views: DriveView[] = []
async function command(view: DriveView, script: string) {
  const child = Bun.spawn(
    view.launcher([
      '/usr/bin/setpriv',
      '--reuid=1000',
      '--regid=1000',
      '--clear-groups',
      '--inh-caps=-all',
      '--ambient-caps=-all',
      '--bounding-set=-all',
      '--no-new-privs',
      'bash',
      '-c',
      script
    ]),
    { cwd: '/tmp', stdout: 'pipe', stderr: 'pipe' }
  )
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited
  ])
  assert.equal(code, 0, err + out)
  return out.trim()
}
try {
  for (const config of configs) views.push((await driveMounts.acquire(config))!)
  const [first, second] = views
  assert.equal(first.scope.path, second.scope.path)
  assert.equal(first.library.path, second.library.path)
  assert.notEqual(first.chat?.path, second.chat?.path)
  const start = await first.sequence()
  assert.equal(
    await command(
      first,
      `set -eu
    test "$(id -u)" = 1000
    grep -q 'CapEff:.*0000000000000000' /proc/self/status
    test ! -r /run/ankole/rclone.sock
    test "$(/drive/Skills/fuse-check/scripts/run.sh)" = meta-capability
    test -r /drive/AGENTS.md
    test ! -w /drive/AGENTS.md
    test ! -w /drive/Skills/fuse-check/SKILL.md
    printf shared > /drive/AgentDrive/manager-shared.txt
    mkdir -p /drive/ChatDrive/reports
    printf report > /drive/ChatDrive/reports/report.txt
    printf first > /drive/ChatDrive/marker.txt
    printf conversation-rules > /drive/ChatDrive/AGENTS.md
    printf conversation-design > /drive/ChatDrive/DESIGN.md
    mkdir /drive/ChatDrive/Skills
    printf conversation-skill > /drive/ChatDrive/Skills/local.txt
    mkdir /drive/ChatDrive/empty
    rmdir /drive/ChatDrive/empty
    cat /drive/AgentDrive/manager-shared.txt`
    ),
    'shared'
  )
  assert.equal(await first.flush(start), '')
  assert.match(await first.flushPath('/drive/ChatDrive/reports/report.txt'), /^[0-9a-f-]{36}$/)
  assert.equal(await command(first, 'cat /drive/ChatDrive/AGENTS.md'), 'conversation-rules')
  assert.equal(await command(first, 'cat /drive/ChatDrive/DESIGN.md'), 'conversation-design')
  assert.equal(await command(first, 'cat /drive/ChatDrive/Skills/local.txt'), 'conversation-skill')
  assert.equal(
    await command(second, 'test ! -e /drive/ChatDrive/marker.txt; cat /drive/AgentDrive/manager-shared.txt'),
    'shared'
  )
  const secondStart = await second.sequence()
  await command(second, 'printf second > /drive/ChatDrive/marker.txt')
  assert.equal(await second.flush(secondStart), '')
  assert.equal(await command(first, 'cat /drive/ChatDrive/marker.txt'), 'first')
  assert.equal(await command(second, 'cat /drive/ChatDrive/marker.txt'), 'second')
  await mkdir('/workspace', { recursive: true })
  const turnSkills = '/workspace/.ankole/turn-skills/mounted-test'
  const unlinkSkills = await linkMountedSkills(turnSkills)
  assert.equal(await command(first, `${turnSkills}/fuse-check/scripts/run.sh`), 'meta-capability')
  await unlinkSkills()
  assert.equal(existsSync(turnSkills), false)
  assert.equal(await command(first, '/drive/Skills/fuse-check/scripts/run.sh'), 'meta-capability')
  await symlink('/drive/ChatDrive/marker.txt', '/workspace/chat-link')
  assert.equal(await readFile(await resolveScopedDrivePath(first, '/workspace/chat-link'), 'utf8'), 'first')
  assert.equal(await readFile(await resolveScopedDrivePath(second, '/workspace/chat-link'), 'utf8'), 'second')
  const ids = await driveMounts.flushPaths(
    first.key,
    ['/workspace/chat-link'],
    '/workspace',
    AbortSignal.timeout(10_000)
  )
  assert.match(ids[0], /^[0-9a-f-]{36}$/)
  await driveMounts.resume()
  assert.equal(await command(first, 'cat /drive/ChatDrive/marker.txt'), 'first')
  const manager = new AgentCodexRuntimeManager()
  const leases = []
  try {
    for (const view of views) {
      const config = materializeCodexConfig({ agentHomeRoot: '/workspace', viewKey: view.key })
      leases.push(
        await manager.acquire({
          ...config,
          agentUID: 'test-agent',
          driveView: view,
          aiGatewayBaseURL: 'http://127.0.0.1:1/api/v1/ai-gateway',
          aiGatewayAPIKey: 'local-initialize-only',
          appServer: codexAppServerSpec(config)
        })
      )
    }
    assert.equal(manager.activeRuntimeCount(), 2)
    assert.notEqual(leases[0].runtime.client.processID, leases[1].runtime.client.processID)
  } finally {
    await Promise.all(leases.map(lease => lease.release()))
  }
  assert.equal(manager.activeRuntimeCount(), 0)
  let ticks = 0
  const heartbeat = setInterval(() => ticks++, 100)
  try {
    assert.equal(
      await readFile(await resolveScopedDrivePath(first, '/drive/AgentDrive/slow-read.txt'), 'utf8'),
      'slow bytes'
    )
    assert(ticks >= 50, `10-second DAV read blocked the supervisor event loop: ${ticks} timer ticks`)
  } finally {
    clearInterval(heartbeat)
  }
  if (process.env.ANKOLE_VFS_STRESS === '1') {
    const batchStart = await first.sequence()
    await command(
      first,
      `python3 - <<'PY'
import pathlib
root=pathlib.Path('/drive/AgentDrive/many-small-files')
root.mkdir()
for i in range(20000): (root/f'{i}.txt').write_text(f'file {i}\\n')
PY`
    )
    assert.match(await first.flush(batchStart), /background/)
    const smallStart = await second.sequence()
    const started = performance.now()
    await command(second, 'printf "# Delivery\\n\\nready\\n" > /drive/AgentDrive/delivery._adoc.md')
    assert.equal(await second.flush(smallStart), '')
    const flushMs = performance.now() - started
    const deliveryStart = performance.now()
    assert.match(await second.flushPath('/drive/AgentDrive/delivery._adoc.md'), /^[0-9a-f-]{36}$/)
    const deliveryMs = performance.now() - deliveryStart
    await Bun.write('/test-config/stress-ready', JSON.stringify({ flushMs, deliveryMs }))
    while (!(await Bun.file('/test-config/stress-done').exists())) await Bun.sleep(50)
    assert(flushMs < 500, `foreground flush took ${flushMs} ms`)
    assert(deliveryMs < 500, `attachment flush took ${deliveryMs} ms`)
    console.warn(`20,000-file queue: foreground flush ${flushMs.toFixed(1)} ms, attachment ${deliveryMs.toFixed(1)} ms`)
  }
  console.warn(
    'Shared cache, distinct ChatDrives, uid/capability drop, scoped symlink resolution, delivery IDs and token refresh passed'
  )
} finally {
  await Promise.all(views.map(view => view.release()))
  await driveMounts.drain()
  await driveMounts.stop()
}

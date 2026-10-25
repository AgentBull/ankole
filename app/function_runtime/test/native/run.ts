import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'

type Snapshot = {
  runtime: { activeUserWorkersCount: number }
  process: Record<string, string>
  thread_ids: string[]
}
type NativeEvent = {
  event_type: string
  event: { reason?: string; cpu_time_used?: number; msg?: string }
  metadata?: { service_path?: string }
}

const image = process.env.ANKOLE_FUNCTION_RUNTIME_TEST_IMAGE || 'ankole-function-runtime:dev'
const container = `ankole-native-test-${process.pid}-${crypto.randomUUID().slice(0, 8)}`
const runtimeRoot = resolve(import.meta.dir, '../..')
const output =
  process.env.ANKOLE_FUNCTION_RUNTIME_NATIVE_ARTIFACTS || mkdtempSync(`${tmpdir()}/ankole-function-native-`)
mkdirSync(output, { recursive: true })
const reports: object[] = []
let base = ''

async function docker(...args: string[]) {
  const child = Bun.spawn(['docker', ...args], { stdout: 'pipe', stderr: 'pipe' })
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited
  ])
  assert.equal(status, 0, `docker ${args.join(' ')} failed: ${stderr}`)
  return (args[0] === 'logs' ? `${stdout}\n${stderr}` : stdout).trim()
}
function record(label: string, value: object) {
  reports.push({ label, ...value })
  writeFileSync(resolve(output, 'report.json'), JSON.stringify(reports, null, 2))
  process.stdout.write(`${label}\n`)
}
async function snapshot(): Promise<Snapshot> {
  return (await (await fetch(`${base}/snapshot`)).json()) as Snapshot
}
async function post(path: string, value: unknown) {
  const response = await fetch(base + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(value),
    signal: AbortSignal.timeout(180000)
  })
  assert.equal(response.status, 200, `HTTP ${response.status}: ${await response.clone().text()}`)
  return (await response.json()) as Record<string, unknown>
}
async function retired(label: string, before: Snapshot, timeoutMs: number, createdThreads: string[] = []) {
  const started = performance.now()
  while (true) {
    const current = await snapshot()
    if (
      current.runtime.activeUserWorkersCount === before.runtime.activeUserWorkersCount &&
      createdThreads.every(tid => !current.thread_ids.includes(tid))
    ) {
      record(label, { elapsed_wall_ms: performance.now() - started, snapshot: current })
      return current
    }
    assert(
      performance.now() - started < timeoutMs,
      `${label}: worker or thread did not retire: ${JSON.stringify(current)}`
    )
    await Bun.sleep(50)
  }
}
async function warm(key: string, lifetimeMs: number, retirement = false) {
  let ws: WebSocket | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await new Promise<void>((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Warm invocation did not settle')), 30000)
      const runId = crypto.randomUUID()
      ws = new WebSocket(
        `${base.replace(/^http/, 'ws')}/warm?key=${key}&lifetime_ms=${lifetimeMs}${retirement ? '&retirement=1' : ''}`
      )
      const socket = ws
      socket.onclose = () => reject(new Error('Warm invocation closed before done'))
      socket.onerror = reject
      socket.onopen = () =>
        socket.send(JSON.stringify({ type: 'start', run_id: runId, context: { method: 'POST', path: '/' } }))
      socket.onmessage = event => {
        const frame = JSON.parse(String(event.data))
        if (frame.type !== 'done') return
        try {
          assert.equal(frame.outcome.status, 200)
          assert.equal(frame.outcome.body, 1)
          resolve()
        } catch (error) {
          reject(error)
        }
      }
    })
  } finally {
    clearTimeout(timer)
    ws?.close()
  }
}
async function retireWarmWorker() {
  const before = await snapshot()
  const key = `retire-${crypto.randomUUID()}`
  let ws: WebSocket | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  let replaced: Snapshot | undefined
  try {
    await new Promise<void>((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Retired worker invocation did not settle')), 10000)
      const runId = crypto.randomUUID()
      ws = new WebSocket(`${base.replace(/^http/, 'ws')}/warm?key=${key}&lifetime_ms=5000&retirement=1`)
      const socket = ws
      socket.onclose = () => reject(new Error('Retired worker invocation closed before done'))
      socket.onerror = reject
      socket.onopen = () =>
        socket.send(
          JSON.stringify({ type: 'start', run_id: runId, context: { method: 'POST', path: '/', body: { hold: true } } })
        )
      socket.onmessage = async event => {
        try {
          const frame = JSON.parse(String(event.data))
          if (frame.type === 'call') {
            assert.equal(frame.operation, 'db.query')
            assert.equal((await post('/retire', { key })).retired, true)
            await warm(key, 5000, true)
            replaced = await snapshot()
            assert.equal(replaced.runtime.activeUserWorkersCount - before.runtime.activeUserWorkersCount, 2)
            socket.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value: 'released' }))
          }
          if (frame.type === 'done') {
            assert(replaced, 'Old invocation must remain pending until a fresh worker completes')
            assert.equal(frame.outcome.status, 200)
            assert.equal(frame.outcome.body, 1)
            record('retire-warm-worker-preserves-inflight', { before, replaced, old_outcome: frame.outcome })
            resolve()
          }
        } catch (error) {
          reject(error)
        }
      }
    })
  } finally {
    clearTimeout(timer)
    ws?.close()
  }
  assert(replaced)
  const created = replaced.thread_ids.filter(tid => !before.thread_ids.includes(tid))
  await retired('retire-warm-worker-both-retired', before, 10000, created)
}
async function physicalCancel() {
  const before = await snapshot()
  const abort = new AbortController()
  const result = fetch(`${base}/ptc-cancel`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ program: 'while(true){}', tools: [], memo: [], timeout_ms: 30000 }),
    signal: abort.signal
  })
    .then(response => response.text())
    .catch(error => String(error))
  let running = before
  const started = performance.now()
  while (running.runtime.activeUserWorkersCount === before.runtime.activeUserWorkersCount) {
    assert(performance.now() - started < 5000, 'PTC did not start')
    await Bun.sleep(10)
    running = await snapshot()
  }
  const candidates = running.thread_ids.filter(tid => !before.thread_ids.includes(tid))
  const clock = async () =>
    (await (await fetch(`${base}/thread-cpu?candidates=${candidates.join(',')}`)).json()) as {
      samples: Record<string, number>
    }
  const first = await clock()
  await Bun.sleep(200)
  const second = await clock()
  const executing = candidates.filter(tid => second.samples[tid]! > first.samples[tid]!)
  assert(executing.length > 0, 'PTC must execute CPU work before caller cancellation')
  abort.abort()
  await result
  record('ptc-caller-cancel', { before, running, first, second, executing_threads: executing })
  await retired('ptc-caller-cancel-retired', before, 2000, executing)
}
async function drain() {
  let ws: WebSocket | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await new Promise<void>((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Draining invocation did not settle')), 30000)
      const runId = crypto.randomUUID()
      ws = new WebSocket(`${base.replace(/^http/, 'ws')}/warm?key=drain-${runId}&lifetime_ms=300000&capability=1`)
      const socket = ws
      socket.onclose = () => reject(new Error('Draining invocation closed before done'))
      socket.onerror = reject
      socket.onopen = () =>
        socket.send(JSON.stringify({ type: 'start', run_id: runId, context: { method: 'POST', path: '/' } }))
      socket.onmessage = async event => {
        try {
          const frame = JSON.parse(String(event.data))
          if (frame.type === 'call') {
            assert.equal(frame.operation, 'db.query')
            await docker('kill', '--signal', 'TERM', container)
            await Bun.sleep(100)
            let accepts = false
            try {
              accepts = (await fetch(`${base}/health`, { signal: AbortSignal.timeout(250) })).ok
            } catch {}
            assert.equal(accepts, false, 'draining runtime must stop admitting requests')
            socket.send(JSON.stringify({ type: 'reply', call_id: frame.call_id, value: 'settled' }))
          }
          if (frame.type === 'done') {
            assert.equal(frame.outcome.status, 200)
            assert.equal(frame.outcome.body, 'settled')
            record('sigterm-existing-call-settled', frame.outcome)
            resolve()
          }
        } catch (error) {
          reject(error)
        }
      }
    })
  } finally {
    clearTimeout(timer)
    ws?.close()
  }
  await docker('wait', container)
  assert.equal(await docker('inspect', container, '--format', '{{.State.OOMKilled}}'), 'false')
}

try {
  await docker(
    'run',
    '--detach',
    '--name',
    container,
    '--memory',
    '2g',
    '--publish',
    '127.0.0.1::9000',
    '--volume',
    `${runtimeRoot}:/opt/ankole/function_runtime:ro`,
    image,
    'start',
    '--main-service',
    '/opt/ankole/function_runtime/test/native',
    '--event-worker',
    '/opt/ankole/function_runtime/test/native/events',
    '--port',
    '9000'
  )
  base = `http://${await docker('port', container, '9000/tcp')}`
  let ready = false
  for (let attempt = 0; attempt < 300; attempt++) {
    try {
      ready = (await fetch(`${base}/health`)).ok
    } catch {}
    if (ready) break
    await Bun.sleep(100)
  }
  assert(ready, 'native fixture failed to start')
  const clockTicks = Number(await docker('exec', container, 'getconf', 'CLK_TCK'))
  const nativeCpus = Number(await docker('exec', container, 'nproc'))
  assert(Number.isInteger(clockTicks) && clockTicks > 0)
  record('setup', {
    image: await docker('inspect', container, '--format', '{{.Image}}'),
    clock_ticks: clockTicks,
    native_cpus: nativeCpus,
    baseline: await snapshot()
  })
  const initial = await snapshot()
  await post('/oneshots', { kind: 'inspect', count: 1 })
  await retired('prime-retired', initial, 5000)
  await retireWarmWorker()
  await physicalCancel()

  const cpuSpecs = [
    { name: 'continuous-soft10-hard15', soft_ms: 10000, hard_ms: 15000, yield_cpu_ms: 0 },
    { name: 'continuous-soft5-hard5', soft_ms: 5000, hard_ms: 5000, yield_cpu_ms: 0 },
    { name: 'yield-after8-checkpoints-soft10-hard15', soft_ms: 10000, hard_ms: 15000, yield_cpu_ms: 8000 }
  ]
  for (const spec of cpuSpecs) {
    const before = await snapshot()
    record(spec.name, await post('/cpu', { ...spec, clock_ticks: clockTicks }))
    await retired(`${spec.name}-retired`, before, 5000)
  }
  for (const kind of ['inspect', 'ptc']) {
    const before = await snapshot()
    for (let index = 0; index < 100; index++) await post('/oneshots', { kind, count: 1 })
    const after = await retired(`${kind}-100-retired`, before, 5000)
    assert(
      Number(after.process.Threads) <= Number(before.process.Threads) + nativeCpus,
      `${kind} retained a thread per completed worker`
    )
    record(`${kind}-100`, { before, after })
  }
  for (const count of [20, 100]) {
    const before = await snapshot()
    const lifetimeMs = count === 20 ? 12000 : 20000
    const prefix = `warm-${count}-${crypto.randomUUID()}`
    for (let index = 0; index < count; index++) await warm(`${prefix}-${index}`, lifetimeMs)
    const after = await snapshot()
    assert.equal(after.runtime.activeUserWorkersCount - before.runtime.activeUserWorkersCount, count)
    record(`warm-${count}`, {
      before,
      after,
      temporary_lifetime_ms: lifetimeMs,
      docker_stats: await docker('stats', '--no-stream', '--format', '{{json .}}', container)
    })
    const created = after.thread_ids.filter(tid => !before.thread_ids.includes(tid))
    await retired(`warm-${count}-retired`, before, lifetimeMs + 10000, created)
  }
  const logs = await docker('logs', '--timestamps', container)
  const events: NativeEvent[] = logs.split('\n').flatMap(line => {
    const marker = 'NATIVE_DIAGNOSTIC_EVENT '
    const index = line.indexOf(marker)
    return index < 0 ? [] : [JSON.parse(line.slice(index + marker.length)) as NativeEvent]
  })
  writeFileSync(resolve(output, 'native-events.json'), JSON.stringify(events, null, 2))
  for (const spec of cpuSpecs) {
    const terminal = events.find(
      event => event.event_type === 'Shutdown' && event.metadata?.service_path?.includes(spec.name)
    )
    assert(terminal, `${spec.name}: native Shutdown event missing`)
    assert.equal(terminal.event.reason, 'CPUTime')
    const used = terminal.event.cpu_time_used
    assert(typeof used === 'number')
    assert(
      used >= spec.hard_ms - 50 && used <= spec.hard_ms + 250,
      `${spec.name}: CPU ${used}ms outside budget ${spec.hard_ms}ms`
    )
    record(`${spec.name}-native-evidence`, { configured_hard_ms: spec.hard_ms, native_cpu_used_ms: used })
    if (spec.yield_cpu_ms > 0) {
      const phases = events.flatMap(event => {
        if (event.event_type !== 'Log' || !event.event.msg?.startsWith('{')) return []
        const value = JSON.parse(event.event.msg)
        return value.diagnostic === 'cpu' && value.label.startsWith(spec.name) ? [value] : []
      })
      const yielded = phases.find(phase => phase.phase === 'yield')
      const resumed = phases.find(phase => phase.phase === 'resume')
      assert(yielded && resumed, `${spec.name}: real yield and resume evidence missing`)
      assert(yielded.cpu_since_start_ms >= spec.yield_cpu_ms)
      assert(resumed.cpu_since_start_ms >= yielded.cpu_since_start_ms)
      assert(phases.indexOf(resumed) > phases.indexOf(yielded))
      record(`${spec.name}-yield-evidence`, { yielded, resumed })
    }
  }
  assert(
    events.some(
      event =>
        event.event_type === 'Shutdown' &&
        event.metadata?.service_path?.includes('ptc-cancel-') &&
        event.event.reason === 'EarlyDrop'
    )
  )
  await drain()
  process.stdout.write(`Native runtime checks passed. Artifacts: ${output}\n`)
} finally {
  const logs = await docker('logs', '--timestamps', container).catch(error => String(error))
  writeFileSync(resolve(output, 'native.log'), logs)
  await docker('rm', '--force', container).catch(() => {})
  process.stdout.write(`Native runtime artifacts: ${output}\n`)
}

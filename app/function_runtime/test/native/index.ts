import { buildAppletWorkerBootstrap } from '../../main/applet_bootstrap.ts'
import { buildPtcRunnerModule, type ProgramRequest } from '../../main/ptc_bootstrap.ts'

const basePermissions = {
  allow_all: false,
  allow_net: null,
  allow_read: null,
  allow_write: null,
  allow_env: null,
  allow_run: null,
  allow_ffi: null,
  allow_sys: null,
  allow_import: null
}
const warmWorkers = new Map<string, any>()

function processMemory() {
  const status = Deno.readTextFileSync('/proc/self/status')
  const smaps = Deno.readTextFileSync('/proc/self/smaps_rollup')
  const wanted = /^(Threads|VmRSS|VmSize|VmHWM|Rss|Pss|Private_Clean|Private_Dirty):\s+(.+)$/gm
  return Object.fromEntries(Array.from(`${status}\n${smaps}`.matchAll(wanted), match => [match[1], match[2]]))
}
async function snapshot() {
  return {
    timestamp: new Date().toISOString(),
    runtime: await EdgeRuntime.getRuntimeMetrics(),
    process: processMemory(),
    thread_ids: threadIds()
  }
}
function threadIds() {
  return Array.from(Deno.readDirSync('/proc/self/task'), entry => entry.name).sort()
}
function threadTicks(id: string) {
  if (!/^[0-9]+$/.test(id)) throw new Error('Expected a Linux TID')
  const text = Deno.readTextFileSync(`/proc/self/task/${id}/stat`)
  const fields = text
    .slice(text.lastIndexOf(')') + 2)
    .trim()
    .split(/\s+/)
  return Number(fields[11]) + Number(fields[12])
}
async function newThreads(previous: string[]) {
  for (let attempt = 0; attempt < 50; attempt++) {
    const added = threadIds().filter(id => !previous.includes(id))
    if (added.length > 0) return added
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error('No dedicated Worker TID appeared; do not fabricate thread CPU measurements')
}
function forward(request: Request) {
  const headers = new Headers(request.headers)
  headers.delete('content-length')
  headers.delete('accept-encoding')
  const forwarded = new Request(request.url, { method: request.method, headers })
  EdgeRuntime.applySupabaseTag(request, forwarded)
  return forwarded
}
async function create(label: string, code: string, options = {}) {
  const servicePath = `/tmp/native-diagnostic/${label}`
  Deno.mkdirSync(servicePath, { recursive: true })
  return await EdgeRuntime.userWorkers.create({
    servicePath,
    poolKey: label,
    maybeModuleCode: code,
    envVars: [],
    noNpm: true,
    allowRemoteModules: false,
    noModuleCache: false,
    memoryLimitMb: 64,
    workerTimeoutMs: 120000,
    cpuTimeSoftLimitMs: 10000,
    cpuTimeHardLimitMs: 15000,
    permissions: basePermissions,
    ...options
  })
}

function cpuWorker(label: string, clockTicks: number, yieldCpuMs: number) {
  return `
const label=${JSON.stringify(label)}, hz=${clockTicks}, yieldCpuMs=${yieldCpuMs};
Deno.serve(async request=>{
  let clockUrl=new URL(request.headers.get('x-native-diagnostic-cpu-url'));
  async function clock(){const response=await fetch(clockUrl);if(!response.ok)throw Error('Thread CPU clock unavailable');return await response.json();}
  const before=(await clock()).samples;
  let calibration=1;
  for(let i=0;i<100000000;i++)calibration=Math.imul(calibration^i,1664525)|0;
  const after=(await clock()).samples;
  const deltas=Object.entries(after).map(([tid,value])=>({tid,delta:value-before[tid]})).sort((a,b)=>b.delta-a.delta);
  if(!deltas.length || deltas[0].delta<=0 || deltas.length>1 && deltas[0].delta===deltas[1].delta)throw Error('CPU calibration did not identify an execution thread: '+JSON.stringify(deltas));
  const tid=deltas[0].tid,start=before[tid];
  clockUrl.search='';clockUrl.searchParams.set('tid',tid);
  console.log(JSON.stringify({diagnostic:'cpu-thread-calibration',label,tid,deltas,calibration}));
  async function ticks(){return (await clock()).ticks;}
  async function emit(phase,extra={}){const current=await ticks();console.log(JSON.stringify({diagnostic:'cpu',label,phase,ticks:current,cpu_since_start_ms:(current-start)*1000/hz,wall_ms:performance.now(),...extra}));return current;}
  await emit('start');
  if(yieldCpuMs>0){
    let value=1, current=start, checkpoints=0;
    while((current-start)*1000/hz<yieldCpuMs){
      for(let i=0;i<10000000;i++)value=Math.imul(value^i,1664525)|0;
      current=await ticks(); checkpoints++;
    }
    await emit('yield',{checkpoints,value});
    await new Promise(resolve=>setTimeout(resolve,100));
    await emit('resume');
  }
  while(true){}
});`
}

Deno.serve(async request => {
  const url = new URL(request.url)
  if (url.pathname === '/health') return Response.json({ ready: true })
  if (url.pathname === '/snapshot') return Response.json(await snapshot())
  if (url.pathname === '/thread-cpu') {
    const candidates = url.searchParams.get('candidates')
    if (candidates) {
      return Response.json({ samples: Object.fromEntries(candidates.split(',').map(tid => [tid, threadTicks(tid)])) })
    }
    return Response.json({ ticks: threadTicks(url.searchParams.get('tid') || '') })
  }
  if (url.pathname === '/cpu' && request.method === 'POST') {
    const input = (await request.json()) as {
      name: string
      clock_ticks: number
      yield_cpu_ms?: number
      soft_ms: number
      hard_ms: number
    }
    const label = `${input.name}-${crypto.randomUUID()}`
    const before = await snapshot()
    const started = performance.now()
    try {
      const previousThreads = threadIds()
      const worker = await create(label, cpuWorker(label, input.clock_ticks, input.yield_cpu_ms || 0), {
        forceCreate: true,
        cpuTimeSoftLimitMs: input.soft_ms,
        cpuTimeHardLimitMs: input.hard_ms,
        permissions: { ...basePermissions, allow_net: ['127.0.0.1:9000'] }
      })
      const candidates = await newThreads(previousThreads)
      const forwarded = forward(request)
      forwarded.headers.set(
        'x-native-diagnostic-cpu-url',
        `http://127.0.0.1:9000/thread-cpu?candidates=${candidates.join(',')}`
      )
      console.warn(JSON.stringify({ diagnostic: 'cpu-thread-candidates', label, candidates }))
      const response = await worker.fetch(forwarded)
      await response.arrayBuffer()
      return Response.json({
        label,
        unexpected_response: response.status,
        elapsed_wall_ms: performance.now() - started,
        before,
        after: await snapshot()
      })
    } catch (error) {
      return Response.json({
        label,
        worker_transport_error: String(error),
        elapsed_wall_ms: performance.now() - started,
        before,
        after: await snapshot()
      })
    }
  }
  if (url.pathname === '/ptc-cancel' && request.method === 'POST') {
    const payload = (await request.json()) as ProgramRequest
    const instance = await create(`ptc-cancel-${crypto.randomUUID()}`, buildPtcRunnerModule(payload), {
      forceCreate: true,
      context: { supervisor: { requestAbsentTimeoutMs: 0 } },
      memoryLimitMb: 256,
      workerTimeoutMs: 30000,
      cpuTimeSoftLimitMs: 30000,
      cpuTimeHardLimitMs: 30000
    })
    try {
      const response = await instance.fetch(forward(request), { signal: request.signal })
      const bytes = await response.arrayBuffer()
      return new Response(bytes, { status: response.status, headers: response.headers })
    } catch (error) {
      return Response.json({ error: String(error) })
    }
  }
  if (url.pathname === '/oneshots' && request.method === 'POST') {
    const input = (await request.json()) as { kind: 'inspect' | 'ptc'; count: number }
    const started = performance.now()
    for (let index = 0; index < input.count; index++) {
      const label = `${input.kind}-${crypto.randomUUID()}`
      const code =
        input.kind === 'inspect'
          ? buildAppletWorkerBootstrap('export default {"GET /":()=>1}', true)
          : buildPtcRunnerModule({ program: 'text("ok");', tools: [], memo: [] })
      const timeoutMs = input.kind === 'inspect' ? 5000 : 30000
      const worker = await create(label, code, {
        forceCreate: true,
        workerTimeoutMs: timeoutMs,
        cpuTimeSoftLimitMs: timeoutMs,
        cpuTimeHardLimitMs: timeoutMs,
        context: { supervisor: { requestAbsentTimeoutMs: 0 } },
        memoryLimitMb: input.kind === 'inspect' ? 64 : 256,
        permissions: input.kind === 'inspect' ? { ...basePermissions, allow_env: [] } : basePermissions
      })
      const response = await worker.fetch(forward(request))
      const output = (await response.json()) as { routes?: string[]; status?: string }
      if (
        response.status !== 200 ||
        (input.kind === 'inspect' ? output.routes?.[0] !== 'GET /' : output.status !== 'completed')
      ) {
        throw new Error(`Unexpected ${input.kind} result ${JSON.stringify(output)}`)
      }
    }
    return Response.json({ kind: input.kind, count: input.count, elapsed_wall_ms: performance.now() - started })
  }
  if (url.pathname === '/retire' && request.method === 'POST') {
    const { key } = (await request.json()) as { key: string }
    const worker = warmWorkers.get(key)
    if (!worker) return Response.json({ error: 'Unknown warm worker' }, { status: 404 })
    await worker.retire()
    warmWorkers.delete(key)
    return Response.json({ retired: true })
  }
  if (url.pathname === '/warm') {
    const key = url.searchParams.get('key')!
    const lifetimeMs = Number(url.searchParams.get('lifetime_ms'))
    let worker = warmWorkers.get(key)
    if (!worker) {
      worker = await create(
        key,
        buildAppletWorkerBootstrap(
          url.searchParams.has('retirement')
            ? 'let count=0;export default {"POST /":async r=>{const value=++count;if(r.body?.hold)await AnkoleRuntime.db.query("retire",{});return value}}'
            : url.searchParams.has('capability')
              ? 'export default {"POST /":()=>AnkoleRuntime.db.query("t")}'
              : 'export default {"POST /":()=>1}'
        ),
        { memoryLimitMb: 128, workerTimeoutMs: lifetimeMs, permissions: { ...basePermissions, allow_env: [] } }
      )
      warmWorkers.set(key, worker)
    }
    return await worker.fetch(forward(request))
  }
  return new Response('missing', { status: 404 })
})

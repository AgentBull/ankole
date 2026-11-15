type Tool = { namespace: string | null; name: string; global_name: string }
type Memo = { namespace?: string | null; name: string; arguments: unknown; output: unknown }
export type ProgramRequest = {
  program: string
  tools?: Tool[]
  memo?: Memo[]
  timeout_ms?: number
  max_pending_calls?: number
  max_pending_bytes?: number
  max_memo_bytes?: number
}

export function buildPtcRunnerModule(payload: ProgramRequest) {
  return `(${ptcWorker.toString()})(${JSON.stringify(payload)});`
}

function ptcWorker(request: ProgramRequest) {
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
  const serve = Deno.serve.bind(Deno)
  const channel = new MessageChannel()
  const stringify = JSON.stringify
  const parse = JSON.parse
  const encode = (value: unknown) => new TextEncoder().encode(stringify(value)).length
  const equal = (left: unknown, right: unknown): boolean => {
    if (left === right) return true
    if (
      !left ||
      !right ||
      typeof left !== 'object' ||
      typeof right !== 'object' ||
      Array.isArray(left) !== Array.isArray(right)
    ) {
      return false
    }
    const keys = Object.keys(left)
    return (
      keys.length === Object.keys(right).length &&
      keys.every(
        key =>
          Object.hasOwn(right, key) &&
          equal((left as Record<string, unknown>)[key], (right as Record<string, unknown>)[key])
      )
    )
  }
  const capped = (value: number | undefined, limit: number) => Math.min(value ?? limit, limit)
  const bounded = (value: number | undefined, fallback: number, limit: number) => Math.min(value ?? fallback, limit)
  const bindings = request.tools || []
  const memo = request.memo || []
  const output: { kind: string; value: string }[] = []
  const pending: { namespace: string | null; name: string; arguments: unknown }[] = []
  let failure: { error_code: string; error: string } | undefined
  let cursor = 0
  let activity = 0
  let outputBytes = 0
  let pendingBytes = 0
  let status = 'running'
  const fail = (code: string, message: string) => {
    failure ||= { error_code: code, error: message.slice(0, 16384) }
  }
  const tools: Record<string, (args?: unknown) => Promise<unknown>> = {}
  const identities = new Set<string>()
  let nameBytes = 0
  if (memo.length > 1024 || encode(memo) > capped(request.max_memo_bytes, 8 * 1024 * 1024)) {
    fail('program_memo_limit_exceeded', 'program memo exceeded the entry or byte limit')
  }
  if (bindings.length > 128) fail('program_tool_limit_exceeded', 'program tools exceeded 128 entries')
  for (const binding of bindings) {
    const identity = stringify([binding.namespace ?? null, binding.name])
    nameBytes += new TextEncoder().encode((binding.namespace || '') + binding.name + binding.global_name).length
    if (
      !binding.name ||
      binding.namespace === '' ||
      !binding.global_name ||
      new TextEncoder().encode(binding.global_name).length > 256 ||
      nameBytes > 16384 ||
      identities.has(identity) ||
      Object.hasOwn(tools, binding.global_name)
    ) {
      fail('program_invalid_tools', 'program tool identities and JavaScript globals must be valid and unique')
    }
    identities.add(identity)
    if (Object.hasOwn(tools, binding.global_name)) continue
    Object.defineProperty(tools, binding.global_name, {
      enumerable: true,
      value: async (args: unknown = {}) => {
        activity++
        const argumentsValue = parse(stringify(args))
        if (cursor < memo.length) {
          const entry = memo[cursor]
          if (
            (entry.namespace ?? null) !== (binding.namespace ?? null) ||
            entry.name !== binding.name ||
            !equal(entry.arguments, argumentsValue)
          ) {
            fail('program_replay_diverged', 'program replay diverged from the recorded tool call')
            throw new Error(failure!.error)
          }
          cursor++
          return parse(stringify(entry.output))
        }
        const bytes = encode(argumentsValue)
        if (
          bytes > 256 * 1024 ||
          pending.length >= bounded(request.max_pending_calls, 64, 1024) ||
          pendingBytes + bytes > bounded(request.max_pending_bytes, 1024 * 1024, 8 * 1024 * 1024)
        ) {
          fail('program_pending_limit_exceeded', 'program pending calls exceeded the call or byte limit')
          throw new Error(failure!.error)
        }
        pendingBytes += bytes
        pending.push({ namespace: binding.namespace ?? null, name: binding.name, arguments: argumentsValue })
        return await new Promise(() => {})
      }
    })
  }
  if (memo.some(entry => !identities.has(stringify([entry.namespace ?? null, entry.name])))) {
    fail('program_memo_tool_not_allowed', 'program memo references a disabled tool')
  }
  const emit = (kind: string, value: unknown) => {
    activity++
    const text = String(value)
    const bytes = new TextEncoder().encode(text).length
    if (bytes > (kind === 'image' ? 16384 : 65536) || output.length >= 256 || outputBytes + bytes > 1024 * 1024) {
      fail('program_output_limit_exceeded', 'program output exceeded the part or byte limit')
      throw new Error(failure!.error)
    }
    outputBytes += bytes
    output.push({ kind, value: text })
  }
  Object.assign(globalThis, {
    tools,
    text: (value: unknown) => emit('text', value),
    image: (value: unknown) => emit('image', value)
  })
  let seed = 0x2f6e2b1
  Math.random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0
    return seed / 4294967296
  }
  const NativeDate = Date
  Object.assign(globalThis, {
    Date: class extends NativeDate {
      constructor(...args: any[]) {
        super(...((args.length === 0 ? [1735689600000] : args) as [number]))
      }
      static now() {
        return 1735689600000
      }
    }
  })
  serve(async () => {
    for (const name of [
      'fetch',
      'WebSocket',
      'Deno',
      'EdgeRuntime',
      'setTimeout',
      'setInterval',
      'clearTimeout',
      'clearInterval',
      'MessageChannel',
      'MessagePort',
      'Worker',
      'crypto',
      'performance',
      'process'
    ]) {
      Object.defineProperty(globalThis, name, { value: undefined, configurable: false, writable: false })
    }
    const outcome = await new Promise(resolve => {
      let lastActivity = -1
      let idle = 0
      let ended = false
      const finish = () => {
        if (ended) return
        ended = true
        channel.port1.close()
        channel.port2.close()
        if (!failure && status === 'completed' && cursor < memo.length) {
          fail(
            'program_replay_memo_unused',
            `program replay completed with ${memo.length - cursor} unused memo entries`
          )
        }
        if (!failure && status === 'running' && pending.length === 0) {
          fail('program_invalid_terminal_state', 'program neither completed nor paused')
        }
        resolve({
          status: failure ? 'failed' : status === 'completed' ? 'completed' : 'pending',
          output,
          pending_calls: failure || status === 'completed' ? [] : pending,
          ...failure
        })
      }
      if (!failure) {
        Promise.resolve()
          .then(() => new AsyncFunction(request.program)())
          .then(
            () => {
              status = 'completed'
            },
            error => {
              fail('program_execution_failed', String(error?.stack || error))
              status = 'failed'
            }
          )
      }
      channel.port1.onmessage = () => {
        if (failure || status !== 'running') {
          finish()
          return
        }
        idle = lastActivity === activity ? idle + 1 : 0
        lastActivity = activity
        if (idle >= 2) finish()
        else channel.port2.postMessage(null)
      }
      channel.port2.postMessage(null)
    })
    return Response.json(outcome)
  })
}

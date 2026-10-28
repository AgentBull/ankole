import { expect, test } from 'bun:test'
import { runInNewContext } from 'node:vm'
import { MessageChannel } from 'node:worker_threads'
import { buildPtcRunnerModule, type ProgramRequest } from '../main/ptc_bootstrap.ts'

type Call = { namespace: string; name: string; arguments: unknown }
type Outcome = { status: string; output: unknown[]; pending_calls: Call[]; error_code?: string }

const tools = [
  { namespace: 'alpha', name: 'lookup', global_name: 'a' },
  { namespace: 'beta', name: 'lookup', global_name: 'b' },
  { namespace: 'alpha', name: 'store', global_name: 'c' }
]
const calls = tools.flatMap(tool =>
  [null, { nested: [1, true, 'é'] }].map(argumentsValue => ({
    namespace: tool.namespace,
    name: tool.name,
    arguments: argumentsValue
  }))
)

// Execute the production-generated worker in an isolated JavaScript realm.
// Only Deno's HTTP entry point is replaced; replay, promises and MessageChannel
// run unchanged. This unit harness does not verify the native worker sandbox.
async function run(request: Omit<ProgramRequest, 'tools'> & { tools?: ProgramRequest['tools'] }): Promise<Outcome> {
  let handler: (() => Promise<Response>) | undefined
  runInNewContext(buildPtcRunnerModule({ tools, ...request }), {
    TextEncoder,
    Response,
    MessageChannel,
    Deno: { serve: (callback: () => Promise<Response>) => (handler = callback) }
  })
  if (!handler) throw new Error('Production worker did not register its HTTP handler')
  return (await handler()).json() as Promise<Outcome>
}

function* sequences(length: number): Generator<Call[]> {
  if (length === 0) yield []
  else for (const prefix of sequences(length - 1)) for (const call of calls) yield [...prefix, call]
}

function invocation(call: Call) {
  const binding = tools.find(tool => tool.namespace === call.namespace && tool.name === call.name)!
  return `tools.${binding.global_name}(${JSON.stringify(call.arguments)})`
}

test('bounded production replay preserves every prefix of sequential and parallel call sequences', async () => {
  let checked = 0
  for (let length = 0; length <= 3; length++) {
    for (const sequence of sequences(length)) {
      for (let prefix = 0; prefix <= length; prefix++) {
        const memo = sequence.slice(0, prefix).map((call, index) => ({ ...call, output: `result-${index}` }))
        for (const parallel of [false, true]) {
          const program = parallel
            ? `const values = await Promise.all([${sequence.map(invocation).join(',')}]); values.forEach(text);`
            : sequence.map(call => `text(await ${invocation(call)});`).join('\n')
          const outcome = await run({ program, memo })
          const completed = prefix === length
          expect(outcome.status).toBe(completed ? 'completed' : 'pending')
          expect(outcome.pending_calls).toEqual(completed ? [] : sequence.slice(prefix, parallel ? length : prefix + 1))
          expect(outcome.output).toEqual(
            parallel && !completed ? [] : memo.map(entry => ({ kind: 'text', value: entry.output }))
          )
          checked++
        }
      }
    }
  }
  expect(checked).toBe(1970)
}, 30_000)

test('bounded replay mismatches remain failures even when the program catches them', async () => {
  let checked = 0
  for (const expected of calls) {
    for (const actual of calls) {
      if (JSON.stringify(expected) === JSON.stringify(actual)) continue
      for (const parallel of [false, true]) {
        const attempt = `${invocation(actual)}.catch(() => 'caught')`
        const program = parallel
          ? `await Promise.all([${attempt}, tools.c(null).catch(() => 'caught')]); text('done');`
          : `await ${attempt}; await tools.c(null).catch(() => 'caught'); text('done');`
        const outcome = await run({ program, memo: [{ ...expected, output: 'wrong-result' }] })
        expect(outcome.status).toBe('failed')
        expect(outcome.error_code).toBe('program_replay_diverged')
        expect(outcome.pending_calls).toEqual([])
        checked++
      }
    }
  }
  expect(checked).toBe(60)
})

test('replay compares JSON values and rejects unused or disabled memo entries', async () => {
  const argumentsValue = { a: 1, b: { c: [null, true], d: 'é' } }
  const memo = [{ namespace: 'alpha', name: 'lookup', arguments: argumentsValue, output: null }]
  expect(await run({ program: 'text(await tools.a({b:{d:"é",c:[null,true]},a:1}));', memo })).toMatchObject({
    status: 'completed',
    output: [{ kind: 'text', value: 'null' }],
    pending_calls: []
  })
  expect(await run({ program: 'text("done");', memo })).toMatchObject({
    status: 'failed',
    error_code: 'program_replay_memo_unused',
    pending_calls: []
  })
  expect(await run({ program: 'text("done");', memo, tools: tools.slice(1) })).toMatchObject({
    status: 'failed',
    error_code: 'program_memo_tool_not_allowed',
    pending_calls: []
  })
})

test('a caught pending-limit failure never publishes a partial batch', async () => {
  for (let limit = 1; limit <= 3; limit++) {
    for (let count = 1; count <= 4; count++) {
      const program = `await Promise.all([${Array(count).fill('tools.a(null).catch(() => null)').join(',')}]);`
      const outcome = await run({ program, max_pending_calls: limit })
      expect(outcome.status).toBe(count <= limit ? 'pending' : 'failed')
      expect(outcome.pending_calls).toHaveLength(count <= limit ? count : 0)
      if (count > limit) expect(outcome.error_code).toBe('program_pending_limit_exceeded')
    }
  }
})

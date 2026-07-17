import { describe, expect, test } from 'bun:test'
import { parseBatchItem, parseBrowserCommand, parseCLI, shellWords } from '../src/cli/parser'

describe('browser CLI parser', () => {
  test('uses an agent-browser-style verb-first command surface', () => {
    expect(parseCLI(['--session', 'research', '--json', 'fill', '@e4', 'hello'])).toEqual({
      kind: 'command',
      global: { session: 'research', json: true },
      command: { name: 'fill', args: { selector: '@e4', text: 'hello' } }
    })
  })

  test('parses run without treating script arguments as browser flags', () => {
    expect(
      parseCLI(['--timeout', '90000', 'run', 'browser/final.mjs', '--run-dir', 'runs/1', '--', '--page', '2'])
    ).toEqual({
      kind: 'run',
      global: { json: false, timeoutMs: 90_000 },
      scriptPath: 'browser/final.mjs',
      stdin: false,
      runDir: 'runs/1',
      scriptArgs: ['--page', '2']
    })
  })

  test('batch reuses the same command parser', () => {
    const words = shellWords(`fill '@e1' "hello world"`)
    const [name, ...args] = words
    expect(parseBrowserCommand(name!, args)).toEqual({
      name: 'fill',
      args: { selector: '@e1', text: 'hello world' }
    })
  })

  test('accepts output flags after batch and matches agent-browser nth ordering', () => {
    expect(parseCLI(['batch', '--json', '--bail', 'snapshot -i'])).toMatchObject({
      kind: 'batch',
      global: { json: true },
      bail: true
    })
    expect(parseBrowserCommand('find', ['nth', '2', 'a', 'click'])).toEqual({
      name: 'find',
      args: { kind: 'nth', index: 2, selector: 'a', action: 'click' }
    })
    expect(parseBrowserCommand('find', ['role', 'textbox', 'fill', 'hello', '--name', 'username', '--exact'])).toEqual({
      name: 'find',
      args: {
        kind: 'role',
        value: 'textbox',
        action: 'fill',
        text: 'hello',
        name: 'username',
        exact: true
      }
    })
  })

  test('keeps lifecycle commands out of the model-visible parser', () => {
    expect(() => parseCLI(['lifecycle', 'purge'])).toThrow('internal command')
  })

  test('eval --stdin is a CLI concern that never reaches the wire command shape', () => {
    expect(parseCLI(['eval', '--stdin'])).toEqual({ kind: 'eval-stdin', global: { json: false } })
    expect(() => parseBatchItem('eval', ['--stdin'])).toThrow('top-level command')
  })

  test('batch items reject commands outside the batchable vocabulary at parse time', () => {
    expect(() => parseBatchItem('close', [])).toThrow('batch cannot contain close')
    expect(() => parseBatchItem('lease.acquire', ['r'])).toThrow('batch cannot contain lease.acquire')
  })

  test('wait --load validates against the protocol load states', () => {
    expect(parseBrowserCommand('wait', ['--load', 'networkidle'])).toEqual({
      name: 'wait',
      args: { load: 'networkidle' }
    })
    expect(() => parseBrowserCommand('wait', ['--load', 'bogus'])).toThrow('must be one of')
  })
})

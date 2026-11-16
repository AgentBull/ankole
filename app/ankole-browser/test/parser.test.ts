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

  test('parses snapshot --diff and -q/--query filters', () => {
    expect(parseBrowserCommand('snapshot', ['-i', '--diff', '-q', 'Modal'])).toEqual({
      name: 'snapshot',
      args: { interactive: true, diff: true, query: 'Modal' }
    })
    expect(parseBrowserCommand('snapshot', ['--query=/submit|confirm/i', '-c'])).toEqual({
      name: 'snapshot',
      args: { compact: true, query: '/submit|confirm/i' }
    })
  })

  test('parses inline --snap and --snap-diff before or after positional arguments across actions, upload, find, webmcp, and batch', () => {
    expect(parseBrowserCommand('click', ['@e3', '--snap-diff'])).toEqual({
      name: 'click',
      args: { selector: '@e3', snap: 'diff' }
    })
    expect(parseBrowserCommand('click', ['--snap-diff', '@e3'])).toEqual({
      name: 'click',
      args: { selector: '@e3', snap: 'diff' }
    })
    expect(parseBrowserCommand('fill', ['--snap', '@e4', 'hello'])).toEqual({
      name: 'fill',
      args: { selector: '@e4', text: 'hello', snap: 'interactive' }
    })
    expect(parseBrowserCommand('select', ['@e5', 'Enterprise', '--snap'])).toEqual({
      name: 'select',
      args: { selector: '@e5', value: 'Enterprise', snap: 'interactive' }
    })
    expect(parseBrowserCommand('select', ['--snap-diff', '@e5', 'Enterprise'])).toEqual({
      name: 'select',
      args: { selector: '@e5', value: 'Enterprise', snap: 'diff' }
    })
    expect(parseBrowserCommand('upload', ['@e7', 'a.pdf', 'b.pdf', '--snap-diff'])).toEqual({
      name: 'upload',
      args: { selector: '@e7', paths: ['a.pdf', 'b.pdf'], snap: 'diff' }
    })
    expect(parseBrowserCommand('upload', ['--snap-diff', '@e7', 'a.pdf'])).toEqual({
      name: 'upload',
      args: { selector: '@e7', paths: ['a.pdf'], snap: 'diff' }
    })
    expect(parseBrowserCommand('scroll', ['--snap-diff', 'down', '480', '--selector', '#feed'])).toEqual({
      name: 'scroll',
      args: { direction: 'down', pixels: 480, selector: '#feed', snap: 'diff' }
    })
    expect(parseBrowserCommand('find', ['role', 'button', 'click', '--name', 'Save', '--snap-diff'])).toEqual({
      name: 'find',
      args: { kind: 'role', value: 'button', action: 'click', name: 'Save', snap: 'diff' }
    })
    expect(parseBrowserCommand('find', ['--snap-diff', 'role', 'button', 'click', '--name', 'Save'])).toEqual({
      name: 'find',
      args: { kind: 'role', value: 'button', action: 'click', name: 'Save', snap: 'diff' }
    })
    expect(parseBrowserCommand('webmcp', ['call', '--snap-diff', 'search_catalog', '{"query":"kitesurf"}'])).toEqual({
      name: 'webmcp',
      args: { action: 'call', tool: 'search_catalog', input: { query: 'kitesurf' }, snap: 'diff' }
    })
    expect(
      parseCLI(['batch', '--bail', '--snap-diff', 'fill @e1 "alice"', 'select @e2 "Admin"', 'click @e3'])
    ).toMatchObject({
      kind: 'batch',
      bail: true,
      snap: 'diff'
    })
    expect(() => parseBrowserCommand('click', ['@e1', '--snap', '--snap-diff'])).toThrow(
      'cannot combine --snap and --snap-diff'
    )
    expect(() => parseBrowserCommand('find', ['text', 'Save', '--snap'])).toThrow('require an interactive find action')
    expect(() => parseBrowserCommand('find', ['text', 'Save', 'text', '--snap-diff'])).toThrow(
      'require an interactive find action'
    )
    expect(() => parseBrowserCommand('webmcp', ['list', '--snap'])).toThrow('only valid on webmcp call')
  })

  test('parses diagnostics, network, and webmcp commands', () => {
    expect(parseBrowserCommand('diagnostics', [])).toEqual({
      name: 'diagnostics',
      args: {}
    })
    expect(parseBrowserCommand('diagnostics', ['--all', '--include-static', '--url', '/api/', '--clear'])).toEqual({
      name: 'diagnostics',
      args: { all: true, include_static: true, url: '/api/', clear: true }
    })
    expect(parseBrowserCommand('network', [])).toEqual({
      name: 'network',
      args: { mode: 'status' }
    })
    expect(parseBrowserCommand('network', ['no-media'])).toEqual({
      name: 'network',
      args: { mode: 'no-media' }
    })
    expect(() => parseBrowserCommand('network', ['offline'])).toThrow('must be one of: status, default, no-media')
    expect(parseBrowserCommand('webmcp', [])).toEqual({
      name: 'webmcp',
      args: { action: 'list' }
    })
    expect(parseBrowserCommand('webmcp', ['call', 'search_catalog', '{"query":"kitesurf"}', '--snap-diff'])).toEqual({
      name: 'webmcp',
      args: { action: 'call', tool: 'search_catalog', input: { query: 'kitesurf' }, snap: 'diff' }
    })
    expect(() => parseBrowserCommand('webmcp', ['call', 'search_catalog', '[1,2]'])).toThrow('JSON object')
  })
})

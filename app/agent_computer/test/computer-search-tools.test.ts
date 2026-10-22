import { afterAll, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { CommandFinished, ContainerComputer } from '../src/tools/computer/computer'
import type { ComputerToolContext } from '../src/tools/computer/context'
import { createCommandTool } from '../src/tools/computer/command-tool'
import { FffSearchRuntime } from '../src/tools/computer/fff-search'
import { createFindTool } from '../src/tools/computer/find-tool'
import { createGrepTool } from '../src/tools/computer/grep-tool'
import { createLsTool } from '../src/tools/computer/ls-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'
import { FakeDrive } from './support/fake-drive'

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

/** find/grep/ls never touch the computer facade; command/read tests stub what they use. */
function searchContext(agentHome: string, workspaceRoot: string, computer?: ContainerComputer): ComputerToolContext {
  return {
    agentHome,
    workspaceRoot,
    drive: new FakeDrive(agentHome).drive(),
    computer: computer ?? {
      runCommand: async () => {
        throw new Error('computer is not part of this test')
      },
      readFileWindow: async () => {
        throw new Error('computer is not part of this test')
      },
      readFileBytes: async () => {
        throw new Error('computer is not part of this test')
      }
    }
  }
}

function makeHome(): { agentHome: string; workspaceRoot: string } {
  const agentHome = realpathSync(mkdtempSync(join(tmpdir(), 'fff-home-')))
  const workspaceRoot = join(agentHome, 'sessions', '1')
  mkdirSync(workspaceRoot, { recursive: true })
  return { agentHome, workspaceRoot }
}

describe('find/grep/ls over a real index', () => {
  const { agentHome, workspaceRoot } = makeHome()
  const runtime = new FffSearchRuntime()
  const context = searchContext(agentHome, workspaceRoot)
  afterAll(() => runtime.destroyAll())

  mkdirSync(join(workspaceRoot, 'src'), { recursive: true })
  mkdirSync(join(workspaceRoot, 'docs'), { recursive: true })
  writeFileSync(join(workspaceRoot, 'src', 'finder-pool.ts'), 'export function createFinderPool() {\n  return 42\n}\n')
  writeFileSync(join(workspaceRoot, 'src', 'query-builder.ts'), 'export const queryBuilder = 1\n')
  writeFileSync(join(workspaceRoot, 'docs', 'guide.md'), '# Guide\nuse the finder pool\n')
  writeFileSync(join(workspaceRoot, '.hidden-note'), 'dot\n')
  writeFileSync(join(workspaceRoot, 'docs', 'exact name.txt'), 'unique scoped marker\n')
  writeFileSync(join(workspaceRoot, 'docs', 'exact name.txt.backup'), 'unique scoped marker\n')
  for (let index = 0; index < 30; index++) {
    writeFileSync(join(workspaceRoot, 'docs', `page-${String(index).padStart(2, '0')}.md`), `page ${index}\n`)
  }

  const find = createFindTool(context, runtime)
  const grep = createGrepTool(context, runtime)
  const ls = createLsTool(context)

  it('keeps literal file constraints exact for find and grep, including spaces and absolute paths', async () => {
    for (const path of ['docs/exact name.txt', join(workspaceRoot, 'docs/exact name.txt')]) {
      const found = textOf(await find.execute('exact-find', { path }))
      expect(found).toContain('exact name.txt')
      expect(found).not.toContain('exact name.txt.backup')
      const matched = textOf(await grep.execute('exact-grep', { path, pattern: 'unique scoped marker' }))
      expect(matched).toContain('unique scoped marker')
      expect(matched).not.toContain('exact name.txt.backup')
    }
  })

  it('keeps a search outside the workspace inside its requested directory after a parent search', async () => {
    const parent = join(agentHome, 'user-files')
    const child = join(parent, 'selected')
    mkdirSync(child, { recursive: true })
    writeFileSync(join(parent, 'outside.txt'), 'scope marker\n')
    writeFileSync(join(child, 'inside.txt'), 'scope marker\n')
    await find.execute('parent', { path: parent })

    const files = textOf(await find.execute('child-find', { path: child }))
    expect(files).toContain('inside.txt')
    expect(files).not.toContain('outside.txt')
    const matches = textOf(await grep.execute('child-grep', { path: child, pattern: 'scope marker' }))
    expect(matches).toContain('inside.txt')
    expect(matches).not.toContain('outside.txt')
  })

  it('finds files by fuzzy whole-path pattern', async () => {
    const result = await find.execute('t1', { pattern: 'finder pool' })
    expect(textOf(result)).toContain('src/finder-pool.ts')
  })

  it('scopes find with a path glob and reports no matches plainly', async () => {
    const scoped = await find.execute('t2', { pattern: 'guide', path: 'docs/' })
    expect(textOf(scoped)).toContain('docs/guide.md')
    const missing = await find.execute('t3', { pattern: 'zzz-does-not-exist-qqq' })
    expect(textOf(missing)).toContain('No files found')
  })

  it('honors exclude for find', async () => {
    const result = await find.execute('t4', { pattern: 'guide', exclude: 'docs/' })
    expect(textOf(result)).not.toContain('docs/guide.md')
  })

  it('paginates find with an opaque cursor', async () => {
    const first = await find.execute('t5', { pattern: 'page', path: 'docs/', limit: 10 })
    const firstText = textOf(first)
    expect(first.details?.cursor).toBeDefined()
    expect(firstText).toContain('cursor=')
    const seen = new Set(firstText.split('\n').filter(line => line.includes('page-')))
    let cursor = first.details?.cursor
    while (cursor) {
      const next = await find.execute('t5b', { cursor })
      for (const line of textOf(next)
        .split('\n')
        .filter(line => line.includes('page-'))) {
        seen.add(line)
      }
      cursor = next.details?.cursor
    }
    expect(seen.size).toBe(30)
  })

  it('expires unknown find cursors with a rerun hint', async () => {
    const result = await find.execute('t6', { cursor: 'f999999' })
    expect(textOf(result)).toContain('Cursor expired')
  })

  it('greps literal content with file-grouped line numbers', async () => {
    const result = await grep.execute('t7', { pattern: 'createFinderPool' })
    const text = textOf(result)
    expect(text).toContain('src/finder-pool.ts')
    expect(text).toContain(' 1: ')
    expect(text).toContain('createFinderPool')
  })

  it('applies smart-case and scoping', async () => {
    const insensitive = await grep.execute('t8', { pattern: 'createfinderpool' })
    expect(textOf(insensitive)).toContain('finder-pool.ts')
    // A case-sensitive miss either reports nothing or falls back to fuzzy —
    // both mean no exact match existed.
    const sensitive = textOf(await grep.execute('t9', { pattern: 'createfinderpool', caseSensitive: true }))
    expect(sensitive.includes('No matches found') || sensitive.includes('0 exact matches')).toBe(true)
    // guide.md holds the literal phrase but sits outside the src/ scope.
    const unscoped = textOf(await grep.execute('t10', { pattern: 'finder pool' }))
    expect(unscoped).toContain('docs/guide.md')
    const scoped = textOf(await grep.execute('t10b', { pattern: 'finder pool', path: 'src/' }))
    expect(scoped).not.toContain('docs/guide.md')
  })

  it('adds context lines with the dash separator', async () => {
    const result = await grep.execute('t11', { pattern: 'return 42', context: 1 })
    const text = textOf(result)
    expect(text).toContain(' 2: ')
    expect(text).toContain(' 1- ')
    expect(text).toContain(' 3- ')
  })

  it('refuses wildcard-only patterns with a steer', async () => {
    const result = await grep.execute('t12', { pattern: '.*' })
    expect(textOf(result)).toContain('matches everything')
    expect(textOf(result)).toContain('read_file')
  })

  it('requires a pattern unless a cursor is set', async () => {
    const result = await grep.execute('t13', {})
    expect(textOf(result)).toContain('pattern is required')
  })

  it('paginates grep with an opaque cursor', async () => {
    const pageFiles = (text: string) => text.split('\n').filter(line => line.startsWith('docs/page-'))
    const first = await grep.execute('t13c', { pattern: 'page', path: 'docs/', limit: 10 })
    expect(first.details?.cursor).toBeDefined()
    const seen = new Set(pageFiles(textOf(first)))
    let cursor = first.details?.cursor
    while (cursor) {
      const next = await grep.execute('t13d', { cursor })
      for (const file of pageFiles(textOf(next))) seen.add(file)
      cursor = next.details?.cursor
    }
    expect(seen.size).toBe(30)
  })

  it('expires unknown grep cursors with a rerun hint', async () => {
    const result = await grep.execute('t13b', { cursor: 'g999999' })
    expect(textOf(result)).toContain('Cursor expired')
  })

  it('lists a directory alphabetically with markers and dotfiles', async () => {
    const result = await ls.execute('t14', {})
    const lines = textOf(result).split('\n')
    expect(lines).toContain('.hidden-note')
    expect(lines).toContain('docs/')
    expect(lines).toContain('src/')
    expect(lines.indexOf('docs/')).toBeLessThan(lines.indexOf('src/'))
  })

  it('caps ls entries and points at the next limit', async () => {
    const result = await ls.execute('t15', { path: 'docs', limit: 5 })
    const text = textOf(result)
    expect(text).toContain('5 entries limit reached')
    expect(result.details?.truncated).toBe(true)
  })

  it('reports ls misses as text, not failures', async () => {
    expect(textOf(await ls.execute('t16', { path: 'nope' }))).toContain('Path not found')
    expect(textOf(await ls.execute('t17', { path: 'docs/guide.md' }))).toContain('Not a directory')
    expect(textOf(await ls.execute('t18', { path: '/etc' }))).toContain('outside the agent home')
  })
})

it('finds and greps the Agent Home when it is the process home directory', async () => {
  const { agentHome, workspaceRoot } = makeHome()
  writeFileSync(join(agentHome, 'home-search-marker.txt'), 'HOME_SEARCH_CONTENT\n')
  const script = `
    import { createComputerTools } from './src/tools/computer/index.ts'
    import { fffSearchRuntime } from './src/tools/computer/fff-search.ts'
    import { FakeDrive } from './test/support/fake-drive.ts'
    const agentHome = process.env.HOME
    const workspaceRoot = process.env.ANKOLE_SEARCH_TEST_WORKSPACE
    const tools = createComputerTools({ agentHome, workspaceRoot, drive: new FakeDrive(agentHome).drive() })
    try {
      await fffSearchRuntime.acquire(workspaceRoot)
      const find = tools.find(tool => tool.name === 'find')
      const grep = tools.find(tool => tool.name === 'grep')
      const found = await find.execute('home-find', { path: agentHome, pattern: 'home-search-marker' })
      const matched = await grep.execute('home-grep', { path: '~', pattern: 'HOME_SEARCH_CONTENT' })
      const outside = await find.execute('outside-find', { path: '/' })
      console.log(JSON.stringify({ found, matched, outside }))
    } finally {
      fffSearchRuntime.destroyAll()
    }
  `
  const child = Bun.spawn([process.execPath, '--eval', script], {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env, HOME: agentHome, ANKOLE_SEARCH_TEST_WORKSPACE: workspaceRoot },
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  expect({ exitCode, stderr }).toEqual({ exitCode: 0, stderr: '' })
  const output = JSON.parse(stdout)
  expect(textOf(output.found)).toContain(`${agentHome}/home-search-marker.txt`)
  expect(textOf(output.matched)).toContain('HOME_SEARCH_CONTENT')
  expect(textOf(output.outside)).toContain('outside the agent home')
}, 30_000)

class BigOutputCommand implements CommandFinished {
  constructor(
    readonly exitCode: number,
    private readonly stdout: string
  ) {}

  async output(): Promise<string> {
    return this.stdout
  }
}

describe('command output persistence', () => {
  const { agentHome, workspaceRoot } = makeHome()

  function commandComputer(stdout: string): ContainerComputer {
    return {
      runCommand: async () => new BigOutputCommand(0, stdout),
      readFileWindow: async () => null,
      readFileBytes: async () => null
    }
  }

  it('saves truncated output under the agent home and says so', async () => {
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, commandComputer('x'.repeat(60_000))))
    const result = await command.execute('call_1', { command: 'echo big' })
    const text = textOf(result)
    expect(text).toContain('[output truncated')
    expect(text).toContain('captured output saved to:')
    const logDir = join(agentHome, '.ankole', 'command-logs')
    expect(existsSync(join(logDir, 'call_1.log'))).toBe(true)
    expect(result.details?.outputLogPath).toBe(join(logDir, 'call_1.log'))
  })

  it('writes nothing for output inside the budget', async () => {
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, commandComputer('small output')))
    const result = await command.execute('call_2', { command: 'echo small' })
    expect(textOf(result)).not.toContain('saved to:')
    expect(existsSync(join(agentHome, '.ankole', 'command-logs', 'call_2.log'))).toBe(false)
  })

  it('keeps incomplete capture visible outside the clipped output and never invents unread byte counts', async () => {
    const computer = commandComputer('x'.repeat(60_000))
    computer.runCommand = async () =>
      Object.assign(new BigOutputCommand(0, 'x'.repeat(60_000)), {
        outputCapture: { observedBytes: 60_000, droppedBytes: 0, drained: false }
      })
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, computer))
    const result = await command.execute('incomplete', { command: 'report' })
    const text = textOf(result)
    expect(text).toContain('[output truncated')
    expect(text).toContain('[output capture ended before EOF; remaining output size is unknown]')
    expect(text).not.toContain('of 60000 observed bytes')
    expect(result.details?.outputCapture).toEqual({ observedBytes: 60_000, droppedBytes: 0, drained: false })
    expect(readFileSync(result.details!.outputLogPath!, 'utf8')).toBe('x'.repeat(60_000))
  })

  it('keeps only the newest logs', async () => {
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, commandComputer('y'.repeat(60_000))))
    for (let index = 0; index < 25; index++) {
      await command.execute(`sweep_${index}`, { command: 'echo big' })
    }
    const names = readdirSync(join(agentHome, '.ankole', 'command-logs')).filter(name => name.endsWith('.log'))
    expect(names.length).toBeLessThanOrEqual(20)
    expect(names).toContain('sweep_24.log')
  })
})

describe('read_file budget clipping', () => {
  it('returns the lines that fit and an exact continuation offset', async () => {
    const longLine = 'a'.repeat(2500)
    const lines = Array.from({ length: 80 }, () => longLine)
    const computer: ContainerComputer = {
      runCommand: async () => new BigOutputCommand(0, ''),
      readFileWindow: async (input: { offset: number; limit: number }) => ({
        sniff: Buffer.from(longLine),
        totalLines: lines.length,
        lines: lines.slice(input.offset - 1, input.offset - 1 + input.limit)
      }),
      readFileBytes: async () => null
    }
    const { agentHome, workspaceRoot } = makeHome()
    const readFile = createReadFileTool(searchContext(agentHome, workspaceRoot, computer))
    const result = await readFile.execute('t19', { path: 'big.txt' })
    const text = textOf(result)
    expect(text).toContain('char budget')
    expect(result.details?.truncated).toBe(true)
    const match = text.match(/continue with offset=(\d+)/)
    expect(match).not.toBeNull()
    const nextOffset = Number(match![1])
    expect(nextOffset).toBeGreaterThan(1)
    expect(nextOffset).toBeLessThan(81)
    expect(text).toContain(`${nextOffset - 1}|`)
    expect(text).not.toContain(`\n${nextOffset}|`)
  })
})

import { afterAll, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { CommandFinished, ContainerComputer } from '../src/tools/computer/computer'
import type { ComputerToolContext } from '../src/tools/computer/context'
import { createCommandTool } from '../src/tools/computer/command-tool'
import {
  FffSearchRuntime,
  buildSearchQuery,
  fileAnnotation,
  normalizeConstraint,
  normalizeExcludes,
  resolveSearchTarget
} from '../src/tools/computer/fff-search'
import { createFindTool } from '../src/tools/computer/find-tool'
import { clipLinesToBudget } from '../src/tools/computer/format'
import { createGrepTool } from '../src/tools/computer/grep-tool'
import { createLsTool } from '../src/tools/computer/ls-tool'
import { createReadFileTool } from '../src/tools/computer/read-file-tool'

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
    userFilesRoot: join(agentHome, 'user-files'),
    getComputer: async () => {
      if (!computer) throw new Error('computer facade is not part of this test')
      return computer
    }
  }
}

function makeHome(): { agentHome: string; workspaceRoot: string } {
  const agentHome = realpathSync(mkdtempSync(join(tmpdir(), 'fff-home-')))
  const workspaceRoot = join(agentHome, 'sessions', '1')
  mkdirSync(workspaceRoot, { recursive: true })
  return { agentHome, workspaceRoot }
}

describe('search query building', () => {
  it('normalizes constraints into parser shapes', () => {
    expect(normalizeConstraint('src')).toBe('src/')
    expect(normalizeConstraint('./src/')).toBe('src/')
    expect(normalizeConstraint('main.rs')).toBe('main.rs')
    expect(normalizeConstraint('src/**')).toBe('src/')
    expect(normalizeConstraint('src/**/*')).toBe('src/')
    expect(normalizeConstraint('src/**/*.ts')).toBe('src/**/*.ts')
    expect(normalizeConstraint('*.ts')).toBe('*.ts')
    expect(normalizeConstraint('**')).toBeUndefined()
    expect(normalizeConstraint('.')).toBeUndefined()
    expect(normalizeConstraint('')).toBeUndefined()
  })

  it('normalizes excludes from strings, arrays, and negated forms', () => {
    expect(normalizeExcludes('test/,*.min.js')).toEqual(['!test/', '!*.min.js'])
    expect(normalizeExcludes('!vendor')).toEqual(['!vendor/'])
    expect(normalizeExcludes(['a.txt', 'b/'])).toEqual(['!a.txt', '!b/'])
    expect(normalizeExcludes(undefined)).toEqual([])
  })

  it('assembles constraint, excludes, and pattern in parser order', () => {
    expect(buildSearchQuery({ constraint: 'src/', excludes: ['!test/'], pattern: 'main' })).toBe('src/ !test/ main')
    expect(buildSearchQuery({ constraint: undefined, excludes: [], pattern: '  ' })).toBe('')
  })

  it('annotates git state ahead of frecency, one tag at most', () => {
    expect(fileAnnotation({ gitStatus: 'modified', totalFrecencyScore: 99 })).toBe('  [modified in git]')
    expect(fileAnnotation({ gitStatus: 'clean', totalFrecencyScore: 26 })).toBe('  [VERY often touched file]')
    expect(fileAnnotation({ gitStatus: '', totalFrecencyScore: 21 })).toBe('  [often touched file]')
    expect(fileAnnotation({ gitStatus: 'unknown', totalFrecencyScore: 3 })).toBe('')
  })

  it('clips to a budget on line boundaries and keeps at least one line', () => {
    const clipped = clipLinesToBudget('aaa\nbbb\nccc', 7)
    expect(clipped).toEqual({ text: 'aaa\nbbb', clipped: true, keptLines: 2, totalLines: 3 })
    expect(clipLinesToBudget('short', 100).clipped).toBe(false)
    const giant = clipLinesToBudget('x'.repeat(50), 10)
    expect(giant.text).toBe('x'.repeat(10))
    expect(giant.keptLines).toBe(1)
  })
})

describe('resolveSearchTarget', () => {
  const { agentHome, workspaceRoot } = makeHome()
  mkdirSync(join(workspaceRoot, 'src'), { recursive: true })
  mkdirSync(join(agentHome, 'user-files'), { recursive: true })

  it('defaults to the workspace root', () => {
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, undefined)
    expect(target).toEqual({ ok: true, root: realpathSync(workspaceRoot) })
  })

  it('folds workspace-relative paths onto the workspace finder', () => {
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, 'src')
    expect(target).toEqual({ ok: true, root: realpathSync(workspaceRoot), constraint: 'src/' })
  })

  it('keeps glob and missing segments as the constraint', () => {
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, 'src/**/*.ts')
    expect(target).toEqual({ ok: true, root: realpathSync(workspaceRoot), constraint: 'src/**/*.ts' })
  })

  it('routes ~ paths to a root outside the workspace', () => {
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, '~/user-files')
    expect(target).toEqual({ ok: true, root: join(realpathSync(agentHome), 'user-files') })
  })

  it('refuses roots outside the agent home', () => {
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, '/etc')
    expect(target.ok).toBe(false)
    if (!target.ok) expect(target.message).toContain('outside the agent home')
  })

  it('refuses symlinks that escape the agent home', () => {
    const outside = mkdtempSync(join(tmpdir(), 'fff-outside-'))
    symlinkSync(outside, join(workspaceRoot, 'escape'))
    const target = resolveSearchTarget({ agentHome, workspaceRoot }, 'escape')
    expect(target.ok).toBe(false)
  })
})

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
  for (let index = 0; index < 30; index++) {
    writeFileSync(join(workspaceRoot, 'docs', `page-${String(index).padStart(2, '0')}.md`), `page ${index}\n`)
  }

  const find = createFindTool(context, runtime)
  const grep = createGrepTool(context, runtime)
  const ls = createLsTool(context)

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
      fileSize: async () => null,
      readFileWindow: async () => null,
      fs: { writeFiles: async () => {} }
    }
  }

  it('saves truncated output under the agent home and says so', async () => {
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, commandComputer('x'.repeat(60_000))))
    const result = await command.execute('call_1', { command: 'echo big' })
    const text = textOf(result)
    expect(text).toContain('[output truncated')
    expect(text).toContain('output before truncation saved to:')
    const logDir = join(agentHome, '.ankole', 'command-logs')
    expect(existsSync(join(logDir, 'call_1.log'))).toBe(true)
    expect(result.details?.fullOutputPath).toBe(join(logDir, 'call_1.log'))
  })

  it('writes nothing for output inside the budget', async () => {
    const command = createCommandTool(searchContext(agentHome, workspaceRoot, commandComputer('small output')))
    const result = await command.execute('call_2', { command: 'echo small' })
    expect(textOf(result)).not.toContain('saved to:')
    expect(existsSync(join(agentHome, '.ankole', 'command-logs', 'call_2.log'))).toBe(false)
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
      fileSize: async () => null,
      readFileWindow: async (input: { offset: number; limit: number }) => ({
        sniff: Buffer.from(longLine),
        totalLines: lines.length,
        lines: lines.slice(input.offset - 1, input.offset - 1 + input.limit)
      }),
      fs: { writeFiles: async () => {} }
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

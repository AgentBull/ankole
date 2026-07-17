import { expect, test } from 'bun:test'
import { readFile } from 'node:fs/promises'
import { dirname, relative, resolve } from 'node:path'

const packageRoot = resolve(import.meta.dir, '..')

test('browser data plane has no control-plane or Agent Computer dependency', async () => {
  const violations: string[] = []
  const glob = new Bun.Glob('src/**/*.ts')
  for await (const file of glob.scan({ cwd: packageRoot })) {
    const source = await readFile(resolve(packageRoot, file), 'utf8')
    for (const match of source.matchAll(/(?:from\s+|import\s*\()\s*['"]([^'"]+)['"]/g)) {
      const specifier = match[1]!
      if (specifier.startsWith('@ankole/')) violations.push(`${file}: ${specifier}`)
      if (/control_plane|agent_computer|AppConfigure|Principal|BackgroundAgentJob/i.test(specifier)) {
        violations.push(`${file}: ${specifier}`)
      }
      if (specifier.startsWith('.')) {
        const target = resolve(packageRoot, dirname(file), specifier)
        const escaped = relative(packageRoot, target)
        if (escaped === '..' || escaped.startsWith('../')) violations.push(`${file}: ${specifier}`)
      }
    }
  }

  const manifest = JSON.parse(await readFile(resolve(packageRoot, 'package.json'), 'utf8')) as {
    dependencies?: Record<string, string>
  }
  expect(Object.keys(manifest.dependencies ?? {}).sort()).toEqual(['playwright-core', 'zod'])
  expect(violations).toEqual([])
})

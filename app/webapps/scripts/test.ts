import { existsSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { edition, internalsRoot, repositoryRoot } from './edition'

const paths = ['./common', './console', './setup/state', './auth', './pod']
if (edition === 'saas') {
  paths.push(path.join(internalsRoot, 'webapps'))
  const pluginsRoot = path.join(internalsRoot, 'plugins')
  if (existsSync(pluginsRoot)) {
    for (const entry of readdirSync(pluginsRoot, { withFileTypes: true }).sort((a, b) =>
      a.name.localeCompare(b.name)
    )) {
      if (!entry.isDirectory()) continue
      const pluginWebapps = path.join(pluginsRoot, entry.name, 'webapps')
      if (existsSync(pluginWebapps)) paths.push(pluginWebapps)
    }
  }
}
process.exit(
  await Bun.spawn(['bun', 'test', '--preload', './scripts/test-preload.ts', ...paths, ...process.argv.slice(2)], {
    cwd: path.join(repositoryRoot, 'app/webapps'),
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  }).exited
)

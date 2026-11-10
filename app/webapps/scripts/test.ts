import path from 'node:path'
import { edition, internalsRoot, repositoryRoot } from './edition'

const paths = ['./common', './console', './setup/state', './auth', './pod']
if (edition === 'saas') paths.push(path.join(internalsRoot, 'webapps'))
process.exit(
  await Bun.spawn(['bun', 'test', '--preload', './scripts/test-preload.ts', ...paths, ...process.argv.slice(2)], {
    cwd: path.join(repositoryRoot, 'app/webapps'),
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  }).exited
)

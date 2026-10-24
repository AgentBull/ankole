import path from 'node:path'
import { edition, repositoryRoot } from './edition'

const paths = ['./common', './console', './setup/state', './auth/state', './pod/state']
if (edition === 'saas') paths.push(path.join(repositoryRoot, 'internals/webapps'))
process.exit(
  await Bun.spawn(['bun', 'test', '--preload', './scripts/test-preload.ts', ...paths, ...process.argv.slice(2)], {
    cwd: path.join(repositoryRoot, 'app/webapps'),
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  }).exited
)

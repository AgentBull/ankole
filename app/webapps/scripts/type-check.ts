import path from 'node:path'
import { mkdirSync, writeFileSync } from 'node:fs'
import { artifactRoot, edition, prepareEdition, repositoryRoot } from './edition'

prepareEdition()
const publicRoot = path.join(repositoryRoot, 'app/webapps')
let project = path.join(publicRoot, 'tsconfig.json')
if (edition === 'saas') {
  const base = await Bun.file(project).json()
  const destination = path.join(artifactRoot, 'webapps')
  mkdirSync(destination, { recursive: true })
  const config = {
    extends: project,
    compilerOptions: { typeRoots: [path.join(publicRoot, 'node_modules/@types')] },
    include: [
      ...base.include.map((pattern: string) => path.join(publicRoot, pattern)),
      path.join(repositoryRoot, 'internals/webapps/**/*.ts'),
      path.join(repositoryRoot, 'internals/webapps/**/*.tsx')
    ]
  }
  project = path.join(destination, 'tsconfig.json')
  writeFileSync(project, JSON.stringify(config))
}
process.exit(
  await Bun.spawn(['tsc', '-p', project, '--noEmit'], {
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  }).exited
)

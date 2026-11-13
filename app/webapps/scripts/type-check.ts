import path from 'node:path'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { artifactRoot, edition, editionModulesFile, internalsRoot, prepareEdition, repositoryRoot } from './edition'

prepareEdition()
const publicRoot = path.join(repositoryRoot, 'app/webapps')
let project = path.join(publicRoot, 'tsconfig.json')
if (edition === 'saas') {
  const base = await Bun.file(project).json()
  const destination = path.join(artifactRoot, 'webapps')
  mkdirSync(destination, { recursive: true })
  const pluginsRoot = path.join(internalsRoot, 'plugins')
  const config = {
    extends: project,
    compilerOptions: {
      typeRoots: [path.join(publicRoot, 'node_modules/@types')],
      paths: {
        '@ankole/edition-modules/*': [editionModulesFile]
      }
    },
    include: [
      ...base.include.map((pattern: string) => path.join(publicRoot, pattern)),
      editionModulesFile,
      path.join(internalsRoot, 'webapps/**/*.ts'),
      path.join(internalsRoot, 'webapps/**/*.tsx'),
      ...(existsSync(pluginsRoot)
        ? [path.join(pluginsRoot, '*/webapps/**/*.ts'), path.join(pluginsRoot, '*/webapps/**/*.tsx')]
        : [])
    ]
  }
  project = path.join(destination, 'tsconfig.json')
  writeFileSync(project, JSON.stringify(config))
}
process.exit(
  await Bun.spawn([process.execPath, 'check', '-p', project, '--noEmit'], {
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  }).exited
)

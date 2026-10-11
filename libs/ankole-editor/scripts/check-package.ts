import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'

const project = resolve(import.meta.dir, '..')
const consumer = await mkdtemp(resolve(tmpdir(), 'ankole-editor-consumer-'))
const manifest = JSON.parse(await readFile(resolve(project, 'package.json'), 'utf8'))
const workspace = JSON.parse(await readFile(resolve(project, '../../package.json'), 'utf8'))
const patchPrefix = 'libs/ankole-editor/'
const patchedDependencies = Object.fromEntries(
  Object.entries(workspace.patchedDependencies as Record<string, string>)
    .filter(([, path]) => path.startsWith(`${patchPrefix}patches/`))
    .map(([name, path]) => [name, path.slice(patchPrefix.length)])
)

async function run(command: string[], cwd: string, env = process.env) {
  const child = Bun.spawn(command, { cwd, env, stdout: 'inherit', stderr: 'inherit' })
  if ((await child.exited) !== 0) throw new Error(`Command failed: ${command.join(' ')}`)
}

console.warn(`Isolated package consumer: ${consumer}`)
try {
  await run(
    ['bun', 'pm', 'pack', '--ignore-scripts', '--filename', resolve(consumer, 'editor.tgz'), '--quiet'],
    project
  )
  await run(
    ['bun', 'pm', 'pack', '--ignore-scripts', '--filename', resolve(consumer, 'uikit.tgz'), '--quiet'],
    resolve(project, '../uikit')
  )
  await cp(resolve(project, 'patches'), resolve(consumer, 'patches'), { recursive: true })
  const dependencies = {
    [manifest.name]: './editor.tgz',
    '@ankole/uikit': './uikit.tgz',
    ...manifest.peerDependencies
  }
  const devDependencies = Object.fromEntries(
    [
      'vite',
      '@vitejs/plugin-react',
      '@tailwindcss/vite',
      'typescript',
      '@types/react',
      '@types/react-dom',
      '@types/bun'
    ].map(name => [name, manifest.devDependencies[name]])
  )
  await writeFile(
    resolve(consumer, 'package.json'),
    JSON.stringify(
      {
        name: 'block-editor-consumer-check',
        private: true,
        type: 'module',
        dependencies,
        devDependencies,
        overrides: { '@ankole/uikit': './uikit.tgz' },
        patchedDependencies,
        scripts: { build: 'bun --bun vite build', preview: 'bun --bun vite preview --host 127.0.0.1' }
      },
      null,
      2
    )
  )
  await mkdir(resolve(consumer, 'playground'))
  for (const name of ['embedded.html', 'embedded.tsx', 'embedded.css']) {
    await cp(resolve(project, 'playground', name), resolve(consumer, 'playground', name))
  }
  await writeFile(
    resolve(consumer, 'vite.config.ts'),
    `
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { dedupe: ['react', 'react-dom'] },
  build: { target: ['chrome126', 'firefox153', 'safari17'], cssTarget: ['chrome126', 'firefox153', 'safari17'],
    rolldownOptions: { input: 'playground/embedded.html' } }
})
`
  )
  await writeFile(
    resolve(consumer, 'tsconfig.json'),
    JSON.stringify(
      {
        compilerOptions: {
          target: 'ES2022',
          module: 'ESNext',
          moduleResolution: 'bundler',
          jsx: 'react-jsx',
          strict: true,
          skipLibCheck: true,
          noEmit: true,
          types: ['bun', 'vite/client']
        },
        include: ['playground', 'smoke.ts']
      },
      null,
      2
    )
  )
  // Bun has no DOM, so the smoke test uses editor states without a view. The embedding test runs
  // the visible editor and PageSession in browsers.
  await writeFile(
    resolve(consumer, 'smoke.ts'),
    `
import { headlessState, readTree, replaceTree } from '@ankole/block-editor/editor'
import { parseMarkdown, printMarkdown, printXml, parseXml, sameTree } from '@ankole/block-editor/document'
const source = '<future version="0">\\n  Content **with marks**\\n</future>'
const page = readTree(headlessState(source).doc)
if (!sameTree(parseMarkdown(source), parseXml(printXml(page)))) throw new Error('Package tree mismatch')
const reopened = readTree(headlessState(printMarkdown(page)).doc)
const state = headlessState('Before')
const written = readTree(state.update(replaceTree(state, parseXml(printXml(page)))).state.doc)
if (printXml(reopened) !== printXml(page) || printXml(written) !== printXml(page)) throw new Error('Package editor mismatch')
`
  )
  await run(['bun', 'install'], consumer)
  await run(['bun', 'node_modules/typescript/bin/tsc', '--noEmit'], consumer)
  await run(['bun', 'smoke.ts'], consumer)
  await run(['bun', 'run', 'build'], consumer)
  await run(['bun', 'run', 'test:e2e', 'e2e/embedding.spec.ts'], project, {
    ...process.env,
    E2E_CONSUMER_ROOT: consumer,
    E2E_PREVIEW: '1'
  })
  await rm(consumer, { recursive: true })
  console.warn('Package installation, public types, codecs and three-browser embedding passed.')
} catch (error) {
  console.error(`Consumer files retained for inspection: ${consumer}`)
  throw error
}
